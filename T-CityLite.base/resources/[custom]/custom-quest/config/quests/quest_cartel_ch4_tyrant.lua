-- Cartel Ch3: 暴君

return {{ id = 'cartel_ch4_tyrant', title = '暴君 — Cartel 终章',
    description = '你用鲜血铺就了通往王座的道路。整个洛圣都都畏惧你的名字。',
    category = 'cartel', level = 4,
    required_tags = { role = 'gang_member' },
    conditions = { story_arc = 'cartel', cooldown_hours = 0, min_police = 0, player_choices = {{ flag = 'cartel_ruthless' }} },
    rewards = { money = { type = 'bank', min = 25000, max = 40000 }, items = {{ name = 'cocaine', count = 30 },{ name = 'weapon_rifle', count = 1 },{ name = 'rifle_ammo', count = 150 }}, rep = { cartel = 150 },
        on_complete = { action = 'set_gang_grade', gang = 'cartel', grade = 3 } },
    steps = {
        { id = 'step_throne', title = '坐上王座', description = '已经没有反对者了。', type = 'reach', data = { coords = { x = 1400.0, y = 1150.0, z = 110.0 }, radius = 10.0 } },
        { id = 'step_address', title = '铁腕宣言', description = '向手下宣布你的统治。', type = 'interact', data = { coords = { x = 1400.0, y = 1150.0, z = 110.0 }, radius = 5.0 } },
        { id = 'step_raid_prep', title = '备战', description = 'FIB 的突袭随时可能到来。', type = 'interact', data = { coords = { x = 1500.0, y = 1200.0, z = 110.0 }, radius = 5.0 } },
    },
}}
