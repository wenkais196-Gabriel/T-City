# Agent Action Evaluation (`tools/agent_eval.py`)

Offline, CI-friendly evaluator for the `agent_actions` audit table. It reads a
JSONL/JSON export, computes a schema-versioned metrics report and renders a
one-page Markdown summary. It is **read-only** and **offline**: no database
connection, no network access, no game server, no clock-dependent output. The
only writes are the explicit `--out` / `--markdown` paths.

- **Tool:** [`tools/agent_eval.py`](../../../tools/agent_eval.py)
- **Tests:** [`tests/agent/test_agent_eval.py`](../../../tests/agent/test_agent_eval.py)
- **Table:** `agent_actions` (migration
  [`v2.3_agent_actions.sql`](../../migrations/v2.3_agent_actions.sql))
- **Design reference:** [`design/05-test-and-eval.md`](design/05-test-and-eval.md) §10
- **Report schema version:** `1`

---

## 1. Quick start

From the repository root:

```bash
# Empty/zero report (safe on a fresh checkout)
python3 tools/agent_eval.py --input /dev/null --out /tmp/agent_eval.json

# One or more exports; repeats are merged
python3 tools/agent_eval.py \
  --input reports/agent_actions-2026-10-22.jsonl \
  --input reports/agent_actions-2026-10-23.jsonl \
  --out reports/agent_eval.json \
  --markdown reports/agent_eval.md

# CI gate: exit 2 when execution_success_rate < 0.80
python3 tools/agent_eval.py --input reports/agent_actions.jsonl \
  --out reports/agent_eval.json --fail-under-success 0.80

# Tests (never touch the DB)
python3 -m pytest -q tests/agent/test_agent_eval.py
```

`--input -` reads stdin. When `--out` is omitted the JSON report goes to stdout;
the one-line human summary always goes to stderr so it cannot corrupt JSON
piped to another process.

### Exit codes

| Code | Meaning |
|:---|:---|
| `0` | Report written; gate passed (or no gate requested) |
| `1` | Input could not be read or output could not be written |
| `2` | `--fail-under-success` was not met, **or** there were no `executed`/`failed` samples to prove it (fail-closed) |

A gate with no samples exits `2` on purpose: an empty export must not turn a CI
success-rate gate green. Invalid `--fail-under-success` values (outside `0..1`)
are rejected by `argparse` with exit code `2` as well.

---

## 2. Exporting from MariaDB

The evaluator accepts either:

- **JSONL** — one JSON object per line, the recommended format; or
- **JSON** — a top-level array of objects (a single object is accepted as a
  one-row export).

MariaDB's `JSON_OBJECT` produces compact, correctly escaped JSON. `params` /
`result` arrive as JSON **strings**; the evaluator accepts strings or decoded
objects, so this is lossless. Timestamps are pre-formatted to ISO-8601 with
milliseconds so the loader does not depend on client locale.

```bash
# Credentials come from the environment / an operator-owned option file.
# Never put a password in this document, a committed file, or a shell history.
set -a; . ./.env; set +a   # TCITY_DB_HOST / TCITY_DB_USER / TCITY_DB_PASS / TCITY_DB_NAME

MYSQL_PWD="${TCITY_DB_PASS:?set TCITY_DB_PASS}" \
mysql --batch --raw --skip-column-names --default-character-set=utf8mb4 \
  -h "${TCITY_DB_HOST:?set TCITY_DB_HOST}" \
  -u "${TCITY_DB_USER:?set TCITY_DB_USER}" \
  "${TCITY_DB_NAME:?set TCITY_DB_NAME}" \
  -e "
    SELECT JSON_OBJECT(
      'id',              id,
      'agent_id',        agent_id,
      'action_type',     action_type,
      'status',          status,
      'params',          params,
      'result',          COALESCE(result, ''),
      'error',           COALESCE(error, ''),
      'requested_at',    DATE_FORMAT(requested_at, '%Y-%m-%dT%H:%i:%s.%f'),
      'approved_at',     COALESCE(DATE_FORMAT(approved_at,  '%Y-%m-%dT%H:%i:%s.%f'), ''),
      'executed_at',     COALESCE(DATE_FORMAT(executed_at,  '%Y-%m-%dT%H:%i:%s.%f'), ''),
      'approved_by',     COALESCE(approved_by, ''),
      'expires_at',      COALESCE(DATE_FORMAT(expires_at,   '%Y-%m-%dT%H:%i:%s.%f'), ''),
      'idempotency_key', idempotency_key
    )
    FROM agent_actions
    WHERE requested_at >= CURDATE() - INTERVAL 30 DAY
    ORDER BY id
  " > reports/agent_actions-$(date +%F).jsonl

unset MYSQL_PWD
```

