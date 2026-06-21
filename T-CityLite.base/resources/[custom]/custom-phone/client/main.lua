local QBCore = exports['qb-core']:GetCoreObject()
local isPhoneOpen = false

-- Open Phone Function
local function OpenPhone()
    if isPhoneOpen then return end
    isPhoneOpen = true
    SetNuiFocus(true, true)
    
    -- Play GTA V native phone-out animation
    local ped = PlayerPedId()
    if DoesEntityExist(ped) then
        RequestAnimDict('cellphone@')
        while not HasAnimDictLoaded('cellphone@') do Wait(0) end
        TaskPlayAnim(ped, 'cellphone@', 'cellphone_text_in', 8.0, -8.0, 800, 49, 0, false, false, false)
    end
    
    -- Tell NUI to open phone
    SendNUIMessage({
        action = 'phone:open'
    })
    
    -- Trigger open thread for zero tick overhead when closed
    -- 天气映射表（qb-weathersync 字符串名 → 显示名+图标）
    local weatherMap = {
        EXTRASUNNY = { icon = "☀️", label = "晴" },
        CLEAR      = { icon = "🌤️", label = "晴" },
        NEUTRAL    = { icon = "🌥️", label = "阴" },
        SMOG       = { icon = "🌫️", label = "雾" },
        FOGGY      = { icon = "🌫️", label = "雾" },
        OVERCAST   = { icon = "☁️", label = "阴" },
        CLOUDS     = { icon = "☁️", label = "多云" },
        CLEARING   = { icon = "⛅", label = "转晴" },
        RAIN       = { icon = "🌧️", label = "雨" },
        THUNDER    = { icon = "⛈️", label = "雷" },
        SNOW       = { icon = "❄️", label = "雪" },
        BLIZZARD   = { icon = "🌨️", label = "暴雪" },
        SNOWLIGHT  = { icon = "🌨️", label = "小雪" },
        XMAS       = { icon = "🎄", label = "圣诞" },
        HALLOWEEN  = { icon = "🎃", label = "万圣" },
    }
    -- 本地日期（用 FiveM 原生 GetLocalTime，不依赖 os 库）
    local dayNames = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
    local monthNames = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }
    local function getLocalDate()
        local yr, mo, dy = GetLocalTime()
        return dayNames[GetClockDayOfWeek() + 1], monthNames[mo] .. ' ' .. dy
    end
    -- 优先用 qb-weathersync 的 export，降级用 GetWeatherTypeTransition
    local function getWeatherInfo()
        local name
        local ok = pcall(function() name = exports['qb-weathersync']:getWeatherState() end)
        if not ok or not name then
            local hash = GetWeatherTypeTransition()
            local fallback = { [916995460]="CLEAR", [-1148613331]="OVERCAST", [1420204096]="RAIN", [-1233681761]="THUNDER", [-273223690]="SNOW" }
            name = fallback[hash] or "EXTRASUNNY"
        end
        local info = weatherMap[name]
        if info then return info.icon, info.label end
        return "🌤️", "晴"
    end
    local timeTick = 0
    CreateThread(function()
        -- 打开手机时立即发送一次时间+天气
        local h = GetClockHours(); local m = GetClockMinutes()
        local wIcon, wLabel = getWeatherInfo()
        local dName, dDate = getLocalDate()
        -- [debug] 打印手机读取的时间
        print(('[phone] GameTime=%02d:%02d, Weather=%s, Date=%s'):format(h, m, wLabel, dDate))
        SendNUIMessage({ action = 'phone:updateTime', hour = h, minute = m,
            dayName = dName, date = dDate,
            weatherIcon = wIcon, weatherLabel = wLabel })

        while isPhoneOpen do
            -- Keep phone animation looping after entry
            if not IsEntityPlayingAnim(GetPlayerPed(-1), 'cellphone@', 'cellphone_text_read_base', 3) then
                TaskPlayAnim(GetPlayerPed(-1), 'cellphone@', 'cellphone_text_read_base', 8.0, -8.0, -1, 49, 0, false, false, false)
            end
            -- While phone is open, disable standard game control keys that interfere with UI typing
            -- NOTE: Do NOT disable INPUT_CHAT (T key/245) so players can still chat
            DisableControlAction(0, 1, true) -- LookLeftRight
            DisableControlAction(0, 2, true) -- LookUpDown
            DisableControlAction(0, 24, true) -- Attack
            DisableControlAction(0, 257, true) -- Attack 2
            DisableControlAction(0, 25, true) -- Aim
            DisableControlAction(0, 263, true) -- Melee Attack 1
            DisableControlAction(0, 37, true) -- Select Weapon
            DisableControlAction(0, 44, true) -- Cover
            DisableControlAction(0, 140, true) -- Light Attack
            DisableControlAction(0, 141, true) -- Heavy Attack
            DisableControlAction(0, 142, true) -- Melee Attack Alternate

            -- 每 2 秒同步一次游戏内时间（减少 SendNUIMessage 频率）
            timeTick = timeTick + 1
            if timeTick >= 120 then
                timeTick = 0
                local h = GetClockHours(); local m = GetClockMinutes()
                local wIcon, wLabel = getWeatherInfo()
                local dName, dDate = getLocalDate()
                SendNUIMessage({
                    action = 'phone:updateTime',
                    hour = h, minute = m,
                    dayName = dName, date = dDate,
                    weatherIcon = wIcon, weatherLabel = wLabel
                })
            end
            Wait(0)
        end
        -- Clear animation when phone closes
        ClearPedTasks(GetPlayerPed(-1))
    end)
