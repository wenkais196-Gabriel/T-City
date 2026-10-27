# Agent Read Layer (Phase 3 / P1)

Read-only database contract for agent tooling. It implements the read side of
GitHub issues **#22** (`agent_events` outbox + cursor) and **#23** (read-only
views, `agent_ro`, PII).

- **Schema contract version:** `1`
- **Database:** `TCityLite` (MariaDB 11.8)
- **Migration:** [`T-CityLite.base/migrations/v2.2_agent_read_layer.sql`](../../migrations/v2.2_agent_read_layer.sql)
- **Machine-readable schema:** [`schema.json`](schema.json)
- **Generator:** [`tools/agent_schema.py`](../../../tools/agent_schema.py)
- **Account setup:** [`tools/setup_agent_ro.sh`](../../../tools/setup_agent_ro.sh)

> **Issue #24 update:** the read-only HTTP API, MCP sidecar and the
> `agent_events_feed` view are documented in [`API.md`](API.md). The schema
> registry and `setup_agent_ro.sh` now include that fifth view.
>
> **Issues #30/#32 update:** server-side action proposals, previews, budget
> policy and human approval are documented in [`ACTIONS.md`](ACTIONS.md)
> (`custom-director`, table `agent_actions`).

> **Client harness:** Windows FiveM Legacy + MCP bridge, NUI test hooks and
> known input limitations are documented in [`CLIENT_HARNESS.md`](CLIENT_HARNESS.md).
>
> **Console driving:** this FXServer build has no RCON; `tcity-cmd` (screen stdin
> injection) and its four hard-won pitfalls are documented in [`CONSOLE.md`](CONSOLE.md).

Agents read through a small, stable set of views instead of joining 20+ game
tables. All access goes directly to MariaDB; it does not touch the FXServer
thread. Writes are deliberately out of scope for this layer.

---

## 1. What is exposed

| View | Grain | Columns |
|:---|:---|:---|
| `agent_player_snapshot` | one row per player | `citizenid`, `name`, `job`, `gang`, `cash`, `bank`, `crypto`, `firstname`, `lastname`, `last_updated`, `schema_version` |
| `agent_player_timeline` | one row per activity event | `citizenid`, `event_type`, `occurred_at`, `payload` (JSON), `source_table`, `schema_version` |
| `agent_world_state` | world-state row, event summary, or fallback | `region_id`, `state_key`, `state_value` (JSON), `changed_at`, `source_table`, `schema_version` |
| `agent_economy_metrics` | one row per job | `job`, `player_count`, `total_cash`, `total_bank`, `avg_bank`, `max_bank`, `schema_version` |

Every view carries a constant `schema_version = 1`. `schema.json` carries the
same version at the top level, so a consumer can detect a contract change before
parsing fields.

`agent_events` is the append-only write-side outbox for #22:

```text
id BIGINT AUTO_INCREMENT PK   -- cursor for since_id pagination
event_type VARCHAR(64)        -- quest.completed, story.choice, economy.transfer, ...
citizenid VARCHAR(11) NULL
payload LONGTEXT NULL         -- JSON object
schema_version SMALLINT DEFAULT 1
created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
INDEX (event_type, id), (citizenid, id), (created_at)
```

`agent_events` is intentionally **not** granted to `agent_ro`. The event feed is
meant to be served by the #22 helper/API, not read directly by the agent
account. This layer creates the table; it does not implement the writer or HTTP
endpoint.

### Local row counts (2026-10-21)

| View / table | Rows |
|:---|---:|
| `agent_player_snapshot` | 2 |
| `agent_player_timeline` | 48 (47 `quest_event_log` + 0 `player_choices` + 1 `bank_statements`) |
| `agent_world_state` | 1 (fallback: `world_state` and `world_events` are empty) |
| `agent_economy_metrics` | 2 |
| `agent_events` | 0 |

---

## 2. Security model

1. **Dedicated read-only account.** `agent_ro@localhost` gets `SELECT` on the
   five views only. It gets no privileges on `players`, `quest_event_log`,
   `bank_statements`, `world_*`, `agent_events`, or any other base table. It
   cannot `INSERT`, `UPDATE`, `DELETE`, `CREATE`, `DROP`, or grant.
2. **Views are `SQL SECURITY DEFINER`.** The views are owned by the migration
   user (`DEFINER=CURRENT_USER`) and run with that owner's privileges. This is
   why `agent_ro` can select a view without having `SELECT` on the base tables.
   Keep the definer account alive; dropping it makes the views unusable.
