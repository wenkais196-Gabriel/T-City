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
local ESCORT_TIMEOUT_MS = 90000  -- 到场硬上限（P3：不再用它触发下车）
local ARRIVE_SPEED = 5.0         -- 到场下车要求车速 < 5 m/s，避免擦身而过时下车
local UNIT_LIFETIME_MS = 300000  -- 5 minutes（只在 police_backup_v2 回滚时生效）
local LEAVE_RADIUS = 150.0
local LEAVE_GRACE_MS = 30000
local ENEMY_RADIUS = 50.0
local DRIVE_SPEED = 22.0

-- 任务重发的心跳（S5）：GetScriptTaskStatus 说"正在执行"时，仍然每 N 毫秒补一次，
-- 因为任务可能被 ClearPedTasks / 上车 / 击倒从外部清掉，而 native 只反映"当前在跑"。
-- 数值来自真机观感：车 5 秒、跟随 6 秒足够，再短就是白花帧。
local DRIVE_RETASK_HEARTBEAT_MS = 5000
local FOLLOW_RETASK_HEARTBEAT_MS = 6000

-- 撤离（S8）：到点不再原地删车，而是让单位开走、走远了再消失。
-- 开源实现里最普遍的做法就是 TaskVehicleDriveWander + SetEntityAsNoLongerNeeded
-- （Mooreiche/AIBackup 的 cancel 分支就是这么写的），而不是在玩家眼前 DeleteEntity。
local RETREAT_SPEED = 22.0
local RETREAT_DRIVING_STYLE = 262315  -- 262315: 允许驶离道路、不理会交通灯
local RETREAT_DESPAWN_RADIUS = 220.0
local RETREAT_TIMEOUT_MS = 15000
local RETREAT_BOARD_WAIT_MS = 8000

local active = {}  -- [requestId] = state

--- 服务端是否持有寿命（S3/S4）。为真时客户端不再自己算 5 分钟：到点由服务端发
--- `police:client:BackupEnd`，客户端只负责删实体。留这个开关是为了 v2 回滚后
--- 客户端仍能自清（否则一条扫描不到的服务端会让支援单位永远跟着玩家）。
local function serverOwnsLifetime()
    return GetConvar('police_backup_v2', '1') == '1'
end

local pending = {} -- [requestId] = true while models are loading
local pendingLane = {} -- [requestId] = 0/1 —— 一次叫两车时错开停车位
local pendingEscort = {} -- [requestId] = 跟着哪个 server id（B3：可能是另一位警官）

-- ---------------------------------------------------------------------------
-- 任务门控（S5）
-- ---------------------------------------------------------------------------
local taskHashes = {}

--- 任务名 → 哈希（GetScriptTaskStatus 要的是任务哈希，不是字符串）。
local function taskHash(name)
    local cached = taskHashes[name]
    if cached then return cached end
    local hash = type(GetHashKey) == 'function' and GetHashKey(name) or 0
    taskHashes[name] = hash
    return hash
end

--- 读一个 ped 当前任务的执行状态；缺 native 或未知哈希时回 0（= 不可知）。
local function taskStatus(ped, name)
    if type(GetScriptTaskStatus) ~= 'function' then return 0 end
    local ok, status = pcall(GetScriptTaskStatus, ped, taskHash(name))
    if ok and type(status) == 'number' then return status end
    return 0
end

--- 该不该给这个 ped 重新下发任务（判定在 P0 的 backup_contract，便于 golden 覆盖）。
local function shouldRetask(ped, name, sinceMs, nowMs, heartbeatMs)
    local status = taskStatus(ped, name)
    return BackupContract.ShouldRetask(status, sinceMs, nowMs, heartbeatMs)
end
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

    -- 一行收尾日志：真机验证"服务端发了 BackupEnd，客户端真的删了实体"时，
    -- 服务端看不到实体，只能靠这条与 CitizenFX 客户端日志对账。
    print(('[custom-police] backup %s cleaned (reason=%s)'):format(
        tostring(requestId), tostring(reason or 'unknown')))

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

