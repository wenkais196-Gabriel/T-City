-- Variables
local coin = Crypto.Coin
local QBCore = exports['qb-core']:GetCoreObject()

-- qb-core 重启后，上面这份快照里的函数引用会全部失效（P1-6，PR #196）：
-- 本资源没有声明 qb-core 依赖，不会被重启级联带走，所以在 qb-core 起来时重解析一次。
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= 'qb-core' then return end
    -- ⚠️ 不能在事件里同步调：真机实测此刻 export 引用可能还指向 qb-core 旧 script host，
    -- 会抛 `Execution of function reference in script host failed`。放线程里重试到拿到新表。
    CreateThread(function()
        for _ = 1, 30 do
            local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
            if ok and core then
                QBCore = core
                return
            end
            Wait(500)
        end
    end)
end)
local bannedCharacters = { '%', '$', ';' }

-- Function
local function RefreshCrypto()
    local result = MySQL.query.await('SELECT * FROM crypto WHERE crypto = ?', { coin })
    if result ~= nil and result[1] ~= nil then
        Crypto.Worth[coin] = result[1].worth
        if result[1].history ~= nil then
            Crypto.History[coin] = json.decode(result[1].history)
            TriggerClientEvent('qb-crypto:client:UpdateCryptoWorth', -1, coin, result[1].worth, json.decode(result[1].history))
        else
            TriggerClientEvent('qb-crypto:client:UpdateCryptoWorth', -1, coin, result[1].worth, nil)
        end
    end
end

local function ErrorHandle(error)
    for k, v in pairs(Ticker.Error_handle) do
        if string.match(error, k) then
            return v
        end
    end
    return false
end

local function GetTickerPrice() -- Touch = no help
    local ticker_promise = promise.new()
    PerformHttpRequest('https://min-api.cryptocompare.com/data/price?fsym=' .. Ticker.coin .. '&tsyms=' .. Ticker.currency .. '&api_key=' .. Ticker.Api_key, function(Error, Result, _)
        local result_obj = json.decode(Result)
        if not result_obj['Response'] then
            local this_resolve = { error = Error, response_data = result_obj[string.upper(Ticker.currency)] }
            ticker_promise:resolve(this_resolve) --- Could resolve Error aswell for more accurate Error messages? Solved in else
        else
            local this_resolve = { error = result_obj['Message'] }
            ticker_promise:resolve(this_resolve)
        end
    end, 'GET')
    Citizen.Await(ticker_promise)
    if type(ticker_promise.value.error) ~= 'number' then
        local get_user_friendly_error = ErrorHandle(ticker_promise.value.error)
        if get_user_friendly_error then
            return get_user_friendly_error
        else
            return '\27[31m Unexpected error \27[0m' --- Raised an error which we did not expect, script should be capable of sticking with last recorded price and shutting down the sync logic
        end
    else
        return ticker_promise.value.response_data
    end
end

