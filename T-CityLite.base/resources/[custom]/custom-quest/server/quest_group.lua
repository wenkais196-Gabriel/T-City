-- ============================================================================
-- QuestGroup — 组队任务实例管理器 (v1.0.0)
-- ============================================================================
-- 职责:
--   1. 创建组队任务实例 — 绑定 leader + members + questId
--   2. 组员生命周期管理 — 加入/离开/踢出
--   3. 组队奖励批量结算 — 遍历所有队员，通过 RewardService 统一发放
--   4. 组队进度同步 — 广播步骤变更到所有队员客户端
--
-- 依赖: QuestMutex (底层锁)
--       RewardService (统一奖励网关)
-- ============================================================================

QuestGroup = QuestGroup or {}

local QBCore = exports['qb-core']:GetCoreObject()

-- ── 配置 ──────────────────────────────────────────────────────────────

QuestGroup.MAX_GROUP_SIZE = 6          -- 组队最大人数
QuestGroup.INVITE_TIMEOUT_SEC = 120    -- 邀请超时 (秒)

-- ── 内部状态 ──────────────────────────────────────────────────────────

-- 活跃的组队实例: { [instanceId] = { leader, members, questId, createdAt } }
local groups = {}

-- 待处理的邀请: { [inviteeSource] = { instanceId, questId, inviterSource, expiresAt } }
local pendingInvites = {}

-- ── 公开 API ──────────────────────────────────────────────────────────

