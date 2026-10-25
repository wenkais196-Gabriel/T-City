"""request_id protocol for phone app queries/actions.

Regression for the qb-core single-slot callback bug: two concurrent `appQuery`
calls (PoliceMDT refresh() -> Promise.all([units, incidents])) used to
overwrite ``QBCore.ServerCallbacks['phone:server:appQuery']``, leaving the first
NUI fetch pending forever. The NUI bridges now carry a client-generated
``request_id`` over dedicated net events, correlate the response by that id, and
time out after 8 s.

These tests execute the real protocol blocks extracted from
client/core/bridge.lua, client/main.lua and server/main.lua against a
deterministic CitizenFX stub (no engine, no network).
"""

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
PHONE = BASE / "resources" / "[custom]" / "custom-phone"
CLIENT = PHONE / "client" / "main.lua"
BRIDGE = PHONE / "client" / "core" / "bridge.lua"
SERVER = PHONE / "server" / "main.lua"
RATE_LIMIT = PHONE / "server" / "core" / "rate_limit.lua"
# 限流实现已搬到 core-framework；这里要把实现装进沙箱，并伪造 CfxLua 的 `exports`
#（既是可注册的函数，又能 exports['res']:Method(...) 调用，且必须吞掉 self）。
OWNER_RATE_LIMIT = (Path(__file__).resolve().parents[3] / 'resources' / '[standalone]'
                    / 'core-framework' / 'server' / 'rate_limit.lua')

EXPORTS_SHIM = """
local __registry = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) __registry[name] = fn end,
    __index = function(_, resource)
        return setmetatable({}, {
            __index = function(_, method)
                return function(_, ...)
                    local fn = __registry[method]
                    if type(fn) ~= 'function' then return nil end
                    return fn(...)
                end
            end,
        })
    end,
})
GetGameTimer = GetGameTimer or function() return os.time() * 1000 end
"""
NUI = PHONE / "web" / "src" / "utils" / "nui.ts"

LUA_BIN = shutil.which("lua5.4")
MARKER = "phone-app-protocol"
READER_MARKER = "phone-app-readers"

CLIENT_STUBS = r"""
-- CitizenFX stubs: deterministic timer queue, captured callbacks/events.
local nuicallbacks, netevents, handlers, timers, sent = {}, {}, {}, {}, {}
local clock = 1000

function GetGameTimer() return clock end
function GetCurrentResourceName() return 'custom-phone' end
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
function RegisterNUICallback(name, fn) nuicallbacks[name] = fn end
function RegisterNetEvent(name, fn) netevents[name] = fn end
function AddEventHandler(name, fn) handlers[#handlers + 1] = { name = name, fn = fn } end
function TriggerServerEvent(name, ...) sent[#sent + 1] = { name = name, args = { ... } } end

local function runTimers()
    local due = timers
    timers = {}
    for _, timer in ipairs(due) do timer.fn() end
end

local function sentFor(name)
    local out = {}
    for _, event in ipairs(sent) do
        if event.name == name then out[#out + 1] = event end
    end
    return out
end

local function respond(eventName, requestId, response)
    assert(netevents[eventName], 'missing net event: ' .. tostring(eventName))
    netevents[eventName](requestId, response)
end

local function capture(sink, tag)
    return function(response)
        sink[#sink + 1] = { tag = tag, response = response }
    end
end
"""

