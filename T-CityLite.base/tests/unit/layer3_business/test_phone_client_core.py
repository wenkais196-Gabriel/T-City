"""client/core contracts: bridge, focus, events, and main wiring.

These tests execute the real ``client/core/*.lua`` modules against a
deterministic CitizenFX stub (no engine, no network). They pin the migration of
``client/main.lua`` onto the shared bridge/focus/events core without changing the
NUI contract:

* ``PhoneBridge.RegisterNui`` registers the old callback names and answers once;
* ``PhoneBridge.Request`` keeps the 8 s request_id protocol and ignores
  duplicate/unknown/late responses; resource stop answers pending callbacks;
* ``PhoneFocus`` isolates owners, restores the previous owner's keepInput and
  preserves the documented phone close behaviour (Release leaves keepInput
  alone; Reset clears it);
* ``PhoneEvents`` forwards ``phone:client:event`` to the NUI exactly once and
  fans out to local subscribers;
* ``client/main.lua`` uses the core modules while every legacy NUI callback
  name stays registered.
"""

import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
PHONE = BASE / "resources" / "[custom]" / "custom-phone"
CLIENT = PHONE / "client" / "main.lua"
CORE = PHONE / "client" / "core"
BRIDGE = CORE / "bridge.lua"
FOCUS = CORE / "focus.lua"
EVENTS = CORE / "events.lua"
DIAG = CORE / "diag.lua"

LUA_BIN = shutil.which("lua5.4")

LUA_STUBS = r"""
-- CitizenFX stubs: deterministic timer queue, captured callbacks/events/focus.
local nuicallbacks, netevents, handlers, timers, sent, messages = {}, {}, {}, {}, {}, {}
local focusCalls, keepCalls = {}, {}
local currentFocus, currentCursor, currentKeep = false, false, false
local clock = 1000
local convars = {}

function GetConvar(name) return convars[name] or '' end
function GetConvarInt(name) return tonumber(convars[name] or '') or 0 end
function setConvar(name, value) convars[name] = value end

function GetGameTimer() return clock end
function GetCurrentResourceName() return 'custom-phone' end
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
function RegisterNUICallback(name, fn) nuicallbacks[name] = fn end
function RegisterNetEvent(name, fn) netevents[name] = fn end
function AddEventHandler(name, fn) handlers[#handlers + 1] = { name = name, fn = fn } end
function TriggerServerEvent(name, ...) sent[#sent + 1] = { name = name, args = { ... } } end
function SendNUIMessage(message) messages[#messages + 1] = message end

function SetNuiFocus(focus, cursor)
    focusCalls[#focusCalls + 1] = { focus = focus == true, cursor = cursor == true }
    currentFocus, currentCursor = focus == true, cursor == true
end
function SetNuiFocusKeepInput(value)
    keepCalls[#keepCalls + 1] = value == true
    currentKeep = value == true
end
function IsNuiFocused() return currentFocus end
function IsNuiFocusKeepingInput() return currentKeep end

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

local function capture(sink, tag)
    return function(response)
        sink[#sink + 1] = { tag = tag, response = response }
    end
end

local function lastFocus() return focusCalls[#focusCalls] or {} end
local function lastKeep() return keepCalls[#keepCalls] end

local function stopHandlers(name)
    local out = {}
    for _, handler in ipairs(handlers) do
        if handler.name == name then out[#out + 1] = handler end
    end
    return out
end
"""


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def harness(*modules: Path, body: str) -> str:
    return LUA_STUBS + "\n" + "\n".join(read(module) for module in modules) + "\n" + body


def run_lua(source: str) -> subprocess.CompletedProcess:
    if LUA_BIN is None:
        pytest.skip("lua5.4 is not installed")
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False) as handle:
        handle.write(source)
        path = handle.name
    try:
        return subprocess.run(
            [LUA_BIN, path], capture_output=True, text=True, timeout=10
        )
    finally:
        Path(path).unlink(missing_ok=True)


def assert_lua(source: str) -> None:
    result = run_lua(source)
    assert result.returncode == 0, f"{result.stderr}\n{result.stdout}"


# ---------------------------------------------------------------------------
# bridge
# ---------------------------------------------------------------------------


