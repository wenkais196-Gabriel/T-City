-- quest_entity_tracker.lua — 实体追踪模块 (v0.9)
--
-- 职责:
--   1. 监听 quest:server:onStepCompleted，读取模板 entity_tracking 字段
--   2. 在运输步骤开始时激活客户端 EntityTracker
--   3. 步骤变更时推送 stepUpdate
--
-- 使用方式（quest 模板中）:
--   entity_tracking = {
--       trailer = {
--           bind_step = 'step_hook_trailer',
--           release_step = 'step_unhook_trailer',
--           detach_countdown_sec = 150,
--       },
--       truck = {
--           bind_step = 'step_check_in',
--           require_in_steps = { 'step_deliver_trailer' },
--           exit_countdown_sec = 150,
--       },
--   }
--
-- 任何包含 entity_tracking 字段的 quest 模板都会自动获得实体追踪能力，
-- 无需额外注册。

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 步骤完成 → 检查是否需要激活/更新实体追踪
-- ==============================================================

AddEventHandler('quest:server:onStepCompleted', function(citizenid, questId, stepId, nextStepId)
    local template = QuestRegistry.GetTemplate(questId)
    if not template or not template.entity_tracking then return end

    local et = template.entity_tracking

    -- 查找玩家 src
    local function findSrc()
        for _, pId in ipairs(GetPlayers()) do
            local Player = QBCore.Functions.GetPlayer(tonumber(pId))
            if Player and Player.PlayerData.citizenid == citizenid then
                return tonumber(pId)
            end
        end
        return nil
    end
    local src = findSrc()
    if not src then return end

    -- 始终推送当前步骤更新（让客户端知道当前在哪个步骤）
    TriggerClientEvent('quest:client:entityTrackStepUpdate', src, nextStepId)

    -- 判断是否应激活追踪
    local trailerCfg = et.trailer
    local truckCfg = et.truck
    local shouldStart = false

    -- 刚完成挂接步骤 → 开始运输 → 激活追踪
    if trailerCfg and stepId == trailerCfg.bind_step then
        shouldStart = true
    end
    -- 刚进入 require_in_steps 中的某个步骤 → 激活追踪
    if truckCfg then
        for _, reqStep in ipairs(truckCfg.require_in_steps or {}) do
            if nextStepId == reqStep then
                shouldStart = true
                break
            end
        end
    end

    if shouldStart then
        TriggerClientEvent('quest:client:entityTrackStart', src, {
            questId = questId,
            trailer = et.trailer,
            truck = et.truck,
        })
    end
end)

print('[quest-entity-tracker] ✅ 实体追踪模块已注册 — 任何带 entity_tracking 字段的 quest 自动激活')
