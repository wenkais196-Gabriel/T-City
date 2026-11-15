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

-- 🔒 服务端权威记录（2026-11-07，P1-5 阶段 F）：
-- 原来押金 / 报酬 / 时间窗口全由客户端 deliveryData 决定 —— 改包就能 `deposit = 1e9`
-- 换到 `AddMoney(finalReward + deposit)`，等于凭空印钱（宪法第 1 条：服务端权威）。
-- 现在接单时按 Config 算好并留档，结算只认这份记录，客户端传的值一律不采信。
local activeDeliveries = {}

-- 掉线时把"未结算的配送"记到 citizenid 名下，等玩家**重新上线**再结算：
-- 那时玩家在线，操作背包是安全的（离线装卸 inventory 会和存档打架）。
-- 结算规则：货还在 → 回收并退还押金；货没了 → 押金不退（货已经被用掉了）。
local pendingSettlements = {}

local function DeliveryTimes(distance)
    local baseTime = math.ceil(distance / Config.DeliveryAvgSpeed) + Config.DeliveryFixedTime
    return {
        baseTime = baseTime,
        fastTime = math.ceil(baseTime * Config.DeliveryFastMult),
        maxTime = math.ceil(baseTime * Config.DeliveryLateMult),
    }
end

-- 断线清理：记录属于"这个 source 上的这个角色"。掉线后不清，FiveM 复用 source 时
-- 新玩家可能把旧单结算掉（CC 复核实测：没交押金也能拿到报酬+押金）。
AddEventHandler('playerDropped', function()
    local src = source
    local record = activeDeliveries[src]
    if record and record.citizenid then
        pendingSettlements[record.citizenid] = {
            itemName = Config.DeliveryItems[record.item].item,
            amount = record.amount,
            deposit = record.deposit,
        }
    end
    activeDeliveries[src] = nil
    acceptLocks[src] = nil
end)

-- 玩家重新上线：结算上一次掉线留下的配送（在线状态下操作背包才安全）
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local citizenid = Player.PlayerData.citizenid
    local pending = pendingSettlements[citizenid]
    if not pending then return end

    -- qb-inventory 是在自己的 QBCore:Server:PlayerLoaded 里把 RemoveItem 注入到 Player.Functions 的；
    -- 它热重启/加载顺序变化时这里会是 nil —— 此时**保留 pending**，等玩家下次上线再结算。
    if type(Player.Functions.RemoveItem) ~= 'function' then
        print(('[qb-drugs] drop settlement skipped for %s: qb-inventory 未就绪，保留待下次'):format(citizenid))
        return
    end

    local source = Player.PlayerData.source
    local ok, removed = pcall(Player.Functions.RemoveItem, pending.itemName, pending.amount, false, 'qb-drugs:dropSettlement')
    if not ok then
        print(('[qb-drugs] drop settlement failed for %s: %s（保留 pending）'):format(citizenid, tostring(removed)))
        return
    end

    pendingSettlements[citizenid] = nil            -- 结算成功后消费，防重复

    if removed then
        Player.Functions.AddMoney('cash', pending.deposit, '配送押金退还(掉线结算)')
        TriggerClientEvent('QBCore:Notify', source,
            ('上次掉线的配送已取消：回收 %s x%d，退还押金 $%s'):format(pending.itemName, pending.amount, Money(pending.deposit)),
            'primary')
        print(('[qb-drugs] drop settlement: %s refunded $%s'):format(citizenid, Money(pending.deposit)))
    else
        TriggerClientEvent('QBCore:Notify', source,
            ('上次掉线的配送货已不在背包，押金 $%s 不退'):format(Money(pending.deposit)), 'error')
        print(('[qb-drugs] drop settlement: %s forfeited $%s (item gone)'):format(citizenid, Money(pending.deposit)))
    end
