-- main.lua — custom-quest 客户端  v0.7.0
--
-- 职责:
--   1. 接收服务端推送的事件（任务接受/步骤推进/完成/失败）
--   2. 生成和管理 GPS 路点 (quest_blips)
--   3. 任务 HUD 追踪 UI
--   4. v0.7.0: PolyZone 自动检测 reach 步骤到达
--   5. v0.7.0: 重连状态恢复
--   6. 客户端 NUI 回调（手机集成预留）

local QBCore = exports['qb-core']:GetCoreObject()

-- 当前活跃任务状态
local activeQuest = nil
local currentBlip = nil

-- v0.7.0: 活跃的 PolyZone 实例
local activeZone = nil

-- ==============================================================
-- 路点管理
-- ==============================================================

function SetNewBlip(coords, title)
    ClearBlip()
    if not coords then return end

    currentBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(currentBlip, 1)
    SetBlipColour(currentBlip, 2)
    SetBlipRoute(currentBlip, true)
    SetBlipRouteColour(currentBlip, 2)
    SetBlipDisplay(currentBlip, 2)   -- 显示距离
    SetBlipAsShortRange(currentBlip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(title or _L('blip_quest_target'))
    EndTextCommandSetBlipName(currentBlip)
end

function ClearBlip()
    if currentBlip and DoesBlipExist(currentBlip) then
        RemoveBlip(currentBlip)
    end
    currentBlip = nil
end

-- v0.7.0: 清理 PolyZone + activeNode
function ClearZone()
    if activeZone then
        activeZone:destroy()
        activeZone = nil
    end
    activeNode = nil  -- v0.9: 同时清理活跃节点，防止旧节点线程残留
end

-- v0.8a: 清理所有活跃节点 + blip（QuestNodes 兼容层兜底）
RegisterNetEvent('quest:client:clearAllNodes', function(data)
    ClearBlip()
    ClearZone()
    if activeNode then activeNode = nil end
    if nodeTimer then
        Citizen.SetTimeout(0, function() end) -- dummy, just nil it
        nodeTimer = nil
    end
end)

-- v0.7.0: 为 reach 步骤创建 PolyZone 自动检测区
function SetupReachZone(stepData, questId, stepId)
    ClearZone()

    local coords = stepData.coords
    if not coords then return end

    local radius = stepData.radius or 25.0

    -- 使用 PolyZone 创建球形检测区
    if PolyZone then
        activeZone = PolyZone:Create(vector3(coords.x, coords.y, coords.z), {
            name = ('quest_reach_%s_%s'):format(questId, stepId),
            offset = { 0.0, 0.0, 0.0 },
            scale = { radius, radius, 10.0 },
            debugPoly = false,
        })

        if activeZone then
            activeZone:onPlayerInOut(function(isInside)
                if isInside and activeQuest and activeQuest.current_step == stepId then
                    -- 请求 Nonce Token 后自动触发
                    QBCore.Functions.TriggerCallback(
                        Config.Quest.Events.QUEST_REQUEST_NONCE,
                        function(nonce)
                            if nonce then
                                TriggerServerEvent(Config.Quest.Events.QUEST_REACH, questId, stepId, nonce)
                            end
                        end
                    )
                end
            end)
        end
    end
end

-- ==============================================================
-- 事件: 任务被接受
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_ACCEPTED, function(data)
    activeQuest = data

    -- v0.11: 清理旧 checkpoint
    CheckpointManager.Clear()

    -- 生成第一步的路点 + Checkpoint / PolyZone / custom_event 监听器
    if data.steps and data.current_step then
        for _, step in ipairs(data.steps) do
            if step.id == data.current_step then
                -- v0.11: 优先使用 CheckpointManager，PolyZone 作为 fallback
                local useCheckpoint = Config.Quest.Checkpoint.Enabled
                    and Config.Quest.Checkpoint.DefaultTypeMap[step.type]
                    and step.data and (step.data.coords or step.data.destCoords)

                if useCheckpoint then
                    CheckpointManager.Create(data.quest_id, step.id, step.type, step.data)
                    if step.data.coords then
                        SetNewBlip(step.data.coords, step.title)
                    end
                elseif step.type == 'reach' and step.data and step.data.coords then
                    SetNewBlip(step.data.coords, step.title)
                    SetupReachZone(step.data, data.quest_id, step.id)
                elseif step.type == 'custom_event' then
                    if step.data.event_name == 'trailer_hooked' then
                        TriggerEvent('quest:client:monitorTrailerHitch', {
                            questId = data.quest_id,
                            stepId = step.id,
                            trailerModel = step.data.trailer_model,
                            spawn_coords = step.data.spawn_coords,
                            backup_coords = step.data.backup_coords,
                        })
                    end
                elseif (step.type == 'validator' or step.type == 'interact') and step.data and step.data.coords then
                    SetNewBlip(step.data.coords, step.title)
                end
                break
            end
        end
    end

    QBCore.Functions.Notify(('Quest started: %s'):format(data.title), 'success')
end)

