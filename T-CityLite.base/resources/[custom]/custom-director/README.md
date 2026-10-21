# custom-director — server-only agent action broker

First safe slice of GitHub issues **#30 / #32**: an agent can *propose* a small,
whitelisted set of game actions. The resource validates, previews, enforces
policy/budget, persists an audit row, auto-executes low-risk actions, and puts
`add_money` / `start_quest` behind human approval.

It is server-only. There is no client script, no NUI, no LLM integration and no
client-side trust. See [`docs/agent/ACTIONS.md`](../../../docs/agent/ACTIONS.md)
for the formal contract and [`docs/server-design/08-agent-director.md`](../../../../docs/server-design/08-agent-director.md)
for the architecture.

| Item | Value |
|:---|:---|
| Resource | `T-CityLite.base/resources/[custom]/custom-director` |
| Migration | [`migrations/v2.3_agent_actions.sql`](../../../migrations/v2.3_agent_actions.sql) |
| Dependencies | `qb-core`, `oxmysql`, `custom-quest`, `core-framework` |
| Audit table | `agent_actions` |
| Default state | **disabled** (`agent_actions_enabled = 0`) |

---

## 1. Configuration

Everything is a FiveM convar. Tokens are **never** stored in this repository,
the database, logs or HTTP responses. Put the values in an untracked local cfg
(or your secret manager) and never commit them.

| Convar | Default | Meaning |
|:---|:---|:---|
| `agent_actions_enabled` | `0` | `1` enables proposals/execution. Any other value returns `503 disabled`. Read per request, so it is a live kill switch. |
| `agent_actions_token` | *(empty)* | Bearer token for agent endpoints. Empty ⇒ every HTTP endpoint returns `503`. Required for HTTP. |
| `agent_actions_admin_token` | *(empty)* | Bearer token for approve/reject. Empty ⇒ approve/reject returns `503`. Required for HTTP approvals. |
| `agent_actions_max_money` | `1000` | Per-action `add_money` cap (integer ≥ 1). |
| `agent_actions_daily_budget` | `5000` | Daily `add_money` budget across `pending_approval`, `approved` and `executed` rows. |
| `agent_actions_max_notify_chars` | `300` | Maximum `notify` text length in UTF-8 characters (capped at 2000). |
| `agent_actions_ttl_seconds` | `900` | Approval deadline for `pending_approval` rows (30–86400). |
| `agent_actions_selftest` | `0` | `1` runs the pure policy selftest on resource start and prints `[AGENT-ACTIONS-SELFTEST]` lines. No DB/player writes. |

Example **local, untracked** cfg (do not commit real values):

```cfg
# custom-director.local.cfg (gitignored / server-side secret store)
set agent_actions_enabled "1"
set agent_actions_token "REPLACE_WITH_LONG_RANDOM_TOKEN"
set agent_actions_admin_token "REPLACE_WITH_A_DIFFERENT_LONG_RANDOM_TOKEN"
set agent_actions_max_money "1000"
set agent_actions_daily_budget "5000"
set agent_actions_max_notify_chars "300"
set agent_actions_ttl_seconds "900"
# set agent_actions_selftest "1"
```

Generate tokens locally, for example `openssl rand -hex 32`. The two tokens
must be different: an agent must not be able to approve its own actions.

Start the resource only after the migration is applied:

```cfg
ensure custom-director
```

This slice does **not** edit `server.cfg` or restart FXServer.

---

## 2. Database

Apply the migration once (idempotent):

```bash
cd /path/to/T-City
set -a; . ./.env; set +a
MYSQL_PWD="$TCITY_DB_PASS" mysql -h "$TCITY_DB_HOST" -P "${TCITY_DB_PORT:-3306}" \
  -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
  < T-CityLite.base/migrations/v2.3_agent_actions.sql
```

Verify without printing credentials:

