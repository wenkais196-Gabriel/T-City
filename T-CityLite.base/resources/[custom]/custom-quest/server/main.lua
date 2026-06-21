-- main.lua — custom-quest 服务端入口  v0.7.0
--
-- 职责:
--   1. 自动加载任务模板（QuestRegistry.AutoLoad）
--   2. 注册核心事件处理器（accept / abandon / reach / collect / requestState / requestNonce）
--   3. 注册所有 Exports（11 个: 9 original + 2 new）
--   4. 注册到 core-framework Bus（如果可用）
--
-- 事件流:
--   quest:server:accept     → QuestManager.TriggerQuest
--   quest:server:abandon    → QuestManager.AbandonQuest
--   quest:server:reach      → QuestSecurity.ValidateClientEvent → QuestManager.AdvanceStep
--   quest:server:collect    → QuestSecurity.ValidateClientEvent → 服务端扣物品 → AdvanceStep  ★ v0.7.0
--   quest:server:requestState → 推送当前任务状态给客户端                ★ v0.7.0
--   quest:server:requestNonce → 返回 Nonce Token                      ★ v0.7.0

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 初始化
-- ==============================================================

-- 自动加载内置任务模板
QuestRegistry.AutoLoad()

-- ==============================================================
-- 事件: 接取任务
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_ACCEPT, function(questId)
    local src = source

    -- 安全校验
    if not Config.Quest.Enabled then
        TriggerClientEvent('QBCore:Notify', src, 'Quest system is disabled', 'error')
        return
    end

    -- Rate Limit 检查
    if not QuestSecurity.CheckRateLimit(src, 'accept') then
        TriggerClientEvent('QBCore:Notify', src, 'Please wait before accepting another quest', 'error')
        return
    end

    local success, message = QuestManager.TriggerQuest(src, questId)
    if success then
        TriggerClientEvent('QBCore:Notify', src, message, 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, message, 'error')
    end
end)

-- ==============================================================
-- 事件: 放弃任务
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_ABANDON, function(questId)
    local src = source

    if not QuestSecurity.CheckRateLimit(src, 'abandon') then
        return
    end

    local success, message = QuestManager.AbandonQuest(src, questId)
    if success then
        TriggerClientEvent('QBCore:Notify', src, message, 'primary')
    end
end)

-- ==============================================================
-- 事件: 到达目标位置（reach 步骤完成）
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_REACH, function(questId, stepId, nonceToken)
    local src = source

    -- v0.7.0: 传入客户端坐标用于速度检测
    local ped = GetPlayerPed(src)
    local coords = ped ~= 0 and GetEntityCoords(ped)
    local clientData = coords and { coords = coords } or nil

    -- 全量安全校验
    local ok, err = QuestSecurity.ValidateClientEvent(src, questId, stepId, nonceToken, clientData)
    if not ok then
        if exports['custom-logs'] then
            local Player = QBCore.Functions.GetPlayer(src)
            local cid = Player and Player.PlayerData.citizenid or 'unknown'
            exports['custom-logs']:LogSecurity('任务作弊拦截',
                ('**%s** (%s) | Quest: %s | Step: %s | Reason: %s'):format(
                    GetPlayerName(src), cid, questId, stepId, err or 'unknown'
                ), 16711680)
        end
        return
    end

    -- 推进步骤
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local success, message = QuestManager.AdvanceStep(
        Player.PlayerData.citizenid,
        questId, stepId
    )

    if not success then
        TriggerClientEvent('QBCore:Notify', src, message, 'error')
    end
end)

-- ==============================================================
-- v1.0.0: 事件: 原子节点完成 (NodeEngine 统一入口)
-- INTERACT / DELIVER / COMBAT / WAIT 节点均由客户端主动上报此事件
-- ==============================================================

