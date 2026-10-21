-- nui.lua — 客户端 NUI 回调与焦点管理
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 职责:
--   1. NUI 焦点管理 (SetNuiFocus)
--   2. NUI 回调处理 (buyVehicle / financeVehicle / testDrive / swapVehicle / closeNui)
--   3. 打开 NUI (openVehicleShopNui)
--
-- 参考: phone-nui-patterns.md — ESC / 右键关闭规范

local QBCore = exports['qb-core']:GetCoreObject()

-- NUI 是否已经打开：打开状态下只 update，不重复 SetNuiFocus / 重新挂载
local nuiOpen = false

-- ==============================================================
-- NUI Callback: 关闭
-- ==============================================================

function _vCloseNui()
    nuiOpen = false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ type = 'close' })
end

RegisterNUICallback('closeNui', function(_, cb)
    _vCloseNui()
    cb('ok')
end)

-- ==============================================================
-- NUI Callback: 购买
-- ==============================================================

RegisterNUICallback('buyVehicle', function(data, cb)
    nuiOpen = false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ type = 'close' })
    if data and data.vehicle then
        TriggerServerEvent('qb-vehicleshop:server:buyShowroomVehicle',
            { buyVehicle = data.vehicle })
    end
    cb('ok')
end)

-- ==============================================================
-- NUI Callback: 分期
-- ==============================================================

RegisterNUICallback('financeVehicle', function(data, cb)
    nuiOpen = false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ type = 'close' })
    if data and data.vehicle and data.downPayment and data.paymentCount then
        TriggerServerEvent('qb-vehicleshop:server:financeVehicle',
            tonumber(data.downPayment), tonumber(data.paymentCount), data.vehicle)
    end
    cb('ok')
end)

-- ==============================================================
-- NUI Callback: 试驾
-- ==============================================================

RegisterNUICallback('testDrive', function(data, cb)
    nuiOpen = false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ type = 'close' })
    -- 试驾由现有的 TestDrive 事件处理
    -- NUI 关闭后, 模拟触发 TestDrive
    if not inTestDrive and ClosestVehicle ~= 0 then
        TriggerEvent('qb-vehicleshop:client:TestDrive')
    end
    cb('ok')
end)

-- ==============================================================
-- NUI Callback: 换车
-- ==============================================================

RegisterNUICallback('swapVehicle', function(_, cb)
    nuiOpen = false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ type = 'close' })
    -- 触发车辆类别选择菜单
    TriggerEvent(Config.FilterByMake and 'qb-vehicleshop:client:vehMakes'
                                      or 'qb-vehicleshop:client:vehCategories')
    cb('ok')
end)

-- ==============================================================
-- 打开 NUI
-- ==============================================================

--- 打开车店 NUI
---@param shopName string
function OpenVehicleShopNui(shopName)
    if not shopName or not Config.Shops[shopName] then return end

    local shop   = Config.Shops[shopName]
    local chosen = shop['ShowroomVehicles'][ClosestVehicle]
    if not chosen then return end

    local vehData = QBCore.Shared.Vehicles[chosen.chosenVehicle]
    if not vehData then return end

    -- 构建车辆规格 (占位: 从 QBCore.Shared.Vehicles 获取, 未来可从 custom-vehicles 获取真实数据)
    local specs = {
        { label = 'SPD', value = vehData.speed  or math.random(50, 95),  display = (vehData.speed  or math.random(50, 95)) .. '/100' },
        { label = 'ACC', value = vehData.accel  or math.random(50, 95),  display = (vehData.accel  or math.random(50, 95)) .. '/100' },
        { label = 'BRK', value = vehData.braking or math.random(50, 95),  display = (vehData.braking or math.random(50, 95)) .. '/100' },
        { label = 'HDL', value = vehData.handling or math.random(50, 95), display = (vehData.handling or math.random(50, 95)) .. '/100' },
    }

    local payload = {
        shopLabel        = shop['ShopLabel'],
        shopName         = shopName,
        vehicle          = {
            brand = vehData.brand or '',
            name  = vehData.name  or chosen.chosenVehicle,
            model = chosen.chosenVehicle,
            price = vehData.price or 0,
        },
        specs            = specs,
        testDriveMinutes = shop['TestDriveTimeLimit'] or 1.5,
        showFinance      = shop['Type'] == 'free-use',
        maxPayments      = Config.MaximumPayments or 24,
        minDownPercent   = Config.MinimumDown or 10,
    }

    -- 已经打开 → 原地更新展示车，不重新抢焦点/不闪屏
    if nuiOpen then
        payload.type = 'update'
        SendNUIMessage(payload)
        return
    end

    payload.type = 'open'
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(true)
    nuiOpen = true

    print(('[qb-vehicleshop] 🖥️ Opening NUI for shop=%s vehicle=%s price=%s'):format(
        shopName, vehData.name or chosen.chosenVehicle, vehData.price or 0))

    SendNUIMessage(payload)
end

-- 暴露全局供 zones.lua 调用
_G._vOpenNui = OpenVehicleShopNui

print('[qb-vehicleshop] 🖥️  NUI 模块已加载 (nui.lua)')