-- ==============================================================
-- 事件: 步骤推进
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_STEP_ADVANCED, function(data)
    if not activeQuest or activeQuest.quest_id ~= data.quest_id then return end

    -- 更新当前步骤
    activeQuest.current_step = data.to_step

    -- v0.9: 防御性清除 trailer blip（步骤变更时兜底）
    TriggerEvent('quest:client:clearTrailerBlip')

    -- 清理旧 PolyZone（validator/interact 节点由各自的 node 事件自行清理，避免竞态覆盖）
    if data.next_step_type ~= 'validator' and data.next_step_type ~= 'interact' then
        ClearZone()
    end

    -- v0.11: 更新 Checkpoint / Blip / PolyZone
    local stepData = data.next_step_data
    if stepData then
        -- v0.11: 优先使用 CheckpointManager，PolyZone 作为 fallback
        local useCheckpoint = Config.Quest.Checkpoint.Enabled
            and Config.Quest.Checkpoint.DefaultTypeMap[data.next_step_type]
            and (stepData.coords or stepData.destCoords)

        if useCheckpoint then
            -- 清理旧 checkpoint → 创建新 checkpoint
            CheckpointManager.Clear()
            CheckpointManager.Create(data.quest_id, data.to_step, data.next_step_type, stepData)
            local blipCoord = stepData.coords or stepData.destCoords
            if blipCoord then
                SetNewBlip(blipCoord, data.next_step_title)
            end

        elseif data.next_step_type == 'reach' and stepData.coords then
            SetNewBlip(stepData.coords, data.next_step_title)
            SetupReachZone(stepData, data.quest_id, data.to_step)
        elseif (data.next_step_type == 'validator' or data.next_step_type == 'interact') and stepData.coords then
            SetNewBlip(stepData.coords, data.next_step_title)
        elseif data.next_step_type == 'deliver' or data.next_step_type == 'DELIVER' then
            if stepData.destCoords then
                SetNewBlip(stepData.destCoords, data.next_step_title)
            end
        elseif data.next_step_type == 'custom_event' then
            if stepData.event_name == 'trailer_hooked' then
                TriggerEvent('quest:client:monitorTrailerHitch', {
                    questId = data.quest_id,
                    stepId = data.to_step,
                    trailerModel = stepData.trailer_model,
                    spawn_coords = stepData.spawn_coords,
                    backup_coords = stepData.backup_coords,
                })
            elseif stepData.event_name == 'aviation_height_monitor' then
                TriggerEvent('quest:client:activateHeightMonitor', {
                    questId = data.quest_id,
                    max_height = stepData.max_height,
                    check_duration_sec = stepData.check_duration_sec,
                })
            end
        elseif data.next_step_type == 'goto' or data.next_step_type == 'GOTO' then
            if stepData.coords then
                SetNewBlip(stepData.coords, data.next_step_title)
                SetupReachZone(stepData, data.quest_id, data.to_step)
            end
        else
            ClearBlip()
        end
    else
        ClearBlip()
    end

    print(('[quest-client] ➡️ STEP: %s → %s (type=%s)'):format(data.from_step, data.to_step, data.next_step_type))
    QBCore.Functions.Notify(('Step: %s'):format(data.next_step_title), 'primary')
end)

