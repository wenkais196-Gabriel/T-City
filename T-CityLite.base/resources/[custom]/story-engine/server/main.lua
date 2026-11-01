-- server/main.lua — story-engine 服务端入口
--
-- 职责:
--   1. 加载配置 + 注册决策定义
--   2. 注册网络事件: story:server:makeDecision
--   3. 注册到 core-framework Bus
--   4. 注册 exports
--
-- 事件流:
--   quest 步骤类型 decision → QuestNodes 触发 'story:client:offerDecision'
--   → 客户端打开 NUI → 玩家选择 → story:server:makeDecision
--   → DecisionEngine.MakeChoice → CompleteStep → 任务继续

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 初始化: 加载配置
-- ==============================================================

-- 加载决策定义
-- FiveM 沙箱中 require/dofile 不可用，使用 LoadResourceFile + load
local resourceName = GetCurrentResourceName()
local function loadConfigFile(filename)
    local content = LoadResourceFile(resourceName, filename)
    if not content then
        print('[story-engine] ⚠️ Failed to load ' .. filename)
        return nil
    end
    local chunk, err = load(content, '@' .. filename)
    if not chunk then
        print('[story-engine] ⚠️ Syntax error in ' .. filename .. ': ' .. tostring(err))
        return nil
    end
    return chunk()
end

local decisions = loadConfigFile('config/decisions.lua')
local registeredCount = DecisionEngine.RegisterAll(decisions)
print(('[story-engine] 📋 %d 决策定义已注册'):format(registeredCount))

