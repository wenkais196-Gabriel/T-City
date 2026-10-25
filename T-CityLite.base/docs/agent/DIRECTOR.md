# Rule-Based Director Bridge (`custom-director`, v1)

Issue **#31** adds the smallest useful director loop on top of the #30/#32
action broker:

```text
observe agent_events -> match a rule -> AgentActions.Propose -> pending_approval
                                                                      |
                                                          human approves (L3)
                                                                      v
                                                     custom-quest TriggerQuest
```

It is deliberately **rules only**: no LLM, no generated content, no automatic
approval and no automatic execution. The bridge observes events, creates
proposals and stops. Every `start_quest` proposal is L3 and remains in
`pending_approval` until an operator approves it.

| Item | Value |
|:---|:---|
| Resource | `T-CityLite.base/resources/[custom]/custom-director` (server-only) |
| Migration | [`v2.3.1_agent_director.sql`](../../migrations/v2.3.1_agent_director.sql) |
| State table | `agent_director_state` |
| Event stream | `agent_events` (append-only, v2.2.1 triggers) |
| Audit table | `agent_actions` (v2.3) |
| Default | **disabled** (`agent_director_enabled = 0`) |

---

## 1. Flow and boundaries

```text
agent_events (id, event_type, citizenid, payload, created_at)
      |
      | SELECT ... WHERE id > cursor ORDER BY id LIMIT batch
      v
director_rules.lua   quest.completed -> follow-up quest (allowlist)
      |
      | AgentActions.Propose('director:rules', 'start_quest',
      |                      {citizenid, quest_id}, idempotency_key, false)
      v
agent_actions.status = pending_approval
      |
      | human: /agentapprove <id> (console / qbcore.god) or admin HTTP token
      v
AgentActions.Approve -> policy re-check -> custom-quest:TriggerQuest
```

Invariants:

1. **Server-side only.** No client script, NUI or HTTP input is involved in the
   poll loop. The existing HTTP API is unchanged and still requires tokens.
2. **Propose only.** `resources/[custom]/custom-director/server/director.lua` calls `AgentActions.Propose`. It has
   no approval or execution path, and it never calls `AgentActions.Approve`.
3. **Human approval for L3.** The broker's policy marks `start_quest` as L3
   with `requires_approval = true`; `dryRun = false` therefore persists
   `pending_approval`, never `approved`/`executed`.
4. **No LLM.** The target quest comes from a static allowlist. The same input
   always produces the same proposal.
5. **No policy duplication.** Validation, preview, online-player checks, quest
   catalog checks, idempotency and TTL all stay in
   `resources/[custom]/custom-director/server/policy.lua` +
   `resources/[custom]/custom-director/server/main.lua`.
6. **Bounded work.** Batch size, proposal count per tick and poll interval are
   clamped by convars.

### 1.1 Files

| File | Role |
|:---|:---|
| `resources/[custom]/custom-director/server/director_rules.lua` | Pure Lua rule table, payload extraction and idempotency-key format. No FiveM/DB dependency. |
| `resources/[custom]/custom-director/server/director.lua` | Cursor, poll loop, `Propose` calls, `RunOnce`/`GetState`/`Reset` exports. |
| `resources/[custom]/custom-director/server/main.lua` | Reused unchanged as the action broker. |
| `resources/[custom]/custom-director/server/policy.lua` | Reused unchanged as the policy/preview engine. |
| `tests/agent/test_director_rules.lua` | Standalone Lua tests. |
| `tests/unit/layer3_business/test_director_rules.py` | Pytest wrapper + static contract checks. |
| `resources/[custom]/tcity-e2e/config/scenarios/director_bridge.json` | Live observe -> propose scenario with a 120 s human window. |

---

## 2. Rule map

`DirectorRules.FOLLOW_UPS` maps a completed chapter-1 quest to its chapter-2
follow-up. The list is explicit; there is no "next chapter" naming convention.

