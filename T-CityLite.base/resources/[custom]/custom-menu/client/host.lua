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

--- resource 路由的回调结果解析：
--- - `{ ok = false, reason = ... }` → 原样返回（动作被拒）
--- - `{ ok = true, spec = <MenuSpec> }` → 关掉当前视图、把 spec 压进同一层并 menu:update
---   （子菜单语义与 `submenu` 路由完全一致，只是 spec 由对方资源同步返回而不是 builder）
--- - 其余 → `{ ok = true, dispatched = 'resource' }`
local function menuResolveResourceResult(intent, ret)
    if type(ret) ~= 'table' then
        return { ok = true, dispatched = 'resource' }
    end
    if ret.ok == false then
        return ret
    end
    if type(ret.spec) ~= 'table' then
        return ret
    end
    local known = hostState.knownIntents or menuBuildKnownIntents(nil)
    local okValid, errValid = MenuSpec.Validate(ret.spec, { knownIntents = known })
    if not okValid then
        print(('[custom-menu] resource intent %s 返回的子菜单不合法：%s'):format(intent, tostring(errValid)))
        return { ok = false, reason = errValid }
    end
    hostState.stack[#hostState.stack + 1] = menuCloneTable(ret.spec)
    menuSendUpdate(hostState.stack[#hostState.stack])
    return { ok = true, dispatched = 'submenu', depth = #hostState.stack }
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
    elseif kind == 'resource' then
        -- 跨资源回调专用：路由**只带字符串**，一个函数都不带。
        -- 原因：exports 跨资源传参走序列化，表里的函数字段会在对面变成 nil
        -- （2026-11-26 真机：qb-menu 传 handler 闭包，registry 侧收到 route.handler=nil，
        -- 被判定成 client_route_requires_event_or_handler）。所以回调改成
        -- 「叫对方资源导出的方法」，参数只有 intentId + JSON-safe 的 ctx。
        if type(route.resource) ~= 'string' or #route.resource == 0 then
            return false, 'resource_route_requires_resource'
        end
        if type(route.method) ~= 'string' or #route.method == 0 then
            return false, 'resource_route_requires_method'
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
    elseif route.type == 'resource' then
        local target, fn
        local okLookup, lookupErr = pcall(function()
            target = exports[route.resource]
            fn = target and target[route.method]
        end)
        if not okLookup or type(fn) ~= 'function' then
            print(('[custom-menu] resource intent %s 失败：exports[%s]:%s 不可用（%s）'):format(
                intent, tostring(route.resource), tostring(route.method),
                tostring(lookupErr or 'missing_export')))
            return { ok = false, reason = 'resource_export_missing' }
        end
        -- 显式传 self（exports 代理会吃掉第一个实参）；参数里只有字符串和 JSON-safe 表。
        local okCall, ret = pcall(fn, target, intent, ctx)
        if not okCall then
            print(('[custom-menu] resource intent %s 执行失败：%s'):format(intent, tostring(ret)))
            return { ok = false, reason = 'resource_handler_error' }
        end
        return menuResolveResourceResult(intent, ret)
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
--- custom-ui 的栈在推帧/弹帧时会反调本导出，由**拥有 NUI 页面**的资源真正设置焦点。
--- ⚠️ 这一段不能省：`SetNuiFocus` 是按资源的，custom-ui 自己没有 ui_page（它 :74 的 V-10 注释
--- 写明了）。少了它，真机表现是「菜单画出来了，但键盘和鼠标全都没反应」——2026-11-26 实测。
--- 顺序与重试照抄 custom-ui 的约定（:92-112）：keepInput 先设 → false,false 清掉别处留下的
--- 半聚焦 → true,true，并在下一帧与 100ms 后各补一次（有些 build 同帧授予焦点会丢光标）。
exports('ApplyFocus', function(hasFocus, hasCursor, keepInput)
    hostState.hasFocus = hasFocus == true
    hostState.hasCursor = hasCursor == true
    hostState.keepInput = keepInput == true

    if not hostState.hasFocus then
        SetNuiFocusKeepInput(false)
        SetNuiFocus(false, false)
        return true
    end

    SetNuiFocusKeepInput(hostState.keepInput)
    SetNuiFocus(false, false)
    SetNuiFocus(true, true)

    local seq = hostState.seq
    CreateThread(function()
        Wait(0)
        if hostState.open and hostState.hasFocus and hostState.seq == seq then
            SetNuiFocus(true, true)
        end
        Wait(100)
        if hostState.open and hostState.hasFocus and hostState.seq == seq then
            SetNuiFocus(true, true)
        end
    end)
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
    if resName ~= GetCurrentResourceName() then return end
    if hostState.open then
        menuCloseInternal('resource_stop', false)
    end
    -- 资源卸载时页面已经消失，必须**无条件**把焦点还出去：custom-ui 的 Pop 可能因为栈状态
    -- 走不到（例如 custom-ui 自己在重启），而 SetNuiFocus 是本资源自己的，
    -- 漏了这一步就会留下"游戏拿不到键盘"的僵尸状态（闸门 NUI-CLIENT-01 也要求这条）。
    hostState.hasFocus = false
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
end)


-- ══════════════════════════════════════════════════════════════════
-- 开发示例菜单（convar custom_menu_debug，默认关）
--
-- 为什么要有这段：这个资源本身不挂在任何世界坐标上，没有入口就等于"装好了也看不见"。
-- 它给真机验（焦点 / 按键 / Esc / 叠栈）一个可点开的最小入口，也是后续把老资源迁过来时
-- 可以直接照抄的用法示例。
-- ══════════════════════════════════════════════════════════════════

if GetConvar('custom_menu_debug', 'false') == 'true' then
    local function demoToast(message, tone)
        SendNUIMessage({
            action = 'toast:push',
            title = '演示',
            message = tostring(message),
            tone = tone or 'info',
            durationMs = 3000,
        })
    end

    local demoScreens = {}

    demoScreens.form = {
        id = 'demo_form',
        title = '表单示例',
        subtitle = '输入框 / 滑杆 / 单选',
        surface = 'form',
        breadcrumbs = { '演示', '表单' },
        submitLabel = '提交',
        cancelLabel = '取消',
        items = {
            { id = 'plate', kind = 'input', label = '车牌号', placeholder = 'ABC123', maxLength = 8, required = true },
            { id = 'note', kind = 'input', label = '备注', placeholder = '可不填', maxLength = 40 },
            { id = 'volume', kind = 'range', label = '音量', min = 0, max = 100, step = 5, defaultValue = 60, unit = '%' },
        },
    }

    demoScreens.confirm = {
        id = 'demo_confirm',
        title = '确认示例',
        surface = 'confirm',
        breadcrumbs = { '演示', '确认' },
        message = '这一步会把示例数据写进去（不会真的写库）。',
        confirmLabel = '确认',
        cancelLabel = '取消',
        items = {
            { id = 'yes', kind = 'confirm', label = '确认执行', intent = 'demo:toast', args = { message = '已确认' } },
        },
    }

    demoScreens.range = {
        id = 'demo_range',
        title = '滑杆示例',
        surface = 'range',
        breadcrumbs = { '演示', '滑杆' },
        items = {
            { id = 'vol', kind = 'range', label = '界面音量', min = 0, max = 100, step = 10, defaultValue = 50, unit = '%', intent = 'demo:toast' },
        },
    }

    local function registerDemoIntents()
        for name, spec in pairs(demoScreens) do
            local ok, err = menuRegisterIntent('demo:to_' .. name, { type = 'submenu', spec = spec })
            if not ok then
                print(('[custom-menu] demo intent %s 注册失败：%s'):format(name, tostring(err)))
            end
        end

        menuRegisterIntent('demo:toast', {
            type = 'client',
            handler = function(ctx)
                local message = type(ctx) == 'table' and type(ctx.args) == 'table'
                    and ctx.args.message or '点了这一项'
                demoToast(message, 'info')
                return { ok = true }
            end,
        })

        -- 故意打一个服务端没注册的 intent：用来验「拒绝路径」在界面上是否可见。
        menuRegisterIntent('demo:denied', {
            type = 'server',
        })
    end

    local demoRoot = {
        id = 'demo_root',
        title = 'T-City 交互菜单',
        subtitle = 'custom-menu 宿主 · 开发示例',
        surface = 'list',
        breadcrumbs = { '演示' },
        items = {
            { id = 'about', kind = 'info', label = 'custom-menu', description = '一套 MenuSpec + 唯一焦点栈' },
            { id = 'to_form', kind = 'nav', label = '表单示例', description = '输入 / 滑杆', intent = 'demo:to_form' },
            { id = 'to_confirm', kind = 'nav', label = '确认示例', description = '二次确认', intent = 'demo:to_confirm' },
            { id = 'to_range', kind = 'nav', label = '滑杆示例', description = '独立 surface', intent = 'demo:to_range' },
            { id = 'toast', kind = 'action', label = '弹一条提示', intent = 'demo:toast' },
            { id = 'denied', kind = 'action', label = '触发服务端拒绝', description = '未注册的 intent 应被拒', intent = 'demo:denied' },
            { id = 'off', kind = 'action', label = '禁用项示例', description = 'disabled = true', disabled = true },
        },
    }

    registerDemoIntents()

    RegisterCommand('cmenudemo', function()
        local ok, err = menuOpen(demoRoot)
        if not ok then
            print(('[custom-menu] demo 打开失败：%s'):format(tostring(err)))
        end
    end, false)
end
