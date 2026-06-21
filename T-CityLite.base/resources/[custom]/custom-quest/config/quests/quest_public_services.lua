-- config/quests/quest_public_services.lua
-- 🏙️ 轻量化公共服务任务 (P2/Stage 4) — 基于 custom-quest 状态机
--
-- 替代原 qb-taxijob / qb-busjob / qb-towjob / qb-garbagejob 的臃肿客户端轮询
-- 全部使用 reach → interact → deliver 原子步骤, 零轮询, 数据驱动
--
-- 设计原则:
--   - GPS Waypoint 打卡代替原生客户端 Tick
--   - 步骤严格顺序执行 (EnforceStepOrder)
--   - 物理物品收集与交付验证
--   - 非阻塞冷却 (cooldown=0, 只防刷不阻碍)

return {
    -- ==========================================================
    -- 任务 1：出租车司机 (Taxi)
    -- ==========================================================
    {
        id = 'taxi_fare',
        title = '出租车载客',
        description = '驾驶出租车前往接客点，将乘客安全送达目的地。',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 0,
            min_police = 0,
            daily_limit = 20,
        },
        rewards = {
            money = { type = 'bank', min = 200, max = 500 },
            rep = { taxi = 30 },
        },
        steps = {
            {
                id = 'step_pickup',
                title = '前往接客点',
                description = '驾驶出租车前往乘客等候位置',
                type = 'reach',
                data = {
                    coords = { x = 200.0, y = -1000.0, z = 29.0 },
                    radius = 10.0,
                },
            },
            {
                id = 'step_load_passenger',
                title = '载客',
                description = '按喇叭示意乘客上车（在接客点停留3秒）',
                type = 'interact',
                data = {
                    coords = { x = 200.0, y = -1000.0, z = 29.0 },
                    radius = 10.0,
                    duration = 3000,
                    label = '等待乘客上车...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_deliver_passenger',
                title = '送达目的地',
                description = '安全驾驶将乘客送达目的地',
                type = 'reach',
                data = {
                    coords = { x = -300.0, y = -900.0, z = 31.0 },
                    radius = 10.0,
                },
            },
            {
                id = 'step_dropoff',
                title = '乘客下车',
                description = '停稳车辆，乘客下车并支付车费',
                type = 'interact',
                data = {
                    coords = { x = -300.0, y = -900.0, z = 31.0 },
                    radius = 10.0,
                    duration = 2000,
                    label = '等待付款...',
                    in_vehicle = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 2：公交司机 (Bus)
    -- ==========================================================
    {
        id = 'bus_route',
        title = '公交线路运营',
        description = '驾驶公交沿指定线路运行，在公交站打卡上下客。',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 0,
            min_police = 0,
            daily_limit = 10,
        },
        rewards = {
            money = { type = 'bank', min = 300, max = 600 },
            rep = { bus = 40 },
        },
        steps = {
            {
                id = 'step_enter_bus',
                title = '进入公交车',
                description = '坐进公交公司的巴士，准备发车',
                type = 'interact',
                data = {
                    coords = { x = 430.0, y = -650.0, z = 28.0 },
                    radius = 10.0,
                    duration = 2000,
                    label = '准备发车...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_stop_one',
                title = '车站 1/3：市中心',
                description = '停靠市中心站，等待乘客上下车',
                type = 'reach',
                data = {
                    coords = { x = 300.0, y = -600.0, z = 29.0 },
                    radius = 12.0,
                },
            },
            {
                id = 'step_stop_two',
                title = '车站 2/3：商业区',
                description = '停靠商业区站，等待乘客上下车',
                type = 'reach',
                data = {
                    coords = { x = 100.0, y = -700.0, z = 29.0 },
                    radius = 12.0,
                },
            },
            {
                id = 'step_stop_three',
                title = '车站 3/3：居民区',
                description = '停靠居民区终点站，完成本趟运营',
                type = 'interact',
                data = {
                    coords = { x = -100.0, y = -800.0, z = 29.0 },
                    radius = 12.0,
                    duration = 3000,
                    label = '终点站停靠...',
                    in_vehicle = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 3：拖车司机 (Tow)
    -- ==========================================================
    {
        id = 'tow_service',
        title = '违章拖车',
        description = '驾驶拖车前往违章停车点，将车辆拖回扣押场。',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 0,
            min_police = 0,
            daily_limit = 15,
        },
        rewards = {
            money = { type = 'bank', min = 400, max = 800 },
            rep = { tow = 35 },
        },
        steps = {
            {
                id = 'step_enter_towtruck',
                title = '进入拖车',
                description = '驾驶拖车准备出任务',
                type = 'interact',
                data = {
                    coords = { x = 500.0, y = -1500.0, z = 29.0 },
                    radius = 10.0,
                    duration = 2000,
                    label = '启动拖车...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_reach_vehicle',
                title = '前往违章车辆',
                description = '驾驶拖车到达违章停车位置',
                type = 'reach',
                data = {
                    coords = { x = 400.0, y = -1100.0, z = 29.0 },
                    radius = 15.0,
                },
            },
            {
                id = 'step_hook_vehicle',
                title = '挂接车辆',
                description = '操作拖车吊臂挂接违章车辆',
                type = 'interact',
                data = {
                    coords = { x = 400.0, y = -1100.0, z = 29.0 },
                    radius = 8.0,
                    duration = 5000,
                    label = '吊臂挂接中...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_deliver_impound',
                title = '拖回扣押场',
                description = '将违章车辆拖回市扣押场',
                type = 'reach',
                data = {
                    coords = { x = 436.0, y = -1007.0, z = 27.0 },
                    radius = 12.0,
                },
            },
            {
                id = 'step_unhook',
                title = '卸车入库',
                description = '在扣押场完成卸车入库',
                type = 'interact',
                data = {
                    coords = { x = 436.0, y = -1007.0, z = 27.0 },
                    radius = 8.0,
                    duration = 4000,
                    label = '卸车入库...',
                    in_vehicle = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 4：环卫工人 (Garbage)
    -- ==========================================================
    {
        id = 'garbage_collection',
        title = '垃圾收集',
        description = '驾驶垃圾车沿收运路线收集垃圾袋。',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 0,
            min_police = 0,
            daily_limit = 12,
        },
        rewards = {
            money = { type = 'bank', min = 250, max = 500 },
            rep = { garbage = 25 },
        },
        steps = {
            {
                id = 'step_enter_garbage_truck',
                title = '进入垃圾车',
                description = '坐进环卫局的垃圾收集车',
                type = 'interact',
                data = {
                    coords = { x = -350.0, y = -1550.0, z = 25.0 },
                    radius = 10.0,
                    duration = 2000,
                    label = '启动垃圾车...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_collect_one',
                title = '收集点 1/3',
                description = '停靠第一个垃圾收集点',
                type = 'interact',
                data = {
                    coords = { x = -300.0, y = -1450.0, z = 25.0 },
                    radius = 10.0,
                    duration = 4000,
                    label = '收集垃圾袋...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_collect_two',
                title = '收集点 2/3',
                description = '停靠第二个垃圾收集点',
                type = 'interact',
                data = {
                    coords = { x = -200.0, y = -1400.0, z = 25.0 },
                    radius = 10.0,
                    duration = 4000,
                    label = '收集垃圾袋...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_collect_three',
                title = '收集点 3/3',
                description = '停靠最后一个收集点',
                type = 'interact',
                data = {
                    coords = { x = -100.0, y = -1350.0, z = 25.0 },
                    radius = 10.0,
                    duration = 4000,
                    label = '收集垃圾袋...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_dump',
                title = '倾倒垃圾',
                description = '前往垃圾处理场完成倾倒',
                type = 'reach',
                data = {
                    coords = { x = -600.0, y = -1600.0, z = 20.0 },
                    radius = 15.0,
                },
            },
        },
    },
}
