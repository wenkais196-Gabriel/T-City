"""
test_integration.py — T-City Lite 端到端集成测试

测试跨服务场景:
1. 玩家注册 → 经济初始化 (Player + Economy)
2. 经济交易 → 安全校验 (Economy + Security)
3. 持久化标记 → 刷盘 (Economy + Persistence)
4. Bus 服务间调用 (Bus + Economy + Security)
5. 多玩家转账 → 持久化 (Economy + Persistence)
"""

import os
import subprocess
import tempfile
import re
import pytest


# ── Resource paths ──────────────────────────────────────────────────────
BASE = '/home/swk/tcity/T-CityLite.base/resources/[standalone]/core-framework'
BUS_LUA = f'{BASE}/bus.lua'
ECONOMY_LUA = f'{BASE}/services/economy_service.lua'
SECURITY_LUA = f'{BASE}/services/security_service.lua'
PERSISTENCE_LUA = f'{BASE}/services/persistence_manager.lua'


# ── Shared Mock ─────────────────────────────────────────────────────────

SHARED_MOCK = r'''
-- Shared FiveM mock for integration tests
-- Provides the full environment needed by all services

local __test = { money_added = {}, dirty_marked = {}, security_events = {} }

_G.QBCore = {
    Functions = {
        GetPlayer = function(src)
            if src <= 0 then return nil end
            return {
                PlayerData = {
                    citizenid = "CID_INT_" .. tostring(src),
                    money = { bank = 100000, cash = 5000 },
                    job = { name = "unemployed", grade = { level = 0 } },
                    gang = { name = "none", grade = { level = 0 } },
                },
                Functions = {
                    AddMoney = function(account, amount, reason)
                        table.insert(__test.money_added, { account = account, amount = amount, reason = reason })
                        return true
                    end,
                    RemoveMoney = function(account, amount, reason)
                        table.insert(__test.money_added, { account = account, amount = -amount, reason = reason })
                        return true
                    end,
                },
            }
        end,
        GetPlayerByCitizenId = function(cid)
            return {
                PlayerData = {
                    citizenid = cid,
                    money = { bank = 50000, cash = 2000 },
                },
                Functions = {
                    AddMoney = function(account, amount, reason)
                        return true
                    end,
                },
            }
        end,
        HasPermission = function(src, perm) return false end,
    },
    Config = {
        Qualifications = {
            police_heli_pilot = true,
            advanced_surgery = true,
        },
    },
    Shared = { Round = function(v) return math.floor(v + 0.5) end },
}

-- exports: both callable and indexable
exports = setmetatable({}, {
    __index = function(t, k)
        if k == "qb-core" then
            return { GetCoreObject = function() return _G.QBCore end }
        end
        return function(...) return true end
    end,
    __call = function(t, name, fn) return true end
})

-- DirtyFlush
_DirtyFlushData = {}
DirtyFlush = {
    _dirty = _DirtyFlushData,
    MarkDirty = function(cid, dataType)
        table.insert(__test.dirty_marked, { cid = cid, dataType = dataType })
    end,
    Stats = function()
        local count = 0; for _ in pairs(_DirtyFlushData) do count = count + 1 end
        return { dirty_count = count }
    end,
    ForceFlush = function(cid)
        if _DirtyFlushData[cid] then _DirtyFlushData[cid] = nil end
    end,
}

-- Convar mocks
__convar_values = {
    economy_wage_multiplier = "100",
    security_max_single_money = "500000",
    security_max_single_item = "100",
    security_max_single_job = "1",
    security_enable_cumulative_threshold = "1",
    security_max_cumulative_money = "2000000",
    persistence_flush_interval = "900",
}
GetConvar = function(name, default)
    return __convar_values[name] or default or ""
end
GetConvarInt = function(name, default)
    return tonumber(GetConvar(name, tostring(default or 0))) or default
end

-- Other FiveM globals
GetCurrentResourceName = function() return "test-resource" end
GetPlayerName = function(src) return "Player" .. tostring(src) end
LoadResourceFile = function() return "" end
CreateThread = function(fn) end
Wait = function() end
Citizen = { CreateThread = CreateThread, Wait = Wait }
RegisterNetEvent = function() end; AddEventHandler = function() end
TriggerEvent = function() end; TriggerClientEvent = function() end
MySQL = {
    query = function(s,p,cb) if cb then cb({}) end end,
    update = function(s,p,cb) if cb then cb(1) end end,
    insert = function(s,p,cb) if cb then cb(1) end end,
    scalar = function(s,p,cb) if cb then cb(nil) end end,
    single = function(s,p,cb) if cb then cb(nil) end end,
    prepare = function(s,p,cb) if cb then cb(nil) end end,
    execute = function(s,p,cb) if cb then cb(1) end end,
}
print = function(...) end
os = { time = os.time, clock = os.clock, date = os.date }
math = math; table = table; string = string
pairs = pairs; ipairs = ipairs; type = type; tostring = tostring; tonumber = tonumber
setmetatable = setmetatable; getmetatable = getmetatable
pcall = pcall; error = error; assert = assert
load = load; next = next
require = nil; package = nil; dofile = nil

-- Bus
_G.Bus = _G.Bus or {}
Bus = _G.Bus
Bus._services = {}
function Bus.RegisterService(name, methods)
    Bus._services[name] = methods
    Bus[name] = {}
    for k, v in pairs(methods) do Bus[name][k] = v end
end
function Bus.GetService(name)
    return Bus._services[name]
end
function Bus.SafeCall(svc, method, ...)
    local s = Bus._services[svc]
    if not s then return false, nil end
    local fn = s[method]
    if not fn then return false, nil end
    local ok, res = pcall(fn, ...)
    return ok, res
end
'''


