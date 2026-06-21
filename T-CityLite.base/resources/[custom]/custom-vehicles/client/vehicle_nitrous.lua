-- vehicle_nitrous.lua — custom-vehicles 氮气加速系统 (v0.9)
--
-- 职责:
--   1. 氮气加速效果 (每帧 Boost + 消耗)
--   2. 氮气火焰视觉同步
--   3. 氮气安装 (工具箱使用 nitrous 物品)
--   4. HUD 集成 (hud:client:UpdateNitrous)
--
-- 迁移自 qb-mechanicjob/client/nitrous.lua
-- 设计原则: 模块化·高性能·安全·可拓展

local QBCore = exports['qb-core']:GetCoreObject()
local vehicle, plate, netId
local nitrousActive = false
local nitrousVehicles = {}

local StateCfg = Config.Vehicles.State

-- ==============================================================
-- 氮气效果主循环 (每帧, 仅氮气激活时)
-- ==============================================================

local function ListenForNitrous()
    CreateThread(function()
        while true do
            Wait(0)
            if not vehicle then break end
            local ped = PlayerPedId()
            local isDriver = GetPedInVehicleSeat(vehicle, -1) == ped
            if isDriver then
                if IsControlJustPressed(0, 155) then
                    AnimpostfxPlay('RaceTurbo', 0, true)
                    TriggerServerEvent('custom-vehicles:server:syncNitrousFlames', netId, true)
                    -- 兼容旧事件
                    TriggerServerEvent('qb-mechanicjob:server:syncNitrousFlames', netId, true)
                    nitrousActive = true
                end
                if nitrousActive then
                    SetVehicleBoostActive(vehicle, true)
                    SetVehicleCheatPowerIncrease(vehicle, StateCfg.NitrousBoost)
                    nitrousVehicles[plate].level = nitrousVehicles[plate].level - StateCfg.NitrousUsage
                    TriggerEvent('hud:client:UpdateNitrous', nitrousVehicles[plate].level, nitrousVehicles[plate].hasnitro)
                end
                if IsControlJustReleased(0, 155) or nitrousVehicles[plate].level <= 0 then
                    nitrousActive = false
                    AnimpostfxStop('RaceTurbo')
                    SetVehicleBoostActive(vehicle, false)
                    TriggerServerEvent('custom-vehicles:server:syncNitrousFlames', netId, false)
                    TriggerServerEvent('qb-mechanicjob:server:syncNitrousFlames', netId, false)
                    if nitrousVehicles[plate].level <= 0 then
                        nitrousVehicles[plate].hasnitro = false
                        TriggerServerEvent('custom-vehicles:server:syncNitrous', plate, false)
                        TriggerServerEvent('qb-mechanicjob:server:syncNitrous', plate, false)
                        TriggerEvent('hud:client:UpdateNitrous', 0, false)
                        plate = nil
                        vehicle = nil
                        netId = nil
                        break
                    else
                        TriggerServerEvent('custom-vehicles:server:syncNitrous', plate, true, nitrousVehicles[plate].level)
                        TriggerServerEvent('qb-mechanicjob:server:syncNitrous', plate, true, nitrousVehicles[plate].level)
                    end
                end
            else
                plate = nil
                vehicle = nil
                netId = nil
                nitrousActive = false
                TriggerEvent('hud:client:UpdateNitrous', 0, false)
                break
            end
        end
    end)
end

-- ==============================================================
-- 上车检测: 检查该车是否有氮气
-- ==============================================================

AddEventHandler('gameEventTriggered', function(event)
    if event == 'CEventNetworkPlayerEnteredVehicle' then
        vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
        plate = QBCore.Functions.GetPlate(vehicle)
        netId = NetworkGetNetworkIdFromEntity(vehicle)

        QBCore.Functions.TriggerCallback('custom-vehicles:server:getNitrousVehicles', function(vehs)
            if vehs then nitrousVehicles = vehs end
            -- 回调返回后立即检查该车是否有氮气（非阻塞, 不 Wait）
            if nitrousVehicles[plate] and nitrousVehicles[plate].hasnitro and nitrousVehicles[plate].level > 0 then
                TriggerEvent('hud:client:UpdateNitrous', nitrousVehicles[plate].level, true)
                ListenForNitrous()
            end
        end)
    end
end)