---创建组队任务实例
---@param leaderSource number 队长 source
---@param questId string 任务 ID
---@param memberSources table|nil 初始队员 source 列表
---@return boolean success
---@return string|nil instanceId
---@return string|nil errorReason
function QuestGroup.CreateGroupInstance(leaderSource, questId, memberSources)
    -- 校验队长在线
    local leaderPlayer = QBCore.Functions.GetPlayer(leaderSource)
    if not leaderPlayer then
        return false, nil, 'Team leader not found'
    end

    -- 获取排他锁 (group 模式)
    local acquired, instanceId, rejectReason = QuestMutex.AcquireLock(
        questId, leaderSource, 'group', nil, memberSources
    )
    if not acquired then
        return false, nil, rejectReason or 'Failed to lock quest for group'
    end

    -- 构建队员表
    local members = {}
    members[leaderSource] = true

    if memberSources then
        for _, src in ipairs(memberSources) do
            if src ~= leaderSource then
                members[src] = true
            end
        end
    end

    -- 存储组队实例
    groups[instanceId] = {
        leader = leaderSource,
        members = members,
        questId = questId,
        createdAt = os.time(),
    }

    -- 通知所有队员
    for src in pairs(members) do
        if src ~= leaderSource then
            TriggerClientEvent('quest:client:groupJoined', src, {
                instanceId = instanceId,
                questId = questId,
                leader = leaderSource,
                members = QuestGroup.GetMemberList(instanceId),
            })
        end
    end

    print(('[QuestGroup] Group created: %s | quest=%s | leader=%d | members=%d')
        :format(instanceId, questId, leaderSource, #QuestGroup.GetMemberList(instanceId)))

    return true, instanceId, nil
end

---获取组队实例的成员列表 (source 数组)
---@param instanceId string
---@return table {source, ...}
function QuestGroup.GetMemberList(instanceId)
    local group = groups[instanceId]
    if not group then return {} end

    local list = {}
    for src in pairs(group.members) do
        list[#list + 1] = src
    end
    return list
end

---检查玩家是否为组员
---@param instanceId string
---@param playerSource number
---@return boolean
function QuestGroup.IsMember(instanceId, playerSource)
    local group = groups[instanceId]
    if not group then return false end
    return group.members[playerSource] == true
end

---检查玩家是否为队长
---@param instanceId string
---@param playerSource number
---@return boolean
function QuestGroup.IsLeader(instanceId, playerSource)
    local group = groups[instanceId]
    if not group then return false end
    return group.leader == playerSource
end

---添加队员 (队长操作)
---@param instanceId string
---@param leaderSource number 队长 (鉴权)
---@param newMemberSource number 新队员
---@return boolean
---@return string|nil error
function QuestGroup.AddMember(instanceId, leaderSource, newMemberSource)
    local group = groups[instanceId]
    if not group then return false, 'Group not found' end
    if group.leader ~= leaderSource then return false, 'Only the leader can add members' end

    local memberCount = 0
    for _ in pairs(group.members) do memberCount = memberCount + 1 end
    if memberCount >= QuestGroup.MAX_GROUP_SIZE then
        return false, ('Group is full (max %d)'):format(QuestGroup.MAX_GROUP_SIZE)
    end

    -- 检查新队员是否在线
    local player = QBCore.Functions.GetPlayer(newMemberSource)
    if not player then return false, 'Player not found' end

    group.members[newMemberSource] = true
    QuestMutex.AddGroupMember(group.questId, instanceId, newMemberSource)

    -- 通知新队员
    TriggerClientEvent('quest:client:groupJoined', newMemberSource, {
        instanceId = instanceId,
        questId = group.questId,
        leader = group.leader,
        members = QuestGroup.GetMemberList(instanceId),
    })

    -- 通知全队
    QuestGroup.BroadcastToGroup(instanceId, 'quest:client:groupUpdated', {
        instanceId = instanceId,
        members = QuestGroup.GetMemberList(instanceId),
        action = 'member_added',
        newMember = newMemberSource,
    })

    return true, nil
end

---移除队员 (队长操作 或 队员自己离开)
---@param instanceId string
---@param operatorSource number 操作者
---@param targetSource number 被移除的队员
---@return boolean
---@return string|nil error
function QuestGroup.RemoveMember(instanceId, operatorSource, targetSource)
    local group = groups[instanceId]
    if not group then return false, 'Group not found' end

    -- 鉴权：只有队长可以踢人，或者队员自己离开
    if operatorSource ~= group.leader and operatorSource ~= targetSource then
        return false, 'Only the leader can remove members'
    end

    -- 队长不能离开 (除非解散)
    if targetSource == group.leader then
        return QuestGroup.DisbandGroup(instanceId, 'leader_left')
    end

    group.members[targetSource] = nil
    QuestMutex.RemoveGroupMember(group.questId, instanceId, targetSource)

    -- 通知被移除的队员
    local player = QBCore.Functions.GetPlayer(targetSource)
    if player then
        TriggerClientEvent('quest:client:groupLeft', targetSource, {
            instanceId = instanceId,
            reason = 'removed',
        })
    end

    -- 通知全队
    QuestGroup.BroadcastToGroup(instanceId, 'quest:client:groupUpdated', {
        instanceId = instanceId,
        members = QuestGroup.GetMemberList(instanceId),
        action = 'member_removed',
        removedMember = targetSource,
    })

    return true, nil
end

---解散组队
---@param instanceId string
---@param reason string
---@return boolean
function QuestGroup.DisbandGroup(instanceId, reason)
    local group = groups[instanceId]
    if not group then return false end

    -- 释放锁
    QuestMutex.ReleaseLock(group.questId, group.leader)

    -- 通知全队
    QuestGroup.BroadcastToGroup(instanceId, 'quest:client:groupDisbanded', {
        instanceId = instanceId,
        questId = group.questId,
        reason = reason or 'disbanded',
    })

    groups[instanceId] = nil
    print(('[QuestGroup] Group disbanded: %s (reason: %s)'):format(instanceId, reason))
    return true
end

---获取组队实例信息
---@param instanceId string
---@return table|nil {leader, members, questId, createdAt}
function QuestGroup.GetGroupInfo(instanceId)
    return groups[instanceId]
end

---向组队所有成员广播客户端事件
---@param instanceId string
---@param eventName string
---@param data any
function QuestGroup.BroadcastToGroup(instanceId, eventName, data)
    local group = groups[instanceId]
    if not group then return end

    for src in pairs(group.members) do
        TriggerClientEvent(eventName, src, data)
    end
end

---批量结算组队奖励 — 遍历所有队员，通过 RewardService 统一发放
---@param instanceId string
---@param questId string
---@param rewards table 奖励配置
---@return number memberCount 实际发放人数
function QuestGroup.GrantGroupRewards(instanceId, questId, rewards)
    local group = groups[instanceId]
    if not group then return 0 end

    -- 💰 统一经济网关: 优先走 core_economy
    local count = 0
    for src in pairs(group.members) do
        local Player = QBCore.Functions.GetPlayer(src)
        if Player then
            if GetResourceState('core_economy') == 'started' then
                exports['core_economy']:TriggerReward(src, ('quest:%s:group'):format(questId), rewards, { skipHeat = false })
            else
                QuestRewards.GrantRewards(src, rewards, questId)
            end
            count = count + 1
        end
    end

    return count
end

---检查玩家是否已在某个组队中
---@param playerSource number
---@return string|nil instanceId
function QuestGroup.FindPlayerGroup(playerSource)
    for instanceId, group in pairs(groups) do
        if group.members[playerSource] then
            return instanceId
        end
    end
    return nil
end

print('[quest-group] ✅ 组队任务实例管理器已加载 (v1.0.0)')
print(('[quest-group]   最大组队人数: %d | 邀请超时: %d秒'):format(QuestGroup.MAX_GROUP_SIZE, QuestGroup.INVITE_TIMEOUT_SEC))
