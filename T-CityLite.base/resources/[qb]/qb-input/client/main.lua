local properties = nil

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then
        return
    end
    Wait(1000)
    SendNUIMessage({
        action = 'SET_STYLE',
        data = Config.Style
    })
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    SendNUIMessage({
        action = 'SET_STYLE',
        data = Config.Style
    })
end)

RegisterNUICallback('buttonSubmit', function(data, cb)
    SetNuiFocus(false)
    properties:resolve(data.data)
    properties = nil
    cb('ok')
end)

RegisterNUICallback('closeMenu', function(_, cb)
    SetNuiFocus(false)
    properties:resolve(nil)
    properties = nil
    cb('ok')
end)

local function ShowInputLegacy(data)
    Wait(150)
    if not data then return end
    if properties then return end

    properties = promise.new()

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'OPEN_MENU',
        data = data
    })

    return Citizen.Await(properties)
end

-- 适配层入口（issue #366）：convar `qb_menu_use_custom_menu` 打开时
-- client/adapter.lua 才会定义 QBInputAdapter；关着时与改造前完全一致。
local function ShowInput(data)
    local adapter = _G.QBInputAdapter
    if adapter then
        -- 第三个参数让适配层看得见旧路径的单飞状态（properties），
        -- 否则「旧表单开着时又能开原生表单」，两张表单抢焦点。
        return adapter.show(data, ShowInputLegacy, function() return properties ~= nil end)
    end
    return ShowInputLegacy(data)
end

exports('ShowInput', ShowInput)
