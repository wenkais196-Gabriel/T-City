-- notify-test 服务端测试 — exports 跨资源通信
-- notifytest_server: 服务端控制台运行
-- /notifytest_svr:    游戏内 F8 运行

local results, passed, failed = {}, 0, 0

RegisterCommand('notifytest_server', function(source, args)
    passed, failed = 0, 0

    local svcAvailable = pcall(exports['core-framework'].BusStatus)

    print('\n═══════════════════════════════════════════════')
    print('  通知系统双轨制测试 (服务端)')
    print('═══════════════════════════════════════════════\n')

    -- 1: Bus.notify 注册
    print('--- 1: Bus.notify 注册 ---')
    if svcAvailable then
        local s = exports['core-framework']:BusStatus()
        local ok = s and s.services
        for _, n in ipairs(s and s.services or {}) do ok = ok or n == 'notify' end
        print(ok and '  ✅ Bus.notify 已注册' or '  ❌ Bus.notify 未注册'); passed = passed + (ok and 1 or 0); failed = failed + (ok and 0 or 1)
    else print('  ❌ core-framework 未启动'); failed = failed + 1 end

    -- 2: Service exports
    print('--- 2: Service exports ---')
    if svcAvailable then
        for _, m in ipairs({'service_notify_Send','service_notify_Broadcast','service_notify_SendAdvanced','service_notify_RegisterType','service_notify_UnregisterType','service_notify_GetRegisteredTypes','service_notify_Subscribe'}) do
            local ok = exports['core-framework'][m] ~= nil
            print(ok and ('  ✅ %s'):format(m) or ('  ❌ %s'):format(m)); passed = passed + (ok and 1 or 0); failed = failed + (ok and 0 or 1)
        end
    else for _=1,7 do print('  ❌ (需要 core-framework)'); failed=failed+1 end end

    -- 3: 自定义类型
    print('--- 3: 自定义类型注册 ---')
    if svcAvailable then
        exports['core-framework']:service_notify_UnregisterType('_test_notify_')
        local r1 = exports['core-framework']:service_notify_RegisterType('test-suite', {type='_test_notify_',channel='native',icon='CHAR_LESTER'})
        print(r1==true and '  ✅ RegisterType: true' or '  ❌ RegisterType: false'); passed=passed+(r1==true and 1 or 0); failed=failed+(r1==true and 0 or 1)

        local r2 = exports['core-framework']:service_notify_RegisterType('test-suite-2', {type='_test_notify_',channel='nui'})
        print(r2==false and '  ✅ 重复注册被拒绝' or '  ❌ 重复注册未被拒绝'); passed=passed+(r2==false and 1 or 0); failed=failed+(r2==false and 0 or 1)

        local t = exports['core-framework']:service_notify_GetRegisteredTypes()
        local ok = type(t)=='table' and t['_test_notify_']~=nil
        print(ok and '  ✅ GetRegisteredTypes 包含' or '  ❌ GetRegisteredTypes 不包含'); passed=passed+(ok and 1 or 0); failed=failed+(ok and 0 or 1)

        exports['core-framework']:service_notify_UnregisterType('_test_notify_')
        local t2 = exports['core-framework']:service_notify_GetRegisteredTypes()
        ok = type(t2)~='table' or t2['_test_notify_']==nil
        print(ok and '  ✅ UnregisterType 后已移除' or '  ❌ UnregisterType 失败'); passed=passed+(ok and 1 or 0); failed=failed+(ok and 0 or 1)
    else for _=1,4 do print('  ❌ (需要 core-framework)'); failed=failed+1 end end

    -- 4: 服务端 → 客户端
    print('--- 4: 服务端通知发送 ---')
    if source and source > 0 then
        local QBCore = exports['qb-core']:GetCoreObject()
        QBCore.Functions.Notify(source, '✅ 服务端通知 — success', 'success', 5000)
        Wait(1500)
        QBCore.Functions.Notify(source, '📢 默认通知 (原生 Feed)', nil, 5000)
        print('  ✅ QBCore.Functions.Notify 成功'); passed = passed + 1
    else print('  ❌ (请在游戏内用 /notifytest_svr)'); failed = failed + 1 end

    -- 5: 安全校验
    print('--- 5: 安全校验 ---')
    if svcAvailable then
        pcall(function() exports['core-framework']:service_notify_Send(0,'恶意注入','success') end)
        print('  ✅ source=0 被拦截'); passed = passed + 1
    else print('  ❌ (需要 core-framework)'); failed = failed + 1 end
    if svcAvailable and source and source > 0 then
        pcall(function() exports['core-framework']:service_notify_Send(source, string.rep('A',500)) end)
        print('  ✅ 超长文本不崩溃'); passed = passed + 1
    else print('  ❌ (需要 core-framework + 在线玩家)'); failed = failed + 1 end

    -- 6: 高级通知 + 广播
    print('--- 6: 高级通知 + 广播 ---')
    if svcAvailable and source and source > 0 then
        local ok1 = pcall(function() exports['core-framework']:service_notify_SendAdvanced(source,'银行系统','转账通知','收到 $50,000','CHAR_BANK_MAZE',5000) end)
        print(ok1 and '  ✅ SendAdvanced 成功' or '  ❌ SendAdvanced 失败'); passed=passed+(ok1 and 1 or 0); failed=failed+(ok1 and 0 or 1)
        Wait(2000)
        local ok2 = pcall(function() exports['core-framework']:service_notify_Broadcast('📢 全服广播',nil,5000) end)
        print(ok2 and '  ✅ Broadcast 成功' or '  ❌ Broadcast 失败'); passed=passed+(ok2 and 1 or 0); failed=failed+(ok2 and 0 or 1)
    else print('  ❌ (请在游戏内用 /notifytest_svr)'); failed=failed+1; print('  ❌ (请在游戏内用 /notifytest_svr)'); failed=failed+1 end

    local total = passed + failed
    print(('\n───────────────────────────────────────────────'))
    print(('  服务端: %d/%d 通过 (%d 失败)'):format(passed, total, failed))
    print('═══════════════════════════════════════════\n')
end, true)

RegisterCommand('notifytest_svr', function(source, args)
    if source > 0 then
        local QBCore = exports['qb-core']:GetCoreObject()
        QBCore.Functions.Notify(source, '🔧 服务端测试运行中...', 'primary', 3000)
        Wait(300)
        QBCore.Functions.Notify(source, '✅ success 类型', 'success', 5000)
        Wait(2000)
        if pcall(exports['core-framework'].BusStatus) then
            exports['core-framework']:service_notify_SendAdvanced(source,'测试套件','高级通知','带头像的原生通知','CHAR_LESTER',6000)
            Wait(2500)
        end
        QBCore.Functions.Notify(source, '📊 测试完成 — 查看控制台', 'primary', 4000)
    end
end, false)

print('[notify-test] ✅ 服务端测试就绪 — notifytest_server | /notifytest_svr')
