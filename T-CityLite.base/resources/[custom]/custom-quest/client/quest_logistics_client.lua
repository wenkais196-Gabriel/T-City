-- quest_logistics_client.lua — 物流任务客户端逻辑
--
-- v0.7.1: 飞行高度雷达监控（aviation_smuggling_flight 任务专用）
--   当玩家处于低空飞行步骤时，每 500ms 检测飞行高度
--   超过 max_height → HUD 闪红警告
--   在低空保持 check_duration_sec 秒后 → 触发 custom_event 推进任务

local QBCore = exports['qb-core']:GetCoreObject()

-- ══════════════════════════════════════════════════════════════
-- v0.9: 实体追踪 — 共享倒计时：违规走 / 合规停 / 永不重置
-- （必须在文件顶部声明，高度监控等模块引用此变量）
-- ══════════════════════════════════════════════════════════════

local EntityTracker = {
    active = false,
    questId = nil,
    trailer = {
        enabled = false,
        releaseStep = nil,
    },
    truck = {
        enabled = false,
        requireInSteps = {},
        currentStep = nil,
    },
    -- 超高空违规（飞行走私：超过高度限制也触发倒计时）
    heightEnabled = false,
    heightViolating = false,
    -- 共享倒计时（脱钩/下车/超高共用一个计时器）
    countdownTotal = 150,
    countdownRemaining = 150,
    countdownTicking = false,
    countdownEverStarted = false,
    lastNotifySec = 0,
    settleSec = 0,
}

-- ==============================================================
-- 飞行高度监控状态
-- ==============================================================

local heightMonitor = {
    active = false,
    maxHeight = 150.0,
    requiredDuration = 45,
    lowAltitudeTime = 0,      -- 累计低空时间（秒）
    lastCheckTime = 0,
    warnedHigh = false,
}

-- ==============================================================
-- 事件: 激活高度监控（由 quest 系统的 custom_event 步骤触发）
-- ==============================================================

RegisterNetEvent('quest:client:activateHeightMonitor', function(data)
    if not data then return end

    heightMonitor.active = true
    heightMonitor.maxHeight = data.max_height or 150.0
    heightMonitor.requiredDuration = data.check_duration_sec or 45
    heightMonitor.lowAltitudeTime = 0
    heightMonitor.lastCheckTime = GetGameTimer()
    heightMonitor.warnedHigh = false

    -- 联动 EntityTracker：超高也触发违规倒计时
    EntityTracker.heightEnabled = true
    EntityTracker.heightViolating = false

    QBCore.Functions.Notify(
        ('⚠️ 低空飞行监控已激活 — 保持 %.0f 米以下 %d 秒'):format(
            heightMonitor.maxHeight, heightMonitor.requiredDuration),
        'primary')
end)

RegisterNetEvent('quest:client:deactivateHeightMonitor', function()
    heightMonitor.active = false
    EntityTracker.heightEnabled = false
    EntityTracker.heightViolating = false
end)

