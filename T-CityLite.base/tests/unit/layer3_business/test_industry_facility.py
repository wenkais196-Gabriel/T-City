"""S2 设施 / 工位：真跑 Lua，桩只替换 MySQL。

这里钉：

1. **成本曲线** `floor(base × 1.35^(n-1))`（第 1/2/3 个工位）。
2. **上限**：`workstations < ?` 必须在 UPDATE 的 WHERE 里；到上限不扣钱、不加行。
3. **钱与设施成对**：先扣钱、再改行；改行失败/冲突必须退回。
4. **CAS 冲突**：预读后被别人改了工位 → `conflict`，余额回到原值。
5. **接线**：加载 fxmanifest 里的全部 server 脚本（不提供全局 QBCore），
   断言 S1 四个 + S2 三个命令都注册了 —— S1 真机 P0 的教训。

跑法：``uv run --with pytest python -m pytest tests/unit/layer3_business/test_industry_facility.py -q``
"""

from __future__ import annotations

import re
from pathlib import Path

from industry_harness import (
    MIGRATION_FACILITY,
    SCHEMA_FIXTURE,
    run_facility as run,
    run_ui,
    run_wiring,
)

MIGRATION = MIGRATION_FACILITY
MIGRATION_STOCK = Path(__file__).resolve().parents[3] / "migrations" / "v4.6_industry_stock_level.sql"

#: P3（#411）：facility / UI 两套假 DB 都还不认识 `stock_level = stock_level + 1`
#: 这条 CAS。用例在加载完真实脚本后补上它（探针属于共享文件，不在本片改动范围）。
STOCK_UPGRADE_DB = """
local __baseStockUpdate = MySQL.update.await
MySQL.update = { await = function(sql, values)
    if sql:find('stock_level = stock_level + 1', 1, true) then
        if __stockRace and not __stockRaceFired then
            __stockRaceFired = true
            local hook = __stockRace
            __stockRace = nil
            hook()
        end
        local orgId = values[1]
        local current = tonumber(values[2])
        local cap = tonumber(values[3])
        local row = (__facilityRows and __facilityRows[orgId]) or __facilities[orgId]
        if not row then return { affectedRows = 0 } end
        local level = tonumber(row.stock_level) or 0
        if level ~= current then return { affectedRows = 0 } end
        if cap and level >= cap then return { affectedRows = 0 } end
        row.stock_level = level + 1
        return { affectedRows = 1 }
    end
    return __baseStockUpdate(sql, values)
end }
"""


# ══════════════════════════════════════════════════════════════════
# Q2 配置
# ══════════════════════════════════════════════════════════════════


def test_mine_facility_and_recipe_config():
    out = run("""
        local mine = Config.Industry.Facilities.mine
        local recipe = mine.recipes[1]
        __emit('BASE', tostring(mine.baseCost))
        __emit('CAP', tostring(mine.workstationCap))
        __emit('MAXLEVEL', tostring(mine.maxLevel))
        __emit('RECIPES', tostring(#mine.recipes))
        __emit('RECIPE_ID', tostring(recipe.id))
        __emit('INPUT', tostring(recipe.inputs[1].name) .. ':' .. tostring(recipe.inputs[1].count))
        __emit('OUTPUT', tostring(recipe.output.name) .. ':' .. tostring(recipe.output.count))
        __emit('DURATION', tostring(recipe.duration))
    """)
    assert out["BASE"] == "50000"
    assert out["CAP"] == "10"
    assert out["MAXLEVEL"] == "5"
    assert out["RECIPES"] == "1"
    assert out["RECIPE_ID"] == "iron_smelt"
    assert out["INPUT"] == "iron_ore:3", f"配方输入不对：{out['INPUT']}"
    assert out["OUTPUT"] == "iron_ingot:1", f"配方输出不对：{out['OUTPUT']}"
    assert out["DURATION"] == "60"


# ══════════════════════════════════════════════════════════════════
# Q3 成本曲线
# ══════════════════════════════════════════════════════════════════


