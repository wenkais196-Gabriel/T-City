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

-- 焦点由 custom-ui 的输入栈统一分派（SetNuiFocus 是**按资源**的，
-- 只有拥有 ui_page 的资源调用才有效）。栈顶是本资源时它会回调这里。
exports('ApplyFocus', function(hasFocus, hasCursor, keepInput)
    if hasFocus then
        SetNuiFocus(true, hasCursor ~= false)
        SetNuiFocusKeepInput(keepInput ~= false)
    else
        if IsNuiFocusKeepingInput() then SetNuiFocusKeepInput(false) end
        SetNuiFocus(false, false)
        SetTimeout(100, function() SetNuiFocus(false, false) end)
    end
    return true
end)

-- 关闭决策弹窗的唯一出口：释放焦点 + 恢复 keepInput + 清状态
function closeDecisionSurface(reason, keepPending)
    if not isNuiOpen and not pendingDecision then return end
    -- 顺序照抄 custom-phone 的 ApplyFocus(false)：**先撤 keepInput，再释放焦点**。
    -- 反过来（先 SetNuiFocus(false,false) 再 KeepInput(true)）真机表现是：
    -- 焦点放了，但鼠标游标留在屏幕上不走。
    local popped = pcall(function() exports['custom-ui']:Pop('story-decision') end)
    if not popped then
        if IsNuiFocusKeepingInput() then SetNuiFocusKeepInput(false) end
        SetNuiFocus(false, false)
    end
    -- 兜底：无论走哪条路，100ms 后再按一次关，防止 keepInput 打断收尾
    SetTimeout(100, function() SetNuiFocus(false, false) end)
    isNuiOpen = false
    nuiOpenedAt = 0
    -- 只有"玩家真的做了选择"才丢掉 pending；界面被看门狗收走时保留，
    -- 否则 /story_choose 兜底也跟着失效（真机：20s 后命令直接说"没有待决策"）。
    if not keepPending then pendingDecision = nil end
    -- 看门狗/CEF 异常收界面后，不要再自动抢焦点（否则玩家控制被反复夺走）；
    -- 此时 pendingDecision 仍保留，/story_choose 随时可用。
    nuiClosedByPlayer = (reason == 'watchdog' or reason == 'nui_not_ready')
    openToken = (openToken or 0) + 1
    telemetry('nui.closeSurface', { reason = reason })
end

RegisterNetEvent('story:client:nuiPing', function()
    print('[story-engine] 🧪 nuiPing -> SendNUIMessage')
    SendNUIMessage({
        type = 'openDecision',
        prompt = 'NUI 自检：看到这个面板说明 SendNUIMessage 通了',
        options = { { id = 'a', text = '选项 A' }, { id = 'b', text = '选项 B' } },
        timeout = 60,
    })
end)