Notes:

- Prefer a `0600` option file passed with `--defaults-extra-file=` over
  `MYSQL_PWD`; the env form above is only a portable shorthand. Never pass
  `-p<password>` on the command line.
- Exporting with `--raw` (no tab escaping) is required: JSON strings already
  escape tabs/newlines as `\t` / `\n`.
- For large tables, export in `id` ranges or add `LIMIT` and concatenate the
  files; `--input` is repeatable and the report merges all rows.
- `JSON_OBJECT` keeps `params` / `result` as strings. If you produce an export
  yourself and emit them as embedded objects, that is also accepted.
- NULL-able columns are coalesced to `''` so every line is a complete JSON
  object regardless of the client's NULL rendering; the evaluator treats an
  empty timestamp/field as missing.
- `SELECT ... INTO OUTFILE` works too, but requires `FILE` privilege and
  `secure_file_priv` access. The `mysql --batch` form needs neither.
- Exports contain `params` (possibly `citizenid`) and approver labels. Treat
  them as audit data: keep them out of git and off shared drives.

---

## 3. Metric definitions

Report shape (`schema_version: 1`): `totals`, `rates`, `latency_ms`,
`idempotency`, `counts`, `risk`, `notes`, plus `input` when run through the CLI.
A metric that cannot be computed is `null`, never `0` dressed up as data.

### 3.1 `totals`

| Field | Definition |
|:---|:---|
| `actions` | Parsed rows in the export (after malformed lines are skipped) |
| `by_status` | Count per `status`; only observed statuses are present |
| `by_action` | Count per `action_type`; missing value groups under `unknown` |
| `by_agent` | Count per `agent_id`; missing value groups under `unknown` |

`proposed` rows are dry-run reservations and are included in `totals`,
`rejection_rate` and idempotency, but not in execution/approval metrics.

### 3.2 `rates`

| Metric | Numerator / denominator | `null` when | Caveat |
|:---|:---|:---|:---|
| `execution_success_rate` | `executed / (executed + failed)` | no terminal rows | `rejected`, `pending_approval`, `approved` and `proposed` are **not** in the denominator |
| `verification_failure_rate` | terminal rows whose `error` or `result` contains `verification_failed` / `(executed + failed)` | no terminal rows | textual detection only; `amount_verification_failed` also matches |
| `approval_rate` | approval-required rows with non-empty `approved_at` / approval-required rows | no approval-required rows | measures "reached an approval decision", not "was approved" (rejections also write `approved_at`) |
| `human_approval_rate` | `approved / (approved + rejected)` | no decisions | the share of human decisions that were approvals |
| `approval_required_rate` | approval-required rows / all persisted rows | no rows | how much of the agent's work needs a human at all |
| `rejection_rate` | `rejected / all persisted rows` | no rows | includes TTL-expiry rejections; policy rejections are not persisted |

**Approval-required** is derived row-by-row, not from `action_type`:

- `pending_approval` → yes;
- `rejected` → yes (manual rejection or TTL expiry both went through approval);
- `approved` / `executed` / `failed` → yes unless `approved_by = 'auto'`;
- `proposed` and unknown statuses → no.

The table has no `requires_approval` column. `approved_by = 'auto'` is the only
durable marker of an L1 auto-execution, so a legacy `executed` row with a NULL
`approved_by` is conservatively treated as approval-required.

### 3.3 `latency_ms`

| Field | Definition |
|:---|:---|
| `p50`, `p90`, `p95`, `max` | Nearest-rank percentiles over integer milliseconds |
| `samples` | Rows with a terminal status and both timestamps parseable |
| `skipped_samples` | Terminal rows missing `requested_at` or `executed_at`, or with an unparseable value |
| `negative_samples` | Samples where `executed_at < requested_at` (kept, but signalled) |

- Latency is `executed_at - requested_at` for `executed` / `failed` rows.
- Pending/approved/rejected/proposed rows are **not** latency candidates and
  are not counted as skipped. A terminal row with a missing timestamp is.
- ISO-8601 strings (`T` or space separator, optional `Z`/offset, fractional
  seconds) and epoch milliseconds are accepted. Naive ISO values are treated as
  UTC so two naive values keep their wall-clock difference; mixing naive and
  offset values assumes the naive side is UTC.
