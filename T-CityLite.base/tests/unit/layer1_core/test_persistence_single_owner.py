"""P1-2 / P1-1 — 存档只能有一个写者，且刷盘永远不许回调 `Player.Functions.Save`。

两个病，一个文件里钉住：

* **P1-2（环）**：`core-framework` 的 `ForceFlush` 调 `Player.Functions.Save(true)`，
  而 `Save(true)` 又会 `DirtyFlush.ForceFlush(citizenid)`。两边一旦指向同一个脏池
  （同一个 Lua state、或有人把 `_G.DirtyFlush` 换掉）就是无限递归。这里把两份实现
  装进**同一个 Lua state** 复现最坏情况：改之前必须栈溢出，改之后必须恰好一次写。
* **P1-1（单写者 / 失败保留）**：脏池只有一份，刷盘失败时脏标记不能清、`failed_flushes`
  要涨、重试前不许再打 DB；停服刷盘要有可读的 ack（attempted / ok / failed）。

harness 不复制实现：qb-core 的 store、core-framework 的 delegate、以及
`QBCore.Player.Save` 的函数体都是从真实源码里读进来跑的。
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
QB_STORE = BASE / "resources" / "[qb]" / "qb-core" / "server" / "services" / "persistence_manager.lua"
CF_STORE = (
    BASE / "resources" / "[standalone]" / "core-framework" / "services" / "persistence_manager.lua"
)
PLAYER = BASE / "resources" / "[qb]" / "qb-core" / "server" / "player.lua"

HARNESS = r"""
-- ── 最小 FiveM 运行时：只够这两份文件 + Player.Save 跑起来 ──────────
__convars = { persistence_flush_interval = '900' }
function GetConvar(k, d) if __convars[k] == nil then return d end return tostring(__convars[k]) end
function GetConvarInt(k, d)
    local n = tonumber(__convars[k]); if n == nil then return d end; return math.floor(n)
end
function ConvarInt(k, d) return GetConvarInt(k, d) end
function ConvarFloat(k, d) local n = tonumber(__convars[k]); if n == nil then return d end; return n end
function GetCurrentResourceName() return 'qb-core' end
function GetGameTimer() return math.floor(os.clock() * 1000) end

function vector3(x, y, z)
    local v = { x = x or 0.0, y = y or 0.0, z = z or 0.0 }
    return setmetatable(v, {
        __sub = function(a, b) return vector3(a.x - b.x, a.y - b.y, a.z - b.z) end,
        __len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end,
    })
end

__ped = 1
function GetPlayerPed(_) return __ped end
function GetEntityCoords(_) return vector3(1.0, 2.0, 3.0) end
function GetEntityHealth(_) return 200 end
function GetResourceState(_) return 'missing' end

json = { encode = function(_) return '__json__' end }

-- ── fake MySQL：可切换失败，统计尝试次数与成功写入次数 ──────────────
__writes = 0
__attempts = 0
__fail = false
local insert_table = {}
__on_write = nil
insert_table.await = function(_query, _params)
    __attempts = __attempts + 1
    if __fail then error('fake db down') end
    __writes = __writes + 1
    if __on_write then local hook = __on_write; __on_write = nil; hook() end
    return 1, 1
end
MySQL = {
    insert = setmetatable(insert_table, {
        __call = function(_, _query, _params, cb)
            __attempts = __attempts + 1
            if __fail then return end
            __writes = __writes + 1
            if cb then cb(1, 1) end
        end,
    }),
}

-- ── exports：同 state 模拟（__exports 就是 'qb-core' 对外的导出表） ──
__exports = {}
exports = setmetatable({ __exports }, {
    __index = function(_, resource)
        if resource == 'qb-core' then return __exports end
        return setmetatable({}, { __index = function() return function() return true end end })
    end,
    __call = function(t, name, fn) t[1][name] = fn end,
})

-- ── Bus / thread / 事件：只记录，不真跑 ────────────────────────────
_handlers = {}
function AddEventHandler(name, fn) _handlers[name] = fn end
function RegisterNetEvent(_, fn) if type(fn) == 'function' then _handlers[_[1]] = fn end end
function TriggerEvent(_) end
function TriggerClientEvent(_) end
function CreateThread(_) end          -- 定时器不跑，测试直接调 FlushAll
function Wait(_) end
Citizen = { CreateThread = CreateThread, Wait = Wait }