def test_workstation_cost_curve_is_exponential():
    """第 1/2/3 个工位：base / floor(base×1.35) / floor(base×1.35²)。"""
    out = run("""
        __reset()
        __seed('mining_co', 1000000)

        local ok0, _, buildCost = Facility.Build('mining_co', 'mine', { actor = 'cid1', ref = 'b1' })
        local ok1, e1, c1 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h1' })
        local ok2, e2, c2 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h2' })
        local ok3, e3, c3 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h3' })

        __emit('OKS', table.concat({
            tostring(ok0), tostring(ok1), tostring(ok2), tostring(ok3),
        }, ','))
        __emit('ERRORS', table.concat({
            tostring(e1 or 'nil'), tostring(e2 or 'nil'), tostring(e3 or 'nil'),
        }, ','))
        __emit('BUILD_COST', tostring(buildCost))
        __emit('COSTS', table.concat({ tostring(c1), tostring(c2), tostring(c3) }, ','))
        __emit('HELPER', table.concat({
            tostring(Facility.WorkstationCost('mine', 0)),
            tostring(Facility.WorkstationCost('mine', 1)),
            tostring(Facility.WorkstationCost('mine', 2)),
        }, ','))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('WS', tostring(__facility('mining_co').workstations))
    """)
    assert out["OKS"] == "true,true,true,true", f"建造/雇工位失败：{out}"
    assert out["ERRORS"] == "nil,nil,nil"
    assert out["BUILD_COST"] == "50000", "建设施固定扣 baseCost"
    assert out["COSTS"] == "50000,67500,91125", (
        f"工位成本不是 floor(base×1.35^(n-1))：{out['COSTS']}"
    )
    assert out["HELPER"] == "50000,67500,91125", (
        f"WorkstationCost 的曲线不对：{out['HELPER']}"
    )
    assert out["BAL"] == "741375", f"余额扣减与成本曲线不一致：{out['BAL']}"
    assert out["WS"] == "3"


# ══════════════════════════════════════════════════════════════════
# Q3 上限 / 并发
# ══════════════════════════════════════════════════════════════════


def test_cap_reached_does_not_charge_or_add():
    """到上限返回 cap_reached：余额与流水都不动，工位数不变。

    同时断言实际执行的 UPDATE 带 `workstations < ?` —— 顺序执行时预读上限
    已经先拦住，但守卫仍必须留在 SQL 里（注入删掉它时这条断言必须红）。
    """
    out = run("""
        __reset()
        -- 余额足够覆盖到上限时的成本，注入「先扣钱后判上限」时才能真的扣到钱。
        __seed('mining_co', 100000000)
        __facilitySeed('mining_co', { workstations = 9 })

        local ok1, e1 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h9' })
        local sql = tostring(__lastFacilityUpdateSql)
        local balanceBefore = __balance('mining_co')
        local ledgerBefore = __ledgerCount()

        local ok2, e2 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h10' })

        __emit('OK1', tostring(ok1))
        __emit('ERR1', tostring(e1 or 'nil'))
        __emit('WS1', tostring(__facility('mining_co').workstations))
        __emit('SQL', sql)
        __emit('OK2', tostring(ok2))
        __emit('ERR2', tostring(e2 or 'nil'))
        __emit('WS2', tostring(__facility('mining_co').workstations))
        __emit('BAL_DELTA', tostring(__balance('mining_co') - balanceBefore))
        __emit('LEDGER_DELTA', tostring(__ledgerCount() - ledgerBefore))
    """)
    assert out["OK1"] == "true" and out["WS1"] == "10", f"第 10 个工位应成功：{out}"
    assert "workstations < ?" in out["SQL"], (
        "上限守卫必须写在 UPDATE 的 WHERE 里；删掉它顺序执行也可能被预读掩盖："
        f"{out['SQL']}"
    )
    assert out["OK2"] == "false", "到上限后还能继续雇"
    assert out["ERR2"] == "cap_reached", f"上限错误码不对：{out['ERR2']}"
    assert out["WS2"] == "10", "cap_reached 仍改动了工位数"
    assert out["BAL_DELTA"] == "0", "cap_reached 扣了钱"
    assert out["LEDGER_DELTA"] == "0", "cap_reached 产生了资金流水（应先判上限再扣钱）"


