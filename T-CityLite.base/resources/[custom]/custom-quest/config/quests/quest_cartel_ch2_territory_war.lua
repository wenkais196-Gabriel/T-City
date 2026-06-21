-- Cartel Ch1: 地盘之争

return {{ id = 'cartel_ch2_territory_war', title = '地盘之争 — Cartel 第一章',
    description = 'Cartel 与 Los Aztecas 的地盘冲突升级。',
    category = 'cartel', level = 2,
    required_tags = { role = 'gang_member' },
    conditions = { story_arc = 'cartel', cooldown_hours = 4, min_police = 1 },
    rewards = { money = { type = 'bank', min = 3000, max = 5000 }, items = {{ name = 'weapon_pistol', count = 1 },{ name = 'pistol_ammo', count = 50 },{ name = 'coca_leaf', count = 15 }}, rep = { cartel = 60 } },
    steps = {
        { id = 'step_meet_halcon', title = '前往安全屋', description = 'Halcon 在安全屋等你。', type = 'reach', data = { coords = { x = 1310.0, y = 1125.0, z = 104.0 }, radius = 10.0 } },
        { id = 'step_gear_up', title = '领取补给', description = '从武器柜领取装备。', type = 'interact', data = { coords = { x = 1305.0, y = 1120.0, z = 104.0 }, radius = 3.0 } },
        { id = 'step_clear_outpost_1', title = '清剿据点 #1', description = '消灭 Aztecas 的第一个据点。', type = 'reach', data = { coords = { x = 900.0, y = -1800.0, z = 32.0 }, radius = 30.0 } },
        { id = 'step_clear_outpost_2', title = '清剿据点 #2', description = '第二个据点——他们的仓库。', type = 'reach', data = { coords = { x = 1100.0, y = -1900.0, z = 32.0 }, radius = 30.0 } },
        { id = 'step_hunt_leader', title = '追击头目', description = 'Aztecas 头目逃到废弃工厂。', type = 'reach', data = { coords = { x = 700.0, y = -2200.0, z = 15.0 }, radius = 25.0 } },
        { id = 'step_decision', title = '生杀大权', description = '头目跪在你面前——饶恕还是处决？', type = 'decision', data = { decision_id = 'cartel_ch2_mercy_or_ruthless' } },
    },
}}
