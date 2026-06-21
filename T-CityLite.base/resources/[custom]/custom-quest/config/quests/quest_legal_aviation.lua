-- config/quests/quest_legal_aviation.lua
-- ✈️ 合法民航运输任务 v0.11 — Mixed 航空模式
--
-- aviation_type='mixed': 根据玩家驾驶的载具自动选择 airport 或 helipad 路线
--   固定翼 (class 15-16): 跑道机场起降 + 高空 ring 航路点
--   直升机 (class 17-19): 停机坪起降 + 低空 cylinder 引导点
--
-- 要求: 飞行执照 (pilot)

return {
    -- ==========================================================
    -- 医疗物资运输 (Mixed — 飞机/直升机双路线)
    -- ==========================================================
    {
        id = 'aviation_medical_airlift',
        title = '医疗物资运输',
        description = '运送急救药品和医疗设备。固定翼走高空航线，直升机直飞楼顶。',
        category = 'logistics',
        level = 1,
        required_tags = { role = 'unemployed' },
        conditions = {
            cooldown_hours = 0,
            min_license = 'pilot',
        },

        -- v0.11: Mixed 航空路线表
        -- TriggerQuest 时根据玩家实际驾驶的载具 class 匹配对应路线
        aviation_routes = {
            ------------------------------------------------------------------
            -- 固定翼路线: 跑道机场 → 高空航线 → 跑道机场
            ------------------------------------------------------------------
            airplane = {
                vehicle_classes = { 15, 16 },  -- Planes (hash fallback 兼容)
                same_airport_allowed = false,   -- 禁止 LSIA→LSIA 同机场互飞
                departure = { pool = 'aviation_airports' },
                arrival   = { pool = 'aviation_airports' },
                -- 动态航路: pct=沿dep→arr比例, alt=绝对海拔
                -- 爬升(20%,300m) → 巡航(50%,300m) → 下降(80%,80m)
                waypoints = {
                    { pct = 0.20, alt = 300.0, checkpoint = { type = 'ring', radius = 35.0, height_tolerance = 60.0, label = '🛫 爬升航路点' } },
                    { pct = 0.50, alt = 300.0, checkpoint = { type = 'ring', radius = 40.0, height_tolerance = 60.0, label = '🛩️ 巡航中点' } },
                    { pct = 0.80, alt = 80.0,  checkpoint = { type = 'ring', radius = 30.0, height_tolerance = 50.0, label = '⬇️ 下降进场' } },
                },
                rewards = {
                    money = { type = 'bank', min = 2000, max = 3500 },
                    rep = { aviation = 40 },
                },
            },

            ------------------------------------------------------------------
            -- 直升机路线: 公共停机坪 → 短程低空 → 医院楼顶
            ------------------------------------------------------------------
            helicopter = {
                vehicle_classes = { 17, 18, 19 },  -- Helicopters (hash fallback 兼容)
                same_airport_allowed = true,        -- 直升机允许短距跳点
                departure = { pool = 'aviation_helipads', filter = { type = 'public' } },
                arrival   = { pool = 'aviation_helipads', filter = { type = 'hospital' } },
                -- 动态航路: 出航(25%,80m) → 进场(60%,60m) → 着陆(arr.z+5,85%)
                waypoints = {
                    { pct = 0.25, alt = 80.0,  checkpoint = { type = 'cylinder', radius = 25.0, height_tolerance = 40.0, label = '🏙️ 市区低空引导点' } },
                    { pct = 0.60, alt = 60.0,  checkpoint = { type = 'cylinder', radius = 20.0, height_tolerance = 35.0, label = '🏥 医院进场点' } },
                    { pct = 0.85, alt = -1.0,  checkpoint = { type = 'cylinder', radius = 15.0, height_tolerance = 25.0, label = '🚁 楼顶着陆区' } },
                },
                rewards = {
                    money = { type = 'bank', min = 1200, max = 2200 },
                    rep = { aviation = 25 },
                },
            },
        },

        -- 默认奖励（路由选择后会覆盖）
        rewards = {
            money = { type = 'bank', min = 2000, max = 3500 },
            rep = { aviation = 40 },
        },

        -- ══════════════════════════════════════════════════════
        -- 共享步骤（坐标在 TriggerQuest 时由路由注入）
        -- ══════════════════════════════════════════════════════
        steps = {
            -- 1. 绑定载具 (departure 坐标注入)
            {
                id = 'step_validate_plane',
                title = '确认航空载具',
                description = '驾驶飞机/直升机进入验证区。自有载具享受全额收益，租用则扣除手续费。',
                type = 'validator',
                data = {
                    coords = { x = -1150.0, y = -2650.0, z = 13.0 },  -- 默认 LSIA，路由注入覆盖
                    radius = 25.0,
                    duration = 3000,
                    label = '验证航空载具',
                    in_vehicle = true,
                    validator_id = 'validate_logistics_vehicle',
                    validator_data = {
                        allowed_classes = { 15, 16, 17, 18, 19 },  -- mixed: 全类型通过，路由注入缩小范围
                        fallback_model = 'duster',
                        rental_fee_percent = 15,
                        rental_deposit = 500,
                    },
                },
            },
            -- 2. 装载物资
            {
                id = 'step_load_medical',
                title = '装载医疗物资',
                description = '前往货仓装载急救药品和医疗设备',
                type = 'interact',
                data = {
                    coords = { x = -1150.0, y = -2650.0, z = 13.0 },  -- 装载点在 departure 附近(自动跟随)
                    radius = 15.0,
                    duration = 6000,
                    label = '装载医疗物资箱...',
                    in_vehicle = true,
                },
            },
            -- 3. 航路点 1 (路由注入)
            {
                id = 'step_climb_cruise',
                title = '航路引导 1/3',
                description = '跟随航路指引飞往第一个引导点',
                type = 'reach',
                data = {
                    coords = { x = -1000.0, y = -2400.0, z = 300.0 },  -- 默认高空，路由注入覆盖
                    radius = 50.0,
                    checkpoint = { type = 'ring', radius = 35.0, height_tolerance = 60.0, label = '航路点 1/3' },
                },
            },
            -- 4. 航路点 2 (路由注入)
            {
                id = 'step_cruise_mid',
                title = '航路引导 2/3',
                description = '飞往第二个引导点',
                type = 'reach',
                data = {
                    coords = { x = 1200.0, y = 2800.0, z = 300.0 },
                    radius = 60.0,
                    checkpoint = { type = 'ring', radius = 40.0, height_tolerance = 60.0, label = '航路点 2/3' },
                },
            },
            -- 5. 航路点 3 (路由注入)
            {
                id = 'step_descent_approach',
                title = '航路引导 3/3',
                description = '飞往最后一个引导点，准备降落',
                type = 'reach',
                data = {
                    coords = { x = 1900.0, y = 4200.0, z = 80.0 },
                    radius = 40.0,
                    checkpoint = { type = 'ring', radius = 30.0, height_tolerance = 50.0, label = '航路点 3/3' },
                },
            },
            -- 6. 送达目的地 (arrival 坐标注入)
            {
                id = 'step_land_grapeseed',
                title = '降落送达',
                description = '平稳降落在目的地并滑行至卸货区',
                type = 'validator',
                data = {
                    coords = { x = 2100.0, y = 4800.0, z = 41.0 },  -- 默认 Grapeseed，路由注入覆盖
                    radius = 20.0,
                    duration = 2000,
                    label = '送达校验中...',
                    in_vehicle = true,
                    checkpoint = { type = 'cylinder', radius = 18.0, label = '🛬 降落点' },
                    validator_id = 'validate_delivery_arrival',
                    validator_data = {
                        destCoords = { x = 2100.0, y = 4800.0, z = 41.0 },
                        use_bound_vehicle = true,
                    },
                },
            },
            -- 7. 卸载物资 (坐标跟随 arrival)
            {
                id = 'step_unload_medical',
                title = '卸载医疗物资',
                description = '在目的地卸下医疗物资，完成配送',
                type = 'interact',
                data = {
                    coords = { x = 2100.0, y = 4800.0, z = 41.0 },
                    radius = 15.0,
                    duration = 5000,
                    label = '卸载医疗物资...',
                    in_vehicle = true,
                },
            },
            -- 8. 归还载具 (回到 departure)
            {
                id = 'step_return_rental',
                title = '交还租用载具',
                description = '租用载具请返回起飞点交还；私家载具直接按E完成',
                type = 'validator',
                data = {
                    coords = { x = -1150.0, y = -2650.0, z = 13.0 },  -- 默认 LSIA，路由注入覆盖
                    radius = 30.0,
                    duration = 3000,
                    label = '交还载具',
                    in_vehicle = true,
                    validator_id = 'validate_rental_cleanup',
                    validator_data = {
                        returnCoords = { x = -1150.0, y = -2650.0, z = 13.0 },
                    },
                },
            },
        },
    },
}
