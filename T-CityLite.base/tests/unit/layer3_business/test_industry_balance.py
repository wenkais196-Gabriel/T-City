"""产业数值卡（#387）：把「周期多长、每阶段能卖多少、多久回本」钉成可执行断言。

这份用例只读配置 + 走真实的纯函数/假 DB 路径，不复制一套「看起来差不多」的公式：

* 阶段天数与总秒数走 `IndustryCycle.PhaseSeconds`；
* 每阶段配额与单组织上限走 `IndustrySales.EnsureSeed` 的**真实种子行**；
* 产量走 `IndustryProduction.Compute`，收入走 `IndustrySales.QuoteRevenue`；
* 两家组织的 50% 上限走 `IndustrySales.SettleSale` 的真实 CAS；
* 工位成本走 `Facility.WorkstationCost`。

三处口径先写死（与 issue #387 的两条评论一致）：

1. **周期 = 28 天（10/10/5/3）**。结算不是第五阶段，是衰退结束边界上的一次事件；
   `industry_state.phase` 只有四个值，`cycle.Phases.settlement` 必须不存在。
2. **回本用「净现金」口径**：S7 每个周期都会清空设施与金库余额，初始资本要重新投入，
   所以 `C / (R - C)` 才是回本周数；`R / C` 只是毛收入倍数，不叫回本。
   目标区间 6–10 周；本卡 1 工位落在 6.95 周。
3. **满建 10 工位必须能吃掉单组织 50% 配额**（最差阶段是衰退）：
   2,200 件 / (72h × 0.70) = 43.65 单位/小时 ≤ 10 × 4.5 = 45。

反向注入靶子（交付记录里贴实际红/绿）：

* 任一阶段 `days +1` → 第 1 条与回本/日毛利一起红；
* `SeedQuota` 调回 10 → 配额、收入、50% 上限一起红；
* `OrgCapRatio` 改 1.0 → 两家组织的 `org_cap_reached` 用例红。
"""

from __future__ import annotations

from industry_harness import FALSE, NIL, run_full as run


# ══════════════════════════════════════════════════════════════════
# 1. 周期长度：四阶段合计 28 天，结算不是阶段
# ══════════════════════════════════════════════════════════════════


def test_phase_days_sum_to_28_and_settlement_is_not_a_phase():
    out = run("""
        local cycle = Config.Industry.Cycle
        local order = cycle.Order
        __emit('ORDER', table.concat(order, ','))
        __emit('PHASE_COUNT', tostring(#order))

        local total = 0
        for _, key in ipairs(order) do
            local days = tonumber(cycle.Phases[key].days) or 0
            total = total + days
            __emit('DAYS_' .. key, tostring(days))
            __emit('SECONDS_' .. key, tostring(IndustryCycle.PhaseSeconds(key)))
        end
        __emit('TOTAL_DAYS', tostring(total))
        __emit('TOTAL_SECONDS', tostring(
            IndustryCycle.PhaseSeconds('expansion')
            + IndustryCycle.PhaseSeconds('competition')
            + IndustryCycle.PhaseSeconds('maturity')
            + IndustryCycle.PhaseSeconds('recession')))
        __emit('HAS_SETTLEMENT_PHASE', tostring(cycle.Phases.settlement ~= nil))
    """)

    assert out["ORDER"] == "expansion,competition,maturity,recession"
    assert out["PHASE_COUNT"] == "4", "阶段枚举只能是四个值；结算不是阶段"
    assert [out["DAYS_" + phase] for phase in (
        "expansion", "competition", "maturity", "recession"
    )] == ["10", "10", "5", "3"], f"阶段天数不是 10/10/5/3：{out}"
    assert out["TOTAL_DAYS"] == "28", "四阶段合计必须是 28 天（设计稿 §5 已改成 28）"
    assert out["TOTAL_SECONDS"] == str(28 * 86400), "总秒数必须与 28 天一致"
    assert out["HAS_SETTLEMENT_PHASE"] == FALSE, (
        "出现第五个 settlement 阶段；结算应是一次边界事件（S7 SettleCycle）"
    )


# ══════════════════════════════════════════════════════════════════
# 2. 每阶段配额与单组织 50% 上限（走真实的 EnsureSeed）
# ══════════════════════════════════════════════════════════════════


