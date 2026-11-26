--[[
    qb-menu → custom-menu 适配层（issue #366）

    convar `qb_menu_use_custom_menu` 默认 false：关着时本文件直接返回，main.lua 的
    原有路径一行不变（这就是回滚路径）。打开时把老结构
        { header, txt, icon, disabled, params = { event, args, isServer, ... } }
    翻译成 MenuSpec，交给 custom-menu 的导出；存量调用点（145 处 / 20 个资源）不改。

    归因：每次 open 用 GetInvokingResource() 记下调用方；closeMenu() 只关调用方
    自己的那个 session —— 老实现是全局单例，任何资源都能关掉别人的界面。

    叠栈：点击 params.event（普通客户端事件）时把事件跑在 custom-menu 的 submenu
    builder 里；事件里同步再调 openMenu 的，作为子菜单压栈，Backspace 能回上一级。
]]

local RESOURCE = GetCurrentResourceName()
local CUSTOM_MENU = 'custom-menu'

--- 是否接管：GlobalState（服务端下发，跨客户端最可靠）或 convar 任一为真。
---
--- 关键：**在调用时判断，不在加载时判断**。加载时判断的话，运维事后 `setr` 打开开关
--- 必须重启资源甚至重连客户端才生效 —— 2026-11-26 真机实测：服务端 convar 是 true、
--- 客户端 `GetConvar` 读不到，适配层静默不接管，玩家侧表现就是"还是旧 UI"。
--- 所以：文件永远加载，`adaptOpen` 里再问一次。
local function isEnabled()
    local shared = GlobalState and GlobalState.qb_menu_use_custom_menu
    if shared == true then return true end
    if shared == false then return false end
    return GetConvar('qb_menu_use_custom_menu', 'false') == 'true'
end

local state = {
    seq = 0,
    current = nil,  -- { owner = <resource>, rootId = <spec id> }
    menus = {},     -- specId -> { owner = <resource>, items = { [原下标] = 老 item } }
    capture = nil,  -- 二级菜单同步 reopen 的捕获上下文
    routes = {},    -- owner -> true（两个 intent 已注册）
}

local function invoke(method, ...)
    local api = exports[CUSTOM_MENU]
    local ok, a, b = pcall(api[method], api, ...)
    if not ok then
        print(('[qb-menu] custom-menu:%s 调用失败：%s'):format(method, tostring(a)))
        return false, 'call_failed'
    end
    return a, b
end

local function customMenuStarted()
    return GetResourceState(CUSTOM_MENU) == 'started'
end

local function invokingResource()
    local ok, name = pcall(GetInvokingResource)
    if ok and type(name) == 'string' and name ~= '' then
        return name
    end
    return RESOURCE
end

local function nonEmptyString(value)
    return type(value) == 'string' and #value > 0
end

local function paramsOf(item)
    return type(item.params) == 'table' and item.params or {}
end

local function clearState()
    state.current = nil
    state.menus = {}
    state.capture = nil
end

--- 只关调用方自己的菜单。owner 为 nil 表示内部路径（NUI / 资源卸载）。
local function closeSession(owner, reason)
    local current = state.current
    if not current then
        return false
    end
    if owner ~= nil and current.owner ~= owner then
        return false
    end
    clearState()
    invoke('Close', reason or 'qb_menu_close')
    return true
end

local function runLegacyAction(item)
    if type(item.action) == 'function' then
        item.action()
        return
    end
    local params = paramsOf(item)
    local event = params.event
    if event == nil then
        return
    end
    if params.isServer then
        TriggerServerEvent(event, params.args)
    elseif params.isCommand then
        ExecuteCommand(event)
    elseif params.isQBCommand then
        TriggerServerEvent('QBCore:CallCommand', event, params.args)
    elseif params.isAction then
        if type(event) == 'function' then
            event(params.args)
        end
    elseif type(event) == 'string' then
        TriggerEvent(event, params.args)
    end
end

