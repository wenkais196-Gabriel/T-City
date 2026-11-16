-- vendor_focus_probe.lua — 真跑 client/vendor_focus.lua（不复制状态机）
--
-- 只桩原生/事件注册：
--   * SetNuiFocus / SetNuiFocusKeepInput → 记录调用顺序
--   * AddEventHandler                       → 捕获 onResourceStop
--   * CreateThread                         → 捕获死亡兜底线程，按需手动跑一次
--
-- 断言：
--   1. 初始不持有焦点、不调用原生；
--   2. 第一个 owner 申请时先 keepInput(true) 再 SetNuiFocus(true,true)；
--   3. 第二个 owner 不重复申请；逐个释放时只在最后一个 owner 离开时关；
--   4. 关焦点只 SetNuiFocus(false,false)，**不**把 keepInput 置 false；
--   5. 重新申请会重新打开；
--   6. 死亡兜底线程会 ReleaseAll；
--   7. ReleaseAll 幂等；
--   8. onResourceStop 只对当前资源生效，并额外复位 keepInput。
--
-- 用法:
--   lua5.4 vendor_focus_probe.lua <client/vendor_focus.lua>

local SOURCE = arg[1]
if not SOURCE then
    error('用法: lua5.4 vendor_focus_probe.lua <client/vendor_focus.lua>')
end

local file = assert(io.open(SOURCE, 'r'))
local source = file:read('a')
file:close()

-- ---------------------------------------------------------------------------
-- 桩
-- ---------------------------------------------------------------------------

local calls = {}
local handlers = {}
local threads = {}

local env = {
    SetNuiFocus = function(hasFocus, hasCursor)
        calls[#calls + 1] = { kind = 'focus', focus = hasFocus, cursor = hasCursor }
    end,
    SetNuiFocusKeepInput = function(value)
        calls[#calls + 1] = { kind = 'keep', value = value }
    end,
    GetCurrentResourceName = function() return 'custom-quest' end,
    AddEventHandler = function(name, fn) handlers[name] = fn end,
    CreateThread = function(fn) threads[#threads + 1] = fn end,
    PlayerPedId = function() return 1 end,
    IsEntityDead = function() return false end,
    Wait = function() end,
    print = function() end,
    -- 沙箱环境不会自动继承标准库全局；模块用到的都显式给。
    type = type,
    tostring = tostring,
    next = next,
    pairs = pairs,
    ipairs = ipairs,
}

local chunk = assert(load(source, '@vendor_focus', 't', env))
chunk()

local F = env.VendorFocus
assert(type(F) == 'table', 'vendor_focus.lua 没有导出 VendorFocus')

-- ---------------------------------------------------------------------------
-- 断言助手
-- ---------------------------------------------------------------------------

local checks, passed = 0, 0
local function check(name, ok, detail)
    checks = checks + 1
    if ok then
        passed = passed + 1
    else
        print(('FAIL %s: %s'):format(name, tostring(detail or '')))
    end
end

local function count(kind)
    local n = 0
    for _, call in ipairs(calls) do
        if call.kind == kind then n = n + 1 end
    end
    return n
end

local function keepFalse()
    local n = 0
    for _, call in ipairs(calls) do
        if call.kind == 'keep' and call.value == false then n = n + 1 end
    end
    return n
end

local function lastFocus()
    for index = #calls, 1, -1 do
        if calls[index].kind == 'focus' then return calls[index] end
    end
    return nil
end

-- 1) 初始
check('starts_released', F.IsActive() == false and #calls == 0,
    tostring(F.IsActive()) .. '/' .. tostring(#calls))

-- 2) 第一个 owner：先 keepInput，再 focus(true,true)
F.Acquire('offer')
check('open_sequence',
    F.IsActive() == true and #calls == 2
        and calls[1].kind == 'keep' and calls[1].value == true
        and calls[2].kind == 'focus' and calls[2].focus == true and calls[2].cursor == true,
    'calls=' .. tostring(#calls))

-- 3) 第二个 owner 不重复调用原生
F.Acquire('menu')
check('second_owner_is_free', #calls == 2 and F.IsActive() == true,
    'calls=' .. tostring(#calls))

-- 4) 还有 owner 时不关
F.ReleaseOwner('offer')
check('still_focused_with_menu', F.IsActive() == true and count('focus') == 1,
    'active=' .. tostring(F.IsActive()))

-- 5) 最后一个 owner 离开 → 关；keepInput 保留
F.ReleaseOwner('menu')
local closed = lastFocus()
check('close_on_last_owner',
    F.IsActive() == false and count('focus') == 2
        and closed.focus == false and closed.cursor == false
        and keepFalse() == 0,
    'active=' .. tostring(F.IsActive()) .. ' keepFalse=' .. tostring(keepFalse()))

-- 6) 重新申请会重新打开
F.Acquire('menu')
check('reopen_reapplies',
    F.IsActive() == true and count('focus') == 3 and count('keep') == 2,
    'focus=' .. tostring(count('focus')) .. ' keep=' .. tostring(count('keep')))

-- 7) 死亡兜底线程：Applied=true 时按下 250ms 轮询，IsEntityDead 返回 1 即释放
env.IsEntityDead = function() return 1 end
env.Wait = function() error('stop-thread') end
assert(type(threads[1]) == 'function', '没有注册死亡兜底线程')
pcall(threads[1])
check('death_releases_focus', F.IsActive() == false and count('focus') == 4,
    'active=' .. tostring(F.IsActive()) .. ' focus=' .. tostring(count('focus')))
env.IsEntityDead = function() return false end
env.Wait = function() end

-- 8) ReleaseAll 幂等
F.Acquire('offer')
local before = count('focus')
F.ReleaseAll('test')
local afterFirst = count('focus')
F.ReleaseAll('again')
check('release_all_is_idempotent',
    F.IsActive() == false and afterFirst == before + 1 and count('focus') == afterFirst,
    ('before=%d first=%d second=%d'):format(before, afterFirst, count('focus')))

-- 9) onResourceStop：别的资源不处理；本资源关焦点 + 复位 keepInput
assert(type(handlers.onResourceStop) == 'function', '没有注册 onResourceStop')
local stopBefore = #calls
handlers.onResourceStop('other-resource')
check('stop_ignores_other_resources', #calls == stopBefore,
    tostring(#calls - stopBefore))

F.Acquire('menu')
handlers.onResourceStop('custom-quest')
check('stop_releases_and_resets_keepinput',
    F.IsActive() == false and keepFalse() == 1
        and lastFocus().focus == false and lastFocus().cursor == false,
    'active=' .. tostring(F.IsActive()) .. ' keepFalse=' .. tostring(keepFalse()))

print(('SUMMARY %d/%d'):format(passed, checks))
if passed ~= checks then
    os.exit(1)
end
