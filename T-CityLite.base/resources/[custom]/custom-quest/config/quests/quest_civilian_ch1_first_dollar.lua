-- Civilian 序章: 初金

return {{ id = 'civilian_ch1_first_dollar', title = '初金 — 平民序章',
    description = '你初到洛圣都，身无分文。Old Tony 教你挣到第一桶金。',
    category = 'civilian', level = 1,
    required_tags = { role = 'civilian' },
    conditions = { story_arc = 'civilian', cooldown_hours = 0, min_police = 0 },
    rewards = { money = { type = 'bank', min = 300, max = 600 }, items = {{ name = 'sandwich', count = 2 }}, rep = { civilian = 20 } },
    steps = {
        { id = 'step_meet_tony', title = '公交站的好心人', description = '找到那位看报纸的老人。', type = 'reach', data = { coords = { x = -260.0, y = -950.0, z = 31.0 }, radius = 10.0 } },
        { id = 'step_go_mine', title = '前往矿场', description = 'Old Tony 指给你矿场的方向。', type = 'reach', data = { coords = { x = -595.0, y = 3490.0, z = 30.0 }, radius = 20.0 } },
        { id = 'step_mine_ore', title = '挖矿挣钱', description = '使用矿镐采集 5 块铁矿石。', type = 'custom_event', data = { event_name = 'mine_ore', match = { ore_type = 'iron_ore' }, required_count = 5 } },
        { id = 'step_go_bank', title = '去银行开户', description = '带着工资去银行存钱。', type = 'reach', data = { coords = { x = 150.0, y = -1040.0, z = 29.0 }, radius = 10.0 } },
        { id = 'step_decision', title = 'Marcus Chen 的名片', description = '一个西装男人递来烫金名片。', type = 'decision', data = { decision_id = 'civilian_ch1_honest_or_shadow' } },
    },
}}
