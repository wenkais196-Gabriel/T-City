local QBCore = exports['qb-core']:GetCoreObject()

local spawnedGates = {}
local gateConfigs = {
    -- Main Entrance: Double massive sliding gates (prop_lrggate_02 on both left and right sides)
    {
        id = "cartel_gate_main_l",
        model = "prop_lrggate_02",
        coords = vector3(1316.67, 1106.31, 104.97),
        heading = 108.04
    },
    {
        id = "cartel_gate_main_r",
        model = "prop_lrggate_02",
        coords = vector3(1316.86, 1106.04, 104.97),
        heading = 288.62
    },
    -- Back Entrance: Double estate gates (prop_lrggate_01_l and prop_lrggate_01_r)
    {
        id = "cartel_gate_back_l",
        model = "prop_lrggate_01_l",
        coords = vector3(1313.22, 1185.69, 107.1),
        heading = 90.0
    },
    {
        id = "cartel_gate_back_r",
        model = "prop_lrggate_01_r",
        coords = vector3(1313.25, 1191.61, 107.1),
        heading = 90.0
    }
}

-- ============================================================================
--      C A R T E L   G A T E S   S P A W N E R   W I T H   S C A F F O L D I N G
-- ============================================================================

local enableDebugLogs = false
local function DebugPrint(msg)
    if enableDebugLogs then
        print(msg)
    end
end

DebugPrint("^2[Cartel Gates Debug] Spawner script loaded successfully.^0")

-- Loop to continuously hide default static gates at both entrances
CreateThread(function()
    local hideHashes = {
        GetHashKey("prop_gate_lrg_01"),
        GetHashKey("prop_gate_lrg_02"),
        GetHashKey("prop_gate_military_5a")
    }
    
    while true do
        if LocalPlayer.state.isLoggedIn then
            -- 1. Main Entrance (Hide vanilla gates)
            for _, hash in ipairs(hideHashes) do
                CreateModelHide(1315.51, 1105.38, 105.81, 10.0, hash, true)
            end
            
            -- 2. Back Entrance (Hide vanilla gates)
            for _, hash in ipairs(hideHashes) do
                CreateModelHide(1313.40, 1188.64, 106.90, 10.0, hash, true)
            end
        end
        Wait(5000) -- Refresh hide state every 5 seconds as player approaches/streams map
    end
end)

-- Spawn gates client-side when near
CreateThread(function()
    while true do
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)
        
        for _, config in ipairs(gateConfigs) do
            local distance = #(playerCoords - config.coords)
            
            if distance < 120.0 then
                if not spawnedGates[config.id] or not DoesEntityExist(spawnedGates[config.id]) then
                    DebugPrint(string.format("^3[Cartel Gates Debug] Player near %s (Distance: %.2f). Starting spawn...^0", config.id, distance))
                    
                    local hash = GetHashKey(config.model)
                    RequestModel(hash)
                    
                    -- Safety Timeout: Prevents infinite loop thread crash
                    local timeout = 0
                    local loadFailed = false
                    while not HasModelLoaded(hash) do
                        Wait(10)
                        timeout = timeout + 1
                        if timeout > 300 then -- 3 seconds timeout
                            loadFailed = true
                            break
                        end
                    end
                    
                    if loadFailed then
                        print(string.format("^1[Cartel Gates ERROR] Model '%s' failed to load for %s! Skipping to prevent crash.^0", config.model, config.id))
                        TriggerEvent('chat:addMessage', {
                            color = { 255, 0, 0 },
                            args = { "GATE ERROR", string.format("模型 %s 加载失败！请检查模型名称是否正确。", config.model) }
                        })
                    else
                        DebugPrint(string.format("^2[Cartel Gates Debug] Model loaded. Spawning object at %s...^0", tostring(config.coords)))
                        
                        -- Spawn object client-side (doorFlag = true is vital to bypass static collision blocks!)
                        local obj = CreateObject(hash, config.coords.x, config.coords.y, config.coords.z, false, false, true)
                        if DoesEntityExist(obj) then
                            SetEntityCoordsNoOffset(obj, config.coords.x, config.coords.y, config.coords.z, false, false, false) -- Snap perfectly to the exact visual height first!
                            SetEntityHeading(obj, config.heading)
                            FreezeEntityPosition(obj, true) -- Freeze physics initially on spawn to prevent falling underground
                            spawnedGates[config.id] = obj
                            
                            DebugPrint(string.format("^2[Cartel Gates Debug] Gate %s spawned successfully! Entity ID: %d^0", config.id, obj))
                        else
                            print(string.format("^1[Cartel Gates ERROR] CreateObject returned invalid entity for %s!^0", config.id))
                        end
                    end
                end
            else
                if spawnedGates[config.id] and DoesEntityExist(spawnedGates[config.id]) then
                    DebugPrint(string.format("^3[Cartel Gates Debug] Player left %s area (Distance: %.2f). Deleting gate...^0", config.id, distance))
                    DeleteObject(spawnedGates[config.id])
                    spawnedGates[config.id] = nil
                end
            end
        end
        Wait(2000)
    end
