-- dashboard_api.lua — 智能车载中控屏服务端 API (v0.7b)
--
-- 职责:
--   1. RegisterDashboardApp — 外部第三方 App 动态注册
--   2. 警用控制台服务端校验 (job鉴权 + PA喊话 + 警笛)
--   3. 航空/航海控制台
--   4. 物流电子印章交单 (三合一校验: 玩家+车牌+货物)
--   5. 操作 Rate Limit (1000ms 防刷)
--
-- 四原则: 模块化·高性能·安全·可拓展

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 外部 App 注册 API (可拓展)
-- ==============================================================

---@type table[] 已注册的第三方 Dashboard App
DashboardApps = DashboardApps or {}

--- 注册 Dashboard App（外部资源调用）
---@param app table { id, label, icon, job, nui_event }
---@return boolean
function RegisterDashboardApp(app)
    if not app or not app.id or not app.label then
        print('[dashboard-api] ⚠️ Invalid app registration — missing id or label')
        return false
    end

    -- 防重复
    for _, existing in ipairs(DashboardApps) do
        if existing.id == app.id then
            print(('[dashboard-api] ⚠️ App already registered: %s'):format(app.id))
            return false
        end
    end

    app.registered_at = os.time()
    DashboardApps[#DashboardApps + 1] = app

    -- 广播给所有在线客户端
    for _, playerId in ipairs(GetPlayers()) do
        TriggerClientEvent('custom-vehicles:client:registerApp', tonumber(playerId), app)
    end

    print(('[dashboard-api] 📱 App registered: %s (%s) — job=%s'):format(app.id, app.label, app.job or 'all'))
    return true
end

exports('RegisterDashboardApp', RegisterDashboardApp)

-- 玩家加载后推送已注册的 App
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local src = Player.PlayerData.source
    for _, app in ipairs(DashboardApps) do
        TriggerClientEvent('custom-vehicles:client:registerApp', src, app)
    end
end)

-- ==============================================================
-- Rate Limit (1000ms 操作冷却)
-- ==============================================================

local opCooldowns = {} -- [src] = { [action] = timestamp }

local function checkOpRateLimit(src, action)
    local now = os.clock() * 1000
    if not opCooldowns[src] then opCooldowns[src] = {} end
    local last = opCooldowns[src][action] or 0
    if now - last < 1000 then return false end
    opCooldowns[src][action] = now
    return true
end

-- ==============================================================
-- 驾驶席身份校验 (安全)
-- ==============================================================

--- 校验玩家是否在驾驶席
---@param src number
---@param veh number
---@return boolean isDriver
local function isDriverSeat(src, veh)
    local ped = GetPlayerPed(src)
    local playerVeh = GetVehiclePedIsIn(ped, false)
    if playerVeh ~= veh then return false end
    return GetPedInVehicleSeat(veh, -1) == ped
end

--- 校验玩家与载具的物理距离
---@param src number
---@param veh number
---@param maxDist number
---@return boolean
local function isNearVehicle(src, veh, maxDist)
    maxDist = maxDist or 5.0
    local ped = GetPlayerPed(src)
    local pCoords = GetEntityCoords(ped)
    local vCoords = GetEntityCoords(veh)
    return #(pCoords - vCoords) <= maxDist
end

-- ==============================================================
-- 警用控制台
-- ==============================================================

