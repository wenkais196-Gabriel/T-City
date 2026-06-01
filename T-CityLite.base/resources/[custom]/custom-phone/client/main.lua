local QBCore = exports['qb-core']:GetCoreObject()
local isPhoneOpen = false

-- Open Phone Function
local function OpenPhone()
    if isPhoneOpen then return end
    isPhoneOpen = true
    SetNuiFocus(true, true)
    
    -- Tell NUI to open phone
    SendNUIMessage({
        action = 'phone:open'
    })
    
    -- Perform phone open animation (optional, but keep it clean)
    -- Trigger open thread for zero tick overhead when closed
    CreateThread(function()
        while isPhoneOpen do
            -- While phone is open, disable standard game control keys that interfere with UI typing
            DisableControlAction(0, 1, true) -- LookLeftRight
            DisableControlAction(0, 2, true) -- LookUpDown
            DisableControlAction(0, 24, true) -- Attack
            DisableControlAction(0, 257, true) -- Attack 2
            DisableControlAction(0, 25, true) -- Aim
            DisableControlAction(0, 263, true) -- Melee Attack 1
            DisableControlAction(0, 37, true) -- Select Weapon
            DisableControlAction(0, 44, true) -- Cover
            DisableControlAction(0, 140, true) -- Light Attack
            DisableControlAction(0, 141, true) -- Heavy Attack
            DisableControlAction(0, 142, true) -- Melee Attack Alternate
            Wait(0)
        end
    end)
end

-- Close Phone Function
local function ClosePhone()
    if not isPhoneOpen then return end
    isPhoneOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({
        action = 'phone:close'
    })
end

-- Command & Keybind to toggle phone
RegisterCommand('phone', function()
    if isPhoneOpen then
        ClosePhone()
    else
        OpenPhone()
    end
end, false)


-- Register key binding on resource start
AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    RegisterKeyMapping('phone', 'Open Mobile Phone', 'keyboard', Config.OpenKey)
end)

-- ----------------------------------------------------
-- NUI Callbacks
-- ----------------------------------------------------
RegisterNUICallback('closePhone', function(_, cb)
    ClosePhone()
    cb({ success = true })
end)

RegisterNUICallback('getPhoneData', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getPhoneData', function(data)
        cb(data)
    end)
end)

-- Contact CRUD Callbacks
RegisterNUICallback('addContact', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:addContact', function(res)
        cb(res)
    end, data.name, data.number)
end)

RegisterNUICallback('deleteContact', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:deleteContact', function(res)
        cb(res)
    end, data.id)
end)

-- SMS Callbacks
RegisterNUICallback('sendMessage', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:sendMessage', function(res)
        cb(res)
    end, data.receiver_number, data.message)
end)

RegisterNUICallback('markMessagesRead', function(data, cb)
    TriggerServerEvent('phone:server:markMessagesRead', data.sender_number)
    cb({ success = true })
end)

-- Notification Tray Callbacks (Transient UI Store syncing)
RegisterNUICallback('markNotificationsRead', function(_, cb)
    cb({ success = true })
end)

RegisterNUICallback('clearNotifications', function(_, cb)
    cb({ success = true })
end)

RegisterNUICallback('deleteNotification', function(data, cb)
    cb({ success = true })
end)

-- Banking Callbacks (Wire Transfer & Secure Fallbacks)
RegisterNUICallback('bankTransfer', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:bankTransfer', function(res)
        cb(res)
    end, data.toPhoneNumber, data.amount, data.reason)
end)

RegisterNUICallback('bankDeposit', function(_, cb)
    cb({ success = false, message = 'Mobile deposits are disabled. Please use a physical ATM or bank teller.' })
end)

RegisterNUICallback('bankWithdraw', function(_, cb)
    cb({ success = false, message = 'Mobile withdrawals are disabled. Please use a physical ATM or bank teller.' })
end)

-- v0.4.2 Premium features NUI Callbacks
RegisterNUICallback('getNearbyPlayers', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getNearbyPlayers', function(res)
        cb(res)
    end)
end)

RegisterNUICallback('shareContactNearby', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:shareContactNearby', function(res)
        cb(res)
    end, data.targetId, data.name, data.number)
end)

RegisterNUICallback('getOwnedVehicles', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getOwnedVehicles', function(res)
        cb(res)
    end)
end)

RegisterNUICallback('getHotlineStatus', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:getHotlineStatus', function(res)
        cb(res)
    end, data.jobType)
end)

RegisterNUICallback('triggerHotlineCall', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:triggerHotlineCall', function(res)
        cb(res)
    end, data.jobType)
