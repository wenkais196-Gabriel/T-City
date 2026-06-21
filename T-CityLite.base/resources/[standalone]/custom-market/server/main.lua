-- main.lua — custom-market 动态交易市场引擎
--
-- 模块化·高性能·安全·可拓展 — 四原则设计
--
-- 核心机制:
--   1. 每商品独立 OrderBook: 供给/需求 → 实时动态价格
--   2. "买多就涨，卖多就跌" → 买 = demand↑ → price↑, 卖 = supply↑ → price↓
--   3. 均值回归: 每Tick价格向 basePrice 缓慢回归
--   4. 统一结算: 通过 Bus.EconomyService.AddScaled() 走统一经济出口
--   5. 价格约束: minPrice/maxPrice 硬顶 + MaxDeviation 软顶
--
-- 使用:
--   local price = Bus.MarketService.GetPrice('cocaine')
--   local ok, actualPrice = Bus.MarketService.Buy(source, 'cocaine', 10)
--   local ok, actualPrice = Bus.MarketService.Sell(source, 'cocaine', 5)
--   local stats = Bus.MarketService.GetMarketStats()  -- 全市场快照

local QBCore = exports['qb-core']:GetCoreObject()
MarketService = {}

-- ==============================================================
-- 内存 OrderBook (商品名 → 实时状态)
-- ==============================================================

local orderBooks = {}

-- 初始化 OrderBook
local function initOrderBook(itemName)
    local cfg = Config.Market.Commodities[itemName]
    if not cfg then return nil end

    if not orderBooks[itemName] then
        orderBooks[itemName] = {
            basePrice       = cfg.basePrice,
            currentPrice    = cfg.basePrice,
            supplyVolume    = cfg.supplyVolume,
            demandVolume    = cfg.demandVolume,
            minPrice        = cfg.minPrice,
            maxPrice        = cfg.maxPrice,
            label           = cfg.label,
            category        = cfg.category,
            -- 统计
            totalBought     = 0,
            totalSold       = 0,
            lastUpdated     = os.time(),
        }
    end

    return orderBooks[itemName]
end

-- 启动时初始化所有商品
for itemName, _ in pairs(Config.Market.Commodities) do
    initOrderBook(itemName)
end

-- ==============================================================
-- 价格计算公式
-- ==============================================================

--- 计算当前价格
--- price = basePrice * (1 + elasticity * (demand - supply) / max(supply, 1))
--- 然后 clamp 到 [basePrice*(1-maxDeviation), basePrice*(1+maxDeviation)]
--- 再 clamp 到 [minPrice, maxPrice]
---@param book table OrderBook
---@return number currentPrice
local function calculatePrice(book)
    local e = Config.Market.Elasticity
    local supply = math.max(book.supplyVolume, Config.Market.MinVolume)
    local demand = math.max(book.demandVolume, Config.Market.MinVolume)

    -- 供需比驱动
    local ratio = (demand - supply) / supply
    local rawPrice = book.basePrice * (1 + e * ratio)

    -- 软约束: basePrice 偏离上限
    local maxDev = Config.Market.MaxDeviation
    local softMin = book.basePrice * (1 - maxDev)
    local softMax = book.basePrice * (1 + maxDev)
    local clamped = rawPrice
    if clamped < softMin then clamped = softMin end
    if clamped > softMax then clamped = softMax end

    -- 硬约束: 绝对上下限
    if book.minPrice and clamped < book.minPrice then clamped = book.minPrice end
    if book.maxPrice and clamped > book.maxPrice then clamped = book.maxPrice end

    return QBCore.Shared.Round(clamped)
end

