-- sentence.lua — server-authoritative custody sentences (`justice_sentences`).
--
-- The qb-prison client clock is presentation only. Every sentence here is
-- measured by the database clock (`ends_at`), so offline time counts and a
-- client cannot shorten its own sentence by sending a fake jail time.

local QBCore = exports['qb-core']:GetCoreObject()

JusticeSentences = {}

local MAX_CASE_ID = 32
local MAX_REASON = 255

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function validCitizenid(citizenid)
    citizenid = tostring(citizenid or '')
    return #citizenid > 0 and #citizenid <= 50, citizenid
end

local function trimTo(value, limit)
    if value == nil then return nil end
    value = tostring(value)
    if #value == 0 then return nil end
    if #value > limit then value = value:sub(1, limit) end
    return value
end

--- The bundled oxmysql build returns `{ affectedRows = n }` for update; stock
--- builds return a number. Normalise both so "row was actually transitioned"
--- checks are reliable.
local function affectedRows(result)
    if type(result) == 'number' then return result end
    if type(result) == 'table' then return math.floor(tonumber(result.affectedRows) or 0) end
    return 0
end

--- Remaining seconds for the newest active sentence, measured by MySQL.
--- Returns 0 when the citizen has no active sentence.
function JusticeSentences.RemainingSeconds(citizenid)
    local ok, cid = validCitizenid(citizenid)
    if not ok then return 0 end
    local row = MySQL.single.await(
        [[SELECT GREATEST(0, TIMESTAMPDIFF(SECOND, NOW(), ends_at)) AS remaining_seconds
          FROM justice_sentences
          WHERE citizenid = ? AND status = 'active'
          ORDER BY id DESC LIMIT 1]], { cid })
    if not row then return 0 end
    return math.max(0, math.floor(tonumber(row.remaining_seconds) or 0))
end

--- Active sentence row or nil. `remaining_seconds` is included for callers that
--- want to project the sentence without a second round trip.
function JusticeSentences.Get(citizenid)
    local ok, cid = validCitizenid(citizenid)
    if not ok then return nil end
    local rows = MySQL.query.await(
        [[SELECT id, citizenid, case_id, minutes, reason, status, started_at, ends_at,
                 released_at, created_by,
                 GREATEST(0, TIMESTAMPDIFF(SECOND, NOW(), ends_at)) AS remaining_seconds
          FROM justice_sentences
          WHERE citizenid = ? AND status = 'active'
          ORDER BY id DESC LIMIT 1]], { cid })
    return rows and rows[1] or nil
end

local function remainingMinutesFor(citizenid)
    local seconds = JusticeSentences.RemainingSeconds(citizenid)
    return math.max(0, math.ceil(seconds / 60))
end

-- ---------------------------------------------------------------------------
-- Write path
-- ---------------------------------------------------------------------------

--- Create or adjust the active sentence for a citizen.
---
--- mode='set' replaces the remaining time (`ends_at = NOW() + minutes`), which
--- is what a trial/plea verdict must do. mode='add' extends the current
--- `ends_at`, which is what an additional arrest does.
---
--- @param citizenid string
--- @param minutes number
--- @param caseId string|nil
--- @param reason string|nil
--- @param mode 'set'|'add'|nil
--- @param createdBy string|nil
--- @return number remainingMinutes, string|nil error
function JusticeSentences.Apply(citizenid, minutes, caseId, reason, mode, createdBy)
    local ok, cid = validCitizenid(citizenid)
    if not ok then return 0, 'invalid_citizen' end

    minutes = math.floor(tonumber(minutes) or 0)
    if minutes <= 0 then return 0, 'invalid_minutes' end

    mode = tostring(mode or 'add'):lower()
    if mode ~= 'set' and mode ~= 'add' then return 0, 'invalid_mode' end

    caseId = trimTo(caseId, MAX_CASE_ID)
    reason = trimTo(reason, MAX_REASON)
    createdBy = trimTo(createdBy, 50)

    local affected
    if mode == 'set' then
        affected = MySQL.update.await(
            [[UPDATE justice_sentences
              SET ends_at = DATE_ADD(NOW(), INTERVAL ? MINUTE),
                  minutes = ?,
                  case_id = ?,
                  reason = ?
              WHERE citizenid = ? AND status = 'active']],
            { minutes, minutes, caseId, reason, cid })
    else
        affected = MySQL.update.await(
            [[UPDATE justice_sentences
              SET ends_at = DATE_ADD(ends_at, INTERVAL ? MINUTE),
                  minutes = minutes + ?
              WHERE citizenid = ? AND status = 'active']],
            { minutes, minutes, cid })
    end

    -- Broken active row (or none yet): start a new sentence. This is a single
    -- statement per branch; the bundled oxmysql build has no transactions.
    if affectedRows(affected) == 0 then
        MySQL.insert.await(
            [[INSERT INTO justice_sentences
                (citizenid, case_id, minutes, reason, status, started_at, ends_at, created_by)
              VALUES (?, ?, ?, ?, 'active', NOW(), DATE_ADD(NOW(), INTERVAL ? MINUTE), ?)]],
            { cid, caseId, minutes, reason, minutes, createdBy })
    end

    return remainingMinutesFor(cid)