3. **PII removed at the boundary.** The snapshot excludes `license`,
   `identifier`, `position`, `inventory`, `metadata`, `phone`, and account
   `users`. `name`, `firstname`, and `lastname` are exposed because the agent
   needs a human-readable label, and they are marked `"pii": true` in
   `schema.json`. Treat them as personal data and do not forward them to third
   parties. `citizenid` is exposed as the stable join key: it is a QBCore
   character id, not the FiveM `license`/`identifier`, and it is not flagged PII.
4. **No credentials in tracked files.** The migration and docs contain no
   passwords. `tools/setup_agent_ro.sh` reads `AGENT_DB_PASS` from the
   environment or `.env`, generates one with `openssl rand -hex 24` if absent,
   writes it to `.env` (gitignored, mode `600`), and never echoes it.
5. **Append-only event table.** `agent_events` is written by the server-side
   helper only. There is no update/delete path in this layer; `id` is the
   monotonic cursor.
6. **Player text is untrusted data.** Timeline payloads can contain quest
   metadata, decision labels, or bank reasons derived from player input. Never
   interpret those strings as instructions to an LLM or shell.
7. **Aggregation is not anonymization.** `agent_economy_metrics` groups by job.
   A group with one player can reveal that player's balances. Apply a minimum
   group size before showing results outside the trusted agent.
8. **Tiny local dataset.** The current local DB has two players. Do not use its
   economy numbers as a production baseline.

### What is deliberately not exposed

- `license`, `cid`, `identifier`, `phone_number`, and `position`; `last_updated`
  history (only the single snapshot timestamp is exposed)
