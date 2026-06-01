local QBCore = exports['qb-core']:GetCoreObject()
local isProtected = false

local function DebugPrint(msg)
    if QBConfig
        and QBConfig.Custom
        and QBConfig.Custom.General
        and QBConfig.Custom.General.EnableDebug
    then
        print(('[custom-main][client] %s'):format(msg))
    end
end

-- 强制复活并重置本地与数据库状态（仅在无医疗资源时使用）
local function ForceRevivePlayer()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    -- 使用原生 resurrect 复活本地 Ped
    NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, heading, true, false)
    SetEntityMaxHealth(ped, 200)
    SetEntityHealth(ped, 200)
    ClearPedBloodDamage(ped)

    -- 同步状态给 LocalPlayer 状态袋
    LocalPlayer.state:set('isDead', false, true)
    LocalPlayer.state:set('inLaststand', false, true)

    -- 触发自定义服务端事件重置数据库元数据
    TriggerServerEvent('custom-main:server:ResetDeathStatus')
end

-- 玩家登录保护函数，提供安全时间防止掉落地图伤害或出生撞击伤害
local function StartLoginProtection()
    CreateThread(function()
        isProtected = true
        
        -- 稍微等待，确保 Ped 已经在游戏世界中完全加载
        Wait(500)
        
        local ped = PlayerPedId()
        
        -- 无论数据库是否记录了死亡标记，在上线时强制进行一次医疗复活与伤势清理，确保上线即为完美健康状态 (仅在 qb-ambulancejob 未启用时运行)
        if GetResourceState('qb-ambulancejob') ~= 'started' then
            ForceRevivePlayer()
            -- 确保本地生命值为满状态
            SetEntityMaxHealth(ped, 200)
            SetEntityHealth(ped, 200)
            ClearPedBloodDamage(ped)
        end
        
        local startTime = GetGameTimer()
        local duration = 12000 -- 12 秒的超级无敌与防摔保护期

        DebugPrint("已启动 12 秒上线无敌保护，防止跌落伤害及加载倒地...")

        while GetGameTimer() - startTime < duration do
            ped = PlayerPedId()
            -- 每一帧都锁定无敌
            SetEntityInvincible(ped, true)
            SetPlayerInvincible(PlayerId(), true)
            
            -- 如果在加载中仍因某些逆天物理引擎碰撞/卡出虚空被系统杀掉，强行在保护期内无限复活 (仅在 qb-ambulancejob 未启用时生效)
            if GetResourceState('qb-ambulancejob') ~= 'started' and (IsEntityDead(ped) or GetEntityHealth(ped) <= 0) then
                DebugPrint("检测到加载期间发生死亡，触发上线强力拉起复活...")
                ForceRevivePlayer()
                Wait(500)
            end
            Wait(100)
        end

        -- 保护结束，恢复正常伤害接收
        ped = PlayerPedId()
        SetEntityInvincible(ped, false)
        SetPlayerInvincible(PlayerId(), false)
        isProtected = false
        DebugPrint("上线无敌保护已安全结束")
    end)
end

CreateThread(function()
    DebugPrint('custom-main client initialized')
end)

-- 玩家加载完成（客户端）事件桥接
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    DebugPrint('QBCore:Client:OnPlayerLoaded')
    
    -- 启动超强上线保护（适用于所有加载阶段，无视 qb-ambulancejob 是否启用）
    StartLoginProtection()
end)

-- 玩家卸载（客户端）事件桥接
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    DebugPrint('QBCore:Client:OnPlayerUnload')
end)

-- 检测死亡并自动复活的后台线程（仅在 qb-ambulancejob 未启用时生效）
CreateThread(function()
    while true do
        Wait(2000)
        if LocalPlayer.state.isLoggedIn then
            if GetResourceState('qb-ambulancejob') ~= 'started' then
                local ped = PlayerPedId()
                if IsEntityDead(ped) or GetEntityHealth(ped) <= 0 then
                    DebugPrint('Detected player death while qb-ambulancejob is stopped. Auto-reviving in 3 seconds...')
                    Wait(3000)
                    -- 再次确认状态，防止在等待期间被其它逻辑处理
                    if IsEntityDead(PlayerPedId()) or GetEntityHealth(PlayerPedId()) <= 0 then
                        ForceRevivePlayer()
                    end
                end
            else
                -- 如果 qb-ambulancejob 已经启动，可以降低检测频率或直接退出线程
                Wait(5000)
            end
        end
    end
end)

-- 上线前与角色选择阶段的超级无敌保护线程（防止在加载脚本前或选择角色时摔伤/死亡被医疗脚本记录）
CreateThread(function()
    while true do
        Wait(100)
        if not LocalPlayer.state.isLoggedIn then
            local ped = PlayerPedId()
            if ped and ped ~= 0 then
                SetEntityInvincible(ped, true)
                SetPlayerInvincible(PlayerId(), true)
                SetEntityHealth(ped, 200)
                SetEntityMaxHealth(ped, 200)
            end
        else
            Wait(2000)
        end
    end
end)


