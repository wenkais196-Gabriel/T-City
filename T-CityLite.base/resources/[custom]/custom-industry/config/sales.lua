-- config/sales.lua — S4 销售 / 配额参数（纯数据 + convar）。
--
-- 口径（写死在这里，不在 sale.lua 里再算一遍）：
--   * 价格由服务端决定：客户端只能说「卖 N 件」，任何价格/倍率字段都不读。
--   * 单组织累计上限 = floor(quota_total × OrgCapRatio)，OrgCapRatio = 0.5。
--   * 周期占位：S4 固定 cycle_no = 0 / phase = 'static'，S6 只改这两个值。
--
-- 真机验收旋钮：
--   set industry_demand_seed 10     -- 需求总量（启动时校准未使用的配额）
--   set industry_sale_price 50      -- iron_ore 单价
--   set industry_sales_debug true   -- /orgsell 后台入口（仅控制台）

local function integerConvar(name, default, minimum)
    local value = tonumber(GetConvar(name, tostring(default)))
    if not value or value ~= value then value = default end -- NaN 兜底
    if value < minimum then value = minimum end
    return math.floor(value)
end

Config.Industry.Sales = {
    -- S6 之前不推进周期；S6 只改值，不动表结构。
    CycleNo = 0,
    Phase = 'static',

    -- 种子需求行由迁移插入；启动时用这个 convar 校准 quota_total（quota_used = 0 时）。
    SeedItem = 'iron_ore',
    SeedQuota = integerConvar('industry_demand_seed', 10, 0),

    -- 服务端定价。新增可卖物品时在这里加一行（没有价格 = 不可卖）。
    UnitPrices = {
        iron_ore = integerConvar('industry_sale_price', 50, 1),
    },

    -- 单组织上限：全服配额的 50%（设计 §10/§11 的防垄断闸）。
    OrgCapRatio = 0.5,

    -- 单次卖单最多多少件（防止一个非法请求把 int 撑爆；库存与配额还会再截断）。
    MaxQty = 1000000,

    -- core_economy 的活动热度键；系数只从 core_economy 拿，本资源不另写公式。
    ActivityId = 'industry:sale',

    -- 后台入口（`orgsell`，restricted 原生命令，仅控制台）默认关闭。
    DebugCommand = GetConvar('industry_sales_debug', 'false') == 'true',
}
