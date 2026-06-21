-- tests/validate_aviation_medical_airlift_v2.lua
-- 深度校验 quest_legal_aviation.lua — aviation_medical_airlift

local passed, failed = 0, 0
local issues = {}
local function assertTrue(cond, msg)
    if cond then passed = passed + 1; print('  ✅ ' .. msg)
    else failed = failed + 1; table.insert(issues, msg); print('  ❌ ' .. msg) end
end

-- ═══════════════════════════════ 加载 ══════════════════════
local configPath = 'T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_legal_aviation.lua'
local f = io.open(configPath, 'r')
if not f then print('❌ 无法读取: ' .. configPath); os.exit(1) end
local src = f:read('*all'); f:close()

-- ═══════════════════════════════ 解析 ══════════════════════
-- 步骤块 (向下扫描到匹配的 })
local function findStepBlocks(text)
    local blocks, pos = {}, 1
    while true do
        local sid = text:find("id%s*=%s*'step_", pos)
        if not sid then break end
        -- 回退找 opening {
        local depth, blockStart = 0, sid
        for i = sid, 1, -1 do
            local c = text:sub(i,i)
            if c == '}' then depth = depth + 1
            elseif c == '{' then
                if depth == 0 then blockStart = i; break end
                depth = depth - 1
            end
        end
        -- 前进找 matching }
        depth = 0; local blockEnd = blockStart
        for i = blockStart, #text do
            local c = text:sub(i,i)
            if c == '{' then depth = depth + 1
            elseif c == '}' then depth = depth - 1; if depth == 0 then blockEnd = i; break end end
        end
        local block = text:sub(blockStart, blockEnd)
        local stepId = block:match("id%s*=%s*'([^']+)'")
        local stepType = block:match("type%s*=%s*'([^']+)'")
        local stepTitle = block:match("title%s*=%s*'([^']*)'")
        table.insert(blocks, { id=stepId, type=stepType, title=stepTitle, raw=block })
        pos = blockEnd + 1
    end
    return blocks
end

-- 从步骤块提取关键字段
local function parseStep(block)
    local s = {}
    s.id = block.id
    s.type = block.type
    s.title = block.title
    local raw = block.raw
    s.validator_id = raw:match("validator_id%s*=%s*'([^']+)'")
    s.in_vehicle = raw:match('in_vehicle%s*=%s*(%a+)')
    s.duration = tonumber(raw:match('duration%s*=%s*(%d+)') or '0')
    s.radius = tonumber(raw:match('radius%s*=%s*(%d+%.?%d*)') or '0')
    s.label = raw:match('label%s*=%s*"([^"]*)"') or raw:match("label%s*=%s*'([^']*)'")
    -- coords (取第一个 coords 块或顶层 x/y/z)
    local cx = tonumber(raw:match('coords%s*=%s*%{%s*x%s*=%s*([%d%.%-]+)'))
    local cy = tonumber(raw:match('coords%s*=%s*%{%s*x%s*=%s*[%d%.%-]+%s*,%s*y%s*=%s*([%d%.%-]+)'))
    local cz = tonumber(raw:match('coords%s*=%s*%{%s*x%s*=%s*[%d%.%-]+%s*,%s*y%s*=%s*[%d%.%-]+%s*,%s*z%s*=%s*([%d%.%-]+)'))
    if cx and cy and cz then s.coords = { x=cx, y=cy, z=cz } end
    -- validator_data coords
    local dx = tonumber(raw:match('destCoords%s*=%s*%{%s*x%s*=%s*([%d%.%-]+)'))
    local dy = tonumber(raw:match('destCoords%s*=%s*%{%s*x%s*=%s*[%d%.%-]+%s*,%s*y%s*=%s*([%d%.%-]+)'))
    local dz = tonumber(raw:match('destCoords%s*=%s*%{%s*x%s*=%s*[%d%.%-]+%s*,%s*y%s*=%s*[%d%.%-]+%s*,%s*z%s*=%s*([%d%.%-]+)'))
    if dx and dy and dz then s.destCoords = { x=dx, y=dy, z=dz } end
    s.allowClasses = raw:match('allowed_classes%s*=%s*%{([^}]+)%}')
    s.fallbackModel = raw:match("fallback_model%s*=%s*'([^']+)'")
    s.rentalPct = tonumber(raw:match('rental_fee_percent%s*=%s*(%d+)'))
    s.rentalDeposit = tonumber(raw:match('rental_deposit%s*=%s*(%d+)'))
    s.returnCoords_str = raw:match("returnCoords%s*=%s*%b{}")
    return s
