local Plates = {}

local function IsVehicleOwned(plate)
    local result = MySQL.scalar.await('SELECT plate FROM player_vehicles WHERE plate = ?', { plate })
    return result
end

-- Callbacks

QBCore.Functions.CreateCallback('police:GetImpoundedVehicles', function(_, cb)
    local vehicles = {}
    MySQL.query('SELECT * FROM player_vehicles WHERE state = ?', { 2 }, function(result)
        if result[1] then
            vehicles = result
        end
        cb(vehicles)
    end)
end)

QBCore.Functions.CreateCallback('police:server:IsPlateFlagged', function(_, cb, plate)
    local retval = false
    if Plates and Plates[plate] then
        if Plates[plate].isflagged then
            retval = true
        end
    end
    cb(retval)
end)

-- Events

RegisterNetEvent('heli:server:spotlight', function(state)
    local serverID = source
    TriggerClientEvent('heli:client:spotlight', -1, serverID, state)
end)

RegisterNetEvent('police:server:Impound', function(plate, fullImpound, price, body, engine, fuel)
    local src = source

    -- 🛡️ Security Fix: 服务端权威校验 — 仅值班执法人员可扣押/没收车辆
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then
        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('拦截非法扣押车辆',
                ('**Source**: %d | **Plate**: %s | **fullImpound**: %s'):format(src, plate or 'nil', tostring(fullImpound)),
                16711680)
        end
        return
    end

    price = price and price or 0
    if IsVehicleOwned(plate) then
        if not fullImpound then
            MySQL.query('UPDATE player_vehicles SET state = ?, depotprice = ?, body = ?, engine = ?, fuel = ? WHERE plate = ?', { 0, price, body, engine, fuel, plate })
            TriggerClientEvent('QBCore:Notify', src, Lang:t('info.vehicle_taken_depot', { price = price }))
        else
            MySQL.query('UPDATE player_vehicles SET state = ?, body = ?, engine = ?, fuel = ? WHERE plate = ?', { 2, body, engine, fuel, plate })
            TriggerClientEvent('QBCore:Notify', src, Lang:t('info.vehicle_seized'))
        end
    end
end)

RegisterNetEvent('police:server:TakeOutImpound', function(plate, garage)
    local src = source

    -- 🛡️ Security Fix: 仅值班执法人员可取回扣押车辆
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then
        if exports['custom-logs'] then
            exports['custom-logs']:LogSecurity('拦截非法取回扣押车辆',
                ('**Source**: %d | **Plate**: %s | **Garage**: %s'):format(src, plate or 'nil', tostring(garage or 'nil')),
                16711680)
        end
        return
    end

    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local targetCoords = Config.Locations['impound'][garage]
    if #(playerCoords - targetCoords) > 10.0 then return DropPlayer(src, 'Attempted exploit abuse') end
    MySQL.update('UPDATE player_vehicles SET state = ? WHERE plate = ?', { 0, plate })
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.impound_vehicle_removed'), 'success')
end)

RegisterNetEvent('police:server:FlaggedPlateTriggered', function(coords, plate)
    for _, Player in pairs(QBCore.Functions.GetQBPlayers()) do
        if Player then
            if (Player.PlayerData.job.name == 'police' and Player.PlayerData.job.onduty) then
                local veh_plate = plate:upper()
                local message = Lang:t('info.flagged_vehicle_radar', { plate = veh_plate })
                TriggerClientEvent('police:client:policeAlert', Player.PlayerData.source, coords, message)
            end
        end
    end
    -- 🌐 Atmosphere: chase scene on flagged vehicle pursuit
    if Bus and Bus.SafeCall then Bus.SafeCall('atmosphere', 'PlayScene', source, 'chase') end
end)

-- Commands

QBCore.Commands.Add('flagplate', Lang:t('commands.flagplate'), { { name = 'plate', help = Lang:t('info.plate_number') }, { name = 'reason', help = Lang:t('info.flag_reason') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        local reason = {}
        for i = 2, #args, 1 do
            reason[#reason + 1] = args[i]
        end
        Plates[args[1]:upper()] = {
            isflagged = true,
            reason = table.concat(reason, ' ')
        }
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.vehicle_flagged', { vehicle = args[1]:upper(), reason = table.concat(reason, ' ') }))
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('unflagplate', Lang:t('commands.unflagplate'), { { name = 'plate', help = Lang:t('info.plate_number') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        if Plates and Plates[args[1]:upper()] then
            if Plates[args[1]:upper()].isflagged then
                Plates[args[1]:upper()].isflagged = false
                TriggerClientEvent('QBCore:Notify', src, Lang:t('info.unflag_vehicle', { vehicle = args[1]:upper() }))
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

QBCore.Commands.Add('plateinfo', Lang:t('commands.plateinfo'), { { name = 'plate', help = Lang:t('info.plate_number') } }, true, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if Player.PlayerData.job.type == 'leo' and Player.PlayerData.job.onduty then
        if Plates and Plates[args[1]:upper()] then
            if Plates[args[1]:upper()].isflagged then
                TriggerClientEvent('QBCore:Notify', src, Lang:t('success.vehicle_flagged', { plate = args[1]:upper(), reason = Plates[args[1]:upper()].reason }), 'success')
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehicle_not_flag'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.on_duty_police_only'), 'error')
    end
end)

-- /impoundplayer [playerID] — 扣押指定玩家所有载具
QBCore.Commands.Add('impoundplayer', 'Impound all vehicles of a player', { { name = 'playerID', help = 'Player ID' } }, false, function(source, args)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then
        TriggerClientEvent('QBCore:Notify', src, '仅限值班警察使用', 'error')
        return
    end
    local targetId = tonumber(args[1])
    if not targetId then
        TriggerClientEvent('QBCore:Notify', src, '用法: /impoundplayer [玩家ID]', 'error')
        return
    end
    local Target = QBCore.Functions.GetPlayer(targetId)
    if not Target then
        TriggerClientEvent('QBCore:Notify', src, '玩家不在线', 'error')
        return
    end
    local affected = MySQL.update.await('UPDATE player_vehicles SET state = 2 WHERE citizenid = ? AND state = 0', { Target.PlayerData.citizenid })
    TriggerClientEvent('QBCore:Notify', src, ('已扣押 %s 的 %d 辆载具'):format(GetPlayerName(targetId), affected), 'success')
    if exports['custom-logs'] then
        exports['custom-logs']:LogGeneric('警察扣押全部',
            ('**%s** 扣押了 **%s** 的全部 %d 辆载具'):format(GetPlayerName(src), GetPlayerName(targetId), affected), 16711680)
    end
end, 'admin')

-- /impoundnear — 扣押警官周围最近的玩家载具
QBCore.Commands.Add('impoundnear', 'Impound nearest vehicle', {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or Player.PlayerData.job.type ~= 'leo' or not Player.PlayerData.job.onduty then
        TriggerClientEvent('QBCore:Notify', src, '仅限值班警察使用', 'error')
        return
    end
    TriggerClientEvent('police:client:impoundNear', src)
end, 'admin')
