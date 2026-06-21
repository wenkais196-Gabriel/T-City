-- stolen_radar.lua — 警用被盗车辆雷达 (v0.7b)
--
-- 值班警察在载具中时，每 3 秒扫描周围 50m 内的车辆
-- 发现 Entity.state.isStolen → 标记红点 + 手机通知

local SCAN_INTERVAL = 3000
local SCAN_RANGE = 50.0

Citizen.CreateThread(function()
    while true do
        Wait(SCAN_INTERVAL)

        local ped = PlayerPedId()
        -- 必须是警察且值班
        local PlayerData = exports['qb-core']:GetPlayerData()
        if not PlayerData or not PlayerData.job or PlayerData.job.name ~= 'police' or not PlayerData.job.onduty then
            goto cont
        end

        -- 必须在载具中（巡逻车/直升机均可）
        local policeVeh = GetVehiclePedIsIn(ped, false)
        if not policeVeh or policeVeh == 0 then
            goto cont
        end

        local pCoords = GetEntityCoords(ped)
        local allVehicles = GetGamePool('CVehicle')
        for _, v in ipairs(allVehicles) do
            if v == policeVeh then goto next_veh end
            if not DoesEntityExist(v) then goto next_veh end
            local dist = #(pCoords - GetEntityCoords(v))
            if dist > SCAN_RANGE then goto next_veh end

            if Entity(v).state.isStolen then
                local plate = GetVehicleNumberPlateText(v):gsub('^%s+', ''):gsub('%s+$', ''):upper()
                local model = GetDisplayNameFromVehicleModel(GetEntityModel(v))
                local vCoords = GetEntityCoords(v)

                -- 红点标记
                local blip = AddBlipForEntity(v)
                SetBlipSprite(blip, 225)        -- 红色车辆标记
                SetBlipColour(blip, 1)           -- 红色
                SetBlipFlashes(blip, true)
                SetBlipAsShortRange(blip, false)
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentString(('被盗: %s [%s]'):format(model, plate))
                EndTextCommandSetBlipName(blip)

                -- 5 秒后自动清除标记
                SetTimeout(5000, function()
                    if DoesBlipExist(blip) then
                        RemoveBlip(blip)
                    end
                end)

                -- 手机通知
                TriggerEvent('qb-phone:client:addPoliceAlert', {
                    title = '🚨 被盗车辆',
                    coords = { x = vCoords.x, y = vCoords.y, z = vCoords.z },
                    description = ('%s [%s]'):format(model, plate),
                })
            end
            ::next_veh::
        end
        ::cont::
    end
end)

print('[qb-policejob] 📡 被盗车辆雷达已激活 — 50m 范围 3s 扫描')
