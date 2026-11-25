-- client/menu_shim.lua — menuv ↔ custom-ui 输入栈垫片（#353）
--
-- 真机症状（2026-11-25）：
--   * 手机开着时 /admin 还能叠开 —— menuv 既不查栈，别的菜单也看不见它；
--   * /admin 开着按 Esc 关不掉，反而呼出游戏暂停菜单 —— menuv 只在 NUI 有焦点时
--     才看得到 Esc，而它从不调 SetNuiFocus。
--
-- 这里只补三件事，不改 menuv 本体、也不写第二份焦点：
--   1. 打开前问 custom-ui:IsTaken()，被别的界面占用就拒绝并提示；
--   2. 打开时 Push('adminmenu')、关闭时 Pop —— 让手机/中控/背包看得见它；
--   3. 菜单开着期间只屏蔽暂停控制 199/200，并用 IsDisabledControlJustPressed 消费 Esc。
--
-- M6(#348): menuv 下线后删除本垫片。

local STACK_ID = 'adminmenu'

-- GTA 里 Esc 对应两个暂停控制号（custom-ui/client/main.lua:28-29 也是两个都挡）；
-- 只挡一个在部分输入配置下会漏，暂停菜单照样弹出来。
local PAUSE_CONTROLS = { 199, 200 }

-- menuv 的键盘导航靠它自己的 RegisterKeyMapping（方向/确认/返回），不是 NUI 焦点。
-- 这几个控制不放进 custom-ui 的屏蔽名单，避免控制屏蔽顺带压掉菜单导航。
local NAV_CONTROLS = { 172, 173, 174, 175, 176, 177, 186, 187, 188, 189 }

-- 本资源是否有一局 admin 菜单开着（Push 成功与否都要管 Esc）
local sessionActive = false

AdminMenuShim = AdminMenuShim or {}

local function customUiReady()
    return GetResourceState('custom-ui') == 'started'
end

local function stackIsTaken()
    if not customUiReady() then return false end
    local ok, taken = pcall(function() return exports['custom-ui']:IsTaken() end)
    return ok and taken == true
end

local function stackOwns(id)
    if not customUiReady() then return false end
    local ok, owns = pcall(function() return exports['custom-ui']:Owns(id) end)
    return ok and owns == true
end

local function stackHasFrame(id)
    if not customUiReady() then return false end
    local ok, path = pcall(function() return exports['custom-ui']:Path() end)
    if not ok or type(path) ~= 'table' then return false end

    for _, frameId in ipairs(path) do
        if frameId == id then return true end
    end

    return false
end

local function stackPush(frame)
    if not customUiReady() then return false end
    return (pcall(function() exports['custom-ui']:Push(frame) end))
end

local function stackPop(id)
    if not customUiReady() then return false end
    return (pcall(function() exports['custom-ui']:Pop(id) end))
end

-- custom-ui 的栈按下焦点时会回调帧 owner 的 ApplyFocus。这里只"认领"、不按焦点：
-- menuv 是原生/NUI 键盘菜单，不需要 NUI 焦点；缺这个导出时栈会退回自己按，
-- 等于把键盘交给没有 ui_page 的 custom-ui（真机表现：面板还在，键盘被吃走）。
-- 注意：本导出**不调用** SetNuiFocus —— 全仓焦点写入仍然只有 custom-ui 一处。
exports('ApplyFocus', function(hasFocus, hasCursor, keepInput)
    return true
end)

--- 打开 admin 菜单前问一次输入栈。
--- 自己的帧已经在栈顶（子菜单/返回父菜单）时不拦截。
---@return boolean
function AdminMenuShim.CanOpen()
    if stackOwns(STACK_ID) then return true end
    if not stackIsTaken() then return true end

    QBCore.Functions.Notify(Lang:t('error.menu_already_open'), 'error')
    return false
end

local function pushFrame()
    stackPush({
        id = STACK_ID,
        cursor = false,       -- menuv 不用鼠标
        keepInput = false,    -- 也不接管输入：键盘继续走 menuv 的 key mapping
        allow = NAV_CONTROLS, -- 菜单导航键不屏蔽
        owner = 'qb-adminmenu',
    })
end

--- 把 admin 菜单放进 custom-ui 的输入栈（幂等）。
local function reserve()
    sessionActive = true
    -- Owns = 自己就是栈顶；Path = 帧在栈里（被别的层压在下面）。两种都不重复 push。
    if stackOwns(STACK_ID) or stackHasFrame(STACK_ID) then return end
    pushFrame()
end

--- 从输入栈里弹出 admin 菜单（幂等）。
local function release()
    sessionActive = false
    if not stackHasFrame(STACK_ID) then return end
    stackPop(STACK_ID)
end

AdminMenuShim.Release = release

--- 关闭 admin 菜单（Esc / 强制关闭共用）：先收 menuv，再弹出栈。
function AdminMenuShim.Close()
    if MenuV then
        MenuV:CloseAll()
    end
    release()
end

local function blockPauseControls()
    for _, control in ipairs(PAUSE_CONTROLS) do
        DisableControlAction(0, control, true)
    end
end

local function escPressed()
    return IsDisabledControlJustPressed(0, 199) or IsDisabledControlJustPressed(0, 200)
end

--- 关闭后继续挡一小段 Esc：读到按下的那一帧已经过去，但引擎可能还在处理同一次按键。
local function drainEsc()
    local untilMs = GetGameTimer() + 300
    while GetGameTimer() < untilMs do
        blockPauseControls()
        Wait(0)
    end
end

-- 每次打开（含子菜单）递增；旧线程在下一帧自行退出。
local guardToken = 0

local function startGuard()
    guardToken = guardToken + 1
    local token = guardToken

    CreateThread(function()
        local seenOpen = false
        local startedAt = GetGameTimer()
        local nextStackCheck = startedAt + 500

        while token == guardToken do
            if not sessionActive then return end

            -- 栈被外部清过（/phonefix、custom-ui 重启）：菜单还开着就补回去
            if GetGameTimer() >= nextStackCheck then
                nextStackCheck = GetGameTimer() + 500
                if not stackHasFrame(STACK_ID) then pushFrame() end
            end

            if MenuV ~= nil and MenuV.CurrentMenu ~= nil then
                seenOpen = true
                blockPauseControls()
                if escPressed() then
                    AdminMenuShim.Close()
                    drainEsc()
                    return
                end
            elseif seenOpen then
                -- 由 menuv 自己关掉（Backspace / close_all / 资源逻辑）：只弹栈
                release()
                return
            elseif GetGameTimer() - startedAt > 5000 then
                -- 菜单始终没打开（menuv 未就绪 / 打开被拒）：别把栈永远占着
                release()
                return
            end

            Wait(0)
        end
    end)
end

--- 统一的打开入口：先问栈，再入栈，最后交给 menuv。
---@param menu table MenuV menu
---@return boolean opened
function AdminMenuShim.OpenMenu(menu)
    if not AdminMenuShim.CanOpen() then return false end

    reserve()
    startGuard()
    MenuV:OpenMenu(menu)
    return true
end

-- 资源卸载（restart / stop）：custom-ui 的栈不会自己清理已停资源留下的帧。
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    release()
end)
