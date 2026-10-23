"""
test_economy.py — Economy Service 单元测试

测试范围:
- GetBalance (source 参数)
- AddScaled (倍数缩放、缓存、脏标记)
- Transfer (同在线、离线、自转拦截、余额不足)
"""

import os
import subprocess
import tempfile
from pathlib import Path
import pytest


ECONOMY_LUA = str(Path(__file__).resolve().parents[3] / 'resources' / '[standalone]' / 'core-framework' / 'services' / 'economy_service.lua')


def run_economy_test(test_code: str, extra_mocks: str = "") -> dict:
    """Load economy service with mocks and run test code."""
    mock = r'''
-- Mocks
local __test = { money_added = {}, transfers = {} }
_G.QBCore = {
    Functions = {
        GetPlayer = function(src)
            if src == 999 then return nil end
            if src == 888 then return { PlayerData = { citizenid = "POOR", money = { bank = 0, cash = 0 } }, Functions = { AddMoney = function() return false end, RemoveMoney = function() return true end } } end
            return {
                PlayerData = {
                    citizenid = src == 2 and "CID002" or "CID001",
                    money = { bank = 10000, cash = 500 },
                    job = { name = "unemployed", grade = { level = 0 } },
                },
                Functions = {
                    AddMoney = function(account, amount, reason)
                        table.insert(__test.money_added, { account = account, amount = amount, reason = reason })
                        return true
                    end,
                    RemoveMoney = function(account, amount, reason)
                        table.insert(__test.transfers, { account = account, amount = amount, reason = reason })
                        return true
                    end,
                },
            }
        end,
        GetPlayerByCitizenId = function(cid)
            if cid == "CID002" then
                return {
                    PlayerData = { citizenid = "CID002", money = { bank = 5000 } },
                    Functions = { AddMoney = function(a,amt,r) table.insert(__test.money_added, { account = a, amount = amt, reason = r }) return true end },
                }
            end
            return nil
        end,
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
_DirtyFlush = { marked_dirty = {} }
_DirtyFlush.MarkDirty = function(cid, dataType)
    table.insert(_DirtyFlush.marked_dirty, { cid = cid, dataType = dataType })
end
DirtyFlush = _DirtyFlush
GetConvar = function(name, default)
    if name == "economy_wage_multiplier" then return "100" end
    return default or ""
end
GetConvarInt = function(name, default) return tonumber(GetConvar(name, tostring(default or 0))) or default end
GetCurrentResourceName = function() return "test" end
GetPlayerName = function(src) return "Player" .. tostring(src) end
LoadResourceFile = function() return "" end
CreateThread = function(fn) fn() end
Wait = function() end
Citizen = { CreateThread = CreateThread, Wait = Wait }
RegisterNetEvent = function() end; AddEventHandler = function() end
TriggerEvent = function() end; TriggerClientEvent = function() end
MySQL = { query = function(s,p,cb) if cb then cb({}) end end,
    update = function(s,p,cb) if cb then cb(1) end end,
    insert = function(s,p,cb) if cb then cb(1) end end, scalar = function(s,p,cb) if cb then cb(nil) end end,
    single = function(s,p,cb) if cb then cb(nil) end end, prepare = function(s,p,cb) if cb then cb(nil) end end,
    execute = function(s,p,cb) if cb then cb(1) end end }
print = function(...) end
os = { time = os.time, clock = os.clock, date = os.date }
math = math; table = table; string = string
pairs = pairs; ipairs = ipairs; type = type; tostring = tostring; tonumber = tonumber
setmetatable = setmetatable; getmetatable = getmetatable
pcall = pcall; error = error; assert = assert
load = load; next = next
require = nil; package = nil; dofile = nil
_G.Bus = _G.Bus or {}
Bus = _G.Bus
Bus._services = {}
function Bus.RegisterService(name, methods)
    Bus._services[name] = methods
    Bus[name] = {}
    for k, v in pairs(methods) do Bus[name][k] = v end
end
function Bus.GetService(name) return Bus._services[name] end
function Bus.SafeCall(svc, method, ...)
    local s = Bus._services[svc]
    if not s then return false, nil end
    local fn = s[method]
    if not fn then return false, nil end
    local ok, res = pcall(fn, ...)
    return ok, res
end
''' + extra_mocks

    with open(ECONOMY_LUA, 'r') as f:
        economy_code = f.read()

    # Patch QBCore export call
    economy_code = economy_code.replace(
        "exports['qb-core']:GetCoreObject()",
        "QBCore"
    )
    economy_code = economy_code.replace(
        "exports['custom-logs']",
        "__customLogs"
    )

    full_script = mock + '\n__customLogs = nil\n' + economy_code + '\n' + test_code

    with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
        f.write(full_script)
        tmp = f.name

    try:
        result = subprocess.run(['lua5.4', tmp], capture_output=True, text=True, timeout=10)
        return {'ok': result.returncode == 0, 'stdout': result.stdout, 'stderr': result.stderr}
    finally:
        os.unlink(tmp)


