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
    if not player then return end

    -- 🔒 只认客户端传来的**车牌**，其余（余额/期数/每期额）一律从 DB 取，
    --    并且限定 citizenid = 本人 —— 原来 vehData 全由客户端决定，能改到别人的分期记录。
    local plate = type(vehData) == 'table' and vehData.vehiclePlate or nil
    if type(plate) ~= 'string' or #plate == 0 then return end
    paymentAmount = tonumber(paymentAmount)
    if not paymentAmount or paymentAmount <= 0 then return end

    local row = MySQL.single.await(
        'SELECT balance, paymentamount, paymentsleft FROM player_vehicles WHERE plate = ? AND citizenid = ?',
        { plate, player.PlayerData.citizenid }
    )
    if not row then
        TriggerClientEvent('QBCore:Notify', src, '找不到这台车的分期记录（或不属于你）', 'error')
        return
    end

    local balance = tonumber(row.balance) or 0
    local minPayment = tonumber(row.paymentamount) or 0
    local paymentsLeft = tonumber(row.paymentsleft) or 0
    if balance <= 0 or paymentsLeft <= 1 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.alreadypaid'), 'error')
        return
    end
    if paymentAmount < minPayment then
        TriggerClientEvent('QBCore:Notify', src,
            Lang:t('error.minimumallowed') .. shopUtil.comma_value(minPayment), 'error')
        return
    end
    if paymentAmount > balance then paymentAmount = balance end

    local newBalance = shopUtil.round(balance - paymentAmount)
    local newPaymentsLeft = paymentsLeft - 1
    local newPayment = shopUtil.round(newBalance / newPaymentsLeft)
    local timer = (Config.PaymentInterval * 60)

    local cash = player.PlayerData.money['cash']
    local bank = player.PlayerData.money['bank']
    local account = cash >= paymentAmount and 'cash' or (bank >= paymentAmount and 'bank' or nil)
    if not account then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        return
    end

    if not player.Functions.RemoveMoney(account, paymentAmount, 'financed vehicle') then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        return
    end

    MySQL.update(
        'UPDATE player_vehicles SET balance = ?, paymentamount = ?, paymentsleft = ?, financetime = ? WHERE plate = ? AND citizenid = ?',
        { newBalance, newPayment, newPaymentsLeft, timer, plate, player.PlayerData.citizenid }
    )
end)

-- 全额结清
RegisterNetEvent('qb-vehicleshop:server:financePaymentFull', function(data)
    local src = source
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return end

    -- 🔒 余额也从 DB 取：原来 vehBalance 是客户端给的，付 1 块就能把别人的 balance 清零。
    local plate = type(data) == 'table' and data.vehPlate or nil
    if type(plate) ~= 'string' or #plate == 0 then return end

    local row = MySQL.single.await(
        'SELECT balance FROM player_vehicles WHERE plate = ? AND citizenid = ?',
        { plate, player.PlayerData.citizenid }
    )
    if not row then
        TriggerClientEvent('QBCore:Notify', src, '找不到这台车的分期记录（或不属于你）', 'error')
        return
    end

    local balance = tonumber(row.balance) or 0
    if balance <= 0 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.alreadypaid'), 'error')
        return
    end

    local cash = player.PlayerData.money['cash']
    local bank = player.PlayerData.money['bank']
    local account = cash >= balance and 'cash' or (bank >= balance and 'bank' or nil)
    if not account then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        return
    end

    if not player.Functions.RemoveMoney(account, balance, 'paid off vehicle') then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        return
    end

    MySQL.update(
        'UPDATE player_vehicles SET balance = 0, paymentamount = 0, paymentsleft = 0, financetime = 0 WHERE plate = ? AND citizenid = ?',
        { plate, player.PlayerData.citizenid }
    )
end)

-- ==============================================================
-- 分期购买: 自由商店
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:server:financeVehicle', function(downPayment, paymentAmount, vehicle)
    local src = source
    downPayment   = tonumber(downPayment)
    paymentAmount = tonumber(paymentAmount)
    local pData = QBCore.Functions.GetPlayer(src)
    if not pData then return end

    -- 🔒 车型必须是配置里存在的（原来直接索引 QBCore.Shared.Vehicles[vehicle].price，坏值会让服务端崩）
    if type(vehicle) ~= 'string' or not QBCore.Shared.Vehicles[vehicle] then
        TriggerClientEvent('QBCore:Notify', src, '无效的车型', 'error')
        return
    end
    if not downPayment or not paymentAmount or downPayment < 0 or paymentAmount <= 0 then return end

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
    if not player then return end

    -- 🔒 只有在职车行店员能代客办理分期（同 sellShowroomVehicle）
    if player.PlayerData.job.name ~= 'cardealer' or not player.PlayerData.job.onduty then
        TriggerClientEvent('QBCore:Notify', src, '只有车行员工可以代客办理分期', 'error')
        return
    end

    -- 🔒 车型必须是配置里存在的
    if type(vehicle) ~= 'string' or not QBCore.Shared.Vehicles[vehicle] then
        TriggerClientEvent('QBCore:Notify', src, '无效的车型', 'error')
        return
    end

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
