-- Civilian Ch1: 创业维艰

return {{ id = 'civilian_ch2_startup_struggle', title = '创业维艰 — 平民第一章',
    description = '小店开张第一天——有不速之客上门收保护费。',
    category = 'civilian', level = 2,
    required_tags = { role = 'civilian' },
    conditions = { story_arc = 'civilian', cooldown_hours = 4, min_police = 0 },
    rewards = { money = { type = 'bank', min = 2000, max = 4000 }, items = {{ name = 'sandwich', count = 5 },{ name = 'water', count = 5 }}, rep = { civilian = 60 } },
    steps = {
        { id = 'step_city_hall', title = '办理执照', description = '前往市政厅办理营业执照。', type = 'reach', data = { coords = { x = -550.0, y = -680.0, z = 37.0 }, radius = 10.0 } },
        { id = 'step_rent_shop', title = '签约租店', description = '与中介签约租下店面。', type = 'interact', data = { coords = { x = 150.0, y = -1040.0, z = 29.0 }, radius = 5.0 } },
        { id = 'step_stock_up', title = '采购货物', description = '去批发市场采购首批商品。', type = 'collect', data = { items = {{ name = 'sandwich', count = 5 },{ name = 'water', count = 5 },{ name = 'phone', count = 5 }}, consume = false } },
        { id = 'step_open_shop', title = '开门营业', description = '回到你的店铺——开业大吉！', type = 'reach', data = { coords = { x = 150.0, y = -1040.0, z = 29.0 }, radius = 10.0 } },
        { id = 'step_decision', title = '不速之客', description = '两个混混推开了店门。', type = 'decision', data = { decision_id = 'civilian_ch2_defiant_or_pragmatic' } },
    },
}}
