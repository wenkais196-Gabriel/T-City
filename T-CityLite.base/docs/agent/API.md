---
id: base-agent-api
type: manual
status: active
system: agent
owner: hermes
updated: 2026-10-23
review_by: 2027-01-30
---

# Agent Read API and MCP Sidecar (issue #24)

Read-only HTTP API and stdio MCP server for T-City agents. Both surfaces reuse
[`tools/agent_data.py`](../../../tools/agent_data.py) and query only the curated
`agent_*` views. They never write to MariaDB and never touch the FXServer
thread.

| Component | Path | Transport |
|:---|:---|:---|
| Data layer | [`tools/agent_data.py`](../../../tools/agent_data.py) | Python import / CLI smoke |
| HTTP gateway | [`tools/agent_gateway.py`](../../../tools/agent_gateway.py) | `ThreadingHTTPServer`, JSON over HTTP |
| MCP sidecar | [`tools/agent_mcp.py`](../../../tools/agent_mcp.py) | JSON-RPC 2.0, newline-delimited stdio |
| Schema contract | [`schema.json`](schema.json) | JSON registry, `schema_version = 1` |
| Event feed view | [`migrations/v2.2.2_agent_events_view.sql`](../../migrations/v2.2.2_agent_events_view.sql) | `agent_events_feed` |

The schema registry now covers **5 views / 36 fields**. `agent_events_feed` is
the read-only view over the append-only `agent_events` outbox; `agent_ro` cannot
read `agent_events` directly.

---

## 1. Configuration

All values come from the process environment or the repository `.env`
(gitignored). Never commit real values.

| Variable | Default | Purpose |
|:---|:---|:---|
| `AGENT_DB_HOST` / `TCITY_DB_HOST` | `127.0.0.1` | MariaDB host |
| `AGENT_DB_PORT` / `TCITY_DB_PORT` | `3306` | MariaDB port |
| `AGENT_DB_USER` | `agent_ro` | Read-only account |
| `AGENT_DB_PASS` | **required** | Password for `agent_ro`; no admin fallback |
| `AGENT_DB_NAME` / `TCITY_DB_NAME` | `TCityLite` | Database name |
| `AGENT_TOKEN` | **required for HTTP** | Bearer token; gateway refuses to start without it |
| `AGENT_HTTP_HOST` | `127.0.0.1` | Listen address |
| `AGENT_HTTP_PORT` | `8787` | Listen port |

`tools/agent_data.py` loads `.env` automatically if a key is not already set.
The MCP sidecar needs only the `AGENT_DB_*` values; it does not use
`AGENT_TOKEN` because it is a local stdio process.

Start the gateway:

```bash
cd /path/to/T-City
# AGENT_TOKEN is supplied by the caller/secret manager; do not hardcode it.
export AGENT_TOKEN="$(openssl rand -hex 32)"
AGENT_HTTP_HOST=127.0.0.1 AGENT_HTTP_PORT=8787 \
  python3 tools/agent_gateway.py
```

If `AGENT_TOKEN` is empty or missing, the process exits with status `2` and
prints a refusal to stderr. There is no unauthenticated development mode.

---

## 2. Authentication and transport

Every HTTP endpoint, including `/health`, requires:

```http
Authorization: Bearer <AGENT_TOKEN>
```

- Missing, malformed or wrong tokens receive `401` with
  `{"error": "...", "code": "unauthorized"}` and `WWW-Authenticate: Bearer`.
- Tokens are compared with `hmac.compare_digest`.
- Tokens are never logged or returned in a response.
- Only `GET` is implemented. `POST` / `PUT` / `PATCH` / `DELETE` / `OPTIONS`
  return `405` with `Allow: GET`.
- CORS is intentionally **not** enabled. Put the gateway behind a local
  reverse proxy if a browser UI needs access.
- The gateway itself speaks plain HTTP. Keep the default loopback bind, or
  terminate TLS at a trusted reverse proxy before exposing it on a network.
- Responses use `Content-Type: application/json; charset=utf-8`,
  `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`.

---

## 3. Response contract

Successful list/detail responses:

```json
{
  "schema_version": 1,
  "data": {},
  "next_cursor": 0,
  "meta": {"count": 0}
}
```

- `schema_version` is the agent contract version (`1`). Additive view changes
  keep this version; consumers should also inspect `schema.json`.