SERVER_STUBS = r"""
-- FXServer stubs: captured net events, unicast replies and PhoneApps calls.
local appevents, replies = {}, {}
local queryCalls, actionCalls = {}, {}
local source = 7
-- appRateKey() resolves the citizenid from the getPhoneData cache.
playerCitizen = { [7] = 'CID7', [8] = 'CID8' }

function RegisterNetEvent(name, fn) appevents[name] = fn end
function TriggerClientEvent(name, target, ...)
    replies[#replies + 1] = { name = name, target = target, args = { ... } }
end

PhoneApps = {
    queryResult = { ok = true, result = { rows = { 1 } } },
    actionResult = { ok = true, result = { ok = true } },
}

function PhoneApps.Query(src, appId, queryName, params)
    queryCalls[#queryCalls + 1] = { src = src, app_id = appId, query = queryName, params = params }
    return PhoneApps.queryResult.ok, PhoneApps.queryResult.result
end

function PhoneApps.Action(src, appId, actionName, params)
    actionCalls[#actionCalls + 1] = { src = src, app_id = appId, action = actionName, params = params }
    return PhoneApps.actionResult.ok, PhoneApps.actionResult.result
end
"""


def _protocol_block(path: Path, marker: str = MARKER) -> str:
    src = path.read_text(encoding="utf-8")
    start = src.index(f"-- [{marker}] begin")
    end = src.index(f"-- [{marker}] end", start)
    return src[start:end + len(f"-- [{marker}] end")]


def run_lua(source: str) -> subprocess.CompletedProcess:
    if LUA_BIN is None:
        pytest.skip("lua5.4 is not installed")
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False) as f:
        f.write(source)
        path = f.name
    try:
        return subprocess.run(
            [LUA_BIN, path], capture_output=True, text=True, timeout=10
        )
    finally:
        Path(path).unlink(missing_ok=True)


def assert_lua(source: str) -> None:
    result = run_lua(source)
    assert result.returncode == 0, f"{result.stderr}\n{result.stdout}"


def client_harness(body: str) -> str:
    return (
        CLIENT_STUBS
        + "\n"
        + _protocol_block(BRIDGE)
        + "\n"
        + _protocol_block(CLIENT, READER_MARKER)
        + "\n"
        + body
    )


def server_harness(body: str) -> str:
    return (
        SERVER_STUBS
        + "\n"
        + EXPORTS_SHIM + "\n"
        + f"dofile([[{OWNER_RATE_LIMIT}]])\n"
        + f"dofile([[{RATE_LIMIT}]])"
        + "\n"
        + _protocol_block(SERVER)
        + "\n"
        + body
    )


def test_client_protocol_uses_dedicated_events():
    client = CLIENT.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")
    for token in (
        "phone:server:appQueryRequest",
        "phone:client:appQueryResponse",
        "phone:server:appActionRequest",
        "phone:client:appActionResponse",
    ):
        assert token in client or token in bridge, token
    assert "APP_REQUEST_TIMEOUT_MS = 8000" in bridge
    assert "error = 'timeout'" in bridge
    assert "resource_stopped" in bridge
    assert "error = 'no_response'" in bridge


def test_client_concurrent_queries_resolve_out_of_order():
    assert_lua(client_harness(r"""
local query = assert(nuicallbacks.appQuery, 'appQuery NUI callback missing')
local results = {}

query({ app_id = 'police_mdt', query = 'units', params = {} }, capture(results, 'units'))
query({ app_id = 'police_mdt', query = 'incidents', params = {} }, capture(results, 'incidents'))

local requests = sentFor('phone:server:appQueryRequest')
assert(#requests == 2, 'expected 2 server requests, got ' .. #requests)
local id1, id2 = requests[1].args[1], requests[2].args[1]
assert(type(id1) == 'string' and type(id2) == 'string')
assert(id1 ~= id2, 'concurrent requests must get unique ids')
assert(id1:match('^%d+:%d+$'), 'unexpected request id format: ' .. id1)
assert(#id1 >= 3 and #id1 <= 64, 'request id violates the server bound')
assert(requests[1].args[2].query == 'units')
assert(requests[2].args[2].query == 'incidents')

-- answer the second request first
respond('phone:client:appQueryResponse', id2, { success = true, data = { rows = { 'incidents' } } })
respond('phone:client:appQueryResponse', id1, { success = true, data = { rows = { 'units' } } })

assert(#results == 2, 'each NUI request must get exactly one callback')
assert(results[1].tag == 'incidents' and results[1].response.data.rows[1] == 'incidents')
assert(results[2].tag == 'units' and results[2].response.data.rows[1] == 'units')

-- a duplicate response must not resolve anything twice
respond('phone:client:appQueryResponse', id1, { success = true, data = { rows = { 'dup' } } })
assert(#results == 2, 'duplicate response resolved twice')

-- the 8 s timers still fire but are no-ops after both answers
runTimers()
assert(#results == 2, 'timeout resolved an already answered request')
"""))


