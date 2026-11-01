-- server/p4_npc.lua — NPC callouts (server authority).
--
-- The server decides whether an NPC callout may exist (on-duty officers, one
-- active callout at a time, 30% every 8 minutes), where it happens (the fixed
-- locations in shared/npc_callouts.lua), when the scene is pushed to a client
-- (only once an assigned officer is on scene), and how it settles (payout,
-- audit, close through the existing P0 incident state machine).
--
-- Clients never create an incident and never choose a reward: they only build
-- the local scene and report an outcome after the scene is under control.

local QBCore = exports['qb-core']:GetCoreObject()
local NPC = {}

local OUTCOMES = {
    resolved = true,
    arrest = true,
    failed = true,
    false_alarm = true,
}

-- `failed` archives the call as stale: the callout could not be seen through,
-- but it must not stay on the board. `resolved` is a normal clear.
local DISPOSITIONS = {
    resolved = 'cleared',
    arrest = 'arrest',
    failed = 'stale',
    false_alarm = 'false_alarm',
}

local CLOSE_STATUS = 'cleared'

-- FIT-07: every callout scene is charged to the unified NPC budget as two
-- slots (vehicle + suspect). The incident id only exists after the INSERT, so
-- the budget gets its own server-generated id and this map connects the two
-- for every close path (result, watcher, stale sweep fallback).
local calloutBudget = {} -- [incidentId] = budget id
local calloutSeq = 0

local function nextCalloutBudgetId(source)
    calloutSeq = calloutSeq + 1
    return ('CALL-%d-%d-%d'):format(source, os.time(), calloutSeq)
end

local function releaseCalloutBudget(incidentId, reason)
    local id = tonumber(incidentId)
    if not id then return false end
    local budgetId = calloutBudget[id]
    if not budgetId then return false end
    calloutBudget[id] = nil
    return NPCBudget.Release(budgetId, reason)
end

--- A second callout in the same tick can pass the DB count before either
--- INSERT lands. The budget entry is reserved before the yielding audit, so
--- the first acquired callout wins that race.
local function otherCalloutActive(exceptBudgetId)
    for _, entry in ipairs(GetNpcBudget().entries) do
        if entry.kind == 'callout' and entry.id ~= exceptBudgetId then
            return true
        end
    end
    return false
end

local function pd(source)
    local player = QBCore.Functions.GetPlayer(source)
    if not player or type(player.PlayerData) ~= 'table' then return nil end
    return player.PlayerData
end

local function trim(value)
    return type(value) == 'string' and value:match('^%s*(.-)%s*$') or ''
end

local function audit(actorCid, action, target, detail, actorKind)
    -- 唯一写者见 server/audit.lua（这里只保留同名包装，调用点不用改）
    return PoliceAudit.Write(actorCid, action, target, detail, actorKind)
end