local function HandlePriceChance()
    local currentValue = Crypto.Worth[coin]
    local prevValue = Crypto.Worth[coin]
    local trend = math.random(0, 100)
    local event = math.random(0, 100)
    local chance = event - Crypto.ChanceOfCrashOrLuck

    if event > chance then
        if trend <= Crypto.ChanceOfDown then
            currentValue = currentValue - math.random(Crypto.CasualDown[1], Crypto.CasualDown[2])
        elseif trend >= Crypto.ChanceOfUp then
            currentValue = currentValue + math.random(Crypto.CasualUp[1], Crypto.CasualUp[2])
        end
    else
        if math.random(0, 1) == 1 then
            currentValue = currentValue + math.random(Crypto.Luck[1], Crypto.Luck[2])
        else
            currentValue = currentValue - math.random(Crypto.Crash[1], Crypto.Crash[2])
        end
    end

    if currentValue <= Crypto.Lower then
        currentValue = Crypto.Lower
    elseif currentValue >= Crypto.Upper then
        currentValue = Crypto.Upper
    end

    if Crypto.History[coin][4] then
        -- Shift array index 1 to 3
        for k = 3, 1, -1 do
            Crypto.History[coin][k] = Crypto.History[coin][k + 1]
        end
        -- Assign array index 4 to the latest result
        Crypto.History[coin][4] = { PreviousWorth = prevValue, NewWorth = currentValue }
    else
        Crypto.History[coin][#Crypto.History[coin] + 1] = { PreviousWorth = prevValue, NewWorth = currentValue }
    end

    Crypto.Worth[coin] = currentValue

    local history = json.encode(Crypto.History[coin])
    local props = {
        ['worth'] = currentValue,
        ['history'] = history,
        ['crypto'] = coin
    }
    -- T-City: 本服 oxmysql 的 update 回表（{affectedRows=…}），直接 < 1 会炸；
    -- 而且回调里再 await（RefreshCrypto）会触发 nested ref call。
    -- 改成同步写法：先 update，再按归一化后的行数决定是否 insert，最后刷新。
    local updated = MySQL.update.await(
        'UPDATE crypto set worth = :worth, history = :history where crypto = :crypto', props)
    if type(updated) == 'table' then updated = updated.affectedRows or updated[1] or 0 end
    updated = tonumber(updated) or 0
    if updated < 1 then
        print('Crypto not found, inserting new record for ' .. coin)
        MySQL.insert.await('INSERT INTO crypto (crypto, worth, history) VALUES (:crypto, :worth, :history)', props)
    end
    RefreshCrypto()
end

-- Commands

QBCore.Commands.Add('setcryptoworth', 'Set crypto value', { { name = 'crypto', help = 'Name of the crypto currency' }, { name = 'Value', help = 'New value of the crypto currency' } }, false, function(source, args)
    local src = source
    local crypto = tostring(args[1])

    if crypto ~= nil then
        if Crypto.Worth[crypto] ~= nil then
            local NewWorth = math.ceil(tonumber(args[2]))

            if NewWorth ~= nil then
                local PercentageChange = math.ceil(((NewWorth - Crypto.Worth[crypto]) / Crypto.Worth[crypto]) * 100)
                local ChangeLabel = '+'

                if PercentageChange < 0 then
                    ChangeLabel = '-'
                    PercentageChange = (PercentageChange * -1)
                end

                if Crypto.Worth[crypto] == 0 then
                    PercentageChange = 0
                    ChangeLabel = ''
                end

                Crypto.History[crypto][#Crypto.History[crypto] + 1] = {
                    PreviousWorth = Crypto.Worth[crypto],
                    NewWorth = NewWorth
                }

                -- T-City: 控制台执行时 source=0，TriggerClientEvent 会因 null player 抛错
                if src and src ~= 0 then
                    TriggerClientEvent('QBCore:Notify', src, 'You have changed the value of ' .. Crypto.Labels[crypto] .. ' from: $' .. Crypto.Worth[crypto] .. ' to: $' .. NewWorth .. ' (' .. ChangeLabel .. ' ' .. PercentageChange .. '%)')
                else
                    print(('[qb-crypto] setcryptoworth %s -> %s (from console)'):format(tostring(crypto), tostring(NewWorth)))
                end
                Crypto.Worth[crypto] = NewWorth
                TriggerClientEvent('qb-crypto:client:UpdateCryptoWorth', -1, crypto, NewWorth)
                MySQL.insert('INSERT INTO crypto (worth, history) VALUES (:worth, :history) ON DUPLICATE KEY UPDATE worth = :worth, history = :history', {
                    ['worth'] = NewWorth,
                    ['history'] = json.encode(Crypto.History[crypto]),
                })
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('text.you_have_not_given_a_new_value', { crypto = Crypto.Worth[crypto] }))
            end
        else
            TriggerClientEvent('QBCore:Notify', src, Lang:t('text.this_crypto_does_not_exist'))
        end
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('text.you_have_not_provided_crypto_available_qbit'))
    end
end, 'admin')

QBCore.Commands.Add('checkcryptoworth', '', {}, false, function(source)
    local src = source
    TriggerClientEvent('QBCore:Notify', src, Lang:t('text.the_qbit_has_a_value_of', { crypto = Crypto.Worth['qbit'] }))
end)

