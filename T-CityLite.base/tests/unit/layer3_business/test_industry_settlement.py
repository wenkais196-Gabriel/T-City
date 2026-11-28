"""S7 结算 / 转生：清分边界、幂等、崩溃恢复、个人层字节级不变。

四件事里最贵的是第三件：**结算抹到个人层**是整条链里风险最高的删除。这里用
三层证明：

1. 运行时假 DB 对任何提到 `players` 的 SQL 直接 error（触碰即爆炸）；
2. 结算前后对个人层数据做 canonical 串的 checksum，必须逐字节一致（实际值贴进报告）；
3. 静态扫描 settlement.lua 的写语句，只允许产业层表；扫描器本身有注入用例证明会红。

其余：
  * `UNIQUE(org_id, cycle_no)` 是结算幂等键，第二次调用直接 already_settled；
  * 结算中途崩溃（prestige 写入前 / applied 标记前）重试不重复发威望；
  * dry-run 只读，`__sqlWrites == 0`；
  * 公告失败不阻断结算，恢复后补发一次。
"""

from __future__ import annotations

import re
import sys

from industry_harness import (
    ANNOUNCE_SRC,
    BASE,
    COMMANDS_CYCLE_SRC,
    CYCLE_SRC,
    MIGRATION_CYCLE,
    SCHEMA_FIXTURE,
    SETTLEMENT_SRC,
    TABLE_OWNERS,
    TRUE,
    run_full as run,
    strip_sql_comments,
)

sys.path.insert(0, str(BASE / "tests" / "architecture"))
import lua_source  # noqa: E402

MIGRATION = MIGRATION_CYCLE


SEED = """
    __reset()
    __seedState({ cycle_no = 1, phase = 'recession', started_epoch = 0, ends_epoch = 100000 })
    __seedTreasury('mining_co', 500, 0)
    __seedFacility('mining_co', {
        stock = 40, workstations = 3, produced_units = 777, last_tick_epoch = 100000,
    })
    __seedSale('mining_co', 1, 'iron_ore', 100, 50, 30000)
    __seedSale('mining_co', 1, 'iron_ore', 100, 50, 20000)
    __seedDemand(1, 'expansion', 'iron_ore', 10, 0)
    __seedDemand(1, 'recession', 'iron_ore', 4, 2)
    __seedPlayers({
        ap = { citizenid = 'ap', money = '{"cash":100,"bank":200}',
               inventory = '[{"name":"water","count":2}]' },
        bq = { citizenid = 'bq', money = '{"cash":5,"bank":7}',
               inventory = '[]', vehicles = '[{"plate":"ABC123"}]' },
    })
"""

PRESTIGE_CONVARS = {"industry_prestige_k": "500"}


# ══════════════════════════════════════════════════════════════════
# 1. dry-run：只打印，不写库
# ══════════════════════════════════════════════════════════════════


def test_dry_run_reports_counts_and_writes_nothing():
    out = run(SEED + """
        local report, err = IndustrySettlement.Preview(1)
        __emit('OK', tostring(report ~= nil) .. ':' .. tostring(err or 'nil'))
        __emit('ORGS', tostring(report and report.orgs))
        __emit('RESULTS', tostring(report and report.results))
        __emit('FACILITY', tostring(report and report.facility_rows))
        __emit('SALES', tostring(report and report.sales_rows))
        __emit('DEMAND', tostring(report and report.demand_rows))
        __emit('TREASURY', tostring(report and report.treasury_rows))
        __emit('BALANCE', tostring(report and report.treasury_balance))
        __emit('PRESTIGE', tostring(report and report.prestige_awarded))
        __emit('WRITES', tostring(__sqlWrites()))
        __emit('FACILITY_ROWS_LEFT', tostring(__facilityCount()))
        __emit('DEMAND_LEFT', tostring(__demandCount(1)))
        __emit('RESULTS_LEFT', tostring(__resultCount(1)))
        __emit('BAL_AFTER', tostring(__treasury('mining_co').balance))
    """, convars=PRESTIGE_CONVARS)

    assert out["OK"] == "true:nil", f"Preview 失败：{out}"
    assert out["ORGS"] == "1"
    assert out["RESULTS"] == "1", "将写的结果行数不对"
    assert out["FACILITY"] == "1"
    assert out["SALES"] == "2"
    assert out["DEMAND"] == "2"
    assert out["TREASURY"] == "1"
    assert out["BALANCE"] == "500"
    assert out["PRESTIGE"] == "10", "floor(sqrt(50000 / 500)) 应为 10"
    assert out["WRITES"] == "0", f"dry-run 写了库：{out}"
    assert out["FACILITY_ROWS_LEFT"] == "1"
    assert out["DEMAND_LEFT"] == "2"
    assert out["RESULTS_LEFT"] == "0"
    assert out["BAL_AFTER"] == "500"


# ══════════════════════════════════════════════════════════════════
# 2. 真结算：产业层全清 + prestige + 结果表 + 审计
# ══════════════════════════════════════════════════════════════════


def test_settlement_clears_industry_layer_and_awards_prestige():
    out = run(SEED + """
        local before = __playersChecksum()
        local ok, err, summary = IndustrySettlement.SettleCycle(1, { trigger = 'test' })
        local after = __playersChecksum()
        local treasury = __treasury('mining_co')
        local result = __result('mining_co', 1)
        local ledger = __ledgerRow('settle:1')

        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('SETTLED', tostring(summary and summary.settled))
        __emit('FACILITY_ROWS', tostring(__facilityCount()))
        __emit('SALES_ROWS', tostring(__salesCount()))
        __emit('DEMAND_ROWS', tostring(__demandCount(1)))
        __emit('BALANCE', tostring(treasury.balance))
        __emit('PRESTIGE', tostring(treasury.prestige))
        __emit('TREASURY_CYCLE', tostring(treasury.cycle_no))
        __emit('RESULTS', tostring(__resultCount(1)))
        __emit('REVENUE', tostring(result and result.revenue))
        __emit('PRODUCED', tostring(result and result.produced_units))
        __emit('APPLIED', tostring(result and result.applied))
        __emit('PRESTIGE_AWARDED', tostring(result and result.prestige_awarded))
        __emit('LEDGER_DELTA', tostring(ledger and ledger.delta))
        __emit('LEDGER_REASON', tostring(ledger and ledger.reason))
        __emit('AUDIT', tostring(__auditCount('cycle.settle')))
        __emit('BULLETINS', tostring(__bulletinCount()))
        __emit('PERSONAL_SQL', tostring(__personalViolations()))
        __emit('PLAYERS_BEFORE', before)
        __emit('PLAYERS_AFTER', after)
        print('PLAYERS_BEFORE=' .. before)
        print('PLAYERS_AFTER=' .. after)
    """, convars=PRESTIGE_CONVARS)

    print("PLAYERS_BEFORE=" + out["PLAYERS_BEFORE"])
    print("PLAYERS_AFTER=" + out["PLAYERS_AFTER"])
    assert out["OK"] == "true:nil", f"结算失败：{out}"
    assert out["SETTLED"] == "1"
    assert out["FACILITY_ROWS"] == "0", "设施（含库存）没有清零"
    assert out["SALES_ROWS"] == "0", "本周期卖单没有清"
    assert out["DEMAND_ROWS"] == "0", "本周期配额没有清"
    assert out["BALANCE"] == "0", "金库余额没有清零"
    assert out["PRESTIGE"] == "10"
    assert out["TREASURY_CYCLE"] == "1"
    assert out["RESULTS"] == "1", "结果表必须恰好一行"
    assert out["REVENUE"] == "50000"
    assert out["PRODUCED"] == "777"
    assert out["APPLIED"] == "1"
    assert out["PRESTIGE_AWARDED"] == "10"
    assert out["LEDGER_DELTA"] == "-500", "清掉的余额必须写一条流水"
    assert out["LEDGER_REASON"] == "settlement-clear"
    assert out["AUDIT"] == "1"
    assert out["BULLETINS"] == "1"
    assert out["PERSONAL_SQL"] == "0", "结算对个人层发过 SQL（即使写失败也算越界）"
    assert out["PLAYERS_BEFORE"] == out["PLAYERS_AFTER"], (
        "结算改动了个人层："
        f"{out['PLAYERS_BEFORE']} != {out['PLAYERS_AFTER']}"
    )


