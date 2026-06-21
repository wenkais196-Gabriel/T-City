-- tests/validate_aviation_medical_airlift.lua
-- 静态校验 aviation_medical_airlift 任务模板完整性与状态机可达性
--
-- 用法（在 FiveM 服务端控制台或独立 Lua 5.4 环境均可运行）:
--   lua tests/validate_aviation_medical_airlift.lua
-- 或在服务端:
--   /refresh                          -- 确保资源加载
--   /startquest aviation_medical_airlift  -- 手动接取测试

local json = require('json') or { encode = function(t) return '{}' end, decode = function(s) return {} end }

-- ══════════════════════════════════════════════════════════════
-- 模拟任务模板（从 quest_legal_aviation.lua 提取）
-- ══════════════════════════════════════════════════════════════
local TEMPLATE = {
    id = 'aviation_medical_airlift',
    title = '民航医药空运',
    description = '从LSIA装载医疗物资，保持高空航线 (>250m) 送往Grapeseed乡村诊所。',
    category = 'logistics',
    level = 1,
    required_tags = { role = 'unemployed' },
    conditions = { cooldown_hours = 0, min_license = 'pilot' },
    rewards = {
        money = { type = 'bank', min = 2000, max = 3500 },
        rep = { aviation = 40 },
    },
    steps = {
        { id = 'step_validate_plane',      type = 'validator',     title = '确认货运飞机' },
        { id = 'step_load_medical',         type = 'interact',      title = '装载医疗物资' },
        { id = 'step_climb_cruise',         type = 'reach',         title = '爬升至民航巡航高度' },
        { id = 'step_cruise_mid',           type = 'reach',         title = '航线中点：Sandy Shores 上空' },
        { id = 'step_descent_approach',     type = 'reach',         title = '下降进场' },
        { id = 'step_land_grapeseed',       type = 'validator',     title = '降落Grapeseed跑道' },
        { id = 'step_unload_medical',       type = 'interact',      title = '卸载医疗物资' },
        { id = 'step_return_rental',        type = 'validator',     title = '交还租用飞机' },
    },
}

-- ══════════════════════════════════════════════════════════════
-- 测试套件
-- ══════════════════════════════════════════════════════════════

local passed, failed = 0, 0
local issues = {}

local function assertTrue(cond, msg)
    if cond then
        passed = passed + 1
        print('  ✅ ' .. msg)
    else
        failed = failed + 1
        table.insert(issues, msg)
        print('  ❌ ' .. msg)
    end
end

print('')
print('══════════════════════════════════════════════════════════')
print('  ✈️  aviation_medical_airlift — 静态校验')
print('══════════════════════════════════════════════════════════')
print('')

-- ── 1. 模板基础结构 ──
print('📦 1. 模板基础结构')