--- 撤离（S8）：让单位开车离开，而不是在玩家眼前原地消失。
---
--- 只在"服务端到点/请求者还在旁边"时用；玩家已经跑远（>LEAVE_RADIUS）或实体已经没了
--- 的情况仍然直接 cleanup —— 反正看不见，没必要多跑一段。
---@param state table
---@param reason string
local function beginRetreat(state, reason)
    if state.phase == 'leaving' then return end
    state.phase = 'leaving'
    state.retreatAt = GetGameTimer()
    state.retreatReason = reason or 'expired'
    -- 一行撤离日志：真机验收要能对比"开始撤离"与"清理完成"的间隔，
    -- 间隔≈0 就说明又开始原地删车了。
    print(('[custom-police] backup %s retreating (reason=%s)'):format(
        tostring(state.requestId), tostring(state.retreatReason)))

    if state.blip and state.blip ~= 0 and DoesBlipExist(state.blip) then
        RemoveBlip(state.blip)
    end
    state.blip = nil

    local vehicle = state.vehicle
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end

    SetVehicleSiren(vehicle, false)
    local driver = state.peds[1]
    if not validPed(driver) then return end

    -- 刚打完架时两名警官还在车外，靠 AI 上车在真机上不可靠（25 秒都没上去，
    -- 最后照样在原地被删）。撤离是"收尾动作"，不需要演：直接塞进座位再开走。
    if state.peds[1] and GetVehiclePedIsIn(state.peds[1], false) ~= vehicle then
        if type(SetPedIntoVehicle) == 'function' then
            SetPedIntoVehicle(driver, vehicle, -1)
            if validPed(state.peds[2]) then SetPedIntoVehicle(state.peds[2], vehicle, 0) end
        else
            TaskEnterVehicle(driver, vehicle, RETREAT_BOARD_WAIT_MS, -1, 2.0, 1, 0)
            return
        end
    end

    if not validPed(driver) then return end
    SetVehicleEngineOn(vehicle, true, true, false)
    SetVehicleSiren(vehicle, false)
    TaskVehicleDriveWander(driver, vehicle, RETREAT_SPEED, RETREAT_DRIVING_STYLE)
    state.retreatDriving = true
    if type(SetEntityAsNoLongerNeeded) == 'function' then SetEntityAsNoLongerNeeded(vehicle) end
    for _, ped in ipairs(state.peds) do
        if type(SetPedAsNoLongerNeeded) == 'function' then SetPedAsNoLongerNeeded(ped) end
    end
end

--- 撤离过程中的每帧判定：车没了 / 开得够远 / 超时 → 真的删掉。
local function updateRetreat(state, playerPed, now)
    local vehicle = state.vehicle
    local elapsed = now - (state.retreatAt or now)

    -- 上车阶段的兜底：司机一直上不去（被打死、被卡住）就直接发车。
    if not state.retreatDriving and elapsed >= RETREAT_BOARD_WAIT_MS then
        local driver = state.peds[1]
        if validPed(driver) and vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
            TaskVehicleDriveWander(driver, vehicle, RETREAT_SPEED, RETREAT_DRIVING_STYLE)
            state.retreatDriving = true
        end
    end

    local exists = vehicle and vehicle ~= 0 and DoesEntityExist(vehicle)
    local distance = exists and #(GetEntityCoords(vehicle) - GetEntityCoords(playerPed)) or 0.0
    local far = exists and distance > RETREAT_DESPAWN_RADIUS
    -- 开远了、或者已经不在画面里（背对/被建筑挡住）就删：玩家看不到"消失"。
    local offscreen = false
    if exists and distance > 60.0 and type(IsEntityOnScreen) == 'function' then
        local ok, onScreen = pcall(IsEntityOnScreen, vehicle)
        offscreen = ok and onScreen == false
    end
    if not exists or far or offscreen or elapsed >= RETREAT_TIMEOUT_MS then
        cleanup(state.requestId, false, state.retreatReason or 'expired')
    end
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