end)

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

    -- 一次只能有一单：否则第二单会覆盖记录 —— 第一单的押金白扣、货还在背包（CC 复核实测净赚 500/轮）
    if activeDeliveries[src] then
        acceptLocks[src] = nil
        TriggerClientEvent('QBCore:Notify', src, '你还有一单配送没结算，先完成或取消它', 'error')
        return
    end

    -- 校验商品：只认 Config 里的 key（原来直接索引，坏 key 会抛错；伪造 key 更是
    -- 商品 key 在 Config 里是**数字下标**（1/2…），客户端传来也是数字；字符串 key 也一并接受
    local itemKey = type(deliveryData) == 'table' and deliveryData.item or nil
    local itemConfig = (type(itemKey) == 'number' or type(itemKey) == 'string')
        and Config.DeliveryItems[itemKey] or nil
    if not itemConfig then
        acceptLocks[src] = nil
        TriggerClientEvent('QBCore:Notify', src, '无效的配送商品', 'error')
        return
    end

    -- 数量固定 1（客户端传什么都不认）；押金与报酬按 Config 反算
    local itemAmount = 1
    local item = itemConfig.item
    local basePayout = itemConfig.payout * itemAmount
    local deposit = math.ceil(basePayout * Config.DeliveryDepositRate)
    local distance = math.max(0, math.min(tonumber(deliveryData.distance) or 0, 20000))
    local times = DeliveryTimes(distance)

    -- 检查余额
    local cash = Player.Functions.GetMoney('cash')
    if cash < deposit then
        TriggerClientEvent('QBCore:Notify', src, ('押金不足！需要 $%s，你只有 $%s'):format(Money(deposit), Money(cash)), 'error')
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

    -- 留档：结算只认这份，防重放
    activeDeliveries[src] = {
        citizenid = Player.PlayerData.citizenid,   -- 断线后 source 可能被复用，结算必须核对身份
        item = itemKey,
        amount = itemAmount,
        basePayout = basePayout,
        deposit = deposit,
        fastTime = times.fastTime,
        maxTime = times.maxTime,
        acceptedAt = GetGameTimer(),
        coords = type(deliveryData.coords) == 'table' and deliveryData.coords or nil,
        locationLabel = deliveryData.locationLabel,
    }

    -- 延迟释放锁 (防止极速连续触发)
    SetTimeout(2000, function()
        acceptLocks[src] = nil
    end)

    print(('[qb-drugs] %s accepted delivery: %s x%d, deposit=$%s, distance=%.0fm'):format(
        GetPlayerName(src), item, itemAmount, Money(deposit), deliveryData['distance'] or 0))
end)

-- Events
RegisterNetEvent('qb-drugs:server:updateDealerItems', function(itemData, amount, dealer)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 🔒 参数全部来自客户端：dealer / slot / name / amount 逐个校验。
    -- 原来直接 `Config.Dealers[dealer]['products'][slot]`（坏 key 就崩），
    -- 且 `RemoveItem` 的返回值被忽略 —— 背包里没货也照样 AddMoney（等于印钱）。
    if type(itemData) ~= 'table' or type(dealer) ~= 'string' then return end
    local shop = Config.Dealers[dealer]
    local slot = tonumber(itemData.slot)
    if not shop or not shop.products or not slot then return end
    local product = shop.products[slot]
    if not product then return end
    if itemData.name ~= product.name then return end

    amount = tonumber(amount)
    if not amount or amount <= 0 or amount % 1 ~= 0 then return end

    -- 库存够：只减库存并广播（不发钱）
    if product.amount - amount >= 0 then
        product.amount = product.amount - amount
        TriggerClientEvent('qb-drugs:client:setDealerItems', -1, itemData, amount, dealer)
        return
    end

    -- 库存不足：玩家把货卖给 dealer —— 必须先真的扣掉货，才发钱
    local held = Player.Functions.GetItemByName(product.name)
    if not held or held.amount < amount then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.item_unavailable'), 'error')
        return
    end
    local removed = exports['qb-inventory']:RemoveItem(src, product.name, amount, false, 'qb-drugs:server:updateDealerItems')
    if removed == false then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.item_unavailable'), 'error')
        return
    end
    Player.Functions.AddMoney('cash', amount * product.price, 'qb-drugs:server:updateDealerItems')
    TriggerClientEvent('QBCore:Notify', src, Lang:t('success.order_delivered'), 'success')
end)

