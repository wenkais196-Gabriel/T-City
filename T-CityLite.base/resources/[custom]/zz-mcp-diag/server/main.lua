-- 一次性诊断资源：只用于验证 fivem-mcp 的 RCON / console 行为
local rconPwd = GetConvar('rcon_password', '')

print(('[zz-mcp-diag] server side loaded — rcon_password_len=%d sv_maxclients=%s')
    :format(#rconPwd, GetConvar('sv_maxclients', '?')))

RegisterCommand('zdiag', function(source, args)
    local who = source == 0 and 'console' or ('player:' .. source)
    print(('[zz-mcp-diag] zdiag from %s args=%s'):format(who, table.concat(args, ',')))
end, false)

RegisterCommand('zdiag_client', function(source)
    print(('[zz-mcp-diag] zdiag_client from %s'):format(tostring(source)))
    TriggerClientEvent('zz-mcp-diag:ping', source or -1, 'pong-from-server')
end, false)

RegisterNetEvent('zz-mcp-diag:clientReady', function()
    print(('[zz-mcp-diag] client ready (source=%s)'):format(tostring(source)))
end)
