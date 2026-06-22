-- menus.lua — 客户端菜单逻辑
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 职责:
--   1. 车辆类别/品牌筛选 (vehCategories / vehMakes / openVehCats)
--   2. 分期输入对话框 (openFinance / openCustomFinance)
--   3. 分期车辆管理 (getVehicles / getVehicleFinance / financePayment)
--   4. ID 输入对话框 (openIdMenu)
--   5. 菜单导航事件 (homeMenu / showVehOptions / swapVehicle / buyShowroomVehicle)

local QBCore = exports['qb-core']:GetCoreObject()

-- ==============================================================
-- 事件: 主菜单
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:homeMenu', function()
    exports['qb-menu']:openMenu(vehicleMenu)
end)

RegisterNetEvent('qb-vehicleshop:client:showVehOptions', function()
    exports['qb-menu']:openMenu(vehicleMenu, true, true)
end)

-- ==============================================================
-- 车辆类别选择
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:vehCategories', function(data)
    local catmenu = {}
    local firstvalue = nil
    local categoryMenu = {
        {
            header = Lang:t('menus.goback_header'),
            icon   = 'fa-solid fa-angle-left',
            params = {
                event = Config.FilterByMake and 'qb-vehicleshop:client:vehMakes' or 'qb-vehicleshop:client:homeMenu'
            }
        }
    }
    for k, v in pairs(QBCore.Shared.Vehicles) do
        local shopMatch = false
        if type(QBCore.Shared.Vehicles[k]['shop']) == 'table' then
            for _, shop in pairs(QBCore.Shared.Vehicles[k]['shop']) do
                if shop == insideShop and (not Config.FilterByMake or QBCore.Shared.Vehicles[k]['brand'] == data.make) then
                    shopMatch = true
                end
            end
        elseif QBCore.Shared.Vehicles[k]['shop'] == insideShop
           and (not Config.FilterByMake or QBCore.Shared.Vehicles[k]['brand'] == data.make) then
            shopMatch = true
        end
        if shopMatch then
            catmenu[v.category] = v.category
            if firstvalue == nil then firstvalue = v.category end
        end
    end

    if Config.HideCategorySelectForOne and _vTableLength(catmenu) == 1 then
        TriggerEvent('qb-vehicleshop:client:openVehCats',
            { catName = firstvalue, make = Config.FilterByMake and data.make, onecat = true })
        return
    end

    for k, v in pairs(catmenu) do
        categoryMenu[#categoryMenu + 1] = {
            header = v,
            icon   = 'fa-solid fa-circle',
            params = { event = 'qb-vehicleshop:client:openVehCats', args = { catName = k } }
        }
    end
    exports['qb-menu']:openMenu(categoryMenu, Config.SortAlphabetically, true)
end)

-- ==============================================================
-- 打开某类别下的车辆列表
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:openVehCats', function(data)
    local vehMenu = {
        {
            header = Lang:t('menus.goback_header'),
            icon   = 'fa-solid fa-angle-left',
            params = {
                event = 'qb-vehicleshop:client:vehCategories',
                args  = { make = data.make }
            }
        }
    }
    if data.onecat == true then
        vehMenu[1].params = { event = 'qb-vehicleshop:client:vehMakes' }
    end

    for k, v in pairs(QBCore.Shared.Vehicles) do
        if QBCore.Shared.Vehicles[k]['category'] == data.catName then
            local shopMatch = false
            if type(QBCore.Shared.Vehicles[k]['shop']) == 'table' then
                for _, shop in pairs(QBCore.Shared.Vehicles[k]['shop']) do
                    if shop == insideShop then shopMatch = true end
                end
            elseif QBCore.Shared.Vehicles[k]['shop'] == insideShop then
                shopMatch = true
            end
            if shopMatch then
                vehMenu[#vehMenu + 1] = {
                    header = v.name,
                    txt    = Lang:t('menus.veh_price') .. v.price,
                    icon   = 'fa-solid fa-car-side',
                    params = {
                        isServer = true,
                        event    = 'qb-vehicleshop:server:swapVehicle',
                        args     = {
                            toVehicle      = v.model,
                            ClosestVehicle = ClosestVehicle,
                            ClosestShop    = insideShop
                        }
                    }
                }
            end
        end
    end
    exports['qb-menu']:openMenu(vehMenu, Config.SortAlphabetically, true)
end)

-- ==============================================================
-- 品牌筛选
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:vehMakes', function()
    local makmenu = {}
    local makeMenu = {
        {
            header = Lang:t('menus.goback_header'),
            icon   = 'fa-solid fa-angle-left',
            params = { event = 'qb-vehicleshop:client:homeMenu' }
        }
    }
    for k, v in pairs(QBCore.Shared.Vehicles) do
        if type(QBCore.Shared.Vehicles[k]['shop']) == 'table' then
            for _, shop in pairs(QBCore.Shared.Vehicles[k]['shop']) do
                if shop == insideShop then
                    makmenu[v.brand] = v.brand
                end
            end
        elseif QBCore.Shared.Vehicles[k]['shop'] == insideShop then
            makmenu[v.brand] = v.brand
        end
    end
    for _, v in pairs(makmenu) do
        makeMenu[#makeMenu + 1] = {
            header = v,
            icon   = 'fa-solid fa-circle',
            params = { event = 'qb-vehicleshop:client:vehCategories', args = { make = v } }
        }
    end
    exports['qb-menu']:openMenu(makeMenu, Config.SortAlphabetically, true)