local function spawnPoint(playerPed, lane)
    -- 一次响应可能是两辆车：第二辆往侧后错开，避免两车生成在同一个点互相顶。
    local shift = (tonumber(lane) or 0)
    local offset = GetOffsetFromEntityInWorldCoords(
        playerPed, SPAWN_SIDE + shift * 11.0, SPAWN_FORWARD - shift * 7.0, 0.0)
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

    local spawn = spawnPoint(playerPed, pendingLane[requestId] or 0)
    pendingLane[requestId] = nil
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
        escortSource = tonumber(pendingEscort[requestId]),
    }
    pending[requestId] = nil
    pendingEscort[requestId] = nil
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

--- 通缉目标（S7）：服务端告诉我们"附近有哪些通缉玩家"（只有 netId/距离/星级）。
--- 客户端不自己扫玩家：玩家列表、通缉星级、距离判定全在服务端，这里只负责拿 netId
--- 换成本地 ped 再下发战斗任务。
local suspectNetIds = {}

RegisterNetEvent('police:client:BackupTargets', function(payload)
    suspectNetIds = {}
    if type(payload) ~= 'table' or type(payload.targets) ~= 'table' then return end
    for _, target in ipairs(payload.targets) do
        local netId = tonumber(target and target.net_id)
        if netId and netId > 0 and #suspectNetIds < 8 then
            suspectNetIds[#suspectNetIds + 1] = netId
        end
    end
end)

--- 把服务端给的通缉 netId 解成本地 ped，并只保留"活着且在交战半径内"的。
local function wantedPedsAround(playerPed)
    if #suspectNetIds == 0 then return {} end
    local playerCoords = GetEntityCoords(playerPed)
    local peds = {}
    for _, netId in ipairs(suspectNetIds) do
        local ped = NetworkGetEntityFromNetworkId(netId)
        if ped and ped ~= 0 and DoesEntityExist(ped) and not IsEntityDead(ped) then
            if #(GetEntityCoords(ped) - playerCoords) <= ENEMY_RADIUS * 1.5 then
                peds[#peds + 1] = ped
            end
        end
    end
    return peds
end

--- 这单应该跟着谁（B3）：服务端挑的警官在本地有时就用他，否则回落到请求者自己。
local function escortPed(state, playerPed)
    local source = state.escortSource
    if not source or source <= 0 then return playerPed end
    local mySource = GetPlayerServerId(PlayerId())
    if source == mySource then return playerPed end
    local ped = GetPlayerFromServerId(source)
    if ped and ped ~= -1 then
        local playerEntity = GetPlayerPed(ped)
        if playerEntity and playerEntity ~= 0 and DoesEntityExist(playerEntity) then
            return playerEntity
        end
    end
    return playerPed
end

local function beginFoot(state, distance)
    state.phase = 'foot'
    -- 真机验收靠这行：下车距离必须 ≤ 25m（P3）
    print(('[custom-police] backup %s dismount at %.1fm'):format(
        tostring(state.requestId), tonumber(distance) or -1))
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
    -- 通缉玩家优先并入候选：他们是"这单支援的目标"，普通敌对 ped 只是路上的麻烦。
    local wanted = wantedPedsAround(playerPed)
    for _, suspect in ipairs(wanted) do
        local seen = false
        for _, existing in ipairs(enemies) do
            if existing == suspect then seen = true break end
        end
        if not seen then enemies[#enemies + 1] = suspect end
    end
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

    local anchorPed = escortPed(state, playerPed)
    local playerCoords = GetEntityCoords(anchorPed)
    -- 待命（B2）：不追、不跟随，但战斗逻辑照旧（updateFoot 的战斗分支在上面已经跑过）。
    if state.mode == 'hold' then return end
    for _, ped in ipairs(state.peds) do
        if validPed(ped) then
            local distance = #(GetEntityCoords(ped) - playerCoords)
            if distance > FOLLOW_RESUME_RADIUS then
                local last = state.lastFollow[ped] or 0
                if shouldRetask(ped, 'TASK_GO_TO_ENTITY', last, now, FOLLOW_RETASK_HEARTBEAT_MS) then
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
        -- 500ms 在"开车/交战"这类要跟手的状态下用；下车后跟随是慢动作，1s 足够，
        -- 把每帧的实体与距离采样砍一半。
        Citizen.Wait(state.phase == 'driving' and 500 or 1000)
        local playerPed = PlayerPedId()
        if not DoesEntityExist(playerPed) then
            cleanup(requestId, true, 'dead')
            break
        end

        local now = GetGameTimer()
        -- v2：寿命归服务端（sweep 到点发 BackupEnd）。只有回滚（police_backup_v2 0）
        -- 时才保留客户端自计时，避免"服务端关了、客户端也不清"的双输。
        if not serverOwnsLifetime() and now - state.createdAt >= UNIT_LIFETIME_MS then
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
            local anchorPed = escortPed(state, playerPed)
            local playerCoords = GetEntityCoords(anchorPed)
            local vehicleCoords = GetEntityCoords(state.vehicle)
            if state.mode == 'hold' then
                -- 待命（B2）：刹停并停掉驾驶任务，不再继续开过来；到点/撤离照旧走服务端。
                SetVehicleBrake(state.vehicle, true)
                if not state.holdCleared then
                    state.holdCleared = true
                    ClearPedTasks(driver)
                end
            elseif #(vehicleCoords - playerCoords) <= ARRIVE_RADIUS
                and GetEntitySpeed(state.vehicle) < ARRIVE_SPEED then
                -- P3：必须在玩家身边**并且**慢下来才下车。以前这里是
                -- "距离 ≤20m 或 到 30s"，于是车还在两百米外就把人放下来跑步。
                beginFoot(state, #(vehicleCoords - playerCoords))
            elseif now - state.createdAt >= ESCORT_TIMEOUT_MS then
                -- 90 秒还没到：结束这一单（名额随之释放），而不是从远处跑过来。
                cleanup(requestId, true, 'escort_timeout')
                break
            elseif shouldRetask(driver, 'TASK_VEHICLE_DRIVE_TO_COORD',
                    state.lastDriveTask, now, DRIVE_RETASK_HEARTBEAT_MS) then
                -- 只在"任务不在跑"或心跳到点时才重发：正在开车的司机不必每 2.5 秒
                -- 重建一次路径（真机上表现为车头一抖一抖、油耗和掉帧都白给）。
                TaskVehicleDriveToCoord(
                    driver, state.vehicle, playerCoords.x, playerCoords.y, playerCoords.z,
                    DRIVE_SPEED, 0, state.vehicleModel, 786603, ARRIVE_RADIUS, true)
                state.lastDriveTask = now
            end
        elseif state.phase == 'leaving' then
            updateRetreat(state, playerPed, now)
        else
            -- 下车之后每 3 秒问一次"附近有没有通缉目标"；服务端默认关
            -- （police_backup_engage_wanted 0），关着时这条只是空转一次很小的请求。
            if now - (state.lastTargetAsk or 0) >= 3000 then
                state.lastTargetAsk = now
                TriggerServerEvent('police:server:backupTargets')
            end
            updateFoot(state, playerPed, now)
        end
    end
end

RegisterNetEvent('police:client:SpawnBackup', function(requestId, requestIds, escortSource)
    -- 服务端可能一次给一组 id（响应级别 2 = 两辆车）。逐个校验后再生成，
    -- 任何一个 id 不合法都不影响其余的。
    local ids = {}
    if type(requestIds) == 'table' then
        for _, id in ipairs(requestIds) do
            if type(id) == 'string' and id ~= '' and #id <= 64 then ids[#ids + 1] = id end
            if #ids >= 2 then break end
        end
    end
    if #ids == 0 and type(requestId) == 'string' and requestId ~= '' and #requestId <= 64 then
        ids[1] = requestId
    end

    for index, id in ipairs(ids) do
        if active[id] or pending[id] then goto continue end
        pending[id] = true
        pendingLane[id] = index - 1
        pendingEscort[id] = tonumber(escortSource)
    -- 先报告"我收到了、开始生成"：服务端 10s 没等到这条就会判 expired（S3），
    -- 所以它必须在任何模型加载/等待之前发出。
        ackPhase(id, 'spawning', 0)
        CreateThread(function() spawnBackup(id) end)
        ::continue::
    end
end)

-- ---------------------------------------------------------------------------
-- 指挥（B2）：/backup follow | hold | dismiss
--
-- 只影响调用者自己名下的单位；服务端逻辑一概不动（寿命仍归 sweep）。
-- 三条命令都做成"幂等 + 有回执"：重复执行不会报错，玩家能看到当前状态。
-- ---------------------------------------------------------------------------
local BACKUP_ORDERS = { follow = true, hold = true, dismiss = true }

--- 把一条命令应用到调用者名下的所有单位；返回生效数量。
local function applyOrder(order)
    if not BACKUP_ORDERS[order] then return 0 end
    local applied = 0
    for requestId, state in pairs(active) do
        if order == 'dismiss' then
            -- 先告诉服务端"这单我撤了"，让它立刻释放名额，再让车开走。
            notifyServerEnded(requestId, 'dismissed')
            beginRetreat(state, 'dismissed')
        else
            state.mode = order
            if order == 'hold' then
                -- 立刻停下正在跑的任务：否则"原地待命"的人还在往你这边挪。
                for _, ped in ipairs(state.peds or {}) do
                    if validPed(ped) then ClearPedTasks(ped) end
                end
                if state.vehicle and state.vehicle ~= 0 and DoesEntityExist(state.vehicle) then
                    SetVehicleBrake(state.vehicle, true)
                end
                state.holdCleared = true
            else
                -- 恢复跟随：清掉待命标记并让驾驶/跟随任务下一次判定就能重发。
                state.holdCleared = false
                state.lastDriveTask = 0
                state.lastFollow = {}
            end
        end
        applied = applied + 1
    end
    return applied
end

RegisterCommand('backup', function(_, args)
    local order = tostring((args and args[1]) or ''):lower()
    if not BACKUP_ORDERS[order] then
        TriggerEvent('chat:addMessage', {
            args = { '支援', '用法：/backup follow|hold|dismiss' },
        })
        return
    end
    local applied = applyOrder(order)
    -- 一行回执日志：真机验收靠它确认命令真的进了客户端。
    print(('[custom-police] backup order=%s applied=%d'):format(order, applied))
    TriggerEvent('chat:addMessage', {
        args = { '支援', applied > 0
            and ('已对 %d 个单位执行 %s'):format(applied, order)
            or '你名下没有活动的支援单位' },
    })
end, false)

--- 服务端收尾（S3）：寿命到点或阶段停太久，服务端先发这条再宽限 5 秒放名额。
--- 客户端收到就删车删人，**不回报 backupEnded** —— 名额已经由服务端释放，
--- 回报只会被当成"外单"丢掉，还会在日志里制造一次假失败。
RegisterNetEvent('police:client:BackupEnd', function(requestId, reason)
    if type(requestId) ~= 'string' or requestId == '' or #requestId > 64 then return end
    local state = active[requestId]
    if not state then
        pending[requestId] = nil
        return
    end
    -- 玩家还在旁边就让它开走（S8）；已经跑远或车没了就直接散场，反正看不见。
    local playerPed = PlayerPedId()
    local anchor = state.vehicle
    local visible = DoesEntityExist(playerPed) and anchor and anchor ~= 0 and DoesEntityExist(anchor)
        and #(GetEntityCoords(anchor) - GetEntityCoords(playerPed)) <= LEAVE_RADIUS
    if visible then
        beginRetreat(state, reason or 'expired')
    else
        if GetConvar('police_backup_debug', '0') == '1' then
            local exists = DoesEntityExist(playerPed) and anchor and anchor ~= 0 and DoesEntityExist(anchor)
            print(('[custom-police][debug] backup %s ended without retreat: vehicle=%s distance=%s'):format(
                tostring(requestId), tostring(anchor),
                exists and ('%.1f'):format(#(GetEntityCoords(anchor) - GetEntityCoords(playerPed))) or 'n/a'))
        end
        cleanup(requestId, false, reason or 'expired')
    end
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