-- ==============================================================
-- 每 500ms 检测飞行高度
-- ==============================================================

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(500)

        if not heightMonitor.active then goto continue end

        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if not veh or veh == 0 then
            -- 不在载具中
            heightMonitor.lowAltitudeTime = 0
            goto continue
        end

        -- 只对飞行载具监控
        local vehModel = GetEntityModel(veh)
        if not IsThisModelAHeli(vehModel) and not IsThisModelAPlane(vehModel) then
            heightMonitor.lowAltitudeTime = 0
            goto continue
        end

        -- 获取当前高度（海平面以上）
        local groundZ = 0.0
        local coords = GetEntityCoords(veh)
        local found, waterZ = GetWaterHeight(coords.x, coords.y, coords.z)
        if found and waterZ > groundZ then
            groundZ = waterZ
        end
        local altitude = coords.z - groundZ

        local now = GetGameTimer()
        local deltaTime = (now - heightMonitor.lastCheckTime) / 1000.0
        heightMonitor.lastCheckTime = now

        if altitude > heightMonitor.maxHeight then
            -- 高于限制: 重置累计时间 + 闪红 HUD 警告 + 触发违规倒计时
            heightMonitor.lowAltitudeTime = 0
            EntityTracker.heightViolating = true
            if not heightMonitor.warnedHigh then
                heightMonitor.warnedHigh = true
                QBCore.Functions.Notify(
                    ('🚨 雷达警告！飞行高度 %.0f 米超过 %.0f 米限制！'):format(
                        altitude, heightMonitor.maxHeight),
                    'error')
            end
        else
            -- 安全高度: 累计时间，解除超高违规
            heightMonitor.warnedHigh = false
            EntityTracker.heightViolating = false
            heightMonitor.lowAltitudeTime = heightMonitor.lowAltitudeTime + deltaTime

            if heightMonitor.lowAltitudeTime >= heightMonitor.requiredDuration then
                -- 完成！通过 custom_event 推进任务
                heightMonitor.active = false
                EntityTracker.heightEnabled = false
                EntityTracker.heightViolating = false
                QBCore.Functions.Notify('✅ 已成功穿越雷达网！', 'success')

                -- 发送事件让 quest 系统推进步骤
                TriggerServerEvent('quest:server:aviationHeightMonitorComplete')
                break
            elseif heightMonitor.lowAltitudeTime >= heightMonitor.requiredDuration - 10 then
                -- 快完成了，给提示
                local remaining = math.ceil(heightMonitor.requiredDuration - heightMonitor.lowAltitudeTime)
                if remaining > 0 and remaining <= 10 then
                    QBCore.Functions.Notify(
                        ('保持低空…还有 %d 秒'):format(remaining), 'primary')
                end
            end
        end

        ::continue::
    end
end)

-- ==============================================================
-- VALIDATOR 节点客户端处理器 (v0.7a)
-- PolyZone + E键 + 进度条 → TriggerServerEvent('quest:server:nodeComplete')
-- 支持 in_vehicle 模式（不下车操作）
-- ==============================================================

RegisterNetEvent('quest:client:nodeValidator', function(data)
    if not data or not data.coords then return end

    ClearZone()
    activeNode = { type = 'VALIDATOR', questId = data.questId, stepId = data.stepId, data = data }

    SetNewBlip(data.coords, data.label or 'Validate')

    local radius = data.radius or 10.0
    local targetVec = vector3(data.coords.x, data.coords.y, data.coords.z)

    -- v0.7.2: 交互线程 — 冷却计时替代 boolean，取消/失败后可重试
    local cooldownUntil = 0  -- 允许下次 E 键的时间戳 (GetGameTimer() ms)

    Citizen.CreateThread(function()
        local label = data.label or 'Validate'
        local inVehicle = data.in_vehicle or data.inVehicle or false   -- normalize both snake_case and camelCase
        local insideLast = false

        while activeNode and activeNode.stepId == data.stepId do
            Citizen.Wait(0)
            local ped = PlayerPedId()
            local pCoords = GetEntityCoords(ped)
            local dist = #(pCoords - targetVec)
            local inside = dist <= radius

            if inside and not insideLast then
                -- 刚进入区域
                if inVehicle then
                    local veh = GetVehiclePedIsIn(ped, false)
                    if not veh or veh == 0 then
                        QBCore.Functions.Notify('你必须坐在载具中', 'error')
                        insideLast = inside
                        goto continue
                    end
                end
                QBCore.Functions.Notify(('Press ~g~E~s~ to %s'):format(label), 'primary')
            elseif not inside and insideLast then
                QBCore.Functions.Notify('已离开任务区域', 'error')
            end
            insideLast = inside

            if inside and IsControlJustPressed(0, 38) and GetGameTimer() > cooldownUntil then -- E key 单次按下 + 冷却
                cooldownUntil = GetGameTimer() + 5000  -- 5秒冷却，避免连按

                if not inVehicle and data.animDict and data.animName then
                    RequestAnimDict(data.animDict)
                    while not HasAnimDictLoaded(data.animDict) do Citizen.Wait(10) end
                    TaskPlayAnim(PlayerPedId(), data.animDict, data.animName, 8.0, -8.0, data.duration or 3000, 1, 0, false, false, false)
                end

                local ped = PlayerPedId()
                local veh = GetVehiclePedIsIn(ped, false)
                local vehNetId = veh ~= 0 and NetworkGetNetworkIdFromEntity(veh) or nil

                if exports['progressbar'] then
                    exports['progressbar']:Progress({
                        name = ('quest_validator_%s'):format(data.stepId),  -- 唯一名防冲突
                        duration = data.duration or 3000,
                        label = label,
                        useWhileDead = false,
                        canCancel = true,
                        controlDisables = {
                            disableMovement = not inVehicle,
                            disableCarMovement = inVehicle,
                            disableMouse = false,
                            disableCombat = false,   -- v0.9: 不禁用战斗输入，避免干扰安全带/中控等键
                        },
                    }, function(cancelled)
                        if not cancelled and activeNode and activeNode.stepId == data.stepId then
                            TriggerServerEvent('quest:server:nodeComplete',
                                data.questId, data.stepId, 'VALIDATOR',
                                { position = targetVec, vehicleNetId = vehNetId }
                            )
                        end
                    end)
                else
                    Citizen.Wait(data.duration or 3000)
                    if activeNode and activeNode.stepId == data.stepId then
                        TriggerServerEvent('quest:server:nodeComplete',
                            data.questId, data.stepId, 'VALIDATOR',
                            { position = targetVec, vehicleNetId = vehNetId }
                        )
                    end
                end
            end
            ::continue::
        end
    end)

    -- PolyZone 补充（如果可用则叠加精确检测）
    if PolyZone then
        local zone = PolyZone:Create(targetVec, {
            name = ('quest_validator_%s_%s'):format(data.questId, data.stepId),
            offset = { 0.0, 0.0, 0.0 },
            scale = { radius, radius, 5.0 },
            debugPoly = false,
        })
        if zone then activeZone = zone end
    end
end)

