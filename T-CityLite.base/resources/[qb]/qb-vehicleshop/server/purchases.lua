-- purchases.lua — 购买逻辑 (buyShowroom / sellShowroom / transfervehicle)
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 职责:
--   1. 自由商店直购 (buyShowroomVehicle)
--   2. 管理商店员工代售 (sellShowroomVehicle)
--   3. 玩家间车辆转让 (transfervehicle command)
--   4. 车辆生成与 plate 生成
--
-- 安全保证:
--   - 全部支付走服务端路径, 金额服务端二次验证
--   - 驾照检查服务端权威
--   - 钥匙同步 custom-vehicles (exports 调用, pcall 保护)

local QBCore = exports['qb-core']:GetCoreObject()
local shopUtil = _G._vehicleshop

-- ==============================================================
-- 内部: 写入 player_vehicles 并扣款
-- ==============================================================

local function InsertVehicleAndDeduct(pData, vehicle, plate, price, paymentType, extraFields)
    extraFields = extraFields or {}
    local cols  = { 'license', 'citizenid', 'vehicle', 'hash', 'mods', 'plate', 'garage', 'state' }
    local vals  = {
        pData.PlayerData.license,
        pData.PlayerData.citizenid,
        vehicle,
        GetHashKey(vehicle),
        '{}',
        plate,
        'pillboxgarage',
        0,
    }
    -- 追加额外字段 (分期: balance, paymentamount, paymentsleft, financetime)
    for _, field in ipairs(extraFields.columns or {}) do
        cols[#cols + 1] = field
    end
    for _, value in ipairs(extraFields.values or {}) do
        vals[#vals + 1] = value
    end

    local colStr = table.concat(cols, ', ')
    local placeholders = {}
    for _ = 1, #cols do placeholders[#placeholders + 1] = '?' end
    MySQL.insert(('INSERT INTO player_vehicles (%s) VALUES (%s)'):format(colStr, table.concat(placeholders, ', ')), vals, function(affected)
        if affected and affected.affectedRows and affected.affectedRows > 0 then
            -- Phase 6: 确认插入成功
        else
            print('[qb-vehicleshop] ❌ DB INSERT FAILED for plate: ' .. tostring(plate) .. ' vehicle: ' .. tostring(vehicle))
        end
    end)

    pData.Functions.RemoveMoney(paymentType, price, 'vehicle-bought-in-showroom')

    -- 💰 新车购置税 8%
    if GetResourceState('custom-taxes') == 'started' then
        pcall(function()
            exports['custom-taxes']:CollectVehiclePurchaseTax(pData.PlayerData.source, price, vehicle)
        end)
    end
end

-- ==============================================================
-- 事件: 自由商店直购
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:server:buyShowroomVehicle', function(vehicleData)
    local src = source
    local vehicle = vehicleData.buyVehicle
    local pData = QBCore.Functions.GetPlayer(src)

    -- 安全: 驾照检查
    if not shopUtil.CheckVehicleLicense(pData, vehicle) then
        local licenseName = shopUtil.GetRequiredLicenseName(vehicle)
        TriggerClientEvent('QBCore:Notify', src,
            ('You need a %s to purchase this vehicle!'):format(licenseName or 'license'), 'error', 5000)
        return
    end

    local cash         = pData.PlayerData.money['cash']
    local bank         = pData.PlayerData.money['bank']
    local vehiclePrice = QBCore.Shared.Vehicles[vehicle]['price']
    local plate        = shopUtil.GeneratePlate()

    if cash >= tonumber(vehiclePrice) then
        InsertVehicleAndDeduct(pData, vehicle, plate, vehiclePrice, 'cash')
    elseif bank >= tonumber(vehiclePrice) then
        InsertVehicleAndDeduct(pData, vehicle, plate, vehiclePrice, 'bank')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        return
    end

    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.purchased'), 'success')
    TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', src, vehicle, plate)
end)

-- ==============================================================
-- 事件: 管理商店员工代售
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:server:sellShowroomVehicle', function(data, playerid)
    local src    = source
    local player = QBCore.Functions.GetPlayer(src)
    local target = QBCore.Functions.GetPlayer(tonumber(playerid))

    if not target then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error')
        return
    end

    -- 安全: 买家驾照检查
    if not shopUtil.CheckVehicleLicense(target, data) then
        local licenseName = shopUtil.GetRequiredLicenseName(data)
        TriggerClientEvent('QBCore:Notify', src,
            ('Buyer needs a %s to purchase this vehicle!'):format(licenseName or 'license'), 'error', 5000)
        return
    end

    if #(GetEntityCoords(GetPlayerPed(src)) - GetEntityCoords(GetPlayerPed(target.PlayerData.source))) >= 3 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error')
        return
    end

    local vehicle      = data
    local vehiclePrice = QBCore.Shared.Vehicles[vehicle]['price']
    local commission   = shopUtil.round(vehiclePrice * Config.Commission)
    local plate        = shopUtil.GeneratePlate()
    local cash         = target.PlayerData.money['cash']
    local bank         = target.PlayerData.money['bank']

    if cash >= tonumber(vehiclePrice) then
        InsertVehicleAndDeduct(target, vehicle, plate, vehiclePrice, 'cash')
        player.Functions.AddMoney('bank', commission, 'vehicle sale commission')
    elseif bank >= tonumber(vehiclePrice) then
        InsertVehicleAndDeduct(target, vehicle, plate, vehiclePrice, 'bank')
        player.Functions.AddMoney('bank', commission, 'vehicle sale commission')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notenoughmoney'), 'error')
        return
    end

    TriggerClientEvent('qb-vehicleshop:client:buyShowroomVehicle', target.PlayerData.source, vehicle, plate)
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.earned_commission',
        { amount = shopUtil.comma_value(commission) }), 'success')
    pcall(function()
        exports['qb-banking']:AddMoney(player.PlayerData.job.name, vehiclePrice, 'Vehicle sale')
    end)
    TriggerClientEvent('QBCore:Notify', target.PlayerData.source, Lang:t('success.purchased'), 'success')
