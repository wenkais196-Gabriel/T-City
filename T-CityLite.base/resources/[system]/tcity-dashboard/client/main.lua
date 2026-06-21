-- client/main.lua — 入车/下车状态机 (v2.0)
--
-- 核心流程:
--   1. gameEventTriggered 检测玩家入车 → 启动
--   2. 按 vehicleClass 确定模板 + 轮询间隔
--   3. 发送 NUI 'open' 消息 (含模板/主题/features)
--   4. 启动 Poller.Start(veh, template, interval)
--   5. 玩家下车/换座 → Poller.Stop() → NUI 'close'
--   6. NUI 回调 → Controller.Execute(action, params)
--
-- 零 Tick 开销: 下车后无任何循环在跑

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 状态
-- ==============================================================
local _isDashboardOpen = false
local _isSeatPickerOpen = false
local _currentVehicle = nil
local _currentTemplate = nil
local _currentPollInterval = 200

-- ==============================================================
-- NUI 生命周期
-- ==============================================================

local function _openNui(veh)
    if not veh or veh == 0 then return end

    local ped = PlayerPedId()
    -- 仅驾驶席或副驾可打开
    if not (GetPedInVehicleSeat(veh, -1) == ped or GetPedInVehicleSeat(veh, 0) == ped) then
        QBCore.Functions.Notify('只有驾驶员或副驾驶可以打开中控屏', 'error')
        return
    end

    -- 锁请求 (使用 custom-vehicles 现有排他锁系统)
    local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
    TriggerServerEvent('custom-vehicles:server:requestDashboard', plate)
end

local function _closeNui()
    if not _isDashboardOpen then return end
    if _currentVehicle and DoesEntityExist(_currentVehicle) then
        local plate = GetVehicleNumberPlateText(_currentVehicle):gsub('^%s+', ''):gsub('%s+$', ''):upper()
        TriggerServerEvent('custom-vehicles:server:releaseDashboard', plate)
    end
    Poller.Stop()
    PoliceModule.Deactivate()
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'close' })
    _isDashboardOpen = false
    _currentVehicle = nil
    _currentTemplate = nil
end

-- ==============================================================
-- 后排换座浮层 (Plan C)
-- ==============================================================

local function _openSeatPicker(veh, currentSeat)
    if not veh or veh == 0 then return end

    local localPed = PlayerPedId()
    local maxPassengers = GetVehicleMaxNumberOfPassengers(veh)
    if not maxPassengers or maxPassengers < 1 then maxPassengers = 3 end

    local seats = {}
    for i = -1, maxPassengers - 1 do
        local ped = GetPedInVehicleSeat(veh, i)
        seats[#seats + 1] = {
            index = i,
            occupied = (ped ~= 0),
            isPlayer = (ped == localPed),
        }
    end

    SendNUIMessage({
        type = 'seatPicker',
        seats = seats,
        currentSeat = currentSeat,
    })

    SetNuiFocus(true, true)
    _isSeatPickerOpen = true
end

local function _closeSeatPicker()
    if not _isSeatPickerOpen then return end
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'close' })
    _isSeatPickerOpen = false
end

-- ==============================================================
-- 服务端锁回调
-- ==============================================================

