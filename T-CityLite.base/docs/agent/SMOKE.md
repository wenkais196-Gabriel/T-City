# Live Smoke Checks (`tools/agent_smoke.py`)

The golden/stub suite under `tests/agent/` runs without a server. This CLI is
the bridge to a **running FXServer**: it sends a small, ordered set of HTTP
probes to the gateway (`tools/agent_gateway.py`) and `custom-director`
(`/agent/v1/act`, `/policy`, `/actions`, `/live/*`) and reports exactly what
responded, with one status per probe.

It answers "is the deployed wiring actually alive?", not "is every action
correct?". It never reads the database, never imports a third-party package and
never deletes data.

**Default posture: read-only + `dry_run`.** A non-dry-run request is only sent
with `--allow-write`, and the admin approve endpoint is only called with
`--allow-approve`.

---

## 1. Prerequisites

1. **FXServer is running** and the `custom-director` resource is started. If it
   is stopped, its HTTP routes disappear (connection refused / 404).
2. **The read gateway is running** (`python3 tools/agent_gateway.py`) if you
   want `gateway_health` / `gateway_schema` to run. Its `/health` also pings the
   database: a reachable process with an unreachable DB reports `degraded`.
3. **MySQL/MariaDB is reachable** for the gateway probes. The director probes
   do their own SQL; a DB outage shows up as `db_error` / HTTP 500.
4. **Server convars** are set in the server config (values live outside git):

   | Convar | Needed for |
   |:---|:---|
   | `agent_actions_enabled 1` | every `/agent/v1/act`, `/policy`, `/actions` call |
   | `agent_actions_token` | the director bearer token |
   | `agent_actions_admin_token` | `/actions/{id}/approve` (optional, only stage C) |
   | `agent_live_enabled 1` | `/agent/v1/live/*` |
   | `agent_live_token` | the live bearer token (separate from the action token) |
   | `agent_actions_*` caps/TTL | policy results, not the smoke itself |

5. **An online player** for the write probe. `AGENT_SMOKE_CITIZENID` must be a
   character that is currently online. Note that a `dry_run` proposal still runs
   the normal policy/online check: without a real online citizenid the built-in
   placeholder `SMOKE0001` is likely rejected with `player_not_found`. Set
   `AGENT_SMOKE_CITIZENID` even for a read-only run if you want
   `notify_dry_run` to pass.

The tool reads the process environment directly; it does **not** load `.env`
(so the offline acceptance run with no variables really is all-skip). Export
what you need:

```bash
set -a; . ./.env; set +a    # your local, gitignored file
```

Do not put real tokens in any tracked file, including this document.

### Environment variables

All are optional. A check whose variables are missing is reported as `skip`
with the missing variable name.

| Variable | Used by | Meaning |
|:---|:---|:---|
| `AGENT_GATEWAY_URL` | `gateway_*` | gateway base URL, e.g. `http://127.0.0.1:8787` |
| `AGENT_GATEWAY_TOKEN` | `gateway_*` | gateway bearer token (`AGENT_TOKEN` on the server) |
| `AGENT_DIRECTOR_URL` | director + live | base URL, e.g. `http://127.0.0.1:30120/custom-director` |
| `AGENT_DIRECTOR_TOKEN` | director + act | action bearer token (`agent_actions_token`) |
| `AGENT_LIVE_TOKEN` | `live_players` | live bearer token (`agent_live_token`) |
| `AGENT_ADMIN_TOKEN` | `notify_approve` | admin bearer token (`agent_actions_admin_token`) |
| `AGENT_AGENT_ID` | action routes | `X-Agent-Id`, default `smoke.local` |
| `AGENT_SMOKE_CITIZENID` | write probe | online target player for the real `notify` |

---

## 2. Three-stage usage

### Stage A — read-only

```bash
python3 tools/agent_smoke.py
```

Runs health, schema, policy, list, live and the **dry-run** notify. No mutation
is possible. This is safe to run against any environment you can reach.

Expected: `summary: ... 0 fail` and exit code `0` (missing channels are
`skip`, not `fail`). Checks that are skipped tell you which variable to set.

### Stage B — dry-run write against a real player

```bash
AGENT_SMOKE_CITIZENID=ABC12345 python3 tools/agent_smoke.py --json
```

Still no mutation, but the dry-run proposal now targets an online player and
therefore proves the action token, `X-Agent-Id`, the action contract and the
policy/online gate end to end. The row is persisted with status `proposed`.