```bash
MYSQL_PWD="$TCITY_DB_PASS" mysql -h "$TCITY_DB_HOST" -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
  -e "SHOW CREATE TABLE agent_actions\G"
```

The table stores one row per proposal, including dry-runs (`proposed`) and
rejections. `idempotency_key` is globally unique; `params`, `preview` and
`result` are JSON. No secrets are written.

---

## 3. Actions and policy

| Action | Risk | Status after propose | Approval | Limits / checks |
|:---|:---|:---|:---|:---|
| `notify` | L1 | `approved` → `executed` (same call) | none | target online; text length ≤ `max_notify_chars`; kind whitelist |
| `add_money` | L4 | `pending_approval` | **always** | target online; account ∈ `cash,bank,crypto`; amount 1..`max_money`; daily budget |
| `start_quest` | L3 | `pending_approval` | **always** | target online; `quest_id` must exist in `GetQuestCatalog` |

Arguments:

```json
{"citizenid":"ABC12345","text":"The docks are quiet tonight.","kind":"info"}
{"citizenid":"ABC12345","account":"bank","amount":250,"reason":"director reward"}
{"citizenid":"ABC12345","quest_id":"delivery_001"}
```

`kind` is optional and one of `info`, `success`, `warning`, `error`, `primary`
(default `info`). `reason` is required for `add_money`.

Policy checks are always server-side:

1. kill switch (`agent_actions_enabled`);
2. agent id, action type, params and idempotency-key shape;
3. target player online (`QBCore.Functions.GetPlayerByCitizenId`);
4. action-specific caps/whitelists;
5. daily budget (money) including pending reservations;
6. quest existence (`custom-quest:GetQuestCatalog`);
7. idempotency (same key + same action/params returns the original row).

Policy-rejected proposals are **not** persisted, so the idempotency key remains
reusable after a cap is raised or the player reconnects. Approval-time checks
are repeated; if they now fail, the row is marked `rejected`.

See [`docs/agent/ACTIONS.md`](../../../docs/agent/ACTIONS.md) for preview
schemas, status transitions and budget semantics.

---

## 4. HTTP API

FiveM exposes a resource's `SetHttpHandler` under `/<resource-name>/`, so the
external base URL is:

```text
http://127.0.0.1:30120/custom-director
```

The paths below are the logical handler paths (they are what `req.path` contains
after FiveM strips the resource prefix). Use `Authorization: Bearer …` on every
request; `X-Agent-Id` is required on every proposal/read of the agent's own
rows. All responses are JSON; errors are `{"error":"…","code":"…"}` with no stack
traces. CORS is intentionally not enabled.

| Method | Path | Auth | Purpose |
|:---|:---|:---|:---|
| `POST` | `/agent/v1/act` | agent token + `X-Agent-Id` | Propose (and for `notify`, execute) an action |
| `GET` | `/agent/v1/actions/<id>` | agent token + `X-Agent-Id` | Read one own action |
| `GET` | `/agent/v1/actions?status=…&limit=…` | agent token + `X-Agent-Id` | List own actions (`limit` 1–100) |
| `GET` | `/agent/v1/policy` | agent token | Current limits/action matrix/daily spend |
| `POST` | `/agent/v1/actions/<id>/approve` | **admin** token | Approve + execute a pending action |
| `POST` | `/agent/v1/actions/<id>/reject` | **admin** token | Reject a pending action |

### 4.1 Propose / dry-run

```bash
BASE=http://127.0.0.1:30120/custom-director
export AGENT_TOKEN="…"          # do not paste real tokens into files
export ADMIN_TOKEN="…"

curl -sS -X POST "$BASE/agent/v1/act" \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "X-Agent-Id: director.local" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "notify",
    "args": {"citizenid":"ABC12345","text":"The docks are quiet tonight.","kind":"info"},
    "idempotency_key": "beat_123/notify/1",
    "dry_run": true
  }'
```

Response shape (dry-run; no client event is sent):

