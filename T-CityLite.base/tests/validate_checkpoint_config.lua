-- tests/validate_checkpoint_config.lua
-- 校验 3 个航空任务中所有 checkpoint 配置完整性

local passed, failed = 0, 0
local issues = {}
local function assertTrue(cond, msg)
    if cond then passed = passed + 1; print('  ✅ ' .. msg)
    else failed = failed + 1; table.insert(issues, msg); print('  ❌ ' .. msg) end
end

-- 解析函数
local function findStepBlocks(text)
    local blocks, pos = {}, 1
    while true do
        local sid = text:find("id%s*=%s*'step_", pos)
        if not sid then break end
        local depth, blockStart = 0, sid
        for i = sid, 1, -1 do
            local c = text:sub(i,i)
            if c == '}' then depth = depth + 1
            elseif c == '{' then
                if depth == 0 then blockStart = i; break end
                depth = depth - 1
            end
        end
        depth = 0; local blockEnd = blockStart
        for i = blockStart, #text do
            local c = text:sub(i,i)
            if c == '{' then depth = depth + 1
            elseif c == '}' then depth = depth - 1; if depth == 0 then blockEnd = i; break end end
        end
        local block = text:sub(blockStart, blockEnd)
        table.insert(blocks, {
            id = block:match("id%s*=%s*'([^']+)'"),
            type = block:match("type%s*=%s*'([^']+)'"),
            hasCheckpoint = block:find('checkpoint%s*=%s*%{') ~= nil,
            cpType = block:match("checkpoint.-type%s*=%s*'([^']+)'"),
            cpRadius = tonumber(block:match("checkpoint.-radius%s*=%s*([%d%.]+)") or '0'),
            label = block:match("checkpoint.-label%s*=%s*'([^']*)'") or block:match('checkpoint.-label%s*=%s*"([^"]*)"'),
        })
        pos = blockEnd + 1
    end
    return blocks
end

local quests = {
    {
        name = 'aviation_medical_airlift',
        file = 'T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_legal_aviation.lua',
        expectCheckpoints = { 'step_climb_cruise', 'step_cruise_mid', 'step_descent_approach', 'step_land_grapeseed' },
    },
    {
        name = 'aviation_smuggling_flight',
        file = 'T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_logistics.lua',
        expectCheckpoints = { 'step_deliver_plane' },
    },
    {
        name = 'pilot_license_exam',
        file = 'T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_pilot_exam.lua',
        expectCheckpoints = { 'step_ring_one', 'step_ring_two', 'step_ring_three', 'step_ring_four', 'step_ring_five' },
    },
}

print('')
print('══════════════════════════════════════════════════════════')
print('  ✅ Checkpoint 配置校验')
print('══════════════════════════════════════════════════════════')
print('')

for _, quest in ipairs(quests) do
    print('📦 ' .. quest.name)
    local f = io.open(quest.file, 'r')
    if f then
        local src = f:read('*all'); f:close()
        local steps = findStepBlocks(src)

        -- 检查预期有 checkpoint 的步骤
        local foundMap = {}
        for _, step in ipairs(steps) do
            if step.hasCheckpoint then
                foundMap[step.id] = true
            end
            for _, expId in ipairs(quest.expectCheckpoints) do
                if step.id == expId then
                    assertTrue(step.hasCheckpoint,
                        string.format('%s.%s 有 checkpoint 配置', quest.name, step.id))
                    if step.hasCheckpoint then
                        assertTrue(step.cpType ~= nil,
                            string.format('%s.%s checkpoint type=%s', quest.name, step.id, tostring(step.cpType)))
                        assertTrue(step.cpRadius > 0,
                            string.format('%s.%s checkpoint radius=%.0f', quest.name, step.id, step.cpRadius))
                        assertTrue(step.label ~= nil and #step.label > 0,
                            string.format('%s.%s checkpoint label="%s"', quest.name, step.id, tostring(step.label)))
                    end
                end
            end
        end

        -- 检查是否漏了预期 checkpoint
        for _, expId in ipairs(quest.expectCheckpoints) do
            if not foundMap[expId] then
                assertTrue(false, quest.name .. '.' .. expId .. ' 缺失 checkpoint')
            end
        end
    else
        print('  ❌ 无法读取: ' .. quest.file)
        failed = failed + 1
    end

    print('')
end

print('══════════════════════════════════════════════════════════')
print(string.format('  📊 结果: %d passed / %d failed', passed, failed))
print('══════════════════════════════════════════════════════════')
if failed > 0 then
    for _, i in ipairs(issues) do print('  ❌ ' .. i) end
else
    print('  ✅ 全部 checkpoint 配置完整！')
end
print('')
