"""P4 #412 — 产业仿真器验收：确定性 / 四策略 / 基线告警 / 服务端权威。

被测对象是 `tools/dev/industry_sim/run_sim.py`：它复用 `industry_harness` 的假 DB
装配链，驱动**真实** `production / sale / settlement / cycle` 跑 13 周。这里只断言
仿真器的契约，不复制任何产业公式：

1. 同参数两次跑，JSONL 逐字节一致（sha256 也一致）；
2. 四种策略都能跑完 13 周，且 `max` 的工位数 >= `idle`；
3. 基线比对：默认配置（SalePrice=50）通过；
4. 服务端权威自证：把 `industry_sale_price` 改成 60（+20% 售价）后，基线比对
   必须报出超阈值并以非零退出 —— 证明价格确实来自服务端配置、不是仿真器硬编码。

Run: ``python -m pytest -q tests/unit/layer3_business/test_industry_sim.py``
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
REPO = BASE.parent
RUNNER = REPO / "tools" / "dev" / "industry_sim" / "run_sim.py"
BASELINE = BASE / "tests" / "architecture" / "industry_sim_baseline.json"
WEEKS = 13
POLICIES = ("idle", "steady", "max", "hoard")
WEEK_KEYS = {
    "kind",
    "week",
    "quarter",
    "season",
    "workstations",
    "stock",
    "stock_cap",
    "quota_used",
    "revenue",
    "treasury",
    "prestige",
    "withdrawals",
    "tax_burned",
}


def load_runner():
    """按路径加载 runner（tools/ 不是 package），供纯函数反向校验使用。"""
    spec = importlib.util.spec_from_file_location("industry_run_sim", RUNNER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_runner(out: Path, policy: str, *extra: str, timeout: int = 240):
    """跑一次 CLI，返回 CompletedProcess。"""
    return subprocess.run(
        [
            sys.executable,
            str(RUNNER),
            "--weeks",
            str(WEEKS),
            "--policy",
            policy,
            "--out",
            str(out),
            *extra,
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def read_records(path: Path) -> tuple[list[dict], dict]:
    lines = path.read_text(encoding="utf-8").splitlines()
    records = [json.loads(line) for line in lines if line.strip()]
    weekly = [row for row in records if row.get("kind") == "week"]
    summaries = [row for row in records if row.get("kind") == "summary"]
    assert len(summaries) == 1, f"summary 行应恰好一条，实际 {len(summaries)}"
    return weekly, summaries[0]


@pytest.fixture(scope="module")
def runs(tmp_path_factory: pytest.TempPathFactory) -> dict[str, tuple[list[dict], dict]]:
    """四种策略各跑一次 13 周；同一份结果供多个用例共享。"""
    workdir = tmp_path_factory.mktemp("industry_sim_policies")
    results: dict[str, tuple[list[dict], dict]] = {}
    for policy in POLICIES:
        proc = run_runner(workdir / f"{policy}.jsonl", policy)
        assert proc.returncode == 0, (
            f"{policy} 仿真失败（rc={proc.returncode}）:\n"
            f"stdout={proc.stdout}\nstderr={proc.stderr}"
        )
        results[policy] = read_records(workdir / f"{policy}.jsonl")
    return results


def test_jsonl_is_byte_identical_across_runs(tmp_path: Path) -> None:
    """同参数两次跑：JSONL 逐字节一致（确定性是基线有意义的前提）。"""
    first = tmp_path / "a.jsonl"
    second = tmp_path / "b.jsonl"

    proc_a = run_runner(first, "steady")
    proc_b = run_runner(second, "steady")
    assert proc_a.returncode == 0, proc_a.stderr
    assert proc_b.returncode == 0, proc_b.stderr

    bytes_a = first.read_bytes()
    bytes_b = second.read_bytes()
    assert bytes_a == bytes_b, "两次跑的 JSONL 不是逐字节一致"

    digest = hashlib.sha256(bytes_a).hexdigest()
    assert digest == hashlib.sha256(bytes_b).hexdigest()


def test_four_policies_finish_13_weeks(runs) -> None:
    """四种策略都跑完 13 周，字段齐全；max 的工位数 >= idle。"""
    for policy, (weekly, summary) in runs.items():
        assert len(weekly) == WEEKS, f"{policy} 应有 {WEEKS} 条周记录"
        assert [row["week"] for row in weekly] == list(range(1, WEEKS + 1))
        assert summary["policy"] == policy
        assert summary["weeks"] == WEEKS
        for row in weekly:
            assert set(row) == WEEK_KEYS, f"{policy} 周记录字段不对：{sorted(row)}"
            assert row["quarter"] == 1
            assert row["season"] == "winter"  # 每周固定以冬季收尾
            assert row["tax_burned"] <= row["withdrawals"]

    idle = runs["idle"][1]
    maxed = runs["max"][1]
    assert idle["workstations"] == 0
    assert maxed["workstations"] >= idle["workstations"]

    # 有产能的策略必须真的卖出东西；idle 什么都不做。
    for policy in ("steady", "max", "hoard"):
        assert runs[policy][1]["quarter_revenue"] > 0, f"{policy} 没有收入"
    assert idle["quarter_revenue"] == 0


def test_baseline_matches_default_config(tmp_path: Path) -> None:
    """默认 SalePrice=50 时，基线比对通过（退出码 0）。"""
    assert BASELINE.is_file(), f"基线不存在：{BASELINE}"
    proc = run_runner(tmp_path / "baseline.jsonl", "steady", "--baseline", str(BASELINE))
    assert proc.returncode == 0, f"基线比对意外失败：\n{proc.stdout}\n{proc.stderr}"
    assert "BASELINE OK" in proc.stdout


def test_sale_price_change_breaks_baseline(tmp_path: Path) -> None:
    """服务端权威自证：SalePrice 50→60（+20%），基线比对必须报差异并非零退出。"""
    proc = run_runner(
        tmp_path / "price60.jsonl",
        "steady",
        "--sale-price",
        "60",
        "--baseline",
        str(BASELINE),
    )
    assert proc.returncode != 0, (
        "改了服务端售价却仍然通过基线 —— 价格可能被仿真器硬编码了：\n" + proc.stdout
    )
    assert "BASELINE MISMATCH" in proc.stdout
    assert "quarter_revenue" in proc.stdout


def test_compare_helper_rejects_out_of_tolerance() -> None:
    """反向校验：±10% 阈值本身必须能变红，且基线为 0 时任何非零都算偏离。"""
    runner = load_runner()
    baseline = {"metrics": {"quarter_revenue": 100, "workstations": 2, "stock_level": 0}}

    assert runner.compare_to_baseline(
        {"quarter_revenue": 105, "workstations": 2, "stock_level": 0}, baseline, 0.10
    ) == []
    assert runner.compare_to_baseline(
        {"quarter_revenue": 120, "workstations": 2, "stock_level": 0}, baseline, 0.10
    )
    assert runner.compare_to_baseline(
        {"quarter_revenue": 105, "workstations": 2, "stock_level": 1}, baseline, 0.10
    )