-- ==============================================================
-- 挂车物理检测 + 安全生成 (v0.9 — 多生成点 + NPC避让 + blip + 归属校验)
-- ==============================================================

local trailerMonitor = {
    active = false,
    trailerModel = '',
    questId = nil,
    stepId = nil,
    wasHitched = false,
    spawnedTrailer = nil,        -- 生成的 trailer 实体句柄
    spawnedTrailerNetId = nil,   -- 网络 ID（用于归属校验 + 服务端清理）
    trailerBlip = nil,           -- 地图标记
    lastWrongNotify = 0,         -- 上次"挂错"提示的时间戳
}

-- 安全生成辅助: 检测坐标附近是否有车辆占用
local function IsSpawnPointBlocked(x, y, z, radius)
    local veh = GetClosestVehicle(x, y, z, radius or 8.0, 0, 70)
    return veh and veh ~= 0
end

-- 安全生成辅助: 清理坐标附近的 NPC 车辆（跳过玩家驾驶的车辆）
local function ClearNpcVehiclesNear(x, y, z, radius)
    local allVehicles = GetGamePool('CVehicle')
    local cleared = 0
    for _, veh in ipairs(allVehicles) do
        if DoesEntityExist(veh) then
            local vCoords = GetEntityCoords(veh)
            local dist = #(vector3(x, y, z) - vCoords)
            if dist <= (radius or 10.0) then
                local occupied = false
                for _, playerId in ipairs(GetActivePlayers()) do
                    local ped = GetPlayerPed(playerId)
                    if IsPedInVehicle(ped, veh, false) then
                        occupied = true
                        break
                    end
                end
                if not occupied then
                    DeleteEntity(veh)
                    cleared = cleared + 1
                end
            end
        end
    end
    return cleared
end

