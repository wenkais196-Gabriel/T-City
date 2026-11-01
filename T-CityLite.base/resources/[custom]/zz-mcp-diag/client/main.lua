-- 一次性诊断资源（客户端侧）：用于 devcon / client_command 验证
RegisterNetEvent('zz-mcp-diag:ping', function(msg)
    print(('[zz-mcp-diag] client got ping: %s'):format(tostring(msg)))
end)

CreateThread(function()
    Wait(2000)
    print('[zz-mcp-diag] client side loaded — devcon probe target alive')
    TriggerServerEvent('zz-mcp-diag:clientReady')
end)

RegisterCommand('zdiagc', function()
    print('[zz-mcp-diag] client console command zdiagc executed')
end, false)

-- 心跳：给 devcon / read_console 提供持续输出，便于验证 tap 语义
CreateThread(function()
    local n = 0
    while true do
        Wait(2000)
        n = n + 1
        print(('[zz-mcp-diag] heartbeat #%d'):format(n))
    end
end)
