-- quest_entity_placement.lua — 实体放置节点客户端 (v0.10)
--
-- 职责:
--   1. 接收 quest:client:nodePlacement 事件
--   2. GPS 导航 + 原生 Checkpoint 光圈 + blip 可视化
--   3. 检测货柜（而非拖头）进入回收区 → 自动弹进度条
--   4. 脱钩 + 冻结 + 无敌 → 上报服务端
--   5. 服务端回收后清理本地标记

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 放置节点状态
-- ==============================================================

local PlacementNode = {
    active = false,
    questId = nil,
    stepId = nil,
    zone = nil,          -- { x, y, z, radius }
    action = nil,        -- 'detach_trailer' etc.
    label = 'Placing...',
    duration = 5000,
    inVehicle = true,
    cooldownUntil = 0,
    checkpoint = nil,    -- CreateCheckpoint 返回的 handle
    blip = nil,
}

-- ==============================================================
-- 客户端可视化: Checkpoint 光圈 + blip + GPS 导航
-- ==============================================================

local function CreateDropZoneVisuals(zone)
    -- 1. 原生 Checkpoint 光圈（游戏内可见的立体圆柱标记）
    --    类型 45 = 大环形光圈，类型 4 = 标准圆柱+Checker
    if PlacementNode.checkpoint then
        DeleteCheckpoint(PlacementNode.checkpoint)
    end
    PlacementNode.checkpoint = CreateCheckpoint(
        45,                                  -- checkpointType: 大环形
        zone.x, zone.y, zone.z - 0.5,       -- 略低于地面
        zone.x, zone.y, zone.z,             -- 目标方向（同点）
        zone.radius,                         -- 半径
        0, 255, 100, 150,                    -- RGBA: 绿色半透明
        0                                    -- reserved
    )
    -- 设置光圈始终可见（不受距离限制）
    SetCheckpointCylinderHeight(PlacementNode.checkpoint, 2.0, 2.0, zone.radius)

    -- 2. GPS 导航点
    SetNewWaypoint(zone.x, zone.y)

    -- 3. 地图 Blip
    if PlacementNode.blip then
        RemoveBlip(PlacementNode.blip)
    end
    PlacementNode.blip = AddBlipForCoord(zone.x, zone.y, zone.z)
    SetBlipSprite(PlacementNode.blip, 479)        -- 拖车图标
    SetBlipColour(PlacementNode.blip, 2)           -- 绿色
    SetBlipDisplay(PlacementNode.blip, 2)
    SetBlipAsShortRange(PlacementNode.blip, false)
    SetBlipRoute(PlacementNode.blip, true)
    SetBlipRouteColour(PlacementNode.blip, 2)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString('卸货区')
    EndTextCommandSetBlipName(PlacementNode.blip)
end

local function ClearDropZoneVisuals()
    if PlacementNode.checkpoint then
        DeleteCheckpoint(PlacementNode.checkpoint)
        PlacementNode.checkpoint = nil
    end
    if PlacementNode.blip then
        RemoveBlip(PlacementNode.blip)
        PlacementNode.blip = nil
    end
end

-- ==============================================================
-- 事件: 激活 placement 节点
-- ==============================================================

RegisterNetEvent('quest:client:nodePlacement', function(data)
    if not data or not data.dropzone then
        QBCore.Functions.Notify('⚠️ 回收区数据异常，请联系管理员', 'error')
        return
    end

    ClearDropZoneVisuals()
    PlacementNode.active = false

    local zone = data.dropzone
    PlacementNode.active = true
    PlacementNode.questId = data.questId
    PlacementNode.stepId = data.stepId
    PlacementNode.zone = zone
    PlacementNode.action = data.action or 'detach_trailer'
    PlacementNode.label = data.label or '卸货中...'
    PlacementNode.duration = data.duration or 5000
    PlacementNode.inVehicle = data.inVehicle ~= false
    PlacementNode.cooldownUntil = 0

    CreateDropZoneVisuals(zone)

    QBCore.Functions.Notify('📦 卸货区已标记 (GPS导航 + 绿色光圈)，请将挂车驶入圈内', 'primary')
    print(('[placement-client] 📍 Node activated: quest=%s step=%s zone=(%.1f,%.1f) radius=%.1f'):format(
        data.questId, data.stepId, zone.x, zone.y, zone.radius))
end)