-- ==============================================================
-- 事件: 氮气火焰同步
-- ==============================================================

RegisterNetEvent('custom-vehicles:client:syncNitrousFlames', function(net, toggle)
    if not NetworkDoesEntityExistWithNetworkId(net) then return end
    local veh = NetworkGetEntityFromNetworkId(net)
    SetVehicleNitroEnabled(veh, toggle)
end)

-- 兼容旧事件名
RegisterNetEvent('qb-mechanicjob:client:syncNitrousFlames', function(net, toggle)
    if not NetworkDoesEntityExistWithNetworkId(net) then return end
    local veh = NetworkGetEntityFromNetworkId(net)
    SetVehicleNitroEnabled(veh, toggle)
end)

-- ==============================================================
-- 工具函数 (从 qb-mechanicjob/main.lua 复制)
-- ==============================================================

local function ToggleHood(veh)
    if GetVehicleDoorAngleRatio(veh, 4) > 0.0 then
        SetVehicleDoorShut(veh, 4, false)
    else
        SetVehicleDoorOpen(veh, 4, false, false)
    end
end

local function IsNearBone(veh, bone)
    local playerCoords = GetEntityCoords(PlayerPedId())
    local vehicleBoneIndex = GetEntityBoneIndexByName(veh, bone)
    if vehicleBoneIndex ~= -1 then
        local bonePos = GetWorldPositionOfEntityBone(veh, vehicleBoneIndex)
        if #(playerCoords - bonePos) <= 1.5 then return true end
    end
    return false
end

-- ==============================================================
-- 事件: 安装氮气 (完整流程含 Progressbar)
-- ==============================================================

local function InstallNitrousFlow()
    if IsPedInAnyVehicle(PlayerPedId(), false) then return end
    local closestVehicle, distance = QBCore.Functions.GetClosestVehicle()
    if closestVehicle == 0 or distance > 5.0 then return end
    local vehicleClass = GetVehicleClass(closestVehicle)
    if StateCfg.IgnoreClasses[vehicleClass] then return end
    local vehiclePlate = QBCore.Functions.GetPlate(closestVehicle)
    if not vehiclePlate then return end
    if not IsNearBone(closestVehicle, 'engine') then return end

    ToggleHood(closestVehicle)
    QBCore.Functions.Progressbar('use_nos', 'Installing Nitrous...', 5000, false, true, {
        disableMovement = true,
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'mini@repair',
        anim = 'fixing_a_player',
        flags = 1,
    }, {
        model = 'imp_prop_impexp_span_03',
        bone = 28422,
        coords = vec3(0.06, 0.01, -0.02),
        rotation = vec3(0.0, 0.0, 0.0),
    }, {}, function()
        ToggleHood(closestVehicle)
        TriggerServerEvent('qb-mechanicjob:server:removeItem', 'nitrous')
        TriggerServerEvent('custom-vehicles:server:syncNitrous', vehiclePlate, true, 100)
        TriggerServerEvent('qb-mechanicjob:server:syncNitrous', vehiclePlate, true, 100)
        if not nitrousVehicles[vehiclePlate] then
            nitrousVehicles[vehiclePlate] = { hasnitro = true, level = 100 }
        else
            nitrousVehicles[vehiclePlate].hasnitro = true
            nitrousVehicles[vehiclePlate].level = 100
        end
    end, function()
        ToggleHood(closestVehicle)
    end)
end

RegisterNetEvent('custom-vehicles:client:installNitrous', InstallNitrousFlow)
-- 兼容旧事件名
RegisterNetEvent('qb-mechanicjob:client:installNitrous', InstallNitrousFlow)

-- ==============================================================
-- PTFX 预加载
-- ==============================================================

CreateThread(function()
    RequestNamedPtfxAsset('veh_xs_vehicle_mods')
    while not HasNamedPtfxAssetLoaded('veh_xs_vehicle_mods') do
        Wait(0)
        RequestNamedPtfxAsset('veh_xs_vehicle_mods')
    end
end)
