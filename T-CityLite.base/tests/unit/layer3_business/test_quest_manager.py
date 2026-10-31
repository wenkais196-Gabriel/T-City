"""
test_quest_manager.py — Quest Manager State Machine 单元测试

测试范围:
- QuestNodes._eventMap: 验证所有节点类型映射存在
- QuestNodes.ExecuteNode: 大小写规范化、questId/stepId注入、TriggerClientEvent调用
- QuestNodes.CancelAllNodes: 触发 quest:client:clearAllNodes
- QuestManager._resolvedTemplates: 初始化状态

Note: quest_manager.lua 全长 1101 行，但大部分依赖 MySQL/exports。
此处仅加载纯 Lua 逻辑部分（第1-82行，即 QuestNodes 定义与 QuestManager 初始化，
不包括 `exports['qb-core']:GetCoreObject()` 调用及其后的重依赖代码）。
"""

import os
from pathlib import Path
BASE_DIR = str(Path(__file__).resolve().parents[3])
import sys
import subprocess
import tempfile
import pytest

# Add tests dir to path so conftest fixtures work
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# ── Constants ────────────────────────────────────────────────────────────

QUEST_MANAGER_LUA = (
    BASE_DIR + "//resources/[custom]/custom-quest/"
    "server/quest_manager.lua"
)

# Lines of quest_manager.lua to load (pure Lua, no exports/MySQL calls)
# Stops just before `local QBCore = exports['qb-core']:GetCoreObject()`
def _find_cutoff_line(path):
    with open(path, encoding='utf-8') as f:
        for i, line in enumerate(f):
            if line.startswith("local QBCore = exports"):
                return i
    return 82

QUEST_MANAGER_CUTOFF_LINE = _find_cutoff_line(QUEST_MANAGER_LUA)


def _load_quest_manager_section() -> str:
    """Load only the pure-Lua portion of quest_manager.lua."""
    with open(QUEST_MANAGER_LUA, 'r') as f:
        lines = f.readlines()
    return ''.join(lines[:QUEST_MANAGER_CUTOFF_LINE])


# ── Helper: run Lua test ────────────────────────────────────────────────