--- 均值回归: 每Tick向basePrice靠拢
local function applyMeanReversion(book)
    local decay = Config.Market.DecayRate
    local targetSupply = Config.Market.Commodities[book.label:lower():gsub(' ', '_')] -- hack fallback
    -- 简化回归: supply和demand向初始值各回一步
    local cfg = nil
    for name, c in pairs(Config.Market.Commodities) do
        if c.label == book.label then cfg = c; break end
    end
    if not cfg then return end

    -- 供需都向初始值回归
    book.supplyVolume = book.supplyVolume + (cfg.supplyVolume - book.supplyVolume) * decay
    book.demandVolume = book.demandVolume + (cfg.demandVolume - book.demandVolume) * decay

    -- 确保不低于最小值
    book.supplyVolume = math.max(book.supplyVolume, Config.Market.MinVolume)
    book.demandVolume = math.max(book.demandVolume, Config.Market.MinVolume)
end

-- ==============================================================
-- 公共 API
-- ==============================================================

--- 获取商品当前价格
---@param itemName string
---@return number|nil price
function MarketService.GetPrice(itemName)
    local book = orderBooks[itemName]
    if not book then
        book = initOrderBook(itemName)
    end
    if not book then return nil end

    -- 检查运行时价格覆盖
    local override = Config.Market.GetRuntimePriceOverride(itemName)
    if override then return override end

    return book.currentPrice
end

--- 批量获取多个商品价格
---@param itemNames string[]
---@return table { [itemName] = price }
function MarketService.GetPrices(itemNames)
    local result = {}
    for _, name in ipairs(itemNames) do
        result[name] = MarketService.GetPrice(name)
    end
    return result
end

--- 获取商品完整市场信息
---@param itemName string
---@return table|nil { price, supply, demand, basePrice, label, category }
function MarketService.GetCommodityInfo(itemName)
    local book = orderBooks[itemName]
    if not book then
        book = initOrderBook(itemName)
    end
    if not book then return nil end

    return {
        price = book.currentPrice,
        supply = book.supplyVolume,
        demand = book.demandVolume,
        basePrice = book.basePrice,
        label = book.label,
        category = book.category,
        minPrice = book.minPrice,
        maxPrice = book.maxPrice,
        totalBought = book.totalBought,
        totalSold = book.totalSold,
    }
end

--- 从市场购买商品 (玩家买入 → demand↑ → 价格↑)
---@param source number 买家
---@param itemName string 商品名
---@param quantity number 购买数量
---@return boolean success
---@return number actualPrice 实际单价
---@return string|nil error
function MarketService.Buy(source, itemName, quantity)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false, 0, 'Player not found' end

    quantity = tonumber(quantity) or 0
    if quantity <= 0 then return false, 0, 'Invalid quantity' end

    local book = orderBooks[itemName]
    if not book then return false, 0, 'Unknown commodity: ' .. tostring(itemName) end

    -- 1. 计算当前价格
    local price = book.currentPrice
    local totalCost = price * quantity

    -- 2. 扣款（优先走统一经济出口）
    local bankBalance = Player.PlayerData.money.bank
    if bankBalance < totalCost then
        return false, price, ('余额不足，需要 $%d，当前 $%d'):format(totalCost, bankBalance)
    end

    local deductOk = Player.Functions.RemoveMoney('bank', totalCost, 'MarketBuy:' .. itemName)
    if not deductOk then
        return false, price, '扣款失败'
    end

    -- 3. 给予物品
    if exports['qb-inventory'] and exports['qb-inventory'].AddItem then
        local added = exports['qb-inventory']:AddItem(source, itemName, quantity, nil, nil, 'MarketBuy')
        if not added then
            -- 回滚
            Player.Functions.AddMoney('bank', totalCost, 'MarketBuy rollback')
            return false, price, '物品添加失败，已退款'
        end
    end

    -- 4. 更新 OrderBook: demand↑ → price↑
    book.demandVolume = book.demandVolume + quantity
    book.totalBought = book.totalBought + quantity
    book.currentPrice = calculatePrice(book)
    book.lastUpdated = os.time()

    -- 5. 审计日志
    if quantity * price > 50000 and exports['custom-logs'] then
        exports['custom-logs']:LogEconomy('MarketBuy', ('**%s** (%s) | 购买 %d x %s @ $%d/个 = $%d'):format(
            GetPlayerName(source), Player.PlayerData.citizenid,
            quantity, itemName, price, totalCost
        ), 65280)
    end

    -- 6. 通知
    TriggerClientEvent('QBCore:Notify', source,
        ('购买了 %d x %s @ $%d/个 (总计 $%d)'):format(quantity, book.label, price, totalCost),
        'success'
    )

    return true, price, nil
