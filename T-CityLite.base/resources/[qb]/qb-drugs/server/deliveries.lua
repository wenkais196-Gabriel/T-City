QBCore = exports['qb-core']:GetCoreObject()

-- Functions
exports('GetDealers', function()
    return Config.Dealers
end)

-- Callbacks
QBCore.Functions.CreateCallback('qb-drugs:server:RequestConfig', function(_, cb)
    cb(Config.Dealers)
end)

-- =============================================
-- 接取配送：扣押金 + 给货
-- =============================================
-- 🔒 排他锁: 防止同一玩家快速连续接取刷物品
local acceptLocks = {}

RegisterNetEvent('qb-drugs:server:acceptDelivery', function(deliveryData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 🔒 Mutex Lock: 同一玩家同一时间只能有一个接取操作在处理中
    if acceptLocks[src] then
        TriggerClientEvent('QBCore:Notify', src, 'Please wait...', 'error')
        return
    end
    acceptLocks[src] = true

    local deposit = deliveryData['deposit'] or 0
    local item = Config.DeliveryItems[deliveryData.item].item
    local itemAmount = deliveryData.amount

    -- 检查余额
    local cash = Player.Functions.GetMoney('cash')
    if cash < deposit then
        TriggerClientEvent('QBCore:Notify', src, ('押金不足！需要 $%d，你只有 $%d'):format(deposit, cash), 'error')
        acceptLocks[src] = nil
        return
    end

    -- 原子操作: 先扣钱再给货 (顺序不可逆, 防止余额检查与扣款之间的竞态)
    local removed = Player.Functions.RemoveMoney('cash', deposit, '配送押金')
    if not removed then
        acceptLocks[src] = nil
        return
    end

    -- 给货
    exports['qb-inventory']:AddItem(src, item, itemAmount, false, false, 'qb-drugs:server:acceptDelivery')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[item], 'add')

    -- 延迟释放锁 (防止极速连续触发)
    SetTimeout(2000, function()
        acceptLocks[src] = nil
    end)

    print(('[qb-drugs] %s accepted delivery: %s x%d, deposit=$%d, distance=%.0fm'):format(
        GetPlayerName(src), item, itemAmount, deposit, deliveryData['distance'] or 0))
end)

-- Events
RegisterNetEvent('qb-drugs:server:updateDealerItems', function(itemData, amount, dealer)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    if Config.Dealers[dealer]['products'][itemData.slot].amount - 1 >= 0 then
        Config.Dealers[dealer]['products'][itemData.slot].amount = Config.Dealers[dealer]['products'][itemData.slot].amount - amount
        TriggerClientEvent('qb-drugs:client:setDealerItems', -1, itemData, amount, dealer)
    else
        exports['qb-inventory']:RemoveItem(src, itemData.name, amount, false, 'qb-drugs:server:updateDealerItems')
        Player.Functions.AddMoney('cash', amount * Config.Dealers[dealer]['products'][itemData.slot].price, 'qb-drugs:server:updateDealerItems')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.item_unavailable'), 'error')
    end
end)

-- 配送失败（超时/取消）：从背包移除任务物品
RegisterNetEvent('qb-drugs:server:failDelivery', function(deliveryData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local item = Config.DeliveryItems[deliveryData.item].item
    local itemAmount = deliveryData.amount
    local invItem = Player.Functions.GetItemByName(item)
    if invItem and invItem.amount >= itemAmount then
        exports['qb-inventory']:RemoveItem(src, item, itemAmount, false, 'qb-drugs:server:failDelivery')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[item], 'remove')
    end
    print(('[qb-drugs] %s delivery failed (timeout/cancel): removed %s x%d'):format(GetPlayerName(src), item, itemAmount))
end)