QBCore.Commands.Add('crypto', '', {}, false, function(source)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end -- 控制台 (source=0) 或本帧刚掉线时 GetPlayer 为 nil
    local MyPocket = math.ceil(Player.PlayerData.money.crypto * Crypto.Worth['qbit'])

    TriggerClientEvent('QBCore:Notify', src, Lang:t('text.you_have_with_a_value_of', { playerPlayerDataMoneyCrypto = Player.PlayerData.money.crypto, mypocket = MyPocket }))
end)


-- 交易所柜员机位置（Config 里登记），用于把"任意玩家"收窄成"正在交易所前的人"
local EXCHANGE_MAX_DIST = tonumber(GetConvar('crypto_exchange_max_distance', '20.0')) or 20.0

local function NearExchange(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local anchor = Crypto.Exchange and Crypto.Exchange.coords
    if not anchor then return false end
    local coords = GetEntityCoords(ped)
    return #(coords - anchor.xyz) <= EXCHANGE_MAX_DIST
end

-- Events

local lastWorthFetch = {}
RegisterServerEvent('qb-crypto:server:FetchWorth', function()
    local src = source
    if type(src) ~= 'number' or not QBCore.Functions.GetPlayer(src) then return end
    -- 🔒 每次调用会为每种币各打一条 SQL：**按玩家**冷却（全局冷却会被一个人占满，把别人挡在外面）
    local now = os.time()
    if lastWorthFetch[src] and now - lastWorthFetch[src] < 5 then return end
    lastWorthFetch[src] = now
    for name, _ in pairs(Crypto.Worth) do
        local result = MySQL.query.await('SELECT * FROM crypto WHERE crypto = ?', { name })
        if result[1] ~= nil then
            Crypto.Worth[name] = result[1].worth
            if result[1].history ~= nil then
                Crypto.History[name] = json.decode(result[1].history)
                TriggerClientEvent('qb-crypto:client:UpdateCryptoWorth', -1, name, result[1].worth, json.decode(result[1].history))
            else
                TriggerClientEvent('qb-crypto:client:UpdateCryptoWorth', -1, name, result[1].worth, nil)
            end
        end
    end
end)

RegisterServerEvent('qb-crypto:server:ExchangeFail', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local ItemData = Player.Functions.GetItemByName('cryptostick')
    if ItemData ~= nil then
        exports['qb-inventory']:RemoveItem(src, 'cryptostick', 1, false, 'qb-crypto:server:ExchangeFail')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['cryptostick'], 'remove')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.cryptostick_malfunctioned'), 'error')
    end
end)

-- 会话看门狗：owner 静默（客户端每 ~1.2 秒会上报一次）超过 60 秒就自动收尾。
-- 只在收到事件时判超时是不够的：owner 掉线/客户端卡死后不会再有人发事件。
CreateThread(function()
    while true do
        Wait(15000)
        if rebootOwner and (GetGameTimer() - rebootOwnerAt) > REBOOT_SESSION_TIMEOUT then
            rebootOwner = nil
            Crypto.Exchange.RebootInfo.state = false
            Crypto.Exchange.RebootInfo.percentage = 0
            TriggerClientEvent('qb-crypto:client:SyncReboot', -1)
        end
    end
end)

-- 兑换回补失败的待补偿队列：citizenid → 次数（玩家上线时重试）
local pendingRefunds = {}

AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    local cid = player and player.PlayerData and player.PlayerData.citizenid
    local owed = cid and pendingRefunds[cid]
    if not owed then return end
    local src = player.PlayerData.source
    local added = exports['qb-inventory']:AddItem(src, 'cryptostick', owed, false, {}, 'qb-crypto:refund-retry')
    if added == true then
        pendingRefunds[cid] = nil
        print(('[qb-crypto] ✅ 补偿完成：citizenid=%s x%d'):format(tostring(cid), owed))
    end
end)

