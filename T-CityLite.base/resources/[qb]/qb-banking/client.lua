local QBCore = exports['qb-core']:GetCoreObject()
local zones = {}
local isPlayerInsideBankZone = false
local isUIOpen = false

-- Functions

local function OpenBank()
    if isUIOpen then return end
    isUIOpen = true
    print("[qb-banking] OpenBank() client-side function called. Triggering callback...")
    QBCore.Functions.TriggerCallback('qb-banking:server:openBank', function(accounts, statements, playerData)
        print("[qb-banking] Server callback received for openBank! Accounts count: " .. (accounts and #accounts or 0))
        SetNuiFocus(true, true)
        SendNUIMessage({
            action = 'openBank',
            accounts = accounts,
            statements = statements,
            playerData = playerData
        })
    end)
end



-- NUI Callback

RegisterNUICallback('closeApp', function(_, cb)
    print("[qb-banking] closeApp NUI callback invoked. Hiding focus.")
    SetNuiFocus(false, false)
    isUIOpen = false
    cb('ok')
end)

RegisterNUICallback('withdraw', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:withdraw', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('deposit', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:deposit', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('internalTransfer', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:internalTransfer', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('externalTransfer', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:externalTransfer', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('orderCard', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:orderCard', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('openAccount', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:openAccount', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('renameAccount', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:renameAccount', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('deleteAccount', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:deleteAccount', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('addUser', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:addUser', function(status)
        cb(status)
    end, data)
end)

RegisterNUICallback('removeUser', function(data, cb)
    QBCore.Functions.TriggerCallback('qb-banking:server:removeUser', function(status)
        cb(status)
    end, data)
end)

-- Events


-- Threads

CreateThread(function()
    for i = 1, #Config.locations do
        local blip = AddBlipForCoord(Config.locations[i])
        SetBlipSprite(blip, Config.blipInfo.sprite)
        SetBlipDisplay(blip, 4)
        SetBlipScale(blip, Config.blipInfo.scale)
        SetBlipColour(blip, Config.blipInfo.color)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(tostring(Config.blipInfo.name))
        EndTextCommandSetBlipName(blip)
    end
end)

if Config.useTarget then
    CreateThread(function()
        for i = 1, #Config.locations do
            exports['qb-target']:AddCircleZone('bank_' .. i, Config.locations[i], 1.0, {
                name = 'bank_' .. i,
                useZ = true,
                debugPoly = false,
            }, {
                options = {
                    {
                        icon = 'fas fa-university',
                        label = 'Open Bank',
                        action = function()
                            OpenBank()
                        end,
                    }
                },
                distance = 1.5
            })
        end
    end)
end

-- Bank Counter Proximity E-Interaction (Always enabled as a simple exclusive shortcut)
CreateThread(function()
    for i = 1, #Config.locations do
        local zone = CircleZone:Create(Config.locations[i], 3.0, {
            name = 'bank_' .. i,
            debugPoly = false,
        })
        zones[#zones + 1] = zone
    end

    local combo = ComboZone:Create(zones, {
        name = 'bank_combo',
        debugPoly = false,
    })

    combo:onPlayerInOut(function(isPointInside)
        isPlayerInsideBankZone = isPointInside
        if isPlayerInsideBankZone then
            exports['qb-core']:DrawText('[E] 打开银行账户', 'left')
            CreateThread(function()
                while isPlayerInsideBankZone do
                    Wait(0)
                    if IsControlJustPressed(0, 38) and not isUIOpen then
                        OpenBank()
                    end
                end
            end)
        else
            exports['qb-core']:HideText()
        end
    end)
end)
