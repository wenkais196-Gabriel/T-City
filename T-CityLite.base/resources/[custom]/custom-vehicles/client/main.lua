-- main.lua — custom-vehicles 客户端
--
-- 核心设计: 事件驱动 (gameEventTriggered) 替代高频 Tick 轮询
--   - 旧版 qb-vehiclekeys 有 robKeyLoop 0ms-100ms 死循环 → CPU 高占用
--   - 新版只监听 CEventNetworkPlayerEnteredVehicle 事件 → 空闲时零开销
--
-- 功能:
--   - L 键: 锁定/解锁车门
--   - G 键: 引擎开关
--   - 热线发动 / 撬锁 进度条 + 小游戏
--   - 离开车辆自动锁车

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 客户端本地钥匙缓存
-- ==============================================================

---@type table<string, { hasKeys: boolean, keyType: string, isOwner: boolean, ts: number }>
local stolenVehicle = nil   -- 当前无钥匙进入的车辆（必须在所有 handler 之前声明）
local keyCache = {}
local CACHE_TTL = Config.Vehicles.Performance.ClientCacheTTL * 1000

-- 防重入：CEventNetworkPlayerEnteredVehicle 可能在网络实体重建/座位切换时重复触发
-- 对同一车辆加入 2 秒 debounce，防止行驶中误锁门
local lastEnteredVeh = nil
local lastEnteredTime = 0

-- Carjack 状态（替代 qb-vehiclekeys 的 Carjack 功能）
local isCarjacking = false
local canCarjack = true
local carjackAlertSent = false

local LOCKPICK_ALLOWED = { [8]=true, [13]=true, [14]=true, [15]=true, [16]=true, [19]=true, [21]=true }
local HOTWIRE_ALLOWED  = { [13]=true, [14]=true, [15]=true, [16]=true, [19]=true, [21]=true }

-- ==============================================================
-- 辅助函数
-- ==============================================================

--- 获取当前车辆车牌
local function getCurrentVehiclePlate()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return nil end
    return GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
end

--- 检查是否有钥匙（优先内存缓存，每车牌独立 TTL）
---@param plate string
---@return boolean hasKey
---@return boolean isDefinitive  true=缓存命中或同步兜底命中, false=冷缓存已发异步查询
local function hasKeys(plate)
    if not plate then return false, true end
    -- 统一规范化：trim + upper，确保与 KeyManager 服务端对齐
    plate = plate:gsub('^%s+', ''):gsub('%s+$', ''):upper()

    -- 缓存命中：TTL=0 表示永不过期，仅靠服务端推送事件刷新
    local cached = keyCache[plate]
    if cached and cached.ts then
        if CACHE_TTL == 0 or (GetGameTimer() - cached.ts) < CACHE_TTL then
            return cached.hasKeys, true
        end
    end

    -- 同步兜底：尝试从 qb-vehiclekeys 本地 KeysList 查询
    -- qb-vehiclekeys 的 HasKeys 是纯内存表查询，无异步开销
    -- 当 custom-vehicles 作为 drop-in replacement 且 qb-vehiclekeys 仍在运行时可用
    local qbHasKeys = false
    pcall(function()
        qbHasKeys = exports['qb-vehiclekeys']:HasKeys(plate)
    end)
    if qbHasKeys then
        keyCache[plate] = { hasKeys = true, keyType = 'synced', isOwner = false, ts = GetGameTimer() }
        return true, true  -- 确认有钥匙
    end

    -- 异步向服务端查询（冷缓存，结果未确认）
    TriggerServerEvent(Config.Vehicles.Events.CHECK_KEYS, plate)
    return false, false  -- isDefinitive=false 表示等待服务器回传
end