| Completed quest | Target proposal | Included? | Why |
|:---|:---|:---|:---|
| `civilian_ch1_first_dollar` | `civilian_ch2_startup_struggle` | **yes** | Both require `role = 'civilian'`; the same civilian arc continues. |
| `police_ch1_first_shift` | `police_ch2_corruption_web` | **yes** | Both require `job = 'police'`; the same police arc continues. `ch2` also has `min_police = 1`, which is an environmental on-duty check enforced by `custom-quest` at approval time. |
| `cartel_ch1_first_blood` | `cartel_ch2_territory_war` | **no** | `ch1` requires `role = 'civilian'` while `ch2` requires `role = 'gang_member'` (`custom-career`: any non-`none` gang). A player who just completed `ch1` is not necessarily eligible for `ch2` until they join a gang, so this is not a reliable natural follow-up and the bridge does not guess. |

Additional notes:

- Only `quest.completed` participates. `quest.started`, `quest.step`,
  `quest.failed`, `story.choice`, `economy.*` and `vehicle.*` are skipped.
- The chapter-1 completion does **not** complete the story arc: `story-engine`
  marks an arc complete only on the chapter-4 finale
  (`resources/[custom]/story-engine/config/arc_finales.lua`).
  Therefore `story_arc` one-time gating does not reject the chapter-2 target.
- `police_ch2_corruption_web` cannot be blocked by a chapter-2 cooldown on a
  first playthrough; cooldowns are per quest and the target has never completed.
- `civilian_ch2_startup_struggle` has `cooldown_hours = 4`; again this only
  applies after that quest has been completed once.
- Approval-time conditions remain authoritative. If a target is not currently
  startable (player went offline, already has the quest, no police on duty,
  missing tags), `TriggerQuest` rejects and the failure is recorded on the
  `agent_actions` row.

---

## 3. Payload extraction and idempotency

`agent_events.payload` is a JSON object (`{quest_id, step_id, event_type,
metadata}`). `DirectorRules.extractCompletedQuest` accepts both shapes:

- a decoded Lua table (`payload.quest_id`);
- a JSON string, decoded with the FiveM `json` global when available, or with a
  narrow `"quest_id" : "..."` pattern fallback under plain Lua 5.4.

Malformed JSON, a missing `quest_id`, an empty string, `nil` and non-string
payloads return `nil` and are skipped.

The per-event key is:

```text
director:event:<agent_events.id>:<event_type>:<target_quest>
```

Example:

```text
director:event:42:quest.completed:civilian_ch2_startup_struggle
```

Properties:

- stable for the same event → replay is idempotent in `agent_actions`;
- unique per event id → one event can only create one follow-up proposal;
- different events produce different keys, even for the same quest (a second
  completion of chapter 1, e.g. after a reset, is a new observation);
- length stays under the broker's 128-character idempotency-key cap for all
  current quest ids;
- `nil`/empty arguments return `nil` rather than a malformed key.

