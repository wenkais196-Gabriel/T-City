-- finance-payments.lua — 分期购买与还款逻辑
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
-- Phase 2: 从 finance.lua 拆分
--
-- 职责:
--   1. 分期购买 (financeVehicle / sellfinanceVehicle)
--   2. 分期还款 (financePayment / financePaymentFull)
--   3. 获取车辆列表回调 (getVehicles)

local QBCore   = exports['qb-core']:GetCoreObject()
local shopUtil = _G._vehicleshop

-- ==============================================================
-- 金融计算
-- ==============================================================

--- 首次分期计算
local function calculateFinance(vehiclePrice, downPayment, paymentamount)
    local balance = vehiclePrice - downPayment
    local vehPaymentAmount = balance / paymentamount
    return shopUtil.round(balance), shopUtil.round(vehPaymentAmount)
end

--- 还款后重新计算
local function calculateNewFinance(paymentAmount, vehData)
    local newBalance = tonumber(vehData.balance - paymentAmount)
    local minusPayment = vehData.paymentsLeft - 1
    local newPaymentsLeft = newBalance / minusPayment
    local newPayment = newBalance / newPaymentsLeft
    return shopUtil.round(newBalance), shopUtil.round(newPayment), newPaymentsLeft
end

-- ==============================================================
-- Callback: 获取玩家车辆列表 (分期菜单用)
-- ==============================================================

QBCore.Functions.CreateCallback('qb-vehicleshop:server:getVehicles', function(source, cb)
    local src    = source
    local player = QBCore.Functions.GetPlayer(src)
    if player then
        local vehicles = MySQL.query.await('SELECT * FROM player_vehicles WHERE citizenid = ?',
            { player.PlayerData.citizenid })
        if vehicles[1] then
            cb(vehicles)
        else
            cb({})
        end
    end
end)

-- ==============================================================
-- 分期还款
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:server:financePayment', function(paymentAmount, vehData)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    local cash   = player.PlayerData.money['cash']
    local bank   = player.PlayerData.money['bank']
    local plate  = vehData.vehiclePlate
    paymentAmount = tonumber(paymentAmount)
    local minPayment  = tonumber(vehData.paymentAmount)
    local timer       = (Config.PaymentInterval * 60)
    local newBalance, newPaymentsLeft, newPayment = calculateNewFinance(paymentAmount, vehData)

    if newBalance <= 0 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.overpaid'), 'error')
        return
    end

    if not player or paymentAmount < minPayment then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.minimumallowed') .. shopUtil.comma_value(minPayment), 'error')
        return
    end

    if cash >= paymentAmount then
        player.Functions.RemoveMoney('cash', paymentAmount, 'financed vehicle')
        MySQL.update('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ?',
            { newBalance, newPayment, newPaymentsLeft, timer, plate })
    elseif bank >= paymentAmount then
        player.Functions.RemoveMoney('bank', paymentAmount, 'financed vehicle')
        MySQL.update('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ?',
            { newBalance, newPayment, newPaymentsLeft, timer, plate })
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
    end
end)

-- 全额结清
RegisterNetEvent('qb-vehicleshop:server:financePaymentFull', function(data)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    local cash  = player.PlayerData.money['cash']
    local bank  = player.PlayerData.money['bank']
    local vehBalance = data.vehBalance
    local vehPlate   = data.vehPlate

    if not player or vehBalance == 0 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.alreadypaid'), 'error')
        return
    end

    if cash >= vehBalance then
        player.Functions.RemoveMoney('cash', vehBalance, 'paid off vehicle')
        MySQL.update('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ?',
            { 0, 0, 0, 0, vehPlate })
    elseif bank >= vehBalance then
        player.Functions.RemoveMoney('bank', vehBalance, 'paid off vehicle')
        MySQL.update('UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ?',
            { 0, 0, 0, 0, vehPlate })
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
    end
end)