--- 检查职业共享钥匙（警车/拖车等，替代 qb-vehiclekeys 的 AreKeysJobShared）
---@param veh number
---@return boolean
local function AreKeysJobShared(veh)
    if not veh or veh == 0 then return false end
    local sharedConfig = Config.Vehicles.SharedKeys
    if not sharedConfig then return false end

    local playerData = QBCore.Functions.GetPlayerData()
    if not playerData or not playerData.job then return false end

    local jobName = playerData.job.name
    local onDuty = playerData.job.onduty
    local jobKeys = sharedConfig[jobName]
    if not jobKeys then return false end
    if jobKeys.requireOnduty and not onDuty then return false end

    local vehName = GetDisplayNameFromVehicleModel(GetEntityModel(veh)):upper()
    for _, model in ipairs(jobKeys.vehicles) do
        if model:upper() == vehName then
            local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
            if not hasKeys(plate) then
                TriggerServerEvent('qb-vehiclekeys:server:AcquireVehicleKeys', plate)
            end
            return true
        end
    end
    return false
end

--- 获取车内所有 NPC 乘员
---@param veh number
---@return table
local function GetPedsInVehicle(veh)
    local peds = {}
    for seat = -1, GetVehicleModelNumberOfSeats(GetEntityModel(veh)) - 2 do
        local pedInSeat = GetPedInVehicleSeat(veh, seat)
        if not IsPedAPlayer(pedInSeat) and pedInSeat ~= 0 then
            peds[#peds + 1] = pedInSeat
        end
    end
    return peds
end

--- 检查当前武器是否被禁止用于 Carjack
local function IsBlacklistedWeapon()
    local weapon = GetSelectedPedWeapon(PlayerPedId())
    if weapon == nil then return false end
    for _, v in ipairs(Config.Vehicles.NoCarjackWeapons) do
        if weapon == joaat(v) then return true end
    end
    return false
end

--- 让 NPC 逃离玩家
local function MakePedFlee(ped)
    SetPedFleeAttributes(ped, 0, 0)
    TaskReactAndFleePed(ped, PlayerPedId())
end

--- 加载动画字典
local function loadAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        RequestAnimDict(dict)
        Wait(0)
    end
end

--- 获取车载乘员列表（不含驾驶座）
---@param veh number
---@return boolean hasPassengers
local function vehicleHasPassengers(veh)
    if not veh or veh == 0 then return false end
    local maxSeats = GetVehicleMaxNumberOfPassengers(veh)
    for i = -1, maxSeats - 1 do
        if not IsVehicleSeatFree(veh, i) then
            local pedInSeat = GetPedInVehicleSeat(veh, i)
            if pedInSeat and pedInSeat ~= PlayerPedId() then
                return true
            end
        end
    end
    return false
end

-- ==============================================================
-- 事件: 钥匙状态更新（来自服务端）
-- ==============================================================

RegisterNetEvent(Config.Vehicles.Events.KEYS_UPDATED, function(data)
    local now = GetGameTimer()
    if type(data) == 'table' then
        if data.plate then
            local normPlate = data.plate:gsub('^%s+', ''):gsub('%s+$', ''):upper()
            keyCache[normPlate] = { hasKeys = data.hasKeys, keyType = data.keyType, isOwner = data.isOwner, ts = now }
            -- 拿到钥匙 → 解除 stolenVehicle 熄火循环 + 自动点火
            if data.hasKeys and stolenVehicle then
                local svPlate = GetVehicleNumberPlateText(stolenVehicle):gsub('^%s+', ''):gsub('%s+$', ''):upper()
                if svPlate == normPlate then
                    stolenVehicle = nil
                    SetVehicleEngineOn(stolenVehicle, true, false, false)
                end
            end
        else
            keyCache = {}
            for _, k in ipairs(data) do
                keyCache[k.plate] = { hasKeys = true, keyType = k.keyType, isOwner = k.isOwner, ts = now }
            end
        end
    end
end)

-- ==============================================================
-- 事件: 引擎开关（来自服务端授权）
-- ==============================================================

RegisterNetEvent(Config.Vehicles.Events.ENGINE_TOGGLE, function(authorized)
    if not authorized then return end

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return end

    local engineState = GetIsVehicleEngineRunning(veh)
    if engineState then
        SetVehicleEngineOn(veh, false, true, true)
    else
        SetVehicleEngineOn(veh, true, true, true)
    end
end)

-- ==============================================================
-- 事件: 车辆进入检测 (gameEventTriggered) — 零 Tick 方案
-- 无钥匙车辆持续强制熄火，防止 GTA5 原生踩油门自动点火
-- ==============================================================

AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkPlayerEnteredVehicle' then return end

    local player = args[1]
    local veh = args[2]

    if player ~= PlayerId() then return end
    if not veh or veh == 0 then return end

    -- 防重入：同一车辆 2 秒内不重复处理（防止网络实体重建/座位切换误触发锁门）
    local now = GetGameTimer()
    if veh == lastEnteredVeh and (now - lastEnteredTime) < 2000 then return end
    lastEnteredVeh = veh
    lastEnteredTime = now

    local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()

    if not hasKeys(plate) and not AreKeysJobShared(veh) then
        SetVehicleEngineOn(veh, false, true, true)
        -- 撬锁过的车不反锁，让玩家能进入（引擎仍需热线发动）
        if not Entity(veh).state.lockpicked then
            SetVehicleDoorsLocked(veh, 2)
        end
        stolenVehicle = veh
        QBCore.Functions.Notify('你没有这辆车的钥匙 — 引擎已锁定', 'error')
    else
        stolenVehicle = nil
        SetVehicleDoorsLocked(veh, 0)
    end
end)