def test_cycle_boundary_settles_industry_layer_before_advancing():
    """验收口径：压缩跑完一周期 → 设施 0 / 库存 0 / 金库 0 / prestige +N / 结果 1 行。"""
    out = run(SEED + """
        __state.ends_epoch = 1000
        local ok, err, info = IndustryCycle.Tick(1000)
        local state = __stateRow()
        local result = __result('mining_co', 1)
        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('ADVANCED_TO', tostring(info and info.to))
        __emit('PHASE', state.phase)
        __emit('CYCLE', tostring(state.cycle_no))
        __emit('SETTLED', tostring(state.settled_cycle_no))
        __emit('FACILITY_ROWS', tostring(__facilityCount()))
        __emit('SALES_ROWS', tostring(__salesCount()))
        __emit('DEMAND_ROWS', tostring(__demandCount(1)))
        __emit('BALANCE', tostring(__treasury('mining_co').balance))
        __emit('PRESTIGE', tostring(__treasury('mining_co').prestige))
        __emit('RESULTS', tostring(__resultCount(1)))
        __emit('RESULT_REVENUE', tostring(result and result.revenue))
        __emit('BULLETIN_IS_RESULT', tostring(
            __lastBulletin() and __lastBulletin():find('已结算', 1, true) ~= nil))
    """, convars=PRESTIGE_CONVARS)

    assert out["OK"] == "true:nil", f"周期边界 tick 失败：{out}"
    assert out["ADVANCED_TO"] == "expansion"
    assert out["PHASE"] == "expansion"
    assert out["CYCLE"] == "2", "结算后必须进入下一轮"
    assert out["SETTLED"] == "1"
    assert out["FACILITY_ROWS"] == "0", "设施/库存没有清"
    assert out["SALES_ROWS"] == "0"
    assert out["DEMAND_ROWS"] == "0"
    assert out["BALANCE"] == "0"
    assert out["PRESTIGE"] == "10"
    assert out["RESULTS"] == "1"
    assert out["RESULT_REVENUE"] == "50000"
    assert out["BULLETIN_IS_RESULT"] == TRUE, "结算结果公告没有发出"


# ══════════════════════════════════════════════════════════════════
# 3. 反例：同 (org_id, cycle_no) 第二次结算被拒
# ══════════════════════════════════════════════════════════════════


def test_second_settlement_of_same_org_and_cycle_is_rejected():
    out = run(SEED + """
        IndustrySettlement.SettleCycle(1, { trigger = 'first' })
        local writes_after_first = __sqlWrites()
        local bullets_after_first = __bulletinCount()

        local ok, err, summary = IndustrySettlement.SettleCycle(1, { trigger = 'second' })
        __emit('SECOND_OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('ALREADY', tostring(summary and summary.already_settled))
        __emit('WRITES_ADDED', tostring(__sqlWrites() - writes_after_first))
        __emit('RESULTS', tostring(__resultCount(1)))
        __emit('PRESTIGE', tostring(__treasury('mining_co').prestige))
        __emit('LEDGER', tostring(__ledgerCount()))
        __emit('BULLETINS_ADDED', tostring(__bulletinCount() - bullets_after_first))
    """, convars=PRESTIGE_CONVARS)

    assert out["SECOND_OK"] == "true:nil", f"重复结算应被幂等拒绝而不是报错：{out}"
    assert out["ALREADY"] == TRUE, "第二次结算没有走 already_settled"
    assert out["WRITES_ADDED"] == "0", "重复结算写了库"
    assert out["RESULTS"] == "1"
    assert out["PRESTIGE"] == "10", "重复结算又发了一次 prestige"
    assert out["LEDGER"] == "1"
    assert out["BULLETINS_ADDED"] == "0", "重复结算重复公告"


# ══════════════════════════════════════════════════════════════════
# 4. 崩溃恢复：结果已写、清分没跑完，重试不重复发
# ══════════════════════════════════════════════════════════════════


def test_retry_after_crash_before_treasury_applies_prestige_once():
    out = run(SEED + """
        __failNextSettlementUpdate = true
        local first, firstErr = IndustrySettlement.SettleCycle(1, { trigger = 'crash' })
        local crashedResult = __result('mining_co', 1)
        __emit('FIRST', tostring(first) .. ':' .. tostring(firstErr or 'nil'))
        __emit('FIRST_APPLIED', tostring(crashedResult and crashedResult.applied))
        __emit('FIRST_BALANCE', tostring(__treasury('mining_co').balance))
        __emit('FIRST_SETTLED', tostring(__stateRow().settled_cycle_no))

        local second, secondErr = IndustrySettlement.SettleCycle(1, { trigger = 'retry' })
        local result = __result('mining_co', 1)
        __emit('SECOND', tostring(second) .. ':' .. tostring(secondErr or 'nil'))
        __emit('PRESTIGE', tostring(__treasury('mining_co').prestige))
        __emit('APPLIED', tostring(result and result.applied))
        __emit('SETTLED', tostring(__stateRow().settled_cycle_no))
        __emit('RESULTS', tostring(__resultCount(1)))
    """, convars=PRESTIGE_CONVARS)

    assert out["FIRST"] == "false:db_error", f"注入的失败没有生效：{out}"
    assert out["FIRST_APPLIED"] == "0", "结果行必须在崩溃后保留为未完成"
    assert out["FIRST_BALANCE"] == "500", "失败方向应是「钱没动」"
    assert out["FIRST_SETTLED"] == "0", "结算没完成却推进了 settled_cycle_no"
    assert out["SECOND"] == "true:nil", f"重试没有成功：{out}"
    assert out["PRESTIGE"] == "10", "重试重复累加了 prestige"
    assert out["APPLIED"] == "1"
    assert out["SETTLED"] == "1"
    assert out["RESULTS"] == "1", "重试插了第二行结果"