def test_bridge_register_nui_answers_exactly_once():
    assert_lua(harness(BRIDGE, body=r"""
local seen = {}
PhoneBridge.RegisterNui('ping', function(data, cb)
    seen.data = data
    cb({ success = true, n = 1 })
    cb({ success = true, n = 2 }) -- must be ignored by the once guard
end)
assert(nuicallbacks.ping, 'PhoneBridge.RegisterNui must register the old name')

local results = {}
nuicallbacks.ping({ x = 1 }, capture(results, 'ping'))
assert(seen.data.x == 1)
assert(#results == 1, 'a handler calling cb twice must answer once')
assert(results[1].tag == 'ping' and results[1].response.n == 1)

PhoneBridge.RegisterNui('boom', function() error('handler blew up') end)
local errors = {}
nuicallbacks.boom({}, capture(errors, 'boom'))
assert(#errors == 1, 'a throwing handler must still answer CEF')
assert(errors[1].response.success == false and errors[1].response.error == 'handler_error')

assert(PhoneBridge.RegisterNui('', function() end) == false)
assert(PhoneBridge.RegisterNui('x', nil) == false)
"""))


def test_bridge_answers_a_callable_callback_table():
    """FXServer 把 NUI 应答通道交成"可调用表"（CFX 函数引用），不是 function。

    旧实现的 `if type(cb) ~= 'function' then return end` 会把这类应答静默丢弃：
    handler 跑了、服务端也回包了，CEF 的 fetch 却一直挂到 9 秒 abort，前端只能
    报查询失败/操作失败。这条回归测试钉住"表也要能应答"。
    """
    assert_lua(harness(BRIDGE, body=r"""
local answerCalls = {}
local callableMeta = { __call = function(self, response)
    answerCalls[#answerCalls + 1] = { ref = rawget(self, '__cfx_functionReference'), response = response }
end }

PhoneBridge.RegisterNui('callable', function(data, cb)
    cb({ success = true, n = 7 })
end)

local cb = setmetatable({ __cfx_functionReference = 'ref-callable' }, callableMeta)
nuicallbacks.callable({ x = 1 }, cb)
assert(#answerCalls == 1, 'a callable table must receive the answer')
assert(answerCalls[1].ref == 'ref-callable')
assert(answerCalls[1].response.success == true and answerCalls[1].response.n == 7)
"""))


def test_bridge_answers_a_cfx_function_reference_table():
    assert_lua(harness(BRIDGE, body=r"""
local answerCalls = {}
Citizen = { InvokeFunctionReference = function(ref, response)
    answerCalls[#answerCalls + 1] = { ref = ref, response = response }
end }

PhoneBridge.RegisterNui('refonly', function(data, cb)
    cb({ success = false, error = 'app_forbidden' })
end)

-- 没有 __call 元方法时退回 Citizen.InvokeFunctionReference
nuicallbacks.refonly({}, { __cfx_functionReference = 'ref-plain' })
assert(#answerCalls == 1, 'a bare function reference must still be answered')
assert(answerCalls[1].ref == 'ref-plain')
assert(answerCalls[1].response.error == 'app_forbidden')
"""))


def test_bridge_does_not_run_a_handler_it_cannot_answer():
    assert_lua(harness(BRIDGE, body=r"""
local ran = false
PhoneBridge.RegisterNui('broken', function(data, cb)
    ran = true
    cb({ success = true })
end)

-- 既不是 function 也不是可调用表：宁可不应答（NUI 侧会拿到确定的超时码），
-- 也不要把 handler 跑一半留下副作用。
nuicallbacks.broken({}, 42)
assert(ran == false, 'a handler with no answer channel must not run')
nuicallbacks.broken({}, nil)
assert(ran == false)
"""))


def test_bridge_level_defaults_on_when_the_convar_is_unset():
    """convar 未定义时 GetConvarInt 返回 0，不能据此判定"关闭"。"""
    assert_lua(harness(BRIDGE, DIAG, body=r"""
assert(GetConvar('phone_diag') == '', 'stub must start with the convar unset')
assert(PhoneDiag.Level() == 1, 'unset phone_diag must default to 1, got ' .. tostring(PhoneDiag.Level()))
local trace = PhoneDiag.StartTrace('k3f9a2b1', 'query', 'police_mdt')
assert(trace ~= nil, 'tracing must be on by default')
"""))


