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

--- Notifications are owned by custom-phone (FIT-02). Enqueue through the outbox
--- in p2_system (loaded later, so the global is resolved at call time); fall
--- back to the owner export only if that layer is missing.
local function notifyOfficer(citizenid, title, content, appId)
    local payload = { citizenid = citizenid, title = title, content = content, app_id = appId }
    if type(Outbox) == 'table' and type(Outbox.Enqueue) == 'function' then
        return Outbox.Enqueue('notification', payload)
    end
    pcall(function()
        exports['custom-phone']:Notify(citizenid, title, content, appId)
    end)
    return false
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
            -- FIT-01: job.onduty is owned by the duty service below. An
            -- offline citizen has no live player to project, so that branch
            -- still writes the unit row only.
            local ok, err = P.SetDutyForSource(player.PlayerData.source, false, 'unit_status')
            if not ok then return false, err or 'duty_failed' end
        end
    elseif not player then
        -- A system/agent caller may only park an offline citizen.
        return false, 'not_on_duty'
    elseif not isPolice(player.PlayerData) or player.PlayerData.job.onduty ~= true then
        return false, 'not_on_duty'
    end
    upsertUnit(cid, callsign, status)
    if not audit(cid, 'unit.status', status, nil) then
        print(('[custom-police] unit.status audit failed for %s'):format(tostring(cid)))
    end
    return true
end

--- Live unit board. The rows carry citizenid + display name, so this is a
--- capability-gated sensitive read: the `units.view` audit row must land
--- before the SELECT, and a failed audit refuses the listing.
---@param source number requesting officer source
function P.GetUnits(source)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'units.view')
    if not allowed then return false, reason end
    if not audit(actor.citizenid, 'units.view', nil, nil) then
        return false, 'audit_unavailable'
    end
    local rows = MySQL.query.await(
        'SELECT citizenid, callsign, dept, status, incident_id FROM police_units ORDER BY citizenid LIMIT 100') or {}
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
    if not audit(creator.citizenid, 'incident.create', tostring(id), title) then
        print(('[custom-police] incident.create audit failed for #%s'):format(tostring(id)))
    end

    local notification = {
        title = ('%s: %s'):format(code, title):sub(1, 200),
        content = description:sub(1, 500),
    }
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local p = QBCore.Functions.GetPlayer(src)
        local d = p and p.PlayerData
        if isPolice(d) and d.job.onduty == true then
            notifyOfficer(d.citizenid, notification.title, notification.content, 'police_mdt')
        end
    end
    return { id = tonumber(id), status = 'open' }
end

