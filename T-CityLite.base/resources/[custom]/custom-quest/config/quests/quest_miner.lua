-- config/quests/quest_miner.lua
-- 矿工职业任务系列（外部配置文件示例）
-- 此文件会被 QuestRegistry.AutoLoad() 自动加载
-- 修改后执行 /reloadquests 热重载

return {
    -- ==========================================================
    -- 任务 1: 矿工学徒
    -- ==========================================================
    {
        id = 'miner_apprentice',
        title = '矿工学徒',
        description = '前往郊区矿井采集 5 块铁矿石',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 1,
            min_police = 0,
            daily_limit = 3,       -- v0.7.0: 每日最多完成 3 次
        },
        rewards = {
            money = { type = 'bank', min = 200, max = 400 },
            items = { { name = 'pickaxe', count = 1 } },
            rep = { mining = 50 },  -- v0.7.0: 矿工声望
        },
        steps = {
            {
                id = 'step_go_mine',
                title = '前往矿井',
                description = '前往郊区砂石场',
                type = 'reach',
                data = { coords = { x = -595.9, y = 3492.7, z = 30.0 }, radius = 15.0 },
            },
            {
                id = 'step_mine_iron',
                title = '采集铁矿石',
                description = '使用矿镐采集 5 块铁矿石',
                type = 'custom_event',
                data = {
                    event_name = 'mine_ore',
                    match = { ore_type = 'iron_ore' },
                    required_count = 5,
                    progress_key = 'count',
                },
            },
            {
                id = 'step_return',
                title = '回去报到',
                description = '回到城区职业介绍所',
                type = 'reach',
                data = { coords = { x = -268.4, y = -957.5, z = 31.2 }, radius = 10.0 },
            },
        },
    },

    -- ==========================================================
    -- 任务 2: 中级矿工（需完成学徒任务后解锁）
    -- ==========================================================
    {
        id = 'miner_mid',
        title = '中级矿工',
        description = '深入矿井采集 10 块金矿石并探索隐藏洞穴',
        category = 'civilian',
        level = 2,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 4,
            min_police = 0,
            daily_limit = 1,
            prerequisite_quest = 'miner_apprentice',  -- 前置任务
        },
        rewards = {
            money = { type = 'bank', min = 800, max = 1500 },
            items = { { name = 'pickaxe_pro', count = 1 } },
            rep = { mining = 100 },
        },
        steps = {
            {
                id = 'step_enter_deep',
                title = '深入矿井',
                description = '进入矿井深层区域',
                type = 'reach',
                data = { coords = { x = -590.0, y = 3495.0, z = 20.0 }, radius = 10.0 },
            },
            {
                id = 'step_mine_gold',
                title = '采集金矿石',
                description = '采集 10 块金矿石',
                type = 'custom_event',
                data = {
                    event_name = 'mine_ore',
                    match = { ore_type = 'gold_ore' },
                    required_count = 10,
                    progress_key = 'count',
                },
            },
            {
                id = 'step_explore_cave',
                title = '探索隐藏洞穴',
                description = '进入矿井深处的隐藏洞穴',
                type = 'reach',
                data = { coords = { x = -600.0, y = 3500.0, z = 10.0 }, radius = 8.0 },
            },
        },
    },

    -- ==========================================================
    -- 任务 3: 矿藏收集者（collect 步骤类型示例）
    -- ==========================================================
    {
        id = 'miner_collector',
        title = '矿藏收集者',
        description = '收集 3 块铜矿石和 2 块银矿石交给冶炼厂',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 2,
            min_police = 0,
            daily_limit = 2,
        },
        rewards = {
            money = { type = 'bank', min = 300, max = 600 },
            rep = { mining = 75 },
        },
        steps = {
            {
                id = 'step_collect_ores',
                title = '收集矿石',
                description = '收集 3 块铜矿石和 2 块银矿石',
                type = 'collect',
                data = {
                    items = {
                        { name = 'copper_ore', count = 3 },
                        { name = 'silver_ore', count = 2 },
                    },
                    consume = true,  -- 完成后消耗物品
                },
            },
            {
                id = 'step_deliver',
                title = '交付冶炼厂',
                description = '前往冶炼厂交付矿石',
                type = 'reach',
                data = { coords = { x = 1080.0, y = -1980.0, z = 30.0 }, radius = 15.0 },
            },
        },
    },

    -- ==========================================================
    -- 任务 4: 矿场老板（script_trigger 步骤类型示例）
    -- ==========================================================
    {
        id = 'miner_boss',
        title = '矿场运营官',
        description = '管理矿场日常运营',
        category = 'civilian',
        level = 3,
        required_tags = { role = 'civilian', tier = 'leader' },
        conditions = {
            cooldown_hours = 12,
            min_police = 0,
            daily_limit = 1,
            prerequisite_quest = 'miner_mid',
        },
        rewards = {
            money = { type = 'bank', min = 3000, max = 5000 },
            rep = { mining = 200 },
        },
        steps = {
            {
                id = 'step_reach_office',
                title = '前往矿场办公室',
                description = '前往矿场管理办公室',
                type = 'reach',
                data = { coords = { x = -570.0, y = 3480.0, z = 30.0 }, radius = 12.0 },
            },
            {
                id = 'step_manage_mine',
                title = '启动矿场管理面板',
                description = '触发矿场管理脚本（等待管理操作完成）',
                type = 'script_trigger',
                data = {
                    export_path = 'custom-mining:MineOre',
                    args = { 'management_mode' },
                },
            },
            {
                id = 'step_sign_docs',
                title = '签署运营文件',
                description = '前往市政厅签署文件',
                type = 'reach',
                data = { coords = { x = -268.4, y = -957.5, z = 31.2 }, radius = 10.0 },
            },
        },
    },
}