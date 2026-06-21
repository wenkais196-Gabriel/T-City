-- ============================================================
--  qb-weathersync 客户端
--  事件溯源模型：服务端推送 (syncMinutes, frozen)，客户端用
--  GetGameTimer() 平滑插值。两端独立运行相同 TIME_SCALE，
--  每 60 秒对表一次，漂移 < 0.1 秒。
-- ============================================================

-- 🔒 生产模式: 直接静默, 不依赖任何外部资源
_G.PRODUCTION_MODE = true
local TIME_SCALE = tonumber(GetConvar('weathersync_time_scale', '1.0')) or 1.0
local CurrentWeather = Config.StartWeather
local lastWeather = CurrentWeather
local blackout = Config.Blackout
local blackoutVehicle = Config.BlackoutVehicle
local disable = Config.Disabled

-- 时间状态
local syncMinutes = 0    -- 最近一次服务端同步的游戏分钟数
local syncTimer = 0      -- 最近一次同步时的 GetGameTimer()
local frozen = false     -- 是否冻结

-- ============================================================
--  初始化
-- ============================================================
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    disable = false
    TriggerServerEvent('qb-weathersync:server:RequestStateSync')
end)

-- ============================================================
--  服务端同步事件
-- ============================================================
RegisterNetEvent('qb-weathersync:client:SyncWeather', function(NewWeather, newblackout)
    CurrentWeather = NewWeather
    blackout = newblackout
end)

RegisterNetEvent('qb-weathersync:client:SyncTime', function(minutes, isFrozen)
    if not _G.PRODUCTION_MODE then print(('[weathersync] <<< SyncTime minutes=%d frozen=%s'):format(minutes, tostring(isFrozen))) end
    syncMinutes = minutes
    syncTimer = GetGameTimer()
    frozen = isFrozen
end)

-- ============================================================
--  调试：冻结 / 解冻
-- ============================================================
RegisterNetEvent('qb-weathersync:client:freezeWorld', function(weather, hour, minute)
    disable = true
    if weather and weather ~= '' then
        SetRainLevel(0.0)
        SetWeatherTypePersist(weather)
        SetWeatherTypeNow(weather)
        SetWeatherTypeNowPersist(weather)
        if not _G.PRODUCTION_MODE then print(('[weathersync] 🌍 freezeWorld: weather=%s'):format(weather)) end
    end
    if hour then
        local h = math.floor((hour ~= nil) and tonumber(hour) or 12)
        local m = math.floor((minute ~= nil) and tonumber(minute) or 0)
        NetworkOverrideClockTime(h, m, 0)
        if not _G.PRODUCTION_MODE then print(('[weathersync] 🌍 freezeWorld: time=%02d:%02d  verify=%02d:%02d'):format(h, m, GetClockHours(), GetClockMinutes())) end
    end
end)

RegisterNetEvent('qb-weathersync:client:unfreezeWorld', function()
    disable = false
    if not _G.PRODUCTION_MODE then print('[weathersync] 🌍 unfreezeWorld: sync restored') end
end)

-- 向后兼容 qb-houses 的 EnableSync 调用
RegisterNetEvent('qb-weathersync:client:EnableSync', function()
    disable = false
end)

-- ============================================================
--  天气线程（不变）
-- ============================================================
CreateThread(function()
    while true do
        if not disable then
            if lastWeather ~= CurrentWeather then
                lastWeather = CurrentWeather
                SetWeatherTypeOverTime(CurrentWeather, 15.0)
                Wait(15000)
            end
            Wait(100)
            SetArtificialLightsState(blackout)
            SetArtificialLightsStateAffectsVehicles(blackoutVehicle)
            ClearOverrideWeather()
            ClearWeatherTypePersist()
            SetWeatherTypePersist(lastWeather)
            SetWeatherTypeNow(lastWeather)
            SetWeatherTypeNowPersist(lastWeather)
            if lastWeather == 'XMAS' then
                SetForceVehicleTrails(true)
                SetForcePedFootstepsTracks(true)
            else
                SetForceVehicleTrails(false)
                SetForcePedFootstepsTracks(false)
            end
            if lastWeather == 'RAIN' then
                SetRainLevel(0.3)
            elseif lastWeather == 'THUNDER' then
                SetRainLevel(0.5)
            else
                SetRainLevel(0.0)
            end
        else
            Wait(1000)
        end
    end
end)

-- ============================================================
--  时间线程 — GetGameTimer 平滑插值
-- ============================================================
CreateThread(function()
    while true do
        if not disable then
            Wait(0)
            if frozen then
                -- 冻结：固定显示同步时间
                local h = math.floor(syncMinutes / 60) % 24
                local m = syncMinutes % 60
                NetworkOverrideClockTime(h, m, 0)
            else
                -- 平滑插值: elapsed(真实秒) × TIME_SCALE = 游戏分钟增量
                local elapsedMin = (GetGameTimer() - syncTimer) / 1000.0 * TIME_SCALE
                local cur = syncMinutes + elapsedMin
                cur = cur % 1440
                local h = math.floor(cur / 60)
                local m = math.floor(cur % 60)
                local s = math.floor((cur * 60) % 60)
                NetworkOverrideClockTime(h, m, s)
            end
            -- 每 ~5 秒诊断打印 (仅开发模式)
            if not _G.PRODUCTION_MODE and (GetGameTimer() % 5000) < 16 then
                print(('[weathersync] clock=%02d:%02d:%02d sync=%d frozen=%s disable=%s'):format(
                    GetClockHours(), GetClockMinutes(), GetClockSeconds(), syncMinutes, tostring(frozen), tostring(disable)))
            end
        else
            Wait(1000)
        end
    end
end)

-- ============================================================
--  诊断命令
-- ============================================================
RegisterCommand('checktime', function()
    print('========== TIME DIAGNOSTIC ==========')
    print(('GetClockHours/Minutes: %02d:%02d'):format(GetClockHours(), GetClockMinutes()))
    print(('syncMinutes=%d  syncTimer=%d'):format(syncMinutes, syncTimer))
    local elapsed = frozen and 0 or ((GetGameTimer() - syncTimer) / 1000.0 * TIME_SCALE)
    print(('elapsed=%.1f game-min  frozen=%s  disable=%s'):format(elapsed, tostring(frozen), tostring(disable)))
    print('======================================')
end, false)

RegisterCommand('settime', function(_, args)
    local h = tonumber(args[1])
    local m = tonumber(args[2]) or 0
    if not h or h < 0 or h > 23 then
        print('[settime] 用法: /settime HH [MM] (HH=0-23)')
        return
    end
    print(('[settime] 请求设置时间 %02d:%02d ...'):format(h, m))
    TriggerServerEvent('qb-weathersync:server:setTime', h, m)
end, false)
