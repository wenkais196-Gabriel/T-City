-- server/quest_availability.lua — 只读的「这个玩家现在能接什么」计算层
--
-- 用途：给手机任务 App 提供列表；TriggerQuest 仍然是接任务的唯一权威。
-- 这里只做**同步**检查（不打 DB、不发网络事件），因为它是 UI 数据源，任何一次卡顿都会
-- 直接变成"手机点开一片空白"。
--
-- 与 quest_manager.lua 的关系：判定条件与 TriggerQuest 的准入检查保持一致（职业标签 /
-- 警力 / 执照 / 剧情线前置 / 剧情抉择 / 重复接取 / 冷却），但**不复制接取流程**——真正的
-- 接取仍然走 TriggerQuest，它会把所有条件再查一遍。所以这里算错最多是"显示错了"，
-- 不会让玩家凭空接到任务。
--
-- 依赖缺失时的策略与 TriggerQuest 一致：资源不在就跳过该检查（宽松），
-- 否则新服少装一个 custom-certificates 就会把全部任务藏起来。
--
-- 每条任务都带一份 requirements（需要什么 / 满足了没有）：玩家不该只看到一句
-- "You do not meet the requirements" 而不知道自己缺的是警力、执照还是一次剧情选择。

QuestAvailability = QuestAvailability or {}

local REASONS = {
    tags = 'You do not meet the requirements for this quest',
    police = 'Not enough officers on duty',
    license = 'You do not hold the required license',
    active = 'Quest already in progress',
    cooldown = 'Quest is on cooldown',
    arc = 'You must finish an earlier story arc first',
    choice = 'You must make a story choice first',
}

-- 手机是中文界面：需求也要说人话，别把 role=gang_member 原样丢给玩家
local ROLE_LABELS = {
    civilian = '平民',
    unemployed = '无业',
    gang_member = '帮派成员',
    police = '警察',
    ems = '急救',
    justice = '司法',
}
local TIER_LABELS = { entry = '入门', mid = '中层', leader = '领袖' }
local ARC_LABELS = {
    cartel = '洛圣都地下帝国',
    police = '蓝墙内外',
    civilian = '洛圣都浮世绘',
}
-- 与 quest_manager 的 flagLabels 保持一致：那边用于拒绝提示，这里用于"需要先做出选择"
local CHOICE_LABELS = {
    cartel_mercy = '饶恕 Aztecas 头目',
    cartel_ruthless = '赶尽杀绝',
    cartel_calculated = '搜集证据后再行动',
    cartel_paranoid = '宁可错杀',
    police_justice = '提交证据给 IA',
    police_pragmatic = '保留证据当筹码',
    police_whistleblower = '向媒体曝光',
    police_insider = '接受交易',
    civ_defiant = '拒绝交保护费',
    civ_pragmatic = '交了保护费',
    civ_ambitious = '贷款扩张',
    civ_cautious = '稳扎稳打',
}

--- 安全调用另一个资源的导出：资源不存在就返回 nil（表示"跳过这项检查"）。
local function callExport(resource, method, ...)
    if type(exports) ~= 'table' then return nil end
    local target = exports[resource]
    if target == nil or type(target[method]) ~= 'function' then return nil end
    local ok, result = pcall(target[method], target, ...)
    if not ok then return nil end
    return result
end

--- 把 required_tags 翻成人话。逐项单独问 custom-career，而不是整包判断：
--- 整包只能得到 true/false，说不出"缺的是哪一项"。
local function tagRequirements(source, tags)
    local entries = {}
    if type(tags) ~= 'table' then return entries end

    local order = { 'role', 'job', 'tier', 'org', 'department', 'district', 'gang', 'cert' }
    for _, key in ipairs(order) do
        local value = tags[key]
        if value ~= nil then
            local met = callExport('custom-career', 'PlayerMatchesTags', source, { [key] = value })
            local text
            if key == 'role' then
                text = ('身份：%s'):format(ROLE_LABELS[value] or tostring(value))
            elseif key == 'job' then
                text = ('职业：%s'):format(ROLE_LABELS[value] or tostring(value))
            elseif key == 'tier' then
                text = ('资历：%s'):format(TIER_LABELS[value] or tostring(value))
            elseif key == 'cert' then
                text = ('证件：%s'):format(tostring(value))
            else
                text = ('%s：%s'):format(key, tostring(value))
            end
            entries[#entries + 1] = {
                kind = 'tags',
                text = text,
                -- nil = custom-career 没装 → 按宽松策略视为满足（与 TriggerQuest 一致）
                met = met ~= false,
            }
        end
    end
    return entries
