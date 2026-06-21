-- quest_security.lua — 任务系统纵深安全守卫  v0.7.0
--
-- 六重防御:
--   1. Nonce Token — 防事件重放（每次操作需携带有效 Token，懒清理）
--   2. Rate Limit — 滑动窗口频率熔断（复用 custom-security CheckRateLimit）
--   3. Step Order — 服务端严格顺序强制（不接受客户端指定的 step_id 跳跃）
--   4. Distance Check — 服务端拉坐标验证（不信任客户端传入坐标）
--   5. Speed Anomaly — 速度异常检测（防瞬移后触发 reach）          ★ v0.7.0
--   6. Global Token Bucket — 全局限流熔断（防 DDoS 式刷事件）      ★ v0.7.0
--
-- 设计原则: 纵深防御，绝不信任客户端

QuestSecurity = QuestSecurity or {}

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- Nonce Token 池
-- ==============================================================

-- source → { token → expires_at }
local noncePool = {}

--- 生成 Nonce Token
---@param source number
---@return string token
function QuestSecurity.GenerateNonce(source)
    if not Config.Quest.Security.EnforceNonce then
        return 'nonce_disabled'
    end

    local token = ('%s_%d_%d'):format(
        tostring(source),
        os.time(),
        math.random(100000, 999999)
    )

    if not noncePool[source] then
        noncePool[source] = {}
    end

    noncePool[source][token] = os.time() + Config.Quest.Security.NonceExpiry

    return token
end

--- 验证并消耗 Nonce Token（v0.7.0: 懒清理过期 token）
---@param source number
---@param token string
---@return boolean valid
function QuestSecurity.ValidateNonce(source, token)
    if not Config.Quest.Security.EnforceNonce then
        return true
    end

    -- v0.7.2: token === true 表示调用方显式跳过 nonce（nodeComplete 等已有其他校验层的入口）
    if token == true then return true end
    if not token or type(token) ~= 'string' then return false end

    local pool = noncePool[source]
    if not pool then return false end

    local expiresAt = pool[token]
    if not expiresAt then return false end

    -- 检查过期
    if os.time() > expiresAt then
        pool[token] = nil
        return false
    end

    -- 一次性消耗
    pool[token] = nil

    -- v0.7.0: 懒清理 —— 顺带清理该 source 下所有过期 token
    local now = os.time()
    for tok, expires in pairs(pool) do
        if now > expires then
            pool[tok] = nil
        end
    end

    return true
end

-- ==============================================================
-- Rate Limit（复用 custom-security）
-- ==============================================================

--- 检查操作频率
---@param source number
---@param action string
---@return boolean allowed
function QuestSecurity.CheckRateLimit(source, action)
    if exports['custom-security'] and exports['custom-security'].CheckRateLimit then
        return exports['custom-security']:CheckRateLimit(source, 'quest_' .. action,
            Config.Quest.Security.RateLimitMs)
    end
    -- fallback: 总是允许
    return true
end

-- ==============================================================
-- v0.7.0: 全局令牌桶熔断
-- ==============================================================

QuestSecurity._globalBucket = {
    tokens = Config.Quest.Security.GlobalTokensPerSecond or 50,
    lastRefill = os.time(),
}

--- 全局限流检查（所有玩家共享配额）
---@return boolean allowed
function QuestSecurity.CheckGlobalRateLimit()
    if not Config.Quest.Security.EnableGlobalRateLimit then
        return true
    end

    local bucket = QuestSecurity._globalBucket
    local now = os.time()
    local elapsed = now - bucket.lastRefill
    local maxTokens = Config.Quest.Security.GlobalTokensPerSecond

    -- 每秒补充 token（按时间比例）
    bucket.tokens = math.min(maxTokens, bucket.tokens + elapsed * maxTokens)
    bucket.lastRefill = now

    if bucket.tokens < 1 then
        return false -- 全局熔断
    end

    bucket.tokens = bucket.tokens - 1
    return true
end

-- ==============================================================
-- v0.7.0: 速度异常检测
-- ==============================================================

-- source → { coords = vector3, time = timestamp }
QuestSecurity._lastReachAttempt = {}

