-- config/quests/quest_driver_exam.lua
-- 🚗 自动驾驶考试系统 (P2) — 摆脱人工教练依赖
--
-- 流程: 驾校报名($100) → 绑定DMV考车 → 绕桩刹车 → 城市驾驶 → 返回入库 → 颁发驾照
-- 脚本触发: custom-certificates:GrantLicense('driver')

return {
    {
        id = 'driver_license_exam',
        title = '驾驶执照考试',
        description = '前往驾校完成自动化驾驶考试，通过后获得驾照。全程无需人工教练！',
        category = 'civilian',
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 24,       -- 每天最多考一次
            min_police = 0,
        },
        rewards = {
            money = { type = 'bank', min = 50, max = 100 },
        },
        steps = {
            {
                id = 'step_register',
                title = '驾校报名',
                description = '前往驾校前台缴纳 $100 报名费并登记考试',
                type = 'interact',
                data = {
                    coords = { x = 240.3, y = -1379.89, z = 33.74 },
                    radius = 5.0,
                    duration = 3000,
                    label = '缴纳报名费 $100...',
                },
            },
            {
                id = 'step_enter_dmv_car',
                title = '进入DMV考车',
                description = '坐进系统分配的黄色DMV考车，系好安全带准备出发',
                type = 'interact',
                data = {
                    coords = { x = 245.0, y = -1382.0, z = 33.0 },
                    radius = 8.0,
                    duration = 2000,
                    label = '绑定考车...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_slalom_brake',
                title = '科目二：绕桩与定点刹车',
                description = '沿蓝圈绕桩行驶，在STOP标线内完全停稳（速度归0）',
                type = 'reach',
                data = {
                    coords = { x = 220.0, y = -1400.0, z = 33.0 },
                    radius = 10.0,
                },
            },
            {
                id = 'step_city_drive',
                title = '科目三：城市道路驾驶',
                description = '驶入城市公路完成路考，遵守交通规则，注意限速',
                type = 'reach',
                data = {
                    coords = { x = 350.0, y = -1300.0, z = 33.0 },
                    radius = 20.0,
                },
            },
            {
                id = 'step_return_school',
                title = '返回驾校',
                description = '平稳驶回驾校停车场，准备倒车入库',
                type = 'reach',
                data = {
                    coords = { x = 238.0, y = -1380.0, z = 33.0 },
                    radius = 10.0,
                },
            },
            {
                id = 'step_park_reverse',
                title = '倒车入库',
                description = '将考车平稳倒入指定库位，挂P挡并拉手刹',
                type = 'interact',
                data = {
                    coords = { x = 238.0, y = -1380.0, z = 33.0 },
                    radius = 5.0,
                    duration = 4000,
                    label = '入库停车...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_issue_license',
                title = '领取驾驶执照',
                description = '🎉 考试通过！系统正在授予驾驶执照权限...',
                type = 'script_trigger',
                data = {
                    export_path = 'custom-certificates:GrantLicense',
                    args = { 'driver' },
                },
            },
        },
    },

    -- ==========================================================
    -- 重型载具执照考试 (Heavy Vehicle License Exam)
    -- ==========================================================
    {
        id = 'heavy_license_exam',
        title = '重型载具执照考试',
        description = '驾驶Benson重卡完成倒车穿桩与精准入库，通过后获得重型载具执照。',
        category = 'civilian',
        level = 2,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 48,       -- 每两天可考一次
            min_police = 0,
        },
        rewards = {
            money = { type = 'bank', min = 100, max = 200 },
        },
        steps = {
            {
                id = 'step_register_heavy',
                title = '重卡驾校报名',
                description = '在驾校缴纳 $200 重型载具考试报名费',
                type = 'interact',
                data = {
                    coords = { x = 240.3, y = -1379.89, z = 33.74 },
                    radius = 5.0,
                    duration = 3000,
                    label = '缴纳重卡报名费 $200...',
                },
            },
            {
                id = 'step_enter_truck',
                title = '进入Benson重卡',
                description = '坐进系统分配的重型货车 Benson',
                type = 'interact',
                data = {
                    coords = { x = 900.0, y = -3150.0, z = 6.0 },
                    radius = 15.0,
                    duration = 2000,
                    label = '绑定重卡...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_reverse_slalom',
                title = '倒车穿桩',
                description = '倒车穿过狭窄的堆料区通道，保持平稳不碰桩',
                type = 'reach',
                data = {
                    coords = { x = 920.0, y = -3180.0, z = 6.0 },
                    radius = 12.0,
                },
            },
            {
                id = 'step_dock_precision',
                title = '精准入库',
                description = '将重卡准确推入仓库卸货台，误差不超过2米',
                type = 'reach',
                data = {
                    coords = { x = 850.0, y = -3200.0, z = 6.0 },
                    radius = 5.0,
                },
            },
            {
                id = 'step_issue_heavy_license',
                title = '领取重型载具执照',
                description = '🎉 重卡考试通过！系统正在授予重型载具执照...',
                type = 'script_trigger',
                data = {
                    export_path = 'custom-certificates:GrantLicense',
                    args = { 'heavy' },
                },
            },
        },
    },
}
