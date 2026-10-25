"""custom-phone server core: identity / notify / events / rate_limit.

Covers the phase-1 extraction described in ``docs/client/PHONE_ARCHITECTURE.md``:

* the four core files exist and the manifest loads them before the app
  registry and server/main.lua;
* every module exposes the documented global interface and main.lua actually
  calls it (no implementation left in main);
* PhoneIdentity.From/Resolve, PhoneNotify.Store (persist + legacy push +
  unified push + cache invalidation), PhoneEvents.Push and
  PhoneRateLimit.Allow run against the real files in a Lua harness;
* appQuery/appAction return ``rate_limited`` before reaching PhoneApps once
  the per-player bucket is empty, and the legacy callbacks still exist and are
  limited too;
* the legacy callback/event names are unchanged.
"""

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
PHONE = BASE / "resources" / "[custom]" / "custom-phone"
CORE = PHONE / "server" / "core"
IDENTITY = CORE / "identity.lua"
NOTIFY = CORE / "notify.lua"
EVENTS = CORE / "events.lua"
RATE_LIMIT = CORE / "rate_limit.lua"
MAIN = PHONE / "server" / "main.lua"
MANIFEST = PHONE / "fxmanifest.lua"
SMS = PHONE / "server" / "sms.lua"

LUA_BIN = shutil.which("lua5.4")
MARKER = "phone-app-protocol"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _server_scripts() -> str:
    block = re.search(r"server_scripts\s*\{(.*?)\}", read(MANIFEST), re.S)
    assert block, "server_scripts block not found"
    return block.group(1)


def _protocol_block() -> str:
    src = read(MAIN)
    start = src.index(f"-- [{MARKER}] begin")
    end = src.index(f"-- [{MARKER}] end", start)
    return src[start:end + len(f"-- [{MARKER}] end")]


def run_lua(source: str) -> subprocess.CompletedProcess:
    if LUA_BIN is None:
        pytest.skip("lua5.4 is not installed")
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False) as f:
        f.write(source)
        path = f.name
    try:
        return subprocess.run(
            [LUA_BIN, path], capture_output=True, text=True, timeout=15
        )
    finally:
        Path(path).unlink(missing_ok=True)


def assert_lua(source: str) -> None:
    result = run_lua(source)
    assert result.returncode == 0, f"{result.stderr}\n{result.stdout}"


# ---------------------------------------------------------------------------
# Static contracts: files, load order, interfaces
# ---------------------------------------------------------------------------

def test_core_files_exist():
    for path in (IDENTITY, NOTIFY, EVENTS, RATE_LIMIT):
        assert path.is_file(), f"missing {path}"
        assert path.stat().st_size > 0


def test_manifest_loads_core_before_registry_and_main():
    scripts = _server_scripts()
    for path, label in (
        (IDENTITY, "server/core/identity.lua"),
        (RATE_LIMIT, "server/core/rate_limit.lua"),
        (EVENTS, "server/core/events.lua"),
        (NOTIFY, "server/core/notify.lua"),
    ):
        assert f"'{label}'" in scripts, f"manifest missing {label}"
        assert scripts.index(f"'{label}'") < scripts.index("'server/phone_apps.lua'"), \
            f"{label} must load before phone_apps.lua"
        assert scripts.index(f"'{label}'") < scripts.index("'server/main.lua'"), \
            f"{label} must load before main.lua"

    # notify uses Sms/PhoneDb and PhoneEvents, so both must already be loaded.
    assert scripts.index("'server/sms.lua'") < scripts.index("'server/core/notify.lua'")
    assert scripts.index("'server/core/events.lua'") < scripts.index("'server/core/notify.lua'")
    # The existing qb-phone bridge still starts before main.
    assert scripts.index("'server/qb_phone_compat.lua'") < scripts.index("'server/main.lua'")


