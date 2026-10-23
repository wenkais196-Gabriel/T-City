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

-- 服务端价格边界（客户端只传报价，服务端按 Config 兜底）
local PRICE_MIN, PRICE_MAX = math.huge, 0
for _, stock in pairs(Config.Stock or {}) do
    for _, level in pairs(stock.Price or {}) do
        if type(level) == 'table' and level.min and level.max then
            PRICE_MIN = math.min(PRICE_MIN, level.min)
            PRICE_MAX = math.max(PRICE_MAX, level.max)
        end
    end
end
if PRICE_MIN == math.huge then PRICE_MIN, PRICE_MAX = 1, 50 end

RegisterNetEvent('qb-hotdogjob:server:Sell', function(coords, amount, price)
    local src = source
    if not src or src == 0 then return end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end

    -- 只有热狗摊主能结算
    if not Player.PlayerData.job or Player.PlayerData.job.name ~= 'hotdog' then
        return
    end

    -- 🔒 Rate Limit: 1秒内重复触发直接驳回
    local now = os.time()
    if sellCooldowns[src] and now - sellCooldowns[src] < 1 then
        return
    end
    sellCooldowns[src] = now

    -- 🛡️ 数值清洗：数量与单价都按服务端边界收紧
    amount = math.floor(tonumber(amount) or 0)
    price = tonumber(price) or 0
    if amount <= 0 or price <= 0 then return end
    if amount > 5 then amount = 5 end
    if price < PRICE_MIN then price = PRICE_MIN end
    if price > PRICE_MAX then price = PRICE_MAX end

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
