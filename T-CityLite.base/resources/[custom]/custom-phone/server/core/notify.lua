-- server/core/notify.lua — notification normalisation, persistence and push.
--
-- Owns the `phone_notifications` write path. Loaded after server/sms.lua (for
-- Sms/PhoneDb) and server/core/events.lua (for the unified event), and before
-- server/main.lua so every caller (main, faction, jobboard, banking,
-- qb_phone_compat) sees the same singleton. QBCore itself is resolved lazily
-- through its export, so nothing here depends on main.lua's local QBCore.
--
-- The per-player phoneDataCache lives in main.lua; main registers an
-- invalidator after declaring it, so a notification write still evicts the
-- cached tray exactly once.

local cacheInvalidator

local cachedCore

---@return table|nil
local function getCore()
    if cachedCore then return cachedCore end
    local ok, core = pcall(function()
        return exports['qb-core']:GetCoreObject()
    end)
    if ok and core then cachedCore = core end
    return cachedCore
end

---@param citizenid string
local function invalidateCache(citizenid)
    if cacheInvalidator then cacheInvalidator(citizenid) end
end

-- ----------------------------------------------------
-- Notification persistence
-- ----------------------------------------------------
-- Only app ids that the notification tray can deep-link into are persisted.
-- An unknown value becomes NULL instead of creating a broken dynamic-app
-- target, and every caller goes through the same allowlist (FIT-02).
local NOTIFY_APP_IDS = {
    banking = true,
    police_mdt = true,
}

--- Normalise the persisted part of a notification once, so Store, the Notify
--- export and the push all use the same truncation + app_id rules.
---@param notification table
---@return table
local function NormaliseNotification(notification)
    notification = type(notification) == 'table' and notification or {}
    local title = type(notification.title) == 'string' and notification.title or 'Notification'
    local content = type(notification.content) == 'string' and notification.content or ''
    local appId = type(notification.app_id) == 'string' and notification.app_id:match('^[a-z0-9_]+$') or nil
    if appId and (not NOTIFY_APP_IDS[appId] or #appId > 32) then appId = nil end
    return {
        title = Sms.TruncateBytes(title, 200),
        content = Sms.TruncateChars(content, 1000),
        app_id = appId,
    }
end

--- Push a persisted row to an online target exactly once.
--- The legacy `phone:client:newNotification` event is kept until the NUI
--- consumes the unified `phone:client:event`; both carry the same row.
local function PushStoredNotification(targetSrc, notification, id)
    local timestamp = os.date('%Y-%m-%d %H:%M:%S')

    TriggerClientEvent('phone:client:newNotification', targetSrc, {
        id = id,
        title = notification.title,
        content = notification.content,
        timestamp = timestamp,
        is_read = false,
        origin = 'server',
        app_id = notification.app_id,
    })

    PhoneEvents.Push(targetSrc, 'notification.new', {
        id = id,
        title = notification.title,
        content = notification.content,
        timestamp = timestamp,
        is_read = false,
        origin = 'server',
    }, notification.app_id)
end

-- Server-originated notifications are persisted here and pushed exactly once.
-- Client-originated storeNotification requests are persisted without pushing
-- back to the sender, which is what breaks the
-- phone:client:newNotification -> phone:server:storeNotification loop.
PhoneNotify = {}

--- Persist one notification and push it once unless it came from the client.
---@param targetSrc number
---@param notification table
---@param origin string|nil  'server' (default) or 'client'
---@return boolean accepted  false when the player/notification is invalid
function PhoneNotify.Store(targetSrc, notification, origin)
    if type(notification) ~= 'table' then return false end

    local core = getCore()
    if not core or type(core.Functions) ~= 'table' then return false end
    local Player = core.Functions.GetPlayer(targetSrc)
    if not Player or type(Player.PlayerData) ~= 'table' then return false end

    local citizenid = Player.PlayerData.citizenid
    if not citizenid then return false end

    local normalised = NormaliseNotification(notification)
    MySQL.Async.insert('INSERT INTO phone_notifications (citizenid, title, content, app_id) VALUES (?, ?, ?, ?)', {
        citizenid, normalised.title, normalised.content, normalised.app_id
    }, function(result)
        local id = PhoneDb.InsertId(result)
        if id <= 0 then return end

        invalidateCache(citizenid)

        -- A client-originated row came from that client's own notification
        -- tray. Pushing it back would make the client persist it again.
        if origin == 'client' then return end

        PushStoredNotification(targetSrc, normalised, id)
    end)

    return true
end

--- main.lua passes its cache invalidator here; keeps notify.lua free of the
--- cache implementation while preserving Store's one-eviction behaviour.
---@param fn function|nil
function PhoneNotify.SetCacheInvalidator(fn)
    cacheInvalidator = type(fn) == 'function' and fn or nil
end

-- Backwards-compatible call shape: existing callers use PhoneNotify(src, n).
setmetatable(PhoneNotify, {
    __call = function(_, targetSrc, notification)
        return PhoneNotify.Store(targetSrc, notification, 'server')
    end,
})

--- owner export for `phone_notifications` (FIT-02).
---
--- Persist a notification for a citizen (online or offline) and push it once
--- when they are online. This is the only write path other resources may use;
--- it reuses the same normalisation/allowlist as Store so a caller cannot
--- bypass the truncation or the cache invalidation.
---
--- `meta` is optional: `source` skips the citizenid lookup when the caller
--- already knows the online player, `app_id` is used when `appId` is nil.
---@param citizenid string
---@param title string
---@param content string
---@param appId string|nil
---@param meta table|nil
---@return boolean ok, number|nil id
exports('Notify', function(citizenid, title, content, appId, meta)
    if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 50 then return false end
    if title ~= nil and type(title) ~= 'string' then return false end
    if content ~= nil and type(content) ~= 'string' then return false end
    meta = type(meta) == 'table' and meta or {}
    if appId == nil and type(meta.app_id) == 'string' then appId = meta.app_id end

    local normalised = NormaliseNotification({ title = title, content = content, app_id = appId })
    local targetSrc = tonumber(meta.source)
    local core = getCore()
    if not targetSrc and core and type(core.Functions) == 'table' then
        local Player = core.Functions.GetPlayerByCitizenId(citizenid)
        targetSrc = Player and Player.PlayerData.source or nil
    end

    -- await (not Async) so the outbox worker can tell a failed insert from a
    -- persisted one; the caller is always inside a thread/coroutine.
    local wrote, id = pcall(function()
        local result = MySQL.insert.await(
            'INSERT INTO phone_notifications (citizenid, title, content, app_id) VALUES (?, ?, ?, ?)',
            { citizenid, normalised.title, normalised.content, normalised.app_id })
        return PhoneDb.InsertId(result)
    end)
    if not wrote or not id or id <= 0 then return false end

    invalidateCache(citizenid)
    if targetSrc and targetSrc > 0 then
        PushStoredNotification(targetSrc, normalised, id)
    end
    return true, id
end)
