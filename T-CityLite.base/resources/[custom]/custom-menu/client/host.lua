--[[
    custom-menu Client Host (M2)
    Coordinates MenuSpec validation, custom-ui input-layer stacking,
    openAck 500ms watchdog, and 4 intent dispatch routes (client/server/command/submenu).
]]

local CUSTOM_UI_RESOURCE = 'custom-ui'
local MENU_FRAME_ID = 'custom-menu'
local OPEN_ACK_TIMEOUT_MS = 500

local COMMAND_ALLOWLIST = {
    e = true,
    me = true,
    ['do'] = true,
    hud = true,
}

local intentRegistry = {}

local hostState = {
    open = false,
    seq = 0,
    ackPending = false,
    ackToken = nil,
    stack = {},
    knownIntents = nil,
    hasFocus = false,
    hasCursor = false,
    keepInput = false,
}

local function menuUiReady()
    return GetResourceState(CUSTOM_UI_RESOURCE) == 'started'
end

local function menuCloneTable(src, seen)
    if type(src) ~= 'table' then
        return src
    end
    seen = seen or {}
    if seen[src] then
        return seen[src]
    end
    local copy = {}
    seen[src] = copy
    for k, v in pairs(src) do
        if type(v) ~= 'function' then
            copy[k] = menuCloneTable(v, seen)
        end
    end
    return copy
end

local function menuBuildKnownIntents(opts)
    local set = {}
    for intentId, _ in pairs(intentRegistry) do
        set[intentId] = true
    end
    if type(opts) == 'table' and type(opts.knownIntents) == 'table' then
        for intentId, enabled in pairs(opts.knownIntents) do
            if enabled == true then
                set[intentId] = true
            end
        end
    end
    return set
end

local function menuBuildBreadcrumbs()
    local crumbs = {}
    for i = 1, #hostState.stack do
        local s = hostState.stack[i]
        crumbs[i] = s.title
    end
    return crumbs
end

local function menuSendUpdate(spec)
    local payloadSpec = menuCloneTable(spec)
    if not payloadSpec.breadcrumbs or #payloadSpec.breadcrumbs == 0 then
        payloadSpec.breadcrumbs = menuBuildBreadcrumbs()
    end
    SendNUIMessage({
        action = 'menu:update',
        spec = payloadSpec,
        stackDepth = #hostState.stack,
    })
end

local function menuCloseInternal(reason, skipPop)
    if not hostState.open and #hostState.stack == 0 then
        return false
    end

    hostState.open = false
    hostState.ackPending = false
    hostState.ackToken = nil
    hostState.stack = {}
    hostState.knownIntents = nil

    SendNUIMessage({
        action = 'menu:close',
        reason = reason or 'closed',
    })

    if not skipPop and menuUiReady() then
        local okOwns, owns = pcall(function()
            return exports[CUSTOM_UI_RESOURCE]:Owns(MENU_FRAME_ID)
        end)
        if okOwns and owns then
            pcall(function()
                exports[CUSTOM_UI_RESOURCE]:Pop(MENU_FRAME_ID)
            end)
            pcall(function()
                exports[CUSTOM_UI_RESOURCE]:GuardControls(200)
            end)
        end
    end
    return true
end

local function menuRegisterIntent(intentId, route)
    if type(intentId) ~= 'string' or #intentId == 0 or #intentId > 128 then
        return false, 'invalid_intent_id'
    end
    if type(route) ~= 'table' or type(route.type) ~= 'string' then
        return false, 'invalid_route'
    end

    local kind = route.type
    if kind == 'client' then
        if type(route.event) ~= 'string' and type(route.handler) ~= 'function' then
            return false, 'client_route_requires_event_or_handler'
        end
    elseif kind == 'server' then
        -- Always routed through controlled server gateway custom-menu:server:intent
        route.event = 'custom-menu:server:intent'
    elseif kind == 'command' then
        if type(route.command) ~= 'string' or not COMMAND_ALLOWLIST[route.command] then
            return false, 'command_not_in_allowlist'
        end
    elseif kind == 'submenu' then
        if type(route.spec) ~= 'table' and type(route.builder) ~= 'function' then
            return false, 'submenu_requires_spec_or_builder'
        end
    else
        return false, 'unsupported_route_type'
    end

    intentRegistry[intentId] = route
    return true, nil
