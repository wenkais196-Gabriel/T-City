-- server/decision_engine.lua — 决策核心 FSM
--
-- 职责:
--   1. 接收 quest 步骤的 decision 触发
--   2. 从 DecisionRegistry 查找决策定义
--   3. 校验 chosenOption 是否在定义的白名单中（防注入）
--   4. 执行 effects（写 player_choices / 后续可扩展到 world_state）
--   5. 回调 custom-quest 的 CompleteStep 推进任务

DecisionEngine = DecisionEngine or {}

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 决策注册表
-- ==============================================================

--- decisionId → decision 定义
DecisionEngine._registry = {}

--- 注册决策定义
---@param decision table { id, arc_id, chapter, prompt, options[] }
function DecisionEngine.Register(decision)
    if not decision or not decision.id then
        print('[decision-engine] ⚠️ 跳过无效决策定义')
        return false
    end

    DecisionEngine._registry[decision.id] = decision

    if StoryConfig.Debug then
        print(('[decision-engine] 📋 Registered: %s (%d options, arc=%s, ch%d)'):format(
            decision.id, #(decision.options or {}), decision.arc_id, decision.chapter or 1))
    end
    return true
end

--- 批量注册
function DecisionEngine.RegisterAll(decisions)
    local count = 0
    for _, d in ipairs(decisions) do
        if DecisionEngine.Register(d) then count = count + 1 end
    end
    return count
end

--- 获取决策定义
function DecisionEngine.GetDecision(decisionId)
    return DecisionEngine._registry[decisionId]
end

-- ==============================================================
-- 决策执行
-- ==============================================================

--- 玩家做出选择（由客户端 story:server:makeDecision 调用）
---@param source number
---@param questId string
---@param stepId string
---@param decisionId string
---@param chosenOptionId string
---@return boolean success
---@return string message
function DecisionEngine.MakeChoice(source, questId, stepId, decisionId, chosenOptionId)
    -- 1. 获取玩家
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then
        return false, 'Player not found'
    end

    local citizenid = Player.PlayerData.citizenid

    -- 2. 查找决策定义
    local decision = DecisionEngine._registry[decisionId]
    if not decision then
        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('剧情决策作弊',
                ('**%s** (%s) | Unknown decision: %s'):format(
                    GetPlayerName(source), citizenid, decisionId), 16711680)
        end
        return false, 'Decision not found'
    end

    -- 3. 🔒 白名单校验：chosenOptionId 必须在定义中存在（防客户端注入）
    local matchedOption = nil
    for _, opt in ipairs(decision.options or {}) do
        if opt.id == chosenOptionId then
            matchedOption = opt
            break
        end
    end
    if not matchedOption then
        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('剧情决策作弊-无效选项',
                ('**%s** (%s) | Decision: %s | Invalid option: %s'):format(
                    GetPlayerName(source), citizenid, decisionId, chosenOptionId), 16711680)
        end
        return false, 'Invalid choice option'
    end

    -- 4. 执行 effects
    local effects = matchedOption.effects or {}

    -- 4a. 写入 player_choices 表
    StoryDB.RecordChoice(citizenid, decisionId, chosenOptionId,
        decision.arc_id, decision.chapter or 1)

    -- 4b. 写入 player_flags（通过 QBCore metadata）
    if effects.player_flags then
        for flag, value in pairs(effects.player_flags) do
            Player.Functions.SetMetaData(('story_flag_%s'):format(flag), value)
        end
        if StoryConfig.Debug then
            print(('[decision-engine] 🏷️ Flags set for %s: %s'):format(
                citizenid, json.encode(effects.player_flags)))
        end
    end

    -- 4c. 授予即时奖励（如果有）
    if effects.rewards then
        pcall(function()
            exports['custom-quest']:TriggerQuest and nil  -- 不在这里发奖励，让 quest 的 reward 步骤处理
        end)
    end

    -- 5. 日志
    if StoryConfig.Debug then
        print(('[decision-engine] ✅ Choice: %s → %s = %s (quest=%s)'):format(
            citizenid, decisionId, chosenOptionId, questId))
    end

    -- 6. 回调 custom-quest 完成 decision 步骤
    local ok, msg = exports['custom-quest']:CompleteStep(source, questId, stepId)
    if not ok then
        print(('[decision-engine] ⚠️ CompleteStep failed: %s'):format(msg or 'unknown'))
        return false, msg or 'Failed to advance quest'
    end

    -- 7. 广播决策事件（供外部系统监听，如日志/统计）
    TriggerEvent('story:server:onDecisionMade', citizenid, decisionId, chosenOptionId, decision.arc_id)

    return true, 'Choice recorded'
end

-- ==============================================================
-- 决策查询
-- ==============================================================

--- 获取玩家在某条剧情线上的选择摘要
function DecisionEngine.GetArcChoices(source, arcId, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb({}); return end
    StoryDB.GetPlayerChoices(Player.PlayerData.citizenid, arcId, cb)
end

--- 检查玩家是否满足某个决策的前置选择条件
---@param source number
---@param condition table { decision = 'decision_id', option = 'option_id' }
---@param cb function 回调: boolean
function DecisionEngine.CheckChoiceCondition(source, condition, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then cb(false); return end

    StoryDB.HasMadeChoice(Player.PlayerData.citizenid, condition.decision, function(hasIt)
        if not hasIt then cb(false); return end

        StoryDB.GetPlayerChoices(Player.PlayerData.citizenid, nil, function(choices)
            for _, c in ipairs(choices) do
                if c.decision_id == condition.decision and c.chosen_option == condition.option then
                    cb(true)
                    return
                end
            end
            cb(false)
        end)
    end)
end

print('[decision-engine] ✅ 决策引擎已就绪')
