-- integration.lua — Phase 3: 深度集成 custom-vehicles Bus
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 职责:
--   1. 对接 custom-vehicles Bus 获取车辆里程/车况
--   2. 二手车估值公式
--   3. 增强 Bus.dealership 服务方法

local QBCore   = exports['qb-core']:GetCoreObject()
local shopUtil = _G._vehicleshop

-- ==============================================================
-- 二手车估值
-- ==============================================================

--- 计算二手车估值
--- 公式: basePrice * mileageFactor * conditionFactor
---   mileageFactor  = max(0.3, 1 - mileage / 500000)
---   conditionFactor = avg(radiator, axle, brakes, clutch, fuel) / 100
---@param basePrice number 新车价格
---@param vehicleState table|nil { distance, components } 来自 Bus.vehicles.GetState
---@return number estimatedPrice, number mileage, number conditionPct
function EstimateUsedVehiclePrice(basePrice, vehicleState)
    if not vehicleState then
        return basePrice, 0, 100
    end

    local mileage = vehicleState.distance or 0
    local components = vehicleState.components

    -- 里程折损
    local mileageFactor = math.max(0.3, 1 - (mileage / 500000))

    -- 车况折损
    local conditionPct = 100
    if components then
        local total, count = 0, 0
        for _, v in pairs(components) do
            if type(v) == 'number' then
                total = total + v
                count = count + 1
            end
        end
        if count > 0 then
            conditionPct = total / count
        end
    end
    local conditionFactor = conditionPct / 100

    -- 综合折损 (车况权重大于里程, 取低值)
    local factor = math.min(mileageFactor, conditionFactor)
    local estimatedPrice = shopUtil.round(basePrice * factor)

    return estimatedPrice, mileage, conditionPct
end

--- 获取车辆状态 (安全封装 — pcall 保护, 依赖未加载时返回 nil)
---@param plate string
---@return table|nil
function GetVehicleStateSafe(plate)
    if not plate then return nil end
    local ok, state = pcall(function()
        -- 尝试 Bus.vehicles.GetState
        if Bus and Bus.vehicles and Bus.vehicles.GetState then
            return Bus.vehicles.GetState(plate)
        end
        -- fallback: 尝试直接 exports
        if GetResourceState('custom-vehicles') == 'started' then
            return exports['custom-vehicles']:GetVehicleState(plate)
        end
    end)
    if ok and state then return state end
    return nil
end

-- ==============================================================
-- 扩展 Bus.dealership 服务
-- ==============================================================

if Bus and Bus._services and Bus._services['dealership'] then
    local dealBus = Bus._services['dealership']

    -- 追加方法
    dealBus.EstimateUsedPrice  = EstimateUsedVehiclePrice
    dealBus.GetVehicleState    = GetVehicleStateSafe

    -- 更新 Bus.dealership 速记
    if Bus.dealership then
        Bus.dealership.EstimateUsedPrice = EstimateUsedVehiclePrice
        Bus.dealership.GetVehicleState   = GetVehicleStateSafe
    end

    -- 注册为独立 exports
    exports('service_dealership_EstimateUsedPrice', EstimateUsedVehiclePrice)
    exports('service_dealership_GetVehicleState', GetVehicleStateSafe)

    print('[qb-vehicleshop] 🔗 深度集成 custom-vehicles Bus 已完成 (integration.lua)')
    print('[qb-vehicleshop]   + EstimateUsedPrice: 二手车估值 (里程×车况)')
    print('[qb-vehicleshop]   + GetVehicleState: 安全获取车辆状态')
end

-- ==============================================================
-- NUI 回调: 获取车辆详情 (含里程/车况)
-- ==============================================================

QBCore.Functions.CreateCallback('qb-vehicleshop:server:getVehicleDetail', function(source, cb, vehicleModel)
    local vehData = QBCore.Shared.Vehicles[vehicleModel]
    if not vehData then cb(nil); return end

    local detail = {
        brand  = vehData.brand  or '',
        name   = vehData.name   or vehicleModel,
        model  = vehicleModel,
        price  = vehData.price  or 0,
        speed  = vehData.speed  or 0,
        accel  = vehData.accel  or 0,
        braking = vehData.braking or 0,
        handling = vehData.handling or 0,
        category = vehData.category or '',
        estimatedUsedPrice = nil,
        mileage  = 0,
        condition = 100,
    }

    cb(detail)
end)

print('[qb-vehicleshop] 🔌 集成模块已加载 (integration.lua)')
