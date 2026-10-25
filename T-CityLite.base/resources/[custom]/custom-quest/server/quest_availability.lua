-- server/quest_availability.lua — 只读的「这个玩家现在能接什么」计算层
--
-- 用途：给手机任务 App 提供列表；TriggerQuest 仍然是接任务的唯一权威。
-- 这里只做**同步**检查（不打 DB、不发网络事件），因为它是 UI 数据源，任何一次卡顿都会
-- 直接变成"手机点开一片空白"。
--
-- 与 quest_manager.lua 的关系：判定条件与 TriggerQuest 的准入检查保持一致（职业标签 /
-- 警力 / 执照 / 重复接取 / 冷却），但**不复制接取流程**——真正的接取仍然走 TriggerQuest，
-- 它会把所有条件再查一遍。所以这里算错最多是"显示错了"，不会让玩家凭空接到任务。
--
-- 依赖缺失时的策略与 TriggerQuest 一致：资源不在就跳过该检查（宽松），
-- 否则新服少装一个 custom-certificates 就会把全部任务藏起来。

QuestAvailability = QuestAvailability or {}

local REASONS = {
    tags = 'You do not meet the requirements for this quest',
    police = 'Not enough officers on duty',
    license = 'You do not hold the required license',
    active = 'Quest already in progress',
    cooldown = 'Quest is on cooldown',
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

---@param source number
---@param template table
---@return boolean ok, string|nil reasonCode, string|number|nil detail
function QuestAvailability.Check(source, template)
    if type(template) ~= 'table' then return false, 'missing_template' end

    -- 1. 职业/标签
    if type(template.required_tags) == 'table' then
        local matched = callExport('custom-career', 'PlayerMatchesTags', source, template.required_tags)
        if matched == false then return false, 'tags' end
    end

    local conditions = type(template.conditions) == 'table' and template.conditions or {}

    -- 2. 在勤警力
    if conditions.min_police then
        if type(QBCore) == 'table' and QBCore.Functions and QBCore.Functions.GetDutyCount then
            local onDuty = QBCore.Functions.GetDutyCount('police') or 0
            if onDuty < conditions.min_police then return false, 'police' end
        end
    end

    -- 3. 执照
    if conditions.min_license then
        local hasLicense = callExport('custom-certificates', 'HasLicense', source, conditions.min_license)
        if hasLicense == false then return false, 'license', conditions.min_license end
    end

    -- 4. 已在任务中
    if template.id and type(QuestManager) == 'table' and QuestManager.IsQuestActive then
        if QuestManager.IsQuestActive(source, template.id) then return false, 'active' end
    end

    -- 5. 冷却
    local cooldownHours = tonumber(conditions.cooldown_hours) or 0
    if cooldownHours > 0 and type(QuestCooldown) == 'table' and QuestCooldown.IsOnCooldown then
        -- 冷却按 citizenid 记（不是 source），所以这里必须从玩家数据里取
        local citizenid
        if type(QBCore) == 'table' and type(QBCore.Functions) == 'table' and QBCore.Functions.GetPlayer then
            local Player = QBCore.Functions.GetPlayer(source)
            citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
        end
        if citizenid then
            local onCooldown, remaining = QuestCooldown.IsOnCooldown(citizenid, template.id)
            if onCooldown then return false, 'cooldown', math.ceil((tonumber(remaining) or 0) / 60) end
        end
    end

    return true
end

--- 手机任务列表：不满足条件的**也要出现**，只是 available=false + reason，
--- 让玩家看得到"有这条线，但要先去攒警力/拿执照"，而不是以为内容不存在。
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
            local ok, reason, detail = QuestAvailability.Check(source, template)
            rows[#rows + 1] = {
                id = entry.id,
                title = entry.title,
                description = entry.description,
                category = category,
                level = entry.level or 1,
                rewards = entry.rewards,
                available = ok == true,
                reason = reason,
                reason_text = reason and REASONS[reason] or nil,
                remaining_minutes = reason == 'cooldown' and detail or nil,
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

    local ok, reason, detail = QuestAvailability.Check(source, template)
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
        reason_text = reason and REASONS[reason] or nil,
        remaining_minutes = reason == 'cooldown' and detail or nil,
    }
end

return QuestAvailability
