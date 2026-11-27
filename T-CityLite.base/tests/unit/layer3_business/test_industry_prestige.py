"""S8 永久加成（prestige）：每级 +2%、第 10 级封顶 +20%，只在读取路径生效。

钉住四件事：

1. **公式与上限**：`IndustryCycle.PrestigeBonus(points)` 在 0/1/5/9/10/11/100 级上
   分别给出 0/2/10/18/20/20/20（%），负数与 nil 归零。
2. **生产读取路径**：同样的设施与时间，prestige 10 → 库存 30，prestige 0 → 库存 25；
   把 prestige 清零后重新结算同一段时间，产量随之回到 25（证明倍率没有写死进设施行）。
3. **失败方向**：没有 `org_treasury` 行 = 无加成（不是错误）；读库失败 = fail closed，
   本次结算不写库存。
4. **售价不受影响**：售价公式只叠 core_economy 与阶段倍率；`Inspect` 只把加成
   随快照返回给玩家看，不参与 revenue。

反向注入：删掉 `math.min(raw, maxLevel)`（上限）→ 第 1 条红；删掉生产 multiplier 里的
`prestige.multiplier` → 第 2 条红。两条都在交付记录里贴了实际红。
"""

from __future__ import annotations

from industry_harness import FALSE, run_full as run


# ══════════════════════════════════════════════════════════════════
# 1. 纯函数：每级 +2%，第 10 级封顶 +20%
# ══════════════════════════════════════════════════════════════════


def test_prestige_bonus_is_two_percent_per_level_capped_at_twenty():
    out = run("""
        local function emit(tag, points)
            local bonus = IndustryCycle.PrestigeBonus(points)
            __emit(tag, ('%d|%d|%d|%d'):format(
                bonus.points, bonus.level, bonus.bonusPercent,
                math.floor(bonus.multiplier * 100 + 0.5)))
        end
        emit('ZERO', 0)
        emit('ONE', 1)
        emit('FIVE', 5)
        emit('NINE', 9)
        emit('TEN', 10)
        emit('ELEVEN', 11)
        emit('HUNDRED', 100)
        emit('NIL', nil)
        emit('NEGATIVE', -5)
        __emit('MAXLEVEL', tostring(IndustryCycle.PrestigeBonus(0).maxLevel))
    """)

    assert out["ZERO"] == "0|0|0|100"
    assert out["ONE"] == "1|1|2|102", f"每级 +2% 没生效：{out}"
    assert out["FIVE"] == "5|5|10|110"
    assert out["NINE"] == "9|9|18|118"
    assert out["TEN"] == "10|10|20|120"
    assert out["ELEVEN"] == "11|10|20|120", "第 10 级之后的加成没有封顶"
    assert out["HUNDRED"] == "100|10|20|120", "上限没有按等级封顶"
    assert out["NIL"] == "0|0|0|100", "nil 点数没有归零"
    assert out["NEGATIVE"] == "0|0|0|100", "负数点数没有归零"
    assert out["MAXLEVEL"] == "10"


# ══════════════════════════════════════════════════════════════════
# 2. 生产读取路径：每次结算读当前 prestige，不写死进设施行
# ══════════════════════════════════════════════════════════════════


def test_production_reads_stored_prestige_on_every_settlement():
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'expansion', started_epoch = 0, ends_epoch = 100000 })

        -- 10 工位 × 4.5/h × 扩张 1.25 = 56.25/h；600 秒 = 9；prestige 10 → ×1.2 = 11。
        __seedTreasury('mining_co', 0, 10)
        __seedFacility('mining_co', { stock = 0, workstations = 10, last_tick_epoch = 0 })
        local ok, err, result = IndustryProduction.SettleFacility('mining_co', { now = 600 })
        local boosted = __facility('mining_co')
        __emit('BOOSTED_OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('BOOSTED_STOCK', tostring(boosted.stock))
        __emit('BOOSTED_RESULT', tostring(result and result.produced))
        __emit('BAKED_FIELD', tostring(
            boosted.multiplier ~= nil or boosted.prestige ~= nil or boosted.bonus ~= nil))

        -- 同一段时间把 prestige 归零重跑：产量必须回到 9（倍率只在读取时生效）。
        __seedFacility('mining_co', { stock = 0, workstations = 10, last_tick_epoch = 0 })
        __seedTreasury('mining_co', 0, 0)
        local ok2, err2 = IndustryProduction.SettleFacility('mining_co', { now = 600 })
        __emit('BASELINE_OK', tostring(ok2) .. ':' .. tostring(err2 or 'nil'))
        __emit('BASELINE_STOCK', tostring(__facility('mining_co').stock))
    """)

    assert out["BOOSTED_OK"] == "true:nil", f"带加成结算失败：{out}"
    assert out["BOOSTED_STOCK"] == "11", f"+20% 产能没有进生产公式：{out}"
    assert out["BOOSTED_RESULT"] == "11"
    assert out["BASELINE_STOCK"] == "9", (
        f"清零 prestige 后仍按旧倍率产出（倍率被写死了）：{out}"
    )
    assert out["BAKED_FIELD"] == FALSE, "设施行里出现了倍率/加成列，违背读取路径约束"


def test_missing_treasury_account_means_no_bonus_not_an_error():
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'expansion', started_epoch = 0, ends_epoch = 100000 })
        __seedFacility('mining_co', { stock = 0, workstations = 10, last_tick_epoch = 0 })
        local ok, err = IndustryProduction.SettleFacility('mining_co', { now = 600 })
        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('STOCK', tostring(__facility('mining_co').stock))
    """)

    assert out["OK"] == "true:nil", f"没有金库账户不该阻断生产：{out}"
    assert out["STOCK"] == "9", f"无账户时应按 1 倍产出：{out}"


