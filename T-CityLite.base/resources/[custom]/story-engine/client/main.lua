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
local nuiOpenedAt = 0

-- 客户端可观测性：把 NUI/焦点/回调状态送到服务端日志与 agent_events。
local function telemetry(event, data)
    TriggerServerEvent('tcity:client:telemetry', event, data or {})
end

-- ==============================================================
-- 事件: quest 步骤 decision 触发 → 打开 NUI
-- ==============================================================

-- 关闭决策弹窗的唯一出口：释放焦点 + 恢复 keepInput + 清状态
function closeDecisionSurface(reason)
    if not isNuiOpen and not pendingDecision then return end
    SetNuiFocus(false, false)
    -- 恢复进入前的 keepInput（手机开着时是 true），否则玩家控制/视角被锁
    SetNuiFocusKeepInput(keepInputBefore == true)
    isNuiOpen = false
    nuiOpenedAt = 0
    pendingDecision = nil
    openToken = (openToken or 0) + 1
    telemetry('nui.closeSurface', { reason = reason })
end

RegisterNetEvent('story:client:offerDecision', function(data)
    -- 重复下发不能静默丢弃：上一次弹窗若已失效（CEF 掉了/没收到 close），
    -- 玩家看到的是旧内容、点了没反应，而服务端还在等 —— 表现为"选了没释放"。
    if isNuiOpen then
        print('[story-engine] ♻️ 收到重复决策，先回收旧弹窗再重开')
        telemetry('decision.duplicate', { questId = data and data.questId, stepId = data and data.stepId })
        closeDecisionSurface('duplicate')
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
        options = data.options or {},
    }

    -- 从服务端获取决策定义（通过 NUI 回调时 client data 中注入 prompt/options）
    -- 简化方案: 决策定义嵌入在 quest 模板的 step.data 中
    local prompt = data.prompt or '做出你的选择...'
    local options = data.options or {}
    local timeout = data.timeout or StoryConfig.DecisionTimeout

    -- 如果 data 中包含完整 options，直接渲染
    telemetry('decision.offer', {
        questId = questId, stepId = stepId, decisionId = decisionId,
        option_count = #options, timeout = timeout,
    })

    if data.options and #data.options > 0 then
        -- 防止其他 NUI（如手机）留下的 KeepInput=true 抢走键盘/鼠标；
        -- 但**必须记住原值**，否则关闭后玩家控制回不来（手机那套 keepInput 语义）。
        keepInputBefore = IsNuiFocusKeepingInput()
        SetNuiFocusKeepInput(false)
        SetNuiFocus(true, true)
        isNuiOpen = true
        openToken = (openToken or 0) + 1
        local myToken = openToken
        -- 看门狗：CEF 不回调 makeChoice 时也必须把焦点还回去
        SetTimeout(math.floor((timeout + 5) * 1000), function()
            if isNuiOpen and openToken == myToken then
                print('[story-engine] ⏱️ 决策弹窗超时未响应，强制关闭并交还控制')
                closeDecisionSurface('watchdog')
                TriggerServerEvent('story:server:makeDecision', questId, stepId, decisionId, 'timeout')
            end
        end)
        nuiOpenedAt = GetGameTimer()
        telemetry('nui.focus', {
            open = true, option_count = #options, decisionId = decisionId,
            focused = IsNuiFocused(), keepInput = IsNuiFocusKeepingInput(),
        })
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
        telemetry('decision.no_options', { questId = questId, stepId = stepId, decisionId = decisionId })
        TriggerServerEvent('story:server:makeDecision', questId, stepId, decisionId, 'skip')
    end
end)

-- ==============================================================
-- NUI 回调: 玩家点击选项
-- ==============================================================