_G.Bus = _G.Bus or {}
Bus = _G.Bus
Bus._services = {}
function Bus.RegisterService(name, methods)
    Bus._services[name] = methods
    Bus[name] = {}
    for k, v in pairs(methods) do Bus[name][k] = v end
end

-- ── qb-core 壳：玩家对象 + 统计 Player.Functions.Save 被调次数 ──────
__players = {}        -- citizenid -> Player（GetPlayerByCitizenId 的返回）
__by_source = {}      -- source -> Player（QBCore.Players，Save 按 source 取）
__save_calls = 0

function __makePlayer(cid, src)
    local p = {
        PlayerData = {
            citizenid = cid,
            source = src or 1,
            cid = 1,
            license = 'license:abc',
            name = 'Tester',
            money = { cash = 100, bank = 1000 },
            charinfo = { firstname = 'T', lastname = 'C' },
            job = { name = 'unemployed' },
            gang = { name = 'none' },
            metadata = { health = 200 },
            position = { x = 1.0, y = 2.0, z = 3.0 },
        },
        IsDirty = false,
        LastSavedCoords = vector3(1.0, 2.0, 3.0),
        Functions = {},
    }
    -- 如实镜像 qb-core 的 Save 语义：force 时先标脏再 ForceFlush
    p.Functions.Save = function(force)
        __save_calls = __save_calls + 1
        if not force then return end
        if DirtyFlush then
            DirtyFlush.MarkDirty(cid, 'all')
            DirtyFlush.ForceFlush(cid)
        end
    end
    __players[cid] = p
    __by_source[p.PlayerData.source] = p
    return p
end

__QBCore = {
    Players = __by_source,
    Player = {},
    Functions = {
        GetPlayerByCitizenId = function(cid) return __players[cid] end,
        GetPlayer = function(src)
            for _, p in pairs(__players) do if p.PlayerData.source == src then return p end end
            return nil
        end,
    },
    Shared = { Round = function(v) return math.floor(v + 0.5) end },
    ShowSuccess = function() end,
    ShowError = function() end,
}
QBCore = __QBCore
"""


def _extract_save_function() -> str:
    lines = PLAYER.read_text(encoding="utf-8").splitlines()

    # Save() 现在调用文件级私有 helper `saveInventoryDeferred` —— 一起抽出来，
    # 否则 harness 里会是 "attempt to call a nil value"（这个 helper 负责把背包写
    # 从跨资源函数引用换成传数据，见 player.lua 里的注释）。
    helper_start = None
    for index, line in enumerate(lines):
        if line.startswith("local function saveInventoryDeferred("):
            helper_start = index
            break
    helper = []
    if helper_start is not None:
        for end in range(helper_start + 1, len(lines)):
            if lines[end] == "end":
                helper = lines[helper_start : end + 1]
                break

    start = None
    for index, line in enumerate(lines):
        if line.startswith("function QBCore.Player.Save(source, force)"):
            start = index
            break
    assert start is not None, "player.lua 里找不到 QBCore.Player.Save —— 先更新这个 harness"
    for end in range(start + 1, len(lines)):
        if lines[end] == "end":
            return "\n".join(helper + lines[start : end + 1])
    raise AssertionError("QBCore.Player.Save 没有闭合的 end")


def run(probe: str, fail: bool = False, with_save: bool = False, store_source: str | None = None) -> dict:
    qb_source = (store_source or QB_STORE.read_text(encoding="utf-8")).replace(
        "exports['qb-core']:GetCoreObject()", "__QBCore"
    )
    cf_source = CF_STORE.read_text(encoding="utf-8").replace(
        "exports['qb-core']:GetCoreObject()", "__QBCore"
    )

    parts = [HARNESS, qb_source, cf_source]
    if with_save:
        parts.append(_extract_save_function())
    parts.append("__fail = " + ("true" if fail else "false"))
    parts.append(probe)

    script = "\n".join(parts)
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as handle:
        handle.write(script)
        path = handle.name
    try:
        result = subprocess.run(["lua5.4", path], capture_output=True, text=True, timeout=30)
    finally:
        Path(path).unlink(missing_ok=True)

    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line and not line.startswith("["):
            key, _, raw = line.partition("=")
            values[key.strip()] = raw.strip()
    return {
        "ok": result.returncode == 0,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "values": values,
    }


def _num(result: dict, key: str) -> float:
    assert result["ok"], f"Lua 执行失败：\n{result['stderr']}\n{result['stdout']}"
    assert key in result["values"], f"探针没有输出 {key}: {result['values']}"
    return float(result["values"][key])


# ── P1-2：环 ────────────────────────────────────────────────────────


def test_flush_never_calls_player_save_and_writes_exactly_once():
    """刷盘 → Save(true) → ForceFlush 的环必须消失：一次写，且不经过 Player.Functions.Save。"""
    probe = r"""