def test_prestige_read_failure_fails_closed():
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'expansion', started_epoch = 0, ends_epoch = 100000 })
        __seedTreasury('mining_co', 0, 10)
        __seedFacility('mining_co', { stock = 0, workstations = 10, last_tick_epoch = 0 })

        __failPrestigeRead = true
        local ok, err = IndustryProduction.SettleFacility('mining_co', { now = 600 })
        __emit('FIRST', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('STOCK_AFTER_FAIL', tostring(__facility('mining_co').stock))
        __emit('UNITS_AFTER_FAIL', tostring(__facility('mining_co').produced_units))

        local ok2, err2 = IndustryProduction.SettleFacility('mining_co', { now = 600 })
        __emit('RETRY', tostring(ok2) .. ':' .. tostring(err2 or 'nil'))
        __emit('STOCK_AFTER_RETRY', tostring(__facility('mining_co').stock))
    """)

    assert out["FIRST"] == "false:db_error", f"prestige 读失败没有 fail closed：{out}"
    assert out["STOCK_AFTER_FAIL"] == "0", "读失败后仍写了库存"
    assert out["UNITS_AFTER_FAIL"] == "0", "读失败后仍累计了 produced_units"
    assert out["RETRY"] == "true:nil", f"瞬时读失败后重试没有恢复：{out}"
    assert out["STOCK_AFTER_RETRY"] == "11"


# ══════════════════════════════════════════════════════════════════
# 3. 只读快照显示加成；售价公式不受影响
# ══════════════════════════════════════════════════════════════════


def test_inspect_exposes_prestige_but_sale_price_is_unchanged():
    out = run("""
        __reset()
        __seedState({ cycle_no = 1, phase = 'recession', started_epoch = 0, ends_epoch = 100000 })
        __seedTreasury('mining_co', 0, 10)
        __seedFacility('mining_co', { stock = 10, workstations = 1, last_tick_epoch = 100000 })
        __seedDemand(1, 'recession', 'iron_ore', 100, 0)

        local info, err = IndustrySales.Inspect('mining_co', 'iron_ore')
        __emit('OK', tostring(info ~= nil) .. ':' .. tostring(err or 'nil'))
        __emit('LEVEL', tostring(info and info.prestige and info.prestige.level))
        __emit('BONUS', tostring(info and info.prestige and info.prestige.bonusPercent))
        __emit('MULT', tostring(info and info.prestige and info.prestige.multiplier))
        __emit('UNIT', tostring(info and info.unitPrice))

        local ok, saleErr, result = IndustrySales.SettleSale(
            'mining_co', 'iron_ore', 2, 'prestige-price')
        __emit('SALE', tostring(ok) .. ':' .. tostring(saleErr or 'nil'))
        -- 衰退期：floor(50 × 2 × 1.0 × 1.0 × 0.80) = 80；prestige 不乘售价。
        __emit('REVENUE', tostring(result and result.revenue))
        __emit('QUOTE', tostring(IndustrySales.QuoteRevenue(50, 2)))
    """)

    assert out["OK"] == "true:nil", f"Inspect 失败：{out}"
    assert out["LEVEL"] == "10"
    assert out["BONUS"] == "20"
    assert out["MULT"] == "1.2"
    assert out["UNIT"] == "50"
    assert out["SALE"] == "true:nil", f"带 prestige 的卖单失败：{out}"
    assert out["REVENUE"] == "80", "永久加成错误地乘进了售价"
    assert out["QUOTE"] == "80", "报价把永久加成算进了价格"
