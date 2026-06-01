local QBCore = exports['qb-core']:GetCoreObject()
local isCustomWanted = false
local customWantedStars = 0
local SuspectBlips = {}

-- ==========================================
--        原 生 警 星 检 测 与 移 交 线程
-- ==========================================
CreateThread(function()
    while true do
        Wait(2000)
        if LocalPlayer.state.isLoggedIn then
            local playerId = PlayerId()
            local nativeWanted = GetPlayerWantedLevel(playerId)
            
            -- 当玩家原生警星达到 3 星及以上，且尚未进入自定义通缉状态时
            if nativeWanted >= 3 and not isCustomWanted then
                isCustomWanted = true
                customWantedStars = nativeWanted
                
                -- 提示玩家通缉移交
                TriggerEvent('QBCore:Notify', string.format("【警星移交】你的警星达到 %d 星！NPC 警车已撤退，通缉权已移交玩家警察！", customWantedStars), "error", 8000)
                PlaySoundFrontend(-1, "WANTED_MULTIPLIER", "HUD_FRONTEND_DEFAULT_SOUNDSET", 1)
                
                -- 清除原生警星，防止原生 AI 警察无限刷车干扰 RP
                ClearPlayerWantedLevel(playerId)
                SetMaxWantedLevel(0)
                
                -- 触发服务器事件：向全体警察广播并自动记入 MDT 通缉
                local ped = PlayerPedId()
                local coords = GetEntityCoords(ped)
                local streetHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
                local streetName = GetStreetNameFromHashKey(streetHash)
                TriggerServerEvent('custom-main:server:policeHandoverAlert', coords, streetName, customWantedStars)
            end
            
            -- 如果处于自定义通缉中，持续锁定原生警星为 0，防止再次刷出 AI 警车
            if isCustomWanted then
                ClearPlayerWantedLevel(playerId)
                SetMaxWantedLevel(0)
            end
        end
    end
end)

-- ==========================================
--        定 期 发 送 GPS Triangulation 信号
-- ==========================================
CreateThread(function()
    while true do
        Wait(8000) -- 每 8 秒发送一次 GPS 脉冲
        if LocalPlayer.state.isLoggedIn and isCustomWanted then
            local ped = PlayerPedId()
            local coords = GetEntityCoords(ped)
            local streetHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
            local streetName = GetStreetNameFromHashKey(streetHash)
            
            -- 持续更新坐标脉冲给警察
            TriggerServerEvent('custom-main:server:policeHandoverAlert', coords, streetName, customWantedStars)
            TriggerEvent('QBCore:Notify', "【警用直升机】你的 GPS 信号正被警方基站雷达三角定位，位置已被广播！", "warning", 3000)
        end
    end
end)

-- ==========================================
--        清 除 本 地 自 定 义 通 缉 状 态
-- ==========================================
RegisterNetEvent('custom-main:client:clearLocalWanted', function()
    isCustomWanted = false
    customWantedStars = 0
    local playerId = PlayerId()
    SetMaxWantedLevel(5) -- 恢复原生最大警星限制为 5 星
    ClearPlayerWantedLevel(playerId) -- 清空当前累积的原生警星
    SetPoliceIgnorePlayer(playerId, false) -- 确保恢复为可被 NPC 警察追捕状态
    TriggerEvent('QBCore:Notify', "你已被解除通缉，警方的雷达定位信号已消失。", "success")
end)

-- ==========================================
--         警 员 专 属：雷 达 脉 冲 红 点 blip
-- ==========================================
RegisterNetEvent('custom-main:client:updateSuspectBlip', function(suspectSource, suspectCoords, suspectName, wantedLevel)
    local PlayerData = QBCore.Functions.GetPlayerData()
    
    -- 仅限执勤中的警察可见该红点脉冲
    if PlayerData.job and PlayerData.job.name == 'police' and PlayerData.job.onduty then
        -- 如果已存在该嫌疑人的旧雷达点，清除之
        if SuspectBlips[suspectSource] then
            RemoveBlip(SuspectBlips[suspectSource])
        end
        
        -- 在嫌疑人位置创建一个红色雷达脉冲点
        local blip = AddBlipForCoord(suspectCoords.x, suspectCoords.y, suspectCoords.z)
        SetBlipSprite(blip, 161) -- 警徽/雷达脉冲标记
        SetBlipColour(blip, 1) -- 红色
        SetBlipScale(blip, 1.2)
        SetBlipAsShortRange(blip, false)
        SetBlipFlashes(blip, true) -- 使其闪烁
        
        -- 设置雷达路径引导
        SetBlipRoute(blip, true)
        SetBlipRouteColour(blip, 1) -- 红色路径
        
        -- blip 文本标签
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(string.format("【通缉犯】%s (%d星)", suspectName, wantedLevel))
        EndTextCommandSetBlipName(blip)
        
        SuspectBlips[suspectSource] = blip
        
        -- 提供脉冲提示音
        PlaySoundFrontend(-1, "CHECKPOINT_BEAST", "HUD_FRONTEND_SOUNDSET", 1)
        
        -- 12 秒后自动消失（如果期间没有收到新的 8 秒 GPS 信号更新，模拟信号中断）
        SetTimeout(12000, function()
            if SuspectBlips[suspectSource] and SuspectBlips[suspectSource] == blip then
                RemoveBlip(blip)
                SuspectBlips[suspectSource] = nil
            end
        end)
    end
end)

-- ==========================================
--         警 员 专 属：销 毁 雷 达 blip
-- ==========================================
RegisterNetEvent('custom-main:client:clearSuspectBlip', function(suspectSource)
    if SuspectBlips[suspectSource] then
        RemoveBlip(SuspectBlips[suspectSource])
        SuspectBlips[suspectSource] = nil
    end
end)

