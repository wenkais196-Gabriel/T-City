-- util.lua — 客户端共享工具与全局状态
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 职责:
--   1. 全局状态 (insideShop, ClosestVehicle, testDriveVeh, inTestDrive)
--   2. 工具函数 (drawTxt, tablelength, comma_value)
--   3. 车辆信息获取 (getVehName, getVehPrice, getVehBrand, setClosestShowroomVehicle)
--   4. 玩家数据管理 (PlayerData, handlers)

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 全局状态
-- ==============================================================

PlayerData    = QBCore.Functions.GetPlayerData()
testDriveZone = nil
vehicleMenu   = {}
Initialized   = false
testDriveVeh  = 0
inTestDrive   = false
testDrivePlate = nil   -- Phase 5: 试驾车牌 (用于钥匙清理)
ClosestVehicle = 1
zones         = {}
insideShop    = nil
tempShop      = nil

-- ==============================================================
-- 工具函数
-- ==============================================================

--- 屏幕文字绘制
function _vDrawTxt(text, font, x, y, scale, r, g, b, a)
    SetTextFont(font)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, a)
    SetTextOutline()
    SetTextCentre(1)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(x, y)
end

--- 表长度 (Lua 5.4 兼容)
function _vTableLength(T)
    local count = 0
    for _ in pairs(T) do count = count + 1 end
    return count
end

--- 数字千分位格式化
function _vCommaValue(amount)
    local formatted = amount
    local k
    while true do
        formatted, k = string.gsub(formatted, '^(-?%d+)(%d%d%d)', '%1,%2')
        if k == 0 then break end
    end
    return formatted
end

-- ==============================================================
-- 车辆信息获取
-- ==============================================================

function _vGetVehName()
    local shop = insideShop
    if not shop or not Config.Shops[shop] then return 'Unknown' end
    local chosen = Config.Shops[shop]['ShowroomVehicles'][ClosestVehicle]
    if not chosen then return 'Unknown' end
    return QBCore.Shared.Vehicles[chosen.chosenVehicle]['name']
end

function _vGetVehPrice()
    local shop = insideShop
    if not shop or not Config.Shops[shop] then return '0' end
    local chosen = Config.Shops[shop]['ShowroomVehicles'][ClosestVehicle]
    if not chosen then return '0' end
    return _vCommaValue(QBCore.Shared.Vehicles[chosen.chosenVehicle]['price'])
end

function _vGetVehBrand()
    local shop = insideShop
    if not shop or not Config.Shops[shop] then return 'Unknown' end
    local chosen = Config.Shops[shop]['ShowroomVehicles'][ClosestVehicle]
    if not chosen then return 'Unknown' end
    return QBCore.Shared.Vehicles[chosen.chosenVehicle]['brand']
end

--- 更新最近展示车辆索引
function _vSetClosestShowroomVehicle()
    local pos = GetEntityCoords(PlayerPedId(), true)
    local current, dist = nil, nil
    local shop = insideShop
    if not shop or not Config.Shops[shop] then return end
    for id in pairs(Config.Shops[shop]['ShowroomVehicles']) do
        local c = Config.Shops[shop]['ShowroomVehicles'][id].coords
        local d = #(pos - vector3(c.x, c.y, c.z))
        if not current or d < dist then
            current, dist = id, d
        end
    end
    if current and current ~= ClosestVehicle then
        ClosestVehicle = current
    end
end

-- ==============================================================
-- 车牌校验
-- ==============================================================

function _vCheckPlate(vehicle, plateToSet)
    local vehiclePlate = promise.new()
    CreateThread(function()
        while true do
            Wait(500)
            if GetVehicleNumberPlateText(vehicle) == plateToSet then
                vehiclePlate:resolve(true)
                return
            else
                SetVehicleNumberPlateText(vehicle, plateToSet)
            end
        end
    end)
    return vehiclePlate
end

-- ==============================================================
-- 静态 Headers (qb-menu 用)
-- ==============================================================

_VEH_HEADER_MENU = {
    {
        header = Lang:t('menus.vehHeader_header'),
        txt    = Lang:t('menus.vehHeader_txt'),
        icon   = 'fa-solid fa-car',
        params = { event = 'qb-vehicleshop:client:showVehOptions' }
    }
}

_FINANCE_MENU = {
    {
        header = Lang:t('menus.financed_header'),
        txt    = Lang:t('menus.finance_txt'),
        icon   = 'fa-solid fa-user-ninja',
        params = { event = 'qb-vehicleshop:client:getVehicles' }
    }
}

_RETURN_TEST_DRIVE = {
    {
        header = Lang:t('menus.returnTestDrive_header'),
        icon   = 'fa-solid fa-flag-checkered',
        params = { event = 'qb-vehicleshop:client:TestDriveReturn' }
    }
}

-- ==============================================================
-- 菜单构建 (Phase 1: 从 zones.lua 轮询提取为事件驱动函数)
-- ==============================================================

