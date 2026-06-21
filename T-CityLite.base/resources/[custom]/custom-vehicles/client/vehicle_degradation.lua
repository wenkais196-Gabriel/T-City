-- vehicle_degradation.lua — custom-vehicles 车辆损耗系统 (v0.9)
--
-- 职责:
--   1. 里程追踪 (500ms Tick, 非每帧)
--   2. 引擎健康度损耗 (里程阶梯, 每档只扣一次 — 修复原版帧级重复扣血 Bug)
--   3. 磨损部件随机降级 (散热器/车轴/刹车/离合器/燃油管)
--   4. 部件故障效果触发 (首次跌破阈值触发, 防重复)
--
-- 🔧 修复: 原 qb-mechanicjob/drivingdistance.lua 的 ApplyDamageBasedOnDistance
--    在 Wait(0) 循环中每帧调用, 导致引擎在跨越 5000m 后 ~1.7 秒烧毁。
--    本文件增加 distanceDamageApplied[plate] 防重复标记, 同一档位只扣一次。
--
-- 设计原则: 模块化·高性能·安全·可拓展

local vehicle, plate
local vehicleComponents = {}
local drivingDistance = {}
-- 🛠️ 防重复: 记录已应用过的引擎损耗档位 (修理后清除)
local distanceDamageApplied = {}
-- 防重复: 记录每个部件是否已触发过故障效果 (修理后清除)
local componentEffectTriggered = {}

-- ==============================================================
-- 配置别名 (减少重复路径)
-- ==============================================================

local StateCfg = Config.Vehicles.State

-- ==============================================================
-- 部件初始化
-- ==============================================================

local function InitializeVehicleComponents()
    if not StateCfg.UseWearableParts then return end
    vehicleComponents[plate] = {}
    for part, data in pairs(StateCfg.WearableParts) do
        vehicleComponents[plate][part] = data.maxValue
    end
    -- 重置防重复标记
    distanceDamageApplied[plate] = nil
    componentEffectTriggered[plate] = nil
end

-- ==============================================================
-- 部件故障效果
-- ==============================================================

local function ApplyComponentEffect(component)
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
        local fuel = exports[StateCfg.FuelResource]:GetFuel(vehicle)
        exports[StateCfg.FuelResource]:SetFuel(vehicle, fuel - 10)
    end
end

-- ==============================================================
-- 随机部件损耗
-- ==============================================================