-- 安全生成: 依次尝试主坐标 → 备用坐标 → NPC清理 → 路网吸附
local function SafeSpawnTrailer(modelHash, primaryCoords, backupCoordsList, playerVeh)
    local candidates = {}
    if primaryCoords and primaryCoords.x then
        candidates[#candidates + 1] = primaryCoords
    end
    if backupCoordsList then
        for _, bc in ipairs(backupCoordsList) do
            candidates[#candidates + 1] = bc
        end
    end

    -- 阶段 1: 尝试候选坐标
    for i, coords in ipairs(candidates) do
        local x, y, z, h = coords.x, coords.y, coords.z or 0, coords.heading or 0.0
        if not IsSpawnPointBlocked(x, y, z, 8.0) then
            local trailer = CreateVehicle(modelHash, x, y, z + 0.5, h, true, false)
            if trailer and trailer ~= 0 then
                SetVehicleOnGroundProperly(trailer)
                Citizen.Wait(50)
                local tCoords = GetEntityCoords(trailer)
                if #(vector3(x, y, z) - tCoords) < 5.0 then
                    return trailer, x, y, z, h, i
                else
                    DeleteEntity(trailer)
                end
            end
        end
    end

    -- 阶段 2: 清理 NPC 车辆后重试主坐标
    if primaryCoords and primaryCoords.x then
        local cleared = ClearNpcVehiclesNear(primaryCoords.x, primaryCoords.y, primaryCoords.z, 12.0)
        if cleared > 0 then
            Citizen.Wait(100)
            if not IsSpawnPointBlocked(primaryCoords.x, primaryCoords.y, primaryCoords.z, 8.0) then
                local trailer = CreateVehicle(modelHash, primaryCoords.x, primaryCoords.y, primaryCoords.z + 0.5, primaryCoords.heading or 0.0, true, false)
                if trailer and trailer ~= 0 then
                    SetVehicleOnGroundProperly(trailer)
                    return trailer, primaryCoords.x, primaryCoords.y, primaryCoords.z, primaryCoords.heading or 0.0, 0
                end
            end
        end
    end

    -- 阶段 3: 路网节点 fallback
    if playerVeh and playerVeh ~= 0 then
        local vehCoords = GetEntityCoords(playerVeh)
        local vehHeading = GetEntityHeading(playerVeh)
        for offset = 10, 30, 5 do
            local bx = vehCoords.x - (math.sin(math.rad(vehHeading)) * offset)
            local by = vehCoords.y + (math.cos(math.rad(vehHeading)) * offset)
            local roadNode, nodeCoords = GetClosestVehicleNode(bx, by, vehCoords.z, 0, 3.0, 0)
            if roadNode then
                local nx, ny, nz = nodeCoords.x, nodeCoords.y, nodeCoords.z
                if not IsSpawnPointBlocked(nx, ny, nz, 6.0) then
                    local trailer = CreateVehicle(modelHash, nx, ny, nz + 0.5, vehHeading, true, false)
                    if trailer and trailer ~= 0 then
                        SetVehicleOnGroundProperly(trailer)
                        return trailer, nx, ny, nz, vehHeading, -1
                    end
                end
            end
        end
    end

    return nil
end

RegisterNetEvent('quest:client:monitorTrailerHitch', function(data)
    if not data then return end

    -- 清理前次生成的 trailer（如果存在）
    if trailerMonitor.trailerBlip then
        RemoveBlip(trailerMonitor.trailerBlip)
        trailerMonitor.trailerBlip = nil
    end
    if trailerMonitor.spawnedTrailer and DoesEntityExist(trailerMonitor.spawnedTrailer) then
        DeleteEntity(trailerMonitor.spawnedTrailer)
    end

    trailerMonitor.active = true
    trailerMonitor.trailerModel = data.trailerModel or 'trailerlogs'
    trailerMonitor.questId = data.questId
    trailerMonitor.stepId = data.stepId
    trailerMonitor.wasHitched = false
    trailerMonitor.spawnedTrailer = nil
    trailerMonitor.spawnedTrailerNetId = nil

    local modelHash = GetHashKey(trailerMonitor.trailerModel)
    RequestModel(modelHash)
    local timeout = 0
    while not HasModelLoaded(modelHash) and timeout < 50 do
        Citizen.Wait(100)
        timeout = timeout + 1
    end

    if not HasModelLoaded(modelHash) then
        QBCore.Functions.Notify('⚠️ 挂车模型加载失败: ' .. trailerMonitor.trailerModel, 'error')
        return
    end

    local usePreset = data.spawn_coords and data.spawn_coords.x
    local primaryCoords = usePreset and data.spawn_coords or nil
    local backupCoords = data.backup_coords or nil

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)

    local trailer, sx, sy, sz, sh, attemptIdx = SafeSpawnTrailer(modelHash, primaryCoords, backupCoords, veh)

    if trailer and trailer ~= 0 then
        trailerMonitor.spawnedTrailer = trailer
        SetModelAsNoLongerNeeded(modelHash)

        -- 延迟获取 netId（CreateVehicle 后需等一帧网络同步）
        Citizen.Wait(100)
        local netId = NetworkGetNetworkIdFromEntity(trailer)
        if netId and netId ~= 0 then
            trailerMonitor.spawnedTrailerNetId = netId
            TriggerServerEvent('quest:server:registerTrailer', data.questId, netId, trailerMonitor.trailerModel)
        end

        if usePreset then
            -- 预设坐标: 设地图标记引导玩家
            trailerMonitor.trailerBlip = AddBlipForCoord(sx, sy, sz)
            SetBlipSprite(trailerMonitor.trailerBlip, 479)       -- 拖车图标
            SetBlipColour(trailerMonitor.trailerBlip, 5)          -- 黄色
            SetBlipRoute(trailerMonitor.trailerBlip, true)
            SetBlipRouteColour(trailerMonitor.trailerBlip, 5)
            SetBlipDisplay(trailerMonitor.trailerBlip, 2)
            SetBlipAsShortRange(trailerMonitor.trailerBlip, false)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentString('挂车停放点')
            EndTextCommandSetBlipName(trailerMonitor.trailerBlip)

            local msg = '📦 挂车已放置在货场，请开车前往挂接...'
            if attemptIdx and attemptIdx > 0 then
                msg = ('📦 主停放点被占用，已使用备用点 #%d，请前往挂接...'):format(attemptIdx)
            end
            QBCore.Functions.Notify(msg, 'primary')
        else
            local msg = '📦 挂车已生成在后方，倒车靠近进行物理挂接...'
            if attemptIdx and attemptIdx == -1 then
                msg = '📦 挂车已生成在附近路网节点，倒车靠近进行物理挂接...'
            end
            QBCore.Functions.Notify(msg, 'primary')
        end
    else
        QBCore.Functions.Notify('⚠️ 挂车生成失败！附近无可用空间，请移动到开阔区域重试', 'error')
    end
end)

-- 监控线程: 检测物理挂接 + 归属校验
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(1000)
        if not trailerMonitor.active then goto trailer_end end

        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if not veh or veh == 0 then goto trailer_end end

        -- v0.9: 用 netId 反查当前实体句柄（句柄可能因引擎 GC 变化）
        local ourNetId = trailerMonitor.spawnedTrailerNetId
        local ourCurrentHandle = (ourNetId and ourNetId ~= 0) and NetworkGetEntityFromNetworkId(ourNetId) or nil

        local trailer = GetVehicleTrailerVehicle(veh)
        local isValidTrailer = trailer and trailer ~= 0 and DoesEntityExist(trailer)

        -- 如果 GetVehicleTrailerVehicle 返回无效，但 IsVehicleAttachedToTrailer 为真，
        -- 尝试用 netId 直接拿我们的 trailer 当前句柄来比对
        if not isValidTrailer and IsVehicleAttachedToTrailer(veh) and ourCurrentHandle then
            trailer = ourCurrentHandle
            isValidTrailer = true
        end

        if isValidTrailer and not trailerMonitor.wasHitched then
            -- 主判断: 用 netId 反查句柄比对（最可靠，不受 GC 影响）
            local isOurTrailer = (ourCurrentHandle and trailer == ourCurrentHandle)

            -- 次判断: 直接比对存储的句柄
            if not isOurTrailer then
                local ourStored = trailerMonitor.spawnedTrailer
                if ourStored and DoesEntityExist(ourStored) and trailer == ourStored then
                    isOurTrailer = true
                end
            end

            -- 次判断: netId 比对
            if not isOurTrailer and ourNetId then
                local hitchedNetId = NetworkGetNetworkIdFromEntity(trailer)
                if hitchedNetId ~= 0 and hitchedNetId == ourNetId then
                    isOurTrailer = true
                end
            end

            -- 兜底: 模型比对
            if not isOurTrailer then
                local expectedHash = GetHashKey(trailerMonitor.trailerModel)
                for retry = 1, 3 do
                    if IsVehicleModel(trailer, expectedHash) then
                        isOurTrailer = true; break
                    end
                    Citizen.Wait(200)
                end
            end

            local hitchedNetId = NetworkGetNetworkIdFromEntity(trailer)

            if isOurTrailer then
                trailerMonitor.wasHitched = true
                trailerMonitor.active = false

                -- 清除地图标记
                if trailerMonitor.trailerBlip then
                    RemoveBlip(trailerMonitor.trailerBlip)
                    trailerMonitor.trailerBlip = nil
                end

                print('[trailer-monitor] 📤 Sending trailerHitched to server')
                QBCore.Functions.Notify('✅ 挂车已成功挂接！出发！', 'success')
                TriggerServerEvent('quest:server:trailerHitched',
                    trailerMonitor.questId, trailerMonitor.stepId,
                    hitchedNetId or 0)
            else
                -- 挂错了 trailer，提示玩家去看地图（每 15s 最多一次）
                local now = GetGameTimer()
                if not trailerMonitor.lastWrongNotify or (now - trailerMonitor.lastWrongNotify) > 15000 then
                    trailerMonitor.lastWrongNotify = now
                    QBCore.Functions.Notify('⚠️ 这不是您的任务挂车！请查看地图黄色标记找到正确挂车', 'error', 5000)
                end
            end
        elseif trailer and trailer ~= 0 and not DoesEntityExist(trailer) then
            -- 幽灵实体，忽略（可能是引擎回收的旧 trailer 句柄）
        end

        ::trailer_end::
    end
end)