def test_client_timeout_fires_once_and_late_response_is_ignored():
    assert_lua(client_harness(r"""
local query = assert(nuicallbacks.appQuery, 'appQuery NUI callback missing')
local results = {}
query({ app_id = 'police_mdt', query = 'units' }, capture(results, 'slow'))
local id = sentFor('phone:server:appQueryRequest')[1].args[1]

runTimers()
assert(#results == 1, 'timeout must answer the pending request')
assert(results[1].response.success == false and results[1].response.error == 'timeout')

runTimers()
assert(#results == 1, 'timeout fired twice')

respond('phone:client:appQueryResponse', id, { success = true, data = {} })
assert(#results == 1, 'late response resolved a timed-out request')
"""))


def test_client_actions_are_independent_and_unknown_ids_ignored():
    assert_lua(client_harness(r"""
local query = assert(nuicallbacks.appQuery, 'appQuery NUI callback missing')
local action = assert(nuicallbacks.appAction, 'appAction NUI callback missing')
local results = {}

query({ app_id = 'police_mdt', query = 'units' }, capture(results, 'query'))
local qid = sentFor('phone:server:appQueryRequest')[1].args[1]

action({ app_id = 'police_mdt', action = 'set_status', params = { status = 'available' } },
    capture(results, 'action'))
local arequests = sentFor('phone:server:appActionRequest')
assert(#arequests == 1, 'appAction must use its own server event')
local aid = arequests[1].args[1]
assert(aid ~= qid, 'query and action ids must not collide')

respond('phone:client:appQueryResponse', 'forged:1', { success = true, data = {} })
assert(#results == 0, 'unknown request id must be ignored')

respond('phone:client:appActionResponse', aid, { success = true, data = { ok = true } })
assert(#results == 1 and results[1].tag == 'action')
assert(results[1].response.success == true)

respond('phone:client:appQueryResponse', qid, { success = false, error = 'query_failed' })
assert(#results == 2 and results[2].tag == 'query')
assert(results[2].response.error == 'query_failed')
"""))


def test_client_rejects_non_table_payloads_without_a_round_trip():
    assert_lua(client_harness(r"""
local query = assert(nuicallbacks.appQuery, 'appQuery NUI callback missing')
local action = assert(nuicallbacks.appAction, 'appAction NUI callback missing')
local results = {}

query('not-a-table', capture(results, 'bad-query'))
action(42, capture(results, 'bad-action'))
assert(#results == 2)
assert(results[1].response.success == false and results[1].response.error == 'bad_request')
assert(results[2].response.success == false and results[2].response.error == 'bad_request')
assert(#sentFor('phone:server:appQueryRequest') == 0)
assert(#sentFor('phone:server:appActionRequest') == 0)
"""))


def test_client_resource_stop_answers_every_pending_request():
    assert_lua(client_harness(r"""
local query = assert(nuicallbacks.appQuery, 'appQuery NUI callback missing')
local action = assert(nuicallbacks.appAction, 'appAction NUI callback missing')
local results = {}

query({ app_id = 'police_mdt', query = 'units' }, capture(results, 'query'))
action({ app_id = 'police_mdt', action = 'set_status' }, capture(results, 'action'))

local stopped = 0
for _, handler in ipairs(handlers) do
    if handler.name == 'onResourceStop' then
        stopped = stopped + 1
        handler.fn('custom-phone')
    end
end
assert(stopped == 1, 'expected one app protocol onResourceStop handler')
assert(#results == 2, 'pending callbacks must be answered on resource stop')
for _, entry in ipairs(results) do
    assert(entry.response.success == false and entry.response.error == 'resource_stopped')
end

runTimers()
assert(#results == 2, 'timeout answered after cleanup')
local qid = sentFor('phone:server:appQueryRequest')[1].args[1]
respond('phone:client:appQueryResponse', qid, { success = true })
assert(#results == 2, 'response answered after cleanup')
"""))


