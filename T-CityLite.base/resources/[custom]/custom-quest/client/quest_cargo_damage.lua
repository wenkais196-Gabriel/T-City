-- quest_cargo_damage.lua — 货物损伤追踪客户端模块 (v0.8b)
--
-- 职责: 监控车辆碰撞 → 累积损伤数据 → 交付时回传服务端用于奖励扣减
-- HUD: 不在此模块渲染 — 损伤数据由外部 HUD 系统按需读取
--
-- 激活: TriggerEvent('quest:client:cargoDamageStart', { questId, plate, maxPenaltyPct })
-- 停用: TriggerEvent('quest:client:cargoDamageStop')

local QBCore = exports['qb-core']:GetCoreObject()

local CargoTracker = {
    active = false,
    questId = nil,
    boundPlate = nil,
    initialBodyHealth = 0.0,
    initialEngineHealth = 0.0,
    currentBodyHealth = 0.0,
    currentEngineHealth = 0.0,
    collisionCount = 0,
    damagePct = 0.0,
    damageMaxPenalty = 30,
}

-- 供外部 HUD 系统查询当前损伤状态
exports('GetCargoDamage', function()
    if not CargoTracker.active then return nil end
    return {
        questId = CargoTracker.questId,
        damagePct = CargoTracker.damagePct,
        collisionCount = CargoTracker.collisionCount,
        maxPenalty = CargoTracker.damageMaxPenalty,
    }
end)

RegisterNetEvent('quest:client:cargoDamageStart', function(data)
    if not data then return end
    CargoTracker.active = true
    CargoTracker.questId = data.questId
    CargoTracker.boundPlate = data.plate
    CargoTracker.collisionCount = 0
    CargoTracker.damagePct = 0.0
    CargoTracker.damageMaxPenalty = data.maxPenaltyPct or 30

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh and veh ~= 0 then
        CargoTracker.initialBodyHealth = GetVehicleBodyHealth(veh) or 1000.0
        CargoTracker.initialEngineHealth = GetVehicleEngineHealth(veh) or 1000.0
        CargoTracker.currentBodyHealth = CargoTracker.initialBodyHealth
        CargoTracker.currentEngineHealth = CargoTracker.initialEngineHealth
    else
        CargoTracker.initialBodyHealth = 1000.0
        CargoTracker.initialEngineHealth = 1000.0
        CargoTracker.currentBodyHealth = 1000.0
        CargoTracker.currentEngineHealth = 1000.0
    end
end)

RegisterNetEvent('quest:client:cargoDamageStop', function()
    if not CargoTracker.active then return end
    local result = {
        questId = CargoTracker.questId,
        plate = CargoTracker.boundPlate,
        collisionCount = CargoTracker.collisionCount,
        damagePct = math.floor(CargoTracker.damagePct),
        bodyHealthDelta = math.max(0, CargoTracker.initialBodyHealth - CargoTracker.currentBodyHealth),
        engineHealthDelta = math.max(0, CargoTracker.initialEngineHealth - CargoTracker.currentEngineHealth),
    }
    TriggerServerEvent('quest:server:cargoDamageResult', result)
    CargoTracker.active = false
    CargoTracker.questId = nil
    CargoTracker.boundPlate = nil
    CargoTracker.collisionCount = 0
    CargoTracker.damagePct = 0.0
end)

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(500)
        if not CargoTracker.active then goto monitor_end end

        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if not veh or veh == 0 then goto monitor_end end

        local plate = GetVehicleNumberPlateText(veh)
        if plate then plate = tostring(plate):gsub('^%s+', ''):gsub('%s+$', '') end
        if CargoTracker.boundPlate and plate ~= CargoTracker.boundPlate then goto monitor_end end

        local bodyHealth = GetVehicleBodyHealth(veh) or 1000.0
        local engineHealth = GetVehicleEngineHealth(veh) or 1000.0
        local bodyDelta = CargoTracker.currentBodyHealth - bodyHealth
        local engineDelta = CargoTracker.currentEngineHealth - engineHealth

        if bodyDelta > 8.0 or engineDelta > 8.0 then
            CargoTracker.collisionCount = CargoTracker.collisionCount + 1
            if CargoTracker.collisionCount <= 3 then
                QBCore.Functions.Notify(('⚠️ 货物受损 %.0f%%'):format(CargoTracker.damagePct), 'error')
            end
        end

        local bodyDmgPct = math.max(0, (CargoTracker.initialBodyHealth - bodyHealth) / 10.0)
        local engineDmgPct = math.max(0, (CargoTracker.initialEngineHealth - engineHealth) / 10.0)
        CargoTracker.damagePct = math.min(CargoTracker.damageMaxPenalty, bodyDmgPct + engineDmgPct)
        CargoTracker.currentBodyHealth = bodyHealth
        CargoTracker.currentEngineHealth = engineHealth

        ::monitor_end::
    end
end)

print('[quest-cargo-damage] 📦 货物损伤追踪就绪 (v0.8b — 无内置HUD，exports.GetCargoDamage 供外部查询)')