-- ==========================================
--        警 员 / 帮 派 免 役 及 NPC 友 好 线程
-- ==========================================
local isCartelSetup = false

CreateThread(function()
    while true do
        Wait(1000)
        if LocalPlayer.state.isLoggedIn then
            local PlayerData = QBCore.Functions.GetPlayerData()
            local ped = PlayerPedId()
            local playerId = PlayerId()
            
            if PlayerData.gang and PlayerData.gang.name == 'cartel' then
                -- 优先处理：Cartel 帮派成员（无视是否兼任警察，确保庄园友好）
                SetPoliceIgnorePlayer(playerId, false)
                
                -- 设置关系组为 AMBIENT_GANG_MEXICAN (庄园 Cartel NPC 的原生关系组)
                -- 这样庄园里的 Cartel 守卫会视玩家为同伙，绝不主动开枪产生仇恨！
                SetPedRelationshipGroupHash(ped, GetHashKey("AMBIENT_GANG_MEXICAN"))
                
                -- 核心逻辑：设置双向关系为 0 (Companion / 同盟伙伴)
                -- 这样即使庄园附近发生枪战/枪声，NPC 也会绝对把玩家当做同伴盟友，绝不产生敌对反击！
                if not isCartelSetup then
                    local cartelHash = GetHashKey("AMBIENT_GANG_MEXICAN")
                    local playerHash = GetHashKey("PLAYER")
                    
                    SetRelationshipBetweenGroups(0, playerHash, cartelHash)
                    SetRelationshipBetweenGroups(0, cartelHash, playerHash)
                    SetRelationshipBetweenGroups(0, cartelHash, cartelHash)
                    isCartelSetup = true
                end
            elseif PlayerData.job and PlayerData.job.name == 'police' and PlayerData.job.onduty then
                -- 警察执勤中：免除原生通缉与自定义通缉
                isCustomWanted = false
                customWantedStars = 0
                ClearPlayerWantedLevel(playerId)
                SetMaxWantedLevel(0)
                SetPoliceIgnorePlayer(playerId, true)
                
                -- 设置警察 ped 关系组为 COP (与 NPC 警察同组)
                -- 这样即使误伤 NPC 警察，他们也会把玩家当成“同僚”，绝对不会反击或攻击！
                SetPedRelationshipGroupHash(ped, GetHashKey("COP"))
                
                -- 如果之前是 Cartel 状态，清理大门关系
                if isCartelSetup then
                    local cartelHash = GetHashKey("AMBIENT_GANG_MEXICAN")
                    local playerHash = GetHashKey("PLAYER")
                    
                    SetRelationshipBetweenGroups(5, playerHash, cartelHash)
                    SetRelationshipBetweenGroups(5, cartelHash, playerHash)
                    SetRelationshipBetweenGroups(5, cartelHash, cartelHash)
                    isCartelSetup = false
                end
            else
                -- 普通状态：恢复为普通玩家关系组
                SetPoliceIgnorePlayer(playerId, false)
                SetPedRelationshipGroupHash(ped, GetHashKey("PLAYER"))
                
                -- 恢复双向敌对关系为 5 (Hate / 极度仇恨)
                if isCartelSetup then
                    local cartelHash = GetHashKey("AMBIENT_GANG_MEXICAN")
                    local playerHash = GetHashKey("PLAYER")
                    
                    SetRelationshipBetweenGroups(5, playerHash, cartelHash)
                    SetRelationshipBetweenGroups(5, cartelHash, playerHash)
                    SetRelationshipBetweenGroups(5, cartelHash, cartelHash)
                    isCartelSetup = false
                end
            end
        end
    end
end)

-- ==========================================
--        被 通 缉 逃 犯 专 属：路 人 恐 慌 线程
-- ==========================================
CreateThread(function()
    while true do
        Wait(1500) -- 每 1.5 秒扫描一次附近路人
        if LocalPlayer.state.isLoggedIn and isCustomWanted then
            local playerPed = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)
            
            -- 获取当前客户端加载的所有 Ped 实体
            local peds = GetGamePool('CPed')
            for i = 1, #peds do
                local ped = peds[i]
                
                -- 排除玩家自己、死人、动物以及警察 NPC
                if ped ~= playerPed and not IsPedAPlayer(ped) and not IsEntityDead(ped) then
                    local pedType = GetPedType(ped)
                    -- 6 is COP, 28 is ANIMAL
                    if pedType ~= 6 and pedType ~= 28 then
                        local pedCoords = GetEntityCoords(ped)
                        local dx = playerCoords.x - pedCoords.x
                        local dy = playerCoords.y - pedCoords.y
                        local dz = playerCoords.z - pedCoords.z
                        local distSq = dx*dx + dy*dy + dz*dz
                        
                        -- 对 25 米范围内的普通市民施加恐慌任务 (25^2 = 625.0)
                        if distSq <= 625.0 then
                            -- 如果路人在车里，让他们狂踩油门恐慌逃离
                            if IsPedInAnyVehicle(ped, false) then
                                local veh = GetVehiclePedIsIn(ped, false)
                                if veh and veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                                    -- 触发载具恐慌驾驶指令（Action 9 是地板油极速逃离）
                                    TaskVehicleTempAction(ped, veh, 9, 6000)
                                end
                            else
                                -- 如果路人是步行，让他们抱头大叫逃跑
                                SetPedFleeAttributes(ped, 0, false)
                                TaskFleePed(ped, playerPed, 15000, -1)
                                
                                -- 触发尖叫声效
                                if math.random(1, 10) <= 3 then -- 30% 概率发出环境大喊
                                    PlayAmbientSpeech1(ped, "GENERIC_FRIGHTENED_HIGH", "SPEECH_PARAMS_FORCE_SHOUT_CLEAR")
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end)
