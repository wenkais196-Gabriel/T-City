"""P2-4 闸门：IO / tick / payload 的静态预算。

判据在 `tools/dev/budget_probe.py`：按 `fxmanifest` 找出服务端脚本，脱掉注释后统计
  1. `db_call_sites` —— DB 调用点总数（趋势指标）；
  2. `fast_polling_loops` / `warm_polling_loops` / `wait_zero_loops` —— `while true` 的轮询形状
     （Wait ≤100ms ≈ 600 次/分钟、≤1000ms ≈ 60 次/分钟、Wait(0) 会吃满一个 tick）；
  3. `broadcast_sites` / `broadcast_inline_json` —— 全服广播点，以及其中内联 `json.encode` 的点。

数字超过 `io_budget.json` 就红。预算只能往下调（`--update` 会在数字变大时直接拒绝）。

为什么用结构计数而不是跑测：这些形状的变化（多一个每秒轮询、多一个全服序列化广播）在 CI 里必须能被
**静态**拦住 —— 等运行时才发现的成本就是线上卡顿。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, (REPO / "tools" / "dev").as_posix())

import budget_probe  # noqa: E402

BUDGET = REPO / "T-CityLite.base" / "tests" / "architecture" / "io_budget.json"


def test_current_numbers_are_within_budget():
    problems = budget_probe.check()
    assert not problems, "预算超了：\n  - " + "\n  - ".join(problems)

    # 新增指标必须同时写预算，否则它永远是"没预算 = 不检查"
    metrics = budget_probe.measure()
    budget = budget_probe.load_budget(BUDGET)
    missing = sorted(set(metrics) - set(budget))
    assert not missing, f"这些指标没有预算：{missing}"
    for name, entry in budget.items():
        assert entry.get("note", "").strip(), f"{name} 没写 note（说明它量的是什么、超了该怎么做）"

    # 反向保护：预算被清空/写成 0 会让闸门看起来永远绿（或永远红）
    assert len(budget) >= 6, f"预算只剩 {len(budget)} 项，像是被清过"


# ══════════════════════════════════════════════════════════════════
# 反向形状：每条指标都要能真的咬住
# ══════════════════════════════════════════════════════════════════

def _fixture(tmp_path: Path, body: str) -> Path:
    resources = tmp_path / "resources"
    directory = resources / "probe-res"
    directory.mkdir(parents=True)
    (directory / "fxmanifest.lua").write_text(
        "fx_version 'cerulean'\nserver_script 'server.lua'\n", encoding="utf-8")
    (directory / "server.lua").write_text(body, encoding="utf-8")
    return resources


def _budget_file(tmp_path: Path, **overrides: int) -> Path:
    metrics = {name: {"budget": value, "note": "probe"} for name, value in {
        "db_call_sites": 0,
        "fast_polling_loops": 0,
        "warm_polling_loops": 0,
        "wait_zero_loops": 0,
        "conditional_busy_wait_loops": 0,
        "polling_loops_unknown_interval": 0,
        "broadcast_sites": 0,
        "broadcast_inline_json": 0,
    }.items()}
    for name, value in overrides.items():
        metrics[name]["budget"] = value
    path = tmp_path / "io_budget.json"
    path.write_text(json.dumps({"metrics": metrics}, ensure_ascii=False), encoding="utf-8")
    return path


def test_reverse_new_db_call_rejects_when_over_budget(tmp_path):
    resources = _fixture(tmp_path, "CreateThread(function()\n  MySQL.query('SELECT 1')\nend)\n")
    budget = _budget_file(tmp_path, db_call_sites=0)
    problems = budget_probe.check(budget_probe.measure(resources), budget)
    assert any("db_call_sites" in problem for problem in problems), problems


def test_reverse_fast_polling_loop_rejects_when_over_budget(tmp_path):
    resources = _fixture(tmp_path, "CreateThread(function()\n  while true do\n    Wait(50)\n  end\nend)\n")
    budget = _budget_file(tmp_path, fast_polling_loops=0)
    problems = budget_probe.check(budget_probe.measure(resources), budget)
    assert any("fast_polling_loops" in problem for problem in problems), problems


def test_reverse_wait_zero_loop_rejects_when_over_budget(tmp_path):
    resources = _fixture(tmp_path, "CreateThread(function()\n  while true do\n    Wait(0)\n  end\nend)\n")
    budget = _budget_file(tmp_path, wait_zero_loops=0)
    problems = budget_probe.check(budget_probe.measure(resources), budget)
    assert any("wait_zero_loops" in problem for problem in problems), problems


def test_reverse_broadcast_inline_json_rejects_when_over_budget(tmp_path):
    body = ("CreateThread(function()\n"
            "  TriggerClientEvent('x:sync', -1, json.encode({ a = 1 }))\n"
            "end)\n")
    resources = _fixture(tmp_path, body)
    metrics = budget_probe.measure(resources)
    assert metrics["broadcast_inline_json"] == 1, metrics
    budget = _budget_file(tmp_path, broadcast_inline_json=0)
    problems = budget_probe.check(metrics, budget)
    assert any("broadcast_inline_json" in problem for problem in problems), problems


def test_reverse_comment_only_shapes_are_not_counted(tmp_path):
    """注释里的 `while true do Wait(0)` / `MySQL.query` 不该计入 —— 计的是真的代码。"""
    body = ("-- while true do Wait(0) end\n"
            "-- MySQL.query('SELECT 1')\n"
            "local a = 1\n")
    metrics = budget_probe.measure(_fixture(tmp_path, body))
    assert metrics["wait_zero_loops"] == 0 and metrics["db_call_sites"] == 0, metrics


def test_reverse_variable_wait_interval_is_not_a_silent_escape(tmp_path):
    """把 `Wait(50)` 改成 `Wait(ms)` 不能绕过 fast 预算：要落到 unknown 档并被看见。"""
    resources = _fixture(tmp_path, "local ms = 50\nCreateThread(function()\n  while true do\n    Wait(ms)\n  end\nend)\n")
    metrics = budget_probe.measure(resources)
    assert metrics["polling_loops_unknown_interval"] == 1, metrics
    budget = _budget_file(tmp_path, polling_loops_unknown_interval=0)
    problems = budget_probe.check(metrics, budget)
    assert any("polling_loops_unknown_interval" in problem for problem in problems), problems


def test_reverse_loop_shapes_are_all_detected(tmp_path):
    """`while (true)`、`while 1`、`repeat … until` 与 `while true` 等价，必须都算。"""
    body = ("CreateThread(function()\n"
            "  while (true) do Wait(50) end\n"
            "end)\n"
            "CreateThread(function()\n"
            "  while 1 do Wait(50) end\n"
            "end)\n"
            "CreateThread(function()\n"
            "  repeat Wait(50) until false\n"
            "end)\n")
    metrics = budget_probe.measure(_fixture(tmp_path, body))
    assert metrics["fast_polling_loops"] == 3, metrics


def test_reverse_constant_expression_is_evaluated_not_guessed(tmp_path):
    """`Wait(3600 * 1000)` 是常量表达式（一小时），不该被当成"未知"或"快循环"。"""
    resources = _fixture(tmp_path, "CreateThread(function()\n  while true do\n    Wait(3600 * 1000)\n  end\nend)\n")
    metrics = budget_probe.measure(resources)
    assert metrics["polling_loops_unknown_interval"] == 0, metrics
    assert metrics["fast_polling_loops"] == 0 and metrics["warm_polling_loops"] == 0, metrics


def test_reverse_neighbour_statement_json_encode_is_not_attributed(tmp_path):
    """广播后面的语句里有 json.encode，不该算到这次广播头上（固定窗口就是这么误判的）。"""
    body = ("CreateThread(function()\n"
            "  TriggerClientEvent('x:sync', -1, payload)\n"
            "  local blob = json.encode({ a = 1 })\n"
            "end)\n")
    metrics = budget_probe.measure(_fixture(tmp_path, body))
    assert metrics["broadcast_sites"] == 1 and metrics["broadcast_inline_json"] == 0, metrics


def test_reverse_long_broadcast_argument_list_is_still_detected(tmp_path):
    """参数很长（远超固定窗口）时也要认出来。"""
    padding = ", ".join(f"field_{index} = {index}" for index in range(80))
    body = ("CreateThread(function()\n"
            f"  TriggerClientEvent('x:sync', -1, json.encode({{ {padding} }}))\n"
            "end)\n")
    metrics = budget_probe.measure(_fixture(tmp_path, body))
    assert metrics["broadcast_inline_json"] == 1, metrics


def test_reverse_for_loop_wait_is_classified_as_conditional(tmp_path):
    """`for i = 1, n do Wait(0) end` 是有限循环：算 conditional busy-wait，不算无限轮询。"""
    body = ("local function f(n)\n"
            "  for i = 1, n do\n"
            "    Wait(0)\n"
            "  end\n"
            "end\n")
    metrics = budget_probe.measure(_fixture(tmp_path, body))
    assert metrics["conditional_busy_wait_loops"] == 1, metrics
    assert metrics["wait_zero_loops"] == 0, metrics


def test_reverse_string_with_end_does_not_truncate_loop_body(tmp_path):
    """`print("end")` 里的 end 不能把循环体截短（词法切分后它是字符串 token）。"""
    body = ("CreateThread(function()\n"
            "  while true do\n"
            '    print("end")\n'
            "    Wait(50)\n"
            "  end\n"
            "end)\n")
    metrics = budget_probe.measure(_fixture(tmp_path, body))
    assert metrics["fast_polling_loops"] == 1, metrics


def test_reverse_nested_thread_is_counted_once_per_loop(tmp_path):
    """嵌套 `CreateThread` 里的循环各算各的：外层 60 秒、内层 50ms → 一 warm 一 fast。"""
    body = ("CreateThread(function()\n"
            "  while true do\n"
            "    CreateThread(function()\n"
            "      while true do\n"
            "        Wait(50)\n"
            "      end\n"
            "    end)\n"
            "    Wait(60000)\n"
            "  end\n"
            "end)\n")
    metrics = budget_probe.measure(_fixture(tmp_path, body))
    assert metrics["fast_polling_loops"] == 1, metrics
    assert metrics["warm_polling_loops"] == 0, metrics


def test_reverse_elseif_does_not_break_block_matching(tmp_path):
    """`elseif … then` 不多算一层块：循环体要完整取到 Wait。"""
    body = ("CreateThread(function()\n"
            "  while true do\n"
            "    if a then\n"
            "      x = 1\n"
            "    elseif b then\n"
            "      x = 2\n"
            "    end\n"
            "    Wait(40)\n"
            "  end\n"
            "end)\n")
    metrics = budget_probe.measure(_fixture(tmp_path, body))
    assert metrics["fast_polling_loops"] == 1, metrics


def test_reverse_repeat_until_false_is_infinite_but_until_cond_is_not(tmp_path):
    """`repeat Wait(50) until false` 是无限轮询；`until done` 是等条件循环 —— 别混为一谈。"""
    infinite = _fixture(tmp_path / "a", "CreateThread(function()\n  repeat\n    Wait(50)\n  until false\nend)\n")
    conditional = _fixture(tmp_path / "b", "CreateThread(function()\n  local done = false\n  repeat\n    Wait(50)\n  until done\nend)\n")

    infinite_metrics = budget_probe.measure(infinite)
    conditional_metrics = budget_probe.measure(conditional)

    assert infinite_metrics["fast_polling_loops"] == 1, infinite_metrics
    assert conditional_metrics["fast_polling_loops"] == 0, conditional_metrics
    assert conditional_metrics["conditional_busy_wait_loops"] == 0, conditional_metrics


def test_reverse_repeat_until_constant_false_forms_are_infinite(tmp_path):
    """`until false` / `until (false)` / `until 1 == 2` 都是恒假 → 无限轮询；`until not cond` 是等条件。"""
    for index, condition in enumerate(("false", "(false)", "1 == 2")):
        resources = _fixture(tmp_path / f"case{index}",
                             "CreateThread(function()\n  repeat\n    Wait(0)\n"
                             f"  until {condition}\nend)\n")
        metrics = budget_probe.measure(resources)
        assert metrics["wait_zero_loops"] == 1, (condition, metrics)

    conditional = _fixture(
        tmp_path / "cond",
        "CreateThread(function()\n  local cond = false\n  repeat\n    Wait(0)\n  until not cond\nend)\n")
    metrics = budget_probe.measure(conditional)
    assert metrics["wait_zero_loops"] == 0, metrics
    assert metrics["conditional_busy_wait_loops"] == 1, metrics