-- ==============================================================
-- 主巡检线程: 检测货柜进入回收区 → 自动脱钩
--
-- 关键修复 (v0.10):
--   用货柜(TRAILER)坐标判定，而非拖头坐标
--   避免"拖头进圈脱钩后货柜在圈外被拒"的问题
-- ==============================================================

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(500)

        if not PlacementNode.active then
            Citizen.Wait(1000)
            goto placement_end
        end

        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)

        if PlacementNode.inVehicle and (not veh or veh == 0) then
            goto placement_end
        end

        -- 获取货柜实体（判定对象是货柜，不是拖头）
        local trailer = GetVehicleTrailerVehicle(veh)
        if not trailer or trailer == 0 or not DoesEntityExist(trailer) then
            if not IsVehicleAttachedToTrailer(veh) then
                goto placement_end
            end
        end

        -- ══ 用货柜坐标判定是否进入回收区 ══
        local zone = PlacementNode.zone
        if not zone then goto placement_end end

        local checkCoords
        if trailer and trailer ~= 0 and DoesEntityExist(trailer) then
            checkCoords = GetEntityCoords(trailer)
        else
            checkCoords = GetEntityCoords(veh)  -- fallback
        end

        local dist = #(checkCoords - vector3(zone.x, zone.y, zone.z))
        local inside = dist <= zone.radius

        if not inside then
            goto placement_end
        end

        -- 冷却检查
        local now = GetGameTimer()
        if now < PlacementNode.cooldownUntil then
            goto placement_end
        end

        -- ─── 货柜已进入回收区！自动触发进度条 ───
        PlacementNode.cooldownUntil = now + 10000

        local label = PlacementNode.label
        local duration = PlacementNode.duration

        QBCore.Functions.Notify(('🔄 %s（自动）...'):format(label), 'primary')

        if exports['progressbar'] then
            exports['progressbar']:Progress({
                name = ('quest_placement_%s'):format(PlacementNode.stepId),
                duration = duration,
                label = label,
                useWhileDead = false,
                canCancel = true,
                controlDisables = {
                    disableMovement = false,
                    disableCarMovement = true,
                    disableMouse = false,
                    disableCombat = false,
                },
            }, function(cancelled)
                if cancelled then
                    PlacementNode.cooldownUntil = 0
                    QBCore.Functions.Notify('卸货取消，可重新倒入卸货区', 'error')
                    return
                end

                if not PlacementNode.active then return end

                local ped2 = PlayerPedId()
                local veh2 = GetVehiclePedIsIn(ped2, false)
                if not veh2 or veh2 == 0 then
                    QBCore.Functions.Notify('你已离开载具！卸货失败', 'error')
                    PlacementNode.cooldownUntil = 0
                    return
                end

                local trailer2 = GetVehicleTrailerVehicle(veh2)
                if not trailer2 or trailer2 == 0 or not DoesEntityExist(trailer2) then
                    if not IsVehicleAttachedToTrailer(veh2) then
                        QBCore.Functions.Notify('挂车已丢失！卸货失败', 'error')
                        PlacementNode.cooldownUntil = 0
                        return
                    end
                end
                if not trailer2 or trailer2 == 0 then
                    trailer2 = veh2  -- fallback, 不应该到达这里
                end

                -- ═══ 脱钩 ═══
                DetachVehicleFromTrailer(veh2)

                -- 冻结货柜 + 无敌（防止 NPC 推动导致位置偏移）
                Citizen.Wait(200)
                if DoesEntityExist(trailer2) then
                    FreezeEntityPosition(trailer2, true)
                    SetEntityInvincible(trailer2, true)
                end

                local trailerCoords = GetEntityCoords(trailer2)
                local trailerNetId = NetworkGetNetworkIdFromEntity(trailer2)

                print(('[placement-client] 📤 Placement complete: trailer=%d, pos=(%.1f,%.1f,%.1f)'):format(
                    trailerNetId or 0, trailerCoords.x, trailerCoords.y, trailerCoords.z))

                QBCore.Functions.Notify('✅ 货柜已卸下，正在核验...', 'success')

                TriggerServerEvent('quest:server:placementComplete',
                    PlacementNode.questId,
                    PlacementNode.stepId,
                    {
                        trailerNetId = trailerNetId,
                        trailerPosition = trailerCoords,
                        zone = PlacementNode.zone,
                    }
                )

                PlacementNode.active = false
                ClearDropZoneVisuals()
            end)
        else
            -- 无 progressbar: 简单延迟
            Citizen.Wait(duration)
            if not PlacementNode.active then goto placement_end end

            local ped2 = PlayerPedId()
            local veh2 = GetVehiclePedIsIn(ped2, false)
            if not veh2 or veh2 == 0 then
                PlacementNode.cooldownUntil = 0
                goto placement_end
            end

            local trailer2 = GetVehicleTrailerVehicle(veh2)
            if not trailer2 or trailer2 == 0 or not DoesEntityExist(trailer2) then
                PlacementNode.cooldownUntil = 0
                goto placement_end
            end

            DetachVehicleFromTrailer(veh2)
            Citizen.Wait(200)
            if DoesEntityExist(trailer2) then
                FreezeEntityPosition(trailer2, true)
                SetEntityInvincible(trailer2, true)
            end

            local trailerCoords = GetEntityCoords(trailer2)
            local trailerNetId = NetworkGetNetworkIdFromEntity(trailer2)

            TriggerServerEvent('quest:server:placementComplete',
                PlacementNode.questId,
                PlacementNode.stepId,
                {
                    trailerNetId = trailerNetId,
                    trailerPosition = trailerCoords,
                    zone = PlacementNode.zone,
                }
            )

            PlacementNode.active = false
            ClearDropZoneVisuals()
        end

        ::placement_end::
    end
