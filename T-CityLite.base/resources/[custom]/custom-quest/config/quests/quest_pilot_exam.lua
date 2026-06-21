-- config/quests/quest_pilot_exam.lua
-- ✈️ 飞行执照考核系统 (P2) — 航空培训 + 科目考核
--
-- 流程: LSIA报名($1000) → 绑定教练机 → 起飞过5环 → 平稳降落Sandy跑道 → 颁发飞行执照
-- 脚本触发: custom-certificates:GrantLicense('pilot')

return {
    {
        id = 'pilot_license_exam',
        title = '飞行执照考试',
        description = '前往LSIA国际机场完成飞行科目考核，通过后获得飞行执照。包含起飞、过圈、降落。',
        category = 'civilian',
        level = 2,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 48,       -- 每两天可考一次
            min_police = 0,
        },
        rewards = {
            money = { type = 'bank', min = 200, max = 500 },
        },
        steps = {
            {
                id = 'step_register_pilot',
                title = '航校报名',
                description = '前往LSIA 3号机库航校办公室缴纳 $1000 报名费',
                type = 'interact',
                data = {
                    coords = { x = -1150.0, y = -2650.0, z = 13.0 },
                    radius = 5.0,
                    duration = 3000,
                    label = '缴纳飞行报名费 $1000...',
                },
            },
            {
                id = 'step_enter_plane',
                title = '进入教练机',
                description = '坐进系统分配的训练机 Mammatus，完成起飞前检查',
                type = 'interact',
                data = {
                    coords = { x = -1130.0, y = -2680.0, z = 13.0 },
                    radius = 15.0,
                    duration = 3000,
                    label = '绑定教练机...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_takeoff',
                title = '起飞',
                description = '推动油门平稳起飞，爬升至巡航高度',
                type = 'reach',
                data = {
                    coords = { x = -1200.0, y = -2800.0, z = 100.0 },
                    radius = 40.0,
                },
            },
            {
                id = 'step_ring_one',
                title = '过圈考核 1/5',
                description = '飞往Sandy Shores空域，平稳穿过第1个空中检查环',
                type = 'reach',
                data = {
                    coords = { x = -800.0, y = 1000.0, z = 150.0 },
                    radius = 30.0,
                    checkpoint = { type = 'ring', radius = 25.0, height_tolerance = 40.0, label = '🔵 检查环 1/5' },
                },
            },
            {
                id = 'step_ring_two',
                title = '过圈考核 2/5',
                description = '穿过第2个空中检查环',
                type = 'reach',
                data = {
                    coords = { x = -200.0, y = 1500.0, z = 150.0 },
                    radius = 30.0,
                    checkpoint = { type = 'ring', radius = 25.0, height_tolerance = 40.0, label = '🔵 检查环 2/5' },
                },
            },
            {
                id = 'step_ring_three',
                title = '过圈考核 3/5',
                description = '穿过第3个空中检查环',
                type = 'reach',
                data = {
                    coords = { x = 400.0, y = 2000.0, z = 150.0 },
                    radius = 30.0,
                    checkpoint = { type = 'ring', radius = 25.0, height_tolerance = 40.0, label = '🔵 检查环 3/5' },
                },
            },
            {
                id = 'step_ring_four',
                title = '过圈考核 4/5',
                description = '穿过第4个空中检查环',
                type = 'reach',
                data = {
                    coords = { x = 1000.0, y = 2500.0, z = 150.0 },
                    radius = 30.0,
                    checkpoint = { type = 'ring', radius = 25.0, height_tolerance = 40.0, label = '🔵 检查环 4/5' },
                },
            },
            {
                id = 'step_ring_five',
                title = '过圈考核 5/5',
                description = '穿过最后一个检查环，准备降落',
                type = 'reach',
                data = {
                    coords = { x = 1600.0, y = 3000.0, z = 120.0 },
                    radius = 30.0,
                    checkpoint = { type = 'ring', radius = 25.0, height_tolerance = 40.0, label = '🔵 检查环 5/5' },
                },
            },
            {
                id = 'step_approach',
                title = '进场下降',
                description = '降低高度，对准Sandy Shores跑道进场航线',
                type = 'reach',
                data = {
                    coords = { x = 1800.0, y = 3800.0, z = 50.0 },
                    radius = 40.0,
                },
            },
            {
                id = 'step_landing',
                title = '平稳降落',
                description = '在Sandy Shores跑道平稳着陆并滑行至停机位',
                type = 'interact',
                data = {
                    coords = { x = 1750.0, y = 3250.0, z = 41.0 },
                    radius = 25.0,
                    duration = 5000,
                    label = '着陆校验 + 停机...',
                    in_vehicle = true,
                },
            },
            {
                id = 'step_issue_pilot_license',
                title = '领取飞行执照',
                description = '🎉 飞行考试通过！系统正在授予飞行执照权限...',
                type = 'script_trigger',
                data = {
                    export_path = 'custom-certificates:GrantLicense',
                    args = { 'pilot' },
                },
            },
        },
    },
}