end)

-- Clean up on resource stop
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        DebugPrint("^3[Cartel Gates Debug] Cleaning up spawned gates on resource stop...^0")
        for id, obj in pairs(spawnedGates) do
            if DoesEntityExist(obj) then
                DeleteObject(obj)
            end
        end
    end
end)


-- ============================================================================
--              D E V E L O P E R   T O O L S   &   P L A C E R
-- ============================================================================

local tempGate = nil

RegisterCommand('placegate', function(source, args)
    local modelName = args[1] or "prop_lrggate_01_l"
    local playerPed = PlayerPedId()
    local coords = GetEntityCoords(playerPed)
    local heading = GetEntityHeading(playerPed)
    
    if tempGate and DoesEntityExist(tempGate) then
        DeleteObject(tempGate)
    end
    
    local hash = GetHashKey(modelName)
    RequestModel(hash)
    
    local timeout = 0
    local loadFailed = false
    while not HasModelLoaded(hash) do
        Wait(10)
        timeout = timeout + 1
        if timeout > 300 then
            loadFailed = true
            break
        end
    end
    
    if loadFailed then
        QBCore.Functions.Notify("Failed to load model: " .. modelName, "error")
        return
    end
    
    local spawnCoords = GetOffsetFromEntityInWorldCoords(playerPed, 0.0, 3.0, 0.0)
    tempGate = CreateObject(hash, spawnCoords.x, spawnCoords.y, spawnCoords.z, false, false, true)
    SetEntityHeading(tempGate, heading)
    FreezeEntityPosition(tempGate, true)
    
    QBCore.Functions.Notify("Gate spawned! Use /gateoffset [x] [y] [z] and /gateheading [val], then /gatesave.", "success")
end, false)

RegisterCommand('gateoffset', function(source, args)
    if not tempGate or not DoesEntityExist(tempGate) then
        QBCore.Functions.Notify("No active gate. Run /placegate first.", "error")
        return
    end
    
    local dx = tonumber(args[1]) or 0.0
    local dy = tonumber(args[2]) or 0.0
    local dz = tonumber(args[3]) or 0.0
    
    local coords = GetEntityCoords(tempGate)
    SetEntityCoordsNoOffset(tempGate, coords.x + dx, coords.y + dy, coords.z + dz, false, false, false)
end, false)

RegisterCommand('gateheading', function(source, args)
    if not tempGate or not DoesEntityExist(tempGate) then
        QBCore.Functions.Notify("No active gate. Run /placegate first.", "error")
        return
    end
    
    local heading = tonumber(args[1]) or 0.0
    SetEntityHeading(tempGate, heading)
end, false)

