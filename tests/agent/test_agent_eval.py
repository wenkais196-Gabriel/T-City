#!/usr/bin/env python3
"""Tests for the offline agent action evaluator (tools/agent_eval.py).

No database, no network: every case builds an in-memory or temporary JSONL/JSON
export.  Run from the repository root:

    python3 -m pytest -q tests/agent/test_agent_eval.py
    python3 -m unittest tests.agent.test_agent_eval -v
"""

from __future__ import annotations

import contextlib
import datetime as dt
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import agent_eval  # noqa: E402

BASE = dt.datetime(2026, 10, 22, 18, 0, 0, tzinfo=dt.timezone.utc)


def iso(offset_ms: int = 0) -> str:
    stamp = BASE + dt.timedelta(milliseconds=offset_ms)
    return stamp.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def make_row(**overrides: object) -> dict:
    row = {
        "id": 1,
        "agent_id": "director.rules",
        "action_type": "set_weather",
        "status": "executed",
        "params": '{"weather":"RAIN"}',
        "result": '{"weather":"RAIN","verify_result":true}',
        "error": None,
        "requested_at": iso(0),
        "approved_at": iso(5000),
        "executed_at": iso(5200),
        "approved_by": "discord:alice",
        "expires_at": None,
        "idempotency_key": "k1",
    }
    row.update(overrides)
    return row


class TempFileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-eval-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        # The evaluator confines reads/writes to AGENT_EVAL_ROOT; temp files
        # live outside the repo, so point the root at the per-test directory.
        previous = os.environ.get("AGENT_EVAL_ROOT")
        os.environ["AGENT_EVAL_ROOT"] = str(self.tmp)
        self.addCleanup(self._restore_root, previous)

    @staticmethod
    def _restore_root(previous: str | None) -> None:
        if previous is None:
            os.environ.pop("AGENT_EVAL_ROOT", None)
        else:
            os.environ["AGENT_EVAL_ROOT"] = previous

    def write(self, name: str, text: str) -> Path:
        path = self.tmp / name
        path.write_text(text, encoding="utf-8")
        return path

    def call_main(self, argv: list[str]) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = agent_eval.main(argv)
        return code, out.getvalue(), err.getvalue()


class LoadRowsTests(TempFileTests):
    def test_path_outside_root_is_rejected(self) -> None:
        # The evaluator is agent-callable; --input/--out must not escape the
        # configured root (this is the Sandbox/Path-Traversal guard).
        with self.assertRaises(ValueError):
            agent_eval.load_rows("/etc/hostname")

    def test_empty_file_is_an_empty_list(self) -> None:
        rows = agent_eval.load_rows(self.write("empty.jsonl", ""))
        self.assertEqual(len(rows), 0)
        self.assertEqual(rows.bad_lines, 0)
        self.assertIsInstance(rows, list)

    def test_bad_lines_are_skipped_counted_and_reported(self) -> None:
        path = self.write(
            "bad.jsonl",
            "\n".join(
                [
                    json.dumps(make_row(id=1, idempotency_key="a")),
                    "",
                    "{not json",
                    "[1, 2]",
                    json.dumps(make_row(id=2, idempotency_key="b")),
                ]
            )
            + "\n",
        )
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rows = agent_eval.load_rows(path)
        self.assertEqual([row["id"] for row in rows], [1, 2])
        self.assertEqual(rows.bad_lines, 2)
        self.assertEqual(len(rows.bad_samples), 2)
        self.assertIn("skipped 2 malformed record(s)", err.getvalue())

    def test_json_array_input_and_non_object_items(self) -> None:
        path = self.write(
            "rows.json",
            json.dumps(
                [
                    make_row(id=1, idempotency_key="a"),
                    42,
                    "not-a-row",
                    make_row(id=2, idempotency_key="b"),
                ]
            ),
        )
        rows = agent_eval.load_rows(path, warn=False)
        self.assertEqual([row["id"] for row in rows], [1, 2])
        self.assertEqual(rows.bad_lines, 2)

    def test_single_json_object_is_accepted(self) -> None:
        path = self.write("single.json", json.dumps(make_row(id=7)))
        rows = agent_eval.load_rows(path)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], 7)

    def test_missing_file_raises_oserror(self) -> None:
        with self.assertRaises(OSError):
            agent_eval.load_rows(self.tmp / "nope.jsonl")


