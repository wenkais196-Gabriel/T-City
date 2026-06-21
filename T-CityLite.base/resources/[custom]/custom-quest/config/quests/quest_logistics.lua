-- config/quests/quest_logistics.lua
-- 载具货运与运输任务配置文件 (v0.10)
--
-- ══════════════════════════════════════════════════════════════
-- v0.10: 挂车任务通用模式 (6 个任务已统一)
--
--   步骤模板（5步，无归还步骤）:
--     step_bind_*     [validator]    → 绑定拖头, 记录租赁状态(影响奖励扣减)
--     step_hook_*     [custom_event] → 生成挂车, 物理挂接, 注册到 QuestEntityRegistry
--     step_load_*     [interact]     → 装货动画
--     step_deliver_*  [validator]    → 运抵目的地 (require_trailer + 随机地址池)
--     step_unload_*   [placement]    → 卸货区自动脱钩 → 服务端位置验证 → 延迟回收 → 任务结束
--
--   placement 节点依赖:
--     客户端: client/quest_entity_placement.lua  — 可视化 + 自动检测 + 脱钩
--     服务端: server/quest_entity_placement.lua  — 回收区生成 + 位置验证 + 调度回收
--     注册表: server/quest_entity_registry.lua   — 实体生命周期 (on_leave 延迟回收)
--
--   与 v0.7a 的关键区别:
--     - 卸货步骤从 interact(detach_trailer) 改为 placement(action='detach_trailer')
--     - 去掉所有 step_return_* 归还步骤 (租赁载具由玩家自行归还)
--     - 货柜由 QuestEntityRegistry 管理生命周期 (on_leave: 玩家离开 50m 后自动回收)
--     - 回收区用纯数学偏移生成 (不依赖客户端 native)，半径统一 15m
--     - 奖励扣减: binding.isRental → QuestRewards.GrantRewards 自动扣除 rentalFeePct
-- ══════════════════════════════════════════════════════════════
--
-- 设计原则:
--   - 三级载具体系 (Grade C皮卡 / B箱货 / A半挂)，不同运费加成
--   - "三合一电子戳" 校验 (玩家CID + 车牌 + 货物)
--   - 不下车交互 (in_vehicle) + 物理挂车 (require_trailer)
--   - 非阻塞冷却 (cooldown=0，只防刷不阻碍)
--   - 租赁载具仅记录、不影响 quest 生命周期，抽成在结算时自动扣除