RegisterCommand('gatesave', function()
    if not tempGate or not DoesEntityExist(tempGate) then
        QBCore.Functions.Notify("No active gate to save.", "error")
        return
    end
    
    local coords = GetEntityCoords(tempGate)
    local heading = GetEntityHeading(tempGate)
    local modelHash = GetEntityModel(tempGate)
    
    local coordsStr = string.format("vector3(%.2f, %.2f, %.2f)", coords.x, coords.y, coords.z)
    print("----- GATESAVE CONFIG -----")
    print(string.format("coords = %s", coordsStr))
    print(string.format("heading = %.2f", heading))
    print(string.format("hash = %s", modelHash))
    
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 0 },
        multiline = true,
        args = { "Gate Placer", string.format("Coords: %s | Heading: %.2f | Saved to F8 console log!", coordsStr, heading) }
    })
end, false)

-- Teleport directly to Main Gate coordinates
RegisterCommand('tpgates', function()
    local playerPed = PlayerPedId()
    SetEntityCoords(playerPed, 1315.51, 1105.38, 105.81)
    SetEntityHeading(playerPed, 294.17)
    QBCore.Functions.Notify("Teleported to Main Gate coords!", "success")
end, false)

-- Dedicated testgate command to diagnose collision conflicts by spawning in mid-air
RegisterCommand('testgate', function()
    local playerPed = PlayerPedId()
    local coords = GetEntityCoords(playerPed)
    local hash = GetHashKey("prop_lrggate_02")
    RequestModel(hash)
    
    local timeout = 0
    local loadFailed = false
    while not HasModelLoaded(hash) do
        Wait(10)
        timeout = timeout + 1
        if timeout > 300 then
            loadFailed = true
            break
        end
    end
    
    if loadFailed then
        QBCore.Functions.Notify("Failed to load model: prop_lrggate_02", "error")
        return
    end
    
    local obj = CreateObject(hash, coords.x, coords.y, coords.z + 2.5, false, false, true)
    if DoesEntityExist(obj) then
        FreezeEntityPosition(obj, true)
        QBCore.Functions.Notify("Test Gate spawned successfully in mid-air! Entity: " .. obj, "success")
        
        -- Auto delete after 10 seconds
        SetTimeout(10000, function()
            if DoesEntityExist(obj) then
                DeleteObject(obj)
                QBCore.Functions.Notify("Test Gate cleaned up successfully.", "error")
            end
        end)
    else
        QBCore.Functions.Notify("Test Gate failed to spawn even in mid-air!", "error")
    end
end, false)

-- ============================================================================
--   S M A R T   A U T O M A T I C   S L I D I N G   &   S C A F F O L D I N G
-- ============================================================================

-- Set to true to use qb-doorlock's 100% native automatic sliding system.
-- Set to false to use cartel-gates' custom smooth client-side interpolation sliding system.
local UseNativeSliding = false

local isMainGateLocked = true
local isBackGateLocked = true
local currentProgress = 0.0 -- 0.0 (fully closed) to 1.0 (fully open)
local gateDebugActive = false

-- Test Sliding Animation Command for Double Gates
local gateOffsets = {
    cartel_gate_main_l = { dir = vector3(-0.31, 0.95, 0.0), dist = 5.0 },
    cartel_gate_main_r = { dir = vector3(0.32, -0.95, 0.0), dist = 5.0 }
}