def test_server_echoes_the_request_id_to_the_calling_source_only():
    assert_lua(server_harness(r"""
local handler = assert(appevents['phone:server:appQueryRequest'], 'appQueryRequest missing')
assert(source == 7)

handler('1000:1', { app_id = 'police_mdt', query = 'units', params = { x = 1 } })
assert(#queryCalls == 1, 'PhoneApps.Query must be called once')
assert(queryCalls[1].src == 7)
assert(queryCalls[1].app_id == 'police_mdt' and queryCalls[1].query == 'units')
assert(queryCalls[1].params.x == 1)

local reply = assert(replies[1])
assert(reply.name == 'phone:client:appQueryResponse')
assert(reply.target == 7, 'response must unicast to the caller, never broadcast')
assert(reply.args[1] == '1000:1', 'request id must be echoed verbatim')
assert(reply.args[2].success == true and reply.args[2].data.rows[1] == 1)

PhoneApps.queryResult = { ok = false, result = 'app_forbidden' }
handler('1000:2', { app_id = 'police_mdt', query = 'units' })
assert(replies[2].target == 7)
assert(replies[2].args[1] == '1000:2')
assert(replies[2].args[2].success == false and replies[2].args[2].error == 'app_forbidden')

local action = assert(appevents['phone:server:appActionRequest'], 'appActionRequest missing')
action('1000:3', { app_id = 'police_mdt', action = 'set_status', params = { status = 'available' } })
assert(#actionCalls == 1 and actionCalls[1].action == 'set_status')
assert(replies[3].name == 'phone:client:appActionResponse')
assert(replies[3].target == 7 and replies[3].args[1] == '1000:3')
"""))


def test_server_rejects_bad_payloads_and_malformed_request_ids():
    assert_lua(server_harness(r"""
local query = assert(appevents['phone:server:appQueryRequest'])
local action = assert(appevents['phone:server:appActionRequest'])

query('1:1', 'not-a-table')
assert(#replies == 1 and replies[1].args[2].error == 'bad_request')
action('1:2', nil)
assert(#replies == 2 and replies[2].args[2].error == 'bad_request')
assert(#queryCalls == 0 and #actionCalls == 0, 'bad payloads must not reach PhoneApps')

local before = #replies
for _, bad in ipairs({ '', 'ab', string.rep('x', 65), 1234, true }) do
    query(bad, { app_id = 'police_mdt', query = 'units' })
    action(bad, { app_id = 'police_mdt', action = 'set_status' })
end
query(nil, { app_id = 'police_mdt', query = 'units' })
assert(#replies == before, 'malformed request ids must be dropped silently')
assert(#queryCalls == 0 and #actionCalls == 0, 'malformed ids must not reach PhoneApps')

-- a valid id still round-trips after the rejects
query('1000:4', { app_id = 'police_mdt', query = 'units' })
assert(#replies == before + 1)
assert(replies[#replies].args[1] == '1000:4')
"""))


def test_server_keeps_the_legacy_callbacks_for_other_callers():
    server = SERVER.read_text(encoding="utf-8")
    assert "CreateCallback('phone:server:appQuery'" in server
    assert "CreateCallback('phone:server:appAction'" in server
    assert "CreateCallback('phone:server:getPhoneApps'" in server


