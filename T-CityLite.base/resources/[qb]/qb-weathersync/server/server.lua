local QBCore = exports['qb-core']:GetCoreObject()

-- ============================================================
--  状态模型：gameMinutes(整数 分钟) + frozen(bool) + timerStart(ms)
--  1 真实秒 = TIME_SCALE 游戏分钟 (GTA V 默认 2.0)
-- ============================================================
local TIME_SCALE = tonumber(GetConvar('weathersync_time_scale', '1.0')) or 1.0
local CurrentWeather = Config.StartWeather
local gameMinutes = 0          -- 当前游戏分钟数 (0 ~ 1439, 例: 120 = 02:00)
local frozen = Config.FreezeTime
local timerStart = 0           -- GetGameTimer() 基准点
local blackout = Config.Blackout
local newWeatherTimer = Config.NewWeatherTimer

-- 初始化：用 os.time 推算当前游戏分钟
do
    local now = os.time(os.date("!*t"))
    gameMinutes = math.floor(now / 60) % 1440  -- 1:1 时钟: 当前真实世界分钟 = 游戏分钟
    timerStart = GetGameTimer()
end

-- ============================================================
--  辅助函数
-- ============================================================
local function getSource(src)
    return src == '' and 0 or src
end

local function isAllowedToChange(src)
    return src == 0 or QBCore.Functions.HasPermission(src, "admin") or IsPlayerAceAllowed(src, 'command')
end

--- 获取当前服务端游戏分钟数（含冻结判定）
local function getCurrentGameMinutes()
    if frozen then return gameMinutes end
    local elapsed = (GetGameTimer() - timerStart) / 1000.0 * TIME_SCALE
    return math.floor((gameMinutes + elapsed) % 1440)
end

-- ============================================================
--  天气
-- ============================================================
local function nextWeatherStage()
    if CurrentWeather == "CLEAR" or CurrentWeather == "CLOUDS" or CurrentWeather == "EXTRASUNNY" then
        CurrentWeather = (math.random(1, 5) > 2) and "CLEARING" or "OVERCAST"
    elseif CurrentWeather == "CLEARING" or CurrentWeather == "OVERCAST" then
        local new = math.random(1, 6)
        if new == 1 then CurrentWeather = (CurrentWeather == "CLEARING") and "FOGGY" or "RAIN"
        elseif new == 2 then CurrentWeather = "CLOUDS"
        elseif new == 3 then CurrentWeather = "CLEAR"
        elseif new == 4 then CurrentWeather = "EXTRASUNNY"
        elseif new == 5 then CurrentWeather = "SMOG"
        else CurrentWeather = "FOGGY"
        end
    elseif CurrentWeather == "THUNDER" or CurrentWeather == "RAIN" then CurrentWeather = "CLEARING"
    elseif CurrentWeather == "SMOG" or CurrentWeather == "FOGGY" then CurrentWeather = "CLEAR"
    else CurrentWeather = "CLEAR"
    end
    TriggerEvent("qb-weathersync:server:RequestStateSync")
end

local function setWeather(weather)
    local validWeatherType = false
    for _, weatherType in pairs(Config.AvailableWeatherTypes) do
        if weatherType == string.upper(weather) then validWeatherType = true end
    end
    if not validWeatherType then return false end
    CurrentWeather = string.upper(weather)
    newWeatherTimer = Config.NewWeatherTimer
    Config.DynamicWeather = false
    TriggerEvent('qb-weathersync:server:RequestStateSync')
    return true
end

-- ============================================================
--  时间
-- ============================================================
local function setTime(hour, minute)
    local h = tonumber(hour)
    local m = tonumber(minute) or 0
    if h == nil or h < 0 or h > 23 then
        print(Lang:t('time.invalid'))
        return false
    end
    gameMinutes = h * 60 + m
    frozen = true
    timerStart = GetGameTimer()
    print(Lang:t('time.change', {value = h, value2 = m}))
    TriggerEvent('qb-weathersync:server:RequestStateSync')
    return true
end