end

--- 向市场出售商品 (玩家卖出 → supply↑ → 价格↓)
---@param source number 卖家
---@param itemName string 商品名
---@param quantity number 出售数量
---@return boolean success
---@return number actualPrice 实际单价
---@return string|nil error
function MarketService.Sell(source, itemName, quantity)
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return false, 0, 'Player not found' end

    quantity = tonumber(quantity) or 0
    if quantity <= 0 then return false, 0, 'Invalid quantity' end

    local book = orderBooks[itemName]
    if not book then return false, 0, 'Unknown commodity: ' .. tostring(itemName) end

    -- 1. 检查玩家是否有足够物品
    local hasItem = QBCore.Functions.HasItem(source, itemName, quantity)
    if not hasItem then
        return false, book.currentPrice, ('你没有足够的 %s'):format(book.label)
    end

    -- 2. 计算价格（卖出价比市价略低 5%，模拟市场折价）
    local price = QBCore.Shared.Round(book.currentPrice * 0.95)
    local totalRevenue = price * quantity

    -- 3. 移除物品
    if exports['qb-inventory'] and exports['qb-inventory'].RemoveItem then
        exports['qb-inventory']:RemoveItem(source, itemName, quantity, nil, 'MarketSell')
    end

    -- 4. 付款（走统一经济出口）
    if Bus and Bus.EconomyService then
        Bus.EconomyService.AddScaled(source, 'bank', totalRevenue, 'MarketSell:' .. itemName)
    else
        Player.Functions.AddMoney('bank', totalRevenue, 'MarketSell:' .. itemName)
    end

    -- 5. 更新 OrderBook: supply↑ → price↓
    book.supplyVolume = book.supplyVolume + quantity
    book.totalSold = book.totalSold + quantity
    book.currentPrice = calculatePrice(book)
    book.lastUpdated = os.time()

    -- 6. 审计日志
    if quantity * price > 50000 and exports['custom-logs'] then
        exports['custom-logs']:LogEconomy('MarketSell', ('**%s** (%s) | 出售 %d x %s @ $%d/个 = $%d'):format(
            GetPlayerName(source), Player.PlayerData.citizenid,
            quantity, itemName, price, totalRevenue
        ), 16744576)
    end

    -- 7. 通知
    TriggerClientEvent('QBCore:Notify', source,
        ('出售了 %d x %s @ $%d/个 (总计 $%d)'):format(quantity, book.label, price, totalRevenue),
        'success'
    )

    return true, price, nil
end

--- 获取全市场快照
---@return table[] 所有商品的市场数据
function MarketService.GetMarketStats()
    local stats = {}
    for itemName, book in pairs(orderBooks) do
        table.insert(stats, {
            name = itemName,
            label = book.label,
            category = book.category,
            price = book.currentPrice,
            basePrice = book.basePrice,
            supply = book.supplyVolume,
            demand = book.demandVolume,
            change = QBCore.Shared.Round((book.currentPrice - book.basePrice) / book.basePrice * 100),
            totalBought = book.totalBought,
            totalSold = book.totalSold,
        })
    end
    return stats
end

--- 获取某分类的所有商品
---@param category string
---@return table[]
function MarketService.GetCategory(category)
    local items = {}
    for itemName, book in pairs(orderBooks) do
        if book.category == category then
            table.insert(items, {
                name = itemName,
                label = book.label,
                price = book.currentPrice,
                basePrice = book.basePrice,
                change = QBCore.Shared.Round((book.currentPrice - book.basePrice) / book.basePrice * 100),
            })
        end
    end
    return items
end