def test_bridge_request_timeout_and_late_response():
    assert_lua(harness(BRIDGE, body=r"""
PhoneBridge.RegisterNui('query', function(data, cb)
    PhoneBridge.Request('phone:server:probeRequest', data, cb)
end)

local results = {}
nuicallbacks.query({ q = 'units' }, capture(results, 'query'))
local request = sentFor('phone:server:probeRequest')[1]
assert(request, 'Request must use a dedicated server event')
local id = request.args[1]
assert(type(id) == 'string' and id:match('^%d+:%d+$'))
assert(#id >= 3 and #id <= 64, 'request id must fit the server bound')
assert(request.args[2].q == 'units')

assert(netevents['phone:client:probeResponse'], 'response event must be registered')
assert(timers[1] and timers[1].ms == 8000, 'default deadline must stay 8 s')

-- forged ids must not resolve anything
netevents['phone:client:probeResponse']('forged:99', { success = true })
assert(#results == 0, 'unknown request id resolved a callback')

runTimers()
assert(#results == 1, 'timeout must answer the pending request')
assert(results[1].response.success == false and results[1].response.error == 'timeout')

runTimers()
assert(#results == 1, 'timeout fired twice')

netevents['phone:client:probeResponse'](id, { success = true, data = {} })
assert(#results == 1, 'late response resolved a timed-out request')
"""))


def test_bridge_requests_are_independent_and_custom_timeout_is_honoured():
    assert_lua(harness(BRIDGE, body=r"""
local results = {}
local idA = PhoneBridge.Request('phone:server:aRequest', { n = 1 }, capture(results, 'a'), 250)
local idB = PhoneBridge.Request('phone:server:bRequest', { n = 2 }, capture(results, 'b'))
assert(idA and idB and idA ~= idB, 'request ids must be unique')
assert(timers[1].ms == 250, 'explicit timeout must be honoured')
assert(timers[2].ms == 8000, 'default timeout must remain 8 s')

-- out-of-order, per-event resolution
netevents['phone:client:bResponse'](idB, { success = true, tag = 'b' })
netevents['phone:client:aResponse'](idA, { success = false, error = 'query_failed' })
assert(#results == 2)
assert(results[1].tag == 'b' and results[1].response.tag == 'b')
assert(results[2].tag == 'a' and results[2].response.error == 'query_failed')

-- duplicate and post-resolve responses are ignored
netevents['phone:client:aResponse'](idA, { success = true })
assert(#results == 2, 'duplicate response resolved twice')

-- a non-table server response is normalised, never trusted
local idC = PhoneBridge.Request('phone:server:cRequest', {}, capture(results, 'c'))
netevents['phone:client:cResponse'](idC, 'not-a-table')
assert(#results == 3 and results[3].response.success == false)
assert(results[3].response.error == 'no_response')

local bad = {}
PhoneBridge.Request(nil, {}, capture(bad, 'bad'))
PhoneBridge.Request('phone:server:dRequest', {}, nil)
assert(#bad == 1 and bad[1].response.error == 'bad_request')

runTimers()
assert(#results == 3, 'timers must be no-ops after all responses')
"""))


def test_bridge_resource_stop_answers_every_pending_request():
    assert_lua(harness(BRIDGE, body=r"""
local results = {}
PhoneBridge.Request('phone:server:aRequest', {}, capture(results, 'a'))
PhoneBridge.Request('phone:server:bRequest', {}, capture(results, 'b'))

local stops = stopHandlers('onResourceStop')
assert(#stops == 1, 'bridge must register exactly one onResourceStop handler')
stops[1].fn('other-resource')
assert(#results == 0, 'another resource stopping must not clear phone requests')
stops[1].fn('custom-phone')

assert(#results == 2, 'pending callbacks must be answered on resource stop')
for _, entry in ipairs(results) do
    assert(entry.response.success == false and entry.response.error == 'resource_stopped')
end
assert(#sentFor('phone:server:aRequest') == 1)

runTimers()
assert(#results == 2, 'timeout answered after cleanup')
netevents['phone:client:aResponse'](sentFor('phone:server:aRequest')[1].args[1], { success = true })
assert(#results == 2, 'response answered after cleanup')
"""))


def test_bridge_await_ack_resends_until_the_nui_answers():
    assert_lua(harness(BRIDGE, body=r"""
local sends, timedOut = 0, false
PhoneBridge.AwaitAck('phone:open', function() sends = sends + 1 end, {
    intervalMs = 250,
    timeoutMs = 2000,
    onTimeout = function() timedOut = true end,
})
assert(sends == 1, 'the first phone:open must be sent immediately')

runTimers() -- 250 ms
assert(sends == 2, 'an unacked phone:open must be resent')
runTimers() -- 500 ms
assert(sends == 3)

assert(PhoneBridge.Ack('phone:open') == true)
runTimers()
runTimers()
runTimers()
assert(sends == 3, 'the ack must stop the resend loop')
assert(timedOut == false, 'a timely ack must not fire onTimeout')
"""))


