-- quest_entity_registry.lua — 任务实体注册表 + 延迟回收策略 (v0.10)
--
-- 职责:
--   1. 注册任务中生成的所有实体 (载具、挂车、道具prop)
--   2. 按回收策略延迟删除实体 (提升扮演质量 — 玩家走后才消失)
--   3. 任务完成/失败时强制清空所有残留实体
--
-- 回收策略 (recycle_policy):
--   'on_leave'     — 监控玩家距离，>leave_radius 时删除 (最长等 force_after_sec)
--   'on_complete'  — 任务完成时删除
--   'immediate'    — 标记后下一帧立即删除
--   'timed'        — 固定 delay_sec 秒后删除
--
-- 使用方式:
--   生成实体后:  QuestEntityRegistry.Register(citizenid, questId, entityType, netId, policy)
--   到达回收步骤: QuestEntityRegistry.ScheduleRecycle(citizenid, questId, entityType)
--   任务结束:      QuestEntityRegistry.ForceRecycleAll(citizenid, questId)

local QBCore = exports['qb-core']:GetCoreObject()

QuestEntityRegistry = {}

-- v0.10: 前向声明 — local function 在文件尾部定义，
-- 但公开 API 在前半部分就引用了它们，必须先声明为 local
local _getEntity, _findSource, _doRecycle
local _startLeaveMonitor, _startTimedRecycle, _cancelMonitor

-- ══════════════════════════════════════════════════════════════
-- 内部状态
-- ══════════════════════════════════════════════════════════════

---@class QuestEntity
---@field netId number         网络 ID
---@field entityType string    类型标识 (trailer / truck / prop)
---@field model string         模型名
---@field recyclePolicy string 回收策略
---@field leaveRadius number   玩家远离半径 (仅 on_leave)
---@field forceAfterSec number 强制回收秒数 (仅 on_leave / timed)
---@field delaySec number      固定延迟秒数 (仅 timed)
---@field scheduled boolean    是否已调度回收
---@field recycled boolean     是否已回收

-- citizenid → questId → { [entityType] = QuestEntity, ... }
local _registry = {}

-- 活跃的回收监控线程 (citizenid_questId_entityType → timerRef)
local _recycleTimers = {}

-- ══════════════════════════════════════════════════════════════
-- 公开 API
-- ══════════════════════════════════════════════════════════════

--- 注册一个任务实体
---@param citizenid string
---@param questId string
---@param entityType string   实体类型标识 (如 'trailer', 'truck')
---@param netId number        网络 ID
---@param opts table|nil      { model, recyclePolicy, leaveRadius, forceAfterSec, delaySec }
function QuestEntityRegistry.Register(citizenid, questId, entityType, netId, opts)
    if not citizenid or not questId or not entityType or not netId then return end

    if not _registry[citizenid] then
        _registry[citizenid] = {}
    end
    if not _registry[citizenid][questId] then
        _registry[citizenid][questId] = {}
    end

    opts = opts or {}
    _registry[citizenid][questId][entityType] = {
        netId = netId,
        entityType = entityType,
        model = opts.model or 'unknown',
        recyclePolicy = opts.recyclePolicy or 'on_quest_end',
        leaveRadius = opts.leaveRadius or 50.0,
        forceAfterSec = opts.forceAfterSec or 60,
        delaySec = opts.delaySec or 30,
        scheduled = false,
        recycled = false,
    }

    print(('[entity-registry] 📋 Registered: %s | %s | %s | netId=%d | policy=%s'):format(
        citizenid, questId, entityType, netId, opts.recyclePolicy or 'on_quest_end'))
end

--- 标记实体为"已挂接" (用于 trailer 等需要区分状态的实体)
---@param citizenid string
---@param questId string
---@param entityType string
---@param hitched boolean
function QuestEntityRegistry.MarkHitched(citizenid, questId, entityType, hitched)
    local ent = _getEntity(citizenid, questId, entityType)
    if ent then
        ent.hitched = hitched
    end
end