def test_demand_seed_and_org_cap_match_the_card():
    out = run("""
        __reset()
        local sales = Config.Industry.Sales
        for _, phase in ipairs(Config.Industry.Cycle.Order) do
            __seedState({ cycle_no = 1, phase = phase, started_epoch = 0, ends_epoch = 100000 })
            local ok, err = IndustrySales.EnsureSeed()
            local row = __demandRow(1, phase, sales.SeedItem)
            __emit('OK_' .. phase, tostring(ok) .. ':' .. tostring(err or 'nil'))
            __emit('TOTAL_' .. phase, tostring(row and row.quota_total))
            __emit('USED_' .. phase, tostring(row and row.quota_used))
            __emit('CAP_' .. phase, tostring(row and math.floor(
                row.quota_total * sales.OrgCapRatio + 1e-9)))
        end
        __emit('SEED_QUOTA', tostring(sales.SeedQuota))
        __emit('ORG_CAP_RATIO', tostring(sales.OrgCapRatio))
    """)

    expected = {
        "expansion": ("11000", "5500"),
        "competition": ("9350", "4675"),
        "maturity": ("7700", "3850"),
        "recession": ("4400", "2200"),
    }
    for phase, (total, cap) in expected.items():
        assert out["OK_" + phase] == "true:nil", f"{phase} 种子行写入失败：{out}"
        assert out["TOTAL_" + phase] == total, f"{phase} 配额不是 11,000 × 阶段倍率：{out}"
        assert out["USED_" + phase] == "0"
        assert out["CAP_" + phase] == cap, f"{phase} 单组织 50% 上限不对：{out}"

    assert out["SEED_QUOTA"] == "11000"
    assert out["ORG_CAP_RATIO"] == "0.5", "OrgCapRatio 必须保持 0.5（防单组织吃光需求）"


# ══════════════════════════════════════════════════════════════════
# 3. 1 工位：单周期收入、净现金、回本周数
# ══════════════════════════════════════════════════════════════════


def test_single_workstation_cycle_revenue_and_payback():
    out = run("""
        __reset()
        local cycle = Config.Industry.Cycle
        local production = Config.Industry.Production
        local sales = Config.Industry.Sales
        local facilities = Config.Industry.Facilities
        local item = sales.SeedItem
        local unitPrice = sales.UnitPrices[item]

        local totalUnits, totalRevenue = 0, 0
        local rows = {}
        for _, phase in ipairs(cycle.Order) do
            local cfg = cycle.Phases[phase]
            local seconds = IndustryCycle.PhaseSeconds(phase)
            __seedState({ cycle_no = 1, phase = phase, started_epoch = 0, ends_epoch = seconds })
            local plan = IndustryProduction.Compute({
                now = seconds, lastTickAt = 0, workstations = 1, stock = 0,
                cap = 1000000000,
                unitsPerHour = production.UnitsPerHour,
                multiplier = production.Multiplier * cfg.production,
                maxCatchup = seconds,
            })
            local quota = math.floor(sales.SeedQuota * cfg.quota + 1e-9)
            local cap = math.floor(quota * sales.OrgCapRatio + 1e-9)
            local qty = math.min(plan.expected, cap)
            local revenue, err = IndustrySales.QuoteRevenue(unitPrice, qty)
            assert(revenue, tostring(err))
            totalUnits = totalUnits + qty
            totalRevenue = totalRevenue + revenue
            rows[#rows + 1] = ('%s:%d:%d:%d'):format(phase, plan.expected, qty, revenue)
        end

        local buildCost = facilities.mine.baseCost + Facility.WorkstationCost('mine', 0)
        local net = totalRevenue - buildCost
        -- 回本周期 = C / (R - C) 个周期；一个周期 4 周。
        local paybackHundredths = math.floor((buildCost / net) * 28 / 7 * 100 + 0.5)
        __emit('ROWS', table.concat(rows, ','))
        __emit('UNITS', tostring(totalUnits))
        __emit('REVENUE', tostring(totalRevenue))
        __emit('BUILD_COST', tostring(buildCost))
        __emit('NET', tostring(net))
        __emit('PAYBACK_WEEKS_X100', tostring(paybackHundredths))
        __emit('DAILY_GROSS', tostring(math.floor(totalRevenue / 28)))
    """)

    assert out["ROWS"] == (
        "expansion:1350:1350:67500,"
        "competition:1080:1080:51300,"
        "maturity:540:540:29700,"
        "recession:226:226:9040"
    ), f"1 工位的阶段产量/销量/收入与数值卡不一致：{out}"
    assert out["UNITS"] == "3196"
    assert out["REVENUE"] == "157540", "1 工位单周期收入应为 $157,540"
    assert out["BUILD_COST"] == "100000", "设施 + 首个工位必须还是 $100,000"
    assert out["NET"] == "57540", "单周期净现金必须为正，否则每轮重建都在亏钱"
    assert int(out["NET"]) > 0
    assert out["PAYBACK_WEEKS_X100"] == "695", "回本应为 6.95 周"
    assert 600 <= int(out["PAYBACK_WEEKS_X100"]) <= 1000, (
        f"回本不在 6–10 周目标区间：{out['PAYBACK_WEEKS_X100']} / 100 周"
    )
    assert out["DAILY_GROSS"] == "5626"


