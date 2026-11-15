"""core-framework 的 persistence 只是 delegate —— 转发契约。

2026-11-01（P1-1/P1-2）之前，这个文件测的是“delegate 自己持有一个脏池，刷盘时
调用 `Player.Functions.Save(true)`”。那正是环本身：`Save(true)` 会回头调
`DirtyFlush.ForceFlush`。旧断言等于把 bug 写进了验收标准，所以整份改写成
**转发契约**：所有状态在 qb-core 的 Store 里，这里只验它把调用送对地方、
并且自己没有池子/定时器/写库语句。

行为级证据（真实 Store + 真实 Player.Save + fake DB 失败）在
`tests/unit/layer1_core/test_persistence_single_owner.py`。
"""

from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
CF_STORE = (
    BASE / "resources" / "[standalone]" / "core-framework" / "services" / "persistence_manager.lua"
)

MOCK = r"""
-- ── fake owner：qb-core 的 Store 通过 exports['qb-core'] 暴露 ──────────
__calls = {}
__ack = { reason = 'owner_ack', attempted = 2, ok = 1, failed = 1, duration_ms = 7 }
__owner_available = true

local function record(name)
    return function(...)
        __calls[#__calls + 1] = { name = name, args = { ... } }
        if name == 'StoreFlushAll' then return __ack end
        if name == 'StoreStats' then
            return { dirty_pool_size = 3, failed_flushes = 1, flush_count = 5,
                     force_count = 2, last_flush_time = 1, last_flush_duration = 9,
                     total_players_flushed = 4 }
        end
        return true
    end
end

local ownerExports = {
    StoreMarkDirty = record('StoreMarkDirty'),
    StoreSaveNow = record('StoreSaveNow'),
    StoreForceFlush = record('StoreForceFlush'),
    StoreFlushAll = record('StoreFlushAll'),
    StoreStats = record('StoreStats'),
}

exports = setmetatable({}, {
    __index = function(_, resource)
        if resource == 'qb-core' and __owner_available then return ownerExports end
        return nil
    end,
    __call = function() end,
})

__threads = 0
function CreateThread(_) __threads = __threads + 1 end
function Wait(_) end
AddEventHandler = function() end
GetCurrentResourceName = function() return 'core-framework' end

_G.Bus = _G.Bus or {}
Bus = _G.Bus
Bus._services = {}
function Bus.RegisterService(name, methods)
    Bus._services[name] = methods
    Bus[name] = {}
    for k, v in pairs(methods) do Bus[name][k] = v end
end
function Bus.GetService(name) return Bus._services[name] end
"""


def run(probe: str) -> dict:
    source = CF_STORE.read_text(encoding="utf-8")
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as handle:
        handle.write(MOCK + "\n" + source + "\n" + probe)
        path = handle.name
    try:
        result = subprocess.run(["lua5.4", path], capture_output=True, text=True, timeout=15)
    finally:
        Path(path).unlink(missing_ok=True)

    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, _, raw = line.partition("=")
            values[key.strip()] = raw.strip()
    return {"ok": result.returncode == 0, "stdout": result.stdout, "stderr": result.stderr,
            "values": values}


def _num(result: dict, key: str) -> float:
    assert result["ok"], f"Lua 执行失败：\n{result['stderr']}\n{result['stdout']}"
    assert key in result["values"], f"探针没有输出 {key}: {result['values']}"
    return float(result["values"][key])


def test_delegate_holds_no_state_and_starts_no_thread():
    result = run("""
print('DIRTY_POOL=' .. tostring(_G.DirtyFlush._dirty))
print('THREADS=' .. __threads)
""")
    assert result["values"].get("DIRTY_POOL") == "nil", (
        "delegate 又开了一份脏池 —— 两个池就是两套真相: " + result["stdout"]
    )
    assert _num(result, "THREADS") == 0, (
        "delegate 又起了自己的定时器 —— 900s 会刷两次: " + result["stdout"]
    )