-- v0.9: 轻量 blip 清理（步骤推进时防御性调用，不改变 monitor 状态）
RegisterNetEvent('quest:client:clearTrailerBlip', function()
    if trailerMonitor.trailerBlip then
        RemoveBlip(trailerMonitor.trailerBlip)
        trailerMonitor.trailerBlip = nil
    end
end)

-- v0.9: 服务端通知清理未挂接的 trailer（含 blip + 实体）
RegisterNetEvent('quest:client:cleanupTrailer', function()
    if trailerMonitor.spawnedTrailer and DoesEntityExist(trailerMonitor.spawnedTrailer) then
        if not trailerMonitor.wasHitched then
            DeleteEntity(trailerMonitor.spawnedTrailer)
        end
    end
    if trailerMonitor.trailerBlip then
        RemoveBlip(trailerMonitor.trailerBlip)
        trailerMonitor.trailerBlip = nil
    end
    trailerMonitor.active = false
    trailerMonitor.spawnedTrailer = nil
    trailerMonitor.spawnedTrailerNetId = nil
end)

print('[quest-logistics-client] 🚛 v0.9: 多生成点安全 + NPC避让 + blip + 归属校验 + cleanup 已就绪')

--- 激活实体追踪
RegisterNetEvent('quest:client:entityTrackStart', function(data)
    if not data then return end
    EntityTracker.active = true
    EntityTracker.questId = data.questId
    EntityTracker.countdownTicking = false
    EntityTracker.countdownEverStarted = false
    EntityTracker.settleSec = 3     -- 3 秒宽限期，等待 GetVehicleTrailerVehicle 稳定
    EntityTracker.lastNotifySec = 0

    if data.trailer then
        EntityTracker.trailer.enabled = true
        EntityTracker.trailer.releaseStep = data.trailer.release_step
    end
    if data.truck then
        EntityTracker.truck.enabled = true
        EntityTracker.truck.requireInSteps = data.truck.require_in_steps or {}
    end
    if data.height then
        EntityTracker.heightEnabled = true
        EntityTracker.heightViolating = false
    end

    -- 取 trailer 和 truck 倒计时中较大的作为共享总额
    local tSec = (data.trailer and data.trailer.detach_countdown_sec) or 150
    local kSec = (data.truck and data.truck.exit_countdown_sec) or 150
    EntityTracker.countdownTotal = math.max(tSec, kSec)
    EntityTracker.countdownRemaining = EntityTracker.countdownTotal
end)