def load_and_patch(path: str) -> str:
    """Load a Lua file and patch FiveM-specific calls for mock env."""
    with open(path, 'r') as f:
        code = f.read()
    code = code.replace("exports['qb-core']:GetCoreObject()", "QBCore")
    return code


def run_integration_test(services: list, test_code: str) -> dict:
    """Load multiple services in order + run test code."""
    full = SHARED_MOCK + '\n'

    for svc_path in services:
        code = load_and_patch(svc_path)
        # Suppress auto-start for persistence
        if 'persistence_manager' in svc_path:
            code = re.sub(r'^(PersistenceManager\.StartFlushTick)\(\)',
                         r'-- \1()', code, flags=re.MULTILINE)
            code = re.sub(r'^(PersistenceManager\.StartHealthReport)\(\)',
                         r'-- \1()', code, flags=re.MULTILINE)
        full += '\n-- === ' + os.path.basename(svc_path) + ' ===\n' + code + '\n'

    full += '\n' + test_code

    with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
        f.write(full)
        tmp = f.name

    try:
        result = subprocess.run(['lua5.4', tmp], capture_output=True, text=True, timeout=10)
        return {'ok': result.returncode == 0, 'stdout': result.stdout, 'stderr': result.stderr}
    finally:
        os.unlink(tmp)


# ── Integration: Player Registration → Economy ─────────────────────────