-- 键盘选择：面板开着时按 1/2/3 直接提交对应选项。
-- 为什么必须有：真机上 CEF 的鼠标点击不可靠（OS 光标被 GTA 限制、合成点击进不了 NUI），
-- 而 keepInput(true) 时键盘仍在游戏侧，所以用原始按键轮询（同 nav.lua 的做法）读 1/2/3。
CreateThread(function()
    local holdUntil = 0
    while true do
        Wait(50)
        if pendingDecision and isNuiOpen then
            local opts = pendingDecision.options or {}
            for i = 1, math.min(#opts, 9) do
                local vk = 0x30 + i   -- 1..9
                if IsRawKeyDown(vk) and GetGameTimer() > holdUntil then
                    holdUntil = GetGameTimer() + 400
                    local picked = opts[i].id
                    local pd = pendingDecision
                    pendingDecision = nil
                    closeDecisionSurface('hotkey', true)
                    TriggerServerEvent('story:server:makeDecision', pd.questId, pd.stepId, pd.decisionId, picked)
                    print(('[story-engine] ⌨️ 按键 %d → 已提交 %s'):format(i, tostring(picked)))
                    break
                end
            end
        end
    end
end)

RegisterNetEvent('story:client:offerDecision', function(data)
    -- 重复下发不能静默丢弃：上一次弹窗若已失效（CEF 掉了/没收到 close），
    -- 玩家看到的是旧内容、点了没反应，而服务端还在等 —— 表现为"选了没释放"。
    if isNuiOpen then
        local sameOne = pendingDecision and data
            and pendingDecision.questId == data.questId
            and pendingDecision.stepId == data.stepId
        if sameOne then
            -- 同一个决策重复下发：**什么都不做**。关+重开会重建按钮 DOM，
            -- 玩家正要点的那颗按钮被换掉 → makeChoice 永远不触发（真机复现多次）。
            telemetry('decision.duplicate_ignored', { questId = data.questId, stepId = data.stepId })
            return
        end
        print('[story-engine] ♻️ 收到另一个决策，先回收旧弹窗')
        telemetry('decision.duplicate', { questId = data and data.questId, stepId = data and data.stepId })
        closeDecisionSurface('duplicate', true)
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
        -- 顺序红线：**先 SendNUIMessage 渲染，再 SetNuiFocus 抢焦点**。
        -- 真机实测：先抢焦点时 CEF 收不到这条消息（面板不出现，但焦点已被夺走，
        -- 玩家只能等服务端超时）；探针先发消息则面板正常显示。
        -- 选项必须清洗成纯 {id,text}：决策定义里还带 effects/player_flags 等字段，
        -- 一旦含有函数/元表，SendNUIMessage 的 JSON 编码会失败并**静默丢弃**整条消息
        -- （真机症状：日志显示已发送，页面 openDecision 从未执行，只见游标不见面板）。
        local simpleOptions = {}
        for i, opt in ipairs(options or {}) do
            simpleOptions[i] = { id = tostring(opt.id or i), text = tostring(opt.text or ('选项 ' .. i)) }
        end
        local earlyPayload = {
            type = 'openDecision',
            prompt = tostring(prompt or ''),
            options = simpleOptions,
            timeout = tonumber(timeout) or 120,
        }
        lastDecisionPayload = earlyPayload
        SendNUIMessage(earlyPayload)
        print(('[story-engine] 🧪 early SendNUIMessage options=%d'):format(#options))
        -- 防止其他 NUI（如手机）留下的 KeepInput=true 抢走键盘/鼠标；
        -- 但**必须记住原值**，否则关闭后玩家控制回不来（手机那套 keepInput 语义）。
        -- 按项目红线：开 = SetNuiFocus(true,true) **再** KeepInput(true)。
        -- 之前写成 KeepInput(false) 在前，等于把键盘让给游戏，CEF 拿不到鼠标事件
        -- （真机表现：面板看得见、点不动，只能等超时）。
        keepInputBefore = IsNuiFocusKeepingInput()
        -- 走 custom-ui 的输入栈：它决定"谁是顶层"，再回调我们的 ApplyFocus。
        -- 绕过它直接 SetNuiFocus 会被别的资源（手机/UI 层）随时改回去 ——
        -- 真机症状正是"面板看得见、键盘能用（Lua 原始按键）、鼠标点击全丢"。
        local pushed = pcall(function()
            -- keepInput = false：决策是**模态**，打开期间把输入完全交给 CEF。
            -- 这是鼠标能点动的前提——keepInput=true 时游戏继续持有鼠标，
            -- CEF 只拿到游标、拿不到按键事件（真机：游标在、点不动）。
            -- 页面自己处理 1/2/Esc（decision_nui.html 的 keydown）。
            exports['custom-ui']:Push({
                id = 'story-decision', owner = 'story-engine',
                cursor = true, keepInput = true,
            })
        end)
        -- 本资源是 ui_page 的拥有者，必须自己按焦点；custom-ui 的栈只决定归谁。
        SetNuiFocusKeepInput(false)   -- 先 keepInput，再按焦点（顺序反了会丢光标）
        SetNuiFocus(true, true)
        print(('[story-engine] 🎯 own focus applied, top=%s'):format(tostring((function() local okk, t = pcall(function() return exports['custom-ui']:Top() end) return okk and t or '?' end)())))
        if not pushed then
            SetNuiFocus(true, true)
            SetNuiFocusKeepInput(true)
        end
        isNuiOpen = true
        openToken = (openToken or 0) + 1
        local myToken = openToken
        -- 看门狗：CEF 不回调时把焦点还回去（不替玩家结算，聊天兜底仍可用）
        -- 界面存活时间跟随决策本身的 timeout（最少 60s）：20s 太短，
        -- 玩家还没看清就被收走，而且会让"面板在但点不动"的错觉更严重。
        SetTimeout(math.max(60, timeout) * 1000, function()
            if isNuiOpen and openToken == myToken then
                print('[story-engine] ⏱️ 决策超时，交还控制（/story_choose 仍可继续）')
                closeDecisionSurface('watchdog', true)
            end
        end)
        nuiOpenedAt = GetGameTimer()
        telemetry('nui.focus', {
            open = true, option_count = #options, decisionId = decisionId,
            focused = IsNuiFocused(), keepInput = IsNuiFocusKeepingInput(),
        })
        local payload = earlyPayload   -- 复用已清洗的 payload
        -- 不再等握手才发：CEF 有时不回 nuiReady，等它就等于"永远没面板"。
        -- 直接发 + 1s 后补发一次（丢包兜底）；握手到了只是多一条日志。
        print(('[story-engine] 🧪 SendNUIMessage openDecision options=%d')
            :format(#(payload.options or {})))
        pendingNuiPayload = nil
        openedAtAll = true
        nuiClosedByPlayer = false
        -- 面板已经在上面发过一次；这里**不再重发**，重发会重建按钮 DOM，
        -- 玩家点到一半的按钮被换掉 → makeChoice 永远不触发。

        -- 玩家必须有第二条路：聊天里直接选，不依赖 CEF
        TriggerEvent('chat:addMessage', {
            color = { 255, 200, 60 },
            multiline = true,
            args = { '[纸条]', prompt .. '  →  输入 /story_choose ' ..
                table.concat(collectOptionKeys(options, 1), ' 或 ') },
        })
        print(('[story-engine] 📜 决策可选: %s（也可 /story_choose <选项id>）')
            :format(table.concat(collectOptionKeys(options, 2), ', ')))
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

--- 选项的短键（a/b/c…）与 id，聊天兜底用
function collectOptionKeys(options, mode)
    local out = {}
    local labels = { 'a', 'b', 'c', 'd', 'e', 'f' }
    for i, opt in ipairs(options or {}) do
        out[#out + 1] = (mode == 1) and (labels[i] or tostring(i)) or tostring(opt.id)
    end
    return out
end

-- 聊天兜底：/story_choose a|b|c（或直接给选项 id）
RegisterCommand('story_choose', function(_, args)
    if not pendingDecision then
        print('[story-engine] 当前没有待决策的事项')
        return
    end
    local key = tostring(args[1] or ''):lower()
    local picked = nil
    local labels = { 'a', 'b', 'c', 'd', 'e', 'f' }
    for i, opt in ipairs(pendingDecision.options or {}) do
        if key == labels[i] or key == tostring(opt.id):lower() then picked = opt.id break end
    end
    if not picked then
        print('[story-engine] 无效选项: ' .. key)
        return
    end
    local pd = pendingDecision
    closeDecisionSurface('chat_choice')
    TriggerServerEvent('story:server:makeDecision', pd.questId, pd.stepId, pd.decisionId, picked)
    print('[story-engine] 已提交选择: ' .. tostring(picked))
end, false)

RegisterNUICallback('nuiOpened', function(data, cb)
    cb('ok')
    print(('[story-engine] 🧪 NUI 收到面板: options=%s'):format(tostring(data and data.n)))
end)

RegisterNUICallback('nuiReady', function(_, cb)
    cb('ok')
    nuiReady = true
    telemetry('nui.ready', {})
    if pendingNuiPayload then
        local payload = pendingNuiPayload
        pendingNuiPayload = nil
        SendNUIMessage(payload)
        print('[story-engine] ✅ NUI 握手完成，已补发决策面板')
    end
end)

RegisterNUICallback('makeChoice', function(data, cb)
    telemetry('nui.makeChoice', { optionId = data and data.optionId or nil })
    cb('ok') -- 先确认收到

    -- ⚠️ 顺序红线：必须先取走 pendingDecision，再关界面。
    -- closeDecisionSurface 会清空 pendingDecision，之前写成"先关再读"，
    -- 于是每次都走 'no pending decision' 分支 → 选择根本没发给服务端，
    -- 玩家只能干等 120s 服务端超时兜底（真机症状：点了没反应、要等过期）。
    local pending = pendingDecision
    local choice = data and data.optionId

    if not pending then
        print('[story-engine] ⚠️ makeChoice but no pending decision')
        closeDecisionSurface('makeChoice')
        return
    end
    if not choice then
        print('[story-engine] ⚠️ makeChoice missing optionId')
        return
    end

    pendingDecision = nil
    closeDecisionSurface('makeChoice', true)   -- 只放焦点，pending 已手动取走

    TriggerServerEvent('story:server:makeDecision',
        pending.questId,
        pending.stepId,
        pending.decisionId,
        choice
    )
    print(('[story-engine] ✅ 已提交选择 %s（%s/%s）')
        :format(tostring(choice), tostring(pending.questId), tostring(pending.stepId)))
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

-- 顺序无关的看护：quest 的 step 事件、手机、其它 NUI 都可能在决策期间抢焦点。
-- 只要还有待决策，就每 2 秒自检一次：焦点丢了就重新拿回来并重发面板。
CreateThread(function()
    while true do
        Wait(2000)
        -- ⚠️ 不能用 IsNuiFocused() 判断：本 build 恒为 false（见 nui-debug-playbook §3.0a），
        -- 于是这个"看护"每 2 秒就重发一次面板，openDecision 会重建所有按钮 ——
        -- 玩家的鼠标点击落在被销毁的 DOM 节点上 → makeChoice 永远不触发，
        -- 面板却一直挂着，只能等服务端 120s 超时（真机症状完全吻合）。
        -- 正确条件：只在"界面确实没了"时补一次，绝不在开着的时候重发。
        if pendingDecision and not isNuiOpen and not nuiClosedByPlayer then
            if true then
                keepInputBefore = IsNuiFocusKeepingInput()
                SetNuiFocusKeepInput(false)
                SetNuiFocus(true, true)
                isNuiOpen = true
                if lastDecisionPayload then
                    SendNUIMessage(lastDecisionPayload)
                    print('[story-engine] 🔁 焦点被抢，已重新下发决策面板')
                end
            end
        end
    end
end)