--- 更新当前步骤
RegisterNetEvent('quest:client:entityTrackStepUpdate', function(stepId)
    EntityTracker.truck.currentStep = stepId
    if EntityTracker.trailer.enabled and stepId == EntityTracker.trailer.releaseStep then
        EntityTracker.trailer.enabled = false
    end
end)

--- 停用
RegisterNetEvent('quest:client:entityTrackStop', function()
    EntityTracker.active = false
    EntityTracker.trailer.enabled = false
    EntityTracker.truck.enabled = false
    EntityTracker.heightEnabled = false
    EntityTracker.heightViolating = false
    EntityTracker.countdownTicking = false
end)

-- 巡检线程：共享倒计时 — 违规走/合规停/永不重置
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(1000)
        if not EntityTracker.active then Citizen.Wait(2000); goto tracker_end end

        -- 宽限期：激活后等 3 秒让 GetVehicleTrailerVehicle 稳定
        if EntityTracker.settleSec > 0 then
            EntityTracker.settleSec = EntityTracker.settleSec - 1
            goto tracker_end
        end

        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)

        -- 判断是否违规
        local detached = true
        if EntityTracker.trailer.enabled and veh and veh ~= 0 then
            local trailer = GetVehicleTrailerVehicle(veh)
            if trailer and trailer ~= 0 and DoesEntityExist(trailer) then
                detached = false
            elseif IsVehicleAttachedToTrailer(veh) then
                -- GetVehicleTrailerVehicle 可能返回无效句柄，IsVehicleAttachedToTrailer 更可靠
                detached = false
            end
        end

        local mustBeInVehicle = false
        if EntityTracker.truck.enabled and EntityTracker.truck.currentStep then
            for _, sid in ipairs(EntityTracker.truck.requireInSteps) do
                if sid == EntityTracker.truck.currentStep then
                    mustBeInVehicle = true; break
                end
            end
        end
        local exited = mustBeInVehicle and (not veh or veh == 0)

        -- 违规 = 脱钩 或 下车 或 超高
        local isViolating = (EntityTracker.trailer.enabled and detached)
            or (EntityTracker.truck.enabled and exited)
            or (EntityTracker.heightEnabled and EntityTracker.heightViolating)

        -- 载具毁坏检测：引擎健康 ≤ 0 → 立即失败（不等待倒计时）
        if EntityTracker.truck.enabled and veh and veh ~= 0 then
            local engineHealth = GetVehicleEngineHealth(veh)
            if engineHealth and engineHealth <= 0.0 then
                QBCore.Functions.Notify('💥 载具已毁坏！任务失败！', 'error', 8000)
                TriggerServerEvent('quest:server:entityTrackingFail', EntityTracker.questId, 'vehicle_destroyed')
                EntityTracker.active = false
                goto tracker_end
            end
        end

        if isViolating then
            if not EntityTracker.countdownEverStarted then
                EntityTracker.countdownEverStarted = true
                EntityTracker.lastNotifySec = 0
                QBCore.Functions.Notify(
                    ('⚠️ 违规！请在 %d 秒内恢复！（上车并挂接可暂停倒计时）'):format(EntityTracker.countdownRemaining),
                    'error', 6000)
            end
            EntityTracker.countdownTicking = true
        else
            -- 合规：暂停倒计时
            if EntityTracker.countdownTicking then
                EntityTracker.countdownTicking = false
                QBCore.Functions.Notify('✅ 已恢复运输状态，倒计时暂停', 'success', 3000)
            end
        end

        -- 倒计时走
        if EntityTracker.countdownTicking then
            EntityTracker.countdownRemaining = EntityTracker.countdownRemaining - 1
            local rem = EntityTracker.countdownRemaining

            -- 每 30s / 最后 10s 提示
            if rem > 10 and rem % 30 == 0 and rem ~= EntityTracker.lastNotifySec then
                EntityTracker.lastNotifySec = rem
                local mins = math.floor(rem / 60)
                local secs = rem % 60
                QBCore.Functions.Notify(('⏰ 剩余时间: %d:%02d（恢复运输可暂停）'):format(mins, secs), 'error', 4000)
            elseif rem <= 10 and rem > 0 and rem ~= EntityTracker.lastNotifySec then
                EntityTracker.lastNotifySec = rem
                QBCore.Functions.Notify(('🚨 最后 %d 秒！'):format(rem), 'error', 3000)
            end

            if rem <= 0 then
                QBCore.Functions.Notify('❌ 运输违规超时！任务失败！', 'error', 8000)
                TriggerServerEvent('quest:server:entityTrackingFail', EntityTracker.questId, 'entity_timeout')
                EntityTracker.active = false
            end
        end

        ::tracker_end::
    end
