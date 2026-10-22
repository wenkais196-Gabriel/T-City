#!/usr/bin/env python3
"""Offline evaluator for the T-City agent action audit trail (design 05 §10).

Consumes a JSONL/JSON export of ``agent_actions`` rows and emits a deterministic
metrics report.  Everything here is pure standard library and read-only: no
database, no network, no game server, no clock-dependent output.  The only
writes are the explicit ``--out`` / ``--markdown`` files passed to the CLI.

Input format
------------
One JSON object per line (``.jsonl``) or a JSON array of objects (``.json``).
``params`` / ``result`` may be JSON strings or already-decoded objects.
``requested_at`` / ``approved_at`` / ``executed_at`` may be ISO-8601 strings
(``T`` or space separated, optional offset) or epoch milliseconds.  Unknown
fields are ignored.

The optional ``--denials`` input uses the same loader and format; each row must
carry ``agent_id``, ``action_type`` and ``code`` (``dry_run`` is optional).

Metric contract (see T-CityLite.base/docs/agent/EVAL.md for the full table):

* ``execution_success_rate``  = executed / (executed + failed), null if 0
* ``verification_failure_rate`` = terminal rows whose ``error`` or ``result``
  text contains ``verification_failed`` / (executed + failed), null if 0
* ``approval_rate`` = approval-required rows with ``approved_at`` / approval-
  required rows, null if 0.  Auto-approved (``approved_by='auto'``) and dry-run
  (``proposed``) rows are not approval-required; rejected rows are (they also
  carry ``approved_at``, so this measures "reached an approval decision").
* ``rejection_rate`` = rejected / all persisted rows, null if 0
* ``denial_rate`` = policy denials / (policy denials + persisted rows), null when
  no ``--denials`` input was supplied (and when both counts are 0)
* ``latency_ms`` = executed_at - requested_at for executed/failed rows; rows
  missing either timestamp are excluded and counted in ``skipped_samples``.
* ``idempotency`` = duplicate-key counts over the export; ``replay_rate`` is
  the share of rows beyond the first occurrence of their key.

Policy-rejected proposals never reach ``agent_actions`` (their idempotency key
must stay reusable), so the over-privilege rejection rate needs a second input:
pass one or more ``--denials`` exports of the ``agent_denials`` table.  Without
that input ``rates.denial_rate`` is ``null`` (not ``0``) and a note says so.
``risk`` stays ``null`` because ``agent_actions`` has no risk column.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

SCHEMA_VERSION = 1

TERMINAL_STATUSES: tuple[str, ...] = ("executed", "failed")
AUTO_APPROVER = "auto"

_EPOCH = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)
_NUMERIC_RE = re.compile(r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?")
_WARN_SAMPLE_LIMIT = 5


class LoadedRows(list):
    """A ``list[dict]`` with load diagnostics attached.

    ``load_rows`` returns this subtype so callers can see how many malformed
    records were skipped (``bad_lines``) without a second return value.  It
    behaves exactly like a list everywhere else.
    """

    def __init__(self, rows: Iterable[Mapping[str, Any]] = (), source: str | None = None) -> None:
        super().__init__(rows)
        self.source = source
        self.files: list[str] = [source] if source else []
        self.bad_lines = 0
        self.bad_samples: list[str] = []

    def add_bad(self, where: str, reason: str) -> None:
        self.bad_lines += 1
        if len(self.bad_samples) < _WARN_SAMPLE_LIMIT:
            self.bad_samples.append(f"{where}: {reason}")

    def extend_loaded(self, other: "LoadedRows") -> None:
        """Append another loader result, merging its diagnostics."""
        self.extend(other)
        for name in other.files:
            if name:
                self.files.append(name)
        self.bad_lines += other.bad_lines
        room = _WARN_SAMPLE_LIMIT - len(self.bad_samples)
        if room > 0:
            self.bad_samples.extend(other.bad_samples[:room])


def _allowed_root() -> Path:
    """Directory the CLI may read/write, from AGENT_EVAL_ROOT or the cwd.

    The evaluator is meant to be callable by an agent, so a path from a prompt
    must not be able to escape into ~/.ssh or a service unit file. Library
    callers that pass absolute temp paths set the env var (the tests do).
    """
    return Path(os.environ.get("AGENT_EVAL_ROOT", Path.cwd())).resolve()


def _contained(path: str) -> Path:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    candidate = candidate.resolve()
    root = _allowed_root()
    if candidate != root and root not in candidate.parents:
        raise ValueError(f"path escapes the allowed root {root}: {candidate}")
    return candidate


def _read_text(path: str) -> str:
    if path == "-":
        return sys.stdin.read()
    # ``/dev/null`` is the conventional "empty export" argument (see EVAL.md).
    # It carries no data, so accepting it does not widen the root guard.
    if Path(path).is_absolute() and Path(path) == Path(os.devnull):
        return ""
    return _contained(path).read_text(encoding="utf-8-sig", errors="replace")


def load_rows(path: str | os.PathLike[str], *, warn: bool = True) -> LoadedRows:
    """Load an ``agent_actions`` export.

    ``.jsonl`` / ``.ndjson`` files are read one object per line.  A file whose
    full content parses as a JSON array (or a single object) is treated as a
    ``.json`` export.  A malformed line/item is skipped and counted in
    ``bad_lines``; the first few reasons are kept in ``bad_samples``.  A warning
    is printed to stderr unless ``warn=False`` (the CLI relies on this so the
    count is never silent).
    """
    rows = LoadedRows(source=str(path))
    text = _read_text(str(path))
    stripped = text.strip()

    parsed_document = False
    if stripped.startswith("[") or stripped.startswith("{"):
        try:
            document = json.loads(stripped)
        except ValueError:
            document = None  # fall back to line-oriented salvage below
        else:
            parsed_document = True
            if isinstance(document, list):
                for index, item in enumerate(document, 1):
                    if isinstance(item, Mapping):
                        rows.append(dict(item))
                    else:
                        rows.add_bad(f"{path}[{index}]", "not a JSON object")
            elif isinstance(document, Mapping):
                # A single-object export is accepted as a one-row document.
                rows.append(dict(document))
            else:
                rows.add_bad(str(path), "top-level JSON is neither an array nor an object")

    if not parsed_document:
        for lineno, line in enumerate(text.splitlines(), 1):
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except ValueError as exc:
                detail = getattr(exc, "msg", None) or "invalid JSON"
                rows.add_bad(f"{path}:{lineno}", detail)
                continue
            if not isinstance(item, Mapping):
                rows.add_bad(f"{path}:{lineno}", "not a JSON object")
                continue
            rows.append(dict(item))

    if warn and rows.bad_lines:
        first = rows.bad_samples[0] if rows.bad_samples else "unknown"
        print(
            f"agent_eval: skipped {rows.bad_lines} malformed record(s) in {path} "
            f"(first: {first})",
            file=sys.stderr,
        )
    return rows


def _to_epoch_ms(value: Any) -> int | None:
    """Parse epoch-ms or ISO-8601 into integer milliseconds since the epoch.

    Naive ISO timestamps are interpreted as UTC so that two naive values keep
    their wall-clock difference.  Mixed naive/offset values are therefore
    compared as if the naive side were UTC.
    """
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
        if not math.isfinite(number):
            return None
        return int(round(number))
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if _NUMERIC_RE.fullmatch(text):
        try:
            number = float(text)
        except ValueError:
            return None
        if not math.isfinite(number):
            return None
        return int(round(number))

    iso = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
    try:
        parsed = dt.datetime.fromisoformat(iso)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    else:
        parsed = parsed.astimezone(dt.timezone.utc)
    return int(round((parsed - _EPOCH).total_seconds() * 1000.0))


def _status(row: Mapping[str, Any]) -> str:
    value = row.get("status")
    if value is None:
        return "unknown"
    text = str(value).strip().lower()
    return text or "unknown"


def _label(row: Mapping[str, Any], field: str) -> str:
    value = row.get(field)
    if value is None:
        return "unknown"
    text = str(value).strip()
    return text or "unknown"


def _text(value: Any) -> str:
    """Flatten a JSON-ish field to text for substring checks / Markdown."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    except (TypeError, ValueError):
        return str(value)


