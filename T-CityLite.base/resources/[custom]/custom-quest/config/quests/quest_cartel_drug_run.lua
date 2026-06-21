-- config/quests/quest_cartel_drug_run.lua
-- Cartel 毒品运输任务
-- 将成品毒品送达街头分销点

return {
    -- ==========================================================
    -- 任务 1: 可卡因运输
    -- ==========================================================
    {
        id = 'cartel_drug_run',
        title = '街头交货',
        description = '将可卡因送到指定的街头分销点，避开警察巡逻',
        category = 'cartel',
        level = 1,
        required_tags = { role = 'civilian', tier = 'entry' },
        conditions = {
            cooldown_hours = 2,
            min_police = 2,
            daily_limit = 3,
        },
        rewards = {
            money = { type = 'bank', min = 1500, max = 3000 },
            rep = { cartel = 30 },
        },
        steps = {
            {
                id = 'step_get_product',
                title = '获取货物',
                description = '从 Cartel 组织仓库或背包获取 3 份可卡因',
                type = 'collect',
                data = {
                    items = { { name = 'cocaine', count = 3 } },
                    consume = false,  -- 不消耗，将在后续步骤手动扣除
                },
            },
            {
                id = 'step_deliver_1',
                title = '第一站: 洛圣都港区',
                description = '将货送到港口仓库区',
                type = 'reach',
                data = { coords = { x = 900.0, y = -3200.0, z = 6.0 }, radius = 15.0 },
            },
            {
                id = 'step_deliver_2',
                title = '第二站: 南区小巷',
                description = '将货送到南洛圣都的隐蔽交接点',
                type = 'reach',
                data = { coords = { x = 300.0, y = -1800.0, z = 26.0 }, radius = 10.0 },
            },
            {
                id = 'step_deliver_3',
                title = '第三站: 东部工业区',
                description = '最后一站，工业区夜间交接',
                type = 'reach',
                data = { coords = { x = 1200.0, y = -1500.0, z = 35.0 }, radius = 12.0 },
            },
            {
                id = 'step_complete',
                title = '交货完成',
                description = '交付 3 份可卡因（将从背包扣除）',
                type = 'collect',
                data = {
                    items = { { name = 'cocaine', count = 3 } },
                    consume = true,  -- 此步消耗物品
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 2: 大麻运输
    -- ==========================================================
    {
        id = 'cartel_weed_run',
        title = '绿意运输',
        description = '将大麻包装送到沙漠地区的接头人',
        category = 'cartel',
        level = 1,
        required_tags = { role = 'civilian', tier = 'entry' },
        conditions = {
            cooldown_hours = 1,
            min_police = 1,
            daily_limit = 5,
        },
        rewards = {
            money = { type = 'bank', min = 800, max = 1500 },
            rep = { cartel = 20 },
        },
        steps = {
            {
                id = 'step_get_weed',
                title = '获取大麻',
                description = '从仓库或背包获取 5 份大麻包装',
                type = 'collect',
                data = {
                    items = { { name = 'weed_pack', count = 5 } },
                    consume = false,
                },
            },
            {
                id = 'step_desert_meet',
                title = '沙漠接头',
                description = '前往大沙漠中的接头地点',
                type = 'reach',
                data = { coords = { x = 1500.0, y = 3800.0, z = 35.0 }, radius = 20.0 },
            },
            {
                id = 'step_hand_over',
                title = '交付货物',
                description = '交出 5 份大麻包装',
                type = 'collect',
                data = {
                    items = { { name = 'weed_pack', count = 5 } },
                    consume = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 3: script_trigger 示例 — 洗钱任务
    -- ==========================================================
    {
        id = 'cartel_launder',
        title = '资金清洗',
        description = '将犯罪所得通过当铺洗白',
        category = 'cartel',
        level = 2,
        required_tags = { role = 'civilian', tier = 'mid' },
        conditions = {
            cooldown_hours = 6,
            min_police = 0,
            daily_limit = 2,
        },
        rewards = {
            money = { type = 'bank', min = 2000, max = 4000 },
            rep = { cartel = 40 },
        },
        steps = {
            {
                id = 'step_reach_pawnshop',
                title = '前往当铺',
                description = '前往当铺准备洗钱',
                type = 'reach',
                data = { coords = { x = 130.0, y = -1290.0, z = 29.0 }, radius = 10.0 },
            },
            {
                id = 'step_launder',
                title = '清洗资金',
                description = '通过当铺洗钱 (调用 custom-crime LaunderMoney)',
                type = 'script_trigger',
                data = {
                    export_path = 'custom-crime:LaunderMoney',
                    args = { 'launder_mode' },
                },
            },
        },
    },
}
