-- config/quests/quest_civilian_misc.lua
-- 🛒 市井商业与特色副业任务 (P2/Stage 5) — 基于 custom-quest 状态机
--
-- 热狗摊贩 / 新闻记者 / 回收站

return {
    -- ==========================================================
    -- 热狗摊贩 (Hotdog)
    -- ==========================================================
    {
        id = 'hotdog_vendor',
        title = '热狗摊贩',
        description = '在热狗摊位制作并销售热狗，赚取现金收入。',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 0,
            min_police = 0,
            daily_limit = 15,
        },
        rewards = {
            money = { type = 'cash', min = 150, max = 350 },
        },
        steps = {
            {
                id = 'step_reach_stand',
                title = '前往热狗摊',
                description = '前往市区的热狗摊位',
                type = 'reach',
                data = {
                    coords = { x = -150.0, y = -250.0, z = 44.0 },
                    radius = 5.0,
                },
            },
            {
                id = 'step_prepare',
                title = '准备食材',
                description = '从冰箱取出热狗和面包',
                type = 'interact',
                data = {
                    coords = { x = -150.0, y = -250.0, z = 44.0 },
                    radius = 5.0,
                    duration = 3000,
                    label = '准备食材...',
                },
            },
            {
                id = 'step_cook',
                title = '烤制热狗',
                description = '在烤架上翻烤热狗至金黄',
                type = 'interact',
                data = {
                    coords = { x = -150.0, y = -250.0, z = 44.0 },
                    radius = 3.0,
                    duration = 5000,
                    label = '烤制热狗...',
                },
            },
            {
                id = 'step_serve',
                title = '售卖',
                description = '等待顾客购买并收款',
                type = 'interact',
                data = {
                    coords = { x = -150.0, y = -250.0, z = 44.0 },
                    radius = 3.0,
                    duration = 4000,
                    label = '售卖中...',
                },
            },
        },
    },

    -- ==========================================================
    -- 新闻记者 (Reporter)
    -- ==========================================================
    {
        id = 'news_report',
        title = '新闻采访',
        description = '前往事件现场拍摄照片，回到新闻社发稿。',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 0,
            min_police = 0,
            daily_limit = 8,
        },
        rewards = {
            money = { type = 'bank', min = 300, max = 600 },
            rep = { reporter = 30 },
        },
        steps = {
            {
                id = 'step_reach_newsroom',
                title = '前往新闻社',
                description = '前往洛圣都新闻社领取采访任务',
                type = 'reach',
                data = {
                    coords = { x = -600.0, y = -930.0, z = 23.0 },
                    radius = 10.0,
                },
            },
            {
                id = 'step_get_assignment',
                title = '领取采访任务',
                description = '从编辑处获取今日采访线索',
                type = 'interact',
                data = {
                    coords = { x = -600.0, y = -930.0, z = 23.0 },
                    radius = 5.0,
                    duration = 3000,
                    label = '领取采访任务...',
                },
            },
            {
                id = 'step_reach_scene',
                title = '前往现场',
                description = '驾车前往新闻事件现场',
                type = 'reach',
                data = {
                    coords = { x = 200.0, y = -900.0, z = 30.0 },
                    radius = 15.0,
                },
            },
            {
                id = 'step_take_photo',
                title = '拍摄照片',
                description = '在事件现场拍摄新闻照片',
                type = 'interact',
                data = {
                    coords = { x = 200.0, y = -900.0, z = 30.0 },
                    radius = 15.0,
                    duration = 4000,
                    label = '拍摄新闻照片...',
                },
            },
            {
                id = 'step_return_newsroom',
                title = '回社发稿',
                description = '返回新闻社提交稿件和照片',
                type = 'reach',
                data = {
                    coords = { x = -600.0, y = -930.0, z = 23.0 },
                    radius = 10.0,
                },
            },
            {
                id = 'step_submit',
                title = '提交稿件',
                description = '将照片和稿件提交给编辑',
                type = 'interact',
                data = {
                    coords = { x = -600.0, y = -930.0, z = 23.0 },
                    radius = 5.0,
                    duration = 3000,
                    label = '提交稿件...',
                },
            },
        },
    },

    -- ==========================================================
    -- 回收站工人 (Recycle/Scrapyard)
    -- ==========================================================
    {
        id = 'recycle_run',
        title = '废品回收',
        description = '前往城市各回收点收集可回收材料，运回回收站。',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 0,
            min_police = 0,
            daily_limit = 10,
        },
        rewards = {
            money = { type = 'bank', min = 200, max = 450 },
            items = { { name = 'plastic', count = 3 } },
            rep = { recycle = 25 },
        },
        steps = {
            {
                id = 'step_enter_truck',
                title = '进入回收车',
                description = '驾驶回收站的平板卡车',
                type = 'interact',
                data = {
                    coords = { x = 1039.0, y = -310.0, z = 59.0 },
                    radius = 10.0,
                    duration = 2000,
                    label = '启动回收车...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_pickup_one',
                title = '回收点 1/3',
                description = '停靠第一个废品回收点装货',
                type = 'interact',
                data = {
                    coords = { x = 1100.0, y = -400.0, z = 67.0 },
                    radius = 8.0,
                    duration = 4000,
                    label = '装载废品...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_pickup_two',
                title = '回收点 2/3',
                description = '停靠第二个废品回收点装货',
                type = 'interact',
                data = {
                    coords = { x = 1200.0, y = -500.0, z = 65.0 },
                    radius = 8.0,
                    duration = 4000,
                    label = '装载废品...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_pickup_three',
                title = '回收点 3/3',
                description = '停靠最后一个废品回收点装货',
                type = 'interact',
                data = {
                    coords = { x = 1300.0, y = -600.0, z = 65.0 },
                    radius = 8.0,
                    duration = 4000,
                    label = '装载废品...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_return_yard',
                title = '返回回收站',
                description = '满载而归，返回回收站卸货',
                type = 'reach',
                data = {
                    coords = { x = 1039.0, y = -310.0, z = 59.0 },
                    radius = 12.0,
                },
            },
        },
    },
}
