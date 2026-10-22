# Agent Action Contract (`custom-director`, v1)

Server-side contract for agent-proposed game actions. This is a safe slice of
issues **#30 / #32**: proposals, previews, policy/budget, human approval for
risky actions and an audit row. Scope is deliberately limited to five actions;
there is no LLM integration.

- **Resource:** `T-CityLite.base/resources/[custom]/custom-director` (server-only)
- **Migration:** `T-CityLite.base/migrations/v2.3_agent_actions.sql`
- **Table:** `agent_actions`
- **Audience:** out-of-process Agent Hub, trusted server resources, approval UI
- **Schema version:** `1` (`GET /agent/v1/policy` → `schema_version: 1`)

---

## 1. Action matrix

| Action | Risk | Args | Status after propose | Approval | Execution |
|:---|:---|:---|:---|:---|:---|
| `notify` | L1 表现 | `citizenid`, `text`, `kind?` | `approved` → `executed` | none (policy only) | `Player.Functions.Notify` (or `QBCore:Notify`) |
| `add_money` | L4 经济 | `citizenid`, `account`, `amount`, `reason` | `pending_approval` | **always** | `Player.Functions.AddMoney(account, amount, 'agent_action:<id>')` + delta verification |
| `start_quest` | L3 任务 | `citizenid`, `quest_id` | `pending_approval` | **always** | `exports['custom-quest']:TriggerQuest(source, quest_id)` |
| `set_job` | L3 职业 | `citizenid`, `job`, `grade?` | `pending_approval` | **always** | `Player.Functions.SetJob(job, grade)` + job/grade read-back verification |
| `grant_item` | L4 物品 | `citizenid`, `item`, `amount`, `reason` | `pending_approval` | **always** | `Player.Functions.AddItem(item, amount)` + inventory delta verification |

Anything else is rejected with `code: "unsupported_action"`.

### 1.1 Argument normalization

| Field | Rule |
|:---|:---|
| `agent_id` | 1–64 chars, `[A-Za-z0-9_.:-]`, trimmed |
| `citizenid` | 1–11 chars, `[A-Za-z0-9_-]`, trimmed (matches `players.citizenid VARCHAR(11)`) |
| `idempotency_key` | 1–128 printable non-space chars, globally unique |
| `notify.text` | non-empty; ≤ `agent_actions_max_notify_chars` UTF-8 chars; C0 controls except tab/LF/CR rejected |
| `notify.kind` | `info` \| `success` \| `warning` \| `error` \| `primary`; default `info` |
| `add_money.account` | `cash` \| `bank` \| `crypto` |
| `add_money.amount` | finite whole number, 1..`agent_actions_max_money` |
| `add_money.reason` | 1–128 chars, no C0 controls |
| `start_quest.quest_id` | 1–64 chars, `[A-Za-z0-9_.:-]`; must exist in `GetQuestCatalog` |
| `set_job.job` | 1–64 chars, `[A-Za-z0-9_.-]`, lowercased; must exist in `QBCore.Shared.Jobs` |
| `set_job.grade` | optional integer `0..100`, default `0`; must exist in `jobs[job].grades` when that table is present |
| `grant_item.item` | 1–64 chars, `[A-Za-z0-9_.:-]`; must exist in `QBCore.Shared.Items` |
| `grant_item.amount` | integer `1..agent_actions_max_item_amount` (default 50, clamped 1..1000) |
| `grant_item.reason` | 1–128 chars, no C0 controls |
| `approver` | 1–64 chars, no C0 controls (e.g. `discord:alice`, `console`) |
| reject `reason` | optional, 1–255 chars |

Unknown keys inside `args` are dropped for `notify`, `add_money` and
`start_quest`, but rejected with `invalid_params` for `set_job` and
`grant_item`. Unknown action types are rejected. There is no client-side
validation path.

---

## 2. Request envelope

### 2.1 HTTP

```http
POST /agent/v1/act
Authorization: Bearer <agent_actions_token>
X-Agent-Id: director.local
Content-Type: application/json

{
  "type": "add_money",
  "args": {
    "citizenid": "ABC12345",
    "account": "bank",
    "amount": 250,
    "reason": "director reward"
  },
  "idempotency_key": "beat_123/money/1",
  "dry_run": false
}
```

