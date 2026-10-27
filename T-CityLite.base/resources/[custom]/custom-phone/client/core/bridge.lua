-- client/core/bridge.lua — NUI registration + request_id transport.
--
-- Two jobs, both previously inlined in client/main.lua:
--
--   1. PhoneBridge.RegisterNui(name, handler) registers a NUI callback through
--      one wrapper, so every handler gets a single-answer guard and a failed
--      handler can never leave CEF's fetch pending forever.
--   2. PhoneBridge.Request(event, payload, cb, timeoutMs) sends a client
--      generated request_id over a dedicated server event and resolves the
--      matching response event exactly once. Duplicate, unknown and late
--      responses are ignored; the default deadline is 8 s and a resource stop
--      answers every pending callback with resource_stopped.
--
-- Response event convention: `phone:server:<name>Request` →
-- `phone:client:<name>Response`. The two current app pairs are:
--   phone:server:appQueryRequest  -> phone:client:appQueryResponse
--   phone:server:appActionRequest -> phone:client:appActionResponse
-- A fifth, optional `responseEvent` argument overrides the convention for
-- future callers that need a different pairing.
--
-- This file must load before client/main.lua.

-- [phone-app-protocol] begin (extracted by test_phone_request_protocol.py)
PhoneBridge = PhoneBridge or {}

local APP_REQUEST_TIMEOUT_MS = 8000
PhoneBridge.TIMEOUT_MS = APP_REQUEST_TIMEOUT_MS

local requestSeq = 0
local pending = {}          -- [request_id] = { cb = fn, response_event = name }
local responseHandlers = {} -- [response_event] = true (RegisterNetEvent once)

--- Correlatable ids must stay inside the server's 3..64 byte bound.
local function nextRequestId()
    requestSeq = requestSeq + 1
    return ('%d:%d'):format(GetGameTimer(), requestSeq)
end

local function defaultResponseEvent(event)
    local name = event:gsub('^phone:server:', 'phone:client:')
    if name:sub(-7) == 'Request' then
        name = name:sub(1, -8) .. 'Response'
    end
    return name
end

--- Trace hooks are optional: bridge.lua must keep working when the diag module is
--- absent (tests, older clients), so every call is a lazy guarded lookup.
local function diagPhase(trace, phase, code)
    if not trace then return end
    local diag = PhoneDiag
    if type(diag) == 'table' and type(diag.Phase) == 'function' then
        diag.Phase(trace, phase, code)
    end
end

--- Resolve one pending request. Unknown ids (forged, duplicated or already
--- timed out) are ignored so a late response can never answer a newer request.
function PhoneBridge.Resolve(id, res)
    if type(id) ~= 'string' then return false end
    local entry = pending[id]
    if not entry then return false end
    pending[id] = nil
    if type(res) ~= 'table' then res = { success = false, error = 'no_response' } end
    diagPhase(entry.trace, 'req.cli.resp', res.error or 'ok')
    entry.cb(res)
    return true
end

local function ensureResponseHandler(responseEvent)
    if responseHandlers[responseEvent] then return end
    responseHandlers[responseEvent] = true
    RegisterNetEvent(responseEvent, function(id, response)
        if type(id) ~= 'string' then return end
        PhoneBridge.Resolve(id, response)
    end)
end

--- Send a request and resolve `cb` exactly once.
---@param event string server request event
---@param payload any JSON-encodable data
---@param cb fun(response: table)
---@param timeoutMs number|nil defaults to 8000
---@param responseEvent string|nil override the derived response event
---@param trace table|nil 诊断 trace；有它时 tid 就是 request_id，服务端ring 才能拼上
---@return string|nil request_id, string|nil response_event
function PhoneBridge.Request(event, payload, cb, timeoutMs, responseEvent, trace)
    if type(event) ~= 'string' or event == '' or type(cb) ~= 'function' then
        if type(cb) == 'function' then cb({ success = false, error = 'bad_request' }) end
        return nil
    end
    timeoutMs = tonumber(timeoutMs)
    if not timeoutMs or timeoutMs <= 0 then timeoutMs = APP_REQUEST_TIMEOUT_MS end

    local id = (trace and trace.tid) or nextRequestId()
    local resolvedEvent = responseEvent or defaultResponseEvent(event)
    ensureResponseHandler(resolvedEvent)

    pending[id] = { cb = cb, response_event = resolvedEvent, trace = trace }
    TriggerServerEvent(event, id, payload)
    SetTimeout(timeoutMs, function()
        -- A response (or Clear) removes the slot first, so this timer can never
        -- answer twice or resolve a newer request.
        local entry = pending[id]
        if not entry or entry.cb ~= cb then return end
        pending[id] = nil
        cb({ success = false, error = 'timeout' })
    end)
    return id, resolvedEvent
end

