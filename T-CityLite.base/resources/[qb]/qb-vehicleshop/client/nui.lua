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

function _vIsNuiOpen()
    return nuiOpen
end

function _vCloseNui()
    nuiOpen = false
    local ok = pcall(function() exports['custom-ui']:CloseMenu({ owner = GetCurrentResourceName() }) end)
    if not ok then
        SetNuiFocus(false, false)
        SetNuiFocusKeepInput(false)
    end
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
    -- 保持 NUI 打开并显示 processing，等服务端 purchaseResult 再决定关闭/报错
    if data and data.vehicle then
        TriggerServerEvent('qb-vehicleshop:server:buyShowroomVehicle',
            { buyVehicle = data.vehicle })
    end
    cb('ok')
end)

RegisterNetEvent('qb-vehicleshop:client:purchaseResult', function(success, message)
    SendNUIMessage({
        type = 'result',
        success = success == true,
        message = message or '',
    })
    if success then
        _vCloseNui()
    end
end)

-- ==============================================================
-- NUI Callback: 分期
-- ==============================================================

RegisterNUICallback('financeVehicle', function(data, cb)
    -- V-10 续（CC 评审 Q2 的回归点）：必须走 _vCloseNui 弹栈。
    -- 原来直接 SetNuiFocus(false,false)+close，栈里的 menu:qb-vehicleshop 帧留着 →
    -- custom-ui 之后每次 apply 都按这层禁走路/冲刺，玩家"下车走不动"。
    _vCloseNui()
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
    _vCloseNui() -- 同上：必须弹栈，否则试驾后人物动不了
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
    -- 主动交互流程：关闭面板，走到其他展车旁再按 E
    _vCloseNui()
    QBCore.Functions.Notify('走到其他展车旁，按 E 浏览该车', 'primary', 4000)
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
    -- V-10：焦点要由拥有 ui_page 的资源按（SetNuiFocus 是按资源的）
    local ok = pcall(function()
        exports['custom-ui']:OpenMenu({ keepInput = false, owner = GetCurrentResourceName() })
    end)
    if not ok then
        SetNuiFocus(true, true)
        SetNuiFocusKeepInput(true)
    end
    nuiOpen = true

    print(('[qb-vehicleshop] 🖥️ Opening NUI for shop=%s vehicle=%s price=%s'):format(
        shopName, vehData.name or chosen.chosenVehicle, vehData.price or 0))

    SendNUIMessage(payload)
end

-- 暴露全局供 zones.lua 调用
_G._vOpenNui = OpenVehicleShopNui

print('[qb-vehicleshop] 🖥️  NUI 模块已加载 (nui.lua)')

-- V-10（2026-11-12）：custom-ui 的输入栈会回调拥有页面的资源来真正按焦点
exports('ApplyFocus', function(hasFocus, hasCursor, keepInput)
    SetNuiFocusKeepInput(keepInput == true)
    SetNuiFocus(hasFocus == true, hasCursor ~= false)
end)