External URL: `http://127.0.0.1:30120/custom-director/agent/v1/act`
(FiveM prefixes a resource's HTTP handler with `/<resource-name>/`).
`dry_run` must be a JSON boolean if present; default `false`.
`X-Agent-Id` is required on act and on own-row reads; it is not accepted from
the body.

### 2.2 Server export

```lua
exports['custom-director']:Propose(agentId, actionType, params, idempotencyKey, dryRun)
```

Returns the same result table as HTTP (`ok`, `id`, `status`, `preview`,
`error`, `code`, `result`; some fields absent when not applicable).

---

## 3. Preview contract

A preview is computed **before** persistence/execution and stored as JSON in
`agent_actions.preview`. It is advisory but is what approvers see; approval
recomputes it.

Common fields:

```json
{
  "action_type": "add_money",
  "risk": "L4",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12
}
```

`player_found` is based on `QBCore.Functions.GetPlayerByCitizenId` (online
players only). If false, policy rejects the proposal before a row is written.

### 3.1 `notify`

```json
{
  "action_type": "notify",
  "risk": "L1",
  "requires_approval": false,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "text_length": 28,
  "kind": "info"
}
```

### 3.2 `add_money`

```json
{
  "action_type": "add_money",
  "risk": "L4",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "account": "bank",
  "amount": 250,
  "account_exists": true,
  "before": 1250,
  "after": 1500,
  "daily_budget": 5000,
  "daily_spent": 0,
  "daily_remaining": 5000,
  "daily_remaining_after": 4750
}
```

If the account is missing: `account_exists: false`, `before`/`after` absent,
and policy returns `account_unavailable`. Balances come from
`Player.PlayerData.money[account]` and may change between preview and approval.

### 3.3 `start_quest`

```json
{
  "action_type": "start_quest",
  "risk": "L3",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "quest_id": "delivery_001",
  "quest_found": true,
  "quest_title": "First Delivery",
  "quest_category": "delivery"
}
```

`GetQuestCatalog()` currently returns
`{ [category] = { {id, title, description, category, level, required_tags, rewards}, ... } }`.
The broker indexes both that shape and a flat quest array. If the export fails,
the proposal is rejected with `quest_catalog_unavailable`; if the id is absent,
policy rejects with `quest_not_found`.

### 3.4 `set_job`

```json
{
  "action_type": "set_job",
  "risk": "L3",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "job": "police",
  "grade": 2,
  "before": { "job": "unemployed", "grade": 0 }
}
```

`before` comes from the live `PlayerData.job` and is omitted while the player is
offline (policy rejects that proposal with `player_not_found`). Approval
recomputes the preview, so `before` reflects the job at approval time.

### 3.5 `grant_item`

```json
{
  "action_type": "grant_item",
  "risk": "L4",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "item": "bread",
  "amount": 3,
  "reason": "director reward",
  "before": 2
}
```

`before` is the current held quantity from `Player.Functions.GetItemByName(item)`
(`0` when the player holds none). It is omitted while the player is offline.

---

## 4. Status lifecycle

```text
dry_run = true
  propose ──► proposed                         (terminal; no execution)

notify (dry_run = false)
  propose ──► approved ──► executed
                       └─► failed             (notify/AddMoney/quest execution error)

add_money / start_quest / set_job / grant_item (dry_run = false)
  propose ──► pending_approval ──► approved ──► executed
                              │             └─► failed
                              ├─► rejected              (operator reject)
                              ├─► rejected              (approval-time policy failure)
                              └─► rejected              (TTL expired)
```

| Status | Meaning |
|:---|:---|
| `proposed` | Persisted dry-run; preview only. Not executable. |
| `pending_approval` | Waiting for an admin token / `/agentapprove`. Has `expires_at`. |
| `approved` | Transitional: approved, execution in progress (or process interrupted). |
| `executed` | Execution succeeded; `result` and `executed_at` set. |
| `rejected` | Operator rejected, approval-time policy failed, or expired. `error`/`result` say why. |
| `failed` | Execution was attempted and failed. `error`/`result` set. Money/quest effects may be partial; inspect the row. |

`Approve`/`Reject` only operate on `pending_approval` rows; any other status
returns `invalid_status` (HTTP `409`). A row stuck in `approved` after a server
crash is not automatically retried in this slice; operators should inspect and
resolve it manually.

---

## 5. Policy and budget

### 5.1 Money

- Per-action cap: `amount ≤ agent_actions_max_money` (default 1000).
- Daily budget:
  - sum of `amount` for `add_money` rows with status
    `pending_approval`, `approved` or `executed`
  - whose `requested_at >= CURDATE()` (database local date)
  - must satisfy `existing_spend + amount ≤ agent_actions_daily_budget`
    (default 5000).
- Pending rows **reserve** budget; rejecting/expiring/failing them releases it.
- On approval, the current row is excluded from the existing-spend sum and then
  added once, avoiding double counting.
- A proposal rejected by policy is not persisted, so it does not consume
  idempotency or budget.
- `add_money` requires the player to be online at propose and approve time.

### 5.2 Notify

- Text length is measured in UTF-8 characters.
- Max is `agent_actions_max_notify_chars` (default 300, hard cap 2000).
- Target must be online; delivery is fire-and-forget (no client ack).

### 5.3 Quests

- `quest_id` must exist in the current `custom-quest` catalog at propose time.
- Existence is re-checked on approve.
- `TriggerQuest` enforces its own enabled/cooldown/precondition rules. A
  rejection from that export becomes `failed` with its message (truncated to
  255 chars in `error`).

### 5.4 TTL / expiry

- `expires_at = requested_at + agent_actions_ttl_seconds` (default 900s) for
  pending approvals.
- `Approve` on an expired row marks it `rejected` with `error = "expired"` and
  returns `code: "expired"` (HTTP `410`).
- `List` lazily sweeps expired pending rows to `rejected` (no background worker
  in this slice).

### 5.5 Kill switch

`agent_actions_enabled = 1` is required for propose/approve/reject. It is read
on every call. Any other value:

- exports return `{ok:false, code:"disabled"}`;
- every HTTP endpoint returns `503 {"error":"agent actions are disabled","code":"disabled"}`.

`stop custom-director` removes the HTTP endpoint and exports immediately.
Tokens are convars only; clearing `agent_actions_token` makes all HTTP calls
`503` while leaving server exports available.

### 5.6 Jobs and items

- `job` must exist in `QBCore.Shared.Jobs` at propose and approve time
  (`job_not_found` otherwise).
- If `jobs[job].grades` is present, `tostring(grade)` must be one of its keys
  (`grade_not_found` otherwise). Jobs without a `grades` table accept any
  in-range grade.
- `item` must exist in `QBCore.Shared.Items` at propose and approve time
  (`item_not_found` otherwise).
- `grant_item.amount` is capped by `agent_actions_max_item_amount`
  (default `50`, clamped `1..1000`). It does **not** consume the `add_money`
  daily budget; there is no item budget in this slice.
- Both actions require the target player to be online.

### 5.7 Approval matrix

| Action | Risk | Auto-execute | Human approval | Budget / cap |
|:---|:---|:---|:---|:---|
| `notify` | L1 | yes (policy only) | no | `max_notify_chars` |
| `start_quest` | L3 | no | **always** | quest catalog |
| `set_job` | L3 | no | **always** | `QBCore.Shared.Jobs` + grades |
| `add_money` | L4 | no | **always** | `max_money` + daily budget |
| `grant_item` | L4 | no | **always** | `max_item_amount` only |

`agent_actions_enabled = 0` disables every action. A proposal rejected by policy
before persistence is not an approval-matrix exception: it never executes.

---

## 6. Idempotency

`agent_actions.idempotency_key` is globally `UNIQUE`.

- Same key + same `action_type` + same **normalized** params → return the
  original row (`ok: true`, `idempotent: true`, original status/preview/result).
  No second execution.
- Same key + different action or params → `409 idempotency_conflict`; the
  original row is untouched.
- Concurrent inserts race on the unique key; the loser re-reads and returns the
  winner (or the conflict).
- A dry-run consumes the key with status `proposed`. Use a distinct key for the
  real action (recommended pattern: `beat_123/notify/dry`, `beat_123/notify/1`).
- A `failed`/`rejected` row still owns its key. Retrying requires a new key.
- Policy-rejected proposals are not inserted, so their keys remain reusable.

---

## 7. Audit fields

| Column | Content |
|:---|:---|
| `id` | Action id used by approve/reject/get/list |
| `agent_id` | Caller identity from `X-Agent-Id` / export argument |
| `action_type` | `notify` \| `add_money` \| `start_quest` \| `set_job` \| `grant_item` |
| `params` | Normalized JSON args (unknown fields dropped for legacy actions, rejected for `set_job`/`grant_item`) |
| `status` | See §4 |
| `idempotency_key` | Caller key, unique |
| `preview` | Last computed preview JSON |
| `result` | Execution result JSON (balances/quest message) or rejection reason |
| `error` | Short failure/rejection reason, ≤255 chars |
| `requested_at` | `DATETIME(3)` insert time |
| `approved_by` | Approver label, or `auto` for notify; `system:expired` on TTL |
| `approved_at` | Approval time |
| `executed_at` | Execution attempt completion time (also set on failure) |
| `expires_at` | Approval deadline (pending only) |

`params`/`preview`/`result` never contain tokens, licenses or IPs. Tokens are
not stored.

---

## 8. Execution and failure semantics

### `notify`

- Resolves the online player by citizenid, uses
  `Player.Functions.Notify(text, kind, 5000)` with `QBCore:Notify` fallback.
- No delivery acknowledgement. If the call does not throw, the row becomes
  `executed`.

### `add_money`

1. Re-resolve the online player and account balance.
2. `Player.Functions.AddMoney(account, amount, 'agent_action:<id>')`.
3. Re-read the balance and require `after - before ≈ amount` (tolerance 0.001).
4. On mismatch, mark `failed` and log loudly. **No automatic rollback** is
   attempted; a partial mutation is left for operator review.

This is an L4 action: it never auto-executes, even if `dry_run` is false.

### `start_quest`

- Calls `exports['custom-quest']:TriggerQuest(source, quest_id)`.
- Success requires the export's first return value to be `true`.
- Any `false`/`nil` result or thrown error becomes `failed` with the message.

### `set_job`

1. Re-resolve the online player and record `before = { job, grade }`.
2. `Player.Functions.SetJob(job, grade)`; a return other than `true` becomes
   `failed` (`execution_failed`).
3. Read back `PlayerData.job.name` and `PlayerData.job.grade.level`; they must
   equal the requested `job`/`grade`.
4. On mismatch, mark `failed` with a `verification_failed` message. **No
   automatic rollback**; the previous job is in the audit `result.before`.

This is an L3 action: it never auto-executes, even if `dry_run` is false.

### `grant_item`

1. Re-resolve the online player and record `before` from
   `Player.Functions.GetItemByName(item)` (`0` if none).
2. `Player.Functions.AddItem(item, amount)` (this is the player method, **not**
   the `exports['qb-core']:AddItem` item-definition registrar); a return other
   than `true` becomes `failed` (`execution_failed`).
3. Re-read the held quantity and require `after - before == amount`.
4. On mismatch, mark `failed` with a `verification_failed` message. **No
   automatic rollback**; operators use the audit row.

The success `result` JSON contains `{ item, amount, before, after, reason,
verify_result }` (plus `at`); `set_job` contains `{ before, after,
verify_result, at }`. Execution failures surface as `code: "execution_failed"`;
the detailed `verification_failed ...` / `execution_failed ...` text is in
`error` and in `result.error`.

This is an L4 action: it never auto-executes, even if `dry_run` is false, and
it does not consume the `add_money` daily budget.

---

## 9. HTTP errors

Errors are JSON objects with exactly `error` and `code` (additional fields may
appear for action results). No stack traces.

| Code | Typical HTTP | Meaning |
|:---|:---|:---|
| `unauthorized` | 401 | Missing/wrong bearer token |
| `missing_agent_id` | 400 | No valid `X-Agent-Id` |
| `bad_request` / `invalid_params` | 400 | Malformed body or args |
| `unsupported_action` | 400 | Action not in the whitelist |
| `money_cap_exceeded` | 400 | `amount > max_money` |
| `daily_budget_exceeded` | 400 | Daily budget would be exceeded |
| `player_not_found` | 400 | Target not online |
| `account_unavailable` | 400 | Target lacks the account |
| `quest_not_found` | 400 | Quest not in catalog |
| `job_not_found` | 400 | Job not in `QBCore.Shared.Jobs` |
| `grade_not_found` | 400 | Grade not in `jobs[job].grades` |
| `item_not_found` | 400 | Item not in `QBCore.Shared.Items` |
| `text_too_long` | 400 | Notify text over cap |
| `not_found` | 404 | Unknown route or own-row id not found |
| `method_not_allowed` | 405 | Wrong method (`Allow` set) |
| `idempotency_conflict` | 409 | Key reused with different action/params |
| `invalid_status` | 409 | Approve/reject on a non-pending row |
| `execution_failed` | 409 | Execution attempted and failed |
| `expired` | 410 | Approval deadline passed |
| `body_too_large` | 413 | Body > 16 KiB |
| `db_error` | 500 | Database unavailable/query failed |
| `quest_catalog_unavailable` | 500 | `GetQuestCatalog` threw |
| `disabled` | 503 | Kill switch off |
| `agent_token_not_configured` | 503 | Agent token empty |
| `admin_token_not_configured` | 503 | Admin token empty on approve/reject |

Policy rejection at **proposal** time returns the policy code; policy rejection
at **approval** time also marks the row `rejected` and returns `409` when the
underlying code is a `400`-class policy code.

---

## 10. Security invariants

1. Server-side only: no client scripts/NUI; clients cannot propose or approve.
2. Two independent tokens (agent vs admin); constant-time comparison.
3. Agent token cannot approve; admin token cannot propose.
4. `X-Agent-Id` scopes reads; foreign ids return `404`.
5. All numeric/string/enum/online/quest/budget checks happen on the server.
6. Unknown action types are rejected, not defaulted.
7. No hardcoded secrets; no token logging/persistence.
8. Keep the FXServer HTTP port on loopback/private networks; terminate TLS at a
   trusted proxy if needed. CORS is not enabled.
9. No automatic rollback of economy mutations; failures are audited loudly.
10. `add_money`, `start_quest`, `set_job` and `grant_item` always require
    `pending_approval`, regardless of the proposing agent.

---

## 11. Implementation notes

- oxmysql may return `{affectedRows, insertId}` instead of a number; the broker
  normalizes both `MySQL.insert.await` and `MySQL.update.await` results before
  using them as action ids/affected counts.
- `Player.Functions.AddMoney` exists in two shapes depending on load order:
  qb-core's original closure and core-framework's `function(self, ...)` wrapper.
  The broker reads `debug.getinfo(fn, 'u').nparams` and calls the matching shape.
- Cross-resource player objects are copies: the broker reads money **from the
  DB** before/after, calls `player.Functions.Save(true)`, then verifies the DB
  delta instead of trusting a stale in-memory copy.
- Live smoke (2026-10-21): notify executed, add_money 250 approved and persisted,
  duplicate key idempotent, cap rejected, agent token cannot approve, start_quest
  approved and executed.

---

## 12. Out of scope / next slices

- Discord/Web approval UI, approval notifications.
- Per-agent rate limiting beyond FXServer's HTTP limiter (10/s, burst 25) and
  the daily money budget.
- Background TTL worker (currently lazy sweep on `List`/`Approve`).
- World-state/atmosphere/scene/NPC actions (L2+ from the design doc).
- Undo/rollback for money; compensation flows for quests.
- LLM/Hub implementation; this resource only accepts proposals.
- Offline-player money operations (QB `GetPlayerByCitizenId` is online-only).