--- 根据当前商店构建 vehicleMenu 表
--- 由 zone enter 和 refreshMenu 事件触发，替代 while insideShop 轮询
---@param shopName string|nil 如果为 nil 则清空当前菜单
function _vBuildVehicleMenu(shopName)
    if not shopName or not Config.Shops[shopName] then
        vehicleMenu = {}
        return
    end
    local shop = Config.Shops[shopName]
    local chosenVehicle = shop['ShowroomVehicles'][ClosestVehicle]
    if not chosenVehicle then
        vehicleMenu = {}
        return
    end
    local vehModel  = chosenVehicle.chosenVehicle
    local vehData   = QBCore.Shared.Vehicles[vehModel]
    local brandName = vehData and vehData.brand or ''
    local vehName   = vehData and vehData.name  or vehModel
    local vehPrice  = vehData and vehData.price or 0

    if shop['Type'] == 'free-use' then
        vehicleMenu = {
            {
                isMenuHeader = true,
                icon  = 'fa-solid fa-circle-info',
                header = brandName:upper() .. ' ' .. vehName:upper() .. ' - $' .. _vCommaValue(vehPrice),
            },
            {
                header = Lang:t('menus.test_header'),
                txt    = Lang:t('menus.freeuse_test_txt'),
                icon   = 'fa-solid fa-car-on',
                params = { event = 'qb-vehicleshop:client:TestDrive' }
            },
            {
                header = Lang:t('menus.freeuse_buy_header'),
                txt    = Lang:t('menus.freeuse_buy_txt'),
                icon   = 'fa-solid fa-hand-holding-dollar',
                params = {
                    isServer = true,
                    event    = 'qb-vehicleshop:server:buyShowroomVehicle',
                    args     = { buyVehicle = vehModel }
                }
            },
            {
                header = Lang:t('menus.finance_header'),
                txt    = Lang:t('menus.freeuse_finance_txt'),
                icon   = 'fa-solid fa-coins',
                params = {
                    event = 'qb-vehicleshop:client:openFinance',
                    args  = { price = _vCommaValue(vehPrice), buyVehicle = vehModel }
                }
            },
            {
                header = Lang:t('menus.swap_header'),
                txt    = Lang:t('menus.swap_txt'),
                icon   = 'fa-solid fa-arrow-rotate-left',
                params = {
                    event = Config.FilterByMake and 'qb-vehicleshop:client:vehMakes'
                                                    or 'qb-vehicleshop:client:vehCategories',
                }
            },
        }
    elseif shop['Type'] == 'managed' then
        vehicleMenu = {
            {
                isMenuHeader = true,
                icon  = 'fa-solid fa-circle-info',
                header = brandName:upper() .. ' ' .. vehName:upper() .. ' - $' .. _vCommaValue(vehPrice),
            },
            {
                header = Lang:t('menus.test_header'),
                txt    = Lang:t('menus.managed_test_txt'),
                icon   = 'fa-solid fa-user-plus',
                params = {
                    event = 'qb-vehicleshop:client:openIdMenu',
                    args  = { vehicle = vehModel, type = 'testDrive' }
                }
            },
            {
                header = Lang:t('menus.managed_sell_header'),
                txt    = Lang:t('menus.managed_sell_txt'),
                icon   = 'fa-solid fa-cash-register',
                params = {
                    event = 'qb-vehicleshop:client:openIdMenu',
                    args  = { vehicle = vehModel, type = 'sellVehicle' }
                }
            },
            {
                header = Lang:t('menus.finance_header'),
                txt    = Lang:t('menus.managed_finance_txt'),
                icon   = 'fa-solid fa-coins',
                params = {
                    event = 'qb-vehicleshop:client:openCustomFinance',
                    args  = { price = _vCommaValue(vehPrice), vehicle = vehModel }
                }
            },
            {
                header = Lang:t('menus.swap_header'),
                txt    = Lang:t('menus.swap_txt'),
                icon   = 'fa-solid fa-arrow-rotate-left',
                params = {
                    event = Config.FilterByMake and 'qb-vehicleshop:client:vehMakes'
                                                    or 'qb-vehicleshop:client:vehCategories',
                }
            },
        }
    else
        vehicleMenu = {}
    end
end

-- ==============================================================
-- 玩家生命周期
-- ==============================================================

AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    PlayerData = QBCore.Functions.GetPlayerData()
    local citizenid = PlayerData.citizenid
    TriggerServerEvent('qb-vehicleshop:server:addPlayer', citizenid)
    TriggerServerEvent('qb-vehicleshop:server:checkFinance')
    if not Initialized then _vInit() end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if next(PlayerData) ~= nil and not Initialized then
        PlayerData = QBCore.Functions.GetPlayerData()
        local citizenid = PlayerData.citizenid
        TriggerServerEvent('qb-vehicleshop:server:addPlayer', citizenid)
        TriggerServerEvent('qb-vehicleshop:server:checkFinance')
        _vInit()
    end
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(JobInfo)
    PlayerData.job = JobInfo
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    local citizenid = PlayerData.citizenid
    TriggerServerEvent('qb-vehicleshop:server:removePlayer', citizenid)
    PlayerData = {}
end)

print('[qb-vehicleshop] 🔧 客户端工具模块已加载 (util.lua)')