- `inventory`, `metadata`, `qualifications`, `certs`, `rank_tier`, `department`
- `players.money` raw JSON (only cash/bank/crypto are extracted)
- bank account `users` lists and account names in the snapshot
- `agent_events` (read API is a separate #22 deliverable)
- table DDL, write access, or the ability to create temporary tables

### Deliberate contract compromises

- **No per-player crypto table.** `players` has no `crypto` column; the local
  `crypto` table is a market-price table, not player holdings. The snapshot's
  `crypto` comes from `players.money.$.crypto`.
- **No vehicle creation timestamp.** `player_vehicles` has no `created_at` or
  `acquired_at` column, so vehicle acquisition cannot be placed on the timeline
  without inventing a time. It is omitted. If a timestamp is added later, add a
  fourth `UNION ALL` branch.
- **Timeline event names are namespaced, not remapped.** `quest_event_log`
  stores `advance` / `trigger` / `complete`; the view exposes
  `quest.advance`, `quest.trigger`, `quest.complete`. Use `agent_events` when
  you need the normalized names (`quest.completed`, etc.); the v2.2.1 triggers
  emit those.
- **Timeline `citizenid` can be NULL.** `bank_statements.citizenid` is nullable
  (job/shared accounts), so the timeline column is nullable. Filter by
  `citizenid` when a player-specific stream is required.
- **`bank_statements.date` can move.** It is a `TIMESTAMP ... ON UPDATE
  CURRENT_TIMESTAMP`, so updating a statement row can change its timeline
  position. Treat it as the best available bank-event time, not an immutable
  audit timestamp.
- **The timeline has no surrogate id.** Use `occurred_at` filters for the
  timeline; use `agent_events.id` when exact `since_id` pagination is required.
- **`agent_world_state` emits a fallback row.** While both `world_state` and
  `world_events` are empty, the view returns `source_table='fallback'`,
  `region_id='system'`, `state_key='no_data'`. Consumers must check
  `source_table` before treating a row as real world state.
- **No ordering guarantee.** SQL views do not guarantee row order. Always add
  `ORDER BY occurred_at` (timeline) or `ORDER BY changed_at` (world state).
- **MariaDB JSON is text.** `JSON_VALID` guards prevent malformed player JSON
  from breaking the views; invalid values become `0`/`NULL`, and an invalid
  `world_state.state_value` becomes `{"raw": <original text>}`.
- **Heterogeneous collations.** `quest_event_log` is `utf8mb4_unicode_ci` while
  `bank_statements`/`player_choices` are `utf8mb4_general_ci`. UNION branches
  explicitly normalize to `utf8mb4_unicode_ci`; do not remove those collation
  clauses.
- **View owner dependency.** `DEFINER=CURRENT_USER` avoids hard-coding a
  username, but production should use a dedicated, long-lived definer account.
  Avoid running the migration as a temporary admin.

---

## 2.1 Event writers (`v2.2.1_agent_event_triggers.sql`)

`agent_events` is fed by AFTER INSERT triggers on the tables that already carry
activity. This keeps the feed complete without editing every Lua service.

| Source table | `event_type` | Payload |
|:---|:---|:---|
| `quest_event_log` | `quest.started` / `quest.step` / `quest.completed` / `quest.failed` / `quest.abandoned` | quest_id, step_id, raw event_type, metadata |
| `player_choices` | `story.choice` | decision_id, chosen_option, arc_id, chapter |
| `bank_statements` | `economy.deposit` / `economy.withdraw` / `economy.transaction` | account_name, amount, reason, statement_type |
| `player_vehicles` | `vehicle.acquired` | plate, vehicle, garage |

Apply after the read layer:

```bash
MYSQL_PWD="$TCITY_DB_PASS" mysql -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
  < T-CityLite.base/migrations/v2.2.1_agent_event_triggers.sql
```

Notes:

- Triggers only `INSERT`; `agent_events` has no UPDATE/DELETE path.
- `payload.metadata` is embedded as a JSON object via inline `JSON_EXTRACT`
  (do not move it into a `LONGTEXT` variable, or MariaDB double-encodes it).
- `citizenid` is truncated to 11 chars to match the table contract.
- `agent_ro` is **not** granted `agent_events`; the event read API is a
  separate #22 deliverable.

---

## 3. Creating `agent_ro`

### Apply the migration first

```bash
cd /path/to/T-City
set -a; . ./.env; set +a
MYSQL_PWD="$TCITY_DB_PASS" mysql --default-character-set=utf8mb4 \
  -h "$TCITY_DB_HOST" -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
  < T-CityLite.base/migrations/v2.2_agent_read_layer.sql
```

The migration is idempotent: `CREATE TABLE IF NOT EXISTS` for `agent_events` and
`CREATE OR REPLACE VIEW` for every view. Re-running it is safe.

### Create the account

```bash
./tools/setup_agent_ro.sh
```

The account creator needs `GRANT OPTION`. A normal MariaDB root account has it.
If the `.env` user does not, the script fails before changing `.env` or the
account and prints:

```text
error: DB user '<user>' lacks GRANT OPTION; run this script as a MariaDB admin
```

To rotate the password intentionally, export a new value:

```bash
AGENT_DB_PASS="$(openssl rand -hex 24)" ./tools/setup_agent_ro.sh
```

The script is idempotent: it reuses the value already in `.env`, re-applies the
same grants, and rewrites only the `AGENT_DB_PASS` line in `.env`.

Verify the grants and the two negative cases:

```bash
set -a; . ./.env; set +a

# 1. Can read a view
MYSQL_PWD="$AGENT_DB_PASS" mysql -u agent_ro "$TCITY_DB_NAME" \
  -e "SELECT COUNT(*) FROM agent_player_snapshot;"

# 2. Cannot read the base table
MYSQL_PWD="$AGENT_DB_PASS" mysql -u agent_ro "$TCITY_DB_NAME" \
  -e "SELECT COUNT(*) FROM players;"          # expected: ERROR 1142
```

`SHOW GRANTS FOR 'agent_ro'@'localhost'` should list `SELECT` on exactly the
five views. If the local `.env` user cannot grant, ask an admin to run the setup
script. Do not work around it by writing to `mysql.tables_priv`.

### Regenerate the schema contract

```bash
set -a; . ./.env; set +a
python3 tools/agent_schema.py
```

The tool prefers the `mysql.connector` Python package and falls back to the
`mysql`/`mariadb` CLI. It reads `TCITY_DB_*` from the environment or `.env`,
introspects `information_schema.COLUMNS`, and writes
`T-CityLite.base/docs/agent/schema.json` atomically. PII is flagged for
`license`, `ip`, `identifier`, `position`, and display names
(`name`/`firstname`/`lastname`).

---

## 4. Sample queries

### 4.1 Player snapshot

```sql
-- One player
SELECT citizenid, name, job, gang, cash, bank, crypto,
       firstname, lastname, last_updated, schema_version
FROM agent_player_snapshot
WHERE citizenid = '<citizenid>';

-- Richest players (agent triage)
SELECT citizenid, name, job, bank, cash
FROM agent_player_snapshot
ORDER BY bank DESC
LIMIT 20;
```

### 4.2 Player timeline

```sql
-- Recent activity for one player
SELECT citizenid, event_type, occurred_at, source_table, payload
FROM agent_player_timeline
WHERE citizenid = '<citizenid>'
  AND occurred_at >= NOW() - INTERVAL 7 DAY
ORDER BY occurred_at DESC
LIMIT 100;

-- Quest progression only
SELECT citizenid, event_type, occurred_at,
       JSON_UNQUOTE(JSON_EXTRACT(payload, '$.quest_id')) AS quest_id,
       JSON_UNQUOTE(JSON_EXTRACT(payload, '$.step_id'))  AS step_id
FROM agent_player_timeline
WHERE source_table = 'quest_event_log'
  AND event_type IN ('quest.trigger', 'quest.advance', 'quest.complete')
ORDER BY occurred_at DESC
LIMIT 100;

-- Event-type distribution (last 24h)
SELECT event_type, source_table, COUNT(*) AS events
FROM agent_player_timeline
WHERE occurred_at >= NOW() - INTERVAL 1 DAY
GROUP BY event_type, source_table
ORDER BY events DESC;
```

### 4.3 World state

```sql
-- Real world state only (exclude the empty-table fallback)
SELECT region_id, state_key, state_value, changed_at, source_table
FROM agent_world_state
WHERE source_table <> 'fallback'
ORDER BY changed_at DESC
LIMIT 50;

-- World-event summary rows
SELECT region_id, state_key,
       JSON_UNQUOTE(JSON_EXTRACT(state_value, '$.event_count')) AS event_count,
       changed_at
FROM agent_world_state
WHERE source_table = 'world_events'
ORDER BY changed_at DESC;

-- Did we get the fallback?
SELECT region_id, state_key, state_value, source_table
FROM agent_world_state
WHERE source_table = 'fallback';
```

### 4.4 Economy metrics

```sql
-- Job-level economy overview
SELECT job, player_count, total_cash, total_bank, avg_bank, max_bank
FROM agent_economy_metrics
ORDER BY total_bank DESC;

-- Police economy only
SELECT *
FROM agent_economy_metrics
WHERE job = 'police';
```

### 4.5 Event cursor (server-side / future #22 API, not `agent_ro`)

```sql
-- Only an account with SELECT on agent_events can run this.
SELECT id, event_type, citizenid, payload, schema_version, created_at
FROM agent_events
WHERE id > 0
  AND event_type IN ('quest.completed', 'story.choice')
ORDER BY id
LIMIT 200;
```

Pagination rule for #22: `WHERE id > :since_id ORDER BY id ASC LIMIT :limit` and
return `next_since_id` as the last emitted `id`. Do not use `created_at` as the
cursor; multiple events can share a millisecond.

---

## 5. Verification performed

```bash
# Migration (idempotent; exit 0 on repeat runs)
mysql ... < T-CityLite.base/migrations/v2.2_agent_read_layer.sql

# Row counts + sample rows
for v in agent_player_snapshot agent_player_timeline \
         agent_world_state agent_economy_metrics; do
  mysql ... -e "SELECT COUNT(*) FROM \`$v\`; SELECT * FROM \`$v\` LIMIT 5;"
done

# Contract generation
python3 tools/agent_schema.py
```

Observed on 2026-10-21:

```text
agent_player_snapshot   2
agent_player_timeline  48
agent_world_state       1   (fallback)
agent_economy_metrics   2
agent_events            0
```

`tools/setup_agent_ro.sh` could not complete against the local `.env` account
because that MariaDB user has `CREATE USER` but not `GRANT OPTION`
(`ERROR 1142`). The script now preflights this and exits with an actionable
message. Account creation must be run by a MariaDB admin; all view validation
above was performed with the normal `.env` credentials.

---

## 6. Related issues / next steps

- **#22:** implement the server-side `agent_events` writer (quest.completed,
  quest.step, story.choice, economy.transfer, player.login) and the
  `GET /agent/v1/events?since_id=&type=&limit=` endpoint. This layer only creates
  the table.
