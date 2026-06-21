-- Police Ch3: 英雄

return {{ id = 'police_ch4_hero', title = '英雄 — LSPD 终章',
    description = '你曝光了一切。市长下台，Morrison 入狱。洛圣都将记住你的名字。',
    category = 'police', level = 4,
    required_tags = { job = 'police' },
    conditions = { story_arc = 'police', cooldown_hours = 0, min_police = 0, player_choices = {{ flag = 'police_justice' },{ flag = 'police_whistleblower' }} },
    rewards = { money = { type = 'bank', min = 30000, max = 50000 }, items = {{ name = 'weapon_carbinerifle', count = 1 },{ name = 'rifle_ammo', count = 200 }}, rep = { police = 200 } },
    steps = {
        { id = 'step_press', title = '新闻发布会', description = '站在媒体面前说出真相。', type = 'reach', data = { coords = { x = -550.0, y = -680.0, z = 37.0 }, radius = 10.0 } },
        { id = 'step_testify', title = '法庭作证', description = '你的证词将决定一切。', type = 'interact', data = { coords = { x = -530.0, y = -670.0, z = 37.0 }, radius = 5.0 } },
        { id = 'step_leave_badge', title = '放下警徽', description = '你选择了正义，但体制容不下你。', type = 'interact', data = { coords = { x = 360.0, y = -1584.0, z = 30.0 }, radius = 5.0 } },
    },
}}
