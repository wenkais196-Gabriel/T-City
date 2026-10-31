-- server/p0_incidents.lua — 警情的写入面：建单、合并、投影、状态机执行、清扫。

-- 两条硬规则：insertIncidentRow 是唯一写入点，projectIncident 是唯一发送点。
-- 任何来源（平民 911、控制台、车牌雷达、NPC）建单都走这里，所以警察收到的通知、
-- 屏幕一句话、提示音、地图标记永远一样；合并掉的重复报警一次都不响。
--
-- 拆分说明见 server/p0.lua 头注释。本文件只绑定它真正用到的共享名字。

local QBCore = exports['qb-core']:GetCoreObject()
local P = PoliceDispatch
local I = P.internal

local pd, isPolice, grade, audit, trim, notifyOfficer = I.pd, I.isPolice, I.grade, I.audit, I.trim, I.notifyOfficer
local INCIDENT_STATUS, INCIDENT_TRANSITIONS, INCIDENT_DISPOSITIONS =
    I.INCIDENT_STATUS, I.INCIDENT_TRANSITIONS, I.INCIDENT_DISPOSITIONS

-- 单位模型在 p0_units.lua，按调用时解析
local function markIncidentUnits(incidentId, status) return I.markIncidentUnits(incidentId, status) end
local function releaseIncidentUnits(incidentId) return I.releaseIncidentUnits(incidentId) end
local function sweepOfflineUnits() return I.sweepOfflineUnits() end
local function syncDuty(data) return I.syncDuty(data) end

--- 同一类、同一地点、5 分钟内的重复报警并到同一单。
---
--- 为什么需要：一次抢劫被 5 个人先后报警，警情板就会出现 5 条一模一样的单，
--- 警员分不清哪条是真事件，派单/清场/统计全被稀释。限流（15 秒/人）只是
--- 不让一个人连刷，挡不住"很多人同时报同一件事"。
local MERGE_WINDOW_MINUTES = 5

local MERGE_RADIUS_METERS = 60.0

--- 找一个可以合并的开放单：同 code、同区域、窗口内还有人动过。
---@return table|nil row { id, title, status }
local function findMergeableIncident(code, coords, ref)
    -- 有 ref 就按 ref 合并（同一个报警源的多个阶段坐标会漂），
    -- 没有 ref 才退回「同 code + 半径内」—— 蓝图 AC-P2-05 要的就是前者。
    if type(ref) == 'string' and ref ~= '' then
        local row = MySQL.single.await(([[
            SELECT id, title, status, merge_count
              FROM police_incidents
             WHERE status IN ('open','assigned','enroute','on_scene')
               AND ref = ?
               AND COALESCE(last_activity_at, created_at) > NOW() - INTERVAL %d MINUTE
             ORDER BY id DESC
             LIMIT 1
        ]]):format(MERGE_WINDOW_MINUTES), { ref })
        return row
    end
    if type(coords) ~= 'table' then return nil end
    local x, y = tonumber(coords.x), tonumber(coords.y)
    if not x or not y then return nil end
    local rows = MySQL.query.await(([[
        SELECT id, title, status,
               SQRT(POW(COALESCE(x, 0) - ?, 2) + POW(COALESCE(y, 0) - ?, 2)) AS distance
          FROM police_incidents
         WHERE status IN ('open','assigned','enroute','on_scene')
           AND code = ?
           AND x IS NOT NULL
           AND COALESCE(last_activity_at, created_at) > NOW() - INTERVAL %d MINUTE
         ORDER BY id DESC
         LIMIT 1
    ]]):format(MERGE_WINDOW_MINUTES), { x, y, code }) or {}
    local row = rows[1]
    if not row then return nil end
    if (tonumber(row.distance) or 0) > MERGE_RADIUS_METERS then return nil end
    return row
end

--- 通知在勤警察。标题带单号：手机通知和 MDT 里的同一条能对上，
--- 否则"有人报警"这句话在板上对应哪一行全靠猜。
local function notifyOnDutyIncident(incident, content)
    local title = ('#%s %s: %s'):format(
        tostring(incident.id), tostring(incident.code or '911'), tostring(incident.title or ''))
    title = title:sub(1, 200)
    local body = tostring(content or ''):sub(1, 500)
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local p = QBCore.Functions.GetPlayer(src)
        local d = p and p.PlayerData
        if isPolice(d) and d.job.onduty == true then
            -- P2-2 预算层：同 code 90 s 合并成「×N」，非紧急每 5 s 最多 3 条。
            -- police_alert_budget 0 可一键关掉（回滚到逐条发）。
            local action, count = 'sent', 1
            if PoliceAlertBudget and GetConvarInt('police_alert_budget', 1) ~= 0 then
                action, count = PoliceAlertBudget.Decide(
                    d.citizenid, incident.code, incident.priority, os.time() * 1000)
            end
            if GetConvarInt and GetConvarInt('police_alert_debug', 0) == 1 then
                print(('[alert-budget] cid=%s code=%s action=%s count=%d'):format(
                    tostring(d.citizenid), tostring(incident.code), tostring(action), tonumber(count) or 0))
            end
            if action == 'sent' or action == 'merged' then
                local shown = PoliceAlertBudget and PoliceAlertBudget.Decorate(title, count) or title
                notifyOfficer(d.citizenid, shown, body, 'police_mdt')
            end
        end
    end
