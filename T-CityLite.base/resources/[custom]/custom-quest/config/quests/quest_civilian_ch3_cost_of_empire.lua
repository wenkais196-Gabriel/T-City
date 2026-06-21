-- Civilian Ch2: 帝国的代价

return {{ id = 'civilian_ch3_cost_of_empire', title = '帝国的代价 — 平民第二章',
    description = '$50,000 贷款可以收购竞争对手——但抵押品是你的店。',
    category = 'civilian', level = 3,
    required_tags = { role = 'civilian' },
    conditions = { story_arc = 'civilian', cooldown_hours = 8, min_police = 0 },
    rewards = { money = { type = 'bank', min = 5000, max = 12000 }, items = {{ name = 'phone', count = 10 }}, rep = { civilian = 100 } },
    steps = {
        { id = 'step_chamber', title = '商会晚宴', description = '参加洛圣都商会晚宴。', type = 'reach', data = { coords = { x = -580.0, y = -710.0, z = 40.0 }, radius = 15.0 } },
        { id = 'step_network', title = '建立人脉', description = '与三位潜在合作伙伴交谈。', type = 'interact', data = { coords = { x = -580.0, y = -710.0, z = 40.0 }, radius = 5.0 } },
        { id = 'step_raise_funds', title = '筹集资金', description = '准备 $20,000 扩张启动资金。', type = 'collect', data = { items = {{ name = 'markedbills', count = 20 }}, consume = true } },
        { id = 'step_scout_location', title = '考察选址', description = '考察新店铺选址。', type = 'reach', data = { coords = { x = -200.0, y = -1400.0, z = 30.0 }, radius = 20.0 } },
        { id = 'step_decision', title = '赌一把？', description = '贷款合同就在面前——签还是不签？', type = 'decision', data = { decision_id = 'civilian_ch3_ambitious_or_cautious' } },
    },
}}
