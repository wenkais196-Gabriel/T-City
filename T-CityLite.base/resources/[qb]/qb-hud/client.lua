local QBCore = exports['qb-core']:GetCoreObject()
local PlayerData = QBCore.Functions.GetPlayerData()
local config = Config
local speedMultiplier = config.UseMPH and 2.23694 or 3.6
local seatbeltOn = false
local cruiseOn = false
local showAltitude = false
local showSeatbelt = false
local nos = 0
local stress = 0
local hunger = 100
local thirst = 100
local cashAmount = 0
local bankAmount = 0
local nitroActive = 0
local harness = 0
local hp = 100
local armed = 0
local parachute = -1
local oxygen = 100
local dev = false
local playerDead = false
local showMenu = false
local showCircleB = false
local showSquareB = false
local Menu = config.Menu
local CinematicHeight = 0.2
local w = 0
local radioActive = false

-- Debug: /rings command to force all status rings visible for testing
local debugShowAllRings = false

-- Waypoint distance tracking
local waypointActive = false
local waypointDistance = 0
local customTarget = nil -- {x, y, z, label} for future task integration

DisplayRadar(false)

local function CinematicShow(bool)
    SetBigmapActive(true, false)
    Wait(0)
    SetBigmapActive(false, false)
    if bool then
        for i = CinematicHeight, 0, -1.0 do
            Wait(10)
            w = i
        end
    else
        for i = 0, CinematicHeight, 1.0 do
            Wait(10)
            w = i
        end
    end
end

local function loadSettings(settings)
    for k, v in pairs(settings) do
        if k == 'isToggleMapShapeChecked' then
            Menu.isToggleMapShapeChecked = v
            SendNUIMessage({ test = true, event = k, toggle = v })
        elseif k == 'isCinematicModeChecked' then
            Menu.isCinematicModeChecked = v
            CinematicShow(v)
            SendNUIMessage({ test = true, event = k, toggle = v })
        elseif k == 'isChangeFPSChecked' then
            Menu[k] = v
            local val = v and 'Optimized' or 'Synced'
            SendNUIMessage({ test = true, event = k, toggle = val })
        else
            Menu[k] = v
            SendNUIMessage({ test = true, event = k, toggle = v })
        end
    end
    QBCore.Functions.Notify(Lang:t('notify.hud_settings_loaded'), 'success')
    Wait(1000)
    TriggerEvent('hud:client:LoadMap')
end

local function saveSettings()
    SetResourceKvp('hudSettings', json.encode(Menu))
end

-- Check if minimap/radar should be visible (mirrors DisplayRadar logic exactly)
local function isRadarVisible()
    if Menu.isHideMapChecked then return false end
    if Menu.isCinematicModeChecked then return false end
    if IsPauseMenuActive() then return false end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped) and not IsThisModelABicycle(GetVehiclePedIsIn(ped)) then
        return true
    end
    return Menu.isOutMapChecked
end

local function hasHarness(items)
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return end

    local _harness = false
    if items then
        for _, v in pairs(items) do
            if v.name == 'harness' then
                _harness = true
            end
        end
    end

    harness = _harness
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    Wait(2000)
    local hudSettings = GetResourceKvpString('hudSettings')
    if hudSettings then loadSettings(json.decode(hudSettings)) end
    PlayerData = QBCore.Functions.GetPlayerData()
    -- 从服务端数据恢复本地压力/饥饿/口渴值 (修复登录后显示为 0 的问题)
    if PlayerData.metadata then
        stress = PlayerData.metadata.stress or 0
        hunger = PlayerData.metadata.hunger or 100
        thirst = PlayerData.metadata.thirst or 100
    end
    Wait(3000)
    SetEntityHealth(PlayerPedId(), 200)
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    PlayerData = {}
end)

RegisterNetEvent('QBCore:Player:SetPlayerData', function(val)
    PlayerData = val
end)

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    Wait(2000)
    local hudSettings = GetResourceKvpString('hudSettings')
    if hudSettings then loadSettings(json.decode(hudSettings)) end
end)

AddEventHandler('pma-voice:radioActive', function(data)
    radioActive = data
end)

-- Callbacks & Events
RegisterCommand('menu', function()
    Wait(50)
    if showMenu then return end
    TriggerEvent('hud:client:playOpenMenuSounds')
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open' })
    showMenu = true
end)