def test_cas_conflict_refunds_and_keeps_the_concurrent_value():
    """预读 0 后别人把工位改成 1：CAS 失败 → conflict，余额回到原值。"""
    out = run("""
        __reset()
        __seed('mining_co', 1000000)
        __facilitySeed('mining_co', { workstations = 0 })

        __facilityRace = function()
            __facilities['mining_co'].workstations = 1
        end

        local ok, err = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h1' })

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('WS', tostring(__facility('mining_co').workstations))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEDGER', tostring(__ledgerCount()))
        local deltas = {}
        for _, row in ipairs(__ledger) do deltas[#deltas + 1] = tostring(row.delta) end
        __emit('DELTAS', table.concat(deltas, ','))
        local last = __audits[#__audits]
        __emit('AUDIT_RESULT', last and last.payload:match('"result":"([^"]+)"') or 'nil')
    """)
    assert out["OK"] == "false", "CAS 冲突时必须失败"
    assert out["ERR"] == "conflict", f"错误码必须是 conflict，实际 {out['ERR']}"
    assert out["WS"] == "1", "冲突后不能覆盖别人写入的工位数"
    assert out["BAL"] == "1000000", "冲突后扣款没有退回"
    assert out["LEDGER"] == "2", "应先扣款再补偿（两条流水）"
    assert out["DELTAS"] == "-50000,50000", f"补偿流水不对：{out['DELTAS']}"
    assert out["AUDIT_RESULT"] == "conflict"


# ══════════════════════════════════════════════════════════════════
# Q3 余额不足 / Build 幂等 / 回滚
# ══════════════════════════════════════════════════════════════════


def test_insufficient_funds_leaves_no_facility_and_no_charge():
    out = run("""
        __reset()
        __seed('mining_co', 49999)

        local ok1, e1 = Facility.Build('mining_co', 'mine', { actor = 'cid1', ref = 'b1' })
        __emit('BUILD_OK', tostring(ok1))
        __emit('BUILD_ERR', tostring(e1 or 'nil'))
        __emit('FACILITIES', tostring(__facilityCount()))
        __emit('BAL1', tostring(__balance('mining_co')))
        __emit('LEDGER1', tostring(__ledgerCount()))

        __facilitySeed('mining_co', { workstations = 0 })
        local ok2, e2 = Facility.AddWorkstation('mining_co', { actor = 'cid1', ref = 'h1' })
        __emit('HIRE_OK', tostring(ok2))
        __emit('HIRE_ERR', tostring(e2 or 'nil'))
        __emit('WS', tostring(__facility('mining_co').workstations))
        __emit('BAL2', tostring(__balance('mining_co')))
        __emit('LEDGER2', tostring(__ledgerCount()))
    """)
    assert out["BUILD_OK"] == "false" and out["BUILD_ERR"] == "insufficient_funds", (
        f"余额不足应返回 insufficient_funds：{out}"
    )
    assert out["FACILITIES"] == "0", "余额不足时仍建了设施行"
    assert out["BAL1"] == "49999" and out["LEDGER1"] == "0", "余额不足时动了钱"
    assert out["HIRE_OK"] == "false" and out["HIRE_ERR"] == "insufficient_funds"
    assert out["WS"] == "0" and out["BAL2"] == "49999" and out["LEDGER2"] == "0"


def test_build_is_idempotent_and_audits_both_attempts():
    out = run("""
        __reset()
        __seed('mining_co', 1000000)

        local ok1 = Facility.Build('mining_co', 'mine', { actor = 'cid1', ref = 'b1' })
        local balanceAfterFirst = __balance('mining_co')
        local ok2, e2 = Facility.Build('mining_co', 'mine', { actor = 'cid1', ref = 'b2' })

        __emit('OK1', tostring(ok1))
        __emit('OK2', tostring(ok2))
        __emit('ERR2', tostring(e2 or 'nil'))
        __emit('FACILITIES', tostring(__facilityCount()))
        __emit('BAL_UNCHANGED', tostring(__balance('mining_co') == balanceAfterFirst))

        local results = {}
        for _, entry in ipairs(__audits) do
            if entry.action == 'facility.build' then
                results[#results + 1] = entry.payload:match('"result":"([^"]+)"') or '?'
            end
        end
        __emit('RESULTS', table.concat(results, ','))
    """)
    assert out["OK1"] == "true", "第一次建设施失败"
    assert out["OK2"] == "false" and out["ERR2"] == "already_built", (
        f"重复建设施应返回 already_built：{out}"
    )
    assert out["FACILITIES"] == "1", "一组织一设施：不能产生第二行"
    assert out["BAL_UNCHANGED"] == "true", "重复建设施又扣了一次钱"
    assert out["RESULTS"] == "ok,already_built", (
        f"成功与失败都必须写审计：{out['RESULTS']}"
    )