-- ==============================================================
-- 事件: 任务完成
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_COMPLETED, function(data)
    print('[quest-client] 🎉 QUEST_COMPLETED received: ' .. tostring(data and data.title))
    activeNode = nil
    ClearBlip()
    ClearZone()
    CheckpointManager.Clear()  -- v0.11
    activeQuest = nil
    QBCore.Functions.Notify(('Quest completed: %s!'):format(data.title), 'success')
end)

-- ==============================================================
-- 事件: 任务失败
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_FAILED, function(data)
    activeNode = nil
    ClearBlip()
    ClearZone()
    CheckpointManager.Clear()  -- v0.11
    activeQuest = nil
    QBCore.Functions.Notify(('Quest failed: %s'):format(data.reason or 'unknown'), 'error')
end)

-- ==============================================================
-- 事件: 任务放弃
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_ABANDONED, function(data)
    activeNode = nil
    ClearBlip()
    ClearZone()
    CheckpointManager.Clear()  -- v0.11
    activeQuest = nil
    QBCore.Functions.Notify('Quest abandoned', 'primary')
end)

-- ==============================================================
-- 事件: 进度更新（custom_event 步骤实时进度）
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_PROGRESS, function(data)
    if not activeQuest or activeQuest.quest_id ~= data.quest_id then return end
    QBCore.Functions.Notify(
        ('Progress: %d/%d'):format(data.progress, data.required), 'primary')
end)

-- ==============================================================
-- v0.7.0: 事件: 重连状态恢复
-- ==============================================================

RegisterNetEvent(Config.Quest.Events.QUEST_STATE_RESTORE, function(data)
    if not data or not data.quest_id then return end

    activeQuest = data

    -- 重新生成当前步骤的路点 + PolyZone
    if data.steps and data.current_step then
        for _, step in ipairs(data.steps) do
            if step.id == data.current_step then
                if step.type == 'reach' and step.data and step.data.coords then
                    SetNewBlip(step.data.coords, step.title)
                    SetupReachZone(step.data, data.quest_id, step.id)
                elseif (step.type == 'validator' or step.type == 'interact') and step.data and step.data.coords then
                    -- v0.7.2: reconnect 时恢复 validator/interact 的 blip
                    SetNewBlip(step.data.coords, step.title)
                elseif (step.type == 'deliver' or step.type == 'DELIVER') and step.data and step.data.destCoords then
                    SetNewBlip(step.data.destCoords, step.title)
                end
                break
            end
        end
    end

    QBCore.Functions.Notify(('Quest restored: %s'):format(data.title), 'primary')
end)

-- ==============================================================
-- v0.7.0: 重连时自动请求状态
-- ==============================================================

AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    -- 等待一小段时间确保服务端就绪
    Citizen.SetTimeout(2000, function()
        TriggerServerEvent(Config.Quest.Events.QUEST_REQUEST_STATE)
    end)
end)

-- 也监听资源重启后的恢复
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        Citizen.SetTimeout(2000, function()
            TriggerServerEvent(Config.Quest.Events.QUEST_REQUEST_STATE)
        end)
    end
end)

-- ==============================================================
-- 命令: 查看活跃任务
-- ==============================================================

RegisterCommand('quest', function()
    if activeQuest then
        QBCore.Functions.Notify(
            ('Active: %s | Step: %s'):format(activeQuest.title, activeQuest.current_step or 'none'),
            'primary', 5000)
    else
        QBCore.Functions.Notify('No active quest', 'error')
    end
end, false)

-- ==============================================================
-- v1.0.0: 原子节点客户端处理器
-- ==============================================================

-- 活跃的节点状态 (每个玩家同时只有一个活跃节点)
local activeNode = nil
local nodeTimer = nil

-- ── GOTO 节点 (已由 QUEST_ACCEPTED / QUEST_STEP_ADVANCED 处理) ────

RegisterNetEvent('quest:client:nodeGoto', function(data)
    -- GOTO 节点复用了现有的 SetupReachZone 机制
    -- 这里只做数据记录
    activeNode = { type = 'GOTO', questId = data.questId, stepId = data.stepId, data = data }
    if data.coords then
        SetNewBlip(data.coords, data.label or 'Destination')
        SetupReachZone(data, data.questId, data.stepId)
    end
end)

-- ── INTERACT 节点: 进度条 + 动画 ──────────────────────────────────

