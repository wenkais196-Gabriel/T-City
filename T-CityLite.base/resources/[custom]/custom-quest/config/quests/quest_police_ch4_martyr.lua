-- Police Ch3: 殉道者

return {{ id = 'police_ch4_martyr', title = '殉道者 — LSPD 终章',
    description = '你玩火自焚。想走灰色路线，却被反咬一口——你成了替罪羊。',
    category = 'police', level = 4,
    required_tags = { job = 'police' },
    conditions = { story_arc = 'police', cooldown_hours = 0, min_police = 0, player_choices = {{ flag = 'police_pragmatic' }} },
    rewards = { money = { type = 'bank', min = 5000, max = 10000 }, items = {{ name = 'weapon_pistol', count = 1 },{ name = 'pistol_ammo', count = 50 }}, rep = { police = -50 } },
    steps = {
        { id = 'step_arrest', title = '被捕', description = '你的储物柜里"发现"了赃款。', type = 'reach', data = { coords = { x = 360.0, y = -1584.0, z = 30.0 }, radius = 10.0 } },
        { id = 'step_jail', title = '牢房', description = '那些你曾抓捕的罪犯在铁栏外笑。', type = 'interact', data = { coords = { x = 350.0, y = -1580.0, z = 30.0 }, radius = 3.0 } },
        { id = 'step_release', title = '释放', description = '证据不足——但警徽没了，名声毁了。', type = 'reach', data = { coords = { x = 300.0, y = -1400.0, z = 30.0 }, radius = 15.0 } },
    },
}}