local function setTimeFreeze(state)
    if state == nil then state = not frozen end
    frozen = state
    timerStart = GetGameTimer()  -- 重置计时基准，防止冻结期间积累的时长一次性释放
    TriggerEvent('qb-weathersync:server:RequestStateSync')
    return frozen
end

-- ============================================================
--  其他
-- ============================================================
local function setBlackout(state)
    if state == nil then state = not blackout end
    if state then blackout = true else blackout = false end
    TriggerEvent('qb-weathersync:server:RequestStateSync')
    return blackout
end

local function setDynamicWeather(state)
    if state == nil then state = not Config.DynamicWeather end
    if state then Config.DynamicWeather = true else Config.DynamicWeather = false end
    TriggerEvent('qb-weathersync:server:RequestStateSync')
    return Config.DynamicWeather
end

-- ============================================================
--  网络事件（保留所有原有接口）
-- ============================================================
RegisterNetEvent('qb-weathersync:server:RequestStateSync', function()
    local cur = getCurrentGameMinutes()
    TriggerClientEvent('qb-weathersync:client:SyncWeather', -1, CurrentWeather, blackout)
    TriggerClientEvent('qb-weathersync:client:SyncTime', -1, cur, frozen)
end)

RegisterNetEvent('qb-weathersync:server:setWeather', function(weather)
    local src = getSource(source)
    if isAllowedToChange(src) then
        local success = setWeather(weather)
        if src > 0 then
            if success then TriggerClientEvent('QBCore:Notify', src, Lang:t('weather.updated'))
            else TriggerClientEvent('QBCore:Notify', src, Lang:t('weather.invalid')) end
        end
    end
end)

RegisterNetEvent('qb-weathersync:server:setTime', function(hour, minute)
    local src = getSource(source)
    if isAllowedToChange(src) then
        local success = setTime(hour, minute)
        if src > 0 then
            if success then TriggerClientEvent('QBCore:Notify', src, Lang:t('time.change', {value = hour, value2 = minute or "00"}))
            else TriggerClientEvent('QBCore:Notify', src, Lang:t('time.invalid')) end
        end
    end
end)

RegisterNetEvent('qb-weathersync:server:toggleBlackout', function(state)
    local src = getSource(source)
    if isAllowedToChange(src) then
        local newstate = setBlackout(state)
        if src > 0 then
            if newstate then TriggerClientEvent('QBCore:Notify', src, Lang:t('blackout.enabled'))
            else TriggerClientEvent('QBCore:Notify', src, Lang:t('blackout.disabled')) end
        end
    end
end)

RegisterNetEvent('qb-weathersync:server:toggleFreezeTime', function(state)
    local src = getSource(source)
    if isAllowedToChange(src) then
        local newstate = setTimeFreeze(state)
        if src > 0 then
            if newstate then TriggerClientEvent('QBCore:Notify', src, Lang:t('time.now_frozen'))
            else TriggerClientEvent('QBCore:Notify', src, Lang:t('time.now_unfrozen')) end
        end
    end
end)

RegisterNetEvent('qb-weathersync:server:toggleDynamicWeather', function(state)
    local src = getSource(source)
    if isAllowedToChange(src) then
        local newstate = setDynamicWeather(state)
        if src > 0 then
            if newstate then TriggerClientEvent('QBCore:Notify', src, Lang:t('weather.now_unfrozen'))
            else TriggerClientEvent('QBCore:Notify', src, Lang:t('weather.now_frozen')) end
        end
    end
end)

-- ============================================================
--  命令
-- ============================================================
QBCore.Commands.Add('freezetime', Lang:t('help.freezecommand'), {}, false, function(source)
    local newstate = setTimeFreeze()
    if source > 0 then
        if newstate then return TriggerClientEvent('QBCore:Notify', source, Lang:t('time.frozenc')) end
        return TriggerClientEvent('QBCore:Notify', source, Lang:t('time.unfrozenc'))
    end
    if newstate then print(Lang:t('time.now_frozen')) else print(Lang:t('time.now_unfrozen')) end
end, 'admin')

