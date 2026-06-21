-- config/quests/quest_chain_miner.lua
-- 矿工职业生涯任务链配置
-- v0.7.0: 任务链定义了多个任务之间的线性/分支关系

return {
    id = 'miner_career_chain',
    title = '矿工生涯',
    description = '从学徒到矿场老板的完整职业道路 —— 完成所有阶段解锁传奇矿镐',
    category = 'civilian',

    -- 解锁条件：任何平民角色均可开始
    unlock_condition = { role = 'civilian' },

    -- 线性链：必须按顺序完成
    is_linear = true,
    is_repeatable = false,
    cooldown_hours = 0,        -- 链本身无冷却（由单个任务控制）

    -- 链内任务 ID 列表（顺序执行）
    quests = {
        'miner_apprentice',     -- 阶段 1
        'miner_mid',            -- 阶段 2
        'miner_boss',           -- 阶段 3
    },

    -- 全部完成后的额外奖励
    chain_completion_rewards = {
        money = { type = 'bank', min = 10000, max = 15000 },
        items = { { name = 'pickaxe_legendary', count = 1 } },
        rep = { mining = 500 },
    },
}