def test_modules_expose_the_public_interface():
    identity = read(IDENTITY)
    assert "PhoneIdentity = {}" in identity
    for fn in ("From", "IsLeader", "Resolve"):
        assert f"function PhoneIdentity.{fn}(" in identity, fn

    notify = read(NOTIFY)
    assert "PhoneNotify = {}" in notify
    assert "function PhoneNotify.Store(" in notify
    assert "function PhoneNotify.SetCacheInvalidator(" in notify
    assert "setmetatable(PhoneNotify" in notify
    assert "exports('Notify'" in notify
    assert "phone_notifications" in notify

    events = read(EVENTS)
    assert "function PhoneEvents.Push(" in events
    assert "phone:client:event" in events

    rate = read(RATE_LIMIT)
    assert "function PhoneRateLimit.Allow(" in rate
    assert "DefaultRate" in rate and "DefaultBurst" in rate
    assert "rate = 30" in rate and "burst = 10" in rate
    assert "phone_app_rate_per_minute" in rate
    assert "phone_app_rate_burst" in rate


def test_main_calls_core_and_no_longer_defines_it():
    main = read(MAIN)
    for token in (
        "PhoneIdentity.Resolve(",
        "PhoneNotify.Store(",
        "PhoneEvents.Push(",
        "PhoneRateLimit.Allow(",
    ):
        assert token in main, f"main.lua does not call {token}"

    # Rate-limit keys stay app:<citizenid>:<query|action>.
    assert "('app:%s:%s'):format" in main
    assert "appRateKey(src, 'query')" in main
    assert "appRateKey(src, 'action')" in main

    for moved in (
        "function PhoneIdentity.",
        "local function NormaliseNotification(",
        "local function PushStoredNotification(",
        "local function StoreNotification(",
        "function PhoneNotify(",
        "local NOTIFY_APP_IDS",
    ):
        assert moved not in main, f"migrated implementation still in main.lua: {moved}"

    # The one-way cache hook is the only notify/cache coupling left in main.
    assert "PhoneNotify.SetCacheInvalidator(" in main
    assert "phoneDataCache[citizenid] = nil" in main


def test_legacy_callbacks_and_event_names_are_preserved():
    main = read(MAIN)
    for callback in (
        "phone:server:appQuery",
        "phone:server:appAction",
        "phone:server:getPhoneApps",
        "phone:server:storeNotification",
    ):
        assert f"'{callback}'" in main, callback

    notify = read(NOTIFY)
    assert "TriggerClientEvent('phone:client:newNotification'" in notify
    assert "phone:client:newNotification" in notify
    for event in (
        "phone:client:newMessage",
        "phone:client:incomingCall",
        "phone:client:callEnded",
        "phone:client:callAnswered",
    ):
        assert event in main, event


def test_legacy_app_callbacks_are_rate_limited_too():
    main = read(MAIN)
    for callback in ("phone:server:appQuery", "phone:server:appAction"):
        start = main.index(f"CreateCallback('{callback}'")
        block = main[start: main.index("\nend)", start)]
        assert "PhoneRateLimit.Allow(appRateKey(source" in block, callback
        assert "rate_limited" in block, callback


# ---------------------------------------------------------------------------
# Behaviour: real files, minimal FiveM stub
# ---------------------------------------------------------------------------

def test_identity_resolves_career_identity():
    assert_lua(f"""
dofile([[{IDENTITY}]])

assert(PhoneIdentity.From(nil).primary_role == 'none')
assert(PhoneIdentity.From({{ job_name = 'police', rank_tier = 'leader' }}).primary_role == 'police')
assert(PhoneIdentity.IsLeader({{ rank_tier = 'leader' }}))

exports = {{
    ['custom-career'] = {{
        -- FiveM's exports proxy accepts colon syntax; the plain-table stub
        -- receives the export table as the first argument.
        GetPlayerIdentity = function(_, src)
            assert(src == 7)
            return {{ job_name = 'ambulance', rank_tier = 'leader' }}
        end,
    }},
}}
local identity = PhoneIdentity.Resolve(7)
assert(identity.primary_role == 'medic')
assert(PhoneIdentity.IsLeader(identity))
""")


