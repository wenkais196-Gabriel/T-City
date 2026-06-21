-- dashboard.lua — 智能车载中控屏 (v0.8)
--
-- 事件驱动 + 按需推流:
--   - 速度/RPM/档位: 100ms (仅仪表盘打开时)
--   - 引擎/车身/油量/锁/涡轮/底栏: 事件触发 + 5s 兜底
--
-- 四原则: 模块化·高性能·安全·可拓展

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 状态
-- ==============================================================
local dashboardOpen = false
local currentVehicle = nil
local lastDiagPush = 0
local lastSlowPush = 0
local DIAG_INTERVAL = 200    -- 速度/RPM 轻量推 (200ms 足够平滑, 降低 NUI 压力)
local SLOW_INTERVAL = 5000   -- 引擎/车身/油量/底栏 兜底

-- 底栏缓存 (事件驱动时直接推，避免每帧采集)
local cachedTiresOk, cachedTiresTotal = 4, 4
local cachedDoorsOk, cachedDoorsTotal = 4, 4
local cachedSeats = {}

-- ==============================================================
-- NUI 唤醒/关闭
-- ==============================================================

local function toggleDashboard()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    -- 🔒 仅驾驶员(-1)或副驾驶(0)可打开, 其余座位拒绝
    if veh and veh ~= 0 then
        local seat = GetPedInVehicleSeat(veh, -1) == ped and -1 or
                     GetPedInVehicleSeat(veh, 0) == ped and 0 or -2
        if seat == -2 then
            QBCore.Functions.Notify('只有驾驶员或副驾驶可以打开中控屏', 'error')
            return
        end
    end
    if not veh or veh == 0 then
        if dashboardOpen then
            SetNuiFocus(false, false)
            SendNUIMessage({ type = 'close' })
            dashboardOpen = false
            currentVehicle = nil
        else
            QBCore.Functions.Notify('你必须坐在载具中才能打开中控屏', 'error')
        end
        return
    end

    if dashboardOpen then
        -- 释放排他锁
        if currentVehicle and DoesEntityExist(currentVehicle) then
            local closePlate = GetVehicleNumberPlateText(currentVehicle):gsub('^%s+', ''):gsub('%s+$', ''):upper()
            TriggerServerEvent('custom-vehicles:server:releaseDashboard', closePlate)
        end
        SetNuiFocus(false, false)
        SendNUIMessage({ type = 'close' })
        dashboardOpen = false
        currentVehicle = nil
    else
        local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
        -- 向服务端请求排他锁, 回调中打开
        TriggerServerEvent('custom-vehicles:server:requestDashboard', plate)
    end
end

-- I 键：由 NUI JS 处理 (SetNuiFocus 吃掉键盘, 游戏层收不到 I)
-- 保留 /dashboard 命令供 F8 控制台手动打开
RegisterCommand('dashboard', function()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh and veh ~= 0 then
        toggleDashboard()
    else
        QBCore.Functions.Notify('你必须坐在载具中才能打开中控屏', 'error')
    end
end, false)

-- ESC 关闭由 NUI JS 处理 (keydown Escape → fetch closeDashboard → NUI回调 → toggleDashboard)

-- ==============================================================
-- 高速推流: 速度/RPM/档位 (仅仪表盘打开)
-- ==============================================================

function sendDiagData()
    if not currentVehicle or not DoesEntityExist(currentVehicle) then
        if dashboardOpen then toggleDashboard() end
        return
    end
    local veh = currentVehicle
    local speed = GetEntitySpeed(veh) * 2.23694
    local rpm = GetVehicleCurrentRpm(veh) or 0
    -- 仅 3 字段, type='tick' 不触发 updateVehicleStatus
    SendNUIMessage({
        type = 'tick',
        speed = math.floor(speed),
        rpm = math.floor(rpm * 100),
    })
end

CreateThread(function()
    while true do
        local now = GetGameTimer()
        if dashboardOpen and currentVehicle and (now - lastDiagPush) >= DIAG_INTERVAL then
            lastDiagPush = now
            sendDiagData()
        end
        Wait(dashboardOpen and DIAG_INTERVAL or 1000)
    end
end)

-- ==============================================================
-- 低速推流: 引擎/车身/机油/水温/电池/涡轮/底栏
-- ==============================================================

