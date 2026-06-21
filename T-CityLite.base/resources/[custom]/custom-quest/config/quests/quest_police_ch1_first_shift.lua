-- Police 序章: 初更

return {{ id = 'police_ch1_first_shift', title = '初更 — LSPD 序章',
    description = '刚从警校毕业，Captain Reyes 亲自带你熟悉巡逻流程。',
    category = 'police', level = 1,
    required_tags = { job = 'police' },
    conditions = { story_arc = 'police', cooldown_hours = 0, min_police = 0 },
    rewards = { money = { type = 'bank', min = 200, max = 400 }, items = {{ name = 'weapon_flashlight', count = 1 }}, rep = { police = 20 } },
    steps = {
        { id = 'step_report_station', title = '前往 Davis 警署', description = 'Captain Reyes 在等你报到。', type = 'reach', data = { coords = { x = 360.0, y = -1584.0, z = 30.0 }, radius = 15.0 } },
        { id = 'step_gear_up', title = '领取装备', description = '在 locker room 换装领取警械。', type = 'interact', data = { coords = { x = 358.0, y = -1580.0, z = 30.0 }, radius = 5.0 } },
        { id = 'step_patrol', title = '驾车巡逻', description = 'Reyes 让你开车在辖区巡逻。', type = 'reach', data = { coords = { x = 280.0, y = -1450.0, z = 30.0 }, radius = 20.0 } },
        { id = 'step_respond_911', title = '响应 911', description = '便利店抢劫！前往现场。', type = 'reach', data = { coords = { x = 200.0, y = -1380.0, z = 30.0 }, radius = 15.0 } },
        { id = 'step_decision', title = '口袋里的纸条', description = '你在嫌犯口袋发现一张纸条。', type = 'decision', data = { decision_id = 'police_ch1_honest_or_silent' } },
    },
}}
