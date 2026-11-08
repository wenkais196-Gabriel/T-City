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

local function exploitBan(id, reason)
    MySQL.insert('INSERT INTO bans (name, license, discord, ip, reason, expire, bannedby) VALUES (?, ?, ?, ?, ?, ?, ?)',
        {
            GetPlayerName(id),
            QBCore.Functions.GetIdentifier(id, 'license'),
            QBCore.Functions.GetIdentifier(id, 'discord'),
            QBCore.Functions.GetIdentifier(id, 'ip'),
            reason,
            2147483647,
            'qb-pawnshop'
        })
    TriggerEvent('qb-log:server:CreateLog', 'pawnshop', 'Player Banned', 'red',
        string.format('%s was banned by %s for %s', GetPlayerName(id), 'qb-pawnshop', reason), true)
    DropPlayer(id, 'You were permanently banned by the server for: Exploiting')
end

-- 价格 / 熔炼配方一律以**服务端**配置为准。原来两者都从客户端参数里取：
--   `sellPawnItems(..., itemPrice)` 的单价来自客户端（卖一块石头要价一百万的印钞机），
--   `pickupMelted(item)` 的奖励表也来自客户端（可以任意指定奖励物品与数量）。
local MAX_SELL_AMOUNT = 100
local MAX_MELT_AMOUNT = 100

local function findPawnEntry(itemName)
    for _, entry in pairs(Config.PawnItems) do
        if type(entry) == 'table' and entry.item == itemName then return entry end
    end
    return nil
end

local function findMeltingEntry(itemName)
    for _, entry in pairs(Config.MeltingItems) do
        if type(entry) == 'table' and entry.item == itemName then return entry end
    end
    return nil
end

local function sanitizeAmount(value, limit)
    local amount = math.floor(tonumber(value) or 0)
    if amount <= 0 or amount > limit then return nil end
    return amount
end

RegisterNetEvent('qb-pawnshop:server:sellPawnItems', function(itemName, itemAmount)
    local src = source
    if not exports['custom-main']:CheckRateLimit(src, "sell_pawn_item", 1500) then
        TriggerClientEvent('QBCore:Notify', src, "您的操作过于频繁，请慢一点", "error")
        return
    end
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(itemName) ~= 'string' then return end
    local pawnEntry = findPawnEntry(itemName)
    local amount = sanitizeAmount(itemAmount, MAX_SELL_AMOUNT)
    if not pawnEntry or not amount then return end
    local totalPrice = (tonumber(pawnEntry.price) or 0) * amount
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local dist
    for _, value in pairs(Config.PawnLocation) do
        dist = #(playerCoords - value.coords)
        if #(playerCoords - value.coords) < 2 then
            dist = #(playerCoords - value.coords)
            break
        end
    end
    if dist > 5 then
        exploitBan(src, 'sellPawnItems Exploiting')
        return
    end
    if exports['qb-inventory']:RemoveItem(src, itemName, tonumber(itemAmount), false, 'qb-pawnshop:server:sellPawnItems') then
        local finalAmount = exports['custom-main']:AddScaledMoney(src, Config.BankMoney and 'bank' or 'cash', totalPrice, 'qb-pawnshop:server:sellPawnItems')
        TriggerClientEvent('QBCore:Notify', src, Lang:t('success.sold', { value = tonumber(itemAmount), value2 = QBCore.Shared.Items[itemName].label, value3 = finalAmount }), 'success')
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[itemName], 'remove')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_items'), 'error')
    end
    TriggerClientEvent('qb-pawnshop:client:openMenu', src)
end)

RegisterNetEvent('qb-pawnshop:server:meltItemRemove', function(itemName, itemAmount)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player or type(itemName) ~= 'string' then return end
    local meltEntry = findMeltingEntry(itemName)
    local amount = sanitizeAmount(itemAmount, MAX_MELT_AMOUNT)
    if not meltEntry or not amount then return end
    if exports['qb-inventory']:RemoveItem(src, itemName, amount, false, 'qb-pawnshop:server:meltItemRemove') then
        TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[itemName], 'remove')
        local meltTime = (amount * (tonumber(meltEntry.meltTime) or 0))
        -- 回给客户端的是**服务端**那份条目（客户端提交的同名条目一律忽略）
        TriggerClientEvent('qb-pawnshop:client:startMelting', src, meltEntry, amount, (meltTime * 60000 / 1000))
        TriggerClientEvent('QBCore:Notify', src, Lang:t('info.melt_wait', { value = meltTime }), 'primary')
    else
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.no_items'), 'error')
    end
end)

RegisterNetEvent('qb-pawnshop:server:pickupMelted', function(item)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local playerCoords = GetEntityCoords(GetPlayerPed(src))
    local dist
    for _, value in pairs(Config.PawnLocation) do
        dist = #(playerCoords - value.coords)
        if #(playerCoords - value.coords) < 2 then
            dist = #(playerCoords - value.coords)
            break
        end
    end
    if dist > 5 then
        exploitBan(src, 'pickupMelted Exploiting')
        return
    end
    if type(item) ~= 'table' or type(item.items) ~= 'table' then return end
    for _, v in pairs(item.items) do
        if type(v) ~= 'table' then goto continue end
        local submittedName = type(v.item) == 'table' and v.item.item or v.name
        local meltEntry = type(submittedName) == 'string' and findMeltingEntry(submittedName) or nil
        if not meltEntry then goto continue end
        local meltedAmount = sanitizeAmount(v.amount, MAX_MELT_AMOUNT)
        if not meltedAmount then goto continue end
        -- 🔒 奖励表来自**服务端**配置：原来直接用客户端提交的 `v.item.reward`
        for _, m in pairs(meltEntry.rewards) do
            local rewardAmount = m.amount
            if exports['qb-inventory']:AddItem(src, m.item, (meltedAmount * rewardAmount), false, false, 'qb-pawnshop:server:pickupMelted') then
                TriggerClientEvent('qb-inventory:client:ItemBox', src, QBCore.Shared.Items[m.item], 'add')
                TriggerClientEvent('QBCore:Notify', src, Lang:t('success.items_received', { value = (meltedAmount * rewardAmount), value2 = QBCore.Shared.Items[m.item].label }), 'success')
                TriggerClientEvent('qb-pawnshop:client:resetPickup', src)
            else
                TriggerClientEvent('QBCore:Notify', src, Lang:t('error.inventory_full', { value = QBCore.Shared.Items[m.item].label }), 'warning', 7500)
            end
        end
        ::continue::
    end
    TriggerClientEvent('qb-pawnshop:client:openMenu', src)
end)

RegisterNetEvent('qb-pawnshop:server:launderMoney', function(amount)
    local src = source
    amount = tonumber(amount) or 0
    if amount <= 0 then
        TriggerClientEvent('QBCore:Notify', src, Lang:t('error.negative'), 'error')
        return
    end
    -- 调用 custom-crime 的 LaunderMoney 导出（含折旧/审计/冷却/警察校验）
    local hasExport = exports['custom-crime'] and exports['custom-crime'].LaunderMoney
    if hasExport then
        exports['custom-crime']:LaunderMoney(src, amount)
    else
        TriggerClientEvent('QBCore:Notify', src, '洗钱服务暂不可用，请联系管理员', 'error')
    end
end)

QBCore.Functions.CreateCallback('qb-pawnshop:server:getInv', function(source, cb)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return cb({}) end
    return cb(Player.PlayerData.items or {})
end)