local lastRebootUpdate = {}
local rebootOwner = nil       -- 当前重启会话的发起者
local rebootOwnerAt = 0       -- 最后一次收到 owner 上报的时刻
local REBOOT_SESSION_TIMEOUT = 60 * 1000   -- owner 60 秒不吭声就自动收尾，防"永久卡重启中"
RegisterServerEvent('qb-crypto:server:Rebooting', function(state, percentage)
    local src = source
    -- 🔒 全服共享的重启状态：任意玩家原来能把它改成任意值（伪造"交易所重启中"）。
    --    客户端实际发的是 `Rebooting(true/false, percentage)`（见 client/main.lua 的重启循环），
    --    所以 state 必须是 boolean、percentage 必须是 0~100 的整数，并按秒节流。
    if type(src) ~= 'number' or type(state) ~= 'boolean' then return end
    -- 🔒 全服共享状态必须只有"正在交易所柜员机前的人"能写（原来任何玩家都能伪造重启中）。
    --    例外：正在重启的会话发起者必须能把状态收尾（即使他已经走出 20 米），
    --    否则服务端会永久卡在 state=true。
    if not QBCore.Functions.GetPlayer(src) then return end

    -- owner 超时（60 秒没有任何上报）→ 自动收尾，避免交易所永久卡"重启中"
    if rebootOwner and (GetGameTimer() - rebootOwnerAt) > REBOOT_SESSION_TIMEOUT then
        rebootOwner = nil
        Crypto.Exchange.RebootInfo.state = false
        Crypto.Exchange.RebootInfo.percentage = 0
        TriggerClientEvent('qb-crypto:client:SyncReboot', -1)
    end

    local isOwner = rebootOwner == src
    -- 🔒 会话一旦有 owner，其他人**任何**上报都不接受（原来只拦 false，非 owner 的 true 还能覆盖进度）
    if rebootOwner and not isOwner then return end
    if not isOwner and not NearExchange(src) then return end
    percentage = tonumber(percentage)
    if not percentage or percentage < 0 or percentage > 100 or percentage % 1 ~= 0 then return end
    -- 客户端重启循环每帧上报一次进度：用毫秒计时，200ms 节流（**按玩家**，否则一个人能吃满全局冷却）
    local now = GetGameTimer()
    if lastRebootUpdate[src] and now - lastRebootUpdate[src] < 200 then return end
    lastRebootUpdate[src] = now

    if state == true and not rebootOwner then
        rebootOwner = src          -- 这次重启由他发起
        rebootOwnerAt = GetGameTimer()
    elseif state == false and isOwner then
        rebootOwner = nil         -- 发起者收尾
    end
    if isOwner then rebootOwnerAt = GetGameTimer() end

    Crypto.Exchange.RebootInfo.state = state
    Crypto.Exchange.RebootInfo.percentage = percentage
end)

AddEventHandler('playerDropped', function()
    local src = source
    if rebootOwner == src then
        rebootOwner = nil
        Crypto.Exchange.RebootInfo.state = false
        Crypto.Exchange.RebootInfo.percentage = 0
        TriggerClientEvent('qb-crypto:client:SyncReboot', -1)
    end
end)

RegisterServerEvent('qb-crypto:server:GetRebootState', function()
    local src = source
    if type(src) ~= 'number' or not QBCore.Functions.GetPlayer(src) then return end
    TriggerClientEvent('qb-crypto:client:GetRebootState', src, Crypto.Exchange.RebootInfo)
end)

local lastRebootSync = {}
RegisterServerEvent('qb-crypto:server:SyncReboot', function()
    local src = source
    if type(src) ~= 'number' or not QBCore.Functions.GetPlayer(src) then return end
    if not NearExchange(src) then return end
    -- 🔒 全服广播：按玩家 1 秒节流
    local now = os.time()
    if lastRebootSync[src] and now == lastRebootSync[src] then return end
    lastRebootSync[src] = now
    TriggerClientEvent('qb-crypto:client:SyncReboot', -1)
end)

