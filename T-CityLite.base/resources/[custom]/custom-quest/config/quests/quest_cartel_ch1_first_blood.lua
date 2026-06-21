-- Cartel 序章: 初血

return {{ id = 'cartel_ch1_first_blood', title = '初血 — Cartel 序章',
    description = '在 Sandy Shores 酒吧，一个自称 Halcon 的人注意到了你。',
    category = 'cartel', level = 1,
    required_tags = { role = 'civilian' },
    conditions = { story_arc = 'cartel', cooldown_hours = 0, min_police = 0 },
    rewards = { money = { type = 'bank', min = 300, max = 500 }, items = {{ name = 'water', count = 2 }}, rep = { cartel = 20 } },
    steps = {
        { id = 'step_meet_halcon', title = '会见 Halcon', description = '前往 Sandy Shores 酒吧。', type = 'reach', data = { coords = { x = 1960.0, y = 3700.0, z = 33.0 }, radius = 10.0 } },
        { id = 'step_pickup_package', title = '取走包裹', description = 'Halcon 让你去后巷取包裹。', type = 'interact', data = { coords = { x = 1955.0, y = 3695.0, z = 33.0 }, radius = 3.0 } },
        { id = 'step_drive_ranch', title = '运送包裹', description = '驾车将包裹送到 Madrazo Ranch。', type = 'reach', data = { coords = { x = 1310.0, y = 1125.0, z = 104.0 }, radius = 15.0 } },
        { id = 'step_drop_package', title = '交付包裹', description = '将包裹交给 Ranch 的接头人。', type = 'interact', data = { coords = { x = 1310.0, y = 1120.0, z = 104.0 }, radius = 5.0 } },
        { id = 'step_decision', title = 'Halcon 的考验', description = 'Halcon 递来一把枪……', type = 'decision', data = { decision_id = 'cartel_ch1_logistics_or_enforcer' } },
    },
}}