- `data` is an object, an array, or a digest object depending on the endpoint.
- `next_cursor` is present on the event feed. It is the last returned event
  `id`, or the request's `since_id` when no rows were returned.
- `meta` is informational (`count`, effective `limit`, filters). It is not
  part of the stable data payload.

Errors:

```json
{"error": "unknown field(s): citizenid; DROP TABLE players", "code": "bad_request"}
```

| HTTP | `code` | Meaning |
|---:|:---|:---|
| 400 | `bad_request` | Invalid query parameter, field, order, type, timestamp or cursor |
| 401 | `unauthorized` | Missing/invalid bearer token |
| 403 | `forbidden` | Database account lacks SELECT on a view |
| 404 | `not_found` | Unknown endpoint or unknown `citizenid` |
| 405 | `method_not_allowed` | Only `GET` is supported |
| 500 | `internal_error` / `agent_data_error` | Unexpected server failure |
| 503 | `database_error` / `database_unavailable` / `database_auth` | DB unavailable or misconfigured |
| 503 | `schema_unavailable` | Required view/migration or `schema.json` is missing |

No stack trace is returned to a client. Unexpected failures are logged to
stderr as a type/message only.

---

## 4. HTTP endpoints

Base path: `/agent/v1`. Examples use `$AGENT_TOKEN`; never paste a real token
into a tracked file.

### 4.1 `GET /agent/v1/health`

Liveness plus a shallow DB check (`SELECT 1`). Health is authenticated too.

```bash
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  http://127.0.0.1:8787/agent/v1/health
```

```json
{
  "schema_version": 1,
  "data": {
    "status": "ok",
    "api_version": "v1",
    "schema_version": 1,
    "read_only": true,
    "database": {"backend": "mysql-cli", "reachable": true},
    "server_time": "2026-10-21T14:43:21+02:00"
  }
}
```

`status` is `degraded` when the DB ping fails; the process is still alive.
`backend` is `mysql.connector` or `mysql-cli`, matching the data layer fallback.

### 4.2 `GET /agent/v1/schema`

Returns the versioned contract from `schema.json` (plus `read_only: true` and
`api_version`). This is the registry agents should use to discover views,
fields and PII flags before issuing queries.

```bash
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  http://127.0.0.1:8787/agent/v1/schema
```

Response shape:

```json
{
  "schema_version": 1,
  "data": {
    "schema_version": 1,
    "database": "TCityLite",
    "generated_by": "tools/agent_schema.py",
    "read_only": true,
    "api_version": "v1",
    "views": {
      "agent_events_feed": {
        "description": "...",
        "source_tables": ["agent_events"],
        "pii_fields": [],
        "fields": [{"name": "event_type", "type": "varchar(64)", "pii": false}]
      }
    }
  }
}
```

`name`, `firstname` and `lastname` are marked `pii: true` in the snapshot view.
Treat them as personal data.

### 4.3 `GET /agent/v1/players`

Query the player snapshot. Values are parameterized; identifiers, field names
and order clauses are whitelisted.

| Parameter | Type | Notes |
|:---|:---|:---|
| `limit` | int | `1..200`, default 50; out-of-range values are clamped |
| `job` | string | Exact job name (`police`, `trucker`, ...) |
| `gang` | string | Exact gang name (`none`, ...) |
| `updated_since` | string | ISO 8601 date/time or relative `15m` / `5h` / `7d` |
| `fields` | string | Comma-separated whitelist; omit for all snapshot fields |
| `order_by` | string | `citizenid`, `name`, `job`, `gang`, `cash`, `bank`, `crypto`, `last_updated`, `schema_version` |
| `order` | string | `asc` or `desc` |

```bash
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  'http://127.0.0.1:8787/agent/v1/players?limit=20&job=police&fields=citizenid,job,bank&order_by=bank&order=desc'
```

```json
{
  "schema_version": 1,
  "data": [
    {"citizenid": "IYY39878", "job": "police", "bank": 98365616.0}
  ],
  "meta": {"count": 1, "limit": 20, "order_by": "bank", "order": "desc"}
}
```

Injection-shaped values are rejected with `400` before any SQL is sent, for
example `fields=citizenid; DROP TABLE players` or `order_by=bank; DROP`.

### 4.4 `GET /agent/v1/players/<citizenid>`