class SummaryTests(unittest.TestCase):
    def test_empty_report_is_zero_valued_not_an_error(self) -> None:
        report = agent_eval.summarize([])
        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(report["totals"]["actions"], 0)
        self.assertEqual(report["totals"]["by_status"], {})
        for value in report["rates"].values():
            self.assertIsNone(value)
        for key in ("p50", "p90", "p95", "max"):
            self.assertIsNone(report["latency_ms"][key])
        self.assertEqual(report["latency_ms"]["samples"], 0)
        self.assertEqual(report["latency_ms"]["skipped_samples"], 0)
        self.assertEqual(report["idempotency"]["duplicate_keys"], 0)
        self.assertIsNone(report["idempotency"]["replay_rate"])
        self.assertIsNone(report["risk"])
        self.assertIn("越权拒绝率无法从本表计算", report["notes"][0])
        self.assertIn("# Agent Action Evaluation", agent_eval.render_markdown(report))

    def test_totals_and_distributions(self) -> None:
        rows = [
            make_row(id=1, status="executed", action_type="notify", agent_id="a", idempotency_key="1"),
            make_row(id=2, status="failed", action_type="notify", agent_id="a", idempotency_key="2"),
            make_row(id=3, status="rejected", action_type="set_weather", agent_id="b", idempotency_key="3"),
            make_row(id=4, status="pending_approval", action_type="add_money", agent_id="b", idempotency_key="4"),
        ]
        report = agent_eval.summarize(rows)
        totals = report["totals"]
        self.assertEqual(totals["actions"], 4)
        self.assertEqual(
            totals["by_status"],
            {"executed": 1, "failed": 1, "pending_approval": 1, "rejected": 1},
        )
        self.assertEqual(totals["by_action"], {"add_money": 1, "notify": 2, "set_weather": 1})
        self.assertEqual(totals["by_agent"], {"a": 2, "b": 2})

    def test_success_rate_denominator_is_executed_plus_failed(self) -> None:
        rows = [
            make_row(id=1, status="executed", idempotency_key="1"),
            make_row(id=2, status="executed", idempotency_key="2"),
            make_row(id=3, status="failed", error="execution_failed", idempotency_key="3"),
            make_row(id=4, status="rejected", approved_at=iso(1), idempotency_key="4"),
        ]
        report = agent_eval.summarize(rows)
        self.assertAlmostEqual(report["rates"]["execution_success_rate"], 2 / 3)
        self.assertEqual(report["counts"]["terminal_executions"], 3)

    def test_success_rate_is_null_without_terminal_rows(self) -> None:
        rows = [
            make_row(id=1, status="pending_approval", approved_at=None, executed_at=None, idempotency_key="1"),
            make_row(id=2, status="rejected", idempotency_key="2"),
        ]
        report = agent_eval.summarize(rows)
        self.assertIsNone(report["rates"]["execution_success_rate"])
        self.assertIsNone(report["rates"]["verification_failure_rate"])

    def test_rejection_rate_uses_all_persisted_rows(self) -> None:
        rows = [
            make_row(id=1, status="executed", idempotency_key="1"),
            make_row(id=2, status="rejected", idempotency_key="2"),
            make_row(id=3, status="pending_approval", approved_at=None, executed_at=None, idempotency_key="3"),
            make_row(id=4, status="proposed", approved_at=None, executed_at=None, idempotency_key="4"),
        ]
        report = agent_eval.summarize(rows)
        self.assertAlmostEqual(report["rates"]["rejection_rate"], 0.25)

    def test_verification_failures_from_error_and_result_text(self) -> None:
        rows = [
            make_row(
                id=1,
                status="failed",
                error="amount_verification_failed before=1 after=1 expected=50",
                idempotency_key="1",
            ),
            make_row(
                id=2,
                status="failed",
                error=None,
                result={"error": "verification_failed before=1 after=2"},
                idempotency_key="2",
            ),
            make_row(id=3, status="executed", idempotency_key="3"),
            make_row(id=4, status="executed", idempotency_key="4"),
        ]
        report = agent_eval.summarize(rows)
        self.assertEqual(report["counts"]["verification_failures"], 2)
        self.assertAlmostEqual(report["rates"]["verification_failure_rate"], 0.5)

    def test_approval_rate_excludes_auto_approved_and_dry_run_rows(self) -> None:
        rows = [
            make_row(id=1, status="executed", approved_by="auto", idempotency_key="1"),
            make_row(id=2, status="executed", approved_by="auto", idempotency_key="2"),
            make_row(id=3, status="executed", approved_by="discord:alice", idempotency_key="3"),
            make_row(
                id=4,
                status="pending_approval",
                approved_by=None,
                approved_at=None,
                executed_at=None,
                idempotency_key="4",
            ),
            make_row(id=5, status="rejected", approved_by="discord:bob", idempotency_key="5"),
            make_row(
                id=6,
                status="proposed",
                approved_by=None,
                approved_at=None,
                executed_at=None,
                idempotency_key="6",
            ),
        ]
        report = agent_eval.summarize(rows)
        self.assertEqual(report["counts"]["approval_required"], 3)
        self.assertEqual(report["counts"]["approval_decisions"], 2)
        self.assertAlmostEqual(report["rates"]["approval_rate"], 2 / 3)
        # approved=1 (alice), rejected=1 -> 1/2; two auto rows are not decisions.
        self.assertAlmostEqual(report["rates"]["human_approval_rate"], 1 / 2)
        self.assertAlmostEqual(report["rates"]["approval_required_rate"], 3 / 6)

    def test_approval_rate_is_null_when_nothing_needs_approval(self) -> None:
        rows = [
            make_row(id=1, status="executed", approved_by="auto", idempotency_key="1"),
            make_row(
                id=2,
                status="proposed",
                approved_by=None,
                approved_at=None,
                executed_at=None,
                idempotency_key="2",
            ),
        ]
        report = agent_eval.summarize(rows)
        self.assertEqual(report["counts"]["approval_required"], 0)
        self.assertIsNone(report["rates"]["approval_rate"])
        self.assertIsNone(report["rates"]["human_approval_rate"])
        self.assertEqual(report["rates"]["approval_required_rate"], 0.0)