def test_retry_after_crash_between_deletes_converges_and_writes_exactly_one_audit():
    """「删到一半进程没了」：设施已删、卖单还没删，applied 仍是 0。

    重跑必须收敛到同一结果（设施/卖单/配额/余额全 0、prestige 只发一次），
    且审计里 `cycle.settle` **恰好一条** —— 第一次失败不能留半条成功审计。
    """
    out = run(SEED + """
        local before = __playersChecksum()

        __failNextSalesDelete = true
        local first, firstErr = IndustrySettlement.SettleCycle(
            1, { trigger = 'crash-mid-delete' })
        __emit('FIRST', tostring(first) .. ':' .. tostring(firstErr or 'nil'))
        __emit('FACILITY_AFTER_FIRST', tostring(__facilityCount()))
        __emit('SALES_AFTER_FIRST', tostring(__salesCount()))
        __emit('DEMAND_AFTER_FIRST', tostring(__demandCount(1)))
        __emit('BALANCE_AFTER_FIRST', tostring(__treasury('mining_co').balance))
        __emit('PRESTIGE_AFTER_FIRST', tostring(__treasury('mining_co').prestige))
        __emit('APPLIED_AFTER_FIRST', tostring(__result('mining_co', 1).applied))
        __emit('SETTLED_AFTER_FIRST', tostring(__stateRow().settled_cycle_no))
        __emit('AUDIT_AFTER_FIRST', tostring(__auditCount('cycle.settle')))

        local second, secondErr = IndustrySettlement.SettleCycle(1, { trigger = 'retry' })
        local after = __playersChecksum()
        __emit('SECOND', tostring(second) .. ':' .. tostring(secondErr or 'nil'))
        __emit('FACILITY', tostring(__facilityCount()))
        __emit('SALES', tostring(__salesCount()))
        __emit('DEMAND', tostring(__demandCount(1)))
        __emit('BALANCE', tostring(__treasury('mining_co').balance))
        __emit('PRESTIGE', tostring(__treasury('mining_co').prestige))
        __emit('RESULTS', tostring(__resultCount(1)))
        __emit('APPLIED', tostring(__result('mining_co', 1).applied))
        __emit('SETTLED', tostring(__stateRow().settled_cycle_no))
        __emit('AUDIT', tostring(__auditCount('cycle.settle')))
        __emit('PLAYERS_BEFORE', before)
        __emit('PLAYERS_AFTER', after)
    """, convars=PRESTIGE_CONVARS)

    assert out["FIRST"] == "false:db_error", f"注入的删除失败没有生效：{out}"
    assert out["FACILITY_AFTER_FIRST"] == "0", "崩溃前已完成的设施删除不该回滚"
    assert out["SALES_AFTER_FIRST"] == "2", "卖单删除失败后不应被标记为完成"
    assert out["DEMAND_AFTER_FIRST"] == "2", "失败时不该清全服配额"
    assert out["BALANCE_AFTER_FIRST"] == "0", "金库清零是幂等绝对值，崩溃后保持 0"
    assert out["PRESTIGE_AFTER_FIRST"] == "10", "prestige 是绝对值，崩溃后保持 10"
    assert out["APPLIED_AFTER_FIRST"] == "0", "崩溃后结果行必须保持未完成"
    assert out["SETTLED_AFTER_FIRST"] == "0", "失败时推进了 settled_cycle_no"
    assert out["AUDIT_AFTER_FIRST"] == "0", "失败路径写了成功审计"

    assert out["SECOND"] == "true:nil", f"重跑没有收敛：{out}"
    assert out["FACILITY"] == "0"
    assert out["SALES"] == "0"
    assert out["DEMAND"] == "0"
    assert out["BALANCE"] == "0"
    assert out["PRESTIGE"] == "10", "重跑重复发了 prestige"
    assert out["RESULTS"] == "1", "重跑插了第二行结果"
    assert out["APPLIED"] == "1"
    assert out["SETTLED"] == "1"
    assert out["AUDIT"] == "1", "审计里必须恰好一条 cycle.settle"
    assert out["PLAYERS_BEFORE"] == out["PLAYERS_AFTER"], (
        "崩溃恢复路径改动了个人层："
        f"{out['PLAYERS_BEFORE']} != {out['PLAYERS_AFTER']}"
    )


def test_retry_after_crash_before_applied_marker_does_not_double_prestige():
    out = run(SEED + """
        __failNextAppliedUpdate = true
        local first, firstErr = IndustrySettlement.SettleCycle(1, { trigger = 'crash' })
        __emit('FIRST', tostring(first) .. ':' .. tostring(firstErr or 'nil'))
        __emit('FIRST_PRESTIGE', tostring(__treasury('mining_co').prestige))
        __emit('FIRST_APPLIED', tostring(__result('mining_co', 1).applied))
        __emit('FACILITY_AFTER_FIRST', tostring(__facilityCount()))

        local second = IndustrySettlement.SettleCycle(1, { trigger = 'retry' })
        __emit('SECOND', tostring(second))
        __emit('PRESTIGE', tostring(__treasury('mining_co').prestige))
        __emit('APPLIED', tostring(__result('mining_co', 1).applied))
        __emit('SETTLED', tostring(__stateRow().settled_cycle_no))
    """, convars=PRESTIGE_CONVARS)

    assert out["FIRST"] == "false:db_error", f"注入的失败没有生效：{out}"
    assert out["FIRST_PRESTIGE"] == "10", "prestige 在标记 applied 前就应写入（绝对值）"
    assert out["FIRST_APPLIED"] == "0", "失败时不能标 applied"
    assert out["FACILITY_AFTER_FIRST"] == "0", "崩溃前已完成的删除不该回滚"
    assert out["SECOND"] == TRUE
    assert out["PRESTIGE"] == "10", "重试把 prestige 又加了一遍"
    assert out["APPLIED"] == "1"
    assert out["SETTLED"] == "1"


# ══════════════════════════════════════════════════════════════════
# 5. 个人层：静态扫描 + 注入用例
# ══════════════════════════════════════════════════════════════════


WRITE_PATTERNS = (
    re.compile(
        r"\b(?:INSERT(?:\s+IGNORE)?\s+INTO|REPLACE\s+INTO)\s+[`\"']?([A-Za-z0-9_]+)",
        re.I,
    ),
    re.compile(r"\bUPDATE\s+[`\"']?([A-Za-z0-9_]+)[`\"']?\s+SET\b", re.I),
    re.compile(r"\bDELETE\s+FROM\s+[`\"']?([A-Za-z0-9_]+)", re.I),
)
PERSONAL_TABLES = {"players", "player_vehicles", "inventories", "player_houses"}


def written_tables(source: str) -> list[str]:
    code = lua_source.blank_noise(source, keep_strings=True)
    found: list[str] = []
    for pattern in WRITE_PATTERNS:
        for match in pattern.finditer(code):
            name = match.group(1).lower()
            if name in PERSONAL_TABLES and name not in found:
                found.append(name)
    return found


def test_personal_layer_scanner_detects_injected_writes():
    injected = """
        MySQL.update.await('UPDATE players SET money = ? WHERE citizenid = ?', { '{}', 'cid' })
        MySQL.execute.await('DELETE FROM player_vehicles WHERE citizenid = ?', { 'cid' })
    """
    assert written_tables(injected) == ["players", "player_vehicles"]


