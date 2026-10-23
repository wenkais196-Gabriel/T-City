-- NUI -> server bridges that must live outside client/main.lua.
--
-- Kept in their own client script so the focus/call state machine in
-- client/main.lua stays untouched; the NUI calls these exactly like the other
-- phone endpoints in main.lua.
local QBCore = exports['qb-core']:GetCoreObject()

RegisterNUICallback('getCallHistory', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getCallHistory', function(res)
        cb(res)
    end)
end)

-- SMS keyset pagination: { number, before_id?, limit? } -> { success, messages,
-- next_before_id }. The server validates the conversation and the caller.
RegisterNUICallback('getMessages', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:getMessages', function(res)
        cb(res)
    end, data)
end)

-- Dispatch / agent voice line: the server sends the text after the player
-- answers a system call; the NUI speaks it locally and shows a subtitle.
RegisterNetEvent('phone:client:systemSpeech', function(data)
    if type(data) ~= 'table' or type(data.text) ~= 'string' then return end
    SendNUIMessage({
        action = 'phone:systemSpeech',
        callId = data.callId,
        text = data.text:sub(1, 300),
    })
end)