def _present(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        return bool(value.strip())
    return True


def _is_verification_failure(row: Mapping[str, Any]) -> bool:
    haystack = f"{_text(row.get('error'))}\n{_text(row.get('result'))}".lower()
    return "verification_failed" in haystack


def _requires_approval(status: str, approved_by: Any) -> bool:
    """Whether this persisted row needed the approval stage.

    ``approved_by='auto'`` is the only auditable marker of an auto-approved L1
    action.  ``proposed`` is a dry-run reservation and never needs approval;
    ``rejected`` rows (manual reject or TTL expiry) do.
    """
    if status == "proposed":
        return False
    if status == "pending_approval":
        return True
    if status == "rejected":
        return True
    if status in ("approved", "executed", "failed"):
        approver = "" if approved_by is None else str(approved_by).strip().lower()
        return approver != AUTO_APPROVER
    return False  # unknown status: no opinion, keep it out of the denominator


def _percentile(sorted_values: Sequence[int], percentile: float) -> int | None:
    """Nearest-rank percentile (no interpolation, no float arithmetic)."""
    if not sorted_values:
        return None
    rank = max(1, math.ceil(percentile / 100.0 * len(sorted_values)))
    return sorted_values[rank - 1]


# Columns an ``agent_denials`` row must carry to be aggregated.  The table has
# no nullable identity/code columns, so a row missing one is an export defect
# and is counted in ``bad_rows_skipped`` instead of silently landing in
# ``unknown``.
DENIAL_REQUIRED_FIELDS: tuple[str, ...] = ("agent_id", "action_type", "code")


def _is_dry_run(value: Any) -> bool:
    """Interpret the ``dry_run`` column (TINYINT(1) exports as 0/1)."""
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "y")
    return False