class LatencyTests(unittest.TestCase):
    def test_percentiles_use_nearest_rank_on_fixed_timestamps(self) -> None:
        rows = [
            make_row(id=i, requested_at=iso(0), executed_at=iso(offset), idempotency_key=f"k{i}")
            for i, offset in enumerate((100, 200, 300, 400, 500), 1)
        ]
        report = agent_eval.summarize(rows)["latency_ms"]
        self.assertEqual(report["samples"], 5)
        self.assertEqual(report["skipped_samples"], 0)
        self.assertAlmostEqual(report["p50"], 300, delta=1)
        self.assertAlmostEqual(report["p90"], 500, delta=1)
        self.assertAlmostEqual(report["p95"], 500, delta=1)
        self.assertAlmostEqual(report["max"], 500, delta=1)

    def test_epoch_milliseconds_are_supported(self) -> None:
        requested = 1729620000000
        rows = [
            make_row(
                id=i,
                requested_at=requested,
                executed_at=requested + offset,
                idempotency_key=f"k{i}",
            )
            for i, offset in enumerate((10, 20, 30), 1)
        ]
        report = agent_eval.summarize(rows)["latency_ms"]
        self.assertEqual(report["samples"], 3)
        self.assertEqual(report["p50"], 20)
        self.assertEqual(report["p90"], 30)
        self.assertEqual(report["p95"], 30)
        self.assertEqual(report["max"], 30)

    def test_missing_executed_at_is_excluded_and_counted_as_skipped(self) -> None:
        rows = [
            make_row(id=1, executed_at=None, idempotency_key="1"),
            make_row(id=2, executed_at=iso(100), idempotency_key="2"),
            make_row(id=3, requested_at=None, executed_at=iso(100), idempotency_key="3"),
        ]
        report = agent_eval.summarize(rows)["latency_ms"]
        self.assertEqual(report["samples"], 1)
        self.assertEqual(report["skipped_samples"], 2)
        self.assertEqual(report["p50"], 100)

    def test_non_terminal_rows_are_not_latency_samples(self) -> None:
        rows = [
            make_row(
                id=1,
                status="pending_approval",
                approved_at=None,
                executed_at=None,
                idempotency_key="1",
            ),
            make_row(id=2, status="rejected", executed_at=None, idempotency_key="2"),
        ]
        report = agent_eval.summarize(rows)["latency_ms"]
        self.assertEqual(report["samples"], 0)
        self.assertEqual(report["skipped_samples"], 0)
        self.assertIsNone(report["p95"])

    def test_unparseable_timestamp_is_skipped(self) -> None:
        rows = [make_row(id=1, executed_at="yesterday", idempotency_key="1")]
        report = agent_eval.summarize(rows)["latency_ms"]
        self.assertEqual(report["samples"], 0)
        self.assertEqual(report["skipped_samples"], 1)

    def test_negative_latency_is_kept_but_counted(self) -> None:
        rows = [make_row(id=1, requested_at=iso(500), executed_at=iso(100), idempotency_key="1")]
        report = agent_eval.summarize(rows)["latency_ms"]
        self.assertEqual(report["samples"], 1)
        self.assertEqual(report["negative_samples"], 1)
        self.assertEqual(report["max"], -400)