- **#23 follow-up:** run `tools/setup_agent_ro.sh` as an admin, then add the
  negative-access test (`players` must be denied) to CI.
- **#24:** schema registry + read-only HTTP API + MCP sidecar are implemented;
  see [`API.md`](API.md), `tools/agent_gateway.py` and `tools/agent_mcp.py`.
- Future: if `player_vehicles` gains a creation timestamp, add a vehicle branch
  to `agent_player_timeline`. If a per-player crypto ledger is added, replace
  `players.money.$.crypto` with that authoritative source.

---

## 7. Agent 接管栈（2026-10）

读层之上又叠了四层，文档分别如下：

| 文档 | 内容 |
|---|---|
| [`STATUS.md`](STATUS.md) | **先看这个**：分层现状、17 个动作覆盖、设计差异、上手顺序、未验证项 |
| [`ACTIONS.md`](ACTIONS.md) | 动作契约：风险分级、参数规范化、审批、执行与回读、错误码、`agent_denials` |
| [`TOOLS.md`](TOOLS.md) | 30 个工具的路由与风险表（由 `tools/agent_tools.json` 生成，勿手改） |
| [`EVAL.md`](EVAL.md) | 评测：导出、指标定义（含 denial_rate）、已知盲区 |
| [`SMOKE.md`](SMOKE.md) | 实机冒烟：三段式检查与常见失败 |
| [`design/`](design/) | 五份设计（实时感知 / 效果通道 / 工具契约 / 写操作 / 测试评测） |

实机验证顺序：建表（`v2.3`、`v2.5`）→ 开 convar → `tools/agent_smoke.py` → 导出审计 → `tools/agent_eval.py`。