```json
{
  "ok": true,
  "id": 1,
  "status": "proposed",
  "preview": {
    "action_type": "notify",
    "risk": "L1",
    "requires_approval": false,
    "citizenid": "ABC12345",
    "player_found": true,
    "player_source": 12,
    "text_length": 28,
    "kind": "info"
  },
  "dry_run": true
}
```

A real `notify` returns `status: "executed"`. An `add_money` proposal returns
`202` and:

```json
{
  "ok": true,
  "id": 2,
  "status": "pending_approval",
  "preview": {
    "action_type": "add_money",
    "risk": "L4",
    "requires_approval": true,
    "citizenid": "ABC12345",
    "player_found": true,
    "account": "bank",
    "amount": 250,
    "account_exists": true,
    "before": 1250,
    "after": 1500,
    "daily_budget": 5000,
    "daily_spent": 0,
    "daily_remaining": 5000,
    "daily_remaining_after": 4750
  },
  "expires_at": "2026-10-21 16:00:00"
}
```

### 4.2 Approve / reject

```bash
# Approve and execute
curl -sS -X POST "$BASE/agent/v1/actions/2/approve" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"approver":"discord:alice"}'

# Reject
curl -sS -X POST "$BASE/agent/v1/actions/2/reject" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"approver":"discord:alice","reason":"event already paid out"}'
```

Approval re-runs normalization, preview and policy. The row transitions
`pending_approval → approved → executed` (or `failed`). A policy/expiry failure
moves it to `rejected`. `approved_by`/`approved_at` and `executed_at` are set.

### 4.3 Read surfaces

```bash
curl -sS "$BASE/agent/v1/policy" \
  -H "Authorization: Bearer $AGENT_TOKEN"

curl -sS "$BASE/agent/v1/actions?status=pending_approval&limit=20" \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "X-Agent-Id: director.local"

curl -sS "$BASE/agent/v1/actions/2" \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "X-Agent-Id: director.local"
```

Reads are scoped to the `X-Agent-Id` header. Another agent's row returns `404`
(no existence leak).

### 4.4 HTTP status codes

| HTTP | When |
|:---|:---|
| `200` | Proposal accepted/executed, read OK, approval/rejection OK |
| `202` | Proposal accepted and awaiting approval |
| `400` | Missing/invalid header, body or action params |
| `401` | Missing/wrong bearer token |
| `404` | Unknown route or unknown/foreign action id |
| `405` | Wrong method for a known route (`Allow` header set) |
| `409` | Idempotency conflict, invalid status transition, execution failure |
| `410` | Approval deadline passed |
| `413` | Request body > 16 KiB |
| `500` | Database/internal failure (no stack trace returned) |
| `503` | Disabled, agent token unset, or admin token unset |

If `agent_actions_enabled != 1` **or** `agent_actions_token` is empty, every
HTTP endpoint returns `503`.

---

## 5. Server exports

Trusted server resources can call the same broker without HTTP:

```lua
-- returns {ok, id, status, preview, error}
local proposal = exports['custom-director']:Propose(
    'director.local',
    'add_money',
    { citizenid = 'ABC12345', account = 'bank', amount = 250, reason = 'director reward' },
    'beat_123/money/1',
    false -- dryRun
)

local approved = exports['custom-director']:Approve(proposal.id, 'discord:alice')
local rejected = exports['custom-director']:Reject(proposal.id, 'discord:alice', 'duplicate')
local row = exports['custom-director']:Get(proposal.id)
local rows = exports['custom-director']:List('pending_approval', 20)
local policy = exports['custom-director']:Policy()
```

Exports are server-only and still enforce the same convar kill switch, policy,
budget and approval rules.

---

## 6. Console approval

```text
/agentapprove <id>
```

- FXServer console (`source == 0`) is allowed.
- In-game players need the `qbcore.god` ACE.
- Calls made by another resource are refused (console commands must originate
  from the real console).
