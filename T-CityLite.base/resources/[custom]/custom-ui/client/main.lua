-- client/main.lua — T-City 通用菜单/焦点工具
--
-- 解决所有 NUI 菜单的共性问题：
--   1. SetNuiFocus / SetNuiFocusKeepInput 成对管理
--   2. 关闭菜单后短时间屏蔽攻击/瞄准/武器轮盘，避免"点关闭打一拳"
--   3. 统一的距离判断
--
-- 用法:
--   exports['custom-ui']:OpenMenu({ keepInput = false })
--   exports['custom-ui']:CloseMenu()
--   exports['custom-ui']:GuardControls(300)
--   exports['custom-ui']:DistanceToCoords(vector3(...), 3.0)

local isOpen = false

local GUARD_CONTROLS = {
    24,  -- INPUT_ATTACK
    257, -- INPUT_ATTACK2
    25,  -- INPUT_AIM
    37,  -- INPUT_SELECT_WEAPON
    14,  -- INPUT_WEAPON_WHEEL_NEXT
    15,  -- INPUT_WEAPON_WHEEL_PREV
    16,  -- INPUT_SELECT_NEXT_WEAPON
    17,  -- INPUT_SELECT_PREV_WEAPON
    81,  -- INPUT_VEH_RADIO_WHEEL
    82,  -- INPUT_VEH_NEXT_RADIO
    83,  -- INPUT_VEH_PREV_RADIO
}

--- 短时间屏蔽会误触的攻击/武器轮盘控制
---@param durationMs number|nil 默认 300ms
function GuardControls(durationMs)
    local untilMs = GetGameTimer() + (durationMs or 300)
    CreateThread(function()
        while GetGameTimer() < untilMs do
            for _, control in ipairs(GUARD_CONTROLS) do
                DisableControlAction(0, control, true)
            end
            Wait(0)
        end
    end)
end

--- 打开菜单
---@param opts table|nil { keepInput = boolean }
function OpenMenu(opts)
    opts = opts or {}
    -- Reset first: another resource (notably qb-menu's old one-argument
    -- SetNuiFocus(false)) can leave the NUI half-focused, and a plain
    -- SetNuiFocus(true, true) then shows the page without a usable cursor.
    SetNuiFocus(false, false)
    SetNuiFocus(true, true)
    -- qb-phone never calls SetNuiFocusKeepInput(false): movement keeps working
    -- while the phone is open and only look/attack are disabled per frame. An
    -- explicit false here was what froze WASD, so only opt in when asked.
    if opts.keepInput then SetNuiFocusKeepInput(true) end
    isOpen = true
    -- Some builds ignore the cursor flag when focus is granted in the same
    -- frame as the reset. Re-assert it after one frame and again after 100ms;
    -- no keepInput call after this point (it can drop the cursor again).
    CreateThread(function()
        Wait(0)
        if not isOpen then return end
        SetNuiFocus(true, true)
        Wait(100)
        if isOpen then SetNuiFocus(true, true) end
    end)
end

--- 关闭菜单：释放焦点 + 防误触保护
---@param opts table|nil { guardMs = number }
function CloseMenu(opts)
    opts = opts or {}
    isOpen = false
    SetNuiFocus(false, false)
    -- Do not force keepInput off here: qb-phone leaves it alone and movement
    -- resumes after close because focus is already gone.
    GuardControls(opts.guardMs or 300)
end

--- 菜单是否打开
function IsMenuOpen()
    return isOpen
end

-- ==============================================================================
-- 交互路径（栈）—— 像 GTA 暂停菜单那样"打开即接管、逐层返回"
-- ==============================================================================
--
-- 世界 → 手机 → App → 输入框，每一层是一"帧"。规则只有一条：
-- **栈顶那一帧拥有键盘**，栈空时把输入还给游戏（于是 Esc 能呼出原生暂停菜单）。
--
--   Input.Push({ id='phone', close=ClosePhone })
--   Input.Push({ id='phone:mdt', close=... })      -- 进 App
--   Input.Push({ id='phone:mdt/search', kind='text' })
--   Input.Pop('phone:mdt/search')                  -- Esc 退出输入框
--   Input.Pop('phone:mdt')                          -- Esc 回桌面
--   Input.Pop('phone')                              -- Esc 关手机 → 下一层是游戏本身
--
-- 为什么不是纯布尔计数器：Esc 链要求"返回一层"，没有栈就不知道返回哪。
-- 为什么不用 IsNuiFocused()：本 build 上它恒为 false（见 nui-debug-playbook）。
Input = Input or {}

local path = {}
local captureThread = false
-- 记住 keepInput：与 PhoneFocus 一样，关闭时**不要**把它关掉（那会让下次开手机冻住 WASD）
local state = { keepInput = false }

