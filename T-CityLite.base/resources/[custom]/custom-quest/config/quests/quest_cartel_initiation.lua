-- config/quests/quest_cartel_initiation.lua
-- Cartel 入会考验 — 运输任务
-- 新成员加入 Cartel 必须完成此任务

return {
    {
        id = 'cartel_initiation',
        title = 'Cartel 入会考验',
        description = '向大老板证明你的忠诚 — 安全运输一批古柯叶到农场',
        category = 'cartel',
        level = 1,
        required_tags = { role = 'civilian' },  -- 尚未加入 cartel 的平民可接
        conditions = {
            cooldown_hours = 24,
            min_police = 2,
            daily_limit = 1,
        },
        rewards = {
            money = { type = 'bank', min = 500, max = 1000 },
            items = { { name = 'coca_leaf', count = 10 } },
            rep = { cartel = 50 },
            -- 完成后自动将玩家加入 cartel 帮派 (等级0: Halcon)
            on_complete = {
                action = 'set_gang',
                gang = 'cartel',
                grade = 0,
            },
        },
        steps = {
            {
                id = 'step_meet_boss',
                title = '会见大老板',
                description = '前往 Madrazo Ranch 会见 Cartel 大老板',
                type = 'reach',
                data = { coords = { x = 1310.0, y = 1125.0, z = 104.0 }, radius = 8.0 },
            },
            {
                id = 'step_pickup_coca',
                title = '取货',
                description = '前往郊区采集点取古柯叶',
                type = 'reach',
                data = { coords = { x = 1960.0, y = 3700.0, z = 33.0 }, radius = 15.0 },
            },
            {
                id = 'step_collect_leaves',
                title = '收集古柯叶',
                description = '收集 10 片古柯叶',
                type = 'collect',
                data = {
                    items = { { name = 'coca_leaf', count = 10 } },
                    consume = false,
                },
            },
            {
                id = 'step_deliver_farm',
                title = '返回农场',
                description = '将古柯叶运回 Madrazo Ranch 实验室',
                type = 'reach',
                data = { coords = { x = 1310.0, y = 1120.0, z = 104.0 }, radius = 10.0 },
            },
        },
    },
}