class IdempotencyTests(unittest.TestCase):
    def test_duplicate_keys_and_replay_rate(self) -> None:
        keys = ["a", "a", "a", "b", "b", "c"]
        rows = [make_row(id=i, idempotency_key=key) for i, key in enumerate(keys, 1)]
        report = agent_eval.summarize(rows)["idempotency"]
        self.assertEqual(report["duplicate_keys"], 2)
        self.assertEqual(report["duplicate_key_rows"], 5)
        self.assertEqual(report["rows_with_key"], 6)
        self.assertAlmostEqual(report["replay_rate"], 3 / 6)

    def test_missing_or_blank_keys_are_excluded(self) -> None:
        rows = [
            make_row(id=1, idempotency_key=None),
            make_row(id=2, idempotency_key=""),
        ]
        report = agent_eval.summarize(rows)["idempotency"]
        self.assertEqual(report["duplicate_keys"], 0)
        self.assertEqual(report["rows_with_key"], 0)
        self.assertIsNone(report["replay_rate"])


class RiskAndNotesTests(unittest.TestCase):
    def test_risk_is_null_without_a_row_level_field(self) -> None:
        report = agent_eval.summarize([make_row()])
        self.assertIsNone(report["risk"])
        self.assertIn("越权拒绝率无法从本表计算", report["notes"][0])
        self.assertTrue(any("risk" in note and "null" in note for note in report["notes"]))
        self.assertTrue(any("不落库" in note for note in report["notes"]))

    def test_risk_extra_field_is_aggregated_without_guessing(self) -> None:
        rows = [
            make_row(id=1, risk="L3", idempotency_key="1"),
            make_row(id=2, risk="L3", idempotency_key="2"),
            make_row(id=3, risk="L4", idempotency_key="3"),
            make_row(id=4, idempotency_key="4"),
        ]
        risk = agent_eval.summarize(rows)["risk"]
        self.assertEqual(risk["by_risk"], {"L3": 2, "L4": 1})
        self.assertEqual(risk["labeled_actions"], 3)
        self.assertEqual(risk["unlabeled_actions"], 1)

    def test_unknown_fields_are_ignored(self) -> None:
        row = make_row(extra_field={"nested": [1, 2, 3]}, another="x")
        report = agent_eval.summarize([row])
        self.assertEqual(report["totals"]["actions"], 1)
        self.assertEqual(report["rates"]["execution_success_rate"], 1.0)


