-- zones.lua — 客户端区域管理与展示车辆
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 职责:
--   1. 展示车辆生成 (Init)
--   2. PolyZone 创建 (free-use / managed / vehicle zones / finance zone)
--   3. 试驾归还区域
--   4. Blip 创建

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 展示车辆区域
-- ==============================================================

function _vCreateVehZones(shopName, entity)
    if not Config.UsingTarget then
        for i = 1, #Config.Shops[shopName]['ShowroomVehicles'] do
            local c = Config.Shops[shopName]['ShowroomVehicles'][i]['coords']
            zones[#zones + 1] = BoxZone:Create(
                vector3(c.x, c.y, c.z),
                Config.Shops[shopName]['Zone']['size'],
                Config.Shops[shopName]['Zone']['size'],
                {
                    name     = 'box_zone_' .. shopName .. '_' .. i,
                    minZ     = Config.Shops[shopName]['Zone']['minZ'],
                    maxZ     = Config.Shops[shopName]['Zone']['maxZ'],
                    debugPoly = false,
                })
        end
        local combo = ComboZone:Create(zones, { name = 'vehCombo', debugPoly = false })
        combo:onPlayerInOut(function(isPointInside)
            if isPointInside then
                if PlayerData and PlayerData.job
                   and (PlayerData.job.name == Config.Shops[insideShop]['Job']
                        or Config.Shops[insideShop]['Job'] == 'none') then
                    exports['qb-menu']:showHeader(_VEH_HEADER_MENU)
                end
            else
                exports['qb-menu']:closeMenu()
            end
        end)
    else
        exports['qb-target']:AddTargetEntity(entity, {
            options = {
                {
                    type    = 'client',
                    event   = 'qb-vehicleshop:client:showVehOptions',
                    icon    = 'fas fa-car',
                    label   = Lang:t('general.vehinteraction'),
                    canInteract = function()
                        local shop = insideShop
                        return shop and (Config.Shops[shop]['Job'] == 'none'
                               or PlayerData.job.name == Config.Shops[shop]['Job'])
                    end
                },
            },
            distance = 3.0
        })
    end
end

-- ==============================================================
-- NUI 主动交互：进入区域后按 E 打开，而不是自动劫持面板
-- ==============================================================
local shopPromptRunning = false

local function _vStartShopPrompt()
    if not Config.UseNui or shopPromptRunning then return end
    shopPromptRunning = true
    CreateThread(function()
        -- 10Hz 轻量轮询：只监听 E 提示，不在店内做 0ms 空转
        while true do
            if not insideShop then break end
            Wait(100)
            if IsControlJustReleased(0, 38) -- E
                and not IsPedInAnyVehicle(PlayerPedId(), false)
                and not _vIsNuiOpen() then
                _vSetClosestShowroomVehicle()
                _vOpenNui(insideShop)
            end
        end
        shopPromptRunning = false
    end)
end

-- ==============================================================
-- 自由商店 (free-use) 区域
-- ==============================================================

function _vCreateFreeUseShop(shopShape, name)
    local zone = PolyZone:Create(shopShape, {
        name  = name,
        minZ  = shopShape.minZ,
        maxZ  = shopShape.maxZ,
    })

    zone:onPlayerInOut(function(isPointInside)
        if isPointInside then
            insideShop = name
            _vSetClosestShowroomVehicle()
            if Config.UseNui then
                _vStartShopPrompt()
                QBCore.Functions.Notify('按 E 浏览车辆', 'primary', 4000)
            else
                _vBuildVehicleMenu(name)  -- Phase 1: 事件驱动, 替代 while insideShop 轮询
            end
        else
            if Config.UseNui then
                _vCloseNui()
            end
            insideShop = nil
            ClosestVehicle = 1
            vehicleMenu = {}
        end
    end)
end

-- ==============================================================
-- 管理商店 (managed) 区域
-- ==============================================================

function _vCreateManagedShop(shopShape, name)
    local zone = PolyZone:Create(shopShape, {
        name = name,
        minZ = shopShape.minZ,
        maxZ = shopShape.maxZ,
    })

    zone:onPlayerInOut(function(isPointInside)
        if isPointInside then
            insideShop = name
            if PlayerData and PlayerData.job and PlayerData.job.name == Config.Shops[name]['Job'] then
                _vSetClosestShowroomVehicle()
                if Config.UseNui then
                    _vStartShopPrompt()
                    QBCore.Functions.Notify('按 E 浏览车辆', 'primary', 4000)
                else
                    _vBuildVehicleMenu(name)  -- Phase 1: 事件驱动
                end
            end
        else
            if Config.UseNui then
                _vCloseNui()
            end
            insideShop = nil
            ClosestVehicle = 1
            vehicleMenu = {}
        end
    end)