def test_build_rolls_the_payment_back_when_the_insert_fails():
    out = run("""
        __reset()
        __seed('mining_co', 1000000)
        __failFacilityInsert = true

        local ok, err = Facility.Build('mining_co', 'mine', { actor = 'cid1', ref = 'b1' })

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('FACILITIES', tostring(__facilityCount()))
        __emit('LEDGER', tostring(__ledgerCount()))
        local deltas = {}
        for _, row in ipairs(__ledger) do deltas[#deltas + 1] = tostring(row.delta) end
        __emit('DELTAS', table.concat(deltas, ','))
        local last = __audits[#__audits]
        __emit('AUDIT_RESULT', last and last.payload:match('"result":"([^"]+)"') or 'nil')
    """)
    assert out["OK"] == "false" and out["ERR"] == "db_error", (
        f"设施行写失败应返回 db_error：{out}"
    )
    assert out["BAL"] == "1000000", "设施行写失败后钱没有退回（钱少了、设施没建）"
    assert out["FACILITIES"] == "0"
    assert out["LEDGER"] == "2" and out["DELTAS"] == "-50000,50000", (
        f"回滚流水不对：{out['DELTAS']}"
    )
    assert out["AUDIT_RESULT"] == "db_error"


# ══════════════════════════════════════════════════════════════════
# Q1 迁移 / fixture
# ══════════════════════════════════════════════════════════════════


def test_migration_and_fixture_declare_industry_facility():
    for label, path in (("迁移", MIGRATION), ("fixture", SCHEMA_FIXTURE)):
        text = path.read_text(encoding="utf-8")
        assert re.search(r"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+`industry_facility`", text, re.I), (
            f"{label}里没有建 industry_facility：{path}"
        )
        assert "PRIMARY KEY (`org_id`)" in text, f"{label}缺少 org_id 主键"
        assert "idx_facility_type" in text, f"{label}缺少 idx_facility_type"


# ══════════════════════════════════════════════════════════════════
# Q5 接线：加载 fxmanifest 的全部 server 脚本，不提供全局 QBCore
# ══════════════════════════════════════════════════════════════════

def test_all_server_scripts_register_all_commands_without_global_qbcore():
    """S1 真机教训：只加载单个文件看不见跨脚本作用域；这里按 manifest 全加载。"""
    out = run_wiring(debug=False)

    expected = {
        "orgfund", "orgfunddeposit", "orgfundwithdraw", "orgfundgrant",
        "orgbuild", "orghire", "orgfacility",
    }
    assert out["COUNT"] == "7", f"命令没有全部注册（生产表现：资源 Started、命令为空）：{out}"
    assert sorted(out["NAMES"].split(",")) == sorted(expected), (
        f"注册的命令名不对：{out['NAMES']}"
    )
    assert out["HAS_GLOBAL"] == "false", (
        "用例自己定义了全局 QBCore —— 生产环境缺它的 bug 会被永远掩盖"
    )


# ══════════════════════════════════════════════════════════════════
# P3（#411）库存等级：上限曲线 / 价格曲线 / 升级扣款 / Boss 闸门
# ══════════════════════════════════════════════════════════════════


def test_stock_upgrade_config_cap_and_price_curve():
    """上限 = 540 + 900 × 等级（0–6）；价格 = floor(40000 × 1.6^等级)。"""
    out = run("""
        local mine = Config.Industry.Facilities.mine
        __emit('BASE_CAP', tostring(mine.stockCap))
        __emit('STEP', tostring(mine.stockCapPerLevel))
        __emit('MAX_LEVEL', tostring(mine.stockLevelMax))
        __emit('BASE_COST', tostring(mine.stockUpgradeBaseCost))
        __emit('GROWTH', tostring(mine.stockUpgradeGrowth))

        local caps, costs = {}, {}
        for level = 0, 7 do
            caps[#caps + 1] = tostring(Facility.StockCapFor(level, 'mine'))
            costs[#costs + 1] = tostring(Facility.StockUpgradeCost('mine', level) or 'nil')
        end
        __emit('CAPS', table.concat(caps, ','))
        __emit('COSTS', table.concat(costs, ','))
        __emit('NEGATIVE', tostring(Facility.StockCapFor(-3, 'mine')))
    """)
    assert out["BASE_CAP"] == "540", "#387 数值卡：基础上限必须保持 540"
    assert out["STEP"] == "900", "每级增量必须是 +900"
    assert out["MAX_LEVEL"] == "6", "库存等级范围必须是 0–6"
    assert out["BASE_COST"] == "40000"
    assert out["GROWTH"] == "1.6"
    assert out["CAPS"] == "540,1440,2340,3240,4140,5040,5940,5940", (
        f"库存上限曲线不对：{out['CAPS']}"
    )
    # 6 级是上限：0→1 … 5→6 共六次可买，6 级再问价格必须是 nil。
    assert out["COSTS"] == "40000,64000,102400,163840,262144,419430,nil,nil", (
        f"升级价格曲线不对：{out['COSTS']}"
    )
    assert out["NEGATIVE"] == "540", "非法负等级必须夹回 0"


