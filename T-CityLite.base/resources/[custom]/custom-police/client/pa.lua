-- client/pa.lua — /pa <文本>：扩音器喊话。权限/距离/冷却全在 server/pa.lua。

RegisterCommand('pa', function(_, args)
    local parts = {}
    for i = 1, #args do parts[#parts + 1] = args[i] end
    local text = table.concat(parts, ' ')
    if text == '' then
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName('用法：/pa <要对现场说的话>')
        EndTextCommandThefeedPostTicker(false, true)
        return
    end
    TriggerServerEvent('police:server:pa', text)
end, false)
