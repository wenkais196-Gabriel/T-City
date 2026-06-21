-- quest_entity_placement.lua — 实体放置节点服务端 (v0.10)
--
-- 职责:
--   1. 回收区坐标生成 (路网搜索 + 避障)
--   2. placement 节点完成事件处理 (quest:server:placementComplete)
--   3. 验证实体在回收区内的位置
--   4. 调度延迟回收
--
-- 注意: 实体冻结/无敌由客户端在 DetachVehicleFromTrailer 后执行

local QBCore = exports['qb-core']:GetCoreObject()

QuestEntityPlacement = {}

-- 缓存的回收区坐标: citizenid_questId → { x, y, z, radius }
local _dropZoneCache = {}

-- ==============================================================
-- 公开 API
-- ==============================================================

--- 在目标坐标附近生成回收区（纯服务端数学偏移，不依赖任何 native）
---@param originCoords table {x, y, z}
---@param searchMin number  搜索最小半径 (米)
---@param searchMax number  搜索最大半径 (米)
---@param zoneRadius number 回收区判定半径
---@return table|nil { x, y, z, heading, radius }
function QuestEntityPlacement.GenerateDropZone(originCoords, searchMin, searchMax, zoneRadius)
    if not originCoords or not originCoords.x then
        print('[quest-placement] ⚠️ GenerateDropZone: invalid origin coords')
        return nil
    end

    searchMin = searchMin or 15
    searchMax = searchMax or 40
    zoneRadius = zoneRadius or 10.0

    -- 多角度、多距离搜索纯数学偏移
    for _, angle in ipairs({0, 45, 90, 135, 180, 225, 270, 315}) do
        for dist = searchMin, searchMax, 5 do
            local rad = math.rad(angle)
            local bx = originCoords.x + math.cos(rad) * dist
            local by = originCoords.y + math.sin(rad) * dist
            local bz = originCoords.z

            local heading = math.deg(math.atan2(originCoords.y - by, originCoords.x - bx))
            local zone = {
                x = bx, y = by, z = bz,
                heading = heading,
                radius = zoneRadius,
            }
            print(('[quest-placement] 📍 DropZone generated: (%.1f, %.1f, %.1f) dist=%.0fm angle=%d°'):format(
                bx, by, bz, dist, angle))
            return zone
        end
    end

    -- Fallback: 原点偏移 20m
    local fallback = {
        x = originCoords.x + 20,
        y = originCoords.y + 10,
        z = originCoords.z,
        heading = 0,
        radius = zoneRadius,
    }
    print('[quest-placement] ⚠️ DropZone fallback used')
    return fallback
end

--- 缓存回收区坐标 (供后续验证使用)
---@param citizenid string
---@param questId string
---@param zone table {x, y, z, radius}
function QuestEntityPlacement.CacheDropZone(citizenid, questId, zone)
    local key = ('%s_%s'):format(citizenid, questId)
    _dropZoneCache[key] = zone
end

--- 获取缓存的回收区
---@param citizenid string
---@param questId string
---@return table|nil
function QuestEntityPlacement.GetDropZone(citizenid, questId)
    local key = ('%s_%s'):format(citizenid, questId)
    return _dropZoneCache[key]
end

--- 清理缓存
---@param citizenid string
---@param questId string
function QuestEntityPlacement.ClearDropZone(citizenid, questId)
    local key = ('%s_%s'):format(citizenid, questId)
    _dropZoneCache[key] = nil
end

-- ==============================================================
-- 事件: placement 节点完成 (客户端上报)
-- ==============================================================

RegisterNetEvent('quest:server:placementComplete', function(questId, stepId, placementData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    local citizenid = Player.PlayerData.citizenid

    print(('[quest-placement] 📥 placementComplete: src=%d, quest=%s, step=%s'):format(
        src, questId, stepId))

    placementData = placementData or {}

    -- 1. 获取回收区
    local zone = QuestEntityPlacement.GetDropZone(citizenid, questId)
    if not zone then
        TriggerClientEvent('QBCore:Notify', src, '回收区数据丢失，请联系管理员', 'error')
        print(('[quest-placement] ❌ No drop zone cached for %s | %s'):format(citizenid, questId))
        return
    end

    -- 2. 获取货柜实体 (从 Registry)
    local trailerNetId = QuestEntityRegistry.GetNetId(citizenid, questId, 'trailer')
    if not trailerNetId then
        TriggerClientEvent('QBCore:Notify', src, '找不到货柜实体，请重试', 'error')
        print(('[quest-placement] ❌ No trailer entity registered for %s | %s'):format(citizenid, questId))
        return
    end

    -- 3. 权威验证货柜位置
    local trailer = NetworkGetEntityFromNetworkId(trailerNetId)
    if not trailer or trailer == 0 or not DoesEntityExist(trailer) then
        TriggerClientEvent('QBCore:Notify', src, '货柜实体已丢失！任务无法完成', 'error')
        print(('[quest-placement] ❌ Trailer entity does not exist: netId=%d'):format(trailerNetId))
        return
    end

    local trailerCoords = GetEntityCoords(trailer)
    local zoneCenter = vector3(zone.x, zone.y, zone.z)
    local dist = #(trailerCoords - zoneCenter)

    print(('[quest-placement] 🔍 Position check: trailer=(%.1f,%.1f,%.1f) zone=(%.1f,%.1f,%.1f) dist=%.1f radius=%.1f'):format(
        trailerCoords.x, trailerCoords.y, trailerCoords.z,
        zone.x, zone.y, zone.z, dist, zone.radius))

    if dist > zone.radius then
        local msg = ('货柜未在卸柜区内！距离还差 %.0f 米（需要 %.0f 米以内）。请重新挂接并倒入卸柜区。'):format(
            dist - zone.radius, zone.radius)
        TriggerClientEvent('QBCore:Notify', src, msg, 'error')
        -- v0.10: 解冻货柜，允许玩家重新挂接
        FreezeEntityPosition(trailer, false)
        -- 解无敌由客户端通过 ClearEntityInvincible 或重新 Attach 时自动处理
        return
    end

    -- 4. 验证通过 — 推进步骤
    print('[quest-placement] ✅ Placement verified! Advancing step.')
    TriggerClientEvent('QBCore:Notify', src, '✅ 卸柜完成！货柜已签收。', 'success')

    -- 5. 调度延迟回收 (玩家走后消失)
    QuestEntityRegistry.ScheduleRecycle(citizenid, questId, 'trailer')

    -- 6. 清理缓存 + 推进步骤
    QuestEntityPlacement.ClearDropZone(citizenid, questId)

    -- 走统一的 nodeComplete 管道推进步骤
    local success, message = QuestManager.AdvanceStep(citizenid, questId, stepId, {
        placement_verified = true,
        trailer_position = trailerCoords,
        zone = zone,
    })

    if not success then
        TriggerClientEvent('QBCore:Notify', src, message or '步骤推进失败', 'error')
    end
end)

-- ==============================================================
-- 事件: 任务完成/失败时清理缓存
-- ==============================================================

AddEventHandler('quest:server:onQuestCompleted', function(citizenid, questId)
    QuestEntityPlacement.ClearDropZone(citizenid, questId)
end)

AddEventHandler('quest:server:onQuestFailed', function(citizenid, questId, reason)
    QuestEntityPlacement.ClearDropZone(citizenid, questId)
end)

print('[quest-entity-placement] ✅ v0.10: placement 节点服务端 (回收区生成 + 验证 + 调度回收) 已就绪')