RegisterNetEvent('quest:server:nodeComplete', function(questId, stepId, nodeType, clientData)
    local src = source
    print(('[custom-quest] 📥 nodeComplete: src=%d, quest=%s, step=%s, nodeType=%s'):format(
        src, questId, stepId, nodeType))

    -- 安全校验（v0.7.2: nonceToken=true 表示跳过 Nonce，nodeComplete 有自身校验层）
    local ok, err = QuestSecurity.ValidateClientEvent(src, questId, stepId, true)
    if not ok then
        -- v0.8b: 增强诊断 — 打印安全层失败详情 + 活跃任务缓存状态
        local Player = QBCore.Functions.GetPlayer(src)
        local citizenid = Player and Player.PlayerData.citizenid or 'unknown'
        local cached = QuestCache.GetActiveQuests(citizenid)
        local expectedStep = '?'
        if cached then
            for _, q in ipairs(cached) do
                if q.quest_id == questId then expectedStep = q.current_step or 'nil' end
            end
        end
        print(('[custom-quest] 🔒 SECURITY BLOCK: src=%d, cid=%s, quest=%s, claimed_step=%s, expected_step=%s, reason=%s, cache=%s'):format(
            src, citizenid, questId, stepId, expectedStep, err or 'unknown',
            cached and ('%d entries'):format(#cached) or 'nil'))
        if exports['custom-logs'] then
            local Player = QBCore.Functions.GetPlayer(src)
            local cid = Player and Player.PlayerData.citizenid or 'unknown'
            exports['custom-logs']:LogSecurity('任务作弊拦截-NodeComplete',
                ('**%s** (%s) | Quest: %s | Step: %s | Node: %s | Reason: %s'):format(
                    GetPlayerName(src), cid, questId, stepId, nodeType, err or 'unknown'
                ), 16711680)
        end
        TriggerClientEvent('QBCore:Notify', src, 'Node validation failed', 'error')
        return
    end

    -- 竞争模式排他锁检查 (第一个结算者加锁，后续驳回)
    local template = QuestRegistry.GetTemplate(questId)
    if template and template.mode == 'competitive' then
        local locked, owner = QuestMutex.IsLocked(questId, stepId)
        if locked and owner ~= src then
            TriggerClientEvent('QBCore:Notify', src, '目标已被其他人抢先完成', 'error')
            return
        end
        -- 首次完成者加锁
        if not locked then
            QuestMutex.AcquireLock(questId, src, 'competitive', stepId)
        end
    end

    -- NodeEngine 服务端验证
    clientData = clientData or {}
    clientData.nodeType = nodeType  -- v0.7.2: ValidateNode 需要 clientData.nodeType
    print(('[custom-quest] 🔍 ValidateNode: src=%d, quest=%s, step=%s, nodeType=%s, QN=%s, fn=%s'):format(
        src, questId, stepId, nodeType, type(QuestNodes), type(QuestNodes and QuestNodes.ValidateNode)))
    local valid, validateErr = QuestNodes.ValidateNode(src, questId, stepId, clientData)
    print(('[custom-quest] 🔍 ValidateNode result: valid=%s, err=%s'):format(tostring(valid), tostring(validateErr)))
    if not valid then
        TriggerClientEvent('QBCore:Notify', src, validateErr or 'Node validation failed', 'error')
        return
    end

    -- 推进步骤
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local success, message = QuestManager.AdvanceStep(
        Player.PlayerData.citizenid,
        questId, stepId, clientData
    )

    if not success then
        TriggerClientEvent('QBCore:Notify', src, message, 'error')
    end
end)

-- ==============================================================
-- v0.7.0: 事件: 收集物品（collect 步骤完成）
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_COLLECT, function(questId, stepId, nonceToken)
    local src = source

    -- 1. 安全校验
    local ok, err = QuestSecurity.ValidateClientEvent(src, questId, stepId, nonceToken)
    if not ok then return end

    -- 2. 获取步骤配置
    local template = QuestRegistry.GetTemplate(questId)
    local step = QuestRegistry.GetStep(template, stepId)
    if not step or not step.data or not step.data.items then
        TriggerClientEvent('QBCore:Notify', src, 'Invalid collect step configuration', 'error')
        return
    end

    -- 3. 服务端权威检查背包
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local requiredItems = step.data.items
    local consumeItems = step.data.consume ~= false -- 默认消耗物品

    for _, itemReq in ipairs(requiredItems) do
        if itemReq.name then
            local requiredCount = tonumber(itemReq.count) or 1
            local hasCount = 0
            if exports['qb-inventory'] and exports['qb-inventory'].GetItemCount then
                hasCount = exports['qb-inventory']:GetItemCount(src, itemReq.name)
            else
                -- fallback: 通过 Player.Functions.HasItem
                local items = Player.PlayerData.items or {}
                for _, invItem in ipairs(items) do
                    if invItem.name == itemReq.name then
                        hasCount = hasCount + (invItem.amount or 1)
                    end
                end
            end

            if hasCount < requiredCount then
                TriggerClientEvent('QBCore:Notify', src,
                    ('Need %d x %s (you have %d)'):format(requiredCount, itemReq.name, hasCount), 'error')
                return
            end
        end
    end

    -- 4. 扣除物品
    if consumeItems then
        for _, itemReq in ipairs(requiredItems) do
            if itemReq.name then
                local requiredCount = tonumber(itemReq.count) or 1
                if exports['qb-inventory'] and exports['qb-inventory'].RemoveItem then
                    exports['qb-inventory']:RemoveItem(src, itemReq.name, requiredCount)
                else
                    Player.Functions.RemoveItem(itemReq.name, requiredCount)
                end
            end
        end
    end

    -- 5. 推进步骤
    local success, message = QuestManager.AdvanceStep(
        Player.PlayerData.citizenid,
        questId, stepId
    )

    if not success then
        TriggerClientEvent('QBCore:Notify', src, message, 'error')
    end
end)

-- ==============================================================
-- v0.7.0: 事件: 请求任务状态恢复（客户端重连）
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_REQUEST_STATE, function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    local activeQuests = QuestManager.GetActiveQuests(src)

    if activeQuests and #activeQuests > 0 then
        -- 只推送第一个活跃任务（大多数玩家同时只做 1 个任务）
        local quest = activeQuests[1]
        local template = QuestRegistry.GetTemplate(quest.quest_id)
        if template then
            TriggerClientEvent(Config.Quest.Events.QUEST_STATE_RESTORE, src, {
                quest_id = quest.quest_id,
                title = template.title,
                description = template.description,
                steps = template.steps,
                current_step = quest.current_step,
                progress_data = quest.progress_data,
            })
        end
    end
end)

-- ==============================================================
-- v0.7.0: 回调: 请求 Nonce Token（客户端用）
-- ==============================================================

QBCore.Functions.CreateCallback(Config.Quest.Events.QUEST_REQUEST_NONCE, function(source, cb)
    local nonce = QuestSecurity.GenerateNonce(source)
    cb(nonce)
end)

-- ==============================================================
-- Exports
-- ==============================================================

-- 1. 接取任务
exports('TriggerQuest', function(source, questId)
    return QuestManager.TriggerQuest(source, questId)
end)

-- 2. 通用事件桥（外部脚本广播自定义事件）
-- v0.7.0: 优先使用 eventIndex 反向索引 (O(1))，fallback 到全量遍历
exports('OnCustomEvent', function(source, eventName, data)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid
    -- v0.7.0: 优先使用反向索引
    local indexed = QuestCache.LookupEvent(eventName, citizenid)
    if indexed then
        local template = QuestRegistry.GetTemplate(indexed.quest_id)
        if template then
            for _, step in ipairs(template.steps) do
                if step.id == indexed.step_id and step.data then
                    -- 检查 match 条件
                    local match = step.data.match
                    if match then
                        local matched = true
                        for key, val in pairs(match) do
                            if data[key] ~= val then
                                matched = false
                                break
                            end
                        end
                        if matched then
                            -- 累加进度
                            local progressKey = step.data.progress_key or 'count'

                            local progressData = {}
                            QuestDB.GetQuestProgress(citizenid, indexed.quest_id, function(row)
                                if row and row.progress_data then
                                    local pd = row.progress_data
                                    if type(pd) == 'string' then pd = json.decode(pd) or {} end
                                    local currentCount = (pd[progressKey] or 0) + 1
                                    pd[progressKey] = currentCount

                                    local required = step.data.required_count or 1
                                    if currentCount >= required then
                                        QuestManager.AdvanceStep(citizenid, indexed.quest_id, step.id, pd)
                                    else
                                        QuestDB.UpdateProgress(citizenid, indexed.quest_id, step.id, json.encode(pd))
                                        TriggerClientEvent(Config.Quest.Events.QUEST_PROGRESS, source, {
                                            quest_id = indexed.quest_id,
                                            step_id = step.id,
                                            progress = currentCount,
                                            required = required,
                                        })
                                    end
                                end
                            end)
                            return
                        end
                    else
                        -- v0.10: 无 match 条件的 custom_event — 直接推进（如 trailer_hooked）
                        QuestManager.AdvanceStep(citizenid, indexed.quest_id, step.id, data)
                        return
                    end
                end
            end
        end
    end

    -- fallback: 全量遍历（兼容未建立索引的旧逻辑）
    local activeQuests = QuestCache.GetActiveQuests(citizenid, function(cid)
        local result = {}
        QuestDB.GetActiveQuests(cid, function(rows)
            result = rows or {}
        end)
        return result
    end)

    if not activeQuests then return end

    for _, activeQuest in ipairs(activeQuests) do
        local template = QuestRegistry.GetTemplate(activeQuest.quest_id)
        if template then
            for _, step in ipairs(template.steps) do
                if step.id == activeQuest.current_step
                    and step.type == 'custom_event'
                    and step.data
                    and step.data.event_name == eventName then

                    local match = step.data.match
                    if match then
                        local matched = true
                        for key, val in pairs(match) do
                            if data[key] ~= val then
                                matched = false
                                break
                            end
                        end
                        if not matched then goto continue_step end
                    end

                    local progressKey = step.data.progress_key or 'count'

                    local progressData = activeQuest.progress_data
                    if type(progressData) == 'string' then
                        progressData = json.decode(progressData) or {}
                    end
                    local currentCount = (progressData[progressKey] or 0) + 1
                    progressData[progressKey] = currentCount

                    local required = step.data.required_count or 1
                    if currentCount >= required then
                        QuestManager.AdvanceStep(citizenid, activeQuest.quest_id, step.id, progressData)
                    else
                        QuestDB.UpdateProgress(citizenid, activeQuest.quest_id, step.id, json.encode(progressData))
                        TriggerClientEvent(Config.Quest.Events.QUEST_PROGRESS, source, {
                            quest_id = activeQuest.quest_id,
                            step_id = step.id,
                            progress = currentCount,
                            required = required,
                        })
                    end

                    ::continue_step::
                end
            end
        end
    end
end)

-- 3. 直接完成某一步
exports('CompleteStep', function(source, questId, stepId)
    return QuestManager.CompleteStep(source, questId, stepId)
end)

-- 4. 注册步骤校验器
exports('RegisterStepValidator', function(validatorId, validatorFn)
    return QuestValidators.Register(validatorId, validatorFn)
end)

-- 5. 强制失败
exports('FailQuest', function(source, questId, reason)
    return QuestManager.FailQuest(source, questId, reason or 'unknown')
end)

-- 6. 查询活跃任务
exports('GetActiveQuests', function(source)
    return QuestManager.GetActiveQuests(source)
end)

-- 7. 查询任务进度
exports('GetQuestProgress', function(source, questId)
    return QuestManager.GetQuestProgress(source, questId)
end)

-- 8. 生成 Nonce Token（供客户端调用）
exports('GenerateNonce', function(source)
    return QuestSecurity.GenerateNonce(source)
end)

-- 9. 获取分类任务列表（供手机 UI 使用）
exports('GetQuestCatalog', function()
    return QuestRegistry.GetCategorizedList()
end)

-- 10. v0.7.0: 检查指定任务是否活跃
exports('IsQuestActive', function(source, questId)
    return QuestManager.IsQuestActive(source, questId)
end)

-- 11. v0.7.0: 获取指定任务的当前步骤
exports('GetQuestStep', function(source, questId)
    return QuestManager.GetQuestStep(source, questId)
end)

-- ==============================================================
-- 注册到 Bus（如果 core-framework 可用）
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('quest', {
        TriggerQuest      = QuestManager.TriggerQuest,
        CompleteStep      = QuestManager.CompleteStep,
        FailQuest         = QuestManager.FailQuest,
        AbandonQuest      = QuestManager.AbandonQuest,
        GetActiveQuests   = QuestManager.GetActiveQuests,
        GetQuestProgress  = QuestManager.GetQuestProgress,
        IsQuestActive     = QuestManager.IsQuestActive,      -- v0.7.0
        GetQuestStep      = QuestManager.GetQuestStep,       -- v0.7.0
        GenerateNonce     = QuestSecurity.GenerateNonce,
        RegisterValidator = QuestValidators.Register,
        GetCatalog        = QuestRegistry.GetCategorizedList,
    })
end

-- ==============================================================
-- v0.7.1: 飞行高度监控完成事件
-- ==============================================================

RegisterNetEvent('quest:server:aviationHeightMonitorComplete', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 广播 aviation_height_monitor custom_event 给任务系统
    exports['custom-quest']:OnCustomEvent(src, 'aviation_height_monitor', {
        completed = true,
        timestamp = os.time(),
    })
end)

-- ==============================================================
-- v0.9: 挂车生命周期追踪 — netId registry + hitched 标记 + cleanup
-- ==============================================================

---@class TrailerRecord
---@field netId number      挂车网络 ID
---@field hitched boolean   是否已被玩家挂接

-- citizenid → questId → TrailerRecord
local TrailerTracker = {}

--- 客户端生成 trailer 后上报，服务端记录
--- v0.10: 同时注册到 QuestEntityRegistry 以支持延迟回收
RegisterNetEvent('quest:server:registerTrailer', function(questId, trailerNetId, trailerModel)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid

    if not TrailerTracker[citizenid] then
        TrailerTracker[citizenid] = {}
    end
    TrailerTracker[citizenid][questId] = {
        netId = trailerNetId,
        hitched = false,
    }

    -- v0.10: 注册到实体注册表 (延迟回收: 玩家离开 50m 后或 60s 超时)
    QuestEntityRegistry.Register(citizenid, questId, 'trailer', trailerNetId, {
        model = trailerModel or 'unknown',
        recyclePolicy = 'on_leave',
        leaveRadius = 50.0,
        forceAfterSec = 60,
    })

    print(('[trailer-tracker] 📋 registered: %s | %s | netId=%d | model=%s'):format(
        citizenid, questId, trailerNetId, trailerModel or 'unknown'))
end)

--- v0.10: 清理指定玩家的所有 trailer（包括已挂接和未挂接）
--- 委托给 QuestEntityRegistry.ForceRecycleAll 统一处理
local function CleanupAllTrailers(citizenid)
    local records = TrailerTracker[citizenid]
    if not records then return end

    for questId, _ in pairs(records) do
        QuestEntityRegistry.ForceRecycleAll(citizenid, questId)
    end
    TrailerTracker[citizenid] = nil

    -- 兜底: 通知客户端清理残留
    local src = nil
    for _, pId in ipairs(GetPlayers()) do
        local Player = QBCore.Functions.GetPlayer(tonumber(pId))
        if Player and Player.PlayerData.citizenid == citizenid then
            src = tonumber(pId)
            break
        end
    end
    if src then
        TriggerClientEvent('quest:client:cleanupTrailer', src)
    end
end

-- ==============================================================
-- v0.7a: 挂车物理挂接事件 (v0.9: +标记 hitched)
-- ==============================================================

RegisterNetEvent('quest:server:trailerHitched', function(questId, stepId, trailerNetId)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- v0.10: 标记该 trailer 已挂接（TrailerTracker + EntityRegistry 双写）
    local citizenid = Player.PlayerData.citizenid
    if TrailerTracker[citizenid] and TrailerTracker[citizenid][questId] then
        -- 比对 netId，确认挂接的是注册过的 trailer
        local record = TrailerTracker[citizenid][questId]
        if record.netId == trailerNetId or trailerNetId == 0 then
            record.hitched = true
            QuestEntityRegistry.MarkHitched(citizenid, questId, 'trailer', true)
        end
        -- 清理该 quest 的其他未挂接记录（如有旧 trailer）
        for qId, rec in pairs(TrailerTracker[citizenid]) do
            if qId == questId and not rec.hitched and rec.netId ~= trailerNetId then
                local oldTrailer = NetworkGetEntityFromNetworkId(rec.netId)
                if oldTrailer and oldTrailer ~= 0 and DoesEntityExist(oldTrailer) then
                    DeleteEntity(oldTrailer)
                end
                TrailerTracker[citizenid][qId] = nil
            end
        end
    end

    -- 广播 trailer_hooked custom_event 给任务系统推进步骤
    exports['custom-quest']:OnCustomEvent(src, 'trailer_hooked', {
        trailer_netid = trailerNetId,
        timestamp = os.time(),
    })
end)

-- v0.10: 内部事件 — 触发 trailer 清理 (已改为清理所有 trailer)
RegisterNetEvent('quest:server:cleanupTrailers', function(citizenid)
    CleanupAllTrailers(citizenid)
end)

-- v0.9: 实体追踪超时 → 任务失败
RegisterNetEvent('quest:server:entityTrackingFail', function(questId, reason)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid

    -- 审计日志
    if exports['custom-logs'] then
        exports['custom-logs']:LogSecurity('运输任务违规',
            ('**%s** (%s) | Quest: %s | Reason: %s'):format(
                GetPlayerName(src), citizenid, questId, reason or 'unknown'
            ), 16744192)
    end

    -- v0.10: 清理所有 trailer (包括已挂接的)
    CleanupAllTrailers(citizenid)

    -- 失败任务
    QuestManager.FailQuest(src, questId, reason or 'entity_tracking_violation')
    TriggerClientEvent('QBCore:Notify', src, '❌ 任务失败：违反运输规则', 'error')
end)

-- ==============================================================
-- v0.7.2: 中控屏电子印章交单事件
-- ==============================================================

RegisterNetEvent('quest:server:dashboardStampDelivery', function(callerSrc, questId, stepId)
    local src = callerSrc or source  -- 跨资源 TriggerEvent 显式传入
    print(('[custom-quest] 📥 dashboardDelivery: src=%d, quest=%s, step=%s'):format(
        src, questId, stepId))

    -- 安全校验
    local ok, err = QuestSecurity.ValidateClientEvent(src, questId, stepId, true)  -- v0.7.2: 跳过 Nonce
    if not ok then
        TriggerClientEvent('QBCore:Notify', src, err or 'Validation failed', 'error')
        return
    end

    local template = QuestRegistry.GetTemplate(questId)
    if not template then
        TriggerClientEvent('QBCore:Notify', src, 'Quest template not found', 'error')
        return
    end

    for _, step in ipairs(template.steps) do
        if step.id == stepId and step.data and step.data.validator_id then
            local Player = QBCore.Functions.GetPlayer(src)
            if not Player then return end

            local validatorData = step.data.validator_data or {}
            -- 合并校验器关心的meta字段（不混入UI字段）
            local validatorMetaKeys = {
                destCoords = true, radius = true, use_bound_vehicle = true,
                require_trailer = true, returnCoords = true,
                allowed_classes = true, fallback_model = true,
                rental_fee_percent = true, rental_deposit = true,
            }
            for k, v in pairs(step.data) do
                if validatorMetaKeys[k] then
                    validatorData[k] = v
                end
            end

            local questData = { questId = questId, citizenid = Player.PlayerData.citizenid, vehicleNetId = nil }  -- dashboard 无 clientData
            local passed, msg = QuestValidators.Run(step.data.validator_id, src, validatorData, questData)
            if not passed then
                TriggerClientEvent('QBCore:Notify', src, msg or '电子印章校验失败', 'error')
                return
            end

            -- 校验通过，推进步骤
            local success, message = QuestManager.AdvanceStep(
                Player.PlayerData.citizenid, questId, stepId)
            if not success then
                TriggerClientEvent('QBCore:Notify', src, message, 'error')
            end
            return
        end
    end

    TriggerClientEvent('QBCore:Notify', src, '未找到可校验的步骤', 'error')
end)

-- ==============================================================
-- v0.7.2: 调试命令 — 直接接取/放弃任务（admin only）
-- ==============================================================

RegisterCommand('startquest', function(source, args)
    local src = source
    local questId = args[1]
    if not questId then
        TriggerClientEvent('QBCore:Notify', src, '用法: /startquest <questId>', 'error')
        -- 列出可用任务
        local ids = QuestRegistry.GetAllIds()
        local list = table.concat(ids, ', ')
        TriggerClientEvent('chat:addMessage', src, {
            color = { 255, 200, 100 },
            multiline = true,
            args = { '可用任务: ' .. list }
        })
        return
    end

    local success, message = QuestManager.TriggerQuest(src, questId)
    if success then
        TriggerClientEvent('QBCore:Notify', src, message, 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, message, 'error')
    end
end, true) -- restricted

RegisterCommand('abandonquest', function(source, args)
    local src = source
    local questId = args[1]
    if not questId then
        -- 无参数: 放弃所有活跃任务
        local activeQuests = QuestManager.GetActiveQuests(src)
        if not activeQuests or #activeQuests == 0 then
            TriggerClientEvent('QBCore:Notify', src, '没有活跃任务', 'error')
            return
        end
        for _, q in ipairs(activeQuests) do
            QuestManager.AbandonQuest(src, q.quest_id)
        end
        TriggerClientEvent('QBCore:Notify', src,
            ('已放弃 %d 个活跃任务'):format(#activeQuests), 'primary')
        return
    end

    local success, message = QuestManager.AbandonQuest(src, questId)
    if success then
        TriggerClientEvent('QBCore:Notify', src, message, 'primary')
    else
        TriggerClientEvent('QBCore:Notify', src, message, 'error')
    end
end, true) -- restricted

RegisterCommand('grantheavy', function(source)
    local src = source
    if exports['custom-certificates'] and exports['custom-certificates'].GrantLicense then
        local ok, msg = exports['custom-certificates']:GrantLicense(src, 'heavy')
        if ok then
            TriggerClientEvent('QBCore:Notify', src, '✅ 已授予重型载具执照 (heavy)', 'success')
        else
            TriggerClientEvent('QBCore:Notify', src, '❌ 执照授予失败: ' .. (msg or 'unknown'), 'error')
        end
    else
        -- fallback: 直接设 metadata
        local Player = QBCore.Functions.GetPlayer(src)
        if Player then
            local licences = Player.PlayerData.metadata.licences or {}
            licences['heavy'] = true
            Player.Functions.SetMetaData('licences', licences)
            TriggerClientEvent('QBCore:Notify', src, '✅ 已强制写入 heavy 执照 (metadata fallback)', 'success')
        end
    end
end, true) -- restricted

RegisterCommand('revokeheavy', function(source)
    local src = source
    if exports['custom-certificates'] and exports['custom-certificates'].RevokeLicense then
        local ok, msg = exports['custom-certificates']:RevokeLicense(src, 'heavy')
        if ok then
            TriggerClientEvent('QBCore:Notify', src, '🗑️ 已吊销重型载具执照 (heavy)', 'success')
        else
            TriggerClientEvent('QBCore:Notify', src, '❌ 吊销失败: ' .. (msg or 'unknown'), 'error')
        end
    else
        local Player = QBCore.Functions.GetPlayer(src)
        if Player then
            local licences = Player.PlayerData.metadata.licences or {}
            licences['heavy'] = nil
            Player.Functions.SetMetaData('licences', licences)
            TriggerClientEvent('QBCore:Notify', src, '🗑️ 已强制清除 heavy 执照 (metadata fallback)', 'success')
        end
    end
end, true) -- restricted

RegisterCommand('debugquest', function(source, args)
    local src = source
    local questId = args[1]
    if not questId then
        TriggerClientEvent('QBCore:Notify', src, '用法: /debugquest <questId>', 'error')
        return
    end

    local template = QuestRegistry.GetTemplate(questId)
    if not template then
        TriggerClientEvent('QBCore:Notify', src, '任务模板不存在: ' .. questId, 'error')
        return
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local lines = { ('📋 诊断: %s'):format(questId) }

    -- 1. required_tags 检查
    if template.required_tags then
        if exports['custom-career'] then
            local ok, matchResult = pcall(function()
                return exports['custom-career']:PlayerMatchesTags(src, template.required_tags)
            end)
            if ok then
                table.insert(lines, ('  📌 required_tags: %s → %s'):format(
                    json.encode(template.required_tags), matchResult and '✅ PASS' or '❌ FAIL'))
            else
                table.insert(lines, '  📌 required_tags: ❌ custom-career pcall 异常')
            end
        else
            table.insert(lines, '  📌 required_tags: ⚠️ custom-career 未运行，跳过')
        end
    else
        table.insert(lines, '  📌 required_tags: 无要求 ✅')
    end

    -- 2. min_license 检查
    if template.conditions and template.conditions.min_license then
        local licenseType = template.conditions.min_license
        local hasLicense = false
        if exports['custom-certificates'] then
            local ok, result = pcall(function()
                return exports['custom-certificates']:HasLicense(src, licenseType)
            end)
            if ok then hasLicense = result end
        end
        -- fallback: 检查 metadata
        if not hasLicense then
            local licences = Player.PlayerData.metadata.licences or {}
            hasLicense = licences[licenseType] == true
        end
        table.insert(lines, ('  📌 min_license (%s): %s'):format(
            licenseType, hasLicense and '✅ PASS' or '❌ FAIL'))
    else
        table.insert(lines, '  📌 min_license: 无要求 ✅')
    end

    -- 3. min_police 检查
    if template.conditions and template.conditions.min_police then
        local policeCount = QBCore.Functions.GetDutyCount('police')
        table.insert(lines, ('  📌 min_police: 需要%d, 当前%d → %s'):format(
            template.conditions.min_police, policeCount,
            policeCount >= template.conditions.min_police and '✅ PASS' or '❌ FAIL'))
    else
        table.insert(lines, '  📌 min_police: 无要求 ✅')
    end

    -- 4. 活跃任务数
    local quests = QuestManager.GetActiveQuests(src)
    table.insert(lines, ('  📌 活跃任务: %d/%d'):format(#quests, Config.Quest.MaxActiveQuests))

    -- 5. 冷却
    local onCooldown = false
    if template.conditions and template.conditions.cooldown_hours then
        if QuestCooldown then
            onCooldown = QuestCooldown.IsOnCooldown(Player.PlayerData.citizenid, questId)
        end
        table.insert(lines, ('  📌 冷却中: %s'):format(onCooldown and '❌ YES' or '✅ NO'))
    end

    TriggerClientEvent('chat:addMessage', src, {
        color = { 255, 220, 100 },
        multiline = true,
        args = { table.concat(lines, '\n') }
    })
end, true) -- restricted

RegisterCommand('listquests', function(source)
    local src = source
    local catalog = QuestRegistry.GetCategorizedList()
    local lines = {}
    for category, quests in pairs(catalog) do
        for _, q in ipairs(quests) do
            table.insert(lines, ('[%s] %s — %s (Lv.%d)'):format(
                category, q.id, q.title, q.level or 1))
        end
    end
    if #lines == 0 then
        TriggerClientEvent('chat:addMessage', src, {
            color = { 255, 100, 100 },
            args = { '⚠️ 无已注册的任务模板！检查 quest_registry 日志' }
        })
        return
    end
    TriggerClientEvent('chat:addMessage', src, {
        color = { 100, 200, 255 },
        multiline = true,
        args = { '📋 可用任务:\n' .. table.concat(lines, '\n') }
    })
end, true) -- restricted

-- ==============================================================
-- v0.10: 调试命令 — 跳转到指定步骤 (admin only)
-- 用法: /queststep <questId> <stepId>
--   例: /queststep euro_container_haul step_deliver_container
--   会自动接取任务并完成前面的所有步骤，到达目标步
-- ==============================================================

RegisterCommand('queststep', function(source, args)
    local src = source
    local questId = args[1]
    local targetStepId = args[2]

    if not questId or not targetStepId then
        TriggerClientEvent('QBCore:Notify', src, '用法: /queststep <questId> <stepId>', 'error')
        TriggerClientEvent('QBCore:Notify', src, '例: /queststep euro_container_haul step_deliver_container', 'primary')
        return
    end

    local template = QuestRegistry.GetTemplate(questId)
    if not template then
        TriggerClientEvent('QBCore:Notify', src, '任务模板不存在: ' .. questId, 'error')
        return
    end

    -- 找到目标步骤索引
    local targetIndex = nil
    for i, step in ipairs(template.steps) do
        if step.id == targetStepId then
            targetIndex = i
            break
        end
    end

    if not targetIndex then
        TriggerClientEvent('QBCore:Notify', src, '步骤不存在: ' .. targetStepId, 'error')
        -- 列出可用步骤
        local stepIds = {}
        for _, step in ipairs(template.steps) do
            stepIds[#stepIds + 1] = step.id
        end
        TriggerClientEvent('chat:addMessage', src, {
            color = { 255, 200, 100 },
            args = { '可用步骤: ' .. table.concat(stepIds, ', ') }
        })
        return
    end

    -- 先放弃现有同 ID 任务
    QuestManager.AbandonQuest(src, questId)

    -- 接取任务
    local success, message = QuestManager.TriggerQuest(src, questId)
    if not success then
        TriggerClientEvent('QBCore:Notify', src, '接取失败: ' .. message, 'error')
        return
    end

    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local citizenid = Player.PlayerData.citizenid

    -- 模拟完成目标步之前的所有步骤
    for i = 1, targetIndex - 1 do
        local step = template.steps[i]
        -- 跳过不存在的步骤类型（已有 type 字段）
        if step.type == 'custom_event' then
            -- custom_event 步骤需要事件驱动，手动建立索引后推进
            if step.data and step.data.event_name then
                QuestCache.IndexEvent(citizenid, step.data.event_name, questId, step.id)
            end
        end
        -- 直接推进步骤（绕过校验器）
        local advanceSuccess = QuestManager.AdvanceStep(citizenid, questId, step.id, { _debug_skip = true })
        if not advanceSuccess then
            TriggerClientEvent('QBCore:Notify', src,
                ('❌ 跳步失败于 %s (索引 %d)'):format(step.id, i), 'error')
            return
        end
    end

    TriggerClientEvent('QBCore:Notify', src,
        ('✅ 已跳至 %s → %s (%d/%d)'):format(questId, targetStepId, targetIndex, #template.steps), 'success')
end, true) -- restricted

-- ==============================================================
-- v1.0: 玩家死亡/倒地 → 活跃任务全部失败（事件驱动 + 轮询兜底）
-- ==============================================================

-- 主路径：监听 qb-ambulancejob 的死亡状态变更事件
RegisterNetEvent('hospital:server:SetDeathStatus', function(isDead)
    local src = source
    if not isDead then return end  -- 只处理死亡，不处理复活
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or not Player.PlayerData then return end

    local citizenid = Player.PlayerData.citizenid
    local activeQuests = QuestCache.GetActiveQuests(citizenid)
    if not activeQuests or #activeQuests == 0 then return end

    for _, q in ipairs(activeQuests) do
        QuestManager.FailQuest(src, q.quest_id, 'player_death')
    end
    TriggerClientEvent('QBCore:Notify', src, '💀 任务失败：你已死亡', 'error')
end)

-- 兜底：每 30 秒轮询（无 qb-ambulancejob 或跨资源事件丢失时兜底）
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(30000)
        for _, pId in ipairs(GetPlayers()) do
            local src = tonumber(pId)
            local Player = QBCore.Functions.GetPlayer(src)
            if not Player or not Player.PlayerData then goto next_player end

            local metadata = Player.PlayerData.metadata or {}
            local isDead = metadata['isdead'] or metadata['inlaststand'] or false
            if not isDead then goto next_player end

            local citizenid = Player.PlayerData.citizenid
            local activeQuests = QuestCache.GetActiveQuests(citizenid)
            if not activeQuests or #activeQuests == 0 then goto next_player end

            for _, q in ipairs(activeQuests) do
                QuestManager.FailQuest(src, q.quest_id, 'player_death')
            end
            TriggerClientEvent('QBCore:Notify', src, '💀 任务失败：你已死亡', 'error')
            ::next_player::
        end
    end
end)

-- ==============================================================
-- v0.11: 坐标采集工具 — 保存到 pos_collection.json
-- ==============================================================

RegisterNetEvent('quest:server:savePosCollection', function(collection)
    local src = source
    if not collection or type(collection) ~= 'table' or #collection == 0 then return end

    local resourceName = GetCurrentResourceName()
    local filePath = ('pos_collection_%s.json'):format(os.date('%Y%m%d_%H%M%S'))

    -- 格式化为 JSON
    local jsonLines = {}
    table.insert(jsonLines, '{')
    for i, entry in ipairs(collection) do
        local comma = i < #collection and ',' or ''
        table.insert(jsonLines, string.format(
            '  {"name":"%s","type":"%s","x":%.2f,"y":%.2f,"z":%.2f,"heading":%.1f}%s',
            entry.name, entry.type, entry.x, entry.y, entry.z, entry.heading or 0, comma
        ))
    end
    table.insert(jsonLines, '}')

    local jsonStr = table.concat(jsonLines, '\n')

    -- 写入文件 (SaveResourceFile 仅在服务端可用)
    local ok = pcall(function()
        SaveResourceFile(resourceName, filePath, jsonStr, -1)
    end)

    if ok then
        print(('[quest-pos] 💾 %d 个坐标已保存: %s'):format(#collection, filePath))

        -- 同时输出 Lua 格式到控制台
        print('[quest-pos] 📋 address_pools.lua 格式:')
        for _, entry in ipairs(collection) do
            print(string.format('    { coords = { x = %.2f, y = %.2f, z = %.2f }, label = \'%s\', type = \'%s\' },',
                entry.x, entry.y, entry.z, entry.name, entry.type))
        end
    else
        print('[quest-pos] ❌ 文件保存失败: ' .. filePath)
    end

    if src and src > 0 then
        TriggerClientEvent('QBCore:Notify', src,
            ('💾 %d 个坐标已保存: %s'):format(#collection, filePath), 'success')
    end
end)

print('[custom-quest] ✅ 通用任务系统已启动 (v0.7.2)')
print('[custom-quest]   11 exports: TriggerQuest, OnCustomEvent, CompleteStep, RegisterStepValidator, FailQuest, GetActiveQuests, GetQuestProgress, GenerateNonce, GetQuestCatalog, IsQuestActive, GetQuestStep')
print('[custom-quest]   Bus: service_quest_* 可用')
print('[custom-quest]   事件: accept, abandon, reach, collect, dashboardStampDelivery, requestState, requestNonce')