def test_notify_store_persists_pushes_and_invalidates_cache():
    assert_lua(f"""
local state = {{
    inserts = {{}},
    pushes = {{}},
    invalidated = {{}},
    exports = {{}},
    nextId = 42,
}}

local Players = {{
    [7] = {{ PlayerData = {{ source = 7, citizenid = 'CID7' }} }},
}}
local byCitizen = {{ CID7 = Players[7] }}

QBCore = {{
    Functions = {{
        GetPlayer = function(src) return Players[src] end,
        GetPlayerByCitizenId = function(cid) return byCitizen[cid] end,
    }},
}}

exports = setmetatable({{}}, {{
    __call = function(_, name, fn) state.exports[name] = fn end,
    __index = function(_, name)
        if name == 'qb-core' then
            return {{ GetCoreObject = function() return QBCore end }}
        end
        return nil
    end,
}})

function TriggerClientEvent(name, target, payload)
    state.pushes[#state.pushes + 1] = {{ name = name, target = target, payload = payload }}
end

MySQL = {{
    Async = {{
        insert = function(query, params, cb)
            state.inserts[#state.inserts + 1] = {{ query = query, params = params }}
            if cb then cb({{ insertId = state.nextId, affectedRows = 1 }}) end
        end,
    }},
    insert = {{
        await = function(query, params)
            state.inserts[#state.inserts + 1] = {{ query = query, params = params }}
            return {{ insertId = 43, affectedRows = 1 }}
        end,
    }},
}}

dofile([[{SMS}]])
dofile([[{EVENTS}]])
dofile([[{NOTIFY}]])

assert(type(PhoneNotify) == 'table')
assert(type(state.exports.Notify) == 'function', 'Notify export missing')

PhoneNotify.SetCacheInvalidator(function(citizenid)
    state.invalidated[#state.invalidated + 1] = citizenid
end)

assert(PhoneNotify.Store(7, {{ title = 'Hi', content = 'There', app_id = 'police_mdt' }}) == true)
assert(#state.inserts == 1, 'Store must insert once')
assert(state.inserts[1].params[1] == 'CID7')
assert(state.inserts[1].params[2] == 'Hi')
assert(state.inserts[1].params[3] == 'There')
assert(state.inserts[1].params[4] == 'police_mdt')
assert(state.invalidated[1] == 'CID7', 'Store must evict the tray cache')

local legacy, unified
for _, push in ipairs(state.pushes) do
    if push.name == 'phone:client:newNotification' then legacy = push end
    if push.name == 'phone:client:event' then unified = push end
end
assert(legacy, 'legacy notification event missing')
assert(legacy.target == 7 and legacy.payload.id == 42)
assert(legacy.payload.app_id == 'police_mdt')
assert(unified, 'unified phone:client:event missing')
assert(unified.payload.type == 'notification.new')
assert(unified.payload.app_id == 'police_mdt')
assert(unified.payload.payload.id == 42)
assert(type(unified.payload.ts) == 'number')

-- Existing call shape (PhoneNotify(src, n)) keeps working through __call.
PhoneNotify(7, {{ title = 'Again' }})
assert(#state.inserts == 2)

-- A client echo is stored but never pushed back (loop breaker).
local before = #state.pushes
assert(PhoneNotify.Store(7, {{ title = 'Echo' }}, 'client') == true)
assert(#state.inserts == 3)
assert(#state.pushes == before, 'client origin must not push')

-- Owner export (used by custom-police) returns the insert id and pushes once.
local ok, id = state.exports.Notify('CID7', 'Title', 'Body', 'banking', {{ source = 7 }})
assert(ok == true and id == 43)
assert(#state.pushes == before + 2)
assert(state.exports.Notify('', 'Title', 'Body') == false)
""")


def test_events_push_contract():
    assert_lua(f"""
local pushes = {{}}
function TriggerClientEvent(name, target, payload)
    pushes[#pushes + 1] = {{ name = name, target = target, payload = payload }}
end

dofile([[{EVENTS}]])

assert(PhoneEvents.Push(7, 'message.new', {{ id = 1 }}, 'police_mdt') == true)
assert(#pushes == 1)
assert(pushes[1].name == 'phone:client:event')
assert(pushes[1].target == 7)
assert(pushes[1].payload.type == 'message.new')
assert(pushes[1].payload.app_id == 'police_mdt')
assert(pushes[1].payload.payload.id == 1)
assert(type(pushes[1].payload.ts) == 'number')

assert(PhoneEvents.Push('7', 'message.new') == false)
assert(PhoneEvents.Push(7, '') == false)
assert(#pushes == 1, 'invalid pushes must not reach the client')
""")