def test_upgrade_stock_charges_treasury_and_returns_new_cap():
    """1→2→3 级：每次只走 Treasury，余额按 40k/64k/102.4k 递减。"""
    out = run(STOCK_UPGRADE_DB + """
        __reset()
        __seed('mining_co', 1000000)
        __facilitySeed('mining_co', { workstations = 3 })
        __facilities['mining_co'].stock_level = 0

        local ok1, err1, cost1, level1, cap1 = Facility.UpgradeStock(
            'mining_co', { actor = 'cid1', ref = 'su1' })
        local ok2, err2, cost2, level2, cap2 = Facility.UpgradeStock(
            'mining_co', { actor = 'cid1', ref = 'su2' })
        local ok3, err3, cost3, level3, cap3 = Facility.UpgradeStock(
            'mining_co', { actor = 'cid1', ref = 'su3' })

        __emit('OKS', table.concat({ tostring(ok1), tostring(ok2), tostring(ok3) }, ','))
        __emit('ERRS', table.concat({
            tostring(err1 or 'nil'), tostring(err2 or 'nil'), tostring(err3 or 'nil'),
        }, ','))
        __emit('COSTS', table.concat({ tostring(cost1), tostring(cost2), tostring(cost3) }, ','))
        __emit('LEVELS', table.concat({ tostring(level1), tostring(level2), tostring(level3) }, ','))
        __emit('CAPS', table.concat({ tostring(cap1), tostring(cap2), tostring(cap3) }, ','))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('STOCK_LEVEL', tostring(__facility('mining_co').stock_level))
        __emit('LEDGER', tostring(__ledgerCount()))
        local deltas = {}
        for _, row in ipairs(__ledger) do deltas[#deltas + 1] = tostring(row.delta) end
        __emit('DELTAS', table.concat(deltas, ','))
        local payload = __lastAuditPayload('facility.stock_upgrade') or ''
        __emit('AUDIT', (payload:match('"result":"([^"]+)"') or '?') .. ':'
            .. (payload:match('"stock_level":(%d+)') or '?'))
    """)
    assert out["OKS"] == "true,true,true", f"三级升级应全部成功：{out}"
    assert out["ERRS"] == "nil,nil,nil"
    assert out["COSTS"] == "40000,64000,102400", f"价格曲线不对：{out['COSTS']}"
    assert out["LEVELS"] == "1,2,3"
    assert out["CAPS"] == "1440,2340,3240", f"升级后的上限不对：{out['CAPS']}"
    assert out["BAL"] == "793600", f"金库扣款合计不对：{out['BAL']}"
    assert out["STOCK_LEVEL"] == "3"
    assert out["LEDGER"] == "3", f"每次升级都应有 Treasury 流水：{out}"
    assert out["DELTAS"] == "-40000,-64000,-102400"
    assert out["AUDIT"] == "ok:3", f"审计缺结果或等级：{out['AUDIT']}"


def test_upgrade_stock_insufficient_funds_leaves_everything_untouched():
    out = run(STOCK_UPGRADE_DB + """
        __reset()
        __seed('mining_co', 63999)
        __facilitySeed('mining_co', { workstations = 3 })
        __facilities['mining_co'].stock_level = 1

        local ok, err = Facility.UpgradeStock('mining_co', { actor = 'cid1', ref = 'su1' })

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEVEL', tostring(__facility('mining_co').stock_level))
        __emit('LEDGER', tostring(__ledgerCount()))
    """)
    assert out["OK"] == "false" and out["ERR"] == "insufficient_funds", (
        f"余额 63,999 < 64,000 时必须拒绝：{out}"
    )
    assert out["BAL"] == "63999", "被拒的升级动了金库"
    assert out["LEVEL"] == "1" and out["LEDGER"] == "0"


