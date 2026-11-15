-- config.lua — 可消耗物品表（custom-consumables）
--
-- 为什么单独维护一张表而不是读 qb-core 的 items：qb-core 的 item 定义里只有重量与描述，
-- 没有"吃了涨多少"。
--
-- ⚠ 名字必须与 `qb-core/shared/items.lua` 里的 item 名**逐字一致**。
--    2026-11-10 真机故障：这张表写的是 water / burger / taco / apple / weed_white，
--    而商店卖的是 water_bottle / kurkakola / tosti / sandwich / weed_whitewidow ——
--    名字对不上，`Config.Consumables[itemName]` 取到 nil，玩家吃了完全没反应；
--    原来能生效的只有 sandwich / beer / vodka。
--    `tests/architecture/test_consumables_contract.py` 现在会拦住这种错位。
--
-- 字段：
--   hunger / thirst  饱和值（0–100 的百分比，加到玩家状态上）
--   alcohol          酒精增量（0–1，给警用酒测读）
--   drug             药物读数增量（0–1，给警用药检读）
--   stress           压力变化（负数降压）
--   cooldownMs       同一物品的最短使用间隔

Config = Config or {}

Config.Consumables = {
    -- 喝的（商店 normal 货架）
    water_bottle = { thirst = 35, cooldownMs = 3000 },
    kurkakola    = { thirst = 20, cooldownMs = 3000 },
    coffee       = { thirst = 25, stress = -5, cooldownMs = 3000 },
    beer         = { thirst = 15, alcohol = 0.25, stress = -8, cooldownMs = 4000 },
    whiskey      = { thirst = 10, alcohol = 0.35, stress = -10, cooldownMs = 4000 },
    vodka        = { thirst = 10, alcohol = 0.50, stress = -12, cooldownMs = 4000 },

    -- 吃的（商店 normal 货架）
    tosti         = { hunger = 30, cooldownMs = 4000 },
    sandwich      = { hunger = 35, cooldownMs = 4000 },
    twerks_candy  = { hunger = 10, cooldownMs = 1500 },
    snikkel_candy = { hunger = 12, cooldownMs = 1500 },

    -- 药（走私/组织线产出）
    weed_whitewidow = { drug = 0.30, stress = -10, cooldownMs = 6000 },
    weed_purplehaze = { drug = 0.40, stress = -12, cooldownMs = 6000 },
    weed_skunk      = { drug = 0.35, stress = -11, cooldownMs = 6000 },
    weed_ogkush     = { drug = 0.45, stress = -14, cooldownMs = 6000 },
    weed_amnesia    = { drug = 0.38, stress = -12, cooldownMs = 6000 },
}

--- 状态衰减：每 DECAY_INTERVAL_MS 一次，按 DECAY_HUNGER / DECAY_THIRST 扣。
Config.DecayIntervalMs = 60000
Config.DecayHunger = 1.0
Config.DecayThirst = 1.2

--- 酒精/药物随时间的代谢（每秒）
Config.AlcoholDecayPerSecond = 0.01
Config.DrugDecayPerSecond = 0.008
