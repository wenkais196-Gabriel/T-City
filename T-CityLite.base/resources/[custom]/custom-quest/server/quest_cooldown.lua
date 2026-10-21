-- quest_cooldown.lua — 任务冷却管理
--
-- 提供任务冷却的检查、设置、查询接口
-- 内存优先 → 缓存 → DB（异步结果只用于回填，不参与同步判定）

QuestCooldown = QuestCooldown or {}

-- citizenid → { [questId] = expiresAt(unix) }
QuestCooldown._mem = {}

local function now()
    return os.time()
end

--- 从 DB 预加载某玩家的冷却（登录时调用）
---@param citizenid string
function QuestCooldown.Load(citizenid)
    QuestDB.GetAllCooldowns(citizenid, function(data)
        local m = {}
        for questId, remaining in pairs(data or {}) do
            if type(remaining) == 'number' and remaining > 0 then
                m[questId] = now() + remaining
            end
        end
        QuestCooldown._mem[citizenid] = m
    end)
end

--- 检查任务是否在冷却中（同步、内存权威）
---@param citizenid string
---@param questId string
---@return boolean onCooldown
---@return number remainingSeconds
function QuestCooldown.IsOnCooldown(citizenid, questId)
    local mem = QuestCooldown._mem[citizenid]
    if mem and mem[questId] then
        local remaining = mem[questId] - now()
        if remaining > 0 then
            return true, remaining
        end
        mem[questId] = nil
    end

    -- 缓存层（若由其他路径回填）
    local cooldowns = QuestCache.GetCooldowns(citizenid)
    if cooldowns and type(cooldowns[questId]) == 'number' and cooldowns[questId] > 0 then
        return true, cooldowns[questId]
    end

    return false, 0
end

--- 设置任务冷却
---@param citizenid string
---@param questId string
---@param hours number
function QuestCooldown.SetCooldown(citizenid, questId, hours)
    QuestDB.SetCooldown(citizenid, questId, hours)

    QuestCooldown._mem[citizenid] = QuestCooldown._mem[citizenid] or {}
    QuestCooldown._mem[citizenid][questId] = now() + math.floor((hours or 0) * 3600)

    QuestCache.InvalidateCooldowns(citizenid)
end

-- 登录时加载 DB 冷却，避免"重启后冷却全部失效"
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if Player and Player.PlayerData then
        QuestCooldown.Load(Player.PlayerData.citizenid)
    end
end)

print('[quest-cooldown] ✅ 任务冷却管理已加载')
