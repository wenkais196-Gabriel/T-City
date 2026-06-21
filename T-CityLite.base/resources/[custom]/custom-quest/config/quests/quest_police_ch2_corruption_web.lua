-- Police Ch1: 腐败之网

return {{ id = 'police_ch2_corruption_web', title = '腐败之网 — LSPD 第一章',
    description = 'IA 正式调查 Morrison。你的选择决定调查走向。',
    category = 'police', level = 2,
    required_tags = { job = 'police' },
    conditions = { story_arc = 'police', cooldown_hours = 4, min_police = 1 },
    rewards = { money = { type = 'bank', min = 2000, max = 4000 }, items = {{ name = 'weapon_pumpshotgun', count = 1 },{ name = 'shotgun_ammo', count = 30 }}, rep = { police = 60 } },
    steps = {
        { id = 'step_ia_office', title = '前往 IA 办公室', description = 'IA 调查官 Davis 约你见面。', type = 'reach', data = { coords = { x = 360.0, y = -1584.0, z = 30.0 }, radius = 10.0 } },
        { id = 'step_review_files', title = '翻阅案卷', description = '查阅 Morrison 的案卷。', type = 'interact', data = { coords = { x = 358.0, y = -1580.0, z = 30.0 }, radius = 3.0 } },
        { id = 'step_surveil', title = '跟踪取证', description = '跟踪 Morrison 下班路线。', type = 'reach', data = { coords = { x = 200.0, y = -1200.0, z = 30.0 }, radius = 30.0 } },
        { id = 'step_ambush', title = '伏击', description = 'Morrison 察觉被跟踪！', type = 'combat', data = { coords = { x = 180.0, y = -1180.0, z = 30.0 }, radius = 25.0 } },
        { id = 'step_decision', title = '证据的归宿', description = 'Morrison 的铁证——交给谁？', type = 'decision', data = { decision_id = 'police_ch2_justice_or_pragmatic' } },
    },
}}