def test_mark_dirty_and_force_flush_forward_to_owner():
    result = run("""
PersistenceManager.MarkDirty('CID1', 'money')
PersistenceManager.ForceFlushPlayer('CID1')
print('CALLS=' .. #__calls)
print('CALL1=' .. tostring(__calls[1] and __calls[1].name))
print('CALL1_ARG=' .. tostring(__calls[1] and __calls[1].args[1]))
print('CALL1_TYPE=' .. tostring(__calls[1] and __calls[1].args[2]))
print('CALL2=' .. tostring(__calls[2] and __calls[2].name))
print('CALL2_REASON=' .. tostring(__calls[2] and __calls[2].args[2]))
""")
    assert _num(result, "CALLS") == 2, result["stdout"]
    assert result["values"].get("CALL1") == "StoreMarkDirty", result["stdout"]
    assert result["values"].get("CALL1_ARG") == "CID1", result["stdout"]
    assert result["values"].get("CALL1_TYPE") == "money", result["stdout"]
    assert result["values"].get("CALL2") == "StoreSaveNow", (
        "ForceFlushPlayer 必须走 SaveNow，不是走 Save(true): " + result["stdout"]
    )
    assert result["values"].get("CALL2_REASON") == "force_player", result["stdout"]


def test_flush_all_returns_the_owner_ack_verbatim():
    result = run("""
local ack = PersistenceManager.FlushAll('resource_stop', true)
print('ACK_REASON=' .. tostring(ack.reason))
print('ACK_ATTEMPTED=' .. tostring(ack.attempted))
print('ACK_OK=' .. tostring(ack.ok))
print('ACK_FAILED=' .. tostring(ack.failed))
print('OWNER_ARG=' .. tostring(__calls[1] and __calls[1].name))
print('IGNORE_ARG=' .. tostring(__calls[1] and __calls[1].args[2]))
""")
    assert result["values"].get("ACK_REASON") == "owner_ack", (
        "ack 必须是 owner 的原始结果，不能在这里重新编一个: " + result["stdout"]
    )
    assert _num(result, "ACK_ATTEMPTED") == 2 and _num(result, "ACK_FAILED") == 1, result["stdout"]
    assert result["values"].get("OWNER_ARG") == "StoreFlushAll", result["stdout"]
    assert result["values"].get("IGNORE_ARG") == "true", (
        "停服刷盘必须把 ignoreBackoff 透传下去: " + result["stdout"]
    )


def test_stats_are_tagged_with_the_owner_resource():
    result = run("""
local s = PersistenceManager.Stats()
print('OWNER=' .. tostring(s.owner))
print('POOL=' .. tostring(s.dirty_pool_size))
print('FAILED=' .. tostring(s.failed_flushes))
""")
    assert result["values"].get("OWNER") == "qb-core", result["stdout"]
    assert _num(result, "POOL") == 3 and _num(result, "FAILED") == 1, result["stdout"]


def test_missing_owner_degrades_instead_of_crashing():
    result = run("""
__owner_available = false
local ack = PersistenceManager.FlushAll('tick')
local s = PersistenceManager.Stats()
print('ACK_OWNER=' .. tostring(ack.owner))
print('ACK_ATTEMPTED=' .. tostring(ack.attempted))
print('STATS_OWNER=' .. tostring(s.owner))
print('STATS_POOL=' .. tostring(s.dirty_pool_size))
""")
    assert result["ok"], f"owner 缺失时不许抛错:\n{result['stderr']}"
    assert result["values"].get("ACK_OWNER") == "unavailable", result["stdout"]
    assert result["values"].get("STATS_OWNER") == "unavailable", result["stdout"]


def test_bus_service_keeps_the_same_method_names():
    result = run("""
local keys = {}
for name in pairs(Bus.GetService('persistence') or {}) do keys[#keys + 1] = name end
table.sort(keys)
print('METHODS=' .. table.concat(keys, ','))
print('HAS_SAVE_NOW=' .. tostring(Bus.persistence ~= nil and Bus.persistence.SaveNow ~= nil))
""")
    methods = set((result["values"].get("METHODS") or "").split(","))
    required = {"MarkDirty", "SaveNow", "ForceFlush", "ForceFlushPlayer", "FlushAll", "Stats",
                "StartFlushTick", "StartHealthReport"}
    assert required <= methods, f"Bus 方法表少了 {required - methods}: {result['stdout']}"
    assert result["values"].get("HAS_SAVE_NOW") == "true", result["stdout"]


def test_no_sql_and_no_save_call_in_source():
    source = CF_STORE.read_text(encoding="utf-8")
    assert not re.search(r"\bINSERT\s+INTO\b", source, re.IGNORECASE), (
        "delegate 里出现了写库语句 —— 写者只能有一个"
    )
    assert "Player.Functions.Save" not in source, "delegate 又接回 Save(true) 了"