local function handleItemIntent(owner, ctx)
    local menu = state.menus[ctx.menuId]
    local slot = type(ctx.args) == 'table' and ctx.args.slot or nil
    if not menu or menu.owner ~= owner or type(slot) ~= 'number' then
        return
    end
    local item = menu.items[slot]
    if type(item) ~= 'table' then
        return
    end
    -- 老 clickedButton 的顺序：先关菜单，再执行动作
    closeSession(owner, 'qb_menu_item')
    runLegacyAction(item)
end

local function handleMenuIntent(owner, ctx)
    local menu = state.menus[ctx.menuId]
    local slot = type(ctx.args) == 'table' and ctx.args.slot or nil
    if not menu or menu.owner ~= owner or type(slot) ~= 'number' then
        return nil
    end
    local item = menu.items[slot]
    if type(item) ~= 'table' then
        return nil
    end
    local event = paramsOf(item).event
    if type(event) ~= 'string' then
        return nil
    end

    local capture = { owner = owner, spec = nil }
    state.capture = capture
    local ok, err = pcall(TriggerEvent, event, paramsOf(item).args)
    state.capture = nil
    if not ok then
        print(('[qb-menu] 菜单事件 %s 执行失败：%s'):format(tostring(event), tostring(err)))
    end
    if capture.spec == nil then
        -- 事件没有同步再开一个 qb-menu 菜单（通知 / qb-input 表单 / 异步 open）：
        -- 老实现点击后关闭菜单，这里保持同样的收尾。
        closeSession(owner, 'qb_menu_event')
        return nil
    end
    return capture.spec
end

local function ensureRoutes(owner)
    if state.routes[owner] then
        return true
    end
    local itemIntent = ('qb-menu:%s:item'):format(owner)
    local menuIntent = ('qb-menu:%s:menu'):format(owner)
    if #itemIntent > 128 or #menuIntent > 128 then
        return false
    end
    local okItem, itemReason = invoke('RegisterIntent', itemIntent, {
        type = 'client',
        handler = function(ctx) handleItemIntent(owner, ctx) end,
    })
    if okItem ~= true then
        print(('[qb-menu] RegisterIntent(%s) 失败：%s'):format(itemIntent, tostring(itemReason)))
        return false
    end
    local okMenu, menuReason = invoke('RegisterIntent', menuIntent, {
        type = 'submenu',
        builder = function(ctx) return handleMenuIntent(owner, ctx) end,
    })
    if okMenu ~= true then
        print(('[qb-menu] RegisterIntent(%s) 失败：%s'):format(menuIntent, tostring(menuReason)))
        return false
    end
    state.routes[owner] = true
    return true
end

local function itemTitle(item, index)
    if nonEmptyString(item.header) then
        return item.header
    end
    return ('Item %d'):format(index)
end

local function itemDescription(item)
    if nonEmptyString(item.txt) then
        return item.txt
    end
    if nonEmptyString(item.text) then
        return item.text
    end
    return nil
end

--- 普通客户端事件才可能是"再开一个 qb-menu 菜单"；带 isServer/isCommand/
--- isQBCommand/isAction 或顶层 action 函数的走直接执行路径。
local function reopensMenu(item)
    local params = paramsOf(item)
    if type(params.event) ~= 'string' then
        return false
    end
    if params.isServer or params.isCommand or params.isQBCommand or params.isAction then
        return false
    end
    return type(item.action) ~= 'function'
end

