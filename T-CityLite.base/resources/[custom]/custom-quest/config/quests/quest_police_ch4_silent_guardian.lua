-- Police Ch3: 沉默守护者

return {{ id = 'police_ch4_silent_guardian', title = '沉默守护者 — LSPD 终章',
    description = '你选择了从内部改变体制。没有掌声——但你知道自己保护了更多人。',
    category = 'police', level = 4,
    required_tags = { job = 'police' },
    conditions = { story_arc = 'police', cooldown_hours = 0, min_police = 0, player_choices = {{ flag = 'police_insider' }} },
    rewards = { money = { type = 'bank', min = 40000, max = 60000 }, items = {{ name = 'weapon_carbinerifle', count = 1 },{ name = 'rifle_ammo', count = 200 }}, rep = { police = 150 } },
    steps = {
        { id = 'step_promotion', title = '警监办公室', description = '你升到了警监——代价呢？', type = 'reach', data = { coords = { x = 360.0, y = -1584.0, z = 30.0 }, radius = 10.0 } },
        { id = 'step_first_order', title = '第一道命令', description = '悄悄撤销对无辜者的指控。', type = 'interact', data = { coords = { x = 358.0, y = -1580.0, z = 30.0 }, radius = 3.0 } },
        { id = 'step_look_out', title = '窗外的城市', description = '没人知道你今天做了什么——但你知道。', type = 'interact', data = { coords = { x = 365.0, y = -1590.0, z = 30.0 }, radius = 5.0 } },
    },
}}
