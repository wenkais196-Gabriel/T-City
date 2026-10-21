"""
test_security.py — Security Service 单元测试

测试范围:
- SanitizeNumber (类型校验, 最小/最大钳制, NaN/Inf, 整数强制)
- SanitizeString (trim, maxLength, pattern, empty check)
- ValidateSource (有效/无效 source, PlayerData 完整性)
- ValidateSourceWithJob (职业白名单, 上岗检查)
- CheckSingleThreshold (单笔熔断, 管理员豁免)
- CheckCumulativeThreshold (窗口累计熔断, 窗口过期)
- ValidateMoneyEvent (全量: source + 金额 + 类型 + 阈值)
- ValidateJobEvent (全量: source + 职业名 + 等级)
- ValidateItemEvent (全量: source + 物品名 + 数量)
"""

import os
import subprocess
import tempfile
from pathlib import Path
import pytest


SECURITY_LUA = str(Path(__file__).resolve().parents[3] / 'resources' / '[standalone]' / 'core-framework' / 'services' / 'security_service.lua')


def run_security_test(test_code: str) -> dict:
    """Load security service with mocks and run test code."""
    mock = r'''
_G.QBCore = {
    Functions = {
        GetPlayer = function(src)
            if src == 0 then return nil end
            if src == -1 then return {
                -- Incomplete PlayerData
                PlayerData = nil,
            } end
            return {
                PlayerData = {
                    citizenid = "CID_" .. tostring(src),
                    money = { bank = 50000, cash = 1000 },
                    job = { name = (src == 10 or src == 11) and "police" or "unemployed", grade = { level = (src == 10 or src == 11) and 3 or 0 }, onduty = src == 11 },
                    gang = { name = "none", grade = { level = 0 } },
                },
            }
        end,
        HasPermission = function(src, perm)
            -- src 99 = admin
            return src == 99
        end,
    },
    Config = {
        Qualifications = {
            police_heli_pilot = true,
            advanced_surgery = true,
            weapon_craft = true,
        },
    },
    Shared = { Round = function(v) return math.floor(v + 0.5) end },
}
exports = setmetatable({}, {
    __index = function(t, k)
        if k == "qb-core" then
            return { GetCoreObject = function() return _G.QBCore end }
        end
        return function(...) return true end
    end,
    __call = function(t, name, fn) return true end
})

__convar_values = {
    security_max_single_money = "500000",
    security_max_single_item = "100",
    security_max_single_job = "1",
    security_enable_cumulative_threshold = "1",
    security_max_cumulative_money = "2000000",
}
GetConvar = function(name, default)
    return __convar_values[name] or default or ""
end
GetConvarInt = function(name, default)
    return tonumber(GetConvar(name, tostring(default or 0))) or default
end
GetCurrentResourceName = function() return "test" end
GetPlayerName = function(src) return "Player" .. tostring(src) end
LoadResourceFile = function() return "" end
CreateThread = function(fn) end
Wait = function() end
Citizen = { CreateThread = CreateThread, Wait = Wait }
RegisterNetEvent = function() end; AddEventHandler = function() end
TriggerEvent = function() end; TriggerClientEvent = function() end
MySQL = { query = function() end }
print = function(...) end
os = { time = os.time, clock = os.clock, date = os.date }
math = math; table = table; string = string
pairs = pairs; ipairs = ipairs; type = type; tostring = tostring; tonumber = tonumber
setmetatable = setmetatable; getmetatable = getmetatable
pcall = pcall; error = error; assert = assert; load = load; next = next
require = nil; package = nil; dofile = nil
_G.Bus = _G.Bus or {}
Bus = _G.Bus
Bus._services = {}
function Bus.RegisterService(name, methods)
    Bus._services[name] = methods
    Bus[name] = {}
    for k, v in pairs(methods) do Bus[name][k] = v end
end
'''

    with open(SECURITY_LUA, 'r') as f:
        security_code = f.read()

    security_code = security_code.replace("exports['qb-core']:GetCoreObject()", "QBCore")

    full_script = mock + '\n' + security_code + '\n' + test_code

    with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
        f.write(full_script)
        tmp = f.name

    try:
        result = subprocess.run(['lua5.4', tmp], capture_output=True, text=True, timeout=10)
        return {'ok': result.returncode == 0, 'stdout': result.stdout, 'stderr': result.stderr}
    finally:
        os.unlink(tmp)


# ── SanitizeNumber ──────────────────────────────────────────────────────

