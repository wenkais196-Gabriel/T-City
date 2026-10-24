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

function P.SetUnitStatus(citizenid, callsign, status)
    if not VALID_STATUS[status] then return false, 'invalid_status' end
    MySQL.insert.await([[
        INSERT INTO police_units (citizenid, callsign, status) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE callsign = VALUES(callsign), status = VALUES(status),
            incident_id = IF(VALUES(status) IN ('off_duty','available'), NULL, incident_id)
    ]], { citizenid, callsign and tostring(callsign):sub(1, 16) or nil, status })
    audit(citizenid, 'unit.status', status, nil)
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
    local rows
    if status and INCIDENT_STATUS[status] then
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
            status = row.status, x = row.x, y = row.y, z = row.z,
            created_at = tostring(row.created_at),
        }
    end
    return { incidents = incidents, count = #incidents }
end

function P.AssignUnit(source, incidentId, targetCitizenId)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'incident.assign')
    if not allowed then return false, reason end
    local id = tonumber(incidentId)
    if not id then return false, 'invalid_incident' end
    local target = tostring(targetCitizenId or ''):sub(1, 50)
    if target == '' then return false, 'invalid_unit' end
    local incident = MySQL.single.await('SELECT id, status FROM police_incidents WHERE id = ?', { id })
    if not incident then return false, 'incident_not_found' end
    MySQL.insert.await([[
        INSERT INTO police_incident_units (incident_id, citizenid) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE joined_at = joined_at
    ]], { id, target })
    MySQL.update.await("UPDATE police_units SET status = 'assigned', incident_id = ? WHERE citizenid = ?", { id, target })
    MySQL.update.await("UPDATE police_incidents SET status = 'assigned' WHERE id = ?", { id })
    audit(actor.citizenid, 'incident.assign', tostring(id), target)
    return { id = id, unit = target, status = 'assigned' }
end

function P.SetIncidentStatus(source, incidentId, status)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'incident.update')
    if not allowed then return false, reason end
    if not INCIDENT_STATUS[status] then return false, 'invalid_status' end
    local id = tonumber(incidentId)
    if not id then return false, 'invalid_incident' end
    local assigned = MySQL.single.await(
        'SELECT 1 AS ok FROM police_incident_units WHERE incident_id = ? AND citizenid = ? LIMIT 1',
        { id, actor.citizenid })
    if grade(actor) < 2 and not assigned then return false, 'not_assigned' end
    local closed = (status == 'closed' or status == 'cleared')
    MySQL.update.await(
        'UPDATE police_incidents SET status = ?, closed_at = IF(?, NOW(), closed_at), updated_at = NOW() WHERE id = ?',
        { status, closed and 1 or 0, id })
    if status == 'enroute' or status == 'on_scene' then
        MySQL.update.await('UPDATE police_units SET status = ? WHERE incident_id = ?', { status, id })
    elseif closed then
        MySQL.update.await('UPDATE police_units SET incident_id = NULL, status = "available" WHERE incident_id = ?', { id })
    end
    audit(actor.citizenid, 'incident.status', tostring(id), status)
    return { id = id, status = status }
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
    local row = MySQL.single.await(
        'SELECT citizenid, charinfo, job, metadata, last_seen FROM players WHERE citizenid = ? LIMIT 1',
        { tostring(citizenid or ''):sub(1, 50) })
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
    audit(actor.citizenid, 'lookup.citizen.result', tostring(row.citizenid), nil)
    return {
        citizenid = row.citizenid,
        name = ('%s %s'):format(tostring(info.firstname or '?'), tostring(info.lastname or '?')),
        birthdate = info.birthdate, job = job.name or 'unemployed',
        wants = meta.wanted, last_seen = tostring(row.last_seen or ''),
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
    if not isPolice(data) then return end
    local status = data.job.onduty == true and 'available' or 'off_duty'
    MySQL.insert.await([[
        INSERT INTO police_units (citizenid, callsign, status) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE callsign = VALUES(callsign), status = VALUES(status),
            incident_id = IF(VALUES(status) = 'off_duty', NULL, incident_id)
    ]], { data.citizenid, type(data.metadata) == 'table' and data.metadata.callsign or nil, status })
end

RegisterNetEvent('QBCore:Server:OnJobUpdate', function(source, job)
    local data = pd(source)
    if data and type(job) == 'table' then data.job = job end
    if data then syncDuty(data) end
end)

RegisterNetEvent('QBCore:Server:PlayerLoaded', function(Player)
    if Player and Player.PlayerData then syncDuty(Player.PlayerData) end
end)

AddEventHandler('playerDropped', function()
    local data = pd(source)
    if data and isPolice(data) then
        pcall(function()
            MySQL.update.await("UPDATE police_units SET status = 'off_duty', incident_id = NULL WHERE citizenid = ?", { data.citizenid })
        end)
    end
end)

-- ---------------------------------------------------------------
-- Events/commands
-- ---------------------------------------------------------------
RegisterNetEvent('custom-police:server:setStatus', function(status)
    local data = pd(source)
    if not isPolice(data) then return end
    P.SetUnitStatus(data.citizenid, type(data.metadata) == 'table' and data.metadata.callsign or nil, tostring(status or ''))
end)

RegisterNetEvent('custom-police:server:911', function(payload)
    if type(payload) ~= 'table' then return end
    P.CreateIncident(source, payload)
end)

function P.SetUnitStatusForSource(source, status)
    local data = pd(source)
    if not isPolice(data) then return false, 'not_police' end
    return P.SetUnitStatus(data.citizenid, type(data.metadata) == 'table' and data.metadata.callsign or nil, tostring(status or ''))
end

exports('SetUnitStatus', P.SetUnitStatus)
exports('SetUnitStatusForSource', P.SetUnitStatusForSource)
exports('GetUnits', P.GetUnits)
exports('CreateIncident', P.CreateIncident)
exports('GetIncidents', P.GetIncidents)
exports('AssignUnit', P.AssignUnit)
exports('SetIncidentStatus', P.SetIncidentStatus)
exports('LookupCitizen', P.LookupCitizen)
exports('LookupVehicle', P.LookupVehicle)
exports('GetAudit', P.GetAudit)

print('[custom-police] P0 dispatch layer loaded')
