"""FIT-07 — one budget for every NPC the police layer spawns.

Static contract plus a pure-Lua behaviour test (no FXServer, no DB, no
network):

* ``shared/npc_budget.lua`` owns the caps / slot costs / pure admission check;
* ``server/npc_budget.lua`` owns Acquire/Release/Sweep/Get, the audit rows
  (``npc.spawn`` / ``npc.despawn`` / ``npc.stale``) and the 60s sweep timer;
* ``RequestBackup`` and ``CreateNpcCallout`` both call ``Acquire`` and every
  release path calls ``Release``;
* the generated Lua harness drives the real server file against a MySQL stub
  and checks the global cap (6), per-player cap (2), duplicate ids, the callout
  cost (2), release idempotency, the 10-minute TTL and the audit details.

    python3 -m pytest -q tests/architecture/test_npc_budget.py
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
POLICE = BASE / "resources" / "[custom]" / "custom-police"
SHARED = POLICE / "shared" / "npc_budget.lua"
SERVER = POLICE / "server" / "npc_budget.lua"
P2 = POLICE / "server" / "p2_system.lua"
P4 = POLICE / "server" / "p4_npc.lua"
MANIFEST = POLICE / "fxmanifest.lua"
LUA_BIN = shutil.which("lua5.4")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# Static wiring
# ---------------------------------------------------------------------------

def test_manifest_loads_budget_shared_and_server_and_bumps_version():
    manifest = read(MANIFEST)
    assert "shared/npc_budget.lua" in manifest
    assert "server/npc_budget.lua" in manifest
    assert manifest.index("shared/npc_budget.lua") < manifest.index("server/npc_budget.lua")
    assert manifest.index("server/npc_budget.lua") < manifest.index("server/p2_system.lua")
    assert "version '1.7.0'" in manifest
    assert "version '1.6.0'" not in manifest


def test_shared_module_pins_caps_costs_and_pure_check():
    src = read(SHARED)
    for token in (
        "NPCBudget.MAX_GLOBAL = 6",
        "NPCBudget.MAX_PLAYER = 2",
        "NPCBudget.TTL_SECONDS = 10 * 60",
        "NPCBudget.SWEEP_INTERVAL_MS = 60 * 1000",
        "backup = 1",
        "callout = 2",
        "function NPCBudget.CanAcquire(",
        "return false, 'invalid_kind'",
        "return false, 'invalid_id'",
        "return false, 'duplicate'",
        "return false, 'global_limit'",
        "return false, 'player_limit'",
    ):
        assert token in src, token


def test_server_module_implements_acquire_release_sweep_get_and_audit():
    src = read(SERVER)
    for token in (
        "function NPCBudget.Acquire(",
        "function NPCBudget.Release(",
        "function NPCBudget.Sweep(",
        "function NPCBudget.Get(",
        "function GetNpcBudget(",
        "exports('GetNpcBudget', GetNpcBudget)",
        "auditNpc('npc.spawn'",
        "auditNpc('npc.despawn'",
        "auditNpc('npc.stale'",
        "entries[key] = {",
        "if not entry then return false end",
        "NPCBudget.SWEEP_INTERVAL_MS",
        "AddEventHandler('onResourceStart'",
    ):
        assert token in src, token

    # The snapshot is a copy, not the live table.
    get_block = src[src.index("function NPCBudget.Get("):src.index("--- Global read-only accessor")]
    assert "used = used" in get_block
    assert "max = NPCBudget.MAX_GLOBAL" in get_block
    assert "byPlayer = byPlayer" in get_block
    assert "entries = list" in get_block


def test_backup_acquires_and_releases_through_the_budget():
    src = read(P2)
    assert "NPCBudget.Acquire('backup', requestId, cid)" in src
    # 审计失败 / 玩家离开 / 半支队伍：rollback 必须把这一组槽全部退回。
    assert "NPCBudget.Release(id, 'request_rollback')" in src
    assert "NPCBudget.Release(requestId, 'backup_ended')" in src
    assert "releaseBackupSlots(cid, 'player_dropped')" in src
    # The old per-citizen table is gone: the budget is the only counter.
    assert "backupUnits" not in src
    # BACKUP_MAX_UNITS 只是"一次响应最多几辆车"的夹取常量（每车 1 槽），
    # 真正的每人上限仍然只由预算判定，所以这里断言它是个常量而不是计数器。
    assert "local BACKUP_MAX_UNITS = 2" in src
    assert "if units > BACKUP_MAX_UNITS then units = BACKUP_MAX_UNITS end" in src
    assert "BACKUP_COOLDOWN = 60" in src


def test_backup_binds_source_before_the_yielding_acquire():
    """A drop during the budget's audit insert must still find the reservation."""
    src = read(P2)
    bind = src.index("backupSource[src] = cid")
    acquire = src.index("local admitted, budgetError = NPCBudget.Acquire('backup'")
    assert bind < acquire
    # 恢复映射只允许出现在 rollback 里，且不能复活 playerDropped 已经清掉的映射。
    rollback_at = src.index("local function rollback(errorCode)")
    restore = "if backupSource[src] == cid then backupSource[src] = previousSource end"
    restore_at = src.index(restore)
    assert rollback_at < restore_at, "恢复映射只允许出现在 rollback 里"