-- 加载剧情线定义
local arcs = loadConfigFile('config/story_arcs.lua')
print(('[story-engine] 📚 %d 条剧情线已加载'):format(#arcs))

-- 加载终章映射
local ArcFinales = loadConfigFile('config/arc_finales.lua')

-- ==============================================================
-- v0.7 一次性门控: 监听 quest 完成 → 标记剧情线完成
-- ==============================================================

AddEventHandler('quest:server:onQuestCompleted', function(citizenid, questId)
    for arcId, finaleIds in pairs(ArcFinales) do
        for _, fid in ipairs(finaleIds) do
            if fid == questId then
                StoryDB.MarkArcCompleted(citizenid, arcId)
                print(('[story-engine] 🏁 Arc %s COMPLETED for %s (quest=%s)'):format(
                    arcId, citizenid, questId))
                return
            end
        end
    end
end)

-- ==============================================================
-- v0.7 一次性门控: 玩家登录时加载已完成剧情线
-- ==============================================================

-- qb-core 的服务端加载事件（注意：不存在 QBCore:Server:OnPlayerLoaded）
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if Player and Player.PlayerData then
        StoryDB.LoadArcCompletions(Player.PlayerData.citizenid)
    end
end)
-- ==============================================================
-- 事件: 玩家做出决策
-- ==============================================================

RegisterNetEvent('story:server:makeDecision', function(questId, stepId, decisionId, chosenOptionId)
    local src = source

    -- 安全: 基本 source 校验
    if not src or src <= 0 then
        print('[story-engine] ⚠️ makeDecision from invalid source')
        return
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then
        print('[story-engine] ⚠️ makeDecision: Player not found for source=' .. tostring(src))
        return
    end

    print(('[story-engine] 📩 makeDecision src=%s cid=%s quest=%s step=%s decision=%s choice=%s'):format(
        tostring(src), Player.PlayerData.citizenid, tostring(questId), tostring(stepId),
        tostring(decisionId), tostring(chosenOptionId)))

    local success, message = DecisionEngine.MakeChoice(src, questId, stepId, decisionId, chosenOptionId)

    if not success then
        TriggerClientEvent('QBCore:Notify', src, message or 'Choice failed', 'error')
    end
end)

-- ==============================================================
-- 客户端可观测性（NUI / 焦点 / 回调失败）
-- ==============================================================

RegisterNetEvent('tcity:client:telemetry', function(event, data)
    local src = source
    if not src or src <= 0 then return end
    local Player = QBCore.Functions.GetPlayer(src)
    local cid = Player and Player.PlayerData and Player.PlayerData.citizenid or nil
    local eventName = tostring(event or 'unknown')
    local payload = json.encode({ event = eventName, data = data or {} })

    print(('[client-telemetry] src=%s cid=%s event=%s data=%s'):format(
        tostring(src), tostring(cid), eventName, tostring(payload)))

    -- Heartbeat is console-only to avoid filling the event outbox every 10s.
    if eventName ~= 'heartbeat' and cid then
        pcall(function()
            exports.oxmysql:execute(
                'INSERT INTO agent_events (event_type, citizenid, payload, schema_version) VALUES (?, ?, ?, 1)',
                { 'client.telemetry', cid, payload })
        end)
    end
end)

-- ==============================================================
-- Exports
-- ==============================================================

-- 获取玩家在某剧情线的选择
exports('GetArcChoices', function(source, arcId, cb)
    DecisionEngine.GetArcChoices(source, arcId, cb)
end)

-- 获取玩家所有选择
exports('GetAllChoices', function(source, cb)
    DecisionEngine.GetArcChoices(source, nil, cb)
end)

-- 检查前置选择条件
exports('CheckChoiceCondition', function(source, condition, cb)
    DecisionEngine.CheckChoiceCondition(source, condition, cb)
end)

-- 注册自定义决策（供其他资源动态添加）
exports('RegisterDecision', function(decision)
    return DecisionEngine.Register(decision)
end)

-- 获取决策定义
exports('GetDecision', function(decisionId)
    return DecisionEngine.GetDecision(decisionId)
end)

-- v0.7 一次性门控: 同步检查剧情线是否已完成
exports('IsArcCompleted', function(source, arcId)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false end
    return StoryDB.IsArcCompletedSync(Player.PlayerData.citizenid, arcId)
end)

-- v0.7 DLC 框架: 检查剧情线是否启用
local _arcsById = {}
for _, arc in ipairs(arcs) do _arcsById[arc.id] = arc end

exports('IsArcEnabled', function(arcId)
    local arc = _arcsById[arcId]
    return arc and arc.enabled ~= false  -- nil → true (默认启用)
end)

-- 服务端下发决策（custom-quest 推进到 decision 步骤时调用）
exports('OfferDecision', function(source, questId, stepId, decisionId, timeout)
    return DecisionEngine.OfferDecision(source, questId, stepId, decisionId, timeout)
end)

-- 清除待响应决策（任务结束/放弃时调用）
exports('ClearDecision', function(source)
    DecisionEngine.ClearPending(source)
end)

-- 服务端可信资源直接提交决策（仍走 pending 上下文校验，不经过客户端事件）
exports('MakeChoice', function(source, questId, stepId, decisionId, chosenOptionId)
    return DecisionEngine.MakeChoice(source, questId, stepId, decisionId, chosenOptionId)
end)

-- 玩家离线时清理，避免 pending/计时器泄漏
AddEventHandler('playerDropped', function()
    DecisionEngine.ClearPending(source)
end)

-- 任务失败/放弃时收口，避免遗留决策在后续任务中被复用
AddEventHandler('quest:server:onQuestFailed', function(citizenid, questId)
    for src, pending in pairs(DecisionEngine._pending) do
        if pending.citizenid == citizenid and pending.questId == questId then
            DecisionEngine.ClearPending(src)
        end
    end
end)

-- ==============================================================
-- 注册到 Bus
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('story', {
        GetArcChoices      = DecisionEngine.GetArcChoices,
        GetAllChoices      = function(source, cb) DecisionEngine.GetArcChoices(source, nil, cb) end,
        CheckChoiceCondition = DecisionEngine.CheckChoiceCondition,
        RegisterDecision   = DecisionEngine.Register,
        GetDecision        = DecisionEngine.GetDecision,
        IsArcCompleted     = function(source, arcId)
            local Player = QBCore.Functions.GetPlayer(source)
            if not Player then return false end
            return StoryDB.IsArcCompletedSync(Player.PlayerData.citizenid, arcId)
        end,
        IsArcEnabled       = function(arcId)
            local arc = _arcsById[arcId]
            return arc and arc.enabled ~= false
        end,
    })
    print('[story-engine] 🔗 已注册到 Bus: service_story_*')
end

print('[story-engine] ✅ 剧情引擎已启动 (v0.7.0)')
-- ==============================================================
-- 开发期：直接下发一个决策（不依赖 quest 状态），用于真机验证面板/点击链路
-- 用法（控制台）：setr story_debug_cmds 1 ; story_offer_dev <src> [decisionId]
-- ==============================================================
RegisterCommand('story_nui_ping', function(source, args)
    if GetConvar('story_debug_cmds', '0') ~= '1' then return end
    if source ~= 0 then return end
    local src = tonumber(args[1])
    if not src then print('[story-dev] 用法: story_nui_ping <src>') return end
    TriggerClientEvent('story:client:nuiPing', src)
    print('[story-dev] nuiPing → src=' .. tostring(src))
end, true)

RegisterCommand('story_offer_dev', function(source, args)
    if GetConvar('story_debug_cmds', '0') ~= '1' then
        print('[story-dev] story_offer_dev 未启用（setr story_debug_cmds 1）')
        return
    end
    if source ~= 0 then return end
    local src = tonumber(args[1])
    local decisionId = args[2] or 'police_ch1_honest_or_silent'
    local questId = args[3] or 'dev_quest'
    local stepId = args[4] or 'dev_step'
    if not src then print('[story-dev] 用法: story_offer_dev <src> [decisionId] [questId] [stepId]') return end
    local ok, res = pcall(function()
        return exports['story-engine']:OfferDecision(src, questId, stepId, decisionId, 120)
    end)
    if not ok or res == false then
        print(('[story-dev] OfferDecision 失败: %s'):format(tostring(ok and res or res)))
        return
    end
    local def = exports['story-engine']:GetDecision(decisionId)
    TriggerClientEvent('story:client:offerDecision', src, {
        questId = questId, stepId = stepId, decision_id = decisionId,
        prompt = def and def.prompt, options = def and def.options,
        timeout = (def and def.timeout) or 120,
    })
    print(('[story-dev] 已下发决策 %s → src=%s（options=%d）')
        :format(decisionId, tostring(src), def and def.options and #def.options or 0))
end, true)

print('[story-engine]   事件: story:server:makeDecision')
print('[story-engine]   9 exports: GetArcChoices, GetAllChoices, CheckChoiceCondition, RegisterDecision, GetDecision, IsArcCompleted, IsArcEnabled, OfferDecision, ClearDecision')