# ══════════════════════════════════════════════════════════════════
# 4. 满建 10 工位：吃满 50% 配额，日毛利落在 §10 区间
# ══════════════════════════════════════════════════════════════════


def test_full_build_saturates_the_org_cap_and_daily_gross_is_in_band():
    out = run("""
        __reset()
        local cycle = Config.Industry.Cycle
        local production = Config.Industry.Production
        local sales = Config.Industry.Sales
        local facilities = Config.Industry.Facilities
        local item = sales.SeedItem
        local unitPrice = sales.UnitPrices[item]
        local workstations = facilities.mine.workstationCap

        local totalUnits, totalRevenue = 0, 0
        local rows, capacity = {}, {}
        for _, phase in ipairs(cycle.Order) do
            local cfg = cycle.Phases[phase]
            local seconds = IndustryCycle.PhaseSeconds(phase)
            __seedState({ cycle_no = 1, phase = phase, started_epoch = 0, ends_epoch = seconds })
            local plan = IndustryProduction.Compute({
                now = seconds, lastTickAt = 0, workstations = workstations, stock = 0,
                cap = 1000000000,
                unitsPerHour = production.UnitsPerHour,
                multiplier = production.Multiplier * cfg.production,
                maxCatchup = seconds,
            })
            local quota = math.floor(sales.SeedQuota * cfg.quota + 1e-9)
            local cap = math.floor(quota * sales.OrgCapRatio + 1e-9)
            local qty = math.min(plan.expected, cap)
            local revenue, err = IndustrySales.QuoteRevenue(unitPrice, qty)
            assert(revenue, tostring(err))
            totalUnits = totalUnits + qty
            totalRevenue = totalRevenue + revenue
            rows[#rows + 1] = ('%s:%d:%d:%d'):format(phase, plan.expected, cap, revenue)
            capacity[#capacity + 1] = tostring(plan.expected >= cap)
        end

        __emit('WORKSTATIONS', tostring(workstations))
        __emit('CAPACITY_OK', table.concat(capacity, ','))
        __emit('ROWS', table.concat(rows, ','))
        __emit('UNITS', tostring(totalUnits))
        __emit('REVENUE', tostring(totalRevenue))
        __emit('DAILY_GROSS', tostring(math.floor(totalRevenue / 28)))
    """)

    assert out["WORKSTATIONS"] == "10"
    assert out["CAPACITY_OK"] == "true,true,true,true", (
        f"满建产能没有在四个阶段都覆盖 50% 配额：{out}"
    )
    assert out["ROWS"] == (
        "expansion:13500:5500:275000,"
        "competition:10800:4675:222062,"
        "maturity:5400:3850:211750,"
        "recession:2268:2200:88000"
    ), f"满建的阶段产量/配额/收入与数值卡不一致：{out}"
    assert out["UNITS"] == "16225", "满建单周期应卖满 16,225 件（50% 上限）"
    assert out["REVENUE"] == "796812", "满建单周期收入应为 $796,812"
    assert out["DAILY_GROSS"] == "28457", "满建日毛利应为 $28,457"
    assert 15000 <= int(out["DAILY_GROSS"]) <= 30000, "日毛利不在设计 §10 的 $15k–$30k 区间"


# ══════════════════════════════════════════════════════════════════
# 4b. 推荐 4 工位：同时满足「净回本 6–10 周」与「日毛利 $15k–$30k」
# ══════════════════════════════════════════════════════════════════


