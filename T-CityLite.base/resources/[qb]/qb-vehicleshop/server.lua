-- Variables
local QBCore = exports['qb-core']:GetCoreObject()
local financetimer = {}

-- 车辆类别 → 证件类型映射
local VehicleClassLicenseMap = {
    [0] = 'driver', [1] = 'driver', [2] = 'driver', [3] = 'driver', [4] = 'driver',
    [5] = 'driver', [6] = 'driver', [7] = 'driver', [8] = 'driver', [9] = 'driver',
    [10] = 'heavy', [11] = 'heavy', [17] = 'heavy', [19] = 'heavy', [20] = 'heavy',
    [12] = 'driver', [13] = 'driver', [18] = 'driver', [22] = 'driver',
    [14] = 'boat',
    [15] = 'pilot', [16] = 'pilot',
}

local function CheckVehicleLicense(player, vehicleModel)
    local hash = GetHashKey(vehicleModel)
    local vehClass = GetVehicleClassFromName(hash)
    local requiredLicense = VehicleClassLicenseMap[vehClass]
    if not requiredLicense then return true end
    local licences = player.PlayerData.metadata['licences']
    if not licences then return false end
    return licences[requiredLicense] == true
end

local function GetRequiredLicenseName(vehicleModel)
    local hash = GetHashKey(vehicleModel)
    local vehClass = GetVehicleClassFromName(hash)
    local requiredLicense = VehicleClassLicenseMap[vehClass]
    local names = { driver = 'Driver License', pilot = 'Pilot License', boat = 'Boat License', heavy = 'Heavy Vehicle License' }
    return requiredLicense and names[requiredLicense] or nil
end

local vehicleTypes = { -- https://docs.fivem.net/natives/?_0xA273060E
    motorcycles = 'bike',
    boats = 'boat',
    helicopters = 'heli',
    planes = 'plane',
    submarines = 'submarine',
    trailer = 'trailer',
    train = 'train'
}

local function GetVehicleTypeByModel(model)
    local vehicleData = QBCore.Shared.Vehicles[model]
    if not vehicleData then return 'automobile' end
    local category = vehicleData.category
    local vehicleType = vehicleTypes[category]
    return vehicleType or 'automobile'
end

QBCore.Functions.CreateCallback('qb-vehicleshop:server:spawnvehicle', function(source, cb, plate, vehicle, coords)
    local vehType = QBCore.Shared.Vehicles[vehicle] and QBCore.Shared.Vehicles[vehicle].type or GetVehicleTypeByModel(vehicle)
    local veh = CreateVehicleServerSetter(GetHashKey(vehicle), vehType, coords.x, coords.y, coords.z, coords.w)
    local netId = NetworkGetNetworkIdFromEntity(veh)
    SetVehicleNumberPlateText(veh, plate)
    local vehProps = {}
    local result = MySQL.rawExecute.await('SELECT mods FROM player_vehicles WHERE plate = ?', { plate })
    if result and result[1] then vehProps = json.decode(result[1].mods) end
    cb(netId, vehProps, plate)
end)

-- Handlers
-- Store game time for player when they load
RegisterNetEvent('qb-vehicleshop:server:addPlayer', function(citizenid)
    financetimer[citizenid] = os.time()
end)

-- Deduct stored game time from player on logout
-- ⚡ Performance Fix: 异步化查询，避免在频繁触发的断线事件中阻塞主线程
RegisterNetEvent('qb-vehicleshop:server:removePlayer', function(citizenid)
    if financetimer[citizenid] then
        local playTime = financetimer[citizenid]
        MySQL.query('SELECT * FROM player_vehicles WHERE citizenid = ?', { citizenid }, function(financetime)
            if financetime then
                for _, v in pairs(financetime) do
                    if v.balance >= 1 then
                        local newTime = (v.financetime - ((os.time() - playTime) / 60))
                        if newTime < 0 then newTime = 0 end
                        MySQL.update('UPDATE player_vehicles SET financetime = ? WHERE plate = ?', { math.ceil(newTime), v.plate })
                    end
                end
            end
        end)
    end
    financetimer[citizenid] = nil
end)

