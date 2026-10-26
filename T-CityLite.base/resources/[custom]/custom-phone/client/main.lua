-- client/main.lua — wiring only. NUI registration/request_id timeouts live in
-- client/core/bridge.lua, focus ownership in client/core/focus.lua and the
-- unified phone:client:event channel in client/core/events.lua. The manifest
-- must load those three before this file.
local QBCore = exports['qb-core']:GetCoreObject()
local isPhoneOpen = false

-- A resource (re)start is also the recovery path when a previous client left
-- NUI focus/cursor stuck: never inherit that state.
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    PhoneFocus.Reset()
end)

-- Additive unified event channel; the legacy phone:client:* handlers below stay
-- registered unchanged during the migration.
PhoneEvents.Start()

-- Close Phone Function (must be defined before OpenPhone — CreateThread closure)
local function ClosePhone()
    if not isPhoneOpen then return end
    isPhoneOpen = false
    TriggerServerEvent('phone:server:focusState', { phase = 'close-start' })
    -- custom-ui owns the phone menu/focus by default. When another focus owner
    -- (fingerprint/story/vehicle) is on top, closing the phone must not clear
    -- that UI's focus; just pop the phone from the stack below it.
    local owner = PhoneFocus.State().owner
    if owner == nil or owner == 'phone' then
        pcall(function() exports['custom-ui']:CloseMenu() end)
    end
    -- Release drops NUI focus even when custom-ui.CloseMenu is missing or
    -- throws. It deliberately leaves keepInput for the next phone open: the
    -- project's real-client contract is qb-phone style (see AGENTS.md).
    PhoneBridge.Ack('phone:open') -- stop any open-ack resend loop
    PhoneFocus.Release('phone')
    SendNUIMessage({
        action = 'phone:close'
    })
    -- Verify the release actually stuck; if any resource re-grabbed focus in
    -- the same frame, clear the leak and report the state. A different focus
    -- owner is left alone: it may legitimately have opened on top of the phone.
    CreateThread(function()
        Wait(80)
        local focus = PhoneFocus.State()
        if focus.owner == nil and IsNuiFocused() then
            PhoneFocus.Reset()
            focus = PhoneFocus.State()
        end
        TriggerServerEvent('phone:server:focusState', {
            phase = 'close',
            focused = IsNuiFocused(),
            keepInput = IsNuiFocusKeepingInput(),
            owner = focus.owner or 'none',
        })
    end)
    -- Stop phone animation
    local ped = GetPlayerPed(-1)
    if DoesEntityExist(ped) then
        StopAnimTask(ped, 'cellphone@', 'cellphone_text_read_base', 1.0)
        ClearPedTasks(ped)
    end
end

