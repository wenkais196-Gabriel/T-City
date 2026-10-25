-- tests/fixtures/quest_availability_harness.lua
-- 由 test_quest_availability.py 用 lua5.4 执行：桩好依赖后 dofile 目标模块，跑一组用例。
-- __MODULE__ 会被替换成被测文件的绝对路径。
__cases = {}

local function emit(name, ok, code, msg)
    __cases[#__cases + 1] = string.format("%s|%s|%s|%s", name, tostring(ok), tostring(code or ""), tostring(msg or ""))
end

__state = {
    tags_match = true,
    police_on_duty = 3,
    has_license = true,
    active = false,
    on_cooldown = false,
    remaining = 0,
    career_missing = false,
    cert_missing = false,
}

exports = setmetatable({}, {
    __index = function(_, resource)
        if resource == 'custom-career' then
            if __state.career_missing then return nil end
            -- 记下真实收到的参数：callExport 走的是 
            -- exports['res']:Method(...) 的约定（第一个参数是 proxy 自己，必须被吃掉），
            -- 参数一旦错位，真实环境里会把 source 当成 tags、把 tags 丢掉。
            return { PlayerMatchesTags = function(_, src, tags)
                __state.last_src = src
                __state.last_tags = tags
                return __state.tags_match
            end }
        elseif resource == 'custom-certificates' then
            if __state.cert_missing then return nil end
            return { HasLicense = function(_, _, _) return __state.has_license end }
        end
        return nil
    end,
})

QBCore = {
    Functions = {
        GetDutyCount = function(_) return __state.police_on_duty end,
        GetPlayer = function(_) return { PlayerData = { citizenid = 'CID1' } } end,
    },
}

QuestManager = { IsQuestActive = function(_, _) return __state.active end }
QuestCooldown = { IsOnCooldown = function(_, _) return __state.on_cooldown, __state.remaining end }

QuestRegistry = {
    GetCategorizedList = function()
        return {
            civilian = {
                { id = 'q_free', title = 'free quest', description = 'd', category = 'civilian', level = 1 },
                { id = 'q_cop', title = 'needs police', description = 'd', category = 'civilian', level = 2 },
            },
        }
    end,
    GetTemplate = function(questId)
        if questId == 'q_cop' then
            return { id = 'q_cop', title = 'needs police', conditions = { min_police = 2, cooldown_hours = 3 } }
        end
        return { id = 'q_free', title = 'free quest', conditions = {} }
    end,
}

dofile('__MODULE__')

local function reset()
    __state.tags_match = true
    __state.police_on_duty = 3
    __state.has_license = true
    __state.active = false
    __state.on_cooldown = false
    __state.remaining = 0
    __state.career_missing = false
    __state.cert_missing = false
end

-- 1. all conditions met
reset()
local ok, code = QuestAvailability.Check(1, QuestRegistry.GetTemplate('q_free'))
emit('all_good', ok == true, code)

-- 2. tag mismatch
reset(); __state.tags_match = false
local tmplTags = { id = 't', required_tags = { role = 'police' } }
local ok2, code2 = QuestAvailability.Check(1, tmplTags)
emit('tags_mismatch', ok2, code2)

-- 3. tag match
reset()
local ok3 = QuestAvailability.Check(1, tmplTags)
emit('tags_match', ok3 == true, nil)

-- 3b. 参数不许错位：导出必须收到 (source, tags)，不是 (tags, nil)
emit('tag_args', __state.last_tags ~= nil, type(__state.last_tags), tostring(__state.last_src))

-- 4. not enough police
reset(); __state.police_on_duty = 1
local tmplPolice = { id = 't2', conditions = { min_police = 2 } }
local ok4, code4 = QuestAvailability.Check(1, tmplPolice)
emit('not_enough_police', ok4, code4)

-- 5. missing license
reset(); __state.has_license = false
local tmplLic = { id = 't3', conditions = { min_license = 'heavy' } }
local ok5, code5 = QuestAvailability.Check(1, tmplLic)
emit('missing_license', ok5, code5)

-- 6. already active
reset(); __state.active = true
local ok6, code6 = QuestAvailability.Check(1, QuestRegistry.GetTemplate('q_free'))
emit('already_active', ok6, code6)

-- 7. on cooldown
reset(); __state.on_cooldown = true; __state.remaining = 600
local ok7, code7, detail7 = QuestAvailability.Check(1, QuestRegistry.GetTemplate('q_cop'))
emit('on_cooldown', ok7, code7, detail7)

-- 8. dependency resource missing must be lenient (same as TriggerQuest)
reset(); __state.career_missing = true
local ok8 = QuestAvailability.Check(1, tmplTags)
emit('career_missing_is_lenient', ok8 == true, nil)

-- 9. List flags availability
reset(); __state.police_on_duty = 0
local list = QuestAvailability.List(1)
local byId = {}
for _, row in ipairs(list) do byId[row.id] = row end
emit('list_contains_free', byId['q_free'] ~= nil and byId['q_free'].available == true, nil)
emit('list_contains_cop', byId['q_cop'] ~= nil and byId['q_cop'].available == false, byId['q_cop'] and byId['q_cop'].reason)
emit('list_row_shape', byId['q_free'] ~= nil and byId['q_free'].category == 'civilian' and byId['q_free'].level == 1, nil)

print(table.concat(__cases, "\n"))