--- Live incident queue. Descriptions/locations are sensitive operational data,
--- so the read requires `incident.update` (the existing board capability; the
--- policy table has no incident.view) and writes an `incident.view` audit row
--- before the SELECT. A failed audit refuses the listing.
---@param source number requesting officer source
---@param status string|nil optional active-status filter
function P.GetIncidents(source, status)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'incident.update')
    if not allowed then return false, reason end
    if status ~= nil and status ~= '' then
        if not INCIDENT_LIST_STATUS[status] then return false, 'invalid_status' end
    else
        status = nil
    end
    if not audit(actor.citizenid, 'incident.view', tostring(status or 'active'), nil) then
        return false, 'audit_unavailable'
    end
    local rows
    if status then
        rows = MySQL.query.await(
            'SELECT id, code, title, description, priority, status, disposition, npc_template, x, y, z, created_at FROM police_incidents WHERE status = ? ORDER BY priority ASC, id DESC LIMIT 50', { status })
    else
        rows = MySQL.query.await(
            "SELECT id, code, title, description, priority, status, disposition, npc_template, x, y, z, created_at FROM police_incidents WHERE status NOT IN ('closed') ORDER BY priority ASC, id DESC LIMIT 50")
    end
    local incidents = {}
    for _, row in ipairs(rows or {}) do
        incidents[#incidents + 1] = {
            id = tonumber(row.id), code = row.code, title = row.title,
            description = row.description, priority = tonumber(row.priority),
            status = row.status, disposition = row.disposition, npc_template = row.npc_template,
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
    local incident = MySQL.single.await('SELECT id, status FROM police_incidents WHERE id = ? LIMIT 1', { id })
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
    if not audit(actor.citizenid, 'incident.assign', tostring(id), target) then
        print(('[custom-police] incident.assign audit failed for #%s'):format(tostring(id)))
    end
    return { id = id, unit = target, status = 'assigned' }
end

--- System/agent assignment path (no player source). Kept next to
--- P.AssignUnit so agent actions cannot bypass the SM-01/SM-02 write helpers.
function P.AssignUnitSystem(incidentId, targetCitizenId, actorCitizenId)
    local id = tonumber(incidentId)
    if not id then return false, 'invalid_incident' end
    local target = tostring(targetCitizenId or ''):sub(1, 50)
    if target == '' then return false, 'invalid_unit' end
    local incident = MySQL.single.await(
        'SELECT id, status FROM police_incidents WHERE id = ? LIMIT 1', { id })
    if not incident then return false, 'incident_not_found' end
    if incident.status ~= 'open' and incident.status ~= 'assigned' then
        return false, 'invalid_transition'
    end
    local currentAssignment = MySQL.single.await(
        'SELECT status, incident_id FROM police_units WHERE citizenid = ? LIMIT 1', { target })
    if not currentAssignment then return false, 'unit_not_found' end
    if currentAssignment.status == 'off_duty' then return false, 'unit_off_duty' end
    if tonumber(currentAssignment.incident_id) == id
        and (currentAssignment.status == 'assigned' or currentAssignment.status == 'enroute'
             or currentAssignment.status == 'on_scene') then
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
    if not audit(actorCitizenId or 'system', 'incident.assign', tostring(id), target) then
        print(('[custom-police] incident.assign audit failed for #%s'):format(tostring(id)))
    end
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
        if not audit(actor.citizenid, 'incident.close', tostring(id), closeDisposition) then
            print(('[custom-police] incident.close audit failed for #%s'):format(tostring(id)))
        end
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
    if not audit(actor.citizenid, 'incident.status', tostring(id), targetStatus) then
        print(('[custom-police] incident.status audit failed for #%s'):format(tostring(id)))
    end
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

    if not audit(actor.citizenid, 'lookup.citizen.result', tostring(row.citizenid), nil) then
        print(('[custom-police] lookup.citizen.result audit failed for %s'):format(tostring(row.citizenid)))
    end
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
    if not audit(actor.citizenid, 'lookup.vehicle.result', normalized, nil) then
        print(('[custom-police] lookup.vehicle.result audit failed for %s'):format(tostring(normalized)))
    end
    return { plate = row.plate, citizenid = row.citizenid, model = row.vehicle, state = row.state }
end

function P.GetAudit(source)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'audit.view')
    if not allowed then return false, reason end
    -- FIT-05: reading the forensic log is itself a sensitive read. Write the
    -- row with the same direct INSERT (never by calling GetAudit, which would
    -- recurse) and refuse the listing when the write fails.
    if not audit(actor.citizenid, 'audit.view', 'police_audit', nil) then
        return false, 'audit_unavailable'
    end
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

-- FIT-01: the single police duty writer. 10-8/10-7, /duty's quick command and
-- custom-director's set_job_duty on a police target all come through here.
-- qb-core's SetJobDuty stays the primitive projection: it returns nothing, so
-- the value is read back from PlayerData.job.onduty, then projected through
-- syncDuty and audited as `duty.set`.
function P.SetDutyForSource(source, onDuty, reason)
    local data = pd(source)
    if not isPolice(data) then return false, 'not_police' end
    if onDuty ~= true and onDuty ~= false then return false, 'duty_failed' end
    local player = QBCore.Functions.GetPlayer(source)
    if not player then return false, 'not_police' end

    local ok = pcall(function() player.Functions.SetJobDuty(onDuty) end)
    if not ok or data.job.onduty ~= onDuty then return false, 'duty_failed' end

    -- SetJobDuty raises OnJobUpdate synchronously, whose handler already calls
    -- syncDuty. Calling it again is an idempotent safety net for builds that
    -- do not raise the event; syncDuty never calls SetJobDuty, so no recursion.
    syncDuty(data)

    local detail = ('%s:%s'):format(
        onDuty and 'on' or 'off', tostring(reason or 'unspecified'):sub(1, 100))
    if not audit(data.citizenid, 'duty.set', data.citizenid, detail) then
        print(('[custom-police] duty.set audit failed for %s'):format(tostring(data.citizenid)))
    end
    return true
end