def test_upgrade_stock_rejects_at_max_level_without_charging():
    out = run(STOCK_UPGRADE_DB + """
        __reset()
        __seed('mining_co', 1000000)
        __facilitySeed('mining_co', { workstations = 3 })
        __facilities['mining_co'].stock_level = 6

        local ok, err = Facility.UpgradeStock('mining_co', { actor = 'cid1', ref = 'su1' })

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEVEL', tostring(__facility('mining_co').stock_level))
        __emit('LEDGER', tostring(__ledgerCount()))
        __emit('NEXT', tostring(Facility.StockUpgradeCost('mine', 6) or 'nil'))
        __emit('CAP', tostring(Facility.StockCapFor(6, 'mine')))
    """)
    assert out["OK"] == "false" and out["ERR"] == "max_level", (
        f"满级必须拒绝：{out}"
    )
    assert out["BAL"] == "1000000" and out["LEVEL"] == "6" and out["LEDGER"] == "0"
    assert out["NEXT"] == "nil", "满级后快照不能给出下一级价格"
    assert out["CAP"] == "5940", "满级上限必须是 540 + 900 × 6"


def test_upgrade_stock_cas_conflict_refunds_the_payment():
    """预读 0 级后别人先升到 1 级：CAS 失败 → conflict，钱原路退回。"""
    out = run(STOCK_UPGRADE_DB + """
        __reset()
        __seed('mining_co', 1000000)
        __facilitySeed('mining_co', { workstations = 3 })
        __facilities['mining_co'].stock_level = 0
        __stockRace = function()
            __facilities['mining_co'].stock_level = 1
        end

        local ok, err = Facility.UpgradeStock('mining_co', { actor = 'cid1', ref = 'su1' })
        local deltas = {}
        for _, row in ipairs(__ledger) do deltas[#deltas + 1] = tostring(row.delta) end

        __emit('OK', tostring(ok))
        __emit('ERR', tostring(err or 'nil'))
        __emit('BAL', tostring(__balance('mining_co')))
        __emit('LEVEL', tostring(__facility('mining_co').stock_level))
        __emit('LEDGER', tostring(__ledgerCount()))
        __emit('DELTAS', table.concat(deltas, ','))
    """)
    assert out["OK"] == "false" and out["ERR"] == "conflict", (
        f"CAS 冲突必须报 conflict：{out}"
    )
    assert out["BAL"] == "1000000", "冲突后扣款没有退回"
    assert out["LEVEL"] == "1", "冲突后不能覆盖别人写入的等级"
    assert out["LEDGER"] == "2" and out["DELTAS"] == "-40000,40000", (
        f"退款流水不对：{out['DELTAS']}"
    )


def test_snapshot_exposes_stock_level_and_next_upgrade_cost():
    out = run_ui("""
        __reset()
        __seedOrg('mining_co', 1000000)
        __seedFacilityRow('mining_co', 42, { workstations = 3, level = 1, produced_units = 7 })
        __facilityRows['mining_co'].stock_level = 1
        __seedDemand('iron_ore', 10, 0)

        local snap = IndustryUi.Snapshot(boss(), 'mining_co')
        __emit('L1_LEVEL', tostring(snap and snap.facility and snap.facility.stockLevel))
        __emit('L1_MAX', tostring(snap and snap.facility and snap.facility.stockMaxLevel))
        __emit('L1_CAP', tostring(snap and snap.facility and snap.facility.stockCap))
        __emit('L1_NEXT', tostring(snap and snap.facility and snap.facility.nextStockUpgradeCost))
        __emit('L1_BLOCK', tostring(snap and snap.facility and snap.facility.stockUpgradeBlocked))

        __facilityRows['mining_co'].stock_level = 6
        local maxed = IndustryUi.Snapshot(boss(), 'mining_co')
        __emit('MAX_LEVEL', tostring(maxed and maxed.facility and maxed.facility.stockLevel))
        __emit('MAX_CAP', tostring(maxed and maxed.facility and maxed.facility.stockCap))
        __emit('MAX_NEXT', tostring(maxed and maxed.facility and maxed.facility.nextStockUpgradeCost))
        __emit('MAX_BLOCK', tostring(maxed and maxed.facility and maxed.facility.stockUpgradeBlocked))
    """)
    assert out["L1_LEVEL"] == "1" and out["L1_MAX"] == "6", f"快照缺库存等级：{out}"
    assert out["L1_CAP"] == "1440", f"快照的 stockCap 没按等级算：{out}"
    assert out["L1_NEXT"] == "64000", f"下一级价格不对：{out}"
    assert out["L1_BLOCK"] == "nil"
    assert out["MAX_LEVEL"] == "6" and out["MAX_CAP"] == "5940"
    assert out["MAX_NEXT"] == "nil", "满级快照必须给 nil（手机端据此禁用）"
    assert out["MAX_BLOCK"] == "max_level"


