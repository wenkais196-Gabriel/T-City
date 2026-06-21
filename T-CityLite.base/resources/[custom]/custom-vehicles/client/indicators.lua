-- indicators.lua — 转向灯 + 双闪 + 音效 (v0.8)
--
-- ← 方向键左 / → 方向键右: 手动 toggle
-- ←+→ 按住 300ms 或 中控屏: 双闪 (hazard)
-- 双闪下车不灭 — 手动关闭才灭
-- 音效: tick.ogg (转向灯 500ms) / hazard_tick.ogg (双闪 300ms 快节奏)
--
-- 排除: 摩托(8)、自行车(13)、船(14)、飞机(15/16)、火车(21)

local QBCore = exports['qb-core']:GetCoreObject()
local EXCLUDED_CLASSES = {
    [8]=true, [13]=true, [14]=true, [15]=true, [16]=true, [21]=true,
}

local leftOn = false
local rightOn = false
local hazardOn = false
local hazardPersist = false  -- 下车不灭标记

local function isExcluded(veh)
    return EXCLUDED_CLASSES[GetVehicleClass(veh)] or false
end

local function applyLights(veh)
    -- GTA5: side 0=右, 1=左 (与直觉相反)
    SetVehicleIndicatorLights(veh, 1, leftOn or hazardOn)
    SetVehicleIndicatorLights(veh, 0, rightOn or hazardOn)
end

-- ==============================================================
-- ← → toggle
-- ==============================================================

Citizen.CreateThread(function()
    while true do
        Wait(0)
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)

        if not veh or veh == 0 then
            -- 下车不灭双闪
            if (leftOn or rightOn) and not hazardOn then
                leftOn, rightOn = false, false
            end
            Wait(500)
            goto cont
        end

        if isExcluded(veh) then
            if leftOn or rightOn or hazardOn then
                leftOn, rightOn, hazardOn = false, false, false
            end
            Wait(500)
            goto cont
        end

        -- ←
        if IsDisabledControlJustPressed(0, 174) then
            if hazardOn then
                -- 双闪中按方向 → 退出双闪
                hazardOn = false
                leftOn, rightOn = false, false
            elseif leftOn then
                leftOn = false
            else
                leftOn = true
                rightOn = false
            end
            applyLights(veh)
        end

        -- →
        if IsDisabledControlJustPressed(0, 175) then
            if hazardOn then
                hazardOn = false
                leftOn, rightOn = false, false
            elseif rightOn then
                rightOn = false
            else
                rightOn = true
                leftOn = false
            end
            applyLights(veh)
        end

        -- ↓ 方向键下 → 双闪 toggle (187 = INPUT_FRONTEND_DOWN)
        if IsDisabledControlJustPressed(0, 187) then
            hazardOn = not hazardOn
            if hazardOn then
                leftOn, rightOn = true, true
                QBCore.Functions.Notify('🚨 双闪已开启', 'primary')
            else
                leftOn, rightOn = false, false
                QBCore.Functions.Notify('🚨 双闪已关闭', 'primary')
            end
            applyLights(veh)
        end

        ::cont::
    end
end)

-- ==============================================================
-- 音效: 转向灯/双闪 独立线程
-- ==============================================================

CreateThread(function()
    while true do
        if leftOn or rightOn or hazardOn then
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            -- 转向灯: ~1000ms (匹配 GTA5 闪灯周期, 一次闪一下提示音)
            -- 双闪:   ~500ms  (快一倍)
            local interval = hazardOn and 500 or 1000
            local sound = hazardOn and 'hazard_tick' or 'tick'

            TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 5.0, sound, 0.15)
            Wait(interval)
        else
            Wait(800)
        end
    end
end)

-- ==============================================================
-- 离开车辆: 普通灯灭, 双闪保持
-- ==============================================================

AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkPlayerLeftVehicle' and args[1] == PlayerId() then
        if hazardOn then
            -- 双闪保持: 只关方向灯
            leftOn, rightOn = false, false
            hazardPersist = true
        else
            leftOn, rightOn = false, false
        end
    end
end)

-- 重新上车: 恢复状态
AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkPlayerEnteredVehicle' and args[1] == PlayerId() then
        if hazardPersist then
            hazardOn = true
            leftOn, rightOn = true, true
            hazardPersist = false
            local veh = GetVehiclePedIsIn(PlayerPedId(), false)
            if veh and veh ~= 0 then applyLights(veh) end
        end
    end
end)

-- ==============================================================
-- 中控屏双闪 toggle (export)
-- ==============================================================

local function toggleHazard()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return end
    if isExcluded(veh) then return end

    hazardOn = not hazardOn
    if hazardOn then
        leftOn, rightOn = true, true
    else
        leftOn, rightOn = false, false
    end
    applyLights(veh)
end

exports('ToggleHazard', toggleHazard)
exports('IsHazardActive', function() return hazardOn end)

-- 中控屏按钮 → 事件驱动 (避免同一资源内 exports 调用的兼容性问题)
RegisterNetEvent('custom-vehicles:client:toggleHazard', function()
    toggleHazard()
    -- 回传状态给 dashboard
    if hazardOn then
        QBCore.Functions.Notify('🚨 双闪已开启', 'primary')
    else
        QBCore.Functions.Notify('🚨 双闪已关闭', 'primary')
    end
end)

print('[custom-vehicles] 💡 转向灯+双闪+音效 — ←→手动 | ←+→双闪 | 下车保持')