### Stage C — controlled real write

```bash
# one real notify, no approval (notify is L1 and auto-executes)
AGENT_SMOKE_CITIZENID=ABC12345 python3 tools/agent_smoke.py --allow-write

# additionally exercise the admin approve endpoint
AGENT_SMOKE_CITIZENID=ABC12345 \
AGENT_ADMIN_TOKEN=... \
python3 tools/agent_smoke.py --allow-approve --json
```

`--allow-approve` implies `--allow-write`. Only use stage C against a test
server: the player receives the in-game notification, and the audit rows stay in
`agent_actions` (see §5).

`--read-only` is accepted for explicitness; combining it with a write flag is a
usage error (exit `2`).

---

## 3. What each check proves

| # | Check | Request | Proves |
|--:|:---|:---|:---|
| 1 | `gateway_health` | `GET /agent/v1/health` | the gateway process answers and reports `ok`/`degraded`; its DB ping is meaningful |
| 2 | `gateway_schema` | `GET /agent/v1/schema` | the read-only contract registry is served and carries `schema_version` |
| 3 | `director_policy` | `GET /agent/v1/policy` (director token) | custom-director HTTP is up, the action token is accepted, the kill switch is on |
| 4 | `director_list_actions` | `GET /agent/v1/actions?limit=1` + `X-Agent-Id` | the token and agent identity are accepted; list/DB path works |
| 5 | `live_players` | `GET /agent/v1/live/players?limit=1` (live token) | `agent_live_enabled`, the separate live token and in-memory sampling work |
| 6 | `notify_dry_run` | `POST /agent/v1/act` with `dry_run: true` | the act envelope, agent id, normalization and policy gate work **without mutating game state** |
| 7 | `notify_propose` | `POST /agent/v1/act` without `dry_run` | the real write path and audit insert work (only with `--allow-write`) |
| 8 | `notify_get` | `GET /agent/v1/actions/{id}` + `X-Agent-Id` | the own-row read path and its id scoping work (only if step 7 returned an id) |
| 9 | `notify_approve` | `POST /agent/v1/actions/{id}/approve` (admin token) | the separate admin credential and the approval guard work (only with `--allow-approve`) |
| 10 | `cleanup` | no request | explicit statement that the tool deletes nothing and rows remain |

Notes:

- `notify` is L1: a proposal without `dry_run` is `executed` immediately. The
  approve endpoint is only valid for `pending_approval` rows, so step 9 normally
  receives `409 invalid_status` for this action and is reported as `skip`
  ("approve not applicable"). That is the guard working, not a broken endpoint.
  To smoke a real approval, propose an action that requires approval (e.g.
  `announce` or `add_money`) and approve that id out of band.
- `director_policy` returns `503 disabled` when `agent_actions_enabled` is not
  `1`; `live_players` keeps working independently because the live routes are
  registered before the action kill switch.
- A `degraded` gateway health still passes (the process is up); the detail shows
  the state so you can investigate the database separately.

---

## 4. Output, timeouts and exit codes

- Human mode prints a table; `--json` prints a stable report:

  ```json
  {
    "run_id": "smoke-20261022T184549Z-513b65",
    "started_at": "2026-10-22T18:45:49+00:00",
    "finished_at": "2026-10-22T18:45:49+00:00",
    "read_only": true,
    "allow_write": false,
    "allow_approve": false,
    "agent_id": "smoke.local",
    "checks": [
      {"name": "gateway_health", "status": "pass", "detail": "status=ok",
       "http_status": 200, "elapsed_ms": 12}
    ],
    "summary": {"pass": 6, "fail": 0, "skip": 4}
  }
  ```

  `status` is `pass` / `fail` / `skip`; `http_status` is `null` for skipped
  checks and transport failures; `elapsed_ms` is measured per request.
- `--timeout-ms` (default `5000`) applies to each request independently.
- Exit codes: `0` = no failures (passes and skips), `1` = at least one `fail`,
  `2` = invalid arguments (including `--timeout-ms 0`).
- A transport error (`ConnectionRefused`, DNS, timeout, TLS) is reported as a
  `fail` with the exception type; you never get a traceback.

### Token safety

Tokens are read from the environment only to populate the `Authorization`
header. They never appear in stdout, stderr, the JSON report, a URL or a detail
string; when a variable is absent the detail names it (for example
`missing AGENT_LIVE_TOKEN`), and any upstream text that happens to contain a
configured token is redacted to `<redacted>`. The report also omits target URLs.

---