__players['CID_A'] = __makePlayer('CID_A')
DirtyFlush.MarkDirty('CID_A', 'all')
local ack = PersistenceManager.FlushAll('test')
print('WRITES=' .. __writes)
print('ATTEMPTS=' .. __attempts)
print('SAVE_CALLS=' .. __save_calls)
print('DIRTY_AFTER=' .. tostring(PersistenceManager.Stats().dirty_pool_size))
print('ACK_ATTEMPTED=' .. tostring(ack and (ack.attempted or ack.total) or 'nil'))
print('ACK_OK=' .. tostring(ack and (ack.ok or ack.succeeded) or 'nil'))
"""
    result = run(probe)
    assert result["ok"], f"刷盘直接炸了（栈溢出就是这条环）:\n{result['stderr']}\n{result['stdout']}"
    assert _num(result, "WRITES") == 1, f"一次刷盘只能写一次库:\n{result['stdout']}"
    assert _num(result, "SAVE_CALLS") == 0, (
        "刷盘又走了 Player.Functions.Save —— 环只是换了入口: " + result["stdout"]
    )
    assert _num(result, "DIRTY_AFTER") == 0, f"写成功后脏标记必须清:\n{result['stdout']}"


def test_force_save_on_player_is_a_single_write_not_a_reflush():
    """`QBCore.Player.Save(src, true)` 自身也只写一次，不许再触发一次 ForceFlush。"""
    probe = r"""
__players['CID_D'] = __makePlayer('CID_D')
QBCore.Player.Save(1, true)
print('WRITES=' .. __writes)
print('ATTEMPTS=' .. __attempts)
print('SAVE_CALLS=' .. __save_calls)
print('IS_DIRTY=' .. tostring(__players['CID_D'].IsDirty))
"""
    result = run(probe, with_save=True)
    assert result["ok"], f"Player.Save 执行失败:\n{result['stderr']}\n{result['stdout']}"
    assert _num(result, "WRITES") == 1, f"强制存档只该落一次库:\n{result['stdout']}"
    assert _num(result, "SAVE_CALLS") == 0, "Player.Save 不该回调自己: " + result["stdout"]
    assert result["values"].get("IS_DIRTY") == "false", (
        "写成功后 IsDirty 必须为 false: " + result["stdout"]
    )


def test_force_save_failure_keeps_the_player_dirty():
    """写库失败时 IsDirty 不许被清掉——现在的代码无条件清，钱就是这么丢的。"""
    probe = r"""
__players['CID_E'] = __makePlayer('CID_E')
QBCore.Player.Save(1, true)
print('ATTEMPTS=' .. __attempts)
print('WRITES=' .. __writes)
print('IS_DIRTY=' .. tostring(__players['CID_E'].IsDirty))
"""
    result = run(probe, fail=True, with_save=True)
    assert result["ok"], f"Player.Save 执行失败:\n{result['stderr']}\n{result['stdout']}"
    assert _num(result, "WRITES") == 0, f"失败时不该算成写入成功:\n{result['stdout']}"
    assert result["values"].get("IS_DIRTY") == "true", (
        "写库失败还把 IsDirty 清掉 = 静默丢钱: " + result["stdout"]
    )


# ── P1-1：单写者 / 失败保留 / ack ─────────────────────────────────


def test_one_dirty_pool_shared_by_both_entrypoints():
    """从 delegate 标脏，owner 的池子必须看得见；反过来也一样——池子只有一份。"""
    probe = r"""