QBCore.Commands.Add('freezeweather', Lang:t('help.freezeweathercommand'), {}, false, function(source)
    local newstate = setDynamicWeather()
    if source > 0 then
        if newstate then TriggerClientEvent('QBCore:Notify', source, Lang:t('dynamic_weather.enabled'))
        else TriggerClientEvent('QBCore:Notify', source, Lang:t('dynamic_weather.disabled')) end
    end
end, 'admin')

QBCore.Commands.Add('weather', Lang:t('help.weathercommand'), {{name = Lang:t('help.weathertype'), help = Lang:t('help.availableweather')}}, true, function(source, args)
    local success = setWeather(args[1])
    if source > 0 then
        if success then TriggerClientEvent('QBCore:Notify', source, Lang:t('weather.willchangeto', {value = string.lower(args[1])}))
        else TriggerClientEvent('QBCore:Notify', source, Lang:t('weather.invalidc'), 'error') end
    end
end, 'admin')

QBCore.Commands.Add('blackout', Lang:t('help.blackoutcommand'), {}, false, function(source)
    local newstate = setBlackout()
    if source > 0 then
        if newstate then TriggerClientEvent('QBCore:Notify', source, Lang:t('blackout.enabledc'))
        else TriggerClientEvent('QBCore:Notify', source, Lang:t('blackout.disabledc')) end
    end
end, 'admin')

QBCore.Commands.Add('morning', Lang:t('help.morningcommand'), {}, false, function(source)
    setTime(9, 0)
    if source > 0 then TriggerClientEvent('QBCore:Notify', source, Lang:t('time.morning')) end
end, 'admin')

QBCore.Commands.Add('noon', Lang:t('help.nooncommand'), {}, false, function(source)
    setTime(12, 0)
    if source > 0 then TriggerClientEvent('QBCore:Notify', source, Lang:t('time.noon')) end
end, 'admin')

QBCore.Commands.Add('evening', Lang:t('help.eveningcommand'), {}, false, function(source)
    setTime(18, 0)
    if source > 0 then TriggerClientEvent('QBCore:Notify', source, Lang:t('time.evening')) end
end, 'admin')

QBCore.Commands.Add('night', Lang:t('help.nightcommand'), {}, false, function(source)
    setTime(23, 0)
    if source > 0 then TriggerClientEvent('QBCore:Notify', source, Lang:t('time.night')) end
end, 'admin')

QBCore.Commands.Add('time', Lang:t('help.timecommand'), {{ name=Lang:t('help.timehname'), help=Lang:t('help.timeh') }, { name=Lang:t('help.timemname'), help=Lang:t('help.timem') }}, true, function(source, args)
    local success = setTime(args[1], args[2])
    if source > 0 then
        if success then TriggerClientEvent('QBCore:Notify', source, Lang:t('time.changec', {value = args[1] .. ':' .. (args[2] or "00")}))
        else TriggerClientEvent('QBCore:Notify', source, Lang:t('time.invalidc'), 'error') end
    end
end, 'admin')

-- 开发调试：冻结全服世界状态
QBCore.Commands.Add('freezeworld', '冻结全服天气和时间', {
    { name = 'preset', help = 'night|snow|storm|clear 或天气名 或 time' },
    { name = 'hour',   help = '小时 0-23' },
    { name = 'minute', help = '分钟 0-59' }
}, false, function(source, args)
    local preset = args[1]
    local hour = tonumber(args[2])
    local minute = tonumber(args[3]) or 0
    local weather, h
    if not preset then
        TriggerClientEvent('QBCore:Notify', source, '用法: /freezeworld [night|snow|storm|clear|天气名] [时] [分]', 'error')
        return
    end
    local defaults = { night=23, snow=0, storm=22, clear=12, time=12 }
    if preset == 'night' or preset == 'snow' or preset == 'storm' or preset == 'clear' or preset == 'time' then
        weather = (preset == 'time') and nil or (preset == 'snow' and 'XMAS' or preset == 'storm' and 'THUNDER' or 'CLEAR')
        h = (hour ~= nil) and hour or defaults[preset]
    else
        weather = preset:upper()
        h = (hour ~= nil) and hour or 12
    end
    -- 冻结服务端
    if weather then CurrentWeather = weather end
    Config.DynamicWeather = false
    gameMinutes = h * 60 + minute
    frozen = true
    timerStart = GetGameTimer()
    -- 广播冻结
    TriggerClientEvent('qb-weathersync:client:freezeWorld', -1, weather, h, minute)
    TriggerEvent('qb-weathersync:server:RequestStateSync')
    local desc = weather and ('%s %02d:%02d'):format(weather, h, minute) or ('%02d:%02d'):format(h, minute)
    if source > 0 then TriggerClientEvent('QBCore:Notify', source, '🌍 全服已冻结: ' .. desc, 'success') end
    print(('[weathersync] 🌍 freezeWorld by %s (ALL): %s'):format(GetPlayerName(source), desc))
end, 'admin')