- The approval is recorded with `approved_by = "console"` or `"player:<src>"`.

The HTTP admin route is the preferred approval channel for a Discord/Web UI.

---

## 7. Security model

- **Server-only:** `server_only 'yes'`, no `client_script`, no NUI. Clients
  cannot propose, approve or read rows.
- **No hardcoded secrets:** tokens come from convars only. They are never
  logged, stored in MariaDB or returned. Both tokens must be set and different.
- **Loopback/private network:** `SetHttpHandler` listens on the FXServer HTTP
  port. Do not expose that port to the public internet; use a trusted local
  reverse proxy/TLS terminator if a remote approver UI needs it.
- **Least privilege:** agent token cannot approve; admin token cannot propose.
  Reads are filtered by `X-Agent-Id`.
- **No client trust:** every type/range/account/player/quest/budget check runs
  on the server.
- **No stack traces:** HTTP errors use `{error, code}` only; unexpected errors
  are logged server-side, truncated.
- **No rollback:** `add_money` verifies the balance delta and records a loud
  failure row if it does not match. It deliberately does **not** attempt an
  automatic rollback.
- **No LLM:** this resource only executes deterministic actions.

---

## 8. Kill switch

Any of these stops execution immediately:

```cfg
set agent_actions_enabled "0"   # proposals/approvals/executions -> 503 or disabled
```

or:

```text
stop custom-director
```

`agent_actions_enabled` is read on every call, so `set … 0` takes effect without
a restart. Stopping the resource removes its exports and HTTP endpoint; other
game systems keep working.

To keep the resource running but disable only token access, leave
`agent_actions_enabled 1` and clear `agent_actions_token` (HTTP returns 503,
exports still work). For a full stop, use `agent_actions_enabled 0`.

---

## 9. Tests and verification

Offline checks (no FXServer, no DB):

```bash
cd /path/to/T-City
luac5.4 -p 'T-CityLite.base/resources/[custom]/custom-director/server/policy.lua'
luac5.4 -p 'T-CityLite.base/resources/[custom]/custom-director/server/main.lua'
luac5.4 -p 'T-CityLite.base/resources/[custom]/custom-director/server/selftest.lua'

lua5.4 T-CityLite.base/tests/agent/test_agent_actions_policy.lua
cd T-CityLite.base && python3 -m pytest -q tests/unit/layer3_business/test_agent_actions.py
```

In-resource selftest (pure policy only; no players/DB writes):

```cfg
setr agent_actions_selftest "1"
ensure custom-director
```

Look for `[AGENT-ACTIONS-SELFTEST] RESULT passed=… failed=…` in the server
console. Remove the convar afterwards.

Live smoke performed on 2026-10-21 with a held fake player:

- `notify` → `executed`
- `add_money` 250 → `pending_approval` → admin approve → `executed`, DB bank 10000 → 10250
- duplicate idempotency key → same action id, no double credit
- amount 5000 → `money_cap_exceeded`
- agent token on approve → 401
- `start_quest` → `pending_approval` → admin approve → `executed`

The harness is not enabled by default; keep `agent_actions_enabled=0` unless an
operator has configured both tokens and an approval process.

---

## 10. Known limitations (intentional, first slice)

- No per-agent HTTP rate limit beyond FXServer's built-in HTTP limiter and the
  daily money budget.
- No background expiry worker: expired pending rows are rejected lazily on
  `List` and on `Approve`.
- `notify` has no delivery acknowledgement; an online target is assumed.
- `add_money` only works for online players (QB `GetPlayerByCitizenId`).
- `start_quest` returns whatever `custom-quest:TriggerQuest` reports; quest
  preconditions/cooldowns are enforced by that resource, not duplicated here.
- Daily budget is based on the DB `requested_at` date; pending approvals reserve
  budget until rejected/expired/failed.
- No Discord/Web approval UI, no LLM, no world-state/atmosphere actions; those
  are follow-up issues.