end)

-- ==============================================================
-- 事件: 服务端回收后清理本地
-- ==============================================================

RegisterNetEvent('quest:client:entityRecycled', function(data)
    if not data then return end
    if PlacementNode.questId == data.questId then
        ClearDropZoneVisuals()
        PlacementNode.active = false
    end
end)

-- ==============================================================
-- 事件: 节点取消
-- ==============================================================

RegisterNetEvent('quest:client:nodeCancel', function(data)
    if PlacementNode.active and PlacementNode.questId == data.questId and PlacementNode.stepId == data.stepId then
        PlacementNode.active = false
        ClearDropZoneVisuals()
    end
end)

RegisterNetEvent('quest:client:clearAllNodes', function(data)
    if PlacementNode.active and PlacementNode.questId == data.questId then
        PlacementNode.active = false
        ClearDropZoneVisuals()
    end
end)

print('[quest-entity-placement-client] ✅ v0.10: placement 节点 (GPS+Checkpoint+货柜坐标判定) 已就绪')

-- ==============================================================
-- 🔬 /testplacement — 可视化预览命令
--    在玩家前方 15m 生成 truck marker + container 矩形
--    回车即见效果，不用走完整任务
-- ==============================================================

local testPlacementActive = false
local testTruckCoords = nil
local testContainerZone = nil

RegisterCommand('testplacement', function()
    local ped = PlayerPedId()
    local pCoords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local rad = math.rad(heading)

    -- 车头泊位: 玩家前方 15m
    testTruckCoords = {
        x = pCoords.x + math.cos(rad) * 15.0,
        y = pCoords.y + math.sin(rad) * 15.0,
        z = pCoords.z - 1.0,
        heading = heading,
    }

    -- 集装箱放置区: 车头后方 10m (即玩家前方 5m)
    local containerCenterX = pCoords.x + math.cos(rad) * 5.0
    local containerCenterY = pCoords.y + math.sin(rad) * 5.0
    local containerCenterZ = pCoords.z - 1.0

    testContainerZone = {
        cx = containerCenterX,
        cy = containerCenterY,
        cz = containerCenterZ,
        heading = heading,
        width = 3.0,     -- 集装箱宽 2.5m + 余量
        length = 12.0,   -- 40ft 集装箱
    }

    if testPlacementActive then
        testPlacementActive = false
        QBCore.Functions.Notify('🔬 测试标记已关闭', 'primary')
    else
        testPlacementActive = true
        -- 设 GPS 导航点到车头泊位
        SetNewWaypoint(testTruckCoords.x, testTruckCoords.y)
        QBCore.Functions.Notify('🔬 测试标记已开启 — 前方绿色卡车图标=拖头泊位, 金色框=货柜区', 'success')
    end
end, false)