RegisterNetEvent('quest:client:nodeInteract', function(data)
    ClearZone()
    activeNode = { type = 'INTERACT', questId = data.questId, stepId = data.stepId, data = data }

    local coords = data.coords or data.targetCoords
    if coords then
        SetNewBlip(coords, data.label or 'Interact')
    end

    -- v0.7.2: 交互线程 — 距离轮询 fallback（不依赖 PolyZone）
    if not coords then return end
    local radius = data.radius or 10.0
    local targetVec = vector3(coords.x, coords.y, coords.z)

    local autoTrigger = data.autoTrigger or false
    local cooldownUntil = 0
    Citizen.CreateThread(function()
        local label = data.label or 'Interact'
        local inVehicle = data.in_vehicle or data.inVehicle or false   -- normalize both snake_case and camelCase
        local insideLast = false
        local autoFired = false
        while activeNode and activeNode.stepId == data.stepId do
            Citizen.Wait(0)
            local ped = PlayerPedId()
            local pCoords = GetEntityCoords(ped)
            local dist = #(pCoords - targetVec)
            local inside = dist <= radius

            if inside and not insideLast then
                if inVehicle then
                    local veh = GetVehiclePedIsIn(ped, false)
                    if not veh or veh == 0 then
                        QBCore.Functions.Notify('你必须坐在载具中', 'error')
                        insideLast = inside
                        goto continue_interact
                    end
                end
                if not autoTrigger then
                    QBCore.Functions.Notify(('Press ~g~E~s~ to %s'):format(label), 'primary')
                end
            elseif not inside and insideLast then
                QBCore.Functions.Notify('已离开任务区域', 'error')
            end
            insideLast = inside

            -- v0.7.2: 自动触发 — validator 后直接执行，无需按 E
            local shouldFire = false
            if autoTrigger and inside and not autoFired then
                shouldFire = true
                autoFired = true
            elseif not autoTrigger and inside and IsControlJustPressed(0, 38) and GetGameTimer() > cooldownUntil then
                shouldFire = true
                cooldownUntil = GetGameTimer() + 5000
            end

            if shouldFire then
                if not inVehicle and data.animDict and data.animName then
                    RequestAnimDict(data.animDict)
                    while not HasAnimDictLoaded(data.animDict) do Citizen.Wait(10) end
                    TaskPlayAnim(PlayerPedId(), data.animDict, data.animName, 8.0, -8.0, data.duration or 3000, 1, 0, false, false, false)
                end

                if exports['progressbar'] then
                    exports['progressbar']:Progress({
                        name = 'quest_interact',
                        duration = data.duration or 3000,
                        label = label,
                        useWhileDead = false,
                        canCancel = true,
                        controlDisables = {
                            disableMovement = not inVehicle,
                            disableCarMovement = inVehicle,
                            disableMouse = false,
                            disableCombat = false,
                        },
                    }, function(cancelled)
                        if not cancelled and activeNode and activeNode.stepId == data.stepId then
                            if data.detachTrailer then
                                local ped = PlayerPedId()
                                local veh = GetVehiclePedIsIn(ped, false)
                                if veh and veh ~= 0 then DetachVehicleFromTrailer(veh) end
                            end
                            TriggerServerEvent('quest:server:nodeComplete',
                                data.questId, data.stepId, 'INTERACT',
                                { position = targetVec, detachTrailer = data.detachTrailer }
                            )
                        end
                    end)
                else
                    Citizen.Wait(data.duration or 3000)
                    if data.detachTrailer then
                        local ped = PlayerPedId()
                        local veh = GetVehiclePedIsIn(ped, false)
                        if veh and veh ~= 0 then DetachVehicleFromTrailer(veh) end
                    end
                    TriggerServerEvent('quest:server:nodeComplete',
                        data.questId, data.stepId, 'INTERACT',
                        { position = targetVec, detachTrailer = data.detachTrailer }
                    )
                end
            end
            ::continue_interact::
        end
    end)

    -- PolyZone 补充（如果可用则叠加）
    if PolyZone then
        local zone = PolyZone:Create(targetVec, {
            name = ('quest_interact_%s_%s'):format(data.questId, data.stepId),
            offset = { 0.0, 0.0, 0.0 },
            scale = { radius, radius, 5.0 },
            debugPoly = false,
        })
        if zone then activeZone = zone end
    end
end)

