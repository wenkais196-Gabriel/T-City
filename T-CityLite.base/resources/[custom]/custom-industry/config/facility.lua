-- config/facility.lua — 设施类型与配方（P0 纯数据）。
--
-- S2 只落配置、不跑生产：stock 恒为 0，配方先按 custom-cartel 的形状写，
-- 等 S3 的生产结算再来读它。
--
-- 成本：第 n 个工位 = floor(baseCost × 1.35^(n-1))，n = 当前 workstations + 1。
-- 建设施本身固定扣 baseCost（不含工位）。

Config.Industry.Facilities = {
    mine = {
        label = '矿业设施',
        baseCost = 50000,
        workstationCap = 10,
        maxLevel = 5,

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
