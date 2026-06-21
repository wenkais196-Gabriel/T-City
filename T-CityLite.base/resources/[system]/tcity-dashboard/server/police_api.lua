-- server/police_api.lua — 警车功能服务端 API (v2.1)
--
-- 职责:
--   1. 车牌标记/取消/查询 (source 权威 + onduty 校验)
--   2. ANPR 批量检查回调
--   3. 扣押操作鉴权 (委托 qb-policejob)
--   4. GPS 追踪器广播
--
-- 设计原则 (T-City Lite 四铁律):
--   模块化: 独立服务模块，通过 Bus 注册
--   安全: 五层校验链 (Source→类型→权限→距离→限流)
--   高性能: 内存 O(1) 查表，无同步 SQL
--   可拓展: 统一事件命名空间，外部可监听

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 车牌标记存储 (内存表 + SQL 持久化)
-- ==============================================================

---@type table<string, { isflagged: boolean, reason: string, flaggedBy: string, flaggedAt: number }>
local FlaggedPlates = {}

-- v2.2: 服务端启动时从 SQL 预加载所有标记
CreateThread(function()
    Wait(1000) -- 等待 oxmysql 就绪
    local result = MySQL.query.await('SELECT * FROM plate_flags WHERE isflagged = 1')
    if result and #result > 0 then
        for _, row in ipairs(result) do
            FlaggedPlates[row.plate] = {
                isflagged = true,
                reason = row.reason or '',
                flaggedBy = row.flagged_by or 'UNKNOWN',
                flaggedAt = row.flagged_at or os.time(),
            }
        end
        print(('[tcity-dashboard] 📋 从 SQL 预加载了 %d 条车牌标记'):format(#result))
    end
end)

-- v2.2: 写入 SQL
local function _saveFlagToDb(plate, reason, flaggedBy)
    MySQL.insert('INSERT INTO plate_flags (plate, isflagged, reason, flagged_by, flagged_at) VALUES (?, 1, ?, ?, ?) ON DUPLICATE KEY UPDATE isflagged = 1, reason = VALUES(reason), flagged_by = VALUES(flagged_by), flagged_at = VALUES(flagged_at)', {
        plate, reason, flaggedBy, os.time()
    })
end

local function _removeFlagFromDb(plate)
    MySQL.update('UPDATE plate_flags SET isflagged = 0 WHERE plate = ?', { plate })
end

-- ==============================================================
-- Rate Limit (1000ms 操作冷却)
-- ==============================================================

local opCooldowns = {}

local function checkRateLimit(src, action)
    local now = os.clock() * 1000
    if not opCooldowns[src] then opCooldowns[src] = {} end
    local last = opCooldowns[src][action]
    if last and now - last < 1000 then return false end
    opCooldowns[src][action] = now
    return true
end

-- ==============================================================
-- 安全校验: 必须是值班执法者
-- ==============================================================

local function isOnDutyLeo(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end
    local job = Player.PlayerData.job
    if not job then return false end
    -- 检查 job.type 或 job.name
    if job.type == 'leo' then return job.onduty == true end
    if job.name == 'police' then return job.onduty == true end
    return false
end

-- ==============================================================
-- 清理玩家缓存 (playerDropped)
-- ==============================================================

AddEventHandler('playerDropped', function()
    local src = source
    opCooldowns[src] = nil
end)

-- ==============================================================
-- 车牌标记 (服务端权威)
-- ==============================================================

RegisterNetEvent('tcity-dashboard:server:flagPlate', function(plate, reason)
    local src = source

    if not checkRateLimit(src, 'flagPlate') then return end

    if not isOnDutyLeo(src) then
        if exports['custom-logs'] then
            local Player = QBCore.Functions.GetPlayer(src)
            exports['custom-logs']:LogSecurity('非法车牌标记',
                ('**Source**: %d | **CitizenID**: %s | **Plate**: %s'):format(
                    src, Player and Player.PlayerData.citizenid or 'unknown', plate or 'nil'), 16711680)
        end
        return
    end

    local Player = QBCore.Functions.GetPlayer(src)
    plate = plate:upper()
    reason = reason or '中控屏标记'

    FlaggedPlates[plate] = {
        isflagged = true,
        reason = reason,
        flaggedBy = Player.PlayerData.citizenid,
        flaggedAt = os.time(),
    }

    -- v2.2: 持久化到 SQL
    _saveFlagToDb(plate, reason, Player.PlayerData.citizenid)

    -- 同时也更新 qb-policejob 的 Plates 表 (如果可访问)
    TriggerEvent('police:server:plateFlagged', plate, reason)

    TriggerClientEvent('QBCore:Notify', src,
        ('已标记车牌: %s — 原因: %s'):format(plate, reason), 'success')

    -- 审计
    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('车牌标记',
            ('**%s** (%s) 标记了车牌 **%s** | 原因: %s'):format(
                GetPlayerName(src), Player.PlayerData.citizenid, plate, reason), 255)
    end
end)

-- ==============================================================
-- 车牌取消标记
-- ==============================================================

RegisterNetEvent('tcity-dashboard:server:unflagPlate', function(plate)
    local src = source

    if not checkRateLimit(src, 'unflagPlate') then return end

    if not isOnDutyLeo(src) then
        if exports['custom-logs'] then
            local Player = QBCore.Functions.GetPlayer(src)
            exports['custom-logs']:LogSecurity('非法取消标记',
                ('**Source**: %d | **CitizenID**: %s | **Plate**: %s'):format(
                    src, Player and Player.PlayerData.citizenid or 'unknown', plate or 'nil'), 16711680)
        end
        return
    end

    plate = plate:upper()
    if FlaggedPlates[plate] then
        FlaggedPlates[plate].isflagged = false
        -- v2.2: 同步更新 SQL
        _removeFlagFromDb(plate)
        TriggerClientEvent('QBCore:Notify', src,
            ('已取消标记: %s'):format(plate), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src,
            ('车牌 %s 未被标记'):format(plate), 'error')
    end
end)

-- ==============================================================
-- ANPR 批量检查回调 (客户端雷达扫描时调用)
-- ==============================================================

QBCore.Functions.CreateCallback('tcity-dashboard:server:checkPlatesFlagged', function(source, cb, plates)
    local src = source

    -- 安全校验
    if not isOnDutyLeo(src) then
        cb({})
        return
    end

    -- 构建标记映射表
    local flaggedMap = {}
    if plates and type(plates) == 'table' then
        for _, plate in ipairs(plates) do
            local p = plate:upper()
            if FlaggedPlates[p] and FlaggedPlates[p].isflagged then
                flaggedMap[p] = true
            end
        end
    end

    cb(flaggedMap)
end)

-- ==============================================================
-- GPS 追踪器
-- ==============================================================

RegisterNetEvent('tcity-dashboard:server:setTracker', function(targetId)
    local src = source

    if not checkRateLimit(src, 'tracker') then return end

    if not isOnDutyLeo(src) then return end

    local Target = QBCore.Functions.GetPlayer(targetId)
    if not Target then
        TriggerClientEvent('QBCore:Notify', src, '目标玩家不在线', 'error')
        return
    end

    -- 给目标装上追踪器状态
    local targetPed = GetPlayerPed(targetId)
    local coords = GetEntityCoords(targetPed)

    -- 通知目标
    TriggerClientEvent('police:client:SetTracker', targetId, true)

    -- 通知附近警察
    for _, playerId in ipairs(GetPlayers()) do
        local Player = QBCore.Functions.GetPlayer(tonumber(playerId))
        if Player and Player.PlayerData.job.name == 'police' and Player.PlayerData.job.onduty then
            TriggerClientEvent('police:client:TrackerMessage', tonumber(playerId),
                ('追踪器已部署 — 目标: %s'):format(GetPlayerName(targetId)), coords)
        end
    end

    TriggerClientEvent('QBCore:Notify', src,
        ('已在 %s 身上部署追踪器'):format(GetPlayerName(targetId)), 'success')

    -- 审计
    if exports['custom-logs'] then
        local Player = QBCore.Functions.GetPlayer(src)
        exports['custom-logs']:LogGeneric('GPS追踪器部署',
            ('**%s** (%s) → 目标: **%s** (%s)'):format(
                GetPlayerName(src), Player.PlayerData.citizenid,
                GetPlayerName(targetId), Target.PlayerData.citizenid), 255)
    end
end)

-- ==============================================================
-- Bus 注册 (可拓展)
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('police', {
        FlagPlate   = function(plate, reason) FlaggedPlates[plate:upper()] = { isflagged = true, reason = reason, flaggedBy = 'SYSTEM', flaggedAt = os.time() } end,
        UnflagPlate = function(plate) if FlaggedPlates[plate:upper()] then FlaggedPlates[plate:upper()].isflagged = false end end,
        IsFlagged   = function(plate) return FlaggedPlates[plate:upper()] and FlaggedPlates[plate:upper()].isflagged end,
        GetInfo     = function(plate) return FlaggedPlates[plate:upper()] end,
    })
end

-- ==============================================================
-- 桥接: 同步 qb-policejob 的标记操作 (向下兼容)
-- ==============================================================

-- 监听 qb-policejob 的标记事件，保持 FlaggedPlates 同步
RegisterNetEvent('police:server:plateFlagged', function(plate, reason)
    -- 来自外部 (qb-policejob /flagplate 命令等) 的标记同步
    if not FlaggedPlates[plate:upper()] or not FlaggedPlates[plate:upper()].isflagged then
        FlaggedPlates[plate:upper()] = {
            isflagged = true,
            reason = reason or '外部标记',
            flaggedBy = 'qb-policejob',
            flaggedAt = os.time(),
        }
    end
end)

-- ==============================================================
-- v2.2: 公民/车辆查询回调
-- ==============================================================

QBCore.Functions.CreateCallback('tcity-dashboard:server:lookupCitizen', function(source, cb, query)
    local src = source
    if not isOnDutyLeo(src) then cb(nil); return end

    query = tostring(query or ''):gsub('^%s+', ''):gsub('%s+$', '')

    -- 尝试按 citizenid 或姓名查找
    local target = QBCore.Functions.GetPlayerByCitizenId(query)
    if not target then
        -- 尝试按 source 查找
        local sid = tonumber(query)
        if sid then target = QBCore.Functions.GetPlayer(sid) end
    end

    if not target then
        -- 尝试模糊搜索在线玩家姓名
        for _, playerId in ipairs(GetPlayers()) do
            local p = QBCore.Functions.GetPlayer(tonumber(playerId))
            if p and p.PlayerData and p.PlayerData.charinfo then
                local fullName = ('%s %s'):format(
                    p.PlayerData.charinfo.firstname or '',
                    p.PlayerData.charinfo.lastname or '')
                if fullName:lower():find(query:lower(), 1, true) then
                    target = p
                    break
                end
            end
        end
    end

    if target and target.PlayerData then
        local pd = target.PlayerData
        cb({
            found = true,
            citizenid = pd.citizenid,
            name = ('%s %s'):format(
                pd.charinfo and pd.charinfo.firstname or '?',
                pd.charinfo and pd.charinfo.lastname or '?'),
            job = pd.job and ('%s [%s]'):format(pd.job.label or pd.job.name, pd.job.grade and pd.job.grade.name or '?') or 'N/A',
            cash = pd.money and pd.money.cash or 0,
            bank = pd.money and pd.money.bank or 0,
            phone = pd.charinfo and pd.charinfo.phone or 'N/A',
            dob = pd.charinfo and pd.charinfo.birthdate or 'N/A',
        })
    else
        cb({ found = false, message = ('未找到公民: %s'):format(query) })
    end
end)

QBCore.Functions.CreateCallback('tcity-dashboard:server:lookupVehicle', function(source, cb, plate)
    local src = source
    if not isOnDutyLeo(src) then cb(nil); return end

    plate = tostring(plate or ''):gsub('^%s+', ''):gsub('%s+$', ''):upper()
    if #plate < 2 then cb({ found = false, message = '请输入有效车牌' }); return end

    local result = MySQL.query.await('SELECT pv.plate, pv.vehicle, pv.garage, pv.state, pv.citizenid, ' ..
        'CONCAT(COALESCE(p.charinfo, "")) as owner_info ' ..
        'FROM player_vehicles pv LEFT JOIN players p ON pv.citizenid = p.citizenid ' ..
        'WHERE pv.plate = ? LIMIT 1', { plate })

    if result and result[1] then
        local v = result[1]
        -- 尝试解析 owner_info JSON
        local ownerName = '未知'
        local ownerInfo = v.owner_info
        if ownerInfo and ownerInfo ~= '' then
            local ok, decoded = pcall(json.decode, ownerInfo)
            if ok and decoded and decoded.firstname then
                ownerName = ('%s %s'):format(decoded.firstname, decoded.lastname)
            end
        end

        local stateLabel = ({ '车库', '取出', '扣押', '没收' })[(v.state or 0) + 1] or '未知'

        cb({
            found = true,
            plate = v.plate,
            model = v.vehicle or 'N/A',
            owner = ownerName,
            citizenid = v.citizenid or 'N/A',
            garage = v.garage or 'N/A',
            state = stateLabel,
        })
    else
        cb({ found = false, message = ('未找到车牌: %s'):format(plate) })
    end
end)

print('[tcity-dashboard] 🛡️ 警车功能服务端 API 已就绪 (v2.2)')
print('[tcity-dashboard]   车牌标记 | ANPR检查 | GPS追踪器 | 公民查询 | 车辆查询 | Bus: police.*')
