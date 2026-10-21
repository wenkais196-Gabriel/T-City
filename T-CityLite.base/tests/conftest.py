"""
conftest.py — T-City Lite Test Suite shared fixtures.

Provides:
1. FiveM Lua mock environment (fiveM_mock) — Lua scripts can run with mocked globals
2. Database fixtures (db_conn, db_cursor) — MySQL connection for schema/CRUD tests
3. Resource path helpers — resolve resource files from tests/
"""

import os
import sys
import json
import subprocess
import pytest

# ── Paths ──────────────────────────────────────────────────────────────
TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.dirname(TESTS_DIR)  # T-CityLite.base/
RESOURCES_DIR = os.path.join(BASE_DIR, 'resources')

sys.path.insert(0, TESTS_DIR)


def resolve_resource(name: str) -> str:
    """Map short resource name → absolute path."""
    # name can be like 'oxmysql', 'core-framework', 'custom-quest'
    patterns = [
        f'[standalone]/{name}',
        f'[system]/{name}',
        f'[custom]/{name}',
        f'[qb]/{name}',
    ]
    for p in patterns:
        full = os.path.join(RESOURCES_DIR, p)
        if os.path.isdir(full):
            return full
    raise FileNotFoundError(f"Resource '{name}' not found in resources/")


def resolve_lua(resource: str, path: str) -> str:
    """Resolve a Lua file path within a resource."""
    base = resolve_resource(resource)
    full = os.path.join(base, path)
    if os.path.exists(full):
        return full
    raise FileNotFoundError(f"Lua file not found: {resource}/{path}")


# ── DB fixtures ────────────────────────────────────────────────────────
@pytest.fixture(scope='module')
def db_config():
    """Return MySQL connection config from environment or defaults."""
    return {
        'host': os.environ.get('TCITY_DB_HOST', 'localhost'),
        'port': int(os.environ.get('TCITY_DB_PORT', 3306)),
        'user': os.environ.get('TCITY_DB_USER', 'swk'),
        'password': os.environ.get('TCITY_DB_PASS', ''),
        'database': os.environ.get('TCITY_DB_NAME', 'TCityLite'),
        'charset': 'utf8mb4',
    }


@pytest.fixture(scope='module')
def db_conn(db_config):
    """MySQL connection (skip if mysql-connector not available)."""
    try:
        import mysql.connector
    except ImportError:
        pytest.skip('mysql-connector-python not installed')
    if not db_config.get('password'):
        pytest.skip('TCITY_DB_PASS not set')
    conn = mysql.connector.connect(**db_config)
    yield conn
    conn.close()


@pytest.fixture
def db_cursor(db_conn):
    """MySQL cursor (transactional: rolls back after each test)."""
    cursor = db_conn.cursor(dictionary=True)
    db_conn.start_transaction()
    yield cursor
    db_conn.rollback()