-- Open Phone Function
local function OpenPhone()
    if isPhoneOpen then return end
    isPhoneOpen = true
    -- SendNUIMessage is fire-and-forget: while CEF is still loading (every
    -- `restart custom-phone`) the frame is dropped and the phone stays "open"
    -- in Lua with nothing on screen. Resend until the NUI acknowledges the
    -- open, which is the only proof the interface exists.
    PhoneBridge.AwaitAck('phone:open', function()
        SendNUIMessage({
            action = 'phone:open'
        })
    end, {
        intervalMs = 250,
        timeoutMs = 2500,
        onTimeout = function()
            -- The UI never answered: drop the half-open state so the next key
            -- press starts clean instead of being swallowed by isPhoneOpen.
            isPhoneOpen = false
            PhoneFocus.Release('phone')
            TriggerServerEvent('phone:server:focusState', { phase = 'open-ack-timeout' })
            TriggerEvent('chat:addMessage', {
                args = { 'SYSTEM', '手机界面没有响应（NUI 未就绪），状态已重置，请再按一次 M' }
            })
        end,
    })
    TriggerServerEvent('phone:server:focusState', { phase = 'open-nui-sent', focused = IsNuiFocused() })

    -- Cursor first: keepInput=true left the mouse bound to camera look on a
    -- real client (NUI focused, no usable cursor). Menus that need movement
    -- can opt in later, but a phone must be clickable.
    -- qb-phone never turns keepInput off, so movement survives while the phone
    -- is open. The focus stack grants focus, then explicitly keeps game input.
    PhoneFocus.Acquire('phone', { cursor = true, keepInput = true })
    TriggerServerEvent('phone:server:focusState', { phase = 'open-start' })

    CreateThread(function()
        local ped = PlayerPedId()
        if not DoesEntityExist(ped) then return end
        RequestAnimDict('cellphone@')
        local loaded = false
        for _ = 1, 50 do
            if HasAnimDictLoaded('cellphone@') then loaded = true break end
            Wait(10)
        end
        if not loaded then
            TriggerServerEvent('phone:server:focusState', { phase = 'anim-timeout' })
            return
        end
        if isPhoneOpen then
            TaskPlayAnim(ped, 'cellphone@', 'cellphone_text_in', 8.0, -8.0, 800, 49, 0, false, false, false)
        end
    end)
    
    -- Focus watchdog: if something steals NUI focus, re-apply it instead of
    -- leaving the phone visible with the mouse still driving the camera.
    CreateThread(function()
        for attempt = 1, 5 do
            Wait(attempt == 1 and 50 or 150)
            if not isPhoneOpen then return end
            -- Another owner (fingerprint/story/vehicle) may legitimately sit on
            -- top of the stack. Do not steal focus from it; when it releases,
            -- the stack re-applies the phone automatically.
            if not PhoneFocus.IsOwner('phone') then return end
            -- Re-assert the cursor flag every time, not only when focus is
            -- reported lost: focused=true with no cursor is the failure we saw.
            PhoneFocus.Acquire('phone', { cursor = true, keepInput = true })
            TriggerServerEvent('phone:server:focusState', {
                phase = 'reassert', attempt = attempt,
                focused = IsNuiFocused(),
                keepInput = IsNuiFocusKeepingInput(),
            })
        end
    end)

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
        local lastHour, lastMinute = h, m

        while isPhoneOpen do
            -- Keep phone animation looping after entry
            if not IsEntityPlayingAnim(GetPlayerPed(-1), 'cellphone@', 'cellphone_text_read_base', 3) then
                TaskPlayAnim(GetPlayerPed(-1), 'cellphone@', 'cellphone_text_read_base', 8.0, -8.0, -1, 49, 0, false, false, false)
            end
            -- This native is not present in every FXServer build (it threw
            -- "attempt to call a nil value" and killed the phone loop on a real
            -- client). Keep the effect only when it exists.
            if DisableDisplayControlActions then DisableDisplayControlActions() end
            -- While phone is open, disable standard game control keys that interfere with UI typing
            -- NOTE: Do NOT disable INPUT_CHAT (T key/245) so players can still chat
            -- qb-phone disables 1-6 (look), not movement 30-35.
            DisableControlAction(0, 1, true) -- LookLeftRight
            DisableControlAction(0, 2, true) -- LookUpDown
            DisableControlAction(0, 3, true)
            DisableControlAction(0, 4, true)
            DisableControlAction(0, 5, true)
            DisableControlAction(0, 6, true)
            DisableControlAction(0, 24, true) -- Attack
            DisableControlAction(0, 257, true) -- Attack 2
            DisableControlAction(0, 25, true) -- Aim
            DisableControlAction(0, 263, true) -- Melee Attack 1
            DisableControlAction(0, 37, true) -- Select Weapon
            DisableControlAction(0, 14, true) -- Weapon wheel next (mouse scroll)
            DisableControlAction(0, 15, true) -- Weapon wheel prev (mouse scroll)
            DisableControlAction(0, 16, true) -- Select next weapon
            DisableControlAction(0, 17, true) -- Select prev weapon
            DisableControlAction(0, 81, true) -- Vehicle radio wheel
            DisableControlAction(0, 82, true) -- Next radio station
            DisableControlAction(0, 83, true) -- Prev radio station
            DisableControlAction(0, 44, true) -- Cover
            DisableControlAction(0, 140, true) -- Light Attack
            DisableControlAction(0, 141, true) -- Heavy Attack
            DisableControlAction(0, 142, true) -- Melee Attack Alternate

            -- ESC key closes phone — handled by NUI JS (window keydown listener)
            -- Right mouse button closes phone (AIM input, already disabled above)
            if IsDisabledControlJustPressed(0, 25) then  -- INPUT_AIM
                ClosePhone()
            end

            -- 每 ~1 秒检查一次游戏内时间，但只在分钟真正变化时才推送，
            -- 避免每秒刷新 NUI store 触发状态栏/首页重渲染（审计 §2）
            timeTick = timeTick + 1
            if timeTick >= 60 then
                timeTick = 0
                local h = GetClockHours(); local m = GetClockMinutes()
                if h ~= lastHour or m ~= lastMinute then
                    lastHour, lastMinute = h, m
                    local wIcon, wLabel = getWeatherInfo()
                    local dName, dDate = getLocalDate()
                    SendNUIMessage({
                        action = 'phone:updateTime',
                        hour = h, minute = m,
                        dayName = dName, date = dDate,
                        weatherIcon = wIcon, weatherLabel = wLabel
                    })
                end
            end
            Wait(0)
        end
        -- Clear animation when phone closes
        ClearPedTasks(GetPlayerPed(-1))
        TriggerServerEvent('phone:server:focusState', { phase = 'loop-exit' })
    end)
