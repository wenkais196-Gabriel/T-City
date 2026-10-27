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

local running = false

local function anyJustPressed(controls)
    for _, control in ipairs(controls) do
        if IsDisabledControlJustPressed(0, control) or IsControlJustPressed(0, control) then
            return true
        end
    end
    return false
end

local function disableAll()
    for _, controls in pairs(DIR_CONTROLS) do
        for _, control in ipairs(controls) do
            DisableControlAction(0, control, true)
        end
    end
    for _, control in ipairs(ACCEPT) do DisableControlAction(0, control, true) end
    for _, control in ipairs(CANCEL) do DisableControlAction(0, control, true) end
end

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
    disableAll()
    for dir, controls in pairs(DIR_CONTROLS) do
        if anyJustPressed(controls) then emit('move', dir) end
    end
    if anyJustPressed(ACCEPT) then emit('activate') end
    if anyJustPressed(CANCEL) then emit('back') end
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
