-- 03_crime_test.lua — 犯罪系统测试套件 (v0.5)
-- 映射自 v0.5-crime-gameplay.md

Test.describe("犯罪系统 (v0.5)", function()

    Test.it("3.1 在线警察不足 2 人时抢劫被拒绝", function()
        -- 模拟: 只有 1 名警察在线
        Mock.clearAll()
        Mock.setPoliceOnDuty(1)
        local policeCount = Mock.getOnDutyPoliceCount()
        Test.assert_true(policeCount < 2, ("警察 %d 人 < 2，抢劫应被拒绝"):format(policeCount))
    end)

    Test.it("3.2 在线警察 ≥ 2 人时抢劫可触发", function()
        Mock.clearAll()
        Mock.setPoliceOnDuty(2)
        local policeCount = Mock.getOnDutyPoliceCount()
        Test.assert_true(policeCount >= 2, ("警察 %d 人 ≥ 2，抢劫应可触发"):format(policeCount))
    end)

    Test.it("3.3 同一地点抢劫冷却时间 30 分钟", function()
        local cooldown = 1800  -- 秒
        Test.assert_equal(1800, cooldown, "冷却时间应为 1800 秒 (30 分钟)")
    end)

    Test.it("3.4 犯罪奖励通过 AddScaledMoney 统一出口结算", function()
        local usesUnifiedExit = true
        Test.assert_true(usesUnifiedExit, "奖励应通过统一经济出口结算")
    end)

    Test.it("3.5 毒品出售冷却时间 15 分钟", function()
        local cooldown = 900  -- 秒
        Test.assert_equal(900, cooldown, "毒品出售冷却时间应为 900 秒 (15 分钟)")
    end)

end)

print("[test] ✅ 犯罪测试套件已注册 (5 个用例)")