def test_settlement_never_writes_the_personal_layer():
    # 不参与季度分配的三个文件：完全不许碰个人层。
    for path in (CYCLE_SRC, ANNOUNCE_SRC, COMMANDS_CYCLE_SRC):
        source = path.read_text(encoding="utf-8")
        assert written_tables(source) == [], f"{path.name} 出现了个人层写语句"
        code = lua_source.blank_noise(source, keep_strings=True)
        assert "Player.Functions" not in code, (
            f"{path.name} 调用了玩家钱接口（结算不该碰个人层）"
        )

    # settlement.lua：季度分配（#410）只允许 AddMoney('bank', ...)。
    # 仍然禁止任何个人层写 SQL 与 RemoveMoney/SetMoney 等其它接口。
    source = SETTLEMENT_SRC.read_text(encoding="utf-8")
    assert written_tables(source) == [], "settlement.lua 出现了个人层写 SQL"
    code = lua_source.blank_noise(source, keep_strings=True)
    calls = re.findall(r"\.Functions\.(\w+)\s*\(", code)
    assert set(calls) <= {"AddMoney"}, f"结算碰了 bank 以外的个人层接口：{calls}"
    for match in re.finditer(r"\.Functions\.AddMoney\s*\(\s*([^,]+),", code):
        assert match.group(1).strip() == "'bank'", (
            f"季度分配只能写个人银行：{match.group(0)}"
        )
    assert "RemoveMoney" not in code, "季度分配不许从个人银行扣钱"


# ══════════════════════════════════════════════════════════════════
# 6. prestige 公式 / 幂等键 / dry-run 命令
# ══════════════════════════════════════════════════════════════════


def test_prestige_formula_matches_the_spec():
    """默认 K=50,000（#387）：$5M 累计正好 10 点 = +20% 封顶。"""
    out = run("""
        __emit('ZERO', tostring(IndustrySettlement.PrestigeFor(0)))
        __emit('SMALL', tostring(IndustrySettlement.PrestigeFor(499)))
        __emit('ONE', tostring(IndustrySettlement.PrestigeFor(500)))
        __emit('K', tostring(IndustrySettlement.PrestigeFor(50000)))
        __emit('QUARTER', tostring(IndustrySettlement.PrestigeFor(1250000)))
        __emit('HUGE', tostring(IndustrySettlement.PrestigeFor(5000000)))
    """)

    assert out["ZERO"] == "0"
    assert out["SMALL"] == "0"
    assert out["ONE"] == "0"
    assert out["K"] == "1"
    assert out["QUARTER"] == "5"
    assert out["HUGE"] == "10", "$5M / K=50,000 → 10 点 = +20% 封顶（#387）"


def test_migration_and_fixture_declare_the_settlement_idempotency_key():
    migration = strip_sql_comments(MIGRATION.read_text(encoding="utf-8"))
    quarter = strip_sql_comments(MIGRATION_QUARTER.read_text(encoding="utf-8"))
    fixture = strip_sql_comments(SCHEMA_FIXTURE.read_text(encoding="utf-8"))

    old_unique = re.compile(
        r"UNIQUE\s+KEY\s+`uniq_org_cycle`\s*\(\s*`org_id`\s*,\s*`cycle_no`\s*\)", re.I
    )
    new_unique = re.compile(
        r"UNIQUE\s+KEY\s+`uniq_org_quarter`\s*\(\s*`org_id`\s*,\s*`quarter_no`\s*\)", re.I
    )
    assert old_unique.search(migration), (
        "v4.4 初版必须保留 UNIQUE(org_id, cycle_no)，否则历史行无从解释"
    )
    assert new_unique.search(quarter), (
        "v4.5 迁移缺 industry_cycle_results.UNIQUE(org_id, quarter_no)"
    )
    assert new_unique.search(fixture), "fixture 与迁移不一致：缺 uniq_org_quarter"
    assert not old_unique.search(fixture), (
        "fixture 是最终形状：旧 uniq_org_cycle 必须已被 v4.5 替换"
    )
    assert re.search(r"CHECK\s*\(\s*`id`\s*=\s*1\s*\)", migration, re.I), (
        "industry_state 必须是单行表（CHECK id = 1）"
    )
    assert re.search(r"CHECK\s*\(\s*`id`\s*=\s*1\s*\)", fixture, re.I), (
        "fixture 里的 industry_state 缺 CHECK id = 1"
    )
    for table in ("industry_state", "industry_cycle_results"):
        assert re.search(
            rf"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+`{table}`", migration, re.I
        ), f"迁移里没有建 {table}"
        assert re.search(
            rf"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+`{table}`", fixture, re.I
        ), f"fixture 里没有建 {table}"

    owners = TABLE_OWNERS.read_text(encoding="utf-8")
    assert '"industry_state"' in owners
    assert '"industry_cycle_results"' in owners


def test_settle_command_defaults_to_dry_run_and_writes_nothing():
    out = run(SEED + """
        IndustryCycleCommands.Register()
        local handler = __handlers['industry_settle']
        local ok, err, report = IndustryCycleCommands.Settle(0, 'dry', 1, 100)
        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('RESULTS', tostring(report and report.results))
        __emit('WRITES', tostring(__sqlWrites()))
        __emit('FACILITY_ROWS_LEFT', tostring(__facilityCount()))

        local playerOk, playerErr = IndustryCycleCommands.Settle(1, 'confirm', 1, 100)
        __emit('PLAYER', tostring(playerOk) .. ':' .. tostring(playerErr or 'nil'))
        __emit('PLAYER_AUDIT', __auditPayload('cycle.settle'))
    """, convars=PRESTIGE_CONVARS)

    assert out["OK"] == "true:nil"
    assert out["RESULTS"] == "1"
    assert out["WRITES"] == "0", "命令的 dry 模式写了库"
    assert out["FACILITY_ROWS_LEFT"] == "1"
    assert out["PLAYER"] == "false:not_console"
    assert 'not_console' in out["PLAYER_AUDIT"]


def test_settle_command_rejects_a_cycle_other_than_the_current_one():
    """settled_cycle_no 只增不减：结算旧周期会清掉历史产业层，提前写高会跳过中间周期。"""
    out = run(SEED + """
        IndustryCycleCommands.Register()
        local oldOk, oldErr = IndustryCycleCommands.Settle(0, 'dry', 0, 100)
        local futureOk, futureErr = IndustryCycleCommands.Settle(0, 'dry', 9, 100)
        __emit('OLD', tostring(oldOk) .. ':' .. tostring(oldErr or 'nil'))
        __emit('FUTURE', tostring(futureOk) .. ':' .. tostring(futureErr or 'nil'))
        __emit('WRITES', tostring(__sqlWrites()))
        __emit('FACILITY_ROWS_LEFT', tostring(__facilityCount()))
    """, convars=PRESTIGE_CONVARS)

    assert out["OLD"] == "false:stale_cycle"
    assert out["FUTURE"] == "false:stale_cycle"
    assert out["WRITES"] == "0"
    assert out["FACILITY_ROWS_LEFT"] == "1"


# ══════════════════════════════════════════════════════════════════
# 7. 公告失败不阻断结算；恢复后补发一次
# ══════════════════════════════════════════════════════════════════


def test_announcement_failure_does_not_block_settlement_and_retries_once():
    out = run(SEED + """
        __failBulletins = true
        local ok, err = IndustrySettlement.SettleCycle(1, { trigger = 'no-phone' })
        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('RESULTS', tostring(__resultCount(1)))
        __emit('SETTLED', tostring(__stateRow().settled_cycle_no))
        __emit('ANNOUNCED', tostring(__stateRow().result_announced_cycle))
        __emit('BULLETINS', tostring(__bulletinCount()))

        __failBulletins = false
        local retried, retryErr = IndustryAnnounce.Result(1)
        __emit('RETRY', tostring(retried) .. ':' .. tostring(retryErr or 'nil'))
        __emit('BULLETINS_AFTER', tostring(__bulletinCount()))
        __emit('ANNOUNCED_AFTER', tostring(__stateRow().result_announced_cycle))
    """, convars=PRESTIGE_CONVARS)

    assert out["OK"] == "true:nil", "公告失败把结算也带崩了"
    assert out["RESULTS"] == "1"
    assert out["SETTLED"] == "1", "公告失败不应阻止 settled_cycle_no"
    assert out["ANNOUNCED"] == "0", "没发出去的公告不能标记为已发布"
    assert out["BULLETINS"] == "0"
    assert out["RETRY"] == "true:nil"
    assert out["BULLETINS_AFTER"] == "1", "恢复后没有补发（或补发了多条）"
    assert out["ANNOUNCED_AFTER"] == "1"


