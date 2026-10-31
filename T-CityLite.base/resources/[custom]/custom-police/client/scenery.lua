-- client/scenery.lua — L1 布景层（蓝图 §6.2）：站点守卫 + 巡逻车。
--
-- 为什么放在客户端：`TaskStartScenarioInPlace` / `TaskVehicleDriveToCoordLongrange`
-- 这些行为 native 只在客户端存在（服务端建出来的人不会动，还会报 nil native）。
-- 代价是布景只在本地可见 —— 对"站点有人值班"这个观感目标来说可以接受，
-- 而且它天然不会在不同玩家之间打架。
--
-- 三条限制：只在离站点 120m 内生成、离远了自动收、`police_scenery 0` 一键关。

local GUARD_MODEL = 's_m_y_cop_01'
local PATROL_MODEL = 'police'
local SPAWN_DISTANCE = 120.0
local DESPAWN_DISTANCE = 260.0
local MAX_GUARDS = 2
local PATROL_SPEED = 12.0
local PATROL_STYLE = 786603
local TICK_MS = 5000

local active = nil   -- { station = vector3, peds = {}, vehicle =, driver =, loop =, index = }

local function enabled()
    return GetConvar('police_scenery', '1') == '1'
end

local function stations()
    local duty = Config and Config.Locations and Config.Locations.duty or {}
    local out = {}
    for _, coords in ipairs(duty) do out[#out + 1] = coords end
    return out
end

local function despawn()
    if not active then return end
    for _, ped in ipairs(active.peds or {}) do
        if ped and ped ~= 0 and DoesEntityExist(ped) then DeleteEntity(ped) end
    end
    if active.driver and DoesEntityExist(active.driver) then DeleteEntity(active.driver) end
    if active.vehicle and DoesEntityExist(active.vehicle) then DeleteEntity(active.vehicle) end
    active = nil
end

local function spawn(station)
    local guardHash = GetHashKey(GUARD_MODEL)
    local patrolHash = GetHashKey(PATROL_MODEL)
    if not EntityUtil.LoadModel(guardHash) or not EntityUtil.LoadModel(patrolHash) then return end

    local state = { station = station, peds = {}, loop = {}, index = 1 }
    for index = 1, MAX_GUARDS do
        local angle = math.rad(index * 150.0)
        local at = vector3(station.x + math.cos(angle) * 1.8, station.y + math.sin(angle) * 1.8, station.z)
        local ped = CreatePed(4, guardHash, at.x, at.y, at.z, (index * 150.0) % 360.0, false, true)
        if ped and ped ~= 0 then
            SetEntityAsMissionEntity(ped, false, true)
            SetEntityInvincible(ped, true)
            SetBlockingOfNonTemporaryEvents(ped, true)
            SetPedFleeAttributes(ped, 0, false)
            SetPedCanRagdoll(ped, false)
            TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_COP_IDLES', 0, true)
            state.peds[#state.peds + 1] = ped
        end
    end

    local bases = Config and Config.Locations and Config.Locations.vehicle or {}
    local base = bases[1]
    if base then
        local vehicle = CreateVehicle(patrolHash, base.x, base.y, base.z, base.w, false, true)
        if vehicle and vehicle ~= 0 then
            SetEntityAsMissionEntity(vehicle, false, true)
            SetVehicleOnGroundProperly(vehicle)
            local driver = CreatePed(4, guardHash, base.x, base.y, base.z, base.w, false, true)
            if driver and driver ~= 0 then
                SetEntityAsMissionEntity(driver, false, true)
                SetPedIntoVehicle(driver, vehicle, -1)
                SetBlockingOfNonTemporaryEvents(driver, true)
                SetPedFleeAttributes(driver, 0, false)
                SetDriverAbility(driver, 0.8)
                SetDriverAggressiveness(driver, 0.0)
                state.vehicle = vehicle
                state.driver = driver
                state.loop = {
                    vector3(base.x + 40.0, base.y + 10.0, base.z),
                    vector3(base.x + 40.0, base.y - 40.0, base.z),
                    vector3(base.x - 10.0, base.y - 40.0, base.z),
                    vector3(base.x - 10.0, base.y + 10.0, base.z),
                }
            end
        end
    end

    SetModelAsNoLongerNeeded(guardHash)
    SetModelAsNoLongerNeeded(patrolHash)
    active = state
    if GetConvar('police_scenery_debug', '0') == '1' then
        print(('[custom-police] scenery: peds=%d car=%s'):format(#state.peds,
            tostring(state.vehicle ~= nil)))
    end
end

CreateThread(function()
    while true do
        Wait(TICK_MS)
        if not enabled() or not Config or not Config.Locations then
            despawn()
        else
            local playerPed = PlayerPedId()
            if DoesEntityExist(playerPed) then
                local origin = GetEntityCoords(playerPed)
                if active and #(origin - active.station) > DESPAWN_DISTANCE then despawn() end
                if not active then
                    for _, station in ipairs(stations()) do
                        if #(origin - station) <= SPAWN_DISTANCE then
                            spawn(station)
                            break
                        end
                    end
                else
                    -- 巡逻车到点就发下一段
                    local target = active.loop[active.index]
                    if target and active.vehicle and DoesEntityExist(active.vehicle)
                        and active.driver and DoesEntityExist(active.driver) then
                        if #(GetEntityCoords(active.vehicle) - target) < 18.0 then
                            active.index = (active.index % #active.loop) + 1
                            target = active.loop[active.index]
                        end
                        TaskVehicleDriveToCoordLongrange(active.driver, active.vehicle,
                            target.x, target.y, target.z, PATROL_SPEED, PATROL_STYLE, 12.0)
                    end
                end
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    despawn()
end)