See [ACTIONS.md §6](ACTIONS.md#6-idempotency) for the broker's same-key replay
and conflict semantics.

---

## 4. Cursor semantics

`agent_director_state` has one row (`name = 'agent_events'`) with:

| Column | Meaning |
|:---|:---|
| `name` | Event stream name; primary key. Currently always `agent_events`. |
| `cursor` | Highest `agent_events.id` fully handled in a committed batch. |
| `updated_at` | Last cursor write (`DATETIME(3)`). |
| `last_event_at` | `created_at` of the last consumed event, for operators. |

A tick:

1. Reads the cursor. If the migration has not run, `RunOnce` returns
   `error = "state_unavailable: ..."`; it never invents a cursor.
2. Runs `SELECT id, event_type, citizenid, payload, created_at FROM
   agent_events WHERE id > ? ORDER BY id LIMIT ?` with the clamped batch size
   (default 50, maximum 200).
3. Processes rows in ascending id order.
4. Stops **before** the next rule-producing event when
   `agent_director_max_proposals` successful proposals have been made. The
   cursor is advanced only to the last fully processed row; the remaining rows
   are picked up next tick. Non-rule rows at the front of a batch are consumed
   normally.
5. Advances the cursor with **one** `UPDATE agent_director_state SET cursor = ?,
   updated_at = NOW(3), last_event_at = ? WHERE name = 'agent_events' AND
   cursor < ?`. The `cursor < ?` guard prevents a stale writer from moving the
   cursor backwards.

### 4.1 Failures and cursor advancement

The bridge prefers forward progress over an infinite retry loop:

- A **policy rejection** (player offline, quest missing, not eligible) is not
  persisted by the broker. It is logged as `[director] policy rejected ...`,
  counted as `skipped`, and the event is consumed.
- A **transient broker failure** (`db_error`, `quest_catalog_unavailable`, a
  thrown exception) is logged as `[director] proposal failed ...` or
  `[director] proposal error ...`, counted as `errors`, and the cursor still
  advances with the batch.
- The cursor is **not** advanced when the state read, event query or cursor
  update fails.
- Because the idempotency key is derived from the event id, a manual replay or a
  cursor rollback cannot create duplicate `agent_actions` rows. An operator can
  recover a missed transient event by lowering the cursor in a maintenance
  window or by using the test-only `Reset()` export, then calling `RunOnce()`.

### 4.2 First enable

A fresh migration seeds `cursor = 0`. If `agent_events` already contains
history, the first enabled tick replays **all** historical `quest.completed`
events (subject to batch size and the proposal cap). This is intentional:
proposals still require human approval, so replay cannot mutate the game
without an operator. On a busy server, seed the cursor to the current
`MAX(id)` before enabling if a full replay is not desired:

```sql
UPDATE agent_director_state
SET `cursor` = (SELECT COALESCE(MAX(id), 0) FROM agent_events)
WHERE name = 'agent_events';
```

---

## 5. Configuration

All values are FiveM convars. The poll loop requires **both** kill switches:

| Convar | Default | Range | Meaning |
|:---|:---|:---|:---|
| `agent_director_enabled` | `0` | `1` enables | Director kill switch. Anything other than `1` disables `RunOnce` and prevents polling. |
| `agent_actions_enabled` | `0` | `1` enables | Broker kill switch; `Propose` returns `disabled` when off. Polling requires both. |
| `agent_director_interval` | `15` | 3–86400 s | Sleep between ticks. |
| `agent_director_batch` | `50` | 1–200 rows | Maximum `agent_events` rows read per tick. |
| `agent_director_max_proposals` | `5` | 1–200 | Successful proposals per tick; the remaining rows stay above the cursor. |

`RunOnce` also returns without doing work when either switch is off:

```json
{"processed":0,"proposed":0,"skipped":0,"errors":0,"cursor":0,"error":"disabled"}
```

Polling starts only when both switches are `1` at resource start. If either is
turned off while the loop is running, the loop stops on its next tick. Changing
a convar after startup requires a `custom-director` restart to start polling
again; `RunOnce` remains callable as an export for manual inspection.

The in-process poll does **not** need `agent_actions_token` or
`agent_actions_admin_token`. Those tokens only protect the HTTP surface. No
token is read, logged or persisted by the director.

Example (untracked local cfg; never commit tokens):

```cfg
set agent_actions_enabled "1"
set agent_director_enabled "1"
set agent_director_interval "15"
set agent_director_batch "50"
set agent_director_max_proposals "5"
```

**Do not edit `server.cfg` for this feature**; use your existing untracked local
overrides.

---

## 6. Approval path and why nothing auto-executes

`start_quest` is L3 in [`policy.lua`](<../../resources/[custom]/custom-director/server/policy.lua>):

```lua
start_quest = { risk = 'L3', requires_approval = true, auto_execute = false }
```

Consequences:

- `Propose(..., dryRun = false)` persists `pending_approval` with a TTL
  (`agent_actions_ttl_seconds`, default 900 s). It does not call
  `TriggerQuest`.
- A human approves with the existing admin path:
  - FXServer console: `/agentapprove <id>`;
  - player with `qbcore.god`: `/agentapprove <id>`;
  - or `POST /agent/v1/actions/<id>/approve` with the **admin** token.
- Approval re-runs argument validation, online-player resolution and policy
  (`quest_id` still exists in the catalog) before execution.
- Expired rows are rejected (`error = "expired"`), not auto-approved.
- The agent token cannot approve. The director does not hold any token.

This is the core safety property: the bridge can be wrong (a stale rule, a
replayed event, a player who went offline) without changing the game, because
the worst outcome is a pending row that a human rejects or ignores until TTL.

---

## 7. Install and migration

Apply the migration once (idempotent):

```bash
cd /path/to/T-City
set -a; . ./.env; set +a
MYSQL_PWD="$TCITY_DB_PASS" mysql -h "$TCITY_DB_HOST" -P "${TCITY_DB_PORT:-3306}" \
  -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
  < T-CityLite.base/migrations/v2.3.1_agent_director.sql
```

Verify without printing credentials:

```bash
MYSQL_PWD="$TCITY_DB_PASS" mysql -h "$TCITY_DB_HOST" -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
  -e "SHOW CREATE TABLE agent_director_state\G
      SELECT `name`, `cursor`, `updated_at`, `last_event_at`
        FROM agent_director_state WHERE name = 'agent_events';"
```

Expected seed row:

```text
name         cursor  updated_at                   last_event_at
agent_events 0       2026-...                      NULL
```

Dependencies: `v2.2_agent_read_layer.sql` (`agent_events`),
`v2.2.1_agent_event_triggers.sql` (quest triggers) and
`v2.3_agent_actions.sql` (`agent_actions`).

`custom-director` must already be ensured in the server config. This slice does
not edit `server.cfg` and does not restart FXServer by itself.

---

## 8. Tests

Pure rules (no DB/FXServer):

```bash
lua5.4 T-CityLite.base/tests/agent/test_director_rules.lua
```

Expected tail:

```text
[DIRECTOR-RULES-TEST] RESULT total=N failed=0
```

Pytest wrapper + static contracts:

```bash
cd T-CityLite.base
python3 -m pytest -q tests/unit/layer3_business/test_director_rules.py
```

Covered:

- civilian ch1 -> ch2 mapping;
- police ch1 -> ch2 mapping;
- cartel ch1 intentionally **not** mapped;
- unknown event type / unknown quest / malformed payload -> `nil`;
- payload as table, compact JSON string and whitespace JSON string;
- idempotency-key exact value, stability, per-event uniqueness, broker cap;
- `director.lua` contains `AgentActions.Propose` and no `Approve` call;
- migration columns/seed, manifest wiring, exports and scenario shape.

`luac5.4 -p` syntax check:

```bash
luac5.4 -p \
  "T-CityLite.base/resources/[custom]/custom-director/server/director_rules.lua" \
  "T-CityLite.base/resources/[custom]/custom-director/server/director.lua" \
  "T-CityLite.base/tests/agent/test_director_rules.lua"
```

---

## 9. Live observe -> propose -> approve test

The `tcity-e2e` scenario `director_bridge` drives a fake civilian through
chapter 1, then holds the fake player online for 120 s so a human can inspect
and approve the proposal. No runner change is needed; `wait` already supports
`ms` up to 600000.

Test environment only (use a local/untracked cfg or the console; do not commit
tokens and do not edit `server.cfg` if your workflow forbids it):

```cfg
setr tcity_e2e 1
setr tcity_e2e_scenario director_bridge
set agent_actions_enabled "1"
set agent_director_enabled "1"
set agent_director_interval "3"
set agent_director_batch "50"
set agent_director_max_proposals "5"
```

Ensure/restart `custom-director` and `tcity-e2e`. The runner waits 8 s, creates
the synthetic player, completes chapter 1 and enters the 120 s window.

During the window, inspect:

```sql
SELECT id, event_type, citizenid, JSON_EXTRACT(payload, '$.quest_id') AS quest_id,
       created_at
FROM agent_events
WHERE event_type = 'quest.completed'
ORDER BY id DESC LIMIT 5;

SELECT `name`, `cursor`, `updated_at`, `last_event_at`
FROM agent_director_state WHERE name = 'agent_events';

SELECT id, agent_id, action_type, status, idempotency_key, params, preview,
       requested_at, expires_at
FROM agent_actions
ORDER BY id DESC LIMIT 5;
```

Expected:

- `agent_director_state.cursor` reaches the `quest.completed` event id;
- `agent_actions` has a row with `agent_id = 'director:rules'`,
  `action_type = 'start_quest'`, `status = 'pending_approval'` and a key of the
  form `director:event:<id>:quest.completed:civilian_ch2_startup_struggle`;
- **no** row is auto-approved or executed by the bridge.

Approve while the fake player is still online:

```text
/agentapprove <id>
```

Then the row becomes `executed` (or `failed` with a concrete `error` if
`TriggerQuest` rejects the target) and `result` contains the quest message.

### Result (2026-10-21)

- `agent_director_state.cursor` advanced 0 -> 75; the same event was not
  re-proposed on later ticks.
- Exactly one `agent_actions` row was created:
  `agent_id=director:rules`, `start_quest`, `pending_approval`,
  key `director:event:75:quest.completed:civilian_ch2_startup_struggle`.
- Admin approval produced `status=executed`; `player_quests` showed
  `civilian_ch1_first_dollar=completed` and
  `civilian_ch2_startup_struggle=in_progress` at `step_city_hall`.
- The bridge never called `Approve`/`Execute`; the approval was human-triggered.

Two runtime fixes found during this live test:

- `agent_events.created_at` comes back as an ISO-8601 string with `T`/`Z` and
  surrounding quotes; it is normalized to MariaDB `DATETIME` before writing
  `last_event_at`.
- oxmysql can return an error **string** from `MySQL.query.await` without
  throwing; cursor updates now treat a string result as a failure instead of
  silently leaving the cursor at 0.

Important cleanup notes:

- When the scenario finishes, `tcity-e2e` deletes the synthetic player and its
  `agent_events`; the `agent_actions` audit row is **not** deleted (no FK).
- Approve/reject during the 120 s window. After cleanup the player is offline,
  so approval fails with `player_offline` and leaves a `failed` audit row.
- Remove the test convars and restart `custom-director` afterwards with the
  production switches (`0` by default).

Manual export smoke (from a trusted server resource or test harness):

```lua
local summary = exports['custom-director']:RunOnce()
-- {processed=N, proposed=N, skipped=N, errors=N, cursor=ID}
local state = exports['custom-director']:GetState()
local newState = exports['custom-director']:Reset() -- TEST ONLY; rewinds to 0
```

`Reset` rewinds the cursor; it does not delete `agent_actions` rows. Replayed
events return the existing action rows via idempotency.

---

## 10. Failure modes

| Situation | `RunOnce` result | Cursor |
|:---|:---|:---|
| `agent_director_enabled != 1` | `error = "disabled"` | unchanged |
| `agent_actions_enabled != 1` | `error = "agent_actions_disabled"` | unchanged |
| `agent_director_state` missing/unavailable | `errors = 1`, `error = "state_unavailable: ..."` | unchanged |
| event query fails | `errors = 1`, `error = "query_failed: ..."` | unchanged |
| event row has no usable id | `errors += 1`, `error = "invalid_event_id"`, stop batch | up to previous row |
| player offline at propose time | `skipped += 1`, `[director] policy rejected ... player_not_found` | advances |
| target quest absent from catalog | `skipped += 1`, policy rejection `quest_not_found` | advances |
| broker DB error / catalog unavailable | `errors += 1`, `[director] proposal failed ...` | advances |
| proposal succeeds | `proposed += 1`, `[director] proposed ...` | advances |
| cursor update fails | `errors += 1`, `error = "cursor_update_failed: ..."` | unchanged; replay is idempotent |

Summary shape:

```lua
{
    processed = 3,  -- rows consumed this tick
    proposed = 1,   -- AgentActions.Propose returned ok
    skipped = 2,    -- non-rule rows / policy rejections / missing citizenid
    errors = 0,     -- DB/query/transient/thrown failures
    cursor = 42,    -- committed cursor after the tick
    error = nil,    -- only set for fatal/guard conditions
}
```

---

## 11. Security invariants

1. Server-only resource; no client event/NUI path into the director.
2. No LLM output can reach `Propose`; only the static rule table and the
   event's `quest_id` do.
3. L3 proposals always require human approval; the director cannot approve.
4. The director cannot execute `start_quest`; execution stays in the broker's
   approve path.
5. Idempotency keys are event-derived, globally unique in `agent_actions`, and
   cannot be supplied by a client.
6. Batch/proposal/interval limits bound DB and broker load.
7. No credentials in code, logs, SQL or docs; the poll loop reads no tokens.
8. The director logs event ids and quest ids, not raw payloads or player PII.
9. Both kill switches are required; off is the default.
10. The cursor is a watermark, not an authorization: a stale/rewound cursor can
    only re-propose existing events, never auto-approve them.

---

## 12. Out of scope (next slices)

- LLM/Hub planners, scoring and beat selection.
- L1/L2/L4 actions and world-state changes.
- Automatic approval, Discord/Web approval UI.
- Rule config hot-reload (rules are compiled into `director_rules.lua`).
- Per-player fairness/cooldown deduplication across multiple events.
- Cleaning `agent_actions` rows created against synthetic e2e players.
- Backfill beyond the replay-from-0 behaviour described above.