function sendSlowData()
    if not currentVehicle or not DoesEntityExist(currentVehicle) then return end
    local veh = currentVehicle

    local engineHealth = GetVehicleEngineHealth(veh) or 1000
    local bodyHealth = GetVehicleBodyHealth(veh) or 1000
    local oilLevel = math.floor((engineHealth / 1000) * 100)
    local battery = (GetVehicleBatteryHealth and GetVehicleBatteryHealth(veh)) or 100
    local engineTemp = (engineHealth / 1000 * 90) + math.random(-2, 2)

    -- 涡轮检测
    local turboInstalled = false
    local turboPsi = 0.0
    if GetVehicleMod(veh, 18) ~= -1 then
        turboInstalled = true
        turboPsi = ((GetVehicleCurrentRpm(veh) or 0) * 2.5) + math.random(-0.1, 0.1) -- 模拟增压
    end
    local transTemp = 65 + (engineTemp * 0.3) + math.random(-1, 1)

    -- 巡航状态 (pcall 避免 export 未就绪时报错)
    local cruiseActive, cruiseSpeed = false, 0
    pcall(function() cruiseActive = exports['custom-vehicles']:IsCruiseActive() end)
    pcall(function() cruiseSpeed = exports['custom-vehicles']:GetCruiseSpeed() end)

    -- 双闪状态
    local hazardActive = false
    pcall(function() hazardActive = exports['custom-vehicles']:IsHazardActive() end)

    local driveMode = currentDriveModeCache or 'comfort'

    local speed = GetEntitySpeed(veh) * 2.23694
    local rpm = GetVehicleCurrentRpm(veh) or 0
    local fuel = GetVehicleFuelLevel(veh) or 0

    -- 底栏数据 (与 diag 合并)
    local tireStates, doorStates, numDoors, hoodOpen, trunkOpen, isConvertible, roofDown
    local tOk = pcall(function()
        tireStates = {}
        local numWheels = GetVehicleNumberOfWheels(veh)
        if not numWheels or numWheels < 1 then numWheels = 4 end
        for i = 0, numWheels - 1 do
            tireStates[#tireStates+1] = IsVehicleTyreBurst(veh, i, false) and 'burst' or 'ok'
        end
        numDoors = GetNumberOfVehicleDoors(veh)
        if not numDoors or numDoors < 1 then numDoors = 2 end
        if numDoors > 6 then numDoors = 4 end
        doorStates = {}
        for i = 0, numDoors - 1 do
            doorStates[#doorStates+1] = (GetVehicleDoorAngleRatio(veh, i) > 0.05) and 'open' or 'closed'
        end
        hoodOpen = GetVehicleDoorAngleRatio(veh, 4) > 0.05
        trunkOpen = GetVehicleDoorAngleRatio(veh, 5) > 0.05
        -- 敞篷: IsVehicleAConvertible 精准检测
        isConvertible = IsVehicleAConvertible(veh, 0)
        if isConvertible then
            local rs = GetVehicleRoofState(veh)
            roofDown = (rs and rs > 0)
        end
    end)
    if not tOk then tireStates, doorStates, numDoors = {'ok','ok','ok','ok'}, {'closed','closed','closed','closed'}, 4; hoodOpen, trunkOpen = false, false end
    -- 座位
    local maxSeats = GetVehicleMaxNumberOfPassengers(veh)
    local seats = {}
    for i = -1, maxSeats - 1 do
        if not IsVehicleSeatFree(veh, i) then
            local pid = GetPedInVehicleSeat(veh, i)
            if i == -1 or pid == PlayerPedId() then seats[#seats+1] = 'driver'
            else seats[#seats+1] = 'occupied' end
        else seats[#seats+1] = 'free' end
    end

    SendNUIMessage({
        type = 'diag',
        speed = math.floor(speed),
        rpm = math.floor(rpm * 100),
        fuel = math.floor(fuel),
        engine = engineHealth,
        body = bodyHealth,
        oil = oilLevel,
        battery = battery,
        coolant = engineTemp,
        turboInstalled = turboInstalled,
        turboPsi = turboPsi,
        transTemp = transTemp,
        cruiseActive = cruiseActive,
        cruiseSpeed = cruiseSpeed,
        hazardActive = hazardActive,
        driveMode = driveMode,
        tireStates = tireStates,
        doorStates = doorStates,
        hoodOpen = hoodOpen, trunkOpen = trunkOpen,
        isConvertible = isConvertible, roofDown = roofDown, numDoors = numDoors,
        seats = seats,
    })
end

-- 慢速兜底线程 (底栏已合并进 diag, 每 2s 一轮)
CreateThread(function()
    while true do
        Wait(SLOW_INTERVAL)
        if dashboardOpen and currentVehicle then
            sendSlowData()
        end
    end
end)

-- ==============================================================
-- ==============================================================
-- 服务端回调: 中控屏排他锁结果
-- ==============================================================

RegisterNetEvent('custom-vehicles:client:dashboardLockResult', function(granted, errMsg)
    if granted then
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        if not veh or veh == 0 then return end
        currentVehicle = veh
        SetNuiFocus(true, true)
        local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
        local model = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
        local class = GetVehicleClass(veh)
        -- 先发 open 唤醒 DOM, 再立即推数据 (避免 diag 在 DOM 就绪前到达)
        SendNUIMessage({ type = 'open', plate = plate, model = model, class = class })
        dashboardOpen = true
        Citizen.Wait(50)  -- 等一帧让 NUI 完成 _buildDOM
        sendSlowData()
    else
        QBCore.Functions.Notify(errMsg or '无法打开中控屏', 'error')
    end
end)

-- ==============================================================
-- 驾驶模式: 服务端广播 → 本客户端执行 (确保车内所有人统一)
-- ==============================================================

RegisterNetEvent('custom-vehicles:client:applyDriveMode', function(vehNetId, mode)
    local veh = NetworkGetEntityFromNetworkId(vehNetId)
    if not veh or veh == 0 then return end
    -- 仅车内乘员应用模式 (服务端广播 -1, 不在车内的人忽略)
    local myVeh = GetVehiclePedIsIn(PlayerPedId(), false)
    if myVeh ~= veh then return end
    applyDriveMode(veh, mode)
    currentDriveModeCache = mode
    -- 如果中控屏开着, 推送最新模式给 JS
    if dashboardOpen then
        SendNUIMessage({ type = 'driveMode', mode = mode, turboInstalled = (GetVehicleMod(veh, 18) ~= -1) })
    end
end)

-- ==============================================================
-- 事件驱动: 锁/引擎变化 → 即时推
-- ==============================================================

-- 锁状态变更 (L 键触发)
AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkPlayerEnteredVehicle' and dashboardOpen then
        sendSlowData()
    end
end)

-- ==============================================================
-- NUI 回调
-- ==============================================================

RegisterNUICallback('dashboardCtrl', function(data, cb)
    if not currentVehicle or not DoesEntityExist(currentVehicle) then cb('fail'); return end
    local action = data.action
    local ped = PlayerPedId()
    local inDriverSeat = GetPedInVehicleSeat(currentVehicle, -1) == ped

    if action == 'engine' then
        if not inDriverSeat then QBCore.Functions.Notify('只有驾驶员可以操作引擎', 'error'); cb('fail'); return end
        local state = GetIsVehicleEngineRunning(currentVehicle)
        SetVehicleEngineOn(currentVehicle, not state, true, true)
    elseif action == 'lock' then
        local lockState = GetVehicleDoorLockStatus(currentVehicle)
        SetVehicleDoorsLocked(currentVehicle, lockState < 2 and 2 or 0)
        TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 5.0, lockState < 2 and 'lock' or 'unlock', 0.3)
    elseif action == 'windows_up' then
        for i = 0, 3 do RollUpWindow(currentVehicle, i) end
    elseif action == 'windows_down' then
        for i = 0, 3 do RollDownWindow(currentVehicle, i) end
    elseif action == 'hood' then
        local open = GetVehicleDoorAngleRatio(currentVehicle, 4) > 0.05
        if open then SetVehicleDoorShut(currentVehicle, 4, false) else SetVehicleDoorOpen(currentVehicle, 4, false, false) end
    elseif action == 'trunk' then
        local open = GetVehicleDoorAngleRatio(currentVehicle, 5) > 0.05
        if open then SetVehicleDoorShut(currentVehicle, 5, false) else SetVehicleDoorOpen(currentVehicle, 5, false, false) end
    elseif action == 'door_d' then
        local open = GetVehicleDoorAngleRatio(currentVehicle, 0) > 0.05
        if open then SetVehicleDoorShut(currentVehicle, 0, false) else SetVehicleDoorOpen(currentVehicle, 0, false, false) end
    elseif action == 'door_p' then
        local open = GetVehicleDoorAngleRatio(currentVehicle, 1) > 0.05
        if open then SetVehicleDoorShut(currentVehicle, 1, false) else SetVehicleDoorOpen(currentVehicle, 1, false, false) end
    elseif action == 'door_rl' then
        local open = GetVehicleDoorAngleRatio(currentVehicle, 2) > 0.05
        if open then SetVehicleDoorShut(currentVehicle, 2, false) else SetVehicleDoorOpen(currentVehicle, 2, false, false) end
    elseif action == 'door_rr' then
        local open = GetVehicleDoorAngleRatio(currentVehicle, 3) > 0.05
        if open then SetVehicleDoorShut(currentVehicle, 3, false) else SetVehicleDoorOpen(currentVehicle, 3, false, false) end
    elseif action == 'roof' then
        if IsVehicleAConvertible(currentVehicle, 0) then
            local roofState = GetVehicleRoofState(currentVehicle)
            if roofState == 0 then
                RaiseConvertibleRoof(currentVehicle, true)
                QBCore.Functions.Notify('敞篷: 正在打开', 'primary')
            else
                LowerConvertibleRoof(currentVehicle, true)
                QBCore.Functions.Notify('敞篷: 正在关闭', 'primary')
            end
        else
            QBCore.Functions.Notify('该载具不是敞篷车', 'error')
        end
    elseif action == 'alarm' then
        if not inDriverSeat then QBCore.Functions.Notify('只有驾驶员可以操作警报', 'error'); cb('fail'); return end
        if IsVehicleAlarmActivated(currentVehicle) then
            SetVehicleAlarm(currentVehicle, false)
            SetVehicleAlarmTimeLeft(currentVehicle, 0)
            QBCore.Functions.Notify('紧急警报: 已关闭', 'primary')
        else
            SetVehicleAlarm(currentVehicle, true)
            StartVehicleAlarm(currentVehicle)
            QBCore.Functions.Notify('紧急警报: 已激活 (喇叭+双闪)', 'success')
        end
    elseif action == 'cargo_door' then
        local open = GetVehicleDoorAngleRatio(currentVehicle, 5) > 0.05
        if open then SetVehicleDoorShut(currentVehicle, 5, false) else SetVehicleDoorOpen(currentVehicle, 5, false, false) end
    elseif action == 'water_cannon' then
        QBCore.Functions.Notify('水炮功能开发中，敬请期待', 'primary')
    end
    cb('ok')
end)

RegisterNUICallback('closeDashboard', function(_, cb)
    if dashboardOpen then
        toggleDashboard()
    end
    cb('ok')
end)

-- 🚨 双闪 (通过事件触发，避免同资源 exports 兼容问题)
RegisterNUICallback('hazardToggle', function(_, cb)
    TriggerEvent('custom-vehicles:client:toggleHazard')
    cb('ok')
end)

-- 🚀 驾驶模式 (走服务端广播, 确保车内所有乘员统一)
local currentDriveModeCache = 'comfort'

RegisterNUICallback('driveMode', function(data, cb)
    local mode = data.mode
    if not currentVehicle or not DoesEntityExist(currentVehicle) then cb('fail'); return end
    local netId = NetworkGetNetworkIdFromEntity(currentVehicle)
    if netId and netId ~= 0 then
        TriggerServerEvent('custom-vehicles:server:setDriveMode', netId, mode)
    end
    cb('ok')
end)

-- 💾 巡航目标速度保存 (供 U 键速启用)
RegisterNUICallback('setCruiseTarget', function(data, cb)
    local targetMph = data.targetMph
    if targetMph and targetMph > 0 then
        _CRUISE_TARGET_MPH = targetMph
        QBCore.Functions.Notify(('巡航目标已保存: %.0f mph · 按 U 启动'):format(targetMph), 'success')
    end
    cb('ok')
end)

-- 保持原有回调
RegisterNUICallback('megaphoneToggle', function(data, cb)
    if not currentVehicle then cb('fail'); return end
    TriggerServerEvent('custom-vehicles:server:megaphone', data.message or '警察！靠边停车！')
    cb('ok')
end)

RegisterNUICallback('anchorToggle', function(data, cb)
    if not currentVehicle then cb('fail'); return end
    local action = data.dropped and 'raise' or 'drop'
    TriggerServerEvent('custom-vehicles:server:anchorControl', action, currentVehicle)
    cb('ok')
end)

RegisterNUICallback('logisticsDeliver', function(_, cb)
    if not currentVehicle then cb({ success = false, message = 'No vehicle' }); return end
    TriggerServerEvent('custom-vehicles:server:logisticsStampDelivery', currentVehicle)
    cb({ success = true, message = '电子印章交单请求已发送' })
end)

RegisterNUICallback('logisticsLoad', function(_, cb)
    TriggerServerEvent('custom-vehicles:server:logisticsQuickLoad')
    cb('ok')
end)

RegisterNUICallback('openApp', function(data, cb)
    if data and data.nuiEvent then TriggerEvent(data.nuiEvent) end
    cb('ok')
end)

RegisterNUICallback('policeRadar', function(_, cb)
    if not currentVehicle then cb({}); return end
    local vehCoords = GetEntityCoords(currentVehicle)
    local vehHeading = GetEntityHeading(currentVehicle)
    local targets = {}
    local allVehicles = GetGamePool('CVehicle')
    for _, targetVeh in ipairs(allVehicles) do
        if targetVeh ~= currentVehicle then
            local tCoords = GetEntityCoords(targetVeh)
            local dist = #(vehCoords - tCoords)
            if dist < 30 then
                local angle = math.abs(vehHeading - GetEntityHeading(targetVeh))
                if angle < 45 or angle > 315 then
                    local tSpeed = GetEntitySpeed(targetVeh) * 2.23694  -- mph
                    local tPlate = GetVehicleNumberPlateText(targetVeh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
                    local tModel = GetDisplayNameFromVehicleModel(GetEntityModel(targetVeh))
                    targets[#targets + 1] = { plate = tPlate, model = tModel, speed = math.floor(tSpeed), distance = math.floor(dist) }
                end
            end
        end
    end
    cb(targets)
end)

RegisterNUICallback('megaphone', function(data, cb)
    TriggerServerEvent('custom-vehicles:server:megaphone', data.message or '')
    cb('ok')
end)

RegisterNUICallback('sirenControl', function(data, cb)
    if not currentVehicle then cb('fail'); return end
    TriggerServerEvent('custom-vehicles:server:sirenControl', data.mode or 'wail', currentVehicle)
    cb('ok')
end)

RegisterNUICallback('aviationAltimeter', function(_, cb)
    if not currentVehicle then cb({}); return end
    local coords = GetEntityCoords(currentVehicle)
    local groundZ = 0.0
    local found, waterZ = GetWaterHeight(coords.x, coords.y, coords.z)
    if found and waterZ > groundZ then groundZ = waterZ end
    cb({ altitude = math.floor(coords.z - groundZ), groundLevel = math.floor(groundZ) })
end)

RegisterNUICallback('anchorControl', function(data, cb)
    if not currentVehicle then cb('fail'); return end
    TriggerServerEvent('custom-vehicles:server:anchorControl', data.action or 'drop', currentVehicle)
    cb('ok')
end)

-- ==============================================================
-- 驾驶模式应用 (操纵车辆物理)
-- ==============================================================

function applyDriveMode(veh, mode)
    if not veh or veh == 0 then return end

    -- 模式参数: { fInitialDriveForce, fSteeringLock, fSuspensionForce, fBrakeForce }
    local modes = {
        comfort    = { 0.85, 1.0,  0.85, 1.0  },
        sport      = { 1.15, 0.85, 1.2,  1.05 },
        eco        = { 0.70, 1.0,  0.9,  1.0  },
        freight    = { 1.1,  1.05, 1.0,  1.15 },
        offroad    = { 1.0,  1.0,  1.3,  1.0  },
    }

    local params = modes[mode]
    if not params then return end

    if params[1] then SetVehicleHandlingFloat(veh, 'fInitialDriveForce', params[1]) end
    if params[2] then SetVehicleHandlingFloat(veh, 'fSteeringLock', params[2]) end
    if params[3] then SetVehicleHandlingFloat(veh, 'fSuspensionForce', params[3]) end
    if params[4] then SetVehicleHandlingFloat(veh, 'fBrakeForce', params[4]) end

    local modeLabels = { comfort = '🏖️ 舒适', sport = '🚗 运动', eco = '🌿 经济', freight = '📦 货运', offroad = '🏔️ 越野' }
    QBCore.Functions.Notify('驾驶模式: ' .. (modeLabels[mode] or mode), 'success')
end

-- ==============================================================
-- 巡航状态事件 (从 cruise.lua 接收)
-- ==============================================================

RegisterNetEvent('custom-vehicles:client:cruiseState', function(active, speed)
    if dashboardOpen then
        SendNUIMessage({ type = 'cruise', active = active, speed = speed })
    end
end)

-- ==============================================================
-- Exports
-- ==============================================================

exports('IsDashboardOpen', function() return dashboardOpen end)
exports('ToggleDashboard', function() toggleDashboard() end)

-- 监听 quest + app 注册
RegisterNetEvent('quest:client:stepAdvanced', function(data)
    if dashboardOpen then
        SendNUIMessage({ type = 'logistics', questId = data.quest_id, stepTitle = data.next_step_title, stepDesc = data.next_step_description })
    end
end)

RegisterNetEvent('custom-vehicles:client:registerApp', function(appData)
    if dashboardOpen then
        SendNUIMessage({ type = 'registerApp', app = appData })
    end
end)

print('[custom-vehicles] 📊 车载中控屏 v0.8 — 事件驱动 + 驾驶模式 + 底栏 + 夜间 | MPH')