end

local steps = findStepBlocks(src)
for i, s in ipairs(steps) do steps[i] = parseStep(s) end

-- Quest 级字段
local questId = src:match("id%s*=%s*'([^']+)'")
local questCat = src:match("category%s*=%s*'([^']+)'")
local questLevel = tonumber(src:match("level%s*=%s*(%d+)"))
local minLicense = src:match("min_license%s*=%s*'([^']+)'")
local cooldown = tonumber(src:match("cooldown_hours%s*=%s*(%d+)"))
local rewMin = tonumber(src:match("money.-min%s*=%s*(%d+)"))
local rewMax = tonumber(src:match("money.-max%s*=%s*(%d+)"))
local rewType = src:match("type%s*=%s*'([^']+)'")
local repAv = tonumber(src:match("aviation%s*=%s*(%d+)"))

-- ═══════════════════════════════ 校验 ══════════════════════
print('')
print('══════════════════════════════════════════════════════════')
print('  ✈️  aviation_medical_airlift — 深度校验')
print('══════════════════════════════════════════════════════════')
print('')

print('📦 1. 模板基础')
assertTrue(questId == 'aviation_medical_airlift', 'id=' .. tostring(questId))
assertTrue(questCat == 'logistics', 'category=' .. tostring(questCat))
assertTrue(questLevel == 1, 'level=' .. tostring(questLevel))

print('\n📋 2. 条件')
assertTrue(minLicense == 'pilot', '飞行执照要求')
assertTrue(cooldown == 0, '冷却=0')

print('\n💰 3. 奖励')
assertTrue(rewType == 'bank', 'type=bank')
assertTrue(rewMin == 2000 and rewMax == 3500, string.format('$%d-%d', rewMin or 0, rewMax or 0))
assertTrue(repAv == 40, '声望 aviation=' .. tostring(repAv))

