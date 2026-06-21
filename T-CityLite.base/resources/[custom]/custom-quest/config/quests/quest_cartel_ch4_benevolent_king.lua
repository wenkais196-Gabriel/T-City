-- Cartel Ch3: 仁君

return {{ id = 'cartel_ch4_benevolent_king', title = '仁君 — Cartel 终章',
    description = '你证明了自己：有智慧也有仁慈。今天，你将成为 Cartel 的新主人。',
    category = 'cartel', level = 4,
    required_tags = { role = 'gang_member' },
    conditions = { story_arc = 'cartel', cooldown_hours = 0, min_police = 0, player_choices = {{ flag = 'cartel_mercy' },{ flag = 'cartel_calculated' }} },
    rewards = { money = { type = 'bank', min = 40000, max = 60000 }, items = {{ name = 'cocaine', count = 50 },{ name = 'weapon_rifle', count = 1 },{ name = 'rifle_ammo', count = 200 }}, rep = { cartel = 200 },
        on_complete = { action = 'set_gang_grade', gang = 'cartel', grade = 3 } },
    steps = {
        { id = 'step_throne_room', title = '加冕', description = '前往 Cartel 总部。', type = 'reach', data = { coords = { x = 1400.0, y = 1150.0, z = 110.0 }, radius = 10.0 } },
        { id = 'step_accept_crown', title = '接过权杖', description = '老大递给你 Cartel 的印章。', type = 'interact', data = { coords = { x = 1400.0, y = 1150.0, z = 110.0 }, radius = 5.0 } },
        { id = 'step_address_allies', title = '召集盟友', description = 'Aztecas 头目也在场。', type = 'interact', data = { coords = { x = 1410.0, y = 1160.0, z = 110.0 }, radius = 5.0 } },
    },
}}