-- ==============================================================
-- 分期购买: 自由商店
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:server:financeVehicle', function(downPayment, paymentAmount, vehicle)
    local src = source
    downPayment   = tonumber(downPayment)
    paymentAmount = tonumber(paymentAmount)
    local pData = QBCore.Functions.GetPlayer(src)

    -- 安全: 驾照检查
    if not shopUtil.CheckVehicleLicense(pData, vehicle) then
        local licenseName = shopUtil.GetRequiredLicenseName(vehicle)
        TriggerClientEvent('QBCore:Notify', src,
            ('You need a %s to finance this vehicle!'):format(licenseName or 'license'), 'error', 5000)
        return
    end

    local cash         = pData.PlayerData.money['cash']
    local bank         = pData.PlayerData.money['bank']
    local vehiclePrice = QBCore.Shared.Vehicles[vehicle]['price']
    local timer        = (Config.PaymentInterval * 60)
    local minDown      = tonumber(shopUtil.round((Config.MinimumDown / 100) * vehiclePrice))

    if downPayment > vehiclePrice then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notworth'), 'error')
    end
    if downPayment < minDown then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.downtoosmall'), 'error')
    end
    if paymentAmount > Config.MaximumPayments then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.exceededmax'), 'error')
    end

    local plate = shopUtil.GeneratePlate()
    local balance, vehPaymentAmount = calculateFinance(vehiclePrice, downPayment, paymentAmount)

    if cash >= downPayment then
        MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
            pData.PlayerData.license,
            pData.PlayerData.citizenid,
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
            pData.PlayerData.citizenid,
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

-- ==============================================================
-- 分期购买: 管理商店代客分期
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:server:sellfinanceVehicle', function(downPayment, paymentAmount, vehicle, playerid)
    local src    = source
    local player = QBCore.Functions.GetPlayer(src)
    local target = QBCore.Functions.GetPlayer(tonumber(playerid))

    -- 安全: 驾照检查
    if target and not shopUtil.CheckVehicleLicense(target, vehicle) then
        local licenseName = shopUtil.GetRequiredLicenseName(vehicle)
        TriggerClientEvent('QBCore:Notify', src,
            ('Buyer needs a %s to finance this vehicle!'):format(licenseName or 'license'), 'error', 5000)
        return
    end

    if not target then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error')
        return
    end

    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target.PlayerData.source))) >= 3 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error')
        return
    end

    downPayment   = tonumber(downPayment)
    paymentAmount = tonumber(paymentAmount)
    local vehiclePrice = QBCore.Shared.Vehicles[vehicle]['price']
    local timer        = (Config.PaymentInterval * 60)
    local minDown      = tonumber(shopUtil.round((Config.MinimumDown / 100) * vehiclePrice))

    if downPayment > vehiclePrice then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notworth'), 'error')
    end
    if downPayment < minDown then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.downtoosmall'), 'error')
    end
    if paymentAmount > Config.MaximumPayments then
        return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.exceededmax'), 'error')
    end

    local commission = shopUtil.round(vehiclePrice * Config.FinanceCommission)
    local plate = shopUtil.GeneratePlate()
    local balance, vehPaymentAmount = calculateFinance(vehiclePrice, downPayment, paymentAmount)

    local cash = target.PlayerData.money['cash']
    local bank = target.PlayerData.money['bank']

    if cash >= downPayment then
        MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
            target.PlayerData.license,
            target.PlayerData.citizenid,
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
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.earned_commission',
            { amount = shopUtil.comma_value(commission) }), 'success')
        pcall(function()
            exports['qb-banking']:AddMoney(player.PlayerData.job.name, vehiclePrice, 'Vehicle sale')
        end)
        TriggerClientEvent('QBCore:Notify', target.PlayerData.source, Lang:t('success.purchased'), 'success')
    elseif bank >= downPayment then
        MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate, garage, state, balance, paymentamount, paymentsleft, financetime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
            target.PlayerData.license,
            target.PlayerData.citizenid,
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
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.earned_commission',
            { amount = shopUtil.comma_value(commission) }), 'success')
        pcall(function()
            exports['qb-banking']:AddMoney(player.PlayerData.job.name, vehiclePrice, 'Vehicle sale')
        end)
        TriggerClientEvent('QBCore:Notify', target.PlayerData.source, Lang:t('success.purchased'), 'success')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
    end
end)

print('[qb-vehicleshop] 💰 分期支付模块已加载 (finance-payments.lua)')