end)

-- ==============================================================
-- 事件: 玩家间车辆转让 (/transfervehicle)
-- ==============================================================

QBCore.Commands.Add('transfervehicle',
    Lang:t('general.command_transfervehicle'),
    {
        { name = 'ID',     help = Lang:t('general.command_transfervehicle_help') },
        { name = 'amount', help = Lang:t('general.command_transfervehicle_amount') },
    },
    false,
    function(source, args)
        local src       = source
        local buyerId   = tonumber(args[1])
        local sellAmount = tonumber(args[2])

        if buyerId == 0 then
            return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.Invalid_ID'), 'error')
        end

        local ped       = GetPlayerPed(src)
        local targetPed = GetPlayerPed(buyerId)
        if targetPed == 0 then
            return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyerinfo'), 'error')
        end

        local vehicle = GetVehiclePedIsIn(ped, false)
        if vehicle == 0 then
            return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notinveh'), 'error')
        end

        local plate = QBCore.Shared.Trim(GetVehicleNumberPlateText(vehicle))
        if not plate then
            return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.vehinfo'), 'error')
        end

        local player = QBCore.Functions.GetPlayer(src)
        local target = QBCore.Functions.GetPlayer(buyerId)
        if not target then
            return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyerinfo'), 'error')
        end

        local row = MySQL.single.await('SELECT * FROM player_vehicles WHERE plate = ?', { plate })

        if Config.PreventFinanceSelling and row.balance > 0 then
            return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.financed'), 'error')
        end
        if row.citizenid ~= player.PlayerData.citizenid then
            return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.notown'), 'error')
        end
        if #(GetEntityCoords(ped) - GetEntityCoords(targetPed)) > 5.0 then
            return TriggerClientEvent('QBCore:Notify', src, Lang:t('error.playertoofar'), 'error')
        end

        -- 安全检查: 买家驾照
        local vehicleModel = row.vehicle
        if vehicleModel and not shopUtil.CheckVehicleLicense(target, vehicleModel) then
            local licenseName = shopUtil.GetRequiredLicenseName(vehicleModel)
            TriggerClientEvent('QBCore:Notify', src,
                ('Buyer needs a %s to receive this vehicle!'):format(licenseName or 'license'), 'error', 5000)
            return
        end

        local targetcid      = target.PlayerData.citizenid
        local targetlicense  = QBCore.Functions.GetIdentifier(target.PlayerData.source, 'license')

        if not sellAmount then
            -- 免费赠送
            MySQL.update('UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ?',
                { targetcid, targetlicense, plate })

            pcall(function()
                exports['custom-vehicles']:RemoveKeys(plate, player.PlayerData.citizenid)
                exports['custom-vehicles']:SetOwner(plate, targetcid)
            end)

            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.gifted'), 'success')
            TriggerClientEvent('vehiclekeys:client:SetOwner', buyerId, plate)
            TriggerClientEvent('QBCore:Notify', buyerId, Lang:t('success.received_gift'), 'success')
            return
        end

        -- 付费转让
        local targetCash = target.Functions.GetMoney('cash')
        local targetBank = target.Functions.GetMoney('bank')

        if targetCash >= sellAmount then
            MySQL.update('UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ?',
                { targetcid, targetlicense, plate })

            pcall(function()
                exports['custom-vehicles']:RemoveKeys(plate, player.PlayerData.citizenid)
                exports['custom-vehicles']:SetOwner(plate, targetcid)
            end)

            player.Functions.AddMoney('cash', sellAmount, 'transferred vehicle')
            target.Functions.RemoveMoney('cash', sellAmount, 'transferred vehicle')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.soldfor') .. shopUtil.comma_value(sellAmount), 'success')
            TriggerClientEvent('vehiclekeys:client:SetOwner', buyerId, plate)
            TriggerClientEvent('QBCore:Notify', buyerId, Lang:t('success.boughtfor') .. shopUtil.comma_value(sellAmount), 'success')
        elseif targetBank >= sellAmount then
            MySQL.update('UPDATE player_vehicles SET citizenid = ?, license = ? WHERE plate = ?',
                { targetcid, targetlicense, plate })

            pcall(function()
                exports['custom-vehicles']:RemoveKeys(plate, player.PlayerData.citizenid)
                exports['custom-vehicles']:SetOwner(plate, targetcid)
            end)

            player.Functions.AddMoney('bank', sellAmount, 'transferred vehicle')
            target.Functions.RemoveMoney('bank', sellAmount, 'transferred vehicle')
            TriggerClientEvent('QBCore:Notify', src, Lang:t('success.soldfor') .. shopUtil.comma_value(sellAmount), 'success')
            TriggerClientEvent('vehiclekeys:client:SetOwner', buyerId, plate)
            TriggerClientEvent('QBCore:Notify', buyerId, Lang:t('success.boughtfor') .. shopUtil.comma_value(sellAmount), 'success')
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('error.buyertoopoor'), 'error')
        end
    end
)

print('[qb-vehicleshop] 🛒 购买模块已加载 (purchases.lua)')