-- 持续强制熄火（无钥匙车辆踩油门也不会启动）
Citizen.CreateThread(function()
    while true do
        Wait(250)
        if stolenVehicle and DoesEntityExist(stolenVehicle) then
            local ped = PlayerPedId()
            if GetVehiclePedIsIn(ped, false) == stolenVehicle then
                if GetIsVehicleEngineRunning(stolenVehicle) then
                    SetVehicleEngineOn(stolenVehicle, false, true, true)
                end
            else
                stolenVehicle = nil
            end
        end
    end
end)

-- ==============================================================
-- 上车拦截: 轻量轮询 GetVehiclePedIsTryingToEnter
-- 替代 qb-vehiclekeys robKeyLoop (0-100ms 死循环)，使用 Convar 可配间隔
-- 在玩家完成上车动画前锁门，阻止无钥匙进入街头/NPC 车辆
-- ==============================================================

local function isNoLockVehicle(veh)
    if not veh or veh == 0 then return true end
    -- 已撬锁 / 系统标记免锁
    if Entity(veh).state.ignoreLocks then return true end
    if Entity(veh).state.lockpicked then return true end
    local vehClass = GetVehicleClass(veh)
    for _, classId in ipairs(Config.Vehicles.Security.NoLockVehicleClasses) do
        if vehClass == classId then return true end
    end
    return false
end

Citizen.CreateThread(function()
    local lastCheckedVehicle = nil
    while true do
        local interval = Config.Vehicles.Security.EntryCheckIntervalMs
        Citizen.Wait(interval)

        if not Config.Vehicles.Security.LockNPCVehicles then
            lastCheckedVehicle = nil
            goto continue
        end

        local ped = PlayerPedId()
        -- 已在车内则跳过
        if IsPedInAnyVehicle(ped, false) then
            lastCheckedVehicle = nil
            goto continue
        end

        local entering = GetVehiclePedIsTryingToEnter(ped)
        if entering == 0 or entering == lastCheckedVehicle then
            goto continue
        end

        -- 同一辆车不重复检查（防抖）
        lastCheckedVehicle = entering

        -- 免锁车辆直接放行
        if isNoLockVehicle(entering) then
            goto continue
        end

        local plate = GetVehicleNumberPlateText(entering):gsub('^%s+', ''):gsub('%s+$', ''):upper()

        -- 已撬锁车辆放行（不反锁）
        if Entity(entering).state.lockpicked then
            goto continue
        end

        -- 🆕 死亡 NPC 司机：触发搜钥匙进度条（替代 qb-vehiclekeys robKeyLoop）
        local driver = GetPedInVehicleSeat(entering, -1)
        if driver ~= 0 and not IsPedAPlayer(driver) and IsEntityDead(driver) and not hasKeys(plate) then
            -- 解锁车门让玩家进入
            SetVehicleDoorsLocked(entering, 1)
            -- 搜钥匙进度条
            exports['progressbar']:Progress({
                name = 'steal_keys_dead_npc',
                duration = 2500,
                label = '正在搜找钥匙...',
                useWhileDead = false,
                canCancel = true,
                controlDisables = { disableMovement = false, disableCarMovement = true, disableMouse = false, disableCombat = true },
            }, function(cancelled)
                if not cancelled then
                    TriggerServerEvent('qb-vehiclekeys:server:AcquireVehicleKeys', plate)
                end
            end)
            -- 放行（门已解锁）
            goto continue
        end

        if not hasKeys(plate) and not AreKeysJobShared(entering) then
            SetVehicleDoorsLocked(entering, 2)
        end

        ::continue::
    end
end)