# ══════════════════════════════════════════════════════════════════
# P1 两时钟（#409）：季度结算 = 软重置 + 威望 + 起跑金
# ══════════════════════════════════════════════════════════════════
#
# 探针文件 `fixtures/industry_cycle_probe.lua` 不在本片可改范围；两时钟需要的
# `industry_state` 多列、按季/按季度范围的 DELETE 在测试体内补一层假 DB 扩展。
# SQL 形状对不上时返回 affectedRows = 0，不兜底。

MIGRATION_QUARTER = BASE / "migrations" / "v4.5_industry_quarter.sql"

TWO_CLOCK_HARNESS = r"""
local __tcBaseUpdate = MySQL.update.await
local __tcBaseSingle = MySQL.single.await

local function __tcIsStateUpdate(sql)
    return sql:find('UPDATE industry_state', 1, true) ~= nil
        and sql:find('season_no', 1, true) ~= nil
end

function __seedTwoClock(values)
    values = values or {}
    local phases = {
        spring = 'expansion', summer = 'competition',
        autumn = 'maturity', winter = 'recession',
    }
    __state = {
        cycle_no = tonumber(values.cycle_no) or 1,
        phase = values.phase or phases[values.season or 'spring'] or 'expansion',
        started_epoch = tonumber(values.season_started_epoch) or 0,
        ends_epoch = tonumber(values.season_ends_epoch) or 0,
        warning_epoch = values.warning_epoch,
        settled_cycle_no = tonumber(values.settled_cycle_no) or 0,
        result_announced_cycle = tonumber(values.result_announced_cycle) or 0,
        quarter_no = tonumber(values.quarter_no) or 1,
        season = values.season or 'spring',
        season_no = tonumber(values.season_no) or 1,
        season_started_epoch = tonumber(values.season_started_epoch) or 0,
        season_ends_epoch = tonumber(values.season_ends_epoch) or 0,
        quarter_started_epoch = tonumber(values.quarter_started_epoch) or 0,
        quarter_ends_epoch = tonumber(values.quarter_ends_epoch) or 0,
    }
end

MySQL.single.await = function(sql, values)
    if __state and __state.season and sql:find('FROM industry_state', 1, true) then
        if sql:find('SELECT settled_cycle_no', 1, true) then
            return { settled_cycle_no = __state.settled_cycle_no }
        end
        if sql:find('SELECT result_announced_cycle', 1, true) then
            return { result_announced_cycle = __state.result_announced_cycle }
        end
        return {
            id = 1,
            cycle_no = __state.cycle_no,
            phase = __state.phase,
            started_epoch = __state.season_started_epoch,
            ends_epoch = __state.season_ends_epoch,
            warning_done = __state.warning_epoch ~= nil and 1 or 0,
            warning_epoch = __state.warning_epoch,
            settled_cycle_no = __state.settled_cycle_no,
            result_announced_cycle = __state.result_announced_cycle,
            quarter_no = __state.quarter_no,
            season = __state.season,
            season_no = __state.season_no,
            season_started_epoch = __state.season_started_epoch,
            season_ends_epoch = __state.season_ends_epoch,
            quarter_started_epoch = __state.quarter_started_epoch,
            quarter_ends_epoch = __state.quarter_ends_epoch,
        }
    end
    return __tcBaseSingle(sql, values)
end

MySQL.update.await = function(sql, values)
    -- 季度软重置：清掉本组织全部卖单（本季度结束后不该再有更早的流水）。
    if sql:find('DELETE FROM industry_sales', 1, true)
        and sql:find('WHERE org_id = ?', 1, true)
        and not sql:find('cycle_no', 1, true) then
        local removed = 0
        for index = #__sales, 1, -1 do
            if tostring(__sales[index].org_id) == tostring(values[1]) then
                table.remove(__sales, index)
                removed = removed + 1
            end
        end
        return { affectedRows = removed }
    end

    -- 季度配额行：按周号区间删除（只清本季度 13 周）。
    if sql:find('DELETE FROM industry_demand', 1, true)
        and sql:find('BETWEEN', 1, true) then
        local from, to = tonumber(values[1]), tonumber(values[2])
        local removed = 0
        for key, row in pairs(__demands) do
            local cycle = tonumber(row.cycle_no)
            if cycle and cycle >= from and cycle <= to then
                __demands[key] = nil
                removed = removed + 1
            end
        end
        return { affectedRows = removed }
    end

    if __tcIsStateUpdate(sql) then
        local row = __state
        if not row then return { affectedRows = 0 } end

        if sql:find('season_started_at IS NULL', 1, true) then
            if row.season_started_epoch ~= nil then return { affectedRows = 0 } end
            row.phase = values[1]
            row.quarter_no = tonumber(values[2]) or 1
            row.season = values[3]
            row.season_no = tonumber(values[4]) or 1
            row.season_started_epoch = tonumber(values[5])
            row.season_ends_epoch = tonumber(values[6])
            row.quarter_started_epoch = tonumber(values[7])
            row.quarter_ends_epoch = tonumber(values[8])
            row.started_epoch = row.season_started_epoch
            row.ends_epoch = row.season_ends_epoch
            row.warning_epoch = nil
            row.settled_cycle_no = 0
            row.result_announced_cycle = 0
            return { affectedRows = 1 }
        end

        if sql:find('AND season_started_at IS NOT NULL', 1, true) then
            row.cycle_no = tonumber(values[1])
            row.phase = values[2]
            row.started_epoch = tonumber(values[3])
            row.ends_epoch = tonumber(values[4])
            row.quarter_no = tonumber(values[5])
            row.season = values[6]
            row.season_no = tonumber(values[7])
            row.season_started_epoch = tonumber(values[8])
            row.season_ends_epoch = tonumber(values[9])
            row.quarter_started_epoch = tonumber(values[10])
            row.quarter_ends_epoch = tonumber(values[11])
            return { affectedRows = 1 }
        end

        if sql:find('SET cycle_no = ?', 1, true) then
            if row.cycle_no ~= tonumber(values[12]) then return { affectedRows = 0 } end
            if row.phase ~= values[13] then return { affectedRows = 0 } end
            if row.season_no ~= tonumber(values[14]) then return { affectedRows = 0 } end
            if row.season_ends_epoch > tonumber(values[15]) then
                return { affectedRows = 0 }
            end
            if sql:find('settled_cycle_no >= ?', 1, true)
                and row.settled_cycle_no < tonumber(values[16]) then
                return { affectedRows = 0 }
            end
            row.cycle_no = tonumber(values[1])
            row.phase = values[2]
            row.started_epoch = tonumber(values[3])
            row.ends_epoch = tonumber(values[4])
            row.quarter_no = tonumber(values[5])
            row.season = values[6]
            row.season_no = tonumber(values[7])
            row.season_started_epoch = tonumber(values[8])
            row.season_ends_epoch = tonumber(values[9])
            row.quarter_started_epoch = tonumber(values[10])
            row.quarter_ends_epoch = tonumber(values[11])
            if sql:find('warning_announced_at = NULL', 1, true) then
                row.warning_epoch = nil
            end
            return { affectedRows = 1 }
        end
        return { affectedRows = 0 }
    end
    return __tcBaseUpdate(sql, values)
end
"""


