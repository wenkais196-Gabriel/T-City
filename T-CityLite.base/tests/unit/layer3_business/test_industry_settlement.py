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
    for path in (SETTLEMENT_SRC, CYCLE_SRC, ANNOUNCE_SRC, COMMANDS_CYCLE_SRC):
        source = path.read_text(encoding="utf-8")
        assert written_tables(source) == [], f"{path.name} 出现了个人层写语句"
        code = lua_source.blank_noise(source, keep_strings=True)
        assert "Player.Functions" not in code, (
            f"{path.name} 调用了玩家钱接口（结算不该碰个人层）"
        )


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
    fixture = strip_sql_comments(SCHEMA_FIXTURE.read_text(encoding="utf-8"))

    unique = re.compile(
        r"UNIQUE\s+KEY\s+`uniq_org_cycle`\s*\(\s*`org_id`\s*,\s*`cycle_no`\s*\)", re.I
    )
    assert unique.search(migration), "迁移缺 industry_cycle_results.UNIQUE(org_id, cycle_no)"
    assert unique.search(fixture), "fixture 与迁移不一致：缺 uniq_org_cycle"
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