--- 调度回收 — 按实体的 recyclePolicy 启动延迟删除
---@param citizenid string
---@param questId string
---@param entityType string
function QuestEntityRegistry.ScheduleRecycle(citizenid, questId, entityType)
    local ent = _getEntity(citizenid, questId, entityType)
    if not ent then
        print(('[entity-registry] ⚠️ ScheduleRecycle: entity not found: %s | %s | %s'):format(
            citizenid, questId, entityType))
        return
    end

    if ent.recycled then return end
    ent.scheduled = true

    local policy = ent.recyclePolicy
    print(('[entity-registry] ♻️ Scheduling recycle: %s | %s | %s | policy=%s'):format(
        citizenid, questId, entityType, policy))

    if policy == 'immediate' then
        _doRecycle(citizenid, questId, entityType, ent)
    elseif policy == 'on_leave' then
        _startLeaveMonitor(citizenid, questId, entityType, ent)
    elseif policy == 'timed' then
        _startTimedRecycle(citizenid, questId, entityType, ent)
    elseif policy == 'on_complete' or policy == 'on_quest_end' then
        -- 不立即回收，等 ForceRecycleAll
    end
end

--- 强制回收指定 quest 的所有实体 (任务完成/失败/放弃时调用)
---@param citizenid string
---@param questId string
function QuestEntityRegistry.ForceRecycleAll(citizenid, questId)
    local questEnts = _registry[citizenid] and _registry[citizenid][questId]
    if not questEnts then return end

    print(('[entity-registry] 🧹 ForceRecycleAll: %s | %s'):format(citizenid, questId))

    for entityType, ent in pairs(questEnts) do
        if not ent.recycled then
            _cancelMonitor(citizenid, questId, entityType)
            _doRecycle(citizenid, questId, entityType, ent)
        end
    end

    _registry[citizenid][questId] = nil
end

--- 获取注册的实体 netId
---@param citizenid string
---@param questId string
---@param entityType string
---@return number|nil
function QuestEntityRegistry.GetNetId(citizenid, questId, entityType)
    local ent = _getEntity(citizenid, questId, entityType)
    return ent and ent.netId or nil
end

--- 检查实体是否已回收
---@param citizenid string
---@param questId string
---@param entityType string
---@return boolean
function QuestEntityRegistry.IsRecycled(citizenid, questId, entityType)
    local ent = _getEntity(citizenid, questId, entityType)
    if not ent then return true end  -- 未注册视为已回收
    return ent.recycled == true
end

--- 获取注册表 (用于外部遍历)
---@param citizenid string
---@param questId string
---@return table|nil
function QuestEntityRegistry.GetAll(citizenid, questId)
    return _registry[citizenid] and _registry[citizenid][questId]
end

-- ══════════════════════════════════════════════════════════════
-- 内部函数
-- ══════════════════════════════════════════════════════════════

_getEntity = function(citizenid, questId, entityType)
    return _registry[citizenid] and _registry[citizenid][questId] and _registry[citizenid][questId][entityType]
end

--- 通过 citizenid 查找在线玩家的 source
_findSource = function(citizenid)
    for _, pId in ipairs(GetPlayers()) do
        local Player = QBCore.Functions.GetPlayer(tonumber(pId))
        if Player and Player.PlayerData.citizenid == citizenid then
            return tonumber(pId)
        end
    end
    return nil
end

--- 执行实体删除
_doRecycle = function(citizenid, questId, entityType, ent)
    if ent.recycled then return end
    ent.recycled = true

    local trailer = NetworkGetEntityFromNetworkId(ent.netId)
    if trailer and trailer ~= 0 and DoesEntityExist(trailer) then
        -- 先解冻再删除
        FreezeEntityPosition(trailer, false)
        SetEntityInvincible(trailer, false)
        DeleteEntity(trailer)
        print(('[entity-registry] 🗑️ Recycled: %s | %s | %s | netId=%d'):format(
            citizenid, questId, entityType, ent.netId))
    else
        print(('[entity-registry] ⚠️ Recycled (entity already gone): %s | %s | %s | netId=%d'):format(
            citizenid, questId, entityType, ent.netId))
    end

    -- 通知客户端清理本地引用 + blip
    local src = _findSource(citizenid)
    if src then
        TriggerClientEvent('quest:client:entityRecycled', src, {
            questId = questId,
            entityType = entityType,
            netId = ent.netId,
        })
    end
end