def test_quarter_settlement_soft_resets_and_pays_the_starter_grant():
    """季度边界：设施/工位/库存清零、威望增加、起跑金到账、个人层逐字节不变。"""
    out = run(TWO_CLOCK_HARNESS + """
        __reset()
        __seedTwoClock({
            cycle_no = 13, quarter_no = 1, season = 'winter', season_no = 4,
            season_started_epoch = 900, season_ends_epoch = 1000,
            quarter_started_epoch = 0, quarter_ends_epoch = 1000,
        })
        __seedTreasury('mining_co', 500, 0)
        __seedFacility('mining_co', {
            stock = 40, workstations = 3, produced_units = 777, last_tick_epoch = 1000,
        })
        __seedSale('mining_co', 13, 'iron_ore', 1000, 50, 50000)
        __seedDemand(1, 'spring', 'iron_ore', 10, 0)
        __seedDemand(13, 'winter', 'iron_ore', 10, 2)
        __seedDemand(14, 'spring', 'iron_ore', 10, 0) -- 下一季度，不能被本季清掉
        __seedPlayers({
            ap = { citizenid = 'ap', money = '{"cash":100,"bank":200}',
                   inventory = '[{"name":"water","count":2}]' },
        })

        local before = __playersChecksum()
        local ok, err, info = IndustryCycle.Tick(1000)
        local after = __playersChecksum()
        local treasury = __treasury('mining_co')
        local result = __result('mining_co', 1)
        local state = __stateRow()

        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('ADVANCED_TO', tostring(info and info.to))
        __emit('QUARTER', tostring(state.quarter_no))
        __emit('SEASON', state.season)
        __emit('CYCLE', tostring(state.cycle_no))
        __emit('SETTLED', tostring(state.settled_cycle_no))
        __emit('FACILITY_ROWS', tostring(__facilityCount()))
        __emit('SALES_ROWS', tostring(__salesCount()))
        __emit('DEMAND_13', tostring(__demandCount(13)))
        -- 新季节会 EnsureSeed 自己的配额行；这里只看我们预置的第 14 周行是否被越界删除。
        __emit('DEMAND_14_KEPT', tostring(
            __demandRow(14, 'spring', 'iron_ore') ~= nil))
        __emit('BALANCE', tostring(treasury.balance))
        __emit('PRESTIGE', tostring(treasury.prestige))
        __emit('RESULTS', tostring(__resultCount(1)))
        __emit('REVENUE', tostring(result and result.revenue))
        __emit('PRODUCED', tostring(result and result.produced_units))
        __emit('CLEARED', tostring(result and result.balance_cleared))
        __emit('AWARDED', tostring(result and result.prestige_awarded))
        __emit('APPLIED', tostring(result and result.applied))
        __emit('STARTER_LEDGER', tostring(__ledgerRow('quarter-starter:1')
            and __ledgerRow('quarter-starter:1').delta))
        __emit('CLEAR_LEDGER', tostring(__ledgerRow('settle-quarter:1')
            and __ledgerRow('settle-quarter:1').delta))
        __emit('LAST_BULLETIN', tostring(__lastBulletin()))
        __emit('PLAYERS_BEFORE', before)
        __emit('PLAYERS_AFTER', after)
    """, convars={
        "industry_prestige_k": "500",
        "industry_season_seconds": "1",
        "industry_quarter_starter": "200000",
        "industry_quarter_stipend": "10000",
    })

    print("PLAYERS_BEFORE=" + out["PLAYERS_BEFORE"])
    print("PLAYERS_AFTER=" + out["PLAYERS_AFTER"])
    assert out["OK"] == "true:nil", f"季度结算失败：{out}"
    assert out["ADVANCED_TO"] == "spring"
    assert out["QUARTER"] == "2", "季度号没有 +1"
    assert out["SEASON"] == "spring"
    assert out["CYCLE"] == "14"
    assert out["SETTLED"] == "1"
    assert out["FACILITY_ROWS"] == "0", "季度结算没有清空设施/工位/库存"
    assert out["SALES_ROWS"] == "0", "季度结算没有清空卖单"
    assert out["DEMAND_13"] == "0", "本季度配额行没有清掉"
    assert out["DEMAND_14_KEPT"] == TRUE, "季度清算范围越界，删掉了下一季度的配额行"
    assert out["BALANCE"] == "300000", "起跑金 = 200,000 + 10 × 10,000"
    assert out["PRESTIGE"] == "10"
    assert out["RESULTS"] == "1", "季度结果必须恰好一行（键是 quarter_no）"
    assert out["REVENUE"] == "50000"
    assert out["PRODUCED"] == "777"
    assert out["CLEARED"] == "500"
    assert out["AWARDED"] == "10"
    assert out["APPLIED"] == "1"
    assert out["STARTER_LEDGER"] == "300000", "起跑金没有写流水"
    assert out["CLEAR_LEDGER"] == "-500", "清分没有写 settlement-clear 流水"
    assert "产业季度 #1 已结算" in out["LAST_BULLETIN"], (
        f"季度结算公告文案不对：{out['LAST_BULLETIN']}"
    )
    assert out["PLAYERS_BEFORE"] == out["PLAYERS_AFTER"], (
        "季度结算改动了个人层："
        f"{out['PLAYERS_BEFORE']} != {out['PLAYERS_AFTER']}"
    )
    print({key: out[key] for key in (
        "QUARTER", "SEASON", "CYCLE", "SETTLED", "FACILITY_ROWS", "SALES_ROWS",
        "DEMAND_13", "DEMAND_14_KEPT", "BALANCE", "PRESTIGE", "RESULTS",
        "REVENUE", "PRODUCED", "CLEARED", "AWARDED", "STARTER_LEDGER",
        "CLEAR_LEDGER", "LAST_BULLETIN")})


def test_settle_command_maps_the_current_week_to_its_quarter():
    """commands_cycle.lua 不改：它传当前周号，SettleCycle 薄包装换算成季度号。"""
    out = run(TWO_CLOCK_HARNESS + """
        __reset()
        __seedTwoClock({
            cycle_no = 14, quarter_no = 2, season = 'spring', season_no = 1,
            season_started_epoch = 1000, season_ends_epoch = 2000,
            quarter_started_epoch = 1000, quarter_ends_epoch = 6000,
        })
        __seedTreasury('mining_co', 100, 0)
        __seedFacility('mining_co', { stock = 5, workstations = 1, produced_units = 5 })

        IndustryCycleCommands.Register()
        local dryOk, dryErr, report = IndustryCycleCommands.Settle(0, 'dry', 14, 1500)
        __emit('DRY', tostring(dryOk) .. ':' .. tostring(dryErr or 'nil'))
        __emit('REPORT_QUARTER', tostring(report and report.quarter_no))
        __emit('WRITES', tostring(__sqlWrites()))

        local ok, err = IndustryCycleCommands.Settle(0, 'confirm', 14, 1500)
        __emit('CONFIRM', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('SETTLED', tostring(__stateRow().settled_cycle_no))
        __emit('FACILITY_ROWS', tostring(__facilityCount()))
        __emit('BALANCE', tostring(__treasury('mining_co').balance))
        __emit('RESULTS', tostring(__resultCount(2)))
    """, convars={
        "industry_prestige_k": "500",
        "industry_quarter_starter": "200000",
        "industry_quarter_stipend": "10000",
    })

    assert out["DRY"] == "true:nil", f"两时钟 dry-run 失败：{out}"
    assert out["REPORT_QUARTER"] == "2", "dry-run 没有落到季度号"
    assert out["WRITES"] == "0", "dry-run 写了库"
    assert out["CONFIRM"] == "true:nil", f"两时钟 confirm 失败：{out}"
    assert out["SETTLED"] == "2", "SettleCycle 没有把周号换算成季度号"
    assert out["FACILITY_ROWS"] == "0"
    assert out["BALANCE"] == "200000", "季度起跑金没有到账"
    assert out["RESULTS"] == "1"