def summarize_denials(denials: Iterable[Mapping[str, Any]] | None) -> dict[str, Any] | None:
    """Aggregate an ``agent_denials`` export.

    ``None`` means "no denial input was supplied" and must stay distinct from an
    empty export: a report without denial data cannot claim a denial rate of 0.
    """
    if denials is None:
        return None

    total = 0
    dry_run_count = 0
    by_code: Counter[str] = Counter()
    by_action: Counter[str] = Counter()
    by_agent: Counter[str] = Counter()
    bad_rows = int(getattr(denials, "bad_lines", 0))

    for row in denials:
        if not isinstance(row, Mapping) or any(
            not _present(row.get(field)) for field in DENIAL_REQUIRED_FIELDS
        ):
            bad_rows += 1
            continue
        total += 1
        by_code[_label(row, "code")] += 1
        by_action[_label(row, "action_type")] += 1
        by_agent[_label(row, "agent_id")] += 1
        if _is_dry_run(row.get("dry_run")):
            dry_run_count += 1

    return {
        "total": total,
        "by_code": dict(sorted(by_code.items())),
        "by_action": dict(sorted(by_action.items())),
        "by_agent": dict(sorted(by_agent.items())),
        "dry_run_count": dry_run_count,
        "bad_rows_skipped": bad_rows,
    }


