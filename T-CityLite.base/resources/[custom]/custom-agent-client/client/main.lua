-- client/main.lua — effect executor for tcity:agent:exec.
--
-- The client never decides policy and has no "please execute" entry point.
-- It accepts only server-signed messages that match the in-memory session,
-- dispatches a literal handler table, and reports back a telemetry ack.

local QBCore = exports['qb-core']:GetCoreObject()

local ANIM_LOAD_TIMEOUT_MS = 1000
local ANIM_START_TIMEOUT_MS = 250

local session = nil
local active = {}   -- active[rid] = action, cleared when the handler returns

-- ---------------------------------------------------------------------------
-- Handlers: literal table, no event forwarding, no dynamic dispatch
-- ---------------------------------------------------------------------------

local function handleNotify(payload)
    QBCore.Functions.Notify(payload.text, payload.kind, 5000)
    return 'ok'
end

-- 统一走 core-framework 的公共实现（原先这里有一份同样的阻塞等待循环）。
-- 用 function 包一层而不是直接赋值 exports：导出在"调用时"解析，
-- 这样不把核心资源变成加载期硬依赖，资源启动顺序也不影响。
local loadAnimDict = function(dict)
    -- 必须带上本资源的超时：导出默认是 5000ms，直接用会把 effect 超时从 1s 拖到 5s，
    -- 而 ack 文案仍然写着 ANIM_LOAD_TIMEOUT_MS（无头用例抓到的漂移）。
    return exports['core-framework']:LoadAnimDict(dict, ANIM_LOAD_TIMEOUT_MS)
end

local function handlePlayAnim(payload)
    local ped = PlayerPedId()
    if not loadAnimDict(payload.dict) then
        return 'failed', 'anim_load_timeout',
            { message = ('dict not loaded in %dms'):format(ANIM_LOAD_TIMEOUT_MS) }
    end
    TaskPlayAnim(ped, payload.dict, payload.clip, 8.0, 8.0, payload.duration_ms, 49, 0.0,
        false, false, false)

    local deadline = GetGameTimer() + ANIM_START_TIMEOUT_MS
    while GetGameTimer() < deadline do
        if IsEntityPlayingAnim(ped, payload.dict, payload.clip, 3) then
            return 'ok', nil, { dict = payload.dict, clip = payload.clip, duration_ms = payload.duration_ms }
        end
        Wait(50)
    end
    return 'failed', 'anim_not_found', { message = 'animation did not start' }
end

local function handleClearAnim()
    ClearPedTasks(PlayerPedId())
    return 'ok'
end

local function handleTeleport(payload)
    local ped = PlayerPedId()
    if GetVehiclePedIsIn(ped, false) ~= 0 then
        SetPedCoordsKeepVehicle(ped, payload.x, payload.y, payload.z)
    else
        SetEntityCoords(ped, payload.x, payload.y, payload.z, false, false, false, false)
    end
    if payload.heading then SetEntityHeading(ped, payload.heading) end
    return 'ok', nil, { x = payload.x, y = payload.y, z = payload.z, heading = payload.heading }
end

local function handleScreenEffect(payload)
    StartScreenEffect(payload.name, payload.duration_ms, true)
    return 'ok', nil, { name = payload.name, duration_ms = payload.duration_ms }
end

-- M2 deliberately has no NUI: help text is read-only and cannot take focus or
-- input. A later slice may replace this with an HTML-escaped textContent card.
local function handleOpenTextUi(payload)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(('%s: %s'):format(payload.title, payload.body))
    EndTextCommandDisplayHelp(0, false, true, payload.timeout_ms)
    return 'ok', nil, { title_len = #payload.title, body_len = #payload.body }
end

local Handlers = {
    send_notify = handleNotify,
    play_anim = handlePlayAnim,
    clear_anim = handleClearAnim,
    teleport = handleTeleport,
    screen_effect = handleScreenEffect,
    open_text_ui = handleOpenTextUi,
}

-- ---------------------------------------------------------------------------
-- Channel
-- ---------------------------------------------------------------------------

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    TriggerServerEvent('tcity:agent:ready')
end)