def test_bridge_await_ack_timeout_calls_back_once():
    assert_lua(harness(BRIDGE, body=r"""
local sends, timeouts = 0, 0
PhoneBridge.AwaitAck('phone:open', function() sends = sends + 1 end, {
    intervalMs = 250, timeoutMs = 750,
    onTimeout = function() timeouts = timeouts + 1 end,
})
for _ = 1, 8 do runTimers() end
assert(timeouts == 1, 'the deadline must fire onTimeout exactly once')
local sentAtTimeout = sends
for _ = 1, 8 do runTimers() end
assert(sends == sentAtTimeout, 'resending must stop after the deadline')
assert(PhoneBridge.Ack('phone:open') == false, 'a late ack after the deadline is not ours')
"""))


def test_bridge_await_ack_is_replaced_by_a_second_attempt():
    assert_lua(harness(BRIDGE, body=r"""
local first, second = 0, 0
local fired = {}
PhoneBridge.AwaitAck('phone:open', function() first = first + 1 end, {
    intervalMs = 250, timeoutMs = 2000, onTimeout = function() fired[#fired + 1] = 'first' end,
})
PhoneBridge.AwaitAck('phone:open', function() second = second + 1 end, {
    intervalMs = 250, timeoutMs = 2000, onTimeout = function() fired[#fired + 1] = 'second' end,
})
assert(PhoneBridge.Ack('phone:open') == true)
for _ = 1, 6 do runTimers() end
assert(first == 1, 'the superseded attempt must not keep resending')
assert(second == 1, 'the new attempt stops on its own ack')
assert(#fired == 0, 'superseding a waiter must not fire its timeout')
assert(PhoneBridge.Ack('phone:open') == false, 'a second ack has nothing to clear')
"""))


# ---------------------------------------------------------------------------
# focus
# ---------------------------------------------------------------------------


def test_focus_owner_isolation_and_state():
    assert_lua(harness(FOCUS, body=r"""
PhoneFocus.Reset()
assert(PhoneFocus.State().owner == nil and PhoneFocus.State().depth == 0)

PhoneFocus.Acquire() -- default owner is phone
local state = PhoneFocus.State()
assert(state.owner == 'phone' and state.focus == true and state.cursor == true)
assert(state.depth == 1 and state.stack[1] == 'phone')
assert(PhoneFocus.IsOwner('phone') and PhoneFocus.IsOwner())
assert(lastFocus().focus == true and lastFocus().cursor == true)
assert(state.keepInput == false, 'Acquire defaults keepInput to false')

PhoneFocus.Acquire('fingerprint', { cursor = true, keepInput = false })
assert(PhoneFocus.IsOwner('fingerprint') and not PhoneFocus.IsOwner('phone'))
assert(PhoneFocus.State().depth == 2)

local focusBefore = #focusCalls
PhoneFocus.Release('phone') -- not the top owner: fingerprint keeps focus
assert(PhoneFocus.IsOwner('fingerprint'))
assert(#focusCalls == focusBefore, 'releasing a non-top owner must not touch focus')
assert(PhoneFocus.Release('phone') == false, 'releasing an absent owner is a no-op')

PhoneFocus.Release('fingerprint')
state = PhoneFocus.State()
assert(state.owner == nil and state.focus == false and state.cursor == false)
assert(lastFocus().focus == false and lastFocus().cursor == false)
"""))


def test_focus_keepinput_is_restored_per_owner_and_reset():
    assert_lua(harness(FOCUS, body=r"""
PhoneFocus.Reset()
PhoneFocus.Acquire('phone', { cursor = true, keepInput = true })
assert(lastKeep() == true)

PhoneFocus.Acquire('fingerprint', { cursor = true, keepInput = false })
assert(lastKeep() == false, 'a new owner must be able to reset keepInput')

PhoneFocus.Release('fingerprint')
assert(PhoneFocus.IsOwner('phone'))
assert(lastKeep() == true, 'the previous owner keepInput must be restored')

-- Documented phone close contract (AGENTS.md): releasing the last owner must
-- not turn keepInput off, or the next phone open freezes WASD.
local keepsBefore = #keepCalls
PhoneFocus.Release('phone')
assert(#keepCalls == keepsBefore, 'Release must leave keepInput alone')
assert(PhoneFocus.State().keepInput == true)

-- Hard cleanup (resource start/stop, /phonefix) does reset it.
PhoneFocus.Reset()
assert(lastKeep() == false)
assert(PhoneFocus.State().keepInput == false and PhoneFocus.State().owner == nil)
"""))