-- 配送失败（超时/取消）：从背包移除任务物品
RegisterNetEvent('qb-drugs:server:failDelivery', function(deliveryData)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local record = activeDeliveries[src]
    if not record then return end
    if record.citizenid and record.citizenid ~= Player.PlayerData.citizenid then
        return
    end
    activeDeliveries[src] = nil
    local item = Config.DeliveryItems[record.item].item
    local itemAmount = record.amount
    local invItem = Player.Functions.GetItemByName(item)
    if invItem and invItem.amount >= itemAmount then
        exports['qb-inventory']:RemoveItem(src, item, itemAmount, false, 'qb-drugs:server:failDelivery')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[item], 'remove')
    end
    print(('[qb-drugs] %s delivery failed (timeout/cancel): removed %s x%d'):format(GetPlayerName(src), item, itemAmount))
end)

RegisterNetEvent('qb-drugs:server:successDelivery', function(deliveryData, completed)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 只认接单时留的档；没有档 = 没接单 / 已结算过（防重放双倍发钱）
    local record = activeDeliveries[src]
    if not record then return end
    if record.citizenid and record.citizenid ~= Player.PlayerData.citizenid then
        return                                      -- source 被复用给别的角色：不结旧单
    end
    activeDeliveries[src] = nil

    local item = Config.DeliveryItems[record.item].item
    local itemAmount = record.amount
    local basePayout = record.basePayout
    local deposit = record.deposit
    local fastTime = record.fastTime
    local maxTime = record.maxTime
    local copsOnline = QBCore.Functions.GetDutyCount('police')
    local invItem = Player.Functions.GetItemByName(item)
    local elapsed = GetGameTimer() - (record.acceptedAt or GetGameTimer())

    -- 判定等级
    local tier = 'timeout'  -- 超时
    if completed then
        if elapsed <= fastTime then tier = 'fast'
        elseif elapsed <= maxTime then tier = 'normal'
        else tier = 'late'
        end
    end

    -- 先回收货物：**回收失败就不发钱**（原来背包里没有货也照发，等于白拿）
    if not invItem or invItem.amount < itemAmount then
        TriggerClientEvent('QBCore:Notify', src, ('配送物品不在背包里（需要 %s x%d），本次不算完成'):format(item, itemAmount), 'error')
        return
    end
    exports['qb-inventory']:RemoveItem(src, item, itemAmount, false, 'qb-drugs:server:successDelivery')
    TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[item], 'remove')

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
            ('⚡ 快速送达！+$%s (含押金$%s) | 声望+%d'):format(Money(finalReward + deposit), Money(deposit), Config.DeliveryRepGain + 1), 'success')

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
            ('🟢 合格送达！+$%s (含押金$%s) | 声望+%d'):format(Money(finalReward + deposit), Money(deposit), Config.DeliveryRepGain), 'success')

    elseif tier == 'late' then
        -- 🟡 迟到：仅返还押金，无报酬，无声望
        Player.Functions.AddMoney('cash', deposit, '配送押金退还(迟到)')
        TriggerClientEvent('QBCore:Notify', src,
            ('🟡 迟到送达！押金 $%s 已退还，无额外报酬'):format(Money(deposit)), 'primary')

    else
        -- 🔴 超时：扣押金，货物已在顶部回收
        TriggerClientEvent('QBCore:Notify', src,
            ('🔴 配送失败！押金 $%s 已损失'):format(Money(deposit)), 'error')

    end

    -- 通知手机：配送已结束，GPS 导航失效
    if record.coords and record.coords.x then
        TriggerClientEvent('phone:client:gpsMessage', src, {
            status = 'done',
            gps = { x = record.coords.x, y = record.coords.y, label = record.locationLabel or '目的地' },
        })
    end
end)


RegisterNetEvent('qb-drugs:server:sendDeliverySMS', function(message, coords, status)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    -- 🔒 文案完全来自客户端：非字符串直接拒，超长截断（原来可以把任意大小/任意内容塞进短信表）
    if type(message) ~= 'string' or message == '' then return end
    message = message:sub(1, 300)
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
    -- 🔒 dealer key 是客户端给的：先校验类型再查表（原来非字符串 key 会抛 "table index is nil/NaN"）
    if type(currentDealer) ~= 'string' then return end
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