Return one snapshot row. Unknown IDs return `404 not_found`.

```bash
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  http://127.0.0.1:8787/agent/v1/players/IYY39878
```

`citizenid` is validated as `[A-Za-z0-9_-]{1,64}`. The snapshot deliberately
omits `license`, `identifier`, `position`, `inventory`, `metadata` and `phone`.

### 4.5 `GET /agent/v1/players/<citizenid>/timeline`

Read the normalized timeline view (`quest.*`, `story.choice`, `economy.*`).

| Parameter | Type | Notes |
|:---|:---|:---|
| `limit` | int | `1..200`, default 50 |
| `since` | string | ISO 8601 or `15m` / `5h` / `7d`; filters `occurred_at` |

```bash
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  'http://127.0.0.1:8787/agent/v1/players/IYY39878/timeline?limit=10&since=7d'
```

Rows are ordered by `occurred_at DESC`, then `event_type` and `source_table`.
`payload` is parsed into a JSON object when valid. The view has no surrogate
id; use `occurred_at` for the timeline and `agent_events_feed.id` when exact
cursor pagination is required.

### 4.6 `GET /agent/v1/events`

Read the append-only outbox through `agent_events_feed`, ordered by the
monotonic cursor `id`.

| Parameter | Type | Notes |
|:---|:---|:---|
| `since_id` | int | Return rows with `id > since_id`; default 0 |
| `type` | string | Exact type (`quest.completed`) or prefix (`quest.*`) |
| `limit` | int | `1..200`, default 50 |

```bash
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  'http://127.0.0.1:8787/agent/v1/events?since_id=0&type=quest.*&limit=50'
```

```json
{
  "schema_version": 1,
  "data": [],
  "next_cursor": 0,
  "meta": {"count": 0, "limit": 50, "since_id": "0", "type": "quest.*"}
}
```

Cursor rule: request the next page with `since_id=<next_cursor>`. The cursor is
the numeric `id`, not `created_at`, because multiple events can share a
millisecond. An empty page returns the incoming `since_id` as `next_cursor`.

The local dataset currently has zero `agent_events` rows, so the endpoint
returns an empty page. The view and grant are still verified; see section 9.

### 4.7 `GET /agent/v1/world`

Return world state, world-event summaries, or the documented fallback row.

| Parameter | Type | Notes |
|:---|:---|:---|
| `limit` | int | `1..200`, default 50 |

```bash
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  'http://127.0.0.1:8787/agent/v1/world?limit=10'
```

If both `world_state` and `world_events` are empty, the view returns one row
with `source_table: "fallback"`, `region_id: "system"`,
`state_key: "no_data"`. Check `source_table` before treating a row as real
world state. `state_value` is parsed into a JSON object when valid.

### 4.8 `GET /agent/v1/economy`

Per-job aggregates from `agent_economy_metrics`, ordered by `total_bank DESC`.

```bash
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  http://127.0.0.1:8787/agent/v1/economy
```

Aggregation is not anonymization: a job group with one player reveals that
player's balances. Apply a minimum group size before sharing outside the
trusted agent.

### 4.9 `GET /agent/v1/world/digest`

A compact first-look aggregate, bounded by a token budget.

| Parameter | Type | Default | Notes |
|:---|:---|:---|:---|
| `window` (alias `window_minutes`) | int | 5 | `1..1440` minutes; uses DB `NOW()` |
| `budget_tokens` | int | 2000 | `1..20000`; estimate is 4 JSON chars/token. Use >=200 for a useful digest. |

```bash
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  'http://127.0.0.1:8787/agent/v1/world/digest?window=1440&budget_tokens=1000'
```

```json
{
  "schema_version": 1,
  "data": {
    "digest_version": 1,
    "generated_at": "2026-10-21T14:43:26+02:00",
    "window_minutes": 1440,
    "budget_tokens": 1000,
    "players": {
      "total": 2,
      "online": 1,
      "online_is_estimate": true,
      "online_estimate": 1,
      "online_estimate_note": "derived from agent_player_snapshot.last_updated; true session state is not exposed by the read layer",
      "recently_active": 1,
      "stale_24h": 1
    },
    "events": {"available": true, "total": 0, "top_types": []},
    "recent_events": [],
    "economy": {
      "job_groups": 2,
      "players": 2,
      "total_cash": 5965.0,
      "total_bank": 98371166.0,
      "top_jobs": [{"job": "police", "player_count": 1, "total_bank": 98365616.0}]
    },
    "risk": {
      "low_liquidity_count": 0,
      "low_liquidity_players": [],
      "stuck_quest_available": true,
      "stuck_quest_candidates": []
    },
    "truncated": false,
    "estimated_tokens": 265
  }
}
```