def summarize(
    rows: Iterable[Mapping[str, Any]],
    *,
    denials: Iterable[Mapping[str, Any]] | None = None,
) -> dict[str, Any]:
    """Compute the schema-version-1 report for parsed ``agent_actions`` rows.

    ``denials`` is an optional ``agent_denials`` export (see ``--denials``).  It
    defaults to ``None``, which keeps ``rates.denial_rate`` and the ``denials``
    block ``null`` rather than inventing a zero denominator.
    """
    materialized = [row for row in rows]
    total = len(materialized)

    status_counts: Counter[str] = Counter()
    action_counts: Counter[str] = Counter()
    agent_counts: Counter[str] = Counter()
    verification_failures = 0
    terminal_rows = 0
    approval_required = 0
    approval_decisions = 0
    approved_decisions = 0
    rejected = 0
    keys: list[str] = []
    latency_samples: list[int] = []
    latency_skipped = 0
    risks: list[str] = []

    for row in materialized:
        status = _status(row)
        status_counts[status] += 1
        action_counts[_label(row, "action_type")] += 1
        agent_counts[_label(row, "agent_id")] += 1

        if status in TERMINAL_STATUSES:
            terminal_rows += 1
            if _is_verification_failure(row):
                verification_failures += 1
            requested = _to_epoch_ms(row.get("requested_at"))
            executed = _to_epoch_ms(row.get("executed_at"))
            if requested is None or executed is None:
                latency_skipped += 1
            else:
                latency_samples.append(executed - requested)
        if status == "rejected":
            rejected += 1

        if _requires_approval(status, row.get("approved_by")):
            approval_required += 1
            if _present(row.get("approved_at")):
                approval_decisions += 1
                if status != "rejected":
                    approved_decisions += 1

        key = row.get("idempotency_key")
        if _present(key):
            keys.append(str(key).strip())

        if _present(row.get("risk")):
            risks.append(str(row.get("risk")).strip())

    latency_samples.sort()
    negative_latency = sum(1 for sample in latency_samples if sample < 0)

    key_counts = Counter(keys)
    duplicate_keys = sum(1 for count in key_counts.values() if count > 1)
    duplicate_key_rows = sum(count for count in key_counts.values() if count > 1)
    extra_key_rows = sum(count - 1 for count in key_counts.values() if count > 1)

    def rate(numerator: int, denominator: int) -> float | None:
        return (numerator / denominator) if denominator else None

    execution_success_rate = rate(status_counts.get("executed", 0), terminal_rows)
    verification_failure_rate = rate(verification_failures, terminal_rows)
    approval_rate = rate(approval_decisions, approval_required)
    human_approval_rate = rate(approved_decisions, approved_decisions + rejected)
    approval_required_rate = rate(approval_required, total)
    rejection_rate = rate(rejected, total)

    denial_report = summarize_denials(denials)
    denial_total = int(denial_report["total"]) if denial_report is not None else 0
    denial_rate = (
        rate(denial_total, denial_total + total) if denial_report is not None else None
    )

    risk: dict[str, Any] | None
    if risks:
        risk = {
            "by_risk": dict(sorted(Counter(risks).items())),
            "labeled_actions": len(risks),
            "unlabeled_actions": total - len(risks),
        }
    else:
        risk = None

    notes = [
        (
            "已计入 --denials：denial_rate = 被 policy 拒绝的提案数 / "
            "(被拒数 + 落库动作数)；agent_actions 本身不记录被拒提案（幂等键需复用）。"
            if denial_report is not None
            else "未提供 --denials，越权拒绝率不可计算；被 policy 拒绝的提案不落库，"
            "rejection_rate 只是已落库行的 rejected 占比。"
        ),
        (
            "agent_actions 表没有 risk 列，导出行也没有 risk 字段；risk 输出 null，"
            "未根据 action_type 反推。"
            if risk is None
            else (
                "risk 来自导出行内的非标准 risk 字段（表本身不存 risk）；"
                f"仅 {len(risks)}/{total} 行有标签，其余计入 unlabeled_actions。"
            )
        ),
        (
            "latency_ms = executed_at - requested_at，包含审批等待；仅统计 "
            "executed/failed 且两个时间戳都可解析的行，缺字段或解析失败计入 "
            "skipped_samples；分位数用 nearest-rank，无样本时为 null。"
        ),
        (
            "approval_rate 是审批决策覆盖率：分母为需要审批的动作（pending_approval、"
            "rejected，以及非 approved_by=auto 的 approved/executed/failed；proposed "
            "干跑与 auto 自动执行不计），分子为其中 approved_at 非空的行。rejected 也写 "
            "approved_at，所以它不代表“批准比例”。human_approval_rate = approved / "
            "(approved + rejected) 才是人审通过率；approval_required_rate = 需要审批的"
            "动作 / 全部落库行。"
        ),
        "rejection_rate = rejected / 全部落库行；审批超时也会被写成 rejected。",
        (
            "verification_failure_rate 在 error/result 文本中查找子串 "
            "verification_failed；不看 verify_result 字段，也不做后置条件复核。"
        ),
        (
            "idempotency_key 在表上有 UNIQUE 约束，重复只会来自合并/重复导出；"
            "replay_rate = 重复键多出的行数 / 有 key 的行数，是重复导出的代理指标，"
            "不是客户端重试次数。"
        ),
    ]

    return {
        "schema_version": SCHEMA_VERSION,
        "totals": {
            "actions": total,
            "by_status": dict(sorted(status_counts.items())),
            "by_action": dict(sorted(action_counts.items())),
            "by_agent": dict(sorted(agent_counts.items())),
        },
        "rates": {
            "execution_success_rate": execution_success_rate,
            "verification_failure_rate": verification_failure_rate,
            "approval_rate": approval_rate,
            "human_approval_rate": human_approval_rate,
            "approval_required_rate": approval_required_rate,
            "rejection_rate": rejection_rate,
            "denial_rate": denial_rate,
        },
        "latency_ms": {
            "p50": _percentile(latency_samples, 50),
            "p90": _percentile(latency_samples, 90),
            "p95": _percentile(latency_samples, 95),
            "max": latency_samples[-1] if latency_samples else None,
            "samples": len(latency_samples),
            "skipped_samples": latency_skipped,
            "negative_samples": negative_latency,
        },
        "idempotency": {
            "duplicate_keys": duplicate_keys,
            "duplicate_key_rows": duplicate_key_rows,
            "rows_with_key": len(keys),
            "replay_rate": rate(extra_key_rows, len(keys)),
        },
        "counts": {
            "terminal_executions": terminal_rows,
            "verification_failures": verification_failures,
            "approval_required": approval_required,
            "approval_decisions": approval_decisions,
            "latency_samples": len(latency_samples),
            "latency_skipped": latency_skipped,
            "negative_latency_samples": negative_latency,
            "duplicate_key_rows": duplicate_key_rows,
        },
        "risk": risk,
        "denials": denial_report,
        "notes": notes,
    }