end)

RegisterNUICallback('queryAutomatedIvr', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:queryAutomatedIvr', function(res)
        cb(res)
    end, data.actionType)
end)

-- Job Board Callbacks
RegisterNUICallback('acceptJobBoardTask', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:acceptJob', function(res)
        cb(res)
    end, data.id)
end)

RegisterNUICallback('postJobBoardTask', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:postJob', function(res)
        cb(res)
    end, data.title, data.description, data.reward)
end)

-- Faction messages callback
RegisterNUICallback('sendFactionMessage', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:sendFactionMessage', function(res)
        cb(res)
    end, data.content)
end)

-- Sheriff specific callback
RegisterNUICallback('sendSheriffPatrolOrder', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:sendSheriffPatrol', function(res)
        cb(res)
    end, data.zone, data.details)
end)

-- Gang Boss specific callback
RegisterNUICallback('sendGangObjective', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:sendGangObjective', function(res)
        cb(res)
    end, data.objective, data.quota)
end)

-- CityFeed Callbacks
RegisterNUICallback('getCityFeed', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getCityFeed', function(res)
        cb(res)
    end)
end)

RegisterNUICallback('postCityFeed', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:postCityFeed', function(res)
        cb(res)
    end, data.content)
end)

RegisterNUICallback('likeCityFeed', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:likeCityFeed', function(res)
        cb(res)
    end, data.id)
end)

-- ----------------------------------------------------
-- Server Events → Client UI push
-- ----------------------------------------------------
RegisterNetEvent('phone:client:newMessage', function(msg)
    SendNUIMessage({
        action = 'phone:newMessage',
        message = msg
    })
end)

RegisterNetEvent('phone:client:newNotification', function(notif)
    SendNUIMessage({
        action = 'phone:newNotification',
        notification = notif
    })
end)

RegisterNetEvent('phone:client:newJob', function(job)
    SendNUIMessage({
        action = 'phone:jobboard:newJob',
        job = job
    })
end)

RegisterNetEvent('phone:client:factionReceive', function(msg)
    SendNUIMessage({
        action = 'phone:faction:receive',
        message = msg
    })
end)

-- GPS Routing NetEvent
RegisterNetEvent('phone:client:routeGps', function(coords, label)
    SetNewWaypoint(coords.x, coords.y)
    QBCore.Functions.Notify("GPS Waypoint routing active: " .. label, "success")
end)

-- Dynamic Leader app unlocking
local function CheckLeaderApp()
    local success, identity = pcall(function()
        return exports['custom-career']:GetLocalIdentity()
    end)
    if success and identity then
        if identity.rank_tier == 'leader' then
            SendNUIMessage({
                action = 'phone:registerLeaderApp',
                role = identity.primary_role
            })
        else
            SendNUIMessage({
                action = 'phone:removeLeaderApp'
            })
        end
    end
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    Wait(2000)
    CheckLeaderApp()
end)

RegisterNetEvent('custom-career:client:tierChanged', function(newTier)
    CheckLeaderApp()
end)

-- Real-time Money Sync Listener
RegisterNetEvent('QBCore:Client:OnMoneyChange', function(type, amount, operation)
    if not isPhoneOpen then return end
    QBCore.Functions.TriggerCallback('phone:server:getPhoneData', function(data)
        if data and data.success then
            SendNUIMessage({
                action = 'phone:updateMoney',
                money = data.playerData.money
            })
        end
    end)
end)

RegisterNetEvent('QBCore:Client:SetPlayerData', function(val)
    if not isPhoneOpen or not val or not val.money then return end
    SendNUIMessage({
        action = 'phone:updateMoney',
        money = val.money
    })
end)

-- ----------------------------------------------------
-- Job Board Waypoint Distance Tracker (按需激活，完成即停)
-- ----------------------------------------------------
local activeJobId = nil
local activeJobCoords = nil

RegisterNetEvent('phone:client:trackJobArrival', function(id, coords)
    activeJobId = id
    activeJobCoords = coords

    -- 按需创建专属追踪线程（不再污染全局常驻线程）
    CreateThread(function()
        while activeJobId == id and activeJobCoords do
            Wait(1000)
            local ped = PlayerPedId()
            local pCoords = GetEntityCoords(ped)
            local dist = #(pCoords - activeJobCoords)
            if dist < 8.0 then
                TriggerServerEvent('phone:server:completeJob', id)
                if activeJobId == id then
                    activeJobId = nil
                    activeJobCoords = nil
                end
                break -- 线程自我退出
            end
        end
    end)
end)