def test_restart_does_not_settle_the_same_quarter_twice():
    """重启续跑：水位已到位的季度边界只滚季，不重复发放威望/起跑金。"""
    out = run(TWO_CLOCK_HARNESS + """
        __reset()
        __seedTwoClock({
            cycle_no = 13, quarter_no = 1, season = 'winter', season_no = 4,
            season_started_epoch = 900, season_ends_epoch = 1000,
            quarter_started_epoch = 0, quarter_ends_epoch = 1000,
            settled_cycle_no = 1, result_announced_cycle = 1,
        })
        __seedTreasury('mining_co', 0, 10)
        __seedFacility('mining_co', { stock = 0, workstations = 0, produced_units = 999 })

        -- restart custom-industry：Initialize 不得重算时钟。
        IndustryCycle.Start()
        __emit('INIT_UNCHANGED', tostring(__stateRow().season_ends_epoch == 1000))

        local ok, err, info = IndustryCycle.Tick(1000)
        __emit('TICK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('QUARTER', tostring(__stateRow().quarter_no))
        __emit('SEASON', __stateRow().season)
        __emit('BALANCE', tostring(__treasury('mining_co').balance))
        __emit('PRESTIGE', tostring(__treasury('mining_co').prestige))
        __emit('RESULTS', tostring(__resultCount(1)))

        local writes = __sqlWrites()
        local repeated, repeatedErr, summary = IndustrySettlement.SettleQuarter(
            1, { trigger = 'restart' })
        __emit('REPEAT', tostring(repeated) .. ':' .. tostring(repeatedErr or 'nil'))
        __emit('ALREADY', tostring(summary and summary.already_settled))
        __emit('WRITES_ADDED', tostring(__sqlWrites() - writes))
        __emit('BALANCE_AFTER', tostring(__treasury('mining_co').balance))
        __emit('PRESTIGE_AFTER', tostring(__treasury('mining_co').prestige))
        __emit('RESULTS_AFTER', tostring(__resultCount(1)))
    """, convars={
        "industry_prestige_k": "500",
        "industry_season_seconds": "1",
        "industry_quarter_starter": "200000",
        "industry_quarter_stipend": "10000",
    })

    assert out["INIT_UNCHANGED"] == TRUE, "重启把已运行季节的边界重算了"
    assert out["TICK"] == "true:nil", f"季度边界 tick 失败：{out}"
    assert out["QUARTER"] == "2", "季度边界没有滚到下一季度"
    assert out["SEASON"] == "spring"
    assert out["BALANCE"] == "0", "重复结算又发了一次起跑金"
    assert out["PRESTIGE"] == "10", "重复结算又加了一次威望"
    assert out["RESULTS"] == "0", "重复结算写了结果行"
    assert out["REPEAT"] == "true:nil", f"重复结算应幂等返回而不是报错：{out}"
    assert out["ALREADY"] == TRUE, "重复结算没有走 already_settled"
    assert out["WRITES_ADDED"] == "0", "重复结算写了库（水位闸失效）"
    assert out["BALANCE_AFTER"] == "0"
    assert out["PRESTIGE_AFTER"] == "10"
    assert out["RESULTS_AFTER"] == "0"
    print({key: out[key] for key in (
        "INIT_UNCHANGED", "TICK", "QUARTER", "SEASON", "BALANCE", "PRESTIGE",
        "RESULTS", "REPEAT", "ALREADY", "WRITES_ADDED", "BALANCE_AFTER",
        "PRESTIGE_AFTER", "RESULTS_AFTER")})


# ══════════════════════════════════════════════════════════════════
# P2 季度分配（#410）：Boss 40% / 非 Boss 成员平分
# ══════════════════════════════════════════════════════════════════
#
# 仓库没有 `org_members` 表；成员来源是 QBCore 在线玩家 + IndustryAccess.OrgMembership
# （与 announce.lua 的推送名单同一判定）。这里用假 qb-core 提供在线成员，AddMoney
# 只改 `__players[cid].money.bank`，其余字段用 checksum 钉住逐字段不变。

DISTRIBUTE_HARNESS = r"""
__fakePlayers = {}
function __fakeMember(cid, grade)
    __fakePlayers[cid] = {
        PlayerData = {
            citizenid = cid,
            source = 1,
            job = { name = 'miner', grade = { level = grade } },
        },
        Functions = {
            AddMoney = function(kind, amount, reason)
                if kind ~= 'bank' then
                    error('quarter share moneytype 必须是 bank，实际 ' .. tostring(kind))
                end
                __players[cid].money.bank = __players[cid].money.bank + amount
                return true
            end,
        },
    }
end

local __baseExports = exports
exports = setmetatable({}, {
    __index = function(_, resource)
        if resource == 'qb-core' then
            return {
                GetCoreObject = function()
                    return {
                        Functions = {
                            GetQBPlayers = function() return __fakePlayers end,
                        },
                    }
                end,
            }
        end
        return __baseExports[resource]
    end,
    __call = function(_, name, fn) return __baseExports(name, fn) end,
})

--- players 表的 checksum，但把 money.bank 归零后再算：
--- 分配前后除 bank 外的所有字段必须逐字节一致。
function __checksumNoBank()
    local saved = {}
    for cid, row in pairs(__players) do
        if type(row.money) == 'table' then
            saved[cid] = row.money.bank
            row.money.bank = 0
        end
    end
    local sum = __playersChecksum()
    for cid, row in pairs(__players) do
        if saved[cid] ~= nil then row.money.bank = saved[cid] end
    end
    return sum
end
"""

DISTRIBUTE_CONVARS = {
    "industry_prestige_k": "500",
    "industry_quarter_starter": "0",
    "industry_quarter_stipend": "0",
}


