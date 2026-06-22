-- testdrive.lua — 客户端试驾逻辑
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 职责:
--   1. 试驾开始 (TestDrive / customTestDrive)
--   2. 试驾计时器 (startTestDriveTimer)
--   3. 试驾归还 (TestDriveReturn)

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 试驾计时器
-- ==============================================================

function _vStartTestDriveTimer(testDriveTime, prevCoords)
    local gameTimer = GetGameTimer()
    CreateThread(function()
        Wait(2000) -- 等待玩家进入车辆
        while inTestDrive do
            if GetGameTimer() < gameTimer + tonumber(1000 * testDriveTime) then
                local secondsLeft = GetGameTimer() - gameTimer
                if secondsLeft >= tonumber(1000 * testDriveTime) - 20
                   or GetPedInVehicleSeat(NetToVeh(testDriveVeh), -1) ~= PlayerPedId() then
                    TriggerServerEvent('qb-vehicleshop:server:deleteVehicle', testDriveVeh, testDrivePlate)
                    testDriveVeh = 0
                    testDrivePlate = nil
                    inTestDrive = false
                    SetEntityCoords(PlayerPedId(), prevCoords)
                    QBCore.Functions.Notify(Lang:t('general.testdrive_complete'))
                end
                _vDrawTxt(Lang:t('general.testdrive_timer') .. math.ceil(testDriveTime - secondsLeft / 1000),
                    4, 0.5, 0.93, 0.50, 255, 255, 255, 180)
            end
            Wait(0)
        end
    end)
end

-- ==============================================================
-- 事件: 自由试驾
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:TestDrive', function()
    if inTestDrive or ClosestVehicle == 0 then return end

    inTestDrive = true
    local prevCoords = GetEntityCoords(PlayerPedId())
    tempShop = insideShop
    -- 使用唯一车牌避免钥匙冲突 (Phase 5 fix: 旧硬编码 'TESTDRIVE' 导致 compat 安全校验拦截)
    local testPlate = 'TD' .. tostring(math.random(100000, 999999))

    QBCore.Functions.TriggerCallback('qb-vehicleshop:server:spawnvehicle', function(netId, properties, vehPlate)
        local timeout = 5000
        local startTime = GetGameTimer()
        while not NetworkDoesNetworkIdExist(netId) do
            Wait(10)
            if GetGameTimer() - startTime > timeout then return end
        end
        local veh = NetworkGetEntityFromNetworkId(netId)
        NetworkRequestControlOfEntity(veh)
        SetEntityAsMissionEntity(veh, true, true)
        Citizen.InvokeNative(0xAD738C3085FE7E11, veh, true, true)
        SetVehicleNumberPlateText(veh, vehPlate)
        exports['LegacyFuel']:SetFuel(veh, 100)
        TriggerEvent('vehiclekeys:client:SetOwner', vehPlate)
        TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
        SetVehicleEngineOn(veh, true, true, false)
        testDriveVeh = netId
        testDrivePlate = vehPlate  -- Phase 5: 保存车牌用于后续清理
        QBCore.Functions.Notify(Lang:t('general.testdrive_timenoti',
            { testdrivetime = Config.Shops[tempShop]['TestDriveTimeLimit'] }), 'success')
    end, testPlate,
       Config.Shops[tempShop]['ShowroomVehicles'][ClosestVehicle].chosenVehicle,
       Config.Shops[tempShop]['TestDriveSpawn'], true)

    _vCreateTestDriveReturn()
    _vStartTestDriveTimer(Config.Shops[tempShop]['TestDriveTimeLimit'] * 60, prevCoords)
end)

-- ==============================================================
-- 事件: 员工发送试驾 (customTestDrive)
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:customTestDrive', function(data)
    if inTestDrive then
        QBCore.Functions.Notify(Lang:t('error.testdrive_alreadyin'), 'error')
        return
    end

    inTestDrive = true
    local vehicle = data
    local prevCoords = GetEntityCoords(PlayerPedId())
    tempShop = insideShop
    local testPlate = 'TD' .. tostring(math.random(100000, 999999))

    QBCore.Functions.TriggerCallback('qb-vehicleshop:server:spawnvehicle', function(netId, properties, vehPlate)
        local timeout = 5000
        local startTime = GetGameTimer()
        while not NetworkDoesNetworkIdExist(netId) do
            Wait(10)
            if GetGameTimer() - startTime > timeout then return end
        end
        local veh = NetworkGetEntityFromNetworkId(netId)
        NetworkRequestControlOfEntity(veh)
        SetEntityAsMissionEntity(veh, true, true)
        Citizen.InvokeNative(0xAD738C3085FE7E11, veh, true, true)
        SetVehicleNumberPlateText(veh, vehPlate)
        exports['LegacyFuel']:SetFuel(veh, 100)
        TriggerEvent('vehiclekeys:client:SetOwner', vehPlate)
        TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
        SetVehicleEngineOn(veh, true, true, false)
        testDriveVeh = netId
        testDrivePlate = vehPlate
        QBCore.Functions.Notify(Lang:t('general.testdrive_timenoti',
            { testdrivetime = Config.Shops[tempShop]['TestDriveTimeLimit'] }), 'success')
    end, testPlate, vehicle, Config.Shops[tempShop]['TestDriveSpawn'], true)

    _vCreateTestDriveReturn()
    _vStartTestDriveTimer(Config.Shops[tempShop]['TestDriveTimeLimit'] * 60, prevCoords)
end)

-- ==============================================================
-- 事件: 试驾归还
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:TestDriveReturn', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped)
    local entity = NetworkGetEntityFromNetworkId(testDriveVeh)
    if veh == entity then
        TriggerServerEvent('qb-vehicleshop:server:deleteVehicle', testDriveVeh, testDrivePlate)
        testDriveVeh = 0
        testDrivePlate = nil
        inTestDrive = false
        DeleteEntity(veh)
        exports['qb-menu']:closeMenu()
        testDriveZone:destroy()
    else
        QBCore.Functions.Notify(Lang:t('error.testdrive_return'), 'error')
    end
end)

print('[qb-vehicleshop] 🏎️  试驾模块已加载 (testdrive.lua)')