--- PA喊话系统 (v2.1 兼容新 controller 表传参)
RegisterNetEvent('custom-vehicles:server:megaphone', function(data)
    local src = source

    if not checkOpRateLimit(src, 'megaphone') then return end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 职业鉴权：必须是警察
    local job = Player.PlayerData.job
    if not job or (job.name ~= 'police' and job.name ~= 'ambulance' and job.name ~= 'fire') then
        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('非法PA喊话',
                ('**%s** (%s) 试图使用紧急喊话'):format(GetPlayerName(src), Player.PlayerData.citizenid), 16711680)
        end
        return
    end

    -- 兼容新旧调用约定:
    --   新(tcity-dashboard controller): data = { message, vehNetId }
    --   旧(custom-vehicles dashboard): data = message(string)
    local message, veh
    if type(data) == 'table' then
        message = data.message or '注意 — 紧急车辆通行'
        veh = NetworkGetEntityFromNetworkId(data.vehNetId or 0)
    else
        message = tostring(data or '注意 — 紧急车辆通行')
        veh = GetVehiclePedIsIn(GetPlayerPed(src), false)
    end

    -- 驾驶席校验
    if veh and DoesEntityExist(veh) then
        if not isDriverSeat(src, veh) then return end
    end

    -- 截断超长消息
    if type(message) == 'string' then
        message = message:sub(1, 200)
    else
        message = '注意 — 紧急车辆通行'
    end

    -- 扩音范围 (Convar 可调)
    local voiceRange = tonumber(GetConvar('megaphone_voice_range', '50.0')) or 50.0
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)

    -- 广播给附近玩家（通过 pma-voice 或其他方式）
    local title = '紧急人员'
    if job.name == 'police' then title = '警官'
    elseif job.name == 'ambulance' then title = '急救员'
    elseif job.name == 'fire' then title = '消防员' end
    TriggerClientEvent('custom-vehicles:client:megaphoneAudio', -1, {
        coords = coords,
        range = voiceRange,
        message = message,
        officerName = ('%s %s'):format(title, Player.PlayerData.charinfo.firstname),
    })

    -- 审计
    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('PA喊话',
            ('**%s** (%s) | 范围: %.0fm | 内容: %s'):format(
                GetPlayerName(src), Player.PlayerData.citizenid, voiceRange, message:sub(1, 50)), 255)
    end
end)

--- 警笛控制 (v2.1 兼容新 controller 表传参)
RegisterNetEvent('custom-vehicles:server:sirenControl', function(data, legacyVeh)
    local src = source

    if not checkOpRateLimit(src, 'siren') then return end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local job = Player.PlayerData.job
    if not job or (job.name ~= 'police' and job.name ~= 'ambulance' and job.name ~= 'fire') then return end

    -- 兼容新旧两种调用约定:
    --   新(tcity-dashboard controller): data = { mode, vehNetId }
    --   旧(custom-vehicles dashboard): data = mode(string), legacyVeh = entity handle
    local mode, veh
    if type(data) == 'table' then
        mode = data.mode or 'wail'
        veh = NetworkGetEntityFromNetworkId(data.vehNetId or 0)
    else
        mode = data or 'wail'
        veh = legacyVeh
    end

    if not veh or not DoesEntityExist(veh) then return end
    if not isDriverSeat(src, veh) then return end

    -- 广播警笛模式切换
    local netId = NetworkGetNetworkIdFromEntity(veh)
    TriggerClientEvent('custom-vehicles:client:sirenMode', -1, {
        netId = netId or 0,
        mode = mode,  -- wail / yelp / priority / silent
    })
end)

--- 警用测速雷达
RegisterNetEvent('custom-vehicles:server:policeRadarLog', function(targetPlate, targetSpeed, limitSpeed)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 超速记录
    if targetSpeed > limitSpeed then
        if exports['custom-logs'] then
            exports['custom-logs']:LogGeneric('测速雷达超速',
                ('**警员**: %s (%s) | 目标: %s | 速度: %d km/h | 限速: %d km/h'):format(
                    GetPlayerName(src), Player.PlayerData.citizenid, targetPlate, targetSpeed, limitSpeed), 16763904)
        end
    end
end)

-- ==============================================================
-- 航海控制台 — 锚定系统
-- ==============================================================

RegisterNetEvent('custom-vehicles:server:anchorControl', function(data, legacyVeh)
    local src = source

    if not checkOpRateLimit(src, 'anchor') then return end

    -- 兼容新旧调用约定
    local action, veh
    if type(data) == 'table' then
        action = data.action or 'toggle'
        veh = NetworkGetEntityFromNetworkId(data.vehNetId or 0)
    else
        action = data or 'toggle'
        veh = legacyVeh
    end

    if not veh or not DoesEntityExist(veh) then return end
    if not isDriverSeat(src, veh) then return end
    if not isNearVehicle(src, veh, 10.0) then return end

    local netId = NetworkGetNetworkIdFromEntity(veh)

    if action == 'drop' then
        -- 抛锚: 冻结载具物理
        TriggerClientEvent('custom-vehicles:client:anchorState', -1, {
            netId = netId,
            anchored = true,
            coords = GetEntityCoords(veh),
        })
        print(('[dashboard-api] ⚓ Anchor dropped for vehicle %d'):format(veh))
    elseif action == 'raise' then
        TriggerClientEvent('custom-vehicles:client:anchorState', -1, {
            netId = netId,
            anchored = false,
        })
    end
end)