end)

print('[quest-logistics-client] 🎯 v0.9: EntityTracker 共享倒计时 — 违规走/合规停/永不重置 已就绪')

-- ══════════════════════════════════════════════════════════════
-- v0.8b: 驾驶疲劳追踪 (仅 Notify 警告，无自定义 HUD)
-- ══════════════════════════════════════════════════════════════

local Fatigue = {
    active = false,
    drivingSec = 0,
    warned45 = false,
    warned60 = false,
    forcedRest = false,
    restStart = 0,
    restRequiredSec = 180,
}

RegisterNetEvent('quest:client:fatigueActivate', function()
    Fatigue.active = true
    Fatigue.drivingSec = 0
    Fatigue.warned45 = false
    Fatigue.warned60 = false
    Fatigue.forcedRest = false
    Fatigue.restStart = 0
end)

RegisterNetEvent('quest:client:fatigueDeactivate', function()
    Fatigue.active = false
    Fatigue.forcedRest = false
end)

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(1000)
        if not Fatigue.active then goto fatigue_end end

        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        local isDriving = veh and veh ~= 0 and GetIsVehicleEngineRunning(veh)

        if Fatigue.forcedRest then
            if not isDriving then
                if (GetGameTimer() - Fatigue.restStart) / 1000 >= Fatigue.restRequiredSec then
                    Fatigue.forcedRest = false
                    Fatigue.drivingSec = 0
                    Fatigue.warned45 = false
                    Fatigue.warned60 = false
                    QBCore.Functions.Notify('🛏 休息完毕，可以继续驾驶了！', 'success')
                end
            end
            goto fatigue_end
        end

        if isDriving then
            Fatigue.drivingSec = Fatigue.drivingSec + 1
            if Fatigue.drivingSec >= 2700 and not Fatigue.warned45 then
                Fatigue.warned45 = true
                QBCore.Functions.Notify('⚠️ 连续驾驶 45 分钟，建议找地方休息！', 'primary', 8000)
            end
            if Fatigue.drivingSec >= 3600 and not Fatigue.warned60 then
                Fatigue.warned60 = true
                Fatigue.forcedRest = true
                Fatigue.restStart = GetGameTimer()
                QBCore.Functions.Notify('🚨 连续驾驶超过 60 分钟！请停车休息 3 分钟！', 'error', 10000)
            end
        end

        ::fatigue_end::
    end
