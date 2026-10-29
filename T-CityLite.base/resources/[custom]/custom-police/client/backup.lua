-- client/backup.lua — NPC backup requested from the MDT.
-- The server owns permission, the 60s cooldown, the two-unit cap and the
-- audit trail. This file only spawns one police car with two NPC officers,
-- drives them to the caller, keeps them nearby, lets them answer hostiles and
-- reliably removes every entity again (timeout / distance / player death /
-- resource stop) so a unit can never leak on the client.

local BACKUP_VEHICLES = { 'police', 'police2' }
local BACKUP_PED_MODELS = { 's_m_y_cop_01', 's_m_y_hwaycop_01' }
local BACKUP_GROUP_NAME = 'TCT_BACKUP'
local BACKUP_GROUP = GetHashKey(BACKUP_GROUP_NAME)
local PLAYER_GROUP = GetHashKey('PLAYER')
local COP_GROUP = GetHashKey('COP')
local PISTOL = GetHashKey('WEAPON_PISTOL')

local SPAWN_FORWARD = 50.0       -- metres in front of the caller (40–70m band)
local SPAWN_SIDE = 6.0           -- avoid spawning the car on top of the caller
local ARRIVE_RADIUS = 20.0
local FOLLOW_STOP_RADIUS = 10.0
local FOLLOW_RESUME_RADIUS = 14.0
local ESCORT_TIMEOUT_MS = 30000
local UNIT_LIFETIME_MS = 300000  -- 5 minutes
local LEAVE_RADIUS = 150.0
local LEAVE_GRACE_MS = 30000
local ENEMY_RADIUS = 50.0
local DRIVE_SPEED = 22.0

local active = {}  -- [requestId] = state
local pending = {} -- [requestId] = true while models are loading
local runBackup    -- forward declaration: spawnBackup starts this thread

local function notifyServerEnded(requestId, reason)
    pcall(function()
        -- reason 让服务端能回答"这个单位为什么结束"；v2 之前它只有 requestId。
        TriggerServerEvent('police:server:backupEnded', requestId, reason or 'unknown')
    end)
end

--- 上报阶段（S2）：服务端只认"本 source 的活动单 + 阶段向前"，其余丢弃并采样。
--- best-effort：ack 丢了只影响阶段指标与 S3 的超时判定，不能反过来让客户端停下
--- 本地逻辑，更不能因为 pcall 失败把单位卡在 pending 里。
local function ackPhase(requestId, phase, entityCount)
    if type(requestId) ~= 'string' or requestId == '' then return end
    pcall(function()
        TriggerServerEvent('police:server:backupAck', requestId, phase, entityCount or 0, GetGameTimer())
    end)
end