RegisterNUICallback('closeMenu', function(_, cb)
    Wait(50)
    TriggerEvent('hud:client:playCloseMenuSounds')
    showMenu = false
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterKeyMapping('menu', 'Open Menu', 'keyboard', config.OpenMenu)

-- Reset hud
local function restartHud()
    TriggerEvent('hud:client:playResetHudSounds')
    QBCore.Functions.Notify(Lang:t('notify.hud_restart'), 'error')
    if IsPedInAnyVehicle(PlayerPedId()) then
        Wait(2600)
        SendNUIMessage({ action = 'car', show = false })
        SendNUIMessage({ action = 'car', show = true })
    end
    Wait(2600)
    SendNUIMessage({ action = 'hudtick', show = false })
    SendNUIMessage({ action = 'hudtick', show = true })
    Wait(2600)
    QBCore.Functions.Notify(Lang:t('notify.hud_start'), 'success')
end

RegisterNUICallback('restartHud', function(_, cb)
    Wait(50)
    restartHud()
    cb('ok')
end)

RegisterCommand('resethud', function()
    Wait(50)
    restartHud()
end)

RegisterCommand('rings', function()
    debugShowAllRings = not debugShowAllRings
    if debugShowAllRings then
        QBCore.Functions.Notify('🔍 Rings Debug: ALL rings forced visible', 'success')
    else
        QBCore.Functions.Notify('🔍 Rings Debug: back to normal', 'error')
    end
end)

RegisterNUICallback('resetStorage', function(_, cb)
    Wait(50)
    TriggerEvent('hud:client:resetStorage')
    cb('ok')
end)

RegisterNetEvent('hud:client:resetStorage', function()
    Wait(50)
    if Menu.isResetSoundsChecked then
        TriggerServerEvent('InteractSound_SV:PlayOnSource', 'airwrench', 0.1)
    end
    QBCore.Functions.TriggerCallback('hud:server:getMenu', function(menu)
        loadSettings(menu); SetResourceKvp('hudSettings', json.encode(menu))
    end)
end)

-- Notifications
RegisterNUICallback('openMenuSounds', function(_, cb)
    Wait(50)
    Menu.isOpenMenuSoundsChecked = not Menu.isOpenMenuSoundsChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNetEvent('hud:client:playOpenMenuSounds', function()
    Wait(50)
    if not Menu.isOpenMenuSoundsChecked then return end
    TriggerServerEvent('InteractSound_SV:PlayOnSource', 'monkeyopening', 0.5)
end)

RegisterNetEvent('hud:client:playCloseMenuSounds', function()
    Wait(50)
    if not Menu.isOpenMenuSoundsChecked then return end
    TriggerServerEvent('InteractSound_SV:PlayOnSource', 'catclosing', 0.05)
end)

RegisterNUICallback('resetHudSounds', function(_, cb)
    Wait(50)
    Menu.isResetSoundsChecked = not Menu.isResetSoundsChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNetEvent('hud:client:playResetHudSounds', function()
    Wait(50)
    if not Menu.isResetSoundsChecked then return end
    TriggerServerEvent('InteractSound_SV:PlayOnSource', 'airwrench', 0.1)
end)

RegisterNUICallback('checklistSounds', function(_, cb)
    Wait(50)
    TriggerEvent('hud:client:checklistSounds')
    cb('ok')
end)

RegisterNetEvent('hud:client:checklistSounds', function()
    Wait(50)
    Menu.isListSoundsChecked = not Menu.isListSoundsChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
end)

RegisterNetEvent('hud:client:playHudChecklistSound', function()
    Wait(50)
    if not Menu.isListSoundsChecked then return end
    TriggerServerEvent('InteractSound_SV:PlayOnSource', 'shiftyclick', 0.5)
end)

RegisterNUICallback('showOutMap', function(_, cb)
    Wait(50)
    Menu.isOutMapChecked = not Menu.isOutMapChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('showOutCompass', function(_, cb)
    Wait(50)
    Menu.isOutCompassChecked = not Menu.isOutCompassChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('showFollowCompass', function(_, cb)
    Wait(50)
    Menu.isCompassFollowChecked = not Menu.isCompassFollowChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('showMapNotif', function(_, cb)
    Wait(50)
    Menu.isMapNotifChecked = not Menu.isMapNotifChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('showFuelAlert', function(_, cb)
    Wait(50)
    Menu.isLowFuelChecked = not Menu.isLowFuelChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('showCinematicNotif', function(_, cb)
    Wait(50)
    Menu.isCinematicNotifChecked = not Menu.isCinematicNotifChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

-- Status
RegisterNUICallback('dynamicHealth', function(_, cb)
    Wait(50)
    TriggerEvent('hud:client:ToggleHealth')
    cb('ok')
end)

RegisterNetEvent('hud:client:ToggleHealth', function()
    Wait(50)
    Menu.isDynamicHealthChecked = not Menu.isDynamicHealthChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
end)

RegisterNUICallback('dynamicArmor', function(_, cb)
    Wait(50)
    Menu.isDynamicArmorChecked = not Menu.isDynamicArmorChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('dynamicHunger', function(_, cb)
    Wait(50)
    Menu.isDynamicHungerChecked = not Menu.isDynamicHungerChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('dynamicThirst', function(_, cb)
    Wait(50)
    Menu.isDynamicThirstChecked = not Menu.isDynamicThirstChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('dynamicStress', function(_, cb)
    Wait(50)
    Menu.isDynamicStressChecked = not Menu.isDynamicStressChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('dynamicOxygen', function(_, cb)
    Wait(50)
    Menu.isDynamicOxygenChecked = not Menu.isDynamicOxygenChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

-- Vehicle
RegisterNUICallback('changeFPS', function(_, cb)
    Wait(50)
    Menu.isChangeFPSChecked = not Menu.isChangeFPSChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('HideMap', function(_, cb)
    Wait(50)
    Menu.isHideMapChecked = not Menu.isHideMapChecked
    DisplayRadar(not Menu.isHideMapChecked)
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNetEvent('hud:client:LoadMap', function()
    Wait(50)
    -- Credit to Dalrae for the solve.
    local defaultAspectRatio = 1920 / 1080 -- Don't change this.
    local resolutionX, resolutionY = GetActiveScreenResolution()
    local aspectRatio = resolutionX / resolutionY
    local minimapOffset = 0
    if aspectRatio > defaultAspectRatio then
        minimapOffset = ((defaultAspectRatio - aspectRatio) / 3.6) - 0.008
    end
    if Menu.isToggleMapShapeChecked == 'square' then
        RequestStreamedTextureDict('squaremap', false)
        if not HasStreamedTextureDictLoaded('squaremap') then
            Wait(150)
        end
        if Menu.isMapNotifChecked then
            QBCore.Functions.Notify(Lang:t('notify.load_square_map'))
        end
        SetMinimapClipType(0)
        AddReplaceTexture('platform:/textures/graphics', 'radarmasksm', 'squaremap', 'radarmasksm')
        AddReplaceTexture('platform:/textures/graphics', 'radarmask1g', 'squaremap', 'radarmasksm')
        -- 87.5% scale minimap (square)
        SetMinimapComponentPosition('minimap', 'L', 'B', 0.0 + minimapOffset, -0.047, 0.1433, 0.1601)

        -- mask 完全匹配 blur (同位置同尺寸)
        SetMinimapComponentPosition('minimap_mask', 'L', 'B', -0.01 + minimapOffset, 0.025, 0.2293, 0.2625)

        SetMinimapComponentPosition('minimap_blur', 'L', 'B', -0.01 + minimapOffset, 0.025, 0.2293, 0.2625)
        SetBlipAlpha(GetNorthRadarBlip(), 0)
        SetBigmapActive(true, false)
        SetMinimapClipType(0)
        Wait(50)
        SetBigmapActive(false, false)
        if Menu.isToggleMapBordersChecked then
            showCircleB = false
            showSquareB = true
        end
        Wait(1200)
        if Menu.isMapNotifChecked then
            QBCore.Functions.Notify(Lang:t('notify.loaded_square_map'))
        end
    elseif Menu.isToggleMapShapeChecked == 'circle' then
        RequestStreamedTextureDict('circlemap', false)
        if not HasStreamedTextureDictLoaded('circlemap') then
            Wait(150)
        end
        if Menu.isMapNotifChecked then
            QBCore.Functions.Notify(Lang:t('notify.load_circle_map'))
        end
        SetMinimapClipType(1)
        AddReplaceTexture('platform:/textures/graphics', 'radarmasksm', 'circlemap', 'radarmasksm')
        AddReplaceTexture('platform:/textures/graphics', 'radarmask1g', 'circlemap', 'radarmasksm')
        -- 87.5% scale minimap (circle)
        SetMinimapComponentPosition('minimap', 'L', 'B', -0.0100 + minimapOffset, -0.030, 0.1575, 0.2258)

        -- icons within map
        SetMinimapComponentPosition('minimap_mask', 'L', 'B', 0.200 + minimapOffset, 0.0, 0.0569, 0.175)

        SetMinimapComponentPosition('minimap_blur', 'L', 'B', -0.00 + minimapOffset, 0.015, 0.2205, 0.2958)
        SetBlipAlpha(GetNorthRadarBlip(), 0)
        SetMinimapClipType(1)
        SetBigmapActive(true, false)
        Wait(50)
        SetBigmapActive(false, false)
        if Menu.isToggleMapBordersChecked then
            showSquareB = false
            showCircleB = true
        end
        Wait(1200)
        if Menu.isMapNotifChecked then
            QBCore.Functions.Notify(Lang:t('notify.loaded_circle_map'))
        end
    end
end)

RegisterNUICallback('ToggleMapShape', function(_, cb)
    Wait(50)
    if not Menu.isHideMapChecked then
        Menu.isToggleMapShapeChecked = Menu.isToggleMapShapeChecked == 'circle' and 'square' or 'circle'
        Wait(50)
        TriggerEvent('hud:client:LoadMap')
    end
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('ToggleMapBorders', function(_, cb)
    Wait(50)
    Menu.isToggleMapBordersChecked = not Menu.isToggleMapBordersChecked
    if Menu.isToggleMapBordersChecked then
        if Menu.isToggleMapShapeChecked == 'square' then
            showSquareB = true
        else
            showCircleB = true
        end
    else
        showSquareB = false
        showCircleB = false
    end
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('dynamicEngine', function(_, cb)
    Wait(50)
    Menu.isDynamicEngineChecked = not Menu.isDynamicEngineChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('dynamicNitro', function(_, cb)
    Wait(50)
    Menu.isDynamicNitroChecked = not Menu.isDynamicNitroChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

-- Compass
RegisterNUICallback('showCompassBase', function(_, cb)
    Wait(50)
    Menu.isCompassShowChecked = not Menu.isCompassShowChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('showStreetsNames', function(_, cb)
    Wait(50)
    Menu.isShowStreetsChecked = not Menu.isShowStreetsChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('showPointerIndex', function(_, cb)
    Wait(50)
    Menu.isPointerShowChecked = not Menu.isPointerShowChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('showDegreesNum', function(_, cb)
    Wait(50)
    Menu.isDegreesShowChecked = not Menu.isDegreesShowChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('changeCompassFPS', function(_, cb)
    Wait(50)
    Menu.isChangeCompassFPSChecked = not Menu.isChangeCompassFPSChecked
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNUICallback('cinematicMode', function(_, cb)
    Wait(50)
    if Menu.isCinematicModeChecked then
        CinematicShow(false)
        Menu.isCinematicModeChecked = false
        if Menu.isCinematicNotifChecked then
            QBCore.Functions.Notify(Lang:t('notify.cinematic_off'), 'error')
        end
        DisplayRadar(1)
    else
        CinematicShow(true)
        Menu.isCinematicModeChecked = true
        if Menu.isCinematicNotifChecked then
            QBCore.Functions.Notify(Lang:t('notify.cinematic_on'))
        end
    end
    TriggerEvent('hud:client:playHudChecklistSound')
    saveSettings()
    cb('ok')
end)

RegisterNetEvent('hud:client:ToggleAirHud', function()
    showAltitude = not showAltitude
end)

RegisterNetEvent('hud:client:UpdateNeeds', function(newHunger, newThirst) -- Triggered in qb-core
    hunger = newHunger
    thirst = newThirst
end)

RegisterNetEvent('hud:client:UpdateStress', function(newStress) -- Add this event with adding stress elsewhere
    stress = newStress
end)

RegisterNetEvent('hud:client:ToggleShowSeatbelt', function()
    showSeatbelt = not showSeatbelt
end)

RegisterNetEvent('seatbelt:client:ToggleSeatbelt', function(state) -- Triggered in smallresources
    seatbeltOn = state
end)

RegisterNetEvent('seatbelt:client:ToggleCruise', function() -- Triggered in smallresources
    cruiseOn = not cruiseOn
end)

RegisterNetEvent('hud:client:UpdateNitrous', function(nitroLevel, bool)
    nos = nitroLevel
    nitroActive = bool
end)

RegisterNetEvent('hud:client:UpdateHarness', function(harnessHp)
    hp = harnessHp
end)

RegisterNetEvent('qb-admin:client:ToggleDevmode', function()
    dev = not dev
end)

local prevPlayerStats = { nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil }

local function debugOverrideRings(data)
    if not debugShowAllRings then return data end
    -- Force ALL dynamic visibility flags to false → rings always show
    data[2] = false  -- dynamicHealth
    data[3] = false  -- dynamicArmor
    data[4] = false  -- dynamicHunger
    data[5] = false  -- dynamicThirst
    data[6] = false  -- dynamicStress
    data[7] = false  -- dynamicOxygen
    data[8] = false  -- dynamicEngine
    data[9] = false  -- dynamicNitro
    -- Force game-state values to non-extreme so rings are visible
    data[10] = math.min(data[10], 75)   -- health: force < 100
    data[12] = math.max(data[12], 40)   -- armor: force > 0
    data[13] = math.min(data[13], 80)   -- thirst: force < 100
    data[14] = math.min(data[14], 80)   -- hunger: force < 100
    data[15] = math.max(data[15], 25)   -- stress: force > 0
    data[19] = true                     -- armed
    data[20] = math.min(data[20], 85)   -- oxygen: force < 100
    data[21] = math.max(data[21], 0)    -- parachute: force >= 0
    data[22] = math.max(data[22], 40)   -- nos: force > 0
    data[23] = true                     -- cruise
    data[25] = true                     -- harness
    data[28] = math.max(data[28], 50)   -- engine: force in visible range
    data[30] = true                     -- dev
    return data
end

local function updatePlayerHud(data)
    data = debugOverrideRings(data)
    local shouldUpdate = false
    for k, v in pairs(data) do
        if prevPlayerStats[k] ~= v then
            shouldUpdate = true
            break
        end
    end
    prevPlayerStats = data
    if shouldUpdate then
        SendNUIMessage({
            action = 'hudtick',
            show = data[1],
            dynamicHealth = data[2],
            dynamicArmor = data[3],
            dynamicHunger = data[4],
            dynamicThirst = data[5],
            dynamicStress = data[6],
            dynamicOxygen = data[7],
            dynamicEngine = data[8],
            dynamicNitro = data[9],
            health = data[10],
            playerDead = data[11],
            armor = data[12],
            thirst = data[13],
            hunger = data[14],
            stress = data[15],
            voice = data[16],
            radio = data[17],
            talking = data[18],
            armed = data[19],
            oxygen = data[20],
            parachute = data[21],
            nos = data[22],
            cruise = data[23],
            nitroActive = data[24],
            harness = data[25],
            hp = data[26],
            speed = data[27],
            engine = data[28],
            cinematic = data[29],
            dev = data[30],
            radioActive = data[31],
        })
    end
end

local prevVehicleStats = { nil, nil, nil, nil, nil, nil, nil, nil, nil, nil }

local function updateVehicleHud(data)
    local shouldUpdate = false
    for k, v in pairs(data) do
        if prevVehicleStats[k] ~= v then
            shouldUpdate = true
            break
        end
    end
    prevVehicleStats = data
    if shouldUpdate then
        SendNUIMessage({
            action = 'car',
            show = data[1],
            isPaused = data[2],
            seatbelt = data[3],
            speed = data[4],
            fuel = data[5],
            altitude = data[6],
            showAltitude = data[7],
            showSeatbelt = data[8],
            showSquareB = data[9],
            showCircleB = data[10],
        })
    end
end

local lastFuelUpdate = 0
local lastFuelCheck = {}

local function getFuelLevel(vehicle)
    local updateTick = GetGameTimer()
    if (updateTick - lastFuelUpdate) > 2000 then
        lastFuelUpdate = updateTick
        lastFuelCheck = math.floor(exports['LegacyFuel']:GetFuel(vehicle))
    end
    return lastFuelCheck
end

-- HUD Update loop

CreateThread(function()
    local wasInVehicle = false
    while true do
        if Menu.isChangeFPSChecked then
            Wait(500)
        else
            Wait(200)
        end
        if LocalPlayer.state.isLoggedIn then
            local show = true
            local player = PlayerPedId()
            local playerId = PlayerId()
            local weapon = GetSelectedPedWeapon(player)
            -- Player hud
            if not config.WhitelistedWeaponArmed[weapon] then
                if weapon ~= `WEAPON_UNARMED` then
                    armed = true
                else
                    armed = false
                end
            end
            playerDead = IsEntityDead(player) or PlayerData.metadata['inlaststand'] or PlayerData.metadata['isdead'] or false
            parachute = GetPedParachuteState(player)
            -- Stamina
            if not IsEntityInWater(player) then
                oxygen = 100 - GetPlayerSprintStaminaRemaining(playerId)
            end
            -- Oxygen
            if IsEntityInWater(player) then
                oxygen = GetPlayerUnderwaterTimeRemaining(playerId) * 10
            end
            -- Player hud
            local talking = NetworkIsPlayerTalking(playerId)
            local voice = 0
            if LocalPlayer.state['proximity'] then
                voice = LocalPlayer.state['proximity'].distance
            end
            if IsPauseMenuActive() then
                show = false
            end
            local vehicle = GetVehiclePedIsIn(player)
            if not (IsPedInAnyVehicle(player) and not IsThisModelABicycle(vehicle)) then
                updatePlayerHud({
                    show,
                    Menu.isDynamicHealthChecked,
                    Menu.isDynamicArmorChecked,
                    Menu.isDynamicHungerChecked,
                    Menu.isDynamicThirstChecked,
                    Menu.isDynamicStressChecked,
                    Menu.isDynamicOxygenChecked,
                    Menu.isDynamicEngineChecked,
                    Menu.isDynamicNitroChecked,
                    GetEntityHealth(player) - 100,
                    playerDead,
                    GetPedArmour(player),
                    thirst,
                    hunger,
                    stress,
                    voice,
                    LocalPlayer.state['radioChannel'],
                    talking,
                    armed,
                    oxygen,
                    parachute,
                    -1,
                    cruiseOn,
                    nitroActive,
                    harness,
                    hp,
                    math.ceil(GetEntitySpeed(vehicle) * speedMultiplier),
                    -1,
                    Menu.isCinematicModeChecked,
                    dev,
                    radioActive,
                })
            end
            -- Vehicle hud
            if IsPedInAnyHeli(player) or IsPedInAnyPlane(player) then
                showAltitude = true
                showSeatbelt = false
            end
            if IsPedInAnyVehicle(player) and not IsThisModelABicycle(vehicle) then
                if not wasInVehicle then
                    DisplayRadar(true)
                end
                wasInVehicle = true
                local engineHealth = GetVehicleEngineHealth(vehicle)
                if engineHealth ~= engineHealth then -- This checks for NaN, as any NaN value is not equal to itself
                    engineHealth = 0
                end
                updatePlayerHud({
                    show,
                    Menu.isDynamicHealthChecked,
                    Menu.isDynamicArmorChecked,
                    Menu.isDynamicHungerChecked,
                    Menu.isDynamicThirstChecked,
                    Menu.isDynamicStressChecked,
                    Menu.isDynamicOxygenChecked,
                    Menu.isDynamicEngineChecked,
                    Menu.isDynamicNitroChecked,
                    GetEntityHealth(player) - 100,
                    playerDead,
                    GetPedArmour(player),
                    thirst,
                    hunger,
                    stress,
                    voice,
                    LocalPlayer.state['radioChannel'],
                    talking,
                    armed,
                    oxygen,
                    GetPedParachuteState(player),
                    nos,
                    cruiseOn,
                    nitroActive,
                    harness,
                    hp,
                    math.ceil(GetEntitySpeed(vehicle) * speedMultiplier),
                    (engineHealth / 10),
                    Menu.isCinematicModeChecked,
                    dev,
                    radioActive,
                })
                updateVehicleHud({
                    show,
                    IsPauseMenuActive(),
                    seatbeltOn,
                    math.ceil(GetEntitySpeed(vehicle) * speedMultiplier),
                    getFuelLevel(vehicle),
                    math.ceil(GetEntityCoords(player).z * 0.5),
                    showAltitude,
                    showSeatbelt,
                    showSquareB,
                    showCircleB,
                })
                showAltitude = false
                showSeatbelt = true
            else
                if wasInVehicle then
                    wasInVehicle = false
                    SendNUIMessage({
                        action = 'car',
                        show = false,
                        seatbelt = false,
                        cruise = false,
                    })
                    seatbeltOn = false
                    cruiseOn = false
                    harness = false
                end
                DisplayRadar(Menu.isOutMapChecked)
            end
        else
            SendNUIMessage({
                action = 'hudtick',
                show = false
            })
        end
    end
end)

-- Low fuel
CreateThread(function()
    while true do
        if LocalPlayer.state.isLoggedIn then
            local ped = PlayerPedId()
            if IsPedInAnyVehicle(ped, false) and not IsThisModelABicycle(GetEntityModel(GetVehiclePedIsIn(ped, false))) then
                if exports['LegacyFuel']:GetFuel(GetVehiclePedIsIn(ped, false)) <= 20 then -- At 20% Fuel Left
                    if Menu.isLowFuelChecked then
                        TriggerServerEvent('InteractSound_SV:PlayOnSource', 'pager', 0.10)
                        QBCore.Functions.Notify(Lang:t('notify.low_fuel'), 'error')
                        Wait(60000) -- repeats every 1 min until empty
                    end
                end
            end
        end
        Wait(10000)
    end
end)

-- Money HUD

local Round = math.floor

RegisterNetEvent('hud:client:ShowAccounts', function(type, amount)
    if type == 'cash' then
        SendNUIMessage({
            action = 'show',
            type = 'cash',
            cash = Round(amount)
        })
    else
        SendNUIMessage({
            action = 'show',
            type = 'bank',
            bank = Round(amount)
        })
    end
end)

RegisterNetEvent('hud:client:OnMoneyChange', function(type, amount, isMinus)
    cashAmount = PlayerData.money['cash']
    bankAmount = PlayerData.money['bank']
    SendNUIMessage({
        action = 'updatemoney',
        cash = Round(cashAmount),
        bank = Round(bankAmount),
        amount = Round(amount),
        minus = isMinus,
        type = type
    })
end)

-- Harness Check

CreateThread(function()
    while true do
        Wait(1000)

        local ped = PlayerPedId()
        if IsPedInAnyVehicle(ped, false) then
            hasHarness(PlayerData.items)
        end
    end
end)

-- Stress Gain

if not config.DisableStress then
    CreateThread(function() -- Speeding
        while true do
            if LocalPlayer.state.isLoggedIn then
                local ped = PlayerPedId()
                if IsPedInAnyVehicle(ped, false) then
                    local veh = GetVehiclePedIsIn(ped, false)
                    local vehClass = GetVehicleClass(veh)
                    local speed = GetEntitySpeed(veh) * speedMultiplier
                    local vehHash = GetEntityModel(veh)
                    if config.VehClassStress[tostring(vehClass)] and not config.WhitelistedVehicles[vehHash] then
                        local stressSpeed
                        if vehClass == 8 then -- Motorcycle exception for seatbelt
                            stressSpeed = config.MinimumSpeed
                        else
                            stressSpeed = seatbeltOn and config.MinimumSpeed or config.MinimumSpeedUnbuckled
                        end
                        if speed >= stressSpeed then
                            TriggerServerEvent('hud:server:GainStress', math.random(1, 3))
                        end
                    end
                end
            end
            Wait(10000)
        end
    end)

    CreateThread(function() -- Shooting
        while true do
            if LocalPlayer.state.isLoggedIn then
                local ped = PlayerPedId()
                local weapon = GetSelectedPedWeapon(ped)
                if weapon ~= `WEAPON_UNARMED` then
                    if IsPedShooting(ped) and not config.WhitelistedWeaponStress[weapon] then
                        if math.random() < config.StressChance then
                            TriggerServerEvent('hud:server:GainStress', math.random(1, 3))
                        end
                    end
                else
                    Wait(1000)
                end
            end
            Wait(0)
        end
    end)
end

-- Stress Screen Effects

local function GetBlurIntensity(stresslevel)
    for _, v in pairs(config.Intensity['blur']) do
        if stresslevel >= v.min and stresslevel <= v.max then
            return v.intensity
        end
    end
    return 1500
end

local function GetEffectInterval(stresslevel)
    for _, v in pairs(config.EffectInterval) do
        if stresslevel >= v.min and stresslevel <= v.max then
            return v.timeout
        end
    end
    return 60000
end

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local effectInterval = GetEffectInterval(stress)
        if stress >= 100 then
            local BlurIntensity = GetBlurIntensity(stress)
            local FallRepeat = math.random(2, 4)
            TriggerScreenblurFadeIn(1000.0)
            Wait(BlurIntensity)
            TriggerScreenblurFadeOut(1000.0)

            -- Ragdoll removed (v0.7b): SetPedToRagdollWithFall caused vehicle
            -- emergency-stop during enter/exit state transitions. Blackout
            -- screen flash is retained as the stress penalty instead.

            Wait(1000)
            for _ = 1, FallRepeat, 1 do
                Wait(750)
                DoScreenFadeOut(200)
                Wait(1000)
                DoScreenFadeIn(200)
                TriggerScreenblurFadeIn(1000.0)
                Wait(BlurIntensity)
                TriggerScreenblurFadeOut(1000.0)
            end
        elseif stress >= config.MinimumStress then
            local BlurIntensity = GetBlurIntensity(stress)
            TriggerScreenblurFadeIn(1000.0)
            Wait(BlurIntensity)
            TriggerScreenblurFadeOut(1000.0)
        end
        Wait(effectInterval)
    end
end)

-- Minimap update
CreateThread(function()
    while true do
        SetBigmapActive(false, false)
        SetRadarZoom(1000)
        Wait(500)
    end
end)

local function BlackBars()
    DrawRect(0.0, 0.0, 2.0, w, 0, 0, 0, 255)
    DrawRect(0.0, 1.0, 2.0, w, 0, 0, 0, 255)
end

CreateThread(function()
    local minimap = RequestScaleformMovie('minimap')
    if not HasScaleformMovieLoaded(minimap) then
        RequestScaleformMovie(minimap)
        while not HasScaleformMovieLoaded(minimap) do
            Wait(1)
        end
    end
    while true do
        if w > 0 then
            BlackBars()
            DisplayRadar(0)
            SendNUIMessage({
                action = 'hudtick',
                show = false,
            })
            SendNUIMessage({
                action = 'car',
                show = false,
            })
        end
        Wait(0)
    end
end)

local prevBaseplateStats = { nil, nil, nil, nil, nil, nil, nil }

local function updateBaseplateHud(data)
    local shouldUpdate = false
    for k, v in pairs(data) do
        if prevBaseplateStats[k] ~= v then
            shouldUpdate = true
            break
        end
    end
    prevBaseplateStats = data
    if shouldUpdate then
        SendNUIMessage({
            action = 'baseplate',
            show = data[1],
            street1 = data[2],
            street2 = data[3],
            showCompass = data[4],
            showStreets = data[5],
            showPointer = data[6],
            showDegrees = data[7],
        })
    end
end

local lastCrossroadUpdate = 0
local lastCrossroadCheck = {}

local function getCrossroads(player)
    local updateTick = GetGameTimer()
    if updateTick - lastCrossroadUpdate > 1500 then
        local pos = GetEntityCoords(player)
        local street1, street2 = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
        lastCrossroadUpdate = updateTick
        lastCrossroadCheck = { GetStreetNameFromHashKey(street1), GetStreetNameFromHashKey(street2) }
    end
    return lastCrossroadCheck
end

-- Compass Update loop

CreateThread(function()
    local lastHeading = 1
    local heading
    while true do
        if Menu.isChangeCompassFPSChecked then
            Wait(100)
        else
            Wait(100)
        end
        local show = true
        local player = PlayerPedId()
        local camRot = GetGameplayCamRot(0)
        if Menu.isCompassFollowChecked then
            heading = tostring(QBCore.Shared.Round(360.0 - ((camRot.z + 360.0) % 360.0)))
        else
            heading = tostring(QBCore.Shared.Round(360.0 - GetEntityHeading(player)))
        end
        if heading == '360' then heading = '0' end
        if heading ~= lastHeading then
            if IsPedInAnyVehicle(player) then
                local crossroads = getCrossroads(player)
                SendNUIMessage({
                    action = 'update',
                    value = heading
                })
                updateBaseplateHud({
                    show,
                    crossroads[1],
                    crossroads[2],
                    Menu.isCompassShowChecked,
                    Menu.isShowStreetsChecked,
                    Menu.isPointerShowChecked,
                    Menu.isDegreesShowChecked,
                })
            else
                if Menu.isOutCompassChecked then
                    SendNUIMessage({
                        action = 'update',
                        value = heading
                    })
                    SendNUIMessage({
                        action = 'baseplate',
                        show = true,
                        showCompass = true,
                    })
                else
                    SendNUIMessage({
                        action = 'baseplate',
                        show = false,
                    })
                end
            end
        end
        lastHeading = heading
    end
end)

-- ============================================================
-- Waypoint Distance Tracker
-- 显示权限与时间完全跟随左下小地图（DisplayRadar 逻辑）
-- 提供 exports 供后期任务系统（配送、赛车、洗钱等）复用
-- ============================================================
CreateThread(function()
    local lastSent = false
    local lastDist = 0
    while true do
        Wait(500)
        if LocalPlayer.state.isLoggedIn and Menu.isWaypointDistanceChecked then
            local shouldShow = isRadarVisible()
            local ped = PlayerPedId()
            local pCoords = GetEntityCoords(ped)
            local dist = nil
            local targetType = nil
            local targetLabel = nil

            if shouldShow then
                if customTarget then
                    -- 自定义追踪目标（后期任务系统使用）优先级高于原生 waypoint
                    dist = #(vector2(pCoords.x, pCoords.y) - vector2(customTarget.x, customTarget.y))
                    targetType = 'custom'
                    targetLabel = customTarget.label
                else
                    -- 读取原生 GTA waypoint (blip type 8)
                    local blip = GetFirstBlipInfoId(8)
                    if DoesBlipExist(blip) then
                        local wpCoords = GetBlipInfoIdCoord(blip)
                        dist = #(vector2(pCoords.x, pCoords.y) - vector2(wpCoords.x, wpCoords.y))
                        targetType = 'waypoint'
                    end
                end

                if dist then
                    waypointActive = true
                    waypointDistance = dist
                    SendNUIMessage({
                        action = 'waypoint',
                        show = true,
                        distance = dist,
                        type = targetType,
                        label = targetLabel,
                    })
                    lastSent = true
                    lastDist = dist
                    TriggerEvent('hud:client:WaypointDistance', {
                        exists = true,
                        distance = dist,
                        type = targetType,
                        label = targetLabel,
                    })
                elseif lastSent then
                    waypointActive = false
                    waypointDistance = 0
                    SendNUIMessage({ action = 'waypoint', show = false })
                    lastSent = false
                    lastDist = 0
                    TriggerEvent('hud:client:WaypointDistance', { exists = false, distance = 0 })
                end
            elseif lastSent then
                waypointActive = false
                waypointDistance = 0
                SendNUIMessage({ action = 'waypoint', show = false })
                lastSent = false
                lastDist = 0
            end
        end
    end
end)

-- ============================================================
-- Exports: 供其他资源调用的模块化接口
-- ============================================================
exports('GetWaypointInfo', function()
    return {
        exists = waypointActive,
        distance = waypointDistance,
        type = customTarget and 'custom' or 'waypoint',
        label = customTarget and customTarget.label or nil,
    }
end)

exports('SetCustomTarget', function(x, y, z, label)
    customTarget = { x = x, y = y, z = z, label = label }
end)

exports('ClearCustomTarget', function()
    customTarget = nil
end)

-- ============================================================
-- Task Timer Exports
-- 供 qb-drugs 等所有任务系统复用的左侧倒计时
-- ============================================================
exports('ShowTaskTimer', function(mins, secs, phase)
    local timeStr
    if mins < 0 then
        timeStr = ('-%d:%02d'):format(math.abs(mins), secs)
    else
        timeStr = ('%d:%02d'):format(mins, secs)
    end
    SendNUIMessage({
        action = 'tasktimer',
        show = true,
        time = timeStr,
        phase = phase or 'normal',
    })
end)

exports('HideTaskTimer', function()
    SendNUIMessage({
        action = 'tasktimer',
        show = false,
    })
end)

-- ============================================================
-- 调试工具桥接: hud-position-tool 命令 → NUI 位置覆盖
-- ============================================================
RegisterNetEvent('hud-position-tool:ringPosition', function(data)
    SendNUIMessage({
        action = 'debug_ringpos',
        x = data.x,
        y = data.y,
        mode = data.mode,
    })
end)

-- 导出: 供 hud-position-tool 读取当前地图形状
exports('GetCurrentMapShape', function()
    return Menu.isToggleMapShapeChecked or 'circle'
end)

-- 调试: 仪表盘位置覆盖
RegisterNetEvent('hud-position-tool:gaugePosition', function(data)
    SendNUIMessage({
        action = 'debug_gauges',
        x = data.x,
        y = data.y,
        reset = data.reset,
    })
end)

-- 调试: 目的地距离位置覆盖
RegisterNetEvent('hud-position-tool:wpDistPosition', function(data)
    SendNUIMessage({
        action = 'debug_wpdist',
        x = data.x,
        y = data.y,
        reset = data.reset,
    })
end)
