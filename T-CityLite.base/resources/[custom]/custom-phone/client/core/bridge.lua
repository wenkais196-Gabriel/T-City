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

--- Resolve one pending request. Unknown ids (forged, duplicated or already
--- timed out) are ignored so a late response can never answer a newer request.
function PhoneBridge.Resolve(id, res)
    if type(id) ~= 'string' then return false end
    local entry = pending[id]
    if not entry then return false end
    pending[id] = nil
    if type(res) ~= 'table' then res = { success = false, error = 'no_response' } end
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
---@return string|nil request_id, string|nil response_event
function PhoneBridge.Request(event, payload, cb, timeoutMs, responseEvent)
    if type(event) ~= 'string' or event == '' or type(cb) ~= 'function' then
        if type(cb) == 'function' then cb({ success = false, error = 'bad_request' }) end
        return nil
    end
    timeoutMs = tonumber(timeoutMs)
    if not timeoutMs or timeoutMs <= 0 then timeoutMs = APP_REQUEST_TIMEOUT_MS end

    local id = nextRequestId()
    local resolvedEvent = responseEvent or defaultResponseEvent(event)
    ensureResponseHandler(resolvedEvent)

    pending[id] = { cb = cb, response_event = resolvedEvent }
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

--- Wrap a callback so a handler that calls cb twice cannot corrupt CEF state.
local function answerOnce(cb)
    local answered = false
    return function(result)
        if answered then return end
        answered = true
        cb(result)
    end
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
        if type(cb) ~= 'function' then return end
        local answer = answerOnce(cb)
        local ok, err = pcall(handler, data, answer)
        if not ok then
            print(('[custom-phone][bridge] NUI %s failed: %s'):format(name, tostring(err)))
            answer({ success = false, error = 'handler_error' })
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
