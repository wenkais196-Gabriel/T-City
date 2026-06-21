-- quest_cache.lua — 任务系统内存缓存层
--
-- 提供活跃任务 + 冷却状态的 TTL 内存缓存
-- 减少对 player_quests / quest_cooldowns 表的 DB 查询

QuestCache = QuestCache or {}

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 缓存存储
-- ==============================================================

-- 活跃任务缓存: citizenid → { quests = { [quest_id] = questData }, expires_at }
local activeQuestCache = {}

-- 冷却缓存: citizenid → { cooldowns = { [quest_id] = expires_at }, expires_at }
local cooldownCache = {}

-- ==============================================================
-- 活跃任务缓存
-- ==============================================================

--- 获取玩家活跃任务（缓存优先）
---@param citizenid string
---@param fallbackFn function|nil 缓存未命中时的 DB 加载函数
---@return table|nil quests
function QuestCache.GetActiveQuests(citizenid, fallbackFn)
    local entry = activeQuestCache[citizenid]
    local now = os.time()

    if entry and entry.expires_at > now then
        return entry.quests
    end

    -- 缓存过期或不存在 → 调用 fallback
    if fallbackFn then
        local quests = fallbackFn(citizenid)
        -- v0.7.2: fallback 返回空表时不覆盖旧缓存（MySQL 不可用时保留旧数据）
        if quests and #quests > 0 then
            QuestCache.SetActiveQuests(citizenid, quests)
            return quests
        elseif quests and #quests == 0 and entry then
            -- MySQL 不可用：保留过期缓存数据
            return entry.quests
        end
    end

    return nil
end

--- 写入活跃任务缓存
---@param citizenid string
---@param quests table
function QuestCache.SetActiveQuests(citizenid, quests)
    local ttl = Config.Quest.Cache.ActiveQuestTTL
    activeQuestCache[citizenid] = {
        quests = quests,
        expires_at = os.time() + ttl,
    }
end

--- 使玩家缓存失效（任务状态变更时调用）
---@param citizenid string
function QuestCache.InvalidateActive(citizenid)
    activeQuestCache[citizenid] = nil
end

-- ==============================================================
-- 冷却缓存
-- ==============================================================

--- 获取玩家冷却状态（缓存优先）
---@param citizenid string
---@param fallbackFn function|nil
---@return table|nil cooldowns
function QuestCache.GetCooldowns(citizenid, fallbackFn)
    local entry = cooldownCache[citizenid]
    local now = os.time()

    if entry and entry.expires_at > now then
        return entry.cooldowns
    end

    if fallbackFn then
        local cooldowns = fallbackFn(citizenid)
        if cooldowns then
            QuestCache.SetCooldowns(citizenid, cooldowns)
            return cooldowns
        end
    end

    return {}
end

--- 写入冷却缓存
---@param citizenid string
---@param cooldowns table
function QuestCache.SetCooldowns(citizenid, cooldowns)
    local ttl = Config.Quest.Cache.CooldownTTL
    cooldownCache[citizenid] = {
        cooldowns = cooldowns,
        expires_at = os.time() + ttl,
    }
end

--- 使冷却缓存失效
---@param citizenid string
function QuestCache.InvalidateCooldowns(citizenid)
    cooldownCache[citizenid] = nil
end

-- ==============================================================
-- 全量清空 + 清理
-- ==============================================================

--- 玩家下线时清理所有缓存
---@param citizenid string
function QuestCache.ClearPlayer(citizenid)
    activeQuestCache[citizenid] = nil
    cooldownCache[citizenid] = nil
end

--- 全局清理过期缓存（后台定期执行）
function QuestCache.CleanupExpired()
    local now = os.time()
    local cleaned = 0

    for cid, entry in pairs(activeQuestCache) do
        if entry.expires_at <= now then
            activeQuestCache[cid] = nil
            cleaned = cleaned + 1
        end
    end

    for cid, entry in pairs(cooldownCache) do
        if entry.expires_at <= now then
            cooldownCache[cid] = nil
            cleaned = cleaned + 1
        end
    end

    if cleaned > 0 then
        print(('[quest-cache] 🧹 Cleaned %d expired cache entries'):format(cleaned))
    end
end

-- 定期清理（每 5 分钟）
CreateThread(function()
    while true do
        Wait(5 * 60 * 1000)
        QuestCache.CleanupExpired()
    end
end)

-- 玩家下线清理
AddEventHandler('playerDropped', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player and Player.PlayerData then
        QuestCache.ClearPlayer(Player.PlayerData.citizenid)
    end
end)

-- ==============================================================
-- v0.7.0: custom_event 反向索引
-- ==============================================================

-- { [eventName] = { [citizenid] = { quest_id, step_id } } }
QuestCache._eventIndex = {}

--- 建立事件反向索引（任务接取/步骤推进到 custom_event 时调用）
---@param citizenid string
---@param questId string
---@param stepId string
---@param eventName string
function QuestCache.IndexEvent(citizenid, questId, stepId, eventName)
    if not eventName then return end

    if not QuestCache._eventIndex[eventName] then
        QuestCache._eventIndex[eventName] = {}
    end

    QuestCache._eventIndex[eventName][citizenid] = {
        quest_id = questId,
        step_id = stepId,
    }
end

--- 通过事件名查找匹配的活跃步骤（O(1) 查询）
---@param eventName string
---@param citizenid string
---@return table|nil { quest_id, step_id }
function QuestCache.LookupEvent(eventName, citizenid)
    local index = QuestCache._eventIndex[eventName]
    if not index then return nil end
    return index[citizenid]
end

--- 清除指定玩家的所有事件索引（任务完成/失败/放弃时调用）
---@param citizenid string
---@param questId string|nil 不指定时清除所有
function QuestCache.UnindexEvent(citizenid, questId)
    if questId then
        -- 只清除指定任务
        for eventName, index in pairs(QuestCache._eventIndex) do
            local entry = index[citizenid]
            if entry and entry.quest_id == questId then
                index[citizenid] = nil
            end
        end
    else
        -- 清除所有
        for eventName, index in pairs(QuestCache._eventIndex) do
            index[citizenid] = nil
        end
    end
end

-- ==============================================================
-- v0.7.0: 扩展 ClearPlayer 清理事件索引
-- ==============================================================

-- 覆盖原 ClearPlayer 以清理事件索引
local _origClearPlayer = QuestCache.ClearPlayer
function QuestCache.ClearPlayer(citizenid)
    _origClearPlayer(citizenid)
    QuestCache.UnindexEvent(citizenid, nil)
end

print('[quest-cache] ✅ 任务缓存层已加载 (v0.7.0)')
print('[quest-cache]   事件反向索引: O(1) custom_event 查找')