-- bus.lua — qb-vehicleshop Bus 服务注册
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 职责:
--   1. 注册 'dealership' 服务到 core-framework Bus
--   2. 暴露 exports 供外部资源调用
--   3. Plugin Contract 事件发布

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 工具函数 (跨模块共享)
-- ==============================================================

-- 车辆类别 → 证件类型映射
local VehicleClassLicenseMap = {
    [0] = 'driver', [1] = 'driver', [2] = 'driver', [3] = 'driver', [4] = 'driver',
    [5] = 'driver', [6] = 'driver', [7] = 'driver', [8] = 'driver', [9] = 'driver',
    [10] = 'heavy', [11] = 'heavy', [17] = 'heavy', [19] = 'heavy', [20] = 'heavy',
    [12] = 'driver', [13] = 'driver', [18] = 'driver', [22] = 'driver',
    [14] = 'boat',
    [15] = 'pilot', [16] = 'pilot',
}

-- QBCore category → 车辆 class 号（服务端回退，GetVehicleClassFromName 是客户端 native）
local CategoryToClass = {
    compacts = 0, sedans = 1, suvs = 2, coupes = 3, muscle = 4,
    sportsclassics = 5, sports = 6, super = 7, motorcycles = 8, offroad = 9,
    industrial = 10, utility = 11, vans = 12, cycles = 13, boats = 14,
    helicopters = 15, planes = 16, service = 17, emergency = 18,
    military = 19, commercial = 20, trains = 21, submarines = 14,
}

--- 服务端安全获取车辆 class（不依赖客户端 native）
---@param vehicleModel string
---@return integer
local function GetVehicleClassSafe(vehicleModel)
    -- Try native first (client-side only — fails silently on server)
    local ok, cls = pcall(function()
        local h = GetHashKey(vehicleModel)
        return GetVehicleClassFromName(h)
    end)
    if ok and cls then return cls end

    -- Server fallback: use QBCore.Shared.Vehicles category
    local vehData = QBCore.Shared.Vehicles[vehicleModel]
    if vehData and vehData.category then
        local cls2 = CategoryToClass[vehData.category]
        if cls2 then return cls2 end
    end

    -- Default: automobile (class 0 = driver)
    return 0
end

--- 检查玩家是否持有对应车辆类型的驾照
---@param player table QBCore Player object
---@param vehicleModel string
---@return boolean
function CheckVehicleLicense(player, vehicleModel)
    local vehClass = GetVehicleClassSafe(vehicleModel)
    local requiredLicense = VehicleClassLicenseMap[vehClass]
    if not requiredLicense then return true end
    local licences = player.PlayerData.metadata['licences']
    if not licences then return false end
    return licences[requiredLicense] == true
end

--- 获取所需驾照的可读名称
---@param vehicleModel string
---@return string|nil
function GetRequiredLicenseName(vehicleModel)
    local vehClass = GetVehicleClassSafe(vehicleModel)
    local requiredLicense = VehicleClassLicenseMap[vehClass]
    local names = {
        driver = 'Driver License',
        pilot  = 'Pilot License',
        boat   = 'Boat License',
        heavy  = 'Heavy Vehicle License',
    }
    return requiredLicense and names[requiredLicense] or nil
end

--- 服务端距离校验：玩家必须靠近出售该车的展车/车店
---@param source number
---@param vehicleModel string
---@return boolean
function IsPlayerNearShopWithVehicle(source, vehicleModel)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    local coords = GetEntityCoords(ped)

    for _, shop in pairs(Config.Shops) do
        for _, sv in ipairs(shop.ShowroomVehicles or {}) do
            if sv.chosenVehicle == vehicleModel then
                local c = sv.coords
                if c and #(coords - vector3(c.x, c.y, c.z)) <= 8.0 then
                    return true
                end
                local loc = shop.Location
                if loc and #(coords - loc) <= 30.0 then
                    return true
                end
            end
        end
    end
    return false
end

--- 数字格式化: 1000 → "1,000"
---@param amount number
---@return string
function comma_value(amount)
    local formatted = amount
    local k
    while true do
        formatted, k = string.gsub(formatted, '^(-?%d+)(%d%d%d)', '%1,%2')
        if k == 0 then break end
    end
    return formatted
end

--- 四舍五入
---@param x number
---@return integer
function round(x)
    return x >= 0 and math.floor(x + 0.5) or math.ceil(x - 0.5)
end

