-- server/p0.lua — P0 police dispatch authority (units / incidents / audit).
-- The merged resource keeps qb-policejob's action layer; this file is the
-- single server-side source of truth for on-duty status and call queueing.

local QBCore = exports['qb-core']:GetCoreObject()

local P = {}
local VALID_STATUS = {
    off_duty = true, available = true, busy = true, unavailable = true,
    assigned = true, enroute = true, on_scene = true,
}
local INCIDENT_STATUS = {
    open = true, assigned = true, enroute = true, on_scene = true,
    cleared = true, closed = true,
}
-- SM-02 transition table. `cleared` only exists for rows written before the
-- guard landed; new closes store `closed` directly, so it can only move on to
-- `closed`. A same-status call is an idempotent retry, not a transition.
local INCIDENT_TRANSITIONS = {
    open = { assigned = true, closed = true },
    assigned = { enroute = true, open = true, closed = true },
    enroute = { on_scene = true, assigned = true, closed = true },
    on_scene = { closed = true },
    cleared = { closed = true },
    closed = {},
}
local INCIDENT_DISPOSITIONS = {
    cleared = true, cancelled = true, false_alarm = true, stale = true, arrest = true,
}
-- GetIncidents is a live queue/board read; callers may filter by an active
-- status, but `closed` is never listed (archived calls live in cases/audit).
local INCIDENT_LIST_STATUS = {
    open = true, assigned = true, enroute = true, on_scene = true,
}

local function pd(source)
    local player = QBCore.Functions.GetPlayer(source)
    if not player or type(player.PlayerData) ~= 'table' then return nil end
    return player.PlayerData
end

local function isPolice(data)
    return PolicePolicy.IsPolice(data)
end

local function grade(data)
    return PolicePolicy.Grade(data)
end

local function audit(actorCid, action, target, detail, actorKind)
    local ok = pcall(function()
        MySQL.insert.await(
            'INSERT INTO police_audit (actor_citizenid, actor_kind, action, target, detail) VALUES (?, ?, ?, ?, ?)',
            { actorCid, actorKind or 'player', action, target, detail and tostring(detail):sub(1, 500) or nil }
        )
    end)
    return ok
end

local function trim(v)
    return type(v) == 'string' and v:match('^%s*(.-)%s*$') or ''
end

-- Every duty/unit write goes through one of the helpers below. `assigned`,
-- `enroute` and `on_scene` keep their incident link; every manual state clears
-- it so `incident_id ~= NULL` is only true for task-derived states.
local function upsertUnit(citizenid, callsign, status)
    MySQL.insert.await([[
        INSERT INTO police_units (citizenid, callsign, status) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE callsign = VALUES(callsign), status = VALUES(status),
            incident_id = IF(VALUES(status) IN ('off_duty','available','busy','unavailable'), NULL, incident_id)
    ]], { citizenid, callsign and tostring(callsign):sub(1, 16) or nil, status })
end

local function takeUnitOffDuty(citizenid)
    MySQL.update.await(
        "UPDATE police_units SET status = 'off_duty', incident_id = NULL WHERE citizenid = ?", { citizenid })
end

local function assignUnitRow(citizenid, incidentId)
    MySQL.update.await(
        "UPDATE police_units SET status = 'assigned', incident_id = ? WHERE citizenid = ?", { incidentId, citizenid })
end

local function markIncidentUnits(incidentId, status)
    MySQL.update.await('UPDATE police_units SET status = ? WHERE incident_id = ?', { status, incidentId })
end

-- Clearing an incident releases task-derived units only. A manually busy unit
-- keeps `busy` but loses the stale incident link.
local function releaseIncidentUnits(incidentId)
    MySQL.update.await([[
        UPDATE police_units SET status = 'available', incident_id = NULL
         WHERE incident_id = ? AND status IN ('assigned','enroute','on_scene')
    ]], { incidentId })
    MySQL.update.await([[
        UPDATE police_units SET incident_id = NULL
         WHERE incident_id = ? AND status = 'busy'
    ]], { incidentId })
end

