-- client/core/focus.lua — NUI focus ownership stack.
--
-- One resource on this client owns NUI focus at a time. Owners push/pop instead
-- of each calling SetNuiFocus blind:
--
--   phone / fingerprint / story / vehicle (any string is accepted)
--
-- SetNuiFocus / SetNuiFocusKeepInput are only called from here, and every call
-- is recorded so PhoneFocus.State() can be logged. The phone's real-client
-- contract is preserved:
--
--   * Acquire('phone', {cursor=true, keepInput=true}) mirrors the old
--     SetNuiFocus(true,true) then SetNuiFocusKeepInput(true) order;
--   * releasing the last owner only releases focus (SetNuiFocus(false,false)).
--     It deliberately leaves keepInput alone — AGENTS.md documents that
--     turning it off after close freezes WASD on the next phone open;
--   * Reset() is the hard cleanup used on resource start/stop, /phonefix and
--     focus leaks: SetNuiFocus(false,false) + SetNuiFocusKeepInput(false);
--   * the default owner is 'phone', so Acquire()/Release()/IsOwner() without an
--     argument operate on the phone.
--
-- 现在它**只是外壳**：真正决定"谁拥有输入"的是 custom-ui 的交互路径栈
-- （见 docs/client/plans/2026-10-27-input-layering.md）。这里把 Acquire/Release
-- 翻译成 Push/Pop，并保留 State() 给诊断用；没有 custom-ui 时退化为老行为。
--
-- This file must load before client/main.lua.

PhoneFocus = PhoneFocus or {}

local DEFAULT_OWNER = 'phone'
local stack = {} -- bottom -> top: { owner = string, cursor = boolean, keepInput = boolean }
local state = {
    owner = nil,
    focus = false,
    cursor = false,
    keepInput = false,
}

local function ownerName(owner)
    if owner == nil then return DEFAULT_OWNER end
    if type(owner) ~= 'string' or owner == '' then return nil end
    return owner
end

local function setFocus(hasFocus, hasCursor)
    -- Variables keep a single call site: the state below is recorded from the
    -- same arguments, so logs can never disagree with the native call.
    SetNuiFocus(hasFocus, hasCursor)
    state.focus = hasFocus == true
    state.cursor = hasCursor == true
end

