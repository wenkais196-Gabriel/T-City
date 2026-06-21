-- ============================================================================
-- bank_escort.lua — 银行押款护送 (乐高积木模板 v1.0.0)
-- ============================================================================
-- 玩法流程:
--   1. GOTO Fleeca银行     → 前往银行金库
--   2. INTERACT 金库保险柜  → 5秒进度条取出押款箱
--   3. COMBAT 遭遇伏击      → 消灭6名Lost MC劫匪
--   4. DELIVER 押款箱到总部  → 运送3个cash_bag到警察总部
--   5. REWARD 奖励发放       → $5000 + security声望+10
--
-- 设计说明:
--   - 合法职业(保安公司)任务 — 从银行护送现金到总部
--   - mode='solo' — 单人任务
--   - 与非法军火劫掠(arms_heist)共享底层GOTO→COMBAT→DELIVER积木链
--   - heatActivityId='bank_escort' 供经济热度追踪
-- ============================================================================

return {
    id = 'bank_escort',
    title = 'Bank Cash Escort',
    description = 'Secure cash from Fleeca Bank and transport it to HQ under armed escort.',
    category = 'legal',
    type = 'escort',

    -- 三位一体需求 (暂无 — 所有合法职业可接)
    required_tags = nil,

    conditions = {
        cooldown_hours = 2,
        min_police = 2,
    },

    -- 乐高节点序列
    nodes = {
        {
            type = 'GOTO',
            id = 'goto_fleeca',
            title = 'Travel to Fleeca Bank',
            payload = {
                coords = vector3(150.26, -1040.21, 29.37),
                radius = 5.0,
                label = 'Fleeca Bank Vault',
            },
        },
        {
            type = 'INTERACT',
            id = 'secure_cash',
            title = 'Secure Cash from Vault',
            payload = {
                coords = vector3(150.26, -1040.21, 29.37),
                duration = 5000,
                label = 'Securing cash bags...',
                animDict = 'mini@safe_cracking',
                animName = 'dial_turn_01',
            },
        },
        {
            type = 'COMBAT',
            id = 'ambush',
            title = 'Survive the Ambush',
            payload = {
                npcModel = 'g_m_y_lost_01',
                count = 6,
                coords = vector3(120.5, -1050.8, 29.3),
                weapon = 'weapon_microsmg',
                npcHealth = 200,
                npcAccuracy = 30,
                label = 'Eliminate Lost MC Ambushers',
            },
        },
        {
            type = 'DELIVER',
            id = 'deliver_to_hq',
            title = 'Deliver Cash to Police HQ',
            payload = {
                destCoords = vector3(638.5, 1.75, 82.8),
                item = 'cash_bag',
                amount = 3,
                radius = 5.0,
                label = 'Mission Row Police HQ',
            },
        },
    },

    -- 奖励配置
    rewards = {
        money = {
            min = 4000,
            max = 5000,
            type = 'bank',
        },
        items = {
            { name = 'armor', count = 1 },
        },
        rep = {
            security = 10,
        },
    },

    -- 经济热度追踪
    heatActivityId = 'bank_escort',

    -- 任务模式
    mode = 'solo',
}