end)

-- ══════════════════════════════════════════════════════════════
-- v0.8b: 运输计时器 — 采用 drug dealer 的 qb-hud 计时器模式
-- ══════════════════════════════════════════════════════════════

local TransportTimer = {
    active = false,
    questId = nil,
    timeLimitSec = 0,     -- 总时限（秒）
    remainingSec = 0,     -- 剩余秒数
    phase = 'normal',     -- fast / normal / overtime
}

RegisterNetEvent('quest:client:transportHudActivate', function(data)
    if not data then return end
    TransportTimer.active = true
    TransportTimer.questId = data.questId
    TransportTimer.timeLimitSec = (data.timeLimitMin or 15) * 60
    TransportTimer.remainingSec = TransportTimer.timeLimitSec
    TransportTimer.phase = 'normal'
end)

RegisterNetEvent('quest:client:transportHudDeactivate', function()
    TransportTimer.active = false
    if exports['qb-hud'] then
        exports['qb-hud']:HideTaskTimer()
    end
end)

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(1000)
        if not TransportTimer.active then
            Citizen.Wait(2000)
            goto timer_end
        end

        TransportTimer.remainingSec = TransportTimer.remainingSec - 1
        if TransportTimer.remainingSec <= 0 then
            TransportTimer.remainingSec = 0
            TransportTimer.phase = 'overtime'
        end

        local mins = math.floor(math.abs(TransportTimer.remainingSec) / 60)
        local secs = math.abs(TransportTimer.remainingSec) % 60

        -- 阶段判定 (drug dealer 风格)
        local phase
        if TransportTimer.remainingSec > TransportTimer.timeLimitSec * 0.5 then
            phase = 'fast'
        elseif TransportTimer.remainingSec > 0 then
            phase = 'normal'
        else
            phase = 'overtime'
        end
        TransportTimer.phase = phase

        -- 委托给 qb-hud 显示（与 drug dealer 一致）
        if exports['qb-hud'] then
            exports['qb-hud']:ShowTaskTimer(mins, secs, phase)
        end

        ::timer_end::
    end
end)

print('[quest-logistics-client] 🚛 v0.8b: 疲劳追踪 + qb-hud计时器 已就绪 (无自定义HUD)')