end

local function menuSanitizeCommandLine(baseCmd, args)
    if type(baseCmd) ~= 'string' or not COMMAND_ALLOWLIST[baseCmd] then
        return nil
    end
    if type(args) == 'string' and #args > 0 then
        if string.find(args, '[;\r\n]') then
            return nil
        end
        return baseCmd .. ' ' .. args
    end
    return baseCmd
end

local function menuDispatchIntent(data)
    if not hostState.open or #hostState.stack == 0 then
        return { ok = false, reason = 'menu_not_open' }
    end

    local currentSpec = hostState.stack[#hostState.stack]
    local intent = data.intent
    local itemId = type(data.itemId) == 'string' and data.itemId or ''
    local menuId = currentSpec.id

    if type(intent) ~= 'string' or #intent == 0 then
        return { ok = false, reason = 'missing_intent' }
    end

    local route = intentRegistry[intent]
    if not route then
        return { ok = false, reason = 'unknown_intent', intent = intent }
    end

    local ctx = {
        menuId = menuId,
        itemId = itemId,
        intent = intent,
        args = type(data.args) == 'table' and data.args or {},
        values = type(data.values) == 'table' and data.values or {},
    }

    if route.type == 'client' then
        if type(route.handler) == 'function' then
            local okCall, callErr = pcall(route.handler, ctx)
            if not okCall then
                print(('[custom-menu] client intent %s error: %s'):format(intent, tostring(callErr)))
                return { ok = false, reason = 'client_handler_error' }
            end
        end
        if type(route.event) == 'string' and #route.event > 0 then
            TriggerEvent(route.event, ctx)
        end
        return { ok = true, dispatched = 'client' }
    elseif route.type == 'server' then
        TriggerServerEvent('custom-menu:server:intent', {
            menuId = menuId,
            itemId = itemId,
            intent = intent,
            args = ctx.args,
            values = ctx.values,
        })
        return { ok = true, dispatched = 'server' }
    elseif route.type == 'command' then
        local cmdLine = menuSanitizeCommandLine(route.command, route.args)
        if not cmdLine then
            return { ok = false, reason = 'command_rejected' }
        end
        ExecuteCommand(cmdLine)
        return { ok = true, dispatched = 'command' }
    elseif route.type == 'submenu' then
        local rawSub = route.spec
        if type(route.builder) == 'function' then
            local okBuild, built = pcall(route.builder, ctx)
            if not okBuild then
                return { ok = false, reason = 'submenu_builder_error' }
            end
            rawSub = built
        end
        local known = hostState.knownIntents or menuBuildKnownIntents(nil)
        local okValid, errValid = MenuSpec.Validate(rawSub, { knownIntents = known })
        if not okValid then
            print(('[custom-menu] invalid submenu spec for intent %s: %s'):format(intent, tostring(errValid)))
            return { ok = false, reason = errValid }
        end
        -- Replace active view inside the single custom-menu stack layer without calling Push again.
        hostState.stack[#hostState.stack + 1] = menuCloneTable(rawSub)
        menuSendUpdate(hostState.stack[#hostState.stack])
        return { ok = true, dispatched = 'submenu', depth = #hostState.stack }
    end

    return { ok = false, reason = 'unsupported_route' }
end

local function menuOpen(spec, opts)
    local known = menuBuildKnownIntents(opts)
    local okValid, errValid = MenuSpec.Validate(spec, { knownIntents = known })
    if not okValid then
        print(('[custom-menu] Open rejected invalid MenuSpec: %s'):format(tostring(errValid)))
        return false, errValid
    end

    local alreadyOwns = false
    if menuUiReady() then
        local okTaken, taken = pcall(function()
            return exports[CUSTOM_UI_RESOURCE]:IsTaken()
        end)
        local okOwns, owns = pcall(function()
            return exports[CUSTOM_UI_RESOURCE]:Owns(MENU_FRAME_ID)
        end)
        alreadyOwns = okOwns and owns == true
        if okTaken and taken and not alreadyOwns then
            return false, 'custom_ui_taken'
        end

        if not alreadyOwns then
            local okPush, pushed = pcall(function()
                return exports[CUSTOM_UI_RESOURCE]:Push({
                    id = MENU_FRAME_ID,
                    owner = GetCurrentResourceName(),
                    cursor = true,
                    keepInput = false,
                    allow = { 'pause' },
                })
            end)
            if not okPush or pushed == false then
                return false, 'custom_ui_push_failed'
            end
        end
    end

    hostState.open = true
    hostState.seq = hostState.seq + 1
    local openSeq = hostState.seq
    hostState.ackPending = true
    hostState.ackToken = ('ack-%d-%d'):format(GetGameTimer(), openSeq)
    hostState.knownIntents = known
    hostState.stack = { menuCloneTable(spec) }

    local openSpec = menuCloneTable(hostState.stack[1])
    if not openSpec.breadcrumbs or #openSpec.breadcrumbs == 0 then
        openSpec.breadcrumbs = menuBuildBreadcrumbs()
    end

    SendNUIMessage({
        action = 'menu:open',
        ackToken = hostState.ackToken,
        spec = openSpec,
        stackDepth = #hostState.stack,
    })

    CreateThread(function()
        Wait(OPEN_ACK_TIMEOUT_MS)
        if hostState.open and hostState.ackPending and hostState.seq == openSeq then
            print(('[custom-menu] openAck timeout after %dms (menuId=%s, token=%s) — closing and popping frame'):format(
                OPEN_ACK_TIMEOUT_MS,
                tostring(openSpec.id),
                tostring(hostState.ackToken)
            ))
            menuCloseInternal('ack_timeout', false)
        end
    end)

    return true, nil
end

-- Focus contract owned by custom-ui; custom-menu never writes focus natives directly.
exports('ApplyFocus', function(hasFocus, hasCursor, keepInput)
    hostState.hasFocus = hasFocus == true
    hostState.hasCursor = hasCursor == true
    hostState.keepInput = keepInput == true
    return true
end)

exports('ForceClose', function(_frameId, reason)
    menuCloseInternal(reason or 'force_close', true)
    return true
end)

exports('Open', menuOpen)
exports('Close', function(reason)
    return menuCloseInternal(reason or 'close_export', false)
end)
exports('IsOpen', function()
    return hostState.open == true
end)
exports('RegisterIntent', menuRegisterIntent)
exports('AllowCommand', function(cmdName)
    if type(cmdName) == 'string' and #cmdName > 0 and #cmdName <= 48 and not string.find(cmdName, '%s') then
        COMMAND_ALLOWLIST[cmdName] = true
        return true
    end
    return false
end)

RegisterNUICallback('nui:ack', function(data, cb)
    local token = type(data) == 'table' and data.ackToken or nil
    if token == nil or token == hostState.ackToken then
        hostState.ackPending = false
    end
    cb({ ok = true })
end)

RegisterNUICallback('nui:intent', function(data, cb)
    local result = menuDispatchIntent(type(data) == 'table' and data or {})
    cb(result)
end)

RegisterNUICallback('nui:back', function(_data, cb)
    if hostState.open and #hostState.stack > 1 then
        hostState.stack[#hostState.stack] = nil
        menuSendUpdate(hostState.stack[#hostState.stack])
        cb({ ok = true, depth = #hostState.stack })
    else
        cb({ ok = true, depth = #hostState.stack })
    end
end)

RegisterNUICallback('nui:close', function(data, cb)
    local reason = type(data) == 'table' and type(data.reason) == 'string' and data.reason or 'nui_esc'
    cb({ ok = true })
    menuCloseInternal(reason, false)
end)

RegisterNUICallback('nui:toastDismiss', function(_data, cb)
    cb({ ok = true })
end)

RegisterNetEvent('custom-menu:client:intentResult', function(res)
    if type(res) ~= 'table' then
        return
    end
    if res.status == 'denied' then
        SendNUIMessage({
            action = 'toast:push',
            title = 'Action Denied',
            message = tostring(res.reason or 'denied'),
            tone = 'danger',
            durationMs = 4000,
        })
    end
end)

AddEventHandler('onResourceStop', function(resName)
    if resName == GetCurrentResourceName() and hostState.open then
        menuCloseInternal('resource_stop', false)
    end
end)