RegisterNUICallback('makeChoice', function(data, cb)
    telemetry('nui.makeChoice', { optionId = data and data.optionId or nil })
    cb('ok') -- 先确认收到

    closeDecisionSurface('makeChoice')

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
-- NUI 回调: 关闭弹窗（ESC / 外部兜底）
-- ==============================================================

RegisterNUICallback('closeDecision', function(_, cb)
    telemetry('nui.closeDecision', {})
    cb('ok')
    closeDecisionSurface('nui.closeDecision')
end)

-- NUI 端 JS 错误/ fetch 失败的专用回传通道。
RegisterNUICallback('debugNui', function(data, cb)
    cb('ok')
    telemetry('nui.error', data or {})
end)

-- ==============================================================
-- NUI 回调: 超时（玩家未在时间内选择）
-- ==============================================================

RegisterNUICallback('decisionTimeout', function(data, cb)
    telemetry('nui.timeout', data or {})
    cb('ok')

    SetNuiFocus(false, false)
    isNuiOpen = false
    nuiOpenedAt = 0

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
    telemetry('nui.serverClose', { wasOpen = isNuiOpen })
    if isNuiOpen then
        closeDecisionSurface('server.close')
        isNuiOpen = false
        nuiOpenedAt = 0
        pendingDecision = nil
        SendNUIMessage({ type = 'closeDecision' })
    end
end)

-- ==============================================================
-- 兜底命令：NUI 焦点异常/点击回调失败时使用（F8 控制台也可执行）
-- ==============================================================

RegisterCommand('decision', function(_, args)
    if not pendingDecision then
        print('[story-engine] no pending decision')
        return
    end
    local choice = args[1]
    if not choice then
        local ids = {}
        for _, opt in ipairs(pendingDecision.options or {}) do
            ids[#ids + 1] = opt.id
        end
        print('[story-engine] usage: decision <optionId> | options: ' .. table.concat(ids, ', '))
        return
    end
    SetNuiFocus(false, false)
    isNuiOpen = false
    nuiOpenedAt = 0
    telemetry('command.decision', { choice = choice })
    TriggerServerEvent('story:server:makeDecision',
        pendingDecision.questId, pendingDecision.stepId,
        pendingDecision.decisionId, choice)
    pendingDecision = nil
    SendNUIMessage({ type = 'closeDecision' })
end, false)

RegisterCommand('nuitest', function(_, args)
    local optionId = args[1] or 'honest_cop'
    SendNUIMessage({ type = 'testChoose', optionId = optionId })
    print('[story-engine] nuitest -> ' .. optionId)
end, false)

RegisterCommand('nuifocus', function()
    SetNuiFocusKeepInput(false)
    SetNuiFocus(true, true)
    print(('[story-engine] nuifocus focused=%s keepInput=%s'):format(
        tostring(IsNuiFocused()), tostring(IsNuiFocusKeepingInput())))
    telemetry('command.nuifocus', { focused = IsNuiFocused(), keepInput = IsNuiFocusKeepingInput() })
end, false)

RegisterCommand('fixui', function()
    telemetry('command.fixui', { wasOpen = isNuiOpen })
    SetNuiFocus(false, false)
    isNuiOpen = false
    nuiOpenedAt = 0
    pendingDecision = nil
    SendNUIMessage({ type = 'closeDecision' })
    print('[story-engine] UI focus reset')
end, false)

-- 心跳 + 软锁保护：NUI 打开超过 45 秒仍没有回调，主动释放焦点。
CreateThread(function()
    while true do
        Wait(10000)
        telemetry('heartbeat', {
            nuiOpen = isNuiOpen,
            pending = pendingDecision and pendingDecision.decisionId or nil,
            nuiAgeMs = nuiOpenedAt > 0 and (GetGameTimer() - nuiOpenedAt) or 0,
        })
    end
end)

CreateThread(function()
    while true do
        Wait(1000)
        if isNuiOpen and nuiOpenedAt > 0 and (GetGameTimer() - nuiOpenedAt) > 300000 then
            telemetry('nui.watchdog', { decisionId = pendingDecision and pendingDecision.decisionId or nil })
            SetNuiFocus(false, false)
            isNuiOpen = false
            nuiOpenedAt = 0
            SendNUIMessage({ type = 'closeDecision' })
            print('[story-engine] ⚠️ NUI watchdog released focus after 300s')
        end
    end
end)

print('[story-engine] ✅ 客户端已就绪')
