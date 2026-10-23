-- NUI -> server bridge for the Phone app's "Recent" call list.
--
-- Kept in its own client script so the focus/call state machine in
-- client/main.lua stays untouched; the NUI calls `getCallHistory` exactly like
-- the other phone endpoints in main.lua.
local QBCore = exports['qb-core']:GetCoreObject()

RegisterNUICallback('getCallHistory', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getCallHistory', function(res)
        cb(res)
    end)
end)
