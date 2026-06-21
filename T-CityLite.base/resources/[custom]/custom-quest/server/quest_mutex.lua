-- ============================================================================
-- QuestMutex — 任务分布式排他锁服务 (v1.0.0)
-- ============================================================================
-- 设计目标:
--   彻底解决多玩家高并发争夺同一任务目标时的"双倍刷物资" Bug。
--   提供三种锁模式: solo / group / competitive
--
-- 模式说明:
--   - solo:        单人独占锁，防止同一玩家重复接取同一任务
--   - group:       组队共享锁，绑定 Mission_Instance_ID，允许多队员
--   - competitive: 争夺模式排他锁，第一个结算者加锁，后续请求即时驳回
--
-- 锁数据结构:
--   locks[lockKey] = {
--     owner = source,
--     mode = 'competitive',
--     lockedAt = os.time(),
--     instanceId = uuid,
--     members = { [source] = true }  -- group 模式
--   }
--
-- 自动过期:
--   锁超过 EXPIRE_MINUTES 分钟自动释放 (防止死锁)
-- ============================================================================

QuestMutex = QuestMutex or {}

-- ── 配置 ──────────────────────────────────────────────────────────────

QuestMutex.EXPIRE_MINUTES = 30       -- 锁自动过期时间
QuestMutex.CLEANUP_INTERVAL_MS = 120000  -- 清理间隔 (2分钟)

-- ── 内部状态 ──────────────────────────────────────────────────────────

local locks = {}

-- ── 内部: 生成锁键 ────────────────────────────────────────────────────

---生成唯一锁键
---@param questId string
---@param stepId string|nil 可选，为不同步骤独立加锁
---@return string lockKey
local function makeKey(questId, stepId)
    if stepId then
        return ('quest:%s:step:%s'):format(questId, stepId)
    end
    return ('quest:%s'):format(questId)
end

---生成唯一实例 ID
---@return string uuid
local function generateInstanceId()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return template:gsub('[xy]', function(c)
        local v = (c == 'x') and math.random(0, 15) or math.random(8, 11)
        return string.format('%x', v)
    end)
end

-- ── 内部: 过期清理 ────────────────────────────────────────────────────

local function cleanupExpiredLocks()
    local now = os.time()
    local expiredCount = 0
    for key, lock in pairs(locks) do
        if now - lock.lockedAt > QuestMutex.EXPIRE_MINUTES * 60 then
            locks[key] = nil
            expiredCount = expiredCount + 1
        end
    end
    if expiredCount > 0 then
        print(('[QuestMutex] Cleaned up %d expired locks'):format(expiredCount))
    end
end

-- ── 公开 API ──────────────────────────────────────────────────────────

---获取排他锁
---@param questId string 任务 ID
---@param playerSource number 玩家服务器 ID
---@param mode string 'solo' | 'group' | 'competitive'
---@param stepId string|nil 可选，为特定步骤加锁 (争夺模式通常锁定在 reward 步骤)
---@param memberSources table|nil group 模式下的队员 source 列表
---@return boolean acquired
---@return string|nil instanceId (group 模式下返回)
---@return string|nil rejectReason 被拒绝的原因
function QuestMutex.AcquireLock(questId, playerSource, mode, stepId, memberSources)
    mode = mode or 'solo'
    local lockKey = makeKey(questId, stepId)

    -- 过期清理 (惰性)
    local now = os.time()
    local existing = locks[lockKey]
    if existing and now - existing.lockedAt > QuestMutex.EXPIRE_MINUTES * 60 then
        locks[lockKey] = nil
        existing = nil
    end

    -- solo 模式: 该玩家是否已经持有此任务的锁
    if mode == 'solo' then
        -- solo 锁的键包含 source: quest:questId:src:source
        local soloKey = ('%s:src:%d'):format(lockKey, playerSource)
        if locks[soloKey] then
            return false, nil, 'You already have this quest locked'
        end
        locks[soloKey] = {
            owner = playerSource,
            mode = 'solo',
            lockedAt = now,
            instanceId = nil,
            members = { [playerSource] = true },
        }
        return true, nil, nil
    end

    -- competitive 模式: 第一个请求者获得锁
    if mode == 'competitive' then
        if existing then
            -- 锁已被他人持有
            if existing.owner ~= playerSource then
                return false, nil, 'Target已被其他人抢先完成'
            end
            -- 同一玩家重复请求 (幂等)
            return true, existing.instanceId, nil
        end
        local instanceId = generateInstanceId()
        locks[lockKey] = {
            owner = playerSource,
            mode = 'competitive',
            lockedAt = now,
            instanceId = instanceId,
            members = { [playerSource] = true },
        }
        return true, instanceId, nil
    end

    -- group 模式: 创建共享锁
    if mode == 'group' then
        if existing then
            -- 已有组队锁存在，检查是否已有队员
            return false, nil, 'Quest already has an active group'
        end
        local instanceId = generateInstanceId()
        local members = {}
        members[playerSource] = true
        if memberSources then
            for _, src in ipairs(memberSources) do
                members[src] = true
            end
        end
        locks[lockKey] = {
            owner = playerSource,
            mode = 'group',
            lockedAt = now,
            instanceId = instanceId,
            members = members,
        }
        return true, instanceId, nil
    end

    return false, nil, ('Unknown lock mode: %s'):format(tostring(mode))