def test_upgrade_stock_is_boss_only_and_non_boss_is_not_charged():
    """服务端判 Boss：成员 / 外部玩家都拿不到升级，金库分文不动。"""
    out = run_ui(STOCK_UPGRADE_DB + """
        __reset()
        __seedOrg('mining_co', 1000000)
        __seedFacilityRow('mining_co', 0, { workstations = 3 })
        __facilityRows['mining_co'].stock_level = 0

        local ok, err = IndustryUi.UpgradeStock(member(), 'mining_co')
        __emit('MEMBER_OK', tostring(ok))
        __emit('MEMBER_ERR', tostring(err or 'nil'))
        __emit('BAL_AFTER_MEMBER', tostring(__balance('mining_co')))
        __emit('LEVEL_AFTER_MEMBER', tostring(__facilityRows['mining_co'].stock_level))
        __emit('LEDGER_AFTER_MEMBER', tostring(#__ledger))

        local _, outsiderErr = IndustryUi.UpgradeStock(outsider(), 'mining_co')
        __emit('OUTSIDER_ERR', tostring(outsiderErr or 'nil'))

        local bossOk, bossErr, cost, level, cap = IndustryUi.UpgradeStock(boss(), 'mining_co')
        __emit('BOSS_OK', tostring(bossOk))
        __emit('BOSS_ERR', tostring(bossErr or 'nil'))
        __emit('BOSS_COST', tostring(cost))
        __emit('BOSS_LEVEL', tostring(level))
        __emit('BOSS_CAP', tostring(cap))
        __emit('BOSS_BAL', tostring(__balance('mining_co')))
    """)
    assert out["MEMBER_OK"] == "false" and out["MEMBER_ERR"] == "not_boss", (
        f"普通成员调用升级必须被服务端拒：{out}"
    )
    assert out["BAL_AFTER_MEMBER"] == "1000000", "非 Boss 被拒后仍扣了钱"
    assert out["LEVEL_AFTER_MEMBER"] == "0" and out["LEDGER_AFTER_MEMBER"] == "0"
    assert out["OUTSIDER_ERR"] == "not_member"
    assert out["BOSS_OK"] == "true" and out["BOSS_ERR"] == "nil", f"Boss 升级失败：{out}"
    assert out["BOSS_COST"] == "40000" and out["BOSS_LEVEL"] == "1" and out["BOSS_CAP"] == "1440"
    assert out["BOSS_BAL"] == "960000"


def test_stock_level_migration_is_idempotent_and_reflected_in_fixture():
    text = MIGRATION_STOCK.read_text(encoding="utf-8")
    assert "stock_level" in text and re.search(r"TINYINT", text, re.I), (
        "v4.6 迁移必须加 stock_level TINYINT"
    )
    assert "information_schema.COLUMNS" in text, "必须用 information_schema 判存在"
    assert "PREPARE" in text and "DEALLOCATE PREPARE" in text, (
        "必须沿用 v4.3 的 PREPARE/EXECUTE 幂等形状"
    )
    assert re.search(r"DEFAULT\s+0", text, re.I), "stock_level 默认值必须是 0"

    fixture = SCHEMA_FIXTURE.read_text(encoding="utf-8")
    assert re.search(r"`stock_level`\s+tinyint", fixture, re.I), (
        "tests/fixtures/tcity_schema.sql 必须反映 v4.6 的新列"
    )
