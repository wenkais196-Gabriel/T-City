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
-- 兜底（取不到合规路网节点时）：退到玩家**后方** 90m，既不在视野里，也满足 AC-P5-01 的 80m 下限。
local SPAWN_FALLBACK_BACK = 90.0
-- spawn v3 · P1：优先在**路网**上生成，并要求"开车能到"（路径距离合理）。
local SPAWN_NODE_FORWARD = -50.0  -- 在玩家**后方**找节点：那里通常不在视野里，且车头天然朝向玩家
local SPAWN_NODE_SIDE = 50.0
local SPAWN_NODE_CANDIDATES = { 1, 3, 5, 8, 12, 20 }
local SPAWN_MIN_DISTANCE = 80.0  -- 验收 AC-P5-01：距 call ≥80m 出生
local SPAWN_MAX_DISTANCE = 150.0
local SPAWN_MAX_TRAVEL_RATIO = 3.0   -- 路径距离 / 直线距离 的上限，超过就当不可达
-- spawn v3 · P2：远距离 longrange + 无进展看门狗
local LONG_RANGE_THRESHOLD = 150.0
-- 蓝图 §6.3 #6：驾驶风格固定 786603（StopBeforeVehicles + StopBeforePeds +
-- SteerAroundStationaryVehicles + SteerAroundObjects + StopAtTrafficLights），
-- 这是"车流不会撞上来"的配套条件之一。
-- 之前的 2883621 是"抢行"档（不含 StopBeforePeds / 不等红灯），到场更快但也更容易
-- 在路口被别车；发现手感不对可以 `setr police_backup_drive_style 2883621` 回滚。
local DRIVE_STYLE_NORMAL = 786603
local DRIVE_STYLE_RUSH = 2883621
local function backupDriveStyle()
    local raw = tonumber(GetConvar('police_backup_drive_style', ''))
    if raw and raw > 0 then return raw end
    return DRIVE_STYLE_NORMAL
end
local STUCK_WINDOW_MS = 20000  -- 真机上合法掉头就要十几秒
local SPAWN_GRACE_MS = 10000       -- 生成后前 10 秒不计"没进展"（起步/掉头）
local STUCK_PROGRESS_M = 5.0
local SPAWN_SIDE = 6.0           -- avoid spawning the car on top of the caller
local ARRIVE_RADIUS = 20.0
-- 车停稳了但就是进不去（玩家在屋内 / 院子里 / 被护栏隔开）：到这个宽度内停 2.5 秒就下车，
-- 而不是干等看门狗把它判成 vehicle_lost。
local BLOCKED_RADIUS_GRACE = 15.0
local BLOCKED_WAIT_MS = 2500
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

--- 玩家周围 250m 内的车辆数（AC-P5-06 的"遗留实体"判据用）。
local function vehiclesNear(coords, radius)
    if type(GetGamePool) ~= 'function' then return -1 end
    local ok, pool = pcall(GetGamePool, 'CVehicle')
    if not ok or type(pool) ~= 'table' then return -1 end
    local count = 0
    for i = 1, #pool do
        local veh = pool[i]
        if DoesEntityExist(veh) and #(GetEntityCoords(veh) - coords) <= radius then
            count = count + 1
        end
    end
    return count
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
    -- AC-P5-06：清理前后的实体池对比（2 秒后再数一次，给引擎时间回收）。
    if GetConvar('police_backup_debug', '0') == '1' then
        local anchor = GetEntityCoords(PlayerPedId())
        local before = vehiclesNear(anchor, 250.0)
        local hits = state.hits or 0
        SetTimeout(2000, function()
            -- 确定性的判据：单位自己的句柄是否还活着（车池总数会被路人车流干扰）。
            local leftover = 0
            if state.vehicle and state.vehicle ~= 0 and DoesEntityExist(state.vehicle) then
                leftover = leftover + 1
            end
            for _, ped in ipairs(state.peds or {}) do
                if ped and ped ~= 0 and DoesEntityExist(ped) then leftover = leftover + 1 end
            end
            print(('[custom-police][debug] backup %s leftover=%d'):format(
                tostring(requestId), leftover))
            print(('[custom-police][debug] backup %s pool before=%s after=%s hits=%d'):format(
                tostring(requestId), tostring(before),
                tostring(vehiclesNear(anchor, 250.0)), hits))
        end)
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

--- FiveM 的 BOOL native 有时返回 1/0 而不是 true/false（本机实测 GetGroundZFor_3dCoord
--- 的 found 就是数字）。判真一律走这里，否则会出现"地面探测永远失败"这种沉默故障。
local function isTrue(value)
    return value == true or value == 1