local function onDutyOfficers()
    local officers = {}
    for _, source in ipairs(QBCore.Functions.GetPlayers()) do
        local data = pd(source)
        if data and PolicePolicy.IsPolice(data) and data.job.onduty == true then
            officers[#officers + 1] = { source = source, data = data }
        end
    end
    return officers
end

local function onDutyCount()
    return #onDutyOfficers()
end

local function activeNpcCount()
    local count = MySQL.scalar.await(
        "SELECT COUNT(*) FROM police_incidents WHERE npc_template IS NOT NULL AND status <> 'closed'")
    return math.floor(tonumber(count) or 0)
end

local function notifyOfficers(incident, template, location)
    local content = ('%s（%s）'):format(
        (template.description:gsub('{location}', location.label)), location.label):sub(1, 500)
    -- 与玩家报警、系统警报、控制台派单共用一条投影：标题带单号、地图标记只发一次。
    -- （以前这里自己发一条不带单号的通知再插一次旗，手机上的"店被人抢了"和板上哪一行对不上。）
    if type(PoliceDispatch) ~= 'table' or type(PoliceDispatch.ProjectIncident) ~= 'function' then
        return false
    end
    PoliceDispatch.ProjectIncident(incident, { description = content })
    return true
end

--- Create one NPC callout.
--- `officerSrc` may be a player source (manual command) or nil/0 for the
--- automatic scheduler. A player source must be an on-duty officer; the
--- command additionally requires the `police.release` ACE.
--- @return table|false result, string|nil reason
function NPC.CreateNpcCallout(templateId, officerSrc)
    local template = NPCCallouts.Get(templateId)
    if not template then return false, 'invalid_template' end

    local source = tonumber(officerSrc) or 0
    local actorCid = 'system:npc'
    local actorKind = 'system'
    if source > 0 then
        local data = pd(source)
        if not data then return false, 'player_not_found' end
        if not PolicePolicy.IsPolice(data) then return false, 'not_police' end
        if data.job.onduty ~= true then return false, 'not_on_duty' end
        actorCid = data.citizenid
        actorKind = 'player'
    end

    if activeNpcCount() >= NPCCallouts.MAX_ACTIVE then return false, 'limit_reached' end

    -- Reserve the scene before any DB write; every early exit below releases
    -- it again so a validation/database failure cannot leak a slot.
    local budgetId = nextCalloutBudgetId(source)
    local admitted, budgetError = NPCBudget.Acquire('callout', budgetId, actorCid)
    if not admitted then return false, budgetError end
    if otherCalloutActive(budgetId) then
        NPCBudget.Release(budgetId, 'callout_limit')
        return false, 'limit_reached'
    end

    local location = template.locations[math.random(1, #template.locations)]
    if not location then
        NPCBudget.Release(budgetId, 'no_location')
        return false, 'no_location'
    end
    local coords = { x = location.x, y = location.y, z = location.z }
    local title = ('[NPC] %s'):format(template.title):sub(1, 120)
    local description = (template.description:gsub('{location}', location.label)):sub(1, 1000)

    -- 走 police_incidents 的唯一写者（server/p0.lua 的 PoliceIncidents.InsertRow）。
    -- 审计在本函数末尾单独记（npc.callout.create，actor_kind 可能是 player），
    -- 所以让写者跳过它自己那条 incident.create，避免一次建单两条审计。
    local inserted, insertReason = PoliceIncidents.InsertRow(actorCid, {
        code = template.code, title = title, description = description,
        priority = template.priority,
        x = coords.x, y = coords.y, z = coords.z,
        npc_template = template.id,
    }, { audit = false })
    if not inserted then
        NPCBudget.Release(budgetId, insertReason or 'db_error')
        return false, insertReason or 'db_error'
    end
    local id = tonumber(inserted.id)
    calloutBudget[id] = budgetId

    if not audit(actorCid, 'npc.callout.create', tostring(id), template.id, actorKind) then
        print(('[custom-police] npc.callout.create audit failed for #%s'):format(tostring(id)))
    end
    notifyOfficers(inserted, template, location)

    return {
        id = id,
        template = template.id,
        code = template.code,
        title = title,
        coords = coords,
        location = location.label,
        status = 'open',
    }
end

-- In-memory map of incidentId -> source that currently owns the spawned scene.
-- It is deliberately not persisted: a scene only exists for a connected client
-- and any restart/respawn re-arms it through sceneWatcher below.
local spawned = {}

local function broadcastEnd(incidentId)
    local notified = {}
    local entry = spawned[incidentId]
    if entry then
        TriggerClientEvent('police:client:NpcCalloutEnd', entry.source, incidentId)
        notified[entry.source] = true
        spawned[incidentId] = nil
    end
    for _, officer in ipairs(onDutyOfficers()) do
        if not notified[officer.source] then
            TriggerClientEvent('police:client:NpcCalloutEnd', officer.source, incidentId)
            notified[officer.source] = true
        end
    end
end

--- Settle an NPC callout from the officer who controlled the scene.
--- @return table|false result, string|nil reason
function NPC.SubmitResult(source, incidentId, outcome, notes)
    local actor = pd(source)
    if not actor then return false, 'not_police' end
    local allowed, policyReason = PolicePolicy.Can(actor, 'incident.update')
    if not allowed then return false, policyReason end

    local id = tonumber(incidentId)
    if not id then return false, 'invalid_incident' end
    local result = trim(outcome)
    if not OUTCOMES[result] then return false, 'invalid_outcome' end

    local incident = MySQL.single.await(
        'SELECT id, status, npc_template FROM police_incidents WHERE id = ? LIMIT 1', { id })
    if not incident then return false, 'incident_not_found' end
    if not incident.npc_template or tostring(incident.npc_template) == '' then
        return false, 'not_npc_callout'
    end

    -- A retried report on an already closed incident is success (no double
    -- payout, no second audit row).
    if tostring(incident.status) == 'closed' then
        spawned[id] = nil
        releaseCalloutBudget(id, 'callout_already_closed')
        TriggerClientEvent('police:client:NpcCalloutEnd', source, id)
        return { id = id, status = 'closed', idempotent = true }
    end

    local assigned = MySQL.single.await(
        'SELECT 1 AS ok FROM police_incident_units WHERE incident_id = ? AND citizenid = ? LIMIT 1',
        { id, actor.citizenid })
    if PolicePolicy.Grade(actor) < 2 and not assigned then
        return false, 'not_assigned'
    end

    local disposition = DISPOSITIONS[result]
    local closeReason = ('npc_callout:%s'):format(result)
    local note = trim(notes):sub(1, 200)
    if note ~= '' then closeReason = closeReason .. ':' .. note end

    -- Reuse the P0 close path so transition guard, unit release and the
    -- incident.close audit all happen exactly once.
    local callOk, closed = pcall(function()
        return exports['custom-police']:SetIncidentStatus(
            source, id, CLOSE_STATUS, disposition, closeReason)
    end)
    if not callOk or type(closed) ~= 'table' then
        return false, 'close_failed'
    end
    -- Another officer closed the incident between our status read and the P0
    -- transition. P0 reports that as idempotent success; do not pay twice.
    if closed.idempotent == true then
        spawned[id] = nil
        releaseCalloutBudget(id, 'callout_already_closed')
        TriggerClientEvent('police:client:NpcCalloutEnd', source, id)
        return { id = id, status = 'closed', idempotent = true }
    end

    -- Reward is best-effort: a payout failure must never reopen or block the
    -- call. The id above is the authoritative incident id, not a client value.
    local player = QBCore.Functions.GetPlayer(source)
    if player then
        pcall(function()
            player.Functions.AddMoney('bank', 500, 'npc_callout')
        end)
    end
    if not audit(actor.citizenid, 'npc.callout.resolve', tostring(id), result, 'player') then
        print(('[custom-police] npc.callout.resolve audit failed for #%s'):format(tostring(id)))
    end

    broadcastEnd(id)
    -- The scene is settled: return the two slots to the global budget.
    releaseCalloutBudget(id, 'callout_result')
    -- broadcastEnd only reaches on-duty officers; the responder may have gone
    -- 10-7 in the same tick, so clean their scene explicitly too.
    TriggerClientEvent('police:client:NpcCalloutEnd', source, id)
    TriggerClientEvent('QBCore:Notify', source,
        ('NPC 警情 #%d 已结算（%s）'):format(id, result), 'success')
    return { id = id, status = 'closed', disposition = disposition, outcome = result }
end

-- ---------------------------------------------------------------------------
-- Scene push / cleanup watcher.
-- The scene is created on the client only after an assigned (or, for an
-- unassigned manual call, any on-duty) officer is on scene. The server never
-- teleports anyone and never lets a client ask for a scene at an arbitrary
-- coordinate.
-- ---------------------------------------------------------------------------
local function sceneWatcher()
    local ok, err = pcall(function()
        local rows = MySQL.query.await([[
            SELECT id, npc_template, x, y, z, status
              FROM police_incidents
             WHERE npc_template IS NOT NULL AND status <> 'closed'
             LIMIT 10
        ]])
        if not rows then return end

        local active = {}
        for _, row in ipairs(rows) do
            active[tonumber(row.id)] = row
        end

        -- An incident can be closed outside NpcCalloutResult (MDT clear, stale
        -- sweep). Tell the owning client to remove its entities.
        for incidentId, entry in pairs(spawned) do
            if not active[incidentId] then
                TriggerClientEvent('police:client:NpcCalloutEnd', entry.source, incidentId)
                spawned[incidentId] = nil
                releaseCalloutBudget(incidentId, 'callout_watcher')
            end
        end
        -- A callout may be closed through the MDT before any client scene was
        -- pushed, so the budget map has to be swept against the DB as well.
        for incidentId in pairs(calloutBudget) do
            if not active[incidentId] then
                releaseCalloutBudget(incidentId, 'callout_watcher')
            end
        end

        for incidentId, row in pairs(active) do
            if not spawned[incidentId] then
                local templateId = tostring(row.npc_template)
                local target = nil
                local bestDistance = math.huge

                local assigned = MySQL.query.await([[
                    SELECT iu.citizenid, u.status AS unit_status
                      FROM police_incident_units iu
                      LEFT JOIN police_units u ON u.citizenid = iu.citizenid
                     WHERE iu.incident_id = ?
                     LIMIT 10
                ]], { incidentId }) or {}

                -- The scene rotation is part of the fixed template location;
                -- the client must not derive it from the responding player.
                local template = NPCCallouts.Get(templateId)
                local heading = 0.0
                local rx, ry = tonumber(row.x), tonumber(row.y)
                if template and rx and ry then
                    for _, location in ipairs(template.locations) do
                        if math.abs(location.x - rx) < 1.0 and math.abs(location.y - ry) < 1.0 then
                            heading = tonumber(location.heading) or 0.0
                            break
                        end
                    end
                end

                local candidates = {}
                if #assigned > 0 then
                    for _, unit in ipairs(assigned) do
                        candidates[#candidates + 1] = { citizenid = unit.citizenid, status = unit.unit_status }
                    end
                else
                    -- Manual console call with no assignment: the first
                    -- on-duty officer on scene picks it up.
                    for _, officer in ipairs(onDutyOfficers()) do
                        candidates[#candidates + 1] = { source = officer.source, status = nil }
                    end
                end

                for _, candidate in ipairs(candidates) do
                    local src = candidate.source
                    if not src and candidate.citizenid then
                        local player = QBCore.Functions.GetPlayerByCitizenId(candidate.citizenid)
                        src = player and player.PlayerData and player.PlayerData.source or nil
                    end
                    local data = src and pd(src) or nil
                    if data and PolicePolicy.IsPolice(data) and data.job.onduty == true then
                        local x, y, z = tonumber(row.x), tonumber(row.y), tonumber(row.z)
                        if x and y and z then
                            local ped = GetPlayerPed(src)
                            if ped and ped ~= 0 then
                                local playerCoords = GetEntityCoords(ped)
                                local distance = #(playerCoords - vector3(x, y, z))
                                if candidate.status == 'on_scene' or distance <= NPCCallouts.SPAWN_RADIUS then
                                    if distance < bestDistance then
                                        bestDistance = distance
                                        target = {
                                            source = src,
                                            templateId = templateId,
                                            coords = { x = x, y = y, z = z, heading = heading },
                                        }
                                    end
                                end
                            end
                        end
                    end
                end

                if target then
                    spawned[incidentId] = { source = target.source }
                    TriggerClientEvent('police:client:NpcCallout', target.source, incidentId,
                        target.templateId, target.coords)
                    print(('[custom-police] NPC callout #%d scene pushed to %s (%s)'):format(
                        incidentId, tostring(target.source), target.templateId))
                end
            end
        end
    end)
    if not ok then
        print(('[custom-police] NPC callout watcher failed: %s'):format(tostring(err)))
    end
end

local function watcherLoop()
    Wait(5000)
    while true do
        sceneWatcher()
        Wait(3000)
    end
end

-- The scheduler: first evaluation 30s after start, then every 8 minutes. It
-- creates at most one callout and only if at least one officer is on duty and
-- no other NPC callout is still open.
local function autoLoop()
    Wait(NPCCallouts.START_DELAY_MS)
    while true do
        local ok, err = pcall(function()
            if onDutyCount() < 1 then return end
            if activeNpcCount() >= NPCCallouts.MAX_ACTIVE then return end
            if math.random() >= NPCCallouts.SPAWN_CHANCE then return end
            local templateId = NPCCallouts.RandomId()
            local result = NPC.CreateNpcCallout(templateId, nil)
            if type(result) == 'table' then
                print(('[custom-police] NPC callout #%d (%s) dispatched automatically'):format(
                    result.id, tostring(result.template)))
            end
        end)
        if not ok then
            print(('[custom-police] NPC callout scheduler failed: %s'):format(tostring(err)))
        end
        Wait(NPCCallouts.INTERVAL_MS)
    end
end

--- Lightweight read used by tests/diagnostics; never contains player PII.
function NPC.GetActiveCallouts()
    local rows = MySQL.query.await([[
        SELECT id, npc_template, code, title, priority, status, x, y, z
          FROM police_incidents
         WHERE npc_template IS NOT NULL AND status <> 'closed'
         ORDER BY id DESC LIMIT 10
    ]]) or {}
    return rows
end

-- ---------------------------------------------------------------------------
-- Events / console command
-- ---------------------------------------------------------------------------
RegisterNetEvent('police:server:NpcCalloutResult', function(incidentId, outcome, notes)
    local src = source
    local result, reason = NPC.SubmitResult(src, incidentId, outcome, notes)
    if type(result) ~= 'table' then
        TriggerClientEvent('QBCore:Notify', src,
            ('NPC 警情上报失败：%s'):format(tostring(reason or 'unknown')), 'error')
        return  -- 失败就到此为止：显式 return，别让后来的改动在它后面接副作用
    end
end)

RegisterCommand('npc_callout', function(source, args)
    local templateId = tostring(args[1] or '')
    if source ~= 0 and not IsPlayerAceAllowed(source, 'police.release') then
        TriggerClientEvent('QBCore:Notify', source, '权限不足：需要 ACE police.release', 'error')
        return
    end
    local result, reason = NPC.CreateNpcCallout(templateId, source)
    if type(result) ~= 'table' then
        local message = ('npc_callout 失败：%s（可选：%s）'):format(
            tostring(reason or 'unknown'), table.concat(NPCCallouts.Ids(), ', '))
        if source ~= 0 then TriggerClientEvent('QBCore:Notify', source, message, 'error') end
        print('[custom-police] ' .. message)
        return
    end
    print(('[custom-police] npc_callout %s -> incident #%d at %s'):format(
        tostring(result.template), result.id, tostring(result.location)))
    if source ~= 0 then
        TriggerClientEvent('QBCore:Notify', source,
            ('NPC 警情 #%d 已生成：%s'):format(result.id, tostring(result.location)), 'success')
    end
end, false)

AddEventHandler('playerDropped', function()
    local dropped = source
    for incidentId, entry in pairs(spawned) do
        if entry.source == dropped then spawned[incidentId] = nil end
    end
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CreateThread(autoLoop)
    CreateThread(watcherLoop)
end)

exports('CreateNpcCallout', NPC.CreateNpcCallout)
exports('SubmitNpcCalloutResult', NPC.SubmitResult)
exports('GetActiveNpcCallouts', NPC.GetActiveCallouts)
exports('GetNpcCalloutTemplates', function() return NPCCallouts.Ids() end)

print('[custom-police] NPC callout layer loaded')