RegisterServerEvent('qb-crypto:server:ExchangeSuccess', function()
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then return end
    local ItemData = Player.Functions.GetItemByName('cryptostick')
    if ItemData ~= nil then
        -- 🛡️ Security: Both LuckChance and LuckyNumber generated server-side (client value ignored)
        local LuckChance = math.random(1, 10)
        local LuckyNumber = math.random(1, 10)
        local DeelNumber = 1000000
        local Amount = (math.random(611111, 1599999) / DeelNumber)
        if LuckChance == LuckyNumber then
            Amount = (math.random(1599999, 2599999) / DeelNumber)
        end
        -- 🔒 只有明确返回 true 才算扣成功（别的库存实现返回 nil 时 `== false` 挡不住 = 白拿）
        local removed = exports['qb-inventory']:RemoveItem(src, 'cryptostick', 1, false, 'qb-crypto:server:ExchangeSuccess')
        if removed ~= true then return end
        -- 加钱失败就把 cryptostick 还回去，别让玩家既丢物品又没钱
        if Player.Functions.AddMoney('crypto', Amount, 'qb-crypto:server:ExchangeSuccess') == false then
            -- AddItem 签名是 (identifier, item, amount, slot, info, reason)，info 必须是 table
            local refunded = exports['qb-inventory']:AddItem(src, 'cryptostick', 1, false, {}, 'qb-crypto:server:ExchangeSuccess-refund')
            if refunded ~= true then
                -- 回补也失败（背包满/物品异常）：记进待补偿队列，下次上线重试，别让玩家白丢物品
                local cid = Player.PlayerData.citizenid
                pendingRefunds[cid] = (pendingRefunds[cid] or 0) + 1
                print(('[qb-crypto] ⚠️ 兑换回补失败：src=%s citizenid=%s 物品=cryptostick 待补偿=%d'):format(
                    tostring(src), tostring(cid), pendingRefunds[cid]))
            end
            return
        end
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.you_have_exchanged_your_cryptostick_for', { amount = Amount }), 'success', 3500)
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items['cryptostick'], 'remove')
        TriggerClientEvent('qb-phone:client:AddTransaction', src, Player, {}, Lang:t('credit.there_are_amount_credited', { amount = Amount }), 'Credit')
    end
end)

-- Callbacks

QBCore.Functions.CreateCallback('qb-crypto:server:HasSticky', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    local Item = Player.Functions.GetItemByName('cryptostick')

    if Item ~= nil then
        cb(true)
    else
        cb(false)
    end
end)

QBCore.Functions.CreateCallback('qb-crypto:server:GetCryptoData', function(source, cb, name)
    local Player = QBCore.Functions.GetPlayer(source)
    local CryptoData = {
        History = Crypto.History[name],
        Worth = Crypto.Worth[name],
        Portfolio = Player.PlayerData.money.crypto,
        WalletId = Player.PlayerData.metadata['walletid'],
    }

    cb(CryptoData)
end)

QBCore.Functions.CreateCallback('qb-crypto:server:BuyCrypto', function(source, cb, data)
    local Player = QBCore.Functions.GetPlayer(source)
    local total_price = math.floor(tonumber(data.Coins) * tonumber(Crypto.Worth['qbit']))
    if Player.PlayerData.money.bank >= total_price then
        local CryptoData = {
            History = Crypto.History['qbit'],
            Worth = Crypto.Worth['qbit'],
            Portfolio = Player.PlayerData.money.crypto + tonumber(data.Coins),
            WalletId = Player.PlayerData.metadata['walletid'],
        }
        Player.Functions.RemoveMoney('bank', total_price, 'bought crypto')
        TriggerClientEvent('qb-phone:client:AddTransaction', source, Player, data, Lang:t('credit.you_have_qbit_purchased', { dataCoins = tonumber(data.Coins) }), 'Credit')
        Player.Functions.AddMoney('crypto', tonumber(data.Coins), 'bought crypto')
        cb(CryptoData)
    else
        cb(false)
    end
end)