--- 检查玩家移动速度是否异常（防瞬移作弊）
---@param source number
---@param currentCoords vector3
---@return boolean isNormal
function QuestSecurity.CheckSpeedAnomaly(source, currentCoords)
    if not Config.Quest.Security.EnableSpeedCheck then
        return true
    end

    local last = QuestSecurity._lastReachAttempt[source]
    if not last then
        QuestSecurity._lastReachAttempt[source] = {
            coords = currentCoords,
            time = os.time(),
        }
        return true
    end

    local distance = #(currentCoords - last.coords)
    local elapsed = os.time() - last.time

    -- 更新记录
    QuestSecurity._lastReachAttempt[source] = {
        coords = currentCoords,
        time = os.time(),
    }

    if elapsed <= 0 then elapsed = 1 end

    local speed = distance / elapsed
    local maxSpeed = Config.Quest.Security.MaxSpeedMps

    if speed > maxSpeed then
        QuestDB.LogEvent('unknown', 'unknown', 'security_block', nil, {
            reason = 'speed_anomaly',
            speed = speed,
            max_allowed = maxSpeed,
            source = source,
        })
        return false
    end

    return true
end

-- ==============================================================
-- Step Order 顺序强制
-- ==============================================================

--- 验证步骤顺序：客户端声称完成的步骤必须是当前活跃步骤
---@param citizenid string
---@param questId string
---@param claimedStepId string 客户端声称完成的步骤 ID
---@return boolean valid
---@return string|nil error
function QuestSecurity.ValidateStepOrder(citizenid, questId, claimedStepId)
    if not Config.Quest.Security.EnforceStepOrder then
        return true
    end

    local template = QuestRegistry.GetTemplate(questId)
    if not template then
        return false, 'Quest not found'
    end

    -- 从缓存读取当前步骤（v0.8b: 缓存空时同步 DB 查询兜底）
    local activeQuests = QuestCache.GetActiveQuests(citizenid, function(cid)
        local p = promise.new()
        QuestDB.GetActiveQuests(cid, function(rows)
            p:resolve(rows or {})
        end)
        return Citizen.Await(p)
    end)
    if not activeQuests or #activeQuests == 0 then
        -- v0.8b: 最后兜底 — 检查解析后模板是否存在（说明任务活跃）
        if QuestManager._resolvedTemplates[citizenid .. '_' .. questId] then
            return true  -- 信任解析后模板，放行
        end
        return false, 'No active quests in cache'
    end

    local currentStep = nil
    for _, q in ipairs(activeQuests) do
        if q.quest_id == questId then
            currentStep = q.current_step
            break
        end
    end

    if not currentStep then
        return false, 'Quest not active for this player'
    end

    if currentStep ~= claimedStepId then
        return false, ('Step order violation: expected %s, got %s'):format(currentStep, claimedStepId)
    end

    return true
end

-- ==============================================================
-- v0.7.0: 步骤尝试次数限制
-- ==============================================================

-- citizenid → { [questId_stepId] = count }
QuestSecurity._stepAttempts = {}

--- 检查并递增步骤尝试次数
---@param citizenid string
---@param questId string
---@param stepId string
---@return boolean allowed
function QuestSecurity.CheckStepAttempts(citizenid, questId, stepId)
    local maxAttempts = Config.Quest.Security.MaxStepAttempts
    if maxAttempts <= 0 then return true end

    if not QuestSecurity._stepAttempts[citizenid] then
        QuestSecurity._stepAttempts[citizenid] = {}
    end

    local key = ('%s_%s'):format(questId, stepId)
    local count = (QuestSecurity._stepAttempts[citizenid][key] or 0) + 1
    QuestSecurity._stepAttempts[citizenid][key] = count

    if count > maxAttempts then
        QuestDB.LogEvent(citizenid, questId, 'security_block', stepId, {
            reason = 'max_attempts_exceeded',
            attempts = count,
            max = maxAttempts,
        })
        return false
    end

    return true
end

-- ==============================================================
-- Distance Check 服务端坐标拉取
-- ==============================================================

--- 验证玩家是否在目标位置范围内
---@param source number
---@param targetCoords table {x, y, z}
---@param radius number 最大距离（米）
---@return boolean inRange
---@return number distance
function QuestSecurity.CheckDistance(source, targetCoords, radius)
    radius = radius or Config.Quest.Security.MaxReachDistance

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then
        return false, 0
    end

    local playerCoords = GetEntityCoords(ped)
    local distance = #(playerCoords - vector3(
        targetCoords.x or 0,
        targetCoords.y or 0,
        targetCoords.z or 0
    ))

    return distance <= radius, distance
end

-- ==============================================================
-- v0.7.0: script_trigger Export 白名单校验
-- ==============================================================

--- 检查 export 路径是否在白名单中
---@param exportPath string 格式 "resource:exportName"
---@return boolean allowed
function QuestSecurity.IsExportAllowed(exportPath)
    if not exportPath or type(exportPath) ~= 'string' then
        return false
    end

    -- 如果白名单为空表则全部放行（向后兼容）
    local whitelist = Config.Quest.Security.AllowedScriptExports
    if not whitelist or next(whitelist) == nil then
        return true
    end

    return whitelist[exportPath] == true