-- Deduct stored game time from player on quit because we can't get citizenid
-- ⚡ Performance Fix: 异步化查询，避免 playerDropped 阻塞事件循环
AddEventHandler('playerDropped', function()
    local src = source
    local license
    for _, v in pairs(GetPlayerIdentifiers(src)) do
        if string.sub(v, 1, string.len('license:')) == 'license:' then
            license = v
        end
    end
    if license then
        MySQL.query('SELECT * FROM player_vehicles WHERE license = ?', { license }, function(vehicles)
            if vehicles then
                for _, v in pairs(vehicles) do
                    local playTime = financetimer[v.citizenid]
                    if v.balance >= 1 and playTime then
                        local newTime = (v.financetime - ((os.time() - playTime) / 60))
                        if newTime < 0 then newTime = 0 end
                        MySQL.update('UPDATE player_vehicles SET financetime = ? WHERE plate = ?', { math.ceil(newTime), v.plate })
                    end
                end
                if vehicles[1] and financetimer[vehicles[1].citizenid] then financetimer[vehicles[1].citizenid] = nil end
            end
        end)
    end
end)

-- Functions
local function round(x)
    return x >= 0 and math.floor(x + 0.5) or math.ceil(x - 0.5)
end

local function calculateFinance(vehiclePrice, downPayment, paymentamount)
    local balance = vehiclePrice - downPayment
    local vehPaymentAmount = balance / paymentamount
    return round(balance), round(vehPaymentAmount)
end

local function calculateNewFinance(paymentAmount, vehData)
    local newBalance = tonumber(vehData.balance - paymentAmount)
    local minusPayment = vehData.paymentsLeft - 1
    local newPaymentsLeft = newBalance / minusPayment
    local newPayment = newBalance / newPaymentsLeft
    return round(newBalance), round(newPayment), newPaymentsLeft
end

local function GeneratePlate()
    local plate = QBCore.Shared.RandomInt(1) .. QBCore.Shared.RandomStr(2) .. QBCore.Shared.RandomInt(3) .. QBCore.Shared.RandomStr(2)
    local result = MySQL.scalar.await('SELECT plate FROM player_vehicles WHERE plate = ?', { plate })
    if result then
        return GeneratePlate()
    else
        return plate:upper()
    end
end

local function comma_value(amount)
    local formatted = amount
    local k
    while true do
        formatted, k = string.gsub(formatted, '^(-?%d+)(%d%d%d)', '%1,%2')
        if (k == 0) then
            break
        end
    end
    return formatted
end

-- Callbacks
QBCore.Functions.CreateCallback('qb-vehicleshop:server:getVehicles', function(source, cb)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    if player then
        local vehicles = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ?', { player.PlayerData.citizenid })
        if vehicles[1] then
            cb(vehicles)
        end
    end
end)

-- Events

-- Brute force vehicle deletion
RegisterNetEvent('qb-vehicleshop:server:deleteVehicle', function(netId)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    DeleteEntity(vehicle)
end)

-- Sync vehicle for other players
RegisterNetEvent('qb-vehicleshop:server:swapVehicle', function(data)
    local src = source
    TriggerClientEvent('qb-vehicleshop:client:swapVehicle', -1, data)
    Wait(1500)                                                -- let new car spawn
    TriggerClientEvent('qb-vehicleshop:client:homeMenu', src) -- reopen main menu
end)

-- Send customer for test drive
RegisterNetEvent('qb-vehicleshop:server:customTestDrive', function(vehicle, playerid)
    local src = source
    local target = tonumber(playerid)
    if not QBCore.Functions.GetPlayer(target) then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error')
        return
    end
    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target))) < 3 then
        TriggerClientEvent('qb-vehicleshop:client:customTestDrive', target, vehicle)
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error')
    end
end)

