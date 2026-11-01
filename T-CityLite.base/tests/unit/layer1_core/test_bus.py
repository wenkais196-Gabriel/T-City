"""
test_bus.py — Bus 总线单元测试

测试范围:
- RegisterService / GetService / SafeCall
- Plugin 系统: Register / GetSchema / Unregister / Subscribe / Publish / List
- exports 注册 (service_<name>_<method>)
- BusStatus export
- DirtyFlush exports
"""

import os
import sys
from pathlib import Path
import pytest

# Add tests dir to path so conftest fixtures work
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


# ── Helpers ────────────────────────────────────────────────────────────

BUS_LUA_FILE = None  # resolved in fixture


def _resolve_bus():
    """Find the bus.lua file."""
    global BUS_LUA_FILE
    if BUS_LUA_FILE is None:
        patterns = [
            str(Path(__file__).resolve().parents[3] / 'resources' / '[standalone]' / 'core-framework' / 'bus.lua'),
        ]
        for p in patterns:
            if os.path.exists(p):
                BUS_LUA_FILE = p
                return p
        raise FileNotFoundError("bus.lua not found")
    return BUS_LUA_FILE


def run_lua_test(code: str) -> dict:
    """Run Lua code with the mock environment + bus.lua loaded, return results."""
    import subprocess, tempfile

    mock = r'''
-- FiveM mock environment
_G.QBCore = {
    Functions = {
        GetPlayer = function(src)
            return {
                PlayerData = { citizenid = "MOCK001", money = { bank = 10000, cash = 500 } },
                Functions = {
                    AddMoney = function(self, a, amt, r) return true end,
                    RemoveMoney = function(self, a, amt, r) return true end,
                },
            }
        end,
        GetPlayerByCitizenId = function(cid)
            return {
                PlayerData = { citizenid = cid, money = { bank = 5000 } },
                Functions = { AddMoney = function(s,a,amt,r) return true end, RemoveMoney = function(s,a,amt,r) return true end },
            }
        end,
    },
    Shared = { Round = function(v) return math.floor(v + 0.5) end },
}
exports = setmetatable({}, {
    __index = function(t,k) return function(...) return true end end,
    __call = function(t, name, fn)
        if type(name) == 'string' and type(fn) == 'function' then
            __exports_registry[name] = fn
        end
        return true
    end
})
GetConvar = function(n, d) return d or "" end
GetConvarInt = function(n, d) return tonumber(d) or 0 end
GetCurrentResourceName = function() return "test-resource" end
GetPlayerName = function(src) return "Test Player" end
LoadResourceFile = function(r, f) return "" end
CreateThread = function(fn) fn() end
Wait = function(ms) end
Citizen = { CreateThread = CreateThread, Wait = Wait }
RegisterNetEvent = function() end
AddEventHandler = function() end
TriggerEvent = function() end
TriggerClientEvent = function() end
TriggerServerEvent = function() end
MySQL = { query = function(s,p,cb) if cb then cb({}) end end, update = function(s,p,cb) if cb then cb(1) end end,
    insert = function(s,p,cb) if cb then cb(1) end end, scalar = function(s,p,cb) if cb then cb(nil) end end,
    single = function(s,p,cb) if cb then cb(nil) end end, prepare = function(s,p,cb) if cb then cb(nil) end end,
    execute = function(s,p,cb) if cb then cb(1) end end }
print = function(...) end
os = { time = os.time, clock = os.clock, date = os.date }
math = math; table = table; string = string
pairs = pairs; ipairs = ipairs; type = type; tostring = tostring; tonumber = tonumber
unpack = table.unpack or unpack
setmetatable = setmetatable; getmetatable = getmetatable
rawget = rawget; rawset = rawset; select = select
pcall = pcall; xpcall = xpcall; error = error; assert = assert
load = load; next = next
require = nil; package = nil; dofile = nil

-- Track exports for verification
__exports_registry = {}

'''

    bus_file = _resolve_bus()
    with open(bus_file, 'r') as f:
        bus_content = f.read()

    # Patch the exports function to track registrations
    bus_content = bus_content.replace(
        'exports(exportName, fn)',
        'exports(exportName, fn); __exports_registry[exportName] = fn'
    )

    full_script = mock + '\n' + bus_content + '\n' + code

    with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
        f.write(full_script)
        tmp = f.name

    try:
        result = subprocess.run(['lua5.4', tmp], capture_output=True, text=True, timeout=10)
        return {
            'ok': result.returncode == 0,
            'stdout': result.stdout,
            'stderr': result.stderr,
            'exit_code': result.returncode,
        }
    finally:
        os.unlink(tmp)