__makePlayer('CID_B')
__makePlayer('CID_C')
DirtyFlush.MarkDirty('CID_B', 'money')
print('OWNER_POOL=' .. tostring(Store.Stats().dirty_pool_size))
print('DELEGATE_POOL=' .. tostring(PersistenceManager.Stats().dirty_pool_size))
print('OWNER_HAS_ENTRY=' .. tostring(Store._dirty['CID_B'] ~= nil))
Store.MarkDirty('CID_C', 'job')
print('OWNER_POOL_AFTER=' .. tostring(Store.Stats().dirty_pool_size))
print('DELEGATE_POOL_AFTER=' .. tostring(PersistenceManager.Stats().dirty_pool_size))
"""
    result = run(probe)
    assert result["ok"], f"Lua 执行失败：\n{result['stderr']}\n{result['stdout']}"
    assert _num(result, "OWNER_POOL") == 1, f"delegate 标脏没进 owner 的池子:\n{result['stdout']}"
    assert _num(result, "OWNER_POOL_AFTER") == 2, f"owner 标脏没进同一个池子:\n{result['stdout']}"
    assert _num(result, "DELEGATE_POOL") == _num(result, "OWNER_POOL"), (
        "两个入口看到的池子大小不一致 = 两套池: " + result["stdout"]
    )
    assert _num(result, "DELEGATE_POOL_AFTER") == _num(result, "OWNER_POOL_AFTER"), (
        "两个入口看到的池子大小不一致 = 两套池: " + result["stdout"]
    )


def test_failed_flush_keeps_dirty_and_counts_it_then_retries():
    """失败：脏标记保留 + failed_flushes 涨 + 退避期内不重打；恢复后一次写清空。"""
    probe = r"""
__players['CID_F'] = __makePlayer('CID_F')
DirtyFlush.MarkDirty('CID_F', 'all')
__fail = true
local first = PersistenceManager.FlushAll('fail_once')
local after_fail = PersistenceManager.Stats()
print('FAILED_FLUSHES=' .. tostring(after_fail.failed_flushes))
print('DIRTY_AFTER_FAIL=' .. tostring(after_fail.dirty_pool_size))
print('ATTEMPTS_AFTER_FAIL=' .. __attempts)
-- 退避期内再刷一次：不应重打 DB
PersistenceManager.FlushAll('too_soon')
print('ATTEMPTS_AFTER_SOON=' .. __attempts)
print('DIRTY_AFTER_SOON=' .. tostring(PersistenceManager.Stats().dirty_pool_size))
-- 强制重试（不受退避限制）：成功
__fail = false
PersistenceManager.ForceFlushPlayer('CID_F')
print('WRITES_AFTER_RECOVER=' .. __writes)
print('DIRTY_AFTER_RECOVER=' .. tostring(PersistenceManager.Stats().dirty_pool_size))
"""
    result = run(probe)
    assert result["ok"], f"Lua 执行失败：\n{result['stderr']}\n{result['stdout']}"
    assert _num(result, "FAILED_FLUSHES") >= 1, f"失败没有计数:\n{result['stdout']}"
    assert _num(result, "DIRTY_AFTER_FAIL") == 1, (
        "写库失败却清了脏标记 = 下次再也不写: " + result["stdout"]
    )
    assert _num(result, "ATTEMPTS_AFTER_FAIL") == 1, f"一次刷盘只该尝试一次:\n{result['stdout']}"
    assert _num(result, "ATTEMPTS_AFTER_SOON") == 1, (
        "退避期内又打了一次 DB（失败会变成风暴）: " + result["stdout"]
    )
    assert _num(result, "WRITES_AFTER_RECOVER") == 1, f"恢复后应写入一次:\n{result['stdout']}"
    assert _num(result, "DIRTY_AFTER_RECOVER") == 0, f"成功后脏标记要清:\n{result['stdout']}"


def test_write_that_loses_a_concurrent_dirty_mark_is_retried():
    """写库 await 期间玩家又被标脏：这次写进库的不是最新状态，条目不许被清掉。

    （`await` 会让出协程，别的线程完全可以在这一瞬间改钱 —— 清掉条目等于把新改动吞了。）
    """
    probe = r"""