end

--- 建单的投影：在勤警察收到的东西都从这里发。
--- 以前地图标记是报警处理器自己广播的，所以"控制台派单"和"系统建单"没有标记——
--- 板上看得见、地图上找不到。现在建单是唯一入口，投影也跟着收口：
--- 任何来源建出一张单，在勤警察都会同时收到手机通知 + 屏幕一句话 + 提示音 + 临时标记。
---@param incident table 建单结果（含 id / code / title / x / y / z）
---@return number 收到提示的警察数
local function broadcastIncidentAlert(incident)
    local x, y, z = tonumber(incident.x), tonumber(incident.y), tonumber(incident.z)
    if not (x and y and z) then return 0 end
    local text = ('#%s %s'):format(tostring(incident.id), tostring(incident.code or '911'))

    -- D5：精确坐标**永不下发客户端**。偏移逻辑收在 shared/dispatch_view.lua，
    -- 屏幕提示 / 地图标记 / 车机终端 / 手机都用同一份，不会再各自算一遍。
    local point = PoliceDispatchView.Fuzz(incident.id, x, y, z)
    local coords = { x = point.x, y = point.y, z = point.z }
    local sent = 0
    for _, src in ipairs(QBCore.Functions.GetPlayers()) do
        local p = QBCore.Functions.GetPlayer(src)
        local d = p and p.PlayerData
        if isPolice(d) and d.job and d.job.onduty == true then
            TriggerClientEvent('police:client:policeAlert', d.source, coords, text)
            sent = sent + 1
        end
    end
    return sent
end

--- 合并进已有单时什么都不发：同一条警情响五遍等于没有警情。
local function projectIncident(incident, data)
    if not incident or incident.merged then return incident end
    notifyOnDutyIncident(incident, trim(data and (data.description or data.details)))
    incident.alerted = broadcastIncidentAlert(incident)
    return incident
end

--- 同资源内其它模块（NPC callout）复用同一条投影：通知带单号、地图标记只发一次。
--- 内容可以由调用方给（NPC 的台词要带地点名），但"发给谁、发什么形状"只有这一处。
function P.ProjectIncident(incident, data) return projectIncident(incident, data) end