- Nearest-rank: for `n` samples, the p-th percentile is the
  `ceil(p/100 * n)`-th smallest value, with no interpolation. This avoids
  floating-point drift but is not the "averaged" percentile some dashboards use.

### 3.4 `idempotency`

| Field | Definition |
|:---|:---|
| `duplicate_keys` | Number of distinct `idempotency_key` values occurring more than once |
| `duplicate_key_rows` | Total rows belonging to those duplicated keys |
| `rows_with_key` | Rows with a non-empty key |
| `replay_rate` | Rows beyond the first occurrence of their key / `rows_with_key` (`null` when no keys) |

`agent_actions.idempotency_key` is globally `UNIQUE`, so a single healthy
database cannot contain duplicates. A value other than `0` means the export was
merged/duplicated, not that the broker accepted a replay. `replay_rate` is a
duplicate-export proxy, not a client retry rate (retries live in run logs).

### 3.5 `risk`

`agent_actions` has **no risk column**, and the evaluator does not infer risk
from `action_type`. With a normal export, `risk` is `null` and a note explains
why. If an export carries a non-standard row-level `risk` field, it is reported
as `{by_risk, labeled_actions, unlabeled_actions}`; the note then flags the
partial coverage.

### 3.6 `counts`

Raw numerators/denominators (`terminal_executions`, `verification_failures`,
`approval_required`, `approval_decisions`, `latency_samples`, `latency_skipped`,
`negative_latency_samples`, `duplicate_key_rows`) so a reader can recompute every
rate without guessing.

### 3.7 `notes`

Always present. The first note is the design 05 §10 blind spot:

> 被 policy 拒绝的提案不落库，因此越权拒绝率无法从本表计算
> （`rejection_rate` 只是已落库行的 rejected 占比）。

The remaining notes restate the risk, latency, approval, rejection,
verification and idempotency caveats above.

---

## 4. Known blind spots

1. **Over-privilege rejection rate is not computable.** `AgentActions.Propose`
   returns policy failures without inserting a row, so "rejected by policy /
   total over-privileged requests" has no denominator here. `rejection_rate`
   only covers rows that reached the table.
2. **Escaped actions cannot be detected.** Comparing the audit table with game
   balances/inventory would be needed. No such reconciliation exists offline.
3. **Verification is textual.** `verification_failure_rate` searches `error` /
   `result` for `verification_failed`. Actions without a read-back (for example
   `set_time_of_day` and `start_quest`, per `ACTIONS.md`) cannot fail this check,
   and a failure message that does not use that token is missed. `verify_result`
   is not consulted.
4. **Latency includes human approval wait.** `executed_at - requested_at` is
   approve-plus-execute wall time, not the agent-side latency that design §10's
   300 ms target measures. Compare it with run-log latency only with that caveat.
5. **`rejected` is overloaded.** Manual rejection and TTL expiry both become
   `rejected`; `rejection_rate` is not a policy-denial rate and not a false-
   rejection (误拒) rate.
6. **`approval_rate` is decision coverage, not approval share.** Rejected rows
   also carry `approved_at`, so they count in the numerator. Use
   `rejection_rate` for the rejected share, and run logs for per-task approval
   behaviour.
7. **Risk levels and cost are absent.** Design §10's "cost per action" and
   "escape" metrics need run logs (`reports/agent_runs/*.jsonl`) or game-side
   reconciliation; `agent_actions` has no token/cost/risk column.
8. **The export is a snapshot.** Rows pending at export time may be approved or
   expired later; re-export before nightly evaluation. Merged exports can also
   double-count if the same `id` appears in two files (the tool counts rows, not
   distinct ids).
9. **`unknown` grouping.** Missing `agent_id` / `action_type` / `status` are
   grouped under `unknown` so rows are not lost; check `by_status` for new enum
   values after a schema change.
10. **Dry-run rows count in `rejection_rate`.** `proposed` reservations are
    persisted rows; they are excluded from execution and approval rates but not
    from the persisted denominator.

---

## 5. CI integration

`tests/agent` is already collected by the repository CI. To add the report as an
optional gate in a nightly job (not in the PR workflow):

```yaml
- name: Agent action evaluation
  run: |
    python3 tools/agent_eval.py \
      --input reports/agent_actions.jsonl \
      --out reports/agent_eval.json \
      --markdown reports/agent_eval.md \
      --fail-under-success 0.80
```

The example threshold is the design's red line for `execution_success_rate`;
`0.80` is intentionally below the `0.90` task-success target because this metric
does not verify postconditions. Treat a red gate as a signal to read `notes` and
the denominator counts before changing the threshold.