local function DamageRandomComponent()
    if not StateCfg.UseWearableParts then return end
    local componentKeys = {}
    for component in pairs(StateCfg.WearableParts) do
        componentKeys[#componentKeys + 1] = component
    end
    local componentToDamage = componentKeys[math.random(#componentKeys)]
    local wearAmount = math.random(1, 2)  -- 与原始逻辑一致的随机损耗量
    vehicleComponents[plate][componentToDamage] = math.max(0, vehicleComponents[plate][componentToDamage] - wearAmount)

    -- 只在首次跌破阈值时触发一次故障效果
    if vehicleComponents[plate][componentToDamage] <= StateCfg.DamageThreshold then
        if not componentEffectTriggered[plate] then
            componentEffectTriggered[plate] = {}
        end
        if not componentEffectTriggered[plate][componentToDamage] then
            ApplyComponentEffect(componentToDamage)
            componentEffectTriggered[plate][componentToDamage] = true
        end
    end
end

-- ==============================================================
-- 引擎里程损耗 (🔧 修复: 档位防重复)
-- ==============================================================

local function GetDamageAmount(distance)
    for _, tier in ipairs(StateCfg.MinimalMetersForDamage) do
        if distance >= tier.min and distance < tier.max then
            return tier.damage
        end
    end
    return 0
end

--- 🔧 关键修复: 同一档位只扣一次引擎健康度
--- 原版 b ug: 每帧调用 SetVehicleEngineHealth(vehicle, engineHealth - damage)
--- 导致 60 FPS 下 1.7 秒引擎烧毁
local function ApplyDamageBasedOnDistance(distance)
    if not StateCfg.UseDistanceDamage then return end
    local damage = GetDamageAmount(distance)
    if damage <= 0 then return end

    -- 🛠️ 防重复: 如果该档位已经扣过了, 不再重复扣
    local lastApplied = distanceDamageApplied[plate] or 0
    if damage <= lastApplied then return end

    local engineHealth = GetVehicleEngineHealth(vehicle)
    SetVehicleEngineHealth(vehicle, engineHealth - damage)
    distanceDamageApplied[plate] = damage  -- 记录已应用档位
end

-- ==============================================================
-- 里程追踪主循环 (500ms Tick, 非每帧)
-- ==============================================================

local function TrackDistance()
    CreateThread(function()
        while true do
            Wait(500)  -- 🔧 500ms 间隔, 原版 Wait(0) 导致极高 CPU 开销
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
                        local dist = #(drivingDistance[plate].lastCoords - newCoords)
                        -- 🔧 500ms Tick 下高速行驶可达 ~55m/帧 (400km/h), 放宽到 100m
                        if dist < 100 then
                            drivingDistance[plate].distance = drivingDistance[plate].distance + dist
                            drivingDistance[plate].lastCoords = newCoords

                            -- 引擎损耗 (🔧 修复: 档位防重复)
                            local accumulatedDistance = drivingDistance[plate].distance
                            if StateCfg.MinimalMetersForDamage and StateCfg.MinimalMetersForDamage[1] then
                                if accumulatedDistance >= StateCfg.MinimalMetersForDamage[1].min then
                                    ApplyDamageBasedOnDistance(accumulatedDistance)
                                end
                            end

                            -- 随机部件损耗
                            local randomNumber = math.random(1, 1000)
                            if randomNumber <= StateCfg.WearablePartsChance then
                                DamageRandomComponent()
                            end
                        end
                    end
                end
            else
                -- 下车/换车: 同步到服务端
                if drivingDistance[plate] then
                    TriggerServerEvent('custom-vehicles:server:updateDistance', plate, drivingDistance[plate].distance)
                    TriggerServerEvent('custom-vehicles:server:updateComponents', plate, vehicleComponents[plate])

                    -- 同时触发旧版 qb-mechanicjob 兼容事件
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

-- ==============================================================
-- 修理后重置 (兼容 qb-mechanicjob 旧事件)
-- ==============================================================

RegisterNetEvent('qb-mechanicjob:client:resetAllComponents', function(resetPlate)
    if not StateCfg.UseWearableParts then return end
    if not resetPlate then return end
    resetPlate = resetPlate:gsub('^%s+', ''):gsub('%s+$', '')
    if vehicleComponents[resetPlate] then
        for part, data in pairs(StateCfg.WearableParts) do
            vehicleComponents[resetPlate][part] = data.maxValue
        end
    end
    -- 清除故障效果触发记录 + 引擎损耗防重复标记
    componentEffectTriggered[resetPlate] = nil
    distanceDamageApplied[resetPlate] = nil
end)

-- 新版重置事件 (推荐使用)
RegisterNetEvent('custom-vehicles:client:resetComponents', function(resetPlate)
    if not StateCfg.UseWearableParts then return end
    if not resetPlate then return end
    resetPlate = resetPlate:gsub('^%s+', ''):gsub('%s+$', '')
    if vehicleComponents[resetPlate] then
        for part, data in pairs(StateCfg.WearableParts) do
            vehicleComponents[resetPlate][part] = data.maxValue
        end
    end
    componentEffectTriggered[resetPlate] = nil
    distanceDamageApplied[resetPlate] = nil
end)

-- ==============================================================
-- 入口: 玩家上车
-- ==============================================================

AddEventHandler('gameEventTriggered', function(event)
    if event == 'CEventNetworkPlayerEnteredVehicle' then
        if not StateCfg.UseDistance then return end
        vehicle = GetVehiclePedIsIn(PlayerPedId(), false)
        local originalPlate = GetVehicleNumberPlateText(vehicle)
        if not originalPlate then return end
        plate = originalPlate:gsub('^%s+', ''):gsub('%s+$', '')
        local vehicleClass = GetVehicleClass(vehicle)
        if StateCfg.IgnoreClasses[vehicleClass] then return end
        TrackDistance()
    end
end)