local p = __makePlayer('CID_R')
DirtyFlush.MarkDirty('CID_R', 'money')
__on_write = function() DirtyFlush.MarkDirty('CID_R', 'money') end
Store.FlushAll('race')
print('WRITES=' .. __writes)
print('DIRTY_AFTER=' .. tostring(Store.Stats().dirty_pool_size))
print('IS_DIRTY=' .. tostring(p.IsDirty))
Store.FlushAll('race_retry')
print('WRITES2=' .. __writes)
print('DIRTY_FINAL=' .. tostring(Store.Stats().dirty_pool_size))
"""
    result = run(probe)
    assert result["ok"], "Lua 执行失败: " + result["stderr"] + result["stdout"]
    assert _num(result, "WRITES") == 1, result["stdout"]
    assert _num(result, "DIRTY_AFTER") == 1, (
        "写库期间新标上的脏标记被吞掉了 —— 这笔改动永远不会落库: " + result["stdout"]
    )
    assert result["values"].get("IS_DIRTY") == "true", result["stdout"]
    assert _num(result, "WRITES2") == 2, "下一轮必须把最新状态写掉: " + result["stdout"]
    assert _num(result, "DIRTY_FINAL") == 0, result["stdout"]


def test_flush_all_reports_an_ack_with_counts_and_duration():
    """停服刷盘要能回答\"刷了几个、成几个、花多久\"，不是一个静默副作用。"""
    probe = r"""
__players['CID_G'] = __makePlayer('CID_G')
Store.MarkDirty('CID_G', 'all')
local ack = Store.FlushAll('resource_stop')
print('ACK_ATTEMPTED=' .. tostring(ack.attempted))
print('ACK_OK=' .. tostring(ack.ok))
print('ACK_FAILED=' .. tostring(ack.failed))
print('ACK_HAS_DURATION=' .. tostring(ack.duration_ms ~= nil))
print('ACK_REASON=' .. tostring(ack.reason))
"""
    result = run(probe)
    assert result["ok"], f"Lua 执行失败：\n{result['stderr']}\n{result['stdout']}"
    assert _num(result, "ACK_ATTEMPTED") == 1, result["stdout"]
    assert _num(result, "ACK_OK") == 1, result["stdout"]
    assert _num(result, "ACK_FAILED") == 0, result["stdout"]
    assert result["values"].get("ACK_HAS_DURATION") == "true", result["stdout"]
    assert result["values"].get("ACK_REASON") == "resource_stop", (
        "ack 要写明是什么原因刷的盘: " + result["stdout"]
    )


def test_players_who_only_set_isdirty_are_still_flushed():
    """`IsDirty = true` 但没进池子的玩家（economy/metadata 服务的形状）也要被刷到，
    否则他们的钱只在下线那一刻才落库。"""
    probe = r"""
local p = __makePlayer('CID_H')
p.IsDirty = true          -- 只标 IsDirty，不 MarkDirty
local ack = Store.FlushAll('isdirty_scan')
print('ACK_ATTEMPTED=' .. tostring(ack.attempted))
print('WRITES=' .. __writes)
print('DIRTY_AFTER=' .. tostring(Store.Stats().dirty_pool_size))
print('IS_DIRTY_AFTER=' .. tostring(p.IsDirty))
"""
    result = run(probe)
    assert result["ok"], f"Lua 执行失败：\n{result['stderr']}\n{result['stdout']}"
    assert _num(result, "ACK_ATTEMPTED") == 1, (
        "只标 IsDirty 的玩家被漏掉了 —— 钱/职业会静默丢失: " + result["stdout"]
    )
    assert _num(result, "WRITES") == 1, result["stdout"]
    assert _num(result, "DIRTY_AFTER") == 0, result["stdout"]
    assert result["values"].get("IS_DIRTY_AFTER") == "false", result["stdout"]


