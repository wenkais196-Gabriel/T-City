-- test_runner.lua — T-City Lite 游戏内测试引擎
-- 提供断言、套件管理和报告输出
--
-- 用法:
--   Test.describe("套件名", function()
--     Test.it("用例描述", function(source)
--       Test.assert_equal(a, b, "a 应等于 b")
--       Test.assert_true(cond, "条件应为真")
--     end)
--   end)
--   Test.run("套件名")  -- 或 Test.runAll()

Test = Test or {}

-- 内部状态
Test._suites = {}       -- {name -> {tests = {name -> fn}}}
Test._results = {}      -- {suite_name -> {tests = {test_name -> {pass, reason}}}}
Test._current_suite = nil
Test._current_test = nil
Test._start_time = nil

-- 统计
Test._stats = { pass = 0, fail = 0, error = 0, skip = 0 }

-- ─── 套件与用例注册 ───

--- 声明一个测试套件
---@param name string 套件名称
---@param fn function 套件内容，内部调用 Test.it()
function Test.describe(name, fn)
    if Test._suites[name] then
        print(("[test] ⚠️  套件重名: %s (将被覆盖)"):format(name))
    end
    Test._suites[name] = { tests = {} }
    Test._current_suite = name

    -- 执行 describe 内容注册用例
    local ok, err = pcall(fn)
    if not ok then
        print(("[test] ❌ 套件 '%s' 加载失败: %s"):format(name, err))
        Test._suites[name] = nil
    end

    Test._current_suite = nil
end

--- 声明一个测试用例
---@param name string 用例描述
---@param fn function(source) 测试逻辑，接收调用者 source
function Test.it(name, fn)
    if not Test._current_suite then
        error("Test.it() 必须在 Test.describe() 内调用")
    end
    if Test._suites[Test._current_suite].tests[name] then
        print(("[test] ⚠️  用例重名: %s.%s"):format(Test._current_suite, name))
    end
    Test._suites[Test._current_suite].tests[name] = fn
end

-- ─── 断言 ───

--- 断言两个值相等（深度比较）
function Test.assert_equal(expected, actual, message)
    message = message or ("期望 %s, 实际 %s"):format(tostring(expected), tostring(actual))
    if expected ~= actual then
        Test._fail(message)
    else
        Test._pass(message)
    end
end

--- 断言条件为真
function Test.assert_true(condition, message)
    message = message or "条件应为真"
    if not condition then
        Test._fail(message)
    else
        Test._pass(message)
    end
end

--- 断言条件为假
function Test.assert_false(condition, message)
    message = message or "条件应为假"
    if condition then
        Test._fail(message)
    else
        Test._pass(message)
    end
end

--- 断言值为 nil
function Test.assert_nil(value, message)
    message = message or "值应为 nil"
    if value ~= nil then
        Test._fail(message .. ("（实际: %s）"):format(tostring(value)))
    else
        Test._pass(message)
    end
end

--- 断言值非 nil
function Test.assert_not_nil(value, message)
    message = message or "值不应为 nil"
    if value == nil then
        Test._fail(message)
    else
        Test._pass(message)
    end
end

--- 强制跳过当前用例
function Test.skip(reason)
    reason = reason or "无原因"
    Test._stats.skip = Test._stats.skip + 1
    local entry = {
        status = "SKIP",
        reason = reason,
    }
    if Test._current_suite and Test._current_test then
        Test._results[Test._current_suite].tests[Test._current_test] = entry
    end
    error(("[SKIP] %s"):format(reason))  -- 中断当前用例
end

-- ─── 内部方法 ───

function Test._pass(message)
    Test._stats.pass = Test._stats.pass + 1
    if Config and Config.RunMode == "verbose" then
        print(("[test] ✅ %s"):format(message))
    end
end

function Test._fail(message)
    Test._stats.fail = Test._stats.fail + 1
    print(("[test] ❌ %s"):format(message or ""))
    local entry = {
        status = "FAIL",
        reason = message,
    }
    if Test._current_suite and Test._current_test then
        Test._results[Test._current_suite].tests[Test._current_test] = entry
    end
end

-- ─── 执行 ───

