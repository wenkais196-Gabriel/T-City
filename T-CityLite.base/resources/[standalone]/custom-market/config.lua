-- config.lua — custom-market 动态交易市场配置
--
-- 每件商品独立 OrderBook: 供需驱动价格 + 均值回归
-- "买多就涨，卖多就跌" + 自然均衡
--
-- 可通过 Convar 运行时调整所有参数

Config = Config or {}
Config.Market = {}

-- =============================================================
-- 全局市场参数
-- =============================================================

-- 价格弹性系数 (0-1): 越高 → 供需变化对价格影响越大
--   set market_elasticity "0.3"
Config.Market.Elasticity = (function()
    local val = GetConvar('market_elasticity', '0.3')
    return tonumber(val) or 0.3
end)()

-- 均值回归速率 (0-1): 每Tick价格向basePrice回归的比例
--   0 = 完全自由浮动, 1 = 瞬间回归
--   set market_decay_rate "0.005"
Config.Market.DecayRate = (function()
    local val = GetConvar('market_decay_rate', '0.005')
    return tonumber(val) or 0.005
end)()

-- 价格Tick间隔 (秒): 供需平衡重新计算频率
--   set market_tick_interval "300"
Config.Market.TickInterval = (function()
    local val = GetConvar('market_tick_interval', '300')
    local num = tonumber(val) or 300
    return math.max(60, num)  -- 最少60秒
end)()

-- 价格波动上限: 不允许价格偏离 basePrice 超过此比例
--   0.5 = 最低半价, 最高1.5倍
--   set market_max_deviation "0.5"
Config.Market.MaxDeviation = (function()
    local val = GetConvar('market_max_deviation', '0.5')
    return tonumber(val) or 0.5
end)()

-- 最小交易量（避免除以零）
Config.Market.MinVolume = 1

-- =============================================================
-- 商品 OrderBook 初始配置
-- =============================================================
-- basePrice: 基准单价（$）
-- supplyVolume: 初始供给量
-- demandVolume: 初始需求量
-- category: 分类（用于UI分组）
-- minPrice/maxPrice: 绝对最低/最高价（防止极端波动）
-- stackSize: 单格堆叠数（参考）

Config.Market.Commodities = {
    -- ==========================================================
    -- 矿石类 (合法采集)
    -- ==========================================================
    iron_ore = {
        basePrice = 8,
        supplyVolume = 500,
        demandVolume = 500,
        category = 'ores',
        label = '铁矿石',
        minPrice = 2,
        maxPrice = 30,
    },
    copper_ore = {
        basePrice = 12,
        supplyVolume = 400,
        demandVolume = 450,
        category = 'ores',
        label = '铜矿石',
        minPrice = 3,
        maxPrice = 40,
    },
    gold_ore = {
        basePrice = 45,
        supplyVolume = 200,
        demandVolume = 300,
        category = 'ores',
        label = '金矿石',
        minPrice = 15,
        maxPrice = 120,
    },
    silver_ore = {
        basePrice = 30,
        supplyVolume = 250,
        demandVolume = 280,
        category = 'ores',
        label = '银矿石',
        minPrice = 10,
        maxPrice = 80,
    },
    coal = {
        basePrice = 5,
        supplyVolume = 600,
        demandVolume = 550,
        category = 'ores',
        label = '煤炭',
        minPrice = 1,
        maxPrice = 20,
    },
    stone = {
        basePrice = 3,
        supplyVolume = 800,
        demandVolume = 700,
        category = 'ores',
        label = '石料',
        minPrice = 1,
        maxPrice = 12,
    },

    -- ==========================================================
    -- 金属锭 (冶炼产物)
    -- ==========================================================
    iron_ingot = {
        basePrice = 25,
        supplyVolume = 300,
        demandVolume = 350,
        category = 'ingots',
        label = '铁锭',
        minPrice = 8,
        maxPrice = 80,
    },
    copper_ingot = {
        basePrice = 35,
        supplyVolume = 250,
        demandVolume = 300,
        category = 'ingots',
        label = '铜锭',
        minPrice = 12,
        maxPrice = 100,
    },
    gold_ingot = {
        basePrice = 120,
        supplyVolume = 100,
        demandVolume = 150,
        category = 'ingots',
        label = '金锭',
        minPrice = 50,
        maxPrice = 300,
    },
    silver_ingot = {
        basePrice = 80,
        supplyVolume = 120,
        demandVolume = 160,
        category = 'ingots',
        label = '银锭',
        minPrice = 30,
        maxPrice = 200,
    },

    -- ==========================================================
    -- 毒品原料
    -- ==========================================================
    coca_leaf = {
        basePrice = 10,
        supplyVolume = 200,
        demandVolume = 300,
        category = 'drugs_raw',
        label = '古柯叶',
        minPrice = 3,
        maxPrice = 35,
    },
    cannabis_bud = {
        basePrice = 8,
        supplyVolume = 250,
        demandVolume = 350,
        category = 'drugs_raw',
        label = '大麻花',
        minPrice = 2,
        maxPrice = 30,
    },

    -- ==========================================================
    -- 毒品成品
    -- ==========================================================
    coca_paste = {
        basePrice = 40,
        supplyVolume = 100,
        demandVolume = 180,
        category = 'drugs_processed',
        label = '古柯膏',
        minPrice = 15,
        maxPrice = 120,
    },
    cocaine = {
        basePrice = 120,
        supplyVolume = 50,
        demandVolume = 150,
        category = 'drugs_processed',
        label = '可卡因',
        minPrice = 40,
        maxPrice = 350,
    },
    weed_pack = {
        basePrice = 60,
        supplyVolume = 80,
        demandVolume = 140,
        category = 'drugs_processed',
        label = '大麻包装',
        minPrice = 20,
        maxPrice = 180,
    },

    -- ==========================================================
    -- 化学原料 (毒品加工)
    -- ==========================================================
    sulfuric_acid = {
        basePrice = 25,
        supplyVolume = 300,
        demandVolume = 250,
        category = 'chemicals',
        label = '硫酸',
        minPrice = 8,
        maxPrice = 80,
    },
    acetone = {
        basePrice = 30,
        supplyVolume = 280,
        demandVolume = 260,
        category = 'chemicals',
        label = '丙酮',
        minPrice = 10,
        maxPrice = 90,
    },
}

-- =============================================================
-- 从 Convar 读取商品价格覆盖 (管理员运行时调整)
-- 格式: set market_price_cocaine "150"
-- =============================================================

function Config.Market.GetRuntimePriceOverride(itemName)
    local val = GetConvar('market_price_' .. itemName, '')
    if val ~= '' then
        return tonumber(val)
    end
    return nil
end

-- =============================================================
-- 统计
-- =============================================================

local commodityCount = 0
for _ in pairs(Config.Market.Commodities) do commodityCount = commodityCount + 1 end

-- market-config startup prints removed (production mode)