The digest includes:

- player count, an `online` / `online_estimate` from `last_updated` (with
  `online_is_estimate: true`), recently active and stale-24h counts;
- event count in the window, top 5 event types and up to 5 important recent
  events (`quest.completed`, `quest.failed`, `quest.abandoned`,
  `story.choice`, `vehicle.acquired`, `economy.*`), with a truncated payload
  preview;
- economy totals and up to 3 top jobs;
- cheap risk hints: low-liquidity players (`cash + bank < 100`) and up to 5
  stuck quest candidates (latest quest event older than 30 minutes and not
  terminal, from the last 7 days).

When the budget is tight, optional lists are trimmed, then optional sections
are dropped; `truncated` becomes `true`. The final `estimated_tokens` is
computed from the serialized body. The digest is best-effort and bounded, and
`online` / `online_estimate` is explicitly an estimate
(`online_is_estimate: true`): the read layer does not expose live session state.

---

## 5. MCP sidecar (stdio)

Run from the repository root:

```bash
python3 tools/agent_mcp.py
```

- Transport: JSON-RPC 2.0, one JSON object per line on stdin/stdout.
- No external dependencies; stdout contains protocol responses only (logs, if
  any, go to stderr).
- Methods: `initialize`, `tools/list`, `tools/call`, `ping`, and the
  `notifications/initialized` / `notifications/cancelled` notifications.
- Protocol versions accepted: `2024-11-05` (default), `2025-03-26`,
  `2025-06-18`.
- Tool failures are returned as MCP tool results with `isError: true` and a
  JSON body `{"error": "...", "code": "..."}`. Unknown tools and malformed
  requests use JSON-RPC errors.

### 5.1 Tools

| Tool | Input | Returns |
|:---|:---|:---|
| `get_schema` | none | schema registry (`views`, fields, PII, `schema_version`) |
| `query_players` | `limit`, `job`, `gang`, `updated_since`, `fields`, `order_by`, `order` | snapshot rows + `meta` |
| `get_player_snapshot` | `citizenid` (required) | one snapshot row, or `not_found` |
| `list_events` | `since_id`, `type`, `limit` | event rows + `next_cursor` |
| `get_world_digest` | `window_minutes`, `budget_tokens` | budgeted digest |

All tools return `content: [{"type": "text", "text": "<json>"}]`. The JSON body
uses the same `schema_version` / `data` envelope as HTTP; list tools also include
`meta`, and `list_events` includes `next_cursor`.

### 5.2 JSON-RPC examples

One object per line; the blank lines below are only for readability.

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"my-agent","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_schema","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"query_players","arguments":{"limit":2,"job":"police","fields":"citizenid,job,bank"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_events","arguments":{"since_id":0,"type":"quest.*","limit":10}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_world_digest","arguments":{"window_minutes":1440,"budget_tokens":1000}}}
```

Example response to `tools/call`:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {"type": "text", "text": "{\"schema_version\":1,\"data\":{\"views\":{...}}}"}
    ],
    "isError": false
  }
}
```

A client configuration for an MCP host simply launches
`python3 /path/to/T-City/tools/agent_mcp.py`; the process inherits the
`AGENT_DB_*` environment or reads the repository `.env`.

---

## 6. Read-only guarantees

1. **Least-privilege account.** `agent_ro` has `SELECT` on the five agent views
   only. It has no privileges on `players`, `agent_events`, `quest_event_log`,
   `bank_statements`, `world_*`, or any base table. `SHOW GRANTS` must not show
   write privileges.
2. **No write code.** `tools/agent_data.py`, `agent_gateway.py` and
   `agent_mcp.py` contain no `INSERT` / `UPDATE` / `DELETE`. The only SQL
   statement builder emits `SELECT`.
3. **Defense in depth.** `_assert_select_only()` rejects non-SELECT statements,
   multiple statements and write keywords before execution. Identifiers,
   fields, order clauses, event types and citizen IDs are whitelisted.
   Values are passed as parameters with `mysql.connector`, or escaped and
   passed on stdin to the `mysql` CLI.