def test_rate_limit_allows_burst_then_denies():
    assert_lua(f"""
dofile([[{RATE_LIMIT}]])

for i = 1, 10 do
    assert(PhoneRateLimit.Allow('app:CID7:query') == true, 'token ' .. i)
end
assert(PhoneRateLimit.Allow('app:CID7:query') == false, '11th token must be denied')

-- query/action and different citizens have independent buckets.
assert(PhoneRateLimit.Allow('app:CID7:action') == true)
assert(PhoneRateLimit.Allow('app:CID8:query') == true)

-- Explicit rate/burst override.
assert(PhoneRateLimit.Allow('app:CID9:query', 60, 2) == true)
assert(PhoneRateLimit.Allow('app:CID9:query', 60, 2) == true)
assert(PhoneRateLimit.Allow('app:CID9:query', 60, 2) == false)

assert(PhoneRateLimit.Allow('') == false)
""")


def test_app_query_returns_rate_limited_after_burst():
    # Budgets live in server/main.lua: query 120/min burst 40, action 30/min
    # burst 10. A tight harness loop refills almost nothing (120/min = 2/s), so
    # the accepted counts are exact.
    assert_lua(f"""
local appevents, replies = {{}}, {{}}
local queryCalls, actionCalls = 0, 0
local source = 7
playerCitizen = {{ [7] = 'CID7' }}

function RegisterNetEvent(name, fn) appevents[name] = fn end
function TriggerClientEvent(name, target, ...)
    replies[#replies + 1] = {{ name = name, target = target, args = {{ ... }} }}
end

PhoneApps = {{}}
function PhoneApps.Query(src, appId, queryName, params)
    queryCalls = queryCalls + 1
    return true, {{ rows = {{ 1 }} }}
end
function PhoneApps.Action(src, appId, actionName, params)
    actionCalls = actionCalls + 1
    return true, {{ ok = true }}
end

dofile([[{RATE_LIMIT}]])
{_protocol_block()}

local QUERY_BURST, ACTION_BURST = 40, 10

local query = assert(appevents['phone:server:appQueryRequest'])
for i = 1, QUERY_BURST do
    query(('%d:1'):format(i), {{ app_id = 'police_mdt', query = 'units', params = {{}} }})
end
assert(queryCalls == QUERY_BURST, 'the whole burst must reach PhoneApps')
assert(#replies == QUERY_BURST)

local before = #replies
query('41:1', {{ app_id = 'police_mdt', query = 'units', params = {{}} }})
assert(queryCalls == QUERY_BURST, 'rate-limited request must not reach PhoneApps')
assert(#replies == before + 1)
local last = replies[#replies]
assert(last.name == 'phone:client:appQueryResponse')
assert(last.target == 7, 'rate_limited response must unicast to the caller')
assert(last.args[1] == '41:1')
assert(last.args[2].success == false)
assert(last.args[2].error == 'rate_limited')

-- The action bucket is independent, so the query burst does not block it.
local action = assert(appevents['phone:server:appActionRequest'])
for i = 1, ACTION_BURST do
    action(('%d:2'):format(i), {{ app_id = 'police_mdt', action = 'set_status', params = {{}} }})
end
assert(actionCalls == ACTION_BURST, 'the action burst has its own budget')
assert(replies[#replies].args[2].success == true)

local actionBefore = #replies
action('11:2', {{ app_id = 'police_mdt', action = 'set_status', params = {{}} }})
assert(actionCalls == ACTION_BURST, 'exhausted action bucket must not reach PhoneApps')
assert(replies[#replies].args[2].error == 'rate_limited')

-- A malformed payload is rejected before the bucket is consulted, so it still
-- answers bad_request (not rate_limited) and burns no token.
action('12:2', 'not-a-table')
assert(replies[#replies].args[2].error == 'bad_request')
assert(actionCalls == ACTION_BURST)
assert(#replies == actionBefore + 2)
""")
