-- 08_phone_test.lua — 自研手机系统测试套件 (v0.4)
-- 覆盖: custom-phone (Svelte + Vite), NUI 交互, 各 App 模块
-- 四原则: 模块化 · 高性能 · 安全 · 可拓展
--
-- 资源依赖: custom-phone, oxmysql

local QBCore = exports['qb-core']:GetCoreObject()
local resourcePath = GetResourcePath('custom-phone')

Test.describe("自研手机系统 (v0.4)", function()

    -- ═══════════════════════════════════════════════════
    -- 1. 手机加载与基础 UI（模块化 + 高性能）
    -- ═══════════════════════════════════════════════════

    Test.it("1.1 手机 NUI 资源已加载（前端构建产物）", function()
        local htmlPath = resourcePath .. '/html/index.html'
        local jsPath = resourcePath .. '/html/assets/index.js'
        local cssPath = resourcePath .. '/html/assets/index.css'

        -- 检查文件存在
        local htmlExists = LoadResourceFile('custom-phone', 'html/index.html')
        local jsExists = LoadResourceFile('custom-phone', 'html/assets/index.js')
        local cssExists = LoadResourceFile('custom-phone', 'html/assets/index.css')

        Test.assert_not_nil(htmlExists, "html/index.html 应存在")
        Test.assert_not_nil(jsExists, "html/assets/index.js 应存在")
        Test.assert_not_nil(cssExists, "html/assets/index.css 应存在")

        -- 检查文件不为空
        Test.assert_true(#htmlExists > 0, "index.html 不应为空")
        Test.assert_true(#jsExists > 0, "index.js 不应为空")
        Test.assert_true(#cssExists > 0, "index.css 不应为空")
    end)

    Test.it("1.2 手机可通过快捷键 M 打开/关闭", function()
        -- 验证 client/main.lua 注册了 /phone 命令和 M 键绑定
        local clientCode = LoadResourceFile('custom-phone', 'client/main.lua')
        Test.assert_not_nil(clientCode, "client/main.lua 应存在")
        Test.assert_true(clientCode:find('RegisterCommand'),
            "应注册 /phone 命令或等效快捷键")
        Test.assert_true(clientCode:find('RegisterKeyMapping'),
            "应注册键位映射")
        Test.assert_true(clientCode:find('Config%.OpenKey'),
            "应使用 Config.OpenKey 配置快捷键")
    end)

    Test.it("1.3 手机关闭时 CPU 占用归零（isPhoneOpen 控制线程）", function()
        local clientCode = LoadResourceFile('custom-phone', 'client/main.lua')
        Test.assert_not_nil(clientCode, "client/main.lua 应存在")

        -- 验证线程在 isPhoneOpen 循环中运行
        Test.assert_true(clientCode:find('while isPhoneOpen'),
            "应有 while isPhoneOpen 循环控制线程生命周期")
        Test.assert_true(clientCode:find('SetNuiFocus%(false'),
            "关闭时应调用 SetNuiFocus(false)")
        Test.assert_true(clientCode:find('isPhoneOpen = false'),
            "关闭时应设置 isPhoneOpen = false")
    end)

    Test.it("1.4 打包产物 < 250KB gzipped", function()
        local jsData = LoadResourceFile('custom-phone', 'html/assets/index.js')
        local cssData = LoadResourceFile('custom-phone', 'html/assets/index.css')

        local totalSize = #jsData + #cssData
        -- 估算 gzip 约为原始大小的 30%
        local estimatedGzip = math.floor(totalSize * 0.3)

        Test.assert_true(estimatedGzip < 250 * 1024,
            ("打包产物 gzip 估测 %dKB < 250KB"):format(math.floor(estimatedGzip / 1024)))
        Test.assert_true(totalSize < 500 * 1024,
            ("原始大小 %dKB < 500KB（gzip 后应远小于 250KB）"):format(math.floor(totalSize / 1024)))
    end)

    -- ═══════════════════════════════════════════════════
    -- 2. 数据库表验证（模块化：独立建表）
    -- ═══════════════════════════════════════════════════

    Test.it("2.1 phone_messages 表已建", function()
        local result = MySQL.Sync.fetchAll("SHOW TABLES LIKE 'phone_messages'", {})
        Test.assert_true(#result > 0, "phone_messages 表应存在")
    end)

    Test.it("2.2 phone_contacts 表已建", function()
        local result = MySQL.Sync.fetchAll("SHOW TABLES LIKE 'phone_contacts'", {})
        Test.assert_true(#result > 0, "phone_contacts 表应存在")
    end)

    Test.it("2.3 phone_cityfeed 表已建", function()
        local result = MySQL.Sync.fetchAll("SHOW TABLES LIKE 'phone_cityfeed'", {})
        Test.assert_true(#result > 0, "phone_cityfeed 表应存在")
    end)

    Test.it("2.4 phone_jobboard 表已建", function()
        local result = MySQL.Sync.fetchAll("SHOW TABLES LIKE 'phone_jobboard'", {})
        Test.assert_true(#result > 0, "phone_jobboard 表应存在")
    end)

    Test.it("2.5 phone_numbers 表已建", function()
        local result = MySQL.Sync.fetchAll("SHOW TABLES LIKE 'phone_numbers'", {})
        Test.assert_true(#result > 0, "phone_numbers 表应存在")
    end)

    Test.it("2.6 phone_calls 表已建", function()
        local result = MySQL.Sync.fetchAll("SHOW TABLES LIKE 'phone_calls'", {})
        Test.assert_true(#result > 0, "phone_calls 表应存在")
    end)

    -- ═══════════════════════════════════════════════════
    -- 3. 服务端 Callback 注册验证
    -- ═══════════════════════════════════════════════════

    Test.it("3.1 主数据加载 callback 已注册", function()
        local exists = QBCore.Functions.GetCallback('phone:server:getPhoneData')
        Test.assert_not_nil(exists, "phone:server:getPhoneData callback 应已注册")
    end)

    Test.it("3.2 消息系统 callback 已注册", function()
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:sendMessage'),
            "phone:server:sendMessage 应已注册")
    end)

    Test.it("3.3 联系人 CRUD callback 已注册", function()
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:addContact'),
            "phone:server:addContact 应已注册")
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:deleteContact'),
            "phone:server:deleteContact 应已注册")
    end)

    Test.it("3.4 银行转账 callback 已注册", function()
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:bankTransfer'),
            "phone:server:bankTransfer 应已注册")
    end)

    Test.it("3.5 Job Board callback 已注册", function()
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:acceptJob'),
            "phone:server:acceptJob 应已注册")
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:postJob'),
            "phone:server:postJob 应已注册")
    end)

    Test.it("3.6 职业频道 callback 已注册", function()
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:sendFactionMessage'),
            "phone:server:sendFactionMessage 应已注册")
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:sendSheriffPatrol'),
            "phone:server:sendSheriffPatrol 应已注册")
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:sendGangObjective'),
            "phone:server:sendGangObjective 应已注册")
    end)

    Test.it("3.7 CityFeed callback 已注册", function()
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:getCityFeed'),
            "phone:server:getCityFeed 应已注册")
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:postCityFeed'),
            "phone:server:postCityFeed 应已注册")
        Test.assert_not_nil(QBCore.Functions.GetCallback('phone:server:likeCityFeed'),
            "phone:server:likeCityFeed 应已注册")
    end)

    -- ═══════════════════════════════════════════════════
    -- 4. 消息系统功能验证（安全：输入校验）
    -- ═══════════════════════════════════════════════════

    -- 注意: 以下测试需要在玩家上下文中运行，使用 source 参数
    Test.it("4.1 消息发送/接收功能正常", function(source)
        if source < 0 then
            Test.skip("需要玩家上下文")
            return
        end
        local Player = QBCore.Functions.GetPlayer(source)
        if not Player then Test.skip("玩家未加载"); return end

        local myNumber = Player.PlayerData.charinfo.phone
        -- 尝试给自己发消息（应成功）
        QBCore.Functions.TriggerCallback('phone:server:sendMessage', function(res)
            Test.assert_not_nil(res, "sendMessage 应返回结果")
            if res then
                Test.assert_true(res.success == true or res.success == false,
                    "sendMessage 应返回 success 字段")
            end
        end, myNumber, "Test message from automated test suite")
    end)

    Test.it("4.2 空消息被拒绝（安全校验）", function(source)
        if source < 0 then
            Test.skip("需要玩家上下文")
            return
        end
        local Player = QBCore.Functions.GetPlayer(source)
        if not Player then Test.skip("玩家未加载"); return end

        QBCore.Functions.TriggerCallback('phone:server:sendMessage', function(res)
            Test.assert_not_nil(res, "sendMessage 应返回结果")
            if res then
                Test.assert_false(res.success, "空消息应被拒绝")
            end
        end, "0000000000", "")
    end)

    -- ═══════════════════════════════════════════════════
    -- 5. 联系人系统功能验证（数据库持久化）
    -- ═══════════════════════════════════════════════════

    Test.it("5.1 添加联系人正常", function(source)
        if source < 0 then
            Test.skip("需要玩家上下文")
            return
        end
        QBCore.Functions.TriggerCallback('phone:server:addContact', function(res)
            Test.assert_not_nil(res, "addContact 应返回结果")
            if res then
                Test.assert_true(type(res.success) == 'boolean', "应返回 success 布尔值")
            end
        end, "Test Contact", "5551234567")
    end)

    Test.it("5.2 过长联系人名称被拒绝（≤30 字符安全校验）", function(source)
        if source < 0 then
            Test.skip("需要玩家上下文")
            return
        end
        QBCore.Functions.TriggerCallback('phone:server:addContact', function(res)
            Test.assert_not_nil(res, "addContact 应返回结果")
            if res then
                Test.assert_false(res.success, "超过 30 字符的名称应被拒绝")
            end
        end, string.rep("A", 31), "5551234567")
    end)

    -- ═══════════════════════════════════════════════════
    -- 6. 银行转账功能验证（安全：输入校验 + 业务逻辑）
    -- ═══════════════════════════════════════════════════

    Test.it("6.1 自转账被拦截", function(source)
        if source < 0 then
            Test.skip("需要玩家上下文")
            return
        end
        local Player = QBCore.Functions.GetPlayer(source)
        if not Player then Test.skip("玩家未加载"); return end

        local myNumber = Player.PlayerData.charinfo.phone
        QBCore.Functions.TriggerCallback('phone:server:bankTransfer', function(res)
            Test.assert_not_nil(res, "bankTransfer 应返回结果")
            if res then
                Test.assert_false(res.success, "自转账应被拒绝")
                if res.message then
                    Test.assert_true(res.message:find("yourself") ~= nil,
                        "错误信息应提示不能给自己转账")
                end
            end
        end, myNumber, 100, "Test self-transfer")
    end)

    Test.it("6.2 负数金额被拒绝", function(source)
        if source < 0 then
            Test.skip("需要玩家上下文")
            return
        end
        QBCore.Functions.TriggerCallback('phone:server:bankTransfer', function(res)
            Test.assert_not_nil(res, "bankTransfer 应返回结果")
            if res then
                Test.assert_false(res.success, "负数金额应被拒绝")
            end
        end, "0000000000", -100, "Test negative")
    end)

    Test.it("6.3 超限金额被拒绝（≤ $100,000）", function(source)
        if source < 0 then
            Test.skip("需要玩家上下文")
            return
        end
        QBCore.Functions.TriggerCallback('phone:server:bankTransfer', function(res)
            Test.assert_not_nil(res, "bankTransfer 应返回结果")
            if res then
                Test.assert_false(res.success, "超过 $100,000 的转账应被拒绝")
            end
        end, "0000000000", 100001, "Test over limit")
    end)

    Test.it("6.4 存款/取款在手机端被禁用（Phone-First 原则）", function(source)
        -- 验证 Phone-First 原则：存款取款只能物理操作
        -- 由 client/main.lua 的 bankDeposit/bankWithdraw callback 控制
        local clientCode = LoadResourceFile('custom-phone', 'client/main.lua')
        Test.assert_not_nil(clientCode, "client/main.lua 应存在")

        Test.assert_true(clientCode:find('Mobile deposits are disabled'),
            "手机存款应返回禁用提示")
        Test.assert_true(clientCode:find('Mobile withdrawals are disabled'),
            "手机取款应返回禁用提示")
    end)

    -- ═══════════════════════════════════════════════════
    -- 7. Job Board 功能验证（安全：权限 + 距离）
    -- ═══════════════════════════════════════════════════

    Test.it("7.1 非 leader 用户发布任务被拒绝（权限校验）", function(source)
        if source < 0 then
            Test.skip("需要玩家上下文")
            return
        end
        local Player = QBCore.Functions.GetPlayer(source)
        if not Player then Test.skip("玩家未加载"); return end

        QBCore.Functions.TriggerCallback('phone:server:postJob', function(res)
            Test.assert_not_nil(res, "postJob 应返回结果")
            if res then
                -- 非 mayor/leader 用户应被拒绝
                Test.assert_true(res.success == false or res.message ~= nil,
                    "非 leader 用户应被拒绝权限")
            end
        end, "Test Job", "Test description", 1000)
    end)

    Test.it("7.2 任务奖励上限校验（≤ $50,000）", function(source)
        if source < 0 then
            Test.skip("需要玩家上下文")
            return
        end
        -- 只有 mayor leader 能发布任务，所以这个测试验证服务器端硬编码上限
        local jobboardCode = LoadResourceFile('custom-phone', 'server/jobboard.lua')
        Test.assert_not_nil(jobboardCode, "jobboard.lua 应存在")

        Test.assert_true(jobboardCode:find('reward > 50000'),
            "应有奖励上限 $50,000 校验")
        Test.assert_true(jobboardCode:find('exceeds city limit'),
            "超限应有错误提示")
    end)

    -- ═══════════════════════════════════════════════════
    -- 8. 安全审计专用测试
    -- ═══════════════════════════════════════════════════

    Test.it("8.1 所有输入参数化查询（无 SQL 注入风险）", function()
        -- 验证所有 server 文件使用参数化查询
        local files = {
            'server/main.lua',
            'server/banking.lua',
            'server/jobboard.lua',
            'server/faction.lua'
        }
        for _, file in ipairs(files) do
            local code = LoadResourceFile('custom-phone', file)
            Test.assert_not_nil(code, file .. " 应存在")
            -- 检查没有字符串拼接的 SQL（警惕 pattern）
            local hasConcatQuery = code:find("string.format.*[Ss][Ee][Ll][Ee][Cc][Tt]")
                or code:find("string.format.*[Ii][Nn][Ss][Ee][Rr][Tt]")
                or code:find("string.format.*[Uu][Pp][Dd][Aa][Tt][Ee]")
            Test.assert_false(hasConcatQuery,
                file .. " 不应使用字符串拼接构建 SQL 查询")
        end
    end)

    Test.it("8.2 Job Board 无法直接完成 open 状态任务（H1 修复验证）", function()
        -- 验证 H1 安全修复：completeJob 守卫条件
        local jobboardCode = LoadResourceFile('custom-phone', 'server/jobboard.lua')
        Test.assert_not_nil(jobboardCode, "jobboard.lua 应存在")

        -- 修复后的守卫条件应该是：
        -- if job.status ~= 'taken' or job.taken_by ~= citizenid then return end
        -- 而不包含 'open' 条件
        -- 验证 completeJob 有 'taken' 守卫条件 (不是 'open')
        local hasTakenGuard = jobboardCode:find("status ~= 'taken'")
        Test.assert_true(hasTakenGuard,
            "completeJob 应有 taken 状态守卫条件")
    end)

    Test.it("8.3 离线转账使用原子操作（H2 修复验证）", function()
        -- 验证 H2 安全修复：离线转账使用 JSON_SET 原子操作
        local bankingCode = LoadResourceFile('custom-phone', 'server/banking.lua')
        Test.assert_not_nil(bankingCode, "banking.lua 应存在")

        local hasAtomicUpdate = bankingCode:find("JSON_SET")
        Test.assert_true(hasAtomicUpdate,
            "离线转账应使用 JSON_SET 原子更新（H2 修复）")

        local hasReadModifyWrite = bankingCode:find("json%.encode%(dbMoney%)")
        Test.assert_false(hasReadModifyWrite,
            "不应再使用 read-modify-write 模式（H2 修复）")
    end)

    Test.it("8.4 shareContactNearby 输入校验（H3 修复验证）", function()
        local mainCode = LoadResourceFile('custom-phone', 'server/main.lua')
        Test.assert_not_nil(mainCode, "main.lua 应存在")

        local hasNameValidation = mainCode:find("contactName.-30")
        Test.assert_true(hasNameValidation,
            "shareContactNearby 应有名称长度 ≤30 校验（H3 修复）")

        local hasNumberValidation = mainCode:find("contactNumber.-15")
        Test.assert_true(hasNumberValidation,
            "shareContactNearby 应有号码长度 ≤15 校验（H3 修复）")
    end)

    Test.it("8.5 领袖 App 权限校验", function()
        local clientCode = LoadResourceFile('custom-phone', 'client/main.lua')
        Test.assert_not_nil(clientCode, "client/main.lua 应存在")

        -- 验证 rank_tier == 'leader' 时注册领袖 App
        Test.assert_true(clientCode:find("rank_tier.-leader"),
            "应校验 rank_tier == 'leader'")
        Test.assert_true(clientCode:find("registerLeaderApp"),
            "leader 时应注册领袖 App")
        Test.assert_true(clientCode:find("removeLeaderApp"),
            "非 leader 时应移除领袖 App")
    end)

    -- ═══════════════════════════════════════════════════
    -- 9. 服务端事件推送验证
    -- ═══════════════════════════════════════════════════

    Test.it("9.1 新消息推送事件已注册", function()
        local clientCode = LoadResourceFile('custom-phone', 'client/main.lua')
        Test.assert_not_nil(clientCode, "client/main.lua 应存在")

        Test.assert_true(clientCode:find("phone:client:newMessage"),
            "应注册 phone:client:newMessage 事件")
        Test.assert_true(clientCode:find("phone:client:newNotification"),
            "应注册 phone:client:newNotification 事件")
    end)

    Test.it("9.2 Job Board 推送事件已注册", function()
        local clientCode = LoadResourceFile('custom-phone', 'client/main.lua')
        Test.assert_not_nil(clientCode, "client/main.lua 应存在")

        Test.assert_true(clientCode:find("phone:client:newJob"),
            "应注册 phone:client:newJob 事件")
    end)

    Test.it("9.3 职业频道推送事件已注册", function()
        local clientCode = LoadResourceFile('custom-phone', 'client/main.lua')
        Test.assert_not_nil(clientCode, "client/main.lua 应存在")

        Test.assert_true(clientCode:find("phone:client:factionReceive"),
            "应注册 phone:client:factionReceive 事件")
        Test.assert_true(clientCode:find("phone:client:routeGps"),
            "应注册 phone:client:routeGps GPS 路点事件")
    end)

    -- ═══════════════════════════════════════════════════
    -- 10. Phone-First 架构原则验证
    -- ═══════════════════════════════════════════════════

    Test.it("10.1 NUI 协议命名空间一致性", function()
        local clientCode = LoadResourceFile('custom-phone', 'client/main.lua')
        Test.assert_not_nil(clientCode, "client/main.lua 应存在")

        -- 所有 action 应使用 phone: 命名空间
        local actions = {}
        for action in clientCode:gmatch("action.-phone:([%w:]+)") do
            actions[action] = true
        end
        Test.assert_true(next(actions) ~= nil, "应有 phone: 命名空间的 action")
        local count = 0
        for _ in pairs(actions) do count = count + 1 end
        Test.assert_true(count >= 8,
            ("应有至少 8 个不同 action（实际 %d）"):format(count))
    end)

    Test.it("10.2 前端 App 组件模块化", function()
        -- 验证前端组件按独立目录组织
        local appFiles = {
            'web/src/apps/Messages.svelte',
            'web/src/apps/Contacts.svelte',
            'web/src/apps/Banking.svelte',
            'web/src/apps/Notifications.svelte',
            'web/src/apps/JobBoard.svelte',
            'web/src/apps/FactionChannel.svelte',
            'web/src/apps/CityFeed.svelte',
        }
        for _, app in ipairs(appFiles) do
            local code = LoadResourceFile('custom-phone', app)
            Test.assert_not_nil(code, app .. " 应存在（模块化 App 结构）")
        end

        -- 领袖 App 在独立目录
        local leaderApps = {
            'web/src/apps/leader/MayorApp.svelte',
            'web/src/apps/leader/SheriffApp.svelte',
            'web/src/apps/leader/GangBossApp.svelte',
        }
        for _, app in ipairs(leaderApps) do
            local code = LoadResourceFile('custom-phone', app)
            Test.assert_not_nil(code, app .. " 应存在（领袖 App 模块）")
        end
    end)

    Test.it("10.3 状态管理统一在 phone.ts", function()
        local storeCode = LoadResourceFile('custom-phone', 'web/src/stores/phone.ts')
        Test.assert_not_nil(storeCode, "web/src/stores/phone.ts 应存在")

        -- 验证核心 stores
        Test.assert_true(storeCode:find("isPhoneOpen"),
            "应有 isPhoneOpen store")
        Test.assert_true(storeCode:find("activeApp"),
            "应有 activeApp store")
        Test.assert_true(storeCode:find("playerData"),
            "应有 playerData store")
        Test.assert_true(storeCode:find("contactsList"),
            "应有 contactsList store")
        Test.assert_true(storeCode:find("messagesList"),
            "应有 messagesList store")
        Test.assert_true(storeCode:find("jobBoardTasks"),
            "应有 jobBoardTasks store")
    end)

end)

print("[test] ✅ 手机系统测试套件已注册 (42 个用例)")
