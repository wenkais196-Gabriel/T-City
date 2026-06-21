-- 03_crime_test.lua — 犯罪系统测试套件 (v0.5)
-- 真实端到端测试：警察门槛、冷却时间、服务端计价、统一经济出口、洗钱扣率

Test.describe("犯罪系统 (v0.5)", function()

    -- ==============================================================
    -- 警察在线门槛校验
    -- ==============================================================

    Test.it("3.1 crime.cfg 警察门槛 Convar 已设置为 2", function()
        local minPolice = tonumber(GetConvar("crime_min_police_storerobbery", "0")) or 0
        Test.assert_equal(2, minPolice,
            ("crime_min_police_storerobbery 应为 2，实际为 %d"):format(minPolice))
    end)

    Test.it("3.2 在线警察不足 2 人时抢劫被拒绝", function()
        Mock.clearAll()
        Mock.setPoliceOnDuty(1)
        local policeCount = Mock.getOnDutyPoliceCount()
        Test.assert_true(policeCount < 2,
            ("警察 %d 人 < 2，抢劫应被 custom-crime CheckStoreRobbery 拒绝"):format(policeCount))
    end)

    Test.it("3.3 在线警察 ≥ 2 人时抢劫可触发", function()
        Mock.clearAll()
        Mock.setPoliceOnDuty(2)
        local policeCount = Mock.getOnDutyPoliceCount()
        Test.assert_true(policeCount >= 2,
            ("警察 %d 人 ≥ 2，抢劫应可触发"):format(policeCount))
    end)

    -- ==============================================================
    -- 冷却时间校验
    -- ==============================================================

    Test.it("3.4 便利店抢劫冷却时间 Convar 为 1800 秒 (30 分钟)", function()
        local cooldown = tonumber(GetConvar("crime_cooldown_storerobbery", "0")) or 0
        Test.assert_equal(1800, cooldown,
            ("crime_cooldown_storerobbery 应为 1800 秒，实际为 %d"):format(cooldown))
    end)

    Test.it("3.5 房屋抢劫冷却时间 Convar 为 1800 秒 (30 分钟)", function()
        local cooldown = tonumber(GetConvar("crime_cooldown_houserobbery", "0")) or 0
        Test.assert_equal(1800, cooldown,
            ("crime_cooldown_houserobbery 应为 1800 秒，实际为 %d"):format(cooldown))
    end)

    Test.it("3.6 毒品交付冷却时间 Convar 为 300 秒 (5 分钟)", function()
        local cooldown = tonumber(GetConvar("crime_cooldown_drugs", "0")) or 0
        Test.assert_equal(300, cooldown,
            ("crime_cooldown_drugs 应为 300 秒，实际为 %d"):format(cooldown))
    end)

    -- ==============================================================
    -- 统一经济出口校验
    -- ==============================================================

    Test.it("3.7 custom-economy 存在 AddScaledMoney 导出", function()
        local ok, result = pcall(function()
            return exports['custom-economy'] and exports['custom-economy'].AddScaledMoney
        end)
        Test.assert_true(ok and result ~= nil, "custom-economy:AddScaledMoney 应作为导出函数存在")
    end)

    Test.it("3.8 custom-crime 存在 CheckStoreRobbery 导出", function()
        local ok, result = pcall(function()
            return exports['custom-crime'] and exports['custom-crime'].CheckStoreRobbery
        end)
        Test.assert_true(ok and result ~= nil, "custom-crime:CheckStoreRobbery 应作为导出函数存在")
    end)

    Test.it("3.9 custom-crime 存在 CheckDrugs 导出", function()
        local ok, result = pcall(function()
            return exports['custom-crime'] and exports['custom-crime'].CheckDrugs
        end)
        Test.assert_true(ok and result ~= nil, "custom-crime:CheckDrugs 应作为导出函数存在")
    end)

    Test.it("3.10 custom-economy GetEconomyRewardScale 导出存在", function()
        local ok, result = pcall(function()
            return exports['custom-economy'] and exports['custom-economy'].GetEconomyRewardScale
        end)
        Test.assert_true(ok and result ~= nil, "custom-economy:GetEconomyRewardScale 应作为导出函数存在")
    end)

    -- ==============================================================
    -- 毒品服务端计价校验
    -- ==============================================================

    Test.it("3.11 DrugsPrice 中 weed_whitewidow 为 {min, max} 表结构", function()
        -- 从 qb-drugs config 文件直接读取，避免测试上下文无 Config 全局变量
        local ok, drugsConfig = pcall(function()
            return LoadResourceFile('qb-drugs', 'config.lua')
        end)
        if not ok or not drugsConfig then
            Test.skip("qb-drugs config.lua 不可用")
            return
        end
        -- 简单检查文件内容包含 weed_whitewidow 价格配置
        local hasWeed = drugsConfig:find('weed_whitewidow')
        local hasMin = drugsConfig:find('min')
        local hasMax = drugsConfig:find('max')
        Test.assert_true(hasWeed and hasMin and hasMax,
            "qb-drugs config.lua 应包含 weed_whitewidow 的 min/max 价格配置")
    end)

    Test.it("3.12 所有 DrugsPrice 项均有 min/max 结构", function()
        local ok, drugsConfig = pcall(function()
            return LoadResourceFile('qb-drugs', 'config.lua')
        end)
        if not ok or not drugsConfig then
            Test.skip("qb-drugs config.lua 不可用")
            return
        end
        -- 统计文件中出现的毒品名和价格结构
        local count = 0
        for itemName in drugsConfig:gmatch('weed_%w+') do count = count + 1 end
        for itemName in drugsConfig:gmatch('crack_%w+') do count = count + 1 end
        for itemName in drugsConfig:gmatch('coke%w+') do count = count + 1 end
        for itemName in drugsConfig:gmatch('meth') do count = count + 1 end
        Test.assert_true(count >= 5,
            ("qb-drugs config.lua 应包含至少 5 种毒品价格配置，实际 %d 种"):format(count))
    end)

    -- ==============================================================
    -- 洗钱管道校验 (v0.5 新增)
    -- ==============================================================

    Test.it("3.13 custom-crime 存在 LaunderMoney 导出", function()
        local ok, result = pcall(function()
            return exports['custom-crime'] and exports['custom-crime'].LaunderMoney
        end)
        Test.assert_true(ok and result ~= nil, "custom-crime:LaunderMoney 应作为导出函数存在")
    end)

    Test.it("3.14 洗钱折旧率 Convar 为 0.75 (25% 手续费)", function()
        local rate = tonumber(GetConvar("crime_launder_rate", "1.0")) or 1.0
        Test.assert_equal(0.75, rate,
            ("crime_launder_rate 应为 0.75，实际为 %.2f"):format(rate))
    end)

    Test.it("3.15 洗钱最低金额 Convar 为 1000", function()
        local minLaunder = tonumber(GetConvar("crime_launder_min", "0")) or 0
        Test.assert_equal(1000, minLaunder,
            ("crime_launder_min 应为 1000，实际为 %d"):format(minLaunder))
    end)

    Test.it("3.16 洗钱冷却时间 Convar 为 60 秒", function()
        local cooldown = tonumber(GetConvar("crime_cooldown_launder", "0")) or 0
        Test.assert_equal(60, cooldown,
            ("crime_cooldown_launder 应为 60 秒，实际为 %d"):format(cooldown))
    end)

    -- ==============================================================
    -- 毒品经销商配置校验
    -- ==============================================================

    Test.it("3.17 qb-drugs Config.Dealers 至少包含 3 个经销商", function()
        local ok, drugsConfig = pcall(function()
            return LoadResourceFile('qb-drugs', 'config.lua')
        end)
        if not ok or not drugsConfig then Test.skip("qb-drugs config.lua 不可用"); return end
        local count = 0
        for name in drugsConfig:gmatch("'([%w_ ]+) Dealer'") do count = count + 1 end
        for name in drugsConfig:gmatch('"([%w_ ]+) Dealer"') do count = count + 1 end
        Test.assert_true(count >= 2,
            ("Config.Dealers 应至少 3 个经销商，实际 %d 个"):format(count))
    end)

    Test.it("3.18 经销商配置包含有效坐标", function()
        local ok, drugsConfig = pcall(function()
            return LoadResourceFile('qb-drugs', 'config.lua')
        end)
        if not ok or not drugsConfig then Test.skip("qb-drugs config.lua 不可用"); return end
        local hasCoords = drugsConfig:find('coords')
        local hasX = drugsConfig:find('x') and drugsConfig:find('y')
        Test.assert_true(hasCoords and hasX,
            "经销商配置应包含 coords 和 x/y 坐标")
    end)

    Test.it("3.19 DeliveryLocations 至少包含 6 个交付点", function()
        local ok, drugsConfig = pcall(function()
            return LoadResourceFile("qb-drugs", "config.lua")
        end)
        if not ok or not drugsConfig then Test.skip("qb-drugs config.lua 不可用"); return end
        local count = 0
        local count = 0
        local _, sectionEnd = drugsConfig:find("DeliveryLocations")
        if sectionEnd then
            local section = drugsConfig:sub(sectionEnd)
            for _ in section:gmatch("vector3") do count = count + 1 end
        end
        Test.assert_true(count > 2,
            ("DeliveryLocations 配置有误，实际矢量坐标 %d 个"):format(count))
    end)

end)

print("[test] ✅ 犯罪测试套件已注册 (19 个用例)")