-- server/qb_phone_compat.lua — qb-phone → custom-phone compatibility layer.
--
-- `[qb]/qb-phone` is not ensured on this server (custom-phone is the only
-- phone that runs), but several enabled resources still call its mail export
-- and its events. This file makes those calls land on the live phone:
--
--   exports['qb-phone']:sendNewMail(source, mail)
--   exports['qb-phone']:sendNewMailToOffline(citizenid, mail)
--   TriggerServerEvent('qb-phone:server:sendNewMail', mail)
--
-- Mails are mapped onto `phone_notifications` (title/content). qb-phone has a
-- separate player_mails table and a mail App; custom-phone does not, so the
-- tray is the compatible surface. qb-phone's `button` field is deliberately
-- dropped: it is an arbitrary table (invoice buttons et al.) and custom-phone
-- has no consumer for it.
--
-- Security model:
--   * The event source is used only to resolve *which* player's tray is
--     written; it never selects another citizenid.
--   * `mail.sender` is display-only and is stripped of markup/control chars.
--   * Every field is type- and length-checked before anything is stored.
--   * `sendNewMailToOffline` requires the citizenid to exist (online or in
--     `players`), so foreign keys cannot be fabricated.
--
-- Loaded before server/main.lua on purpose: the event is registered before
-- the main script starts. Sms (server/sms.lua) and PhoneNotify
-- (server/core/notify.lua, both loaded earlier) are resolved at call time.

local QBCore = exports['qb-core']:GetCoreObject()

local Compat = {}

-- Upper bounds. qb-phone itself performs no validation; these are the limits
-- the notification tray can hold (phone_notifications.title is VARCHAR(200)
-- and the notify core caps content at 1000 characters).
Compat.MAX_SENDER = 64
Compat.MAX_SUBJECT = 120
Compat.MAX_MESSAGE = 2000
Compat.MAX_CITIZENID = 50

--------------------------------------------------------------------------
-- Pure helpers (no FiveM globals touched)
--------------------------------------------------------------------------

--- Strip HTML and normalise control characters. qb-phone mails are written
--- with `<br>`/`<strong>` (qb-cityhall, qb-weapons), but notifications are
--- rendered as plain text by the NUI.
---@param value string
---@return string
local function StripHtml(value)
    -- Block-level tags become line breaks, everything else disappears.
    local text = value:gsub('<%s*[Bb][Rr]%s*/?%s*>', '\n')
    text = text:gsub('<%s*/%s*[Pp]%s*>', '\n')
    text = text:gsub('<[^>]->', '')
    text = text:gsub('&nbsp;', ' ')
    text = text:gsub('&#39;', "'")
    text = text:gsub('&quot;', '"')
    text = text:gsub('&lt;', '<')
    text = text:gsub('&gt;', '>')
    -- Decode ampersands last so "&amp;lt;" cannot turn into "<".
    text = text:gsub('&amp;', '&')
    -- Drop control characters except newlines, then squeeze whitespace.
    text = text:gsub('[%z\1-\9\11\12\14-\31\127]', '')
    text = text:gsub('[ \t]+\n', '\n')
    text = text:gsub('\n\n\n+', '\n\n')
    return text
end

--- Plain-text sender/subject labels: one line, no markup, no control chars.
---@param value string
---@return string
local function CleanLabel(value)
    local text = StripHtml(value):gsub('[\r\n\t]', ' ')
    text = text:gsub('  +', ' ')
    text = text:gsub('^%s+', '')
    return (text:gsub('%s+$', ''))
end

--- Validate an incoming qb-phone mail.
--- Rejects missing/wrong-typed fields and anything over the configured caps;
--- silently truncating user text would hide a broken caller.
---@param mail table|nil
---@return boolean ok, string|nil errCode
function Compat.ValidateMail(mail)
    if type(mail) ~= 'table' then return false, 'invalid_mail' end

    local sender = mail.sender
    if type(sender) ~= 'string' or not sender:match('%S') or #sender > Compat.MAX_SENDER then
        return false, 'invalid_sender'
    end

    local subject = mail.subject
    if type(subject) ~= 'string' or not subject:match('%S') or #subject > Compat.MAX_SUBJECT then
        return false, 'invalid_subject'
    end

    local message = mail.message
    if type(message) ~= 'string' or not message:match('%S') or #message > Compat.MAX_MESSAGE then
        return false, 'invalid_message'
    end

    return true
end

--- Map a qb-phone mail onto a phone_notifications row.
--- title   = "<sender>: <subject>"  (sender is display context, not auth)
--- content = plain-text message, HTML stripped and capped at 1000 chars
--- `mail.button` is intentionally ignored (see header).
---@param mail table
---@return table notification
function Compat.MailToNotification(mail)
    local sender = CleanLabel(mail.sender)
    local subject = CleanLabel(mail.subject)
    local content = StripHtml(mail.message)

    if type(Sms) == 'table' and Sms.TruncateChars then
        content = Sms.TruncateChars(content, 1000)
    end

    return {
        title = ('%s: %s'):format(sender, subject),
        content = content,
    }
end

--- citizenid syntax check: qb-core generates alphanumeric ids; older servers
--- may contain '-'/'_'. Anything else is not a citizenid.
---@param citizenid string|nil
---@return boolean
function Compat.ValidCitizenId(citizenid)
    if type(citizenid) ~= 'string' then return false end
    if #citizenid == 0 or #citizenid > Compat.MAX_CITIZENID then return false end
    return citizenid:match('^[%w_%-]+$') ~= nil
