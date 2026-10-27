"""GATES-03 — "从未被证明会红"的规则数是一个预算，只许往下走。

`gate_stats.py` 数的是命中率，但 0 命中在报表上只有一种长相：可能是"它保护的形状真的
不存在了"，也可能是"从来没人给它写过反向注入"。后者会让人误以为安全。

所以把"证明"单独定义（由 `tools/dev/gate_coverage.py` 计算）：一条规则算已证明，当且仅当
（1）它在 gate_history 里失败过，（2）它是 `gate_mutation_smoke.py` 的变异用例，
或（3）它本身就是反向校验（名字带 reverse/injected/fires/detects/rejects/on_bad_shapes）。

剩下的就是技术债。这里给它一个上限：**超过上限红，明显低于上限也红**
（否则预算会永远停留在旧数字，没人去收紧——和复用预算是同一套棘轮逻辑）。
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
REPO = BASE.parent
BUDGET = Path(__file__).with_name("gate_coverage_budget.json")
COVERAGE_TOOL = REPO / "tools" / "dev" / "gate_coverage.py"

#: 允许"低于预算"的余量：加了变异用例却忘了收紧预算时，最多容忍这么多。
TIGHTEN_TOLERANCE = 3


def coverage() -> dict:
    spec = importlib.util.spec_from_file_location("gate_coverage", COVERAGE_TOOL)
    assert spec and spec.loader, f"找不到覆盖率工具：{COVERAGE_TOOL}"
    module = importlib.util.module_from_spec(spec)
    sys.modules["gate_coverage"] = module
    spec.loader.exec_module(module)
    return module.coverage()


def budget() -> dict:
    return json.loads(BUDGET.read_text(encoding="utf-8"))


def test_unproven_rules_do_not_exceed_the_budget():
    data = coverage()
    limit = budget()["max_unproven"]
    assert data["unproven"] <= limit, (
        f"未证明的规则从 {limit} 涨到 {data['unproven']}。新增规则必须同时给它一个证明："
        "要么写一条变异用例（tools/dev/gate_mutation_smoke.py），要么让测试自己构造坏形状并断言失败。")


def test_budget_is_tightened_when_proofs_are_added():
    data = coverage()
    limit = budget()["max_unproven"]
    assert data["unproven"] >= limit - TIGHTEN_TOLERANCE, (
        f"未证明的规则已经降到 {data['unproven']}，但预算还写着 {limit}。"
        f"把 gate_coverage_budget.json 的 max_unproven 改成 {data['unproven']}（棘轮只许往下走）。")


def test_budget_records_when_and_why():
    data = budget()
    assert data.get("note", "").strip(), "预算文件要写清这个数字意味着什么"
    assert data.get("since"), "预算文件要记下建立日期，便于回看收敛速度"


def test_coverage_is_not_vacuous():
    """防止"扫描不到任何规则 → 未证明为 0 → 永远绿"。"""
    data = coverage()
    assert data["total"] >= 150, f"只扫到 {data['total']} 条规则，范围被改坏了？"
    assert data["proven"] >= 40, f"已证明的规则只有 {data['proven']} 条，统计逻辑坏了？"


def test_every_smoke_case_targets_a_rule_that_exists():
    """变异用例指向的 nodeid 必须真是架构规则，否则它在给一条不存在的规则"作证"。"""
    data = coverage()
    spec = importlib.util.spec_from_file_location(
        "gate_mutation_smoke", REPO / "tools" / "dev" / "gate_mutation_smoke.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["gate_mutation_smoke"] = module
    spec.loader.exec_module(module)

    known = set()
    for path in (BASE / "tests" / "architecture").glob("test_*.py"):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for line in text.splitlines():
            if line.startswith("def test_"):
                known.add(f"tests/architecture/{path.name}::{line[len('def '):].split('(')[0]}")

    missing = [case.gate for case in module.MUTATIONS if case.gate not in known]
    assert not missing, "变异用例指向了不存在的规则：\n  " + "\n  ".join(missing)
    assert data["proven_by_smoke"] > 0
