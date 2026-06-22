"""
test_decision_engine.py — Decision Engine 单元测试

测试范围:
- DecisionEngine.Register (validates decision.id, stores in _registry, rejects nil/invalid)
- DecisionEngine.RegisterAll (batch registration with count return)
- DecisionEngine.GetDecision (lookup known/unknown)
- DecisionEngine.MakeChoice (validates player, decision, option; rejects unknown options; handles invalid source)
"""

import os
import subprocess
import tempfile
import pytest


DECISION_ENGINE_LUA = '/home/swk/tcity/T-CityLite.base/resources/[custom]/story-engine/server/decision_engine.lua'


def run_decision_test(test_code: str) -> dict:
    """Load decision engine with mocks and run test code."""
    mock = r'''
-- ── Mock environment for Decision Engine ───────────────────────────────

-- StoryConfig mock
_G.StoryConfig = { Debug = false }

-- StoryDB mock — track calls
_G.StoryDB = {}
local __storydb_calls = {}
_G.StoryDB.RecordChoice = function(citizenid, decisionId, chosenOptionId, arcId, chapter)
    table.insert(__storydb_calls, {
        fn = "RecordChoice",
        citizenid = citizenid,
        decisionId = decisionId,
        chosenOptionId = chosenOptionId,
        arcId = arcId,
        chapter = chapter,
    })
    return true
end
_G.StoryDB.GetPlayerChoices = function(citizenid, arcId, cb)
    if cb then cb({}) end
end
_G.StoryDB.HasMadeChoice = function(citizenid, decisionId, cb)
    if cb then cb(false) end
end

-- Exports mocks (replaced in code via string substitution)
__custom_logs = { LogSecurity = function(self, category, message, color) end }
__custom_quest = { CompleteStep = function(self, source, questId, stepId) return true, "ok" end }

-- json mock (simple)
json = { encode = function(t) return "{}" end }

-- QBCore mock
_G.QBCore = {
    Functions = {
        GetPlayer = function(src)
            if src == nil or src == 0 then return nil end
            if src == 999 then return nil end
            return {
                PlayerData = {
                    citizenid = "CID_" .. tostring(src),
                    money = { bank = 50000, cash = 1000 },
                    job = { name = "unemployed", grade = { level = 0, name = "Freelancer" } },
                    gang = { name = "none", grade = { level = 0, name = "None" } },
                    metadata = {},
                    charinfo = { firstname = "Test", lastname = "Player" },
                    position = { x = 0, y = 0, z = 0 },
                },
                Functions = {
                    AddMoney = function(self, account, amount, reason) return true end,
                    RemoveMoney = function(self, account, amount, reason) return true end,
                    SetMetaData = function(self, key, value) return true end,
                },
            }
        end,
    },
    Shared = { Round = function(v) return math.floor(v + 0.5) end },
}

-- exports metatable (for qb-core)
exports = setmetatable({}, {
    __index = function(t, k)
        if k == "qb-core" then
            return { GetCoreObject = function() return _G.QBCore end }
        end
        return function(...) return true end
    end,
    __call = function(t, name, fn) return true end
})

-- FXServer globals
GetConvar = function(name, default)
    if name == "story_debug" then return "false" end
    return default or ""
end
GetConvarInt = function(name, default) return tonumber(GetConvar(name, tostring(default or 0))) or default end
GetCurrentResourceName = function() return "story-engine" end
GetPlayerName = function(src) return "Player" .. tostring(src) end
LoadResourceFile = function() return "" end
CreateThread = function(fn) fn() end
Wait = function(ms) end
Citizen = { CreateThread = CreateThread, Wait = Wait }
RegisterNetEvent = function() end
AddEventHandler = function() end
TriggerEvent = function(name, ...) end
TriggerClientEvent = function() end
MySQL = { query = function(s,p,cb) if cb then cb({}) end end, update = function() end,
    insert = function() end, scalar = function(s,p,cb) if cb then cb(nil) end end,
    single = function(s,p,cb) if cb then cb(nil) end end, prepare = function() end,
    execute = function() end }
print = function(...) end
os = { time = os.time, clock = os.clock, date = os.date }
math = math; table = table; string = string
pairs = pairs; ipairs = ipairs; type = type; tostring = tostring; tonumber = tonumber
setmetatable = setmetatable; getmetatable = getmetatable
pcall = pcall; error = error; assert = assert; load = load; next = next
require = nil; package = nil; dofile = nil
'''

    with open(DECISION_ENGINE_LUA, 'r') as f:
        engine_code = f.read()

    # Patch QBCore export call
    engine_code = engine_code.replace(
        "exports['qb-core']:GetCoreObject()",
        "QBCore"
    )
    engine_code = engine_code.replace(
        'exports["qb-core"]:GetCoreObject()',
        "QBCore"
    )

    # Patch exports that need to return objects (not functions), since the
    # generic exports metatable returns functions and method-call syntax
    # (`exports['custom-logs']:LogSecurity(...)`) would error on a function.
    engine_code = engine_code.replace(
        "exports['custom-logs']",
        "__custom_logs"
    )
    engine_code = engine_code.replace(
        'exports["custom-logs"]',
        "__custom_logs"
    )
    engine_code = engine_code.replace(
        "exports['custom-quest']",
        "__custom_quest"
    )
    engine_code = engine_code.replace(
        'exports["custom-quest"]',
        "__custom_quest"
    )

    full_script = mock + '\n' + engine_code + '\n' + test_code

    with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
        f.write(full_script)
        tmp = f.name

    try:
        result = subprocess.run(['lua5.4', tmp], capture_output=True, text=True, timeout=10)
        return {'ok': result.returncode == 0, 'stdout': result.stdout, 'stderr': result.stderr}
    finally:
        os.unlink(tmp)


