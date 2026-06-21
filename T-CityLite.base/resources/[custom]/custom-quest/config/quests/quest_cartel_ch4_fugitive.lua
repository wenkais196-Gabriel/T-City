-- Cartel Ch3: 逃犯

return {{ id = 'cartel_ch4_fugitive', title = '逃犯 — Cartel 终章',
    description = '你杀了无辜的人。Aztecas 联盟破裂。现在整个 Cartel 都在追杀你。',
    category = 'cartel', level = 4,
    required_tags = { role = 'gang_member' },
    conditions = { story_arc = 'cartel', cooldown_hours = 0, min_police = 0, player_choices = {{ flag = 'cartel_mercy' },{ flag = 'cartel_paranoid' }} },
    rewards = { money = { type = 'bank', min = 10000, max = 15000 }, items = {{ name = 'weapon_pistol', count = 1 },{ name = 'pistol_ammo', count = 100 }}, rep = { cartel = -50 } },
    steps = {
        { id = 'step_run', title = '逃亡', description = 'Halcon 的电话响了——快跑！', type = 'reach', data = { coords = { x = -2000.0, y = 3000.0, z = 5.0 }, radius = 30.0 } },
        { id = 'step_hide', title = '藏身之所', description = '躲进郊区的废弃小屋。', type = 'interact', data = { coords = { x = -2000.0, y = 3000.0, z = 5.0 }, radius = 5.0 } },
        { id = 'step_exit_city', title = '离开洛圣都', description = '一辆车在等你。是时候离开了。', type = 'reach', data = { coords = { x = -3000.0, y = 4500.0, z = 10.0 }, radius = 20.0 } },
    },
}}
