-- client/coroner.lua — L2 后勤层：验尸官把尸体抬走（蓝图 §6.2）。
--
-- 只做四件事：从路网开过来 → 停到尸体旁 → 抬走 → 开车离开。
-- 生成点复用 `BackupFindRoadNode`（backup.lua 里的路网取点，含四档降级），
-- 生命周期（名额/冷却/寿命/审计）全在 server/coroner.lua。

local CORONER_VEHICLE = 'speedo'          -- 面包车，看起来像法医组的车
local CORONER_PED = 's_m_m_doctor_01'
local CORONER_DRIVE_STYLE = 786603        -- 和支援单位一致：让车让人不闯红灯
local CORONER_ARRIVE = 12.0
local CORONER_KNEEL_MS = 6000
local CORONER_LEAVE_MS = 12000

local coroners = {}   -- [requestId] = state

local function loadModel(hash)
    if not IsModelInCdimage(hash) then return false end
    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) do
        if GetGameTimer() > deadline then return false end
        Wait(10)
    end
    return true
end

local function deleteEntity(entity)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        SetEntityAsMissionEntity(entity, false, true)
        DeleteEntity(entity)
    end
end

local function cleanup(requestId, reason)
    local state = coroners[requestId]
    if not state then return end
    coroners[requestId] = nil
    for _, ped in ipairs(state.peds or {}) do deleteEntity(ped) end
    deleteEntity(state.vehicle)
    print(('[custom-police] coroner %s cleaned (%s)'):format(tostring(requestId), tostring(reason)))
end

--- 找尸体：优先用服务端/客户端传下来的 netId，否则找玩家 30m 内最近的一具。
local function resolveCorpse(corpseNet)
    if corpseNet and corpseNet ~= 0 then
        local ok, ped = pcall(NetToPed, corpseNet)
        if ok and ped and ped ~= 0 and DoesEntityExist(ped) then return ped end
    end
    local playerPed = PlayerPedId()
    local origin = GetEntityCoords(playerPed)
    local best, bestDistance = nil, 30.0
    for _, ped in ipairs(GetGamePool('CPed')) do
        if ped ~= playerPed and DoesEntityExist(ped) and IsEntityDead(ped) then
            local distance = #(GetEntityCoords(ped) - origin)
            if distance < bestDistance then best, bestDistance = ped, distance end
        end
    end
    return best
end

--- 找最近的一具尸体并叫单。`/coroner` 与调试入口都走它。
---@return boolean ok, string|nil reason
local function requestCoroner()
    local playerPed = PlayerPedId()
    local corpse = resolveCorpse(nil)
    if not corpse then return false, 'no_body' end
    if type(NetworkGetNetworkIdFromEntity) ~= 'function' then return false, 'no_net' end
    local netId = NetworkGetNetworkIdFromEntity(corpse)
    if not netId or netId == 0 then return false, 'no_net' end
    TriggerServerEvent('police:server:coronerRequest', netId)
    return true
end

--- 抬尸体的全套动作：下车 → 走到尸体旁 → 跪下 6 秒 → 尸体消失 → 回车上。
local function pickUpBody(state, corpse)
    local doctor = state.peds[1]
    if not doctor or not DoesEntityExist(doctor) or not corpse or not DoesEntityExist(corpse) then
        return false
    end
    TaskLeaveVehicle(doctor, state.vehicle, 0)
    local untilAt = GetGameTimer() + 5000
    while GetGameTimer() < untilAt and IsPedInAnyVehicle(doctor, false) do Wait(100) end

    local coords = GetEntityCoords(corpse)
    TaskGoStraightToCoord(doctor, coords.x, coords.y, coords.z, 1.2, 8000, 0.0, 0.5)
    untilAt = GetGameTimer() + 10000
    while GetGameTimer() < untilAt and #(GetEntityCoords(doctor) - coords) > 2.0 do Wait(100) end

    RequestAnimDict('amb@medic@standing@kneel@base')
    untilAt = GetGameTimer() + 3000
    while not HasAnimDictLoaded('amb@medic@standing@kneel@base') and GetGameTimer() < untilAt do Wait(50) end
    TaskPlayAnim(doctor, 'amb@medic@standing@kneel@base', 'base', 4.0, -4.0, CORONER_KNEEL_MS, 1, 0.0, false, false, false)
    Wait(CORONER_KNEEL_MS)
    StopAnimTask(doctor, 'amb@medic@standing@kneel@base', 'base', 1.0)

    -- 尸体被收走：这一步是"验尸官真的干了活"的唯一可见证据。
    deleteEntity(corpse)
    TaskEnterVehicle(doctor, state.vehicle, 8000, -1, 1.0, 1)
    return true