end)

-- ==============================================================
-- 分期: 自由商店输入对话框
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:openFinance', function(data)
    local dialog = exports['qb-input']:ShowInput({
        header     = _vGetVehBrand():upper() .. ' ' .. data.buyVehicle:upper() .. ' - $' .. data.price,
        submitText = Lang:t('menus.submit_text'),
        inputs     = {
            {
                type       = 'number',
                isRequired = true,
                name       = 'downPayment',
                text       = Lang:t('menus.financesubmit_downpayment') .. Config.MinimumDown .. '%'
            },
            {
                type       = 'number',
                isRequired = true,
                name       = 'paymentAmount',
                text       = Lang:t('menus.financesubmit_totalpayment') .. Config.MaximumPayments
            }
        }
    })
    if dialog and dialog.downPayment and dialog.paymentAmount then
        TriggerServerEvent('qb-vehicleshop:server:financeVehicle',
            dialog.downPayment, dialog.paymentAmount, data.buyVehicle)
    end
end)

-- ==============================================================
-- 分期: 管理商店输入对话框 (含客户 ID)
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:openCustomFinance', function(data)
    local dialog = exports['qb-input']:ShowInput({
        header     = _vGetVehBrand():upper() .. ' ' .. data.vehicle:upper() .. ' - $' .. data.price,
        submitText = Lang:t('menus.submit_text'),
        inputs     = {
            {
                type       = 'number',
                isRequired = true,
                name       = 'downPayment',
                text       = Lang:t('menus.financesubmit_downpayment') .. Config.MinimumDown .. '%'
            },
            {
                type       = 'number',
                isRequired = true,
                name       = 'paymentAmount',
                text       = Lang:t('menus.financesubmit_totalpayment') .. Config.MaximumPayments
            },
            {
                text       = Lang:t('menus.submit_ID'),
                name       = 'playerid',
                type       = 'number',
                isRequired = true
            }
        }
    })
    if dialog and dialog.downPayment and dialog.paymentAmount and dialog.playerid then
        TriggerServerEvent('qb-vehicleshop:server:sellfinanceVehicle',
            dialog.downPayment, dialog.paymentAmount, data.vehicle, dialog.playerid)
    end
end)

-- ==============================================================
-- 分期: 查看已分期车辆
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:getVehicles', function()
    QBCore.Functions.TriggerCallback('qb-vehicleshop:server:getVehicles', function(vehicles)
        local ownedVehicles = {}
        for _, v in pairs(vehicles or {}) do
            local vehData = QBCore.Shared.Vehicles[v.vehicle]
            if v.balance ~= 0 and vehData and vehData.shop == insideShop then
                ownedVehicles[#ownedVehicles + 1] = {
                    header = vehData.name,
                    txt    = Lang:t('menus.veh_platetxt') .. v.plate:upper(),
                    icon   = 'fa-solid fa-car-side',
                    params = {
                        event = 'qb-vehicleshop:client:getVehicleFinance',
                        args  = {
                            vehiclePlate  = v.plate:upper(),
                            balance       = v.balance,
                            paymentsLeft  = v.paymentsleft,
                            paymentAmount = v.paymentamount
                        }
                    }
                }
            end
        end
        if #ownedVehicles > 0 then
            exports['qb-menu']:openMenu(ownedVehicles)
        else
            QBCore.Functions.Notify(Lang:t('error.nofinanced'), 'error', 7500)
        end
    end)
end)

-- ==============================================================
-- 分期: 单辆车还款菜单
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:getVehicleFinance', function(data)
    local vehFinance = {
        {
            header = Lang:t('menus.goback_header'),
            params = { event = 'qb-vehicleshop:client:getVehicles' }
        },
        {
            isMenuHeader = true,
            icon  = 'fa-solid fa-sack-dollar',
            header = Lang:t('menus.veh_finance_balance'),
            txt    = Lang:t('menus.veh_finance_currency') .. _vCommaValue(data.balance)
        },
        {
            isMenuHeader = true,
            icon  = 'fa-solid fa-hashtag',
            header = Lang:t('menus.veh_finance_total'),
            txt    = data.paymentsLeft
        },
        {
            isMenuHeader = true,
            icon  = 'fa-solid fa-sack-dollar',
            header = Lang:t('menus.veh_finance_reccuring'),
            txt    = Lang:t('menus.veh_finance_currency') .. _vCommaValue(data.paymentAmount)
        },
        {
            header = Lang:t('menus.veh_finance_pay'),
            icon   = 'fa-solid fa-hand-holding-dollar',
            params = {
                event = 'qb-vehicleshop:client:financePayment',
                args  = {
                    vehData       = data,
                    paymentsLeft  = data.paymentsleft,
                    paymentAmount = data.paymentamount
                }
            }
        },
        {
            header = Lang:t('menus.veh_finance_payoff'),
            icon   = 'fa-solid fa-hand-holding-dollar',
            params = {
                isServer = true,
                event    = 'qb-vehicleshop:server:financePaymentFull',
                args     = { vehBalance = data.balance, vehPlate = data.vehiclePlate }
            }
        },
    }
    exports['qb-menu']:openMenu(vehFinance)