end

-- ==============================================================
-- 分期区域
-- ==============================================================

function _vCreateFinanceZone(coords, name)
    local financeZone = BoxZone:Create(coords, 2.0, 2.0, {
        name      = 'vehicleshop_financeZone_' .. name,
        offset    = { 0.0, 0.0, 0.0 },
        scale     = { 1.0, 1.0, 1.0 },
        minZ      = coords.z - 1,
        maxZ      = coords.z + 1,
        debugPoly = false,
    })

    financeZone:onPlayerInOut(function(isPointInside)
        if isPointInside then
            exports['qb-menu']:showHeader(_FINANCE_MENU)
        else
            exports['qb-menu']:closeMenu()
        end
    end)
end

-- ==============================================================
-- 试驾归还区域
-- ==============================================================

function _vCreateTestDriveReturn()
    testDriveZone = BoxZone:Create(
        Config.Shops[insideShop]['ReturnLocation'],
        3.0, 5.0,
        { name = 'box_zone_testdrive_return_' .. insideShop })

    testDriveZone:onPlayerInOut(function(isPointInside)
        if isPointInside and IsPedInAnyVehicle(PlayerPedId()) then
            SetVehicleForwardSpeed(GetVehiclePedIsIn(PlayerPedId(), false), 0)
            exports['qb-menu']:openMenu(_RETURN_TEST_DRIVE)
        else
            exports['qb-menu']:closeMenu()
        end
    end)
end

-- ==============================================================
-- 初始化: 生成展示车辆 + 创建区域 + Blip
-- ==============================================================

function _vInit()
    Initialized = true

    -- 创建商店区域
    CreateThread(function()
        for name, shop in pairs(Config.Shops) do
            if shop['Type'] == 'free-use' then
                _vCreateFreeUseShop(shop['Zone']['Shape'], name)
            elseif shop['Type'] == 'managed' then
                _vCreateManagedShop(shop['Zone']['Shape'], name)
            end
            if shop['FinanceZone'] then
                _vCreateFinanceZone(shop['FinanceZone'], name)
            end
        end
    end)

    -- 生成展示车辆
    CreateThread(function()
        for k in pairs(Config.Shops) do
            for i = 1, #Config.Shops[k]['ShowroomVehicles'] do
                local model = GetHashKey(Config.Shops[k]['ShowroomVehicles'][i].defaultVehicle)
                RequestModel(model)
                while not HasModelLoaded(model) do Wait(0) end
                local c = Config.Shops[k]['ShowroomVehicles'][i].coords
                local veh = CreateVehicle(model, c.x, c.y, c.z, false, false)
                SetModelAsNoLongerNeeded(model)
                SetVehicleOnGroundProperly(veh)
                SetEntityInvincible(veh, true)
                SetVehicleDirtLevel(veh, 0.0)
                SetVehicleDoorsLocked(veh, 3)
                SetEntityHeading(veh, c.w)
                FreezeEntityPosition(veh, true)
                SetVehicleNumberPlateText(veh, 'BUY ME')
                if Config.UsingTarget then _vCreateVehZones(k, veh) end
            end
            if not Config.UsingTarget then _vCreateVehZones(k) end
        end
    end)

    -- Blip
    CreateThread(function()
        for k, v in pairs(Config.Shops) do
            if v.showBlip then
                local Dealer = AddBlipForCoord(Config.Shops[k]['Location'])
                SetBlipSprite(Dealer, Config.Shops[k]['blipSprite'])
                SetBlipDisplay(Dealer, 4)
                SetBlipScale(Dealer, 0.70)
                SetBlipAsShortRange(Dealer, true)
                SetBlipColour(Dealer, Config.Shops[k]['blipColor'])
                SetBlipCategory(Dealer, 138)
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentSubstringPlayerName(Config.Shops[k]['ShopLabel'])
                EndTextCommandSetBlipName(Dealer)
            end
        end
    end)
end

-- ==============================================================
-- Phase 1: 菜单刷新事件 (替代旧 while insideShop 轮询)
-- 当车辆切换后触发, 确保菜单反映最新展示车
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:refreshMenu', function()
    if insideShop then
        _vSetClosestShowroomVehicle()
        if Config.UseNui then
            -- 只有面板已打开时才原地刷新；关闭状态不主动劫持
            if _vIsNuiOpen() then
                _vOpenNui(insideShop)
            end
        else
            _vBuildVehicleMenu(insideShop)
        end
    end
end)

print('[qb-vehicleshop] 🗺️  区域模块已加载 (zones.lua)')