-- ==============================================================
-- 按键: L — 锁定/解锁
-- ==============================================================

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)

        if IsControlJustPressed(0, 182) then -- L key
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)

            -- 在车内: 锁定所有车门
            if veh and veh ~= 0 then
                local plate = getCurrentVehiclePlate()
                if plate and hasKeys(plate) then
                    local lockState = GetVehicleDoorLockStatus(veh)
                    if lockState < 2 then
                        -- 有乘客时不锁
                        if vehicleHasPassengers(veh) then
                            QBCore.Functions.Notify('车内有乘客，无法锁定', 'error')
                        else
                            SetVehicleDoorsLocked(veh, 2)
                            QBCore.Functions.Notify('车门已锁定', 'primary')
                            TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 5.0, 'lock', 0.3)
                        end
                    else
                        SetVehicleDoorsLocked(veh, 0)
                        QBCore.Functions.Notify('车门已解锁', 'primary')
                        TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 5.0, 'unlock', 0.3)
                    end
                end
                return
            end

            -- 不在车内: 对最近的车操作
            local playerCoords = GetEntityCoords(ped)
            local closestVeh = nil
            local closestDist = 5.0

            local allVehicles = GetGamePool('CVehicle')
            for _, v in ipairs(allVehicles) do
                local vCoords = GetEntityCoords(v)
                local dist = #(playerCoords - vCoords)
                if dist < closestDist then
                    closestDist = dist
                    closestVeh = v
                end
            end

            if closestVeh then
                local plate = GetVehicleNumberPlateText(closestVeh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
                if hasKeys(plate) then
                    local lockState = GetVehicleDoorLockStatus(closestVeh)
                    if lockState < 2 then
                        SetVehicleDoorsLocked(closestVeh, 2)
                        QBCore.Functions.Notify('车门已锁定', 'primary')
                        TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 5.0, 'lock', 0.3)
                    else
                        SetVehicleDoorsLocked(closestVeh, 0)
                        QBCore.Functions.Notify('车门已解锁', 'primary')
                        TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 5.0, 'unlock', 0.3)
                    end
                end
            end
        end
    end
end)

-- ==============================================================
-- 按键: G — 引擎开关
-- ==============================================================

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)

        if IsControlJustPressed(0, 47) then -- G key
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)

            if not veh or veh == 0 then return end

            local plate = getCurrentVehiclePlate()
            if not plate or not hasKeys(plate) then
                QBCore.Functions.Notify('你没有这辆车的钥匙', 'error')
                return
            end

            -- 必须在驾驶座
            if GetPedInVehicleSeat(veh, -1) ~= ped then
                QBCore.Functions.Notify('你必须坐在驾驶座', 'error')
                return
            end

            local engineState = GetIsVehicleEngineRunning(veh)
            if engineState then
                SetVehicleEngineOn(veh, false, false, true)
            else
                SetVehicleEngineOn(veh, true, false, false)
            end
        end
    end
end)

-- ==============================================================
-- 车辆离开事件: 自动锁车 + 熄火
-- ==============================================================

local lastVehicle = nil
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(500)

        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)

        -- 检测到离开车辆
        if lastVehicle and lastVehicle ~= veh then
            if lastVehicle ~= 0 and DoesEntityExist(lastVehicle) then
                SetVehicleEngineOn(lastVehicle, false, true, true)
                if not vehicleHasPassengers(lastVehicle) then
                    -- 有钥匙 或 已撬锁 → 不自动锁门
                    local plate = GetVehicleNumberPlateText(lastVehicle):gsub('^%s+', ''):gsub('%s+$', ''):upper()
                    if not hasKeys(plate) and not AreKeysJobShared(lastVehicle) and not Entity(lastVehicle).state.lockpicked then
                        SetVehicleDoorsLocked(lastVehicle, 2)
                    end
                end
            end
        end

        lastVehicle = veh
    end
