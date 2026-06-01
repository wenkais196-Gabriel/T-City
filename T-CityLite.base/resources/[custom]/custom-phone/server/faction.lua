local QBCore = exports['qb-core']:GetCoreObject()

-- Global in-memory faction messages table
local FactionMessages = {
    police = {},
    medic = {},
    gang = {},
    civilian = {}
}
GlobalState.FactionMessages = FactionMessages

-- Helper to broadcast to specific career role
local function BroadcastToFaction(role, msgData)
    -- Append to in-memory history
    if not FactionMessages[role] then FactionMessages[role] = {} end
    table.insert(FactionMessages[role], msgData)
    if #FactionMessages[role] > 50 then
        table.remove(FactionMessages[role], 1) -- Keep last 50
    end
    GlobalState.FactionMessages = FactionMessages

    -- Send event to all online members with this role
    for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
        local identity = exports['custom-career']:GetPlayerIdentity(playerId)
        if identity and identity.primary_role == role then
            TriggerClientEvent('phone:client:factionReceive', playerId, msgData)
        end
    end
end

-- 1. General faction message send callback
QBCore.Functions.CreateCallback('phone:server:sendFactionMessage', function(source, cb, content)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, message = 'Invalid player' }) end

    -- Input validation (Security Hardening)
    if not content or #content == 0 or #content > 200 then
        return cb({ success = false, message = 'Message must be between 1 and 200 characters' })
    end

    local identity = exports['custom-career']:GetPlayerIdentity(source)
    if not identity then return cb({ success = false, message = 'Career identity not found' }) end

    local role = identity.primary_role
    local name = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname

    local msgData = {
        sender = name,
        content = content,
        time = os.time()
    }

    BroadcastToFaction(role, msgData)
    cb({ success = true, message = msgData })
end)

-- 2. Sheriff tactical order broadcast (SheriffApp)
QBCore.Functions.CreateCallback('phone:server:sendSheriffPatrol', function(source, cb, zone, details)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, message = 'Invalid player' }) end

    -- Input validation (Security Hardening)
    if not details or #details == 0 or #details > 500 then
        return cb({ success = false, message = 'Patrol instructions must be between 1 and 500 characters' })
    end

    local identity = exports['custom-career']:GetPlayerIdentity(source)
    if not identity or identity.rank_tier ~= 'leader' or identity.primary_role ~= 'police' then
        return cb({ success = false, message = 'Unauthorized clearance' })
    end

    local name = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname
    local msgContent = ("🚨 [PATROL ORDER] Active patrol ordered in %s: %s"):format(zone, details)

    local msgData = {
        sender = name .. " (Tactical Command)",
        content = msgContent,
        time = os.time()
    }

    -- 1. Broadcast to LSPD Radio
    BroadcastToFaction('police', msgData)

    -- 2. Push GPS waypoint coordinates based on zone to all online LSPD units
    local coords = vector3(428.2, -984.2, 30.7) -- Default Mission Row
    if zone == "Vinewood Hills" then
        coords = vector3(-399.7, 72.8, 86.8)
    elseif zone == "Sandy Shores" then
        coords = vector3(1851.6, 3687.2, 34.2)
    elseif zone == "Paleto Bay" then
        coords = vector3(-441.5, 6013.2, 31.7)
    end

    for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
        local unit = exports['custom-career']:GetPlayerIdentity(playerId)
        if unit and unit.primary_role == 'police' then
            TriggerClientEvent('phone:client:routeGps', playerId, coords, "Patrol Sector: " .. zone)
            TriggerClientEvent('phone:client:newNotification', playerId, {
                id = math.random(1000, 9999),
                title = "🚨 Tactical Waypoint",
                content = "Patrol coordinates dispatched by Sheriff: Sector " .. zone,
                timestamp = os.date('%Y-%m-%d %H:%M:%S'),
                is_read = false
            })
        end
    end

    cb({ success = true, message = msgData })
end)

-- 3. Gang godfather secure objective broadcast (GangBossApp)
QBCore.Functions.CreateCallback('phone:server:sendGangObjective', function(source, cb, objective, quota)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({ success = false, message = 'Invalid player' }) end

    -- Input validation (Security Hardening)
    if not objective or #objective == 0 or #objective > 500 then
        return cb({ success = false, message = 'Gang directive must be between 1 and 500 characters' })
    end

    local identity = exports['custom-career']:GetPlayerIdentity(source)
    if not identity or identity.rank_tier ~= 'leader' or identity.primary_role ~= 'gang' then
        return cb({ success = false, message = 'Unauthorized clearance' })
    end

    local name = Player.PlayerData.charinfo.firstname .. " " .. Player.PlayerData.charinfo.lastname
    quota = tonumber(quota) or 0

    local msgContent = ("👁️ [OBJECTIVE DISPATCH] %s%s"):format(
        objective,
        quota > 0 and (" (Cash Quota Target: $%d)"):format(quota) or ""
    )

    local msgData = {
        sender = name .. " (Godfather)",
        content = msgContent,
        time = os.time()
    }

    BroadcastToFaction('gang', msgData)
    cb({ success = true, message = msgData })
end)
