-- client/p0.lua — P0 dispatch commands (10-codes + 911).
local function status(code)
    TriggerServerEvent('custom-police:server:setStatus', code)
    TriggerEvent('QBCore:Notify', ('Status: %s'):format(code), 'primary')
end

RegisterCommand('10-8', function() status('available') end, false)
RegisterCommand('10-6', function() status('busy') end, false)
RegisterCommand('10-7', function() status('off_duty') end, false)

RegisterCommand('911', function(_, args)
    local message = table.concat(args or {}, ' ')
    if message == '' then message = 'Emergency call' end
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    TriggerServerEvent('custom-police:server:911', {
        title = message:sub(1, 120),
        description = message:sub(1, 1000),
        priority = 1,
        x = coords.x, y = coords.y, z = coords.z,
    })
    TriggerEvent('QBCore:Notify', '911 call sent', 'success')
end, false)
