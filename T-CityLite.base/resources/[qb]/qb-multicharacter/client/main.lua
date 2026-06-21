local cam = nil
local charPed = nil
local loadScreenCheckState = false
local QBCore = exports['qb-core']:GetCoreObject()
local cached_player_skins = {}
local locationCache = {}

local enableDebugLogs = false
local function DebugPrint(...)
    if enableDebugLogs then
        print(...)
    end
end

local randommodels = { -- models possible to load when choosing empty slot
    'mp_m_freemode_01',
    'mp_f_freemode_01',
}

-- Main Thread

CreateThread(function()
    exports.spawnmanager:setAutoSpawn(false) -- 立即关闭默认重生管理器，杜绝任何默认人物随机生成的闪烁与跑动
    while true do
        Wait(0)
        if NetworkIsSessionStarted() then
            TriggerEvent('qb-multicharacter:client:chooseChar')
            return
        end
    end
end)

-- Functions

local function loadModel(model)
    DebugPrint("[MULTICHARACTER] Requesting model:", model)
    RequestModel(model)
    local timeout = 1000
    while not HasModelLoaded(model) and timeout > 0 do
        Wait(0)
        timeout = timeout - 1
    end
    if timeout <= 0 then
        print("[MULTICHARACTER] ERROR: Model failed to load within timeout:", model)
    else
        DebugPrint("[MULTICHARACTER] Model loaded successfully:", model)
    end
end