4. **No password on argv.** The CLI fallback puts the password in `MYSQL_PWD`
   in the child environment and uses `--no-defaults`; it never appears in the
   command line.
5. **No write endpoints.** Every HTTP route is `GET`; MCP exposes only the five
   read tools.
6. **No stack traces.** Errors are mapped to `{error, code}`; internal details
   stay on stderr.
7. **Hard row cap.** Every user-controlled limit is clamped to 200, including
   the digest's event/timeline helper queries.

The `agent_events_feed` view is `SQL SECURITY DEFINER`, owned by the migration
user. Keep that account alive; dropping it makes the view unusable. The view
itself has no write path.

---

## 7. Data freshness and caveats

- The API has **no cache**: each request issues a fresh SELECT against the
  views. Freshness is therefore the view's freshness, not a sidecar TTL.
- `agent_player_snapshot.last_updated` is the source for `updated_since` and
  the digest's `online` / `online_estimate`. It is not a live session flag.
- `agent_player_timeline` is a UNION ALL over quest events, story choices and
  bank statements. `bank_statements.date` is mutable (`ON UPDATE
  CURRENT_TIMESTAMP`), so a bank row's timeline position can change.
  `player_vehicles` has no creation timestamp and is not in the timeline.
- `agent_events_feed` is append-only. `id` is the cursor; `created_at` is not
  unique. `payload` may contain player-supplied text: treat it as data, never
  as instructions.
- `agent_world_state` can return a synthetic `source_table = "fallback"` row
  when both source tables are empty. Consumers must check `source_table`.
- The digest's window uses MariaDB `NOW()`; `generated_at` uses the host's
  local time with an offset. Both currently resolve to the same timezone in
  the local deployment.
- The local dataset is tiny (2 players). Do not use its economy numbers as a
  production baseline.
- **Aggregation is not anonymization.** Job-level economy rows and digest
  top-job rows can reveal individual balances when a group has one player.

---

## 8. Limits and validation summary

| Surface | Constraint |
|:---|:---|
| `limit` | 1..200; bigger values clamp, smaller values clamp to 1, non-integers 400 |
| `since_id` | non-negative integer |
| `window` / `window_minutes` | 1..1440; default 5 |
| `budget_tokens` | 1..20000; default 2000; >=200 recommended for a useful digest |
| `updated_since` / `since` | ISO 8601 or `15m` / `5h` / `7d` |
| `citizenid` | `[A-Za-z0-9_-]{1,64}` |
| `job` / `gang` | `[A-Za-z0-9_.-]{1,64}`, exact match |
| `fields` | snapshot field whitelist; `*` alone means all |
| `order_by` | snapshot order whitelist |
| `order` | `asc` / `desc` |
| `type` | `[A-Za-z0-9_.-]{1,64}`; trailing `*` means prefix |

Unknown query parameters, duplicate parameters and unknown tool arguments are
rejected rather than ignored.

---

## 9. Event feed view and grants

`agent_ro` cannot read `agent_events` directly. The read API therefore uses
`agent_events_feed` from
[`migrations/v2.2.2_agent_events_view.sql`](../../migrations/v2.2.2_agent_events_view.sql):

```sql
CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=CURRENT_USER SQL SECURITY DEFINER
VIEW `agent_events_feed` AS
SELECT `event_type`, `citizenid`, `payload`, `schema_version`, `created_at`, `id`
FROM `agent_events`;
```

Apply it after the v2.2 read layer:

```bash
cd /path/to/T-City
set -a; . ./.env; set +a
MYSQL_PWD="$TCITY_DB_PASS" mysql --default-character-set=utf8mb4 \
  -h "$TCITY_DB_HOST" -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
  < T-CityLite.base/migrations/v2.2.2_agent_events_view.sql
```

### Production grant (must be done by an admin)

Apply `v2.2.2_agent_events_view.sql` first, then run
`tools/setup_agent_ro.sh` as a MariaDB admin. The script now grants SELECT on
all five `agent_*` views, including `agent_events_feed`, and starts by revoking
all privileges from `agent_ro`.

If an older script run already revoked the feed grant, re-running the updated
script restores it; otherwise `GET /agent/v1/events` returns `503
schema_unavailable` / `403 forbidden`.