return {
    -- ==========================================================
    -- 任务 1：C级/B级 — 工业钢材配送
    -- ==========================================================
    {
        id = 'euro_trucking_steel',
        title = '工业钢材配送',
        description = '使用重载货车配送工业用高规格钢板。私家卡车全额收益，租车扣20%。',
        category = 'logistics',
        level = 1,
        required_tags = { role = 'unemployed' },  -- 平民通用标签（后续扩展多职业匹配）
        conditions = {
            cooldown_hours = 0,          -- 非阻塞，可连续接不同任务
            min_license = 'heavy',
        },
        vehicle_requirement = {
            allowed_classes = { 10, 11 },
            fallback_model = 'benson',
            rental_fee_percent = 20,
            rental_deposit = 500,
        },
        rewards = {
            money = { type = 'bank', min = 1500, max = 2500 },
            rep = { trucking = 50 },
        },
        steps = {
            {
                id = 'step_check_in',
                title = '绑定货运卡车',
                description = '开入码头装货圈，验证您的私家卡车，或在此处租车',
                type = 'validator',
                data = {
                    coords = { x = 900.0, y = -3150.0, z = 6.0 },
                    radius = 20.0,
                    duration = 3000,
                    label = '验证货运载具',
                    in_vehicle = true,
                    validator_id = 'validate_logistics_vehicle',
                    validator_data = {
                        allowed_classes = { 10, 11 },
                        fallback_model = 'benson',
                        rental_fee_percent = 20,
                        rental_deposit = 500,
                    },
                },
            },
            {
                id = 'step_load_cargo',
                title = '装载钢板',
                description = '将卡车倒回 A3 货位。坐在车内点击装货，挂载物理钢材Prop。',
                type = 'interact',
                data = {
                    coords = { x = 900.0, y = -3150.0, z = 6.0 },
                    radius = 15.0,
                    duration = 5000,
                    label = '起重机装货中...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                    attach_prop = {
                        model = 'prop_steel_crushed',
                        bone = 'boot',
                        offset = { x = 0.0, y = -1.5, z = 0.2 },
                    },
                },
            },
            {
                id = 'step_deliver',
                title = '运抵卸货区',
                description = '驾驶绑定的载具将货物运送到目的地',
                type = 'validator',
                data = {
                    address_pool = { pool = 'sandy_shores_rural', min_distance = 800, max_distance = 12000 },
                    radius = 8.0,
                    duration = 2000,
                    label = '电子戳校验中...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 0, y = 0, z = 0 },
                        use_bound_vehicle = true,
                    },
                },
            },
            {
                id = 'step_unload_cargo',
                title = '车内卸货',
                description = '保持停稳状态，在车内按住 E 键完成电子戳戳印与卸货',
                type = 'interact',
                data = {
                    coords = { x = 0, y = 0, z = 0 },
                    radius = 10.0,
                    duration = 4000,
                    label = '起重机卸货中...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                    remove_prop = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 2：A级重特大货运 — 工业桥梁箱梁挂车 (Grade A Semi-Truck)
    -- ==========================================================
    {
        id = 'euro_trucking_heavy_trailer',
        title = '重型桥梁箱梁挂载运输',
        description = '驾驶半挂车头（如 Phantom），挂接专用重型平底拖车，运送特大桥梁箱梁。',
        category = 'logistics',
        level = 3,
        required_tags = { role = 'unemployed' },  -- 平民通用标签
        conditions = {
            cooldown_hours = 0,
            min_license = 'heavy',
        },
        vehicle_requirement = {
            allowed_classes = { 10 },
            fallback_model = 'phantom',
            rental_fee_percent = 25,
            rental_deposit = 1200,
        },
        rewards = {
            money = { type = 'bank', min = 4000, max = 7000 },
            rep = { trucking = 120 },
        },
        -- v0.10: trailer 回收由 placement 节点 + QuestEntityRegistry (on_leave 延迟回收) 管理
        entity_tracking = {
            trailer = {
                bind_step = 'step_hook_trailer',
                release_step = 'step_unhook_trailer',
                detach_countdown_sec = 150,
            },
            truck = {
                bind_step = 'step_check_in',
                require_in_steps = { 'step_deliver_trailer' },
                exit_countdown_sec = 150,
            },
        },
        steps = {
            {
                id = 'step_check_in',
                title = '绑定重型拖头',
                description = '驾驶您的私家半挂拖车头进入验证区。或在此处租车。',
                type = 'validator',
                data = {
                    coords = { x = 900.0, y = -3150.0, z = 6.0 },
                    radius = 20.0,
                    duration = 3000,
                    label = '验证重型拖头',
                    in_vehicle = true,
                    validator_id = 'validate_logistics_vehicle',
                    validator_data = {
                        allowed_classes = { 10 },
                        fallback_model = 'phantom',
                        rental_fee_percent = 25,
                        rental_deposit = 1200,
                    },
                },
            },
            {
                id = 'step_hook_trailer',
                title = '挂接重型拖车斗',
                description = '拖车斗已放置在货场空地。请开车前往并倒车挂接。',
                type = 'custom_event',
                data = {
                    event_name = 'trailer_hooked',
                    trailer_model = 'trailerlogs',
                    spawn_coords = { x = 920.0, y = -3165.0, z = 6.0, heading = 180.0 },
                    backup_coords = {
                        { x = 935.0, y = -3165.0, z = 6.0, heading = 180.0 },
                        { x = 920.0, y = -3180.0, z = 6.0, heading = 180.0 },
                        { x = 905.0, y = -3165.0, z = 6.0, heading = 180.0 },
                    },
                },
            },
            {
                id = 'step_deliver_trailer',
                title = '重载运输到目的地',
                description = '拖带重型挂车平稳运往目的地，注意转弯盲区！',
                type = 'validator',
                data = {
                    address_pool = { pool = 'paleto_bay_north', min_distance = 2000, max_distance = 15000 },
                    radius = 12.0,
                    duration = 2000,
                    label = '脱钩交付校验中...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 0, y = 0, z = 0 },
                        use_bound_vehicle = true,
                        require_trailer = true,
                    },
                },
            },
            {
                id = 'step_unhook_trailer',
                title = '脱钩交货',
                description = '将挂车驶入绿色卸货区，系统自动脱钩回收。挂车将在你离开后消失。',
                type = 'placement',  -- v0.10: 卸货区自动脱钩 + 服务端验证 + on_leave 延迟回收
                data = {
                    dropzone = {
                        relative_to_step = 'step_deliver_trailer',
                        search_radius = { min = 15, max = 40 },
                        zone_radius = 15.0,
                    },
                    action = 'detach_trailer',
                    freeze_on_place = true,
                    invincible_on_place = true,
                    duration = 5000,
                    label = '脱钩交货中...',
                    in_vehicle = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 3：飞机版 — 走私飞行员
    -- ==========================================================
    {
        id = 'aviation_smuggling_flight',
        title = '走私飞行员',
        description = '驾驶货运飞机低空穿梭雷达网，运送科研设备。私家飞机获得 100% 收益。',
        category = 'logistics',
        level = 2,
        conditions = {
            cooldown_hours = 0,
            min_license = 'pilot',
        },
        rewards = {
            money = { type = 'bank', min = 3500, max = 6000 },
            rep = { aviation = 80 },
        },
        -- 实体追踪：低空飞行 + 送达阶段禁止离开载具，150 秒违规倒计时
        entity_tracking = {
            truck = {
                bind_step = 'step_validate_plane',
                require_in_steps = { 'step_low_flight', 'step_deliver_plane' },
                exit_countdown_sec = 150,
            },
        },
        steps = {
            {
                id = 'step_validate_plane',
                title = '确认货运飞机',
                description = '坐进货运飞机后，按 E 键验证载具。自有飞机享受 100% 收益。',
                type = 'validator',
                data = {
                    coords = { x = 1500.0, y = 3800.0, z = 35.0 },
                    radius = 30.0,
                    duration = 3000,
                    label = '验证货运飞机',
                    in_vehicle = true,
                    validator_id = 'validate_logistics_vehicle',
                    validator_data = {
                        allowed_classes = { 15, 16 },
                        fallback_model = 'duster',
                        rental_fee_percent = 25,
                        rental_deposit = 1000,
                    },
                },
            },
            {
                id = 'step_load_equipment',
                title = '装载敏感设备',
                description = '前往飞机货仓门旁边，按 E 键装载科研设备',
                type = 'interact',
                data = {
                    coords = { x = 1500.0, y = 3800.0, z = 35.0 },
                    radius = 15.0,
                    duration = 8000,
                    label = '装载科研设备箱',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_low_flight',
                title = '低空飞行越境',
                description = '保持飞行高度低于海平面 150 米，并在低空平稳飞满 45 秒以躲避雷达！',
                type = 'custom_event',
                data = {
                    event_name = 'aviation_height_monitor',
                    max_height = 60.0,
                    check_duration_sec = 45,
                },
            },
            {
                id = 'step_deliver_plane',
                title = '降落 Grapeseed 跑道',
                description = '驾驶绑定的货运飞机平稳降落在 Grapeseed 跑道并滑行至机坪。',
                type = 'validator',
                data = {
                    coords = { x = 2100.0, y = 4800.0, z = 41.0 },
                    radius = 20.0,
                    duration = 2000,
                    label = '送达校验中...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 2100.0, y = 4800.0, z = 41.0 },
                        use_bound_vehicle = true,
                    },
                    checkpoint = { type = 'cylinder', radius = 18.0, label = '🛬 走私降落点' },
                },
            },
            {
                id = 'step_unload_equipment',
                title = '卸载敏感设备',
                description = '前往飞机货架尾部，按 E 键拆卸并卸载设备箱，结算金币。',
                type = 'interact',
                data = {
                    coords = { x = 2100.0, y = 4800.0, z = 41.0 },
                    radius = 15.0,
                    duration = 6000,
                    label = '卸载设备箱',
                    in_vehicle = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 4：轻量化偷车与拆拆乐 (新手体验)
    -- ==========================================================
    {
        id = 'vehicle_chop_shop',
        title = '偷车与零件回收',
        description = '顺走一辆指定路边车并将其开到拆车厂进行零件拆解。',
        category = 'crime',
        level = 1,
        required_tags = { role = 'unemployed' },  -- 平民通用标签
        conditions = {
            cooldown_hours = 1,
            min_police = 0,
            daily_limit = 3,
        },
        rewards = {
            money = { type = 'cash', min = 600, max = 1200 },
            rep = { cartel = 10 },
        },
        steps = {
            {
                id = 'step_goto_car',
                title = '寻找目标车辆',
                description = '线人已将目标车辆标记在您的地图上，请前往停车地点。',
                type = 'reach',
                data = { coords = { x = -150.0, y = -1000.0, z = 27.0 }, radius = 15.0 },
            },
            {
                id = 'step_hotwire',
                title = '破解车载 ECU',
                description = '走到车辆身旁，使用电子工具破解中控锁获取点火授权',
                type = 'interact',
                data = {
                    coords = { x = -150.0, y = -1000.0, z = 27.0 },
                    radius = 5.0,
                    duration = 5000,
                    label = '破解车载 ECU 锁',
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_deliver_chop',
                title = '开回拆车厂',
                description = '避开警察，将这辆车安全开回南洛圣都拆车厂。',
                type = 'deliver',
                data = {
                    destCoords = { x = -480.0, y = -1700.0, z = 18.0 },
                    radius = 5.0,
                    label = '拆车厂',
                    vehicleModel = 'sentinel',
                },
            },
            {
                id = 'step_dismantle_door',
                title = '拆解主驾驶门',
                description = '使用电砂轮对车辆左前门进行气割，获取再生材料。',
                type = 'interact',
                data = {
                    coords = { x = -480.0, y = -1700.0, z = 18.0 },
                    radius = 5.0,
                    duration = 4000,
                    label = '气割主车门',
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_dismantle_crush',
                title = '粉碎车辆底盘',
                description = '操作吊机将剩余底盘送入粉碎机，结算报废钢材收益！',
                type = 'interact',
                data = {
                    coords = { x = -475.0, y = -1705.0, z = 18.0 },
                    radius = 5.0,
                    duration = 5000,
                    label = '启动金属粉碎机',
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
        },
    },

    -- ══════════════════════════════════════════════════════════
    -- 🚛 欧卡扩展 — 第 1 批：7 个新运输任务 (v0.8a)
    -- ══════════════════════════════════════════════════════════

    -- ==========================================================
    -- 任务 5：ADR 燃油运输 (Lv.4 — 危险品)
    -- ==========================================================
    {
        id = 'euro_fuel_tanker',
        title = 'ADR 燃油运输',
        description = '挂接油罐拖车从港口油库运送航空燃油至佩立托湾加油站。碰撞有泄漏风险，高回报！',
        category = 'logistics',
        level = 4,
        conditions = {
            cooldown_hours = 0,
            min_license = 'heavy',
        },
        vehicle_requirement = {
            allowed_classes = { 10 },
            fallback_model = 'phantom',
            rental_fee_percent = 25,
            rental_deposit = 1500,
        },
        rewards = {
            money = { type = 'bank', min = 5000, max = 8000 },
            rep = { trucking = 180 },
        },
        -- v0.8: 时效 + 货物损伤配置
        logistics_ext = {
            time_limit_min = 20,
            early_bonus_pct = 25,
            late_penalty_pct = 10,
            cargo_fragile = true,
            damage_max_penalty_pct = 30,
        },
        -- v0.10: trailer 回收由 placement 节点 + QuestEntityRegistry (on_leave 延迟回收) 管理
        entity_tracking = {
            trailer = {
                bind_step = 'step_hook_tanker_trailer',
                release_step = 'step_unload_fuel',
                detach_countdown_sec = 150,
            },
            truck = {
                bind_step = 'step_bind_tanker',
                require_in_steps = { 'step_deliver_fuel' },
                exit_countdown_sec = 150,
            },
        },
        steps = {
            {
                id = 'step_bind_tanker',
                title = '绑定油罐拖头',
                description = '驾驶半挂拖头进入港口油库验证区。自有拖头享受 100% 收益。',
                type = 'validator',
                data = {
                    coords = { x = 700.0, y = -2900.0, z = 6.0 },
                    radius = 25.0,
                    duration = 3000,
                    label = '验证油罐拖头',
                    in_vehicle = true,
                    validator_id = 'validate_logistics_vehicle',
                    validator_data = {
                        allowed_classes = { 10 },
                        fallback_model = 'phantom',
                        rental_fee_percent = 25,
                        rental_deposit = 1500,
                    },
                },
            },
            {
                id = 'step_hook_tanker_trailer',
                title = '挂接油罐拖车',
                description = '油罐拖车已放置在油库空地。请开车前往并倒车挂接。',
                type = 'custom_event',
                data = {
                    event_name = 'trailer_hooked',
                    trailer_model = 'tanker2',
                    spawn_coords = { x = 715.0, y = -2915.0, z = 6.0, heading = 135.0 },
                    backup_coords = {
                        { x = 730.0, y = -2915.0, z = 6.0, heading = 135.0 },
                        { x = 715.0, y = -2930.0, z = 6.0, heading = 135.0 },
                        { x = 700.0, y = -2915.0, z = 6.0, heading = 135.0 },
                    },
                },
            },
            {
                id = 'step_load_fuel',
                title = '装载航空燃油',
                description = '保持挂车连接，在装载区按 E 键灌注燃油',
                type = 'interact',
                data = {
                    coords = { x = 700.0, y = -2900.0, z = 6.0 },
                    radius = 18.0,
                    duration = 6000,
                    label = '灌注航空燃油中...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_deliver_fuel',
                title = '长途运抵目的地',
                description = '驾驶油罐车将燃油运往目的地。注意安全驾驶——碰撞会触发泄漏！',
                type = 'validator',
                data = {
                    address_pool = { pool = 'paleto_bay_north', min_distance = 3000, max_distance = 18000 },
                    radius = 12.0,
                    duration = 3000,
                    label = '油罐交付校验中...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 0, y = 0, z = 0 },
                        use_bound_vehicle = true,
                        require_trailer = true,
                    },
                },
            },
            {
                id = 'step_unload_fuel',
                title = '卸载燃油',
                description = '将油罐车驶入绿色卸油区，系统自动脱钩回收。油罐将在你离开后消失。',
                type = 'placement',  -- v0.10: 卸货区自动脱钩 + 服务端验证 + on_leave 延迟回收
                data = {
                    dropzone = {
                        relative_to_step = 'step_deliver_fuel',
                        search_radius = { min = 15, max = 40 },
                        zone_radius = 15.0,
                    },
                    action = 'detach_trailer',
                    freeze_on_place = true,
                    invincible_on_place = true,
                    duration = 5000,
                    label = '燃油卸载中...',
                    in_vehicle = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 6：集装箱港运 (Lv.2)
    -- ==========================================================
    {
        id = 'euro_container_haul',
        title = '集装箱港运',
        description = '从洛圣都港口挂接标准 40 英尺集装箱，运往内陆配送中心。目的地随机。',
        category = 'logistics',
        level = 2,
        conditions = {
            cooldown_hours = 0,
            min_license = 'heavy',
        },
        rewards = {
            money = { type = 'bank', min = 2500, max = 4000 },
            rep = { trucking = 80 },
        },
        logistics_ext = {
            time_limit_min = 15,
            early_bonus_pct = 15,
            late_penalty_pct = 8,
            cargo_fragile = false,
            damage_max_penalty_pct = 15,
        },
        -- v0.10: trailer 回收由 placement 节点 + QuestEntityRegistry (on_leave 延迟回收) 管理
        entity_tracking = {
            trailer = {
                bind_step = 'step_hook_container',
                release_step = 'step_unload_container',
                detach_countdown_sec = 150,
            },
            truck = {
                bind_step = 'step_bind_container',
                require_in_steps = { 'step_deliver_container' },
                exit_countdown_sec = 150,
            },
        },
        steps = {
            {
                id = 'step_bind_container',
                title = '绑定集装箱拖头',
                description = '驾驶半挂拖头进入港口堆场验证区。',
                type = 'validator',
                data = {
                    coords = { x = 800.0, y = -3100.0, z = 6.0 },
                    radius = 25.0,
                    duration = 3000,
                    label = '验证集装箱拖头',
                    in_vehicle = true,
                    validator_id = 'validate_logistics_vehicle',
                    validator_data = {
                        allowed_classes = { 10 },
                        fallback_model = 'phantom',
                        rental_fee_percent = 20,
                        rental_deposit = 800,
                    },
                },
            },
            {
                id = 'step_hook_container',
                title = '挂接集装箱拖车',
                description = '集装箱拖车已放置在堆场空地。请开车前往并倒车挂接。',
                type = 'custom_event',
                data = {
                    event_name = 'trailer_hooked',
                    trailer_model = 'trailers3',
                    spawn_coords = { x = 820.0, y = -3115.0, z = 6.0, heading = 90.0 },
                    backup_coords = {
                        { x = 835.0, y = -3115.0, z = 6.0, heading = 90.0 },
                        { x = 820.0, y = -3130.0, z = 6.0, heading = 90.0 },
                        { x = 805.0, y = -3115.0, z = 6.0, heading = 90.0 },
                    },
                },
            },
            {
                id = 'step_load_container',
                title = '装载集装箱铅封',
                description = '铅封集装箱并在车内按 E 键完成电子报关。',
                type = 'interact',
                data = {
                    coords = { x = 800.0, y = -3100.0, z = 6.0 },
                    radius = 15.0,
                    duration = 4000,
                    label = '铅封集装箱...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_deliver_container',
                title = '运抵内陆配送中心',
                description = '将集装箱安全送达内陆配送中心。',
                type = 'validator',
                data = {
                    address_pool = { pool = 'sandy_shores_rural', min_distance = 1000, max_distance = 12000 },
                    radius = 12.0,
                    duration = 2500,
                    label = '集装箱交付校验...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 0, y = 0, z = 0 },
                        use_bound_vehicle = true,
                        require_trailer = true,
                    },
                },
            },
            {
                id = 'step_unload_container',
                title = '卸柜交货',
                description = '将货柜驶入绿色卸柜区，系统自动脱钩回收。货柜将在你离开后消失。',
                type = 'placement',  -- v0.10: 卸货区自动脱钩 + 服务端验证 + on_leave 延迟回收
                data = {
                    dropzone = {
                        relative_to_step = 'step_deliver_container',
                        search_radius = { min = 15, max = 40 },
                        zone_radius = 15.0,
                    },
                    action = 'detach_trailer',
                    freeze_on_place = true,
                    invincible_on_place = true,
                    duration = 5000,
                    label = '卸柜交货中...',
                    in_vehicle = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 7：汽车运输专列 (Lv.3)
    -- ==========================================================
    {
        id = 'euro_car_transport',
        title = '汽车运输专列',
        description = '挂接双层汽车运输拖车，将 4 辆新车从洛圣都车仓送往北部经销商。目的地随机。',
        category = 'logistics',
        level = 3,
        conditions = {
            cooldown_hours = 0,
            min_license = 'heavy',
        },
        rewards = {
            money = { type = 'bank', min = 3500, max = 5500 },
            rep = { trucking = 120 },
        },
        logistics_ext = {
            time_limit_min = 18,
            early_bonus_pct = 20,
            late_penalty_pct = 10,
            cargo_fragile = true,
            damage_max_penalty_pct = 25,
        },
        -- v0.10: trailer 回收由 placement 节点 + QuestEntityRegistry (on_leave 延迟回收) 管理
        entity_tracking = {
            trailer = {
                bind_step = 'step_hook_car_trailer',
                release_step = 'step_unload_cars',
                detach_countdown_sec = 150,
            },
            truck = {
                bind_step = 'step_bind_transporter',
                require_in_steps = { 'step_deliver_cars' },
                exit_countdown_sec = 150,
            },
        },
        steps = {
            {
                id = 'step_bind_transporter',
                title = '绑定汽车运输拖头',
                description = '驾驶半挂拖头进入车仓验证区。',
                type = 'validator',
                data = {
                    coords = { x = 500.0, y = -2000.0, z = 20.0 },
                    radius = 25.0,
                    duration = 3000,
                    label = '验证运输拖头',
                    in_vehicle = true,
                    validator_id = 'validate_logistics_vehicle',
                    validator_data = {
                        allowed_classes = { 10 },
                        fallback_model = 'hauler',
                        rental_fee_percent = 22,
                        rental_deposit = 1000,
                    },
                },
            },
            {
                id = 'step_hook_car_trailer',
                title = '挂接汽车运输拖车',
                description = '双层汽车运输拖车已放置在车仓空地。请开车前往并倒车挂接。',
                type = 'custom_event',
                data = {
                    event_name = 'trailer_hooked',
                    trailer_model = 'tr2',
                    spawn_coords = { x = 515.0, y = -2015.0, z = 20.0, heading = 270.0 },
                    backup_coords = {
                        { x = 515.0, y = -2030.0, z = 20.0, heading = 270.0 },
                        { x = 530.0, y = -2015.0, z = 20.0, heading = 270.0 },
                        { x = 500.0, y = -2015.0, z = 20.0, heading = 270.0 },
                    },
                },
            },
            {
                id = 'step_load_cars',
                title = '装载新车',
                description = '4 辆新车依次驶上拖车。车内按 E 键完成固定。',
                type = 'interact',
                data = {
                    coords = { x = 500.0, y = -2000.0, z = 20.0 },
                    radius = 15.0,
                    duration = 6000,
                    label = '固定新车中...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_deliver_cars',
                title = '运抵经销商',
                description = '驾驶汽车运输车将新车送达经销商。目的地随机。转弯注意车身长度！',
                type = 'validator',
                data = {
                    address_pool = { pool = 'paleto_bay_north', min_distance = 1000, max_distance = 10000 },
                    radius = 12.0,
                    duration = 2500,
                    label = '车辆交付校验...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 0, y = 0, z = 0 },
                        use_bound_vehicle = true,
                        require_trailer = true,
                    },
                },
            },
            {
                id = 'step_unload_cars',
                title = '卸载新车',
                description = '将运输车驶入绿色卸车区，系统自动脱钩回收。挂车将在你离开后消失。',
                type = 'placement',  -- v0.10: 卸货区自动脱钩 + 服务端验证 + on_leave 延迟回收
                data = {
                    dropzone = {
                        relative_to_step = 'step_deliver_cars',
                        search_radius = { min = 15, max = 40 },
                        zone_radius = 15.0,
                    },
                    action = 'detach_trailer',
                    freeze_on_place = true,
                    invincible_on_place = true,
                    duration = 5000,
                    label = '新车卸载中...',
                    in_vehicle = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 8：冷链生鲜配送 (Lv.2 — 时效敏感)
    -- ==========================================================
    {
        id = 'euro_refrigerated',
        title = '冷链生鲜配送',
        description = '驾驶冷藏箱货从洛圣都码头冷库运送进口生鲜。超时贬值！目的地随机。',
        category = 'logistics',
        level = 2,
        conditions = {
            cooldown_hours = 0,
            min_license = 'driver',
        },
        rewards = {
            money = { type = 'bank', min = 2000, max = 3500 },
            rep = { trucking = 60 },
        },
        logistics_ext = {
            time_limit_min = 15,
            early_bonus_pct = 30,
            late_penalty_pct = 15,
            cargo_fragile = true,
            damage_max_penalty_pct = 20,
        },
        steps = {
            {
                id = 'step_bind_reefer',
                title = '绑定冷藏箱货',
                description = '驾驶冷藏箱货进入码头冷库验证区。',
                type = 'validator',
                data = {
                    coords = { x = 1000.0, y = -3000.0, z = 6.0 },
                    radius = 20.0,
                    duration = 3000,
                    label = '验证冷藏箱货',
                    in_vehicle = true,
                    validator_id = 'validate_logistics_vehicle',
                    validator_data = {
                        allowed_classes = { 10, 11 },
                        fallback_model = 'benson',
                        rental_fee_percent = 18,
                        rental_deposit = 500,
                    },
                },
            },
            {
                id = 'step_load_produce',
                title = '装载进口生鲜',
                description = '在冷库装载区按 E 键装载温控生鲜货物。',
                type = 'interact',
                data = {
                    coords = { x = 1000.0, y = -3000.0, z = 6.0 },
                    radius = 15.0,
                    duration = 5000,
                    label = '装载温控货物...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_deliver_produce',
                title = '急送葡萄籽镇',
                description = '⏱ 时效运输！15 分钟内送达葡萄籽镇农贸市场。超时将逐分钟扣款！',
                type = 'validator',
                data = {
                    coords = { x = 2100.0, y = 4800.0, z = 41.0 },
                    radius = 10.0,
                    duration = 2000,
                    label = '生鲜交付校验...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 2100.0, y = 4800.0, z = 41.0 },
                        use_bound_vehicle = true,
                    },
                },
            },
            {
                id = 'step_unload_produce',
                title = '卸货签收',
                description = '车内按 E 键完成卸货与冷链签收单。',
                type = 'interact',
                data = {
                    coords = { x = 2100.0, y = 4800.0, z = 41.0 },
                    radius = 10.0,
                    duration = 4000,
                    label = '卸货签收中...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_return_reefer',
                title = '归还租赁箱货',
                description = '租用箱货开回码头退押金，私家车直接完成。',
                type = 'validator',
                data = {
                    coords = { x = 970.0, y = -3050.0, z = 6.0 },
                    radius = 15.0,
                    duration = 3000,
                    label = '归还租赁箱货',
                    in_vehicle = true,
                    validator_id = 'validate_rental_cleanup',
                    validator_data = {
                        returnCoords = { x = 970.0, y = -3050.0, z = 6.0 },
                    },
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 9：超大件工程运输 (Lv.5 — 最高难度)
    -- ==========================================================
    {
        id = 'euro_oversized_construction',
        title = '超大件工程运输',
        description = '挂接重型平板拖车，运送特大桥梁预制梁段至山区水坝工地。需要警车护送。',
        category = 'logistics',
        level = 5,
        conditions = {
            cooldown_hours = 0,
            min_license = 'heavy',
        },
        rewards = {
            money = { type = 'bank', min = 7000, max = 12000 },
            rep = { trucking = 250 },
        },
        logistics_ext = {
            time_limit_min = 25,
            early_bonus_pct = 20,
            late_penalty_pct = 10,
            cargo_fragile = true,
            damage_max_penalty_pct = 35,
        },
        -- v0.10: trailer 回收由 placement 节点 + QuestEntityRegistry (on_leave 延迟回收) 管理
        entity_tracking = {
            trailer = {
                bind_step = 'step_hook_oversized_trailer',
                release_step = 'step_unload_beam',
                detach_countdown_sec = 150,
            },
            truck = {
                bind_step = 'step_bind_oversized',
                require_in_steps = { 'step_deliver_beam' },
                exit_countdown_sec = 150,
            },
        },
        steps = {
            {
                id = 'step_bind_oversized',
                title = '绑定重型拖头',
                description = '驾驶半挂拖头进入市区工场验证区。自有拖头享受 100% 收益。',
                type = 'validator',
                data = {
                    coords = { x = 600.0, y = -200.0, z = 35.0 },
                    radius = 25.0,
                    duration = 3000,
                    label = '验证重型拖头',
                    in_vehicle = true,
                    validator_id = 'validate_logistics_vehicle',
                    validator_data = {
                        allowed_classes = { 10 },
                        fallback_model = 'phantom',
                        rental_fee_percent = 28,
                        rental_deposit = 2000,
                    },
                },
            },
            {
                id = 'step_hook_oversized_trailer',
                title = '挂接超大件平板拖车',
                description = '重型平板拖车已放置在工场空地。请开车前往并倒车挂接。',
                type = 'custom_event',
                data = {
                    event_name = 'trailer_hooked',
                    trailer_model = 'trailers3',
                    spawn_coords = { x = 615.0, y = -215.0, z = 35.0, heading = 225.0 },
                    backup_coords = {
                        { x = 600.0, y = -215.0, z = 35.0, heading = 225.0 },
                        { x = 615.0, y = -230.0, z = 35.0, heading = 225.0 },
                        { x = 630.0, y = -215.0, z = 35.0, heading = 225.0 },
                    },
                },
            },
            {
                id = 'step_load_beam',
                title = '吊装桥梁预制梁段',
                description = '起重机吊装 40 米预制梁段到平板拖车上。车内按 E 键固定。',
                type = 'interact',
                data = {
                    coords = { x = 600.0, y = -200.0, z = 35.0 },
                    radius = 18.0,
                    duration = 8000,
                    label = '吊装固定梁段中...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_deliver_beam',
                title = '重载运输到山区工地',
                description = '拖带 80 吨超大件运往山区工地。目的地随机。限速行驶，注意转弯！',
                type = 'validator',
                data = {
                    address_pool = { pool = 'sandy_shores_rural', min_distance = 3000, max_distance = 15000 },
                    radius = 15.0,
                    duration = 3000,
                    label = '超大件交付校验...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 0, y = 0, z = 0 },
                        use_bound_vehicle = true,
                        require_trailer = true,
                    },
                },
            },
            {
                id = 'step_unload_beam',
                title = '脱钩交货',
                description = '将超大件拖车驶入绿色卸货区，系统自动脱钩回收。挂车将在你离开后消失。',
                type = 'placement',  -- v0.10: 卸货区自动脱钩 + 服务端验证 + on_leave 延迟回收
                data = {
                    dropzone = {
                        relative_to_step = 'step_deliver_beam',
                        search_radius = { min = 15, max = 40 },
                        zone_radius = 15.0,
                    },
                    action = 'detach_trailer',
                    freeze_on_place = true,
                    invincible_on_place = true,
                    duration = 6000,
                    label = '脱钩验收中...',
                    in_vehicle = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 10：原木山运 (Lv.2 — 自然风光路线)
    -- ==========================================================
    {
        id = 'euro_timber_haul',
        title = '原木山运',
        description = '从佩立托森林锯木厂挂接原木拖车运送木材。目的地随机。',
        category = 'logistics',
        level = 2,
        conditions = {
            cooldown_hours = 0,
            min_license = 'heavy',
        },
        rewards = {
            money = { type = 'bank', min = 2200, max = 3800 },
            rep = { trucking = 70 },
        },
        logistics_ext = {
            time_limit_min = 18,
            early_bonus_pct = 15,
            late_penalty_pct = 8,
            cargo_fragile = false,
            damage_max_penalty_pct = 15,
        },
        -- v0.10: trailer 回收由 placement 节点 + QuestEntityRegistry (on_leave 延迟回收) 管理
        entity_tracking = {
            trailer = {
                bind_step = 'step_hook_timber_trailer',
                release_step = 'step_unload_timber',
                detach_countdown_sec = 150,
            },
            truck = {
                bind_step = 'step_bind_timber',
                require_in_steps = { 'step_deliver_timber' },
                exit_countdown_sec = 150,
            },
        },
        steps = {
            {
                id = 'step_bind_timber',
                title = '绑定原木拖头',
                description = '驾驶半挂拖头进入锯木厂验证区。',
                type = 'validator',
                data = {
                    coords = { x = -600.0, y = 5600.0, z = 30.0 },
                    radius = 25.0,
                    duration = 3000,
                    label = '验证原木拖头',
                    in_vehicle = true,
                    validator_id = 'validate_logistics_vehicle',
                    validator_data = {
                        allowed_classes = { 10 },
                        fallback_model = 'phantom',
                        rental_fee_percent = 20,
                        rental_deposit = 800,
                    },
                },
            },
            {
                id = 'step_hook_timber_trailer',
                title = '挂接原木拖车',
                description = '原木拖车已放置在锯木厂空地。请开车前往并倒车挂接。',
                type = 'custom_event',
                data = {
                    event_name = 'trailer_hooked',
                    trailer_model = 'trailerlogs',
                    spawn_coords = { x = -585.0, y = 5615.0, z = 30.0, heading = 45.0 },
                    backup_coords = {
                        { x = -570.0, y = 5615.0, z = 30.0, heading = 45.0 },
                        { x = -585.0, y = 5600.0, z = 30.0, heading = 45.0 },
                        { x = -600.0, y = 5615.0, z = 30.0, heading = 45.0 },
                    },
                },
            },
            {
                id = 'step_load_timber',
                title = '捆扎原木',
                description = '车内按 E 键完成原木捆扎与安全检查。',
                type = 'interact',
                data = {
                    coords = { x = -600.0, y = 5600.0, z = 30.0 },
                    radius = 15.0,
                    duration = 4000,
                    label = '捆扎原木中...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_deliver_timber',
                title = '运抵洛圣都港口',
                description = '沿山路将原木运往洛圣都港口集装箱码头。',
                type = 'validator',
                data = {
                    address_pool = { pool = 'port_logistics', min_distance = 1500, max_distance = 12000 },
                    radius = 12.0,
                    duration = 2500,
                    label = '原木交付校验...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 0, y = 0, z = 0 },
                        use_bound_vehicle = true,
                        require_trailer = true,
                    },
                },
            },
            {
                id = 'step_unload_timber',
                title = '卸木交货',
                description = '将原木拖车驶入绿色卸货区，系统自动脱钩回收。挂车将在你离开后消失。',
                type = 'placement',  -- v0.10: 卸货区自动脱钩 + 服务端验证 + on_leave 延迟回收
                data = {
                    dropzone = {
                        relative_to_step = 'step_deliver_timber',
                        search_radius = { min = 15, max = 40 },
                        zone_radius = 15.0,
                    },
                    action = 'detach_trailer',
                    freeze_on_place = true,
                    invincible_on_place = true,
                    duration = 5000,
                    label = '卸木报关中...',
                    in_vehicle = true,
                },
            },
        },
    },

    -- ==========================================================
    -- 任务 11：多站经停快递 (Lv.1 — 新手入门)
    -- 坐标来源: qb-shops GO Postal HQ (69.09,127.68,79.21) + dream-postal 真实送件点
    -- ==========================================================
    {
        id = 'euro_multi_stop_courier',
        title = '多站经停快递',
        description = '从好麦坞 GO Postal 总部出发，经 Alta→Pillbox→Mission Row 三站送达。新手入门。',
        category = 'logistics',
        level = 1,
        required_tags = { role = 'unemployed' },
        conditions = {
            cooldown_hours = 0,
            min_license = 'driver',
        },
        vehicle_requirement = {
            allowed_classes = { 10, 11 },
            fallback_model = 'boxville',
            rental_fee_percent = 10,
            rental_deposit = 300,
        },
        rewards = {
            money = { type = 'bank', min = 1000, max = 2000 },
            rep = { trucking = 30 },
        },
        logistics_ext = {
            time_limit_min = 20,
            early_bonus_pct = 10,
            late_penalty_pct = 5,
            cargo_fragile = false,
            damage_max_penalty_pct = 10,
        },
        steps = {
            {
                id = 'step_bind_courier',
                title = '绑定快递箱货',
                description = '驾驶箱式货车进入好麦坞 GO Postal 总部验证区。新手建议租车起步。',
                type = 'validator',
                data = {
                    coords = { x = 69.09, y = 127.68, z = 79.21 },
                    radius = 20.0,
                    duration = 3000,
                    label = '验证箱式货车',
                    in_vehicle = true,
                    validator_id = 'validate_logistics_vehicle',
                    validator_data = {
                        allowed_classes = { 10, 11 },
                        fallback_model = 'boxville',
                        rental_fee_percent = 10,
                        rental_deposit = 300,
                    },
                },
            },
            {
                id = 'step_load_parcels',
                title = '装载快递包裹',
                description = '在 GO Postal 装载区按 E 键装载三站快递包裹。',
                type = 'interact',
                data = {
                    coords = { x = 69.09, y = 127.68, z = 79.21 },
                    radius = 15.0,
                    duration = 4000,
                    label = '装载快递包裹...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_stop_1',
                title = '第一站：Alta 公寓区',
                description = '送达 Alta 街区收件人 (近军团广场)',
                type = 'validator',
                data = {
                    coords = { x = 207.21, y = -85.17, z = 69.17 },
                    radius = 8.0,
                    duration = 2000,
                    label = 'Alta 签收中...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 207.21, y = -85.17, z = 69.17 },
                        use_bound_vehicle = true,
                    },
                },
            },
            {
                id = 'step_drop_1',
                title = '卸货第一站',
                description = '车内按 E 键完成 Alta 区卸货。',
                type = 'interact',
                data = {
                    coords = { x = 207.21, y = -85.17, z = 69.17 },
                    radius = 8.0,
                    duration = 3000,
                    label = 'Alta 卸货...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_stop_2',
                title = '第二站：Pillbox Hill 诊所',
                description = '送达 Pillbox Hill 医疗区收件人 (近中央医院)',
                type = 'validator',
                data = {
                    coords = { x = 319.95, y = -121.57, z = 68.35 },
                    radius = 8.0,
                    duration = 2000,
                    label = 'Pillbox 签收中...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 319.95, y = -121.57, z = 68.35 },
                        use_bound_vehicle = true,
                    },
                },
            },
            {
                id = 'step_drop_2',
                title = '卸货第二站',
                description = '车内按 E 键完成 Pillbox Hill 卸货。',
                type = 'interact',
                data = {
                    coords = { x = 319.95, y = -121.57, z = 68.35 },
                    radius = 8.0,
                    duration = 3000,
                    label = 'Pillbox 卸货...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_stop_3',
                title = '第三站：Mission Row 警局区',
                description = '送达 Mission Row 写字楼收件人 (近洛圣都警局总部)',
                type = 'validator',
                data = {
                    coords = { x = 330.25, y = -202.46, z = 54.09 },
                    radius = 8.0,
                    duration = 2000,
                    label = 'Mission Row 签收中...',
                    in_vehicle = true,
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 330.25, y = -202.46, z = 54.09 },
                        use_bound_vehicle = true,
                    },
                },
            },
            {
                id = 'step_drop_3',
                title = '卸货最后一站',
                description = '车内按 E 键完成最后一站卸货，返回 GO Postal 总部。',
                type = 'interact',
                data = {
                    coords = { x = 330.25, y = -202.46, z = 54.09 },
                    radius = 8.0,
                    duration = 3000,
                    label = 'Mission Row 卸货...',
                    in_vehicle = true,
                    animDict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
                    animName = 'machinic_loop_mechandplayer',
                },
            },
            {
                id = 'step_return_courier',
                title = '返回 GO Postal 总部',
                description = '驶回好麦坞 GO Postal 总部签退。租用车辆在此退还。',
                type = 'validator',
                data = {
                    coords = { x = 69.09, y = 127.68, z = 79.21 },
                    radius = 15.0,
                    duration = 3000,
                    label = '归还租赁箱货',
                    in_vehicle = true,
                    validator_id = 'validate_rental_cleanup',
                    validator_data = {
                        returnCoords = { x = 69.09, y = 127.68, z = 79.21 },
                    },
                },
            },
        },
    },
}