-- Make a finance payment
RegisterNetEvent('qb-vehicleshop:server:financePayment', function(paymentAmount, vehData)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    local cash = player.PlayerData.money['cash']
    local bank = player.PlayerData.money['bank']
    local plate = vehData.vehiclePlate
    paymentAmount = tonumber(paymentAmount)
    local minPayment = tonumber(vehData.paymentAmount)
    local timer = (Config.PaymentInterval * 60)
    local newBalance, newPaymentsLeft, newPayment = calculateNewFinance(paymentAmount, vehData)
    if newBalance > 0 then
        if player and paymentAmount >= minPayment then
            if cash >= paymentAmount then
                player.Functions.RemoveMoney('cash', paymentAmount, 'financed vehicle')
                MySQL.update('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ?', { newBalance, newPayment, newPaymentsLeft, timer, plate })
            elseif bank >= paymentAmount then
                player.Functions.RemoveMoney('bank', paymentAmount, 'financed vehicle')
                MySQL.update('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ?', { newBalance, newPayment, newPaymentsLeft, timer, plate })
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
            end
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.minimumallowed') .. comma_value(minPayment), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.overpaid'), 'error')
    end
end)


-- Pay off vehice in full
RegisterNetEvent('qb-vehicleshop:server:financePaymentFull', function(data)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    local cash = player.PlayerData.money['cash']
    local bank = player.PlayerData.money['bank']
    local vehBalance = data.vehBalance
    local vehPlate = data.vehPlate
    if player and vehBalance ~= 0 then
        if cash >= vehBalance then
            player.Functions.RemoveMoney('cash', vehBalance, 'paid off vehicle')
            MySQL.update('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ?', { 0, 0, 0, 0, vehPlate })
        elseif bank >= vehBalance then
            player.Functions.RemoveMoney('bank', vehBalance, 'paid off vehicle')
            MySQL.update('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ?', { 0, 0, 0, 0, vehPlate })
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.alreadypaid'), 'error')
    end
end)

-- Buy public vehicle outright
RegisterNetEvent('qb-vehicleshop:server:buyShowroomVehicle', function(vehicle)
    local src = source
    vehicle = vehicle.buyVehicle
    local pData = QBCore.Functions.GetPlayer(src)
    if not CheckVehicleLicense(pData, vehicle) then
        local licenseName = GetRequiredLicenseName(vehicle)
        TriggerClientEvent('QBCore:Notify', src, ('You need a %s to purchase this vehicle!'):format(licenseName or 'license'), 'error', 5000)
        return
    end
    local cid = pData.PlayerData.citizenid
    local cash = pData.PlayerData.money['cash']
    local bank = pData.PlayerData.money['bank']
    local vehiclePrice = QBCore.Shared.Vehicles[vehicle]['price']
    local plate = GeneratePlate()
    if cash > tonumber(vehiclePrice) then
        MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
            pData.PlayerData.license,
            cid,
            vehicle,
            GetHashKey(vehicle),
            '{}',
            plate,
            'pillboxgarage',
            0
        })
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.purchased'), 'success')
        TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', src, vehicle, plate)
        pData.Functions.RemoveMoney('cash', vehiclePrice, 'vehicle-bought-in-showroom')
        -- 💰 新车购置税 8%
        if GetResourceState('custom-taxes') == 'started' then
            exports['custom-taxes']:CollectVehiclePurchaseTax(src, vehiclePrice, vehicle)
        end
    elseif bank > tonumber(vehiclePrice) then
        MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
            pData.PlayerData.license,
            cid,
            vehicle,
            GetHashKey(vehicle),
            '{}',
            plate,
            'pillboxgarage',
            0
        })
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.purchased'), 'success')
        TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', src, vehicle, plate)
        pData.Functions.RemoveMoney('bank', vehiclePrice, 'vehicle-bought-in-showroom')
        -- 💰 新车购置税 8%
        if GetResourceState('custom-taxes') == 'started' then
            exports['custom-taxes']:CollectVehiclePurchaseTax(src, vehiclePrice, vehicle)
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
    end
end)