-- FIT-03: both are qb-core *server-internal* events (qb-core fires them with
-- TriggerEvent). They were registered with RegisterNetEvent, which put them on
-- the client-triggerable surface: any client could send a forged job table for
-- another source and have syncDuty write a police unit row for it. Plain
-- AddEventHandler keeps them off the net surface — every other resource
-- (custom-career, custom-main, custom-director) listens to them this way.
AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job)
    local data = pd(source)
    if data and type(job) == 'table' then data.job = job end
    if data then syncDuty(data) end
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    local data = Player and Player.PlayerData
    if type(data) ~= 'table' or type(data.citizenid) ~= 'string' then return end
    -- `QBCore:Server:PlayerLoaded` is still RegisterNetEvent'd by
    -- custom-justice/server/prison.lua, which keeps the *name* client-callable
    -- for every handler. Accept only qb-core's live PlayerData table (reference
    -- equality with the registered player), never a table a client built.
    local live = QBCore.Functions.GetPlayerByCitizenId(data.citizenid)
    if not live or live.PlayerData ~= data then return end
    syncDuty(data)
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
            if not audit(citizenid, 'incident.unassign', tostring(incidentId), 'unit_dropped', 'system') then
                print(('[custom-police] incident.unassign audit failed for #%s'):format(tostring(incidentId)))
            end
        end
    end
    if not audit(citizenid, 'unit.drop', 'off_duty', incidentId and tostring(incidentId) or nil, 'system') then
        print(('[custom-police] unit.drop audit failed for %s'):format(tostring(citizenid)))
    end
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
         LIMIT 200
    ]]) or {}
    for _, row in ipairs(rows) do
        local cid = row.citizenid
        if cid and not online[cid] then
            takeUnitOffDuty(cid)
            if not audit(cid, 'unit.stale', 'off_duty', 'startup_sweep', 'system') then
                print(('[custom-police] unit.stale audit failed for %s'):format(tostring(cid)))
            end
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
            if not audit('system', 'incident.stale', tostring(id), 'stale_timeout', 'system') then
                print(('[custom-police] incident.stale audit failed for #%s'):format(tostring(id)))
            end
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
        -- Players who were already online during a resource restart never get
        -- another PlayerLoaded, so reconcile their duty projection here.
        for _, src in ipairs(QBCore.Functions.GetPlayers()) do
            local player = QBCore.Functions.GetPlayer(src)
            if player and player.PlayerData then syncDuty(player.PlayerData) end
        end
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

-- 平民 911：任何玩家都能打，所以只接受 table、按 source 限流（5 秒 1 条），
-- 其余校验（title/description 长度、priority 夹取）在 CreateIncident 里。
local call911Cooldown = {}
local CALL_911_COOLDOWN = 5

RegisterNetEvent('custom-police:server:911', function(payload)
    local src = source
    if type(payload) ~= 'table' then return end
    if not pd(src) then return end
    local now = os.time()
    for otherSrc, lastAt in pairs(call911Cooldown) do
        if now - lastAt > 60 then call911Cooldown[otherSrc] = nil end
    end
    local last = call911Cooldown[src]
    if last and now - last < CALL_911_COOLDOWN then return end
    call911Cooldown[src] = now
    P.CreateIncident(src, payload)
end)

function P.SetUnitStatusForSource(source, status)
    local data = pd(source)
    if not isPolice(data) then return false, 'not_police' end
    if not VALID_STATUS[status] then return false, 'invalid_status' end
    local callsign = type(data.metadata) == 'table' and data.metadata.callsign or nil

    if status == 'off_duty' then
        -- 10-7: the duty service owns the qb-core projection and its audit.
        local ok, err = P.SetDutyForSource(source, false, 'unit_status')
        if not ok then return false, err or 'duty_failed' end
        upsertUnit(data.citizenid, callsign, 'off_duty')
        if not audit(data.citizenid, 'unit.status', 'off_duty', nil) then
            print(('[custom-police] unit.status audit failed for %s'):format(tostring(data.citizenid)))
        end
        return true
    end

    if status == 'available' then
        -- 10-8 is the one status that turns the qb-core projection on.
        local ok, err = P.SetDutyForSource(source, true, 'unit_status')
        if not ok then return false, err or 'duty_failed' end
        upsertUnit(data.citizenid, callsign, 'available')
        if not audit(data.citizenid, 'unit.status', 'available', nil) then
            print(('[custom-police] unit.status audit failed for %s'):format(tostring(data.citizenid)))
        end
        return true
    end

    -- busy/assigned/enroute/on_scene never change onduty: they require it.
    if data.job.onduty ~= true then return false, 'not_on_duty' end
    upsertUnit(data.citizenid, callsign, status)
    if not audit(data.citizenid, 'unit.status', status, nil) then
        print(('[custom-police] unit.status audit failed for %s'):format(tostring(data.citizenid)))
    end
    return true
end

exports('SetUnitStatus', P.SetUnitStatus)
exports('SetUnitStatusForSource', P.SetUnitStatusForSource)
exports('SetDutyForSource', P.SetDutyForSource)
exports('GetUnits', P.GetUnits)
exports('CreateIncident', P.CreateIncident)
exports('GetIncidents', P.GetIncidents)
exports('WriteAudit', function(actorCid, actorKind, action, target, detail)
    return audit(actorCid, action, target, detail, actorKind)
end)
exports('AssignUnit', P.AssignUnit)
exports('AssignUnitSystemForAgent', P.AssignUnitSystem)
exports('SetIncidentStatus', P.SetIncidentStatus)
exports('SweepStaleIncidents', SweepStaleIncidents)
exports('LookupCitizen', P.LookupCitizen)
exports('LookupVehicle', P.LookupVehicle)
exports('GetAudit', P.GetAudit)

print('[custom-police] P0 dispatch layer loaded')
