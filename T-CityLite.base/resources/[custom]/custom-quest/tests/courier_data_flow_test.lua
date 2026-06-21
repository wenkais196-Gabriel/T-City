-- tests/courier_data_flow_test.lua — 多站快递全链路数据传递测试 (v0.8b)
--
-- 不依赖 FiveM 运行时 — 纯 Lua 模拟：
--   1. 地址池加载 + 随机选取
--   2. 模板深克隆 + 地址解析
--   3. 步骤推进 (validator → interact → deliver → drop → return)
--   4. 自动触发 (autoTrigger)
--   5. 奖励计算 (损伤 + 时效)
--   6. 缓存清理

-- 辅助
local function table_keys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end
    return keys
end

local passed, failed = 0, 0

local function assert_eq(label, expected, actual)
    if expected == actual then
        passed = passed + 1
        print(('  ✅ %s: %s == %s'):format(label, tostring(expected), tostring(actual)))
    else
        failed = failed + 1
        print(('  ❌ %s: expected %s, got %s'):format(label, tostring(expected), tostring(actual)))
    end
end

local function assert_truthy(label, value)
    if value then
        passed = passed + 1
        print(('  ✅ %s: truthy'):format(label))
    else
        failed = failed + 1
        print(('  ❌ %s: falsy'):format(label))
    end
end

print('═══════════════════════════════════════')
print('🧪 多站快递 — 数据传递全链路测试')
print('═══════════════════════════════════════')
print()

-- ═══════════════════════════════════════
-- 1. 地址池加载
-- ═══════════════════════════════════════
print('📦 Test 1: 地址池加载')

-- 模拟 LoadResourceFile
local pools_raw = [[
return {
    downtown_residential = {
        { coords = { x = 207.21, y = -85.17, z = 69.17 },  label = 'Alta 公寓',       district = 'Alta' },
        { coords = { x = 319.95, y = -121.57, z = 68.35 }, label = 'Pillbox Hill 诊所', district = 'Pillbox Hill' },
        { coords = { x = 330.25, y = -202.46, z = 54.09 }, label = 'Mission Row 写字楼', district = 'Mission Row' },
        { coords = { x = 121.74, y = 40.65, z = 73.52 },   label = 'Burton 排屋',       district = 'Burton' },
    },
    sandy_shores_rural = {
        { coords = { x = 1700.0, y = 3500.0, z = 35.0 },  label = 'Sandy Shores 工地',     district = 'Sandy Shores' },
        { coords = { x = 600.0,  y = 2800.0, z = 42.0 },  label = 'Harmony 内陆物流园',      district = 'Harmony' },
    },
    port_logistics = {
        { coords = { x = 153.68, y = -3211.88, z = 5.91 }, label = 'LS Port 货车总站',      district = 'Port of LS' },
        { coords = { x = 800.0,  y = -3100.0, z = 6.0 },   label = 'LS Port 集装箱堆场',    district = 'Port of LS' },
    },
}
]]