-- Finance public vehicle
RegisterNetEvent('qb-vehicleshop:server:financeVehicle', function(downPayment, paymentAmount, vehicle)
    local src = source
    downPayment = tonumber(downPayment)
    paymentAmount = tonumber(paymentAmount)
    local pData = QBCore.Functions.GetPlayer(src)
    if not CheckVehicleLicense(pData, vehicle) then
        local licenseName = GetRequiredLicenseName(vehicle)
        TriggerClientEvent('QBCore:Notify', src, ('You need a %s to finance this vehicle!'):format(licenseName or 'license'), 'error', 5000)
        return
    end
    local cid = pData.PlayerData.citizenid
    local cash = pData.PlayerData.money['cash']
    local bank = pData.PlayerData.money['bank']
    local vehiclePrice = QBCore.Shared.Vehicles[vehicle]['price']
    local timer = (Config.PaymentInterval * 60)
    local minDown = tonumber(round((Config.MinimumDown / 100) * vehiclePrice))
    if downPayment > vehiclePrice then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notworth'), 'error') end
    if downPayment < minDown then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.downtoosmall'), 'error') end
    if paymentAmount > Config.MaximumPayments then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.exceededmax'), 'error') end
    local plate = GeneratePlate()
    local balance, vehPaymentAmount = calculateFinance(vehiclePrice, downPayment, paymentAmount)
    if cash >= downPayment then
        MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
            pData.PlayerData.license,
            cid,
            vehicle,
            GetHashKey(vehicle),
            '{}',
            plate,
            'pillboxgarage',
            0,
            balance,
            vehPaymentAmount,
            paymentAmount,
            timer
        })
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.purchased'), 'success')
        TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', src, vehicle, plate)
        pData.Functions.RemoveMoney('cash', downPayment, 'vehicle-bought-in-showroom')
    elseif bank >= downPayment then
        MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
            pData.PlayerData.license,
            cid,
            vehicle,
            GetHashKey(vehicle),
            '{}',
            plate,
            'pillboxgarage',
            0,
            balance,
            vehPaymentAmount,
            paymentAmount,
            timer
        })
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.purchased'), 'success')
        TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', src, vehicle, plate)
        pData.Functions.RemoveMoney('bank', downPayment, 'vehicle-bought-in-showroom')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
    end
end)

-- Sell vehicle to customer
RegisterNetEvent('qb-vehicleshop:server:sellShowroomVehicle', function(data, playerid)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    local target = QBCore.Functions.GetPlayer(tonumber(playerid))
    if target and not CheckVehicleLicense(target, data) then
        local licenseName = GetRequiredLicenseName(data)
        TriggerClientEvent('QBCore:Notify', src, ('Buyer needs a %s to purchase this vehicle!'):format(licenseName or 'license'), 'error', 5000)
        return
    end

    if not target then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error')
        return
    end

    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target.PlayerData.source))) < 3 then
        local cid = target.PlayerData.citizenid
        local cash = target.PlayerData.money['cash']
        local bank = target.PlayerData.money['bank']
        local vehicle = data
        local vehiclePrice = QBCore.Shared.Vehicles[vehicle]['price']
        local commission = round(vehiclePrice * Config.Commission)
        local plate = GeneratePlate()
        if cash >= tonumber(vehiclePrice) then
            MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
                target.PlayerData.license,
                cid,
                vehicle,
                GetHashKey(vehicle),
                '{}',
                plate,
                'pillboxgarage',
                0
            })
            TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', target.PlayerData.source, vehicle, plate)
            target.Functions.RemoveMoney('cash', vehiclePrice, 'vehicle-bought-in-showroom')
            player.Functions.AddMoney('bank', commission, 'vehicle sale commission')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.earned_commission', { amount = comma_value(commission) }), 'success')
            exports['qb-banking']:AddMoney(player.PlayerData.job.name, vehiclePrice, 'Vehicle sale')
            TriggerClientEvent('QBCore:Notify', target.PlayerData.source, Lang:t('success.purchased'), 'success')
        elseif bank >= tonumber(vehiclePrice) then
            MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES (?, ?, ?, ?, ?, ?, ?, ?)', {
                target.PlayerData.license,
                cid,
                vehicle,
                GetHashKey(vehicle),
                '{}',
                plate,
                'pillboxgarage',
                0
            })
            TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', target.PlayerData.source, vehicle, plate)
            target.Functions.RemoveMoney('bank', vehiclePrice, 'vehicle-bought-in-showroom')
            player.Functions.AddMoney('bank', commission, 'vehicle sale commission')
            exports['qb-banking']:AddMoney(player.PlayerData.job.name, vehiclePrice, 'Vehicle sale')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.earned_commission', { amount = comma_value(commission) }), 'success')
            TriggerClientEvent('QBCore:Notify', target.PlayerData.source, Lang:t('success.purchased'), 'success')
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error')
    end
end)