end

-- Close Phone Function
local function ClosePhone()
    if not isPhoneOpen then return end
    isPhoneOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({
        action = 'phone:close'
    })
    -- Stop phone animation
    local ped = GetPlayerPed(-1)
    if DoesEntityExist(ped) then
        StopAnimTask(ped, 'cellphone@', 'cellphone_text_read_base', 1.0)
        ClearPedTasks(ped)
    end
end

-- Command & Keybind to toggle phone
RegisterCommand('phone', function()
    if isPhoneOpen then
        ClosePhone()
    else
        OpenPhone()
    end
end, false)


-- Register key binding on resource start
AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    RegisterKeyMapping('phone', 'Open Mobile Phone', 'keyboard', Config.OpenKey)
end)

-- ----------------------------------------------------
-- NUI Callbacks
-- ----------------------------------------------------
RegisterNUICallback('closePhone', function(_, cb)
    ClosePhone()
    cb({ success = true })
end)

RegisterNUICallback('getPhoneData', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getPhoneData', function(data)
        cb(data)
    end)
end)

-- Contact CRUD Callbacks
RegisterNUICallback('addContact', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:addContact', function(res)
        cb(res)
    end, data.name, data.number)
end)

RegisterNUICallback('deleteContact', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:deleteContact', function(res)
        cb(res)
    end, data.id)
end)

-- SMS Callbacks
RegisterNUICallback('sendMessage', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:sendMessage', function(res)
        cb(res)
    end, data.receiver_number, data.message)
end)

RegisterNUICallback('markMessagesRead', function(data, cb)
    TriggerServerEvent('phone:server:markMessagesRead', data.sender_number)
    cb({ success = true })
end)

-- Notification Tray Callbacks (Transient UI Store syncing)
RegisterNUICallback('markNotificationsRead', function(_, cb)
    cb({ success = true })
end)

RegisterNUICallback('clearNotifications', function(_, cb)
    cb({ success = true })
end)

RegisterNUICallback('deleteNotification', function(data, cb)
    cb({ success = true })
end)

-- Banking Callbacks (Wire Transfer & Secure Fallbacks)
RegisterNUICallback('bankTransfer', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:bankTransfer', function(res)
        cb(res)
    end, data.toPhoneNumber, data.amount, data.reason)
end)

RegisterNUICallback('bankDeposit', function(_, cb)
    cb({ success = false, message = 'Mobile deposits are disabled. Please use a physical ATM or bank teller.' })
end)

RegisterNUICallback('bankWithdraw', function(_, cb)
    cb({ success = false, message = 'Mobile withdrawals are disabled. Please use a physical ATM or bank teller.' })
end)

-- GPS 导航按钮回调（手机短信里的 📍 按钮）
RegisterNUICallback('setGpsRoute', function(data, cb)
    if data and data.x then
        -- 从 LocalPlayer.state 读取当前活跃任务坐标（可靠跨帧存储）
        local refX = LocalPlayer.state.activeGpsX
        local refY = LocalPlayer.state.activeGpsY
        if not refX then
            QBCore.Functions.Notify('⚠️ 当前无活跃任务，无法导航', 'error', 4000)
            cb({ success = false, message = '无活跃任务' })
            return
        end
        local dist = #(vector2(data.x + 0.0, data.y + 0.0) - vector2(refX + 0.0, refY + 0.0))
        if dist > 10.0 then
            QBCore.Functions.Notify(('⚠️ 非本次任务地点（偏差 %.0fm），请确认当前任务'):format(dist), 'error', 4000)
            cb({ success = false, message = '非本次任务地点' })
            return
        end
        SetNewWaypoint(data.x + 0.0, data.y + 0.0)
        QBCore.Functions.Notify(('📍 导航已设置: %s'):format(data.label or '目的地'), 'success', 3000)
    end
    cb({ success = true })
end)