print('\n🔗 4. 步骤链 (' .. #steps .. ' 步)')
local expIds = {'step_validate_plane','step_load_medical','step_climb_cruise','step_cruise_mid','step_descent_approach','step_land_grapeseed','step_unload_medical','step_return_rental'}
local expTypes = {'validator','interact','reach','reach','reach','validator','interact','validator'}
assertTrue(#steps == 8, '共 8 步')
for i = 1, #steps do
    local ok = steps[i] and steps[i].id == expIds[i] and steps[i].type == expTypes[i]
    assertTrue(ok, string.format('步骤%d: %-25s type=%-10s', i, steps[i] and steps[i].id or '?', steps[i] and steps[i].type or '?'))
end

print('\n📐 5. 步骤 data 完整性')
for i, s in ipairs(steps) do
    local tag = string.format('step%d "%s"', i, s.id)
    assertTrue(s.coords ~= nil, tag .. ' 有 coords')
    if s.type == 'validator' then
        assertTrue(s.validator_id ~= nil, tag .. ' validator_id=' .. tostring(s.validator_id))
        assertTrue(s.in_vehicle == 'true', tag .. ' in_vehicle=true')
        assertTrue(s.duration > 0, tag .. ' duration=' .. s.duration)
    elseif s.type == 'interact' then
        assertTrue(s.duration > 0, tag .. ' duration=' .. s.duration)
        assertTrue(s.label ~= nil, tag .. ' label=' .. tostring(s.label))
    elseif s.type == 'reach' then
        assertTrue(s.radius > 0, tag .. ' radius=' .. s.radius)
    end
end

print('\n🗺️  6. 航路点坐标')
local function coordStr(c) return string.format('(%.0f,%.0f,%.0fm)', c.x, c.y, c.z) end
local function dist(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end

for _, s in ipairs(steps) do
    if s.id == 'step_validate_plane' then
        print('  起始: ' .. coordStr(s.coords))
        assertTrue(s.coords.z > 10 and s.coords.z < 20, '起始在地面(LSIA)')
        assertTrue(s.fallbackModel == 'duster', 'fallback=duster')
        assertTrue(s.rentalPct == 15, '租赁扣15%')
    elseif s.id == 'step_climb_cruise' then
        print('  爬升: ' .. coordStr(s.coords))
        assertTrue(s.coords.z >= 250, '爬升≥250m')
    elseif s.id == 'step_cruise_mid' then
        print('  巡航: ' .. coordStr(s.coords))
        assertTrue(s.coords.z >= 250, '巡航≥250m')
    elseif s.id == 'step_descent_approach' then
        print('  下降: ' .. coordStr(s.coords))
        assertTrue(s.coords.z < 150, '下降<150m')
    elseif s.id == 'step_land_grapeseed' then
        print('  降落: ' .. coordStr(s.coords))
        assertTrue(s.coords.z < 50, '降落在地面跑道')
    end
end

-- 归还点一致性
local startC, returnC
for _, s in ipairs(steps) do
    if s.id == 'step_validate_plane' then startC = s.coords end
    if s.id == 'step_return_rental' then returnC = s.coords end
end
if startC and returnC then
    print('  归还↔起始: ' .. math.floor(dist(startC, returnC)) .. 'm')
    assertTrue(dist(startC, returnC) < 5, '归还点=起始点(同在LSIA)')
end

print('\n📏 7. 总航程')
local pts = {}
for _, s in ipairs(steps) do
    if s.id:match('step_validate_plane') or s.id:match('step_climb') or s.id:match('step_cruise_mid')
        or s.id:match('step_descent') or s.id:match('step_land') then
        table.insert(pts, { id=s.id, c=s.coords })
    end
end
local totalDist = 0
for i = 2, #pts do
    local d = dist(pts[i-1].c, pts[i].c)
    totalDist = totalDist + d
end
print(string.format('  航段: %d 段, 总航程: %.0fm (%.1fkm)', #pts-1, totalDist, totalDist/1000))
assertTrue(totalDist > 5000, '总航程>5km')

print('\n🔍 8. 与 smuggling_flight 差异化确认')
assertTrue(#steps == 8, '8步>走私5步')
assertTrue(rewMax == 3500, '$3500<$6000(走私)')
assertTrue(repAv == 40, 'rep40<80(走私)')

local reachN = 0; for _, s in ipairs(steps) do if s.type == 'reach' then reachN = reachN + 1 end end
assertTrue(reachN == 3, '3个reach航路点(vs走私0)')

local hasReturn = false; for _, s in ipairs(steps) do if s.id:match('return') then hasReturn = true end end
assertTrue(hasReturn, '有归还步骤(走私无)')

-- 结果
print('')
print('══════════════════════════════════════════════════════════')
print(string.format('  📊 结果: %d passed / %d failed', passed, failed))
print('══════════════════════════════════════════════════════════')
if failed > 0 then
    print('\n  🚨 问题:')
    for _, issue in ipairs(issues) do print('    ❌ ' .. issue) end
else
    print('\n  ✅ 全部通过！')
    print('\n  🎮 游戏内测试:')
    print('    /grantpilot')
    print('    /startquest aviation_medical_airlift')
    print('\n  8步流程 (~5-8分钟):')
    print('    ① 绑定飞机(duster)    LSIA 25m  in_vehicle')
    print('    ② 装载医疗物资         LSIA 15m  6s进度条')
    print('    ③ 爬升至>250m         航路点1   50m检测')
    print('    ④ 巡航Sandy上空       航路点2   60m检测')
    print('    ⑤ 下降进场            航路点3   40m检测')
    print('    ⑥ 降落Grapeseed      跑道 20m   in_vehicle')
    print('    ⑦ 卸载医疗物资         5s进度条')
    print('    ⑧ 归还飞机(租用)/私免  LSIA 30m')
end
print('')