function P.SetUnitStatus(citizenid, callsign, status)
    if not VALID_STATUS[status] then return false, 'invalid_status' end
    local cid = tostring(citizenid or ''):sub(1, 50)
    if cid == '' then return false, 'invalid_citizenid' end
    local player = QBCore.Functions.GetPlayerByCitizenId(cid)
    if status == 'off_duty' then
        if player and isPolice(player.PlayerData) then
            pcall(function() player.Functions.SetJobDuty(false) end)
            if player.PlayerData.job.onduty == true then return false, 'duty_failed' end
        end
    elseif not player then
        -- A system/agent caller may only park an offline citizen.
        return false, 'not_on_duty'
    elseif not isPolice(player.PlayerData) or player.PlayerData.job.onduty ~= true then
        return false, 'not_on_duty'
    end
    upsertUnit(cid, callsign, status)
    audit(cid, 'unit.status', status, nil)
    return true
end

function P.GetUnits()
    local rows = MySQL.query.await('SELECT * FROM police_units ORDER BY citizenid LIMIT 100') or {}
    local names = {}
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local p = QBCore.Functions.GetPlayer(src)
        local d = p and p.PlayerData
        if d then names[d.citizenid] = ('%s %s'):format(
            tostring(d.charinfo and d.charinfo.firstname or '?'),
            tostring(d.charinfo and d.charinfo.lastname or '?')) end
    end
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = {
            citizenid = row.citizenid, name = names[row.citizenid] or '',
            callsign = row.callsign or '', dept = row.dept or 'PATROL',
            status = row.status, incident_id = row.incident_id,
        }
    end
    return { units = out, count = #out }
end

function P.CreateIncident(source, data)
    local creator = pd(source)
    if not creator then return false, 'player_not_found' end
    local title = trim(data and data.title):sub(1, 120)
    if title == '' then return false, 'invalid_title' end
    local code = trim(data and data.code):sub(1, 16)
    if code == '' then code = '911' end
    local priority = tonumber(data and data.priority) or 2
    priority = math.max(1, math.min(3, math.floor(priority)))
    local description = trim(data and data.description):sub(1, 1000)
    local x, y, z = tonumber(data and data.x), tonumber(data and data.y), tonumber(data and data.z)
    local id = MySQL.insert.await([[
        INSERT INTO police_incidents (code, title, description, priority, x, y, z, created_by)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]], { code, title, description, priority, x, y, z, creator.citizenid })
    id = InsertId(id)
    if not id or id == 0 then return false, 'db_error' end
    audit(creator.citizenid, 'incident.create', tostring(id), title)

    local notification = {
        title = ('%s: %s'):format(code, title):sub(1, 200),
        content = description:sub(1, 500),
    }
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local p = QBCore.Functions.GetPlayer(src)
        local d = p and p.PlayerData
        if isPolice(d) and d.job.onduty == true then
            MySQL.insert.await(
                'INSERT INTO phone_notifications (citizenid, title, content, app_id) VALUES (?, ?, ?, ?)',
                { d.citizenid, notification.title, notification.content, 'police_mdt' }
            )
            TriggerClientEvent('phone:client:newNotification', src, {
                id = 0, title = notification.title, content = notification.content,
                timestamp = os.date('%Y-%m-%d %H:%M:%S'), is_read = false,
                app_id = 'police_mdt',
            })
        end
    end
    return { id = tonumber(id), status = 'open' }
end

function P.GetIncidents(status)
    if status ~= nil and status ~= '' then
        if not INCIDENT_LIST_STATUS[status] then return false, 'invalid_status' end
    else
        status = nil
    end
    local rows
    if status then
        rows = MySQL.query.await(
            'SELECT * FROM police_incidents WHERE status = ? ORDER BY priority ASC, id DESC LIMIT 50', { status })
    else
        rows = MySQL.query.await(
            "SELECT * FROM police_incidents WHERE status NOT IN ('closed') ORDER BY priority ASC, id DESC LIMIT 50")
    end
    local incidents = {}
    for _, row in ipairs(rows or {}) do
        incidents[#incidents + 1] = {
            id = tonumber(row.id), code = row.code, title = row.title,
            description = row.description, priority = tonumber(row.priority),
            status = row.status, disposition = row.disposition,
            x = row.x, y = row.y, z = row.z,
            created_at = tostring(row.created_at),
        }
    end
    return { incidents = incidents, count = #incidents }
end

function P.AssignUnit(source, incidentId, targetCitizenId)
    local actor = pd(source)
    if not actor then return false, 'not_police' end
    local allowed, reason = PolicePolicy.Can(actor, 'incident.assign')
    -- Grade 1 officers may claim an open/assigned incident for themselves, but
    -- no one else. Without this path a solo patrol can never go enroute (the
    -- `incident.assign` capability starts at grade 2).
    local selfClaim = false
    if not allowed then
        if reason == 'rank_too_low' and grade(actor) < 2 and actor.job.onduty == true then
            selfClaim = true
        else
            return false, reason
        end
    end
    local id = tonumber(incidentId)
    if not id then return false, 'invalid_incident' end
    local target = tostring(targetCitizenId or ''):sub(1, 50)
    if target == '' then return false, 'invalid_unit' end
    local incident = MySQL.single.await('SELECT id, status FROM police_incidents WHERE id = ?', { id })
    if not incident then return false, 'incident_not_found' end
    if incident.status ~= 'open' and incident.status ~= 'assigned' then
        return false, 'invalid_transition'
    end
    if selfClaim and target ~= actor.citizenid then return false, 'rank_too_low' end
    -- Re-assigning the same, still-active unit is an idempotent retry: no
    -- duplicate row and no duplicate audit entry. An off-duty/available unit
    -- that kept a historical membership row is re-assigned, not skipped.
    local currentAssignment = MySQL.single.await(
        'SELECT status, incident_id FROM police_units WHERE citizenid = ? LIMIT 1', { target })
    local activeStatus = currentAssignment and currentAssignment.status
    if currentAssignment and tonumber(currentAssignment.incident_id) == id
        and (activeStatus == 'assigned' or activeStatus == 'enroute' or activeStatus == 'on_scene') then
        return { id = id, unit = target, status = 'assigned', idempotent = true }
    end
    MySQL.insert.await([[
        INSERT INTO police_incident_units (incident_id, citizenid) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE joined_at = joined_at
    ]], { id, target })
    assignUnitRow(target, id)
    MySQL.update.await(
        "UPDATE police_incidents SET status = 'assigned', last_activity_at = NOW(), updated_at = NOW() WHERE id = ?",
        { id })
    audit(actor.citizenid, 'incident.assign', tostring(id), target)
    return { id = id, unit = target, status = 'assigned' }
end

function P.SetIncidentStatus(source, incidentId, status, disposition, reason)
    local actor = pd(source)
    local allowed, policyReason = PolicePolicy.Can(actor, 'incident.update')
    if not allowed then return false, policyReason end
    if not INCIDENT_STATUS[status] and status ~= 'cancelled' then return false, 'invalid_status' end
    local id = tonumber(incidentId)
    if not id then return false, 'invalid_incident' end

    -- `cleared`/`cancelled` are officer-facing actions; both archive the call.
    local targetStatus = status
    local closeDisposition
    if status == 'cleared' or status == 'cancelled' or status == 'closed' then
        targetStatus = 'closed'
        closeDisposition = trim(disposition):sub(1, 32)
        if closeDisposition == '' then
            closeDisposition = (status == 'cancelled') and 'cancelled' or 'cleared'
        end
        if not INCIDENT_DISPOSITIONS[closeDisposition] then return false, 'invalid_disposition' end
    end

    local incident = MySQL.single.await(
        'SELECT id, status FROM police_incidents WHERE id = ? LIMIT 1', { id })
    if not incident then return false, 'incident_not_found' end

    local assigned = MySQL.single.await(
        'SELECT 1 AS ok FROM police_incident_units WHERE incident_id = ? AND citizenid = ? LIMIT 1',
        { id, actor.citizenid })
    if grade(actor) < 2 and not assigned then return false, 'not_assigned' end

    -- A retried request that already landed is a success, not a transition.
    local currentStatus = tostring(incident.status or '')
    if currentStatus == targetStatus then
        return { id = id, status = targetStatus, idempotent = true }
    end
    local nextStatuses = INCIDENT_TRANSITIONS[currentStatus]
    if not nextStatuses or not nextStatuses[targetStatus] then
        return false, 'invalid_transition'
    end

    if targetStatus == 'closed' then
        local closedReason = trim(reason):sub(1, 255)
        if closedReason == '' then closedReason = nil end
        MySQL.update.await([[
            UPDATE police_incidents
               SET status = 'closed', closed_at = NOW(), disposition = ?, closed_by = ?,
                   closed_reason = ?, last_activity_at = NOW(), updated_at = NOW()
             WHERE id = ?
        ]], { closeDisposition, actor.citizenid, closedReason, id })
        releaseIncidentUnits(id)
        audit(actor.citizenid, 'incident.close', tostring(id), closeDisposition)
        return { id = id, status = 'closed', disposition = closeDisposition }
    end

    MySQL.update.await([[
        UPDATE police_incidents SET status = ?, last_activity_at = NOW(), updated_at = NOW()
         WHERE id = ?
    ]], { targetStatus, id })
    if targetStatus == 'enroute' or targetStatus == 'on_scene' or targetStatus == 'assigned' then
        markIncidentUnits(id, targetStatus)
    elseif targetStatus == 'open' then
        -- Cancelling a dispatch returns the task-derived units to the pool,
        -- while manually busy units stay busy.
        releaseIncidentUnits(id)
    end
    audit(actor.citizenid, 'incident.status', tostring(id), targetStatus)
    return { id = id, status = targetStatus }
end

local function lookupAllowed(source, action, capability)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, capability)
    if not allowed then return nil, reason end
    local ok = audit(actor.citizenid, action, nil, nil)
    if not ok then return nil, 'audit_unavailable' end
    return actor
end

function P.LookupCitizen(source, citizenid)
    local actor, err = lookupAllowed(source, 'lookup.citizen', 'lookup.citizen')
    if not actor then return false, err end
    local cid = tostring(citizenid or ''):sub(1, 50)
    local row = MySQL.single.await(
        'SELECT citizenid, charinfo, job, metadata, last_seen FROM players WHERE citizenid = ? LIMIT 1',
        { cid })
    if not row then return false, 'not_found' end
    local info = row.charinfo
    if type(info) == 'string' then pcall(function() info = json.decode(info) end) end
    info = type(info) == 'table' and info or {}
    local job = row.job
    if type(job) == 'string' then pcall(function() job = json.decode(job) end) end
    job = type(job) == 'table' and job or {}
    local meta = row.metadata
    if type(meta) == 'string' then pcall(function() meta = json.decode(meta) end) end
    meta = type(meta) == 'table' and meta or {}

    -- Three independent wanted sources stay separate so the MDT can label each
    -- one: warrants (long-lived court orders), BOLO tags on reports, and the
    -- live custom-main star level in metadata.wanted. Never merge them into a
    -- single `wants` value.
    local warrants = MySQL.query.await([[
        SELECT id, reason, status, created_at
          FROM police_warrants
         WHERE citizenid = ? AND status IN ('approved','requested')
         ORDER BY id DESC LIMIT 5
    ]], { row.citizenid }) or {}
    local bolo = MySQL.query.await([[
        SELECT id, kind, target, created_at
          FROM police_reports
         WHERE subject_citizenid = ? AND is_bolo = 1
         ORDER BY id DESC LIMIT 5
    ]], { row.citizenid }) or {}

    audit(actor.citizenid, 'lookup.citizen.result', tostring(row.citizenid), nil)
    return {
        citizenid = row.citizenid,
        name = ('%s %s'):format(tostring(info.firstname or '?'), tostring(info.lastname or '?')),
        birthdate = info.birthdate, job = job.name or 'unemployed',
        warrants = warrants, bolo = bolo, active_wanted = meta.wanted,
        last_seen = tostring(row.last_seen or ''),
    }
end

function P.LookupVehicle(source, plate)
    local actor, err = lookupAllowed(source, 'lookup.vehicle', 'lookup.vehicle')
    if not actor then return false, err end
    local normalized = tostring(plate or ''):upper():gsub('%s+', ''):sub(1, 12)
    if normalized == '' then return false, 'invalid_plate' end
    local row = MySQL.single.await(
        'SELECT plate, citizenid, vehicle, state FROM player_vehicles WHERE plate = ? LIMIT 1', { normalized })
    if not row then return false, 'not_found' end
    audit(actor.citizenid, 'lookup.vehicle.result', normalized, nil)
    return { plate = row.plate, citizenid = row.citizenid, model = row.vehicle, state = row.state }
end

function P.GetAudit(source)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'audit.view')
    if not allowed then return false, reason end
    local rows = MySQL.query.await(
        'SELECT actor_citizenid, actor_kind, action, target, detail, created_at FROM police_audit ORDER BY id DESC LIMIT 100'
    ) or {}
    return { rows = rows, count = #rows }
end

-- ---------------------------------------------------------------
-- Sync on-duty state from qb-core (the three duty entry points all hit this)
-- ---------------------------------------------------------------
local function syncDuty(data)
    if not data or type(data.citizenid) ~= 'string' then return end
    local callsign = type(data.metadata) == 'table' and data.metadata.callsign or nil
    if not isPolice(data) then
        -- A prisoner/former officer must not leave a ghost unit behind.
        takeUnitOffDuty(data.citizenid)
        return
    end
    if data.job.onduty ~= true then
        upsertUnit(data.citizenid, callsign, 'off_duty')
        return
    end
    local current = MySQL.single.await(
        'SELECT status FROM police_units WHERE citizenid = ? LIMIT 1', { data.citizenid })
    -- Only a fresh/off-duty unit becomes available. Busy and task-derived
    -- states (assigned/enroute/on_scene) survive job updates untouched.
    if not current or current.status == 'off_duty' then
        upsertUnit(data.citizenid, callsign, 'available')
    end
end

RegisterNetEvent('QBCore:Server:OnJobUpdate', function(source, job)
    local data = pd(source)
    if data and type(job) == 'table' then data.job = job end
    if data then syncDuty(data) end
end)

RegisterNetEvent('QBCore:Server:PlayerLoaded', function(Player)
    if Player and Player.PlayerData then syncDuty(Player.PlayerData) end
end)

-- ---------------------------------------------------------------
-- Drop release + startup sweep (no row is ever deleted, only parked)
-- ---------------------------------------------------------------
local droppingUnits = {}

local function releaseDroppedUnit(citizenid)
    local unit = MySQL.single.await(
        'SELECT incident_id FROM police_units WHERE citizenid = ? LIMIT 1', { citizenid })
    local incidentId = unit and tonumber(unit.incident_id) or nil
    takeUnitOffDuty(citizenid)
    if incidentId then
        local other = MySQL.single.await(
            'SELECT 1 AS ok FROM police_units WHERE incident_id = ? LIMIT 1', { incidentId })
        if not other then
            MySQL.update.await([[
                UPDATE police_incidents SET status = 'open', updated_at = NOW()
                 WHERE id = ? AND status IN ('assigned','enroute','on_scene')
            ]], { incidentId })
            audit(citizenid, 'incident.unassign', tostring(incidentId), 'unit_dropped', 'system')
        end
    end
    audit(citizenid, 'unit.drop', 'off_duty', incidentId and tostring(incidentId) or nil, 'system')
end

local function onPlayerDropped(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or droppingUnits[citizenid] then return end
    droppingUnits[citizenid] = true
    pcall(releaseDroppedUnit, citizenid)
    droppingUnits[citizenid] = nil
end

-- qb-core removes `QBCore.Players[source]` before some resources see the raw
-- `playerDropped` event, so the citizenid is captured from its own event too.
AddEventHandler('QBCore:Server:PlayerDropped', function(Player)
    local data = Player and Player.PlayerData
    if type(data) == 'table' and type(data.citizenid) == 'string' then
        local cid = data.citizenid
        CreateThread(function() onPlayerDropped(cid) end)
    end
end)

AddEventHandler('playerDropped', function()
    local data = pd(source)
    if data and type(data.citizenid) == 'string' then
        local cid = data.citizenid
        CreateThread(function() onPlayerDropped(cid) end)
    end
end)

local function sweepOfflineUnits()
    local online = {}
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local player = QBCore.Functions.GetPlayer(src)
        local data = player and player.PlayerData
        if data and data.citizenid then online[data.citizenid] = true end
    end
    local rows = MySQL.query.await([[
        SELECT citizenid FROM police_units
         WHERE status <> 'off_duty' OR incident_id IS NOT NULL
    ]]) or {}
    for _, row in ipairs(rows) do
        local cid = row.citizenid
        if cid and not online[cid] then
            takeUnitOffDuty(cid)
            audit(cid, 'unit.stale', 'off_duty', 'startup_sweep', 'system')
        end
    end
end

-- Calls with no activity for 45 minutes are abandoned (the unit crashed or
-- went off duty) and are archived. The sweep is bounded so one slow batch can
-- never stall the server, and every incident it touches gets exactly one audit
-- row. Export keeps it directly testable without waiting for the timer.
function SweepStaleIncidents()
    local rows = MySQL.query.await([[
        SELECT id FROM police_incidents
         WHERE status IN ('open','assigned','enroute','on_scene')
           AND COALESCE(last_activity_at, created_at) < NOW() - INTERVAL 45 MINUTE
         ORDER BY id ASC LIMIT 50
    ]]) or {}
    for _, row in ipairs(rows) do
        local id = tonumber(row.id)
        if id then
            MySQL.update.await([[
                UPDATE police_incidents
                   SET status = 'closed', closed_at = NOW(), disposition = 'stale',
                       closed_by = 'system', closed_reason = 'stale_timeout',
                       last_activity_at = NOW(), updated_at = NOW()
                 WHERE id = ? AND status IN ('open','assigned','enroute','on_scene')
            ]], { id })
            releaseIncidentUnits(id)
            audit('system', 'incident.stale', tostring(id), 'stale_timeout', 'system')
        end
    end
    return #rows
end

local function staleSweepLoop()
    Wait(15000)
    while true do
        local ok, err = pcall(SweepStaleIncidents)
        if not ok then print(('[custom-police] stale incident sweep failed: %s'):format(tostring(err))) end
        Wait(60000)
    end
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(10000)
        local ok, err = pcall(sweepOfflineUnits)
        if not ok then print(('[custom-police] startup duty sweep failed: %s'):format(tostring(err))) end
    end)
    CreateThread(staleSweepLoop)
end)