RegisterCommand('testslide', function()
    if not spawnedGates["cartel_gate_main_l"] or not DoesEntityExist(spawnedGates["cartel_gate_main_l"]) then
        QBCore.Functions.Notify("Main gates not spawned yet. Please get closer to the entrance.", "error")
        return
    end

    QBCore.Functions.Notify("Starting smooth double-sliding opening animation...", "success")
    
    CreateThread(function()
        -- 1. Slide open (smooth interpolation)
        for i = 1, 100 do
            local progress = i / 100
            for id, entity in pairs(spawnedGates) do
                local offsetData = gateOffsets[id]
                if offsetData and DoesEntityExist(entity) then
                    local baseCoords = nil
                    for _, cfg in ipairs(gateConfigs) do
                        if cfg.id == id then baseCoords = cfg.coords end
                    end
                    if baseCoords then
                        local currentOffset = offsetData.dir * (offsetData.dist * progress)
                        SetEntityCoordsNoOffset(entity, baseCoords.x + currentOffset.x, baseCoords.y + currentOffset.y, baseCoords.z, false, false, false)
                    end
                end
            end
            Wait(15) -- 1.5 seconds total opening animation
        end
        
        QBCore.Functions.Notify("Gates fully open! Waiting 5 seconds before closing...", "success")
        Wait(5000)
        
        QBCore.Functions.Notify("Starting smooth double-sliding closing animation...", "success")
        
        -- 2. Slide closed (smooth interpolation)
        for i = 100, 1, -1 do
            local progress = i / 100
            for id, entity in pairs(spawnedGates) do
                local offsetData = gateOffsets[id]
                if offsetData and DoesEntityExist(entity) then
                    local baseCoords = nil
                    for _, cfg in ipairs(gateConfigs) do
                        if cfg.id == id then baseCoords = cfg.coords end
                    end
                    if baseCoords then
                        local currentOffset = offsetData.dir * (offsetData.dist * progress)
                        SetEntityCoordsNoOffset(entity, baseCoords.x + currentOffset.x, baseCoords.y + currentOffset.y, baseCoords.z, false, false, false)
                    end
                end
            end
            Wait(15) -- 1.5 seconds total closing animation
        end
        
        QBCore.Functions.Notify("Gates fully closed and locked!", "error")
    end)
end, false)

-- Helper to draw 3D debug info
local function Draw3DText(coords, str)
    local onScreen, worldX, worldY = World3dToScreen2d(coords.x, coords.y, coords.z)
    if onScreen then
        SetTextScale(0.35, 0.35)
        SetTextFont(4)
        SetTextProportional(1)
        SetTextColour(255, 255, 255, 215)
        SetTextEntry("STRING")
        SetTextCentre(1)
        AddTextComponentString(str)
        DrawText(worldX, worldY)
        local factor = (string.len(str)) / 370
        DrawRect(worldX, worldY + 0.0125, 0.015 + factor, 0.03, 0, 0, 0, 100)
    end
end

-- Command to toggle real-time 3D debug scaffolding
RegisterCommand('gatedebug', function()
    gateDebugActive = not gateDebugActive
    QBCore.Functions.Notify("Gate debugging is now " .. (gateDebugActive and "ENABLED" or "DISABLED"), "success")
end, false)