--- Answer every in-flight request (resource stop / manual recovery) once.
---@param reason string|nil defaults to resource_stopped
---@return integer answered
function PhoneBridge.Clear(reason)
    reason = reason or 'resource_stopped'
    local ids = {}
    for id in pairs(pending) do ids[#ids + 1] = id end
    local answered = 0
    for _, id in ipairs(ids) do
        local entry = pending[id]
        if entry then
            pending[id] = nil
            answered = answered + 1
            pcall(entry.cb, { success = false, error = reason })
        end
    end
    return answered
end

-- SendNUIMessage has no acknowledgement. A message sent while CEF is (re)loading
-- the page is silently dropped, which leaves the phone "open" in Lua with no UI
-- on screen — the failure we hit after every `restart custom-phone`. AwaitAck
-- resends until the NUI answers Ack(name); that answer is the only proof the
-- interface actually exists.
local ackWaiters = {} -- [name] = entry

--- Send now, then keep resending until Ack(name) or the deadline.
--- A second call for the same name supersedes the first without firing its
--- timeout, so reopening the phone cannot leave two loops running.
---@param name string ack channel, e.g. 'phone:open'
---@param resend fun() sends one copy of the payload
---@param opts table|nil { intervalMs = 250, timeoutMs = 2500, onTimeout = fun() }
---@return table|nil waiter handle
function PhoneBridge.AwaitAck(name, resend, opts)
    if type(name) ~= 'string' or name == '' or type(resend) ~= 'function' then
        return nil
    end
    opts = opts or {}
    local interval = tonumber(opts.intervalMs) or 250
    if interval <= 0 then interval = 250 end
    local deadline = tonumber(opts.timeoutMs) or 2500

    local entry = { name = name }
    ackWaiters[name] = entry -- supersedes a previous attempt; its tick self-cancels
    resend()

    local elapsed = 0
    local function tick()
        if ackWaiters[name] ~= entry then return end -- acked, replaced or expired
        elapsed = elapsed + interval
        if elapsed >= deadline then
            ackWaiters[name] = nil
            print(('[custom-phone][bridge] %s unacked after %dms'):format(name, elapsed))
            if type(opts.onTimeout) == 'function' then pcall(opts.onTimeout) end
            return
        end
        resend()
        SetTimeout(interval, tick)
    end
    SetTimeout(interval, tick)
    return entry
end

--- Mark `name` as acknowledged by the NUI.
---@param name string
---@return boolean consumed false when nothing was waiting (late or forged ack)
function PhoneBridge.Ack(name)
    if type(name) ~= 'string' then return false end
    if not ackWaiters[name] then return false end
    ackWaiters[name] = nil
    return true
end

--- Diagnóstico: is `name` still waiting for its NUI ack?
---@param name string
---@return boolean
function PhoneBridge.IsAwaitingAck(name)
    return ackWaiters[name] ~= nil
end

--- Wrap a callback so a handler that calls cb twice cannot corrupt CEF state.
local function answerOnce(cb)
    local answered = false
    return function(result)
        if answered then return end
        answered = true
        cb(result)
    end
end

--- Normalise the NUI answer channel.
---
--- Some FXServer builds hand RegisterNUICallback's `cb` over as a CFX *function
--- reference* (`{ __cfx_functionReference = '<ref>' }`) instead of a plain
--- function. Calling such a table raises "attempt to call a table value", and
--- bailing out without answering leaves the NUI fetch pending until its abort
--- deadline — exactly the 9s `AbortError` that made appQuery/appAction look
--- "查询失败" while the plain callbacks (which call cb directly) kept working.
---@param cb any
---@return fun(response: any)|nil answer nil when the channel cannot be answered
function PhoneBridge.AnswerFn(cb)
    local kind = type(cb)
    if kind == 'function' then return cb end
    if kind == 'table' then
        -- 首选 __call 元方法：CFX 的函数引用对象是可调用的表，直接调用就是
        -- 官方语义，NUI 侧才会真的收到响应。
        local mt = getmetatable(cb)
        if mt and type(rawget(mt, '__call')) == 'function' then
            return function(response) return cb(response) end
        end
        local ref = rawget(cb, '__cfx_functionReference')
        if type(ref) == 'string' and ref ~= '' then
            local citizen = Citizen
            if type(citizen) == 'table' and type(citizen.InvokeFunctionReference) == 'function' then
                return function(response)
                    citizen.InvokeFunctionReference(ref, response)
                end
            end
        end
    end
    return nil
end

--- Register a NUI callback through the shared guard.
---@param name string callback name used by the NUI fetchNui()
---@param handler fun(data: any, cb: fun(response: table))
---@return boolean registered
function PhoneBridge.RegisterNui(name, handler)
    if type(name) ~= 'string' or name == '' or type(handler) ~= 'function' then
        return false
    end
    RegisterNUICallback(name, function(data, cb)
        local answer = PhoneBridge.AnswerFn(cb)
        if not answer then
            print(('[custom-phone][bridge] NUI %s: unanswerable callback (%s)'):format(
                tostring(name), type(cb)))
            return
        end
        local once = answerOnce(answer)
        local ok, err = pcall(handler, data, once)
        if not ok then
            print(('[custom-phone][bridge] NUI %s failed: %s'):format(name, tostring(err)))
            once({ success = false, error = 'handler_error' })
        end
    end)
    return true
end

-- A resource stop drops the Lua state; answer outstanding NUI callbacks first
-- so CEF is not left with fetches that can only end in their own timeout.
local function clearPendingOnStop(resource)
    if resource ~= GetCurrentResourceName() then return end
    PhoneBridge.Clear('resource_stopped')
end
AddEventHandler('onResourceStop', clearPendingOnStop)
AddEventHandler('onClientResourceStop', clearPendingOnStop)
-- [phone-app-protocol] end
