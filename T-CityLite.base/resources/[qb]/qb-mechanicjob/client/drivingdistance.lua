local vehicle, plate
local vehicleComponents = {}
local drivingDistance = {}
-- 防重复触发：记录每个部件是否已触发过故障效果（修理后清除）
local componentEffectTriggered = {}

-- Function

local function InitializeVehicleComponents()
    if not Config.UseWearableParts then return end
    vehicleComponents[plate] = {}
    for part, data in pairs(Config.WearableParts) do
        vehicleComponents[plate][part] = data.maxValue
    end
end

local function ApplyComponentEffect(component) -- add custom effects here for each component in config
    if component == 'radiator' then
        local engineHealth = GetVehicleEngineHealth(vehicle)
        SetVehicleEngineHealth(vehicle, engineHealth - 50)
    elseif component == 'axle' then
        for i = 0, 360 do
            Wait(15)
            SetVehicleSteeringScale(vehicle, i)
        end
    elseif component == 'brakes' then
        SetVehicleHandbrake(vehicle, true)
        Wait(5000)
        SetVehicleHandbrake(vehicle, false)
    elseif component == 'clutch' then
        SetVehicleEngineOn(vehicle, false, false, true)
        SetVehicleUndriveable(vehicle, true)
        Wait(5000)
        SetVehicleEngineOn(vehicle, true, false, true)
        SetVehicleUndriveable(vehicle, false)
    elseif component == 'fuel' then
        local fuel = exports[Config.FuelResource]:GetFuel(vehicle)
        exports[Config.FuelResource]:SetFuel(vehicle, fuel - 10)
    end
end

local function DamageRandomComponent()
    if not Config.UseWearableParts then return end
    local componentKeys = {}
    for component, _ in pairs(Config.WearableParts) do
        componentKeys[#componentKeys + 1] = component
    end
    local componentToDamage = componentKeys[math.random(#componentKeys)]
    vehicleComponents[plate][componentToDamage] = math.max(0, vehicleComponents[plate][componentToDamage] - Config.WearablePartsDamage)
    -- 只在首次跌破阈值时触发一次故障效果，防止反复触发（如散热器反复扣50引擎健康度导致不可逆着火）
    if vehicleComponents[plate][componentToDamage] <= Config.DamageThreshold then
        if not componentEffectTriggered[plate] then
            componentEffectTriggered[plate] = {}
        end
        if not componentEffectTriggered[plate][componentToDamage] then
            ApplyComponentEffect(componentToDamage)
            componentEffectTriggered[plate][componentToDamage] = true
        end
    end
end

local function GetDamageAmount(distance)
    for _, tier in ipairs(Config.MinimalMetersForDamage) do
        if distance >= tier.min and distance < tier.max then
            return tier.damage
        end
    end
    return 0
end

local function ApplyDamageBasedOnDistance(distance)
    if not Config.UseDistanceDamage then return end
    local damage = GetDamageAmount(distance)
    local engineHealth = GetVehicleEngineHealth(vehicle)
    SetVehicleEngineHealth(vehicle, engineHealth - damage)
end

local function TrackDistance()
    CreateThread(function()
        while true do
            Wait(0)
            if not vehicle then break end

            local ped = PlayerPedId()
            local isDriver = GetPedInVehicleSeat(vehicle, -1) == ped
            local speed = GetEntitySpeed(vehicle)

            if isDriver then
                if plate and speed > 5 then
                    if not drivingDistance[plate] then
                        drivingDistance[plate] = { distance = 0, lastCoords = GetEntityCoords(vehicle) }
                        InitializeVehicleComponents()
                    else
                        local newCoords = GetEntityCoords(vehicle)
                        local distance = #(drivingDistance[plate].lastCoords - newCoords)
                        if distance < 5 then
                            drivingDistance[plate].distance = drivingDistance[plate].distance + distance
                            drivingDistance[plate].lastCoords = newCoords
                            -- Engine damage
                            local accumulatedDistance = drivingDistance[plate].distance
                            if accumulatedDistance >= Config.MinimalMetersForDamage[1].min then
                                ApplyDamageBasedOnDistance(accumulatedDistance)
                            end
                            -- Parts Damage
                            local randomNumber = math.random(1, 1000)
                            if randomNumber <= Config.WearablePartsChance then
                                DamageRandomComponent()
                            end
                        end
                    end
                end
            else
                if drivingDistance[plate] then
                    TriggerServerEvent('qb-mechanicjob:server:updateDrivingDistance', plate, drivingDistance[plate].distance)
                    TriggerServerEvent('qb-mechanicjob:server:updateVehicleComponents', plate, vehicleComponents[plate])
                end
                plate = nil
                vehicle = nil
                break
            end
        end
    end)
end

-- 修理后重置所有磨损部件状态（来自 repair.lua 的 fix/fixEverything）
RegisterNetEvent('qb-mechanicjob:client:resetAllComponents', function(resetPlate)
    if not Config.UseWearableParts then return end
    if not resetPlate then return end
    resetPlate = Trim(resetPlate)
    if vehicleComponents[resetPlate] then
        for part, data in pairs(Config.WearableParts) do
            vehicleComponents[resetPlate][part] = data.maxValue
        end
    end
    -- 清除故障效果触发记录，允许再次触发（正常磨损流程）
    if componentEffectTriggered[resetPlate] then
        componentEffectTriggered[resetPlate] = nil
    end
end)

-- Handler

AddEventHandler('gameEventTriggered', function(event)
    if event == 'CEventNetworkPlayerEnteredVehicle' then
        if not Config.UseDistance then return end
        vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
        local originalPlate = GetVehicleNumberPlateText(vehicle)
        if not originalPlate then return end
        plate = Trim(originalPlate)
        local vehicleClass = GetVehicleClass(vehicle)
        if Config.IgnoreClasses[vehicleClass] then return end
        TrackDistance()
    end
end)