end)

-- ==============================================================
-- 分期: 还款金额输入
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:financePayment', function(data)
    local dialog = exports['qb-input']:ShowInput({
        header     = Lang:t('menus.veh_finance'),
        submitText = Lang:t('menus.veh_finance_pay'),
        inputs     = {
            {
                type       = 'number',
                isRequired = true,
                name       = 'paymentAmount',
                text       = Lang:t('menus.veh_finance_payment')
            }
        }
    })
    if dialog and dialog.paymentAmount then
        TriggerServerEvent('qb-vehicleshop:server:financePayment', dialog.paymentAmount, data.vehData)
    end
end)

-- ==============================================================
-- ID 输入对话框 (试驾 / 代售)
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:openIdMenu', function(data)
    local dialog = exports['qb-input']:ShowInput({
        header     = QBCore.Shared.Vehicles[data.vehicle]['name'],
        submitText = Lang:t('menus.submit_text'),
        inputs     = {
            {
                text       = Lang:t('menus.submit_ID'),
                name       = 'playerid',
                type       = 'number',
                isRequired = true
            }
        }
    })
    if dialog and dialog.playerid then
        if data.type == 'testDrive' then
            TriggerServerEvent('qb-vehicleshop:server:customTestDrive', data.vehicle, dialog.playerid)
        elseif data.type == 'sellVehicle' then
            TriggerServerEvent('qb-vehicleshop:server:sellShowroomVehicle', data.vehicle, dialog.playerid)
        end
    end
end)

-- ==============================================================
-- 客户端: 换车 (展示车辆切换)
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:swapVehicle', function(data)
    local shopName = data.ClosestShop
    local showroom = Config.Shops[shopName]['ShowroomVehicles'][data.ClosestVehicle]
    if showroom.chosenVehicle == data.toVehicle then return end

    local closestVehicle, closestDistance = QBCore.Functions.GetClosestVehicle(
        vector3(showroom.coords.x, showroom.coords.y, showroom.coords.z))
    if closestVehicle == 0 then return end
    if closestDistance < 5 then DeleteEntity(closestVehicle) end
    while DoesEntityExist(closestVehicle) do Wait(50) end

    showroom.chosenVehicle = data.toVehicle
    local model = GetHashKey(data.toVehicle)
    RequestModel(model)
    while not HasModelLoaded(model) do Wait(50) end
    local veh = CreateVehicle(model, showroom.coords.x, showroom.coords.y, showroom.coords.z, false, false)
    while not DoesEntityExist(veh) do Wait(50) end
    SetModelAsNoLongerNeeded(model)
    SetVehicleOnGroundProperly(veh)
    SetEntityInvincible(veh, true)
    SetEntityHeading(veh, showroom.coords.w)
    SetVehicleDoorsLocked(veh, 3)
    FreezeEntityPosition(veh, true)
    SetVehicleNumberPlateText(veh, 'BUY ME')
    if Config.UsingTarget then _vCreateVehZones(shopName, veh) end
    -- Phase 1: 刷新菜单以反映新车辆信息
    TriggerEvent('qb-vehicleshop:client:refreshMenu')
end)

-- ==============================================================
-- 客户端: 收到已购买车辆
-- ==============================================================

RegisterNetEvent('qb-vehicleshop:client:buyShowroomVehicle', function(vehicle, plate)
    tempShop = insideShop
    QBCore.Functions.TriggerCallback('qb-vehicleshop:server:spawnvehicle', function(netId, properties, vehPlate)
        while not NetworkDoesNetworkIdExist(netId) do Wait(10) end
        local veh = NetworkGetEntityFromNetworkId(netId)
        Citizen.Await(_vCheckPlate(veh, vehPlate))
        QBCore.Functions.SetVehicleProperties(veh, properties)
        exports['LegacyFuel']:SetFuel(veh, 100)
        TriggerEvent('vehiclekeys:client:SetOwner', vehPlate)
        TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
        SetVehicleEngineOn(veh, true, true, false)
    end, plate, vehicle, Config.Shops[tempShop]['VehicleSpawn'], true)
end)

print('[qb-vehicleshop] 📋 菜单模块已加载 (menus.lua)')