def _fmt_rate(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.2f}%"


def _fmt_ms(value: int | None) -> str:
    return "n/a" if value is None else f"{value} ms"


def _fmt_share(count: int, total: int) -> str:
    return "n/a" if total <= 0 else f"{count / total * 100:.1f}%"


def _md_cell(value: Any) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def _md_table(headers: Sequence[str], body: Iterable[Sequence[Any]]) -> list[str]:
    lines = [
        "| " + " | ".join(headers) + " |",
        "|" + "|".join(":---" for _ in headers) + "|",
    ]
    for row in body:
        lines.append("| " + " | ".join(_md_cell(cell) for cell in row) + " |")
    return lines


def render_markdown(report: Mapping[str, Any]) -> str:
    """Render a one-page Markdown summary from a ``summarize`` report."""
    totals = report.get("totals", {})
    rates = report.get("rates", {})
    latency = report.get("latency_ms", {})
    idempotency = report.get("idempotency", {})
    counts = report.get("counts", {})
    total = int(totals.get("actions", 0))

    lines: list[str] = ["# Agent Action Evaluation", ""]
    lines.append(f"- Schema version: `{report.get('schema_version')}`")
    lines.append(f"- Actions: **{total}**")
    input_info = report.get("input")
    if isinstance(input_info, Mapping):
        files = input_info.get("files") or []
        lines.append(f"- Input files: {', '.join(f'`{f}`' for f in files) or '—'}")
        lines.append(f"- Malformed rows skipped: **{input_info.get('bad_rows_skipped', 0)}**")
    lines.append("")

    lines.extend(["## Totals", ""])
    lines.extend(
        _md_table(
            ["Metric", "Value"],
            [
                ("Actions", total),
                ("Executed", totals.get("by_status", {}).get("executed", 0)),
                ("Failed", totals.get("by_status", {}).get("failed", 0)),
                ("Rejected", totals.get("by_status", {}).get("rejected", 0)),
                ("Pending approval", totals.get("by_status", {}).get("pending_approval", 0)),
            ],
        )
    )
    lines.append("")

    lines.extend(["## Status Distribution", ""])
    by_status = totals.get("by_status", {})
    if by_status:
        lines.extend(
            _md_table(
                ["Status", "Count", "Share"],
                [(status, count, _fmt_share(count, total)) for status, count in by_status.items()],
            )
        )
    else:
        lines.append("_No rows._")
    lines.append("")

    lines.extend(["## Action Types", ""])
    by_action = totals.get("by_action", {})
    if by_action:
        lines.extend(
            _md_table(
                ["Action type", "Count", "Share"],
                [(name, count, _fmt_share(count, total)) for name, count in by_action.items()],
            )
        )
    else:
        lines.append("_No rows._")
    lines.append("")

    lines.extend(["## Agents", ""])
    by_agent = totals.get("by_agent", {})
    if by_agent:
        lines.extend(
            _md_table(
                ["Agent", "Count", "Share"],
                [(name, count, _fmt_share(count, total)) for name, count in by_agent.items()],
            )
        )
    else:
        lines.append("_No rows._")
    lines.append("")

    terminal = int(counts.get("terminal_executions", 0))
    approval_required = int(counts.get("approval_required", 0))
    denials = report.get("denials")
    if isinstance(denials, Mapping):
        denial_total = int(denials.get("total", 0))
        denial_basis = f"{denial_total} / {denial_total + total} (denials + persisted)"
    else:
        denial_basis = "no --denials input"
    lines.extend(["## Rates", ""])
    lines.extend(
        _md_table(
            ["Metric", "Value", "Basis"],
            [
                (
                    "Execution success rate",
                    _fmt_rate(rates.get("execution_success_rate")),
                    f"executed / (executed + failed) = "
                    f"{totals.get('by_status', {}).get('executed', 0)} / {terminal}",
                ),
                (
                    "Verification failure rate",
                    _fmt_rate(rates.get("verification_failure_rate")),
                    f"{counts.get('verification_failures', 0)} / {terminal} terminal rows",
                ),
                (
                    "Approval decision coverage",
                    _fmt_rate(rates.get("approval_rate")),
                    f"{counts.get('approval_decisions', 0)} / {approval_required} approval-required",
                ),
                (
                    "Human approval rate",
                    _fmt_rate(rates.get("human_approval_rate")),
                    "approved / (approved + rejected)",
                ),
                (
                    "Approval-required rate",
                    _fmt_rate(rates.get("approval_required_rate")),
                    f"{approval_required} / {total} persisted",
                ),
                (
                    "Rejection rate",
                    _fmt_rate(rates.get("rejection_rate")),
                    f"{totals.get('by_status', {}).get('rejected', 0)} / {total} persisted",
                ),
                (
                    "Denial rate",
                    _fmt_rate(rates.get("denial_rate")),
                    denial_basis,
                ),
            ],
        )
    )
    lines.append("")

    lines.extend(["## Latency", ""])
    lines.extend(
        _md_table(
            ["Metric", "Value"],
            [
                ("p50", _fmt_ms(latency.get("p50"))),
                ("p90", _fmt_ms(latency.get("p90"))),
                ("p95", _fmt_ms(latency.get("p95"))),
                ("max", _fmt_ms(latency.get("max"))),
                ("samples", latency.get("samples", 0)),
                ("skipped samples", latency.get("skipped_samples", 0)),
            ],
        )
    )
    lines.append("")

    lines.extend(["## Idempotency", ""])
    lines.extend(
        _md_table(
            ["Metric", "Value"],
            [
                ("Duplicate keys", idempotency.get("duplicate_keys", 0)),
                ("Duplicate key rows", idempotency.get("duplicate_key_rows", 0)),
                ("Rows with key", idempotency.get("rows_with_key", 0)),
                ("Replay rate", _fmt_rate(idempotency.get("replay_rate"))),
            ],
        )
    )
    lines.append("")

    lines.extend(["## Risk", ""])
    risk = report.get("risk")
    if isinstance(risk, Mapping):
        by_risk = risk.get("by_risk", {})
        lines.extend(
            _md_table(
                ["Risk", "Count"],
                [(level, count) for level, count in by_risk.items()],
            )
        )
        lines.append("")
        lines.append(
            f"Labeled actions: {risk.get('labeled_actions', 0)}; "
            f"unlabeled: {risk.get('unlabeled_actions', 0)}."
        )
    else:
        lines.append("_Not available: `agent_actions` has no `risk` column._")
    lines.append("")

    lines.extend(["## Notes", ""])
    for note in report.get("notes", []):
        lines.append(f"- {note}")
    return "\n".join(lines).rstrip() + "\n"


