-- client/tow.lua — 拖车把 NPC 残骸拖走（蓝图 §6.2 的 L2 后勤，方案 A：只拖 NPC 车）。
--
-- 流程：/tow → 找 40m 内最近的"空车且报废"的 NPC 车 → 平板车从路网开过来 →
-- 停稳后把残骸挂到平板床上 → 开走 → 20 秒后连残骸一起回收。
--
-- 生成复用 `BackupFindRoadNode`（同支援单位/验尸官的一套规则），生命周期在 server/tow.lua。

local TOW_VEHICLE = 'flatbed'
local TOW_PED = 's_m_y_dockwork_01'
local TOW_DRIVE_STYLE = 786603
local TOW_ARRIVE = 10.0
local TOW_DRAG_MS = 20000

local tows = {}   -- [requestId] = state

local loadModel = EntityUtil.LoadModel
local deleteEntity = EntityUtil.Delete

local function cleanup(requestId, reason)
    local state = tows[requestId]
    if not state then return end
    tows[requestId] = nil
    if state.target and DoesEntityExist(state.target) then
        DetachEntity(state.target, true, true)
    end
    deleteEntity(state.vehicle)
    print(('[custom-police] tow %s cleaned (%s)'):format(tostring(requestId), tostring(reason)))
end

--- 找残骸：40m 内、**没人**、引擎报废的 NPC 车。
--- 玩家自己的车由服务端查 `player_vehicles` 拦，这里只做"看起来能拖"的过滤。
local function resolveWreck(netId)
    if netId and netId ~= 0 then
        local ok, veh = pcall(NetToVeh, netId)
        if ok and veh and veh ~= 0 and DoesEntityExist(veh) then return veh end
    end
    local origin = GetEntityCoords(PlayerPedId())
    local best, bestDistance = nil, 40.0
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) and GetVehicleEngineHealth(veh) <= 350.0 then
            local occupied = false
            for seat = -1, 6 do
                local ped = GetPedInVehicleSeat(veh, seat)
                if ped and ped ~= 0 and DoesEntityExist(ped) then occupied = true break end
            end
            if not occupied then
                local distance = #(GetEntityCoords(veh) - origin)
                if distance < bestDistance then best, bestDistance = veh, distance end
            end
        end
    end
    return best
end

--- 把残骸挂到平板床上（挂接点用平板的 bed，偏移按车身高度粗调）。
local function attachWreck(flatbed, wreck)
    local min, max = GetModelDimensions(GetEntityModel(wreck))
    AttachEntityToEntity(wreck, flatbed, 0,
        0.0, -0.6, 1.15 + (max.z - min.z) / 2,
        0.0, 0.0, 0.0, false, false, false, false, 2, true)
end