def test_focus_resource_stop_resets_engine_flags():
    assert_lua(harness(FOCUS, body=r"""
PhoneFocus.Acquire('phone', { cursor = true, keepInput = true })
local stops = stopHandlers('onClientResourceStop')
assert(#stops == 1, 'focus.lua must clean up on a client resource stop')
stops[1].fn('other-resource')
assert(PhoneFocus.IsOwner('phone'), 'another resource stopping must not reset focus')

stops[1].fn('custom-phone')
local state = PhoneFocus.State()
assert(state.owner == nil and state.focus == false and state.cursor == false)
assert(state.keepInput == false)
assert(lastFocus().focus == false)
"""))


def test_focus_reassert_same_owner_does_not_repeat_keepinput():
    assert_lua(harness(FOCUS, body=r"""
PhoneFocus.Reset()
PhoneFocus.Acquire('phone', { cursor = true, keepInput = true })

local focuses, keeps = #focusCalls, #keepCalls
PhoneFocus.Acquire('phone', { cursor = true, keepInput = true })
assert(#focusCalls == focuses + 1, 'watchdog must re-assert focus')
assert(#keepCalls == keeps, 'watchdog must not repeat keepInput (cursor guard)')

PhoneFocus.Acquire('phone', { cursor = true, keepInput = false })
assert(lastKeep() == false, 'an explicit keepInput change must still apply')
"""))


def test_focus_reacquire_moves_owner_to_top_without_duplicates():
    assert_lua(harness(FOCUS, body=r"""
PhoneFocus.Reset()
PhoneFocus.Acquire('phone', { cursor = true, keepInput = true })
PhoneFocus.Acquire('story', { cursor = true, keepInput = false })
PhoneFocus.Acquire('phone', { cursor = false, keepInput = true })

local state = PhoneFocus.State()
assert(state.depth == 2, 're-acquiring must not duplicate the owner')
assert(state.owner == 'phone')
assert(state.stack[1] == 'story' and state.stack[2] == 'phone')
assert(lastFocus().cursor == false, 're-acquire must apply the new cursor flag')

PhoneFocus.Release('phone')
assert(PhoneFocus.IsOwner('story'), 'the lower owner must become active again')
assert(lastFocus().focus == true)
"""))


# ---------------------------------------------------------------------------
# events
# ---------------------------------------------------------------------------


def test_events_start_forwards_to_nui_and_subscribers():
    assert_lua(harness(EVENTS, body=r"""
assert(PhoneEvents.Start() == true)
assert(PhoneEvents.Start() == false, 'Start must be idempotent')
assert(PhoneEvents.IsStarted())

local events = assert(netevents['phone:client:event'], 'unified channel not subscribed')
local got = {}
local function onMessage(payload, appId)
    got[#got + 1] = { payload = payload, appId = appId }
end
assert(PhoneEvents.On('message.new', onMessage))

events({ type = 'message.new', app_id = 'sms', payload = { id = 7 } })
assert(#messages == 1)
assert(messages[1].action == 'phone:event')
assert(messages[1].type == 'message.new')
assert(messages[1].app_id == 'sms')
assert(messages[1].payload.id == 7)
assert(#got == 1 and got[1].payload.id == 7 and got[1].appId == 'sms')

-- A non-string app_id is dropped, a missing payload becomes an empty table.
events({ type = 'money.update', app_id = 42, payload = { bank = 5 } })
assert(messages[2].app_id == nil and messages[2].type == 'money.update')
events({ type = 'job.new' })
assert(messages[3].payload ~= nil and #messages[3].payload == 0)

local before = #messages
events('not-a-table')
events({ type = 123 })
events({ type = '' })
assert(#messages == before, 'malformed events must not reach the NUI')

-- Off removes only the local subscriber; NUI forwarding stays active.
assert(PhoneEvents.Off('message.new', onMessage) == true)
events({ type = 'message.new', payload = { id = 8 } })
assert(#got == 1, 'removed subscriber must not run')
assert(#messages == before + 1, 'NUI must keep receiving the unified event')
assert(PhoneEvents.Off('message.new', onMessage) == false)
"""))