end

--- 剧情抉择：TriggerQuest 要求列出的 flag **全部**为 true（metadata story_flag_*）。
local function choiceRequirement(source, choices)
    local labels = {}
    for _, pc in ipairs(choices) do
        local flag = type(pc) == 'table' and pc.flag or nil
        if flag then labels[#labels + 1] = CHOICE_LABELS[flag] or tostring(flag) end
    end
    if #labels == 0 then return nil end

    local met = true
    if type(QBCore) == 'table' and type(QBCore.Functions) == 'table' and QBCore.Functions.GetPlayer then
        local Player = QBCore.Functions.GetPlayer(source)
        local metadata = Player and Player.PlayerData and Player.PlayerData.metadata
        if not metadata then
            met = false
        else
            for _, pc in ipairs(choices) do
                local flag = type(pc) == 'table' and pc.flag or nil
                if flag and metadata['story_flag_' .. flag] ~= true then met = false end
            end
        end
    end
    return {
        kind = 'choice',
        text = ('剧情选择：%s'):format(table.concat(labels, ' 或 ')),
        met = met,
    }
end

--- 计算一条任务对某个玩家的全部需求。
---@return boolean ok, string|nil reasonCode, string|number|nil detail, table[] requirements
function QuestAvailability.Evaluate(source, template)
    if type(template) ~= 'table' then return false, 'missing_template', nil, {} end

    local requirements = {}
    local function add(entry)
        if entry then requirements[#requirements + 1] = entry end
    end

    -- 1. 职业 / 标签（逐项列出）
    for _, entry in ipairs(tagRequirements(source, template.required_tags)) do add(entry) end

    local conditions = type(template.conditions) == 'table' and template.conditions or {}

    -- 2. 在勤警力
    if conditions.min_police then
        local onDuty, known = 0, false
        if type(QBCore) == 'table' and QBCore.Functions and QBCore.Functions.GetDutyCount then
            onDuty = tonumber(QBCore.Functions.GetDutyCount('police')) or 0
            known = true
        end
        add({
            kind = 'police',
            text = known
                and ('在勤警力 ≥ %d（当前 %d）'):format(conditions.min_police, onDuty)
                or ('在勤警力 ≥ %d'):format(conditions.min_police),
            met = (not known) or onDuty >= conditions.min_police,
        })
    end

    -- 3. 执照
    if conditions.min_license then
        local hasLicense = callExport('custom-certificates', 'HasLicense', source, conditions.min_license)
        add({
            kind = 'license',
            text = ('执照：%s'):format(tostring(conditions.min_license)),
            met = hasLicense ~= false,
        })
    end

    -- 4. 剧情线前置
    if conditions.prerequisite_arc then
        local arc = conditions.prerequisite_arc
        local completed = callExport('story-engine', 'IsArcCompleted', source, arc)
        add({
            kind = 'arc',
            text = ('先完成剧情线「%s」'):format(ARC_LABELS[arc] or tostring(arc)),
            met = completed ~= false,
        })
    end

    -- 5. 剧情抉择前置
    if type(conditions.player_choices) == 'table' then
        add(choiceRequirement(source, conditions.player_choices))
    end

    -- 6. 已在任务中（只有真的在进行中才列出来，否则是噪音）
    if template.id and type(QuestManager) == 'table' and QuestManager.IsQuestActive then
        if QuestManager.IsQuestActive(source, template.id) then
            add({ kind = 'active', text = '该任务已在进行中', met = false })
        end
    end

    -- 7. 冷却（只在模板声明了冷却时间时列出）
    local cooldownHours = tonumber(conditions.cooldown_hours) or 0
    if cooldownHours > 0 then
        local entry = { kind = 'cooldown', text = ('冷却 %d 小时'):format(cooldownHours), met = true }
        if type(QuestCooldown) == 'table' and QuestCooldown.IsOnCooldown then
            -- 冷却按 citizenid 记（不是 source），所以必须从玩家数据里取
            local citizenid
            if type(QBCore) == 'table' and type(QBCore.Functions) == 'table' and QBCore.Functions.GetPlayer then
                local Player = QBCore.Functions.GetPlayer(source)
                citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
            end
            if citizenid then
                local onCooldown, remaining = QuestCooldown.IsOnCooldown(citizenid, template.id)
                if onCooldown then
                    entry.met = false
                    entry.text = ('冷却中 · 还需 %d 分钟'):format(math.ceil((tonumber(remaining) or 0) / 60))
                end
            end
        end
        add(entry)
    end

    -- 第二遍：按需求顺序给出"最早失败的那一项"作为 reason
    for _, kind in ipairs({ 'tags', 'police', 'license', 'arc', 'choice', 'active', 'cooldown' }) do
        for _, req in ipairs(requirements) do
            if req.kind == kind and not req.met then
                return false, kind, kind == 'license' and conditions.min_license or nil, requirements
            end
        end
    end

    return true, nil, nil, requirements
end

--- 兼容旧调用：只要结论。
---@return boolean ok, string|nil reasonCode, string|number|nil detail
function QuestAvailability.Check(source, template)
    local ok, reason, detail = QuestAvailability.Evaluate(source, template)
    return ok, reason, detail
end

--- 需求 → 给人看的文案（第一条不满足的）
local function unmetText(requirements)
    for _, req in ipairs(requirements) do
        if not req.met then return req.text end
    end
    return nil
end

--- 手机任务列表：不满足条件的**也要出现**，并且把"需要什么"逐条摆出来，
--- 让玩家看得到"有这条线，但要先攒警力/拿执照/做剧情选择"，而不是以为内容不存在。
---@param source number
---@return table[] rows
function QuestAvailability.List(source)
    local rows = {}
    if type(QuestRegistry) ~= 'table' or not QuestRegistry.GetCategorizedList then return rows end

    local catalog = QuestRegistry.GetCategorizedList() or {}
    for category, quests in pairs(catalog) do
        for _, entry in ipairs(quests) do
            local template = entry
            if QuestRegistry.GetTemplate then
                template = QuestRegistry.GetTemplate(entry.id) or entry
            end
            local ok, reason, detail, requirements = QuestAvailability.Evaluate(source, template)
            rows[#rows + 1] = {
                id = entry.id,
                title = entry.title,
                description = entry.description,
                category = category,
                level = entry.level or 1,
                rewards = entry.rewards,
                available = ok == true,
                reason = reason,
                -- 不可接时给出"缺哪一条"，而不是一句英文占位
                reason_text = ok == true and nil or (unmetText(requirements) or (reason and REASONS[reason])),
                remaining_minutes = reason == 'cooldown' and detail or nil,
                requirements = requirements,
            }
        end
    end

    table.sort(rows, function(a, b)
        if a.category ~= b.category then return tostring(a.category) < tostring(b.category) end
        if a.level ~= b.level then return (a.level or 0) < (b.level or 0) end
        return tostring(a.id) < tostring(b.id)
    end)
    return rows
end

--- 详情：给手机端的单条任务信息（步骤只给标题，不暴露坐标等执行细节）。
function QuestAvailability.Detail(source, questId)
    if type(questId) ~= 'string' or questId == '' then return nil, 'bad_id' end
    if type(QuestRegistry) ~= 'table' or not QuestRegistry.GetTemplate then return nil, 'no_registry' end
    local template = QuestRegistry.GetTemplate(questId)
    if not template then return nil, 'not_found' end

    local ok, reason, detail, requirements = QuestAvailability.Evaluate(source, template)
    local steps = {}
    for index, step in ipairs(template.steps or {}) do
        steps[#steps + 1] = {
            index = index,
            title = step.title or step.label or step.id,
            type = step.type,
        }
    end

    return {
        id = template.id,
        title = template.title,
        description = template.description,
        category = template.category,
        level = template.level or 1,
        rewards = template.rewards,
        steps = steps,
        available = ok == true,
        reason = reason,
        reason_text = ok == true and nil or (unmetText(requirements) or (reason and REASONS[reason])),
        remaining_minutes = reason == 'cooldown' and detail or nil,
        requirements = requirements,
    }
end

return QuestAvailability
