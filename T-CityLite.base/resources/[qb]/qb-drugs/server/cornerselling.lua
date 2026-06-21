local StolenDrugs = {}

local function getAvailableDrugs(source)
    local AvailableDrugs = {}
    local Player = QBCore.Functions.GetPlayer(source)

    if not Player then return nil end

    for k in pairs(Config.DrugsPrice) do
        local item = Player.Functions.GetItemByName(k)

        if item then
            AvailableDrugs[#AvailableDrugs + 1] = {
                item = item.name,
                amount = item.amount,
                label = QBCore.Shared.Items[item.name]['label']
            }
        end
    end
    return table.type(AvailableDrugs) ~= 'empty' and AvailableDrugs or nil
end

QBCore.Functions.CreateCallback('qb-drugs:server:cornerselling:getAvailableDrugs', function(source, cb)
    cb(getAvailableDrugs(source))
end)

RegisterNetEvent('qb-drugs:server:giveStealItems', function(drugType, amount)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or StolenDrugs == {} then return end
    for k, v in pairs(StolenDrugs) do
        if drugType == v.item and amount == v.amount then
            exports['qb-inventory']:AddItem(src, drugType, amount, false, false, 'qb-drugs:server:giveStealItems')
            table.remove(StolenDrugs, k)
        end
    end
end)

RegisterNetEvent('qb-drugs:server:sellCornerDrugs', function(drugType, amount, price)
    local src = source
    if not src or src == 0 then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local availableDrugs = getAvailableDrugs(src)
    if not availableDrugs or not availableDrugs[drugType] then return end
    local item = availableDrugs[drugType].item
    amount = tonumber(amount) or 0
    if amount <= 0 then return end
    -- [SECURITY] Calculate price server-side from Config (DrugsPrice[item] = {min, max})
    local priceCfg = Config.DrugsPrice[item]
    local unitPrice = 0
    if type(priceCfg) == 'table' then
        unitPrice = math.floor((priceCfg.min + priceCfg.max) / 2 + 0.5)   -- 取中间价作为服务端计价
    elseif type(priceCfg) == 'number' then
        unitPrice = priceCfg
    end
    local serverPrice = unitPrice * amount
    if serverPrice <= 0 then return end
    local hasItem = Player.Functions.GetItemByName(item)
    if hasItem and hasItem.amount >= amount then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.offer_accepted'), 'success')
        exports['qb-inventory']:RemoveItem(src, item, amount, false, 'qb-drugs:server:sellCornerDrugs')
        -- [SECURITY] Route through AddScaledMoney unified economy exit
        local function doPayout(src, amount, reason)
            if exports['custom-economy'] and exports['custom-economy'].AddScaledMoney then
                exports['custom-economy']:AddScaledMoney(src, 'cash', amount, reason)
            else
                local Player = QBCore.Functions.GetPlayer(src)
                if Player then Player.Functions.AddMoney('cash', amount, reason) end
            end
        end
        doPayout(src, serverPrice, 'qb-drugs:server:sellCornerDrugs')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[item], 'remove')
        TriggerClientEvent('qb-drugs:client:refreshAvailableDrugs', src, getAvailableDrugs(src))
    else
        TriggerClientEvent('qb-drugs:client:cornerselling', src)
    end
end)

RegisterNetEvent('qb-drugs:server:robCornerDrugs', function(drugType, amount)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local availableDrugs = getAvailableDrugs(src)
    if not availableDrugs or not Player then return end
    local item = availableDrugs[drugType].item
    exports['qb-inventory']:RemoveItem(src, item, amount, false, 'qb-drugs:server:robCornerDrugs')
    table.insert(StolenDrugs, { item = item, amount = amount })
    TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[item], 'remove')
    TriggerClientEvent('qb-drugs:client:refreshAvailableDrugs', src, getAvailableDrugs(src))
end)

-- =============================================
-- 命令：/selldrugs — 打开街头毒品出售界面
-- =============================================
QBCore.Commands.Add('selldrugs', '切换街头毒品出售模式', {}, false, function(source)
    TriggerClientEvent('qb-drugs:client:cornerselling', source)
end, 'user')
