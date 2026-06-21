-- config/quests/quest_chain_cartel.lua
-- Cartel 职业生涯任务链
-- 从街头小喽啰到集团大头目的完整路径

return {
    id = 'cartel_career_chain',
    title = 'Cartel 帝国之路',
    description = '从 Halcon 到 El Jefe —— 征服洛圣都地下世界',
    category = 'cartel',

    unlock_condition = { role = 'civilian' },

    is_linear = true,
    is_repeatable = false,
    cooldown_hours = 0,

    -- 链内任务 ID（顺序执行）
    quests = {
        'cartel_initiation',    -- 阶段 1: 入会考验 (完成后自动加入 cartel 帮派)
        'cartel_drug_run',      -- 阶段 2: 街头交货
        'cartel_weed_run',      -- 阶段 3: 大麻运输
        'cartel_launder',       -- 阶段 4: 资金清洗
    },

    -- 全部完成后的额外奖励
    chain_completion_rewards = {
        money = { type = 'bank', min = 25000, max = 50000 },
        items = {
            { name = 'cocaine', count = 20 },
            { name = 'weed_pack', count = 10 },
        },
        rep = { cartel = 500 },
        -- 自动提升为 Jefe de Plaza (等级2)
        on_complete = {
            action = 'set_gang_grade',
            gang = 'cartel',
            grade = 2,
        },
    },
}
