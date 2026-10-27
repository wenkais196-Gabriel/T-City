-- client/main.lua — wiring only. NUI registration/request_id timeouts live in
-- client/core/bridge.lua, focus ownership in client/core/focus.lua and the
-- unified phone:client:event channel in client/core/events.lua. The manifest
-- must load those three before this file.
-- 形态与开关的唯一真值是 client/core/surface.lua；这里不再持有布尔。
local QBCore = exports['qb-core']:GetCoreObject()

-- 角色加载标记：加载完成前开设备，服务端拿不到玩家数据，
-- MDT 会回 player_not_found（界面显示"角色尚未加载"），看起来像 bug 其实是时序。
-- 这里直接挡住并给人话提示，别让人对着一个错误横幅猜。
local playerLoaded = false

local function markPlayerLoaded()
    local data = QBCore.Functions.GetPlayerData()
    if data and type(data.citizenid) == 'string' and data.citizenid ~= '' then
        playerLoaded = true
    end
    return playerLoaded
end

-- A resource (re)start is also the recovery path when a previous client left
-- NUI focus/cursor stuck: never inherit that state.
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    PhoneFocus.Reset()
end)

-- Additive unified event channel; the legacy phone:client:* handlers below stay
-- registered unchanged during the migration.
PhoneEvents.Start()

-- 状态一变就喊一声：消费方（custom-agent-client 的状态探针）本来靠 5s 心跳，
-- 结果按完 M 最多 5 秒内读到的还是旧值。事件只是"去看看"，不带任何参数，
-- 所以它既不泄露内容，也不可能被别人拿来伪造状态。
local function announceUiState()
    TriggerEvent('phone:client:stateChanged')
end

-- ---------------------------------------------------------------
-- 单 App 状态：Svelte 侧把"停在哪一页"回吐给 Lua。
-- agent 只能答"手机开着、哪一面"是不够的（08-client-state-probe §边界）；
-- 任务/MDT 停在哪个 tab 得由 App 自己说。只收三个白名单短 token，
-- 不收任何正文、搜索词或玩家输入。
-- ---------------------------------------------------------------
local appState = {}

local function stateToken(value, maxLen)
    if type(value) ~= 'string' or #value == 0 or #value > maxLen then return nil end
    if not value:match('^[%w_%-:]+$') then return nil end
    return value
end

RegisterNUICallback('appState', function(data, cb)
    if type(data) == 'table' then
        appState = {
            id = stateToken(data.app, 24),
            tab = stateToken(data.tab, 24),
            selected = stateToken(data.selected, 48),
        }
    end
    -- 统一应答通道：本 build 的 cb 可能是可调用表，所以不允许对 cb 做类型守卫。
    PhoneBridge.AnswerFn(cb)({ ok = true })
    announceUiState()
end)

-- Close Phone Function (must be defined before OpenPhone — CreateThread closure)
-- 只读状态快照：给 agent 的状态探测用（custom-agent-client 每 5s 取一次）。
-- 只回枚举/布尔/数字，不回任何 UI 内容、消息正文或玩家输入。
exports('GetUiState', function()
    local focus = PhoneFocus.State()
    -- 形态就是开着的证据：Surface.Bind() 在打开时写入，ClosePhone 里 Reset 清空。
    -- （#48 之后 isPhoneOpen 已经不存在，只有注释里还留着旧名字。）
    local kind = Surface.Current()
    return {
        open = kind ~= nil,
        surface = kind,
        -- focused/keep_input 报"我们申请到了什么"（PhoneFocus 记账），不是问引擎：
        -- IsNuiFocused()/IsNuiFocusKeepingInput() 在本 build 恒 false，拿它当真相
        -- 会把"开着且焦点在手机上"报成"没焦点"。
        focused = focus.focus == true,
        keep_input = focus.keepInput == true,
        -- 原生原样上报，只作对照：true 说明引擎认可，false 可能只是它在撒谎。
        nui_focus_native = IsNuiFocused() == true,
        focus_owner = focus.owner,
        -- 哪个 App 停在哪一页（App 自己回吐；没回吐就是 nil）
        app = appState.id and { id = appState.id, tab = appState.tab, selected = appState.selected } or nil,
    }
end)

