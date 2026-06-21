-- Civilian Ch3: 巨头

return {{ id = 'civilian_ch4_mogul', title = '巨头 — 平民终章',
    description = '你从不低头，一路狂奔。现在你拥有洛圣都最大的连锁企业。',
    category = 'civilian', level = 4,
    required_tags = { role = 'civilian' },
    conditions = { story_arc = 'civilian', cooldown_hours = 0, min_police = 0, player_choices = {{ flag = 'civ_ambitious' }} },
    rewards = { money = { type = 'bank', min = 50000, max = 80000 }, items = {{ name = 'phone', count = 30 },{ name = 'markedbills', count = 50 }}, rep = { civilian = 200 } },
    steps = {
        { id = 'step_headquarters', title = '企业总部', description = '站在顶层办公室俯瞰整座城市。', type = 'reach', data = { coords = { x = -150.0, y = -900.0, z = 150.0 }, radius = 15.0 } },
        { id = 'step_sign_deal', title = '签下大单', description = '与全州最大的供货商签署独家协议。', type = 'interact', data = { coords = { x = -150.0, y = -900.0, z = 150.0 }, radius = 5.0 } },
        { id = 'step_reflect', title = '镜子里的自己', description = '你还记得当初在公交站的那个下午吗？', type = 'interact', data = { coords = { x = -150.0, y = -900.0, z = 150.0 }, radius = 3.0 } },
    },
}}