--- 启动 'on_leave' 监控 — 轮询玩家距离
_startLeaveMonitor = function(citizenid, questId, entityType, ent)
    local timerKey = ('%s_%s_%s'):format(citizenid, questId, entityType)
    _cancelMonitor(citizenid, questId, entityType)

    local checkIntervalMs = 3000
    local maxChecks = math.ceil((ent.forceAfterSec or 60) * 1000 / checkIntervalMs)
    local checksDone = 0

    _recycleTimers[timerKey] = {
        timer = nil,
        active = true,
    }

    -- 使用递归 SetTimeout 模拟可取消的间隔
    local function check()
        if not _recycleTimers[timerKey] or not _recycleTimers[timerKey].active then return end
        if ent.recycled then return end

        checksDone = checksDone + 1
        local src = _findSource(citizenid)

        -- 玩家离线 → 立即回收
        if not src then
            _doRecycle(citizenid, questId, entityType, ent)
            _recycleTimers[timerKey] = nil
            return
        end

        -- 检查玩家距离
        local ped = GetPlayerPed(src)
        local playerCoords = GetEntityCoords(ped)
        local entity = NetworkGetEntityFromNetworkId(ent.netId)

        local shouldRecycle = false
        local reason = ''

        if not entity or entity == 0 or not DoesEntityExist(entity) then
            shouldRecycle = true
            reason = 'entity_gone'
        elseif checksDone >= maxChecks then
            shouldRecycle = true
            reason = 'force_timeout'
        else
            local entityCoords = GetEntityCoords(entity)
            local dist = #(playerCoords - entityCoords)
            if dist > ent.leaveRadius then
                shouldRecycle = true
                reason = ('player_left (%.0fm > %.0fm)'):format(dist, ent.leaveRadius)
            end
        end

        if shouldRecycle then
            print(('[entity-registry] ♻️ on_leave trigger: %s | %s | %s | reason=%s | checks=%d'):format(
                citizenid, questId, entityType, reason, checksDone))
            _doRecycle(citizenid, questId, entityType, ent)
            _recycleTimers[timerKey] = nil
        else
            -- 继续轮询
            _recycleTimers[timerKey].timer = SetTimeout(checkIntervalMs, check)
        end
    end

    _recycleTimers[timerKey].timer = SetTimeout(checkIntervalMs, check)
end

--- 启动 'timed' 固定延迟回收
_startTimedRecycle = function(citizenid, questId, entityType, ent)
    local timerKey = ('%s_%s_%s'):format(citizenid, questId, entityType)
    _cancelMonitor(citizenid, questId, entityType)

    local delayMs = (ent.delaySec or 30) * 1000

    _recycleTimers[timerKey] = {
        timer = SetTimeout(delayMs, function()
            if ent.recycled then return end
            _doRecycle(citizenid, questId, entityType, ent)
            _recycleTimers[timerKey] = nil
        end),
        active = true,
    }
end

--- 取消活跃的监控定时器
_cancelMonitor = function(citizenid, questId, entityType)
    local timerKey = ('%s_%s_%s'):format(citizenid, questId, entityType)
    local ref = _recycleTimers[timerKey]
    if ref then
        ref.active = false
        -- SetTimeout 无法真正取消，但 active=false 会让回调跳过
        _recycleTimers[timerKey] = nil
    end
end

-- ══════════════════════════════════════════════════════════════
-- 事件: 任务完成/失败/放弃 → 强制清空
-- ══════════════════════════════════════════════════════════════

AddEventHandler('quest:server:onQuestCompleted', function(citizenid, questId)
    -- 延迟 2 秒再清理 (让客户端完成动画/通知先显示)
    SetTimeout(2000, function()
        QuestEntityRegistry.ForceRecycleAll(citizenid, questId)
    end)
end)

AddEventHandler('quest:server:onQuestFailed', function(citizenid, questId, reason)
    QuestEntityRegistry.ForceRecycleAll(citizenid, questId)
end)

-- v0.10: 玩家断线 → 清理所有该玩家的实体
AddEventHandler('playerDropped', function(reason)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    if _registry[citizenid] then
        for questId, _ in pairs(_registry[citizenid]) do
            QuestEntityRegistry.ForceRecycleAll(citizenid, questId)
        end
        _registry[citizenid] = nil
    end
end)

-- v0.10: 服务端实体回收通知——客户端清理本地引用
RegisterNetEvent('quest:server:entityRecycled', function(questId, entityType)
    -- 此事件由服务端内部调用，不是客户端上报
end)

print('[quest-entity-registry] ✅ v0.10: 实体注册表 + 延迟回收策略 (on_leave/timed/immediate/on_complete) 已就绪')