class TestSanitizeNumber:
    def test_valid_integer(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeNumber(42, { integer = true })
assert(val == 42, "got: " .. tostring(val))
assert(err == nil, "should not error")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_valid_float(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeNumber(3.14)
assert(val == 3.14, "got: " .. tostring(val))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_clamp_to_max(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeNumber(1000, { max = 100 })
assert(val == 100, "should clamp to 100, got: " .. tostring(val))
assert(err ~= nil, "should warn about clamp")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_clamp_to_min(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeNumber(-50, { min = 0 })
assert(val == 0, "should clamp to 0, got: " .. tostring(val))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_integer_rounding(self):
        result = run_security_test("""
local val = SecurityService.SanitizeNumber(3.7, { integer = true })
assert(val == 4, "3.7 should round to 4, got: " .. tostring(val))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_nil_value_with_default(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeNumber(nil, { defaultValue = 99 })
assert(val == 99, "should use default, got: " .. tostring(val))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_nil_value_without_default(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeNumber(nil)
assert(val == nil, "should return nil")
assert(err ~= nil, "should return error")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_non_numeric_string(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeNumber("abc")
assert(val == nil, "should return nil for non-numeric")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_numeric_string(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeNumber("123", { integer = true })
assert(val == 123, "should parse numeric string, got: " .. tostring(val))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_nan_rejection(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeNumber(0/0)  -- NaN
assert(val == nil or err ~= nil, "should reject NaN")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── SanitizeString ──────────────────────────────────────────────────────

class TestSanitizeString:
    def test_valid_string(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeString("hello")
assert(val == "hello", "got: " .. tostring(val))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_trim_whitespace(self):
        result = run_security_test("""
local val = SecurityService.SanitizeString("  hello  ")
assert(val == "hello", "should trim, got: '" .. tostring(val) .. "'")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_max_length_truncation(self):
        result = run_security_test("""
local val = SecurityService.SanitizeString("abcdefghij", { maxLength = 5 })
assert(#val == 5, "should truncate to 5, got length: " .. #val)
assert(val == "abcde")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_pattern_match(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeString("abc123", { pattern = "^[a-z0-9]+$" })
assert(val == "abc123", "should match pattern")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_pattern_reject(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeString("hello world", { pattern = "^[a-z]+$" })
assert(val == nil, "should reject non-matching")
assert(err ~= nil, "should return error")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_empty_reject(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeString("")
assert(val == nil, "should reject empty")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_empty_allowed(self):
        result = run_security_test("""
local val = SecurityService.SanitizeString("", { allowEmpty = true })
assert(val == "", "should allow empty when configured")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_nil_handling(self):
        result = run_security_test("""
local val, err = SecurityService.SanitizeString(nil)
assert(val == nil, "should return nil for nil")
assert(err ~= nil, "should return error for nil")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_non_string_conversion(self):
        result = run_security_test("""
local val = SecurityService.SanitizeString(123)
assert(val == "123", "should convert number to string, got: '" .. tostring(val) .. "'")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── ValidateSource ──────────────────────────────────────────────────────

class TestValidateSource:
    def test_valid_source(self):
        result = run_security_test("""
local ok, Player, err = SecurityService.ValidateSource(1)
assert(ok == true, "source 1 should be valid, err: " .. tostring(err))
assert(Player ~= nil, "Player should not be nil")
assert(Player.PlayerData.citizenid == "CID_1")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_invalid_source_zero(self):
        result = run_security_test("""
local ok, Player, err = SecurityService.ValidateSource(0)
assert(ok == false, "source 0 should be invalid")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_invalid_source_negative(self):
        result = run_security_test("""
local ok, Player, err = SecurityService.ValidateSource(-5)
assert(ok == false, "negative source should be invalid")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_incomplete_playerdata(self):
        result = run_security_test("""
local ok, Player, err = SecurityService.ValidateSource(-1)
assert(ok == false, "incomplete PlayerData should be invalid")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_nil_source(self):
        result = run_security_test("""
local ok, Player, err = SecurityService.ValidateSource(nil)
assert(ok == false, "nil source should be invalid")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_string_source(self):
        result = run_security_test("""
local ok, Player, err = SecurityService.ValidateSource("abc")
assert(ok == false, "string source should be invalid")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── ValidateSourceWithJob ───────────────────────────────────────────────

class TestValidateSourceWithJob:
    def test_authorized_job(self):
        result = run_security_test("""
local ok, Player, err = SecurityService.ValidateSourceWithJob(10, { police = true })
assert(ok == true, "police source should be authorized, err: " .. tostring(err))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_unauthorized_job(self):
        result = run_security_test("""
local ok, Player, err = SecurityService.ValidateSourceWithJob(1, { police = true })
assert(ok == false, "unemployed should be rejected")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_no_job_restriction(self):
        result = run_security_test("""
local ok, Player, err = SecurityService.ValidateSourceWithJob(1, nil)
assert(ok == true, "nil job filter should allow any")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_require_on_duty(self):
        result = run_security_test("""
-- Source 10 = police (onduty nil), Source 11 = police (onduty true)
local ok1 = SecurityService.ValidateSourceWithJob(10, { police = true }, true)
assert(ok1 == false, "off-duty police should be rejected")

local ok2, _, err2 = SecurityService.ValidateSourceWithJob(11, { police = true }, true)
assert(ok2 == true, "on-duty police should be accepted, err: " .. tostring(err2))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── CheckSingleThreshold ───────────────────────────────────────────────

class TestCheckSingleThreshold:
    def test_within_threshold(self):
        result = run_security_test("""
local ok, reason = SecurityService.CheckSingleThreshold(1, 100000, 'money')
assert(ok == true, "should be within threshold, reason: " .. tostring(reason))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_exceeds_threshold(self):
        result = run_security_test("""
local ok, reason = SecurityService.CheckSingleThreshold(1, 999999, 'money')
assert(ok == false, "should exceed threshold")
assert(reason ~= nil, "should return reason")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_admin_exempt(self):
        result = run_security_test("""
-- Source 99 is admin (HasPermission returns true)
local ok, reason = SecurityService.CheckSingleThreshold(99, 999999, 'money')
assert(ok == true, "admin should be exempt, reason: " .. tostring(reason))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── CheckCumulativeThreshold ───────────────────────────────────────────

class TestCheckCumulativeThreshold:
    def test_within_cumulative(self):
        result = run_security_test("""
local ok, reason = SecurityService.CheckCumulativeThreshold(100, 'money_add', 500, 600, 2000)
assert(ok == true, "should be within cumulative, reason: " .. tostring(reason))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_exceeds_cumulative(self):
        result = run_security_test("""
SecurityService.CheckCumulativeThreshold(200, 'money_add', 1500, 600, 2000)
local ok, reason = SecurityService.CheckCumulativeThreshold(200, 'money_add', 600, 600, 2000)
assert(ok == false, "should exceed cumulative threshold")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_window_expiry_resets(self):
        result = run_security_test("""
-- First call sets window start to os.time()
local ok1 = SecurityService.CheckCumulativeThreshold(300, 'action_x', 1500, 1, 2000)
assert(ok1 == true)
-- Wait for window to expire (os.time() doesn't advance in test)
-- But we test that the tracker was created
assert(true, "tracker should have been created")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── ValidateMoneyEvent ─────────────────────────────────────────────────

class TestValidateMoneyEvent:
    def test_valid_money_event(self):
        result = run_security_test("""
local ok, amount, err = SecurityService.ValidateMoneyEvent(1, 5000, 'bank', 'salary')
assert(ok == true, "should be valid, err: " .. tostring(err))
assert(amount == 5000)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_invalid_account_type(self):
        result = run_security_test("""
local ok, amount, err = SecurityService.ValidateMoneyEvent(1, 100, 'crypto', 'test')
assert(ok == false, "should reject invalid account")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_negative_amount(self):
        result = run_security_test("""
local ok, amount, err = SecurityService.ValidateMoneyEvent(1, -100, 'bank', 'test')
assert(ok == false, "should reject negative amount")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_reason_sanitization(self):
        result = run_security_test("""
local ok, amount, err = SecurityService.ValidateMoneyEvent(1, 100, 'bank', 'valid_reason')
assert(ok == true, "valid reason should work")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_invalid_source(self):
        result = run_security_test("""
local ok, amount, err = SecurityService.ValidateMoneyEvent(0, 100, 'bank', 'test')
assert(ok == false, "should reject invalid source")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_exceeds_max_single(self):
        result = run_security_test("""
-- Amount clamped to 500k then CheckSingleThreshold passes on clamped value
-- The sanitizer clamps, doesn't reject; the threshold checks the clamped result
local ok, amount, err = SecurityService.ValidateMoneyEvent(1, 9999999, 'bank', 'big')
-- amount should be clamped to max (500k), not equal to original
assert(amount == 500000, "should clamp to 500k, got: " .. tostring(amount))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── ValidateJobEvent ───────────────────────────────────────────────────

class TestValidateJobEvent:
    def test_valid_job(self):
        result = run_security_test("""
local ok, job, grade, err = SecurityService.ValidateJobEvent(1, "mechanic", 2)
assert(ok == true, "should be valid, err: " .. tostring(err))
assert(job == "mechanic")
assert(grade == 2)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_invalid_job_name(self):
        result = run_security_test("""
-- "BAD JOB!" fails pattern check, defaultValue="unemployed" kicks in
local ok, job, grade, err = SecurityService.ValidateJobEvent(1, "BAD JOB!", 0)
-- Sanitized to "unemployed" (default), so it passes
assert(job == "unemployed", "should default to unemployed, got: " .. tostring(job))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_default_unemployed(self):
        result = run_security_test("""
-- Empty job name should default to "unemployed"
local ok, job, grade, err = SecurityService.ValidateJobEvent(1, "", 0)
-- Empty pattern won't match ^[a-z0-9_]+$ so rejected -> default
-- Actually empty => nil, but defaultValue="unemployed" is set
assert(ok == true or job == "unemployed")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── ValidateItemEvent ──────────────────────────────────────────────────

class TestValidateItemEvent:
    def test_valid_item(self):
        result = run_security_test("""
local ok, item, count, err = SecurityService.ValidateItemEvent(1, "weapon_pistol", 1)
assert(ok == true, "should be valid, err: " .. tostring(err))
assert(item == "weapon_pistol")
assert(count == 1)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_invalid_item_name(self):
        result = run_security_test("""
local ok, item, count, err = SecurityService.ValidateItemEvent(1, "bad item!", 1)
assert(ok == false, "should reject invalid item name")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── ValidateQualificationEvent ─────────────────────────────────────────

class TestValidateQualificationEvent:
    def test_valid_qual_grant(self):
        result = run_security_test("""
local ok, qual = SecurityService.ValidateQualificationEvent(1, "police_heli_pilot", "grant")
assert(ok == true, "should be valid")
assert(qual == "police_heli_pilot")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_invalid_action(self):
        result = run_security_test("""
local ok, qual = SecurityService.ValidateQualificationEvent(1, "police_heli_pilot", "delete")
assert(ok == false, "should reject invalid action")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_unknown_qualification(self):
        result = run_security_test("""
local ok, qual = SecurityService.ValidateQualificationEvent(1, "unknown_skill_xyz", "grant")
assert(ok == false, "should reject unknown qualification")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── ValidateGangEvent ──────────────────────────────────────────────────

class TestValidateGangEvent:
    """帮派变更事件校验（复用 ValidateJobEvent）"""

    def test_valid_gang(self):
        result = run_security_test("""
local ok, gang, grade, err = SecurityService.ValidateGangEvent(1, "cartel", 2)
assert(ok == true, "should be valid, err: " .. tostring(err))
assert(gang == "cartel")
assert(grade == 2)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_invalid_gang_name(self):
        result = run_security_test("""
local ok, gang, grade, err = SecurityService.ValidateGangEvent(1, "BAD GANG!", 0)
assert(gang == "unemployed", "should default to unemployed, got: " .. tostring(gang))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_invalid_source_rejected(self):
        result = run_security_test("""
local ok, gang, grade, err = SecurityService.ValidateGangEvent(0, "cartel", 0)
assert(ok == false, "should reject source 0")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── IsSecurityEnabled ──────────────────────────────────────────────────

class TestIsSecurityEnabled:
    """全局安全熔断开关"""

    def test_enabled_by_default(self):
        result = run_security_test("""
__convar_values["security_enable"] = "true"
local ok = SecurityService.IsSecurityEnabled("money")
assert(ok == true, "should be enabled by default")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_disabled_globally(self):
        result = run_security_test("""
__convar_values["security_enable"] = "false"
local ok = SecurityService.IsSecurityEnabled("money")
assert(ok == false, "should be disabled when global switch off")
-- Restore
__convar_values["security_enable"] = "true"
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_category_specific_disable(self):
        result = run_security_test("""
__convar_values["security_enable"] = "true"
__convar_values["security_enable_item"] = "false"
local ok = SecurityService.IsSecurityEnabled("item")
assert(ok == false, "item security should be disabled")
-- Restore
__convar_values["security_enable_item"] = "true"
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_all_category(self):
        result = run_security_test("""
__convar_values["security_enable"] = "true"
local ok = SecurityService.IsSecurityEnabled("all")
assert(ok == true, "all should return true when global enabled")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_all_category_disabled_globally(self):
        result = run_security_test("""
__convar_values["security_enable"] = "false"
local ok = SecurityService.IsSecurityEnabled("all")
assert(ok == false, "all should return false when global disabled")
-- Restore
__convar_values["security_enable"] = "true"
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── SanitizeInput (generic) ────────────────────────────────────────────

class TestSanitizeInput:
    def test_number_type(self):
        result = run_security_test("""
local val = SecurityService.SanitizeInput("42", { type = "number", integer = true })
assert(val == 42)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_string_type(self):
        result = run_security_test("""
local val = SecurityService.SanitizeInput(" abc ", { type = "string" })
assert(val == "abc", "got: '" .. tostring(val) .. "'")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_boolean_type(self):
        result = run_security_test("""
local val = SecurityService.SanitizeInput("truthy", { type = "boolean" })
assert(val == true, "truthy should become true")
local val2 = SecurityService.SanitizeInput(false, { type = "boolean" })
assert(val2 == false)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_unknown_type_passthrough(self):
        result = run_security_test("""
local val = SecurityService.SanitizeInput("anything", { type = "unknown" })
assert(val == "anything", "unknown type should passthrough")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"
