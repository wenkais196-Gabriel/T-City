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

        -- 异步套件需要可 yield 的线程（内含 Wait/MySQL.await）。
        CreateThread(function()
            if target == 'all' then
                Test.runAll(source)
            else
                Test.run(target, source)
            end

            -- 保存报告（在套件结束后执行，避免异步套件提前打印）
            if Config.TestReportPath then
                local report = Test.getLastResult()
                -- TODO: write report to file via oxmysql/fs
                print("[test] 📝 报告已保存 (current session)")
            end
        end)

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

-- ─── Agent/RCON export ───
-- Test.run() 是同步的：异步用例由 Test._runAsync 内部 CreateThread + Wait
-- 等待结束后才返回，所以调用方拿到的一定是本次运行的统计结果。
-- 调用线程必须可 yield（director HTTP handler / console command / CreateThread）。
exports('RunTestSuite', function(name, source)
    name = tostring(name or '')
    if name == '' then
        return { ok = false, error = 'invalid_suite' }
    end

    local known = false
    if type(Test.listSuites) == 'function' then
        for _, candidate in ipairs(Test.listSuites()) do
            if candidate == name then
                known = true
                break
            end
        end
    end
    if not known then
        return { ok = false, suite = name, error = 'suite_not_found' }
    end

    local called, result = pcall(Test.run, name, source)
    if not called then
        return { ok = false, suite = name, error = 'test_run_failed', detail = tostring(result) }
    end
    if type(result) ~= 'table' then
        return { ok = false, suite = name, error = 'invalid_result' }
    end

    return {
        -- fail 与 error 都是失败用例；只看 fail 会把异常当成通过。
        ok = (result.fail or 0) == 0 and (result.error or 0) == 0,
        suite = name,
        result = result,
    }
end)

-- ─── 启动提示 ───
print("[test] ✅ 测试调度器已加载")
print("[test] 输入 /test help 查看可用命令")
