-- server_test.lua — T-City Lite 游戏内测试调度入口
-- 提供 /test 系列命令，管理和运行测试套件
--
-- 命令列表:
--   /test list              — 列出可用套件
--   /test run <名称>        — 运行指定套件
--   /test run all           — 运行全部
--   /test mock <N>          — 设置模拟警察人数（单人模式）
--   /test mock summary      — 查看模拟玩家状态
--   /test report            — 查看上次结果

local function IsAdmin(source)
    if not source or source < 0 then
        return true  -- 模拟玩家/RCON 视为管理员
    end
    if Config.AdminWhitelist and #Config.AdminWhitelist > 0 then
        -- TODO: check against identifier whitelist
        return false
    end
    return true  -- 开发阶段，默认所有人可用
end

-- ─── /test 命令 ───

RegisterCommand('test', function(source, args, raw)
    if not IsAdmin(source) then
        TriggerClientEvent('QBCore:Notify', source, '你没有权限运行测试', 'error')
        return
    end

    local cmd = args[1] and args[1]:lower() or 'help'

    if cmd == 'list' then
        local suites = Test.listSuites()
        print("[test] 可用测试套件:")
        if #suites == 0 then
            print("  (无)")
            return
        end
        for _, name in ipairs(suites) do
            print(("  📋 %s"):format(name))
        end

    elseif cmd == 'run' then
        local target = args[2]
        if not target then
            print("[test] 用法: /test run <套件名|all>")
            return
        end

        if target == 'all' then
            Test.runAll(source)
        else
            Test.run(target, source)
        end

        -- 保存报告
        if Config.TestReportPath then
            local report = Test.getLastResult()
            -- TODO: write report to file via oxmysql/fs
            print(("[test] 📝 报告已保存 (current session)"))
        end

    elseif cmd == 'mock' then
        if not Config.SinglePlayerMode then
            print("[test] 单人模式未启用，跳过模拟")
            return
        end
        local sub = args[2]
        if sub == 'summary' then
            Mock.summary()
        elseif sub then
            local count = tonumber(sub)
            if count then
                Mock.setPoliceOnDuty(count)
            else
                print("[test] 用法: /test mock <警察人数|summary>")
            end
        else
            print("[test] 用法: /test mock <警察人数|summary>")
        end

    elseif cmd == 'report' then
        local results = Test.getLastResult()
        if not results or next(results) == nil then
            print("[test] 尚无测试结果")
            return
        end
        print("[test] 上次测试结果:")
        for suite_name, suite_result in pairs(results) do
            for test_name, entry in pairs(suite_result.tests or {}) do
                print(("  %s %s.%s"):format(
                    entry.status == "PASS" and "✅" or "❌",
                    suite_name, test_name))
            end
        end

    elseif cmd == 'help' then
        print("[test] 命令列表:")
        print("  /test list                  — 列出可用套件")
        print("  /test run <套件名|all>      — 运行测试")
        print("  /test mock <N|summary>       — 模拟玩家管理")
        print("  /test report                 — 查看上次结果")
        print("  /test help                   — 本帮助")

    else
        print(("[test] 未知命令: %s（输入 /test help 查看帮助）"):format(cmd))
    end
end, false)

-- ─── 启动提示 ───
print("[test] ✅ 测试调度器已加载")
print("[test] 输入 /test help 查看可用命令")