local function initializePedModel(model, data)
    CreateThread(function()
        DebugPrint("[MULTICHARACTER] initializePedModel triggered. model:", model, "hasData:", data ~= nil)
        if not model then
            model = joaat(randommodels[math.random(#randommodels)])
            DebugPrint("[MULTICHARACTER] Warning: No model provided, using random fallback:", model)
        end
        
        loadModel(model)
        
        charPed = CreatePed(2, model, Config.PedCoords.x, Config.PedCoords.y, Config.PedCoords.z - 0.98, Config.PedCoords.w, false, true)
        if DoesEntityExist(charPed) then
            DebugPrint("[MULTICHARACTER] Ped created successfully. Entity ID:", charPed)
        else
            print("[MULTICHARACTER] ERROR: Failed to create Ped entity!")
            return
        end
        
        SetPedComponentVariation(charPed, 0, 0, 0, 2)
        FreezeEntityPosition(charPed, true) -- 强行锁定预览 Ped 物理位置，防止其因地图碰撞体未载入而坠入虚空
        SetEntityInvincible(charPed, true)
        -- PlaceObjectOnGroundProperly(charPed) -- 禁用地面自适应，防止没有碰撞时将 Ped 强行吸附至地图底部
        SetBlockingOfNonTemporaryEvents(charPed, true)
        
        -- 显式赋予 100% 可见度与不透明度，消除隐藏隐患
        SetEntityVisible(charPed, true, false)
        SetEntityAlpha(charPed, 255, false)

        if data then
            DebugPrint("[MULTICHARACTER] Triggering loadPlayerClothing event for preview ped...")
            TriggerEvent('qb-clothing:client:loadPlayerClothing', data, charPed)
        end

        -- 动态相机锁定跟踪：将摄像机视轨中心强行对准并锁定在人物躯干，彻底杜绝画外偏置
        if DoesCamExist(cam) then
            PointCamAtEntity(cam, charPed, 0.0, 0.0, 0.0, true)
            DebugPrint("[MULTICHARACTER] Camera pointed and locked onto preview Ped.")
        else
            DebugPrint("[MULTICHARACTER] Warning: cam does not exist, cannot point camera!")
        end
    end)
end

local function skyCam(bool)
    if bool then
        DoScreenFadeIn(1000)
        SetTimecycleModifier('hud_def_blur')
        SetTimecycleModifierStrength(1.0)
        FreezeEntityPosition(PlayerPedId(), false)
        cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', Config.CamCoords.x, Config.CamCoords.y, Config.CamCoords.z, 0.0, 0.0, Config.CamCoords.w, 60.00, false, 0)
        SetCamActive(cam, true)
        RenderScriptCams(true, false, 1, true, true)
        if DoesEntityExist(charPed) then
            PointCamAtEntity(cam, charPed, 0.0, 0.0, 0.0, true)
        end
    else
        SetTimecycleModifier('default')
        SetCamActive(cam, false)
        DestroyCam(cam, true)
        DestroyAllCams(true)
        RenderScriptCams(false, false, 1, true, true)
        FreezeEntityPosition(PlayerPedId(), false)
    end
end

local function openCharMenu(bool)
    if not bool then
        SetNuiFocus(false, false)
        SendNUIMessage({
            action = 'ui',
            toggle = false
        })
        -- [NUI黑屏根本修复] 绕过 Vue 响应式，直接强制隐藏 DOM
        -- 无论 Vue 的 v-show/v-if 是否正常工作，都确保 .main-screen 黑色层消失
        SendNUIMessage({ action = 'forceHide' })
        skyCam(false)
        return
    end

    QBCore.Functions.TriggerCallback('qb-multicharacter:server:GetNumberOfCharacters', function(result, countries)
        local translations = {}
        for k in pairs(Lang.fallback and Lang.fallback.phrases or Lang.phrases) do
            if k:sub(0, ('ui.'):len()) then
                translations[k:sub(('ui.'):len() + 1)] = Lang:t(k)
            end
        end
        SetNuiFocus(true, true)
        -- 先恢复 DOM 可见性（关闭 forceHide 的覆盖）
        SendNUIMessage({ action = 'forceShow' })
        SendNUIMessage({
            action = 'ui',
            customNationality = Config.customNationality,
            toggle = true,
            nChar = result,
            enableDeleteButton = Config.EnableDeleteButton,
            translations = translations,
            countries = countries,
        })
        skyCam(true)
        if not loadScreenCheckState then
            ShutdownLoadingScreenNui()
            loadScreenCheckState = true
        end
    end)
end

-- Events

RegisterNetEvent('qb-multicharacter:client:closeNUIdefault', function() -- This event is only for no starting apartments
    DeleteEntity(charPed)
    SetNuiFocus(false, false)
    openCharMenu(false) -- 立即显式关闭 NUI 并销毁黑色渐变蒙版，杜绝任何过渡残留
    DoScreenFadeOut(500)
    Wait(2000)
    SetEntityCoords(PlayerPedId(), Config.DefaultSpawn.x, Config.DefaultSpawn.y, Config.DefaultSpawn.z)
    TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
    TriggerEvent('QBCore:Client:OnPlayerLoaded')
    TriggerServerEvent('qb-houses:server:SetInsideMeta', 0, false)
    TriggerServerEvent('qb-apartments:server:SetInsideMeta', 0, 0, false)
    Wait(500)
    openCharMenu(false)
    SetEntityVisible(PlayerPedId(), true)
    Wait(500)
    DoScreenFadeIn(250)
    TriggerEvent('qb-clothes:client:CreateFirstCharacter')
end)

RegisterNetEvent('qb-multicharacter:client:closeNUI', function()
    DeleteEntity(charPed)
    SetNuiFocus(false, false)
    openCharMenu(false) -- 核心修复：在新角色创建并登录公寓选点时，显式关闭多角色UI并销毁黑色蒙版
end)

RegisterNetEvent('qb-multicharacter:client:chooseChar', function()
    SetNuiFocus(false, false)
    DoScreenFadeOut(10)
    Wait(1000)
    local interior = GetInteriorAtCoords(Config.Interior.x, Config.Interior.y, Config.Interior.z - 18.9)
    if interior ~= 0 then
        LoadInterior(interior)
        local timeout = 50
        while not IsInteriorReady(interior) and timeout > 0 do
            Wait(100)
            timeout = timeout - 1
        end
    end
    FreezeEntityPosition(PlayerPedId(), true)

    -- 极致空间引擎优化：将玩家真实实体完全隐形，并直接移动到相机位置！
    -- 这样能强制 GTA V 引擎将全部的流式渲染资源、地表碰撞以及 3D 预览 Ped 渲染核心 100% 聚焦对准在相机正前方，彻底扫清由于渲染焦点距离引起的隐形 Bug！
    SetEntityVisible(PlayerPedId(), false, false)
    SetEntityCoords(PlayerPedId(), Config.CamCoords.x, Config.CamCoords.y, Config.CamCoords.z - 1.98)

    Wait(1500)
    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()
    openCharMenu(true)
end)

RegisterNetEvent('qb-multicharacter:client:spawnLastLocation', function(coords, cData)
    QBCore.Functions.TriggerCallback('apartments:GetOwnedApartment', function(result)
        if result then
            TriggerEvent('apartments:client:SetHomeBlip', result.type)
            local ped = PlayerPedId()
            SetEntityCoords(ped, coords.x, coords.y, coords.z)
            SetEntityHeading(ped, coords.w)
            FreezeEntityPosition(ped, false)
            SetEntityVisible(ped, true)
            local PlayerData = QBCore.Functions.GetPlayerData()
            local insideMeta = PlayerData.metadata['inside']
            DoScreenFadeOut(500)

            if insideMeta.house then
                TriggerEvent('qb-houses:client:LastLocationHouse', insideMeta.house)
            elseif insideMeta.apartment.apartmentType and insideMeta.apartment.apartmentId then
                TriggerEvent('qb-apartments:client:LastLocationHouse', insideMeta.apartment.apartmentType, insideMeta.apartment.apartmentId)
            else
                SetEntityCoords(ped, coords.x, coords.y, coords.z)
                SetEntityHeading(ped, coords.w)
                FreezeEntityPosition(ped, false)
                SetEntityVisible(ped, true)
            end

            TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
            TriggerEvent('QBCore:Client:OnPlayerLoaded')
            Wait(2000)
            DoScreenFadeIn(250)
        end
    end, cData.citizenid)
end)

-- NUI Callbacks

RegisterNUICallback('closeUI', function(_, cb)
    local cData = data.cData
    DoScreenFadeOut(10)
    TriggerServerEvent('qb-multicharacter:server:loadUserData', cData)
    openCharMenu(false)
    SetEntityAsMissionEntity(charPed, true, true)
    DeleteEntity(charPed)
    if Config.SkipSelection then
        SetNuiFocus(false, false)
        skyCam(false)
    else
        openCharMenu(false)
    end
    cb('ok')
end)

RegisterNUICallback('disconnectButton', function(_, cb)
    SetEntityAsMissionEntity(charPed, true, true)
    DeleteEntity(charPed)
    TriggerServerEvent('qb-multicharacter:server:disconnect')
    cb('ok')
end)

RegisterNUICallback('selectCharacter', function(data, cb)
    local cData = data.cData
    DoScreenFadeOut(10)
    TriggerServerEvent('qb-multicharacter:server:loadUserData', cData)
    openCharMenu(false)
    SetEntityAsMissionEntity(charPed, true, true)
    DeleteEntity(charPed)
    cb('ok')
end)

RegisterNUICallback('cDataPed', function(nData, cb)
    local cData = nData.cData
    DebugPrint("[MULTICHARACTER] cDataPed NUI Callback received. Has cData:", cData ~= nil)
    
    SetEntityAsMissionEntity(charPed, true, true)
    DeleteEntity(charPed)
    
    if cData ~= nil then
        DebugPrint("[MULTICHARACTER] Selecting character citizenid:", cData.citizenid)
        if not cached_player_skins[cData.citizenid] then
            DebugPrint("[MULTICHARACTER] Skin not cached. Requesting from server callback...")
            local temp_model = promise.new()
            local temp_data = promise.new()

            QBCore.Functions.TriggerCallback('qb-multicharacter:server:getSkin', function(model, data)
                DebugPrint("[MULTICHARACTER] getSkin server callback returned model:", model, "data length:", data and string.len(data) or 0)
                temp_model:resolve(model)
                temp_data:resolve(data)
            end, cData.citizenid)

            local resolved_model = Citizen.Await(temp_model)
            local resolved_data = Citizen.Await(temp_data)
            DebugPrint("[MULTICHARACTER] Promise resolved. model:", resolved_model)

            cached_player_skins[cData.citizenid] = { model = resolved_model, data = resolved_data }
        else
            DebugPrint("[MULTICHARACTER] Skin already in cache.")
        end

        local model = cached_player_skins[cData.citizenid].model
        local data = cached_player_skins[cData.citizenid].data

        -- 深度修复：在 QBCore 中，model 字段通常存储为字符串（如 'mp_m_freemode_01'）
        -- 原版 model = model ~= nil and tonumber(model) or false 遇到字符串时会转为 false，导致始终加载随机角色！
        -- 如果 data 为 nil，json.decode(data) 会直接抛出 Lua 异常崩溃，导致整个 Ped 生成中断！
        local final_model = nil
        if model then
            if type(model) == 'number' then
                final_model = model
            elseif type(model) == 'string' then
                if tonumber(model) then
                    final_model = tonumber(model)
                else
                    final_model = joaat(model)
                end
            end
        end

        local final_data = nil
        if data and type(data) == 'string' and data ~= "" then
            -- 使用 pcall 包装 json.decode，防止任何格式不合规的脏数据使整条生成链路彻底断裂崩溃
            local success, decoded = pcall(json.decode, data)
            if success then
                final_data = decoded
            else
                print("[MULTICHARACTER] ERROR: Failed to json.decode skin data!")
            end
        end

        DebugPrint("[MULTICHARACTER] Final resolved model:", final_model, "has final_data:", final_data ~= nil)

        if final_model then
            initializePedModel(final_model, final_data)
        else
            DebugPrint("[MULTICHARACTER] No valid model found in skins database, initializing default/empty ped model...")
            initializePedModel()
        end
        cb('ok')
    else
        DebugPrint("[MULTICHARACTER] cData is nil, initializing default/empty ped model...")
        initializePedModel()
        cb('ok')
    end
end)

local function GetDecoratedStreetName(citizenid, coords)
    if not coords or not coords.x or not coords.y or not coords.z then
        return "未知位置"
    end
    
    local cache = locationCache[citizenid]
    if cache then
        local dist = #(vector3(coords.x, coords.y, coords.z) - cache.coords)
        if dist < 1.0 then
            return cache.label
        end
    end
    
    local streetHash, crossingHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local streetName = GetStreetNameFromHashKey(streetHash)
    local zoneLabel = GetLabelText(GetNameOfZone(coords.x, coords.y, coords.z))
    local fullLabel = streetName .. ", " .. zoneLabel
    
    locationCache[citizenid] = {
        coords = vector3(coords.x, coords.y, coords.z),
        label = fullLabel
    }
    return fullLabel
end

RegisterNUICallback('setupCharacters', function(_, cb)
    QBCore.Functions.TriggerCallback('qb-multicharacter:server:setupCharacters', function(result)
        cached_player_skins = {}
        for i = 1, #result do
            if result[i].position then
                result[i].location = GetDecoratedStreetName(result[i].citizenid, result[i].position)
            else
                result[i].location = "未知位置"
            end
        end
        SendNUIMessage({
            action = 'setupCharacters',
            characters = result
        })
        cb('ok')
    end)
end)

RegisterNUICallback('removeBlur', function(_, cb)
    SetTimecycleModifier('default')
    cb('ok')
end)

RegisterNUICallback('createNewCharacter', function(data, cb)
    local cData = data
    DoScreenFadeOut(150)
    if cData.gender == Lang:t('ui.male') then
        cData.gender = 0
    elseif cData.gender == Lang:t('ui.female') then
        cData.gender = 1
    end
    TriggerServerEvent('qb-multicharacter:server:createCharacter', cData)
    Wait(500)
    cb('ok')
end)

RegisterNUICallback('removeCharacter', function(data, cb)
    TriggerServerEvent('qb-multicharacter:server:deleteCharacter', data.citizenid)
    DeletePed(charPed)
    TriggerEvent('qb-multicharacter:client:chooseChar')
    cb('ok')
end)
