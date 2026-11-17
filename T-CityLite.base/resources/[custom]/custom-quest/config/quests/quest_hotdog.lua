-- config/quests/quest_hotdog.lua — 热狗摊（S1 开发模板：只验证「押金租借」这一段）
--
-- 为什么单独一条 dev 模板而不是直接写正式任务：
--   S1 只做完了「租借原语」（押金 / 计租 / 关闭 / 重启补退），摆摊、小游戏、顾客、结算
--   分别排在 S2–S5。现在就把「租 → 站桩 → 还」写进正式内容，等于上线一条「交了押金什么也不用干」
--   的任务，玩家会拿它刷押金流水。
--   所以这条模板由 convar `quest_hotdog_dev` 控制，默认不加载；真机验收时打开。
--
-- 坐标来自 docs/plan/jobs-content/12-hotdog-coordinates.md（S0 踏勘）：
--   摆位 A 是真机验证过的旧热狗壳点位，其余是卫星图 + 路网判据确认的铺装。
--
-- 开关：setr quest_hotdog_dev 1（改完要 refresh 再 restart custom-quest）

if GetConvar('quest_hotdog_dev', '0') ~= '1' then
    return {}
end

local RENT_POINT   = { x = 215.0,  y = -772.0, z = 30.5 }   -- 租赁点 / 归还区
local STAND_A      = { x = 215.8,  y = -810.3, z = 30.7 }   -- 摆位 A（真机已验证；摆摊是自由选点，这里只作参考）

return {
    {
        id = 'hotdog_dev_rental',
        title = '热狗摊 · 租借验收（dev）',
        description = '租一辆热狗车 → 推到广场放下 → 回来还车。只用于验证押金、计租与摆放判定。',
        category = 'test',      -- 不是 civilian：收益闸不按 $/h 判它（它本来就不该有收益）
        level = 1,
        required_tags = { role = 'civilian' },
        conditions = {
            cooldown_hours = 0,
            min_police = 0,
            daily_limit = 20,   -- 真机反复验收用
        },
        rewards = {
            money = { type = 'bank', min = 1, max = 1 },   -- 象征性：这条线不靠任务本身发钱
        },
        steps = {
            {
                id = 'step_rent_cart',
                title = '租借热狗车',
                description = '在租赁点交付押金，领走推车。',
                type = 'rental',
                data = {
                    coords = RENT_POINT,
                    radius = 3.0,
                    duration = 1500,
                    label = '租借热狗车',
                    validator_id = 'validate_rental_open',
                    -- 【测试期占位数值】先做成"方便测一轮"的档位，正式数值等经济系统联动时
                    -- 由 docs/plan/jobs-content/13-hotdog-remaining-plan.md 的 E 片统一配（含税率）。
                    -- 不变量：deposit >= max_minutes × rate_per_min（满时长也扣不穿押金），
                    -- 由 tests/architecture/test_hotdog_test_numbers.py 把守。
                    -- 押金 50、每分钟 1 块、前 30 秒免租、最多计 20 分钟 → 满 20 分钟租金 20，退 30。
                    validator_data = {
                        deposit = 50,
                        rate_per_min = 1,
                        grace_sec = 30,
                        max_minutes = 20,
                    },
                },
            },
            {
                id = 'step_place_stand',
                title = '摆摊',
                description = '把推车推到 Legion Square 东侧广场，选个不挡路的位置放下。',
                type = 'booth',
                data = {
                    model = 'prop_hotdogstand_01',
                    rental_point = RENT_POINT,
                    max_distance = 200.0,     -- 离租赁点
                    road_clearance = 6.0,     -- 离路面节点（离线点，见 hotdog_roads.lua）
                    min_separation = 15.0,    -- 离别人的摊位
                    label = '放下推车',
                    validator_id = 'validate_booth_place',
                    -- 开卖参数：摊位一摆好就开张，价格与节奏都由服务端掌握
                    vendor = {
                        -- 【测试期占位数值】单价取偶数，成品回收按 0.5 折价才不会出现 $7.5。
                        -- 顾客节奏压短：第一位 3–6 秒，之后 6–15 秒，耐心 30 秒 —— 一轮测试能在
                        -- 一分钟内看到多次报价，不用干等 40 秒。
                        prices = { common = 8, rare = 16, exotic = 32 },
                        first_customer_ms = { 3000, 6000 },
                        interval_ms = { 6000, 15000 },
                        -- 顾客从 25–40 m 走过来最多 45 秒。【测试期占位，E 片再定】
                        inbound_budget_ms = 45000,
                        patience_ms = 30000,
                        max_global_npcs = 8,
                        reject_cooldown_ms = 60000,
                        max_rejects = 3,
                        max_offers_per_session = 32,
                        -- 起始库存：测试期给足（普通 6 / 稀有 3 / 高级 1），不开张就能卖；
                        -- 正式数值随 E 片一起定。
                        starting_stock = { common = 6, rare = 3, exotic = 1 },
                    },
                },
            },
            {
                id = 'step_sell',
                title = '开卖',
                description = '在摊位按 E 收摊；顾客来了会弹报价，Y 成交 / N 拒绝。',
                type = 'vendor',
                -- 不要给这一步写 coords / radius / duration：
                -- vendor 由服务端在收摊动作里推进（quest_vendor_bridge.lua 的 close 分支）；
                -- 通用 nodeInteract 一旦拿到坐标就会再报一次 nodeComplete，
                -- 与服务端各推进一次 → 真机 `Step order violation`。
                -- 交互提示由热狗客户端自己画（vendorState 状态条 + E 键映射），不靠模板坐标。
            },
            {
                id = 'step_return_cart',
                title = '还车结算',
                description = '把推车放回租赁点，押金按已用时长结算。',
                type = 'reach',
                data = { coords = RENT_POINT, radius = 4.0 },
            },
        },
    },
}
