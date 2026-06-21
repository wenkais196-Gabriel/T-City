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
local decisions = require 'config.decisions'
local registeredCount = DecisionEngine.RegisterAll(decisions)
print(('[story-engine] 📋 %d 决策定义已注册'):format(registeredCount))

-- 加载剧情线定义
local arcs = require 'config.story_arcs'
print(('[story-engine] 📚 %d 条剧情线已加载'):format(#arcs))

-- 加载终章映射
local ArcFinales = require 'config.arc_finales'

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

RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
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

    if StoryConfig.Debug then
        print(('[story-engine] 📩 Decision from %s: %s = %s (quest=%s, step=%s)'):format(
            Player.PlayerData.citizenid, decisionId, chosenOptionId, questId, stepId))
    end

    local success, message = DecisionEngine.MakeChoice(src, questId, stepId, decisionId, chosenOptionId)

    if not success then
        TriggerClientEvent('QBCore:Notify', src, message or 'Choice failed', 'error')
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
print('[story-engine]   事件: story:server:makeDecision')
print('[story-engine]   7 exports: GetArcChoices, GetAllChoices, CheckChoiceCondition, RegisterDecision, GetDecision, IsArcCompleted, IsArcEnabled')
