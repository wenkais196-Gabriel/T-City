-- server/core/events.lua — unified server -> phone UI event channel.
--
-- During the migration each caller keeps sending its legacy client event and
-- also calls PhoneEvents.Push; once an app consumes `phone:client:event` the
-- legacy event can be removed. The payload contract is documented in
-- docs/client/PHONE_ARCHITECTURE.md §3.

PhoneEvents = {}

--- Push one event to a single player's phone UI.
---@param src number
---@param eventType string
---@param payload table|nil
---@param appId string|nil
---@return boolean pushed
function PhoneEvents.Push(src, eventType, payload, appId)
    if type(src) ~= 'number' or type(eventType) ~= 'string' or eventType == '' then
        return false
    end

    TriggerClientEvent('phone:client:event', src, {
        type = eventType,
        app_id = appId,
        payload = type(payload) == 'table' and payload or {},
        ts = os.time(),
    })
    return true
end