local function ClosePhone(reason)
    local kind = Surface.Current()
    if not kind then return end
    Surface.Reset()
    appState = {}
    -- 任何关闭路径都必须解锁：焦点没了但人还钉在原地是最难查的故障。
    DeviceLock.End()
    TriggerServerEvent('phone:server:focusState', { phase = 'close-start', surface = kind })
    -- custom-ui owns the phone menu/focus by default. When another focus owner
    -- (fingerprint/story/vehicle) is on top, closing the phone must not clear
    -- that UI's focus; just pop the phone from the stack below it.
    local owner = PhoneFocus.State().owner
    if owner == nil or owner == 'phone' or owner == 'tablet' then
        pcall(function() exports['custom-ui']:CloseMenu() end)
    end
    -- Release drops NUI focus even when custom-ui.CloseMenu is missing or
    -- throws. It deliberately leaves keepInput for the next phone open: the
    -- project's real-client contract is qb-phone style (see AGENTS.md).
    PhoneBridge.Ack('phone:open') -- stop any open-ack resend loop
    PhoneFocus.Release(kind)
    SendNUIMessage({
        action = 'phone:close',
        -- switch = 换形态不是退出：NUI 会保留当前 app，别把人踢回桌面
        reason = reason or 'user'
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
    announceUiState()
end

-- Open Phone Function
local function OpenPhone(forcedKind, reason)
    if Surface.IsOpen() then return end
    if not playerLoaded and not markPlayerLoaded() then
        QBCore.Functions.Notify('角色还在加载，稍等一下再打开', 'error')
        return
    end
    -- 形态在打开这一刻定下来：entry > 来电/载具 > 玩家偏好 > 窗口 > 默认
    local kind = Surface.Decide({ entry_surface = forcedKind, reason = reason })
    Surface.Bind(kind)
    -- SendNUIMessage is fire-and-forget: while CEF is still loading (every
    -- `restart custom-phone`) the frame is dropped and the phone stays "open"
    -- in Lua with nothing on screen. Resend until the NUI acknowledges the
    -- open, which is the only proof the interface exists.
    PhoneBridge.AwaitAck('phone:open', function()
        SendNUIMessage({
            action = 'phone:open',
            surface = kind,
            reason = reason or 'open'
        })
    end, {
        intervalMs = 250,
        timeoutMs = 2500,
        onTimeout = function()
            -- The UI never answered: drop the half-open state so the next key
            -- press starts clean instead of being swallowed by isPhoneOpen.
            Surface.Reset()
            DeviceLock.End()
            PhoneFocus.Release(kind)
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
    -- keepInput 是形态的一部分：手机要能边跑边看，平板要站定。
    PhoneFocus.Acquire(kind, { cursor = true, keepInput = (kind == 'phone') })
    DeviceLock.Begin(kind)
    announceUiState()
    TriggerServerEvent('phone:server:focusState', { phase = 'open-start', surface = kind, reason = reason or 'open' })

    CreateThread(function()
        -- 平板不播手机动画：手里举着板子却做"看短信"动作很出戏
        if kind ~= 'phone' then return end
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
        if Surface.IsOpen() and Surface.Current() == 'phone' then
            TaskPlayAnim(ped, 'cellphone@', 'cellphone_text_in', 8.0, -8.0, 800, 49, 0, false, false, false)
        end
    end)
    
    -- Focus watchdog: if something steals NUI focus, re-apply it instead of
    -- leaving the phone visible with the mouse still driving the camera.
    CreateThread(function()
        for attempt = 1, 5 do
            Wait(attempt == 1 and 50 or 150)
            if not Surface.IsOpen() or Surface.Current() ~= kind then return end
            -- Another owner (fingerprint/story/vehicle) may legitimately sit on
            -- top of the stack. Do not steal focus from it; when it releases,
            -- the stack re-applies the phone automatically.
            if not PhoneFocus.IsOwner(kind) then return end
            -- Re-assert the cursor flag every time, not only when focus is
            -- reported lost: focused=true with no cursor is the failure we saw.
            PhoneFocus.Acquire(kind, { cursor = true, keepInput = (kind == 'phone') })
            TriggerServerEvent('phone:server:focusState', {
                phase = 'reassert', attempt = attempt, surface = kind,
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

        while Surface.IsOpen() do
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
            -- 右键只关手机（平板居中还拿右键关面板会误触）；平板用状态栏的关闭按钮
            if kind == 'phone' and IsDisabledControlJustPressed(0, 25) then  -- INPUT_AIM
                ClosePhone('right_click')
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
--
-- 开关只看我们自己的账（Surface.IsOpen），不看 IsNuiFocused()：本 build 上这个
-- 原生**恒为 false**（实测 61 条 focus 事件里 0 条 true，见 docs/client/research/
-- nui-debug-playbook.md），于是"开着 + 原生说没焦点 → 复位重开"的分支会把每一次
-- 关闭变成重开，表现就是按 M 关不掉手机、界面闪。半开（NUI 没应答）由
-- OpenPhone 里的 AwaitAck 超时自己收拾，不需要这里再兜。
--
-- 防重复触发：一次按 M 实测会进来两次（RegisterKeyMapping 在资源重启时会再注册
-- 一次，同一次按键派发两条命令）。300ms 内的重复调用只处理第一次。
local TOGGLE_DEBOUNCE_MS = 300
-- 从 -DEBOUNCE 起步：设 0 会让"资源刚起就按 M"落进去抖窗口（now - 0 < 300），
-- 第一次按键被静默吞掉。
local lastToggleAt = -TOGGLE_DEBOUNCE_MS

--- 同一个设备按两次 = 关；在另一个形态上按 = 换形态；没开就开。
--- kind=nil 表示"让 Surface.Decide 决定"（M 键的默认行为）。
--- 决定必须来自我们自己的账（Surface），不能来自 IsNuiFocused()：本 build 上那个
--- 原生恒 false（见 nui-debug-playbook），拿它判断会让每次关闭变成重开。
local function OpenOrToggle(kind)
    if Surface.IsOpen() then
        local current = Surface.Current()
        if kind == nil or kind == current then
            ClosePhone('key')
            return
        end
        ClosePhone('switch')
        Wait(60)
        OpenPhone(kind, 'command')
        return
    end
    OpenPhone(kind, kind and 'command' or 'key')
end

-- /phone          → 开关（形态由 Surface.Decide 决定，M 键走这条）
-- /phone tablet   → 强制平板（开着手机就换形态）
-- /phone phone    → 强制手机
RegisterCommand('phone', function(_, args)
    local now = GetGameTimer()
    if now - lastToggleAt < TOGGLE_DEBOUNCE_MS then
        -- 这里不报 focused：该原生在本 build 恒 false，报了只会给遥测添一条假信号。
        TriggerServerEvent('phone:server:focusState', { phase = 'toggle-debounced' })
        return
    end
    lastToggleAt = now
    local want = type(args) == 'table' and args[1] or nil
    if want ~= 'phone' and want ~= 'tablet' then want = nil end
    OpenOrToggle(want)
end, false)

-- 平板的入口：形态要有"意图"，不能靠窗口大小猜。
-- /tablet 直接在平板形态打开；/phone 强制手机；已经开着就换形态（先关后开）。
-- 注意：这里**不能**再 RegisterCommand('phone') —— FiveM 后注册者覆盖先注册者，
-- 曾经因此把上面的 toggle 覆盖成"只开不关"，M 键就再也关不掉手机了。
RegisterCommand('tablet', function()
    OpenOrToggle('tablet')
end, false)

RegisterCommand('phonefix', function()
    Surface.Reset()
    appState = {} -- 硬复位连"停在哪一页"一起清，别让下一次打开继承旧 tab
    DeviceLock.End()
    PhoneFocus.Reset()
    SendNUIMessage({ action = 'phone:close', reason = 'phonefix' })
    announceUiState()
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
    ClosePhone('user')
    cb({ success = true })
end)

-- CEF 上报真实 CSS px：surface 阈值判定在 Lua，但只有页面知道窗口多大。
-- 回调名拼错会让 NUI 契约闸门直接红，所以这里必须与 fetchNui('surfaceInfo') 对齐。
RegisterNUICallback('surfaceInfo', function(data, cb)
    local ok = Surface.SetViewport(data and data.width, data and data.height)
    cb({ success = ok, surface = Surface.Current() })
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
    -- 手机未打开（关闭/锁屏）时自动弹出，确保来电一定能被看到（审计 B04）。
    -- 来电强制手机形态：整屏平板会锁住移动，不能边开车边接电话。
    if not Surface.IsOpen() then
        OpenPhone('phone', 'incoming_call')
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
    markPlayerLoaded()
    Wait(2000)
    CheckLeaderApp()
end)

-- 资源在玩家已登录后才启动的情况：等数据到齐再放行
AddEventHandler('QBCore:Player:SetPlayerData', function(value)
    if value and type(value.citizenid) == 'string' and value.citizenid ~= '' then
        playerLoaded = true
    end
end)
CreateThread(function()
    for _ = 1, 10 do
        if markPlayerLoaded() then return end
        Wait(1000)
    end
end)

RegisterNetEvent('custom-career:client:tierChanged', function(newTier)
    CheckLeaderApp()
end)

-- Real-time Money Sync Listener
RegisterNetEvent('QBCore:Client:OnMoneyChange', function(type, amount, operation)
    if not Surface.IsOpen() then return end
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
    if not Surface.IsOpen() or not val or not val.money then return end
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
    if not Surface.IsOpen() then return end
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