-- ---------------------------------------------------------------
-- Events/commands
-- ---------------------------------------------------------------
RegisterNetEvent('custom-police:server:setStatus', function(status)
    local data = pd(source)
    if not isPolice(data) then return end
    P.SetUnitStatusForSource(source, tostring(status or ''))
end)

RegisterNetEvent('custom-police:server:911', function(payload)
    if type(payload) ~= 'table' then return end
    P.CreateIncident(source, payload)
end)

function P.SetUnitStatusForSource(source, status)
    local data = pd(source)
    if not isPolice(data) then return false, 'not_police' end
    if not VALID_STATUS[status] then return false, 'invalid_status' end
    local callsign = type(data.metadata) == 'table' and data.metadata.callsign or nil
    local player = QBCore.Functions.GetPlayer(source)

    if status == 'off_duty' then
        -- 10-7: qb-core projection first, then the unit row. SetJobDuty raises
        -- OnJobUpdate synchronously; syncDuty is idempotent and never calls
        -- SetJobDuty, so this cannot recurse.
        pcall(function() player.Functions.SetJobDuty(false) end)
        if data.job.onduty == true then return false, 'duty_failed' end
        upsertUnit(data.citizenid, callsign, 'off_duty')
        audit(data.citizenid, 'unit.status', 'off_duty', nil)
        return true
    end

    if status == 'available' then
        -- 10-8 is the one status that turns the qb-core projection on.
        pcall(function() player.Functions.SetJobDuty(true) end)
        if data.job.onduty ~= true then return false, 'duty_failed' end
        upsertUnit(data.citizenid, callsign, 'available')
        audit(data.citizenid, 'unit.status', 'available', nil)
        return true
    end

    -- busy/assigned/enroute/on_scene never change onduty: they require it.
    if data.job.onduty ~= true then return false, 'not_on_duty' end
    upsertUnit(data.citizenid, callsign, status)
    audit(data.citizenid, 'unit.status', status, nil)
    return true
end

exports('SetUnitStatus', P.SetUnitStatus)
exports('SetUnitStatusForSource', P.SetUnitStatusForSource)
exports('GetUnits', P.GetUnits)
exports('CreateIncident', P.CreateIncident)
exports('GetIncidents', P.GetIncidents)
exports('AssignUnit', P.AssignUnit)
exports('SetIncidentStatus', P.SetIncidentStatus)
exports('SweepStaleIncidents', SweepStaleIncidents)
exports('LookupCitizen', P.LookupCitizen)
exports('LookupVehicle', P.LookupVehicle)
exports('GetAudit', P.GetAudit)

print('[custom-police] P0 dispatch layer loaded')