# ═══════════════════════════════════════════════════════════════════════════
# TestDecisionRegister
# ═══════════════════════════════════════════════════════════════════════════

class TestDecisionRegister:
    """DecisionEngine.Register(decision) — validate & store."""

    def test_register_valid_decision(self):
        """Register a valid decision, verify stored in _registry."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local decision = {
    id = "arc1_ch1_choice1",
    arc_id = "arc1",
    chapter = 1,
    prompt = "What do you do?",
    options = {
        { id = "opt_a", text = "Fight" },
        { id = "opt_b", text = "Flee" },
    },
}
local ok = DecisionEngine.Register(decision)
assert(ok == true, "Register should return true, got: " .. tostring(ok))
assert(DecisionEngine._registry["arc1_ch1_choice1"] ~= nil, "decision should be in _registry")
assert(DecisionEngine._registry["arc1_ch1_choice1"].arc_id == "arc1")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_nil_decision(self):
        """Register nil should return false and not modify _registry."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local ok = DecisionEngine.Register(nil)
assert(ok == false, "Register(nil) should return false, got: " .. tostring(ok))
assert(next(DecisionEngine._registry) == nil, "_registry should be empty")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_decision_without_id(self):
        """Register a table without 'id' field should be rejected."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local ok = DecisionEngine.Register({ arc_id = "arc1", options = {} })
assert(ok == false, "Register without id should return false")
assert(next(DecisionEngine._registry) == nil, "_registry should be empty")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_empty_table(self):
        """Register empty table {} — has no .id so should be rejected."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local ok = DecisionEngine.Register({})
assert(ok == false, "Register({}) should return false")
assert(next(DecisionEngine._registry) == nil, "_registry should be empty")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_overwrite_existing(self):
        """Registering same id twice overwrites previous value."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local first = { id = "test_id", arc_id = "arc_a", options = {} }
local second = { id = "test_id", arc_id = "arc_b", options = {} }
DecisionEngine.Register(first)
DecisionEngine.Register(second)
assert(DecisionEngine._registry["test_id"].arc_id == "arc_b",
    "should overwrite, got: " .. tostring(DecisionEngine._registry["test_id"].arc_id))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_minimal_decision(self):
        """Register decision with only required 'id' field."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local ok = DecisionEngine.Register({ id = "minimal" })
assert(ok == true, "minimal decision should register")
assert(DecisionEngine._registry["minimal"] ~= nil)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_boolean_false_decision(self):
        """Register false (boolean) — should be rejected (no .id)."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local ok = DecisionEngine.Register(false)
assert(ok == false, "Register(false) should return false")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_number_decision(self):
        """Register a number — errors because code tries to index number.id."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local ok, err = pcall(DecisionEngine.Register, 42)