-- v0.4.2 Premium features NUI Callbacks
RegisterNUICallback('getNearbyPlayers', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getNearbyPlayers', function(res)
        cb(res)
    end)
end)

RegisterNUICallback('shareContactNearby', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:shareContactNearby', function(res)
        cb(res)
    end, data.targetId, data.name, data.number)
end)

RegisterNUICallback('getOwnedVehicles', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getOwnedVehicles', function(res)
        cb(res)
    end)
end)

RegisterNUICallback('getHotlineStatus', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:getHotlineStatus', function(res)
        cb(res)
    end, data.jobType)
end)

RegisterNUICallback('triggerHotlineCall', function(data, cb)
    if data.jobType == 'surrender' then
        -- 自首热线: 直接触发自首, 不走普通热线
        TriggerServerEvent('qb-storerobbery:server:surrender')
        cb({ success = true, active = false, message = 'Surrender request submitted.' })
    else
        QBCore.Functions.TriggerCallback('phone:server:triggerHotlineCall', function(res)
            cb(res)
        end, data.jobType)
    end
end)

RegisterNUICallback('queryAutomatedIvr', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:queryAutomatedIvr', function(res)
        cb(res)
    end, data.actionType)
end)

-- Job Board Callbacks
RegisterNUICallback('acceptJobBoardTask', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:acceptJob', function(res)
        cb(res)
    end, data.id)
end)

RegisterNUICallback('postJobBoardTask', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:postJob', function(res)
        cb(res)
    end, data.title, data.description, data.reward)
end)

-- Faction messages callback
RegisterNUICallback('sendFactionMessage', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:sendFactionMessage', function(res)
        cb(res)
    end, data.content)
end)

-- Sheriff specific callback
RegisterNUICallback('sendSheriffPatrolOrder', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:sendSheriffPatrol', function(res)
        cb(res)
    end, data.zone, data.details)
end)

-- Gang Boss specific callback
RegisterNUICallback('sendGangObjective', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:sendGangObjective', function(res)
        cb(res)
    end, data.objective, data.quota)
end)

-- CityFeed Callbacks
RegisterNUICallback('getCityFeed', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getCityFeed', function(res)
        cb(res)
    end)
end)

RegisterNUICallback('postCityFeed', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:postCityFeed', function(res)
        cb(res)
    end, data.content)
end)

RegisterNUICallback('likeCityFeed', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:likeCityFeed', function(res)
        cb(res)
    end, data.id)
end)

-- ----------------------------------------------------
-- Server Events → Client UI push
-- ----------------------------------------------------
RegisterNetEvent('phone:client:newMessage', function(msg)
    -- 纯文本消息直接转发 NUI（GPS 消息走 phone:client:gpsMessage）
    SendNUIMessage({
        action = 'phone:newMessage',
        message = msg
    })
end)

RegisterNetEvent('phone:client:newNotification', function(notif)
    SendNUIMessage({
        action = 'phone:newNotification',
        notification = notif
    })
end)

RegisterNetEvent('phone:client:newJob', function(job)
    SendNUIMessage({
        action = 'phone:jobboard:newJob',
        job = job
    })
end)

RegisterNetEvent('phone:client:factionReceive', function(msg)
    SendNUIMessage({
        action = 'phone:faction:receive',
        message = msg
    })
end)

-- ============================================================
-- 📍 统一 GPS 导航总线 — 全服所有系统共用此入口
-- ============================================================
-- 调用方式（任意服务端资源）:
--   TriggerClientEvent('phone:client:routeGps', source, vector3(x,y,z), '目的地名')
--   TriggerClientEvent('phone:client:gpsMessage', source, { gps={x,y,label}, status='active', ttl=300 })
--
-- 支持场景:
--   • 毒品送货任务 → 地图标点 + 手机短信
--   • Job Board 接单 → 自动导航到任务点
--   • 警察巡逻调度 → 导航到巡逻区域
--   • 车库取车 → 导航到最近车库
--   • 热线服务 → 导航到最近服务点
--   • 玩家广告 → 可点击的地址链接
-- ============================================================

local activeGps = nil   -- { x, y, label, expiresAt }

-- 清除当前 GPS 导航点
local function ClearGps()
    SetWaypointOff()  -- 正确清除路点，而非在(0,0)创建
    activeGps = nil
    LocalPlayer.state:set('activeGpsX', nil, false)
    LocalPlayer.state:set('activeGpsY', nil, false)
    LocalPlayer.state:set('activeGpsLabel', nil, false)
end