end

local function debugSpawnNode(message)
    if GetConvar('police_backup_debug', '0') == '1' then
        print(('[custom-police][debug] spawn node: %s'):format(tostring(message)))
    end
end

--- 干地判定：这个点是不是在水里。
---
--- 之前要求"必须探到地面"，结果在山地/码头这种地方 `GetGroundZFor_3dCoord` 一直返回 false，
--- 把所有候选都拒掉（玩家在 (2193,4696,35) 时支援直接失败）。现在改成：
---   1) 用 `GetWaterHeight` 判这个点是否在水面以下 —— 这才是"生成在海里"的直接判据；
---   2) 探到地面就用地面高度校正，探不到就沿用路网节点自带的高度（节点本来就在路面上）。
---@return number|nil groundZ  nil = 水里，不能用
local function dryGroundZ(x, y, z)
    if type(GetWaterHeight) == 'function' then
        local okW, hasWater, waterZ = pcall(GetWaterHeight, x, y, z)
        if okW and isTrue(hasWater) and type(waterZ) == 'number' and z <= waterZ + 1.0 then
            return nil
        end
    end
    if type(GetGroundZFor_3dCoord) == 'function' then
        local ok, found, groundZ = pcall(GetGroundZFor_3dCoord, x, y, z + 3.0, false)
        if ok and isTrue(found) and type(groundZ) == 'number' then return groundZ end
    end
    return z
end