--- 运行指定套件
---@param suite_name string 套件名
---@param source number|nil 调用者玩家的 source（可选，默认使用模拟玩家）
---@return table 测试结果
function Test.run(suite_name, source)
    local suite = Test._suites[suite_name]
    if not suite then
        print(("[test] ❌ 套件 '%s' 不存在"):format(suite_name))
        print("[test] 可用套件: " .. table.concat(Test.listSuites(), ", "))
        return { pass = 0, fail = 0, error = 0 }
    end

    -- 初始化结果
    Test._results[suite_name] = { tests = {} }
    Test._stats = { pass = 0, fail = 0, error = 0, skip = 0 }
    Test._current_suite = suite_name

    local suite_total = 0
    local suite_run = 0

    -- 计算总用例数
    for _ in pairs(suite.tests) do
        suite_total = suite_total + 1
    end

    print(("\n═══════════════════════════════════════════════"))
    print(("  测试套件: %s (%d 个用例)"):format(suite_name, suite_total))
    print(("═══════════════════════════════════════════════"))

    Test._start_time = os.time()

    for test_name, test_fn in pairs(suite.tests) do
        Test._current_test = test_name
        local ok, err = pcall(test_fn, source or -1)
        if not ok and err and not err:match("^%[SKIP%]") then
            -- 真正的错误（不是 skip）
            Test._stats.error = Test._stats.error + 1
            print(("[test] 🔴 %s — 异常: %s"):format(test_name, err))
            Test._results[suite_name].tests[test_name] = {
                status = "ERROR",
                reason = err,
            }
        elseif ok or err then
            -- 正常通过，或已通过 _fail() 记录
            if not Test._results[suite_name].tests[test_name] then
                Test._results[suite_name].tests[test_name] = {
                    status = "PASS",
                    reason = "通过",
                }
            end
        end
        suite_run = suite_run + 1

        -- 输出现场进度
        local entry = Test._results[suite_name].tests[test_name]
        if entry then
            local marker = "✅"
            if entry.status == "FAIL" then marker = "❌"
            elseif entry.status == "SKIP" then marker = "⏭️"
            elseif entry.status == "ERROR" then marker = "🔴" end
            print(("  %s [%s/%s] %s"):format(marker, suite_run, suite_total, test_name))
            if Config.RunMode == "verbose" and entry.reason then
                print(("      → %s"):format(entry.reason))
            end
        end

        -- FailFast
        if Config.FailFast and Test._stats.fail > 0 then
            print(("  ⚡  FailFast 触发，中断剩余 %d 个用例"):format(suite_total - suite_run))
            break
        end
    end

    -- 报告
    local elapsed = os.time() - Test._start_time
    print(("───────────────────────────────────────────────"))
    print(("  结果: ✅ %d PASS | ❌ %d FAIL | 🔴 %d ERROR | ⏭️ %d SKIP"):format(
        Test._stats.pass, Test._stats.fail, Test._stats.error, Test._stats.skip))
    print(("  耗时: %ds"):format(elapsed))
    print(("═══════════════════════════════════════════════\n"))

    Test._current_suite = nil
    Test._current_test = nil

    return Test._stats
end

--- 运行所有已注册的测试套件
function Test.runAll(source)
    local suites = Test.listSuites()
    local overall = { pass = 0, fail = 0, error = 0, skip = 0 }

    for _, name in ipairs(suites) do
        local result = Test.run(name, source)
        overall.pass = overall.pass + (result.pass or 0)
        overall.fail = overall.fail + (result.fail or 0)
        overall.error = overall.error + (result.error or 0)
        overall.skip = overall.skip + (result.skip or 0)
    end

    print("\n" .. "=" * 60)
    print("  总体报告")
    print("=" * 60)
    print(("  ✅ %d PASS | ❌ %d FAIL | 🔴 %d ERROR | ⏭️ %d SKIP"):format(
        overall.pass, overall.fail, overall.error, overall.skip))
    print()

    return overall
end

--- 列出所有已注册的测试套件
---@return table 套件名称列表
function Test.listSuites()
    local names = {}
    for name, _ in pairs(Test._suites) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

--- 获取最近一次测试结果
function Test.getLastResult(suite_name)
    if suite_name then
        return Test._results[suite_name]
    end
    return Test._results
end

-- ─── 初始化 ───
print("[test] ✅ 测试引擎已加载")