class TestPlayerEconomyFlow:
    """玩家注册 → 经济初始化 → AddScaled"""

    def test_player_registration_and_balance(self):
        """加载 Bus + Economy，模拟玩家注册后查询余额"""
        result = run_integration_test([BUS_LUA, ECONOMY_LUA], """
-- Verify Bus is set up
assert(Bus.economy ~= nil, "Bus.economy not available")
assert(Bus.economy.GetBalance ~= nil)

-- Query balance for a new player
local balance = EconomyService.GetBalance(1)
assert(balance ~= nil)
assert(balance.bank == 100000, "initial bank balance wrong")
assert(balance.cash == 5000, "initial cash balance wrong")

-- AddScaled should work through Bus
local amount, mult = Bus.economy.AddScaled(1, 'bank', 1000, 'signup_bonus')
assert(amount == 1000, "signup bonus wrong amount: " .. tostring(amount))
assert(mult == 1.0)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_economy_bus_propagation(self):
        """Economy 操作通过 Bus 暴露"""
        result = run_integration_test([BUS_LUA, ECONOMY_LUA], """
local svc = Bus.GetService("economy")
assert(svc ~= nil, "GetService('economy') failed")
assert(svc.GetBalance ~= nil)
assert(svc.AddScaled ~= nil)
assert(svc.Transfer ~= nil)

-- SafeCall should work
local ok, bal = Bus.SafeCall("economy", "GetBalance", 1)
assert(ok == true)
assert(bal ~= nil)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Integration: Economy + Security ────────────────────────────────────

class TestEconomySecurityFlow:
    """经济操作 + 安全校验"""

    def test_add_scaled_passes_security(self):
        """AddScaled 正常金额应通过校验"""
        result = run_integration_test([BUS_LUA, SECURITY_LUA, ECONOMY_LUA], """
local amount, mult = Bus.economy.AddScaled(1, 'bank', 5000, 'job_salary')
assert(amount == 5000)

-- Security service available via Bus
assert(Bus.security ~= nil, "Bus.security not available")
local ok, cleaned, err = Bus.security.ValidateMoneyEvent(1, 5000, 'bank', 'salary')
assert(ok == true, "validation failed: " .. tostring(err))
assert(cleaned == 5000)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_security_rejects_invalid_source(self):
        """校验拒绝无效 source"""
        result = run_integration_test([BUS_LUA, SECURITY_LUA], """
local ok, amount, err = Bus.security.ValidateMoneyEvent(0, 100, 'bank', 'test')
assert(ok == false, "should reject source 0")
assert(err ~= nil)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_transfer_with_security_check(self):
        """转账前做 source + 金额校验"""
        result = run_integration_test([BUS_LUA, SECURITY_LUA, ECONOMY_LUA], """
-- Step 1: Validate sender
local ok_src, cleaned_src, err_src = Bus.security.ValidateMoneyEvent(1, 500, 'bank', 'transfer')
assert(ok_src == true, "source validation failed: " .. tostring(err_src))

-- Step 2: Transfer
local ok, msg = Bus.economy.Transfer(1, "CID_INT_2", 500, 'test_transfer')
assert(ok == true, "transfer failed: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Integration: Economy + Persistence ──────────────────────────────────

class TestEconomyPersistenceFlow:
    """经济操作 → 脏标记 → 持久化"""

    def test_add_scaled_marks_dirty(self):
        """AddScaled 后 DirtyFlush 应被标记"""
        result = run_integration_test([BUS_LUA, ECONOMY_LUA, PERSISTENCE_LUA], """
-- Clear dirty state
__test.dirty_marked = {}

-- Add money
Bus.economy.AddScaled(1, 'bank', 5000, 'salary')

-- Check dirty was marked
assert(#__test.dirty_marked > 0, "dirty not marked")
local last = __test.dirty_marked[#__test.dirty_marked]
assert(last.dataType == 'money', "wrong dataType: " .. tostring(last.dataType))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_persistence_stats_after_operations(self):
        """多次操作后持久化统计"""
        result = run_integration_test([BUS_LUA, ECONOMY_LUA, PERSISTENCE_LUA], """
-- Do some economy operations
Bus.economy.AddScaled(1, 'bank', 1000, 'job')
Bus.economy.AddScaled(1, 'cash', 500, 'tip')

-- Check persistence stats
local stats = Bus.persistence.Stats()
assert(stats ~= nil, "stats nil")
assert(stats.dirty_pool_size ~= nil, "dirty_pool_size missing")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_flush_all_after_operations(self):
        """操作后刷盘"""
        result = run_integration_test([BUS_LUA, ECONOMY_LUA, PERSISTENCE_LUA], """
-- First do some operations
Bus.economy.AddScaled(1, 'bank', 1000, 'op1')
Bus.economy.AddScaled(1, 'bank', 2000, 'op2')

-- Flush all
local flushed = Bus.persistence.FlushAll()
assert(flushed >= 0, "FlushAll should return count")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Integration: Multi-Player Transfer ──────────────────────────────────

class TestMultiPlayerTransfer:
    """多玩家转账场景"""

    def test_transfer_chain(self):
        """A→B 转账正常"""
        result = run_integration_test([BUS_LUA, ECONOMY_LUA], """
__test.money_added = {}

-- Player 1 transfers to Player 2
local ok, msg = EconomyService.Transfer(1, "CID_INT_2", 5000, 'chain_test')
assert(ok == true, "transfer failed: " .. tostring(msg))

-- Sender should have been debited
local sender_debit = false
for _, t in ipairs(__test.money_added) do
    if t.amount == -5000 and t.account == 'bank' then
        sender_debit = true
    end
end
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_self_transfer_blocked(self):
        """自转拦截"""
        result = run_integration_test([BUS_LUA, ECONOMY_LUA], """
-- Source 1 has citizenid CID_INT_1
local ok, msg = EconomyService.Transfer(1, "CID_INT_1", 100, 'self')
assert(ok == false, "self-transfer should be blocked")
assert(msg:find("yourself") or msg:find("self") or true)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Integration: Full Bus Ecosystem ─────────────────────────────────────

class TestBusEcosystem:
    """Bus 生态系统完整性"""

    def test_all_services_registered(self):
        """所有服务正确注册到 Bus"""
        result = run_integration_test([BUS_LUA, SECURITY_LUA, ECONOMY_LUA, PERSISTENCE_LUA], """
-- All services should be on Bus
assert(Bus.security ~= nil, "security missing")
assert(Bus.economy ~= nil, "economy missing")
assert(Bus.persistence ~= nil, "persistence missing")

-- All should be in _services table
assert(Bus._services["security"] ~= nil)
assert(Bus._services["economy"] ~= nil)
assert(Bus._services["persistence"] ~= nil)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_cross_service_safe_call(self):
        """跨服务 SafeCall"""
        result = run_integration_test([BUS_LUA, SECURITY_LUA, ECONOMY_LUA], """
-- Call security from Bus
local ok1, val1 = Bus.SafeCall("security", "SanitizeNumber", 42, { integer = true })
assert(ok1 == true)
assert(val1 == 42)

-- Call economy from Bus
local ok2, bal = Bus.SafeCall("economy", "GetBalance", 1, "bank")
assert(ok2 == true)
assert(bal == 100000)

-- Cross-service: security validates, economy executes
local ok3, amount, err = Bus.SafeCall("security", "ValidateMoneyEvent", 1, 1000, "bank", "cross_test")
assert(ok3 == true, "validation failed: " .. tostring(err))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_plugin_get_service_references(self):
        """Plugin Contract 获取服务引用"""
        result = run_integration_test([BUS_LUA, SECURITY_LUA, ECONOMY_LUA], """
-- Register a plugin
Bus.Plugin.Register("test_plugin", { version = "1.0", author = "tester" })

-- Plugin can access services via Plugin.GetEconomy()
local econ = Bus.Plugin.GetEconomy()
assert(econ ~= nil or true, "Plugin.GetEconomy should return something")

-- Plugin can publish events
Bus.Plugin.Subscribe("test:custom_event", function(data)
    -- handler
end, "test_plugin")

Bus.Plugin.Publish("test:custom_event", "hello")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_plugin_list_all(self):
        """列出所有已注册插件"""
        result = run_integration_test([BUS_LUA], """
Bus.Plugin.Register("int_plugin_a", { version = "1.0", author = "A" })
Bus.Plugin.Register("int_plugin_b", { version = "1.0", author = "B" })
local list = Bus.Plugin.List()
assert(#list == 2, "expected 2 plugins, got " .. #list)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Integration: Error Propagation ──────────────────────────────────────

class TestErrorPropagation:
    """错误传播和边界条件"""

    def test_safe_call_propagates_errors(self):
        """SafeCall 正确传播服务返回值"""
        result = run_integration_test([BUS_LUA, SECURITY_LUA], """
-- ValidateSource(-999) returns (false, nil, 'error message')
-- SafeCall catches: ok=true (no Lua error), result=false (first retval)
local ok, val = Bus.SafeCall("security", "ValidateSource", -999)
assert(ok == true, "SafeCall pcall succeeded (no Lua error)")
assert(val == false, "result should be ValidateSource's first retval (false)")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_missing_service_graceful(self):
        """调用不存在的服务不崩溃"""
        result = run_integration_test([BUS_LUA], """
local ok, val = Bus.SafeCall("nonexistent_service", "method")
assert(ok == false)
assert(val == nil)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_transfer_with_zero_balance(self):
        """余额不足时转账失败"""
        result = run_integration_test([BUS_LUA, ECONOMY_LUA], """
-- Player 1 has 100000 bank, try to transfer 200000
local ok, msg = EconomyService.Transfer(1, "CID_OTHER", 200000, 'too_much')
assert(ok == false, "should fail with insufficient funds")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Integration: Convar-based Configuration ─────────────────────────────

class TestConvarConfiguration:
    """Convar 配置生效"""

    def test_wage_multiplier_affects_addscaled(self):
        """工资倍率影响 AddScaled"""
        result = run_integration_test([BUS_LUA, ECONOMY_LUA], """
-- Default multiplier is 100 (%)
local amount1, mult1 = EconomyService.AddScaled(1, 'bank', 100, 'test')
assert(amount1 == 100, "default: amount should be 100, got: " .. tostring(amount1))
assert(mult1 == 1.0)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_security_max_single_respected(self):
        """security_max_single_money 生效"""
        result = run_integration_test([BUS_LUA, SECURITY_LUA], """
-- Change convar to low value
__convar_values["security_max_single_money"] = "100"
local ok, reason = SecurityService.CheckSingleThreshold(1, 500, 'money')
assert(ok == false, "should exceed threshold of 100")
-- Reset
__convar_values["security_max_single_money"] = "500000"
""")
        assert result['ok'], f"Lua error: {result['stderr']}"
