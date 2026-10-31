-- server/p0_read.lua — 读取面：警情板、公民/车辆/审计查询。

-- 每条读都先过 audit（读警情本身也是敏感操作）：审计失败就拒绝返回，
-- 宁可界面空着，也不让「谁查了谁」这件事没有记录。
--
-- 拆分说明见 server/p0.lua 头注释。本文件只绑定它真正用到的共享名字。

local QBCore = exports['qb-core']:GetCoreObject()
local P = PoliceDispatch
local I = P.internal

local pd, isPolice, grade, audit, trim, notifyOfficer = I.pd, I.isPolice, I.grade, I.audit, I.trim, I.notifyOfficer
local INCIDENT_LIST_STATUS = I.INCIDENT_LIST_STATUS

local function primaryOf(units) return I.primaryOf(units) end

--- 纯查询：不带鉴权、不写审计（由调用方负责）。
---@param status string|nil
local function readIncidents(status)
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
            units = {}, primary = nil,
        }
    end

    return incidents
end

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
    local incidents = readIncidents(status)

    -- 一次查完这张板上的所有单位（不做 N+1），然后把"这个人能点什么"算出来。
    -- UI 只渲染 allowed_actions：前端不许复制一套状态机。
    local ids = {}
    for _, inc in ipairs(incidents) do ids[#ids + 1] = inc.id end
    if #ids > 0 then
        local placeholders = {}
        for _ = 1, #ids do placeholders[#placeholders + 1] = '?' end
        local unitRows = MySQL.query.await(
            ('SELECT incident_id, citizenid, role FROM police_incident_units WHERE incident_id IN (%s) ORDER BY joined_at ASC LIMIT 500')
                :format(table.concat(placeholders, ',')), ids) or {}
        local byIncident = {}
        for _, u in ipairs(unitRows) do
            local key = tonumber(u.incident_id)
            byIncident[key] = byIncident[key] or {}
            byIncident[key][#byIncident[key] + 1] = { citizenid = tostring(u.citizenid), role = tostring(u.role) }
        end
        for _, inc in ipairs(incidents) do
            local units = byIncident[inc.id] or {}
            inc.units = units
            inc.primary = primaryOf(units)
            inc.actions = P.ActionState(actor, inc, units)
        end
    end
    return { incidents = incidents, count = #incidents }
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

-- 导出面：本模块拥有的东西在这里登记；外资源只能用这些名字
exports('GetIncidents', P.GetIncidents)

--- 给其他资源（车机终端 / 手机）用的投影版：坐标已按 D5 偏移。
--- 车机终端 / 手机的警情入口（P2-4）。
---
--- 与 `GetIncidents` 的区别：这里只回**投影后**的字段（坐标按 D5 偏移、不含
--- description / disposition / 单位），并且自己带鉴权与审计 —— 调用方是别的资源，
--- 不能指望它替我们做前置检查。
---@param source number 发起查询的玩家
---@param limit number 最多返回几张（默认 20）
exports('GetIncidentsPublic', function(source, limit)
    local actor = pd(source)
    local allowed, reason = PolicePolicy.Can(actor, 'incident.update')
    if not allowed then return false, reason or 'not_allowed' end
    if not audit(actor.citizenid, 'incident.view', 'public', nil) then
        return false, 'audit_unavailable'
    end
    local rows = readIncidents(nil)
    local out = {}
    local cap = tonumber(limit) or 20
    for _, incident in ipairs(rows or {}) do
        if #out >= cap then break end
        local projected = PoliceDispatchView and PoliceDispatchView.Public(incident)
        if projected then out[#out + 1] = projected end
    end
    return out
end)
exports('LookupCitizen', P.LookupCitizen)
exports('LookupVehicle', P.LookupVehicle)
exports('GetAudit', P.GetAudit)

print('[custom-police] P0 dispatch layer loaded')