-- 监听旧 custom-vehicles 排他锁回调 (复用现有锁系统)
RegisterNetEvent('custom-vehicles:client:dashboardLockResult', function(granted, errMsg)
    if not granted then
        QBCore.Functions.Notify(errMsg or '无法打开中控屏', 'error')
        return
    end

    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if not veh or veh == 0 then return end

    -- 确定模板
    local vclass = GetVehicleClass(veh)
    local template, pollInterval = DashboardConfig.GetTemplate(vclass)
    local theme = DashboardThemes.ToNuiPayload(template)
    local features = DashboardConfig.FeatureFlags[template] or {}

    -- 采集初始 snapshot
    local snapshot = Poller.Snapshot(veh, template)

    -- 合成 NUI 数据
    local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
    local model = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
    local seats = GetVehicleMaxNumberOfPassengers(veh)
    local isConvertible = IsVehicleAConvertible(veh, 0)

    -- 🏷️ 车辆特征标签
    local vehicleModel = GetEntityModel(veh)
    local vehicleTags = {}
    if isConvertible then vehicleTags[#vehicleTags + 1] = '敞篷' end
    -- (涡轮增压已在诊断页 RPM 仪表中追踪，不重复打标签)
    -- 霓虹灯
    local hasNeon = false
    for i = 0, 3 do if IsVehicleNeonLightEnabled(veh, i) then hasNeon = true; break end end
    if not hasNeon and GetVehicleMod(veh, 22) ~= -1 then hasNeon = true end
    if hasNeon then vehicleTags[#vehicleTags + 1] = '霓虹灯' end
    -- 防弹轮胎
    if not GetVehicleTyresCanBurst(veh) then vehicleTags[#vehicleTags + 1] = '防弹轮胎' end
    -- 武装
    if DoesVehicleHaveWeapons(veh) then vehicleTags[#vehicleTags + 1] = '武装载具' end
    -- 防弹装甲
    if GetVehicleMod(veh, 16) ~= -1 then vehicleTags[#vehicleTags + 1] = '防弹装甲' end
    -- 水炮 (消防车)
    if vehicleModel == GetHashKey('firetruk') then vehicleTags[#vehicleTags + 1] = '水炮' end
    -- 警笛 (紧急服务车辆)
    if vclass == 18 then vehicleTags[#vehicleTags + 1] = '警笛' end
    -- 特殊车型标识
    if template == 'boat' then vehicleTags[#vehicleTags + 1] = '船只' end
    if template == 'plane' then vehicleTags[#vehicleTags + 1] = '飞机' end
    if template == 'helicopter' then vehicleTags[#vehicleTags + 1] = '直升机' end

    -- 职业数据
    local playerData = QBCore.Functions.GetPlayerData()
    local job = playerData and playerData.job or {}
    local jobName = job.name or 'unemployed'

    -- 发送 open → NUI 渲染
    SendNUIMessage({
        type = 'open',
        plate = plate,
        model = model,
        class = vclass,
        template = template,
        theme = theme,
        features = features,
        seats = seats,
        isConvertible = isConvertible,
        vehicleTags = vehicleTags,
        job = jobName,
        snapshot = snapshot,
    })

    -- 启动 NUI focus
    SetNuiFocus(true, true)
    _isDashboardOpen = true
    _currentVehicle = veh
    _currentTemplate = template
    _currentPollInterval = pollInterval

    -- 启动轮询
    Poller.Start(veh, template, pollInterval)

    -- v2.1: 警车模块激活
    if jobName == 'police' and vclass == 18 then
        PoliceModule.Activate()
    end

    -- 再推一次 diag (确保 DOM 渲染后数据到位)
    Citizen.Wait(100)
    local data = Poller.Snapshot(veh, template)
    if data then
        SendNUIMessage({ type = 'diag', data = data })
    end
end)

-- ==============================================================
-- 入车/下车检测 (事件驱动)
-- ==============================================================

AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkPlayerEnteredVehicle' then
        if _isDashboardOpen then _closeNui() end
        if _isSeatPickerOpen then _closeSeatPicker() end
    end
end)

-- 玩家死亡/离开载具 → 关闭面板
CreateThread(function()
    while true do
        Wait(2000)
        if _isDashboardOpen then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if not veh or veh == 0 then
                _closeNui()
            elseif veh ~= _currentVehicle then
                _closeNui()
            end
        end
        if _isSeatPickerOpen then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if not veh or veh == 0 then
                _closeSeatPicker()
            end
        end
    end
end)

-- ==============================================================
-- 按键: I 打开中控屏
-- ==============================================================

RegisterCommand('dashboard', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then
        QBCore.Functions.Notify('你必须坐在载具中才能打开中控屏', 'error')
        return
    end

    -- 后排乘客按 I → 换座浮层 (Plan C)
    if not _isDashboardOpen then
        for seatIdx = 1, 10 do
            if GetPedInVehicleSeat(veh, seatIdx) == ped then
                _openSeatPicker(veh, seatIdx)
                return
            end
        end
    end

    -- 驾驶/副驾 → 完整中控屏
    if _isDashboardOpen then
        _closeNui()
    else
        _openNui(veh)
    end
end, false)

-- 按键绑定 (I)
RegisterKeyMapping('dashboard', '智能中控屏', 'keyboard', 'I')

-- ==============================================================
-- NUI 回调: 关闭
-- ==============================================================

RegisterNUICallback('closeDashboard', function(_, cb)
    if _isDashboardOpen then _closeNui() end
    if _isSeatPickerOpen then _closeSeatPicker() end
    cb('ok')
end)

RegisterNUICallback('closeSeatPicker', function(_, cb)
    _closeSeatPicker()
    cb('ok')
end)

-- ==============================================================
-- NUI 回调: 动作执行
-- ==============================================================

RegisterNUICallback('dashboardAction', function(data, cb)
    local action = data and data.action
    local params = data and data.params
    local ok, msg = Controller.Execute(action, params)
    if msg then
        QBCore.Functions.Notify(msg, ok and 'success' or 'error')
    end
    cb({ success = ok, message = msg })
end)

-- ==============================================================
-- NUI 回调: 查询 (本地只读)
-- ==============================================================

RegisterNUICallback('dashboardQuery', function(data, cb)
    local query = data and data.query
    if query == 'radar' then
        -- 测速雷达: 扫描附近车辆
        local veh = _currentVehicle
        if not veh or not DoesEntityExist(veh) then cb({}); return end
        local coords = GetEntityCoords(veh)
        local heading = GetEntityHeading(veh)
        local targets = {}
        for _, tv in ipairs(GetGamePool('CVehicle')) do
            if tv ~= veh then
                local tc = GetEntityCoords(tv)
                local dist = #(coords - tc)
                if dist < 30 then
                    local angle = math.abs(heading - GetEntityHeading(tv))
                    if angle < 45 or angle > 315 then
                        targets[#targets + 1] = {
                            plate = GetVehicleNumberPlateText(tv):gsub('^%s+', ''):gsub('%s+$', ''):upper(),
                            model = GetDisplayNameFromVehicleModel(GetEntityModel(tv)),
                            speed = math.floor(GetEntitySpeed(tv) * 2.23694),
                            distance = math.floor(dist),
                        }
                    end
                end
            end
        end
        cb(targets)
    elseif query == 'altimeter' then
        local veh = _currentVehicle
        if not veh then cb({}); return end
        local c = GetEntityCoords(veh)
        local _, ground = GetGroundZFor_3dCoord(c.x, c.y, c.z, 0)
        cb({ altitude = math.floor(c.z), aboveGround = math.floor(c.z - (ground or 0)) })
    elseif query == 'depth' then
        local veh = _currentVehicle
        if not veh then cb({}); return end
        local c = GetEntityCoords(veh)
        local _, waterZ = GetWaterHeight(c.x, c.y, c.z)
        cb({ depth = waterZ and math.floor(math.abs(waterZ - c.z)) or 0 })
    elseif query == 'camera_list' then
        -- 返回可用监控摄像头列表 (使用 tcity-dashboard 自带的摄像头配置)
        local cameras = {}
        if DashboardConfig and DashboardConfig.SecurityCameras and DashboardConfig.SecurityCameras.cameras then
            for id, cam in pairs(DashboardConfig.SecurityCameras.cameras) do
                cameras[#cameras + 1] = { id = id, label = cam.label, canRotate = cam.canRotate }
            end
        end
        cb(cameras)
    else
        cb({})
    end
end)

-- ==============================================================
-- 外部事件: 巡航状态 → 推 NUI
-- ==============================================================

RegisterNetEvent('custom-vehicles:client:cruiseState', function(active, speed, mode, roadLimit)
    if _isDashboardOpen then
        SendNUIMessage({ type = 'cruise', active = active, speed = speed, mode = mode or 'none', roadLimit = roadLimit or 0 })
    end
end)

-- ==============================================================
-- 外部事件: 驾驶模式广播
-- ==============================================================

RegisterNetEvent('custom-vehicles:client:applyDriveMode', function(vehNetId, mode)
    if _isDashboardOpen then
        SendNUIMessage({ type = 'driveMode', mode = mode })
    end
end)

-- ==============================================================
-- Exports
-- ==============================================================

exports('IsDashboardOpen', function() return _isDashboardOpen end)
exports('GetCurrentTemplate', function() return _currentTemplate end)

-- 外部 App 注册 (兼容旧接口)
RegisterNetEvent('custom-vehicles:client:registerApp', function(appData)
    if _isDashboardOpen then
        SendNUIMessage({ type = 'registerApp', app = appData })
    end
end)

print('[tcity-dashboard] 🚗 客户端状态机已就绪 (v2.0)')
print('[tcity-dashboard]   模板: sports | commercial | emergency | plane | helicopter | boat')
print('[tcity-dashboard]   按键: I = 开关中控屏')