local function topFrame()
    return path[#path]
end

--- 重算焦点与控制屏蔽：只有栈顶说了算。
local function apply()
    local frame = topFrame()
    if not frame then
        -- 顺序很关键：**先摘 keepInput，再放焦点**。
        -- 反过来的话游戏以为 NUI 还在吃输入，鼠标视角被锁死
        -- （真机现象："手机收起来了，但视角转不动"）。
        if state.keepInput then
            SetNuiFocusKeepInput(false)
            state.keepInput = false
        end
        SetNuiFocus(false, false)
        -- 栈空 = 输入还给游戏。Esc/暂停菜单要能在这一层工作。
        return
    end
    local keepInput = frame.keepInput == true
    -- keepInput 必须在 SetNuiFocus **之前**设：之后调用会把光标弄丢
    -- （真机现象："手机开着但看不到游标，还能点进 App"）。
    if state.keepInput ~= keepInput then
        SetNuiFocusKeepInput(keepInput)
        state.keepInput = keepInput
    end
    -- 第二个参数是**光标**，不是 keepInput —— 这两个搞混过一次。
    local cursor = frame.cursor ~= false
    SetNuiFocus(true, cursor)
    if cursor then
        -- 有些 build 在同一帧给焦点会把光标标志吃掉，和 OpenMenu 一样补两帧
        CreateThread(function()
            Wait(0)
            if topFrame() then SetNuiFocus(true, true) end
            Wait(100)
            if topFrame() then SetNuiFocus(true, true) end
        end)
    end
    if captureThread then return end
    captureThread = true
    CreateThread(function()
        while topFrame() do
            local current = topFrame()
            DisableAllControlActions(0)
            if current and current.allow then
                for _, control in ipairs(current.allow) do
                    EnableControlAction(0, control, true)
                end
            end
            Wait(0)
        end
        captureThread = false
    end)
end

--- 压入一帧
---@param frame table { id = string, kind = 'modal'|'text'|nil, allow = table|nil, keepInput = boolean|nil, close = function|nil }
---@return boolean ok, string|nil err
function Input.Push(frame)
    if type(frame) ~= 'table' or type(frame.id) ~= 'string' or frame.id == '' then
        return false, 'frame id required'
    end
    if #path > 0 and topFrame().id == frame.id then
        return true -- 幂等：同一帧重复打开不算新层
    end
    -- 已经在这条路径上（比如重复打开手机）就先弹到它，避免套娃
    for index = #path, 1, -1 do
        if path[index].id == frame.id then
            for _ = #path, index + 1, -1 do table.remove(path) end
            path[index] = frame
            apply()
            return true
        end
    end
    path[#path + 1] = frame
    apply()
    return true
end

--- 弹出指定帧（以及它上面的所有帧）；不给 id 就弹栈顶
---@param id string|nil
---@return string|nil poppedId
function Input.Pop(id)
    if #path == 0 then return nil end
    if id == nil then
        local removed = table.remove(path)
        apply()
        return removed and removed.id or nil
    end
    for index = #path, 1, -1 do
        if path[index].id == id then
            local removed = path[index]
            for _ = #path, index, -1 do table.remove(path) end
            apply()
            return removed.id
        end
    end
    return nil
end

--- 栈顶帧（nil = 没有 UI 占用）
function Input.Top()
    local frame = topFrame()
    if not frame then return nil end
    return { id = frame.id, kind = frame.kind, allow = frame.allow }
end

--- 当前路径，底 → 顶，如 { 'phone', 'phone:mdt', 'phone:mdt/search' }
function Input.Path()
    local out = {}
    for index, frame in ipairs(path) do out[index] = frame.id end
    return out
end

--- 有没有任何 UI 占着输入（玩法脚本用它做门卫）
function Input.IsTaken()
    return #path > 0
end

--- 栈顶是不是这一帧
function Input.Owns(id)
    local frame = topFrame()
    return frame ~= nil and frame.id == id
end

--- 强制清空（资源停止、/phonefix 这类硬复位）
function Input.Reset()
    path = {}
    apply()
end

--- 玩家与坐标的距离
function DistanceToCoords(coords, maxDistance)
    if not coords then return false, 9999.0 end
    local ped = PlayerPedId()
    local playerCoords = GetEntityCoords(ped)
    local target = vector3(coords.x, coords.y, coords.z)
    local dist = #(playerCoords - target)
    return dist <= (maxDistance or 3.0), dist
end

exports('OpenMenu', OpenMenu)
exports('CloseMenu', CloseMenu)
exports('GuardControls', GuardControls)
exports('IsMenuOpen', IsMenuOpen)
exports('Push', Input.Push)
exports('Pop', Input.Pop)
exports('Top', Input.Top)
exports('Path', Input.Path)
exports('IsTaken', Input.IsTaken)
exports('Owns', Input.Owns)
exports('ResetInput', Input.Reset)
exports('DistanceToCoords', DistanceToCoords)

print('[custom-ui] ✅ menu focus/guard/distance helpers ready')
