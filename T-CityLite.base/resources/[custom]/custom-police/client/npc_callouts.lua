-- client/npc_callouts.lua — presentation for server-owned NPC callouts.
--
-- Responsibilities:
--   * build one local scene per callout (cars / victim / clerk / suspects),
--   * give armed suspects a weapon, armour and a police-only hostile group,
--   * show a blip + 3D prompt and report the result with E once controlled,
--   * remove every entity again on NpcCalloutEnd, resource stop, or after the
--     player has been more than 300m away for 60 seconds.
--
-- The client never creates an incident, never picks the location and never
-- decides the payout. Scene coordinates always come from the server.

local QBCore = exports['qb-core']:GetCoreObject()

local HOSTILE_GROUP_NAME = 'TCT_NPC_CALLOUT'
local HOSTILE_GROUP = GetHashKey(HOSTILE_GROUP_NAME)
local PLAYER_GROUP = GetHashKey('PLAYER')
local COP_GROUP = GetHashKey('COP')

local CONTROL_E = 38
local REPORT_DEBOUNCE_MS = 500
local REPORT_RETRY_MS = 15000
local LEAVE_RADIUS = (NPCCallouts and NPCCallouts.DESPAWN_RADIUS) or 300.0
local LEAVE_GRACE_MS = (NPCCallouts and NPCCallouts.DESPAWN_GRACE_MS) or 60000
local TREAT_RADIUS = 3.0
local REPORT_RADIUS = 15.0
local DRAW_RADIUS = 80.0

local scene = nil        -- the single active local scene
local spawning = nil     -- { incidentId = number, cancelled = boolean }
local sceneLoop          -- forward declaration (buildScene starts the thread)

local function notify(text, kind)
    pcall(function()
        QBCore.Functions.Notify(text, kind or 'primary')
    end)
end

