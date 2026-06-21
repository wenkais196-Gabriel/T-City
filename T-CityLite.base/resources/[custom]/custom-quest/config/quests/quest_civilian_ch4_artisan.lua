-- Civilian Ch3: 匠人

return {{ id = 'civilian_ch4_artisan', title = '匠人 — 平民终章',
    description = '你的店不是最大，但是最好。你用品质赢得了比金钱更重要的东西。',
    category = 'civilian', level = 4,
    required_tags = { role = 'civilian' },
    conditions = { story_arc = 'civilian', cooldown_hours = 0, min_police = 0, player_choices = {{ flag = 'civ_defiant' },{ flag = 'civ_cautious' }} },
    rewards = { money = { type = 'bank', min = 20000, max = 35000 }, items = {{ name = 'phone', count = 15 },{ name = 'sandwich', count = 30 }}, rep = { civilian = 180 } },
    steps = {
        { id = 'step_shop', title = '你的店', description = '每一个角落都是你亲手布置的。', type = 'reach', data = { coords = { x = 150.0, y = -1040.0, z = 29.0 }, radius = 10.0 } },
        { id = 'step_award', title = '年度最佳', description = '洛圣都商会颁发"年度最佳独立商家"。', type = 'interact', data = { coords = { x = 150.0, y = -1040.0, z = 29.0 }, radius = 5.0 } },
        { id = 'step_mentor', title = '传递火炬', description = 'Old Tony 坐在你店门口的长椅上。', type = 'interact', data = { coords = { x = 140.0, y = -1030.0, z = 29.0 }, radius = 5.0 } },
    },
}}
