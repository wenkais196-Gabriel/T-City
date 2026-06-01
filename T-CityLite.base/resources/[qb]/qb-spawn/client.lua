local QBCore = exports['qb-core']:GetCoreObject()
local camZPlus1 = 1500
local camZPlus2 = 50
local pointCamCoords = 75
local pointCamCoords2 = 0
local cam1Time = 500
local cam2Time = 1000
local choosingSpawn = false
local Houses = {}
local cam = nil
local cam2 = nil
local isNewCharacter = false
local isProtected = false

local enableDebugLogs = false  -- 调试完成，关闭详细日志
local function DebugPrint(msg)
    if enableDebugLogs then
        print(msg)
    end
end

-- ==========================================
--        幽灵防护与物理穿透引擎 (Ghost Protection)
-- ==========================================

local function StartSpawnProtection()
    CreateThread(function()
        local ped = PlayerPedId()
        local startTime = GetGameTimer()
        local duration = 3000 -- 3 秒幽灵防护保护期

        -- 设置状态包标记，通知生存与 HUD 模块玩家已完全安全降落
        LocalPlayer.state:set("isSpawnFinished", true, false)

        -- 开启绝对无敌、设置 150 Alpha 半透明虚影状态，并屏蔽临时环境事件
        SetEntityInvincible(ped, true)
        SetPlayerInvincible(PlayerId(), true)
        SetEntityAlpha(ped, 150, false)
        SetBlockingOfNonTemporaryEvents(ped, true)

        while GetGameTimer() - startTime < duration do
            ped = PlayerPedId()
            -- 高频维持无敌与透明度状态
            SetEntityInvincible(ped, true)
            SetPlayerInvincible(PlayerId(), true)
            SetEntityAlpha(ped, 150, false)

            -- 动态剔除与局域网内所有 Peds (包括玩家及 NPC) 的物理碰撞，杜绝模型挤压
            local peds = GetGamePool('CPed')
            for i = 1, #peds do
                local otherPed = peds[i]
                if otherPed ~= ped then
                    SetEntityNoCollisionEntity(ped, otherPed, true)
                end
            end

            -- 动态剔除与局域网内所有载具的物理碰撞，避免刚出生时被车祸波及
            local vehicles = GetGamePool('CVehicle')
            for i = 1, #vehicles do
                local veh = vehicles[i]
                SetEntityNoCollisionEntity(ped, veh, true)
            end

            Wait(0)
        end

        -- 保护期结束，平滑恢复正常物理撞击接收与常规血量结算
        ped = PlayerPedId()
        ResetEntityAlpha(ped)
        SetEntityInvincible(ped, false)
        SetPlayerInvincible(PlayerId(), false)
        SetBlockingOfNonTemporaryEvents(ped, false)
        DebugPrint("[qb-spawn] 幽灵保护期与动态防挤压碰撞已安全关闭。")
    end)
end

exports('StartSpawnProtection', StartSpawnProtection)

-- ==========================================
--        极端情况防护网算法 (Edge-Case Safeguards)
-- ==========================================

local function RunEdgeCaseSafeguards(pos)
    local ped = PlayerPedId()
    local x, y, z = pos.x, pos.y, pos.z

    -- 1. 地底/虚空防坠落拉回修正 (Z 轴低于 -100.0)
    if z < -100.0 then
        -- 强制重定位至 Legion Square 市中心安全生成点
        x, y, z = 195.17, -933.77, 29.7
        SetEntityCoords(ped, x, y, z)
        QBCore.Functions.Notify("检测到空间裂缝，您已被引力安全拉回市区中心。", "error", 8000)
        DebugPrint("[qb-spawn] Edge-Case Safeguard triggered: Void fall prevented. Teleported to Legion Square.")
    end

    -- 2. 深海断线防溺水修正 (如果玩家生成在深海中)
    if IsPedSwimming(ped) or IsEntityInWater(ped) then
        -- 赋予 15 秒无限肺活量/水下呼吸 Buff，确保玩家有足够的时间浮上海面
        SetPedMaxTimeUnderwater(ped, 15.0)
        QBCore.Functions.Notify("检测到您在水中上线，水下呼吸气泡已充盈，请尽快游上海面。", "primary", 8000)
        DebugPrint("[qb-spawn] Edge-Case Safeguard triggered: Marine spawn buffer active.")
    end

    -- 3. 高空重登断线坠落修正 (高度 Z 轴大于 150.0 且不处于任何房产内部)
    local PlayerData = QBCore.Functions.GetPlayerData()
    local insideMeta = PlayerData.metadata['inside']
    if z > 150.0 and insideMeta.house == nil and insideMeta.apartment.apartmentType == nil then
        -- 紧急配给降落伞，防止重登高空自由落体摔死
        GiveWeaponToPed(ped, `GADGET_PARACHUTE`, 1, false, true)
        QBCore.Functions.Notify("检测到高空坠落危机，紧急救生备用伞包已自动配给。", "warning", 8000)
        DebugPrint("[qb-spawn] Edge-Case Safeguard triggered: High-altitude spawn detected. Parachute supplied.")
    end

    return vector3(x, y, z)
