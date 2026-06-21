-- client/main.lua — story-engine 客户端入口
--
-- 职责:
--   1. 监听 story:client:offerDecision 事件（由 QuestNodes 触发）
--   2. 打开 NUI 决策弹窗
--   3. 接收 NUI 回调 → 发送 story:server:makeDecision

-- ==============================================================
-- 决策弹窗状态
-- ==============================================================

local isNuiOpen = false
local pendingDecision = nil

-- ==============================================================
-- 事件: quest 步骤 decision 触发 → 打开 NUI
-- ==============================================================

RegisterNetEvent('story:client:offerDecision', function(data)
    if isNuiOpen then
        print('[story-engine] ⚠️ NUI already open, ignoring duplicate decision')
        return
    end

    -- data 结构: { questId, stepId, decision_id, ... }
    -- decision_id 由 quest 模板的 step.data.decision_id 注入
    local decisionId = data.decision_id
    local questId = data.questId
    local stepId = data.stepId

    if not decisionId then
        print('[story-engine] ⚠️ offerDecision missing decision_id')
        -- 跳过此步骤，直接回调完成
        TriggerServerEvent('story:server:makeDecision', questId, stepId, 'unknown', 'skip')
        return
    end

    -- 查找决策定义（客户端需要 prompt + options 用于渲染）
    -- 服务端在 makeDecision 时会白名单校验，客户端只需展示
    pendingDecision = {
        questId = questId,
        stepId = stepId,
        decisionId = decisionId,
    }

    -- 从服务端获取决策定义（通过 NUI 回调时 client data 中注入 prompt/options）
    -- 简化方案: 决策定义嵌入在 quest 模板的 step.data 中
    local prompt = data.prompt or '做出你的选择...'
    local options = data.options or {}
    local timeout = data.timeout or StoryConfig.DecisionTimeout

    -- 如果 data 中包含完整 options，直接渲染
    if data.options and #data.options > 0 then
        SetNuiFocus(true, true)
        isNuiOpen = true
        SendNUIMessage({
            type = 'openDecision',
            prompt = prompt,
            options = options,
            timeout = timeout,
        })
    else
        -- fallback: 仅有 decision_id，需要从服务端获取
        -- 此路径暂不实现（v0.8），序章 quest 模板直接在 step.data.options 中提供
        print('[story-engine] ⚠️ No options in step data — skipping')
        TriggerServerEvent('story:server:makeDecision', questId, stepId, decisionId, 'skip')
    end
end)

-- ==============================================================
-- NUI 回调: 玩家点击选项
-- ==============================================================

RegisterNUICallback('makeChoice', function(data, cb)
    cb('ok') -- 先确认收到

    SetNuiFocus(false, false)
    isNuiOpen = false

    if not pendingDecision then
        print('[story-engine] ⚠️ makeChoice but no pending decision')
        return
    end

    local choice = data.optionId
    if not choice then
        print('[story-engine] ⚠️ makeChoice missing optionId')
        return
    end

    -- 发送到服务端
    TriggerServerEvent('story:server:makeDecision',
        pendingDecision.questId,
        pendingDecision.stepId,
        pendingDecision.decisionId,
        choice
    )

    pendingDecision = nil
end)

-- ==============================================================
-- NUI 回调: 超时（玩家未在时间内选择）
-- ==============================================================

RegisterNUICallback('decisionTimeout', function(data, cb)
    cb('ok')

    SetNuiFocus(false, false)
    isNuiOpen = false

    if not pendingDecision then return end

    -- 超时 → 发送一个默认跳过信号
    TriggerServerEvent('story:server:makeDecision',
        pendingDecision.questId,
        pendingDecision.stepId,
        pendingDecision.decisionId,
        'timeout'
    )

    pendingDecision = nil
end)

-- ==============================================================
-- 关闭 NUI（外部调用，如玩家被传送/死亡）
-- ==============================================================

RegisterNetEvent('story:client:closeDecision', function()
    if isNuiOpen then
        SetNuiFocus(false, false)
        isNuiOpen = false
        pendingDecision = nil
        SendNUIMessage({ type = 'closeDecision' })
    end
end)

print('[story-engine] ✅ 客户端已就绪')
