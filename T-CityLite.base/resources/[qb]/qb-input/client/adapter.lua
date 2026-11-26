--[[
    qb-input → custom-menu 表单适配层（issue #366）

    convar `qb_menu_use_custom_menu` 默认 false：关着时本文件直接返回，main.lua 的
    ShowInput 原样执行（回滚路径）。打开时把 { header, inputs, submitText } 翻译成
    MenuSpec 的 form surface；取消必须回传 nil —— 老调用方普遍写 `if not result then`。

    select / radio / color / checkbox 在 MenuSpec 里没有对应 kind，硬翻译会丢选项值，
    所以含这些类型的对话框整张退回旧 NUI（行为与改造前一致，见回归清单 §4）。
]]

local RESOURCE = GetCurrentResourceName()
local CUSTOM_MENU = 'custom-menu'

--- 与 qb-menu 的适配层同一条规则：**调用时**判断是否接管，不在加载时判断。
local function isEnabled()
    local shared = GlobalState and GlobalState.qb_menu_use_custom_menu
    if shared == true then return true end
    if shared == false then return false end
    return GetConvar('qb_menu_use_custom_menu', 'false') == 'true'
end

local SUPPORTED_INPUT = {
    text = true,
    password = true,
    number = true,
}

local state = {
    seq = 0,
    pending = nil,  -- { owner, specId, done, resolve }
    routes = {},    -- owner -> true
}

local function callMenu(method, ...)
    local api = exports[CUSTOM_MENU]
    local ok, result, extra = pcall(api[method], api, ...)
    if ok then
        return result, extra
    end
    print(('[qb-input] custom-menu:%s 调用失败：%s'):format(method, tostring(result)))
    return false, 'call_failed'
end

local function hasText(value)
    return type(value) == 'string' and #value > 0
end

local function settleDialog(value)
    local pending = state.pending
    if not pending or pending.done then
        return
    end
    pending.done = true
    state.pending = nil
    pending.resolve(value)
end

local function buildSpec(data, owner)
    local items = {}
    local seen = {}
    for i = 1, #data.inputs do
        local input = data.inputs[i]
        if type(input) ~= 'table' or not SUPPORTED_INPUT[input.type] then
            return nil
        end
        local name = input.name
        if not hasText(name) or #name > 64 or seen[name] then
            return nil
        end
        seen[name] = true
        local item = {
            id = name,
            kind = 'input',
            inputType = input.type,
            label = hasText(input.text) and input.text or name,
            required = input.isRequired == true or input.isRequired == 'true',
        }
        if hasText(input.text) then
            item.placeholder = input.text
        end
        if type(input.default) == 'string' or type(input.default) == 'number' then
            item.defaultValue = tostring(input.default)
        end
        items[#items + 1] = item
    end
    if #items == 0 then
        return nil
    end

    state.seq = state.seq + 1
    return {
        id = ('qbi_%d'):format(state.seq),
        title = hasText(data.header) and data.header or 'Form Title',
        surface = 'form',
        submitLabel = hasText(data.submitText) and data.submitText or 'Submit',
        intent = ('qb-input:%s:submit'):format(owner),
        items = items,
    }
end

local function ensureRoute(owner)
    if state.routes[owner] then
        return true
    end
    local intentId = ('qb-input:%s:submit'):format(owner)
    if #intentId > 128 then
        return false
    end
    local ok = callMenu('RegisterIntent', intentId, {
        type = 'client',
        handler = function(ctx)
            local pending = state.pending
            if not pending or pending.owner ~= owner or pending.specId ~= ctx.menuId then
                return
            end
            local values = {}
            if type(ctx.values) == 'table' then
                for key, value in pairs(ctx.values) do
                    values[key] = value
                end
            end
            -- form surface 提交后不会自动关菜单；旧 qb-input 是提交即关
            callMenu('Close', 'qb_input_submit')
            settleDialog(values)
        end,
    })
    if ok ~= true then
        return false
    end
    state.routes[owner] = true
    return true
end

--- 取消 / Esc / 被别的资源顶掉时宿主不会回调我们：轮询 IsOpen 补 nil。
local function watchClosed(pending)
    CreateThread(function()
        while not pending.done do
            Wait(100)
            if pending.done then
                return
            end
            local open = callMenu('IsOpen')
            if open ~= true then
                settleDialog(nil)
            end
        end
    end)
end

local function show(data, legacy, legacyBusy)
    if not isEnabled() then
        -- 回滚路径：与改造前完全一致（包括它自己那两处 SetNuiFocus）。
        if type(legacy) == 'function' then
            return legacy(data)
        end
        return nil
    end
    if type(data) ~= 'table' or type(data.inputs) ~= 'table' then
        return legacy(data)
    end
    -- 旧实现是全局单飞：上一张没关之前，再调直接返回 nil。
    -- legacyBusy() 覆盖「回退到旧 NUI 的对话框还开着」的情况。
    if state.pending ~= nil or (legacyBusy and legacyBusy()) then
        return nil
    end
    if GetResourceState(CUSTOM_MENU) ~= 'started' then
        return legacy(data)
    end

    local okInvoke, caller = pcall(GetInvokingResource)
    local owner = (okInvoke and type(caller) == 'string' and caller ~= '') and caller or RESOURCE
    local spec = buildSpec(data, owner)
    if not spec or not ensureRoute(owner) then
        return legacy(data)
    end

    local promise = promise.new()
    local pending = {
        owner = owner,
        specId = spec.id,
        done = false,
        resolve = function(value) promise:resolve(value) end,
    }
    state.pending = pending

    -- 必须先让出一帧再 Open：qb-menu 的 item 事件是同步触发的，父菜单的 submenu
    -- builder 会在本函数返回后决定要不要关父菜单；同步 Open 会被它的收尾 Close
    -- 关掉（真机表现：点「卖出」表单闪一下就消失）。
    Wait(0)
    if state.pending ~= pending then
        return nil
    end

    local opened, err = callMenu('Open', spec)
    if opened ~= true then
        state.pending = nil
        print(('[qb-input] custom-menu 打开失败：%s'):format(tostring(err or opened)))
        return nil
    end

    watchClosed(pending)
    return Citizen.Await(promise)
end

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= RESOURCE then
        return
    end
    if state.pending then
        callMenu('Close', 'qb_input_stopped')
        settleDialog(nil)
    end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName == CUSTOM_MENU or resourceName == 'custom-ui' then
        settleDialog(nil)
    end
end)

_G.QBInputAdapter = {
    enabled = true,
    show = show,
}
