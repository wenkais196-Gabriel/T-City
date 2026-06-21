-- ============================================================================
-- 现代化任务配置范本: 乐高积木 JSON Payload
-- ============================================================================
-- 核心理念:
--   "不要为新任务写新代码" — 所有复杂 RP 任务由原子节点的 JSON 序列拼装而成。
--   新增一个任务 = 新增一个 Payload 块, 零 Lua/C# 代码。
--
-- 使用方式:
--   1. 将本文件放到任意 resources 的 config/ 目录下
--   2. 服务端 LoadResourceFile + json.decode 读取
--   3. 遍历 nodes 数组, 按序调用 exports['atom_nodes']:StartNode()
--   4. 监听 'atom:server:stepCompleted' 事件 → 推进到下一个节点
--   5. 最后一个节点完成时 → exports['core_economy']:TriggerReward() 发放奖励
-- ============================================================================

return {
    -- ══════════════════════════════════════════════════════════════════
    -- 合法押款护送 (与 bank_escort 共享 GOTO→INTERACT→DELIVER 积木链)
    -- ══════════════════════════════════════════════════════════════════
    bank_escort = {
        id = 'bank_escort',
        label = 'Bank Cash Escort',
        mode = 'solo',           -- solo | group | competitive
        heatActivityId = 'bank_escort',
        nodes = {
            { type = 'GOTO',     payload = { coords = {x=150.3, y=-1040.2, z=29.4},  radius = 5,  label = 'Fleeca Bank' } },
            { type = 'INTERACT', payload = { coords = {x=150.3, y=-1040.2, z=29.4},  duration = 5000, label = 'Secure cash bags', animDict = 'mini@safe_cracking', animName = 'dial_turn_01' } },
            { type = 'DELIVER',  payload = { destCoords = {x=638.5, y=1.8, z=82.8},  item = 'cash_bag', amount = 3, label = 'Deliver to Police HQ' } },
        },
        reward = { money = { bank = 5000 }, items = { {name='armor', amount=1} }, rep = { security = 10 } },
    },

    -- ══════════════════════════════════════════════════════════════════
    -- 非法军火劫掠 (与 bank_escort 同一积木链, 完全不同的体验!)
    -- ══════════════════════════════════════════════════════════════════
    arms_heist = {
        id = 'arms_heist',
        label = 'Fort Zancudo Arms Raid',
        mode = 'competitive',    -- 争夺模式: 第一个到达的独占奖励!
        heatActivityId = 'arms_heist',
        nodes = {
            { type = 'GOTO',     payload = { coords = {x=-2350.5, y=3250.3, z=32.8}, radius = 10, label = 'Infiltrate Fort Zancudo' } },
            { type = 'INTERACT', payload = { coords = {x=-2350.5, y=3250.3, z=32.8}, duration = 8000, label = 'Hacking armory terminal', animDict = 'mp_arresting', animName = 'a_uncuff' } },
            { type = 'DELIVER',  payload = { destCoords = {x=950.2, y=-125.6, z=75.3}, item = 'military_crate', amount = 2, label = 'Deliver to safehouse', vehicleModel = 'barracks' } },
        },
        reward = { money = { cash = 25000 }, rep = { heist = 20 } },
    },

    -- ══════════════════════════════════════════════════════════════════
    -- 急救任务 (链式: 3段GOTO = 赶往现场 → 送往医院 → 返回待命)
    -- ══════════════════════════════════════════════════════════════════
    ems_emergency = {
        id = 'ems_emergency',
        label = 'Emergency Medical Response',
        mode = 'solo',
        heatActivityId = 'ems_rescue',
        nodes = {
            { type = 'GOTO',     payload = { coords = {x=300.0, y=-590.0, z=43.0}, radius = 10, label = 'Respond to emergency scene' } },
            { type = 'DELIVER',  payload = { destCoords = {x=330.0, y=-600.0, z=43.0}, item = 'patient', amount = 1, vehicleModel = 'ambulance', label = 'Transport patient to hospital' } },
            { type = 'GOTO',     payload = { coords = {x=320.0, y=-550.0, z=43.0}, radius = 5,  label = 'Return to station' } },
        },
        reward = { money = { bank = 2500 }, rep = { medical = 10 } },
    },

    -- ══════════════════════════════════════════════════════════════════
    -- 宅配任务 (单人快递 — 纯 GOTO→DELIVER 链)
    -- ══════════════════════════════════════════════════════════════════
    courier_delivery = {
        id = 'courier_delivery',
        label = 'Package Courier',
        mode = 'solo',
        heatActivityId = 'courier',
        nodes = {
            { type = 'GOTO',     payload = { coords = {x=125.0, y=-1020.0, z=29.0}, radius = 3, label = 'Pick up package' } },
            { type = 'DELIVER',  payload = { destCoords = {x=-350.0, y=250.0, z=85.0}, item = 'package', amount = 1, label = 'Deliver to recipient' } },
        },
        reward = { money = { bank = 800 } },
    },
}