end

local function SetDisplay(bool)
    local translations = {}
    for k in pairs(Lang.fallback and Lang.fallback.phrases or Lang.phrases) do
        if k:sub(0, #'ui.') then
            translations[k:sub(#'ui.' + 1)] = Lang:t(k)
        end
    end
    choosingSpawn = bool
    SetNuiFocus(bool, bool)
    SendNUIMessage({
        action = 'showUi',
        status = bool,
        translations = translations
    })
end

-- ==========================================
--        智能路由派发中心 (Spawn Router)
-- ==========================================

RegisterNetEvent('qb-spawn:client:openUI', function(value)
    DebugPrint('[qb-spawn:DEBUG] openUI 触发, isNewCharacter=' .. tostring(isNewCharacter) .. ', value=' .. tostring(value))
    QBCore.Functions.GetPlayerData(function(PlayerData)
        DebugPrint('[qb-spawn:DEBUG] GetPlayerData 回调收到, isNewCharacter=' .. tostring(isNewCharacter))
        -- 1. 硬核原位登录路由拦截 (老玩家无论死伤 100% 绕过 UI 直接原位静默生成)
        if not isNewCharacter then
            DebugPrint("[qb-spawn] 检测到已有角色，触发硬核原路由静默载入...")
            
            -- 加载序列黑屏拦截，杜绝贴图闪烁与惊鸿一瞥
            DebugPrint('[qb-spawn:DEBUG] 调用 DoScreenFadeOut(0)')
            DoScreenFadeOut(0)
            SetEntityVisible(PlayerPedId(), false)
            Wait(300)

            local ped = PlayerPedId()
            local insideMeta = PlayerData.metadata['inside']

            -- 强行锁定冻结与早期上线无敌状态
            FreezeEntityPosition(ped, true)
            SetEntityCoords(ped, PlayerData.position.x, PlayerData.position.y, PlayerData.position.z)
            SetEntityHeading(ped, PlayerData.position.a)
            SetEntityInvincible(ped, true)
            SetPlayerInvincible(PlayerId(), true)

            -- 黑屏保护下挂起，调用 RequestCollisionAtCoord 强载地表碰撞体
            RequestCollisionAtCoord(PlayerData.position.x, PlayerData.position.y, PlayerData.position.z)
            local time = GetGameTimer()
            while not HasCollisionLoadedAroundEntity(ped) and (GetGameTimer() - time) < 5000 do
                Wait(10)
            end
            Wait(500) -- 给地表纹理与细节预留缓冲时间

            -- 激活极端边缘防护网过滤
            local safePos = RunEdgeCaseSafeguards(PlayerData.position)
            SetEntityCoords(ped, safePos.x, safePos.y, safePos.z)
            FreezeEntityPosition(ped, false)

            -- 房产与公寓内部重登静默同步
            local isSpecialSpawn = false
            local insideHouse = insideMeta and insideMeta.house
            local insideAptType = insideMeta and insideMeta.apartment and insideMeta.apartment.apartmentType
            local insideAptId = insideMeta and insideMeta.apartment and insideMeta.apartment.apartmentId
            DebugPrint(('[qb-spawn:DEBUG] inside meta: house=%s, aptType=%s, aptId=%s'):format(
                tostring(insideHouse), tostring(insideAptType), tostring(insideAptId)))
            if insideHouse ~= nil then
                isSpecialSpawn = true
                local houseId = insideHouse
                DebugPrint('[qb-spawn:DEBUG] 触发 qb-houses:client:LastLocationHouse, houseId=' .. tostring(houseId))
                TriggerEvent('qb-houses:client:LastLocationHouse', houseId)
            elseif insideAptType ~= nil or insideAptId ~= nil then
                isSpecialSpawn = true
                DebugPrint('[qb-spawn:DEBUG] 触发 qb-apartments:client:LastLocationHouse, aptType=' .. tostring(insideAptType) .. ', aptId=' .. tostring(insideAptId))
                TriggerEvent('qb-apartments:client:LastLocationHouse', insideAptType, insideAptId)
            end
            DebugPrint('[qb-spawn:DEBUG] isSpecialSpawn=' .. tostring(isSpecialSpawn))

            -- 触发核心与自定义的玩家载入就绪通知
            TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
            TriggerEvent('QBCore:Client:OnPlayerLoaded')

            -- 画面重置与相机解绑
            if DoesCamExist(cam) then DestroyCam(cam, true) end
            if DoesCamExist(cam2) then DestroyCam(cam2, true) end
            RenderScriptCams(false, false, 0, true, true)

            if not isSpecialSpawn then
                DebugPrint('[qb-spawn:DEBUG] 走普通地图路径, 即将 SetEntityVisible + DoScreenFadeIn')
                SetEntityVisible(ped, true)
                StartSpawnProtection()
                Wait(1500)
                DebugPrint('[qb-spawn:DEBUG] 调用 DoScreenFadeIn(1000)')
                DoScreenFadeIn(1000)
                DebugPrint('[qb-spawn:DEBUG] DoScreenFadeIn 调用完成')
                -- [NUI黑屏 Fix] 强制关闭 multicharacter NUI，防止其黑色全屏层残留覆盖画面
                TriggerEvent('qb-multicharacter:client:closeNUI')
            else
                -- [BlackScreen Fix] 房产/公寓出生：qb-interior/qb-houses 负责传送，
                -- 但它们不一定会调用 DoScreenFadeIn，这里做 5 秒超时兜底保障
                CreateThread(function()
                    local timeout = 5000
                    local interval = 200
                    local elapsed = 0
                    while elapsed < timeout do
                        Wait(interval)
                        elapsed = elapsed + interval
                        -- 如果画面已经在淡入（非黑屏），提前退出
                        if IsScreenFadedIn() then
                            -- 就算 interior 已处理淡入，也强制关闭 multichar NUI
                            TriggerEvent('qb-multicharacter:client:closeNUI')
                            return
                        end
                    end
                    -- 超时强制补救：确保玩家可见并淡入
                    DebugPrint("[qb-spawn] BlackScreen fallback triggered for special spawn (openUI).")
                    SetEntityVisible(PlayerPedId(), true)
                    FreezeEntityPosition(PlayerPedId(), false)
                    DoScreenFadeIn(800)
                    TriggerEvent('qb-multicharacter:client:closeNUI')
                end)
            end

        -- 2. 新玩家创建角色的放行路线，依然展示精美公寓选点界面
        else
            DebugPrint("[qb-spawn] 检测到新创建角色，放行公寓选点 UI 界面...")
            SetEntityVisible(PlayerPedId(), false)
            DoScreenFadeOut(250)
            Wait(1000)

            local ped = PlayerPedId()
            -- 为防止在 NUI 挂起选择界面中摔伤，同样注入强制无敌
            SetEntityInvincible(ped, true)
            SetPlayerInvincible(PlayerId(), true)
            
            -- 高空俯瞰相机视角载入
            cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', PlayerData.position.x, PlayerData.position.y, PlayerData.position.z + camZPlus1, -85.00, 0.00, 0.00, 100.00, false, 0)
            SetCamActive(cam, true)
            RenderScriptCams(true, false, 1, true, true)
            
            -- 请求碰撞体载入
            RequestCollisionAtCoord(PlayerData.position.x, PlayerData.position.y, PlayerData.position.z)
            local time = GetGameTimer()
            while not HasCollisionLoadedAroundEntity(ped) and (GetGameTimer() - time) < 3000 do
                Wait(10)
            end
            Wait(500)
            
            DoScreenFadeIn(250)
            Wait(500)
            SetDisplay(value)
        end
    end)
end)

RegisterNetEvent('qb-houses:client:setHouseConfig', function(houseConfig)
    Houses = houseConfig
end)

-- 缓存老/新玩家身份
RegisterNetEvent('qb-spawn:client:setupSpawns', function(cData, new, apps)
    LocalPlayer.state:set("isSpawnFinished", false, false)
    isNewCharacter = new
    if not new then
        QBCore.Functions.TriggerCallback('qb-spawn:server:getOwnedHouses', function(houses)
            local myHouses = {}
            if houses ~= nil then
                for i = 1, (#houses), 1 do
                    myHouses[#myHouses + 1] = {
                        house = houses[i].house,
                        label = Houses[houses[i].house].adress,
                    }
                end
            end

            Wait(500)
            SendNUIMessage({
                action = 'setupLocations',
                locations = QB.Spawns,
                houses = myHouses,
                isNew = new
            })
        end, cData.citizenid)
    elseif new then
        SendNUIMessage({
            action = 'setupAppartements',
            locations = apps,
            isNew = new
        })
    end
end)

-- ==========================================
--               NUI 回调函数
-- ==========================================

RegisterNUICallback('exit', function(_, cb)
    SetNuiFocus(false, false)
    SendNUIMessage({
        action = 'showUi',
        status = false
    })
    choosingSpawn = false
    cb('ok')
end)

local function SetCam(campos)
    cam2 = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', campos.x, campos.y, campos.z + camZPlus1, 300.00, 0.00, 0.00, 110.00, false, 0)
    PointCamAtCoord(cam2, campos.x, campos.y, campos.z + pointCamCoords)
    SetCamActiveWithInterp(cam2, cam, cam1Time, true, true)
    if DoesCamExist(cam) then
        DestroyCam(cam, true)
    end
    Wait(cam1Time)

    cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', campos.x, campos.y, campos.z + camZPlus2, 300.00, 0.00, 0.00, 110.00, false, 0)
    PointCamAtCoord(cam, campos.x, campos.y, campos.z + pointCamCoords2)
    SetCamActiveWithInterp(cam, cam2, cam2Time, true, true)
    SetEntityCoords(PlayerPedId(), campos.x, campos.y, campos.z)
end

RegisterNUICallback('setCam', function(data, cb)
    local location = tostring(data.posname)
    local type = tostring(data.type)
    DoScreenFadeOut(200)
    Wait(500)
    DoScreenFadeIn(200)
    if DoesCamExist(cam) then DestroyCam(cam, true) end
    if DoesCamExist(cam2) then DestroyCam(cam2, true) end
    if type == 'current' then
        QBCore.Functions.GetPlayerData(function(PlayerData)
            SetCam(PlayerData.position)
        end)
    elseif type == 'house' then
        SetCam(Houses[location].coords.enter)
    elseif type == 'normal' then
        SetCam(QB.Spawns[location].coords)
    elseif type == 'appartment' then
        SetCam(Apartments.Locations[location].coords.enter)
    end
    cb('ok')
end)

RegisterNUICallback('chooseAppa', function(data, cb)
    local appaYeet = data.appType
    SetDisplay(false)
    DoScreenFadeOut(500)
    Wait(5000)
    TriggerServerEvent('apartments:server:CreateApartment', appaYeet, Apartments.Locations[appaYeet].label, true)
    TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
    TriggerEvent('QBCore:Client:OnPlayerLoaded')
    local ped = PlayerPedId()
    
    -- 冻结并隐藏玩家实体，交给 qb-interior 完成最终渲染与幽灵保护
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false)
    
    -- 立即释放并销毁选人相机
    RenderScriptCams(false, false, 0, true, true)
    if DoesCamExist(cam) then
        SetCamActive(cam, false)
        DestroyCam(cam, true)
        cam = nil
    end
    if DoesCamExist(cam2) then
        SetCamActive(cam2, false)
        DestroyCam(cam2, true)
        cam2 = nil
    end
    
    cb('ok')
end)

local function PreSpawnPlayer()
    SetDisplay(false)
    DoScreenFadeOut(500)
    Wait(2000)
end

local function PostSpawnPlayer()
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(PlayerPedId(), true)

    -- 落地启动 3 秒无碰撞幽灵状态保护
    StartSpawnProtection()

    -- 相机平滑从高空降落拉回至 Ped
    DoScreenFadeIn(500)
    RenderScriptCams(false, true, 1000, true, true)
    Wait(1000)

    SetCamActive(cam, false)
    DestroyCam(cam, true)
    SetCamActive(cam2, false)
    DestroyCam(cam2, true)
end

RegisterNUICallback('spawnplayer', function(data, cb)
    local location = tostring(data.spawnloc)
    local type = tostring(data.typeLoc)
    local ped = PlayerPedId()
    local PlayerData = QBCore.Functions.GetPlayerData()
    local insideMeta = PlayerData.metadata['inside']
    if type == 'current' then
        PreSpawnPlayer()
        QBCore.Functions.GetPlayerData(function(pd)
            ped = PlayerPedId()
            
            -- 上线前锁定无敌以隔离所有加载伤害
            SetEntityInvincible(ped, true)
            SetPlayerInvincible(PlayerId(), true)

            FreezeEntityPosition(ped, true)
            SetEntityCoords(ped, pd.position.x, pd.position.y, pd.position.z)
            SetEntityHeading(ped, pd.position.a)

            RequestCollisionAtCoord(pd.position.x, pd.position.y, pd.position.z)
            local time = GetGameTimer()
            while not HasCollisionLoadedAroundEntity(ped) and (GetGameTimer() - time) < 5000 do
                Wait(10)
            end

            -- 边缘保护过滤器
            local safePos = RunEdgeCaseSafeguards(pd.position)
            SetEntityCoords(ped, safePos.x, safePos.y, safePos.z)
            FreezeEntityPosition(ped, false)
        end)

        local isSpecialSpawn = false
        if insideMeta.house ~= nil then
            isSpecialSpawn = true
            local houseId = insideMeta.house
            TriggerEvent('qb-houses:client:LastLocationHouse', houseId)
        elseif insideMeta.apartment.apartmentType ~= nil or insideMeta.apartment.apartmentId ~= nil then
            isSpecialSpawn = true
            local apartmentType = insideMeta.apartment.apartmentType
            local apartmentId = insideMeta.apartment.apartmentId
            TriggerEvent('qb-apartments:client:LastLocationHouse', apartmentType, apartmentId)
        end
        TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
        TriggerEvent('QBCore:Client:OnPlayerLoaded')
        
        if not isSpecialSpawn then
            PostSpawnPlayer()
        else
            -- 房产/公寓出生时隐藏玩家实体并冻结，等待 qb-interior 自主完成最终载入与幽灵保护开启
            SetEntityVisible(ped, false)
            FreezeEntityPosition(ped, true)
            -- 立即销毁选人相机
            RenderScriptCams(false, false, 0, true, true)
            if DoesCamExist(cam) then
                SetCamActive(cam, false)
                DestroyCam(cam, true)
                cam = nil
            end
            if DoesCamExist(cam2) then
                SetCamActive(cam2, false)
                DestroyCam(cam2, true)
                cam2 = nil
            end
            -- [BlackScreen Fix] 房产/公寓路径：5 秒超时兜底淡入
            CreateThread(function()
                local timeout = 5000
                local interval = 200
                local elapsed = 0
                while elapsed < timeout do
                    Wait(interval)
                    elapsed = elapsed + interval
                    if IsScreenFadedIn() then return end
                end
                DebugPrint("[qb-spawn] BlackScreen fallback triggered for special spawn (spawnplayer current).")
                SetEntityVisible(PlayerPedId(), true)
                FreezeEntityPosition(PlayerPedId(), false)
                DoScreenFadeIn(800)
            end)
        end
    elseif type == 'house' then
        PreSpawnPlayer()
        TriggerEvent('qb-houses:client:enterOwnedHouse', location)
        TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
        TriggerEvent('QBCore:Client:OnPlayerLoaded')
        TriggerServerEvent('qb-houses:server:SetInsideMeta', 0, false)
        TriggerServerEvent('qb-apartments:server:SetInsideMeta', 0, 0, false)
        
        -- 房产出生时隐藏玩家实体并冻结，等待 qb-interior 自主完成最终载入与幽灵保护开启
        SetEntityVisible(ped, false)
        FreezeEntityPosition(ped, true)
        -- 立即销毁选人相机
        RenderScriptCams(false, false, 0, true, true)
        if DoesCamExist(cam) then
            SetCamActive(cam, false)
            DestroyCam(cam, true)
            cam = nil
        end
        if DoesCamExist(cam2) then
            SetCamActive(cam2, false)
            DestroyCam(cam2, true)
            cam2 = nil
        end
        -- [BlackScreen Fix] house 路径：5 秒超时兜底淡入
        CreateThread(function()
            local timeout = 5000
            local interval = 200
            local elapsed = 0
            while elapsed < timeout do
                Wait(interval)
                elapsed = elapsed + interval
                if IsScreenFadedIn() then return end
            end
            DebugPrint("[qb-spawn] BlackScreen fallback triggered for house spawn.")
            SetEntityVisible(PlayerPedId(), true)
            FreezeEntityPosition(PlayerPedId(), false)
            DoScreenFadeIn(800)
        end)
    elseif type == 'normal' then
        local pos = QB.Spawns[location].coords
        PreSpawnPlayer()
        ped = PlayerPedId()
        
        -- 无敌保护
        SetEntityInvincible(ped, true)
        SetPlayerInvincible(PlayerId(), true)

        FreezeEntityPosition(ped, true)
        SetEntityCoords(ped, pos.x, pos.y, pos.z)
        TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
        TriggerEvent('QBCore:Client:OnPlayerLoaded')
        TriggerServerEvent('qb-houses:server:SetInsideMeta', 0, false)
        TriggerServerEvent('qb-apartments:server:SetInsideMeta', 0, 0, false)

        RequestCollisionAtCoord(pos.x, pos.y, pos.z)
        local time = GetGameTimer()
        while not HasCollisionLoadedAroundEntity(ped) and (GetGameTimer() - time) < 5000 do
            Wait(10)
        end

        local safePos = RunEdgeCaseSafeguards(vector3(pos.x, pos.y, pos.z))
        SetEntityCoords(ped, safePos.x, safePos.y, safePos.z)
        SetEntityHeading(ped, pos.w)
        FreezeEntityPosition(ped, false)
        PostSpawnPlayer()
    end
    cb('ok')
end)

-- ==========================================
--                轮询线程
-- ==========================================

CreateThread(function()
    while true do
        Wait(0)
        if choosingSpawn then
            DisableAllControlActions(0)
        else
            Wait(1000)
        end
    end
end)

-- 后台持续空间防坠落与黑屏卡死守护线程
CreateThread(function()
    while true do
        Wait(1000)
        if LocalPlayer.state.isLoggedIn then
            local ped = PlayerPedId()
            if ped and ped ~= 0 and DoesEntityExist(ped) then
                local coords = GetEntityCoords(ped)
                
                -- 1. 动态虚空防坠落检测 (Z 轴低于 -100.0)
                if coords.z < -100.0 then
                    local safeCoords = vector3(195.17, -933.77, 29.7) -- Legion Square
                    SetEntityCoords(ped, safeCoords.x, safeCoords.y, safeCoords.z)
                    FreezeEntityPosition(ped, false)
                    SetEntityVisible(ped, true)
                    DoScreenFadeIn(500)
                    QBCore.Functions.Notify("检测到您坠入虚空空间，已安全将您重置回市区中心。", "error", 8000)
                    DebugPrint("[qb-spawn] Guard Monitor: Void fall detected at Z=" .. tostring(coords.z) .. ". Reset to Legion Square.")
                end


            end
        end
    end
end)

-- ==========================================
--        手动画面/相机故障恢复指令 (Manual Recovery)
-- ==========================================

RegisterCommand('fadein', function()
    print("[qb-spawn] Manual recovery /fadein triggered.")
    DoScreenFadeIn(500)
    QBCore.Functions.Notify("手动屏幕淡入指令已执行。", "success", 5000)
end, false)

RegisterCommand('fixscreen', function()
    print("[qb-spawn] Manual recovery /fixscreen triggered.")
    DoScreenFadeIn(500)
    RenderScriptCams(false, false, 0, true, true)
    DestroyAllCams(true)
    
    local ped = PlayerPedId()
    SetEntityVisible(ped, true)
    FreezeEntityPosition(ped, false)
    
    QBCore.Functions.Notify("手动黑屏与相机重置指令已执行，实体已平滑复苏！", "success", 8000)
end, false)
