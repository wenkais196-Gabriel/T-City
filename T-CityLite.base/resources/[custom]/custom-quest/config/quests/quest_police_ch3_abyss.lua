-- Police Ch2: 深渊

return {{ id = 'police_ch3_abyss', title = '深渊 — LSPD 第二章',
    description = '腐败不只 Morrison。背后是整个市议会。',
    category = 'police', level = 3,
    required_tags = { job = 'police' },
    conditions = { story_arc = 'police', cooldown_hours = 8, min_police = 2 },
    rewards = { money = { type = 'bank', min = 5000, max = 10000 }, items = {{ name = 'weapon_carbinerifle', count = 1 },{ name = 'rifle_ammo', count = 100 }}, rep = { police = 100 } },
    steps = {
        { id = 'step_city_hall', title = '市政厅取证', description = '窃取市议员电脑文件。', type = 'reach', data = { coords = { x = -550.0, y = -680.0, z = 37.0 }, radius = 15.0 } },
        { id = 'step_hack', title = '黑入系统', description = '找到议员办公室黑入电脑。', type = 'interact', data = { coords = { x = -545.0, y = -675.0, z = 37.0 }, radius = 3.0 } },
        { id = 'step_escape', title = '突围', description = '安保发现了你！杀出去。', type = 'combat', data = { coords = { x = -560.0, y = -690.0, z = 37.0 }, radius = 30.0 } },
        { id = 'step_safehouse', title = '回到安全屋', description = '把证据带回安全地点。', type = 'reach', data = { coords = { x = 800.0, y = -3000.0, z = 6.0 }, radius = 20.0 } },
        { id = 'step_decision', title = '终极选择', description = '曝光还是交易？', type = 'decision', data = { decision_id = 'police_ch3_whistleblower_or_insider' } },
    },
}}