def test_non_player_keys_do_not_pollute_the_dirty_pool():
    """`world_state` 这类 `region:key` 不是玩家：收进 players 脏池只会变成永远写不掉的僵尸条目。"""
    probe = r"""
print('MARK_OK=' .. tostring(Store.MarkDirty('region_a:lockdown', 'world_state')))
print('POOL_AFTER_MARK=' .. tostring(Store.Stats().dirty_pool_size))
local ok = Store.SaveNow('region_b:lockdown', 'probe')
print('SAVE_OK=' .. tostring(ok))
print('POOL_AFTER_SAVE=' .. tostring(Store.Stats().dirty_pool_size))
Store.FlushAll('probe')
print('ACK_ATTEMPTED=' .. tostring(Store.FlushAll('probe2').attempted))
"""
    result = run(probe)
    assert result["ok"], "Lua 执行失败: " + result["stderr"] + result["stdout"]
    assert result["values"].get("MARK_OK") == "false", (
        "非玩家 key 被收进了 players 脏池 —— 它会永远退避重试: " + result["stdout"]
    )
    assert _num(result, "POOL_AFTER_MARK") == 0, result["stdout"]
    assert _num(result, "POOL_AFTER_SAVE") == 0, result["stdout"]
    assert _num(result, "ACK_ATTEMPTED") == 0, result["stdout"]


def test_heartbeat_save_does_not_remark_a_pooled_player():
    """非强制存档把债务交给池子后必须清 IsDirty —— 否则每次心跳都重跑一次 SaveInventory。"""
    probe = r"""
local p = __makePlayer('CID_HB')
p.IsDirty = true
QBCore.Player.Save(1, false)
print('POOL=' .. tostring(Store.Stats().dirty_pool_size))
print('IS_DIRTY=' .. tostring(p.IsDirty))
QBCore.Player.Save(1, false)
QBCore.Player.Save(1, false)
local entry = Store._dirty['CID_HB']
print('REV=' .. tostring(entry and entry.rev))
print('WRITES=' .. __writes)
"""
    result = run(probe, with_save=True)
    assert result["ok"], "Lua 执行失败: " + result["stderr"] + result["stdout"]
    assert _num(result, "POOL") == 1, "非强制存档必须把玩家留在池子里: " + result["stdout"]
    assert result["values"].get("IS_DIRTY") == "false", (
        "池子已经持有债务，IsDirty 还亮着会让心跳重复写 inventory: " + result["stdout"]
    )
    assert _num(result, "REV") == 1, (
        "后续心跳又给同一个玩家加了脏版本 —— 会被当成新改动反复重写: " + result["stdout"]
    )
    assert _num(result, "WRITES") == 0, "非强制存档不该直接写库: " + result["stdout"]


def test_mutation_that_clears_dirty_on_failure_is_caught():
    """变异测试：把"成功才清脏"的守卫打穿，既有断言必须变红。"""
    original = QB_STORE.read_text(encoding="utf-8")
    nl = chr(10)
    old_guard = "    if ok then" + nl + "        local clean = noteSuccess"
    new_guard = "    if true then" + nl + "        local clean = noteSuccess"
    mutated = original.replace(old_guard, new_guard)
    assert mutated != original, "变异没有生效 —— 守卫那行被改写过，先更新这个测试"

    probe = r"""
__players['CID_E'] = __makePlayer('CID_E')
QBCore.Player.Save(1, true)
print('IS_DIRTY=' .. tostring(__players['CID_E'].IsDirty))
"""
    result = run(probe, fail=True, with_save=True, store_source=mutated)
    assert result["ok"], "Lua 执行失败: " + result["stderr"] + result["stdout"]
    assert result["values"].get("IS_DIRTY") == "false", (
        "变异后行为没变 —— 说明这条断言咬不住失败路径: " + result["stdout"]
    )


def test_delegate_has_no_pool_no_sql_and_no_timer():
    """结构断言：delegate 不许再有自己的脏池、SQL、定时器或 Save 调用。"""
    source = CF_STORE.read_text(encoding="utf-8")
    assert "INSERT INTO players" not in source, "delegate 又在写库了——写者只能有一个"
    assert "Player.Functions.Save" not in source, "delegate 又被接回 Save(true)，环会回来"
    assert "_dirty = {}" not in source, "delegate 又开了一份脏池"
    assert "CreateThread" not in source, "delegate 又起了自己的定时器"
    assert "StoreSaveNow" in source or "StoreFlushAll" in source, (
        "delegate 没有接到 owner 的 export 上"
    )