QBCore.Commands.Add('unfreezeworld', '恢复全服天气和时间同步', {}, false, function(source)
    frozen = false
    Config.DynamicWeather = true
    timerStart = GetGameTimer()
    TriggerClientEvent('qb-weathersync:client:unfreezeWorld', -1)
    TriggerEvent('qb-weathersync:server:RequestStateSync')
    if source > 0 then TriggerClientEvent('QBCore:Notify', source, '🌍 全服同步已恢复', 'success') end
    print('[weathersync] 🌍 unfreezeWorld: all clients restored')
end, 'admin')

-- ============================================================
--  定时器
-- ============================================================

-- 60 秒校时广播 + 漂移修正
CreateThread(function()
    while true do
        Wait(60000)
        if not frozen then
            local realMinutes = math.floor(os.time(os.date("!*t")) / 2 + 360) % 1440
            -- 漂移修正：如果独立推进与真实时间相差超过 1 分钟，对齐
            local cur = getCurrentGameMinutes()
            if math.abs(cur - realMinutes) > 1 then
                gameMinutes = realMinutes
                timerStart = GetGameTimer()
            end
        end
        -- 广播当前状态供客户端对表
        TriggerEvent('qb-weathersync:server:RequestStateSync')
    end
end)

-- 5 分钟天气广播
CreateThread(function()
    while true do
        Wait(300000)
        TriggerClientEvent('qb-weathersync:client:SyncWeather', -1, CurrentWeather, blackout)
    end
end)

-- 天气 timer
CreateThread(function()
    while true do
        newWeatherTimer = newWeatherTimer - 1
        Wait((1000 * 60) * Config.NewWeatherTimer)
        if newWeatherTimer == 0 then
            if Config.DynamicWeather then nextWeatherStage() end
            newWeatherTimer = Config.NewWeatherTimer
        end
    end
end)

-- ============================================================
--  玩家加入：单播当前状态（不需要等下次校时广播）
-- ============================================================
RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
    local src = source
    Wait(2000)  -- 等客户端初始化
    local cur = getCurrentGameMinutes()
    TriggerClientEvent('qb-weathersync:client:SyncWeather', src, CurrentWeather, blackout)
    TriggerClientEvent('qb-weathersync:client:SyncTime', src, cur, frozen)
end)

-- ============================================================
--  Exports（保留所有原有接口，行为不变）
-- ============================================================
exports('nextWeatherStage', nextWeatherStage)
exports('setWeather', setWeather)
exports('setTime', setTime)
exports('setBlackout', setBlackout)
exports('setTimeFreeze', setTimeFreeze)
exports('setDynamicWeather', setDynamicWeather)
exports('getBlackoutState', function() return blackout end)
exports('getTimeFreezeState', function() return frozen end)
exports('getWeatherState', function() return CurrentWeather end)
exports('getDynamicWeather', function() return Config.DynamicWeather end)
exports('getTime', function()
    local cur = getCurrentGameMinutes()
    local hour = math.floor(cur / 60) % 24
    local minute = cur % 60
    return hour, minute
end)
