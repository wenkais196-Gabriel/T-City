-- config.lua — 可消耗物品表（custom-consumables）
--
-- 为什么单独维护一张表而不是读 qb-core 的 items：qb-core 的 item 定义里只有重量与描述，
-- 没有"吃了涨多少"。qpb-smallresources 当年也是自带一张表。
--
-- 字段：
--   hunger / thirst  饱和值（0–100 的百分比，加到玩家状态上）
--   alcohol          酒精增量（0–1，给警用酒测读）
--   drug             药物读数增量（0–1，给警用药检读）
--   stress           压力变化（负数降压；没有压力系统的服可忽略）
--   cooldownMs       同一物品的最短使用间隔

Config = Config or {}

Config.Consumables = {
    -- 喝的
    water    = { thirst = 35, cooldownMs = 3000 },
    coffee   = { thirst = 25, stress = -5, cooldownMs = 3000 },
    beer     = { thirst = 15, alcohol = 0.25, stress = -8, cooldownMs = 4000 },
    vodka    = { thirst = 10, alcohol = 0.50, stress = -12, cooldownMs = 4000 },

    -- 吃的
    sandwich = { hunger = 35, cooldownMs = 4000 },
    burger   = { hunger = 45, cooldownMs = 4000 },
    taco     = { hunger = 30, cooldownMs = 4000 },
    apple    = { hunger = 12, thirst = 5, cooldownMs = 2000 },

    -- 药
    weed_white = { drug = 0.30, stress = -10, cooldownMs = 6000 },
    weed_purple = { drug = 0.40, stress = -12, cooldownMs = 6000 },
}

--- 状态衰减：每 DECAY_INTERVAL_MS 一次，按 DECAY_HUNGER / DECAY_THIRST 扣。
Config.DecayIntervalMs = 60000
Config.DecayHunger = 1.0
Config.DecayThirst = 1.2

--- 酒精/药物随时间的代谢（每秒）
Config.AlcoholDecayPerSecond = 0.01
Config.DrugDecayPerSecond = 0.008
