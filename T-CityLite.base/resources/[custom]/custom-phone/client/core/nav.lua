-- client/core/nav.lua — 手机/平板的键盘与手柄导航。
--
-- 为什么在 Lua 而不是浏览器里抢 Tab：keepInput=true 时游戏仍在处理输入，Tab 在 GTA 里有
-- 绑定，CEF 收不到（实测：连按 3 次 Tab + Enter，界面纹丝不动，见
-- docs/client/research/keyboard-and-gamepad-navigation.md §1）。而 GTA 的输入控制本身就把
-- 方向键/d-pad、Enter/A/B 映射到同一批 INPUT_*，所以在 Lua 轮询控制即可**一套代码同时覆盖
-- 键盘与手柄**，而且不会和游戏抢键。
--
-- 关闭时不跑任何循环（零 tick 开销）；每次按键都 DisableControlAction，避免同一下输入再被
-- 游戏当成移动/开火。

PhoneNav = PhoneNav or {}

-- 172-177 是"手机"控制组（方向键在手机上下文就映射到这里），186-189 是前端菜单组
-- （手柄方向在菜单上下文走这组）。**绝不能用 27-30**：那是 MOVE_UP/DOWN/LEFT/RIGHT，
-- 禁用它们等于把玩家钉在原地——CLIENT 用例里有一条专门守着这件事。
local DIR_CONTROLS = {
    up = { 172, 186 },
    down = { 173, 187 },
    left = { 174, 188 },
    right = { 175, 189 },
}
local ACCEPT = { 176 }  -- CELLPHONE_SELECT（Enter / 空格）
local CANCEL = { 177 }  -- CELLPHONE_CANCEL（Backspace）

-- 键盘单独走**原始按键**（Windows VK）：靠控制号读键盘有一个致命前提 ——
-- 游戏得把方向键映射到 172-175 那组手机控制上。实测在保持输入（keepInput）的情况下，
-- 玩家真按方向键时**轮询不到**（agent 注入的按键反而能到 CEF），于是"人打不动、
-- agent 能打"。IsRawKeyDown 不经过控制映射，硬件按了就为真。
local RAW = {
    up = 0x26, down = 0x28, left = 0x25, right = 0x27,
    accept = 0x0D, cancel = 0x08, escape = 0x1B,
    tab = 0x09, shift = 0x10,
    pageup = 0x21, pagedown = 0x22,
    home = 0x24, ['end'] = 0x23,
}
local rawPrev = {}

--- 每帧算出"这一帧刚按下的键"（原生只有 IsRawKeyDown，边沿自己算）。
local function rawEdges()
    local edges = {}
    for kind, vk in pairs(RAW) do
        local down = IsRawKeyDown ~= nil and IsRawKeyDown(vk) or false
        if down and not rawPrev[kind] then edges[kind] = true end
        rawPrev[kind] = down
    end
    return edges
end

local running = false

local function anyJustPressed(controls)
    for _, control in ipairs(controls) do
        if IsDisabledControlJustPressed(0, control) or IsControlJustPressed(0, control) then
            return true
        end
    end
    return false
end

-- 这里**不再** DisableControlAction。
-- 原因：indicators.lua 读的是 IsDisabledControlJustPressed(174/175/187)，我们一禁
-- 172-175 就等于替他按了转向灯（真机实测：手机里按方向键，车上灯乱闪）。
-- 屏蔽归 custom-ui 的交互路径栈，它只放行走路那几个控制。

local function emit(kind, dir)
    SendNUIMessage({ action = 'phone:nav', kind = kind, dir = dir })
end

--- 每帧调用一次（由手机开屏循环驱动）。自建线程会让"开屏期间每帧 tick 数"
--- 翻倍 —— CLIENT 用例 `open_loop_costs_one_tick_per_frame` 就是抓这个的。
function PhoneNav.Tick()
    if not running then return end
    if Surface == nil or not Surface.IsOpen or not Surface.IsOpen() then
        running = false
        return
    end

    -- 1) 键盘：原始按键优先。同一个键这一帧既被原始按键抓到、又出现在控制轮询里时，
    --    只走原始按键那条（否则一次按键会挪两格）。
    local edges = rawEdges()
    local moved = false
    for dir in pairs(DIR_CONTROLS) do
        if edges[dir] then
            emit('move', dir)
            moved = true
        end
    end
    if edges.tab then
        emit('move', edges.shift and 'up' or 'down')
        moved = true
    end
    if edges.pageup then emit('page', 'up') end
    if edges.pagedown then emit('page', 'down') end
    if edges.home then emit('edge', 'first') end
    if edges['end'] then emit('edge', 'last') end
    if edges.accept then emit('activate') end
    if edges.cancel or edges.escape then emit('back') end

    -- 2) 手柄（以及没被原始按键接住的键盘）：控制轮询兜底
    if not moved then
        for dir, controls in pairs(DIR_CONTROLS) do
            if anyJustPressed(controls) then emit('move', dir) end
        end
    end
    if not edges.accept and anyJustPressed(ACCEPT) then emit('activate') end
    if not edges.cancel and anyJustPressed(CANCEL) then emit('back') end
end

--- 开屏后调用：允许 Tick 工作。重复调用是安全的。
function PhoneNav.Start()
    running = true
end

--- 关屏时调用：停掉循环。
function PhoneNav.Stop()
    running = false
end

--- 给诊断用：当前是否在轮询。
function PhoneNav.IsRunning() return running end
