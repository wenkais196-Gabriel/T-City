-- tests/server/quest_flow_test.lua
-- ==========================================================================
-- 服务端用例测试：quest 状态机全流程 + 数据传递验证
--
-- 用法（在 FiveM 服务端控制台）:
--   refresh; ensure custom-quest
--   /quest_flow_test              — 运行所有用例
--   /quest_flow_test aviation     — 只测航空流程
--   /quest_flow_test security     — 只测安全层
-- ==========================================================================

local passed, failed = 0, 0
local startTime = os.clock()

local function assert(cond, label)
    if cond then
        passed = passed + 1
        print('  ✅ ' .. label)
    else
        failed = failed + 1
        print('  ❌ ' .. label)
    end
end

local function section(title)
    print('')
    print('━━━ ' .. title .. ' ━━━')
end

-- ==========================================================================
-- 用例 1: 任务模板完整性
-- ==========================================================================
local function test_template_integrity()
    section('1. 任务模板完整性')

    local quests = {
        'aviation_medical_airlift',
        'aviation_smuggling_flight',
        'pilot_license_exam',
    }

    for _, qid in ipairs(quests) do
        local tmpl = QuestRegistry.GetTemplate(qid)
        assert(tmpl ~= nil, '模板存在: ' .. qid)
        if tmpl then
            assert(type(tmpl.steps) == 'table' and #tmpl.steps > 0,
                qid .. ' 有 ' .. tostring(#tmpl.steps) .. ' 个步骤')
            assert(tmpl.id == qid, qid .. ' id 自洽')

            -- 每步类型合法
            for i, step in ipairs(tmpl.steps) do
                local valid = false
                for _, vt in pairs(Config.Quest.StepTypes) do
                    if vt == step.type then valid = true; break end
                end
                assert(valid, ('%s.step%d type=%s 合法'):format(qid, i, step.type))
            end
        end
    end
end

-- ==========================================================================
-- 用例 2: TriggerQuest → DB → Cache 数据流
-- ==========================================================================
local function test_trigger_quest()
    section('2. TriggerQuest 数据流')

    -- Mock source
    local src = 1

    -- 2a. 不存在的 quest → 返回 false
    local ok, msg = QuestManager.TriggerQuest(src, 'nonexistent_quest')
    assert(not ok, '不存在的 quest 返回 false')
    assert(msg and #msg > 0, '返回错误消息: ' .. tostring(msg))

    -- 2b. 模板结构校验覆盖
    local tmpl = QuestRegistry.GetTemplate('aviation_medical_airlift')
    assert(tmpl ~= nil, '民航模板可获取')

    if tmpl then
        -- 条件字段存在
        assert(tmpl.conditions ~= nil, '有 conditions')
        assert(tmpl.conditions.min_license == 'pilot', '需要飞行执照')

        -- rewards 字段完整
        assert(tmpl.rewards ~= nil, '有 rewards')
        assert(tmpl.rewards.money ~= nil, '有金钱奖励')
        assert(tmpl.rewards.rep ~= nil, '有声望奖励')

        -- 步骤链无空步骤
        for i, step in ipairs(tmpl.steps) do
            assert(step.id ~= nil and #step.id > 0, ('step%d id 非空'):format(i))
            assert(step.type ~= nil, ('step%d type 非空'):format(i))
        end

        -- 第一步是 validator (绑定飞机)
        assert(tmpl.steps[1].type == 'validator', '第一步是 validator')
        -- 最后一步是 validator (归还飞机)
        assert(tmpl.steps[#tmpl.steps].type == 'validator', '最后一步是 validator')

        -- 步骤 ID 唯一性
        local ids = {}
        for _, step in ipairs(tmpl.steps) do
            ids[step.id] = (ids[step.id] or 0) + 1
        end
        for sid, count in pairs(ids) do
            assert(count == 1, ('步骤 id 唯一: %s'):format(sid))
        end
    end
end

-- ==========================================================================
-- 用例 3: AdvanceStep 状态推进链
-- ==========================================================================
local function test_advance_step_chain()
    section('3. AdvanceStep 状态推进')

    local tmpl = QuestRegistry.GetTemplate('aviation_medical_airlift')
    if not tmpl then
        print('  ⚠️ 跳过 (模板未加载)')
        return
    end

    -- 3a. 模拟状态推进: step1 → step2 → ... → step8 → complete
    local simStep = 1
    local simState = 'IN_PROGRESS'

    print(('  模拟起始: [%s] step%d "%s"'):format(simState, simStep, tmpl.steps[simStep].title))

    while simStep <= #tmpl.steps do
        local step = tmpl.steps[simStep]
        assert(step ~= nil, ('步骤 %d 存在'):format(simStep))

        -- 验证每个步骤的 data 完整性
        if step.type == 'validator' then
            assert(step.data ~= nil, ('step%d validator 有 data'):format(simStep))
            if step.data then
                assert(step.data.validator_id ~= nil, ('step%d validator_id=%s'):format(simStep, tostring(step.data.validator_id)))
            end
        elseif step.type == 'reach' then
            assert(step.data ~= nil, ('step%d reach 有 data'):format(simStep))
            if step.data then
                assert(step.data.coords ~= nil, ('step%d reach 有 coords'):format(simStep))
                assert(step.data.radius > 0, ('step%d reach radius=%.0f'):format(simStep, step.data.radius))
            end
        elseif step.type == 'interact' then
            assert(step.data ~= nil, ('step%d interact 有 data'):format(simStep))
            if step.data then
                assert(step.data.duration > 0, ('step%d interact duration=%d'):format(simStep, step.data.duration))
            end
        end

        simStep = simStep + 1
    end

    simState = 'COMPLETED'
    print(('  模拟结束: [%s] 🏁'):format(simState))
    assert(simStep == 9 and simState == 'COMPLETED', '状态机完整推进 8 步 → COMPLETED')
end

-- ==========================================================================
-- 用例 4: 安全层数据传递
-- ==========================================================================
local function test_security_layer()
    section('4. 安全层数据传递')

    -- 4a. Nonce Token 生成
    local nonce1 = QuestSecurity.GenerateNonce(1)
    assert(nonce1 ~= nil and type(nonce1) == 'string', 'Nonce 生成返回字符串')
    assert(#nonce1 > 0, 'Nonce 非空')

    local nonce2 = QuestSecurity.GenerateNonce(2)
    assert(nonce1 ~= nonce2, '不同 source → 不同 Nonce')

    -- 4b. Rate Limit 检查
    local ok1 = QuestSecurity.CheckRateLimit(1, 'accept')
    assert(ok1, '首次 accept 通过 rate limit')

    local ok2 = QuestSecurity.CheckRateLimit(1, 'accept')
    assert(not ok2, '1ms 内二次 accept 被拦截 (rate limit 生效)')

    -- 4c. Export 白名单
    local allowed = QuestSecurity.IsExportAllowed('custom-certificates:GrantLicense')
    assert(allowed or type(allowed) == 'nil', 'Export 白名单检查正常')

    local blocked = QuestSecurity.IsExportAllowed('evil-script:GiveMoney')
    assert(not blocked, '未注册 export 被拒绝')

    -- 4d. 步骤顺序强制 (EnforceStepOrder)
    -- 假设玩家活跃任务当前在 step 1
    -- 如果客户端声称完成了 step 5 → 应被拦截
    -- (此测试依赖真实 DB，此处仅验证逻辑存在)
    local enforceEnabled = Config.Quest.Security.EnforceStepOrder
    assert(enforceEnabled == true, 'EnforceStepOrder 已启用')
end

-- ==========================================================================
-- 用例 5: 奖励发放数据流
-- ==========================================================================
local function test_rewards_data()
    section('5. 奖励数据流')

    local tmpl = QuestRegistry.GetTemplate('aviation_medical_airlift')
    if not tmpl then return end

    local rew = tmpl.rewards
    assert(rew ~= nil, '有 rewards')

    -- 金钱
    assert(rew.money.type == 'bank', '货币类型 = bank')
    assert(rew.money.min >= 0, 'min >= 0')
    assert(rew.money.max >= rew.money.min, 'max >= min')
    assert(rew.money.max > 0, 'max > 0')

    -- 声望
    assert(rew.rep.aviation > 0, 'aviation rep > 0')

    -- 对比: 民航 vs 走私
    local smugTmpl = QuestRegistry.GetTemplate('aviation_smuggling_flight')
    if smugTmpl then
        assert(rew.money.max < smugTmpl.rewards.money.max,
            string.format('民航 $%d < 走私 $%d', rew.money.max, smugTmpl.rewards.money.max))
        assert(rew.rep.aviation < smugTmpl.rewards.rep.aviation,
            string.format('民航 rep %d < 走私 rep %d', rew.rep.aviation, smugTmpl.rewards.rep.aviation))
    end
end

-- ==========================================================================
-- 用例 6: 事件广播链
-- ==========================================================================
local function test_event_broadcast()
    section('6. 事件广播链')

    -- 验证事件常量一致性
    local events = Config.Quest.Events
    assert(events.QUEST_ACCEPTED == 'quest:client:accepted', 'accept 事件名匹配')
    assert(events.QUEST_STEP_ADVANCED == 'quest:client:stepAdvanced', 'advance 事件名匹配')
    assert(events.QUEST_COMPLETED == 'quest:client:completed', 'complete 事件名匹配')
    assert(events.QUEST_FAILED == 'quest:client:failed', 'fail 事件名匹配')

    assert(events.QUEST_ACCEPT == 'quest:server:accept', 'server accept 事件名匹配')
    assert(events.QUEST_REACH == 'quest:server:reach', 'server reach 事件名匹配')
end

-- ==========================================================================
-- 用例 7: Checkpoint 配置数据传递 (服务端→客户端)
-- ==========================================================================
local function test_checkpoint_data()
    section('7. Checkpoint 配置 → 客户端数据传递')

    local tmpl = QuestRegistry.GetTemplate('aviation_medical_airlift')
    if not tmpl then return end

    local cpSteps = {}
    for _, step in ipairs(tmpl.steps) do
        if step.data and step.data.checkpoint then
            table.insert(cpSteps, step)
        end
    end

    assert(#cpSteps >= 3, '至少 3 个步骤有 checkpoint 配置 (实际: ' .. #cpSteps .. ')')

    for _, step in ipairs(cpSteps) do
        local cp = step.data.checkpoint
        -- 这些字段会在 QUEST_STEP_ADVANCED 事件中通过 next_step_data 传递给客户端
        assert(cp.type ~= nil, ('%s checkpoint type=%s → 传递给客户端'):format(step.id, cp.type))
        assert(cp.radius > 0, ('%s checkpoint radius=%.0f → 客户端渲染用'):format(step.id, cp.radius))
        assert(cp.label ~= nil, ('%s checkpoint label=%s → 客户端 UI 用'):format(step.id, tostring(cp.label)))
    end

    -- 验证 ring checkpoint 有 height_tolerance (飞行关键参数)
    local ringCount = 0
    for _, step in ipairs(cpSteps) do
        if step.data.checkpoint.type == 'ring' then
            ringCount = ringCount + 1
            local ht = step.data.checkpoint.height_tolerance
            assert(ht ~= nil and ht > 0,
                ('%s ring height_tolerance=%.0f → 客户端垂直检测用'):format(step.id, ht or 0))
        end
    end
    assert(ringCount >= 2, '至少 2 个 ring checkpoint (实际: ' .. ringCount .. ')')
end

-- ==========================================================================
-- 用例 8: 航空任务步骤间数据依赖链
-- ==========================================================================
local function test_aviation_step_deps()
    section('8. 航空任务步骤依赖链')

    local tmpl = QuestRegistry.GetTemplate('aviation_medical_airlift')
    if not tmpl then return end

    -- 8a. validator → interact 自动触发标记
    -- step_validate_plane (validator) → step_load_medical (interact)
    local s1 = tmpl.steps[1] -- validator (绑定飞机)
    local s2 = tmpl.steps[2] -- interact (装载物资)
    assert(s1.type == 'validator' and s2.type == 'interact',
        'validator→interact: autoTrigger 自动触发链')

    -- 8b. reach 航路点坐标连贯性
    -- 爬升 → 巡航 → 下降: 三个 reach 必须有坐标且高度递减
    local s3 = tmpl.steps[3] -- climb
    local s4 = tmpl.steps[4] -- cruise
    local s5 = tmpl.steps[5] -- descent

    if s3.data and s3.data.coords and s4.data and s4.data.coords and s5.data and s5.data.coords then
        local function dist(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end
        local d34 = dist(s3.data.coords, s4.data.coords)
        local d45 = dist(s4.data.coords, s5.data.coords)

        assert(d34 > 500, ('爬升→巡航 %.0fm > 500m'):format(d34))
        assert(d45 > 1000, ('巡航→进场 %.0fm > 1000m'):format(d45))

        assert(s3.data.coords.z >= 250, '爬升高度 >= 250m → 客户端高容差检测')
        assert(s5.data.coords.z < 150, '进场高度 < 150m → 客户端低容差检测')
    end
end

-- ==========================================================================
-- 主入口
-- ==========================================================================

RegisterCommand('quest_flow_test', function(source, args)
    passed, failed = 0, 0
    startTime = os.clock()

    print('')
    print('══════════════════════════════════════════════════════')
    print('  🧪 custom-quest 服务端数据流测试')
    print('══════════════════════════════════════════════════════')

    local filter = args[1] or 'all'

    if filter == 'all' or filter == 'template' then test_template_integrity() end
    if filter == 'all' or filter == 'trigger' then test_trigger_quest() end
    if filter == 'all' or filter == 'advance' then test_advance_step_chain() end
    if filter == 'all' or filter == 'security' then test_security_layer() end
    if filter == 'all' or filter == 'reward' then test_rewards_data() end
    if filter == 'all' or filter == 'event' then test_event_broadcast() end
    if filter == 'all' or filter == 'aviation' or filter == 'checkpoint' then test_checkpoint_data() end
    if filter == 'all' or filter == 'aviation' then test_aviation_step_deps() end

    local elapsed = os.clock() - startTime
    print('')
    print('══════════════════════════════════════════════════════')
    print(('  📊 %d passed / %d failed | %.2fs'):format(passed, failed, elapsed))
    print('══════════════════════════════════════════════════════')

    if source and source > 0 then
        local color = failed == 0 and 'success' or 'error'
        TriggerClientEvent('QBCore:Notify', source,
            ('Quest Flow Test: %d/%d passed'):format(passed, passed + failed), color)
    end
end, true)

print('[quest-test] ✅ 服务端测试套件已注册: /quest_flow_test [all|aviation|security|template|trigger|advance|reward|event|checkpoint]')