def test_quarter_settlement_splits_treasury_boss_40_and_members_30_each():
    out = run(TWO_CLOCK_HARNESS + DISTRIBUTE_HARNESS + r"""
        __reset()
        __seedTwoClock({
            cycle_no = 13, quarter_no = 1, season = 'winter', season_no = 4,
            season_started_epoch = 900, season_ends_epoch = 1000,
            quarter_started_epoch = 0, quarter_ends_epoch = 1000,
        })
        __seedTreasury('mining_co', 100000, 0)
        __seedPlayers({
            cid_boss = { citizenid = 'cid_boss', name = 'Boss',
                         money = { cash = 11, bank = 100 }, inventory = '[]' },
            cid_m1 = { citizenid = 'cid_m1', name = 'M1',
                       money = { cash = 22, bank = 200 }, inventory = '[]' },
            cid_m2 = { citizenid = 'cid_m2', name = 'M2',
                       money = { cash = 33, bank = 300 }, inventory = '[]' },
        })
        __fakeMember('cid_boss', 4)
        __fakeMember('cid_m1', 1)
        __fakeMember('cid_m2', 1)

        local before = __checksumNoBank()
        local ok, err, summary = IndustrySettlement.SettleQuarter(1, { trigger = 'test' })
        local after = __checksumNoBank()
        local payload = __lastAuditPayload('treasury.distribute')
        local distribution = __ledgerRow('quarter-distribute:1')
        local result = __result('mining_co', 1)

        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('BANK_BOSS', tostring(__players.cid_boss.money.bank))
        __emit('BANK_M1', tostring(__players.cid_m1.money.bank))
        __emit('BANK_M2', tostring(__players.cid_m2.money.bank))
        __emit('CASH_BOSS', tostring(__players.cid_boss.money.cash))
        __emit('TREASURY', tostring(__treasury('mining_co').balance))
        __emit('CLEARED', tostring(result and result.balance_cleared))
        __emit('DISTRIBUTED', tostring(summary and summary.distributed))
        __emit('PAID', tostring(summary and summary.distribute_paid))
        __emit('FAILED', tostring(summary and summary.distribute_failed))
        __emit('LEDGER_DELTA', tostring(distribution and distribution.delta))
        __emit('SETTLE_CLEAR', tostring(__ledgerRow('settle-quarter:1') ~= nil))
        __emit('PAYLOAD', tostring(payload))
        __emit('AUDIT_COUNT', tostring(__auditCount('treasury.distribute')))
        __emit('CHECKSUM_BEFORE', before)
        __emit('CHECKSUM_AFTER', after)

        local repeatOk, repeatErr, repeatSummary = IndustrySettlement.SettleQuarter(
            1, { trigger = 'again' })
        __emit('REPEAT', tostring(repeatOk) .. ':' .. tostring(repeatErr or 'nil'))
        __emit('REPEAT_ALREADY', tostring(repeatSummary and repeatSummary.already_settled))
        __emit('BANK_AFTER_REPEAT', tostring(__players.cid_boss.money.bank))
        __emit('AUDIT_COUNT_AFTER', tostring(__auditCount('treasury.distribute')))
        print('CHECKSUM_BEFORE=' .. before)
        print('CHECKSUM_AFTER=' .. after)
    """, convars=DISTRIBUTE_CONVARS)

    print("CHECKSUM_BEFORE=" + out["CHECKSUM_BEFORE"])
    print("CHECKSUM_AFTER=" + out["CHECKSUM_AFTER"])
    assert out["OK"] == "true:nil", f"季度分配失败：{out}"
    assert out["BANK_BOSS"] == "40100", "Boss 应拿 40,000（100 + 40,000）"
    assert out["BANK_M1"] == "30200", "成员 1 应拿 30,000"
    assert out["BANK_M2"] == "30300", "成员 2 应拿 30,000"
    assert out["CASH_BOSS"] == "11", "分配动了个人银行的 cash 字段"
    assert out["TREASURY"] == "0", "分配后金库应清零（起跑金为 0）"
    assert out["CLEARED"] == "100000", "结果表快照应记录结算前的 100,000"
    assert out["DISTRIBUTED"] == "100000"
    assert out["PAID"] == "100000"
    assert out["FAILED"] == "0"
    assert out["LEDGER_DELTA"] == "-100000", "分配没有从金库扣款/写流水"
    assert out["SETTLE_CLEAR"] == "false", "已分配的钱又写了一次 settlement-clear（重复记账）"
    assert out["AUDIT_COUNT"] == "1", "treasury.distribute 必须恰好一条"
    payload = out["PAYLOAD"]
    for fragment in (
        '"boss_total":40000', '"member_each":30000', '"boss_count":1',
        '"member_count":2', '"paid":100000', '"failed":0', '"result":"ok"',
    ):
        assert fragment in payload, f"分配审计缺 {fragment}：{payload}"
    assert "cid_" not in payload, f"分配审计出现 citizenid/PII：{payload}"
    assert out["CHECKSUM_BEFORE"] == out["CHECKSUM_AFTER"], (
        "分配改动了 players 表 bank 以外的字段："
        f"{out['CHECKSUM_BEFORE']} != {out['CHECKSUM_AFTER']}"
    )
    assert out["REPEAT_ALREADY"] == TRUE, "重复结算没有走 already_settled"
    assert out["BANK_AFTER_REPEAT"] == "40100", "重复结算又发了一次分配"
    assert out["AUDIT_COUNT_AFTER"] == "1", "重复结算重复写了分配审计"


def test_single_person_org_takes_the_whole_treasury_as_boss():
    """单人组织 = 没有非 Boss 成员：Boss 拿 100%，不是 40%。"""
    out = run(TWO_CLOCK_HARNESS + DISTRIBUTE_HARNESS + r"""
        __reset()
        __seedTwoClock({
            cycle_no = 13, quarter_no = 1, season = 'winter', season_no = 4,
            season_started_epoch = 900, season_ends_epoch = 1000,
            quarter_started_epoch = 0, quarter_ends_epoch = 1000,
        })
        __seedTreasury('mining_co', 100000, 0)
        __seedPlayers({
            cid_boss = { citizenid = 'cid_boss', name = 'Boss',
                         money = { cash = 11, bank = 0 }, inventory = '[]' },
        })
        __fakeMember('cid_boss', 4)

        local before = __checksumNoBank()
        local ok, err, summary = IndustrySettlement.SettleQuarter(1, { trigger = 'test' })
        local after = __checksumNoBank()
        local payload = __lastAuditPayload('treasury.distribute')

        __emit('OK', tostring(ok) .. ':' .. tostring(err or 'nil'))
        __emit('BANK_BOSS', tostring(__players.cid_boss.money.bank))
        __emit('TREASURY', tostring(__treasury('mining_co').balance))
        __emit('DISTRIBUTED', tostring(summary and summary.distributed))
        __emit('PAYLOAD', tostring(payload))
        __emit('CHECKSUM_BEFORE', before)
        __emit('CHECKSUM_AFTER', after)
    """, convars=DISTRIBUTE_CONVARS)

    print("CHECKSUM_BEFORE=" + out["CHECKSUM_BEFORE"])
    print("CHECKSUM_AFTER=" + out["CHECKSUM_AFTER"])
    assert out["OK"] == "true:nil", f"单人组织季度分配失败：{out}"
    assert out["BANK_BOSS"] == "100000", "单人组织 Boss 没有拿 100%（写成了 40%？）"
    assert out["TREASURY"] == "0"
    assert out["DISTRIBUTED"] == "100000"
    payload = out["PAYLOAD"]
    assert '"boss_total":100000' in payload, f"审计的 Boss 份额不是全额：{payload}"
    assert '"member_each":0' in payload, f"单人组织不应有成员份额：{payload}"
    assert '"member_count":0' in payload, f"单人组织成员数应为 0：{payload}"
    assert out["CHECKSUM_BEFORE"] == out["CHECKSUM_AFTER"], (
        "单人分配改动了 players 表 bank 以外的字段"
    )