class MarkdownTests(unittest.TestCase):
    def test_markdown_contains_key_tables_and_headers(self) -> None:
        report = agent_eval.summarize([make_row()])
        markdown = agent_eval.render_markdown(report)
        for header in (
            "# Agent Action Evaluation",
            "## Totals",
            "## Rates",
            "## Latency",
            "## Idempotency",
            "## Notes",
        ):
            self.assertIn(header, markdown)
        self.assertIn("| Execution success rate |", markdown)
        self.assertIn("| p95 |", markdown)
        self.assertIn("| Duplicate keys |", markdown)

    def test_markdown_marks_empty_sections(self) -> None:
        markdown = agent_eval.render_markdown(agent_eval.summarize([]))
        self.assertIn("_No rows._", markdown)
        self.assertIn("_Not available", markdown)
        self.assertIn("n/a", markdown)


class CliTests(TempFileTests):
    def test_cli_writes_json_and_markdown(self) -> None:
        source = self.write("rows.jsonl", json.dumps(make_row()) + "\n")
        out = self.tmp / "out.json"
        md = self.tmp / "out.md"
        code, _, err = self.call_main(
            ["--input", str(source), "--out", str(out), "--markdown", str(md)]
        )
        self.assertEqual(code, 0)
        report = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(report["input"]["rows_loaded"], 1)
        self.assertEqual(report["input"]["bad_rows_skipped"], 0)
        self.assertIn("## Rates", md.read_text(encoding="utf-8"))
        self.assertIn("actions=1", err)

    def test_cli_fail_under_success_exit_code(self) -> None:
        source = self.write(
            "rows.jsonl",
            "\n".join(
                [
                    json.dumps(make_row(id=1, status="executed", idempotency_key="1")),
                    json.dumps(
                        make_row(
                            id=2,
                            status="failed",
                            error="execution_failed",
                            executed_at=iso(100),
                            idempotency_key="2",
                        )
                    ),
                ]
            )
            + "\n",
        )
        out = self.tmp / "out.json"
        failing, _, err = self.call_main(
            ["--input", str(source), "--out", str(out), "--fail-under-success", "0.8"]
        )
        self.assertEqual(failing, 2)
        self.assertIn("below --fail-under-success", err)
        passing, _, _ = self.call_main(
            ["--input", str(source), "--out", str(out), "--fail-under-success", "0.5"]
        )
        self.assertEqual(passing, 0)

    def test_cli_gate_without_samples_fails_closed(self) -> None:
        source = self.write("empty.jsonl", "")
        code, _, err = self.call_main(
            ["--input", str(source), "--out", str(self.tmp / "out.json"), "--fail-under-success", "0.1"]
        )
        self.assertEqual(code, 2)
        self.assertIn("no executed/failed samples", err)

    def test_cli_missing_input_returns_1(self) -> None:
        code, _, err = self.call_main(["--input", str(self.tmp / "missing.jsonl")])
        self.assertEqual(code, 1)
        self.assertIn("cannot read input", err)

    def test_cli_merges_multiple_inputs(self) -> None:
        first = self.write("a.jsonl", json.dumps(make_row(id=1, idempotency_key="1")) + "\n")
        second = self.write("b.jsonl", json.dumps(make_row(id=2, idempotency_key="2")) + "\n")
        out = self.tmp / "out.json"
        code, _, _ = self.call_main(["--input", str(first), "--input", str(second), "--out", str(out)])
        self.assertEqual(code, 0)
        report = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(report["totals"]["actions"], 2)
        self.assertEqual(report["input"]["files"], [str(first), str(second)])

    def test_cli_prints_json_to_stdout_without_out(self) -> None:
        source = self.write("rows.jsonl", json.dumps(make_row()) + "\n")
        code, stdout, _ = self.call_main(["--input", str(source)])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(stdout)["totals"]["actions"], 1)


if __name__ == "__main__":
    unittest.main()
