-- tests/unit/layer3_business/fixtures/garbage_config_probe.lua
-- 真加载 custom-quest 的 config/quests/<文件名>（纯数据文件，文件名由 arg[2] 指定），
-- 把它的事实广播出来，由 Python 那边断言形状与数值。
--
-- 为什么不在 Lua 里断言：断言写在 Python 里，失败信息带"为什么"，而且便于和
-- 02-design.md §2.3 的数值表逐项对照。

local RES = arg[1] or error('need resource dir')
local CONFIG = arg[2] or error('need config filename, e.g. quest_garbage.lua')

local OUT = {}
local function emit(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    OUT[#OUT + 1] = table.concat(parts, '|')
end

local path = RES .. '/config/quests/' .. CONFIG
local handle = assert(io.open(path, 'r'))
local source = handle:read('a')
handle:close()

local chunk = assert(load(source, '@' .. CONFIG))
local quests = chunk()
if type(quests) ~= 'table' then
    emit('LOAD_OK', 'false')
    io.write(table.concat(OUT, '\n'), '\n')
    return
end
emit('LOAD_OK', 'true')
emit('TASK_COUNT', #quests)

-- 注意：run_probe 用 setdefault 收集 KEY|VALUE，同名键只留第一条，
-- 所以每条任务用带序号的键（TASK_1 / TASK_2 / TASK_3）。
for questIndex, quest in ipairs(quests) do
    local validatorSteps = {}
    local orderOk = true
    local metaOk = true
    local seen = {}

    for position, step in ipairs(quest.steps or {}) do
        if step.type == 'validator' then
            local data = step.data or {}
            local vdata = data.validator_data or {}
            local expectedIndex = #validatorSteps + 1
            if vdata.index ~= expectedIndex then orderOk = false end
            if data.validator_id ~= 'validate_route_stop' then metaOk = false end
            if type(vdata.job) ~= 'string' or vdata.require_duty ~= true then metaOk = false end
            if type(data.coords) ~= 'table' then metaOk = false end
            -- 校验器只拿 validator_data + 白名单 meta；coords 不在白名单里，
            -- 所以服务端坐标必须同时出现在 validator_data 中，否则每站都会被判 no_coords。
            if type(vdata.coords) ~= 'table' then metaOk = false end
            if (tonumber(data.radius) or 0) < 10 then metaOk = false end

            local coords = data.coords
            if type(coords) == 'table' then
                local key = ('%.1f,%.1f'):format(coords.x or 0, coords.y or 0)
                if seen[key] then metaOk = false end   -- 重复坐标 = 同一站出现两次
                seen[key] = true
            end
            validatorSteps[#validatorSteps + 1] = position
        end
    end

    -- 首尾必须是 interact（报到 / 交回），中间是 validator
    local firstType = quest.steps[1] and quest.steps[1].type or 'nil'
    local lastType = quest.steps[#quest.steps] and quest.steps[#quest.steps].type or 'nil'

    local money = (quest.rewards and quest.rewards.money) or {}
    local rep = (quest.rewards and quest.rewards.rep) or {}

    local repKey, repValue = 'nil', 'nil'
    for key, value in pairs(rep) do repKey, repValue = tostring(key), tostring(value) end
    local job = 'nil'
    for _, step in ipairs(quest.steps or {}) do
        if step.type == 'validator' and step.data and step.data.validator_data then
            job = tostring(step.data.validator_data.job)
            break
        end
    end
    local tagJob = (quest.required_tags and quest.required_tags.job) or 'nil'
    local requireJob = (quest.conditions and quest.conditions.require_job) or 'nil'
    emit('TASK_' .. questIndex, quest.id, #validatorSteps, tostring(money.min), tostring(money.max),
        repKey, repValue, quest.level, tostring(orderOk), tostring(metaOk), firstType, lastType, job,
        tostring(tagJob), tostring(requireJob))
end

io.write(table.concat(OUT, '\n'), '\n')