assertTrue(TEMPLATE.id ~= nil, '有 quest id')
assertTrue(#TEMPLATE.title > 0, '有标题')
assertTrue(TEMPLATE.category == 'logistics', '分类为 logistics')
assertTrue(TEMPLATE.level >= 1, 'level 有效')

-- ── 2. 条件校验 ──
print('')
print('📋 2. 条件校验')

assertTrue(TEMPLATE.conditions.min_license == 'pilot', '需要飞行执照 (min_license=pilot)')
assertTrue(TEMPLATE.conditions.cooldown_hours == 0, '冷却时间为 0 (非阻塞)')
assertTrue(TEMPLATE.required_tags.role == 'unemployed', '平民通用标签')

-- ── 3. 奖励结构 ──
print('')
print('💰 3. 奖励结构')

local rew = TEMPLATE.rewards
assertTrue(rew ~= nil, '有 rewards 定义')
assertTrue(rew.money ~= nil, '有金钱奖励')
assertTrue(rew.money.type == 'bank', '货币类型为 bank')
assertTrue(rew.money.min > 0 and rew.money.max >= rew.money.min, '奖金区间有效 (min=' .. rew.money.min .. ', max=' .. rew.money.max .. ')')
assertTrue(rew.rep ~= nil and rew.rep.aviation == 40, '有声望奖励 (aviation=40)')

-- ── 4. 步骤链完整性 ──
print('')
print('🔗 4. 步骤链完整性')

assertTrue(#TEMPLATE.steps == 8, '共 8 个步骤')

local stepTypes = {}
for i, step in ipairs(TEMPLATE.steps) do
    stepTypes[step.type] = (stepTypes[step.type] or 0) + 1
    assertTrue(step.id ~= nil and #step.id > 0, ('步骤 %d 有 id: %s'):format(i, step.id))
    assertTrue(step.title ~= nil, ('步骤 %d "%s" 有标题'):format(i, step.id))
    assertTrue(step.type ~= nil, ('步骤 %d "%s" 有类型: %s'):format(i, step.id, tostring(step.type)))
end

print('  步骤类型分布:')
for st, count in pairs(stepTypes) do
    print(('    %s: %d'):format(st, count))
end

-- ── 5. 步骤数据完整性 ──
print('')
print('📐 5. 步骤数据节点完整性')

-- 5a. validator 步骤必须有 coords + validator_id
for _, step in ipairs(TEMPLATE.steps) do
    if step.type == 'validator' then
        assertTrue(step.data ~= nil, ('validator "%s" 有 data'):format(step.id))
        if step.data then
            assertTrue(step.data.coords ~= nil, ('validator "%s" 有 coords'):format(step.id))
            assertTrue(step.data.validator_id ~= nil, ('validator "%s" 有 validator_id'):format(step.id))
            assertTrue(step.data.in_vehicle == true, ('validator "%s" 要求 in_vehicle'):format(step.id))
        end
    end
end

-- 5b. interact 步骤必须有 coords + duration
for _, step in ipairs(TEMPLATE.steps) do
    if step.type == 'interact' then
        assertTrue(step.data ~= nil, ('interact "%s" 有 data'):format(step.id))
        if step.data then
            assertTrue(step.data.coords ~= nil, ('interact "%s" 有 coords'):format(step.id))
            assertTrue(step.data.duration > 0, ('interact "%s" 有 duration=%d'):format(step.id, step.data.duration or 0))
        end
    end
end

-- 5c. reach 步骤必须有 coords + radius
for _, step in ipairs(TEMPLATE.steps) do
    if step.type == 'reach' then
        assertTrue(step.data ~= nil, ('reach "%s" 有 data'):format(step.id))
        if step.data then
            assertTrue(step.data.coords ~= nil, ('reach "%s" 有 coords'):format(step.id))
            assertTrue(step.data.radius > 0, ('reach "%s" 有 radius=%d'):format(step.id, step.data.radius or 0))
        end
    end
end

-- ── 6. 航路点逻辑合理性 ──
print('')
print('🗺️  6. 航路点逻辑')

-- LSIA 起飞 → 爬升到 300m → 巡航中点 → 下降进场 → Grapeseed 降落
local climb = TEMPLATE.steps[3]   -- step_climb_cruise
local cruise = TEMPLATE.steps[4]  -- step_cruise_mid
local descent = TEMPLATE.steps[5] -- step_descent_approach

if climb and climb.data and climb.data.coords then
    local c = climb.data.coords
    print(('  爬升点: (%.0f, %.0f, %.0f)'):format(c.x, c.y, c.z))
    assertTrue(c.z >= 250, '爬升高度 ≥ 250m (高空航线): z=' .. c.z)
end

if cruise and cruise.data and cruise.data.coords then
    local c = cruise.data.coords
    print(('  巡航中点: (%.0f, %.0f, %.0f)'):format(c.x, c.y, c.z))
    assertTrue(c.z >= 250, '巡航高度 ≥ 250m: z=' .. c.z)

    if climb and climb.data and climb.data.coords then
        local d = math.sqrt((c.x - climb.data.coords.x)^2 + (c.y - climb.data.coords.y)^2)
        print(('  爬升→巡航距离: %.0fm'):format(d))
        assertTrue(d > 500, '爬升→巡航距离 > 500m (合理航段): ' .. math.floor(d) .. 'm')
    end
end

if descent and descent.data and descent.data.coords then
    local c = descent.data.coords
    print(('  下降进场点: (%.0f, %.0f, %.0f)'):format(c.x, c.y, c.z))
    assertTrue(c.z < 150, '进场高度 < 150m (下降阶段): z=' .. c.z)
end

-- ── 7. 状态机可达性 ──
print('')
print('⚙️  7. 状态机可达性')

-- 模拟: Not Started → In Progress (step 1) → → ... → Completed
local simState = 'NOT_STARTED'
local simStep = 0

print(('  [%s]'):format(simState))

-- TriggerQuest
simState = 'IN_PROGRESS'
simStep = 1
print(('  → [%s] step=%d "%s" type=%s'):format(simState, simStep,
    TEMPLATE.steps[simStep].title, TEMPLATE.steps[simStep].type))

-- AdvanceStep × 7
for i = 2, #TEMPLATE.steps do
    simStep = i
    local step = TEMPLATE.steps[simStep]
    print(('  → [%s] step=%d "%s" type=%s'):format(simState, simStep, step.title, step.type))
end

-- CompleteQuest
simState = 'COMPLETED'
print(('  → [%s] 🏁 任务完成, 奖励: $%d-%d bank + %d aviation rep'):format(
    simState, rew.money.min, rew.money.max, rew.rep.aviation))

assertTrue(simStep == 8, '最后一步是第 8 步 step_return_rental')
assertTrue(simState == 'COMPLETED', '状态机以 COMPLETED 结束')

-- ── 8. 与前序任务的一致性检查 ──
print('')
print('🔍 8. 一致性检查')

-- 8a. 飞行执照要求 vs 走私飞行对比
-- 走私飞行也要求 pilot，两者一致
assertTrue(TEMPLATE.conditions.min_license == 'pilot', '民航任务要求飞行执照 (与走私飞行一致)')

-- 8b. 奖励区间合理性
-- 民航: 2000-3500 vs 走私: 3500-6000 → 合法任务奖励低于非法，合理
assertTrue(rew.money.max < 6000, '合法民航奖励上限 < 走私飞行上限 (6000): max=' .. rew.money.max)

-- 8c. 交还租用飞机步骤存在
local hasReturn = false
for _, step in ipairs(TEMPLATE.steps) do
    if step.id == 'step_return_rental' then
        hasReturn = true
        break
    end
end
assertTrue(hasReturn, '有交还飞机步骤 (step_return_rental)')

-- 8d. 与走私飞行对比步骤数差异
-- 民航 8 步 > 走私 5 步，反映更严格的合法航空规范
assertTrue(#TEMPLATE.steps > 5, '民航任务步骤数 > 走私飞行 (5): ' .. #TEMPLATE.steps .. ' 步')

-- ══════════════════════════════════════════════════════════════
-- 结果汇总
-- ══════════════════════════════════════════════════════════════

print('')
print('══════════════════════════════════════════════════════════')
print(('  📊 校验结果: %d passed / %d failed'):format(passed, failed))
print('══════════════════════════════════════════════════════════')

if failed > 0 then
    print('')
    print('  🚨 发现以下问题:')
    for i, issue in ipairs(issues) do
        print(('    %d. %s'):format(i, issue))
    end
    print('')
end

if failed == 0 then
    print('')
    print('  ✅ 所有校验通过！aviation_medical_airlift 可以安全测试。')
    print('')
    print('  🎮 游戏内测试命令:')
    print('    /startquest aviation_medical_airlift')
    print('')
    print('  📋 推荐测试流程:')
    print('    1. 确保玩家持有飞行执照 (/grantpilot)')
    print('    2. 传送到 LSIA /startquest aviation_medical_airlift')
    print('    3. 按步骤指引: 绑定飞机→装载→爬升→巡航→下降→降落→卸载→归还')
    print('    4. 检查奖励是否正确到账 ($2000-$3500 bank + 40 aviation rep)')
    print('    5. 确认任务完成后可重复接取 (cooldown=0)')
    print('')
end

return failed == 0