-- Thread to draw 3D debug scaffolding
CreateThread(function()
    local mainCenter = vector3(1316.76, 1106.17, 105.86)
    local backCenter = vector3(1313.23, 1188.65, 107.10)
    
    while true do
        if gateDebugActive then
            local playerPed = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)
            
            -- 1. Main Gate Debug Display
            local distMain = #(playerCoords - mainCenter)
            if distMain < 40.0 then
                local targetOpen = (not isMainGateLocked and distMain < 12.0)
                local debugTextMain = string.format(
                    "=== CARTEL MAIN GATES SCAFFOLDING ===\nLock State (from qb-doorlock): %s\nProximity Distance: %.2f meters (Limit: 12.0m)\nGate Spawner Created: %s\nAnimation Progress: %.1f%%\nShould Be Open: %s",
                    isMainGateLocked and "LOCKED (No Proximity)" or "UNLOCKED (Auto Proximity)",
                    distMain,
                    (spawnedGates["cartel_gate_main_l"] ~= nil) and "YES" or "NO",
                    currentProgress * 100,
                    targetOpen and "YES" or "NO"
                )
                Draw3DText(mainCenter + vector3(0.0, 0.0, 1.0), debugTextMain)
            end
            
            -- 2. Back Gate Debug Display (Gate 1)
            local distBack = #(playerCoords - backCenter)
            if distBack < 40.0 then
                local lEnt = spawnedGates["cartel_gate_back_l"]
                local rEnt = spawnedGates["cartel_gate_back_r"]
                
                local lExist = (lEnt ~= nil and DoesEntityExist(lEnt))
                local rExist = (rEnt ~= nil and DoesEntityExist(rEnt))
                
                local lFrozen = lExist and IsEntityPositionFrozen(lEnt) or false
                local rFrozen = rExist and IsEntityPositionFrozen(rEnt) or false
                
                local lHeading = lExist and GetEntityHeading(lEnt) or 0.0
                local rHeading = rExist and GetEntityHeading(rEnt) or 0.0
                
                local debugTextBack = string.format(
                    "=== CARTEL BACK GATES (GATE 1) SCAFFOLDING ===\n" ..
                    "Lock State (from qb-doorlock): %s\n" ..
                    "Proximity Distance: %.2f meters\n\n" ..
                    "[LEFT GATE - South Side]\n" ..
                    "Entity Exist: %s (ID: %s) | Frozen: %s\n" ..
                    "Current Heading: %.2f | Open Ratio: %.2f\n\n" ..
                    "[RIGHT GATE - North Side]\n" ..
                    "Entity Exist: %s (ID: %s) | Frozen: %s\n" ..
                    "Current Heading: %.2f | Open Ratio: %.2f",
                    isBackGateLocked and "LOCKED" or "UNLOCKED",
                    distBack,
                    lExist and "YES" or "NO", tostring(lEnt), lFrozen and "YES" or "NO",
                    lHeading, backProgress,
                    rExist and "YES" or "NO", tostring(rEnt), rFrozen and "YES" or "NO",
                    rHeading, backProgress
                )
                Draw3DText(backCenter + vector3(0.0, 0.0, 1.2), debugTextBack)
            end
            
            Wait(0)
        else
            Wait(1000)
        end
    end
end)

-- Synchronize with qb-doorlock states in real-time
RegisterNetEvent('qb-doorlock:client:setState', function(serverId, doorID, state)
    if doorID == "cartel_gate_main" then
        isMainGateLocked = state
        DebugPrint(string.format("^3[Cartel Gates Debug] Gate main lock state synchronized: %s^0", tostring(state)))
    elseif doorID == "cartel_gate_back" then
        isBackGateLocked = state
        DebugPrint(string.format("^3[Cartel Gates Debug] Gate back lock state synchronized: %s^0", tostring(state)))
    end
end)

-- Fetch initial lock states on script start
CreateThread(function()
    while not QBCore do Wait(100) end
    Wait(2000)
    QBCore.Functions.TriggerCallback('qb-doorlock:server:setupDoors', function(doorList)
        if doorList then
            if doorList["cartel_gate_main"] then
                isMainGateLocked = doorList["cartel_gate_main"].locked
                DebugPrint(string.format("^3[Cartel Gates Debug] Initial gate main lock state fetched: %s^0", tostring(isMainGateLocked)))
            end
            if doorList["cartel_gate_back"] then
                isBackGateLocked = doorList["cartel_gate_back"].locked
                DebugPrint(string.format("^3[Cartel Gates Debug] Initial gate back lock state fetched: %s^0", tostring(isBackGateLocked)))
            end
        end
    end)
end)

