-- quest_registry.lua — 任务模板注册器
--
-- 数据驱动: 从 config/quests/*.lua 加载任务模板
-- 模板结构:
--   {
--     id = 'quest_id',
--     title = '任务标题',
--     description = '描述',
--     category = 'civilian' | 'criminal' | 'leader',
--     level = 1,
--     required_tags = { role = 'civilian' },
--     conditions = { cooldown_hours = 1, min_police = 0 },
--     rewards = { money = { type='bank', min=200, max=400 }, items = {...} },
--     steps = { { id, title, type, data }, ... }
--   }

QuestRegistry = QuestRegistry or {}

-- 已注册的任务模板: quest_id → template
QuestRegistry._templates = {}

-- 按分类索引: category → { quest_id, ... }
QuestRegistry._byCategory = {}

-- ==============================================================
-- 模板加载
-- ==============================================================

--- 加载单个任务模板
---@param template table
---@return boolean success
---@return string|nil error
function QuestRegistry.RegisterTemplate(template)
    -- 基本校验
    if not template or type(template) ~= 'table' then
        return false, 'Template is not a table'
    end

    if not template.id or type(template.id) ~= 'string' then
        return false, 'Template missing valid id'
    end

    if not template.title then
        return false, ('Template %s missing title'):format(template.id)
    end

    -- v0.9: 链模板识别 — 有 quests 字段无 steps → 注册为链元数据
    if template.quests and type(template.quests) == 'table' and #template.quests > 0 then
        if not template.steps or #template.steps == 0 then
            QuestRegistry._chains = QuestRegistry._chains or {}
            QuestRegistry._chains[template.id] = template
            print(('[quest-registry] 🔗 Chain template %s (%d quests) — registered as chain'):format(
                template.id, #template.quests))
            return true, nil
        end
    end

    if not template.steps or type(template.steps) ~= 'table' or #template.steps == 0 then
        return false, ('Template %s has no steps'):format(template.id)
    end

    -- 校验每个步骤
    for i, step in ipairs(template.steps) do
        if not step.id then
            return false, ('Template %s step %d missing id'):format(template.id, i)
        end
        if not step.type then
            return false, ('Template %s step %s missing type'):format(template.id, step.id)
        end
        -- 验证步骤类型有效性
        local validTypes = Config.Quest.StepTypes
        local found = false
        for _, vtype in pairs(validTypes) do
            if vtype == step.type then found = true; break end
        end
        if not found then
            return false, ('Template %s step %s has unknown type: %s'):format(template.id, step.id, step.type)
        end
    end

    -- 检查是否有奖励步骤（reach/collect/custom_event/validator 之后应有 reward）
    local hasReward = false
    for _, step in ipairs(template.steps) do
        if step.type == 'reward' then hasReward = true; break end
    end
    if not hasReward then
        -- 自动追加一个默认奖励步骤
        table.insert(template.steps, {
            id = 'step_reward',
            title = '领取奖励',
            description = '任务完成，领取奖励',
            type = 'reward',
            data = {},
        })
    end

    -- 存储
    QuestRegistry._templates[template.id] = template

    -- 按分类索引
    local category = template.category or 'uncategorized'
    if not QuestRegistry._byCategory[category] then
        QuestRegistry._byCategory[category] = {}
    end
    table.insert(QuestRegistry._byCategory[category], template.id)

    print(('[quest-registry] 📋 Registered: %s (%d steps, category=%s)'):format(
        template.id, #template.steps, category
    ))

    return true, nil
end

--- 批量注册
---@param templates table[]
---@return number registeredCount
---@return table errors
function QuestRegistry.RegisterAll(templates)
    local count = 0
    local errors = {}

    for _, template in ipairs(templates) do
        local ok, err = QuestRegistry.RegisterTemplate(template)
        if ok then
            count = count + 1
        else
            table.insert(errors, err)
        end
    end

    return count, errors
end

-- ==============================================================
-- 模板查询
-- ==============================================================

--- 获取任务模板
---@param questId string
---@return table|nil
function QuestRegistry.GetTemplate(questId)
    return QuestRegistry._templates[questId]
end

--- 获取所有模板 ID
---@param category string|nil
---@return string[]
function QuestRegistry.GetAllIds(category)
    if category then
        return QuestRegistry._byCategory[category] or {}
    end
    local ids = {}
    for questId, _ in pairs(QuestRegistry._templates) do
        table.insert(ids, questId)
    end
    return ids
end

--- 获取按分类组织的模板列表（用于手机 UI）
---@return table { category = { quests = { {id, title, description, level}, ... } } }
function QuestRegistry.GetCategorizedList()
    local result = {}
    for category, ids in pairs(QuestRegistry._byCategory) do
        local quests = {}
        for _, questId in ipairs(ids) do
            local tmpl = QuestRegistry._templates[questId]
            if tmpl then
                table.insert(quests, {
                    id = tmpl.id,
                    title = tmpl.title,
                    description = tmpl.description,
                    category = tmpl.category,
                    level = tmpl.level or 1,
                    required_tags = tmpl.required_tags,
                    rewards = tmpl.rewards,
                })
            end
        end
        result[category] = quests
    end
    return result
end

--- 检查模板是否存在
---@param questId string
---@return boolean
function QuestRegistry.Exists(questId)
    return QuestRegistry._templates[questId] ~= nil
end

-- ==============================================================
-- 自动加载 config/quests/ 目录
-- ==============================================================

--- v0.9: 标准化加载结果 — 支持单模板 / 模板数组 / 链模板
--- 单个文件可能返回: {id=..., steps=...} (单模板) 或 {{id=...}, {id=...}} (数组)
--- 或 {id=..., quests=...} (链模板，跳过注册但记录日志)
---@param value any 文件加载后的返回值
---@return table 标准化后的模板列表
local function NormalizeLoaded(value)
    if not value or type(value) ~= 'table' then return {} end
    -- 单模板 / 链模板 (有 id 字段)
    if value.id then return {value} end
    -- 数组模板 (第一个元素是带 id 的 table)
    if value[1] and type(value[1]) == 'table' and value[1].id then
        local list = {}
        for _, item in ipairs(value) do
            if item.id then list[#list + 1] = item end
        end
        return list
    end
    return {}
end

--- v0.7.0: 从 config/quests/ 目录加载外部任务文件
---@return table quests 从文件中加载的任务模板列表
local function LoadExternalQuests()
    local externalQuests = {}
    -- 尝试加载 config/quests/ 下的所有 .lua 文件
    -- 使用编号命名: quest_001, quest_002, ... 
    -- 也可以使用 data_file 在 fxmanifest 中声明后通过 LoadResourceFile 加载
    
    local fileIndex = 1
    while true do
        local filename = ('config/quests/quest_%03d.lua'):format(fileIndex)
        local content = LoadResourceFile(GetCurrentResourceName(), filename)
        if not content then
            -- 尝试无编号命名
            if fileIndex == 1 then
                -- 尝试 quest_miner.lua 等命名文件（通过显式列表）
                local knownFiles = {
                    'config/quests/quest_miner.lua',
                    'config/quests/quest_logistics.lua',
                    'config/quests/quest_cartel_initiation.lua',
                    'config/quests/quest_cartel_drug_run.lua',
                    'config/quests/quest_chain_cartel.lua',
                    'config/quests/quest_chain_miner.lua',
                    -- P2: 驾考 + 飞行 + 公共服务 + 民航 + 市井商业
                    'config/quests/quest_driver_exam.lua',
                    'config/quests/quest_pilot_exam.lua',
                    'config/quests/quest_public_services.lua',
                    'config/quests/quest_legal_aviation.lua',
                    'config/quests/quest_civilian_misc.lua',
                    -- v0.8b: 配送地址池 (不注册为任务模板，但需加载)
                    -- 'config/quests/address_pools.lua',
                    -- v1.0.0: 乐高积木模板
                    'config/quests/lego/bank_escort.lua',
                    -- v0.7 story-engine: 三个序章
                    'config/quests/quest_cartel_ch1_first_blood.lua',
                    'config/quests/quest_police_ch1_first_shift.lua',
                    'config/quests/quest_civilian_ch1_first_dollar.lua',
                    -- v0.7 story-engine: Cartel / Police / Civilian Ch1-Ch3 (15 files)
                    'config/quests/quest_cartel_ch2_territory_war.lua',
                    'config/quests/quest_cartel_ch3_empire_shadow.lua',
                    'config/quests/quest_cartel_ch4_benevolent_king.lua',
                    'config/quests/quest_cartel_ch4_fugitive.lua',
                    'config/quests/quest_cartel_ch4_tyrant.lua',
                    'config/quests/quest_police_ch2_corruption_web.lua',
                    'config/quests/quest_police_ch3_abyss.lua',
                    'config/quests/quest_police_ch4_hero.lua',
                    'config/quests/quest_police_ch4_silent_guardian.lua',
                    'config/quests/quest_police_ch4_martyr.lua',
                    'config/quests/quest_civilian_ch2_startup_struggle.lua',
                    'config/quests/quest_civilian_ch3_cost_of_empire.lua',
                    'config/quests/quest_civilian_ch4_mogul.lua',
                    'config/quests/quest_civilian_ch4_artisan.lua',
                    'config/quests/quest_civilian_ch4_survivor.lua',
                }
                for _, fn in ipairs(knownFiles) do
                    local c = LoadResourceFile(GetCurrentResourceName(), fn)
                    if c then
                        local ok, loaded = pcall(load(c))
                        if ok and loaded then
                            local normalized = NormalizeLoaded(loaded)
                            for _, tmpl in ipairs(normalized) do
                                externalQuests[#externalQuests + 1] = tmpl
                            end
                            if #normalized > 0 then
                                print(('[quest-registry] 📂 Loaded external: %s (%d templates)'):format(fn, #normalized))
                            end
                        end
                    end
                end
            end
            break
        end

        local ok, loaded = pcall(load(content))
        if ok and loaded then
            local normalized = NormalizeLoaded(loaded)
            for _, tmpl in ipairs(normalized) do
                externalQuests[#externalQuests + 1] = tmpl
            end
            if #normalized > 0 then
                print(('[quest-registry] 📂 Loaded external: %s (%d templates)'):format(filename, #normalized))
            end
        else
            print(('[quest-registry] ⚠️ Failed to parse: %s'):format(filename))
        end

        fileIndex = fileIndex + 1
    end

    return externalQuests
end

function QuestRegistry.AutoLoad()
    -- 1. 尝试加载外部配置文件
    local externalQuests = LoadExternalQuests()

    -- 2. 内置任务（作为 fallback）
    local builtinQuests = {}

    -- 内置示例: 矿工学徒任务
    builtinQuests[#builtinQuests + 1] = {
        id = 'miner_apprentice',
        title = '矿工学徒',
        description = '前往郊区矿井采集 5 块铁矿石',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = { cooldown_hours = 1, min_police = 0 },
        rewards = {
            money = { type = 'bank', min = 200, max = 400 },
            items = { { name = 'pickaxe', count = 1 } },
        },
        steps = {
            {
                id = 'step_go_mine',
                title = '前往矿井',
                description = '前往郊区砂石场',
                type = 'reach',
                data = { coords = { x = -595.9, y = 3492.7, z = 30.0 }, radius = 15.0 },
            },
            {
                id = 'step_mine_iron',
                title = '采集铁矿石',
                description = '使用矿镐采集 5 块铁矿石',
                type = 'custom_event',
                data = { event_name = 'mine_ore', match = { ore_type = 'iron_ore' }, required_count = 5 },
            },
            {
                id = 'step_return',
                title = '回去报到',
                description = '回到城区职业介绍所',
                type = 'reach',
                data = { coords = { x = -268.4, y = -957.5, z = 31.2 }, radius = 10.0 },
            },
        },
    }

    -- 内置示例: 帮派武器运输
    builtinQuests[#builtinQuests + 1] = {
        id = 'gang_weapon_transport',
        title = '军火运输',
        description = '将一批武器从港区运送到帮派据点',
        category = 'criminal',
        level = 2,
        required_tags = { role = 'gang_member' },
        conditions = { cooldown_hours = 6, min_police = 2 },
        rewards = {
            money = { type = 'bank', min = 2000, max = 5000 },
            items = { { name = 'weapon_pistol', count = 1 } },
        },
        steps = {
            {
                id = 'step_pickup',
                title = '港区取货',
                description = '前往港区仓库取货',
                type = 'reach',
                data = { coords = { x = 900.0, y = -3200.0, z = 5.0 }, radius = 20.0 },
            },
            {
                id = 'step_transport',
                title = '运送武器',
                description = '将武器运送到指定据点（不要被警察拦截！）',
                type = 'reach',
                data = { coords = { x = -1500.0, y = -800.0, z = 50.0 }, radius = 30.0 },
            },
        },
    }

    -- 3. 合并：外部文件优先，内置作为补充
    local allQuests = {}
    -- 先加外部文件（优先级更高）
    for _, q in ipairs(externalQuests) do
        allQuests[#allQuests + 1] = q
    end
    -- 再加内置（不被外部覆盖的）
    for _, q in ipairs(builtinQuests) do
        local alreadyExists = false
        for _, eq in ipairs(externalQuests) do
            if eq.id == q.id then alreadyExists = true; break end
        end
        if not alreadyExists then
            allQuests[#allQuests + 1] = q
        end
    end

    local count, errors = QuestRegistry.RegisterAll(allQuests)
    print(('[quest-registry] 📦 Auto-loaded %d quest templates (%d external, %d built-in)'):format(
        count, #externalQuests, #builtinQuests))
    if #errors > 0 then
        for _, err in ipairs(errors) do
            print(('[quest-registry] ⚠️ %s'):format(err))
        end
    end
end

--- v0.7.0: 热重载命令 /reloadquests
RegisterCommand('reloadquests', function(source)
    -- 清空现有模板
    QuestRegistry._templates = {}
    QuestRegistry._byCategory = {}

    -- 重新加载
    QuestRegistry.AutoLoad()

    local total = 0
    for _ in pairs(QuestRegistry._templates) do total = total + 1 end

    if source and source > 0 then
        TriggerClientEvent('QBCore:Notify', source,
            ('Quest templates reloaded: %d quests'):format(total), 'success')
    end
    print(('[quest-registry] 🔄 Hot-reloaded %d quest templates'):format(total))
end, true) -- true = restricted (admin only)

--- v0.7.0: 获取指定步骤
---@param template table
---@param stepId string
---@return table|nil
function QuestRegistry.GetStep(template, stepId)
    if not template or not stepId then return nil end
    for _, step in ipairs(template.steps) do
        if step.id == stepId then return step end
    end
    return nil
end

print('[quest-registry] ✅ 任务注册器已加载 (v0.7.0)')
print('[quest-registry]   外部配置: config/quests/*.lua')
print('[quest-registry]   热重载命令: /reloadquests')