def _rate_argument(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"not a number: {value!r}") from exc
    if not 0.0 <= parsed <= 1.0:
        raise argparse.ArgumentTypeError("must be between 0 and 1 (inclusive)")
    return parsed


def _write_text(path: Path, text: str) -> None:
    target = _contained(str(path))
    if target.parent != Path("."):
        target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="agent_eval.py",
        description=(
            "Offline evaluator for agent_actions JSONL/JSON exports. "
            "Read-only: no database and no network access."
        ),
        epilog=(
            "Exit codes: 0 report written; 1 input/output error; "
            "2 --fail-under-success not met (or no executable samples)."
        ),
    )
    parser.add_argument(
        "--input",
        action="append",
        required=True,
        metavar="PATH",
        help="export to read; repeatable; '-' reads stdin",
    )
    parser.add_argument(
        "--denials",
        action="append",
        metavar="PATH",
        help=(
            "agent_denials export to read; repeatable; enables rates.denial_rate "
            "(omitted: the denial rate is null, not 0)"
        ),
    )
    parser.add_argument("--out", metavar="JSON", help="write the JSON report here (default: stdout)")
    parser.add_argument(
        "--json",
        action="store_true",
        help="print the JSON report to stdout even when --out is given",
    )
    parser.add_argument("--markdown", metavar="MD", help="also write a one-page Markdown report")
    parser.add_argument(
        "--fail-under-success",
        type=_rate_argument,
        default=None,
        metavar="0..1",
        help="exit 2 when execution_success_rate is below this threshold",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    combined = LoadedRows()
    try:
        for path in args.input:
            combined.extend_loaded(load_rows(path))
    except (OSError, ValueError) as exc:
        print(f"agent_eval: cannot read input: {exc}", file=sys.stderr)
        return 1

    denial_rows: LoadedRows | None = None
    if args.denials:
        denial_rows = LoadedRows()
        try:
            for path in args.denials:
                denial_rows.extend_loaded(load_rows(path))
        except (OSError, ValueError) as exc:
            print(f"agent_eval: cannot read denials input: {exc}", file=sys.stderr)
            return 1

    report = summarize(combined, denials=denial_rows)
    report["input"] = {
        "files": combined.files,
        "rows_loaded": len(combined),
        "bad_rows_skipped": combined.bad_lines,
    }
    if denial_rows is not None:
        report["input"]["denial_files"] = denial_rows.files
        report["input"]["denial_rows_loaded"] = len(denial_rows)
    payload = json.dumps(report, ensure_ascii=False, indent=2) + "\n"

    try:
        if args.out and not args.json:
            _write_text(Path(args.out), payload)
        else:
            sys.stdout.write(payload)
        if args.markdown:
            _write_text(Path(args.markdown), render_markdown(report))
    except OSError as exc:
        print(f"agent_eval: cannot write output: {exc}", file=sys.stderr)
        return 1

    totals = report["totals"]["by_status"]
    latency = report["latency_ms"]
    print(
        "agent_eval: actions={} executed={} failed={} success={} rejected={} p95={}".format(
            report["totals"]["actions"],
            totals.get("executed", 0),
            totals.get("failed", 0),
            _fmt_rate(report["rates"]["execution_success_rate"]),
            totals.get("rejected", 0),
            _fmt_ms(latency["p95"]),
        ),
        file=sys.stderr,
    )

    threshold = args.fail_under_success
    if threshold is not None:
        success = report["rates"]["execution_success_rate"]
        if success is None:
            print(
                "agent_eval: no executed/failed samples; "
                f"cannot satisfy --fail-under-success {threshold:.2f}",
                file=sys.stderr,
            )
            return 2
        if success + 1e-12 < threshold:
            print(
                f"agent_eval: execution_success_rate {success:.4f} is below "
                f"--fail-under-success {threshold:.4f}",
                file=sys.stderr,
            )
            return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