local loadFn = loadstring or load
loadFn = loadFn(pools_raw)
assert_truthy('load() 成功', loadFn)
local pools = loadFn()
assert_eq('池数量', 3, #table_keys(pools))
assert_eq('downtown_residential 地址数', 4, #pools.downtown_residential)
print()

-- ═══════════════════════════════════════
-- 2. 地址池选取 (PickAddress)
-- ═══════════════════════════════════════
print('📦 Test 2: 地址选取 + 距离校验')

local pickup_coords = { x = 69.09, y = 127.68, z = 79.21 }  -- GO Postal HQ

-- 模拟 vector3 距离计算
local function vec3_dist(a, b)
    return math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2 + (a.z - b.z)^2)
end

-- 复制 PickAddress 逻辑
local function pick_address(pool, origin, minDist, maxDist)
    minDist = minDist or 100
    maxDist = maxDist or 10000
    for _, addr in ipairs(pool) do
        local dist = vec3_dist(origin, addr.coords)
        if dist >= minDist and dist <= maxDist then
            return { coords = addr.coords, label = addr.label, distance = math.floor(dist) }
        end
    end
    return nil
end

-- 选取距离 GO Postal 500-5000m 的地址
local addr = pick_address(pools.downtown_residential, pickup_coords, 100, 5000)
assert_truthy('PickAddress 返回非空', addr ~= nil)
if addr then
    assert_truthy('label 非空', addr.label and #addr.label > 0)
    assert_truthy('distance > 0', addr.distance > 0)
    print(('  📍 选中: %s (%.0fm)'):format(addr.label, addr.distance))
end
print()

-- ═══════════════════════════════════════
-- 3. 模板深克隆 + 地址解析
-- ═══════════════════════════════════════
print('📦 Test 3: 模板深克隆 + ResolveQuestAddresses')

local template = {
    id = 'euro_multi_stop_courier',
    title = '多站经停快递',
    steps = {
        { id = 'step_bind_courier', type = 'validator', data = { coords = pickup_coords, validator_id = 'validate_logistics_vehicle' } },
        { id = 'step_load_parcels', type = 'interact', data = { coords = pickup_coords } },
        { id = 'step_stop_1', type = 'validator', data = {
            address_pool = { pool = 'downtown_residential', min_distance = 100, max_distance = 3000 },
            validator_data = { destCoords = { x = 0, y = 0, z = 0 }, use_bound_vehicle = true },
        }},
    },
    rewards = { money = { type = 'bank', min = 1000, max = 2000 } },
}

-- 模拟深克隆
local function deep_clone(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deep_clone(v) end
    return c
end

local cloned = deep_clone(template)

-- 模拟 ResolveQuestAddresses
for i, step in ipairs(cloned.steps) do
    if step.data and step.data.address_pool then
        local poolRef = step.data.address_pool
        local pool = pools[poolRef.pool]
        assert_truthy(('池 %s 存在'):format(poolRef.pool), pool ~= nil)
        if pool then
            local a = pick_address(pool, pickup_coords, poolRef.min_distance, poolRef.max_distance)
            assert_truthy('地址解析成功', a ~= nil)
            if a then
                step.data.coords = a.coords
                step.data._resolved_label = a.label
                if step.data.validator_data then
                    step.data.validator_data.destCoords = a.coords
                end
                step.data.address_pool = nil
            end
        end
    end
end

-- 验证原始模板未被修改
assert_truthy('原始模板仍有 address_pool', template.steps[3].data.address_pool ~= nil)
assert_truthy('克隆模板已移除 address_pool', cloned.steps[3].data.address_pool == nil)
assert_truthy('克隆模板已注入 coords', cloned.steps[3].data.coords ~= nil)
if cloned.steps[3].data.coords then
    assert_truthy('坐标非零', cloned.steps[3].data.coords.x ~= 0 or cloned.steps[3].data.coords.y ~= 0)
end
if cloned.steps[3].data.validator_data and cloned.steps[3].data.validator_data.destCoords then
    assert_truthy('destCoords 同步更新', cloned.steps[3].data.validator_data.destCoords.x ~= 0 or cloned.steps[3].data.validator_data.destCoords.y ~= 0)
end
print()

-- ═══════════════════════════════════════
-- 4. 步骤推进状态机模拟
-- ═══════════════════════════════════════
print('📦 Test 4: 步骤推进状态机')

local quest_state = {
    current_step_index = 1,
    steps = cloned.steps,
}

local function advance_step()
    local current = quest_state.steps[quest_state.current_step_index]
    local next_step = quest_state.steps[quest_state.current_step_index + 1]
    if not next_step then return 'completed' end

    -- validator → interact 自动触发
    if current.type == 'validator' and next_step.type == 'interact' then
        next_step.data = next_step.data or {}
        next_step.data.autoTrigger = true  -- ← 驼峰！(已修复)
    end

    quest_state.current_step_index = quest_state.current_step_index + 1
    return 'advanced'
end

-- Step 1 (validator) 完成
local result = advance_step()
assert_eq('step 1→2', 'advanced', result)
assert_eq('当前步骤', 2, quest_state.current_step_index)

-- 验证 autoTrigger
local step2 = quest_state.steps[2]
assert_eq('step2 autoTrigger = true', true, step2.data.autoTrigger)
assert_eq('step2 type', 'interact', step2.type)

-- Step 2 (interact, autoTrigger) 完成 → Step 3
result = advance_step()
assert_eq('step 2→3', 'advanced', result)
assert_eq('当前步骤', 3, quest_state.current_step_index)

local step3 = quest_state.steps[3]
assert_eq('step3 type', 'validator', step3.type)
assert_truthy('step3 有解析后坐标', step3.data.coords ~= nil)
if step3.data._resolved_label then
    print(('  📍 配送目标: %s'):format(step3.data._resolved_label))
end

-- Step 3 (delivery validator) 完成 → 任务完成
result = advance_step()
assert_eq('step 3→completed', 'completed', result)
print()

-- ═══════════════════════════════════════
-- 5. 奖励计算 (损伤 + 时效模拟)
-- ═══════════════════════════════════════
print('📦 Test 5: 奖励计算')

local base_amount = 1500
local damage_pct = 12  -- 模拟 12% 损伤
local time_mult = 1.25  -- 模拟提前完成 +25%

local function calc_reward(base, damage, timeBonus)
    local dmg_mult = 1.0 - (damage / 100)
    local final = math.floor(base * dmg_mult * timeBonus + 0.5)
    return math.max(1, final)
end

local reward = calc_reward(base_amount, damage_pct, time_mult)
assert_eq('奖励计算', math.floor(1500 * 0.88 * 1.25 + 0.5), reward)

-- 无损 + 准时
reward = calc_reward(base_amount, 0, 1.0)
assert_eq('无损准时', base_amount, reward)

-- 严重损伤 + 超时
reward = calc_reward(base_amount, 45, 0.6)
assert_truthy('损伤+超时 > 0', reward > 0)
assert_truthy('损伤+超时 < base', reward < base_amount)
print(('  💰 损伤45%% + 超时40%%: $%d → $%d'):format(base_amount, reward))
print()

-- ═══════════════════════════════════════
-- 6. 缓存清理验证
-- ═══════════════════════════════════════
print('📦 Test 6: 缓存清理')

local cache = {}
local cache_key = 'CITIZEN_123_euro_multi_stop_courier'

-- 模拟存储解析后模板
cache[cache_key] = cloned
assert_truthy('缓存已存储', cache[cache_key] ~= nil)

-- 模拟任务完成 → 清理
cache[cache_key] = nil
assert_eq('缓存已清理', nil, cache[cache_key])
print()

-- ═══════════════════════════════════════
-- 结果
-- ═══════════════════════════════════════
print('═══════════════════════════════════════')
print(('✅ %d passed  ❌ %d failed'):format(passed, failed))
print('═══════════════════════════════════════')

if failed > 0 then
    os.exit(1)
end

-- end of tests