# ── FiveM Lua mock environment ──────────────────────────────────────────
LUA_MOCK_SCRIPT = '''
-- fivem_mock.lua — injected before the test target
-- Provides a minimal FiveM environment so Lua scripts can load without FXServer

-- QBCore stub
_G.QBCore = {
    Functions = {
        GetPlayer = function(src)
            return {
                PlayerData = {
                    citizenid = "MOCK001",
                    money = { bank = 10000, cash = 500 },
                    job = { name = "unemployed", grade = { level = 0, name = "Freelancer" } },
                    gang = { name = "none", grade = { level = 0, name = "None" } },
                    metadata = {},
                    charinfo = { firstname = "Test", lastname = "Player", phone = "555-0000" },
                    position = { x = 0, y = 0, z = 0 },
                },
                Functions = {
                    AddMoney = function(self, account, amount, reason) return true end,
                    RemoveMoney = function(self, account, amount, reason) return true end,
                    SetJob = function(self, job, grade) return true end,
                    SetGang = function(self, gang, grade) return true end,
                },
            }
        end,
        GetPlayerByCitizenId = function(cid)
            return {
                PlayerData = {
                    citizenid = cid,
                    money = { bank = 5000, cash = 200 },
                },
                Functions = {
                    AddMoney = function(self, account, amount, reason) return true end,
                    RemoveMoney = function(self, account, amount, reason) return true end,
                },
            }
        end,
    },
    Shared = {
        Round = function(v) return math.floor(v + 0.5) end,
    },
}

exports = setmetatable({}, {
    __index = function(t, k)
        return function(...) return true end
    end
})

-- FXServer globals
GetConvar = function(name, default)
    local mock_convars = {
        economy_wage_multiplier = "100",
        quest_debug = "true",
        persistence_flush_interval = "900",
    }
    return mock_convars[name] or default or ""
end
GetConvarInt = function(name, default)
    return tonumber(GetConvar(name, tostring(default or 0))) or default
end
GetCurrentResourceName = function() return "test-resource" end
GetPlayerName = function(src) return "Test Player" end
LoadResourceFile = function(resourceName, filename) return "" end

-- Threading
CreateThread = function(fn) fn() end
Wait = function(ms) end
Citizen = { CreateThread = CreateThread, Wait = Wait }

-- Event system
local handlers = {}
RegisterNetEvent = function(name, handler) handlers[name] = handler end
AddEventHandler = function(name, handler) handlers[name] = handler end
TriggerEvent = function(name, ...) if handlers[name] then handlers[name](...) end end
TriggerClientEvent = function(evt, src, data) end

-- DB stubs (tests override these as needed)
MySQL = {
    query = function(sql, params, cb)
        if cb then cb({}) end
    end,
    update = function(sql, params, cb)
        if cb then cb(1) end
    end,
    insert = function(sql, params, cb)
        if cb then cb(1) end
    end,
    scalar = function(sql, params, cb)
        if cb then cb(nil) end
    end,
    single = function(sql, params, cb)
        if cb then cb(nil) end
    end,
    prepare = function(sql, params, cb)
        if cb then cb(nil) end
    end,
    execute = function(sql, params, cb)
        if cb then cb(1) end
    end,
}

-- Misc
print = function(...) end  -- suppress noise; tests can override
os = { time = os.time, clock = os.clock, date = os.date }
math = math
table = table
string = string
pairs = pairs
ipairs = ipairs
type = type
tostring = tostring
tonumber = tonumber
unpack = table.unpack or unpack
setmetatable = setmetatable
getmetatable = getmetatable
rawget = rawget
rawset = rawset
select = select
pcall = pcall
xpcall = xpcall
error = error
assert = assert
load = load
next = next
require = nil  -- FiveM sandbox: no require
package = nil
dofile = nil
'''

@pytest.fixture
def lua_mock_script():
    """Return the Lua mock script content."""
    return LUA_MOCK_SCRIPT


def run_lua_with_mock(script: str, target_file: str, test_code: str = None) -> dict:
    """
    Run a Lua script with the FiveM mock environment preloaded.

    Args:
        script: Lua code to execute (usually includes the mock + target_file loaded)
        target_file: path to the Lua file under test (for error messages)
        test_code: optional assertions to append after loading the target

    Returns:
        dict with keys: success, output, error, return_values
    """
    import tempfile

    full_script = LUA_MOCK_SCRIPT + "\n" + script
    if test_code:
        full_script += "\n" + test_code

    with tempfile.NamedTemporaryFile(mode='w', suffix='.lua', delete=False) as f:
        f.write(full_script)
        tmp_path = f.name

    try:
        result = subprocess.run(
            ['lua5.4', tmp_path],
            capture_output=True, text=True, timeout=10
        )
        return {
            'success': result.returncode == 0,
            'output': result.stdout,
            'error': result.stderr,
            'exit_code': result.returncode,
        }
    finally:
        os.unlink(tmp_path)


def load_lua_resource(resource: str, path: str) -> str:
    """
    Load a Lua file from a resource as a string, patched for the mock environment.
    Replaces CommonJS/exports patterns that don't work in standalone Lua.
    """
    filepath = resolve_lua(resource, path)
    with open(filepath, 'r') as f:
        content = f.read()

    # Patch QBCore export call
    content = content.replace(
        "exports['qb-core']:GetCoreObject()",
        "QBCore"
    )
    content = content.replace(
        'exports["qb-core"]:GetCoreObject()',
        "QBCore"
    )

    # Remove fxmanifest-specific patterns that would error
    # (exports() calls are nops in mock because we already define exports table)

    return content


@pytest.fixture
def tcity_db_config():
    """Return the TCityLite MySQL connection string for tests."""
    return {
        'host': os.environ.get('TCITY_DB_HOST', 'localhost'),
        'port': int(os.environ.get('TCITY_DB_PORT', 3306)),
        'user': os.environ.get('TCITY_DB_USER', 'swk'),
        'password': os.environ.get('TCITY_DB_PASS', ''),
        'database': os.environ.get('TCITY_DB_NAME', 'TCityLite'),
        'charset': 'utf8mb4',
    }