end

-- ==============================================================
-- 综合事件校验（客户端→服务端可信通道）
-- ==============================================================

--- 完整的客户端事件验证入口
---@param source number
---@param questId string
---@param stepId string
---@param nonceToken string
---@param clientData table|nil
---@return boolean ok
---@return string|nil error
function QuestSecurity.ValidateClientEvent(source, questId, stepId, nonceToken, clientData)
    -- 0. v0.7.0: 全局熔断检查（最优先）
    if not QuestSecurity.CheckGlobalRateLimit() then
        return false, 'Server busy, please try again later'
    end

    -- 1. Nonce 校验
    if not QuestSecurity.ValidateNonce(source, nonceToken) then
        QuestDB.LogEvent('unknown', questId, 'security_block', stepId,
            { reason = 'invalid_nonce', source = source })
        return false, 'Invalid or expired security token'
    end

    -- 2. Rate Limit
    if not QuestSecurity.CheckRateLimit(source, 'step_complete') then
        QuestDB.LogEvent('unknown', questId, 'security_block', stepId,
            { reason = 'rate_limit', source = source })
        return false, 'Action too frequent, please slow down'
    end

    -- 3. 玩家有效性
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player or not Player.PlayerData then
        return false, 'Player not found'
    end

    local citizenid = Player.PlayerData.citizenid

    -- 4. 步骤顺序
    local orderOk, orderErr = QuestSecurity.ValidateStepOrder(citizenid, questId, stepId)
    if not orderOk then
        QuestDB.LogEvent(citizenid, questId, 'security_block', stepId,
            { reason = 'step_order_violation', claimed = stepId })
        return false, orderErr
    end

    -- 5. v0.7.0: 步骤尝试次数
    if not QuestSecurity.CheckStepAttempts(citizenid, questId, stepId) then
        QuestDB.LogEvent(citizenid, questId, 'security_block', stepId,
            { reason = 'max_attempts_exceeded' })
        return false, 'Too many attempts, please contact an admin'
    end

    -- 6. 距离校验（如果步骤类型是 reach）
    if clientData and clientData.coords then
        local template = QuestRegistry.GetTemplate(questId)
        if template then
            for _, step in ipairs(template.steps) do
                if step.id == stepId and step.type == 'reach' and step.data and step.data.coords then
                    -- v0.7.0: 速度异常检测
                    local ped = GetPlayerPed(source)
                    local playerCoords = GetEntityCoords(ped)
                    if not QuestSecurity.CheckSpeedAnomaly(source, playerCoords) then
                        QuestDB.LogEvent(citizenid, questId, 'security_block', stepId,
                            { reason = 'speed_anomaly_blocked' })
                        return false, 'Movement speed anomaly detected'
                    end

                    local inRange, dist = QuestSecurity.CheckDistance(source, step.data.coords,
                        step.data.radius or Config.Quest.Security.MaxReachDistance)
                    if not inRange then
                        QuestDB.LogEvent(citizenid, questId, 'security_block', stepId,
                            { reason = 'distance_fail', distance = dist, required = step.data.radius })
                        return false, ('Too far from target (%.1fm away, max %.0fm)'):format(
                            dist, step.data.radius or Config.Quest.Security.MaxReachDistance)
                    end
                    break
                end
            end
        end
    end

    return true, nil
end

-- ==============================================================
-- 清理
-- ==============================================================

AddEventHandler('playerDropped', function()
    local src = source
    noncePool[src] = nil
    QuestSecurity._lastReachAttempt[src] = nil
    QuestSecurity._stepAttempts[src] = nil
end)

-- v0.7.0: 定期深度清理（每 5 分钟，不再每秒遍历）
CreateThread(function()
    while true do
        Wait(5 * 60 * 1000)
        local now = os.time()
        local cleanedSources = 0
        for src, pool in pairs(noncePool) do
            for token, expires in pairs(pool) do
                if now > expires then
                    pool[token] = nil
                end
            end
            if next(pool) == nil then
                noncePool[src] = nil
                cleanedSources = cleanedSources + 1
            end
        end

        -- 清理步骤尝试计数器
        for cid, attempts in pairs(QuestSecurity._stepAttempts) do
            if next(attempts) == nil then
                QuestSecurity._stepAttempts[cid] = nil
            end
        end
    end
end)

print('[quest-security] 🛡️ 任务安全守卫已加载 (v0.7.0)')
print('[quest-security]   六重防御: Nonce + RateLimit + GlobalBucket + StepOrder + SpeedCheck + DistanceCheck')