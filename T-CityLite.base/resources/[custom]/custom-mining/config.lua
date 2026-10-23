-- config.lua — custom-mining 矿业系统配置

Config = Config or {}
Config.Mining = {}

-- =============================================================
-- 系统开关
-- =============================================================
Config.Mining.Enabled = GetConvar('mining_enable', 'true') == 'true'

-- =============================================================
-- 矿点配置
-- =============================================================
Config.Mining.Sites = {
    -- 郊区砂石场 (铁/铜 — 入门矿点)
    {
        id = 'quarry',
        label = '郊区砂石场',
        coords = vector3(-595.9, 3492.7, 30.0),
        radius = 40.0,
        ores = {
            { name = 'iron_ore',  label = '铁矿石', weight = 20, baseTime = 8,  minGrade = 0 },
            { name = 'copper_ore', label = '铜矿石', weight = 15, baseTime = 10, minGrade = 0 },
            { name = 'stone',      label = '石料',   weight = 25, baseTime = 5,  minGrade = 0 },
        },
        blip = { sprite = 618, color = 5, scale = 0.8 },
    },

    -- 山区矿脉 (金/银 — 高级矿点)
    {
        id = 'mountain',
        label = '山区金矿',
        coords = vector3(-1600.0, 2300.0, 80.0),
        radius = 35.0,
        ores = {
            { name = 'gold_ore',   label = '金矿石', weight = 5,  baseTime = 20, minGrade = 1 },
            { name = 'silver_ore', label = '银矿石', weight = 8,  baseTime = 16, minGrade = 1 },
            { name = 'iron_ore',   label = '铁矿石', weight = 10, baseTime = 10, minGrade = 0 },
        },
        blip = { sprite = 618, color = 46, scale = 0.8 },
    },

    -- 沙漠煤矿 (煤炭 — 冶炼燃料)
    {
        id = 'desert',
        label = '沙漠煤矿',
        coords = vector3(1500.0, 3500.0, 35.0),
        radius = 45.0,
        ores = {
            { name = 'coal',   label = '煤炭', weight = 30, baseTime = 6,  minGrade = 0 },
            { name = 'stone',  label = '石料', weight = 20, baseTime = 5,  minGrade = 0 },
        },
        blip = { sprite = 618, color = 81, scale = 0.8 },
    },

    -- 海岸采集点 (石料+铜 — 补充)
    {
        id = 'coast',
        label = '海岸矿场',
        coords = vector3(2800.0, 2950.0, 5.0),
        radius = 30.0,
        ores = {
            { name = 'copper_ore', label = '铜矿石', weight = 12, baseTime = 10, minGrade = 0 },
            { name = 'stone',      label = '石料',   weight = 35, baseTime = 4,  minGrade = 0 },
        },
        blip = { sprite = 618, color = 3, scale = 0.8 },
    },
}

-- =============================================================
-- 冶炼配方
-- =============================================================
Config.Mining.SmeltRecipes = {
    {
        id = 'iron_ingot',
        label = '铁锭',
        inputs = {
            { name = 'iron_ore', count = 3, label = '铁矿石' },
            { name = 'coal',     count = 1, label = '煤炭' },
        },
        output = { name = 'iron_ingot', count = 1, label = '铁锭' },
        duration = 15,
        failRate = 0.05,
    },
    {
        id = 'copper_ingot',
        label = '铜锭',
        inputs = {
            { name = 'copper_ore', count = 3, label = '铜矿石' },
            { name = 'coal',       count = 1, label = '煤炭' },
        },
        output = { name = 'copper_ingot', count = 1, label = '铜锭' },
        duration = 18,
        failRate = 0.08,
    },
    {
        id = 'gold_ingot',
        label = '金锭',
        inputs = {
            { name = 'gold_ore', count = 3, label = '金矿石' },
            { name = 'coal',     count = 2, label = '煤炭' },
        },
        output = { name = 'gold_ingot', count = 1, label = '金锭' },
        duration = 25,
        failRate = 0.12,
    },
    {
        id = 'silver_ingot',
        label = '银锭',
        inputs = {
            { name = 'silver_ore', count = 3, label = '银矿石' },
            { name = 'coal',       count = 2, label = '煤炭' },
        },
        output = { name = 'silver_ingot', count = 1, label = '银锭' },
        duration = 22,
        failRate = 0.10,
    },
}

-- =============================================================
-- 冶炼厂位置
-- =============================================================
Config.Mining.SmelterLocation = {
    coords = vector3(1080.0, -1980.0, 30.0),
    radius = 5.0,
    label = '冶炼厂',
    blip = { sprite = 648, color = 5, scale = 0.8 },
}

-- =============================================================
-- 工具效率加成
-- =============================================================
Config.Mining.Tools = {
    pickaxe = {
        label = '基础矿镐',
        speedMultiplier = 1.0,
        yieldBonus = 0,       -- 额外产出概率
    },
    pickaxe_pro = {
        label = '高级矿镐',
        speedMultiplier = 0.7,  -- 快30%
        yieldBonus = 0.15,      -- 15%概率双倍
    },
    pickaxe_legendary = {
        label = '传奇矿镐',
        speedMultiplier = 0.5,  -- 快50%
        yieldBonus = 0.30,      -- 30%概率双倍
    },
}

-- =============================================================
-- 安全参数
-- =============================================================
Config.Mining.Security = {
    cooldownSec = tonumber(GetConvar('mining_cooldown', '5')) or 5,
    maxPerSession = tonumber(GetConvar('mining_max_per_session', '100')) or 100,
}

-- mining-config startup print removed