def test_nui_timeout_outlives_the_client_deadline():
    nui = NUI.read_text(encoding="utf-8")
    assert "APP_REQUEST_TIMEOUT_MS = 9000" in nui
    assert "eventName === 'appQuery'" in nui
    assert "eventName === 'appAction'" in nui
    # The generic NUI budget stays smaller than the app protocol budget.
    assert "NUI_TIMEOUT_MS = 6000" in nui


# ---------------------------------------------------------------------------
# P-02: getPhoneData is single-flight (qb-core keeps one callback slot per name)
# ---------------------------------------------------------------------------

def test_get_phone_data_is_single_flight():
    src = CLIENT.read_text(encoding="utf-8")
    assert "local phoneDataBusy = false" in src
    assert "local phoneDataWaiters = {}" in src
    assert "fetchPhoneData" in src
    # The NUI open, OnMoneyChange and RemoveBankMoney paths must all go through
    # the coalescing helper; only the helper itself may call the raw callback.
    assert src.count("TriggerCallback('phone:server:getPhoneData'") == 1
    assert "    fetchPhoneData(cb)" not in src, "NUI callback must wrap cb explicitly"
    assert "fetchPhoneData(function(data)" in src
    # 客户端兜底必须早于 NUI 侧的 abort（否则前端只会看到 AbortError 而不是
    # 结构化的 timeout 码）。NUI_TIMEOUT_MS = 6000，所以这里必须是 4000。
    assert "SetTimeout(4000" in src, "client fallback must fire before the NUI abort"
    assert "SetTimeout(8000" not in src

    nui_ts = (PHONE / "web" / "src" / "utils" / "nui.ts").read_text(encoding="utf-8")
    nui_timeout = re.search(r"NUI_TIMEOUT_MS\s*=\s*(\d+)", nui_ts)
    assert nui_timeout, "NUI_TIMEOUT_MS must stay explicit"
    assert int(nui_timeout.group(1)) > 4000, "NUI abort must stay after the client fallback"


def test_phone_app_protocol_uses_dedicated_events():
    client = CLIENT.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")
    server = SERVER.read_text(encoding="utf-8")
    for token in (
        "phone:server:appQueryRequest",
        "phone:client:appQueryResponse",
        "phone:server:appActionRequest",
        "phone:client:appActionResponse",
    ):
        assert token in client or token in bridge or token in server, token


def test_phone_toggle_ignores_duplicate_key_events():
    """一次按 M 会派发两条命令（RegisterKeyMapping 在资源重启时重复注册）。

    实测症状：第二条命令看到 isPhoneOpen=true 且 IsNuiFocused()=true，立刻走
    ClosePhone → 界面被叫出来又秒关，玩家看到的是"按 M 没反应"。
    """
    src = CLIENT.read_text(encoding="utf-8")

    assert "TOGGLE_DEBOUNCE_MS" in src, "toggle needs a debounce window"
    debounce = re.search(r"TOGGLE_DEBOUNCE_MS\s*=\s*(\d+)", src)
    assert debounce and 100 <= int(debounce.group(1)) <= 1000, "debounce must be 100..1000ms"

    # 防抖必须在命令体里的任何状态检查之前（`isPhoneOpen = true` 在 OpenPhone 里
    # 也出现一次，所以只在命令块内比较顺序）
    block = src[src.index("RegisterCommand('phone', function()"):]
    block = block[:block.index("end, false)")]
    guard = block.index("now - lastToggleAt < TOGGLE_DEBOUNCE_MS")
    assert guard < block.index("if isPhoneOpen then"), "debounce must precede the toggle branch"
    assert block.index("lastToggleAt = now") < block.index("if isPhoneOpen then")

    # keymapping 只注册一次（否则防抖只是兜底，根因还在）
    assert "keyMappingRegistered" in src, "key mapping must be registered at most once"
    mapping = src[src.index("onClientResourceStart"):]
    assert mapping.index("if keyMappingRegistered then return end") < mapping.index("RegisterKeyMapping("), \
        "the once-guard must precede RegisterKeyMapping"