def test_recommended_four_workstation_build_meets_both_targets():
    out = run("""
        __reset()
        local cycle = Config.Industry.Cycle
        local production = Config.Industry.Production
        local sales = Config.Industry.Sales
        local facilities = Config.Industry.Facilities
        local item = sales.SeedItem
        local unitPrice = sales.UnitPrices[item]

        local totalUnits, totalRevenue = 0, 0
        local rows = {}
        for _, phase in ipairs(cycle.Order) do
            local cfg = cycle.Phases[phase]
            local seconds = IndustryCycle.PhaseSeconds(phase)
            __seedState({ cycle_no = 1, phase = phase, started_epoch = 0, ends_epoch = seconds })
            local plan = IndustryProduction.Compute({
                now = seconds, lastTickAt = 0, workstations = 4, stock = 0,
                cap = 1000000000,
                unitsPerHour = production.UnitsPerHour,
                multiplier = production.Multiplier * cfg.production,
                maxCatchup = seconds,
            })
            local quota = math.floor(sales.SeedQuota * cfg.quota + 1e-9)
            local cap = math.floor(quota * sales.OrgCapRatio + 1e-9)
            local qty = math.min(plan.expected, cap)
            local revenue = IndustrySales.QuoteRevenue(unitPrice, qty)
            totalUnits = totalUnits + qty
            totalRevenue = totalRevenue + revenue
            rows[#rows + 1] = ('%s:%d:%d:%d'):format(phase, plan.expected, qty, revenue)
        end

        local buildCost = facilities.mine.baseCost
            + Facility.WorkstationCost('mine', 0)
            + Facility.WorkstationCost('mine', 1)
            + Facility.WorkstationCost('mine', 2)
            + Facility.WorkstationCost('mine', 3)
        local net = totalRevenue - buildCost
        __emit('ROWS', table.concat(rows, ','))
        __emit('UNITS', tostring(totalUnits))
        __emit('REVENUE', tostring(totalRevenue))
        __emit('BUILD_COST', tostring(buildCost))
        __emit('NET', tostring(net))
        __emit('PAYBACK_WEEKS_X100', tostring(math.floor((buildCost / net) * 28 / 7 * 100 + 0.5)))
        __emit('DAILY_GROSS', tostring(math.floor(totalRevenue / 28)))
    """)

    assert out["ROWS"] == (
        "expansion:5400:5400:270000,"
        "competition:4320:4320:205200,"
        "maturity:2160:2160:118800,"
        "recession:907:907:36280"
    ), f"4 工位的阶段产量/销量/收入与数值卡不一致：{out}"
    assert out["UNITS"] == "12787"
    assert out["REVENUE"] == "630280"
    assert out["BUILD_COST"] == "381643"
    assert out["NET"] == "248637"
    assert out["PAYBACK_WEEKS_X100"] == "614", "推荐档净回本应为 6.14 周"
    assert 600 <= int(out["PAYBACK_WEEKS_X100"]) <= 1000
    assert out["DAILY_GROSS"] == "22510"
    assert 15000 <= int(out["DAILY_GROSS"]) <= 30000, "推荐档日毛利不在 $15k–$30k"


# ══════════════════════════════════════════════════════════════════
# 5. stockCap：满建 12 小时 / 1 工位成熟期 5 天，且真的能触顶
# ══════════════════════════════════════════════════════════════════