end

RegisterNetEvent('police:client:SpawnCoroner', function(requestId, corpseNet)
    if type(requestId) ~= 'string' or coroners[requestId] then return end
    local playerPed = PlayerPedId()
    if not DoesEntityExist(playerPed) then return end

    local corpse = resolveCorpse(corpseNet)
    if not corpse then
        TriggerServerEvent('police:server:coronerDone', requestId, 'no_body')
        return
    end

    local spawn, heading = BackupFindRoadNode(playerPed, 0)
    if not spawn then
        print('[custom-police] coroner: no road node for the van')
        TriggerServerEvent('police:server:coronerDone', requestId, 'no_road')
        return
    end

    local vehicleHash = GetHashKey(CORONER_VEHICLE)
    local pedHash = GetHashKey(CORONER_PED)
    if not loadModel(vehicleHash) or not loadModel(pedHash) then
        TriggerServerEvent('police:server:coronerDone', requestId, 'model')
        return
    end

    local vehicle = CreateVehicle(vehicleHash, spawn.x, spawn.y, spawn.z + 0.5, heading or 0.0, true, true)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        SetModelAsNoLongerNeeded(vehicleHash)
        SetModelAsNoLongerNeeded(pedHash)
        TriggerServerEvent('police:server:coronerDone', requestId, 'spawn_failed')
        return
    end
    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleOnGroundProperly(vehicle)
    SetVehicleEngineOn(vehicle, true, true, false)

    local driver = CreatePedInsideVehicle(vehicle, 4, pedHash, -1, true, true)
    local helper = CreatePedInsideVehicle(vehicle, 4, pedHash, 0, true, true)
    SetModelAsNoLongerNeeded(vehicleHash)
    SetModelAsNoLongerNeeded(pedHash)
    if not driver or driver == 0 or not DoesEntityExist(driver) then
        deleteEntity(vehicle)
        TriggerServerEvent('police:server:coronerDone', requestId, 'spawn_failed')
        return
    end
    for _, ped in ipairs({ driver, helper }) do
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            SetEntityAsMissionEntity(ped, true, true)
            SetBlockingOfNonTemporaryEvents(ped, true)
            SetPedFleeAttributes(ped, 0, false)
        end
    end

    print(('[custom-police] coroner %s van spawned %.0fm from the body'):format(
        tostring(requestId), #(spawn - GetEntityCoords(corpse))))
    local state = { vehicle = vehicle, peds = { driver, helper }, corpse = corpse, startedAt = GetGameTimer() }
    coroners[requestId] = state

    CreateThread(function()
        local target = GetEntityCoords(corpse)
        TaskVehicleDriveToCoordLongrange(driver, vehicle, target.x, target.y, target.z,
            18.0, CORONER_DRIVE_STYLE, CORONER_ARRIVE)

        local deadline = GetGameTimer() + 90000
        while GetGameTimer() < deadline and coroners[requestId] do
            Wait(500)
            local distance = #(GetEntityCoords(vehicle) - target)
            local speed = GetEntitySpeed(vehicle)
            if distance <= CORONER_ARRIVE and speed < 1.5 then break end
            if not DoesEntityExist(vehicle) then break end
        end
        if not coroners[requestId] then return end

        SetVehicleBrake(vehicle, true)
        local ok = pickUpBody(state, corpse)
        TriggerServerEvent('police:server:coronerDone', requestId, ok and 'done' or 'failed')

        -- 抬完就走：不在现场留着占资源。
        SetVehicleBrake(vehicle, false)
        if DoesEntityExist(vehicle) and DoesEntityExist(driver) then
            TaskVehicleDriveWander(driver, vehicle, 15.0, CORONER_DRIVE_STYLE)
        end
        Wait(CORONER_LEAVE_MS)
        cleanup(requestId, 'left')
    end)
end)

RegisterNetEvent('police:client:CoronerEnd', function(requestId)
    if type(requestId) ~= 'string' then return end
    cleanup(requestId, 'expired')
end)

--- 正式入口：`/coroner`。服务端复验在岗与名额，这里只负责"找到那具尸体"。
RegisterCommand('coroner', function()
    local ok, reason = requestCoroner()
    if ok then return end
    local message = reason == 'no_body' and '附近没有尸体' or '这具尸体不在网络同步范围内'
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, true)
end, false)

--- 真机自测：在玩家面前摆一具尸体（只造场景，叫单由测试者自己按 /coroner）。
RegisterNetEvent('police:client:CoronerDevCorpse', function()
    local playerPed = PlayerPedId()
    local forward = GetEntityForwardVector(playerPed)
    local at = GetEntityCoords(playerPed) + forward * 4.0
    local hash = GetHashKey('a_m_m_business_01')
    if not loadModel(hash) then return end
    local ped = CreatePed(4, hash, at.x, at.y, at.z, 0.0, true, true)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 then return end
    SetEntityAsMissionEntity(ped, true, true)
    SetEntityInvincible(ped, false)
    -- 直接判死：这一条只为造场景，不进入任何正式逻辑。
    SetEntityHealth(ped, 0)
    print('[custom-police] coroner dev: corpse spawned (now run /coroner)')
end)

-- ----------------------------------------------------
-- qb-target：对准尸体就有「叫验尸官」选项（Config.UseTarget 开启时）
-- ----------------------------------------------------
local targetBodies = {}

local function watchBodies()
    if not Config or not Config.UseTarget then return end
    if type(exports) ~= 'table' then return end
    local ok = pcall(function() return exports['qb-target'] end)
    if not ok then return end

    while true do
        Wait(2000)
        local playerPed = PlayerPedId()
        if DoesEntityExist(playerPed) then
            local origin = GetEntityCoords(playerPed)
            local seen = {}
            for _, ped in ipairs(GetGamePool('CPed')) do
                if ped ~= playerPed and DoesEntityExist(ped) and IsEntityDead(ped)
                    and #(GetEntityCoords(ped) - origin) <= 30.0 then
                    seen[ped] = true
                    if not targetBodies[ped] then
                        targetBodies[ped] = true
                        pcall(function()
                            exports['qb-target']:AddTargetEntity(ped, {
                                options = {
                                    {
                                        label = '叫验尸官',
                                        icon = 'fas fa-ambulance',
                                        action = function()
                                            local netId = NetworkGetNetworkIdFromEntity(ped)
                                            TriggerServerEvent('police:server:coronerRequest', netId)
                                        end,
                                    },
                                },
                                distance = 2.5,
                            })
                        end)
                    end
                end
            end
            -- 尸体被收走/刷掉后，把 target 摘掉，别留成幽灵选项。
            for ped in pairs(targetBodies) do
                if not seen[ped] or not DoesEntityExist(ped) then
                    targetBodies[ped] = nil
                    pcall(function() exports['qb-target']:RemoveTargetEntity(ped) end)
                end
            end
        end
    end
end

CreateThread(watchBodies)
