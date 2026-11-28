-- config/facility.lua — 设施类型与配方（P0 纯数据）。
--
-- S2 只落配置、不跑生产：stock 恒为 0，配方先按 custom-cartel 的形状写，
-- 等 S3 的生产结算再来读它。
--
-- 成本：第 n 个工位 = floor(baseCost × 1.35^(n-1))，n = 当前 workstations + 1。
-- 建设施本身固定扣 baseCost（不含工位）。
--
-- 数值卡（#387）：baseCost 50,000 与 1.35 曲线都不动；满建 10 工位总资本
-- ≈ $2,779,505，落在 spec §20 的「头部组织 $2–5M」区间。

Config.Industry.Facilities = {
    mine = {
        label = '矿业设施',
        baseCost = 50000,
        workstationCap = 10,
        maxLevel = 5,

        -- S3 库存上限（#387 数值卡）：540 = 10 工位 × 4.5 单位/小时 × 12 小时。
        -- 旧值 144 是按「1 工位 × 12 单位/小时 × 12 小时」算的，但设施允许 10 工位，
        -- 满建时 1.2 小时就触顶，离线闸门等于失效；540 把口径改成「满建 12 小时」。
        -- 540 同时等于 1 工位在成熟期（5 天 × 1.0 倍）的产量，单工位也够得着。
        -- 满了就冻结，不产生任何回执；离线通胀闸靠这一列。
        --
        -- P3（#411）：这只是 **0 级** 的上限。实际上限 = stockCap + 900 × stock_level，
        -- 等级落库在 industry_facility.stock_level；价格 = floor(40000 × 1.6^等级)。
        -- 仿真（docs/plan/industry-ops/10-plan.md §2）：+900/级时「囤货过冬」与
        -- 「能卖就卖」打平（+0.6%），满级 5,940 ≈ 一周满建产量的 79%。
        stockCap = 540,
        stockCapPerLevel = 900,
        stockLevelMax = 6,
        stockUpgradeBaseCost = 40000,
        stockUpgradeGrowth = 1.6,

        recipes = {
            {
                id = 'iron_smelt',
                label = '铁矿石精炼',
                inputs = {
                    { name = 'iron_ore', count = 3 },
                },
                output = { name = 'iron_ingot', count = 1 },
                duration = 60, -- 秒
            },
        },
    },
}
