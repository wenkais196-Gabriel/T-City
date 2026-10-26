-- server/p0_lifecycle.lua — 警情的生命周期：判定表、申领、到场、路线。

-- 只有三件事，且都是「人的判断」或「引擎的事实」：
--   1. ActionState     —— 给 UI 下发「能不能点、为什么不能」，执行器调用同一个函数；
--   2. ClaimIncident   —— 唯一申领入口：assign + enroute + 推路线，一次调用到位；
--   3. ArriveIncident  —— 到场由客户端检测、服务端用 ped 坐标复算后结算，nonce 一次性。
-- 到场不存在「按钮」：玩家点的是申领，到场是开到了的事实。
--
-- 拆分说明见 server/p0.lua 头注释。本文件只绑定它真正用到的共享名字。

local QBCore = exports['qb-core']:GetCoreObject()
local P = PoliceDispatch
local I = P.internal

local pd, isPolice, grade, audit, trim, notifyOfficer = I.pd, I.isPolice, I.grade, I.audit, I.trim, I.notifyOfficer
local INCIDENT_STATUS, INCIDENT_TRANSITIONS = I.INCIDENT_STATUS, I.INCIDENT_TRANSITIONS

-- 单位模型在 p0_units.lua，按调用时解析
local function unitsOfIncident(incidentId) return I.unitsOfIncident(incidentId) end
local function primaryOf(units) return I.primaryOf(units) end
local function isUnitOf(units, citizenid) return I.isUnitOf(units, citizenid) end
local function enrouteUnitRow(citizenid, incidentId) return I.enrouteUnitRow(citizenid, incidentId) end
local function arriveUnitRow(citizenid, incidentId) return I.arriveUnitRow(citizenid, incidentId) end
local function recomputeIncidentProgress(incidentId) return I.recomputeIncidentProgress(incidentId) end

--- 指派/申领成功后把路线推给这个人。路线不是"点了才出现"，
--- 而是"被派到就出现"——所以推送点在这里，不在 UI 里。
local function pushIncidentRoute(src, incident)
    if not src or src <= 0 or type(incident) ~= 'table' then return false end
    local x, y, z = tonumber(incident.x), tonumber(incident.y), tonumber(incident.z)
    if not (x and y and z) then return false end
    TriggerClientEvent('police:client:routeToIncident', src, {
        id = tonumber(incident.id),
        x = x, y = y, z = z,
        label = ('#%s %s'):format(tostring(incident.id), tostring(incident.code or '911')),
    })
    return true
end

--- 唯一的动作判定源：UI 拿到的 allowed 与真正执行时的判断出自同一个函数。
---@return table { claim = {allowed, reason, label}, clear = {allowed, reason} }
function P.ActionState(actor, incident, units)
    units = units or {}
    local closed = incident.status == 'closed' or incident.status == 'cleared'
    local member, role = isUnitOf(units, actor and actor.citizenid or '')
    local primary = primaryOf(units)

    local claim
    if closed then
        claim = { allowed = false, reason = 'incident_closed' }
    elseif member then
        claim = { allowed = false, reason = 'already_joined' }
    elseif not isPolice(actor) or actor.job.onduty ~= true then
        claim = { allowed = false, reason = 'not_on_duty' }
    else
        claim = { allowed = true, reason = nil, label = primary and 'join' or 'claim' }
    end

    local clear
    if incident.status ~= 'on_scene' then
        clear = { allowed = false, reason = 'not_on_scene' }
    elseif primary and primary ~= actor.citizenid and grade(actor) < 2 then
        clear = { allowed = false, reason = 'not_primary' }
    else
        clear = { allowed = true, reason = nil }
    end

    return { claim = claim, clear = clear, role = role, primary = primary }
end

--- 申领：assign + enroute + 推路线，一步到位。
--- 已有负责人时变成"加入"（support），只改自己的单位状态，不动事件状态。
function P.ClaimIncident(source, incidentId)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'incident.claim')
    if not allowed then return false, reason end

    local id = tonumber(incidentId)
    if not id then return false, 'invalid_incident' end
    local incident = MySQL.single.await(
        'SELECT id, code, title, status, x, y, z FROM police_incidents WHERE id = ? LIMIT 1', { id })
    if not incident then return false, 'incident_not_found' end
    if incident.status == 'closed' or incident.status == 'cleared' then
        return false, 'incident_closed'
    end

    local units = unitsOfIncident(id)
    local member, role = isUnitOf(units, actor.citizenid)
    local primary = primaryOf(units)

    if member then
        -- 幂等重试：已经在单上，补一次路线即可
        pushIncidentRoute(source, incident)
        return { id = id, status = incident.status, role = role, primary = primary, idempotent = true }
    end

    local joinRole = primary and 'support' or 'primary'
    MySQL.insert.await([[
        INSERT INTO police_incident_units (incident_id, citizenid, role) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE role = role
    ]], { id, actor.citizenid, joinRole })
    enrouteUnitRow(actor.citizenid, id)         -- 指派即出发（assign + enroute 一步）

    local nextStatus = incident.status
    if not primary then
        -- 第一个接手的人：单子从 open 进 enroute（不再需要第二次点击）
        MySQL.update.await([[
            UPDATE police_incidents SET status = 'enroute', last_activity_at = NOW(), updated_at = NOW()
             WHERE id = ? AND status IN ('open','assigned')
        ]], { id })
        nextStatus = 'enroute'
        if not audit(actor.citizenid, 'incident.assign', tostring(id), actor.citizenid) then
            print(('[custom-police] incident.assign audit failed for #%s'):format(tostring(id)))
        end
    else
        if not audit(actor.citizenid, 'incident.assign', tostring(id), 'join:' .. actor.citizenid) then
            print(('[custom-police] incident.join audit failed for #%s'):format(tostring(id)))
        end
    end

    pushIncidentRoute(source, incident)
    print(('[police] inc=#%s claim by=%s %s->%s role=%s'):format(
        tostring(id), tostring(actor.citizenid), tostring(incident.status), tostring(nextStatus), joinRole))

    return { id = id, status = nextStatus, role = joinRole, primary = primary or actor.citizenid }