QBCore.Functions.CreateCallback('qb-crypto:server:SellCrypto', function(source, cb, data)
    local Player = QBCore.Functions.GetPlayer(source)

    if Player.PlayerData.money.crypto >= tonumber(data.Coins) then
        local CryptoData = {
            History = Crypto.History['qbit'],
            Worth = Crypto.Worth['qbit'],
            Portfolio = Player.PlayerData.money.crypto - tonumber(data.Coins),
            WalletId = Player.PlayerData.metadata['walletid'],
        }
        Player.Functions.RemoveMoney('crypto', tonumber(data.Coins), 'sold crypto')
        local amount = math.floor(tonumber(data.Coins) * tonumber(Crypto.Worth['qbit']))
        TriggerClientEvent('qb-phone:client:AddTransaction', source, Player, data, Lang:t('debit.you_have_sold', { dataCoins = tonumber(data.Coins) }), 'Debit')
        Player.Functions.AddMoney('bank', amount, 'sold crypto')
        cb(CryptoData)
    else
        cb(false)
    end
end)

QBCore.Functions.CreateCallback('qb-crypto:server:TransferCrypto', function(source, cb, data)
    local newCoin = tostring(data.Coins)
    local newWalletId = tostring(data.WalletId)
    for _, v in pairs(bannedCharacters) do
        newCoin = string.gsub(newCoin, '%' .. v, '')
        newWalletId = string.gsub(newWalletId, '%' .. v, '')
    end
    data.WalletId = newWalletId
    data.Coins = tonumber(newCoin)
    local Player = QBCore.Functions.GetPlayer(source)
    if Player.PlayerData.money.crypto >= tonumber(data.Coins) then
        local query = '%"walletid":"' .. data.WalletId .. '"%'
        local result = MySQL.query.await('SELECT * FROM `players` WHERE `metadata` LIKE ?', { query })
        if result[1] ~= nil then
            local CryptoData = {
                History = Crypto.History['qbit'],
                Worth = Crypto.Worth['qbit'],
                Portfolio = Player.PlayerData.money.crypto - tonumber(data.Coins),
                WalletId = Player.PlayerData.metadata['walletid'],
            }
            Player.Functions.RemoveMoney('crypto', tonumber(data.Coins), 'transfer crypto')
            TriggerClientEvent('qb-phone:client:AddTransaction', source, Player, data, 'You have ' .. tonumber(data.Coins) .. " Qbit('s) transferred!", 'Debit')
            local Target = QBCore.Functions.GetPlayerByCitizenId(result[1].citizenid)

            if Target ~= nil then
                Target.Functions.AddMoney('crypto', tonumber(data.Coins), 'transfer crypto')
                TriggerClientEvent('qb-phone:client:AddTransaction', Target.PlayerData.source, Player, data, 'There are ' .. tonumber(data.Coins) .. " Qbit('s) credited!", 'Credit')
            else
                -- 原来是 `SET money = ?` 整块覆盖：先读快照再写回，中间任何人动过 bank/cash
                -- 都会被无声回滚（丢更新）。改走 owner 的离线入账（JSON_SET 算术）。
                exports['qb-core']:EconomyAddMoneyOffline(result[1].citizenid, 'crypto', tonumber(data.Coins),
                    'crypto transfer (offline)', function(ok)
                    if not ok then
                        Player.Functions.AddMoney('crypto', tonumber(data.Coins), 'crypto transfer rollback')
                        TriggerClientEvent('QBCore:Notify', source, '转账失败：对方账户入账失败，已退款', 'error')
                    end
                end)
            end
            cb(CryptoData)
        else
            cb('notvalid')
        end
    else
        cb('notenough')
    end
end)

-- Threads

CreateThread(function()
    while true do
        Wait(Crypto.RefreshTimer * 60000)
        HandlePriceChance()
    end
end)

-- You touch = you break
if Ticker.Enabled then
    Citizen.CreateThread(function()
        local Interval = Ticker.tick_time * 60000
        if Ticker.tick_time < 2 then
            Interval = 120000
        end
        while (true) do
            local get_coin_price = GetTickerPrice()
            if type(get_coin_price) == 'number' then
                Crypto.Worth['qbit'] = get_coin_price
            else
                print('\27[31m' .. get_coin_price .. '\27[0m')
                Ticker.Enabled = false
                break
            end
            Citizen.Wait(Interval)
        end
    end)
end
