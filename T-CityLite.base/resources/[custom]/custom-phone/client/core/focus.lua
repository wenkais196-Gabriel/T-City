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

--- Take (or re-take) focus for `owner`. Re-acquiring an existing owner moves it
--- to the top instead of stacking duplicates.
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
    for index = #stack, 1, -1 do
        if stack[index].owner == owner then table.remove(stack, index) end
    end
    stack[#stack + 1] = entry
    applyTop()
    return true
end

--- Release one owner. The next owner in the stack (if any) becomes active; if
--- the stack is empty, NUI focus is released and keepInput is left as the
--- project expects after a phone close.
---@param owner string|nil defaults to 'phone'
---@return boolean released whether an entry was removed
function PhoneFocus.Release(owner)
    owner = ownerName(owner)
    if not owner then return false end
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

--- Hard cleanup: drop every owner and restore the pre-phone focus state.
--- Used on resource start/stop, /phonefix and when a focus leak is detected.
---@return boolean
function PhoneFocus.Reset()
    stack = {}
    setFocus(false, false)
    SetNuiFocusKeepInput(false)
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
    return {
        owner = state.owner,
        focus = state.focus,
        cursor = state.cursor,
        keepInput = state.keepInput,
        depth = #stack,
        stack = stackSnapshot(),
    }
end

-- A client-side resource stop leaves the engine focus flag behind; clear it
-- even if main.lua's own stop handler never runs.
AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    PhoneFocus.Reset()
end)