RegisterNetEvent('qb-drugs:server:successDelivery', function(deliveryData, completed, elapsed)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local item = Config.DeliveryItems[deliveryData.item].item
    local itemAmount = deliveryData.amount
    local basePayout = deliveryData.basePayout or (deliveryData.itemData.payout * itemAmount)
    local deposit = deliveryData.deposit or 0
    local fastTime = deliveryData.fastTime or 300
    local maxTime = deliveryData.maxTime or 600
    local copsOnline = QBCore.Functions.GetDutyCount('police')
    local invItem = Player.Functions.GetItemByName(item)
    elapsed = tonumber(elapsed) or 0

    -- 判定等级
    local tier = 'timeout'  -- 超时
    if completed then
        if elapsed <= fastTime then tier = 'fast'
        elseif elapsed <= maxTime then tier = 'normal'
        else tier = 'late'
        end
    end

    -- 先回收货物
    if invItem and invItem.amount >= itemAmount then
        exports['qb-inventory']:RemoveItem(src, item, itemAmount, false, 'qb-drugs:server:successDelivery')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[item], 'remove')
    end

    if tier == 'fast' then
        -- ⚡ 快速：120% 报酬 + 返还押金 + 声望+2
        local reward = math.floor(basePayout * Config.DeliveryRewardFast)
        local finalReward = reward
        if copsOnline > 0 then
            finalReward = math.floor(reward * (1 + copsOnline * 0.1))
        end
        Player.Functions.AddMoney('cash', finalReward + deposit, '配送奖励(快速)')
        Player.Functions.AddRep('dealer', Config.DeliveryRepGain + 1)
        local dealerRep = Player.Functions.GetRep('dealer')
        TriggerClientEvent('QBCore:Notify', src,
            ('⚡ 快速送达！+$%d (含押金$%d) | 声望+%d'):format(finalReward + deposit, deposit, Config.DeliveryRepGain + 1), 'success')

    elseif tier == 'normal' then
        -- 🟢 合格：100% 报酬 + 返还押金 + 声望+1
        local finalReward = basePayout
        if copsOnline > 0 then
            finalReward = math.floor(basePayout * (1 + copsOnline * 0.08))
        end
        Player.Functions.AddMoney('cash', finalReward + deposit, '配送奖励(合格)')
        Player.Functions.AddRep('dealer', Config.DeliveryRepGain)
        local dealerRep = Player.Functions.GetRep('dealer')
        TriggerClientEvent('QBCore:Notify', src,
            ('🟢 合格送达！+$%d (含押金$%d) | 声望+%d'):format(finalReward + deposit, deposit, Config.DeliveryRepGain), 'success')

    elseif tier == 'late' then
        -- 🟡 迟到：仅返还押金，无报酬，无声望
        Player.Functions.AddMoney('cash', deposit, '配送押金退还(迟到)')
        TriggerClientEvent('QBCore:Notify', src,
            ('🟡 迟到送达！押金 $%d 已退还，无额外报酬'):format(deposit), 'primary')

    else
        -- 🔴 超时：扣押金，货物已在顶部回收
        TriggerClientEvent('QBCore:Notify', src,
            ('🔴 配送失败！押金 $%d 已损失'):format(deposit), 'error')

    end

    -- 通知手机：配送已结束，GPS 导航失效
    if deliveryData.coords and deliveryData.coords.x then
        TriggerClientEvent('phone:client:gpsMessage', src, {
            status = 'done',
            gps = { x = deliveryData.coords.x, y = deliveryData.coords.y, label = deliveryData.locationLabel or '目的地' },
        })
    end
end)


RegisterNetEvent('qb-drugs:server:sendDeliverySMS', function(message, coords, status)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local phoneNumber = Player.PlayerData.charinfo.phone
    if not phoneNumber then return end
    local msgData = {
        id = math.random(10000, 99999),
        sender_number = '000-0000',
        receiver_number = phoneNumber,
        message = message,
        timestamp = os.time(),
        is_read = false,
    }
    -- 附带 GPS 坐标 + 状态（走统一 GPS 消息总线）
    if coords and coords.x then
        msgData.gps = { x = coords.x, y = coords.y, label = coords.label or '目的地' }
    end
    if status then
        msgData.status = status
    end
    local gpsJson = (coords and coords.x) and json.encode({ x = coords.x, y = coords.y, label = coords.label }) or nil
    MySQL.insert('INSERT INTO phone_messages (sender_number, receiver_number, message, gps, msg_status) VALUES (?, ?, ?, ?, ?)', {
        '000-0000', phoneNumber, message, gpsJson, status or nil
    }, function()
        -- 有 GPS → 走统一总线（自动设导航点 + 通知）
        if coords and coords.x then
            TriggerClientEvent('phone:client:gpsMessage', src, msgData)
        else
            TriggerClientEvent('phone:client:newMessage', src, msgData)
        end
    end)
end)