def test_stock_cap_is_twelve_hours_of_full_build_and_is_reachable():
    out = run("""
        local facility = Config.Industry.Facilities.mine
        local production = Config.Industry.Production
        local stockCap = facility.stockCap
        local fullRate = facility.workstationCap * production.UnitsPerHour

        __emit('STOCK_CAP', tostring(stockCap))
        __emit('FULL_BUILD_RATE', tostring(fullRate))
        __emit('FULL_FILL_SECONDS', tostring(math.floor(stockCap / fullRate * 3600 + 0.5)))
        __emit('FULL_FILL_HOURS', tostring(stockCap / fullRate))

        local function compute(workstations, seconds, multiplier)
            return IndustryProduction.Compute({
                now = seconds, lastTickAt = 0, workstations = workstations, stock = 0,
                cap = stockCap, unitsPerHour = production.UnitsPerHour,
                multiplier = multiplier, maxCatchup = seconds,
            })
        end

        local expansion = compute(1, IndustryCycle.PhaseSeconds('expansion'),
            Config.Industry.Cycle.Phases.expansion.production)
        __emit('ONE_EXPANSION_PRODUCED', tostring(expansion.produced))
        __emit('ONE_EXPANSION_BLOCKED', tostring(expansion.blocked))

        local maturity = compute(1, IndustryCycle.PhaseSeconds('maturity'), 1)
        __emit('ONE_MATURITY_PRODUCED', tostring(maturity.produced))
        __emit('ONE_MATURITY_BLOCKED', tostring(maturity.blocked))

        local full12h = compute(facility.workstationCap, 12 * 3600, 1)
        __emit('FULL_12H_PRODUCED', tostring(full12h.produced))
        __emit('FULL_12H_EXPECTED', tostring(full12h.expected))
        __emit('FULL_12H_BLOCKED', tostring(full12h.blocked))
    """)

    assert out["STOCK_CAP"] == "540", "stockCap 必须是 10 × 4.5 × 12h = 540"
    assert out["FULL_BUILD_RATE"] == "45.0"
    assert out["FULL_FILL_SECONDS"] == "43200", "满建 12 小时必须正好触顶"
    assert out["FULL_FILL_HOURS"] == "12.0"
    assert out["ONE_EXPANSION_PRODUCED"] == "540", "1 工位在扩张期必须能摸到库存上限"
    assert out["ONE_EXPANSION_BLOCKED"] == "stock_full"
    assert out["ONE_MATURITY_PRODUCED"] == "540", (
        "1 工位在成熟期（5 天 × 1.0）的产量应正好等于 stockCap"
    )
    assert out["ONE_MATURITY_BLOCKED"] == NIL
    assert out["FULL_12H_PRODUCED"] == "540"
    assert out["FULL_12H_EXPECTED"] == "540"
    assert out["FULL_12H_BLOCKED"] == NIL


# ══════════════════════════════════════════════════════════════════
# 6. 两家组织：50% 上限是拒绝，不是截断；全服配额卖满即止
# ══════════════════════════════════════════════════════════════════