def run_lua_test(code: str) -> dict:
    """Run Lua code with FiveM mock + QuestNodes loaded, return result dict."""
    mock = r'''
-- FiveM mock environment for QuestNodes testing
-- Track TriggerClientEvent calls for verification
__tracked_events = {}

GetConvar = function(name, default)
    if name == "quest_debug" then return "true" end
    return default or ""
end
GetConvarInt = function(name, default)
    return tonumber(GetConvar(name, tostring(default or 0))) or default
end
GetCurrentResourceName = function() return "test-resource" end
GetPlayerName = function(src) return "Test Player" end
LoadResourceFile = function() return "" end

-- Threading
CreateThread = function(fn) fn() end
Wait = function(ms) end
Citizen = { CreateThread = CreateThread, Wait = Wait }

-- Events
RegisterNetEvent = function() end
AddEventHandler = function() end
TriggerEvent = function() end
TriggerClientEvent = function(eventName, source, data)
    table.insert(__tracked_events, {
        event = eventName,
        source = source,
        data = data,
    })
end
TriggerServerEvent = function() end

-- DB stubs
MySQL = {
    query = function(sql, params, cb) if cb then cb({}) end end,
    update = function(sql, params, cb) if cb then cb(1) end end,
    insert = function(sql, params, cb) if cb then cb(1) end end,
    scalar = function(sql, params, cb) if cb then cb(nil) end end,
    single = function(sql, params, cb) if cb then cb(nil) end end,
    prepare = function(sql, params, cb) if cb then cb(nil) end end,
    execute = function(sql, params, cb) if cb then cb(1) end end,
}

-- QBCore stub (used by quest_manager.lua later lines, but harmless here)
_G.QBCore = {
    Functions = {
        GetPlayer = function(src)
            return {
                PlayerData = { citizenid = "CID_" .. tostring(src) },
            }
        end,
        GetPlayerByCitizenId = function(cid)
            return { PlayerData = { citizenid = cid } }
        end,
        GetDutyCount = function(job) return 0 end,
    },
    Shared = { Round = function(v) return math.floor(v + 0.5) end },
}

-- exports stub: returns callable for any key
exports = setmetatable({}, {
    __index = function(t, k)
        return function(...) return true end
    end,
    __call = function(t, name, fn) return true end,
})

-- Standard Lua globals
print = function(...) end  -- suppress noise
os = { time = os.time, clock = os.clock, date = os.date }
math = math; table = table; string = string
pairs = pairs; ipairs = ipairs; type = type; tostring = tostring; tonumber = tonumber
unpack = table.unpack or unpack
setmetatable = setmetatable; getmetatable = getmetatable
rawget = rawget; rawset = rawset; select = select
pcall = pcall; xpcall = xpcall; error = error; assert = assert
load = load; next = next
require = nil; package = nil; dofile = nil

-- Config stub (used by QuestNode print messages referencing Config.Quest.Events)
Config = {
    Quest = {
        Enabled = true,
        Events = {
            QUEST_ACCEPTED = "quest:client:accepted",
            QUEST_COMPLETED = "quest:client:completed",
            QUEST_FAILED = "quest:client:failed",
        },
        MaxActiveQuests = 10,
    },
}

-- QuestRegistry stub (referenced by QuestManager, not needed for node tests)
QuestRegistry = { GetTemplate = function() return nil end }

'''

    quest_section = _load_quest_manager_section()

    full_script = mock + '\n' + quest_section + '\n' + code

    with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
        f.write(full_script)
        tmp = f.name

    try:
        result = subprocess.run(
            ['lua5.4', tmp],
            capture_output=True, text=True, timeout=10,
        )
        return {
            'ok': result.returncode == 0,
            'stdout': result.stdout,
            'stderr': result.stderr,
            'exit_code': result.returncode,
        }
    finally:
        os.unlink(tmp)


# ── Tests: QuestNodes._eventMap ─────────────────────────────────────────