end)

-- ==============================================================
-- 命令: /givekeys — 分享钥匙给附近玩家
-- ==============================================================

RegisterCommand('givekeys', function(_, args)
    local targetId = tonumber(args[1])
    if not targetId then
        QBCore.Functions.Notify('用法: /givekeys [玩家ID]', 'error')
        return
    end

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then
        -- 尝试对最近的车操作
        local coords = GetEntityCoords(ped)
        local allVehicles = GetGamePool('CVehicle')
        local closestDist = 5.0
        for _, v in ipairs(allVehicles) do
            local dist = #(coords - GetEntityCoords(v))
            if dist < closestDist then
                veh = v
                break
            end
        end
    end

    if not veh or veh == 0 then
        QBCore.Functions.Notify('你不在任何车辆附近', 'error')
        return
    end

    local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
    TriggerServerEvent(Config.Vehicles.Events.GIVE_KEYS, plate, targetId)
end, false)

-- ==============================================================
-- 命令: /removekeys — 取消钥匙分享
-- ==============================================================

RegisterCommand('removekeys', function(_, args)
    local targetId = tonumber(args[1])
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return end

    local plate = GetVehicleNumberPlateText(veh):gsub('^%s+', ''):gsub('%s+$', ''):upper()
    TriggerServerEvent(Config.Vehicles.Events.REMOVE_KEYS, plate, targetId)
end, false)

-- ==============================================================
-- 命令: /hotwire — 热线发动（需进度条资源）
-- ==============================================================

RegisterCommand('hotwire', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then
        QBCore.Functions.Notify('你必须坐在驾驶座', 'error')
        return
    end

    local class = GetVehicleClass(veh)
    if HOTWIRE_ALLOWED[class] then
        QBCore.Functions.Notify('此载具无法热线发动', 'error')
        return
    end

    if GetPedInVehicleSeat(veh, -1) ~= ped then
        QBCore.Functions.Notify('你必须坐在驾驶座', 'error')
        return
    end

    -- 进度条 + 动画
    if exports['progressbar'] then
        exports['progressbar']:Progress({
            name = 'vehicle_hotwire',
            duration = Config.Vehicles.Security.HotwireDuration,
            label = '正在热线发动...',
            useWhileDead = false,
            canCancel = true,
            controlDisables = { disableMovement = true, disableCarMovement = true, disableMouse = false, disableCombat = true },
        }, function(cancelled)
            if not cancelled then
                local netId = NetworkGetNetworkIdFromEntity(veh)
                TriggerServerEvent(Config.Vehicles.Events.HOTWIRE_ATTEMPT, netId, class)
            end
        end)
    else
        local netId = NetworkGetNetworkIdFromEntity(veh)
        TriggerServerEvent(Config.Vehicles.Events.HOTWIRE_ATTEMPT, netId, class)
    end
end, false)

-- ==============================================================
-- 命令: /lockpick — 撬开车门
-- ==============================================================

RegisterCommand('lockpick', function()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local allVehicles = GetGamePool('CVehicle')
    local closestVeh = nil
    local closestDist = 3.0
    for _, v in ipairs(allVehicles) do
        local dist = #(coords - GetEntityCoords(v))
        if dist < closestDist then
            closestDist = dist
            closestVeh = v
        end
    end

    if not closestVeh then
        QBCore.Functions.Notify('附近没有车辆', 'error')
        return
    end

    local class = GetVehicleClass(closestVeh)
    if LOCKPICK_ALLOWED[class] then
        QBCore.Functions.Notify('此载具无法撬锁', 'error')
        return
    end

    if exports['progressbar'] then
        exports['progressbar']:Progress({
            name = 'vehicle_lockpick',
            duration = Config.Vehicles.Security.LockpickDuration,
            label = '正在撬锁...',
            useWhileDead = false,
            canCancel = true,
            controlDisables = { disableMovement = true, disableCarMovement = true, disableMouse = false, disableCombat = true },
            animation = {
                animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                anim = 'machinic_loop_mechandplayer',
            },
        }, function(cancelled)
            if not cancelled then
                local netId = NetworkGetNetworkIdFromEntity(closestVeh)
                TriggerServerEvent(Config.Vehicles.Events.LOCKPICK_ATTEMPT, netId, class)
            end
        end)
    else
        local netId = NetworkGetNetworkIdFromEntity(closestVeh)
        TriggerServerEvent(Config.Vehicles.Events.LOCKPICK_ATTEMPT, netId, class)
    end
end, false)