-- Finance vehicle to customer
RegisterNetEvent('qb-vehicleshop:server:sellfinanceVehicle', function(downPayment, paymentAmount, vehicle, playerid)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    local target = QBCore.Functions.GetPlayer(tonumber(playerid))
    if target and not CheckVehicleLicense(target, vehicle) then
        local licenseName = GetRequiredLicenseName(vehicle)
        TriggerClientEvent('QBCore:Notify', src, ('Buyer needs a %s to finance this vehicle!'):format(licenseName or 'license'), 'error', 5000)
        return
    end

    if not target then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error')
        return
    end

    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target.PlayerData.source))) < 3 then
        downPayment = tonumber(downPayment)
        paymentAmount = tonumber(paymentAmount)
        local cid = target.PlayerData.citizenid
        local cash = target.PlayerData.money['cash']
        local bank = target.PlayerData.money['bank']
        local vehiclePrice = QBCore.Shared.Vehicles[vehicle]['price']
        local timer = (Config.PaymentInterval * 60)
        local minDown = tonumber(round((Config.MinimumDown / 100) * vehiclePrice))
        if downPayment > vehiclePrice then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notworth'), 'error') end
        if downPayment < minDown then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.downtoosmall'), 'error') end
        if paymentAmount > Config.MaximumPayments then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.exceededmax'), 'error') end
        local commission = round(vehiclePrice * Config.Commission)
        local plate = GeneratePlate()
        local balance, vehPaymentAmount = calculateFinance(vehiclePrice, downPayment, paymentAmount)
        if cash >= downPayment then
            MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
                target.PlayerData.license,
                cid,
                vehicle,
                GetHashKey(vehicle),
                '{}',
                plate,
                'pillboxgarage',
                0,
                balance,
                vehPaymentAmount,
                paymentAmount,
                timer
            })
            TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', target.PlayerData.source, vehicle, plate)
            target.Functions.RemoveMoney('cash', downPayment, 'vehicle-bought-in-showroom')
            player.Functions.AddMoney('bank', commission, 'vehicle sale commission')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.earned_commission', { amount = comma_value(commission) }), 'success')
            exports['qb-banking']:AddMoney(player.PlayerData.job.name, vehiclePrice, 'Vehicle sale')
            TriggerClientEvent('QBCore:Notify', target.PlayerData.source, Lang:t('success.purchased'), 'success')
        elseif bank >= downPayment then
            MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
                target.PlayerData.license,
                cid,
                vehicle,
                GetHashKey(vehicle),
                '{}',
                plate,
                'pillboxgarage',
                0,
                balance,
                vehPaymentAmount,
                paymentAmount,
                timer
            })
            TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', target.PlayerData.source, vehicle, plate)
            target.Functions.RemoveMoney('bank', downPayment, 'vehicle-bought-in-showroom')
            player.Functions.AddMoney('bank', commission, 'vehicle sale commission')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.earned_commission', { amount = comma_value(commission) }), 'success')
            exports['qb-banking']:AddMoney(player.PlayerData.job.name, vehiclePrice, 'Vehicle sale')
            TriggerClientEvent('QBCore:Notify', target.PlayerData.source, Lang:t('success.purchased'), 'success')
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error')
    end
end)

-- Check if payment is due
RegisterNetEvent('qb-vehicleshop:server:checkFinance', function()
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    local query = 'SELECT * FROM player_vehicles WHERE citizenid = ? AND balance > 0 AND financetime < 1'
    local result = MySQL.query.await(query, { player.PlayerData.citizenid })
    if result[1] then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('general.paymentduein', { time = Config.PaymentWarning }))
        Wait(Config.PaymentWarning * 60000)
        local vehicles = MySQL.query.await(query, { player.PlayerData.citizenid })
        for _, v in pairs(vehicles) do
            local plate = v.plate
            MySQL.query('DELETE FROM player_vehicles WHERE plate = @plate', { ['@plate'] = plate })
            --MySQL.update('UPDATE player_vehicles SET citizenid = ? WHERE plate = ?', {'REPO-'..v.citizenid, plate}) -- Use this if you don't want them to be deleted
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.repossessed', { plate = plate }), 'error')
        end
    end
end)