class TestEconomyGetBalance:
    """GetBalance"""

    def test_get_balance_default(self):
        result = run_economy_test("""
local bal = EconomyService.GetBalance(1)
assert(bal ~= nil, "balance should not be nil")
assert(bal.bank == 10000, "bank balance wrong: " .. tostring(bal.bank))
assert(bal.cash == 500, "cash balance wrong: " .. tostring(bal.cash))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_get_balance_specific_account(self):
        result = run_economy_test("""
local bank = EconomyService.GetBalance(1, 'bank')
assert(bank == 10000, "bank wrong: " .. tostring(bank))
local cash = EconomyService.GetBalance(1, 'cash')
assert(cash == 500, "cash wrong: " .. tostring(cash))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_get_balance_player_not_found(self):
        result = run_economy_test("""
local bal = EconomyService.GetBalance(999)
assert(bal == 0, "should return 0 for missing player, got: " .. tostring(bal))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


class TestEconomyAddScaled:
    """AddScaled"""

    def test_add_scaled_basic(self):
        result = run_economy_test("""
local amount, multiplier = EconomyService.AddScaled(1, 'bank', 1000, 'test wage')
assert(amount == 1000, "scaled amount wrong: " .. tostring(amount))
assert(multiplier == 1.0, "multiplier wrong: " .. tostring(multiplier))
assert(#__test.money_added == 1, "money not added")
assert(__test.money_added[1].amount == 1000)
assert(__test.money_added[1].account == 'bank')
assert(__test.money_added[1].reason == 'test wage')
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_add_scaled_zero_amount(self):
        result = run_economy_test("""
local amount, _ = EconomyService.AddScaled(1, 'bank', 0, 'zero')
assert(amount == 0, "should return 0 for zero amount")
assert(#__test.money_added == 0, "should not add zero")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_add_scaled_negative_amount(self):
        result = run_economy_test("""
local amount, _ = EconomyService.AddScaled(1, 'bank', -500, 'negative')
assert(amount == 0, "should return 0 for negative")
assert(#__test.money_added == 0, "should not add negative")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_add_scaled_marks_dirtyflush(self):
        result = run_economy_test("""
_DirtyFlush.marked_dirty = {}
EconomyService.AddScaled(1, 'bank', 500, 'dirty test')
assert(#_DirtyFlush.marked_dirty > 0, "DirtyFlush not marked")
local last = _DirtyFlush.marked_dirty[#_DirtyFlush.marked_dirty]
assert(last.dataType == 'money', "wrong dataType: " .. tostring(last.dataType))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_add_scaled_player_not_found(self):
        result = run_economy_test("""
local amount, mult = EconomyService.AddScaled(999, 'bank', 1000, 'nobody')
assert(amount == 0)
assert(mult == 1.0)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_add_scaled_default_reason(self):
        result = run_economy_test("""
EconomyService.AddScaled(1, 'bank', 100, nil)
assert(__test.money_added[1].reason == 'EconomyService.AddScaled', "default reason not set")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


class TestEconomyTransfer:
    """Transfer"""

    def test_transfer_basic(self):
        result = run_economy_test("""
__test.transfers = {}
local ok, msg = EconomyService.Transfer(1, "CID002", 500, "test transfer")
assert(ok == true, "transfer failed: " .. tostring(msg))
assert(#__test.transfers == 1, "sender not charged")
assert(__test.transfers[1].amount == 500)
assert(__test.transfers[1].account == 'bank')
assert(__test.money_added[1].amount == 500, "receiver not credited")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_transfer_self_blocked(self):
        result = run_economy_test("""
local ok, msg = EconomyService.Transfer(1, "CID001", 500, "self")
assert(ok == false, "should block self-transfer")
assert(msg:find("yourself") ~= nil, "wrong error: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_transfer_insufficient_funds(self):
        result = run_economy_test("""
-- Player has 10000 bank, try to transfer 20000
local ok, msg = EconomyService.Transfer(1, "CID002", 20000, "too much")
assert(ok == false, "should reject insufficient funds")
assert(msg:find("Insufficient") ~= nil, "wrong error: " .. tostring(msg))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_transfer_zero_amount(self):
        result = run_economy_test("""
local ok, msg = EconomyService.Transfer(1, "CID002", 0, "zero")
assert(ok == false, "should reject zero amount")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_transfer_sender_not_found(self):
        result = run_economy_test("""
local ok, msg = EconomyService.Transfer(999, "CID002", 500, "nobody")
assert(ok == false, "should reject missing sender")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


class TestEconomyCaching:
    """Wage Multiplier Caching"""

    def test_wage_multiplier_cached(self):
        result = run_economy_test("""
-- First call should cache
local a1, _ = EconomyService.AddScaled(1, 'bank', 100, 'first')
local a2, _ = EconomyService.AddScaled(1, 'bank', 100, 'second')
assert(a1 == 100, "first call wrong")
assert(a2 == 100, "second call wrong")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


class TestEconomyBusRegistration:
    """Bus registration"""

    def test_registered_on_bus(self):
        result = run_economy_test("""
assert(Bus.economy ~= nil, "not on Bus.economy")
assert(Bus.economy.GetBalance ~= nil, "GetBalance missing")
assert(Bus.economy.AddScaled ~= nil, "AddScaled missing")
assert(Bus.economy.AddMoney ~= nil, "AddMoney missing")
assert(Bus.economy.Transfer ~= nil, "Transfer missing")
local svc = Bus.GetService("economy")
assert(svc ~= nil, "GetService('economy') returned nil")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


class TestEconomyAddMoney:
    """core_economy 网关使用的直接加钱路径"""

    def test_add_money_by_citizenid(self):
        result = run_economy_test("""
__test.money_added = {}
_DirtyFlush.marked_dirty = {}
local ok = EconomyService.AddMoney("CID002", "bank", 1234, "quest:test")
assert(ok == true, "AddMoney should succeed")
assert(#__test.money_added == 1, "money should be added once")
assert(__test.money_added[1].account == "bank")
assert(__test.money_added[1].amount == 1234)
assert(#_DirtyFlush.marked_dirty == 1, "dirty should be marked")
assert(_DirtyFlush.marked_dirty[1].cid == "CID002")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_add_money_unknown_player(self):
        result = run_economy_test("""
local ok = EconomyService.AddMoney("NOPE", "bank", 100, "quest:test")
assert(ok == false, "unknown player should return false")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"