--- Run a native without letting one unsupported build kill the scene thread.
local function safe(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function setupRelationshipGroups()
    if type(DoesRelationshipGroupExist) ~= 'function' or type(AddRelationshipGroup) ~= 'function' then
        return
    end
    if not DoesRelationshipGroupExist(HOSTILE_GROUP) then
        AddRelationshipGroup(HOSTILE_GROUP_NAME)
    end
    if type(SetRelationshipBetweenGroups) ~= 'function' then return end
    -- 5 = hate. The scene group is hostile to players and cops only, so random
    -- civilians are not dragged into the fight (and do not return fire).
    SetRelationshipBetweenGroups(5, HOSTILE_GROUP, PLAYER_GROUP)
    SetRelationshipBetweenGroups(5, PLAYER_GROUP, HOSTILE_GROUP)
    SetRelationshipBetweenGroups(5, HOSTILE_GROUP, COP_GROUP)
    SetRelationshipBetweenGroups(5, COP_GROUP, HOSTILE_GROUP)
end

setupRelationshipGroups()

local function loadModel(modelHash)
    if type(modelHash) ~= 'number' or modelHash == 0 then return false end
    if type(IsModelInCdimage) ~= 'function' or not IsModelInCdimage(modelHash) then return false end
    if type(HasModelLoaded) ~= 'function' or type(RequestModel) ~= 'function' then return false end
    if HasModelLoaded(modelHash) then return true end
    RequestModel(modelHash)
    local deadline = GetGameTimer() + 10000
    while not HasModelLoaded(modelHash) do
        if GetGameTimer() > deadline then return false end
        if spawning and spawning.cancelled then return false end
        Wait(10)
    end
    return true
end

local function loadFirstModel(names)
    if type(names) ~= 'table' then return nil end
    for _, name in ipairs(names) do
        local hash = GetHashKey(name)
        if loadModel(hash) then return hash end
    end
    return nil
end

local function groundZ(x, y, z)
    if type(GetGroundZFor_3dCoord) ~= 'function' then return z end
    local ok, found, result = pcall(GetGroundZFor_3dCoord, x, y, z + 50.0, false)
    if ok and found == true and result then return result end
    return z
end

local function rotated(base, offset, headingDeg)
    local ox = tonumber(offset and offset.x) or 0.0
    local oy = tonumber(offset and offset.y) or 0.0
    local oz = tonumber(offset and offset.z) or 0.0
    local rad = math.rad(tonumber(headingDeg) or 0.0)
    return {
        x = base.x + ox * math.cos(rad) - oy * math.sin(rad),
        y = base.y + ox * math.sin(rad) + oy * math.cos(rad),
        z = base.z + oz,
    }
end

local function deleteEntity(entity)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        safe(SetEntityAsMissionEntity, entity, false, true)
        safe(DeleteEntity, entity)
    end
end

local function deleteVehicle(vehicle)
    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
        safe(SetEntityAsMissionEntity, vehicle, false, true)
        safe(DeleteVehicle, vehicle)
    end
end

local function cleanupScene(reason)
    local state = scene
    if not state then
        if spawning then spawning.cancelled = true end
        return
    end
    scene = nil

    if state.blip and state.blip ~= 0 and safe(DoesBlipExist, state.blip) then
        safe(RemoveBlip, state.blip)
    end
    for _, ped in ipairs(state.peds or {}) do deleteEntity(ped) end
    for _, vehicle in ipairs(state.vehicles or {}) do deleteVehicle(vehicle) end

    if reason then
        print(('[custom-police] NPC callout #%s scene cleaned up (%s)'):format(
            tostring(state.incidentId), tostring(reason)))
    end
end

local function currentPlayerPed()
    local ped = PlayerPedId()
    if ped and ped ~= 0 and DoesEntityExist(ped) then return ped end
    return nil
end

local function isPedDead(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return true end
    local ok, dead = pcall(IsPedDeadOrDying, ped, true)
    return ok and dead == true
end

local function isPedRestrained(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return true end
    local ok, cuffed = pcall(IsEntityPlayingAnim, ped, 'mp_arresting', 'idle', 3)
    return ok and cuffed == true
end

local function buildBlip(coords, label)
    local blip = safe(AddBlipForCoord, coords.x, coords.y, coords.z)
    if not blip or blip == 0 then return 0 end
    safe(SetBlipSprite, blip, 161)
    safe(SetBlipColour, blip, 1)
    safe(SetBlipScale, blip, 1.0)
    safe(SetBlipAsShortRange, blip, false)
    safe(BeginTextCommandSetBlipName, 'STRING')
    safe(AddTextComponentSubstringPlayerName, ('[NPC] %s'):format(tostring(label or '警情')))
    safe(EndTextCommandSetBlipName, blip)
    return blip
end

local function damageVehicle(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end
    local severity = math.random()
    safe(SetVehicleBodyHealth, vehicle, 250.0 + severity * 350.0)
    if severity < 0.35 then
        safe(SetVehicleEngineHealth, vehicle, -1500.0)
    else
        safe(SetVehicleEngineHealth, vehicle, 250.0 + severity * 300.0)
    end
    safe(SetVehicleDoorBroken, vehicle, 0, true)
    safe(SetVehicleDoorBroken, vehicle, 1, true)
    safe(SetVehicleTyreBurst, vehicle, 0, true, 1000.0)
    safe(SetVehicleTyreBurst, vehicle, 1, true, 1000.0)
end

local function spawnVehicle(config, center, heading)
    local hash = loadFirstModel(config.models or {})
    if not hash then return nil end
    local pos = rotated(center, config.offset, heading)
    local z = groundZ(pos.x, pos.y, pos.z) + 0.1
    local vehicle = CreateVehicle(hash, pos.x, pos.y, z,
        heading + (tonumber(config.heading) or 0.0), true, true)
    SetModelAsNoLongerNeeded(hash)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil end

    safe(SetEntityAsMissionEntity, vehicle, true, true)
    safe(SetVehicleOnGroundProperly, vehicle)
    safe(SetVehicleEngineOn, vehicle, false, true, true)
    safe(SetVehicleDoorsLocked, vehicle, 1)
    if config.damaged then damageVehicle(vehicle) end
    return vehicle
end

local function spawnPed(config, center, heading)
    local hash = loadFirstModel(config.models or {})
    if not hash then return nil end
    local pos = rotated(center, config.offset, heading)
    local z = groundZ(pos.x, pos.y, pos.z) + 0.5
    local ped = CreatePed(4, hash, pos.x, pos.y, z,
        heading + (tonumber(config.heading) or 0.0), true, true)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end

    safe(SetEntityAsMissionEntity, ped, true, true)
    safe(SetEntityInvincible, ped, false)
    safe(SetPedCanRagdoll, ped, true)
    safe(SetPedDropsWeaponsWhenDead, ped, false)
    return ped
end

local function configureVictim(ped, config, state)
    safe(SetPedFleeAttributes, ped, 0, false)
    safe(SetBlockingOfNonTemporaryEvents, ped, true)
    local deadChance = tonumber(config.dead_chance) or 0.35
    local dead = math.random() < deadChance
    if dead then
        safe(SetEntityHealth, ped, 0)
    else
        safe(SetEntityHealth, ped, 150)
        safe(TaskStartScenarioInPlace, ped, 'WORLD_HUMAN_SIT_GROUND', 0, true)
    end
    state.victim = ped
    state.victimDead = dead
    state.victimTreated = dead
end

local function configureBystander(ped, config)
    safe(SetPedFleeAttributes, ped, 0, false)
    safe(SetBlockingOfNonTemporaryEvents, ped, true)
    safe(TaskStartScenarioInPlace, ped, config.scenario or 'WORLD_HUMAN_HANDS_UP', 0, true)
end

local function configureSuspect(ped, config, state)
    local weapon = GetHashKey(config.weapon or 'WEAPON_PISTOL')
    safe(SetPedRelationshipGroupHash, ped, HOSTILE_GROUP)
    safe(SetPedAccuracy, ped, 35)
    safe(SetPedArmour, ped, tonumber(config.armour) or 30)
    safe(SetPedCombatAbility, ped, 2)
    safe(SetPedCombatMovement, ped, 2)
    safe(SetPedCombatRange, ped, 2)
    safe(SetPedFleeAttributes, ped, 0, false)
    safe(SetBlockingOfNonTemporaryEvents, ped, true)
    safe(SetPedKeepTask, ped, true)
    safe(GiveWeaponToPed, ped, weapon, 180, false, true)
    safe(SetCurrentPedWeapon, ped, weapon, true)

    local behavior = config.behavior or 'hostile'
    if behavior == 'flee_or_fight' then
        local fleeChance = tonumber(config.flee_chance) or 0.5
        behavior = (math.random() < fleeChance) and 'flee' or 'hostile'
    end
    state.suspects[#state.suspects + 1] = {
        ped = ped,
        behavior = behavior,
        lastTask = 0,
        target = nil,
    }
end

--- Build the local scene. Coordinates are the server-selected fixed spot, never
--- the player position, so the scene does not spawn on top of the responder.
local function buildScene(token, incidentId, templateId, template, coords, heading)
    if token.cancelled then return end

    local state = {
        incidentId = incidentId,
        templateId = templateId,
        template = template,
        coords = coords,
        heading = heading,
        peds = {},
        vehicles = {},
        suspects = {},
        victim = nil,
        victimDead = false,
        victimTreated = false,
        controlled = false,
        reported = false,
        reportedAt = 0,
        lastKeyAt = 0,
        awayAt = nil,
        blip = 0,
        createdAt = GetGameTimer(),
    }
    scene = state

    local sceneCfg = template.scene or {}
    for _, config in ipairs(sceneCfg.vehicles or {}) do
        local vehicle = spawnVehicle(config, coords, heading)
        if vehicle then state.vehicles[#state.vehicles + 1] = vehicle end
        if token.cancelled or scene ~= state then
            if vehicle then deleteVehicle(vehicle) end
            return
        end
    end

    for _, config in ipairs(sceneCfg.victims or {}) do
        local ped = spawnPed(config, coords, heading)
        if ped then
            state.peds[#state.peds + 1] = ped
            configureVictim(ped, config, state)
        end
        if token.cancelled or scene ~= state then
            if ped then deleteEntity(ped) end
            return
        end
    end

    for _, config in ipairs(sceneCfg.bystanders or {}) do
        local ped = spawnPed(config, coords, heading)
        if ped then
            state.peds[#state.peds + 1] = ped
            configureBystander(ped, config)
        end
        if token.cancelled or scene ~= state then
            if ped then deleteEntity(ped) end
            return
        end
    end

    for _, config in ipairs(sceneCfg.suspects or {}) do
        local ped = spawnPed(config, coords, heading)
        if ped then
            state.peds[#state.peds + 1] = ped
            configureSuspect(ped, config, state)
        end
        if token.cancelled or scene ~= state then
            if ped then deleteEntity(ped) end
            return
        end
    end

    if token.cancelled or scene ~= state then return end

    state.blip = buildBlip(coords, template.title)
    state.controlled = #state.suspects == 0 and (state.victim == nil or state.victimTreated)

    notify(('[NPC] %s #%d 已到场：%s'):format(
        tostring(template.label or template.title), incidentId, '请处置现场'), 'police')
    CreateThread(function() sceneLoop(state) end)
end

local function drawText3D(x, y, z, text)
    pcall(function()
        SetDrawOrigin(x, y, z, 0)
        SetTextFont(4)
        SetTextScale(0.35, 0.35)
        SetTextColour(255, 255, 255, 225)
        SetTextCentre(true)
        SetTextEntry('STRING')
        AddTextComponentString(text)
        DrawText(0, 0)
    end)
    pcall(ClearDrawOrigin)
end

local function updateSuspects(state, playerPed, playerCoords, now)
    for _, suspect in ipairs(state.suspects) do
        local ped = suspect.ped
        if ped and ped ~= 0 and DoesEntityExist(ped)
            and not isPedDead(ped) and not isPedRestrained(ped) then
            local distance = #(GetEntityCoords(ped) - playerCoords)
            if suspect.behavior == 'flee' then
                if distance <= 30.0 and now - (suspect.lastTask or 0) > 3000 then
                    safe(TaskSmartFleePed, ped, playerPed, 100.0, -1, false, false)
                    suspect.lastTask = now
                end
            elseif distance <= 60.0 then
                if suspect.target ~= playerPed or now - (suspect.lastTask or 0) > 5000 then
                    safe(TaskCombatPed, ped, playerPed, 0, 16)
                    suspect.target = playerPed
                    suspect.lastTask = now
                end
            end
        end
    end
end

local function suspectsNeutralised(state)
    for _, suspect in ipairs(state.suspects) do
        local ped = suspect.ped
        if ped and ped ~= 0 and DoesEntityExist(ped)
            and not isPedDead(ped) and not isPedRestrained(ped) then
            return false
        end
    end
    return true
end

local function victimHandled(state)
    if not state.victim then return true end
    if state.victimTreated then return true end
    return isPedDead(state.victim)
end

local function updateControlled(state)
    state.controlled = suspectsNeutralised(state) and victimHandled(state)
end

local function reportScene(state, playerPed)
    -- Any dead/restrained suspect means the police made an arrest; otherwise a
    -- controlled scene (or a treated traffic victim) is a normal clear.
    local outcome = 'resolved'
    if #state.suspects > 0 and suspectsNeutralised(state) then outcome = 'arrest' end

    state.reported = true
    state.reportedAt = GetGameTimer()
    TriggerServerEvent('police:server:NpcCalloutResult', state.incidentId, outcome, 'scene_controlled')
    notify(outcome == 'arrest' and '现场已控制，已上报逮捕结果' or '现场已控制，已上报处置结果', 'success')
end

local function tryTreatVictim(state, playerPed)
    local victim = state.victim
    if not victim or not DoesEntityExist(victim) or state.victimTreated then return false end
    if isPedDead(victim) then
        state.victimTreated = true
        return false
    end
    local distance = #(GetEntityCoords(playerPed) - GetEntityCoords(victim))
    if distance > TREAT_RADIUS then return false end
    state.victimTreated = true
    safe(SetEntityHealth, victim, 200)
    safe(ClearPedTasks, victim)
    safe(TaskStartScenarioInPlace, victim, 'WORLD_HUMAN_SIT_GROUND', 0, true)
    notify('伤员已完成初步救治', 'success')
    return true
end

local function handleE(state, playerPed, playerCoords, distance, now)
    if not IsControlJustReleased(0, CONTROL_E) then return end
    if now - state.lastKeyAt < REPORT_DEBOUNCE_MS then return end

    local nearVictim = state.victim and DoesEntityExist(state.victim)
        and #(playerCoords - GetEntityCoords(state.victim)) <= TREAT_RADIUS
    if nearVictim and not state.victimTreated and not isPedDead(state.victim) then
        state.lastKeyAt = now
        tryTreatVictim(state, playerPed)
        return
    end

    if not state.controlled or distance > REPORT_RADIUS then return end
    state.lastKeyAt = now
    if state.reported and now - state.reportedAt < REPORT_RETRY_MS then return end
    reportScene(state, playerPed)
end

local function promptFor(state, playerPed, playerCoords, distance, now)
    if distance > DRAW_RADIUS then return end
    local label = ('[NPC] %s #%d'):format(
        tostring(state.template and (state.template.label or state.template.title) or '警情'),
        state.incidentId)
    drawText3D(state.coords.x, state.coords.y, state.coords.z + 1.2, label .. ' · ' .. tostring(state.template.scene_label or '现场'))

    if state.victim and DoesEntityExist(state.victim) and not state.victimTreated and not isPedDead(state.victim) then
        local victimCoords = GetEntityCoords(state.victim)
        if #(playerCoords - victimCoords) <= 6.0 then
            drawText3D(victimCoords.x, victimCoords.y, victimCoords.z + 1.0, '按 E 救治伤员')
        end
    end

    if state.controlled then
        local text
        if state.reported and now - state.reportedAt < REPORT_RETRY_MS then
            text = '已上报，等待 MDT 确认…'
        elseif state.reported then
            text = '上报超时，按 E 重试'
        else
            text = '现场已控制，按 E 上报 / 回 MDT 清场'
        end
        drawText3D(state.coords.x, state.coords.y, state.coords.z + 1.6, text)
    else
        drawText3D(state.coords.x, state.coords.y, state.coords.z + 1.6, '现场未控制，请处置所有嫌疑人')
    end
end

sceneLoop = function(state)
    while scene == state do
        local playerPed = currentPlayerPed()
        if not playerPed then
            cleanupScene('player_missing')
            break
        end
        local now = GetGameTimer()
        local playerCoords = GetEntityCoords(playerPed)
        local distance = #(playerCoords - state.coords)

        if distance > LEAVE_RADIUS then
            state.awayAt = state.awayAt or now
            if now - state.awayAt >= LEAVE_GRACE_MS then
                cleanupScene('distance')
                break
            end
        else
            state.awayAt = nil
        end

        updateSuspects(state, playerPed, playerCoords, now)
        updateControlled(state)

        if state.reported and now - state.reportedAt >= REPORT_RETRY_MS then
            state.reported = false
        end

        handleE(state, playerPed, playerCoords, distance, now)
        promptFor(state, playerPed, playerCoords, distance, now)

        if distance > DRAW_RADIUS then
            Wait(500)
        else
            Wait(0)
        end
    end
end

RegisterNetEvent('police:client:NpcCallout', function(incidentId, templateId, coords)
    local id = tonumber(incidentId)
    if not id then return end
    local template = NPCCallouts and NPCCallouts.Get(templateId)
    if not template then return end

    local x = tonumber(coords and coords.x)
    local y = tonumber(coords and coords.y)
    local z = tonumber(coords and coords.z)
    if not x or not y or not z then return end
    local heading = tonumber(coords and coords.heading) or 0.0

    if scene then
        if scene.incidentId == id then return end
        cleanupScene('replaced')
    end
    if spawning then
        if spawning.incidentId == id then return end
        spawning.cancelled = true
    end

    local token = { incidentId = id, cancelled = false }
    spawning = token
    CreateThread(function()
        local ok, err = pcall(buildScene, token, id, tostring(templateId), template,
            vector3(x, y, z), heading)
        if not ok then
            print(('[custom-police] NPC callout #%d scene failed: %s'):format(id, tostring(err)))
            if scene and scene.incidentId == id then cleanupScene('build_failed') end
        end
        if spawning == token then spawning = nil end
    end)
end)

RegisterNetEvent('police:client:NpcCalloutEnd', function(incidentId)
    local id = tonumber(incidentId)
    if not id then return end
    if spawning and spawning.incidentId == id then spawning.cancelled = true end
    if scene and scene.incidentId == id then cleanupScene('server_end') end
end)

-- A resource restart must never leave custom peds or cars behind. Any pending
-- model load is cancelled as well.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if spawning then spawning.cancelled = true end
    cleanupScene('resource_stop')
end)