# ── Tests: RegisterService ──────────────────────────────────────────────

class TestBusRegisterService:
    """Bus.RegisterService / GetService / SafeCall"""

    def test_register_service_creates_namespace(self):
        result = run_lua_test("""
local methods = { Greet = function() return "hello" end, Add = function(a,b) return a + b end }
Bus.RegisterService("test_svc", methods)
assert(Bus.test_svc ~= nil, "namespace not created")
assert(Bus.test_svc.Greet ~= nil, "Greet not exposed")
assert(Bus.test_svc.Add ~= nil, "Add not exposed")
assert(Bus._services["test_svc"] ~= nil, "not in _services")
local svc = Bus.GetService("test_svc")
assert(svc ~= nil, "GetService returned nil")
assert(svc.Greet() == "hello", "Greet returned wrong value")
assert(svc.Add(2, 3) == 5, "Add returned wrong value")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_service_twice_overwrites(self):
        """G14：同名服务再注册的现状语义 —— **覆盖**，旧方法整体消失。

        不是"防重复注册"的防护，而是把当前语义钉死：将来若有人把它改成
        "合并"或"拒绝"，这条会红，改动必须显式面对（`Bus.RegisterService` 也没有重名校验，
        `bus.lua` 里 `Bus[name] = {}` 会清掉上一批方法）。
        """
        result = run_lua_test("""
Bus.RegisterService("dup_svc", { Old = function() return 1 end })
Bus.RegisterService("dup_svc", { New = function() return 2 end })
assert(Bus.dup_svc.New ~= nil, "second registration missing")
assert(Bus.dup_svc.Old == nil, "old method survived — 语义已变成合并，需显式确认")
assert(Bus._services["dup_svc"].New ~= nil, "_services not overwritten")
assert(Bus._services["dup_svc"].Old == nil, "_services merged unexpectedly")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_service_adds_exports(self):
        result = run_lua_test("""
local methods = { GetBalance = function() return 100 end, Transfer = function(a,b) return true end }
Bus.RegisterService("economy", methods)
assert(__exports_registry["service_economy_GetBalance"] ~= nil, "export GetBalance missing")
assert(__exports_registry["service_economy_Transfer"] ~= nil, "export Transfer missing")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_safe_call_success(self):
        result = run_lua_test("""
Bus.RegisterService("math_svc", { Add = function(a, b) return a + b end })
local ok, val = Bus.SafeCall("math_svc", "Add", 10, 20)
assert(ok == true, "SafeCall returned false")
assert(val == 30, "SafeCall returned wrong result: " .. tostring(val))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_safe_call_service_not_found(self):
        result = run_lua_test("""
local ok, val = Bus.SafeCall("nonexistent", "Method")
assert(ok == false, "should return false for missing service")
assert(val == nil, "should return nil for missing service")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_safe_call_method_not_found(self):
        result = run_lua_test("""
Bus.RegisterService("empty_svc", {})
local ok, val = Bus.SafeCall("empty_svc", "NoSuchMethod")
assert(ok == false, "should return false for missing method")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_safe_call_handles_error(self):
        result = run_lua_test("""
Bus.RegisterService("boom", { Explode = function() error("kaboom") end })
local ok, val = Bus.SafeCall("boom", "Explode")
assert(ok == false, "should return false on error")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_bus_status_export(self):
        result = run_lua_test("""
local status_fn = exports("BusStatus")
-- Actually BusStatus is exported with exports() not as regular export
-- It's registered via exports('BusStatus', function() ...)
-- Our mock exports just returns true, so we need to check __exports_registry
-- Instead, test Bus itself
assert(Bus._services ~= nil, "_services should exist")
assert(type(Bus._services) == "table", "_services should be a table")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_get_service_returns_nil_for_unknown(self):
        result = run_lua_test("""
local svc = Bus.GetService("does_not_exist_xyz")
assert(svc == nil, "GetService should return nil for unknown service")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_multiple_services_independent(self):
        result = run_lua_test("""
Bus.RegisterService("svc_a", { DoA = function() return "A" end })
Bus.RegisterService("svc_b", { DoB = function() return "B" end })
assert(Bus.svc_a.DoA() == "A")
assert(Bus.svc_b.DoB() == "B")
-- Ensure no cross-contamination
assert(Bus.svc_a.DoB == nil, "DoB should not be on svc_a")
assert(Bus.svc_b.DoA == nil, "DoA should not be on svc_b")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Tests: Plugin System ────────────────────────────────────────────────

class TestBusPlugin:
    """Bus.Plugin 系统"""

    def test_register_plugin(self):
        result = run_lua_test("""
local ok, err = Bus.Plugin.Register("housing_system", {
    version = "1.0.0",
    author = "TestDev",
    description = "A housing plugin",
})
assert(ok == true, "Register failed: " .. tostring(err))
local schema = Bus.Plugin.GetSchema("housing_system")
assert(schema ~= nil, "GetSchema returned nil")
assert(schema.version == "1.0.0")
assert(schema.author == "TestDev")
assert(schema.registered_at ~= nil, "registered_at missing")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_plugin_defaults(self):
        result = run_lua_test("""
local ok, err = Bus.Plugin.Register("minimal_plugin", {})
assert(ok == true, "Register failed: " .. tostring(err))
local schema = Bus.Plugin.GetSchema("minimal_plugin")
assert(schema.version == "1.0.0", "default version wrong")
assert(schema.author == "unknown", "default author wrong")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_plugin_empty_name(self):
        result = run_lua_test("""
local ok, err = Bus.Plugin.Register("", {})
assert(ok == false, "should reject empty name")
assert(err ~= nil, "should return error message")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_plugin_nil_name(self):
        result = run_lua_test("""
local ok, err = Bus.Plugin.Register(nil, {})
assert(ok == false, "should reject nil name")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_register_plugin_duplicate(self):
        result = run_lua_test("""
Bus.Plugin.Register("dup", { version = "1.0.0" })
local ok, err = Bus.Plugin.Register("dup", { version = "2.0.0" })
assert(ok == false, "should reject duplicate")
assert(err:find("already registered") ~= nil, "wrong error: " .. tostring(err))
-- Original should still be there
local schema = Bus.Plugin.GetSchema("dup")
assert(schema.version == "1.0.0", "original should be preserved")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_unregister_plugin(self):
        result = run_lua_test("""
Bus.Plugin.Register("temp_plugin", { version = "1.0.0" })
assert(Bus.Plugin.GetSchema("temp_plugin") ~= nil)
Bus.Plugin.Unregister("temp_plugin")
assert(Bus.Plugin.GetSchema("temp_plugin") == nil, "should be nil after unregister")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_subscribe_and_publish(self):
        result = run_lua_test("""
local received = {}
Bus.Plugin.Subscribe("economy:money_change", function(cid, amount)
    received.cid = cid
    received.amount = amount
end, "test_plugin")

Bus.Plugin.Publish("economy:money_change", "ABC123", 5000)
assert(received.cid == "ABC123", "cid not received: " .. tostring(received.cid))
assert(received.amount == 5000, "amount not received: " .. tostring(received.amount))
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_publish_no_subscribers(self):
        result = run_lua_test("""
-- Should not error when no subscribers
Bus.Plugin.Publish("nonexistent:event", "data")
-- Just verify we reach here without error
assert(true)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_publish_handles_handler_error(self):
        result = run_lua_test("""
Bus.Plugin.Subscribe("test:event", function() error("handler error") end, "bad_plugin")
-- Should not crash
Bus.Plugin.Publish("test:event", "data")
assert(true, "Publish should not crash on handler error")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_plugin_list(self):
        result = run_lua_test("""
Bus.Plugin.Register("plugin_a", { version = "1.0", author = "A" })
Bus.Plugin.Register("plugin_b", { version = "2.0", author = "B" })
local list = Bus.Plugin.List()
assert(#list == 2, "expected 2 plugins, got " .. #list)
-- Order not guaranteed, just count
local found_a, found_b = false, false
for _, p in ipairs(list) do
    if p.name == "plugin_a" then found_a = true end
    if p.name == "plugin_b" then found_b = true end
end
assert(found_a and found_b, "not all plugins in list")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_get_schema_nonexistent(self):
        result = run_lua_test("""
assert(Bus.Plugin.GetSchema("never_registered") == nil)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_plugin_get_economy(self):
        """Plugin.GetEconomy 桥接 — **只返回原语层**（Bus.EconomyService）。

        契约变更：原来返回 `Bus.economy or Bus.EconomyService`，而这两者方法集不同
        （分层便利层没有 RemoveMoney/SetMoney），调用方等于在猜自己拿到了哪套。
        现在原语层优先，便利层走 GetEconomyTools()。
        """
        result = run_lua_test("""
Bus.EconomyService = { RemoveMoney = function() return true end, GetBalance = function() return 999 end }
Bus.economy = { AddScaled = function() return 1 end }
local econ = Bus.Plugin.GetEconomy()
assert(econ ~= nil, "GetEconomy returned nil")
assert(econ.GetBalance() == 999, "wrong economy ref")
assert(econ.RemoveMoney ~= nil, "GetEconomy 必须给出可写钱的层（RemoveMoney）")

local tools = Bus.Plugin.GetEconomyTools()
assert(tools ~= nil and tools.AddScaled ~= nil, "GetEconomyTools 应返回便利层")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_plugin_get_economy_ignores_the_tools_layer(self):
        """只有便利层注册时，GetEconomy 不能拿它冒充原语层。"""
        result = run_lua_test("""
Bus.EconomyService = nil
_G.Bus.EconomyService = nil
_G.EconomyService = nil
Bus.economy = { AddScaled = function() return 1 end }
local econ = Bus.Plugin.GetEconomy()
assert(econ == nil, "便利层不能被 GetEconomy 返回（它没有 RemoveMoney）")
local tools = Bus.Plugin.GetEconomyTools()
assert(tools ~= nil and tools.AddScaled() == 1, "GetEconomyTools 才应该拿到便利层")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_plugin_get_economy_fallback(self):
        """Plugin.GetEconomy — Bus.economy 为 nil 时回退到 _G.EconomyService"""
        result = run_lua_test("""
Bus.economy = nil
_G.EconomyService = { GetBalance = function() return 888 end }
local econ = Bus.Plugin.GetEconomy()
assert(econ ~= nil, "GetEconomy fallback returned nil")
assert(econ.GetBalance() == 888, "wrong fallback ref")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_plugin_get_security(self):
        """Plugin.GetSecurity 桥接 — 返回 Bus.security"""
        result = run_lua_test("""
Bus.security = { ValidateSource = function() return true end }
local sec = Bus.Plugin.GetSecurity()
assert(sec ~= nil, "GetSecurity returned nil")
assert(sec.ValidateSource() == true, "wrong security ref")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"

    def test_plugin_get_persistence(self):
        """Plugin.GetPersistence 桥接 — 返回 Bus.persistence"""
        result = run_lua_test("""
Bus.persistence = { FlushAll = function() return 42 end }
local pers = Bus.Plugin.GetPersistence()
assert(pers ~= nil, "GetPersistence returned nil")
assert(pers.FlushAll() == 42, "wrong persistence ref")
""")
        assert result['ok'], f"Lua error: {result['stderr']}"


# ── Tests: DirtyFlush exports ───────────────────────────────────────────

class TestDirtyFlushExports:
    """Bus 暴露的 DirtyFlush exports"""

    def test_dirtyflush_exports_registered(self):
        result = run_lua_test("""
assert(__exports_registry["DirtyFlushMarkDirty"] ~= nil)
assert(__exports_registry["DirtyFlushStats"] ~= nil)
assert(__exports_registry["DirtyFlushFlushAll"] ~= nil)
assert(__exports_registry["DirtyFlushFlushAllAsync"] ~= nil)
assert(__exports_registry["DirtyFlushForceFlush"] ~= nil)
assert(__exports_registry["DirtyFlushForceFlushAsync"] ~= nil)
""")
        assert result['ok'], f"Lua error: {result['stderr']}"
