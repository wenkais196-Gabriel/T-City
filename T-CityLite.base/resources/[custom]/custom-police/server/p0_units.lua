-- server/p0_units.lua — 单位（police_units）的唯一维护处：值班、状态、指派、进度派生。

-- 分工是「谁写哪张表」：单位状态只在本文件的几个 helper 里写，调用点不写裸 UPDATE；
-- 警情状态的**值**来自 recomputeIncidentProgress —— 单位是事实，警情状态是它的投影（只升级不降级）。
--
-- 拆分说明见 server/p0.lua 头注释。本文件只绑定它真正用到的共享名字。

local QBCore = exports['qb-core']:GetCoreObject()
local P = PoliceDispatch
local I = P.internal

local pd, isPolice, grade, audit, trim, notifyOfficer = I.pd, I.isPolice, I.grade, I.audit, I.trim, I.notifyOfficer
local VALID_STATUS = I.VALID_STATUS

-- 跨模块调用：定义在 p0_lifecycle.lua（本文件之后加载），按调用时解析
local function pushIncidentRoute(src, incident) return I.pushIncidentRoute(src, incident) end

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

--- 指派即出发：单位进 enroute 并绑定单号（与 assignUnitRow 同一处维护，
--- 免得每个调用点各写一条 UPDATE）。
local function enrouteUnitRow(citizenid, incidentId)
    MySQL.update.await(
        "UPDATE police_units SET status = 'enroute', incident_id = ? WHERE citizenid = ?",
        { incidentId, citizenid })
end

--- 到场：单位进 on_scene。只在 p0_units 里写 police_units，调用点不写裸 UPDATE。
local function arriveUnitRow(citizenid, incidentId)
    MySQL.update.await(
        "UPDATE police_units SET status = 'on_scene' WHERE citizenid = ? AND incident_id = ?",
        { citizenid, incidentId })
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

--- 这张单上的所有单位（citizenid + role）。role 之前存在但没人读写，
--- 现在 primary 决定谁能推进主状态、谁能清场。
local function unitsOfIncident(incidentId)
    return MySQL.query.await(
        'SELECT citizenid, role FROM police_incident_units WHERE incident_id = ? ORDER BY joined_at ASC LIMIT 50',
        { incidentId }) or {}
end

local function primaryOf(units)
    for _, u in ipairs(units) do
        if tostring(u.role) == 'primary' then return tostring(u.citizenid) end
    end
    -- 历史数据没有 role：最早加入的那个就是负责人
    return units[1] and tostring(units[1].citizenid) or nil
end

local function isUnitOf(units, citizenid)
    for _, u in ipairs(units) do
        if tostring(u.citizenid) == citizenid then return true, tostring(u.role) end
    end
    return false
end

--- 事件状态是**派生值**：有人到现场 → 事件 on_scene。
--- 只允许升级，不允许降级（清场由清场那条路径负责）。
local function recomputeIncidentProgress(incidentId)
    local rows = MySQL.query.await(
        "SELECT status FROM police_units WHERE incident_id = ? AND status IN ('assigned','enroute','on_scene') LIMIT 100",
        { incidentId }) or {}
    local best = nil
    for _, r in ipairs(rows) do
        if r.status == 'on_scene' then best = 'on_scene' break end
        if r.status == 'enroute' then best = 'enroute' end
    end
    if not best then return nil end
    MySQL.update.await([[
        UPDATE police_incidents
           SET status = ?, last_activity_at = NOW(), updated_at = NOW()
         WHERE id = ? AND status IN ('open','assigned','enroute')
    ]], { best, incidentId })
    return best
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
    local incident = MySQL.single.await(
        'SELECT id, code, title, status, x, y, z FROM police_incidents WHERE id = ? LIMIT 1', { id })
    if not incident then return false, 'incident_not_found' end
    if incident.status ~= 'open' and incident.status ~= 'assigned' and incident.status ~= 'enroute' then
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
    enrouteUnitRow(target, id)
    MySQL.update.await(
        "UPDATE police_incidents SET status = 'assigned', last_activity_at = NOW(), updated_at = NOW() WHERE id = ?",
        { id })
    -- 被派到就出发：路线由服务端推给被指派的人，不依赖他在手机上点任何按钮。
    local targetPlayer = QBCore.Functions.GetPlayerByCitizenId(target)
    if targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.source then
        pushIncidentRoute(targetPlayer.PlayerData.source, incident)
    end
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

    -- Some qb-core runtimes/events replace PlayerData or hand back a stale job
    -- table. Set the live table, raise the same events, then write the
    -- projection from the live value so police_units can never disagree.
    player.PlayerData.job.onduty = onDuty
    TriggerEvent('QBCore:Server:OnJobUpdate', player.PlayerData.source, player.PlayerData.job)
    TriggerClientEvent('QBCore:Client:OnJobUpdate', player.PlayerData.source, player.PlayerData.job)
    player.Functions.UpdatePlayerData()

    player.PlayerData.job.onduty = onDuty
    local live = player.PlayerData
    local callsign = type(live.metadata) == 'table' and live.metadata.callsign or nil
    if onDuty then
        syncDuty(live)
    else
        takeUnitOffDuty(live.citizenid)
    end

    if live.job.onduty ~= onDuty then
        print(('[custom-police] duty mismatch player=%s expected=%s'):format(
            tostring(live.job.onduty), tostring(onDuty)))
        return false, 'duty_failed'
    end

    local detail = ('%s:%s'):format(
        onDuty and 'on' or 'off', tostring(reason or 'unspecified'):sub(1, 100))
    if not audit(live.citizenid, 'duty.set', live.citizenid, detail) then
        print(('[custom-police] duty.set audit failed for %s'):format(tostring(live.citizenid)))
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

-- ---------------------------------------------------------------
-- Events/commands
-- ---------------------------------------------------------------
RegisterNetEvent('custom-police:server:toggleDuty', function()
    local src = source
    local data = pd(src)
    if not isPolice(data) then return end
    P.SetDutyForSource(src, data.job.onduty ~= true, 'duty_point')
end)

RegisterNetEvent('custom-police:server:setStatus', function(status)
    local data = pd(source)
    if not isPolice(data) then return end
    P.SetUnitStatusForSource(source, tostring(status or ''))
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

-- 资源内部共享（不是导出面）
I.upsertUnit, I.takeUnitOffDuty = upsertUnit, takeUnitOffDuty
I.enrouteUnitRow, I.assignUnitRow = enrouteUnitRow, assignUnitRow
I.arriveUnitRow = arriveUnitRow
I.markIncidentUnits, I.releaseIncidentUnits = markIncidentUnits, releaseIncidentUnits
I.unitsOfIncident, I.primaryOf, I.isUnitOf = unitsOfIncident, primaryOf, isUnitOf
I.recomputeIncidentProgress = recomputeIncidentProgress
I.syncDuty, I.sweepOfflineUnits = syncDuty, sweepOfflineUnits


-- 导出面：本模块拥有的东西在这里登记；外资源只能用这些名字
exports('SetUnitStatus', P.SetUnitStatus)
exports('SetUnitStatusForSource', P.SetUnitStatusForSource)
exports('SetDutyForSource', P.SetDutyForSource)
exports('GetUnits', P.GetUnits)
exports('AssignUnit', P.AssignUnit)
exports('AssignUnitSystemForAgent', P.AssignUnitSystem)

print('[custom-police] p0 units ready')
