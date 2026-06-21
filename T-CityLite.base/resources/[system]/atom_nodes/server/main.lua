-- ============================================================================
-- atom_nodes/server/main.lua — 原子任务节点服务端响应层 v2.0
-- ============================================================================
-- 核心逻辑:
--   客户端上报 → 服务端权威验证 (距离 + 物品 + 载具) → 单次响应 → 推进任务状态
--   绝不循环轮询! 绝不主动检查玩家坐标!
-- ============================================================================

local QBCore = exports['qb-core']:GetCoreObject()

-- ── 统一节点到达处理 ──────────────────────────────────────────────────

RegisterNetEvent('atom:server:nodeReached', function(questId, stepId, nodeType, clientData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- GOTO: 距离验证
    if nodeType == 'GOTO' then
        local playerCoords = GetEntityCoords(GetPlayerPed(src))
        local targetCoords = clientData.position
        if targetCoords then
            local dist = #(playerCoords - vector3(targetCoords.x, targetCoords.y, targetCoords.z))
            if dist > 30.0 then
                -- 距离太远, 可能是作弊
                return
            end
        end
    end

    -- INTERACT: 距离验证 (更严格)
    if nodeType == 'INTERACT' then
        local playerCoords = GetEntityCoords(GetPlayerPed(src))
        local targetCoords = clientData.position
        if targetCoords then
            local dist = #(playerCoords - vector3(targetCoords.x, targetCoords.y, targetCoords.z))
            if dist > 10.0 then return end
        end
    end

    -- DELIVER: 距离 + 物品 + 载具验证
    if nodeType == 'DELIVER' then
        local playerCoords = GetEntityCoords(GetPlayerPed(src))
        local targetCoords = clientData.position
        if targetCoords then
            local dist = #(playerCoords - vector3(targetCoords.x, targetCoords.y, targetCoords.z))
            if dist > 15.0 then return end
        end

        -- 物品检查
        if clientData.itemName and clientData.itemAmount then
            if GetResourceState('qb-inventory') ~= 'missing' then
                if not exports['qb-inventory']:HasItem(src, clientData.itemName, clientData.itemAmount) then
                    TriggerClientEvent('QBCore:Notify', src,
                        ('Missing: %s ×%d'):format(clientData.itemName, clientData.itemAmount), 'error')
                    return
                end
                exports['qb-inventory']:RemoveItem(src, clientData.itemName, clientData.itemAmount, false)
            end
        end

        -- 载具检查
        if clientData.vehicleModel then
            local ped = GetPlayerPed(src)
            local veh = GetVehiclePedIsIn(ped, false)
            if veh == 0 then
                TriggerClientEvent('QBCore:Notify', src, 'You must be in a vehicle', 'error')
                return
            end
            local expectedHash = type(clientData.vehicleModel) == 'string'
                and joaat(clientData.vehicleModel) or clientData.vehicleModel
            if GetEntityModel(veh) ~= expectedHash then
                TriggerClientEvent('QBCore:Notify', src, 'Wrong vehicle', 'error')
                return
            end
        end
    end

    -- ── 验证通过 → 广播步骤完成事件 (由外部任务系统消费) ────────────
    TriggerEvent('atom:server:stepCompleted', src, questId, stepId, nodeType, clientData)
    TriggerEvent(('atom:server:stepCompleted:%s:%s'):format(questId, stepId), src, clientData)

    -- 清理客户端节点
    TriggerClientEvent('atom:client:clearNode', src, questId, stepId)

    -- 通知玩家
    TriggerClientEvent('QBCore:Notify', src,
        ('✅ %s completed!'):format(nodeType), 'success')
end)

-- ── 对外 API: 启动节点 ────────────────────────────────────────────────

---启动一个原子节点
---@param source number
---@param questId string
---@param stepId string
---@param node table { type='GOTO'|'INTERACT'|'DELIVER', payload={...} }
function StartNode(source, questId, stepId, node)
    local nodeType = node.type and node.type:upper()
    local payload = node.payload or node.data or {}

    if nodeType == 'GOTO' then
        TriggerClientEvent('atom:client:goto', source, {
            questId = questId,
            stepId = stepId,
            coords = payload.coords,
            radius = payload.radius or 5.0,
            label = payload.label or 'Destination',
        })
    elseif nodeType == 'INTERACT' then
        TriggerClientEvent('atom:client:interact', source, {
            questId = questId,
            stepId = stepId,
            coords = payload.coords or payload.targetCoords,
            radius = payload.radius or 3.0,
            duration = payload.duration or 3000,
            label = payload.label or 'Interact',
            animDict = payload.animDict,
            animName = payload.animName,
        })
    elseif nodeType == 'DELIVER' then
        TriggerClientEvent('atom:client:deliver', source, {
            questId = questId,
            stepId = stepId,
            destCoords = payload.destCoords,
            radius = payload.radius or 5.0,
            label = payload.label or 'Delivery',
            item = payload.item,
            amount = payload.amount,
            vehicleModel = payload.vehicleModel,
        })
    end
end
exports('StartNode', StartNode)

---取消玩家所有节点
---@param source number
---@param questId string
function CancelAllNodes(source, questId)
    TriggerClientEvent('atom:client:clearAll', source, questId)
end
exports('CancelAllNodes', CancelAllNodes)

print('[atom_nodes] ✅ Event-driven node engine started (GOTO | INTERACT | DELIVER)')
