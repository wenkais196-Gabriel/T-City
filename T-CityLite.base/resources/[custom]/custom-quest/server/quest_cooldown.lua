-- quest_cooldown.lua — 任务冷却管理
--
-- 提供任务冷却的检查、设置、查询接口
-- 缓存优先（QuestCache）→ DB fallback

QuestCooldown = QuestCooldown or {}

--- 检查任务是否在冷却中
---@param citizenid string
---@param questId string
---@return boolean onCooldown
---@return number remainingSeconds
function QuestCooldown.IsOnCooldown(citizenid, questId)
    -- 1. 缓存优先
    local cooldowns = QuestCache.GetCooldowns(citizenid, function(cid)
        local result = {}
        QuestDB.GetAllCooldowns(cid, function(data)
            result = data or {}
        end)
        return result
    end)

    if cooldowns and cooldowns[questId] and cooldowns[questId] > 0 then
        return true, cooldowns[questId]
    end

    -- 2. DB fallback
    local onCD = false
    local remaining = 0
    QuestDB.CheckCooldown(citizenid, questId, function(isOnCD, secs)
        onCD = isOnCD
        remaining = secs or 0
    end)

    return onCD, remaining
end

--- 设置任务冷却
---@param citizenid string
---@param questId string
---@param hours number
function QuestCooldown.SetCooldown(citizenid, questId, hours)
    QuestDB.SetCooldown(citizenid, questId, hours)
    QuestCache.InvalidateCooldowns(citizenid)
end

print('[quest-cooldown] ✅ 任务冷却管理已加载')