-- ── DELIVER 节点: 运送标记 ──────────────────────────────────────

RegisterNetEvent('quest:client:nodeDeliver', function(data)
    ClearZone()
    activeNode = { type = 'DELIVER', questId = data.questId, stepId = data.stepId, data = data }

    if data.destCoords then
        SetNewBlip(data.destCoords, data.label or 'Delivery Point')
    end

    -- 创建送达检测区
    if data.destCoords and PolyZone then
        local radius = data.radius or 5.0
        local zone = PolyZone:Create(vector3(data.destCoords.x, data.destCoords.y, data.destCoords.z), {
            name = ('quest_deliver_%s_%s'):format(data.questId, data.stepId),
            offset = { 0.0, 0.0, 0.0 },
            scale = { radius, radius, 5.0 },
            debugPoly = false,
        })

        if zone then
            zone:onPlayerInOut(function(isInside)
                if isInside and activeNode and activeNode.stepId == data.stepId then
                    TriggerServerEvent('quest:server:nodeComplete',
                        data.questId, data.stepId, 'DELIVER',
                        {
                            position = data.destCoords,
                            itemName = data.itemName,
                            itemAmount = data.itemAmount,
                            vehicleModel = data.vehicleModel,
                        }
                    )
                end
            end)

            activeZone = zone
        end
    end
end)

-- ── COMBAT 节点: NPC 生成 + 击杀计数 ─────────────────────────────