end

---释放锁
---@param questId string
---@param playerSource number
---@param stepId string|nil
---@return boolean released
function QuestMutex.ReleaseLock(questId, playerSource, stepId)
    local lockKey = makeKey(questId, stepId)

    -- 检查 competitive/group 锁
    local existing = locks[lockKey]
    if existing and existing.owner == playerSource then
        locks[lockKey] = nil
        return true
    end

    -- 检查 solo 锁
    local soloKey = ('%s:src:%d'):format(lockKey, playerSource)
    if locks[soloKey] then
        locks[soloKey] = nil
        return true
    end

    return false
end

---检查锁状态
---@param questId string
---@param stepId string|nil
---@return boolean locked
---@return number|nil ownerSource
---@return string|nil mode
function QuestMutex.IsLocked(questId, stepId)
    local lockKey = makeKey(questId, stepId)
    local existing = locks[lockKey]
    if not existing then return false, nil, nil end

    -- 过期检查
    if os.time() - existing.lockedAt > QuestMutex.EXPIRE_MINUTES * 60 then
        locks[lockKey] = nil
        return false, nil, nil
    end

    return true, existing.owner, existing.mode
end

---获取锁的持有者
---@param questId string
---@param stepId string|nil
---@return number|nil ownerSource
function QuestMutex.GetLockOwner(questId, stepId)
    local locked, owner = QuestMutex.IsLocked(questId, stepId)
    if locked then return owner end
    return nil
end

---获取组队实例成员
---@param questId string
---@param instanceId string
---@return table|nil { [source] = true }
function QuestMutex.GetGroupMembers(questId, instanceId)
    for _, lock in pairs(locks) do
        if lock.instanceId == instanceId and lock.mode == 'group' then
            return lock.members
        end
    end
    return nil
end

---向组队实例添加成员
---@param questId string
---@param instanceId string
---@param playerSource number
---@return boolean added
function QuestMutex.AddGroupMember(questId, instanceId, playerSource)
    for _, lock in pairs(locks) do
        if lock.instanceId == instanceId and lock.mode == 'group' then
            lock.members[playerSource] = true
            return true
        end
    end
    return false
end

---从组队实例移除成员
---@param questId string
---@param instanceId string
---@param playerSource number
---@return boolean removed
function QuestMutex.RemoveGroupMember(questId, instanceId, playerSource)
    for _, lock in pairs(locks) do
        if lock.instanceId == instanceId and lock.mode == 'group' then
            lock.members[playerSource] = nil
            -- 如果队长离开，转移所有权或解散
            if lock.owner == playerSource then
                -- 找下一个人当队长
                local nextOwner = next(lock.members)
                if nextOwner then
                    lock.owner = nextOwner
                else
                    -- 无人了，释放锁
                    locks[questId] = nil
                end
            end
            return true
        end
    end
    return false
end

---获取锁的实例 ID
---@param questId string
---@param stepId string|nil
---@return string|nil instanceId
function QuestMutex.GetInstanceId(questId, stepId)
    local lockKey = makeKey(questId, stepId)
    local existing = locks[lockKey]
    if existing then return existing.instanceId end
    return nil
end

---获取当前活跃锁的总数 (监控用)
---@return number
function QuestMutex.GetActiveLockCount()
    local count = 0
    for _ in pairs(locks) do
        count = count + 1
    end
    return count
end

-- ── 定时清理 ──────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        Wait(QuestMutex.CLEANUP_INTERVAL_MS)
        cleanupExpiredLocks()
    end
end)

print('[quest-mutex] ✅ 任务分布式排他锁已加载 (v1.0.0)')
print(('[quest-mutex]   模式: solo / group / competitive | 过期: %d min'):format(QuestMutex.EXPIRE_MINUTES))
