-- seatbelt.lua — 安全带系统 (migrated from qb-smallresources)
-- v0.7b: 迁入 custom-vehicles，为车载中控面板集成铺路
--
-- 核心:
--   - /toggleseatbelt 命令
--   - SeatBeltLoop (禁用 F 下车键，防误操作)
--   - HasSeatbeltOn export
--   - 广播 seatbelt:client:ToggleSeatbelt 给 qb-hud 更新 UI
--   - 音效 feedback

local QBCore = exports['qb-core']:GetCoreObject()
local seatbeltOn = false

-- ==============================================================
-- 警报计时器 (必须在 toggleSeatbelt 前定义)
-- ==============================================================

local WARN_INTERVAL_MS = 8000  -- 现实车辆约 5-10s 一轮，配合 1-2s 短音频
local lastWarning = 0

local function resetWarningTimer()
    lastWarning = GetGameTimer()
end

-- ==============================================================
-- 核心: 安全带切换
-- ==============================================================

local function toggleSeatbelt()
    seatbeltOn = not seatbeltOn
    SeatBeltLoop()
    TriggerEvent('seatbelt:client:ToggleSeatbelt', seatbeltOn)
    TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 5.0,
        seatbeltOn and 'carbuckle' or 'carunbuckle', 0.25)
    if seatbeltOn then
        resetWarningTimer()  -- 系上后重置报警计时，15s 内即使解开也不立刻响
    end
end

-- ==============================================================
-- 安全带循环: 防止行驶中误按 F 下车
-- ==============================================================

function SeatBeltLoop()
    CreateThread(function()
        while true do
            if seatbeltOn then
                DisableControlAction(0, 75, true)  -- F key (exit vehicle)
                DisableControlAction(27, 75, true)
            end
            if not IsPedInAnyVehicle(PlayerPedId(), false) then
                seatbeltOn = false
                TriggerEvent('seatbelt:client:ToggleSeatbelt', false)
                break
            end
            if not seatbeltOn then break end
            Wait(0)
        end
    end)
end

-- ==============================================================
-- Export: 供外部查询安全带状态
-- ==============================================================

local function hasSeatbeltOn()
    return seatbeltOn
end

exports('HasSeatbeltOn', hasSeatbeltOn)

-- ==============================================================
-- 命令: /toggleseatbelt
-- ==============================================================

-- B 键安全带（车内时与车外 point 命令上下文互斥，无冲突）
RegisterKeyMapping('toggleseatbelt', 'Toggle Seatbelt', 'keyboard', 'B')

RegisterCommand('toggleseatbelt', function()
    if IsPauseMenuActive() then return end
    if not IsPedInAnyVehicle(PlayerPedId(), false) then
        QBCore.Functions.Notify('你必须坐在载具中才能系安全带', 'error')
        return
    end
    local class = GetVehicleClass(GetVehiclePedIsUsing(PlayerPedId()))
    if class == 8 or class == 13 or class == 14 then
        QBCore.Functions.Notify('此载具不支持安全带', 'error')
        return
    end
    toggleSeatbelt()
end, false)

-- ==============================================================
-- 离开车辆自动解安全带
-- ==============================================================

AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkPlayerLeftVehicle' then
        if args[1] == PlayerId() and seatbeltOn then
            seatbeltOn = false
            TriggerEvent('seatbelt:client:ToggleSeatbelt', false)
        end
    end
end)

-- ==============================================================
-- 未系安全带警报: 行驶中每 15 秒响一次 beltalarm
-- 仅驾驶席触发，乘客不警告
-- ==============================================================

local WARN_SPEED_THRESHOLD = 10.0

CreateThread(function()
    while true do
        Wait(2000)

        if LocalPlayer.state.isLoggedIn
            and not seatbeltOn
            and IsPedInAnyVehicle(PlayerPedId(), false)
        then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            local class = GetVehicleClass(veh)
            if class ~= 8 and class ~= 13 and class ~= 14
                and class ~= 15 and class ~= 16
                and class ~= 18 and class ~= 19 and class ~= 20 and class ~= 21
                and GetPedInVehicleSeat(veh, -1) == ped   -- 仅驾驶席
                and GetEntitySpeed(veh) * 3.6 >= WARN_SPEED_THRESHOLD
            then
                local now = GetGameTimer()
                if now - lastWarning >= WARN_INTERVAL_MS then
                    lastWarning = now
                    TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 5.0, 'beltalarm', 0.3)
                end
            end
        end
    end
end)

print('[custom-vehicles] 🔒 安全带系统已就绪 — /toggleseatbelt | 未系警报: beltalarm')