-- Smart Automatic Proximity Sliding Thread (Runs locally for every client)
CreateThread(function()
    local centerCoords = vector3(1316.76, 1106.17, 105.86)
    
    while true do
        if UseNativeSliding then
            Wait(1000) -- Bypass and yield to qb-doorlock's native automatic sliding
        else
            local playerPed = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)
            local dx = playerCoords.x - centerCoords.x
            local dy = playerCoords.y - centerCoords.y
            local dz = playerCoords.z - centerCoords.z
            local distSq = dx*dx + dy*dy + dz*dz
            
            -- The gates open automatically only if the gate is unlocked in qb-doorlock AND player is close (12.0^2 = 144.0)
            local targetOpen = false
            if not isMainGateLocked and distSq < 144.0 then
                targetOpen = true
            end
            
            local changed = false
            if targetOpen and currentProgress < 1.0 then
                currentProgress = math.min(1.0, currentProgress + 0.015) -- Smooth open increment
                changed = true
            elseif not targetOpen and currentProgress > 0.0 then
                currentProgress = math.max(0.0, currentProgress - 0.015) -- Smooth close decrement
                changed = true
            end
            
            if changed then
                for id, entity in pairs(spawnedGates) do
                    local offsetData = gateOffsets[id]
                    if offsetData and DoesEntityExist(entity) then
                        local baseCoords = nil
                        for _, cfg in ipairs(gateConfigs) do
                            if cfg.id == id then baseCoords = cfg.coords end
                        end
                        if baseCoords then
                            local currentOffset = offsetData.dir * (offsetData.dist * currentProgress)
                            SetEntityCoordsNoOffset(entity, baseCoords.x + currentOffset.x, baseCoords.y + currentOffset.y, baseCoords.z, false, false, false)
                        end
                    end
                end
            end
            
            -- High frequency loop (50 FPS) when animating, otherwise low frequency scanning to conserve CPU resources
            if changed then
                Wait(20)
            else
                Wait(250)
            end
        end
    end
end)

-- Smart Automatic Proximity Swinging Thread for Back Gates (Gate 1)
local backProgress = 0.0 -- 0.0 (fully closed) to 1.0 (fully open)
CreateThread(function()
    local centerCoords = vector3(1313.23, 1188.65, 107.10)
    
    while true do
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)
        local dx = playerCoords.x - centerCoords.x
        local dy = playerCoords.y - centerCoords.y
        local dz = playerCoords.z - centerCoords.z
        local distSq = dx*dx + dy*dy + dz*dz
        
        -- 当解锁且玩家靠近 12 米内时，自动摆开 (12.0^2 = 144.0)
        local targetOpen = false
        if not isBackGateLocked and distSq < 144.0 then
            targetOpen = true
        end
        
        local changed = false
        if targetOpen and backProgress < 1.0 then
            backProgress = math.min(1.0, backProgress + 0.02) -- 渐进平滑开启 (大约 0.75秒)
            changed = true
        elseif not targetOpen and backProgress > 0.0 then
            backProgress = math.max(0.0, backProgress - 0.02) -- 渐进平滑闭合
            changed = true
        end
        
        if changed or (backProgress > 0.0 and backProgress < 1.0) then
            -- 1. 获取两扇门的客户端实体
            local leftGate = spawnedGates["cartel_gate_back_l"]
            local rightGate = spawnedGates["cartel_gate_back_r"]
            
            -- 2. 对称旋转摆动 (左门偏航 Heading 变大，右门偏航 Heading 变小)
            if leftGate and DoesEntityExist(leftGate) then
                SetEntityHeading(leftGate, 90.0 + (90.0 * backProgress))
            end
            if rightGate and DoesEntityExist(rightGate) then
                SetEntityHeading(rightGate, 90.0 - (90.0 * backProgress))
            end
        else
            -- 确保完全静止时 Heading 精准对齐
            if not targetOpen and backProgress == 0.0 then
                local leftGate = spawnedGates["cartel_gate_back_l"]
                local rightGate = spawnedGates["cartel_gate_back_r"]
                if leftGate and DoesEntityExist(leftGate) then SetEntityHeading(leftGate, 90.0) end
                if rightGate and DoesEntityExist(rightGate) then SetEntityHeading(rightGate, 90.0) end
            elseif targetOpen and backProgress == 1.0 then
                local leftGate = spawnedGates["cartel_gate_back_l"]
                local rightGate = spawnedGates["cartel_gate_back_r"]
                if leftGate and DoesEntityExist(leftGate) then SetEntityHeading(leftGate, 180.0) end
                if rightGate and DoesEntityExist(rightGate) then SetEntityHeading(rightGate, 0.0) end
            end
        end
        
        if changed then
            Wait(16) -- 高频流畅动画 (60 FPS)
        else
            Wait(250) -- 低频休眠监听，降低性能消耗
        end
    end
end)
