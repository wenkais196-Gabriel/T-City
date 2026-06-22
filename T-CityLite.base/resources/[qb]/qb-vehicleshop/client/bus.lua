-- bus.lua — qb-vehicleshop 客户端 Bus 服务注册
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
-- Phase 4: 客户端 Bus 注册
--
-- 职责:
--   1. 注册 'dealership_client' 服务到 core-framework Bus
--   2. 暴露客户端 exports 供其他客户端资源调用
--
-- 外部资源调用方式:
--   Bus.dealership_client.GetCurrentShop()
--   exports['qb-vehicleshop']:service_dealership_client_GetCurrentShop()

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 服务方法
-- ==============================================================

local ClientDealership = {}

--- 获取当前所在车店名
---@return string|nil
function ClientDealership.GetCurrentShop()
    return insideShop
end

--- 获取当前最近展示车辆索引
---@return number
function ClientDealership.GetClosestVehicle()
    return ClosestVehicle
end

--- 获取当前车店的车辆列表
---@param shopName string|nil 不传则用当前所在车店
---@return table 车辆模型名数组
function ClientDealership.GetShopVehicles(shopName)
    shopName = shopName or insideShop
    if not shopName or not Config.Shops[shopName] then return {} end

    local vehicles = {}
    for k, v in pairs(QBCore.Shared.Vehicles) do
        local shopMatch = false
        if type(v.shop) == 'table' then
            for _, s in ipairs(v.shop) do
                if s == shopName then shopMatch = true; break end
            end
        elseif v.shop == shopName then
            shopMatch = true
        end
        if shopMatch then
            vehicles[#vehicles + 1] = k
        end
    end
    return vehicles
end

--- 获取当前展示车辆信息
---@return table|nil { model, name, brand, price }
function ClientDealership.GetCurrentVehicle()
    if not insideShop or not Config.Shops[insideShop] then return nil end
    local chosen = Config.Shops[insideShop]['ShowroomVehicles'][ClosestVehicle]
    if not chosen then return nil end
    local vehData = QBCore.Shared.Vehicles[chosen.chosenVehicle]
    if not vehData then return nil end
    return {
        model = chosen.chosenVehicle,
        name  = vehData.name  or chosen.chosenVehicle,
        brand = vehData.brand or '',
        price = vehData.price or 0,
    }
end

--- 构建当前车店菜单并返回 (不自动打开, 供外部资源使用)
---@return table qb-menu 格式的菜单表
function ClientDealership.BuildMenu()
    if not insideShop then return {} end
    _vBuildVehicleMenu(insideShop)
    return vehicleMenu
end

--- 是否在试驾中
---@return boolean
function ClientDealership.IsTestDriving()
    return inTestDrive or false
end

-- ==============================================================
-- Bus 注册
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('dealership_client', {
        GetCurrentShop    = ClientDealership.GetCurrentShop,
        GetClosestVehicle = ClientDealership.GetClosestVehicle,
        GetShopVehicles   = ClientDealership.GetShopVehicles,
        GetCurrentVehicle = ClientDealership.GetCurrentVehicle,
        BuildMenu         = ClientDealership.BuildMenu,
        IsTestDriving     = ClientDealership.IsTestDriving,
    })
end

print('[qb-vehicleshop] 🏪 客户端 Bus 已注册 (dealership_client, 6 methods)')
