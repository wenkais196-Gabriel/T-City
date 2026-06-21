-- Cartel Ch2: 帝国之影

return {{ id = 'cartel_ch3_empire_shadow', title = '帝国之影 — Cartel 第二章',
    description = 'FIB 开始调查 Cartel。内部有卧底——找出泄密者。',
    category = 'cartel', level = 3,
    required_tags = { role = 'gang_member' },
    conditions = { story_arc = 'cartel', cooldown_hours = 8, min_police = 2 },
    rewards = { money = { type = 'bank', min = 8000, max = 15000 }, items = {{ name = 'cocaine', count = 20 },{ name = 'weapon_smg', count = 1 },{ name = 'smg_ammo', count = 100 }}, rep = { cartel = 100 } },
    steps = {
        { id = 'step_report_boss', title = '面见老大', description = '去 Cartel 总部——老大有任务。', type = 'reach', data = { coords = { x = 1400.0, y = 1150.0, z = 110.0 }, radius = 10.0 } },
        { id = 'step_interrogate', title = '审问嫌疑人', description = '与三个嫌疑人逐一交谈。', type = 'interact', data = { coords = { x = 1395.0, y = 1145.0, z = 110.0 }, radius = 3.0 } },
        { id = 'step_track_lead', title = '追踪线索', description = '前往码头仓库追查。', type = 'reach', data = { coords = { x = 500.0, y = -3200.0, z = 6.0 }, radius = 25.0 } },
        { id = 'step_confront', title = '码头交火', description = 'FIB 线人就在仓库里。', type = 'combat', data = { coords = { x = 480.0, y = -3180.0, z = 6.0 }, radius = 30.0 } },
        { id = 'step_decision', title = '最后的判断', description = '嫌疑人声称无辜——你信吗？', type = 'decision', data = { decision_id = 'cartel_ch3_calculate_or_paranoid' } },
    },
}}
