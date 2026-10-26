-- client/core/device_lock.lua — 平板打开时的移动锁。
--
-- 只用逐帧 DisableControlAction，不用 SetPlayerControl(false) / FreezeEntityPosition：
-- 后两个是"粘性"状态，循环一旦死掉人就永久卡住。逐帧禁用的最坏情况是"这一帧没禁住"，
-- 下一帧不跑就等于自动解锁 —— 失败方向是安全的。
--
-- 退出条件只有三个：DeviceLock.End()、实体死亡、ped 不存在。三者都会让线程自己结束。

DeviceLock = DeviceLock or {}

-- 30-35：走 / 跑 / 跳 / 蹲 / 冲刺 / 前后左右移动
local MOVE_CONTROLS = { 30, 31, 32, 33, 34, 35 }

local active = false

function DeviceLock.IsLocked() return active end
function DeviceLock.Controls() return MOVE_CONTROLS end

--- 按形态决定是否上锁。手机：空操作（可以边跑边看）。
---@param kind string 'phone'|'tablet'
function DeviceLock.Begin(kind)
    if kind ~= 'tablet' then
        active = false
        return false
    end
    if active then return true end
    active = true
    CreateThread(function()
        while active do
            local ped = PlayerPedId()
            if not DoesEntityExist(ped) or IsEntityDead(ped) then
                -- 死了还锁着就没法点重生按钮
                active = false
                break
            end
            for index = 1, #MOVE_CONTROLS do
                DisableControlAction(0, MOVE_CONTROLS[index], true)
            end
            Wait(0)
        end
        active = false
    end)
    return true
end

--- 任何关闭路径都必须调它（用户关闭、超时、切换、资源停止、/phonefix）。
function DeviceLock.End()
    active = false
end