end

--- Close the active sentence. Returns true only when a row was transitioned,
--- so callers can rely on it for idempotency.
function JusticeSentences.Release(citizenid, reason, status)
    local ok, cid = validCitizenid(citizenid)
    if not ok then return false end
    status = (status == 'expired') and 'expired' or 'released'

    local affected = MySQL.update.await(
        [[UPDATE justice_sentences
          SET status = ?, released_at = NOW()
          WHERE citizenid = ? AND status = 'active']],
        { status, cid })
    if affectedRows(affected) == 0 then return false end

    print(('[justice-sentences] released %s (%s)%s'):format(
        cid, status, reason and (' — ' .. tostring(reason)) or ''))
    return true
end

--- Expire every sentence whose server-side clock ran out, then push the
--- online inmates out of the cell and clear their metadata projection.
--- Returns the number of expired rows.
function JusticeSentences.ExpireSweep()
    local rows = MySQL.query.await(
        [[SELECT DISTINCT citizenid FROM justice_sentences
          WHERE status = 'active' AND ends_at <= NOW()]], {}) or {}
    if #rows == 0 then return 0 end

    local affected = affectedRows(MySQL.update.await(
        [[UPDATE justice_sentences
          SET status = 'expired', released_at = NOW()
          WHERE status = 'active' AND ends_at <= NOW()]], {}))

    for _, row in ipairs(rows) do
        local cid = row.citizenid
        if cid and JusticeService and JusticeService.Inmates then
            JusticeService.Inmates[cid] = nil
        end

        local Player = QBCore.Functions.GetPlayerByCitizenId(cid)
        if Player then
            local src = Player.PlayerData.source
            pcall(function() Player.Functions.SetMetaData('injail', 0) end)
            if GetResourceState('qb-prison') == 'started' then
                TriggerClientEvent('prison:client:UnjailPerson', src)
            else
                TriggerClientEvent('justice:client:released', src)
            end
        end
    end

    if affected > 0 then
        print(('[justice-sentences] expire sweep released %d sentence(s)'):format(affected))
    end
    return affected
end

-- ---------------------------------------------------------------------------
-- Startup sweep + 15s loop
-- ---------------------------------------------------------------------------

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(1000)
        local ok, result = pcall(JusticeSentences.ExpireSweep)
        if not ok then
            print(('[justice-sentences] startup sweep failed: %s'):format(tostring(result)))
        end
    end)
end)

CreateThread(function()
    Wait(5000)
    while true do
        -- Never let a transient DB error kill the custody clock.
        local ok, result = pcall(JusticeSentences.ExpireSweep)
        if not ok then
            print(('[justice-sentences] expire sweep failed: %s'):format(tostring(result)))
        end
        Wait(15000)
    end
end)

-- ---------------------------------------------------------------------------
-- Exports (qb-prison and caller resources use these)
-- ---------------------------------------------------------------------------

exports('GetSentence', function(citizenid)
    return JusticeSentences.Get(citizenid)
end)

exports('RemainingSeconds', function(citizenid)
    return JusticeSentences.RemainingSeconds(citizenid)
end)

exports('ApplySentence', function(citizenid, minutes, caseId, reason, mode, createdBy)
    return JusticeSentences.Apply(citizenid, minutes, caseId, reason, mode, createdBy)
end)

exports('ReleaseSentence', function(citizenid, reason, status)
    return JusticeSentences.Release(citizenid, reason, status)
end)