--- 生成唯一车牌 (递归直到不冲突)
---@return string
function GeneratePlate()
    local plate = QBCore.Shared.RandomInt(1) .. QBCore.Shared.RandomStr(2)
                  .. QBCore.Shared.RandomInt(3) .. QBCore.Shared.RandomStr(2)
    local result = MySQL.scalar.await('SELECT plate FROM player_vehicles WHERE plate = ?', { plate })
    if result then
        return GeneratePlate()
    else
        return plate:upper()
    end
end

-- ==============================================================
-- 服务方法
-- ==============================================================

local Dealership = {}

--- 查询某商店的配置快照 (只读)
---@param shopName string
---@return table|nil
function Dealership.GetShopConfig(shopName)
    return Config.Shops[shopName]
end

--- 列出所有商店名
---@return table
function Dealership.GetShopList()
    local list = {}
    for name, _ in pairs(Config.Shops) do
        list[#list + 1] = name
    end
    return list
end

--- 计算分期参数
---@param vehiclePrice number
---@param downPayment number
---@param paymentCount number
---@return integer balance, integer paymentPerCycle
function Dealership.CalculateFinance(vehiclePrice, downPayment, paymentCount)
    local balance = vehiclePrice - downPayment
    local paymentPerCycle = balance / paymentCount
    return round(balance), round(paymentPerCycle)
end

--- 重新计算分期 (支付后)
---@param paymentAmount number 本次支付额
---@param vehData table { balance, paymentsLeft, paymentAmount }
---@return integer newBalance, integer newPayment, integer newPaymentsLeft
function Dealership.RecalculateFinance(paymentAmount, vehData)
    local newBalance = tonumber(vehData.balance - paymentAmount)
    local minusPayment = vehData.paymentsLeft - 1
    local newPaymentsLeft = newBalance / minusPayment
    local newPayment = newBalance / newPaymentsLeft
    return round(newBalance), round(newPayment), newPaymentsLeft
end

--- 驾照检查 (服务端安全路径)
---@param player table
---@param vehicleModel string
---@return boolean
function Dealership.CheckLicense(player, vehicleModel)
    return CheckVehicleLicense(player, vehicleModel)
end

--- 获取所需驾照名
---@param vehicleModel string
---@return string|nil
function Dealership.GetLicenseName(vehicleModel)
    return GetRequiredLicenseName(vehicleModel)
end

-- ==============================================================
-- 车辆生成 Callback (试驾 + 购买共用)
-- ==============================================================

local vehicleTypes = { -- https://docs.fivem.net/natives/?0xA273060E
    motorcycles  = 'bike',
    boats        = 'boat',
    helicopters  = 'heli',
    planes       = 'plane',
    submarines   = 'submarine',
    trailer      = 'trailer',
    train        = 'train',
}

local function GetVehicleTypeByModel(model)
    local vehicleData = QBCore.Shared.Vehicles[model]
    if not vehicleData then return 'automobile' end
    local category = vehicleData.category
    local vehicleType = vehicleTypes[category]
    return vehicleType or 'automobile'
end

-- 试驾记录：netId -> { src, model, at }。生成在这里做，所以这里是唯一能记账的地方；
-- `deleteVehicle` 靠它判断"这台车是不是你的试驾车"，否则任何人都能删任意实体。
TestDriveVehicles = TestDriveVehicles or {}

local function isOnDutyDealer(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return false end
    local job = Player.PlayerData and Player.PlayerData.job
    if type(job) ~= 'table' then return false end
    return job.name == 'cardealer' and job.onduty == true
end

-- 车型属于哪家店：`QBCore.Shared.Vehicles[model].shop` 可以是单个店名，也可以是店名数组。
-- 换展车的菜单就是按这个字段筛车型的，所以服务端也必须用同一套判据 —— 用静态的
-- `ShowroomVehicles[*].chosenVehicle` 会把"店员刚换上的车"判成非法。
function VehicleBelongsToShop(model, shopName)
    local cfg = QBCore.Shared.Vehicles[model]
    if not cfg then return false end
    local shop = cfg.shop
    if type(shop) == 'string' then return shop == shopName end
    if type(shop) == 'table' then
        for _, name in pairs(shop) do
            if name == shopName then return true end
        end
    end
    return false
end

function IsOwnTestDrive(netId, src)
    local grant = TestDriveVehicles[netId]
    return grant ~= nil and grant.src == src
end

local function purgeStaleTestDrives(src)
    local now = os.time()
    for netId, grant in pairs(TestDriveVehicles) do
        if grant.src == src or (now - (grant.at or now)) > 600 then
            TestDriveVehicles[netId] = nil
        end
    end
end

QBCore.Functions.CreateCallback('qb-vehicleshop:server:spawnvehicle', function(source, cb, plate, vehicle, coords)
    -- 🔒 三个参数全来自客户端：车型必须是**某个车店展台上真实存在的车**，生成点必须在
    --    该车店的试驾点附近。原来 `vehicle` 直接进 GetHashKey、`coords` 直接进生成函数 ——
    --    任何玩家都能在任意坐标生成任意载具。
    if type(plate) ~= 'string' or type(vehicle) ~= 'string' then cb(nil) return end
    local ctype = type(coords)
    if ctype ~= 'table' and ctype ~= 'vector3' and ctype ~= 'vector4' then cb(nil) return end
    local cx, cy, cz = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    local cw = tonumber(coords.w) or 0.0
    if not cx or not cy or not cz then cb(nil) return end
    if not QBCore.Shared.Vehicles[vehicle] then cb(nil) return end

    -- 同一个车型可能在多家门店销售：只要**任意一家**卖这台车的店就在附近即可。
    local ped = GetPlayerPed(source)
    local pcoords = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    if not pcoords then cb(nil) return end

    local inShowroom, nearShop = false, false
    for shopName, shop in pairs(Config.Shops) do
        if VehicleBelongsToShop(vehicle, shopName) then
            inShowroom = true
            local spawnPoint = shop['TestDriveSpawn']
            if spawnPoint then
                local anchor = vector3(spawnPoint.x, spawnPoint.y, spawnPoint.z)
                -- 玩家要在店里，**且**请求的生成点确实就在这家店的试驾点附近
                -- （只校验玩家位置的话，站在店里就能把车刷到地图另一头）
                if #(pcoords - anchor) <= 200.0 and #(vector3(cx, cy, cz) - anchor) <= 200.0 then
                    nearShop = true
                end
            end
        end
    end
    if not inShowroom then
        print(('[qb-vehicleshop] spawnvehicle rejected: %s 不在任何展台'):format(tostring(vehicle)))
        cb(nil)
        return
    end
    if not nearShop then
        print(('[qb-vehicleshop] spawnvehicle rejected: src=%s 离车店太远'):format(tostring(source)))
        cb(nil)
        return
    end

    purgeStaleTestDrives(source)
    local vehType = QBCore.Shared.Vehicles[vehicle]
                    and QBCore.Shared.Vehicles[vehicle].type
                    or GetVehicleTypeByModel(vehicle)
    local veh   = CreateVehicleServerSetter(GetHashKey(vehicle), vehType, coords.x, coords.y, coords.z, coords.w)
    local netId = NetworkGetNetworkIdFromEntity(veh)
    TestDriveVehicles[netId] = { src = source, model = vehicle, at = os.time() }
    SetVehicleNumberPlateText(veh, plate)
    local vehProps = {}
    local result   = MySQL.rawExecute.await('SELECT mods FROM player_vehicles WHERE plate = ?', { plate })
    if result and result[1] then vehProps = json.decode(result[1].mods) end
    cb(netId, vehProps, plate)
end)

-- ==============================================================
-- Bus 注册
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('dealership', {
        GetShopConfig      = Dealership.GetShopConfig,
        GetShopList        = Dealership.GetShopList,
        CalculateFinance   = Dealership.CalculateFinance,
        RecalculateFinance = Dealership.RecalculateFinance,
        CheckLicense       = Dealership.CheckLicense,
        GetLicenseName     = Dealership.GetLicenseName,
    })
end

-- 直接暴露全局函数供同资源内其他模块使用
_G._vehicleshop = {
    IsOwnTestDrive         = IsOwnTestDrive,
    VehicleBelongsToShop   = VehicleBelongsToShop,
    CheckVehicleLicense    = CheckVehicleLicense,
    GetRequiredLicenseName = GetRequiredLicenseName,
    comma_value            = comma_value,
    round                  = round,
    GeneratePlate          = GeneratePlate,
    IsPlayerNearShopWithVehicle = IsPlayerNearShopWithVehicle,
}

print('[qb-vehicleshop] 🏪 Bus 服务已注册 (dealership, 6 methods)')
print('[qb-vehicleshop]   Exports: service_dealership_GetShopConfig/GetShopList/CalculateFinance/RecalculateFinance/CheckLicense/GetLicenseName')
