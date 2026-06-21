-- vehiclepush.lua — 推车系统 (migrated from qb-smallresources, v0.8)
--
-- 在车前/车后引擎盖/后备箱 → 右键 → Push Vehicle
-- 引擎损坏无法启动时可用 (engineHealth ≤ Config.DamageNeeded)

local isInFront = false

local function loadAnimDict(dict)
    if HasAnimDictLoaded(dict) then return end
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(10)
    end
end

RegisterNetEvent('custom-vehicles:client:pushVehicle', function(veh)
    if not veh or veh == 0 then return end

    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local vehPos = GetEntityCoords(veh)
    local dimension = GetModelDimensions(GetEntityModel(veh))
    local vehClass = GetVehicleClass(veh)

    -- 排除摩托/自行车/船/飞机
    if vehClass == 8 or vehClass == 13 or vehClass == 14 or vehClass == 15 or vehClass == 16 then return end
    -- 有人坐驾驶座不推
    if not IsVehicleSeatFree(veh, -1) then return end
    -- 引擎没坏不推
    if GetVehicleEngineHealth(veh) > 100 then return end

    if #(pos - vehPos) < 3.0 and not IsPedInAnyVehicle(ped, false) then
        -- 判断在车前还是车后
        if #(vehPos + GetEntityForwardVector(veh) - pos) > #(vehPos + GetEntityForwardVector(veh) * -1 - pos) then
            isInFront = false
            AttachEntityToEntity(ped, veh, GetPedBoneIndex(ped, 6286), 0.0, dimension.y - 0.3, dimension.z + 1.0, 0.0, 0.0, 0.0, false, false, false, true, 0, true)
        else
            isInFront = true
            AttachEntityToEntity(ped, veh, GetPedBoneIndex(ped, 6286), 0.0, dimension.y * -1 + 0.1, dimension.z + 1.0, 0.0, 0.0, 180.0, false, false, false, true, 0, true)
        end

        NetworkRequestControlOfEntity(veh)
        loadAnimDict('missfinale_c2ig_11')
        TaskPlayAnim(ped, 'missfinale_c2ig_11', 'pushcar_offcliff_m', 2.0, -8.0, -1, 35, 0, false, false, false)
        exports['qb-core']:DrawText('[E] 停止推车', 'left')

        while true do
            Wait(0)

            -- A/D 转向
            if IsDisabledControlPressed(0, 34) then
                TaskVehicleTempAction(ped, veh, 11, 1000)
            end
            if IsDisabledControlPressed(0, 9) then
                TaskVehicleTempAction(ped, veh, 10, 1000)
            end

            SetVehicleForwardSpeed(veh, isInFront and -1.0 or 1.0)

            if HasEntityCollidedWithAnything(veh) then
                SetVehicleOnGroundProperly(veh)
            end

            if IsControlJustPressed(0, 38) then -- E 停止
                exports['qb-core']:HideText()
                DetachEntity(ped, false, false)
                StopAnimTask(ped, 'missfinale_c2ig_11', 'pushcar_offcliff_m', 2.0)
                FreezeEntityPosition(ped, false)
                break
            end
        end
    end
end)

-- 注册到 qb-target 骨骼交互点
CreateThread(function()
    exports['qb-target']:AddTargetBone({ 'bonnet', 'boot' }, {
        options = {
            {
                icon = 'fas fa-hand-fist',
                label = 'Push Vehicle',
                action = function(entity)
                    TriggerEvent('custom-vehicles:client:pushVehicle', entity)
                end,
                distance = 1.3,
            }
        }
    })
end)

print('[custom-vehicles] 💪 推车系统就绪 — 引擎盖/后备箱右键推车')
