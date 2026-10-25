"""FIT-14 — the rule hit-rate collector is itself a checked contract.

``tools/dev/gate_stats.py`` turns §5 of ``docs/engineering/agent-operating-model.md``
into a number: every architecture-gate run is appended to
``tests/architecture/gate_history.jsonl`` and every rule (pytest nodeid) gets a
"did it ever fire?" verdict.

This file only asserts things that are cheap and offline:

* the module imports and still exposes the four entry points the workflow calls;
* ``--report`` on an empty (or missing) history exits 0 and says ``0 条`` —
  a report tool must not fail because there is nothing to report yet;
* the pytest-summary parser classifies ``PASSED`` / ``FAILED`` / ``ERROR``
  correctly, with a reverse check (feed it one line each and require the exact
  mapping) so a regex tweak cannot silently turn every rule green;
* corrupt history lines are skipped and counted rather than crashing the report;
* a rule that never failed lands in the ``zero hit`` list, one that failed does not.

    python3 -m pytest -q tests/architecture/test_gate_stats.py
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
BASE = REPO / "T-CityLite.base"
TOOL = REPO / "tools" / "dev" / "gate_stats.py"


def _load_module():
    """Load ``tools/dev/gate_stats.py`` from its path (tools/ is not a package)."""
    import importlib.util

    assert TOOL.is_file(), f"missing tool: {TOOL}"
    spec = importlib.util.spec_from_file_location("gate_stats", TOOL)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("gate_stats", module)
    spec.loader.exec_module(module)
    return module


gate_stats = _load_module()


def test_module_exposes_the_entry_points():
    for name in ("parse_pytest_summary", "build_record", "load_history", "build_report", "render_text", "main"):
        assert callable(getattr(gate_stats, name, None)), f"gate_stats.{name} is not callable"
    assert gate_stats.HISTORY == BASE / "tests" / "architecture" / "gate_history.jsonl"


def test_parser_classifies_passed_failed_and_error():
    """Reverse check: one line each, exact status, no extra keys."""
    text = "\n".join(
        [
            "PASSED tests/architecture/test_alpha.py::test_ok",
            "FAILED tests/architecture/test_alpha.py::test_broken",
            "ERROR tests/architecture/test_alpha.py::test_fixture_blew_up",
        ]
    )
    parsed = gate_stats.parse_pytest_summary(text)
    assert parsed == {
        "tests/architecture/test_alpha.py::test_ok": "passed",
        "tests/architecture/test_alpha.py::test_broken": "failed",
        "tests/architecture/test_alpha.py::test_fixture_blew_up": "failed",
    }


def test_parser_ignores_prose_and_failure_bodies():
    """Failure bodies mention PASSED/FAILED too — only summary lines count."""
    text = "\n".join(
        [
            "tests/architecture/test_a.py .F                                   [ 50%]",
            "E   AssertionError: expected PASSED but got FAILED",
            "PASSED tests/architecture/test_a.py::test_one",
            "FAILED tests/architecture/test_a.py::test_two - AssertionError: nope",
        ]
    )
    parsed = gate_stats.parse_pytest_summary(text)
    assert parsed == {
        "tests/architecture/test_a.py::test_one": "passed",
        "tests/architecture/test_a.py::test_two": "failed",
    }


def test_record_counts_skip_skipped():
    record = gate_stats.build_record(
        {"a::ok": "passed", "a::bad": "failed", "a::skipped": "skipped"},
        commit="deadbeef",
        ts="2026-10-25T00:00:00Z",
    )
    assert record["ts"] == "2026-10-25T00:00:00Z"
    assert record["commit"] == "deadbeef"
    assert record["counts"] == {"a::ok": "passed", "a::bad": "failed"}


def test_report_on_missing_history_exits_zero(tmp_path):
    """No history file → exit 0, empty history, and the literal '0 条' in the text."""
    history = tmp_path / "gate_history.jsonl"
    assert not history.exists()
    proc = subprocess.run(
        [sys.executable, str(TOOL), "--report", "--history", str(history)],
        cwd=str(REPO),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert "0 条" in proc.stdout
    assert not history.exists(), "a report must not create the history file"


def test_report_on_empty_file_exits_zero(tmp_path):
    history = tmp_path / "gate_history.jsonl"
    history.write_text("", encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(TOOL), "--report", "--history", str(history)],
        cwd=str(REPO),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert "0 条" in proc.stdout


def test_default_invocation_without_flags_is_report(tmp_path):
    history = tmp_path / "gate_history.jsonl"
    proc = subprocess.run(
        [sys.executable, str(TOOL), "--history", str(history)],
        cwd=str(REPO),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert "0 条" in proc.stdout


def test_record_against_a_missing_arch_dir_exits_two(tmp_path):
    proc = subprocess.run(
        [
            sys.executable,
            str(TOOL),
            "--record",
            "--arch",
            str(tmp_path / "nope"),
            "--history",
            str(tmp_path / "h.jsonl"),
        ],
        cwd=str(REPO),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 2
    assert "找不到 pytest 目录" in proc.stderr


def test_corrupt_lines_are_skipped_and_counted(tmp_path):
    history = tmp_path / "gate_history.jsonl"
    good = {"ts": "2026-10-25T00:00:00Z", "commit": "abc1234", "counts": {"a::ok": "passed"}}
    history.write_text(
        "\n".join(
            [
                json.dumps(good),
                "{not json",
                json.dumps({"ts": "x"}),  # missing counts → counted as bad
                "",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    records, bad = gate_stats.load_history(history)
    assert len(records) == 1
    assert bad == 2


def test_zero_hit_list_separates_never_failed_from_used_rules(tmp_path):
    history = tmp_path / "gate_history.jsonl"
    rows = [
        {"ts": "2026-10-25T00:00:00Z", "commit": "a", "counts": {"r::used": "failed", "r::idle": "passed"}},
        {"ts": "2026-10-25T00:01:00Z", "commit": "b", "counts": {"r::used": "passed", "r::idle": "passed"}},
    ]
    history.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(TOOL), "--report", "--json", "--history", str(history)],
        cwd=str(REPO),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    report = json.loads(proc.stdout)
    assert report["zero_hit"] == ["r::idle"]
    assert report["records"] == 2
    assert report["summary"].startswith("2 条规则")
    used = next(r for r in report["rules"] if r["nodeid"] == "r::used")
    assert used["last"] == "passed"
    assert used["pass"] == 1 and used["fail"] == 1
    assert used["fail_total"] == 1
    idle = next(r for r in report["rules"] if r["nodeid"] == "r::idle")
    assert idle["fail_total"] == 0


def test_report_marks_a_red_run_as_not_all_green(tmp_path):
    history = tmp_path / "gate_history.jsonl"
    rows = [
        {"ts": "2026-10-25T00:00:00Z", "commit": "a", "counts": {"r::one": "passed"}},
        {"ts": "2026-10-25T00:01:00Z", "commit": "b", "counts": {"r::one": "failed"}},
    ]
    history.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
    proc = subprocess.run(
        [sys.executable, str(TOOL), "--report", "--history", str(history)],
        cwd=str(REPO),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert "最近一次有失败" in proc.stdout
    zero_hit_section = proc.stdout.split("连续 0 命中")[1]
    assert "r::one" not in zero_hit_section


def test_window_limits_the_pass_fail_counts(tmp_path):
    history = tmp_path / "gate_history.jsonl"
    rows = [
        {"ts": f"2026-10-25T00:0{i}:00Z", "commit": "a", "counts": {"r::w": "failed" if i < 2 else "passed"}}
        for i in range(4)
    ]
    history.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
    records, bad = gate_stats.load_history(history)
    assert bad == 0
    report = gate_stats.build_report(records, window=2, bad_lines=bad, history_path=history)
    rule = report["rules"][0]
    assert (rule["pass"], rule["fail"]) == (2, 0), "window=2 must look at the last two records only"
    assert rule["fail_total"] == 2, "total failures are all-time, not windowed"