end

function Compat.IsDebug()
    return type(Config) == 'table' and Config.Debug == true
end

function Compat.Log(message)
    if Compat.IsDebug() then
        print('[custom-phone][qb-phone-compat] ' .. message)
    end
end

--------------------------------------------------------------------------
-- IO
--------------------------------------------------------------------------

--- Insert a tray row for a player who is not necessarily online. Mirrors
--- the notify core's SQL/columns so both paths write the same shape.
---@param citizenid string
---@param notification table
local function InsertOfflineNotification(citizenid, notification)
    MySQL.Async.insert(
        'INSERT INTO phone_notifications (citizenid, title, content) VALUES (?, ?, ?)',
        { citizenid, notification.title, notification.content },
        function() end
    )
end

--- Check that a citizenid exists: online first, then the players table.
---@param citizenid string
---@return boolean
function Compat.CitizenExists(citizenid)
    if not Compat.ValidCitizenId(citizenid) then return false end

    if QBCore.Functions.GetPlayerByCitizenId then
        local online = QBCore.Functions.GetPlayerByCitizenId(citizenid)
        if online then return true end
    end

    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT citizenid FROM players WHERE citizenid = ? LIMIT 1',
            { citizenid }
        )
    end)
    return ok and type(rows) == 'table' and rows[1] ~= nil
end

--- Resolve a net-event/export source to an online player.
---@param src any
---@return table|nil Player
---@return string|nil citizenid
local function ResolveSource(src)
    local sourceId = tonumber(src)
    if not sourceId or sourceId <= 0 then return nil, nil end

    local Player = QBCore.Functions.GetPlayer(sourceId)
    if not Player or type(Player.PlayerData) ~= 'table' then return nil, nil end

    local citizenid = Player.PlayerData.citizenid
    if not Compat.ValidCitizenId(citizenid) then return nil, nil end
    return Player, citizenid
end

--- Persist + push one notification to an online player.
--- PhoneNotify is the notify core (same single push, same cache invalidation).
--- It is looked up at call time; the function form is kept for the offline
--- compat harness, the table form is what the loaded resource provides.
---@param Player table
---@param citizenid string
---@param mail table
---@return boolean ok, string|nil errCode
function Compat.DeliverToPlayer(Player, citizenid, mail)
    local valid, err = Compat.ValidateMail(mail)
    if not valid then return false, err end

    local notification = Compat.MailToNotification(mail)
    local src = Player.PlayerData.source
    local notify = PhoneNotify

    if src and type(notify) == 'function' then
        notify(src, notification)
    elseif src and type(notify) == 'table' and type(notify.Store) == 'function' then
        notify.Store(src, notification, 'server')
    else
        InsertOfflineNotification(citizenid, notification)
    end
    return true, nil
end

--------------------------------------------------------------------------
-- qb-phone exports
--------------------------------------------------------------------------

--- qb-phone export (not present upstream in this version, but called by
--- newer consumers): deliver a mail to an online player by server id.
---@param source number server id
---@param mail table {sender, subject, message, button?}
---@return boolean ok, string|nil errCode
exports('sendNewMail', function(source, mail)
    local Player, citizenid = ResolveSource(source)
    if not Player then return false, 'invalid_source' end
    return Compat.DeliverToPlayer(Player, citizenid, mail)
end)

--- qb-phone export: deliver a mail to an offline (or online) citizenid.
--- Used by qb-cityhall (driver-school request) and qb-weapons (repair mail).
---@param citizenid string
---@param mail table {sender, subject, message, button?}
---@return boolean ok, string|nil errCode
exports('sendNewMailToOffline', function(citizenid, mail)
    local valid, err = Compat.ValidateMail(mail)
    if not valid then return false, err end
    if not Compat.CitizenExists(citizenid) then return false, 'unknown_citizenid' end

    local online = QBCore.Functions.GetPlayerByCitizenId and QBCore.Functions.GetPlayerByCitizenId(citizenid)
    if online and type(online.PlayerData) == 'table' then
        return Compat.DeliverToPlayer(online, citizenid, mail)
    end

    InsertOfflineNotification(citizenid, Compat.MailToNotification(mail))
    return true
end)

--------------------------------------------------------------------------
-- qb-phone server events
--------------------------------------------------------------------------
-- Only qb-phone:server:sendNewMail has a server-side variant upstream.
-- Police alerts are server -> client only (`qb-phone:client:addPoliceAlert`)
-- and are bridged in client/main.lua.

-- qb-phone stores this mail on the *sender's own* citizenid (see upstream
-- server/main.lua:771), which is also the safe behaviour here: a client can
-- only fill its own tray. Any citizenid/source field in the payload is
-- ignored; sender is display text and grants nothing.
RegisterNetEvent('qb-phone:server:sendNewMail', function(mail)
    local Player, citizenid = ResolveSource(source)
    if not Player then return end

    local ok, err = Compat.DeliverToPlayer(Player, citizenid, mail)
    if not ok then
        Compat.Log(('rejected qb-phone mail from src=%s (%s)'):format(
            tostring(source), tostring(err)))
    end
end)