-- ==============================================================
-- 玩家加载后同步钥匙状态
-- ==============================================================

AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    Citizen.SetTimeout(2000, function()
        TriggerServerEvent(Config.Vehicles.Events.REQUEST_KEYS)
    end)
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        Citizen.SetTimeout(2000, function()
            TriggerServerEvent(Config.Vehicles.Events.REQUEST_KEYS)
        end)
    end
end)

-- ==============================================================
-- 服务端 → 客户端: 远程解锁/锁门 (热线/撬锁用)
-- ==============================================================

RegisterNetEvent('custom-vehicles:client:setDoorLock', function(vehNetId, lockState)
    local veh = NetworkGetEntityFromNetworkId(vehNetId)
    if veh and veh ~= 0 then
        SetVehicleDoorsLocked(veh, lockState)
    end
end)

RegisterNetEvent('custom-vehicles:client:setStolen', function(vehNetId, stolen)
    local veh = NetworkGetEntityFromNetworkId(vehNetId)
    if veh and veh ~= 0 then
        Entity(veh).state.isStolen = stolen or nil
    end
end)

-- ==============================================================
-- Carjack: 用武器瞄准 NPC 司机抢夺车辆（替代 qb-vehiclekeys）
-- ==============================================================

local function CarjackVehicle(target)
    if not Config.Vehicles.CarJackEnable then return end

    isCarjacking = true
    canCarjack = false
    loadAnimDict('mp_am_hold_up')

    local vehicle = GetVehiclePedIsUsing(target)
    local occupants = GetPedsInVehicle(vehicle)

    -- 恐吓车内所有 NPC
    for p = 1, #occupants do
        local ped = occupants[p]
        CreateThread(function()
            TaskPlayAnim(ped, 'mp_am_hold_up', 'holdup_victim_20s', 8.0, -8.0, -1, 49, 0, false, false, false)
            PlayPain(ped, 6, 0)
            FreezeEntityPosition(vehicle, true)
            SetVehicleUndriveable(vehicle, true)
        end)
        Wait(math.random(200, 500))
    end

    -- NPC死亡或距离过远 → 取消
    CreateThread(function()
        while isCarjacking do
            local dist = #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(target))
            if IsPedDeadOrDying(target) or dist > 7.5 then
                TriggerEvent('progressbar:client:cancel')
                FreezeEntityPosition(vehicle, false)
                SetVehicleUndriveable(vehicle, false)
            end
            Wait(100)
        end
    end)

    -- 进度条
    exports['progressbar']:Progress({
        name = 'carjack_vehicle',
        duration = Config.Vehicles.CarjackingTime,
        label = '正在抢夺车辆...',
        useWhileDead = false,
        canCancel = true,
        controlDisables = { disableMovement = true, disableCarMovement = true, disableMouse = false, disableCombat = true },
    }, function(cancelled)
        local hasWeapon, weaponHash = GetCurrentPedWeapon(PlayerPedId(), true)
        if cancelled or not hasWeapon or not isCarjacking then
            isCarjacking = false
            Wait(Config.Vehicles.DelayBetweenCarjackings)
            canCarjack = true
            return
        end

        local chance = Config.Vehicles.CarjackChance[tostring(GetWeapontypeGroup(weaponHash))] or 0.5

        if math.random() <= chance then
            local plate = QBCore.Functions.GetPlate(vehicle)
            -- 赶走所有 NPC
            for p = 1, #occupants do
                local ped = occupants[p]
                CreateThread(function()
                    FreezeEntityPosition(vehicle, false)
                    SetVehicleUndriveable(vehicle, false)
                    TaskLeaveVehicle(ped, vehicle, 0)
                    PlayPain(ped, 6, 0)
                    Wait(1250)
                    ClearPedTasksImmediately(ped)
                    PlayPain(ped, math.random(7, 8), 0)
                    MakePedFlee(ped)
                end)
            end
            TriggerServerEvent('hud:server:GainStress', math.random(1, 4))
            TriggerServerEvent('qb-vehiclekeys:server:AcquireVehicleKeys', plate)
            QBCore.Functions.Notify('抢夺成功！', 'success')
        else
            QBCore.Functions.Notify('抢夺失败！', 'error')
            FreezeEntityPosition(vehicle, false)
            SetVehicleUndriveable(vehicle, false)
            MakePedFlee(target)
            TriggerServerEvent('hud:server:GainStress', math.random(1, 4))
        end

        isCarjacking = false
        Wait(2000)
        -- 报警
        if not carjackAlertSent then
            carjackAlertSent = true
            local alertChance = Config.Vehicles.PoliceAlertChance
            if GetClockHours() >= 1 and GetClockHours() <= 6 then
                alertChance = Config.Vehicles.PoliceNightAlertChance
            end
            if math.random() <= alertChance then
                TriggerServerEvent('police:server:policeAlert', '车辆抢夺')
            end
            SetTimeout(Config.Vehicles.AlertCooldown, function()
                carjackAlertSent = false
            end)
        end
        Wait(Config.Vehicles.DelayBetweenCarjackings)
        canCarjack = true
    end, function()
        -- 取消
        MakePedFlee(target)
        isCarjacking = false
        Wait(Config.Vehicles.DelayBetweenCarjackings)
        canCarjack = true
    end)