def test_two_orgs_split_demand_and_over_half_is_rejected():
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'expansion', started_epoch = 0, ends_epoch = 100000 })
        IndustrySales.EnsureSeed()

        local row = __demandRow(1, 'expansion', 'iron_ore')
        __emit('TOTAL', tostring(row.quota_total))
        __emit('CAP', tostring(math.floor(
            row.quota_total * Config.Industry.Sales.OrgCapRatio + 1e-9)))

        __seedFacility('mining_co', { stock = 20000, workstations = 1, last_tick_epoch = 100000 })
        __seedFacility('cartel', { stock = 20000, workstations = 1, last_tick_epoch = 100000 })
        __seedTreasury('mining_co', 0, 0)
        __seedTreasury('cartel', 0, 0)

        local okA, errA, resA = IndustrySales.SettleSale('mining_co', 'iron_ore', 5500, 'a')
        local okB, errB = IndustrySales.SettleSale('cartel', 'iron_ore', 5501, 'b')
        local okB2, errB2, resB2 = IndustrySales.SettleSale('cartel', 'iron_ore', 5500, 'b2')
        local okA2, errA2 = IndustrySales.SettleSale('mining_co', 'iron_ore', 1, 'a2')

        local after = __demandRow(1, 'expansion', 'iron_ore')
        __emit('A', tostring(okA) .. ':' .. tostring(errA or 'nil')
            .. ':' .. tostring(resA and resA.revenue))
        __emit('B_OVER', tostring(okB) .. ':' .. tostring(errB or 'nil'))
        __emit('B_EXACT', tostring(okB2) .. ':' .. tostring(errB2 or 'nil')
            .. ':' .. tostring(resB2 and resB2.revenue))
        __emit('A_AFTER', tostring(okA2) .. ':' .. tostring(errA2 or 'nil'))
        __emit('USED', tostring(after.quota_used))
        __emit('REMAIN', tostring(after.quota_total - after.quota_used))
        __emit('BAL_A', tostring(__treasury('mining_co').balance))
        __emit('BAL_B', tostring(__treasury('cartel').balance))
        __emit('SALES', tostring(__salesCount()))
    """)

    assert out["TOTAL"] == "11000"
    assert out["CAP"] == "5500"
    assert out["A"] == "true:nil:275000", f"第一家卖 5,500 件失败：{out}"
    assert out["B_OVER"] == "false:org_cap_reached", (
        "第二家超过 50% 必须拒绝，不能先按全服剩余截断成 5,500"
    )
    assert out["B_EXACT"] == "true:nil:275000", "第二家卖满自己的 5,500 应成功"
    assert out["A_AFTER"] == "false:demand_exhausted"
    assert out["USED"] == "11000" and out["REMAIN"] == "0"
    assert out["BAL_A"] == "275000" and out["BAL_B"] == "275000"
    assert out["SALES"] == "2"


# ══════════════════════════════════════════════════════════════════
# 7. prestige：K 跟收入量级一起缩放，+20% 不是一轮就满
# ══════════════════════════════════════════════════════════════════


def test_prestige_k_matches_revenue_scale_and_caps_over_multiple_cycles():
    out = run("""
        local cycle = Config.Industry.Cycle
        __emit('K', tostring(cycle.PrestigeK))
        __emit('PER_LEVEL', tostring(cycle.PrestigeBonusPerLevel))
        __emit('MAX_LEVEL', tostring(cycle.PrestigeBonusMaxLevel))
        __emit('ONE_STATION', tostring(IndustrySettlement.PrestigeFor(157540)))
        __emit('FOUR_STATIONS', tostring(IndustrySettlement.PrestigeFor(630280)))
        __emit('FULL_BUILD', tostring(IndustrySettlement.PrestigeFor(796812)))
        __emit('FIVE_MILLION', tostring(IndustrySettlement.PrestigeFor(5000000)))
        local bonus = IndustryCycle.PrestigeBonus(cycle.PrestigeBonusMaxLevel)
        __emit('MAX_BONUS_PERCENT', tostring(bonus.bonusPercent))
        __emit('MAX_MULTIPLIER_X100', tostring(math.floor(bonus.multiplier * 100 + 0.5)))
    """)

    assert out["K"] == "50000", "PrestigeK 必须跟新收入量级一起缩放（500 → 50,000）"
    assert out["PER_LEVEL"] == "0.02"
    assert out["MAX_LEVEL"] == "10"
    assert out["ONE_STATION"] == "1", "1 工位每周期约 1 点 prestige"
    assert out["FOUR_STATIONS"] == "3", "推荐 4 工位每周期约 3 点 prestige"
    assert out["FULL_BUILD"] == "3", "满建每周期约 3 点 prestige"
    assert out["FIVE_MILLION"] == "10", "累计 $5M 正好 10 点 = +20% 封顶"
    assert out["MAX_BONUS_PERCENT"] == "20"
    assert out["MAX_MULTIPLIER_X100"] == "120"
    assert int(out["FULL_BUILD"]) < int(out["MAX_LEVEL"]), (
        "满建一个周期就顶满 prestige；K 没跟上新收入量级"
    )


# ══════════════════════════════════════════════════════════════════
# 8. 成本项：baseCost 与 1.35 曲线保持，满建资本落在 §20 区间
# ══════════════════════════════════════════════════════════════════


def test_workstation_cost_curve_and_full_build_capital_are_unchanged():
    out = run("""
        local facility = Config.Industry.Facilities.mine
        __emit('BASE', tostring(facility.baseCost))
        __emit('CAP', tostring(facility.workstationCap))

        local costs = {}
        local total = facility.baseCost
        for current = 0, facility.workstationCap - 1 do
            local cost = Facility.WorkstationCost('mine', current)
            costs[#costs + 1] = tostring(cost)
            total = total + cost
        end
        __emit('COSTS', table.concat(costs, ','))
        __emit('TOTAL', tostring(total))
    """)

    assert out["BASE"] == "50000"
    assert out["CAP"] == "10"
    assert out["COSTS"] == (
        "50000,67500,91125,123018,166075,224201,302672,408607,551620,744687"
    ), f"工位成本曲线被改动了：{out}"
    assert out["TOTAL"] == "2779505", "设施 + 10 工位总资本应为 $2,779,505"
    assert 2_000_000 <= int(out["TOTAL"]) <= 5_000_000, (
        "满建资本不在 spec §20 的「头部组织 $2–5M」区间"
    )