## 5. Residue in `agent_actions`

**The tool deletes nothing.** Every write probe leaves a row:

- `smoke:dry:<run_id>` — `notify`, status `proposed` (dry run, never executes);
- `smoke:propose:<run_id>` — `notify`, status `executed` (or `failed` if the
  notification could not be delivered);
- an approve attempt does not create a row.

Rows from earlier runs accumulate. Filter them with the `smoke:` key prefix,
for example:

```sql
SELECT id, action_type, status, idempotency_key, requested_at
FROM agent_actions
WHERE idempotency_key LIKE 'smoke:%'
ORDER BY id DESC;
```

or inspect your own rows through `GET /agent/v1/actions` with the same
`X-Agent-Id`. Removing them is an operator decision; the smoke tool
intentionally has no delete path.

---

## 6. Common failures

| Symptom (detail) | Likely cause | Fix |
|:---|:---|:---|
| `HTTP 503 code=live_disabled` | `agent_live_enabled` is not `1` | set `setr agent_live_enabled 1`, restart the resource |
| `HTTP 503 code=live_token_not_configured` | `agent_live_token` is empty | set the convar; export the same value as `AGENT_LIVE_TOKEN` |
| `HTTP 401 code=unauthorized` on live | live token mismatch; the director token is not a fallback | use the value of `agent_live_token` |
| `HTTP 503 code=disabled` | `agent_actions_enabled` is `0` | enable the actions kill switch |
| `HTTP 503 code=agent_token_not_configured` | `agent_actions_token` is empty | set it; the HTTP surface is closed without it |
| `HTTP 400 code=missing_agent_id` | `X-Agent-Id` missing/invalid | set `AGENT_AGENT_ID` to 1–64 chars of `[A-Za-z0-9_.:-]` |
| `HTTP 401 code=unauthorized` on director | `AGENT_DIRECTOR_TOKEN` does not match `agent_actions_token` | re-export the right token |
| `HTTP 400 code=player_not_found` on notify | `AGENT_SMOKE_CITIZENID` is unset/offline; the placeholder is not online | set it to an online citizenid |
| `409 invalid_status` on approve | the notify already executed (expected) | no action needed; approve a real `pending_approval` row to test approval |
| `transport error: URLError` | server/gateway not running, wrong URL/port, TLS mismatch | start the process or fix `AGENT_*_URL` |
| `gateway_health` shows `degraded`, or a gateway route returns `503 database_error` | gateway is up but the read DB is down | check `AGENT_DB_*` and the `agent_ro` account |

The gateway URL is the gateway's own base (`http://host:8787`), while the
director URL includes the FiveM resource prefix
(`http://host:30120/custom-director`). The tool appends the `/agent/v1/...`
path to whichever base you provide.

---

## 6.1 Console assertions (`--harness`)

HTTP probes can only report a status code. `--harness` adds console assertions on
top of them (design [`07-harness-channel.md`](design/07-harness-channel.md)), so
"did the effect actually print" becomes a check instead of a guess.

```bash
export TCITY_HARNESS_SERVER_LOG=/path/to/fxserver.log
export TCITY_HARNESS_CLIENT_LOG_DIR="$LOCALAPPDATA/FiveM/FiveM.app/logs"   # optional

python3 tools/agent_smoke.py --harness   --expect-server "Started resource custom-phone"   --expect-client "focus" --harness-timeout-ms 8000 --json
```

| Check | Meaning |
|---|---|
| `harness_server` / `harness_client` | the log is readable; an unset path is `skip`, a set-but-missing path is `fail` |
| `harness_expect_server[*]` / `harness_expect_client[*]` | one entry per `--expect-*` regex; `fail` on timeout |

Rules that follow from the transport (measured, see design 07 §2): `wait` starts at
the current end of the file, the client log rotates per launch, and history needs
`get_console_lines(after_seq=0)` through MCP.

## 7. What this tool does not cover

- Field-level assertions or the 189-case stub matrix; those stay in the offline
  suite.
- Direct database content checks (it deliberately has no DB driver).
- The client-side effect channel / NUI acks (teleport, revive visuals), load,
  concurrency, TTL expiry, and multi-player scenarios.
- Real approval of an auto-executing `notify`; use a pending action for that.
- Cleanup of prior rows; see §5.

For the broader test strategy see
[`design/05-test-and-eval.md`](design/05-test-and-eval.md); for the action
contract behind checks 6–9 see [`ACTIONS.md`](ACTIONS.md).