-- 统一 GPS 路由（直接设置导航点，无消息）
RegisterNetEvent('phone:client:routeGps', function(coords, label)
    if not coords or not coords.x then return end
    SetNewWaypoint(coords.x, coords.y)
    activeGps = { x = coords.x, y = coords.y, label = label or '目的地' }
    LocalPlayer.state:set('activeGpsX', coords.x, false)
    LocalPlayer.state:set('activeGpsY', coords.y, false)
    LocalPlayer.state:set('activeGpsLabel', label or '目的地', false)
    QBCore.Functions.Notify(('📍 GPS 导航已激活: %s'):format(label or '目的地'), 'success', 3000)
end)

-- GPS 消息路由（手机短信 + 导航，支持激活/完成状态切换）
RegisterNetEvent('phone:client:gpsMessage', function(msg)
    if not msg then return end

    if msg.gps and msg.gps.x and msg.status == 'active' then
        activeGps = {
            x = msg.gps.x,
            y = msg.gps.y,
            label = msg.gps.label or '目的地',
            expiresAt = msg.ttl and (os.time() + msg.ttl)
        }
        LocalPlayer.state:set('activeGpsX', msg.gps.x, false)
        LocalPlayer.state:set('activeGpsY', msg.gps.y, false)
        LocalPlayer.state:set('activeGpsLabel', msg.gps.label or '目的地', false)
        pcall(SetNewWaypoint, msg.gps.x, msg.gps.y)
        pcall(QBCore.Functions.Notify, ('📍 GPS 已设置: %s'):format(msg.gps.label or '目的地'), 'success', 3000)
    end

    if msg.status == 'done' or msg.status == 'expired' then
        local shouldClear = false
        if not activeGps then
            shouldClear = true
        elseif msg.gps and msg.gps.x then
            local d = #(vector2(msg.gps.x + 0.0, msg.gps.y + 0.0) - vector2(activeGps.x, activeGps.y))
            shouldClear = (d < 10.0)
        end
        if shouldClear then
            LocalPlayer.state:set('activeGpsX', nil, false)
            LocalPlayer.state:set('activeGpsY', nil, false)
            LocalPlayer.state:set('activeGpsLabel', nil, false)
            ClearGps()
            QBCore.Functions.Notify('📍 任务已完成，GPS 导航已清除', 'primary', 2000)
        end
    end

    SendNUIMessage({
        action = 'phone:newMessage',
        message = msg
    })
end)

-- 定时清理过期 GPS 导航（后台线程）
CreateThread(function()
    while true do
        Wait(15000)  -- 每 15 秒检查
        if activeGps and activeGps.expiresAt and os.time() > activeGps.expiresAt then
            ClearGps()
        end
    end
end)

-- Dynamic Leader app unlocking
local function CheckLeaderApp()
    local success, identity = pcall(function()
        return exports['custom-career']:GetLocalIdentity()
    end)
    if success and identity then
        if identity.rank_tier == 'leader' then
            SendNUIMessage({
                action = 'phone:registerLeaderApp',
                role = identity.primary_role
            })
        else
            SendNUIMessage({
                action = 'phone:removeLeaderApp'
            })
        end
    end
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    Wait(2000)
    CheckLeaderApp()
end)

RegisterNetEvent('custom-career:client:tierChanged', function(newTier)
    CheckLeaderApp()
end)

-- Real-time Money Sync Listener
RegisterNetEvent('QBCore:Client:OnMoneyChange', function(type, amount, operation)
    if not isPhoneOpen then return end
    QBCore.Functions.TriggerCallback('phone:server:getPhoneData', function(data)
        if data and data.success then
            SendNUIMessage({
                action = 'phone:updateMoney',
                money = data.playerData.money
            })
        end
    end)
end)

RegisterNetEvent('QBCore:Client:SetPlayerData', function(val)
    if not isPhoneOpen or not val or not val.money then return end
    SendNUIMessage({
        action = 'phone:updateMoney',
        money = val.money
    })
end)

-- ----------------------------------------------------
-- Job Board Waypoint Distance Tracker (按需激活，完成即停)
-- ----------------------------------------------------
local activeJobId = nil
local activeJobCoords = nil

RegisterNetEvent('phone:client:trackJobArrival', function(id, coords)
    activeJobId = id
    activeJobCoords = coords

    -- 按需创建专属追踪线程（不再污染全局常驻线程）
    CreateThread(function()
        while activeJobId == id and activeJobCoords do
            Wait(1000)
            local ped = PlayerPedId()
            local pCoords = GetEntityCoords(ped)
            local dist = #(pCoords - activeJobCoords)
            if dist < 8.0 then
                TriggerServerEvent('phone:server:completeJob', id)
                if activeJobId == id then
                    activeJobId = nil
                    activeJobCoords = nil
                end
                break -- 线程自我退出
            end
        end
    end)
end)
