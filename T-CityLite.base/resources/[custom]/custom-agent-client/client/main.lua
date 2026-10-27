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