--- police_incidents 的**唯一写入点**（玩家路径、agent 路径、NPC 路径都走这里）。
--- 列集合按需拼接：npc_template 只有 NPC callout 才有，NULL 写进 SQL 而不是传 nil 参数
--- （参数数组里的洞会被 oxmysql 截断，police_audit 那边踩过同一个坑）。
---@param createdBy string 写入者标识：citizenid / 'agent:<id>' / 'npc:<template>'
---@param data table { code, title, description|details, priority, x, y, z, npc_template }
---@param opts table|nil { audit = false } 调用方已自行审计时跳过
---@return table|nil result { id, status }, string|nil reason
local function insertIncidentRow(createdBy, data, opts)
    if type(data) ~= 'table' then return nil, 'invalid_params' end
    local title = trim(data.title):sub(1, 120)
    if title == '' then return nil, 'invalid_title' end
    local code = trim(data.code):sub(1, 16)
    if code == '' then code = '911' end
    local priority = tonumber(data.priority) or 2
    priority = math.max(1, math.min(3, math.floor(priority)))
    local description = trim(data.description or data.details):sub(1, 1000)
    local npcTemplate = data.npc_template and tostring(data.npc_template):sub(1, 32) or nil

    -- 合并优先于插入：重复报警不该在板上多出一行。
    -- 只处理带坐标的报警——NPC 刷新点固定，靠"同点同码"合并会误吞两个独立事件。
    local coords = { x = tonumber(data.x), y = tonumber(data.y) }
    local ref = trim(data.ref):sub(1, 64)
    if ref == '' then ref = nil end
    local mergeable = findMergeableIncident(code, coords, ref)
    if mergeable then
        MySQL.update.await([[
            UPDATE police_incidents
               SET last_activity_at = NOW(), updated_at = NOW(),
                   merge_count = COALESCE(merge_count, 1) + 1
             WHERE id = ?
        ]], { mergeable.id })
        return {
            id = tonumber(mergeable.id),
            status = tostring(mergeable.status or 'open'),
            code = code,
            title = tostring(mergeable.title or title),
            merge_count = (tonumber(mergeable.merge_count) or 1) + 1,
            merged = true,
        }
    end

    local columns = { 'code', 'title', 'description', 'priority', 'created_by' }
    local placeholders = { '?', '?', '?', '?', '?' }
    local values = { code, title, description, priority, createdBy }
    local function add(column, value)          -- 只为非 nil 值追加，数组里不留洞
        if value == nil then return end
        columns[#columns + 1] = column
        placeholders[#placeholders + 1] = '?'
        values[#values + 1] = value
    end
    add('status', opts and opts.status)
    add('x', tonumber(data.x))
    add('y', tonumber(data.y))
    add('z', tonumber(data.z))
    add('npc_template', npcTemplate)
    add('ref', ref)

    local id = MySQL.insert.await(
        ('INSERT INTO police_incidents (%s) VALUES (%s)'):format(
            table.concat(columns, ', '), table.concat(placeholders, ', ')),
        values)
    id = InsertId(id)
    if not id or id == 0 then return nil, 'db_error' end

    -- opts.audit == false 表示调用方已经自己写过审计（例如 agent 路径要 fail-closed：
    -- 审计写不进去就不许建单），这里不再重复记一条。
    if not (opts and opts.audit == false) then
        if not audit(createdBy, 'incident.create', tostring(id), title) then
            print(('[custom-police] incident.create audit failed for #%s'):format(tostring(id)))
        end
    end
    return {
        id = tonumber(id), status = 'open', code = code, title = title,
        description = description,
        -- 坐标必须跟着单子走：建单的人可能是控制台、系统事件或者玩家，
        -- 但在勤警察要的是"去哪"。
        x = tonumber(data.x), y = tonumber(data.y), z = tonumber(data.z),
    }
end

--- 同资源内的唯一写者句柄（p2_system 的 agent 路径、p4_npc 的 NPC 路径都用它）。
--- 不对外 exports：外部只能走 CreateIncident（带玩家身份校验）。
PoliceIncidents = { InsertRow = insertIncidentRow }

function P.CreateIncident(source, data)
    local creator = pd(source)
    if not creator then return false, 'player_not_found' end
    local result, reason = insertIncidentRow(creator.citizenid, data)
    if not result then return false, reason end
    return projectIncident(result, data)
end

--- 系统来源（车辆防盗、脚本事件）建单：没有玩家可校验，调用方必须自带标识。
--- 与玩家路径共用去重与通知，区别只在于 created_by 写的是资源名。
function P.CreateIncidentSystem(createdBy, data)
    if type(createdBy) ~= 'string' or createdBy == '' then return false, 'bad_creator' end
    local result, reason = insertIncidentRow(createdBy:sub(1, 50), data)
    if not result then return false, reason end
    return projectIncident(result, data)
end

--- P6-4：agent 解析出的 call 卡草稿。上板可见，但**不广播、不派 NPC**。
--- 与 CreateIncidentSystem 共用同一个写者（insertIncidentRow），只把 status 固定成 draft。
---@param actorCid string 'action:<id>'
---@param data table { title, description?, code?, priority?, x?, y?, z?, raw_text? }
---@return table|nil result
---@return string|nil reason
function P.DraftCallSystem(actorCid, data)
    if type(actorCid) ~= 'string' or actorCid == '' then return nil, 'bad_creator' end
    if type(data) ~= 'table' then return nil, 'invalid_params' end
    local result, reason = insertIncidentRow(actorCid:sub(1, 50), data, { status = 'draft', audit = false })
    if not result then return nil, reason end
    -- 草稿必须留审计：写不进去就当没写（fail-closed）
    if not audit(actorCid, 'incident.draft', tostring(result.id), result.title, 'agent') then
        return nil, 'audit_unavailable'
    end
    return { id = result.id, status = 'draft', code = result.code, title = result.title }
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

    -- AC-P2-09：结案只能由这张单的 lead（role='primary'）来做。
    -- 没有 lead（没人接手过的单）时，够级别的警员仍然可以结掉 —— 否则调度遗忘的单
    -- 永远关不掉，会一直挂在板上。
    if targetStatus == 'closed' then
        local lead = MySQL.single.await(
            "SELECT citizenid FROM police_incident_units WHERE incident_id = ? AND role = 'primary' ORDER BY joined_at ASC LIMIT 1",
            { id })
        local leadCid = lead and tostring(lead.citizenid or '') or ''
        if leadCid ~= '' and leadCid ~= tostring(actor.citizenid) then
            return false, 'lead_only'
        end
    end

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

-- 资源内部共享（不是导出面）
I.projectIncident, I.insertIncidentRow = projectIncident, insertIncidentRow


-- 导出面：本模块拥有的东西在这里登记；外资源只能用这些名字
exports('CreateIncident', P.CreateIncident)
exports('CreateIncidentFromSystem', P.CreateIncidentSystem)
exports('DraftCallSystem', P.DraftCallSystem)
exports('WriteAudit', function(actorCid, actorKind, action, target, detail)
    return audit(actorCid, action, target, detail, actorKind)
end)
exports('SetIncidentStatus', P.SetIncidentStatus)
exports('SweepStaleIncidents', SweepStaleIncidents)

print('[custom-police] p0 incidents ready')