end

-- Command & Keybind to toggle phone.
-- Recovery: if a previous open left isPhoneOpen=true without NUI focus (hung
-- anim/open), M should reset and reopen instead of being swallowed forever.
--
-- 防重复触发：一次按 M 实测会进来两次（RegisterKeyMapping 在资源重启时会再注册
-- 一次，同一次按键派发两条命令）。第二次进来时 isPhoneOpen 已经是 true 且
-- IsNuiFocused() 已为 true → 立刻 ClosePhone，表现就是"按 M 没反应"（界面被
-- 叫出来又秒关）。所以对 300ms 内的重复调用只处理第一次。
local TOGGLE_DEBOUNCE_MS = 300
local lastToggleAt = 0

RegisterCommand('phone', function()
    local now = GetGameTimer()
    if now - lastToggleAt < TOGGLE_DEBOUNCE_MS then
        TriggerServerEvent('phone:server:focusState', { phase = 'toggle-debounced', focused = IsNuiFocused() })
        return
    end
    lastToggleAt = now

    if isPhoneOpen then
        if IsNuiFocused() then
            ClosePhone()
        else
            isPhoneOpen = false
            PhoneFocus.Release('phone')
            Wait(50)
            OpenPhone()
        end
    else
        OpenPhone()
    end
end, false)

-- Manual recovery: release focus, reset state, close any stale NUI.
RegisterCommand('phonefix', function()
    isPhoneOpen = false
    PhoneFocus.Reset()
    SendNUIMessage({ action = 'phone:close' })
    TriggerEvent('chat:addMessage', { args = { 'SYSTEM', '手机状态已重置' } })
    TriggerServerEvent('phone:server:focusState', { phase = 'phonefix', focused = IsNuiFocused() })
end, false)


-- Register key binding on resource start
-- 只注册一次：资源重启会重跑本文件，重复 RegisterKeyMapping 会让同一次按键
-- 派发多条命令（命令入口的 300ms 防抖是最后一道保险）。
local keyMappingRegistered = false
AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if keyMappingRegistered then return end
    keyMappingRegistered = true
    RegisterKeyMapping('phone', 'Open Mobile Phone', 'keyboard', Config.OpenKey)
end)

-- ----------------------------------------------------
-- NUI Callbacks
-- ----------------------------------------------------
RegisterNUICallback('closePhone', function(_, cb)
    ClosePhone()
    cb({ success = true })
end)