def test_events_subscriber_error_does_not_block_nui_or_other_subscribers():
    assert_lua(harness(EVENTS, body=r"""
PhoneEvents.Start()
local handler = assert(netevents['phone:client:event'])
local called = {}

PhoneEvents.On('boom', function() error('subscriber blew up') end)
PhoneEvents.On('boom', function(payload) called[#called + 1] = payload end)

handler({ type = 'boom', payload = { a = 1 } })
assert(#messages == 1, 'NUI forward must happen before local handlers')
assert(#called == 1 and called[1].a == 1, 'one failing subscriber must not stop the rest')
"""))


# ---------------------------------------------------------------------------
# main wiring (static; main.lua needs the whole QBCore client runtime to run)
# ---------------------------------------------------------------------------


def test_main_uses_bridge_for_the_app_callbacks():
    main = read(CLIENT)
    for callback in ("appQuery", "appAction"):
        assert f"PhoneBridge.RegisterNui('{callback}'" in main
        assert f"PhoneBridge.Request('phone:server:{callback}Request'" in main
        assert f"RegisterNUICallback('{callback}'" not in main
    assert "pendingAppQuery" not in main
    assert "RegisterNetEvent('phone:client:appQueryResponse'" not in main
    assert "RegisterNetEvent('phone:client:appActionResponse'" not in main


def test_main_opens_the_ui_through_the_ack_handshake():
    main = read(CLIENT)
    # OpenPhone must not trust a single fire-and-forget SendNUIMessage.
    assert "PhoneBridge.AwaitAck('phone:open'" in main
    assert "RegisterNUICallback('phoneOpenAck'" in main
    assert "PhoneBridge.Ack('phone:open')" in main
    # A half-open phone (no NUI) must reset itself instead of swallowing keys.
    assert "phase = 'open-ack-timeout'" in main
    assert "isPhoneOpen = false" in main

    app = read(PHONE / "web" / "src" / "App.svelte")
    assert "fetchNui('phoneOpenAck')" in app


def test_main_uses_focus_for_open_close_and_cleanup():
    main = read(CLIENT)
    assert "PhoneFocus.Acquire('phone', { cursor = true, keepInput = true })" in main
    assert "PhoneFocus.Release('phone')" in main
    assert "PhoneFocus.Reset()" in main
    assert "PhoneFocus.IsOwner('phone')" in main
    assert "PhoneFocus.State()" in main
    # The defensive stop handler still clears the engine flags directly.
    assert "SetNuiFocus(false, false)" in main
    assert "SetNuiFocusKeepInput(false)" in main


def test_main_starts_the_unified_event_channel_and_keeps_legacy_events():
    main = read(CLIENT)
    assert "PhoneEvents.Start()" in main
    for event in (
        "phone:client:newMessage",
        "phone:client:newNotification",
        "phone:client:newJob",
        "phone:client:factionReceive",
        "phone:client:incomingCall",
        "phone:client:callAnswered",
        "phone:client:callEnded",
        "phone:client:routeGps",
        "phone:client:gpsMessage",
        "phone:client:systemSpeech",
    ):
        assert f"RegisterNetEvent('{event}'" in main, event


def test_main_keeps_every_legacy_nui_callback_name():
    main = read(CLIENT)
    for callback in (
        "closePhone", "enableKeyboard", "disableKeyboard", "getPhoneData",
        "addContact", "deleteContact", "sendMessage", "markMessagesRead",
        "markNotificationsRead", "clearNotifications", "deleteNotification",
        "bankTransfer", "bankDeposit", "bankWithdraw", "setGpsRoute",
        "getNearbyPlayers", "shareContactNearby", "getOwnedVehicles",
        "getHotlineStatus", "triggerHotlineCall", "getAllHotlineStatus",
        "initiateCall", "answerCall", "rejectCall", "hangupCall",
        "queryAutomatedIvr", "acceptJobBoardTask", "postJobBoardTask",
        "sendFactionMessage", "sendSheriffPatrolOrder", "sendGangObjective",
        "getCityFeed", "postCityFeed", "likeCityFeed", "getCallHistory",
        "getMessages", "getPhoneApps", "clientError", "getMyCitations",
        "payCitation",
    ):
        assert f"RegisterNUICallback('{callback}'" in main, callback


def test_core_modules_exist_and_are_referenced_by_main():
    for module in (BRIDGE, FOCUS, EVENTS):
        assert module.is_file(), module
    main = read(CLIENT)
    for symbol in ("PhoneBridge", "PhoneFocus", "PhoneEvents"):
        assert symbol in main, symbol