RegisterNetEvent('quest:client:nodeCombat', function(data)
    ClearZone()
    activeNode = { type = 'COMBAT', questId = data.questId, stepId = data.stepId, data = data }

    local npcHandles = {}
    local killCount = 0
    local requiredKills = data.npcCount or 3

    -- 生成 NPC
    local spawnCoords = data.coords
    if spawnCoords then
        RequestModel(GetHashKey(data.npcModel))
        while not HasModelLoaded(GetHashKey(data.npcModel)) do Citizen.Wait(10) end

        for i = 1, requiredKills do
            local offsetX = math.random(-20, 20)
            local offsetY = math.random(-20, 20)
            local npc = CreatePed(4, GetHashKey(data.npcModel),
                spawnCoords.x + offsetX, spawnCoords.y + offsetY, spawnCoords.z - 1.0,
                0.0, true, true)
            if npc > 0 then
                SetPedFleeAttributes(npc, 0, false)
                SetPedCombatAttributes(npc, 46, true)
                GiveWeaponToPed(npc, GetHashKey(data.weapon or 'weapon_pistol'), 999, false, true)
                SetPedAccuracy(npc, data.npcAccuracy or 25)
                SetEntityHealth(npc, data.npcHealth or 200)
                TaskCombatPed(npc, PlayerPedId(), 0, 16)
                npcHandles[#npcHandles + 1] = npc
            end
        end

        SetModelAsNoLongerNeeded(GetHashKey(data.npcModel))
    end

    -- 击杀监控线程
    Citizen.CreateThread(function()
        while activeNode and activeNode.stepId == data.stepId do
            Citizen.Wait(500)

            local newKillCount = 0
            local aliveCount = 0
            for _, npc in ipairs(npcHandles) do
                if DoesEntityExist(npc) then
                    if IsEntityDead(npc) then
                        newKillCount = newKillCount + 1
                    else
                        aliveCount = aliveCount + 1
                    end
                end
            end

            if newKillCount > killCount then
                killCount = newKillCount
                QBCore.Functions.Notify(
                    ('Enemies eliminated: %d/%d'):format(killCount, requiredKills), 'primary')
            end

            if aliveCount == 0 and killCount >= requiredKills then
                -- 全部击杀完成
                QBCore.Functions.Notify('All hostiles eliminated!', 'success')
                TriggerServerEvent('quest:server:nodeComplete',
                    data.questId, data.stepId, 'COMBAT',
                    { killCount = killCount, requiredKills = requiredKills }
                )
                break
            end

            if killCount >= requiredKills then
                -- 击杀数够了 (可能有残留 NPC 还活着)
                TriggerServerEvent('quest:server:nodeComplete',
                    data.questId, data.stepId, 'COMBAT',
                    { killCount = killCount, requiredKills = requiredKills }
                )
                break
            end
        end

        -- 清理残留 NPC
        Citizen.Wait(5000)
        for _, npc in ipairs(npcHandles) do
            if DoesEntityExist(npc) then
                DeleteEntity(npc)
            end
        end
    end)
end)

-- ── WAIT 节点: 区域计时器 ──────────────────────────────────────

RegisterNetEvent('quest:client:nodeWait', function(data)
    ClearZone()
    activeNode = { type = 'WAIT', questId = data.questId, stepId = data.stepId, data = data }

    local duration = data.duration or 60
    local allowLeave = data.allowLeave or false
    local elapsed = 0
    local completed = false

    -- 区域检测 (如果不允许离开)
    local waitZone = nil
    if data.coords and not allowLeave and PolyZone then
        waitZone = PolyZone:Create(vector3(data.coords.x, data.coords.y, data.coords.z), {
            name = ('quest_wait_%s_%s'):format(data.questId, data.stepId),
            offset = { 0.0, 0.0, 0.0 },
            scale = { data.radius or 50, data.radius or 50, 20.0 },
            debugPoly = false,
        })
        if waitZone then
            activeZone = waitZone
        end
    end

    -- 计时器线程
    Citizen.CreateThread(function()
        while activeNode and activeNode.stepId == data.stepId and not completed do
            Citizen.Wait(1000)
            elapsed = elapsed + 1

            -- 离开区域检查
            if waitZone then
                local playerCoords = GetEntityCoords(PlayerPedId())
                local dist = #(playerCoords - vector3(data.coords.x, data.coords.y, data.coords.z))
                if dist > (data.radius or 50) then
                    QBCore.Functions.Notify('You left the area! Timer reset.', 'error')
                    elapsed = 0
                end
            end

            -- 进度提示
            local remaining = duration - elapsed
            if remaining <= 0 then
                completed = true
                QBCore.Functions.Notify('Hold complete!', 'success')
                TriggerServerEvent('quest:server:nodeComplete',
                    data.questId, data.stepId, 'WAIT',
                    { elapsed = elapsed, duration = duration }
                )
            elseif remaining <= 10 then
                QBCore.Functions.Notify(('Hold for %d more seconds...'):format(remaining), 'primary')
            end
        end
    end)
end)

-- ── 节点完成: 统一服务端上报入口 (已有) ───────────────────────────
-- 由上述各节点处理函数中的 TriggerServerEvent('quest:server:nodeComplete', ...) 调用

-- ── 节点取消: 清理 ──────────────────────────────────────────────

RegisterNetEvent('quest:client:nodeCancel', function(data)
    if activeNode and activeNode.questId == data.questId and activeNode.stepId == data.stepId then
        activeNode = nil
        ClearZone()
        ClearBlip()
    end
end)

RegisterNetEvent('quest:client:nodeCancelAll', function(data)
    if activeNode and activeNode.questId == data.questId then
        activeNode = nil
        ClearZone()
        ClearBlip()
    end
end)

-- ── 组队事件 ────────────────────────────────────────────────────

RegisterNetEvent('quest:client:groupJoined', function(data)
    QBCore.Functions.Notify(
        ('Joined group for quest. Leader: %d | Members: %d'):format(data.leader, #(data.members or {})),
        'primary')
end)

RegisterNetEvent('quest:client:groupLeft', function(data)
    QBCore.Functions.Notify(
        ('You have been removed from the group. Reason: %s'):format(data.reason or 'unknown'),
        'error')
end)

RegisterNetEvent('quest:client:groupUpdated', function(data)
    if data.action == 'member_added' then
        QBCore.Functions.Notify(('Player %d joined the group.'):format(data.newMember), 'primary')
    elseif data.action == 'member_removed' then
        QBCore.Functions.Notify(('Player %d left the group.'):format(data.removedMember), 'primary')
    end
end)

RegisterNetEvent('quest:client:groupDisbanded', function(data)
    QBCore.Functions.Notify(('Group disbanded: %s'):format(data.reason or 'unknown'), 'error')
end)

-- (生产模式静默: custom-quest 客户端节点处理器已激活)