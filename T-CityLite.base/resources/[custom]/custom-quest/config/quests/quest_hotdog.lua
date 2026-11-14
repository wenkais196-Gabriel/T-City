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
local STAND_A      = { x = 215.8,  y = -810.3, z = 30.7 }   -- 摆位 A（真机已验证）

return {
    {
        id = 'hotdog_dev_rental',
        title = '热狗摊 · 租借验收（dev）',
        description = '租一辆热狗车 → 推到摊位点 → 回来还车。只用于验证押金与计租。',
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
                    -- 押金 250、每分钟 6 块、前 60 秒免租、最多计 60 分钟：
                    -- 满一小时 = 250 押金全部抵扣（退 0），符合 UX 规格 §3.1 的预期
                    validator_data = {
                        deposit = 250,
                        rate_per_min = 6,
                        grace_sec = 60,
                        max_minutes = 60,
                    },
                },
            },
            {
                id = 'step_reach_stand',
                title = '推到摊位点',
                description = '把热狗车推到 Legion Square 东侧广场。',
                type = 'reach',
                data = { coords = STAND_A, radius = 3.0 },
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