-- The UI answers every phone:open with this callback once the frame is on
-- screen. PhoneBridge.AwaitAck stops resending on it; without the answer the
-- client resets the half-open state after 2.5 s instead of hanging.
RegisterNUICallback('phoneOpenAck', function(_, cb)
    if PhoneBridge.Ack('phone:open') then
        TriggerServerEvent('phone:server:focusState', { phase = 'open-ack', focused = IsNuiFocused() })
    end
    cb({ ok = true })
end)

-- Keyboard mode callbacks (no-op: always in SetNuiFocus(true,true) mode)
RegisterNUICallback('enableKeyboard', function(_, cb)
    cb({ success = true })
end)

RegisterNUICallback('disableKeyboard', function(_, cb)
    cb({ success = true })
end)

-- qb-core keeps ONE callback slot per name. Opening the phone, OnMoneyChange
-- and RemoveBankMoney can all request getPhoneData in the same frame; coalesce
-- them into a single in-flight request so none of the callers is overwritten.
local phoneDataBusy = false
local phoneDataWaiters = {}
local function fetchPhoneData(cb)
    phoneDataWaiters[#phoneDataWaiters + 1] = cb
    if phoneDataBusy then return end
    phoneDataBusy = true
    local settled = false
    local function finish(data)
        if settled then return end
        settled = true
        phoneDataBusy = false
        local waiters = phoneDataWaiters
        phoneDataWaiters = {}
        data = data or { success = false, error = 'no_response' }
        for _, waiter in ipairs(waiters) do
            pcall(waiter, data)
        end
    end
    QBCore.Functions.TriggerCallback('phone:server:getPhoneData', finish)
    -- NUI 侧 getPhoneData 的 abort 是 6s（NUI_TIMEOUT_MS）；这里的兜底必须更早，
    -- 否则前端只会看到 AbortError，拿不到结构化的 timeout。
    SetTimeout(4000, function()
        finish({ success = false, error = 'timeout' })
    end)
end

RegisterNUICallback('getPhoneData', function(_, cb)
    fetchPhoneData(function(data) cb(data) end)
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

-- Notification Tray Callbacks (DB-backed persistence)
RegisterNUICallback('markNotificationsRead', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:markNotificationsRead', function(res)
        cb(res)
    end)
end)

RegisterNUICallback('clearNotifications', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:clearNotifications', function(res)
        cb(res)
    end)
end)

RegisterNUICallback('deleteNotification', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:deleteNotification', function(res)
        cb(res)
    end, data.id)
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

RegisterNUICallback('getAllHotlineStatus', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getAllHotlineStatus', function(res)
        cb(res)
    end)
end)

-- Phone Call System Callbacks (real implementation)
RegisterNUICallback('initiateCall', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:initiateCall', function(res)
        cb(res)
    end, data.targetNumber)
end)

RegisterNUICallback('answerCall', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:answerCall', function(res)
        cb(res)
    end, data.callId)
end)

RegisterNUICallback('rejectCall', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:rejectCall', function(res)
        cb(res)
    end, data.callId)
end)

RegisterNUICallback('hangupCall', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:hangupCall', function(res)
        cb(res)
    end, data.callId)
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
    if not notif then return end
    -- 只做本地展示：服务端推送前已经在 StoreAndPushNotification 里落库。
    -- 这里曾把收到的通知回存服务端，会形成
    -- 服务端推送 → 客户端回存 → 服务端再推送 的无限回环（审计 B03）。
    -- 服务端发起的通知带 origin='server' / stored=true；即使没有标记也一律不回存。
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

-- Phone Call Events (real-time push from server)
RegisterNetEvent('phone:client:incomingCall', function(callData)
    -- 手机未打开（关闭/锁屏）时自动弹出，确保来电一定能被看到（审计 B04）
    if not isPhoneOpen then
        OpenPhone()
    end
    SendNUIMessage({
        action = 'phone:incomingCall',
        callData = callData
    })
end)

RegisterNetEvent('phone:client:callAnswered', function(data)
    SendNUIMessage({
        action = 'phone:callAnswered',
        callId = data.callId
    })
end)