end

--- 到场 nonce：一次性、30 秒、按 source 绑定，防止客户端重放"我又到了"。
local arriveNonces = {}

function P.RequestArriveNonce(source, incidentId)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'incident.arrive')
    if not allowed then return nil, reason end
    local id = tonumber(incidentId)
    if not id then return nil, 'invalid_incident' end
    local units = unitsOfIncident(id)
    if not isUnitOf(units, actor.citizenid) then return nil, 'not_assigned' end
    local token = ('%d:%s:%d'):format(math.random(100000, 999999), actor.citizenid, GetGameTimer())
    arriveNonces[token] = {
        source = source, incidentId = id,
        expires = GetGameTimer() + PoliceIncidentRules.NONCE_TTL_MS,
    }
    return token
end

local function consumeNonce(token, source, incidentId)
    local entry = token and arriveNonces[token]
    if not entry then return false, 'bad_nonce' end
    arriveNonces[token] = nil                              -- 一次性
    if GetGameTimer() > entry.expires then return false, 'bad_nonce' end
    if entry.source ~= source or entry.incidentId ~= tonumber(incidentId) then return false, 'bad_nonce' end
    return true
end

--- 到场结算：客户端说"我觉得我到了"，服务端用 ped 坐标复算后拍板。
---@param opts table|nil { manual = true } 自动检测失灵时的人工补录（宽容半径更大）
function P.ArriveIncident(source, incidentId, token, opts)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'incident.arrive')
    if not allowed then return false, reason end

    local id = tonumber(incidentId)
    if not id then return false, 'invalid_incident' end
    local manual = type(opts) == 'table' and opts.manual == true
    if not manual then
        local ok, why = consumeNonce(token, source, id)
        if not ok then return false, why end
    end

    local incident = MySQL.single.await(
        'SELECT id, status, x, y, z FROM police_incidents WHERE id = ? LIMIT 1', { id })
    if not incident then return false, 'incident_not_found' end
    if incident.status == 'closed' or incident.status == 'cleared' then return false, 'incident_closed' end

    local units = unitsOfIncident(id)
    if not isUnitOf(units, actor.citizenid) then return false, 'not_assigned' end

    -- 服务端自己算距离：客户端坐标一概不采信
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false, 'player_not_found' end
    local coords = GetEntityCoords(ped)
    local x, y, z = tonumber(incident.x), tonumber(incident.y), tonumber(incident.z)
    if not (x and y and z) then return false, 'incident_has_no_coords' end
    local dist = #(vector3(coords.x, coords.y, coords.z) - vector3(x, y, z))
    local limit = manual and PoliceIncidentRules.MANUAL_RADIUS or PoliceIncidentRules.SERVER_RADIUS_GRACE
    if dist > limit then
        return false, 'too_far', ('%.1f/%.0f'):format(dist, limit)
    end

    arriveUnitRow(actor.citizenid, id)
    local progress = recomputeIncidentProgress(id)
    if not audit(actor.citizenid, 'incident.arrive', tostring(id),
            ('%s dist=%.1f'):format(manual and 'manual' or 'auto', dist)) then
        print(('[custom-police] incident.arrive audit failed for #%s'):format(tostring(id)))
    end

    -- 让本单其它单位（以及本人）知道有人到了：路线收起、板上刷新。
    for _, u in ipairs(units) do
        local target = QBCore.Functions.GetPlayerByCitizenId(u.citizenid)
        if target and target.PlayerData and target.PlayerData.source then
            TriggerClientEvent('police:client:incidentArrived', target.PlayerData.source, {
                id = id, by = actor.citizenid, auto = not manual,
            })
        end
    end

    print(('[police] inc=#%s arrive by=%s dist=%.1fm (%s) -> %s'):format(
        tostring(id), tostring(actor.citizenid), dist, manual and 'manual' or 'auto',
        tostring(progress or incident.status)))

    return { id = id, status = progress or 'on_scene', distance = dist, manual = manual }
end

-- 资源内部共享（不是导出面）
I.pushIncidentRoute = pushIncidentRoute


-- 导出面：本模块拥有的东西在这里登记；外资源只能用这些名字
exports('ClaimIncident', P.ClaimIncident)
exports('ArriveIncident', P.ArriveIncident)
exports('RequestArriveNonce', P.RequestArriveNonce)
exports('ActionState', P.ActionState)

print('[custom-police] p0 lifecycle ready (claim/arrive)')