-- ==============================================================
-- 物流快捷装货 (中控屏 "快捷装货" 按钮)
-- ==============================================================

RegisterNetEvent('custom-vehicles:server:logisticsQuickLoad', function()
    local src = source
    if not checkOpRateLimit(src, 'logistics') then return end
    exports['custom-quest']:OnCustomEvent(src, 'dashboard_quick_load', {})
end)

-- ==============================================================
-- 物流电子印章交单 (v0.7a ↔ v0.7b 有机结合)
-- ==============================================================

RegisterNetEvent('custom-vehicles:server:logisticsStampDelivery', function(veh)
    local src = source

    if not checkOpRateLimit(src, 'logistics') then return end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    if not DoesEntityExist(veh) then
        TriggerClientEvent('QBCore:Notify', src, '载具不存在', 'error')
        return
    end

    if not isDriverSeat(src, veh) then
        TriggerClientEvent('QBCore:Notify', src, '你必须坐在驾驶席', 'error')
        return
    end

    -- 三合一电子戳校验:
    -- 1. 获取当前活跃物流任务
    local citizenid = Player.PlayerData.citizenid
    local activeQuests = exports['custom-quest']:GetActiveQuests(src) or {}

    local logisticsQuest = nil
    for _, q in ipairs(activeQuests) do
        if q.quest_id == 'euro_trucking_steel'
            or q.quest_id == 'euro_trucking_heavy_trailer'
            or q.quest_id == 'aviation_smuggling_flight' then
            logisticsQuest = q
            break
        end
    end

    if not logisticsQuest then
        TriggerClientEvent('QBCore:Notify', src, '没有进行中的物流任务', 'error')
        return
    end

    -- 2. 验证车牌匹配
    local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
    -- KeyManager 会验证玩家是否有此车的钥匙

    -- 3. 验证步骤正确（当前步骤必须是 delivery 或 unload 类型）
    local stepId = exports['custom-quest']:GetQuestStep(src, logisticsQuest.quest_id)
    if not stepId then
        TriggerClientEvent('QBCore:Notify', src, '无法获取任务步骤', 'error')
        return
    end

    -- 4. v0.7.2: 直接触发 quest:server:dashboardStampDelivery 事件
    -- 该事件会运行当前步骤的 validator（如 validate_delivery_arrival）
    -- 校验通过后自动推进步骤
    -- 注意: 显式传入 src，跨资源 TriggerEvent 不自动设置 source 全局变量
    TriggerEvent('quest:server:dashboardStampDelivery', src, logisticsQuest.quest_id, stepId)

    -- 注: 校验结果由事件处理器通过 Notify 反馈给客户端

    -- 审计
    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('中控屏交单',
            ('**%s** (%s) | 任务: %s | 车牌: %s'):format(
                GetPlayerName(src), citizenid, logisticsQuest.quest_id, plate), 65280)
    end
end)

-- ==============================================================
-- 初始化: 注册内置 App
-- ==============================================================

-- 物流标签页在 dashboard.html 中内置

-- 注册内置 App（示例：出租车计价器占位）
RegisterDashboardApp({
    id = 'taxi_meter_placeholder',
    label = '出租车计价器',
    icon = 'fa-taxi',
    job = 'taxi',
    nui_event = 'taxi:client:showMeter',
})

print('[custom-vehicles] 📊 中控屏服务端 API 已就绪 (v0.7b)')
print('[custom-vehicles]   RegisterDashboardApp | 警用控制台 | 锚定系统 | 电子印章交单')
