-- config/cycle.lua — S6 四阶段与 S7 结算参数（纯数据 + convar）。
--
-- 周期长度（#387 数值卡）：默认 **28 天 = 10/10/5/3**。设计稿 §5 曾写「30 天 =
-- 10/10/5/3/2」，其中 2 天是结算窗口；但 `industry_state.phase` 只有四个值，
-- **结算不是阶段，是衰退结束边界上的一次事件**（S7 `SettleCycle`）。加第五阶段会
-- 牵动状态机、补推逻辑与探针比较维度，收益不抵成本，所以正式值定为 28 天。
--
-- 阶段时长是**设计取值、未取证**（spec §5）：验收时用 convar 压到分钟级，
-- 正式服再按真人试玩调。
--
-- 压缩方式（两者可叠加，PhaseSeconds 优先）：
--   * industry_cycle_scale：real_seconds = floor(design_seconds / scale)。
--     scale = 43200 时，「10 天」压成 20 秒；scale = 1 是原速。
--   * industry_phase_seconds：> 0 时**每个阶段**都用这个秒数。
--     验收口径「压到 60 秒 → 4 分钟走完 4 阶段」就是 set industry_phase_seconds 60。
--
-- 四阶段倍率（spec §5）：
--   扩张 1.25 / 1.00 / 1.00 / 可购置
--   竞争 1.00 / 0.95 / 0.85 / 可购置
--   成熟 1.00 / 1.10 / 0.70 / 可购置
--   衰退 0.70 / 0.80 / 0.40 / **不可购置**（但仍可卖出，否则末期卡死）
--
-- 结算 prestige = floor(sqrt(累计销售额 / K))。
-- #387 数值卡把 K 从 500 调到 50,000：新卡单组织单周期收入量级是 $157k（1 工位）
-- 到 $797k（满建），K=500 会让一个周期拿 17–39 点、+20% 上限当轮就满；K=50,000
-- 使满建约 3 点/周期（4 个周期到 10 级）、1 工位约 1 点/周期（10 个周期到顶），
-- 且累计 $5M 正好 10 点 = +20% 封顶。

local function numberConvar(name, default, minimum)
    local value = tonumber(GetConvar(name, tostring(default)))
    if not value or value ~= value then value = default end -- NaN 兜底
    if value < minimum then value = minimum end
    return value
end

local function integerConvar(name, default, minimum)
    return math.floor(numberConvar(name, default, minimum))
end

Config.Industry.Cycle = {
    -- 顺序即推进顺序；industry_state.phase 存这里面的键。
    Order = { 'expansion', 'competition', 'maturity', 'recession' },

    Phases = {
        expansion = {
            label = '扩张', days = 10,
            production = 1.25, price = 1.00, quota = 1.00, purchasable = true,
        },
        competition = {
            label = '竞争', days = 10,
            production = 1.00, price = 0.95, quota = 0.85, purchasable = true,
        },
        maturity = {
            label = '成熟', days = 5,
            production = 1.00, price = 1.10, quota = 0.70, purchasable = true,
        },
        recession = {
            label = '衰退', days = 3,
            production = 0.70, price = 0.80, quota = 0.40, purchasable = false,
        },
    },

    -- 压缩系数（除数）。默认 1 = 原速；0 会被夹到下限。
    Scale = numberConvar('industry_cycle_scale', 1, 1e-6),

    -- 每阶段秒数覆盖（0 = 不覆盖）。验收旋钮：set industry_phase_seconds 60。
    PhaseSeconds = integerConvar('industry_phase_seconds', 0, 0),

    -- 结算前公告提前量（秒）。0 = 自动推导：
    --   PhaseSeconds > 0 → 取 PhaseSeconds（压缩验收时在最后一个阶段内触发）
    --   否则 → floor(7 天 / Scale)（默认正好 7 天）
    WarningSeconds = integerConvar('industry_cycle_warn_seconds', 0, 0),

    -- 结算失败后的重试节流（秒）：公告/结算每 tick 都会重试，失败日志不要每 30 秒刷一条。
    RetryLogSeconds = integerConvar('industry_cycle_retry_seconds', 300, 1),

    -- prestige 公式的分母（#387 数值卡：50,000，见文件头的推导）。
    PrestigeK = integerConvar('industry_prestige_k', 50000, 1),

    -- S8 永久加成（spec §10：每级 +2%，第 10 级封顶 +20%）。
    -- 等级 = prestige 点数；只乘**产能**，不乘售价：
    --   * 售价已经叠了 core_economy 的全局/热度与阶段倍率，再加一层货币倍率会把通胀
    --     从「库存上限 × 配额」挪到价格上，而价格没有第二道闸；
    --   * 产能加成仍受库存上限与每周期配额约束，且设计 §10 的意图是「让下一轮更快」。
    -- 两个值都在读取时参与计算，不写进设施/卖单行。
    PrestigeBonusPerLevel = numberConvar('industry_prestige_bonus_per_level', 0.02, 0),
    PrestigeBonusMaxLevel = integerConvar('industry_prestige_max_level', 10, 0),

    -- 单次结算最多处理多少组织（查询带 LIMIT；MVP 只有 2 个组织）。
    MaxOrgsPerSettle = integerConvar('industry_settle_org_limit', 500, 1),
}