RegisterNetEvent('phone:client:callEnded', function(data)
    SendNUIMessage({
        action = 'phone:callEnded',
        callId = data.callId,
        status = data.status
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
    fetchPhoneData(function(data)
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

-- Dev diagnostic: probe whether NUI focus survives for 2s without opening
-- any phone UI. /focusprobe → server log lines phase=probe.
RegisterCommand('focusprobe', function()
    SetNuiFocus(false, false)
    Wait(100)
    SetNuiFocus(true, true)
    TriggerServerEvent('phone:server:focusState', {
        phase = 'probe-start', focused = IsNuiFocused(),
        keepInput = IsNuiFocusKeepingInput(),
    })
    CreateThread(function()
        for i = 1, 20 do
            Wait(100)
            TriggerServerEvent('phone:server:focusState', {
                phase = 'probe', attempt = i, focused = IsNuiFocused(),
                keepInput = IsNuiFocusKeepingInput(),
            })
        end
        -- Always release, otherwise the probe leaves the game without input.
        PhoneFocus.Reset()
        TriggerServerEvent('phone:server:focusState', { phase = 'probe-end', focused = IsNuiFocused() })
    end)
end, false)

-- Never leave the game focused/cursor-locked if the resource stops while the
-- phone (or a probe) still holds NUI focus.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    PhoneFocus.Reset()
    -- Defensive: even if client/core/focus.lua somehow failed to load, the
    -- engine flags must be cleared. Reset already records this state.
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
end)

-- onResourceStop is the server-side event; the client also has its own stop
-- notification, so cover both without duplicating the defensive natives.
AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    PhoneFocus.Reset()
end)


-- ----------------------------------------------------
-- NUI bridges that used to live in client/call_history.lua
-- ----------------------------------------------------
-- That extra client script is not reliably loaded on this server (its NUI
-- callbacks and net events never registered), so the bridges live in the file
-- that is known to run. call_history.lua is removed from the manifest.
RegisterNUICallback('getCallHistory', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getCallHistory', function(res)
        cb(res or { success = false, calls = {} })
    end)
end)

RegisterNUICallback('getMessages', function(data, cb)
    QBCore.Functions.TriggerCallback('phone:server:getMessages', function(res)
        cb(res or { success = false, messages = {}, next_before_id = nil })
    end, data)
end)

RegisterNetEvent('phone:client:systemSpeech', function(data)
    if type(data) ~= 'table' or type(data.text) ~= 'string' then return end
    SendNUIMessage({
        action = 'phone:systemSpeech',
        callId = data.callId,
        text = data.text:sub(1, 300),
    })
end)

-- ----------------------------------------------------
-- qb-phone compatibility bridge (see server/qb_phone_compat.lua)
-- ----------------------------------------------------
-- qb-core/server/services/economy_service.lua fires this after a bank
-- removal. The amount is ignored on purpose: the UI refreshes from the
-- authoritative server balance instead of trusting a client-delivered number,
-- and nothing here changes money.
RegisterNetEvent('qb-phone:client:RemoveBankMoney', function()
    if not isPhoneOpen then return end
    fetchPhoneData(function(data)
        if data and data.success and data.playerData then
            SendNUIMessage({
                action = 'phone:updateMoney',
                money = data.playerData.money
            })
        end
    end)
end)

-- qb-policejob / qb-stolen-radar / qb-prison / qb-storerobbery broadcast
-- police alerts to the phone. They are transient, so they are shown in the
-- tray without a per-recipient DB write (qb-phone did not persist them
-- either). No coords are auto-routed: the source resources already fire their
-- own police:client:policeAlert/GPS path.
local qbPoliceAlertSeq = 0
RegisterNetEvent('qb-phone:client:addPoliceAlert', function(alertData)
    if type(alertData) ~= 'table' then return end

    -- qb-storerobbery broadcasts to -1; qb-phone's own client handler dropped
    -- the alert unless the local player was an on-duty cop. The tray is
    -- visible to everyone here, so keep that gate (LEO only).
    local playerData = QBCore.Functions.GetPlayerData()
    local job = playerData and playerData.job
    if not job or not job.onduty then return end
    if job.type ~= 'leo' and job.name ~= 'police' then return end

    local title = type(alertData.title) == 'string' and alertData.title or ''
    local description = type(alertData.description) == 'string' and alertData.description or ''
    -- Plain text only: the tray renders text, not markup or coordinates.
    title = title:gsub('[%c]', ' '):sub(1, 200)
    description = description:gsub('[%c]', ' '):sub(1, 1000)
    if not title:match('%S') then title = '🚨 Police Alert' end

    -- Negative ids never collide with phone_notifications.id (positive), so
    -- the keyed Svelte each-loop can hold DB rows and transient alerts at once.
    qbPoliceAlertSeq = qbPoliceAlertSeq + 1
    SendNUIMessage({
        action = 'phone:newNotification',
        notification = {
            id = -qbPoliceAlertSeq,
            title = title,
            content = description,
            timestamp = os.date('%Y-%m-%d %H:%M:%S'),
            is_read = false,
            origin = 'compat',
        }
    })
end)


-- ----------------------------------------------------
-- Job app registry bridges
-- ----------------------------------------------------
RegisterNUICallback('getPhoneApps', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getPhoneApps', function(res)
        cb(res or { success = false, apps = {} })
    end)
end)