-- Transfer vehicle to player in passenger seat
QBCore.Commands.Add('transfervehicle', Lang:t('general.command_transfervehicle'), { { name = 'ID', help = Lang:t('general.command_transfervehicle_help') }, { name = 'amount', help = Lang:t('general.command_transfervehicle_amount') } }, false, function(source, args)
    local src = source
    local buyerId = tonumber(args[1])
    local sellAmount = tonumber(args[2])
    if buyerId == 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error') end
    local ped = GetPlayerPed(src)
    local targetPed = GetPlayerPed(buyerId)
    if targetPed == 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyerinfo'), 'error') end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notinveh'), 'error') end
    local plate = QBCore.Shared.Trim(GetVehicleNumberPlateText(vehicle))
    if not plate then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehinfo'), 'error') end
    local player = QBCore.Functions.GetPlayer(src)
    local target = QBCore.Functions.GetPlayer(buyerId)
    local row = MySQL.single.await('SELECT * FROM player_vehicles WHERE plate = ?', { plate })
    if Config.PreventFinanceSelling then
        if row.balance > 0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.financed'), 'error') end
    end
    if row.citizenid ~= player.PlayerData.citizenid then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notown'), 'error') end
    if #(GetEntityCoords(ped) - GetEntityCoords(targetPed)) > 5.0 then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error') end
    local targetcid = target.PlayerData.citizenid
    local targetlicense = QBCore.Functions.GetIdentifier(target.PlayerData.source, 'license')
    if not target then return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyerinfo'), 'error') end
    -- 检查买家证件
    local vehicleModel = row.vehicle
    if vehicleModel and not CheckVehicleLicense(target, vehicleModel) then
        local licenseName = GetRequiredLicenseName(vehicleModel)
        TriggerClientEvent('QBCore:Notify', src, ('Buyer needs a %s to receive this vehicle!'):format(licenseName or 'license'), 'error', 5000)
        return
    end
    if not sellAmount then
        MySQL.update('UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ?', { targetcid, targetlicense, plate })
        -- 同步 custom-vehicles KeyManager：移除旧主钥匙，注册新主
        pcall(function()
            exports['custom-vehicles']:RemoveKeys(plate, player.PlayerData.citizenid)
            exports['custom-vehicles']:SetOwner(plate, targetcid)
        end)
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.gifted'), 'success')
        TriggerClientEvent('vehiclekeys:client:SetOwner', buyerId, plate)
        TriggerClientEvent('QBCore:Notify', buyerId, Lang:t('success.received_gift'), 'success')
        return
    end
    if target.Functions.GetMoney('cash') > sellAmount then
        MySQL.update('UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ?', { targetcid, targetlicense, plate })
        -- 同步 custom-vehicles KeyManager：移除旧主钥匙，注册新主
        pcall(function()
            exports['custom-vehicles']:RemoveKeys(plate, player.PlayerData.citizenid)
            exports['custom-vehicles']:SetOwner(plate, targetcid)
        end)
        player.Functions.AddMoney('cash', sellAmount, 'transferred vehicle')
        target.Functions.RemoveMoney('cash', sellAmount, 'transferred vehicle')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.soldfor') .. comma_value(sellAmount), 'success')
        TriggerClientEvent('vehiclekeys:client:SetOwner', buyerId, plate)
        TriggerClientEvent('QBCore:Notify', buyerId, Lang:t('success.boughtfor') .. comma_value(sellAmount), 'success')
    elseif target.Functions.GetMoney('bank') > sellAmount then
        MySQL.update('UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ?', { targetcid, targetlicense, plate })
        -- 同步 custom-vehicles KeyManager：移除旧主钥匙，注册新主
        pcall(function()
            exports['custom-vehicles']:RemoveKeys(plate, player.PlayerData.citizenid)
            exports['custom-vehicles']:SetOwner(plate, targetcid)
        end)
        player.Functions.AddMoney('bank', sellAmount, 'transferred vehicle')
        target.Functions.RemoveMoney('bank', sellAmount, 'transferred vehicle')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.soldfor') .. comma_value(sellAmount), 'success')
        TriggerClientEvent('vehiclekeys:client:SetOwner', buyerId, plate)
        TriggerClientEvent('QBCore:Notify', buyerId, Lang:t('success.boughtfor') .. comma_value(sellAmount), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyertoopoor'), 'error')
    end
end)