local function applyTop()
    local entry = stack[#stack]
    if entry then
        setFocus(true, entry.cursor)
        -- Re-assert keepInput when the active owner changes, and skip it when
        -- the same owner re-takes focus (phone watchdog): on some builds a
        -- keepInput call after SetNuiFocus can drop the cursor again.
        if state.owner ~= entry.owner or state.keepInput ~= entry.keepInput then
            SetNuiFocusKeepInput(entry.keepInput)
            state.keepInput = entry.keepInput
        end
        state.owner = entry.owner
        return
    end
    -- Last owner gone: release focus but leave keepInput untouched (see header).
    setFocus(false, false)
    state.owner = nil
end

local function stackSnapshot()
    local owners = {}
    for index = 1, #stack do owners[index] = stack[index].owner end
    return owners
end

-- 手机开着时允许穿透给游戏的控制：走路/冲刺。别的都归栈顶。
-- 30-35 是 MOVE_*，21 是 SPRINT —— 手机是"边走边看"，不是 GTA 暂停菜单。
local ALLOW_WHILE_OPEN = { 21, 30, 31, 32, 33, 34, 35 }

local function inputLayer()
    -- 用资源状态当门闩，而不是猜 exports 里有没有那个方法：
    -- 测试桩的 exports 会把任意键都返回成"可调用对象"，光看 Push 是否存在会误判。
    if GetResourceState == nil or GetResourceState('custom-ui') ~= 'started' then return nil end
    local ok, layer = pcall(function() return exports['custom-ui'] end)
    if not ok or not layer then return nil end
    return layer
end

local delegatedCache = { at = -1, value = false }
--- 当前是否由共享栈接管（true = 屏蔽与焦点不归我们管）。
---@return boolean
function PhoneFocus.Delegated()
    local now = GetGameTimer and GetGameTimer() or 0
    if now - delegatedCache.at < 2000 and delegatedCache.at >= 0 then
        return delegatedCache.value
    end
    delegatedCache.at = now
    delegatedCache.value = inputLayer() ~= nil
    return delegatedCache.value
end

local delegatedLogged = false
-- 委托状态缓存：每帧问一次 GetResourceState + exports 也是白烧，缓存 2s

local function frameId(owner)
    return owner == 'phone' and 'phone' or ('phone:' .. owner)
end

--- Take (or re-take) focus for `owner` — 委托给 custom-ui 的栈。
---@param owner string|nil defaults to 'phone'
---@param opts table|nil { cursor = boolean (default true), keepInput = boolean (default false) }
---@return boolean acquired
function PhoneFocus.Acquire(owner, opts)
    owner = ownerName(owner)
    if not owner then return false end
    opts = opts or {}
    local entry = {
        owner = owner,
        cursor = opts.cursor ~= false,
        keepInput = opts.keepInput == true,
    }
    local layer = inputLayer()
    if layer then
        -- 两种模式（真机都验过，二选一，不能同时）：
        --   1（默认，边走边看）：游戏继续处理输入 → 手机开着能走路，键盘走 Lua 原始按键；
        --                        代价：引擎把 OS 游标钉在屏幕角落，没有鼠标指针。
        --   0（完全接管）：交出鼠标 → 有游标、能点，但手机开着走不了路。
        local keep = entry.keepInput and GetConvar('phone_keep_input', '1') == '1'
        local ok = pcall(function()
            layer:Push({
                id = frameId(owner),
                cursor = entry.cursor,
                keepInput = keep,
                allow = keep and ALLOW_WHILE_OPEN or nil,
                -- 按焦点必须由**拥有 NUI 页面的资源**来做：在 custom-ui 里调
                -- SetNuiFocus 等于把焦点交给一个不存在的页面（真机表现：手机能显示，
                -- 但收不到鼠标键盘、也没有游标；背包和目标盘却正常）。
                -- 跨资源不能传函数，所以只报资源名，由 custom-ui 回调本资源的 ApplyFocus。
                owner = GetCurrentResourceName(),
            })
        end)
        if ok then
            state.owner = owner
            state.focus = true
            state.cursor = entry.cursor
            -- 报"实际生效"的那个值：convar 可能把 keepInput 关掉，
            -- 报请求值会让人以为 keepInput 还开着（诊断误导过一次）。
            state.keepInput = keep
            if not delegatedLogged then
                delegatedLogged = true
                print('[custom-phone][focus] delegated to custom-ui input path')
            end
            return true
        end
    end
    -- 退化：没有 custom-ui（比如单独测这个资源）时按老办法自己设焦点
    for index = #stack, 1, -1 do
        if stack[index].owner == owner then table.remove(stack, index) end
    end
    stack[#stack + 1] = entry
    applyTop()
    return true
end

--- 压入一个子帧（App / 输入框）。父帧已经在栈上；没有 custom-ui 时什么都不做。
---@param id string 例如 'phone:mdt'、'phone:text'
---@return boolean
function PhoneFocus.PushFrame(id)
    local layer = inputLayer()
    if not layer or type(id) ~= 'string' or id == '' then return false end
    local ok = pcall(function()
        layer:Push({
            id = id,
            cursor = true,
            keepInput = GetConvar('phone_keep_input', '1') == '1',
            allow = GetConvar('phone_keep_input', '1') == '1' and ALLOW_WHILE_OPEN or nil,
            owner = GetCurrentResourceName(),
        })
    end)
    return ok
end

--- 弹掉一个子帧（连同它上面的层）。
---@param id string
---@return boolean
function PhoneFocus.PopFrame(id)
    local layer = inputLayer()
    if not layer then return false end
    return pcall(function() return layer:Pop(id) end)
end

--- Release one owner. The next owner in the stack (if any) becomes active; if
--- the stack is empty, NUI focus is released and keepInput is left as the
--- project expects after a phone close.
---@param owner string|nil defaults to 'phone'
---@return boolean released whether an entry was removed
function PhoneFocus.Release(owner)
    owner = ownerName(owner)
    if not owner then return false end

    -- 先问共享栈：委托之后本地 stack 是空的，若先跑本地那段就会"没删到东西 → return false"，
    -- 结果是手机关了但帧还挂在栈上，屏蔽线程一直跑 —— 玩家动不了、还以为是卡
    -- （真机就是这么表现的：open=false 但 frames 里还有 'phone'）。
    local layer = inputLayer()
    if layer then
        local ok, popped = pcall(function() return layer:Pop(frameId(owner)) end)
        if ok and popped then
            if #stack == 0 or stack[#stack].owner == owner then
                state.owner = nil
                state.focus = false
            end
            return true
        end
    end

    local wasTop = #stack > 0 and stack[#stack].owner == owner
    local removed = false
    for index = #stack, 1, -1 do
        if stack[index].owner == owner then
            table.remove(stack, index)
            removed = true
        end
    end
    if not removed then return false end
    -- Removing a non-top owner does not change the active window; only the top
    -- (or the empty stack) needs a native call.
    if wasTop or #stack == 0 then applyTop() end
    return true
end

--- 由 custom-ui 回调：只有拥有 NUI 页面的资源才能真的把焦点按到页面上。
---@param hasFocus boolean
---@param hasCursor boolean
---@param keepInput boolean
function PhoneFocus.ApplyFocus(hasFocus, hasCursor, keepInput)
    if hasFocus then
        SetNuiFocusKeepInput(keepInput == true)
        SetNuiFocus(true, hasCursor ~= false)
        state.focus = true
        state.cursor = hasCursor ~= false
        state.keepInput = keepInput == true
    else
        if state.keepInput then SetNuiFocusKeepInput(false) end
        SetNuiFocus(false, false)
        state.focus = false
        state.cursor = false
        state.keepInput = false
    end
end

--- 重新把焦点按下去（页面加载完成后调用，见 ack 处理）。
---@return boolean
function PhoneFocus.Refresh()
    local layer = inputLayer()
    if layer then
        local ok = pcall(function() layer:RefreshFocus() end)
        if ok then return true end
    end
    local entry = stack[#stack]
    if entry then setFocus(true, entry.cursor) end
    return entry ~= nil
end

--- Hard cleanup: drop every owner and restore the pre-phone focus state.
--- Used on resource start/stop, /phonefix and when a focus leak is detected.
---@return boolean
function PhoneFocus.Reset()
    stack = {}
    local handled = false
    local layer = inputLayer()
    if layer then
        handled = pcall(function() layer:ResetInput() end)
    end
    -- 栈自己会把焦点放掉；再调一次原生就是重复（也会让"手机不碰 SetNuiFocus"失效）
    if not handled then
        setFocus(false, false)
        SetNuiFocusKeepInput(false)
    end
    state.owner = nil
    state.keepInput = false
    return true
end

--- Is `owner` the resource currently holding NUI focus?
---@param owner string|nil defaults to 'phone'
---@return boolean
function PhoneFocus.IsOwner(owner)
    owner = ownerName(owner)
    if not owner or #stack == 0 then return false end
    return stack[#stack].owner == owner
end

--- Immutable-enough snapshot for diagnostics/logs.
---@return table { owner, focus, cursor, keepInput, depth, stack }
function PhoneFocus.State()
    local path
    local layer = inputLayer()
    if layer then
        local ok, value = pcall(function() return layer:Path() end)
        if ok and type(value) == 'table' then path = value end
    end
    return {
        owner = state.owner,
        -- 是否走了共享栈（false = 退化到自己 SetNuiFocus，那时 keepInput 会是真的，
        -- 而 keepInput=true 会把鼠标扣在角落 → 看不到游标）
        delegated = inputLayer() ~= nil,
        focus = state.focus,
        cursor = state.cursor,
        keepInput = state.keepInput,
        depth = #stack,
        stack = stackSnapshot(),
        path = path,
    }
end

-- A client-side resource stop leaves the engine focus flag behind; clear it
-- even if main.lua's own stop handler never runs.
AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    PhoneFocus.Reset()
end)
