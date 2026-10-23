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
exports('DistanceToCoords', DistanceToCoords)

print('[custom-ui] ✅ menu focus/guard/distance helpers ready')
