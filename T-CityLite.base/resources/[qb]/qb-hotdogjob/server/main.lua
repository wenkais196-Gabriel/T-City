local QBCore = exports['qb-core']:GetCoreObject()
local Bail = {}

-- Callbacks

QBCore.Functions.CreateCallback('qb-hotdogjob:server:HasMoney', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)

    if Player.PlayerData.money.bank >= Config.StandDeposit then
        Player.Functions.RemoveMoney('bank', Config.StandDeposit, 'hot dog deposit')
        Bail[Player.PlayerData.citizenid] = true
        cb(true)
    else
        Bail[Player.PlayerData.citizenid] = false
        cb(false)
    end
end)

QBCore.Functions.CreateCallback('qb-hotdogjob:server:BringBack', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)

    if Bail[Player.PlayerData.citizenid] then
        Player.Functions.AddMoney('bank', Config.StandDeposit, 'hot dog deposit')
        cb(true)
    else
        cb(false)
    end
end)

-- Events

-- 🔒 防刷: 每玩家每秒最多卖出一次
local sellCooldowns = {}

RegisterNetEvent('qb-hotdogjob:server:Sell', function(coords, amount, price)
    local src = source
    if not src or src == 0 then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 🔒 Rate Limit: 1秒内重复触发直接驳回
    local now = os.time()
    if sellCooldowns[src] and now - sellCooldowns[src] < 1 then
        return
    end
    sellCooldowns[src] = now

    -- 📍 距离验证
    local pCoords = GetEntityCoords(GetPlayerPed(src))
    if #(pCoords - vector3(coords.x, coords.y, coords.z)) > 4 then
        exports['qb-core']:ExploitBan(src, 'hotdog job')
        return
    end

    -- 🛡️ 数值清洗
    amount = tonumber(amount) or 0
    price = tonumber(price) or 0
    if amount <= 0 or price <= 0 then return end
    if amount > 100 then amount = 100 end
    if price > 100 then price = 100 end

    -- 💰 统一经济网关 (自动应用 global × heat × bonus 系数)
    local finalAmount = amount * price
    if GetResourceState('core_economy') == 'started' then
        exports['core_economy']:TriggerReward(src, 'hotdog_sell', finalAmount, {
            moneytype = 'cash',
            reason = 'sold_hotdog',
        })
    else
        Player.Functions.AddMoney('cash', finalAmount, 'sold hotdog')
    end
end)

RegisterNetEvent('qb-hotdogjob:server:UpdateReputation', function(quality)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if quality == 'exotic' then
        if Player.Functions.GetRep('hotdog') + 3 > Config.MaxReputation then
            Player.Functions.AddRep('hotdog', Config.MaxReputation - Player.Functions.GetRep('hotdog'))
        else
            Player.Functions.AddRep('hotdog', 3)
        end
    elseif quality == 'rare' then
        if Player.Functions.GetRep('hotdog') + 2 > Config.MaxReputation then
            Player.Functions.AddRep('hotdog', Config.MaxReputation - Player.Functions.GetRep('hotdog'))
        else
            Player.Functions.AddRep('hotdog', 2)
        end
    elseif quality == 'common' then
        if Player.Functions.GetRep('hotdog') + 1 > Config.MaxReputation then
            Player.Functions.AddRep('hotdog', Config.MaxReputation - Player.Functions.GetRep('hotdog'))
        else
            Player.Functions.AddRep('hotdog', 1)
        end
    end

    TriggerClientEvent('qb-hotdogjob:client:UpdateReputation', src, Player.PlayerData.metadata['rep'])
end)

-- Commands

QBCore.Commands.Add('removestand', Lang:t('info.command'), {}, false, function(source, _)
    TriggerClientEvent('qb-hotdogjob:staff:DeletStand', source)
end, 'admin')