assert(ok == false, "Register(42) should error (cannot index number), got ok=" .. tostring(ok))
assert(err:find("number") ~= nil, "error should mention number, got: " .. tostring(err))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_string_decision(self):
        """Register a string — should be rejected (no .id)."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local ok = DecisionEngine.Register("not_a_table")
assert(ok == false, "Register(string) should return false")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ═══════════════════════════════════════════════════════════════════════════
# TestDecisionRegisterAll
# ═══════════════════════════════════════════════════════════════════════════

class TestDecisionRegisterAll:
    """DecisionEngine.RegisterAll(decisions) — batch registration."""

    def test_register_all_valid(self):
        """Batch register multiple valid decisions, verify count."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local decisions = {
    { id = "d1", arc_id = "arc1", chapter = 1, options = {} },
    { id = "d2", arc_id = "arc1", chapter = 2, options = {} },
    { id = "d3", arc_id = "arc2", chapter = 1, options = {} },
}
local count = DecisionEngine.RegisterAll(decisions)
assert(count == 3, "expected 3, got: " .. tostring(count))
assert(DecisionEngine._registry["d1"] ~= nil)
assert(DecisionEngine._registry["d2"] ~= nil)
assert(DecisionEngine._registry["d3"] ~= nil)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_all_mixed_valid_invalid(self):
        """Batch with some invalid entries — only valid ones count."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local decisions = {
    { id = "good1" },
    { arc_id = "no_id" },   -- invalid: no .id field
    { id = "good2" },
    { id = "good3" },
}
local count = DecisionEngine.RegisterAll(decisions)
assert(count == 3, "expected 3 valid, got: " .. tostring(count))
assert(DecisionEngine._registry["good1"] ~= nil)
assert(DecisionEngine._registry["good2"] ~= nil)
assert(DecisionEngine._registry["good3"] ~= nil)
assert(DecisionEngine._registry["no_id"] == nil, "invalid should not be registered")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_all_empty_list(self):
        """RegisterAll on empty list returns 0."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local count = DecisionEngine.RegisterAll({})
assert(count == 0, "expected 0, got: " .. tostring(count))
assert(next(DecisionEngine._registry) == nil)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_all_all_invalid(self):
        """RegisterAll with all invalid entries returns 0."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local decisions = {
    nil,
    { arc_id = "no_id" },
    false,
    123,
}
local count = DecisionEngine.RegisterAll(decisions)
assert(count == 0, "expected 0, got: " .. tostring(count))
assert(next(DecisionEngine._registry) == nil)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_all_nil_argument(self):
        """RegisterAll(nil) — ipairs on nil should error. Verify it's handled."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local ok, err = pcall(DecisionEngine.RegisterAll, nil)
assert(ok == false, "RegisterAll(nil) should error, but was pcall-safe")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ═══════════════════════════════════════════════════════════════════════════
# TestDecisionGetDecision
# ═══════════════════════════════════════════════════════════════════════════

class TestDecisionGetDecision:
    """DecisionEngine.GetDecision(decisionId) — lookup."""

    def test_get_known_decision(self):
        """Lookup a registered decision returns the definition."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local d = { id = "known_id", arc_id = "arc1", chapter = 3, options = {{ id = "opt1" }} }
DecisionEngine.Register(d)
local found = DecisionEngine.GetDecision("known_id")
assert(found ~= nil, "should find decision")
assert(found.id == "known_id")
assert(found.arc_id == "arc1")
assert(found.chapter == 3)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_get_unknown_decision(self):
        """Lookup an unregistered id returns nil."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local found = DecisionEngine.GetDecision("nonexistent")