RegisterNetEvent('tcity:agent:hello', function(msg)
    if type(msg) ~= 'table' or msg.v ~= 1 then return end
    if type(msg.session) ~= 'string' or msg.session == '' then return end
    session = msg.session
end)

RegisterNetEvent('tcity:agent:exec', function(msg)
    if type(msg) ~= 'table' or msg.v ~= 1 then return end
    if type(session) ~= 'string' or msg.session ~= session then return end
    local rid = msg.request_id
    if type(rid) ~= 'string' or rid == '' then return end

    local handler = Handlers[msg.action]
    if not handler then
        TriggerServerEvent('tcity:agent:ack', {
            v = 1, request_id = rid, session = session,
            status = 'rejected', error_code = 'action_not_allowed',
        })
        return
    end

    active[rid] = msg.action
    local ok, status, errorCode, detail = pcall(handler, msg.payload or {}, msg.timeout_ms or 4000)
    active[rid] = nil

    if not ok then
        TriggerServerEvent('tcity:agent:ack', {
            v = 1, request_id = rid, session = session,
            status = 'failed', error_code = 'client_error',
            detail = { message = tostring(status):sub(1, 200) },
        })
        return
    end

    TriggerServerEvent('tcity:agent:ack', {
        v = 1, request_id = rid, session = session,
        status = status or 'failed', error_code = errorCode, detail = detail or {},
    })
end)

RegisterNetEvent('tcity:agent:cancel', function(msg)
    if type(msg) ~= 'table' or msg.v ~= 1 or msg.session ~= session then return end
    local rid = msg.request_id
    if type(rid) ~= 'string' then return end
    if active[rid] then
        active[rid] = nil
        ClearPedTasks(PlayerPedId())
    end
    TriggerServerEvent('tcity:agent:ack', {
        v = 1, request_id = rid, session = session, status = 'cancelled',
    })
end)

-- ---------------------------------------------------------------------------
-- State probe (read-only)
--
-- custom-agent-client is the only resource that may talk to the director, so the
-- client-side snapshot lives here. It carries enums/booleans/numbers only: no UI
-- text, no player input, no identifiers. The server re-sanitises everything and
-- expires it after 15 s, so a stale snapshot can never look like current truth.
-- ---------------------------------------------------------------------------
local PROBE_INTERVAL_MS = 5000

local function phoneState()
    -- Cross-resource client exports are a runtime contract (06-client-model P10):
    -- the phone may be stopped, so treat a missing export as "unknown", not fatal.
    local ok, state = pcall(function() return exports['custom-phone']:GetUiState() end)
    if ok and type(state) == 'table' then
        return {
            open = state.open == true,
            surface = state.surface,
            focused = state.focused == true,
            keep_input = state.keep_input == true,
            -- 引擎原生的原话，与上面的记账分开：两者不一致 = 原生在撒谎
            -- （本 build 恒 false，见 nui-debug-playbook）。
            nui_focus_native = state.nui_focus_native == true,
            -- 焦点落在哪个控件上（NUI 侧 nav 回吐；空 = 没有焦点）
            focus = type(state.focus) == 'string' and state.focus or nil,
            focus_owner = state.focus_owner,
            app = type(state.app) == 'table' and {
                id = state.app.id,
                tab = state.app.tab,
                selected = state.app.selected,
            } or nil,
        }
    end
    return nil
end

local function collectState()
    local data = QBCore and QBCore.Functions.GetPlayerData and QBCore.Functions.GetPlayerData()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    local w, h = GetActiveScreenResolution()
    return {
        v = 1,
        logged_in = type(data) == 'table' and type(data.citizenid) == 'string' and data.citizenid ~= '',
        phone = phoneState(),
        ped = {
            in_vehicle = vehicle ~= 0,
            vehicle_class = vehicle ~= 0 and GetVehicleClass(vehicle) or 0,
            health = GetEntityHealth(ped),
            dead = IsEntityDead(ped) == true,
        },
        screen = { w = w, h = h },
    }
