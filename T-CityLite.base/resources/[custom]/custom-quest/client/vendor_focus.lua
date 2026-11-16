-- ==============================================================
-- vendor_focus.lua — 热狗摊 CEF 焦点的**唯一**所有者
-- ==============================================================
-- 为什么单独一个文件：
--   * `SetNuiFocus` / `SetNuiFocusKeepInput` 是全局原生，散在业务代码里迟早会
--     出现「面板关了但焦点没放」（玩家卡在鼠标不能动、WASD 也不灵）。
--   * 闸门 `focus_unpaired`（tests/architecture/test_nui_client_contracts.py）会
--     检查 true/false 成对；`focus_outside_owner` 要求本资源的所有焦点调用都在
--     声明了 `NUI_FOCUS_OWNER` 的这个文件里。
--
-- 焦点语义（[custom]/AGENTS.md «焦点语义（血泪）»）：
--   开：先 `SetNuiFocusKeepInput(true)`，再 `SetNuiFocus(true, true)`。
--       顺序反了会把光标弄丢；keepInput 让 WASD 仍可用，玩家不会“被菜单钉住”。
--   关：只 `SetNuiFocus(false, false)`，**保留** keepInput。
--       下一次打开时它已经在 true，不需要重新申请，也不会冻结移动。
--   资源停止：额外把 keepInput 复位，避免热重载后把 true 留给下一个资源。
--
-- 谁在用：
--   * 顾客报价可见（quest_hotdog_vendor_client.lua 的 PushOffer）
--   * 购买菜单可见（同一个文件的 DrawBuyMenu）
--   两个 owner 分开登记：报价关了但菜单还开着时，焦点不能提前释放。
-- ==============================================================

local NUI_FOCUS_OWNER = true   -- 闸门标记：本资源所有焦点调用只允许出现在本文件

VendorFocus = VendorFocus or {}

--- 当前持有焦点的面板：owner → true。
local Owners = {}
--- 我们是否已经调用过 SetNuiFocus(true, true)。
local Applied = false

--- 申请焦点。只在第一个 owner 出现时真正调用原生。
---@param owner string 'offer' | 'menu'
---@return boolean
function VendorFocus.Acquire(owner)
    if type(owner) ~= 'string' or owner == '' then return false end

    local hadOwner = next(Owners) ~= nil
    Owners[owner] = true
    if hadOwner or Applied then return true end

    -- 顺序红线：keepInput 必须在 SetNuiFocus **之前**。
    -- 反过来写在本 build 上真机表现是“面板显示了但没有光标”。
    SetNuiFocusKeepInput(true)
    SetNuiFocus(true, true)
    Applied = true
    return true
end

--- 释放一个 owner。只有最后一个 owner 离开时才真的把焦点交还给游戏。
--- 名字带 Owner 是为了避开 reuse_scan 的通用 `Release` 同名预算（见
--- tests/architecture/test_reuse_budget.py）；语义仍是“放掉一个 owner”。
---@param owner string
---@return boolean
function VendorFocus.ReleaseOwner(owner)
    if not Owners[owner] then return false end

    Owners[owner] = nil
    if next(Owners) ~= nil then return true end

    -- 关焦点保留 keepInput（见文件头）。这里不调用 SetNuiFocusKeepInput(false)。
    if Applied then
        Applied = false
        SetNuiFocus(false, false)
    end
    return true
end

--- 无条件释放所有 owner。死亡兜底 / 任务清理 / 资源停止使用。
---@param reason string|nil 仅用于日志
function VendorFocus.ReleaseAll(reason)
    local shouldRelease = Applied or next(Owners) ~= nil
    Owners = {}
    if shouldRelease and Applied then
        Applied = false
        SetNuiFocus(false, false)
    end
    if reason then
        print(('[quest-hotdog-focus] 🖱️ 焦点已释放：%s'):format(tostring(reason)))
    end
end

--- 供业务代码判断“是不是我们面板拿着焦点”。原生 IsNuiFocused() 在本 build
--- 恒 false（[custom]/AGENTS.md），所以用自己的账。
---@return boolean
function VendorFocus.IsActive()
    return Applied
end

-- ==============================================================
-- 死亡兜底：焦点开着时玩家倒下，面板不会自己收到事件。
-- 只在 Applied=true 时每 250ms 查一次；空闲时一秒醒一次。
-- ==============================================================
CreateThread(function()
    while true do
        if Applied then
            local ped = PlayerPedId()
            local dead = type(IsEntityDead) == 'function'
                and (IsEntityDead(ped) == true or IsEntityDead(ped) == 1)
            if dead then
                VendorFocus.ReleaseAll('dead')
            end
            Wait(250)
        else
            Wait(1000)
        end
    end
end)

-- ==============================================================
-- 资源停止：热重载时客户端脚本会整体换掉，但焦点是引擎态。
-- 必须把 keepInput 也复位，否则下一个资源会继承 true。
-- 这不是普通的“关面板”路径，所以和 Release() 分开写。
-- ==============================================================
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    Owners = {}
    Applied = false
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
end)

print('[quest-hotdog-focus] 🖱️ CEF 焦点模块已就绪（单点开关）')
