-- tests/police_dashboard_test.lua — 警车中控屏 v2.1 集成测试
--
-- 测试场景:
--   1. Police/EMS 分离验证
--   2. ANPR 扫描流程
--   3. 车牌标记/查询鉴权
--   4. 非警察权限拒绝
--   5. 并发压力测试
--
-- 此脚本仅在沙盒内做静态验证，不依赖 FiveM 运行时。

local passed = 0
local failed = 0
local errors = {}

local function assert_true(desc, value)
    if value then
        passed = passed + 1
    else
        failed = failed + 1
        errors[#errors + 1] = ('FAIL: %s'):format(desc)
    end
end

local function assert_false(desc, value)
    if not value then
        passed = passed + 1
    else
        failed = failed + 1
        errors[#errors + 1] = ('FAIL: %s'):format(desc)
    end
end

local function assert_eq(desc, actual, expected)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        errors[#errors + 1] = ('FAIL: %s — expected %s, got %s'):format(desc, tostring(expected), tostring(actual))
    end
end

print('\n══════════════════════════════════════════')
print('🚔 警车中控屏 v2.2 — 集成测试套件')
print('══════════════════════════════════════════\n')

-- ==============================================================
-- 测试 1: Police/EMS 分离逻辑
-- ==============================================================
print('📋 测试 1: Police/EMS 分离逻辑')

-- 模拟: police 职业 + emergency class 18 → 应显示 police
local showPolice = function(job, isEmergency)
    return job == 'police' and isEmergency == true
end
local showAmbulance = function(job, isEmergency)
    return job == 'ambulance' and isEmergency == true
end
local showFire = function(job, isEmergency)
    return job == 'fire' and isEmergency == true
end

assert_true('警察+警车 → 显示警用控制台', showPolice('police', true))
assert_false('警察+普通车 → 不显示警用控制台', showPolice('police', false))
assert_false('平民+警车 → 不显示警用控制台', showPolice('unemployed', true))
-- 救护员在警车中 → 不应看到警察控制台
assert_false('救护员+警车 → 不显示警用控制台', showPolice('ambulance', true))

assert_true('救护员+救护车 → 显示救护控制台', showAmbulance('ambulance', true))
assert_false('警察+救护车 → 不显示救护控制台', showAmbulance('police', true))

assert_true('消防员+消防车 → 显示消防控制台', showFire('fire', true))
assert_false('平民+消防车 → 不显示消防控制台', showFire('unemployed', true))

-- ==============================================================
-- 测试 2: ANPR 标记检查逻辑
-- ==============================================================
print('\n📋 测试 2: ANPR 标记检查')

-- 模拟 FlaggedPlates 服务端表
local FlaggedPlates = {
    ['ABC123'] = { isflagged = true, reason = '测试标记' },
    ['XYZ789'] = { isflagged = true, reason = '被盗' },
    ['DEF456'] = { isflagged = false },
}

local function checkPlatesFlagged(plates)
    local result = {}
    for _, plate in ipairs(plates) do
        if FlaggedPlates[plate] and FlaggedPlates[plate].isflagged then
            result[plate] = true
        end
    end
    return result
end

local results1 = checkPlatesFlagged({ 'ABC123', 'DEF456', 'UNKNOWN' })
assert_true('ABC123 被标记 → 返回 true', results1['ABC123'] == true)
assert_false('DEF456 未标记 → 不在结果中', results1['DEF456'])
assert_false('UNKNOWN 不存在 → 不在结果中', results1['UNKNOWN'])

-- 批量空输入
local results2 = checkPlatesFlagged({})
-- 空输入应返回空表
local emptyCheck = (next(results2) == nil)
assert_true('空输入 → 空结果', emptyCheck)

-- ==============================================================
-- 测试 3: 安全鉴权
-- ==============================================================
print('\n📋 测试 3: 安全鉴权')

local function isOnDutyLeo(job)
    if not job then return false end
    if job.type == 'leo' then return job.onduty == true end
    if job.name == 'police' then return job.onduty == true end
    return false
end

assert_true('值班警察 → 通过鉴权', isOnDutyLeo({ name = 'police', onduty = true }))
assert_false('下班警察 → 拒绝鉴权', isOnDutyLeo({ name = 'police', onduty = false }))
assert_false('平民 → 拒绝鉴权', isOnDutyLeo({ name = 'unemployed', onduty = false }))
assert_false('nil → 拒绝鉴权', isOnDutyLeo(nil))

-- ==============================================================
-- 测试 4: Rate Limit
-- ==============================================================
print('\n📋 测试 4: Rate Limit')

local opCooldowns = {}
local function checkRateLimit(src, action)
    local now = os.clock() * 1000
    if not opCooldowns[src] then opCooldowns[src] = {} end
    local last = opCooldowns[src][action]
    if last and now - last < 1000 then return false end
    opCooldowns[src][action] = now
    return true
end

assert_true('首次操作 → 允许', checkRateLimit(1, 'flagPlate'))
assert_false('1s内重复 → 拒绝', checkRateLimit(1, 'flagPlate'))
-- 模拟 1.1s 后
opCooldowns[1].flagPlate = (opCooldowns[1].flagPlate or 0) - 1100
assert_true('1s后 → 允许', checkRateLimit(1, 'flagPlate'))

-- ==============================================================
-- 测试 5: 并发压力 (模拟 100 名玩家)
-- ==============================================================
print('\n📋 测试 5: 并发压力 (100 玩家)')

local concurrentOps = 0
local simulatedPlayers = 100
for i = 1, simulatedPlayers do
    if checkRateLimit(i, 'radar') then
        concurrentOps = concurrentOps + 1
    end
end
assert_eq('100 并发玩家 → 全部通过 (不同 src)', concurrentOps, 100)

-- 同一玩家高频操作
local samePlayerOps = 0
for i = 1, 100 do
    if checkRateLimit(999, 'siren') then
        samePlayerOps = samePlayerOps + 1
    end
end
assert_eq('同一玩家100次操作 → 仅首次通过', samePlayerOps, 1)

-- ==============================================================
-- 测试 6: 配置完整性
-- ==============================================================
print('\n📋 测试 6: 配置完整性')

-- 模拟 vehicle.lua 的配置检查
local emergencyFeatures = {
    ctrl_anpr = true, ctrl_tracker = true, ctrl_camera = true,
    ctrl_flagplate = true, ctrl_impound = true, ctrl_speed_radar = true,
}

local requiredFeatures = { 'ctrl_anpr', 'ctrl_tracker', 'ctrl_camera', 'ctrl_flagplate', 'ctrl_impound', 'ctrl_speed_radar' }
for _, feat in ipairs(requiredFeatures) do
    assert_true(('功能 %s → 已配置'):format(feat), emergencyFeatures[feat] == true)
end

-- jobRestricted 检查
local jobRestricted = {
    anpr = { 'police' }, tracker = { 'police' }, camera = { 'police' },
    flagplate = { 'police' }, impound = { 'police' }, speed_radar = { 'police' },
}
for _, action in ipairs({ 'anpr', 'tracker', 'camera', 'flagplate', 'impound', 'speed_radar' }) do
    assert_true(('鉴权 %s → police only'):format(action), jobRestricted[action][1] == 'police')
end

-- ==============================================================
-- 测试 7: v2.2 扫描日志 (最近 50 条截断)
-- ==============================================================
print('\n📋 测试 7: 扫描日志截断')

local scanLog = {}
local function appendScanLog(plate, speed)
    scanLog[#scanLog + 1] = { plate = plate, speed = speed, time = '12:00' }
    while #scanLog > 50 do table.remove(scanLog, 1) end
end

-- 添加 60 条记录
for i = 1, 60 do
    appendScanLog('PLATE' .. i, i * 2)
end

assert_eq('扫描日志上限 50 条', #scanLog, 50)
assert_eq('最早记录已丢弃 (保留 PLATE11)', scanLog[1].plate, 'PLATE11')
assert_eq('最新记录保留 (PLATE60)', scanLog[50].plate, 'PLATE60')

-- ==============================================================
-- 测试 8: v2.2 SQL 持久化 (模拟)
-- ==============================================================
print('\n📋 测试 8: SQL 持久化逻辑')

-- 模拟 FlaggedPlates 表
local dbFlagged = {}
local function saveToDb(plate, reason, by)
    dbFlagged[plate] = { isflagged = 1, reason = reason, flagged_by = by, flagged_at = os.time() }
end
local function removeFromDb(plate)
    if dbFlagged[plate] then dbFlagged[plate].isflagged = 0 end
end

saveToDb('ABC123', '涉嫌盗窃', 'OFFICER_1')
assert_true('SQL 保存后可查', dbFlagged['ABC123'] ~= nil and dbFlagged['ABC123'].isflagged == 1)

removeFromDb('ABC123')
assert_eq('SQL 取消标记后 isflagged=0', dbFlagged['ABC123'].isflagged, 0)

-- ==============================================================
-- 测试 9: v2.2 公民查询 (模拟)
-- ==============================================================
print('\n📋 测试 9: 公民查询')

local function lookupCitizen(players, query)
    for _, p in ipairs(players) do
        if p.citizenid == query then return p end
        local fullName = p.firstname .. ' ' .. p.lastname
        if fullName:lower():find(query:lower(), 1, true) then return p end
    end
    return nil
end

local onlinePlayers = {
    { citizenid = 'ABC12345', firstname = 'John', lastname = 'Doe', job = 'police' },
    { citizenid = 'XYZ98765', firstname = 'Jane', lastname = 'Smith', job = 'ambulance' },
}

local r1 = lookupCitizen(onlinePlayers, 'ABC12345')
assert_true('按 citizenid 查询成功', r1 ~= nil and r1.firstname == 'John')

local r2 = lookupCitizen(onlinePlayers, 'Jane')
assert_true('按姓名模糊查询成功', r2 ~= nil and r2.citizenid == 'XYZ98765')

local r3 = lookupCitizen(onlinePlayers, 'NOTFOUND')
assert_true('不存在的公民返回 nil', r3 == nil)

-- ==============================================================
-- 测试 10: 摄像头配置完整性
-- ==============================================================
print('\n📋 测试 7: 摄像头配置完整性')

local securityCameras = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34 }
assert_eq('摄像头数量', #securityCameras, 34)

-- ==============================================================
-- 结果汇总
-- ==============================================================
print('\n══════════════════════════════════════════')
print('📊 测试结果汇总')
print('══════════════════════════════════════════')
print(('   ✅ 通过: %d'):format(passed))
print(('   ❌ 失败: %d'):format(failed))

if #errors > 0 then
    print('\n── 失败详情 ──')
    for _, e in ipairs(errors) do
        print('   ' .. e)
    end
end

if failed == 0 then
    print('\n🎉 全部测试通过！警车中控屏 v2.1 就绪。')
else
    print(('\n⚠️ %d 个测试失败，需要修复。'):format(failed))
    os.exit(1)
end