-- NUI 自证握手：页面加载时报告 build id 与宿主名（见 web/src/main.ts）。
-- 服务端有这条日志 = 页面跑的是新 bundle 且 NUI→Lua 路由通。
RegisterNUICallback('nuiReady', function(data, cb)
    TriggerServerEvent('phone:server:nuiReady', data)
    cb({ ok = true })
end)

-- 四段探针结果：页面用真实 appQuery 走完整条链路后回报终态码。
RegisterNUICallback('nuiProbe', function(data, cb)
    TriggerServerEvent('phone:server:nuiProbe', data)
    cb({ ok = true })
end)

-- qb-core stores exactly ONE pending callback per callback name
-- (QBCore.ServerCallbacks[name]) and the response clears it, so two concurrent
-- appQuery calls — PoliceMDT refresh() does Promise.all([units, incidents]) —
-- overwrite each other and the first NUI fetch never resolves. The dedicated
-- request/response event pair with a client-generated request_id now lives in
-- client/core/bridge.lua; only these two app readers stay here. The legacy
-- QBCore callbacks stay registered server-side for other callers.
-- [phone-app-readers] begin (extracted by test_phone_request_protocol.py)
-- 诊断挂钩是可选依赖：diag 模块不存在时（单元测试里的裸 bridge、老客户端）
-- 这些函数退化成 nil / no-op，读请求的行为与之前逐字节等价。
local function startRequestTrace(payload, kind)
    local diag = PhoneDiag
    if type(diag) ~= 'table' then return nil end
    local tid = diag.TakeTraceId(payload) or diag.NewTraceId()
    local trace = diag.StartTrace(tid, kind, type(payload) == 'table' and payload.app_id or nil)
    diag.Phase(trace, 'req.cli.recv')
    diag.Phase(trace, 'req.cli.fwd')
    return trace
end

local function finishRequestTrace(trace, res)
    if not trace then return end
    local diag = PhoneDiag
    if type(diag) ~= 'table' then return end
    local code = 'no_response'
    if type(res) == 'table' then code = res.error or 'ok' end
    diag.Phase(trace, 'req.cli.answer', code)
    diag.Finish(trace, code, { answered = type(res) == 'table' })
end

PhoneBridge.RegisterNui('appQuery', function(data, cb)
    if type(data) ~= 'table' then return cb({ success = false, error = 'bad_request' }) end
    local trace = startRequestTrace(data, 'query')
    PhoneBridge.Request('phone:server:appQueryRequest', data, function(res)
        finishRequestTrace(trace, res)
        cb(res)
    end, nil, nil, trace)
end)