local function isDeadPed(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return true end
    if IsEntityDead(ped) then return true end
    if type(IsPedFatallyInjured) == 'function' then
        local ok, fatal = pcall(IsPedFatallyInjured, ped)
        if ok and fatal == true then return true end
    end
    return false
end

local function validPed(ped)
    return ped and ped ~= 0 and DoesEntityExist(ped) and not isDeadPed(ped)
end

local function firstAlivePed(state)
    for _, ped in ipairs(state.peds) do
        if validPed(ped) then return ped end
    end
    return nil
end

local function setupRelationshipGroups()
    if type(DoesRelationshipGroupExist) ~= 'function' or type(AddRelationshipGroup) ~= 'function' then
        return
    end
    if not DoesRelationshipGroupExist(BACKUP_GROUP) then
        AddRelationshipGroup(BACKUP_GROUP_NAME)
    end
    if type(SetRelationshipBetweenGroups) ~= 'function' then return end
    -- 0 = companion: the unit never turns on the caller, other officers or
    -- itself. Hostiles are engaged explicitly with TaskCombatPed instead of
    -- globally marking a group hostile.
    SetRelationshipBetweenGroups(0, BACKUP_GROUP, PLAYER_GROUP)
    SetRelationshipBetweenGroups(0, PLAYER_GROUP, BACKUP_GROUP)
    SetRelationshipBetweenGroups(0, BACKUP_GROUP, COP_GROUP)
    SetRelationshipBetweenGroups(0, COP_GROUP, BACKUP_GROUP)
    SetRelationshipBetweenGroups(0, BACKUP_GROUP, BACKUP_GROUP)
end

setupRelationshipGroups()

local LoadModel = CFShared and CFShared.LoadModel
if not LoadModel then
    print('[custom-police] ⚠ core-framework/client/shared.lua 未包含，模型加载不可用')
    LoadModel = function() return false end
end

-- Try the preferred model first; IsModelInCdimage keeps servers without a
-- custom police fleet from hard-failing on a missing model.
local function loadFirstModel(names)
    for _, name in ipairs(names) do
        local hash = GetHashKey(name)
        if LoadModel(hash) then return hash end
    end
    return nil
end

local function deleteEntity(entity)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        if type(SetEntityAsMissionEntity) == 'function' then
            SetEntityAsMissionEntity(entity, false, true)
        end
        DeleteEntity(entity)
    end
end

local function cleanup(requestId, notifyServer, reason)
    local state = active[requestId]
    if not state then return end
    active[requestId] = nil
    pending[requestId] = nil

    if state.blip and state.blip ~= 0 and DoesBlipExist(state.blip) then
        RemoveBlip(state.blip)
    end
    for _, ped in ipairs(state.peds or {}) do
        deleteEntity(ped)
    end
    if state.vehicle and state.vehicle ~= 0 and DoesEntityExist(state.vehicle) then
        if type(SetEntityAsMissionEntity) == 'function' then
            SetEntityAsMissionEntity(state.vehicle, false, true)
        end
        DeleteVehicle(state.vehicle)
    end
    if notifyServer then notifyServerEnded(requestId, reason) end
end

local function createBlip(vehicle, coords)
    local blip = 0
    if type(AddBlipForEntity) == 'function' then
        blip = AddBlipForEntity(vehicle)
    end
    if (not blip or blip == 0) and type(AddBlipForCoord) == 'function' then
        blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    end
    if not blip or blip == 0 then return 0 end

    SetBlipSprite(blip, 1)
    SetBlipColour(blip, 38) -- blue support marker
    SetBlipScale(blip, 1.0)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('支援单位')
    EndTextCommandSetBlipName(blip)
    return blip
end

local function spawnPoint(playerPed)
    local offset = GetOffsetFromEntityInWorldCoords(
        playerPed, SPAWN_SIDE, SPAWN_FORWARD, 0.0)
    local x, y, z = offset.x, offset.y, offset.z

    -- Ground the spawn so the car does not fall from the caller's z when the
    -- road is lower/higher. If the probe fails we keep the offset z.
    if type(GetGroundZFor_3dCoord) == 'function' then
        local ok, found, groundZ = pcall(GetGroundZFor_3dCoord, x, y, z + 100.0, false)
        if ok and found == true and groundZ then z = groundZ end
    end
    return vector3(x, y, z)
end

local function configureOfficer(ped, veh)
    SetEntityAsMissionEntity(ped, true, true)
    SetPedFleeAttributes(ped, 0, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedRelationshipGroupHash(ped, BACKUP_GROUP)
    SetPedAccuracy(ped, 50)
    SetPedArmour(ped, 50)
    GiveWeaponToPed(ped, PISTOL, 500, false, true)
    SetCurrentPedWeapon(ped, PISTOL, true)
    SetPedCanRagdoll(ped, true)
    SetPedDropsWeaponsWhenDead(ped, false)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        SetEntityAsMissionEntity(veh, true, true)
    end
end

local function spawnBackup(requestId)
    local playerPed = PlayerPedId()
    if not DoesEntityExist(playerPed) then
        pending[requestId] = nil
        notifyServerEnded(requestId, 'dead')
        return
    end

    local vehicleHash = loadFirstModel(BACKUP_VEHICLES)
    local pedHash = loadFirstModel(BACKUP_PED_MODELS)
    if not vehicleHash or not pedHash then
        if vehicleHash then SetModelAsNoLongerNeeded(vehicleHash) end
        if pedHash then SetModelAsNoLongerNeeded(pedHash) end
        pending[requestId] = nil
        notifyServerEnded(requestId, 'spawn_failed')
        print(('[custom-police] backup %s: no usable vehicle/ped model'):format(tostring(requestId)))
        return
    end

    local spawn = spawnPoint(playerPed)
    local heading = (GetEntityHeading(playerPed) + 180.0) % 360.0
    local vehicle = CreateVehicle(vehicleHash, spawn.x, spawn.y, spawn.z + 0.5, heading, true, true)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        pending[requestId] = nil
        SetModelAsNoLongerNeeded(vehicleHash)
        SetModelAsNoLongerNeeded(pedHash)
        notifyServerEnded(requestId, 'spawn_failed')
        return
    end
    SetEntityAsMissionEntity(vehicle, true, true)
    if type(SetVehicleOnGroundProperly) == 'function' then SetVehicleOnGroundProperly(vehicle) end
    SetVehicleEngineOn(vehicle, true, true, false)
    SetVehicleSiren(vehicle, true)
    if type(SetVehicleHasMutedSirens) == 'function' then
        SetVehicleHasMutedSirens(vehicle, false)
    end

    local driver = CreatePedInsideVehicle(vehicle, 4, pedHash, -1, true, true)
    local passenger = CreatePedInsideVehicle(vehicle, 4, pedHash, 0, true, true)
    local peds = {}
    if driver and driver ~= 0 and DoesEntityExist(driver) then peds[#peds + 1] = driver end
    if passenger and passenger ~= 0 and DoesEntityExist(passenger) then peds[#peds + 1] = passenger end

    SetModelAsNoLongerNeeded(vehicleHash)
    SetModelAsNoLongerNeeded(pedHash)

    if #peds ~= 2 then
        for _, ped in ipairs(peds) do deleteEntity(ped) end
        if DoesEntityExist(vehicle) then DeleteVehicle(vehicle) end
        pending[requestId] = nil
        notifyServerEnded(requestId, 'spawn_failed')
        return
    end

    for _, ped in ipairs(peds) do configureOfficer(ped, vehicle) end

    local blip = createBlip(vehicle, spawn)
    local state = {
        requestId = requestId,
        vehicle = vehicle,
        vehicleModel = vehicleHash,
        peds = peds,
        own = { [driver] = true, [passenger] = true },
        blip = blip,
        createdAt = GetGameTimer(),
        phase = 'driving',
        footAt = nil,
        lastDriveTask = 0,
        combat = false,
        combatTarget = {},
        lastCombat = {},
        guard = {},
        lastFollow = {},
        outOfRangeAt = nil,
    }
    pending[requestId] = nil
    active[requestId] = state
    -- 车 + 2 人都在手上才开始算"出发"：这是服务端 15s enroute 超时的锚点，
    -- 也是生成成功率的分母/分子。
    ackPhase(requestId, 'enroute', #state.peds + 1)
    CreateThread(function() runBackup(state) end)
end

local function playerIsDead(playerPed)
    if IsEntityDead(playerPed) then return true end
    if type(IsPedFatallyInjured) == 'function' then
        local ok, fatal = pcall(IsPedFatallyInjured, playerPed)
        if ok and fatal == true then return true end
    end
    return false
end

local function playerIsInCombat(playerPed)
    if type(IsPedInCombat) == 'function' then
        local ok, result = pcall(IsPedInCombat, playerPed, 0)
        if ok and result == true then return true end
        ok, result = pcall(IsPedInCombat, playerPed, playerPed)
        if ok and result == true then return true end
    end
    if type(IsPedShooting) == 'function' then
        local ok, result = pcall(IsPedShooting, playerPed)
        if ok and result == true then return true end
    end
    return false
end

local function isFriendlyGroup(ped)
    if type(GetPedRelationshipGroupHash) ~= 'function' then return false end
    local group = GetPedRelationshipGroupHash(ped)
    return group == PLAYER_GROUP or group == COP_GROUP or group == BACKUP_GROUP
end

-- Only peds that are already fighting the caller/the unit (or shooting in a
-- combat zone) are treated as enemies. Players, backup officers, dead peds and
-- friendly relationship groups (players/other cops) are never targeted.
local function findEnemies(playerPed, state)
    local enemies = {}
    if type(GetGamePool) ~= 'function' then return enemies end
    local pool = GetGamePool('CPed')
    if type(pool) ~= 'table' then return enemies end

    local playerCoords = GetEntityCoords(playerPed)
    local inCombat = playerIsInCombat(playerPed)
    for i = 1, #pool do
        local ped = pool[i]
        if ped ~= playerPed and not state.own[ped] and DoesEntityExist(ped)
            and not IsPedAPlayer(ped) and not isDeadPed(ped) and not isFriendlyGroup(ped) then
            local distance = #(playerCoords - GetEntityCoords(ped))
            if distance <= ENEMY_RADIUS then
                local hostile = false
                if type(IsPedInCombat) == 'function' then
                    local ok, result = pcall(IsPedInCombat, ped, playerPed)
                    if ok and result == true then hostile = true end
                end
                if not hostile and type(IsPedShooting) == 'function' then
                    local ok, result = pcall(IsPedShooting, ped)
                    if ok and result == true then hostile = true end
                end
                if not hostile and inCombat and type(IsPedArmed) == 'function' then
                    local ok, armed = pcall(IsPedArmed, ped, 7)
                    if ok and armed == true then hostile = true end
                end
                if not hostile and type(IsPedInCombat) == 'function' then
                    for _, backupPed in ipairs(state.peds) do
                        if validPed(backupPed) then
                            local ok, result = pcall(IsPedInCombat, ped, backupPed)
                            if ok and result == true then hostile = true break end
                        end
                    end
                end
                if hostile then enemies[#enemies + 1] = ped end
            end
        end
    end
    return enemies
end

local function closestEnemy(ped, enemies)
    local coords = GetEntityCoords(ped)
    local target, best = nil, math.huge
    for _, enemy in ipairs(enemies) do
        if enemy and DoesEntityExist(enemy) and not isDeadPed(enemy) then
            local distance = #(coords - GetEntityCoords(enemy))
            if distance < best then target, best = enemy, distance end
        end
    end
    return target
end

local function beginFoot(state)
    state.phase = 'foot'
    state.footAt = GetGameTimer() + 1500
    -- 到场：这是"平均到场时间"的唯一可信锚点（服务端看不到实体坐标）。
    ackPhase(state.requestId, 'onscene', 0)
    local vehicle = state.vehicle
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end

    SetVehicleSiren(vehicle, false)
    SetVehicleBrake(vehicle, true)
    SetVehicleEngineOn(vehicle, false, true, true)
    for _, ped in ipairs(state.peds) do
        if validPed(ped) then
            TaskLeaveVehicle(ped, vehicle, 0)
        end
    end
end

local function updateFoot(state, playerPed, now)
    if state.footAt and now < state.footAt then return end

    local enemies = findEnemies(playerPed, state)
    if #enemies > 0 then
        state.combat = true
        if not state.engagedAcked then
            state.engagedAcked = true
            -- 只报一次：engaged 是采样指标，不是状态机（它不影响权限）。
            ackPhase(state.requestId, 'engaged', 0)
        end
        for _, ped in ipairs(state.peds) do
            if validPed(ped) then
                local target = closestEnemy(ped, enemies)
                if target then
                    local last = state.lastCombat[ped] or 0
                    if state.combatTarget[ped] ~= target or now - last > 5000 then
                        ClearPedTasks(ped)
                        TaskCombatPed(ped, target, 0, 16)
                        if type(SetPedKeepTask) == 'function' then SetPedKeepTask(ped, true) end
                        state.combatTarget[ped] = target
                        state.lastCombat[ped] = now
                    end
                end
            end
        end
        return
    end

    if state.combat then
        state.combat = false
        for _, ped in ipairs(state.peds) do
            if validPed(ped) then
                ClearPedTasks(ped)
                state.combatTarget[ped] = nil
                state.lastCombat[ped] = nil
                state.guard[ped] = nil
            end
        end
    end

    local playerCoords = GetEntityCoords(playerPed)
    for _, ped in ipairs(state.peds) do
        if validPed(ped) then
            local distance = #(GetEntityCoords(ped) - playerCoords)
            if distance > FOLLOW_RESUME_RADIUS then
                local last = state.lastFollow[ped] or 0
                if now - last > 2000 then
                    if state.guard[ped] then ClearPedTasks(ped) end
                    TaskGoToEntity(ped, playerPed, -1, FOLLOW_STOP_RADIUS, 2.0, 1073741824, 0)
                    if type(SetPedKeepTask) == 'function' then SetPedKeepTask(ped, true) end
                    state.lastFollow[ped] = now
                    state.guard[ped] = nil
                end
            elseif distance <= FOLLOW_STOP_RADIUS and not state.guard[ped] then
                ClearPedTasks(ped)
                if type(TaskStartScenarioInPlace) == 'function' then
                    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_COP_IDLES', 0, true)
                end
                state.guard[ped] = true
            end
        end
    end
end

runBackup = function(state)
    local requestId = state.requestId
    while active[requestId] == state do
        Citizen.Wait(500)
        local playerPed = PlayerPedId()
        if not DoesEntityExist(playerPed) then
            cleanup(requestId, true, 'dead')
            break
        end

        local now = GetGameTimer()
        if now - state.createdAt >= UNIT_LIFETIME_MS then
            cleanup(requestId, true, 'timeout')
            break
        end
        if playerIsDead(playerPed) then
            cleanup(requestId, true, 'dead')
            break
        end
        local alivePed = firstAlivePed(state)
        if not alivePed then
            cleanup(requestId, true, 'no_alive_ped')
            break
        end

        -- While driving the car is the unit; after dismounting, follow the
        -- officers (the abandoned car must not count as "player left").
        local anchor = alivePed
        if state.phase == 'driving' and state.vehicle and state.vehicle ~= 0
            and DoesEntityExist(state.vehicle) then
            anchor = state.vehicle
        end
        if anchor then
            local distance = #(GetEntityCoords(playerPed) - GetEntityCoords(anchor))
            if distance > LEAVE_RADIUS then
                state.outOfRangeAt = state.outOfRangeAt or now
                if now - state.outOfRangeAt >= LEAVE_GRACE_MS then
                    cleanup(requestId, true, 'left')
                    break
                end
            else
                state.outOfRangeAt = nil
            end
        end

        if state.phase == 'driving' then
            if not (state.vehicle and state.vehicle ~= 0 and DoesEntityExist(state.vehicle)) then
                cleanup(requestId, true, 'vehicle_lost')
                break
            end
            local driver = state.peds[1]
            if not validPed(driver) then
                cleanup(requestId, true, 'vehicle_lost')
                break
            end
            local playerCoords = GetEntityCoords(playerPed)
            local vehicleCoords = GetEntityCoords(state.vehicle)
            if #(vehicleCoords - playerCoords) <= ARRIVE_RADIUS
                or now - state.createdAt >= ESCORT_TIMEOUT_MS then
                beginFoot(state)
            elseif now - state.lastDriveTask > 2500 then
                TaskVehicleDriveToCoord(
                    driver, state.vehicle, playerCoords.x, playerCoords.y, playerCoords.z,
                    DRIVE_SPEED, 0, state.vehicleModel, 786603, ARRIVE_RADIUS, true)
                state.lastDriveTask = now
            end
        else
            updateFoot(state, playerPed, now)
        end
    end
end

RegisterNetEvent('police:client:SpawnBackup', function(requestId)
    if type(requestId) ~= 'string' or requestId == '' or #requestId > 64 then return end
    if active[requestId] or pending[requestId] then return end
    pending[requestId] = true
    -- 先报告"我收到了、开始生成"：服务端 10s 没等到这条就会判 expired（S3），
    -- 所以它必须在任何模型加载/等待之前发出。
    ackPhase(requestId, 'spawning', 0)
    CreateThread(function() spawnBackup(requestId) end)
end)

-- Never leave NPCs behind when the resource is restarted. Tell the server too
-- so the per-officer cap is released even if only the client restarted.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    local ids = {}
    for requestId in pairs(active) do ids[#ids + 1] = requestId end
    for _, requestId in ipairs(ids) do
        cleanup(requestId, true, 'resource_stop')
    end
    -- Requests still loading models have no entities yet, but the server slot
    -- must still be released.
    for requestId in pairs(pending) do
        pending[requestId] = nil
        notifyServerEnded(requestId, 'resource_stop')
    end
end)
