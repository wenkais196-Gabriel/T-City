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
-- 待响应决策（服务端下发 → 校验 → 收口）
-- ==============================================================

-- source → { questId, stepId, decisionId, citizenid, expiresAt, defaultOption, timer }
DecisionEngine._pending = {}

local function clearPending(source, reason)
    local pending = DecisionEngine._pending[source]
    if pending and pending.timer then
        ClearTimeout(pending.timer)
    end
    DecisionEngine._pending[source] = nil
    if pending and reason and StoryConfig.Debug then
        print(('[decision-engine] 🧹 Pending cleared (%s) for source=%s'):format(reason, tostring(source)))
    end
end

--- 服务端下发决策时登记（由 custom-quest 推进到 decision 步骤时调用）
---@param source number
---@param questId string
---@param stepId string
---@param decisionId string
---@param timeout number|nil
---@return boolean success
---@return string message
function DecisionEngine.OfferDecision(source, questId, stepId, decisionId, timeout)
    local decision = DecisionEngine._registry[decisionId]
    if not decision then
        return false, 'unknown decision'
    end

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then
        return false, 'Player not found'
    end

    if type(questId) ~= 'string' or type(stepId) ~= 'string' then
        return false, 'invalid quest step'
    end

    -- 同一玩家只保留一个待响应决策，避免并发弹窗
    clearPending(source, 'replaced')

    local seconds = tonumber(timeout) or tonumber(decision.timeout) or StoryConfig.DecisionTimeout
    if seconds < 5 then seconds = 5 end

    local defaultOption = decision.default_option
    if not defaultOption and decision.options and decision.options[1] then
        defaultOption = decision.options[1].id
    end

    local pending = {
        questId = questId,
        stepId = stepId,
        decisionId = decisionId,
        citizenid = Player.PlayerData.citizenid,
        expiresAt = os.time() + seconds,
        defaultOption = defaultOption,
    }
    DecisionEngine._pending[source] = pending

    -- 服务端兜底：客户端超时/断线/NUI 异常时按默认选项收口，避免任务永久卡在 decision 步骤
    pending.timer = SetTimeout((seconds + 5) * 1000, function()
        if DecisionEngine._pending[source] == pending then
            print(('[decision-engine] ⏰ Decision timeout (server fallback): %s for %s'):format(
                decisionId, pending.citizenid))
            DecisionEngine.Resolve(source, '__timeout__', true)
        end
    end)

    return true, 'offered'
end

--- 清除玩家待响应决策（任务完成/失败/放弃、玩家离线时调用）
---@param source number
function DecisionEngine.ClearPending(source)
    clearPending(source, 'external')
end

local function findOption(decision, optionId)
    for _, opt in ipairs(decision.options or {}) do
        if opt.id == optionId then
            return opt
        end
    end
    return nil
end

--- 校验并落盘，随后推进任务
---@param source number
---@param chosenOptionId string
---@param isTimeout boolean
---@return boolean success
---@return string message
function DecisionEngine.Resolve(source, chosenOptionId, isTimeout)
    local pending = DecisionEngine._pending[source]
    if not pending then
        return false, 'No active decision'
    end

    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then
        clearPending(source, 'player missing')
        return false, 'Player not found'
    end

    if pending.citizenid ~= Player.PlayerData.citizenid then
        clearPending(source, 'citizen mismatch')
        return false, 'Player mismatch'
    end

    -- 客户端超时信号或服务端兜底 → 使用默认选项
    if isTimeout or chosenOptionId == '__timeout__' or chosenOptionId == 'timeout' or chosenOptionId == 'skip' then
        chosenOptionId = pending.defaultOption
        if not chosenOptionId then
            clearPending(source, 'no default option')
            return false, 'No default option'
        end
    end

    local decision = DecisionEngine._registry[pending.decisionId]
    if not decision then
        clearPending(source, 'decision removed')
        return false, 'Decision not found'
    end

    -- 🔒 白名单校验：chosenOptionId 必须在定义中存在（防客户端注入）
    local matchedOption = findOption(decision, chosenOptionId)
    if not matchedOption then
        -- 不消费 pending：玩家仍可重试，最终由服务端超时兜底
        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('剧情决策作弊-无效选项',
                ('**%s** (%s) | Decision: %s | Invalid option: %s'):format(
                    GetPlayerName(source), pending.citizenid, pending.decisionId,
                    tostring(chosenOptionId)), 16711680)
        end
        return false, 'Invalid choice option'
    end

    local decisionId = pending.decisionId
    local citizenid = pending.citizenid
    local questId = pending.questId
    local stepId = pending.stepId

    -- 先消费 pending，防止重复提交/重复推进
    clearPending(source, 'resolved')

    -- 服务端兜底超时/正常结算都要关掉客户端 NUI；否则 SetNuiFocus(true)
    -- 会把玩家控制锁死（本次实机卡在“口袋里的纸条”就是这个）。
    TriggerClientEvent('story:client:closeDecision', source)
    -- 执行 effects
    local effects = matchedOption.effects or {}

    -- 写入 player_choices 表
    StoryDB.RecordChoice(citizenid, decisionId, chosenOptionId,
        decision.arc_id, decision.chapter or 1)

    -- 写入 player_flags（通过 QBCore metadata）
    if effects.player_flags then
        for flag, value in pairs(effects.player_flags) do
            Player.Functions.SetMetaData(('story_flag_%s'):format(flag), value)
        end
        if StoryConfig.Debug then
            print(('[decision-engine] 🏷️ Flags set for %s: %s'):format(
                citizenid, json.encode(effects.player_flags)))
        end
    end

    if StoryConfig.Debug then
        print(('[decision-engine] ✅ Choice: %s → %s = %s (quest=%s)'):format(
            citizenid, decisionId, chosenOptionId, questId))
    end

    -- 回调 custom-quest 完成 decision 步骤
    local ok, msg = exports['custom-quest']:CompleteStep(source, questId, stepId)
    if not ok then
        print(('[decision-engine] ⚠️ CompleteStep failed: %s'):format(msg or 'unknown'))
        return false, msg or 'Failed to advance quest'
    end

    -- 广播决策事件（供外部系统监听，如日志/统计/导演系统）
    TriggerEvent('story:server:onDecisionMade', citizenid, decisionId, chosenOptionId,
        decision.arc_id, questId, stepId)

    return true, 'Choice recorded'
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
    local pending = DecisionEngine._pending[source]
    if not pending then
        return false, 'No active decision'
    end

    -- 🔒 只接受服务端刚刚下发的那个决策，拒绝跨任务/跨步骤/跨决策的伪造请求
    if pending.questId ~= questId or pending.stepId ~= stepId
        or pending.decisionId ~= decisionId then
        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('剧情决策作弊-上下文不匹配',
                ('**%s** (%s) | pending=%s/%s/%s | got=%s/%s/%s'):format(
                    GetPlayerName(source), pending.citizenid,
                    pending.questId, pending.stepId, pending.decisionId,
                    tostring(questId), tostring(stepId), tostring(decisionId)), 16711680)
        end
        return false, 'Decision context mismatch'
    end

    -- 超过客户端展示期限的迟到请求按超时处理，避免玩家用旧弹窗绕过计时
    if os.time() > pending.expiresAt then
        return DecisionEngine.Resolve(source, '__timeout__', true)
    end

    return DecisionEngine.Resolve(source, chosenOptionId, false)
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
