-- ============================================================================
-- atom_nodes/client/main.lua — 原子任务节点客户端事件驱动层 v2.0
-- ============================================================================
-- 设计铁律:
--   "服务器绝对不主动循环计算玩家坐标或状态 (CPU 消耗为 0)。
--    客户端通过 PolyZone 监听玩家进入区域, 仅在触发瞬间向服务端上报。"
--
-- 三个原子节点:
--   GOTO     — 前往坐标 (PolyZone 自动检测, 到达即上报)
--   INTERACT — 与 NPC/物体交互 (进度条 + E键 + 动画)
--   DELIVER  — 运送物资/车辆到目标点 (PolyZone + 物品/载具检查)
-- ============================================================================

local activeNodes = {}  -- { [questId_stepId] = { type, data, zone } }

-- ── GOTO: 到达即触发 ──────────────────────────────────────────────────

RegisterNetEvent('atom:client:goto', function(data)
    -- data: { questId, stepId, coords={x,y,z}, radius=5.0, label='Destination' }
    local key = ('%s_%s'):format(data.questId, data.stepId)
    ClearNode(key)

    local zone = PolyZone:Create(
        vector3(data.coords.x, data.coords.y, data.coords.z),
        { name = key, offset = {0,0,0}, scale = {data.radius or 5, data.radius or 5, 10}, debugPoly = false }
    )

    zone:onPlayerInOut(function(isInside)
        if isInside then
            -- 到达! 上报服务端
            TriggerServerEvent('atom:server:nodeReached', data.questId, data.stepId, 'GOTO', {
                position = data.coords,
            })
            -- 到达后自动清理
            ClearNode(key)
        end
    end)

    if data.coords then
        SetNewBlip(data.coords, data.label or 'Destination')
    end

    activeNodes[key] = { type = 'GOTO', data = data, zone = zone }
end)

-- ── INTERACT: E键交互 + 进度条 ────────────────────────────────────────

RegisterNetEvent('atom:client:interact', function(data)
    local key = ('%s_%s'):format(data.questId, data.stepId)
    ClearNode(key)

    local coords = data.coords or data.targetCoords
    if not coords then return end

    local zone = PolyZone:Create(
        vector3(coords.x, coords.y, coords.z),
        { name = key, offset = {0,0,0}, scale = {data.radius or 3, data.radius or 3, 5}, debugPoly = false }
    )

    zone:onPlayerInOut(function(isInside)
        if not isInside then
            lib.hideTextUI()
            return
        end

        lib.showTextUI(('[E] %s'):format(data.label or 'Interact'))

        Citizen.CreateThread(function()
            while activeNodes[key] do
                if IsControlJustPressed(0, 38) then
                    lib.hideTextUI()

                    -- 动画
                    if data.animDict and data.animName then
                        lib.requestAnimDict(data.animDict, 3000)
                        TaskPlayAnim(PlayerPedId(), data.animDict, data.animName, 8.0, -8.0, data.duration or 3000, 1, 0, false, false, false)
                    end

                    -- 进度条
                    local completed = lib.progressBar({
                        duration = data.duration or 3000,
                        label = data.label or 'Interacting...',
                        canCancel = true,
                        disable = { move = true, car = true, combat = true },
                    })

                    if completed then
                        TriggerServerEvent('atom:server:nodeReached', data.questId, data.stepId, 'INTERACT', {
                            position = coords,
                        })
                        ClearNode(key)
                    end
                end
                Citizen.Wait(0)
            end
        end)
    end)

    if coords then
        SetNewBlip(coords, data.label or 'Interact')
    end

    activeNodes[key] = { type = 'INTERACT', data = data, zone = zone }
end)

-- ── DELIVER: 到达 + 物品/载具验证 ─────────────────────────────────────

RegisterNetEvent('atom:client:deliver', function(data)
    local key = ('%s_%s'):format(data.questId, data.stepId)
    ClearNode(key)

    if not data.destCoords then return end

    local zone = PolyZone:Create(
        vector3(data.destCoords.x, data.destCoords.y, data.destCoords.z),
        { name = key, offset = {0,0,0}, scale = {data.radius or 5, data.radius or 5, 5}, debugPoly = false }
    )

    zone:onPlayerInOut(function(isInside)
        if isInside then
            -- 到达! 服务端做物品/载具权威检查
            TriggerServerEvent('atom:server:nodeReached', data.questId, data.stepId, 'DELIVER', {
                position = data.destCoords,
                itemName = data.item,
                itemAmount = data.amount,
                vehicleModel = data.vehicleModel,
            })
            ClearNode(key)
        end
    end)

    SetNewBlip(data.destCoords, data.label or 'Delivery Point')
    activeNodes[key] = { type = 'DELIVER', data = data, zone = zone }
end)

-- ── 清理 ──────────────────────────────────────────────────────────────

RegisterNetEvent('atom:client:clearNode', function(questId, stepId)
    ClearNode(('%s_%s'):format(questId, stepId))
end)

RegisterNetEvent('atom:client:clearAll', function(questId)
    for key, node in pairs(activeNodes) do
        if key:match('^' .. questId .. '_') then
            ClearNode(key)
        end
    end
end)

function ClearNode(key)
    local node = activeNodes[key]
    if node and node.zone then
        node.zone:destroy()
    end
    activeNodes[key] = nil
    ClearBlip()
    lib.hideTextUI()
end

-- ── Blip helper ────────────────────────────────────────────────────────

local currentBlip = nil

function SetNewBlip(coords, title)
    ClearBlip()
    if not coords then return end
    currentBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(currentBlip, 1)
    SetBlipColour(currentBlip, 2)
    SetBlipRoute(currentBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(title or _L('blip_atom_target'))
    EndTextCommandSetBlipName(currentBlip)
end

function ClearBlip()
    if currentBlip and DoesBlipExist(currentBlip) then
        RemoveBlip(currentBlip)
    end
    currentBlip = nil
end