PhoneBridge.RegisterNui('appAction', function(data, cb)
    if type(data) ~= 'table' then return cb({ success = false, error = 'bad_request' }) end
    local trace = startRequestTrace(data, 'action')
    PhoneBridge.Request('phone:server:appActionRequest', data, function(res)
        finishRequestTrace(trace, res)
        cb(res)
    end, nil, nil, trace)
end)
-- [phone-app-readers] end


RegisterNUICallback('clientError', function(data, cb)
    TriggerServerEvent('phone:server:clientError', data)
    cb({ ok = true })
end)


RegisterCommand('paycitation', function(_, args)
    local id = tonumber(args and args[1])
    if not id then return TriggerEvent('QBCore:Notify', '用法: /paycitation <id>', 'error') end
    QBCore.Functions.TriggerCallback('phone:server:payCitation', function(res)
        if res and res.success then
            TriggerEvent('QBCore:Notify', ('罚单 #%d 已支付 $%d'):format(res.id, res.amount), 'success')
        else
            TriggerEvent('QBCore:Notify', ('支付失败: %s'):format(res and res.error or 'unknown'), 'error')
        end
    end, id)
end, false)


-- P2 citation payment bridges (Banking 我的罚单)
RegisterNUICallback('getMyCitations', function(_, cb)
    QBCore.Functions.TriggerCallback('phone:server:getMyCitations', function(res)
        cb(res or { success = false, error = 'no_response' })
    end)
end)

RegisterNUICallback('payCitation', function(data, cb)
    local id = tonumber(data and data.citationId)
    if not id then return cb({ success = false, error = 'invalid_citation' }) end
    QBCore.Functions.TriggerCallback('phone:server:payCitation', function(res)
        cb(res or { success = false, error = 'no_response' })
    end, id)
end)

-- 手机里的报警入口：客户端只转交一句原因，位置由警察侧从 ped 上取。
RegisterNUICallback('report911', function(data, cb)
    if type(data) ~= 'table' then return cb({ success = false, error = 'bad_request' }) end
    QBCore.Functions.TriggerCallback('phone:server:report911', function(res)
        cb(res or { success = false, error = 'no_response' })
    end, { reason = data.reason })
end)

-- ==============================================================
-- 警情路线引导（同任务的路点：一条画在地图上的路线 + 距离）
-- ==============================================================
-- MDT 上点「前往」不只是改个状态：警员需要知道往哪开。以前点完只有一句"前往中"，
-- 坐标得自己从板子上抄。这里跟 custom-quest 的 SetNewBlip 用同一套画法，
-- 但自己的 blip 自己管，避免和任务路线互相清掉。

local mdtRouteBlip = nil

local function clearMdtRoute()
    if mdtRouteBlip and DoesBlipExist(mdtRouteBlip) then RemoveBlip(mdtRouteBlip) end
    mdtRouteBlip = nil
end

RegisterNUICallback('mdtNavigate', function(data, cb)
    if type(data) ~= 'table' then return cb({ success = false, error = 'bad_request' }) end
    if data.clear then
        clearMdtRoute()
        return cb({ success = true, cleared = true })
    end

    local x, y = tonumber(data.x), tonumber(data.y)
    if not x or not y or x == 0.0 and y == 0.0 then
        return cb({ success = false, error = 'bad_coords' })
    end
    local z = tonumber(data.z) or 0.0
    local label = type(data.label) == 'string' and data.label or '警情现场'
    label = label:gsub('[%c]', ' '):sub(1, 64)

    clearMdtRoute()
    mdtRouteBlip = AddBlipForCoord(x, y, z)
    SetBlipSprite(mdtRouteBlip, 60)
    SetBlipColour(mdtRouteBlip, 1)
    SetBlipRoute(mdtRouteBlip, true)
    SetBlipRouteColour(mdtRouteBlip, 1)
    SetBlipDisplay(mdtRouteBlip, 2)      -- 2 = 在路线上显示距离
    SetBlipAsShortRange(mdtRouteBlip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(mdtRouteBlip)
    SetNewWaypoint(x, y)                 -- 小地图上的那条线
    cb({ success = true })
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then clearMdtRoute() end
end)