local function sortItems(list, sort, skipFirst)
    if not sort then
        return list
    end
    local ordered = {}
    for i = 1, #list do ordered[i] = list[i] end
    local head = ordered[1]
    local body = {}
    for i = skipFirst and 2 or 1, #ordered do
        body[#body + 1] = ordered[i]
    end
    table.sort(body, function(a, b) return a.header < b.header end)
    local out = {}
    if skipFirst then out[1] = head end
    for i = 1, #body do out[#out + 1] = body[i] end
    return out
end

local function buildSpec(list, owner)
    local items, legacyItems = {}, {}
    local title, subtitle = '菜单', nil
    local startIndex = 1
    local head = list[1]
    if type(head) == 'table' and head.isMenuHeader == true then
        title = itemTitle(head, 1)
        subtitle = itemDescription(head)
        startIndex = 2
    end

    local itemIntent = ('qb-menu:%s:item'):format(owner)
    local menuIntent = ('qb-menu:%s:menu'):format(owner)

    for i = startIndex, #list do
        local legacy = list[i]
        if type(legacy) == 'table' and legacy.hidden ~= true then
            local mapped = {
                id = ('i%d'):format(i),
                label = itemTitle(legacy, i),
            }
            if legacy.isMenuHeader == true then
                mapped.kind = 'info'
            else
                mapped.kind = 'action'
                mapped.intent = reopensMenu(legacy) and menuIntent or itemIntent
                mapped.args = { slot = i }
                if legacy.disabled == true then
                    mapped.disabled = true
                end
            end
            mapped.description = itemDescription(legacy)
            if nonEmptyString(legacy.icon) then
                mapped.icon = legacy.icon
            end
            items[#items + 1] = mapped
            legacyItems[i] = legacy
        end
    end

    if #items == 0 and startIndex == 1 then
        -- 连标题都没有的数组在老实现里也不显示；只有标题的菜单保留（空 items 合法）
        return nil, nil
    end
    state.seq = state.seq + 1
    local spec = {
        id = ('qbm_%d'):format(state.seq),
        title = title,
        subtitle = subtitle,
        surface = 'list',
        items = items,
    }
    return spec, legacyItems
end

local function adaptOpen(data, sort, skipFirst, legacyOpen)
    if not isEnabled() then
        -- 回滚路径：与改造前完全一致，一行行为都不变。
        if type(legacyOpen) == 'function' then
            return legacyOpen(data, sort, skipFirst)
        end
        return
    end
    if type(data) ~= 'table' or next(data) == nil then
        return
    end
    local owner = invokingResource()
    local ordered = sortItems(data, sort, skipFirst)

    -- 二级菜单：事件里同步再调 openMenu → 只把 spec 交回 builder，由宿主压栈。
    -- owner == RESOURCE 是兜底：本地 TriggerEvent 的 handler 里再调 export 时，
    -- GetInvokingResource 不一定回得到发起事件的资源；capture 是同步窗口，
    -- 这里宁可认 captured owner，也不要让子菜单错成新的根。
    local capture = state.capture
    if capture and (capture.owner == owner or owner == RESOURCE) then
        local spec, legacyItems = buildSpec(ordered, capture.owner)
        if spec then
            state.menus[spec.id] = { owner = capture.owner, items = legacyItems }
            capture.spec = spec
        end
        return
    end

    local spec, legacyItems = buildSpec(ordered, owner)

    if not customMenuStarted() then
        return legacyOpen(data, sort, skipFirst)
    end
    if not spec then
        return
    end
    if not ensureRoutes(owner) then
        print('[qb-menu] 适配层注册 intent 失败，回退旧 NUI')
        return legacyOpen(data, sort, skipFirst)
    end

    clearState()
    state.menus[spec.id] = { owner = owner, items = legacyItems }
    state.current = { owner = owner, rootId = spec.id }
    local opened, err = invoke('Open', spec)
    if opened ~= true then
        clearState()
        print(('[qb-menu] custom-menu 打开失败：%s'):format(tostring(err or opened)))
    end
end

local function adaptClose(legacyClose)
    if not isEnabled() and type(legacyClose) == 'function' then
        return legacyClose()
    end
    return closeSession(invokingResource(), 'qb_menu_close')
end

local headerWarned = false

local function adaptShowHeader(data, legacyShowHeader)
    if not customMenuStarted() then
        return legacyShowHeader(data)
    end
    -- custom-menu 没有"不抢焦点、只画一行提示"的 surface；映射成 Open 会意外抢焦点。
    if not headerWarned then
        headerWarned = true
        print('[qb-menu] 适配层：showHeader 无被动渲染，已忽略（见 docs/client/ux/menu-regression-checklist.md §4）')
    end
end

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= RESOURCE then
        return
    end
    if state.current ~= nil then
        clearState()
        invoke('Close', 'qb_menu_stopped')
    end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName == CUSTOM_MENU or resourceName == 'custom-ui' then
        clearState()
    end
end)

_G.QBMenuAdapter = {
    enabled = true,
    openMenu = adaptOpen,
    closeMenu = adaptClose,
    showHeader = adaptShowHeader,
}