-- 每帧绘制
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        if not testPlacementActive then
            Citizen.Wait(500)
            goto test_draw_end
        end

        local ped = PlayerPedId()
        local pCoords = GetEntityCoords(ped)
        local dist = #(pCoords - vector3(testTruckCoords.x, testTruckCoords.y, testTruckCoords.z))
        if dist > 120 then goto test_draw_end end

        -- ─── 1. 车头泊位: DrawMarker type 39 (TruckSymbol) ───
        DrawMarker(39,
            testTruckCoords.x, testTruckCoords.y, testTruckCoords.z + 0.5,
            0, 0, 0,                              -- dirX, dirY, dirZ
            0, 0, testTruckCoords.heading,        -- rotX, rotY, rotZ
            2.0, 2.0, 2.0,                        -- scale
            0, 255, 100, 200,                      -- RGBA 绿色
            false, false, 0, false, nil, nil, false)

        -- ─── 2. 集装箱放置区: DrawPoly 半透明矩形 ───
        local hdg = math.rad(testContainerZone.heading)
        local hw = testContainerZone.width / 2
        local hl = testContainerZone.length / 2
        local cx, cy, cz = testContainerZone.cx, testContainerZone.cy, testContainerZone.cz

        -- 四个角（世界坐标，带旋转）
        local function rotPoint(ox, oy)
            local rx = ox * math.cos(hdg) - oy * math.sin(hdg)
            local ry = ox * math.sin(hdg) + oy * math.cos(hdg)
            return cx + rx, cy + ry
        end

        local x1, y1 = rotPoint(-hl, -hw)  -- 左前
        local x2, y2 = rotPoint( hl, -hw)  -- 右前
        local x3, y3 = rotPoint( hl,  hw)  -- 右后
        local x4, y4 = rotPoint(-hl,  hw)  -- 左后

        -- DrawPoly: 金色半透明填充矩形
        DrawPoly(x1, y1, cz + 0.02, x2, y2, cz + 0.02, x3, y3, cz + 0.02, x4, y4, cz + 0.02,
            255, 215, 0, 80)  -- 金色 80/255 透明度

        -- DrawLine: 白色边框（更清晰）
        local borderAlpha = 180
        DrawLine(x1, y1, cz + 0.04, x2, y2, cz + 0.04, 255, 255, 255, borderAlpha)
        DrawLine(x2, y2, cz + 0.04, x3, y3, cz + 0.04, 255, 255, 255, borderAlpha)
        DrawLine(x3, y3, cz + 0.04, x4, y4, cz + 0.04, 255, 255, 255, borderAlpha)
        DrawLine(x4, y4, cz + 0.04, x1, y1, cz + 0.04, 255, 255, 255, borderAlpha)

        -- ─── 3. 标签文字浮在空中 ───
        -- 车头泊位标签
        local labelOn = true
        SetDrawOrigin(testTruckCoords.x, testTruckCoords.y, testTruckCoords.z + 3.0, 0)
        BeginTextCommandDisplayText('STRING')
        AddTextComponentSubstringPlayerName('🚛 拖头泊位')
        SetTextScale(0.4, 0.4)
        SetTextColour(0, 255, 100, 255)
        SetTextCentre(true)
        EndTextCommandDisplayText(0, 0, 0)
        ClearDrawOrigin()

        -- 集装箱区标签
        SetDrawOrigin(testContainerZone.cx, testContainerZone.cy, testContainerZone.cz + 2.0, 0)
        BeginTextCommandDisplayText('STRING')
        AddTextComponentSubstringPlayerName('📦 货柜放置区')
        SetTextScale(0.4, 0.4)
        SetTextColour(255, 215, 0, 255)
        SetTextCentre(true)
        EndTextCommandDisplayText(0, 0, 0)
        ClearDrawOrigin()

        ::test_draw_end::
    end
end)

print('[quest-entity-placement-client] 🔬 /testplacement 预览命令已就绪')
