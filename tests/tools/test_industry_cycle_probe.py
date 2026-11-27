"""真机周期验收脚本的离线契约。

真机脚本最贵的失败模式是「判据本身写错」：序列比较漏掉一次跨周期推进、
补推回溯量把终止状态也推成过去、或者清理 SQL 不小心写到个人层。
所以这里只测**纯函数与静态守卫**，不连数据库、不启服务端。

Run: ``python3 -m pytest -q tests/tools/test_industry_cycle_probe.py``
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
TOOL = REPO / "tools" / "dev" / "industry_cycle_probe.py"


def load():
    spec = importlib.util.spec_from_file_location("industry_cycle_probe", TOOL)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # dataclass 的字符串注解要靠 sys.modules 解析模块名；不注册会在 exec 时炸。
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(spec.name, None)
        raise
    return module


def transition(module, from_phase: str, to_phase: str, cycle_no: int):
    return module.Transition(from_phase, to_phase, cycle_no)


# ══════════════════════════════════════════════════════════════════
# 1. 序列判据：8 次推进，跨周期只在衰退→扩张
# ══════════════════════════════════════════════════════════════════


def test_expected_sequence_for_two_cycles_is_eight_chained_transitions():
    module = load()
    expected = module.expected_transitions(10, 2)

    assert len(expected) == 8
    assert [(item.cycle_no, item.from_phase, item.to_phase) for item in expected] == [
        (10, "expansion", "competition"),
        (10, "competition", "maturity"),
        (10, "maturity", "recession"),
        (11, "recession", "expansion"),
        (11, "expansion", "competition"),
        (11, "competition", "maturity"),
        (11, "maturity", "recession"),
        (12, "recession", "expansion"),
    ]
    for previous, current in zip(expected, expected[1:]):
        assert previous.to_phase == current.from_phase, "序列没有首尾相接"
        if current.from_phase == "recession" and current.to_phase == "expansion":
            # 跨周期推进：payload 的 cycle_no 记的是**新**周期。
            assert current.cycle_no == previous.cycle_no + 1
        else:
            assert current.cycle_no == previous.cycle_no


def test_exact_sequence_passes_validation():
    module = load()
    observed = module.expected_transitions(10, 2)
    assert module.validate_transitions(observed, 10, 2) == []


def test_skipped_phase_is_rejected():
    module = load()
    observed = list(module.expected_transitions(10, 2))
    observed[1] = transition(module, "expansion", "maturity", 10)  # 跳过竞争
    failures = module.validate_transitions(observed, 10, 2)
    assert failures, "跳段必须判红"
    assert "competition" in failures[0]


def test_restart_rewind_is_rejected():
    module = load()
    observed = list(module.expected_transitions(10, 2))
    observed[4] = transition(module, "maturity", "competition", 11)  # 回退
    failures = module.validate_transitions(observed, 10, 2)
    assert failures, "阶段回退必须判红"


def test_short_or_long_sequences_are_rejected():
    module = load()
    expected = module.expected_transitions(10, 2)
    assert module.validate_transitions(expected[:-1], 10, 2)
    assert module.validate_transitions(expected + [expected[-1]], 10, 2)


def test_audit_payload_parser_ignores_malformed_rows():
    module = load()
    assert module.parse_advance_payload(
        '{"from":"expansion","to":"competition","cycle_no":3}'
    ) == transition(module, "expansion", "competition", 3)
    assert module.parse_advance_payload("not json") is None
    assert module.parse_advance_payload('{"from":"x"}') is None


# ══════════════════════════════════════════════════════════════════
# 2. 周期号选择 / 补推回溯量
# ══════════════════════════════════════════════════════════════════


def test_start_cycle_skips_every_known_cycle_and_null_shapes():
    module = load()
    assert module.choose_start_cycle(3, "7", None, "", "NULL", 5) == 8
    assert module.choose_start_cycle(None, "NULL") == 1


def test_restart_resume_allows_only_standing_still_or_one_step_forward():
    module = load()
    state = lambda cycle, phase: {"cycle_no": str(cycle), "phase": phase}  # noqa: E731

    assert module.restart_resume_ok(state(11, "competition"), state(11, "competition"))
    assert module.restart_resume_ok(state(11, "competition"), state(11, "maturity"))
    assert module.restart_resume_ok(state(11, "recession"), state(12, "expansion"))

    assert not module.restart_resume_ok(state(11, "maturity"), state(11, "competition")), (
        "阶段回退必须判红"
    )
    assert not module.restart_resume_ok(state(11, "expansion"), state(11, "maturity")), (
        "同一 tick 跨两格必须判红"
    )
    assert not module.restart_resume_ok(state(11, "competition"), state(13, "expansion")), (
        "跨多个周期必须判红"
    )


def _simulate_catchup(module, phase: str, scale: int) -> tuple[int, str, int]:
    """复刻 TickOnce 的补推：当前边界在过去时，每次 tick 推进一格；返回终止状态。"""
    end = -module.past_due_lookback(phase, scale)  # now = 0，边界在 end
    index = module.PHASE_ORDER.index(phase)
    cycle = 11
    steps = 0
    while end <= 0:
        index += 1
        if index == len(module.PHASE_ORDER):
            index = 0
            cycle += 1
        end += scale
        steps += 1
    return cycle, module.PHASE_ORDER[index], steps


def test_past_due_lookback_stops_at_next_cycle_expansion():
    """补推注入后必须停在「下一周期扩张期」，否则探针观察不到终止状态。"""
    module = load()
    for phase, expected_steps in (("expansion", 4), ("competition", 3)):
        cycle, final_phase, steps = _simulate_catchup(module, phase, 60)
        assert (cycle, final_phase, steps) == (12, "expansion", expected_steps), (
            f"{phase} 的补推没有停在下一周期扩张期：{cycle}:{final_phase} "
            f"steps={steps}"
        )


# ══════════════════════════════════════════════════════════════════
# 3. 个人层静态守卫 / checksum 解析
# ══════════════════════════════════════════════════════════════════


@pytest.mark.parametrize(
    "table", ["players", "player_vehicles", "inventories", "player_houses"]
)
@pytest.mark.parametrize(
    "sql_template",
    [
        "UPDATE {table} SET money = 0",
        "INSERT INTO {table} (id) VALUES (1)",
        "INSERT IGNORE INTO {table} (id) VALUES (1)",
        "REPLACE INTO {table} (id) VALUES (1)",
        "DELETE FROM {table} WHERE id = 1",
        "ALTER TABLE {table} ADD COLUMN x int",
        "DROP TABLE {table}",
        "TRUNCATE TABLE {table}",
    ],
)
def test_guard_rejects_every_personal_write_shape(table, sql_template):
    module = load()
    with pytest.raises(module.ProbeError):
        module.guard_sql(sql_template.format(table=table))


def test_guard_allows_checksums_and_reads_but_rejects_unknown_access():
    module = load()
    module.guard_sql("CHECKSUM TABLE players, player_vehicles, inventories, player_houses")
    module.guard_sql("SELECT COUNT(*) AS n FROM players LIMIT 1")
    module.guard_sql("UPDATE industry_facility SET stock = 0 WHERE org_id = 'x'")
    with pytest.raises(module.ProbeError):
        module.guard_sql("LOCK TABLES players WRITE")


def test_checksum_rows_parse_and_diff():
    module = load()
    text = (
        "Table\tChecksum\n"
        "TCityLite.players\t111\n"
        "TCityLite.player_vehicles\t222\n"
        "TCityLite.inventories\t333\n"
        "TCityLite.player_houses\t444\n"
    )
    parsed = module.parse_checksum_rows(text)
    assert parsed == {
        "players": "111",
        "player_vehicles": "222",
        "inventories": "333",
        "player_houses": "444",
    }

    after = dict(parsed, players="999")
    counts_before = {table: 1 for table in module.PERSONAL_TABLES}
    counts_after = dict(counts_before)
    failures = module.checksum_failures(parsed, after, counts_before, counts_after)
    assert failures and "players" in failures[0]

    counts_after["inventories"] = 2
    failures = module.checksum_failures(parsed, parsed, counts_before, counts_after)
    assert failures and "inventories" in failures[0]

    table = module.format_checksum_table(parsed, after, counts_before, counts_after)
    assert "players" in table and "111" in table and "999" in table


def test_sql_literal_keeps_batch_null_and_escapes_quotes():
    module = load()
    assert module.sql_literal(None) == "NULL"
    assert module.sql_literal("NULL") == "NULL", (
        "mariadb --batch 的 NULL 字面量必须还原成 SQL NULL，不能写成字符串"
    )
    assert module.sql_literal("mining_co") == "'mining_co'"
    assert module.sql_literal("O'Reilly") == "'O''Reilly'"


def test_settle_output_helpers():
    module = load()
    assert module.is_already_settled("industry_settle cycle=2 already settled")
    assert module.is_already_settled('{"already_settled":true}')
    assert not module.is_already_settled("settlement done")

# ══════════════════════════════════════════════════════════════════
# 4. preflight：就绪判据必须走 DB 事实，不能只靠控制台文本
# ══════════════════════════════════════════════════════════════════

class _FakeSql:
    def __init__(self, state_rows: int) -> None:
        self.state_rows = state_rows
        self.queries: list[str] = []

    def query(self, sql: str):
        self.queries.append(sql)
        if "industry_state" in sql:
            return [{"n": self.state_rows}]
        return []


class _FakeConsole:
    def __init__(self, output: str) -> None:
        self.output = output

    def __call__(self, command: str, timeout: float = 60.0) -> str:
        return self.output


class _ProbeShell:
    """只借 preflight 需要的那几个属性；不触发网络/DB/控制台。"""

    preflight = None  # 由用例注入

    def __init__(self, module, *, state_rows: int, console_output: str) -> None:
        self.module = module
        self.args = type("A", (), {"allow_players_online": True, "allow_industry_data": True})()
        self.sql = _FakeSql(state_rows)
        self.console = _FakeConsole(console_output)
        self.snapshot = type("S", (), {"facilities": [], "treasuries": []})()
        self.logs: list[str] = []

    def log(self, message: str) -> None:
        self.logs.append(message)


def test_preflight_accepts_db_ready_when_console_echo_is_buffered() -> None:
    """块缓冲下控制台回显可能迟到 —— 只要 DB 里有 industry_state 行，就必须判就绪。

    真机复现过两次：功能明明正常，preflight 拿到 `(no output)` 就报「industry_enable 未开」。
    """
    module = load()
    shell = _ProbeShell(module, state_rows=1, console_output="(no output)")
    module.CycleProbe.preflight(shell)  # 不抛 = 通过
    assert any("DB 事实" in line for line in shell.logs), shell.logs


def test_preflight_rejects_when_db_has_no_state_row() -> None:
    """真的没就绪（industry_state 无行）时必须报错，不能因为放宽判据而放过。"""
    module = load()
    shell = _ProbeShell(module, state_rows=0, console_output="(no output)")
    with pytest.raises(module.ProbeError):
        module.CycleProbe.preflight(shell)

