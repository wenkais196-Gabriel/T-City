-- server/p2_system.lua — system (agent) entry points for the police board.
-- These have no player source: the actor is an agent id and every write is
-- audited with actor_kind='agent'. Authorization/approval happens in
-- custom-director (L1-L3); this layer only validates data and state.
local QBCore = exports['qb-core']:GetCoreObject()
local Sys = {}

local function audit(actorId, action, target, detail)
    return pcall(function()
        MySQL.insert.await(
            'INSERT INTO police_audit (actor_citizenid, actor_kind, action, target, detail) VALUES (?, "agent", ?, ?, ?)',
            { ('agent:%s'):format(tostring(actorId or 'unknown'):sub(1, 40)), action, target,
              detail and tostring(detail):sub(1, 500) or nil })
    end)
end

local function trim(v)
    return type(v) == 'string' and v:match('^%s*(.-)%s*$') or ''
end

local function broadcast(title, content)
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local p = QBCore.Functions.GetPlayer(src)
        local d = p and p.PlayerData
        if d and type(d.job) == 'table' and d.job.name == 'police' and d.job.onduty == true then
            MySQL.insert.await(
                'INSERT INTO phone_notifications (citizenid, title, content, app_id) VALUES (?, ?, ?, ?)',
                { d.citizenid, title:sub(1, 200), content:sub(1, 500), 'police_mdt' })
            TriggerClientEvent('phone:client:newNotification', src, {
                id = 0, title = title:sub(1, 200), content = content:sub(1, 500),
                timestamp = os.date('%Y-%m-%d %H:%M:%S'), is_read = false, app_id = 'police_mdt',
            })
        end
    end
end

--- L1: create an incident as an agent. Returns {id=...}.
function Sys.CreateIncident(actorId, data)
    if type(data) ~= 'table' then return false, 'invalid_params' end
    local title = trim(data.title):sub(1, 120)
    if #title < 3 then return false, 'invalid_title' end
    local code = trim(data.code):sub(1, 16)
    if code == '' then code = '911' end
    local priority = math.max(1, math.min(3, math.floor(tonumber(data.priority) or 2)))
    local details = trim(data.details or data.description):sub(1, 1000)
    if not audit(actorId, 'incident.create', nil, title) then return false, 'audit_unavailable' end
    local id = MySQL.insert.await([[
        INSERT INTO police_incidents (code, title, description, priority, created_by)
        VALUES (?, ?, ?, ?, ?)
    ]], { code, title, details, priority, ('agent:%s'):format(tostring(actorId):sub(1, 40)) })
    id = InsertId(id)
    if not id or id == 0 then return false, 'db_error' end
    broadcast(('%s: %s'):format(code, title), details)
    return { id = tonumber(id), status = 'open' }
end

--- L2: assign a unit to an incident as an agent.
function Sys.AssignUnit(actorId, incidentId, citizenid)
    local id = tonumber(incidentId)
    local target = tostring(citizenid or ''):sub(1, 50)
    if not id then return false, 'invalid_incident' end
    if target == '' then return false, 'invalid_unit' end
    local incident = MySQL.single.await('SELECT id FROM police_incidents WHERE id = ? LIMIT 1', { id })
    if not incident then return false, 'incident_not_found' end
    local unit = MySQL.single.await('SELECT citizenid, status FROM police_units WHERE citizenid = ? LIMIT 1', { target })
    if not unit then return false, 'unit_not_found' end
    if unit.status == 'off_duty' then return false, 'unit_off_duty' end
    if not audit(actorId, 'incident.assign', tostring(id), target) then return false, 'audit_unavailable' end
    MySQL.insert.await([[
        INSERT INTO police_incident_units (incident_id, citizenid) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE joined_at = joined_at
    ]], { id, target })
    MySQL.update.await("UPDATE police_units SET status = 'assigned', incident_id = ? WHERE citizenid = ?", { id, target })
    MySQL.update.await("UPDATE police_incidents SET status = 'assigned' WHERE id = ?", { id })
    return { id = id, unit = target, status = 'assigned' }
end

--- L3: jail a citizen as an agent. Delegates to custom-justice so the normal
--- sentence bookkeeping and qb-prison handoff are reused.
function Sys.Jail(actorId, citizenid, minutes, reason)
    local target = tostring(citizenid or ''):sub(1, 50)
    local mins = math.floor(tonumber(minutes) or 0)
    local text = trim(reason):sub(1, 240)
    if target == '' then return false, 'invalid_citizen' end
    if mins < 1 or mins > 120 then return false, 'invalid_minutes' end
    if #text < 3 then return false, 'invalid_reason' end
    local player = QBCore.Functions.GetPlayerByCitizenId(target)
    if not player then return false, 'citizen_offline' end
    local ok, result = pcall(function()
        return exports['custom-justice']:Imprison(target, mins, { text })
    end)
    if not ok or result ~= true then
        -- Fallback: metadata + qb-prison, still audited.
        pcall(function()
            player.Functions.SetMetaData('injail', mins)
            TriggerClientEvent('prison:client:Enter', player.PlayerData.source, mins)
        end)
    end
    MySQL.insert.await([[
        INSERT INTO police_arrests (citizenid, officer_citizenid, charges) VALUES (?, ?, ?)
    ]], { target, ('agent:%s'):format(tostring(actorId):sub(1, 40)), text })
    audit(actorId, 'arrest.register', target, ('%d min: %s'):format(mins, text))
    return { citizenid = target, minutes = mins, status = 'jailed' }
end

exports('CreateIncidentSystem', Sys.CreateIncident)
exports('AssignUnitSystem', Sys.AssignUnit)
exports('JailSystem', Sys.Jail)
print('[custom-police] P4 system entry points loaded')


-- Ops command: release a jailed player and optionally restore their job.
-- Console (source 0) or an ACE-allowed admin only.
RegisterCommand('police_release', function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'police.release') then return end
    local target = tonumber(args and args[1])
    if not target then return print('usage: police_release <serverId> [job] [grade]') end
    local player = QBCore.Functions.GetPlayer(target)
    if not player then return print('player not found') end
    player.Functions.SetMetaData('injail', 0)
    TriggerClientEvent('prison:client:UnjailPerson', target)
    local job = args[2]
    if job and job ~= '' then
        local okJob, errJob
        if Bus and Bus.JobService and type(Bus.JobService.SetJob) == 'function' then
            okJob, errJob = Bus.JobService.SetJob(target, job, args[3] or '0', 'police_release')
        else
            okJob, errJob = player.Functions.SetJob(job, args[3] or '0')
        end
        print(('[custom-police] SetJob(%s,%s) -> %s %s'):format(job, tostring(args[3]), tostring(okJob), tostring(errJob)))
    end
    print(('[custom-police] released %s%s'):format(target, job and (' -> ' .. job) or ''))
end, true)
