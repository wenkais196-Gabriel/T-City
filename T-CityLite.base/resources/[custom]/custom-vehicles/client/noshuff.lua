-- noshuff.lua — 防座位乱跳 (migrated from qb-smallresources, v0.8)
--
-- 阻止 GTA5 原生 AI 在上车/下车/碰撞时自动 shuffle 座位
-- 玩家手动 /shuff 命令可临时允许 shuffle

local disableShuffle = true

RegisterNetEvent('QBCore:Client:EnteredVehicle', function(data)
    local ped = PlayerPedId()
    while IsPedInAnyVehicle(ped, false) do
        local sleep = 100
        if disableShuffle and GetPedInVehicleSeat(data.vehicle, 0) == ped and GetIsTaskActive(ped, 165) then
            sleep = 0
            SetPedIntoVehicle(ped, data.vehicle, 0)
            SetPedConfigFlag(ped, 184, true)
        end
        Wait(sleep)
    end
end)

RegisterNetEvent('custom-vehicles:client:seatShuffle', function()
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then
        disableShuffle = false
        SetPedConfigFlag(ped, 184, false)
        Wait(3000)
        disableShuffle = true
    else
        CancelEvent()
    end
end)

-- 前后向: /shuff 命令
RegisterCommand('shuff', function()
    TriggerEvent('custom-vehicles:client:seatShuffle')
end, false)

-- 向 qb-radialmenu 广播兼容事件 (不改动 qb-radialmenu 自身)
RegisterNetEvent('SeatShuffle', function()
    TriggerEvent('custom-vehicles:client:seatShuffle')
end)

print('[custom-vehicles] 🪑 防座位乱跳就绪 — /shuff 手动换位')
