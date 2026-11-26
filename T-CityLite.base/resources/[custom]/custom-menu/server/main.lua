--[[
    custom-menu server gate & intent dispatch registry.
    Server is the authority: client disabled hints are ignored and unregistered intents return denied.
]]

local INTENT_COOLDOWN_MS = 200
local serverIntents = {}
local lastIntentAt = {}

local function menuSrvValidId(v, maxLen)
    return type(v) == 'string' and #v > 0 and #v <= (maxLen or 64)
end

local function menuSrvRegisterIntent(intentName, handlerFn, meta)
    if not menuSrvValidId(intentName, 128) then
        return false, 'invalid_intent_name'
    end
    if type(handlerFn) ~= 'function' then
        return false, 'invalid_handler'
    end
    serverIntents[intentName] = {
        handler = handlerFn,
        meta = type(meta) == 'table' and meta or {},
    }
    return true, nil
end

local function menuSrvDispatch(src, payload, skipCooldownCheck)
    if type(src) ~= 'number' or src <= 0 then
        return { ok = false, status = 'denied', reason = 'invalid_source' }
    end
    if type(payload) ~= 'table' then
        return { ok = false, status = 'denied', reason = 'invalid_payload' }
    end

    local menuId = payload.menuId
    local itemId = payload.itemId
    local intent = payload.intent

    if not menuSrvValidId(menuId, 64) or not menuSrvValidId(itemId, 64) or not menuSrvValidId(intent, 128) then
        return {
            ok = false,
            status = 'denied',
            reason = 'missing_menu_item_or_intent',
            menuId = type(menuId) == 'string' and menuId or '',
            itemId = type(itemId) == 'string' and itemId or '',
            intent = type(intent) == 'string' and intent or '',
        }
    end

    if not skipCooldownCheck then
        local now = GetGameTimer()
        local prev = lastIntentAt[src] or 0
        if (now - prev) < INTENT_COOLDOWN_MS then
            return {
                ok = false,
                status = 'denied',
                reason = 'cooldown_active',
                menuId = menuId,
                itemId = itemId,
                intent = intent,
            }
        end
        lastIntentAt[src] = now
    end

    local entry = serverIntents[intent]
    if not entry or type(entry.handler) ~= 'function' then
        return {
            ok = false,
            status = 'denied',
            reason = 'unregistered_intent',
            menuId = menuId,
            itemId = itemId,
            intent = intent,
        }
    end

    -- Server authority: never read/trust payload.disabled; forward only sanitized input payload.
    local ctx = {
        src = src,
        menuId = menuId,
        itemId = itemId,
        intent = intent,
        args = type(payload.args) == 'table' and payload.args or {},
        values = type(payload.values) == 'table' and payload.values or {},
    }
    local callOk, resultOrErr, extraReason = pcall(entry.handler, src, ctx)
    if not callOk then
        print(('[custom-menu] server intent %s handler error (src=%s): %s'):format(intent, tostring(src), tostring(resultOrErr)))
        return {
            ok = false,
            status = 'denied',
            reason = 'handler_error',
            menuId = menuId,
            itemId = itemId,
            intent = intent,
        }
    end
    if resultOrErr == false then
        return {
            ok = false,
            status = 'denied',
            reason = type(extraReason) == 'string' and extraReason or 'handler_denied',
            menuId = menuId,
            itemId = itemId,
            intent = intent,
        }
    end
    return {
        ok = true,
        status = 'accepted',
        menuId = menuId,
        itemId = itemId,
        intent = intent,
    }
end

RegisterNetEvent('custom-menu:server:intent', function(payload)
    local src = source
    if type(src) ~= 'number' or src <= 0 or type(payload) ~= 'table' then
        return
    end
    local now = GetGameTimer()
    local prev = lastIntentAt[src] or 0
    if (now - prev) < INTENT_COOLDOWN_MS then
        TriggerClientEvent('custom-menu:client:intentResult', src, {
            ok = false,
            status = 'denied',
            reason = 'cooldown_active',
            menuId = type(payload.menuId) == 'string' and payload.menuId or '',
            itemId = type(payload.itemId) == 'string' and payload.itemId or '',
            intent = type(payload.intent) == 'string' and payload.intent or '',
        })
        return
    end
    lastIntentAt[src] = now
    local res = menuSrvDispatch(src, payload, true)
    if res.status == 'denied' then
        print(('[custom-menu] denied intent=%s menuId=%s itemId=%s src=%s reason=%s'):format(
            tostring(res.intent),
            tostring(res.menuId),
            tostring(res.itemId),
            tostring(src),
            tostring(res.reason)
        ))
    end
    TriggerClientEvent('custom-menu:client:intentResult', src, res)
end)

-- Local server event only (NOT RegisterNetEvent): sibling server scripts register handlers here.
AddEventHandler('custom-menu:server:registerIntent', function(intentName, handlerFn, meta)
    local ok, err = menuSrvRegisterIntent(intentName, handlerFn, meta)
    if not ok then
        print(('[custom-menu] failed registering server intent %s: %s'):format(tostring(intentName), tostring(err)))
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    if src then
        lastIntentAt[src] = nil
    end
end)

exports('RegisterIntent', menuSrvRegisterIntent)
exports('HasIntent', function(intentName)
    return serverIntents[intentName] ~= nil
end)
exports('HandleIntent', menuSrvDispatch)
