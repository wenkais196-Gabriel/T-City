-- client/core/events.lua — unified server → client event channel.
--
-- Server resources may send one event instead of a per-feature event:
--
--   TriggerClientEvent('phone:client:event', src, {
--       type = 'message.new' | 'notification.new' | 'money.update' | ...,
--       app_id = 'police_mdt' | nil,
--       payload = { ... },
--   })
--
-- PhoneEvents.Start() subscribes once; every event is forwarded to the UI as
-- SendNUIMessage({ action = 'phone:event', type, payload, app_id }) and then
-- offered to local PhoneEvents.On(type, fn) subscribers. The legacy
-- phone:client:* handlers in client/main.lua stay registered unchanged, so
-- this module is additive during the migration.
--
-- This file must load before client/main.lua.

PhoneEvents = PhoneEvents or {}

local handlers = {} -- [event_type] = { fn, ... }
local started = false

local function logHandlerError(eventType, err)
    print(('[custom-phone][events] %s handler failed: %s'):format(eventType, tostring(err)))
end

local function dispatch(eventType, payload, appId)
    SendNUIMessage({
        action = 'phone:event',
        type = eventType,
        payload = payload,
        app_id = appId,
    })
    local subscribers = handlers[eventType]
    if not subscribers then return end
    for index = 1, #subscribers do
        local ok, err = pcall(subscribers[index], payload, appId)
        if not ok then logHandlerError(eventType, err) end
    end
end

--- Subscribe to one unified event type.
---@param eventType string e.g. 'notification.new'
---@param fn fun(payload: any, app_id: string|nil)
---@return boolean subscribed
function PhoneEvents.On(eventType, fn)
    if type(eventType) ~= 'string' or eventType == '' or type(fn) ~= 'function' then
        return false
    end
    local subscribers = handlers[eventType]
    if not subscribers then
        subscribers = {}
        handlers[eventType] = subscribers
    end
    subscribers[#subscribers + 1] = fn
    return true
end

--- Remove a previously registered local subscriber.
---@param eventType string
---@param fn function
---@return boolean removed
function PhoneEvents.Off(eventType, fn)
    local subscribers = handlers[eventType]
    if not subscribers then return false end
    for index = #subscribers, 1, -1 do
        if subscribers[index] == fn then
            table.remove(subscribers, index)
            return true
        end
    end
    return false
end

--- Subscribe to the unified channel. Idempotent: repeat calls register nothing.
---@return boolean started
function PhoneEvents.Start()
    if started then return false end
    started = true
    RegisterNetEvent('phone:client:event', function(data)
        if type(data) ~= 'table' then return end
        local eventType = data.type
        if type(eventType) ~= 'string' or eventType == '' then return end
        local appId = data.app_id
        if appId ~= nil and type(appId) ~= 'string' then appId = nil end
        local payload = data.payload
        if payload == nil then payload = {} end
        dispatch(eventType, payload, appId)
    end)
    return true
end

--- Whether the unified channel is subscribed (diagnostics/tests).
---@return boolean
function PhoneEvents.IsStarted()
    return started
end
