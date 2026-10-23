-- config.lua — custom-cartel Cartel Organization Core Configuration
--
-- Modular · High-Performance · Secure · Extensible
--
-- All Cartel gameplay parameters centrally managed
-- Runtime overridable via Convar
-- Labels use { en, zh } tables → client-side language auto-resolution

Config = Config or {}
Config.Cartel = {}

-- =============================================================
-- System Toggle
-- =============================================================

Config.Cartel.Enabled = GetConvar('cartel_enable', 'true') == 'true'

-- =============================================================
-- Drug Production Recipes
-- =============================================================
-- Recipe format:
--   recipe_id = {
--     inputs  = { { name, count, label = { en, zh } }, ... }
--     output  = { name, count, label = { en, zh } }
--     duration = seconds
--     minigame = 'safecracker'|'progressbar'|nil
--     failRate = 0~1
--     requiredGrade = 0~4
--   }

Config.Cartel.Recipes = {
    -- ======== Coca Leaf → Coca Paste ========
    coca_paste = {
        label    = { en = 'Coca Paste',       zh = '古柯膏' },
        description = { en = 'Mix coca leaves with sulfuric acid to produce coca paste',
                        zh = '将古柯叶与硫酸混合制成古柯膏' },
        inputs = {
            { name = 'coca_leaf',       count = 3, label = { en = 'Coca Leaf',       zh = '古柯叶' } },
            { name = 'sulfuric_acid',   count = 1, label = { en = 'Sulfuric Acid',   zh = '硫酸' } },
        },
        output = { name = 'coca_paste', count = 1, label = { en = 'Coca Paste',       zh = '古柯膏' } },
        duration = 30,          -- 30 seconds
        minigame = 'progressbar',
        failRate = 0.15,        -- 15% failure rate
        requiredGrade = 0,      -- Halcon and above
    },

    -- ======== Coca Paste → Cocaine ========
    cocaine = {
        label    = { en = 'Cocaine',          zh = '可卡因' },
        description = { en = 'Refine coca paste with acetone into pure cocaine',
                        zh = '用丙酮精炼古柯膏制成高纯度可卡因' },
        inputs = {
            { name = 'coca_paste',      count = 2, label = { en = 'Coca Paste',       zh = '古柯膏' } },
            { name = 'acetone',         count = 1, label = { en = 'Acetone',          zh = '丙酮' } },
        },
        output = { name = 'cocaine',    count = 1, label = { en = 'Cocaine',          zh = '可卡因' } },
        duration = 45,          -- 45 seconds
        minigame = 'safecracker',
        failRate = 0.25,        -- 25% failure rate
        requiredGrade = 1,      -- Sicario and above
    },

    -- ======== Cannabis Bud → Weed Pack ========
    weed_pack = {
        label    = { en = 'Weed Pack',        zh = '大麻包装' },
        description = { en = 'Vacuum-seal cannabis buds into sellable packs',
                        zh = '将大麻花真空包装成可销售的商品' },
        inputs = {
            { name = 'cannabis_bud',    count = 5, label = { en = 'Cannabis Bud',     zh = '大麻花' } },
        },
        output = { name = 'weed_pack',  count = 1, label = { en = 'Weed Pack',        zh = '大麻包装' } },
        duration = 20,          -- 20 seconds
        minigame = 'progressbar',
        failRate = 0.05,        -- 5% failure rate
        requiredGrade = 0,      -- lowest rank
    },
}

-- =============================================================
-- Lab Location (Madrazo Ranch underground)
-- =============================================================

Config.Cartel.LabLocation = {
    coords = vector3(1310.0, 1120.0, 103.5),  -- Madrazo Ranch interior
    radius = 3.0,                               -- interaction range
    label = { en = 'Drug Laboratory', zh = '毒品实验室' },
    blip = {
        sprite = 499,    -- chemical icon
        color = 1,       -- red
        scale = 0.8,
        label = { en = 'Cartel Laboratory', zh = 'Cartel 实验室' },
    },
}

-- =============================================================
-- NPC Configuration (Cartel Farm Allies)
-- =============================================================

Config.Cartel.NPCs = {
    -- === Chemical Supplier ===
    {
        id = 'cartel_chem_dealer',
        model = 's_m_m_chemsec_01',      -- chemical security personnel
        coords = vector4(1312.5, 1118.0, 103.5, 180.0),
        label = { en = 'Chemical Supplier', zh = '化学供应商' },
        role = 'supplier',
        items = {
            { name = 'sulfuric_acid', price = 25, stock = 100 },
            { name = 'acetone', price = 30, stock = 80 },
            { name = 'coca_leaf', price = 10, stock = 200 },
            { name = 'cannabis_bud', price = 8, stock = 150 },
        },
        scenario = 'WORLD_HUMAN_SMOKING',
    },

    -- === Drug Distributor ===
    {
        id = 'cartel_drug_dealer',
        model = 'g_m_m_chicold_01',      -- middle-aged latino male
        coords = vector4(1315.0, 1115.5, 103.5, 90.0),
        label = { en = 'Drug Distributor', zh = '毒品分销商' },
        role = 'dealer',
        buyPrices = {
            cocaine = 100,               -- buys cocaine at $100/pc
            weed_pack = 50,              -- buys weed at $50/pc
        },
        scenario = 'WORLD_HUMAN_AA_SMOKE',
    },

    -- === Quest Giver / Cartel Boss ===
    {
        id = 'cartel_boss_npc',
        model = 'g_m_m_mexboss_01',      -- mexican cartel boss
        coords = vector4(1310.0, 1125.0, 103.5, 0.0),
        label = { en = 'Cartel Boss', zh = 'Cartel 大老板' },
        role = 'quest_giver',
        scenario = 'WORLD_HUMAN_DRINKING',
    },
}

-- =============================================================
-- Security Configuration
-- =============================================================

Config.Cartel.Security = {
    -- min online police to trigger raid
    minPoliceForRaid = tonumber(GetConvar('cartel_raid_min_police', '3')) or 3,

    -- raid chance (per hour)
    raidChancePerHour = tonumber(GetConvar('cartel_raid_chance', '0.15')) or 0.15,

    -- production cooldown (seconds) — anti-farm
    productionCooldown = tonumber(GetConvar('cartel_production_cooldown', '10')) or 10,

    -- max batch size per production
    maxBatchSize = tonumber(GetConvar('cartel_max_batch', '5')) or 5,
}

-- =============================================================
-- Stats
-- =============================================================

local recipeCount = 0; for _ in pairs(Config.Cartel.Recipes) do recipeCount = recipeCount + 1 end

-- cartel-config startup prints removed (production mode)