RegisterNetEvent('qb-drugs:server:dealerShop', function(currentDealer)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local playerPed = GetPlayerPed(src)
    local playerCoords = GetEntityCoords(playerPed)
    local dealerData = Config.Dealers[currentDealer]
    if not dealerData then return end
    local dist = #(playerCoords - vector3(dealerData.coords.x, dealerData.coords.y, dealerData.coords.z))
    if dist > 5.0 then return end
    local curRep = Player.Functions.GetRep('dealer')
    local repItems = {}
    for k in pairs(dealerData.products) do
        if curRep >= dealerData['products'][k].minrep then
            repItems[#repItems+1] = dealerData['products'][k]
        end
    end
    exports['qb-inventory']:CreateShop({
        name = dealerData.name,
        label = dealerData.name,
        slots = #repItems,
        coords = dealerData.coords,
        items = repItems,
    })
    exports['qb-inventory']:OpenShop(src, dealerData.name)
end)

-- Commands

QBCore.Commands.Add('newdealer', Lang:t('info.newdealer_command_desc'), { {
    name = Lang:t('info.newdealer_command_help1_name'),
    help = Lang:t('info.newdealer_command_help1_help')
}, {
    name = Lang:t('info.newdealer_command_help2_name'),
    help = Lang:t('info.newdealer_command_help2_help')
}, {
    name = Lang:t('info.newdealer_command_help3_name'),
    help = Lang:t('info.newdealer_command_help3_help')
} }, true, function(source, args)
    local ped = GetPlayerPed(source)
    local coords = GetEntityCoords(ped)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return end
    local dealerName = args[1]
    local minTime = tonumber(args[2])
    local maxTime = tonumber(args[3])
    local time = json.encode({ min = minTime, max = maxTime })
    local pos = json.encode({ x = coords.x, y = coords.y, z = coords.z })
    local result = MySQL.scalar.await('SELECT name FROM dealers WHERE name = ?', { dealerName })
    if result then return TriggerClientEvent('QBCore:Notify', source, Lang:t('error.dealer_already_exists'), 'error') end
    MySQL.insert('INSERT INTO dealers (name, coords, time, createdby) VALUES (?, ?, ?, ?)', { dealerName, pos, time, Player.PlayerData.citizenid }, function()
        Config.Dealers[dealerName] = {
            ['name'] = dealerName,
            ['coords'] = {
                ['x'] = coords.x,
                ['y'] = coords.y,
                ['z'] = coords.z
            },
            ['time'] = {
                ['min'] = minTime,
                ['max'] = maxTime
            },
            ['products'] = Config.Products
        }
        TriggerClientEvent('qb-drugs:client:RefreshDealers', -1, Config.Dealers)
    end)
end, 'admin')

QBCore.Commands.Add('deletedealer', Lang:t('info.deletedealer_command_desc'), { {
    name = Lang:t('info.deletedealer_command_help1_name'),
    help = Lang:t('info.deletedealer_command_help1_help')
} }, true, function(source, args)
    local dealerName = args[1]
    local result = MySQL.scalar.await('SELECT * FROM dealers WHERE name = ?', { dealerName })
    if result then
        MySQL.query('DELETE FROM dealers WHERE name = ?', { dealerName })
        Config.Dealers[dealerName] = nil
        TriggerClientEvent('qb-drugs:client:RefreshDealers', -1, Config.Dealers)
        TriggerClientEvent('QBCore:Notify', source, Lang:t('success.dealer_deleted', { dealerName = dealerName }), 'success')
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.dealer_not_exists_command', { dealerName = dealerName }), 'error')
    end
end, 'admin')

QBCore.Commands.Add('dealers', Lang:t('info.dealers_command_desc'), {}, false, function(source, _)
    local DealersText = ''
    if Config.Dealers ~= nil and next(Config.Dealers) ~= nil then
        for _, v in pairs(Config.Dealers) do
            DealersText = DealersText .. Lang:t('info.list_dealers_name_prefix') .. v['name'] .. '<br>'
        end
        TriggerClientEvent('chat:addMessage', source, {
            template = '<div class="chat-message advert"><div class="chat-message-body"><strong>' .. Lang:t('info.list_dealers_title') .. '</strong><br><br> ' .. DealersText .. '</div></div>',
            args = {}
        })
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.no_dealers'), 'error')
    end
end, 'admin')

QBCore.Commands.Add('dealergoto', Lang:t('info.dealergoto_command_desc'), { {
    name = Lang:t('info.dealergoto_command_help1_name'),
    help = Lang:t('info.dealergoto_command_help1_help')
} }, true, function(source, args)
    local DealerName = tostring(args[1])
    if Config.Dealers[DealerName] then
        local ped = GetPlayerPed(source)
        SetEntityCoords(ped, Config.Dealers[DealerName]['coords']['x'], Config.Dealers[DealerName]['coords']['y'], Config.Dealers[DealerName]['coords']['z'])
        TriggerClientEvent('QBCore:Notify', source, Lang:t('success.teleported_to_dealer', { dealerName = DealerName }), 'success')
    else
        TriggerClientEvent('QBCore:Notify', source, Lang:t('error.dealer_not_exists'), 'error')
    end
end, 'admin')

CreateThread(function()
    Wait(500)
    local dealers = MySQL.query.await('SELECT * FROM dealers', {})
    if dealers[1] then
        for _, v in pairs(dealers) do
            local coords = json.decode(v.coords)
            local time = json.decode(v.time)

            Config.Dealers[v.name] = {
                ['name'] = v.name,
                ['coords'] = {
                    ['x'] = coords.x,
                    ['y'] = coords.y,
                    ['z'] = coords.z
                },
                ['time'] = {
                    ['min'] = time.min,
                    ['max'] = time.max
                },
                ['products'] = Config.Products
            }
        end
    end
    TriggerClientEvent('qb-drugs:client:RefreshDealers', -1, Config.Dealers)
end)