assert(found == nil, "should return nil for unknown, got: " .. tostring(found))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_get_decision_after_clear(self):
        """After clearing _registry, previously known id returns nil."""
        result = run_decision_test("""
DecisionEngine._registry = {}
DecisionEngine.Register({ id = "temp" })
assert(DecisionEngine.GetDecision("temp") ~= nil)
DecisionEngine._registry = {}
assert(DecisionEngine.GetDecision("temp") == nil, "should be gone after clear")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_get_decision_nil_id(self):
        """GetDecision(nil) returns nil (table lookup with nil key)."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local found = DecisionEngine.GetDecision(nil)
assert(found == nil, "GetDecision(nil) should return nil")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ═══════════════════════════════════════════════════════════════════════════
# TestDecisionMakeChoice
# ═══════════════════════════════════════════════════════════════════════════

class TestDecisionMakeChoice:
    """DecisionEngine.MakeChoice(source, questId, stepId, decisionId, chosenOptionId)."""

    # ── helpers ──────────────────────────────────────────────────────────

    def test_make_choice_success(self):
        """Happy path: valid player, valid decision, valid option."""
        result = run_decision_test("""
DecisionEngine._registry = {}
DecisionEngine.Register({
    id = "mychoice",
    arc_id = "arc_happy",
    chapter = 1,
    prompt = "Choose wisely",
    options = {
        { id = "opt_yes", text = "Yes", effects = {} },
        { id = "opt_no",  text = "No",  effects = {} },
    },
})
__storydb_calls = {}
local ok, msg = DecisionEngine.MakeChoice(1, "quest1", "step1", "mychoice", "opt_yes")
assert(ok == true, "MakeChoice failed: " .. tostring(msg))
assert(msg == "Choice recorded", "unexpected message: " .. tostring(msg))
assert(#__storydb_calls == 1, "RecordChoice should be called once, got: " .. #__storydb_calls)
assert(__storydb_calls[1].fn == "RecordChoice")
assert(__storydb_calls[1].citizenid == "CID_1")
assert(__storydb_calls[1].decisionId == "mychoice")
assert(__storydb_calls[1].chosenOptionId == "opt_yes")
assert(__storydb_calls[1].arcId == "arc_happy")
assert(__storydb_calls[1].chapter == 1)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_make_choice_player_not_found(self):
        """Source 0 (or invalid) → GetPlayer returns nil → 'Player not found'."""
        result = run_decision_test("""
DecisionEngine._registry = {}
DecisionEngine.Register({
    id = "any",
    arc_id = "arc_any",
    chapter = 1,
    options = { { id = "opt", text = "X" } },
})
local ok, msg = DecisionEngine.MakeChoice(0, "q", "s", "any", "opt")
assert(ok == false, "should fail for source 0")
assert(msg == "Player not found", "wrong message: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_make_choice_decision_not_found(self):
        """Valid player but unknown decisionId → 'Decision not found'."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local ok, msg = DecisionEngine.MakeChoice(1, "q", "s", "no_such_decision", "opt")
assert(ok == false, "should fail for unknown decision")
assert(msg == "Decision not found", "wrong message: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_make_choice_invalid_option(self):
        """Valid decision but chosenOptionId not in decision.options → 'Invalid choice option'."""
        result = run_decision_test("""
DecisionEngine._registry = {}
DecisionEngine.Register({
    id = "locked",
    arc_id = "arc1",
    chapter = 1,
    options = {
        { id = "opt_a", text = "A" },
        { id = "opt_b", text = "B" },
    },
})
local ok, msg = DecisionEngine.MakeChoice(1, "q", "s", "locked", "opt_injected")
assert(ok == false, "should reject injected option")
assert(msg == "Invalid choice option", "wrong message: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_make_choice_second_option(self):
        """Choose the second option in the list."""
        result = run_decision_test("""
DecisionEngine._registry = {}
DecisionEngine.Register({
    id = "two_opts",
    arc_id = "arc2",
    chapter = 1,
    options = {
        { id = "opt_first",  text = "First" },
        { id = "opt_second", text = "Second", effects = { player_flags = { brave = true } } },
    },
})
__storydb_calls = {}
local ok, msg = DecisionEngine.MakeChoice(2, "quest2", "step2", "two_opts", "opt_second")
assert(ok == true, "MakeChoice failed: " .. tostring(msg))
assert(#__storydb_calls == 1, "RecordChoice should be called")
assert(__storydb_calls[1].chosenOptionId == "opt_second")
assert(__storydb_calls[1].citizenid == "CID_2")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_make_choice_empty_options_list(self):
        """Decision with empty options list — any choice is invalid."""
        result = run_decision_test("""
DecisionEngine._registry = {}
DecisionEngine.Register({
    id = "no_opts",
    arc_id = "arc_empty",
    chapter = 1,
    options = {},
})
local ok, msg = DecisionEngine.MakeChoice(1, "q", "s", "no_opts", "anything")
assert(ok == false, "should reject when no options defined")
assert(msg == "Invalid choice option", "wrong message: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_make_choice_nil_options(self):
        """Decision with nil options — treated as empty, any choice invalid."""
        result = run_decision_test("""
DecisionEngine._registry = {}
DecisionEngine.Register({
    id = "nil_opts",
    arc_id = "arc_nil",
    chapter = 1,
    -- options is nil (not provided)
})
local ok, msg = DecisionEngine.MakeChoice(1, "q", "s", "nil_opts", "anything")
assert(ok == false, "should reject when options is nil")
assert(msg == "Invalid choice option", "wrong message: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_make_choice_completestep_failure(self):
        """When CompleteStep returns false, MakeChoice propagates the error."""
        result = run_decision_test("""
DecisionEngine._registry = {}
DecisionEngine.Register({
    id = "broken",
    arc_id = "arc_brk",
    chapter = 1,
    options = { { id = "opt", text = "Go" } },
})
-- Override CompleteStep to fail
__custom_quest.CompleteStep = function(self, source, questId, stepId)
    return false, "Step engine down"
end
__storydb_calls = {}
local ok, msg = DecisionEngine.MakeChoice(1, "q", "s", "broken", "opt")
assert(ok == false, "should fail when CompleteStep fails")
assert(msg == "Step engine down", "wrong error message: " .. tostring(msg))
-- RecordChoice should still have been called before CompleteStep fails
assert(#__storydb_calls == 1, "RecordChoice should still be called even if CompleteStep fails")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_make_choice_with_player_flags_effects(self):
        """Decision option with player_flags triggers SetMetaData calls."""
        result = run_decision_test("""
DecisionEngine._registry = {}
DecisionEngine.Register({
    id = "flags_choice",
    arc_id = "arc_flags",
    chapter = 1,
    options = { {
        id = "flag_opt",
        text = "Set Flags",
        effects = {
            player_flags = {
                dark_side = true,
                respect = -10,
            },
        },
    } },
})
__storydb_calls = {}
local ok, msg = DecisionEngine.MakeChoice(1, "q", "s", "flags_choice", "flag_opt")
assert(ok == true, "MakeChoice with flags failed: " .. tostring(msg))
assert(#__storydb_calls == 1)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_make_choice_source_999_not_found(self):
        """Source 999 → GetPlayer returns nil → 'Player not found'."""
        result = run_decision_test("""
DecisionEngine._registry = {}
DecisionEngine.Register({
    id = "exists",
    arc_id = "arc",
    chapter = 1,
    options = { { id = "opt", text = "X" } },
})
local ok, msg = DecisionEngine.MakeChoice(999, "q", "s", "exists", "opt")
assert(ok == false, "should fail for unknown player (999)")
assert(msg == "Player not found", "wrong: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_make_choice_nil_source(self):
        """nil source → GetPlayer(nil) → try to index nil → error or handled."""
        result = run_decision_test("""
DecisionEngine._registry = {}
DecisionEngine.Register({
    id = "d",
    arc_id = "a",
    chapter = 1,
    options = { { id = "o", text = "X" } },
})
-- nil source → GetPlayer(nil) returns nil → "Player not found"
local ok, msg = DecisionEngine.MakeChoice(nil, "q", "s", "d", "o")
assert(ok == false, "should fail for nil source")
assert(msg == "Player not found", "wrong: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_make_choice_nil_decision_id(self):
        """nil decisionId → lookup nil key → nil → 'Decision not found'."""
        result = run_decision_test("""
DecisionEngine._registry = {}
local ok, msg = DecisionEngine.MakeChoice(1, "q", "s", nil, "opt")
assert(ok == false, "should fail for nil decisionId")
assert(msg == "Decision not found", "wrong: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"