def test_callout_acquires_and_releases_through_the_budget():
    src = read(P4)
    assert "NPCBudget.Acquire('callout', budgetId, actorCid)" in src
    # 唯一写者把失败原因透传出来（可能是 db_error，也可能是 invalid_title 之类），
    # 但"写库失败必须释放预算"这条不能变。
    assert "NPCBudget.Release(budgetId, insertReason or 'db_error')" in src
    assert "NPCBudget.Release(budgetId, 'no_location')" in src
    assert "NPCBudget.Release(budgetId, 'callout_limit')" in src
    assert "releaseCalloutBudget(id, 'callout_already_closed')" in src
    assert "releaseCalloutBudget(id, 'callout_result')" in src
    assert "releaseCalloutBudget(incidentId, 'callout_watcher')" in src


# ---------------------------------------------------------------------------
# Behaviour (real Lua files + stubs)
# ---------------------------------------------------------------------------

HARNESS = r"""
-- Generated FIT-07 harness: load the real shared/server budget files against
-- a MySQL stub, then exercise the public API.
local audit = {}
local exported = {}
local clock = 1000000
os.time = function() return clock end

MySQL = {
    insert = {
        await = function(sql, params)
            audit[#audit + 1] = { sql = sql, params = params }
            return 1
        end,
    },
    query = {                       -- 审计唯一写者用 query.await
        await = function(sql, params)
            audit[#audit + 1] = { sql = sql, params = params }
            return { affectedRows = 1 }
        end,
    },
}
AddEventHandler = function(_name, _fn) end
CreateThread = function(_fn) end
Wait = function(_ms) end
GetCurrentResourceName = function() return 'custom-police' end
exports = function(name, fn) exported[name] = fn end

dofile(__AUDIT__)   -- 审计唯一写者（npc_budget 的 auditNpc 委派给它）
dofile(__SHARED__)
dofile(__SERVER__)

local function expect(condition, message)
    if not condition then error(message, 2) end
end

-- 参数布局现在由 server/audit.lua 决定：{ actor, actor_kind, action, target?, detail? }
-- （actor_kind 是真实参数，不再是 SQL 里的字面量），所以按值找 action 而不是按下标猜。
local function params_contain(row, value)
    for _, v in ipairs(row.params) do
        if v == value then return true end
    end
    return false
end

local function audit_rows(action)
    local rows = {}
    for _, row in ipairs(audit) do
        if params_contain(row, action) then rows[#rows + 1] = row end
    end
    return rows
end

local function find_audit(action, target)
    for _, row in ipairs(audit) do
        if params_contain(row, action) and params_contain(row, target) then return row end
    end
    return nil
end

-- Constants + empty snapshot.
expect(NPCBudget.MAX_GLOBAL == 6, 'global cap must be 6')
expect(NPCBudget.MAX_PLAYER == 2, 'player cap must be 2')
expect(NPCBudget.TTL_SECONDS == 600, 'ttl must be 600s')
local snapshot = GetNpcBudget()
expect(snapshot.used == 0 and snapshot.max == 6, 'empty used/max')
expect(#snapshot.entries == 0 and next(snapshot.byPlayer) == nil, 'empty entries')

-- Per-player cap: backup costs 1, two units fill one citizen.
expect(NPCBudget.Acquire('backup', 'b1', 'cidA') == true, 'b1 admitted')
expect(NPCBudget.Acquire('backup', 'b2', 'cidA') == true, 'b2 admitted')
local ok, err = NPCBudget.Acquire('backup', 'b3', 'cidA')
expect(ok == false and err == 'player_limit', 'third unit must be player_limit')
snapshot = GetNpcBudget()
expect(snapshot.used == 2, 'two backup slots used')
expect(snapshot.byPlayer.cidA == 2, 'player A has two slots')
expect(#snapshot.entries == 2, 'two entries')

-- Release is idempotent and audited exactly once.
expect(NPCBudget.Release('b1', 'test_release') == true, 'release b1')
expect(NPCBudget.Release('b1', 'again') == false, 'second release is false')
expect(NPCBudget.Release('missing', 'nope') == false, 'unknown id is false')
local despawn = find_audit('npc.despawn', 'b1')
expect(despawn ~= nil, 'npc.despawn audited')
expect(despawn.params[1] == 'cidA', 'despawn owner')
-- 参数布局 { actor, actor_kind, action, target, detail }：reason 在第 5 位
expect(despawn.params[5] == 'test_release', 'despawn reason')
expect(#audit_rows('npc.despawn') == 1, 'one despawn audit')

-- Global cap: b2(1) + b4(1) + callout c1(2) + b5(1) + b6(1) = 6.
expect(NPCBudget.Acquire('backup', 'b4', 'cidB') == true, 'b4 admitted')
expect(NPCBudget.Acquire('callout', 'c1', 'cidC') == true, 'callout admitted')
expect(NPCBudget.Acquire('backup', 'b5', 'cidD') == true, 'b5 admitted')
expect(NPCBudget.Acquire('backup', 'b6', 'cidE') == true, 'b6 admitted')
ok, err = NPCBudget.Acquire('backup', 'b7', 'cidF')
expect(ok == false and err == 'global_limit', 'seventh slot must be global_limit')
snapshot = GetNpcBudget()
expect(snapshot.used == 6, 'global used is 6')
expect(snapshot.byPlayer.cidC == 2, 'callout costs two slots')

-- Duplicate ids and invalid inputs.
ok, err = NPCBudget.Acquire('backup', 'b2', 'cidZ')
expect(ok == false and err == 'duplicate', 'duplicate id')
ok, err = NPCBudget.Acquire('swat', 'x1', 'cidZ')
expect(ok == false and err == 'invalid_kind', 'invalid kind')
ok, err = NPCBudget.Acquire('backup', nil, 'cidZ')
expect(ok == false and err == 'invalid_id', 'invalid id')
ok, err = NPCBudget.Acquire('backup', 'x2', '')
expect(ok == false and err == 'invalid_citizenid', 'invalid citizenid')

-- Audit details: spawn target=id, detail=kind:slots.
local spawn = find_audit('npc.spawn', 'b1')
expect(spawn ~= nil, 'npc.spawn audited')
expect(spawn.params[1] == 'cidA', 'spawn owner')
expect(spawn.params[5] == 'backup:1', 'backup cost detail')   -- detail 在第 5 位
spawn = find_audit('npc.spawn', 'c1')
expect(spawn ~= nil and spawn.params[5] == 'callout:2', 'callout cost detail')

-- TTL: exactly 10 minutes is still alive, one second more is stale.
clock = clock + NPCBudget.TTL_SECONDS
expect(NPCBudget.Sweep() == 0, 'exactly at ttl is not stale')
clock = clock + 1
expect(NPCBudget.Sweep() == 5, 'five entries stale')
expect(#audit_rows('npc.stale') == 5, 'five stale audits')
snapshot = GetNpcBudget()
expect(snapshot.used == 0 and #snapshot.entries == 0, 'sweep empties the budget')
expect(next(snapshot.byPlayer) == nil, 'sweep clears per-player totals')

-- The exported read-only accessor and the global both return the same shape.
expect(type(exported.GetNpcBudget) == 'function', 'GetNpcBudget exported')
local exported_snapshot = exported.GetNpcBudget()
expect(exported_snapshot.used == 0 and exported_snapshot.max == 6, 'exported snapshot')
print('npc_budget harness ok')
"""


@pytest.mark.skipif(LUA_BIN is None, reason="lua5.4 is not installed")
def test_budget_behaviour_under_lua(tmp_path: Path) -> None:
    harness = tmp_path / "npc_budget_harness.lua"
    script = HARNESS.replace("__AUDIT__", json.dumps(str(POLICE / "server" / "audit.lua"))).replace(
        "__SHARED__", json.dumps(str(SHARED))).replace(
        "__SERVER__", json.dumps(str(SERVER))
    )
    harness.write_text(script, encoding="utf-8")
    result = subprocess.run(
        [LUA_BIN, str(harness)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "npc_budget harness ok" in result.stdout
