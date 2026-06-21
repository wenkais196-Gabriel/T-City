-- Civilian Ch3: 幸存者

return {{ id = 'civilian_ch4_survivor', title = '幸存者 — 平民终章',
    description = '你选择了最安全的路。不算耀眼——但你活下来了。在这座城市，这已经是胜利。',
    category = 'civilian', level = 4,
    required_tags = { role = 'civilian' },
    conditions = { story_arc = 'civilian', cooldown_hours = 0, min_police = 0, player_choices = {{ flag = 'civ_pragmatic' }} },
    rewards = { money = { type = 'bank', min = 15000, max = 25000 }, items = {{ name = 'phone', count = 10 },{ name = 'sandwich', count = 10 }}, rep = { civilian = 120 } },
    steps = {
        { id = 'step_shop', title = '熟悉的小店', description = '收银台的玻璃完好无损。', type = 'reach', data = { coords = { x = 150.0, y = -1040.0, z = 29.0 }, radius = 10.0 } },
        { id = 'step_routine', title = '日常', description = '打开收银机，整理货架。', type = 'interact', data = { coords = { x = 150.0, y = -1040.0, z = 29.0 }, radius = 3.0 } },
        { id = 'step_sunset', title = '落日', description = '你还站着——在这座城市，这已经是胜利。', type = 'interact', data = { coords = { x = 140.0, y = -1030.0, z = 29.0 }, radius = 5.0 } },
    },
}}