RegisterNetEvent('police:client:SpawnTow', function(requestId, netId)
    if type(requestId) ~= 'string' or tows[requestId] then return end
    local playerPed = PlayerPedId()
    if not DoesEntityExist(playerPed) then return end

    local wreck = resolveWreck(netId)
    if not wreck then
        TriggerServerEvent('police:server:towDone', requestId, 'no_wreck')
        return
    end

    local spawn, heading = BackupFindRoadNode(playerPed, 0)
    if not spawn then
        TriggerServerEvent('police:server:towDone', requestId, 'no_road')
        return
    end

    local vehicleHash = GetHashKey(TOW_VEHICLE)
    local pedHash = GetHashKey(TOW_PED)
    if not loadModel(vehicleHash) or not loadModel(pedHash) then
        TriggerServerEvent('police:server:towDone', requestId, 'model')
        return
    end

    local flatbed = CreateVehicle(vehicleHash, spawn.x, spawn.y, spawn.z + 0.5, heading or 0.0, true, true)
    if not flatbed or flatbed == 0 or not DoesEntityExist(flatbed) then
        SetModelAsNoLongerNeeded(vehicleHash)
        SetModelAsNoLongerNeeded(pedHash)
        TriggerServerEvent('police:server:towDone', requestId, 'spawn_failed')
        return
    end
    SetEntityAsMissionEntity(flatbed, true, true)
    SetVehicleOnGroundProperly(flatbed)
    SetVehicleEngineOn(flatbed, true, true, false)

    local driver = CreatePedInsideVehicle(flatbed, 4, pedHash, -1, true, true)
    SetModelAsNoLongerNeeded(vehicleHash)
    SetModelAsNoLongerNeeded(pedHash)
    if not driver or driver == 0 or not DoesEntityExist(driver) then
        deleteEntity(flatbed)
        TriggerServerEvent('police:server:towDone', requestId, 'spawn_failed')
        return
    end
    SetEntityAsMissionEntity(driver, true, true)
    SetBlockingOfNonTemporaryEvents(driver, true)
    SetPedFleeAttributes(driver, 0, false)

    print(('[custom-police] tow %s flatbed spawned %.0fm from the wreck'):format(
        tostring(requestId), #(spawn - GetEntityCoords(wreck))))
    local state = { vehicle = flatbed, target = wreck }
    tows[requestId] = state

    CreateThread(function()
        local target = GetEntityCoords(wreck)
        TaskVehicleDriveToCoordLongrange(driver, flatbed, target.x, target.y, target.z,
            15.0, TOW_DRIVE_STYLE, TOW_ARRIVE)

        local deadline = GetGameTimer() + 90000
        while GetGameTimer() < deadline and tows[requestId] do
            Wait(500)
            if not DoesEntityExist(flatbed) or not DoesEntityExist(wreck) then break end
            local distance = #(GetEntityCoords(flatbed) - target)
            if distance <= TOW_ARRIVE and GetEntitySpeed(flatbed) < 1.5 then break end
        end
        if not tows[requestId] then return end

        SetVehicleBrake(flatbed, true)
        local attached = DoesEntityExist(wreck) and DoesEntityExist(flatbed)
        if attached then
            attachWreck(flatbed, wreck)
            TriggerServerEvent('police:server:towDone', requestId, 'done')
        else
            TriggerServerEvent('police:server:towDone', requestId, 'wreck_missing')
        end

        -- 拖走：开着走 20 秒，然后连残骸一起回收（残骸是 NPC 车，删掉不会伤玩家财产）。
        SetVehicleBrake(flatbed, false)
        if DoesEntityExist(flatbed) and DoesEntityExist(driver) then
            TaskVehicleDriveWander(driver, flatbed, 15.0, TOW_DRIVE_STYLE)
        end
        Wait(TOW_DRAG_MS)
        if DoesEntityExist(wreck) then
            DetachEntity(wreck, true, true)
            deleteEntity(wreck)
        end
        cleanup(requestId, 'left')
    end)
end)

RegisterNetEvent('police:client:TowEnd', function(requestId)
    if type(requestId) ~= 'string' then return end
    cleanup(requestId, 'expired')
end)

RegisterNetEvent('police:client:TowDenied', function(reason)
    local message = reason == 'player_owned' and '这是玩家的车，走扣押流程' or '现在不能叫拖车'
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, true)
end)

--- 正式入口：`/tow`。服务端复验在岗、名额与车辆归属。
RegisterCommand('tow', function()
    local wreck = resolveWreck(nil)
    if not wreck then
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName('40 米内没有可拖的报废车辆')
        EndTextCommandThefeedPostTicker(false, true)
        return
    end
    local plate = GetVehicleNumberPlateText(wreck)
    local netId = NetworkGetNetworkIdFromEntity(wreck)
    TriggerServerEvent('police:server:towRequest', plate, netId)
end, false)

--- 真机自测：在玩家旁边摆一辆报废的 NPC 车（不自动叫拖车）。
RegisterNetEvent('police:client:TowDevWreck', function()
    local playerPed = PlayerPedId()
    local forward = GetEntityForwardVector(playerPed)
    local at = GetEntityCoords(playerPed) + forward * 5.0
    local hash = GetHashKey('blista')
    if not loadModel(hash) then return end
    local wreck = CreateVehicle(hash, at.x, at.y, at.z, 0.0, true, true)
    SetModelAsNoLongerNeeded(hash)
    if not wreck or wreck == 0 then return end
    SetEntityAsMissionEntity(wreck, true, true)
    SetVehicleOnGroundProperly(wreck)
    SetVehicleEngineHealth(wreck, 120.0)
    SetVehicleBodyHealth(wreck, 200.0)
    SetVehicleUndriveable(wreck, true)
    print('[custom-police] tow dev: wreck spawned (now run /tow)')
end)