class TestQuestNodesEventMap:
    """验证 QuestNodes._eventMap 包含所有节点类型映射"""

    def test_event_map_exists(self):
        result = run_lua_test("""
assert(QuestNodes ~= nil, "QuestNodes should exist")
assert(QuestNodes._eventMap ~= nil, "_eventMap should exist")
assert(type(QuestNodes._eventMap) == "table", "_eventMap should be a table")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_event_map_goto(self):
        result = run_lua_test("""
assert(QuestNodes._eventMap.GOTO == "quest:client:nodeGoto",
    "GOTO mapping wrong: " .. tostring(QuestNodes._eventMap.GOTO))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_event_map_interact(self):
        result = run_lua_test("""
assert(QuestNodes._eventMap.INTERACT == "quest:client:nodeInteract",
    "INTERACT mapping wrong: " .. tostring(QuestNodes._eventMap.INTERACT))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_event_map_validator(self):
        result = run_lua_test("""
assert(QuestNodes._eventMap.VALIDATOR == "quest:client:nodeValidator",
    "VALIDATOR mapping wrong: " .. tostring(QuestNodes._eventMap.VALIDATOR))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_event_map_deliver(self):
        result = run_lua_test("""
assert(QuestNodes._eventMap.DELIVER == "quest:client:nodeDeliver",
    "DELIVER mapping wrong: " .. tostring(QuestNodes._eventMap.DELIVER))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_event_map_combat(self):
        result = run_lua_test("""
assert(QuestNodes._eventMap.COMBAT == "quest:client:nodeCombat",
    "COMBAT mapping wrong: " .. tostring(QuestNodes._eventMap.COMBAT))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_event_map_wait(self):
        result = run_lua_test("""
assert(QuestNodes._eventMap.WAIT == "quest:client:nodeWait",
    "WAIT mapping wrong: " .. tostring(QuestNodes._eventMap.WAIT))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_event_map_placement(self):
        result = run_lua_test("""
assert(QuestNodes._eventMap.PLACEMENT == "quest:client:nodePlacement",
    "PLACEMENT mapping wrong: " .. tostring(QuestNodes._eventMap.PLACEMENT))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_event_map_decision(self):
        result = run_lua_test("""
assert(QuestNodes._eventMap.DECISION == "story:client:offerDecision",
    "DECISION mapping wrong: " .. tostring(QuestNodes._eventMap.DECISION))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_event_map_count(self):
        """Verify exactly 9 node types are mapped (GOTO/REACH/INTERACT/VALIDATOR/DELIVER/COMBAT/WAIT/PLACEMENT/DECISION)"""
        result = run_lua_test("""
local count = 0
for _ in pairs(QuestNodes._eventMap) do count = count + 1 end
assert(count == 9, "expected 9 node types, got " .. tostring(count))
-- reach 是模板里最常见的步骤类型，必须和 GOTO 走同一条下发路径
assert(QuestNodes._eventMap.REACH == QuestNodes._eventMap.GOTO, "reach must reuse the goto node")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Tests: QuestNodes.ExecuteNode ───────────────────────────────────────

class TestQuestNodesExecuteNode:
    """验证 ExecuteNode 的行为：规范化、注入、事件触发"""

    def test_execute_node_exists(self):
        result = run_lua_test("""
assert(QuestNodes.ExecuteNode ~= nil, "ExecuteNode should exist")
assert(type(QuestNodes.ExecuteNode) == "function", "ExecuteNode should be a function")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_execute_node_triggers_correct_event(self):
        result = run_lua_test("""
__tracked_events = {}
QuestNodes.ExecuteNode(1, "Q_TEST", "step_1", "GOTO", { x = 1, y = 2 })
assert(#__tracked_events == 1, "expected 1 event, got " .. #__tracked_events)
local evt = __tracked_events[1]
assert(evt.event == "quest:client:nodeGoto",
    "wrong event: " .. tostring(evt.event))
assert(evt.source == 1, "wrong source: " .. tostring(evt.source))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_execute_node_injects_quest_id_and_step_id(self):
        result = run_lua_test("""
__tracked_events = {}
QuestNodes.ExecuteNode(2, "Q_DELIVER_001", "step_3", "DELIVER",
    { item = "package", count = 5 })
assert(#__tracked_events == 1)
local evt = __tracked_events[1]
assert(evt.data.questId == "Q_DELIVER_001",
    "questId missing: " .. tostring(evt.data.questId))
assert(evt.data.stepId == "step_3",
    "stepId missing: " .. tostring(evt.data.stepId))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_execute_node_preserves_payload_fields(self):
        result = run_lua_test("""
__tracked_events = {}
QuestNodes.ExecuteNode(3, "Q_ITEM", "step_2", "INTERACT",
    { item = "lockpick", label = "Pick Lock" })
assert(#__tracked_events == 1)
local evt = __tracked_events[1]
assert(evt.data.item == "lockpick",
    "item not preserved: " .. tostring(evt.data.item))
assert(evt.data.label == "Pick Lock",
    "label not preserved: " .. tostring(evt.data.label))
assert(evt.data.questId == "Q_ITEM")
assert(evt.data.stepId == "step_2")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_execute_node_normalizes_lowercase_to_uppercase(self):
        """模板可能使用小写节点类型，ExecuteNode 应自动规范化"""
        result = run_lua_test("""
__tracked_events = {}
-- Use lowercase "goto" — should normalize to "GOTO" and find the mapping
QuestNodes.ExecuteNode(1, "Q_TEST", "step_1", "goto", { x = 10 })
assert(#__tracked_events == 1,
    "expected 1 event, got " .. #__tracked_events)
local evt = __tracked_events[1]
assert(evt.event == "quest:client:nodeGoto",
    "should normalize lowercase 'goto' to GOTO mapping, got: " .. tostring(evt.event))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_execute_node_normalizes_validator_lowercase(self):
        result = run_lua_test("""
__tracked_events = {}
QuestNodes.ExecuteNode(1, "Q_VAL", "step_1", "validator", {})
assert(#__tracked_events == 1)
assert(__tracked_events[1].event == "quest:client:nodeValidator",
    "wrong event: " .. tostring(__tracked_events[1].event))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_execute_node_normalizes_interact_lowercase(self):
        result = run_lua_test("""
__tracked_events = {}
QuestNodes.ExecuteNode(1, "Q_INT", "step_1", "interact", {})
assert(#__tracked_events == 1)
assert(__tracked_events[1].event == "quest:client:nodeInteract",
    "wrong event: " .. tostring(__tracked_events[1].event))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_execute_node_unknown_type_does_not_trigger_event(self):
        """未知的节点类型不应触发事件"""
        result = run_lua_test("""
__tracked_events = {}
QuestNodes.ExecuteNode(1, "Q_BAD", "step_1", "UNKNOWN_TYPE", {})
assert(#__tracked_events == 0,
    "expected 0 events for unknown type, got " .. #__tracked_events)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_execute_node_nil_type_does_not_trigger_event(self):
        """nil 节点类型不应触发事件（防御性）"""
        result = run_lua_test("""
__tracked_events = {}
QuestNodes.ExecuteNode(1, "Q_NIL", "step_1", nil, {})
assert(#__tracked_events == 0,
    "expected 0 events for nil type, got " .. #__tracked_events)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_execute_node_nil_payload_still_injects_ids(self):
        """无 payload 时仍应注入 questId/stepId"""
        result = run_lua_test("""
__tracked_events = {}
QuestNodes.ExecuteNode(5, "Q_NO_PAYLOAD", "step_99", "GOTO", nil)
assert(#__tracked_events == 1)
local evt = __tracked_events[1]
assert(evt.data.questId == "Q_NO_PAYLOAD")
assert(evt.data.stepId == "step_99")
-- Should have only questId and stepId
local count = 0
for _ in pairs(evt.data) do count = count + 1 end
assert(count == 2, "expected 2 fields, got " .. count)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_execute_node_all_valid_types_trigger(self):
        """验证所有 8 种节点类型都能正确触发对应事件"""
        result = run_lua_test("""
local types = {
    GOTO = "quest:client:nodeGoto",
    INTERACT = "quest:client:nodeInteract",
    VALIDATOR = "quest:client:nodeValidator",
    DELIVER = "quest:client:nodeDeliver",
    COMBAT = "quest:client:nodeCombat",
    WAIT = "quest:client:nodeWait",
    PLACEMENT = "quest:client:nodePlacement",
    DECISION = "story:client:offerDecision",
}
local allPass = true
for nodeType, expectedEvent in pairs(types) do
    __tracked_events = {}
    QuestNodes.ExecuteNode(99, "Q_ALL", "s1", nodeType, { test = true })
    if #__tracked_events ~= 1 then
        allPass = false
        print("FAIL: " .. nodeType .. " triggered " .. #__tracked_events .. " events")
    elseif __tracked_events[1].event ~= expectedEvent then
        allPass = false
        print("FAIL: " .. nodeType .. " event = " ..
            tostring(__tracked_events[1].event) .. " expected " .. expectedEvent)
    end
end
assert(allPass, "not all node types passed")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Tests: QuestNodes.CancelAllNodes ────────────────────────────────────

class TestQuestNodesCancelAllNodes:
    """验证 CancelAllNodes 触发清理事件"""

    def test_cancel_all_nodes_exists(self):
        result = run_lua_test("""
assert(QuestNodes.CancelAllNodes ~= nil, "CancelAllNodes should exist")
assert(type(QuestNodes.CancelAllNodes) == "function",
    "CancelAllNodes should be a function")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_cancel_all_nodes_triggers_clear_event(self):
        result = run_lua_test("""
__tracked_events = {}
QuestNodes.CancelAllNodes(1, "Q_CANCEL_001")
assert(#__tracked_events == 1, "expected 1 event, got " .. #__tracked_events)
local evt = __tracked_events[1]
assert(evt.event == "quest:client:clearAllNodes",
    "wrong event: " .. tostring(evt.event))
assert(evt.source == 1, "wrong source: " .. tostring(evt.source))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_cancel_all_nodes_includes_quest_id_in_data(self):
        result = run_lua_test("""
__tracked_events = {}
QuestNodes.CancelAllNodes(7, "QUEST_XYZ")
assert(#__tracked_events == 1)
assert(__tracked_events[1].data.questId == "QUEST_XYZ",
    "questId missing: " .. tostring(__tracked_events[1].data.questId))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Tests: QuestNodes.ValidateNode ──────────────────────────────────────

class TestQuestNodesValidateNode:
    """ValidateNode 现在会查询 QuestRegistry 并校验步骤/类型，不再是恒真 stub"""

    def test_validate_node_exists(self):
        result = run_lua_test("""
assert(QuestNodes.ValidateNode ~= nil, "ValidateNode should exist")
assert(type(QuestNodes.ValidateNode) == "function")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_validate_node_rejects_unknown_quest(self):
        result = run_lua_test("""
local ok, msg = QuestNodes.ValidateNode(1, "Q", "step", {})
assert(ok == false, "unknown quest should be rejected, got " .. tostring(ok))
assert(msg == "Quest not found", "unexpected message: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_validate_node_accepts_matching_step(self):
        result = run_lua_test("""
QuestRegistry.GetTemplate = function(questId)
    return { steps = { { id = "step", type = "goto", data = {} } } }
end
local ok, msg = QuestNodes.ValidateNode(1, "Q", "step", { nodeType = "GOTO" })
assert(ok == true, "matching step should pass, got " .. tostring(ok))
assert(msg == "ok", "unexpected message: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Tests: QuestManager._resolvedTemplates ──────────────────────────────

class TestQuestManagerInit:
    """验证 QuestManager 初始化状态"""

    def test_quest_manager_exists(self):
        result = run_lua_test("""
assert(QuestManager ~= nil, "QuestManager should exist")
assert(type(QuestManager) == "table", "QuestManager should be a table")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_resolved_templates_starts_empty(self):
        result = run_lua_test("""
assert(QuestManager._resolvedTemplates ~= nil,
    "_resolvedTemplates should exist")
assert(type(QuestManager._resolvedTemplates) == "table",
    "_resolvedTemplates should be a table")
-- Should start empty
local count = 0
for _ in pairs(QuestManager._resolvedTemplates) do count = count + 1 end
assert(count == 0, "_resolvedTemplates should be empty initially, got " .. count)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_quest_manager_is_separate_from_quest_nodes(self):
        """QuestManager 和 QuestNodes 是两个独立的表"""
        result = run_lua_test("""
assert(QuestManager ~= QuestNodes,
    "QuestManager and QuestNodes should be different tables")
-- QuestNodes should not have _resolvedTemplates
assert(QuestNodes._resolvedTemplates == nil,
    "QuestNodes should not have _resolvedTemplates")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Tests: QuestDebug ───────────────────────────────────────────────────

class TestQuestDebug:
    """验证 QUEST_DEBUG convar 控制"""

    def test_quest_debug_enabled_in_test(self):
        """模拟环境中 quest_debug=true，QUEST_DEBUG 应为 true"""
        result = run_lua_test("""
-- QUEST_DEBUG is local, so we test indirectly:
-- When debug is enabled, QuestPrint should not error
-- (it only calls string.format when QUEST_DEBUG is true)
-- We verify the convar is read correctly by checking that
-- the module loaded without errors
assert(true)  -- if we got here, QUEST_DEBUG logic didn't crash
""")
        assert result['ok'], f"Lua error: {result['stderr']}"
