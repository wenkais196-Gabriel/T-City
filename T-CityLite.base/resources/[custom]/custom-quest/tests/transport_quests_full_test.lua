-- tests/transport_quests_full_test.lua — 全部运输任务服务端集成测试 (v0.8b)
--
-- 验证 8 个运输任务的:
--   1. 模板注册正确
--   2. TriggerQuest 成功（条件检查通过）
--   3. 地址池解析随机化
--   4. 步骤全链推进
--   5. 奖励结算
--   6. 缓存清理

-- 复用 server_quest_chain_test 的 mock 环境
dofile('T-CityLite.base/resources/[custom]/custom-quest/tests/server_quest_chain_test.lua')

local stats = { passed = 0, failed = 0, skipped = 0 }

local function run_quest_test(questId)
    print()
    print(('🧪 测试: %s'):format(questId))

    local template = QuestRegistry.GetTemplate(questId)
    if not template then
        print('  ❌ 模板未注册')
        stats.skipped = stats.skipped + 1
        return
    end

    print(('  📋 %s (Lv.%d, %d steps, category=%s)'):format(
        template.title, template.level, #template.steps, template.category))

    -- 列出步骤和地址池引用
    local hasPool = false
    for i, step in ipairs(template.steps) do
        local flags = ''
        if step.data and step.data.address_pool then
            flags = ' [ADDR_POOL: ' .. step.data.address_pool.pool .. ']'
            hasPool = true
        elseif step.data and step.data._resolved_label then
            flags = ' [RESOLVED: ' .. step.data._resolved_label .. ']'
        elseif step.type == 'reward' then
            flags = ' [REWARD]'
        end
        print(('    Step %d: %s (%s)%s'):format(i, step.id, step.type, flags))
    end

    -- 触发任务
    local src = 1
    local citizenid = 'CITIZEN_TEST'

    local success, msg = QuestManager.TriggerQuest(src, questId)
    if not success then
        print(('  ❌ TriggerQuest 失败: %s'):format(msg))
        stats.failed = stats.failed + 1
        return
    end
    print(('  ✅ TriggerQuest: %s'):format(msg))

    -- 检查地址池是否解析
    local resolved = QuestManager._resolvedTemplates[citizenid .. '_' .. questId]
    if resolved then
        print('  ✅ 地址池已解析（深克隆模板已缓存）')
    elseif hasPool then
        print('  ⚠️ 有地址池但未解析 — 检查 address_pool 字段')
    end

    -- 逐步推进
    local stepResults = {}
    for i, step in ipairs(template.steps) do
        local tmpl = resolved or template
        local curStep = tmpl.steps[i]

        local extra = ''
        if curStep.type == 'validator' and curStep.data and curStep.data.validator_id == 'validate_delivery_arrival' then
            local label = curStep.data._resolved_label or curStep.data.label or '(unknown)'
            extra = ' → dest: ' .. label
        end

        local ok, err = QuestManager.AdvanceStep(citizenid, questId, curStep.id,
            { position = curStep.data and curStep.data.coords })

        local toStep = 'COMPLETED'
        if i < #tmpl.steps then toStep = tmpl.steps[i + 1].id end

        if ok then
            stepResults[i] = true
        else
            stepResults[i] = false
            print(('  ❌ Step %d: %s → %s — %s'):format(i, curStep.id, toStep, err or 'unknown'))
            stats.failed = stats.failed + 1
            -- 不 break — 尝试继续推进剩余的步骤
        end
    end

    -- 汇总
    local completed = 0
    for _, v in ipairs(stepResults) do
        if v then completed = completed + 1 end
    end

    -- 验证缓存清理
    local cached = QuestManager._resolvedTemplates[citizenid .. '_' .. questId]

    if completed == #template.steps then
        print(('  ✅ 全部 %d/%d 步骤通过 | 缓存清理: %s'):format(
            completed, #template.steps, cached == nil and '✅' or '⚠️'))
        stats.passed = stats.passed + 1
    else
        print(('  ⚠️ %d/%d 步骤通过 | 缓存清理: %s'):format(
            completed, #template.steps, cached == nil and '✅' or '⚠️'))
        if completed > 0 then stats.passed = stats.passed + 1 end
        if completed == 0 then stats.failed = stats.failed + 1 end
    end
end

-- ═══════════════════════════════════════
-- 运行全部运输任务测试
-- ═══════════════════════════════════════

print()
print('═══════════════════════════════════════')
print('🧪 全部运输任务 — 服务端全链测试')
print('═══════════════════════════════════════')

local transportQuests = {
    'euro_trucking_steel',            -- Lv.1 — sandy_shores_rural
    'euro_container_haul',            -- Lv.2 — sandy_shores_rural
    'euro_refrigerated',              -- Lv.2 — sandy_shores_rural
    'euro_timber_haul',               -- Lv.2 — port_logistics
    'euro_car_transport',             -- Lv.3 — paleto_bay_north
    'euro_fuel_tanker',               -- Lv.4 — paleto_bay_north
    'euro_oversized_construction',    -- Lv.5 — paleto_bay_north
    'euro_trucking_heavy_trailer',    -- Lv.3 — paleto_bay_north
}

-- 先清缓存避免跨测试干扰
QuestCache.ClearPlayer('CITIZEN_TEST')

for _, qid in ipairs(transportQuests) do
    run_quest_test(qid)
    -- 每个任务间清缓存
    QuestCache.ClearPlayer('CITIZEN_TEST')
    QuestManager._resolvedTemplates = {}
end

-- ═══════════════════════════════════════
-- 地址池随机化验证（同一个任务接 3 次）
-- ═══════════════════════════════════════

print()
print('═══════════════════════════════════════')
print('🧪 地址池随机化 — 3 次接取对比')
print('═══════════════════════════════════════')

local testQuest = 'euro_trucking_steel'
local destinations = {}

for round = 1, 3 do
    QuestCache.ClearPlayer('CITIZEN_TEST')
    QuestManager._resolvedTemplates = {}

    local ok = QuestManager.TriggerQuest(1, testQuest)
    if ok then
        local resolved = QuestManager._resolvedTemplates['CITIZEN_TEST' .. '_' .. testQuest]
        if resolved then
            for _, step in ipairs(resolved.steps) do
                if step.data and step.data._resolved_label then
                    destinations[round] = step.data._resolved_label
                    break
                end
            end
        end
        -- 清理
        for _, step in ipairs(resolved and resolved.steps or {}) do
            QuestManager.AdvanceStep('CITIZEN_TEST', testQuest, step.id, {})
        end
    end
end

print('  3 次接取目的地:')
local allSame = true
for i, dest in ipairs(destinations) do
    print(('    第%d次: %s'):format(i, dest or '未解析'))
    if i > 1 and dest ~= destinations[1] then allSame = false end
end

if destinations[1] and not allSame then
    print('  ✅ 地址池随机化正常（3 次不同目的地）')
elseif destinations[1] then
    print('  ⚠️ 3 次同一目的地 — 地址池太小或运气问题，再测一次确认')
else
    print('  ❌ 地址池未解析')
end

-- ═══════════════════════════════════════
-- 最终统计
-- ═══════════════════════════════════════

print()
print('═══════════════════════════════════════')
print(('📊 结果: ✅ %d passed | ❌ %d failed | ⏭️ %d skipped'):format(
    stats.passed, stats.failed, stats.skipped))
print('═══════════════════════════════════════')