end

-- ---------------------------------------------------------------------------
-- 开发用：让服务端（RCON / director）替 agent 敲一行客户端控制台命令。
-- 为什么需要：devcon 的 29200 端口在监听，但握手不成（遥控台默认关），
-- 而合成鼠标点击又因为 GTA 锁光标而无效 —— 客户端侧的"动作"没有别的入口。
-- 安全：convar agent_devcmd_enabled 默认关；命令必须匹配白名单；只接受
-- 服务端下发的事件（客户端无法自触发）；不接受分号/换行，防止一次塞多条。
-- ---------------------------------------------------------------------------
local DEVCMD_ALLOWED = {
    '^phoneui [a-z0-9_:-]+$',
    '^phoneui [a-z0-9_:-]+ [a-z0-9_:-]+$', -- 带页码：/phoneui police_mdt case
    '^tablet$',
    '^phone$',
    '^phonefix$',
    -- 警用：值班状态与 911。这两个是 custom-police 的客户端命令，值班会把单位写进
    -- police_units（MDT「单位」页与 /live/police/board 都读它），911 会建一条警情。
    '^10%-[678]$',
    -- 注意：Lua 的 pattern **没有** {n,m} 计数（那是正则的写法）。
    -- 这里原来写 '^911 [^%c;]{1,80}$'，永远匹配不上 —— 911 全部被拒，
    -- 而 devcmd 只回 not_allowed，看不出"是格式写错了"。长度改在下面判。
    '^911 [^%c;]+$',
}

-- 一条 devcmd 最多这么长：手机命令都短，超长的要么是误用，要么是想塞别的
local DEVCMD_MAX_LEN = 96

local function devcmdAllowed(cmd)
    if #cmd > DEVCMD_MAX_LEN then return false end
    for _, pattern in ipairs(DEVCMD_ALLOWED) do
        if cmd:match(pattern) then return true end
    end
    return false
end

RegisterNetEvent('tcity:agent:devcmd', function(raw)
    if GetConvar('agent_devcmd_enabled', '0') ~= '1' then return end
    if type(raw) ~= 'string' or #raw > 64 then return end
    local cmd = raw:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if cmd:find('[;%c]') then return end -- 分号/控制字符：一次只许一条命令
    if not devcmdAllowed(cmd) then
        TriggerServerEvent('tcity:agent:devcmd_result', raw, 'not_allowed')
        return
    end
    ExecuteCommand(cmd)
    TriggerServerEvent('tcity:agent:devcmd_result', cmd, 'ok')
end)

local function pushState()
    local ok, snapshot = pcall(collectState)
    if ok and type(snapshot) == 'table' then
        TriggerServerEvent('tcity:agent:state', snapshot)
    end
end

-- 状态一变就推一份：5s 心跳能证明"还活着"，但读不到"刚按完 M 之后"的样子。
-- 手机只广播"变了"，快照仍由本资源自己采集，所以对方拿不到也改不了这里的数据。
--
-- 合并 150ms 内的连续变化：换形态是"先关再开"，两次广播相隔几十毫秒，
-- 第一个推的是 open=false，第二个（真正的终态）会被服务端 250ms 窗口丢掉——
-- 结果是刚换完形态 5 秒内，agent 读到的还是"关着"。
local pendingPush = nil
AddEventHandler('phone:client:stateChanged', function()
    if pendingPush then
        ClearTimeout(pendingPush)
        pendingPush = nil
    end
    pendingPush = SetTimeout(150, function()
        pendingPush = nil
        pushState()
    end)
end)

CreateThread(function()
    while true do
        -- Always send: the server expires a snapshot after 15 s, so an
        -- idle-but-fine client must keep beating or the probe goes dark
        -- exactly when nothing is happening (the interesting case).
        pushState()
        Wait(PROBE_INTERVAL_MS)
    end
end)