-- ==============================================================
-- 定时均值回归 Tick
-- ==============================================================

CreateThread(function()
    print(('[market] ⏰ 价格Tick已启动: 每 %ds 回归均衡'):format(Config.Market.TickInterval))

    while true do
        Wait(Config.Market.TickInterval * 1000)

        local updatedCount = 0
        for itemName, book in pairs(orderBooks) do
            local oldPrice = book.currentPrice
            applyMeanReversion(book)
            book.currentPrice = calculatePrice(book)
            if book.currentPrice ~= oldPrice then
                updatedCount = updatedCount + 1
            end
        end

        if updatedCount > 0 then
            print(('[market] 📊 均值回归: %d 种商品价格更新'):format(updatedCount))
        end
    end
end)

-- ==============================================================
-- 每小时统计报告
-- ==============================================================

CreateThread(function()
    while true do
        Wait(3600 * 1000)  -- 每小时

        local totalVolume = 0
        for _, book in pairs(orderBooks) do
            totalVolume = totalVolume + book.totalBought + book.totalSold
        end

        if totalVolume > 0 then
            print(('[market] 📈 小时报告: 总交易量 %d 单位'):format(totalVolume))
        end
    end
end)

-- ==============================================================
-- 注册到 Bus
-- ==============================================================

if Bus and Bus.RegisterService then
    Bus.RegisterService('market', {
        GetPrice        = MarketService.GetPrice,
        GetPrices       = MarketService.GetPrices,
        GetCommodityInfo = MarketService.GetCommodityInfo,
        Buy             = MarketService.Buy,
        Sell            = MarketService.Sell,
        GetMarketStats  = MarketService.GetMarketStats,
        GetCategory     = MarketService.GetCategory,
    })
end

-- ==============================================================
-- 管理命令
-- ==============================================================

QBCore.Commands.Add('market', '查看交易市场价格 (可选参数: 分类名)', {}, false, function(source, args)
    local category = args[1]
    local items

    if category then
        items = MarketService.GetCategory(category)
        if #items == 0 then
            TriggerClientEvent('QBCore:Notify', source, ('没有找到分类: %s'):format(category), 'error')
            return
        end
    else
        items = MarketService.GetMarketStats()
    end

    TriggerClientEvent('chat:addMessage', source, {
        color = { 255, 215, 0 },
        args = { '市场行情', category and ('分类: ' .. category) or '全部商品' }
    })

    for _, item in ipairs(items) do
        local arrow = item.change >= 0 and '📈' or '📉'
        local color = item.change >= 0 and { 255, 100, 100 } or { 100, 255, 100 }
        TriggerClientEvent('chat:addMessage', source, {
            color = color,
            args = { '  ', ('%s %s | $%d (%s%d%%) | 供需 %d/%d'):format(
                arrow, item.label, item.price,
                item.change >= 0 and '+' or '', item.change,
                item.supply or 0, item.demand or 0
            ) }
        })
    end
end, 'user')

QBCore.Commands.Add('marketsetprice', '手动设置商品价格 (管理员)', {{name='item', help='商品名'}, {name='price', help='新价格'}}, true, function(source, args)
    local itemName = args[1]
    local newPrice = tonumber(args[2])

    if not itemName or not newPrice then
        TriggerClientEvent('QBCore:Notify', source, _L(src, 'market_setprice_usage'), 'error')
        return
    end

    local book = orderBooks[itemName]
    if not book then
        TriggerClientEvent('QBCore:Notify', source, _L(src, 'market_unknown_item', itemName), 'error')
        return
    end

    book.currentPrice = newPrice
    TriggerClientEvent('QBCore:Notify', source, ('%s 价格已设为 $%d'):format(book.label, newPrice), 'success')
end, 'admin')

print('[custom-market] 📊 动态交易市场已注册到 Bus')
print('[custom-market]   Exports: GetPrice, Buy, Sell, GetMarketStats, GetCategory')
print('[custom-market]   命令: /market (查看行情), /marketsetprice (管理员定价)')