end

-- Carjack 检测循环：玩家用枪瞄准 NPC 司机时触发
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(100)

        if not LocalPlayer.state.isLoggedIn then goto continue_cj end
        if not Config.Vehicles.CarJackEnable then goto continue_cj end
        if not canCarjack or isCarjacking then goto continue_cj end

        local ped = PlayerPedId()
        if IsPedInAnyVehicle(ped, false) then goto continue_cj end

        local aiming, targetPed = GetEntityPlayerIsFreeAimingAt(PlayerId())
        if not aiming or not targetPed or targetPed == 0 then goto continue_cj end
        if not DoesEntityExist(targetPed) then goto continue_cj end
        if not IsPedInAnyVehicle(targetPed, false) then goto continue_cj end
        if IsEntityDead(targetPed) then goto continue_cj end
        if IsPedAPlayer(targetPed) then goto continue_cj end

        local targetVeh = GetVehiclePedIsIn(targetPed)
        if GetPedInVehicleSeat(targetVeh, -1) ~= targetPed then goto continue_cj end

        -- 免疫车辆检查
        local immune = false
        for _, v in ipairs(Config.Vehicles.ImmuneVehicles) do
            if GetEntityModel(targetVeh) == joaat(v) then immune = true; break end
        end
        if immune then goto continue_cj end

        -- 武器黑名单
        if IsBlacklistedWeapon() then goto continue_cj end

        -- 距离检查
        if #(GetEntityCoords(ped) - GetEntityCoords(targetPed)) < 5.0 then
            CarjackVehicle(targetPed)
        end

        ::continue_cj::
    end
end)

print('[custom-vehicles] 🚗 客户端已就绪 — 事件驱动模式，空闲 Tick 零开销')

-- ==============================================================
-- 兼容旧版 qb-vehiclekeys 客户端事件（15+ 外部脚本依赖）
-- ==============================================================

-- qb-core / qb-garages / qb-policejob / qb-ambulancejob 等
-- 触发此事件声明车辆所有权 → 转发服务端 compat.lua 处理
RegisterNetEvent('vehiclekeys:client:SetOwner', function(plate)
    if not plate then return end
    TriggerServerEvent('qb-vehiclekeys:server:AcquireVehicleKeys', plate)
end)