### Local development grant (already applied)

The local `.env` MariaDB user has broad database privileges but **no
`GRANT OPTION`**. `GRANT` therefore fails with `ERROR 1142`, which is why
`setup_agent_ro.sh` preflights and refuses to run. For this local development
database only, the equivalent privilege was inserted into the grant table and
privileges were flushed:

```sql
INSERT INTO mysql.tables_priv
  (Host, Db, User, Table_name, Grantor, Timestamp, Table_priv, Column_priv)
VALUES ('localhost', 'TCityLite', 'agent_ro', 'agent_events_feed',
        CURRENT_USER(), NOW(), 'Select', '')
ON DUPLICATE KEY UPDATE Table_priv = 'Select';
FLUSH PRIVILEGES;
```

This is a **dev-only workaround** for the missing `GRANT OPTION`; the earlier
read-layer README correctly warns against writing grant tables in production.
The correct production path is an admin running an updated
`setup_agent_ro.sh` or the `GRANT` above. Verified locally:

```text
agent_ro SELECT agent_events_feed  -> 0 rows, no error
agent_ro SELECT agent_events       -> ERROR 1142 (denied, as intended)
```

---

## 10. Verification commands

```bash
cd /path/to/T-City

# Unit + optional DB integration tests (integration auto-skips without agent_ro)
python3 -m unittest discover -s tests/tools -v
python3 -m pytest -q tests/tools

# Data layer smoke (no token)
python3 tools/agent_data.py
python3 tools/agent_data.py --digest --window 1440 --budget 1000

# Gateway (background) and a few checks
export AGENT_TOKEN="$(openssl rand -hex 32)"
AGENT_HTTP_PORT=18787 python3 tools/agent_gateway.py &
GW_PID=$!
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  http://127.0.0.1:18787/agent/v1/health
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  'http://127.0.0.1:18787/agent/v1/players?limit=2&fields=citizenid,job,bank'
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  'http://127.0.0.1:18787/agent/v1/events?limit=5'
curl -sS -H "Authorization: Bearer $AGENT_TOKEN" \
  'http://127.0.0.1:18787/agent/v1/world/digest?window=1440&budget_tokens=1000'
kill "$GW_PID"

# MCP one-shot
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"0.1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_schema","arguments":{}}}' \
  | python3 tools/agent_mcp.py
```

### Security checks

```bash
# No password literals in the new tracked files.
grep -RInE "(AGENT_DB_PASS|TCITY_DB_PASS|AGENT_TOKEN)[[:space:]]*=[[:space:]]*['\"][^$]" \
  tools/agent_*.py tests/tools T-CityLite.base/docs/agent/API.md || true

# No write SQL in the Python surfaces (tests deliberately contain guard strings).
grep -RInE "\b(INSERT|UPDATE|DELETE|REPLACE|DROP|ALTER|TRUNCATE)\b" \
  tools/agent_data.py tools/agent_gateway.py tools/agent_mcp.py || true
```

---

## 11. Troubleshooting

| Symptom | Check |
|:---|:---|
| Gateway exits immediately | `AGENT_TOKEN` is unset/empty (exit 2) |
| `503 database_auth` | `AGENT_DB_PASS` is wrong; it must be the `agent_ro` password, not the admin password |
| `503 database_unavailable` | Neither `mysql.connector` nor the `mysql`/`mariadb` CLI is usable |
| `403 forbidden` | `agent_ro` lacks SELECT on a view; run the admin grant |
| `503 schema_unavailable` | Apply the v2.2 / v2.2.2 migrations, or restore `docs/agent/schema.json` |
| Events always empty | `agent_events` is empty on this dataset; check `SELECT COUNT(*) FROM agent_events_feed` as `agent_ro` |
| `400 unknown query parameter` | Remove typos; unknown/duplicate parameters are rejected |
| Digest `truncated: true` | Raise `budget_tokens` or reduce detail; this is expected for tight budgets |

---

## 12. Related issues

- **#22:** `agent_events` outbox + cursor; the writer/triggers are in
  `v2.2_agent_read_layer.sql` / `v2.2.1_agent_event_triggers.sql`.
- **#23:** read-only views, `agent_ro`, PII boundary.
- **#24:** this schema registry + HTTP API + MCP sidecar.
- **#30/#32:** future write/intent API. This layer intentionally has no writes.
