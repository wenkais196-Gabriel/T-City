local function CalculateDynamicDecay()
    local ped = PlayerPedId()
    local multiplier = 1.0
    local speed = GetEntitySpeed(ped)

    -- 1. 静止/休息阻尼：坐下或完全静止时，新陈代谢消耗降低 50%
    if IsPedSittingInAnyVehicle(ped) or speed < 0.1 then
        multiplier = 0.5
    -- 2. 剧烈运动过载：奔跑/冲刺时，消耗上浮 30%
    elseif IsPedRunning(ped) or IsPedSprinting(ped) then
        multiplier = 1.3
    end

    -- 3. 战场极度紧绷：正在开枪射击或处于通缉中，消耗增加 50%
    if IsPedShooting(ped) or GetPlayerWantedLevel(PlayerId()) > 0 then
        multiplier = 1.5
    end

    return multiplier
end

CreateThread(function()
    local staggered = false
    while true do
        local sleep = 0
        if LocalPlayer.state.isLoggedIn and LocalPlayer.state.isSpawnFinished then
            if not staggered then
                staggered = true
                -- 错峰防抖：首次登录/载入完成后随机延迟 1 至 30 秒，分摊心跳和自动存档的数据库写入压力
                Wait(math.random(1000, 30000))
            end
            sleep = (1000 * 60) * QBCore.Config.UpdateInterval
            local multiplier = CalculateDynamicDecay()
            TriggerServerEvent('QBCore:UpdatePlayer', multiplier)
        else
            sleep = 1000
        end
        Wait(sleep)
    end
end)

CreateThread(function()
    while true do
        if LocalPlayer.state.isLoggedIn and LocalPlayer.state.isSpawnFinished then
            if (QBCore.PlayerData.metadata['hunger'] <= 0 or QBCore.PlayerData.metadata['thirst'] <= 0) and not (QBCore.PlayerData.metadata['isdead'] or QBCore.PlayerData.metadata['inlaststand']) then
                local ped = PlayerPedId()
                local currentHealth = GetEntityHealth(ped)
                local decreaseThreshold = math.random(5, 10)
                SetEntityHealth(ped, currentHealth - decreaseThreshold)
            end
        end
        Wait(QBCore.Config.StatusInterval)
    end
end)