--- 一个候选节点是否满足全部出生规则；返回 groundZ（nil = 不合格）。
local function nodeIsUsable(nodePos, playerCoords, rules)
    local distance = #(nodePos - playerCoords)
    local minDistance = rules.minDistance or SPAWN_MIN_DISTANCE
    if distance < minDistance or distance > (rules.maxDistance or SPAWN_MAX_DISTANCE) then
        debugSpawnNode(('distance %.1fm outside window'):format(distance))
        return nil
    end

    -- 可达性：路径距离必须存在且不能离谱（高架/河对岸会给出 -1 或数倍直线距离）。
    if type(CalculateTravelDistanceBetweenPoints) == 'function' then
        local okT, travel = pcall(CalculateTravelDistanceBetweenPoints,
            nodePos.x, nodePos.y, nodePos.z, playerCoords.x, playerCoords.y, playerCoords.z)
        if okT and type(travel) == 'number'
            and (travel <= 0 or travel > distance * (rules.maxTravelRatio or SPAWN_MAX_TRAVEL_RATIO)) then
            debugSpawnNode(('unreachable: travel=%.0fm straight=%.0fm'):format(travel, distance))
            return nil
        end
    end

    -- 视野：两个判据任一为真都算被看见。
    local visible = false
    if type(IsSphereVisible) == 'function' then
        local okv, value = pcall(IsSphereVisible, nodePos.x, nodePos.y, nodePos.z + 1.0, 8.0)
        visible = okv and isTrue(value)
    end
    if not visible and type(IsPointOnScreen) == 'function' then
        local okp, value = pcall(IsPointOnScreen, nodePos.x, nodePos.y, nodePos.z + 1.0, 1.0)
        visible = okp and isTrue(value)
    end
    if visible and rules.requireInvisible ~= false then
        debugSpawnNode('candidate is visible to the caller')
        return nil
    end

    -- 被车流占着的点不能生成（真机碰撞全部发生在出生瞬间）。
    --
    -- 这里原来用 `IsPositionOccupied(..., 4.0, true, true, ...)`，实测 37 个节点全被判"被占"
    -- ——那个 native 的参数语义按版本变（p8/p9 不同含义），结果就是永远生不出来。
    -- 改成 `GetClosestVehicle`：语义单一，只要 4.5m 内有车就换点。
    if type(GetClosestVehicle) == 'function' then
        local okV, blocker = pcall(GetClosestVehicle, nodePos.x, nodePos.y, nodePos.z, 4.5, 0, 70)
        if okV and type(blocker) == 'number' and blocker ~= 0 and DoesEntityExist(blocker) then
            debugSpawnNode('candidate is occupied by another vehicle')
            return nil
        end
    end

    -- 路网节点也可能贴着海/河（码头、海滩路）。
    local groundZ = dryGroundZ(nodePos.x, nodePos.y, nodePos.z)
    if not groundZ then
        debugSpawnNode(('candidate is in water or has no ground at %.0f,%.0f,%.0f (%.0fm)'):format(
            nodePos.x, nodePos.y, nodePos.z, #(nodePos - playerCoords)))
        return nil
    end
    return groundZ
end

--- 在**路网**上找一个合规落点（spawn v3 · P1；2026-10-30 起不再退回偏移点）。
---
--- 玩家反馈定下来的硬规则：支援车必须从路上来。所以这个函数是唯一入口，
--- 找不到合规节点就让这一单失败，绝不在草地/沙滩/海面上变出一辆警车。
--- 搜索中心扫四个（正后、更后、左侧后、右侧后），每个中心再扫 6 个 nth 候选，
--- 按"朝向顺不顺"挑最好的一个。
---@return vector3|nil spawn, number|nil heading
local function findSpawnNode(playerPed, lane)
    if GetConvar('police_backup_spawn_mode', 'node') == 'offset' then return nil end
    if type(GetNthClosestVehicleNodeFavourDirection) ~= 'function' then
        debugSpawnNode('native missing')
        return nil
    end

    local playerCoords = GetEntityCoords(playerPed)
    local shift = tonumber(lane) or 0
    local centers = {
        { SPAWN_NODE_SIDE, SPAWN_NODE_FORWARD },
        { SPAWN_NODE_SIDE, SPAWN_NODE_FORWARD - 30.0 },
        { SPAWN_NODE_SIDE + 20.0, SPAWN_NODE_FORWARD },
        { SPAWN_NODE_SIDE - 20.0, SPAWN_NODE_FORWARD },
    }

    -- 三档递进（玩家的硬规则是"必须在路网上"；在此基础上尽量满足距离与视角）：
    --   1) 理想：80–150m、路径 ≤3×直线、不可见、不被占、干地
    --   2) 放宽：80–200m、路径 ≤6×直线（河/高架绕行很常见）
    --   3) 兜底：80–250m、路径 ≤10×直线，允许被看见（总比没有支援好）
    local tiers = {
        { name = 'strict', maxDistance = 150.0, maxTravelRatio = 3.0, requireInvisible = true },
        { name = 'relaxed', maxDistance = 200.0, maxTravelRatio = 6.0, requireInvisible = true },
        { name = 'last', maxDistance = 250.0, maxTravelRatio = 10.0, requireInvisible = false },
        -- 4) 环境实在给不出 80m 的路（码头、海岛、水边一站周围全是水）：退到最近的一条
        --    仍然合规的路（≥40m，仍是干地/未被占），因为"必须在路网上"是硬规则，
        --    距离只是尽量满足。日志里 tier=closest 便于验收统计降级次数。
        { name = 'closest', minDistance = 40.0, maxDistance = 250.0,
          maxTravelRatio = 12.0, requireInvisible = false },
    }

    for _, rules in ipairs(tiers) do
        local best, bestDot = nil, -2.0
        for _, center in ipairs(centers) do
            local target = GetOffsetFromEntityInWorldCoords(
                playerPed, center[1] + shift * 15.0, center[2] - shift * 10.0, 0.0)
            for _, nth in ipairs(SPAWN_NODE_CANDIDATES) do
                local ok, heading, nodePos = pcall(GetNthClosestVehicleNodeFavourDirection,
                    target.x, target.y, target.z,
                    playerCoords.x, playerCoords.y, playerCoords.z,
                    nth, 1, 3.0, 0)
                if ok and type(heading) == 'number' and nodePos then
                    local groundZ = nodeIsUsable(nodePos, playerCoords, rules)
                    if groundZ then
                        local rad = math.rad(heading)
                        local dx, dy = playerCoords.x - nodePos.x, playerCoords.y - nodePos.y
                        local length = math.sqrt(dx * dx + dy * dy)
                        local dot = length > 0.01
                            and ((math.sin(rad) * dx / length) + (math.cos(rad) * dy / length)) or 0
                        if dot > bestDot then
                            bestDot = dot
                            best = { heading = heading, nth = nth,
                                pos = vector3(nodePos.x, nodePos.y, groundZ),
                                distance = #(nodePos - playerCoords) }
                        end
                    end
                end
            end
        end
        if best then
            print(('[custom-police] backup spawn node dist=%.1fm heading=%.0f dot=%.2f nth=%d tier=%s'):format(
                best.distance, best.heading, bestDot, best.nth, rules.name))
            return best.pos, best.heading
        end
    end

    if not best then
        debugSpawnNode('no candidate node passed the rules')
        return nil, nil
    end

    print(('[custom-police] backup spawn node dist=%.1fm heading=%.0f dot=%.2f nth=%d'):format(
        best.distance, best.heading, bestDot, best.nth))
    return best.pos, best.heading
end

-- 其他服务（验尸官等）要复用同一套路网取点规则：函数在文件内是 local，
-- 这里挂一个全局给同资源的其它 client 脚本用（FiveM 的跨脚本全局按名字直接读）。
BackupFindRoadNode = findSpawnNode

--- 调试用的偏移生成（只在 `police_backup_spawn_mode=offset` 时才会被调用）。
--- 生产路径**不用**它：玩家明确要求"必须从路网上来"。
local function spawnPoint(playerPed, lane)
    local shift = (tonumber(lane) or 0)
    local offset = GetOffsetFromEntityInWorldCoords(
        playerPed, SPAWN_SIDE + shift * 11.0, -SPAWN_FALLBACK_BACK - shift * 7.0, 0.0)
    local groundZ = dryGroundZ(offset.x, offset.y, offset.z)
    if not groundZ then return nil end
    return vector3(offset.x, offset.y, groundZ)
end

--- 支援单位配方（蓝图 §6.3 #5）。**故意不调原生"标记成警察"的那一个 native**：
--- 它会把 ped 交给原生警察 AI，原生 AI 会自己去"处理"通缉玩家，绕过
--- `police_backup_engage_wanted`（默认 0，NPC 不打玩家）与 findEnemies 的玩家排除。
--- 「被当成执法人员」这件事已经由 `SetPedRelationshipGroupHash(ped, BACKUP_GROUP)` 承担，
--- `isFriendlyGroup` 把 PLAYER/COP/BACKUP 三个组都当友军。
--- 司机能力/攻击性照蓝图给（0.9 / 0.1）：攻击性 0.1 = 不主动挑事。
local function configureOfficer(ped, veh, isDriver)
    SetEntityAsMissionEntity(ped, true, true)
    if isDriver then
        if type(SetDriverAbility) == 'function' then SetDriverAbility(ped, 0.9) end
        if type(SetDriverAggressiveness) == 'function' then SetDriverAggressiveness(ped, 0.1) end
    end
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

    local lane = pendingLane[requestId] or 0
    pendingLane[requestId] = nil

    -- 唯一生成路径：路网节点。取不到合规节点就让这一单失败——
    -- 宁可让玩家重按一次，也不要在草地/沙滩/海面上变出一辆警车。
    local spawn, spawnHeading = findSpawnNode(playerPed, lane)
    if not spawn and GetConvar('police_backup_spawn_mode', 'node') == 'offset' then
        spawn = spawnPoint(playerPed, lane)
        spawnHeading = (GetEntityHeading(playerPed) + 180.0) % 360.0
        if spawn then print('[custom-police] backup spawn fell back to offset placement (debug mode)') end
    end
    if not spawn then
        pending[requestId] = nil
        SetModelAsNoLongerNeeded(vehicleHash)
        SetModelAsNoLongerNeeded(pedHash)
        local at = GetEntityCoords(playerPed)
        print(('[custom-police] backup spawn failed: no road node matches the spawn rules (player at %.0f,%.0f,%.0f)'):format(
            at.x, at.y, at.z))
        notifyServerEnded(requestId, 'spawn_failed')
        return
    end
    local heading = spawnHeading
    if type(LoadAllPathNodes) == 'function' then pcall(LoadAllPathNodes, true) end
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
    -- 验收实验 A（AC-P5-04）：`police_backup_siren 0` 时关笛，用来对比"被不让行的车流撞"。
    local sirenOn = GetConvar('police_backup_siren', '1') == '1'
    SetVehicleSiren(vehicle, sirenOn)
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

    -- 验收自检（AC-P5-01/02）：出生距离、与玩家朝向的夹角、警笛是否真的开了。
    -- 只在 police_backup_debug=1 时打，验收时把这几行贴进 PR 当证据。
    if GetConvar('police_backup_debug', '0') == '1' then
        local playerAt = GetEntityCoords(playerPed)
        local vehicleAt = GetEntityCoords(vehicle)
        local delta = vehicleAt - playerAt
        local dist = #delta
        local angle = -1
        if dist > 0.01 then
            local forward = GetEntityForwardVector(playerPed)
            local dot = (forward.x * delta.x + forward.y * delta.y + forward.z * delta.z) / dist
            dot = math.max(-1.0, math.min(1.0, dot))
            angle = math.deg(math.acos(dot))
        end
        local siren = type(IsVehicleSirenOn) == 'function' and IsVehicleSirenOn(vehicle) or nil
        print(('[custom-police][debug] spawn check dist=%.1fm angle=%.0fdeg siren=%s'):format(
            dist, angle, tostring(siren)))
    end

    configureOfficer(driver, vehicle, true)
    if passenger and passenger ~= 0 and DoesEntityExist(passenger) then
        configureOfficer(passenger, vehicle, false)
    end

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
            elseif (function()
                local dist = #(vehicleCoords - playerCoords)
                if dist <= ARRIVE_RADIUS + BLOCKED_RADIUS_GRACE
                    and GetEntitySpeed(state.vehicle) < 1.0 then
                    state.stoppedAt = state.stoppedAt or now
                    return (now - state.stoppedAt) >= BLOCKED_WAIT_MS
                end
                state.stoppedAt = nil
                return false
            end)() then
                -- 到不了跟前（目标点在屋内/院内）：停稳两秒半就下车走过去。
                beginFoot(state, #(vehicleCoords - playerCoords))
            elseif #(vehicleCoords - playerCoords) <= ARRIVE_RADIUS
                and GetEntitySpeed(state.vehicle) < ARRIVE_SPEED then
                -- P3：必须在玩家身边**并且**慢下来才下车。以前这里是
                -- "距离 ≤20m 或 到 30s"，于是车还在两百米外就把人放下来跑步。
                beginFoot(state, #(vehicleCoords - playerCoords))
            elseif now - state.createdAt >= ESCORT_TIMEOUT_MS then
                -- 90 秒还没到：结束这一单（名额随之释放），而不是从远处跑过来。
                cleanup(requestId, true, 'escort_timeout')
                break
            else
                -- spawn v3 · P2：无进展看门狗（NPC 会先朝反方向开再掉头，光靠规划救不了）。
                local distanceToPlayer = #(vehicleCoords - playerCoords)
                local driveStyle = backupDriveStyle()

                -- 验收计数（AC-P5-05）：被环境车撞了几次。HasEntityCollidedWithAnything
                -- 每帧都可能为真，所以同一辆车 2 秒内只记一次。
                if type(HasEntityCollidedWithAnything) == 'function'
                    and HasEntityCollidedWithAnything(state.vehicle) then
                    if not state.lastHitAt or now - state.lastHitAt > 2000 then
                        state.lastHitAt = now
                        state.hits = (state.hits or 0) + 1
                        if GetConvar('police_backup_debug', '0') == '1' then
                            print(('[custom-police][debug] backup %s collision #%d at %.0fm'):format(
                                tostring(requestId), state.hits, distanceToPlayer))
                        end
                    end
                end
                if not state.progressDistance
                    or distanceToPlayer < state.progressDistance - STUCK_PROGRESS_M then
                    state.progressDistance = distanceToPlayer
                    state.progressAt = now
                    state.stalls = 0
                end
                if not state.progressAt then state.progressAt = now end
                -- 刚生成的 10 秒是起步/掉头时间，不能算"没进展"。
                if now - state.createdAt < SPAWN_GRACE_MS then
                    state.progressAt = now
                end

                if now - state.progressAt > STUCK_WINDOW_MS then
                    state.stalls = (state.stalls or 0) + 1
                    local speed = GetEntitySpeed(state.vehicle) or -1
                    print(('[custom-police] backup %s stalled #%d at %.0fm speed=%.1f'):format(
                        tostring(requestId), state.stalls, distanceToPlayer, speed))
                    if state.stalls >= 3 then
                        cleanup(requestId, true, 'vehicle_lost')
                        break
                    end
                    state.lastDriveTask = 0
                    state.progressAt = now
                end

                if shouldRetask(driver, 'TASK_VEHICLE_DRIVE_TO_COORD',
                        state.lastDriveTask, now, DRIVE_RETASK_HEARTBEAT_MS) then
                    if distanceToPlayer > LONG_RANGE_THRESHOLD
                        and type(TaskVehicleDriveToCoordLongrange) == 'function' then
                        TaskVehicleDriveToCoordLongrange(
                            driver, state.vehicle, playerCoords.x, playerCoords.y, playerCoords.z,
                            DRIVE_SPEED, driveStyle, ARRIVE_RADIUS)
                    else
                        TaskVehicleDriveToCoord(
                            driver, state.vehicle, playerCoords.x, playerCoords.y, playerCoords.z,
                            DRIVE_SPEED, 0, state.vehicleModel, driveStyle,
                            ARRIVE_RADIUS, true)
                    end
                    state.lastDriveTask = now
                end
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
