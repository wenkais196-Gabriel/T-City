# Agent Action Contract (`custom-director`, v1)

Server-side contract for agent-proposed game actions. This is a safe slice of
issues **#30 / #32**: proposals, previews, policy/budget, human approval for
risky actions and an audit row. Scope covers twenty-five actions: player-scoped
actions, three L2 world/presentation actions, the police dispatch/judicial
actions, and the test-only `police_run_e2e`. There is no LLM integration.
Adding the L2 actions, `teleport`, `spawn_vehicle`, `remove_item`,
`set_bucket`, `kick`, `revive`, `delete_vehicle`, `set_job_duty`,
`set_metadata`, `send_phone_message` and `police_run_e2e` did not change
`schema_version` (still `1`).

- **Resource:** `T-CityLite.base/resources/[custom]/custom-director` (server-only)
- **Migration:** `T-CityLite.base/migrations/v2.3_agent_actions.sql`
- **Table:** `agent_actions`
- **Denial migration:** `T-CityLite.base/migrations/v2.5_agent_denials.sql`
- **Denial table:** `agent_denials` (policy rejections; no parameter values)
- **Audience:** out-of-process Agent Hub, trusted server resources, approval UI
- **Schema version:** `1` (`GET /agent/v1/policy` → `schema_version: 1`)

---

## 1. Action matrix

| Action | Risk | Args | Status after propose | Approval | Execution |
|:---|:---|:---|:---|:---|:---|
| `notify` | L1 表现 | `citizenid`, `text`, `kind?` | `approved` → `executed` | none (policy only) | `Player.Functions.Notify` (or `QBCore:Notify`) |
| `announce` | L2 世界 | `message`, `kind?` | `pending_approval` | **always** | broadcast to `QBCore.Functions.GetPlayers()` via `Player.Functions.Notify(message, kind, 5000)`; `delivered` count, `0` is not a failure |
| `set_weather` | L2 世界 | `weather` | `pending_approval` | **always** | `exports['qb-weathersync']:setWeather(weather)` + `getWeatherState()` read-back |
| `set_time_of_day` | L2 世界 | `hour`, `minute?` | `pending_approval` | **always** | `setTime(hour, minute)` + `getTime()` read-back |
| `add_money` | L4 经济 | `citizenid`, `account`, `amount`, `reason` | `pending_approval` | **always** | `Player.Functions.AddMoney(account, amount, 'agent_action:<id>')` + delta verification |
| `start_quest` | L3 任务 | `citizenid`, `quest_id` | `pending_approval` | **always** | `exports['custom-quest']:TriggerQuest(source, quest_id)` |
| `set_job` | L3 职业 | `citizenid`, `job`, `grade?` | `pending_approval` | **always** | `Player.Functions.SetJob(job, grade)` + job/grade read-back verification |
| `set_job_duty` | L2 出勤 | `citizenid`, `onduty` | `pending_approval` | **always** | `Player.Functions.SetJobDuty(onduty)` + `PlayerData.job.onduty` read-back; `blast_radius = "single"` |
| `send_phone_message` | L2 消息 | `citizenid`, `message` | `pending_approval` | **always** | `exports['custom-phone']:SendSystemMessage(phone, message, 'City Services')`: persisted `phone_messages` row + `phone:client:newMessage`/`newNotification` to the online receiver; `blast_radius = "single"` |
| `set_metadata` | L3 属性 | `citizenid`, `key`, `value` | `pending_approval` | **always** | `Player.Functions.SetMetaData(key, value)` + numeric metadata read-back; whitelist `hunger`/`thirst`/`stress`/`armor` |
| `teleport` | L3 位置 | `citizenid`, `x`, `y`, `z`, `heading?` | `pending_approval` | **always** | `exports['custom-agent-client']:Execute(source, 'teleport', {x,y,z,heading}, 5000, {agent_id='director:<id>'})` + client ack |
| `spawn_vehicle` | L3 载具 | `citizenid`, `model`, `plate?` | `pending_approval` | **always** | server-side `CreateVehicleServerSetter` 1.5 m in front of the ped, bounded existence wait (2 s), optional plate write + read-back |
| `revive` | L3 医疗 | `citizenid` | `pending_approval` | **always** | `Player.Functions.SetMetaData('isdead'/'inlaststand', false)` + `TriggerClientEvent('hospital:client:Revive', source)` (pcall) + metadata read-back |
| `delete_vehicle` | L4 载具 | `citizenid`, `plate?` | `pending_approval` | **always** | only the vehicle the player is currently in (`GetVehiclePedIsIn`) → `DeleteEntity` (pcall) + bounded 1 s `DoesEntityExist` check; `compensation = "manual"` |
| `grant_item` | L4 物品 | `citizenid`, `item`, `amount`, `reason` | `pending_approval` | **always** | `Player.Functions.AddItem(item, amount)` + inventory delta verification |
| `remove_item` | L4 物品 | `citizenid`, `item`, `amount?`, `reason` | `pending_approval` | **always** | `Player.Functions.RemoveItem(item, amount)` + inventory delta verification; `compensation = "manual"` |
| `set_bucket` | L3 会话 | `citizenid`, `bucket` | `pending_approval` | **always** | `QBCore.Functions.SetPlayerBucket(source, bucket)` + `GetPlayerRoutingBucket` read-back; session-scoped |
| `police_assign_unit` | L2 调度 | `incident_id`, `citizenid` | `pending_approval` | **always** | `exports['custom-police']:AssignUnitSystem('action:<id>', incident_id, citizenid)`：写 `police_incident_units`、单位置为 `assigned`、审计 `actor_kind='agent'` |
| `police_jail_player` | L3 司法 | `citizenid`, `minutes`(1–120), `reason` | `pending_approval` | **always** | `exports['custom-police']:JailSystem(...)` → `custom-justice:Imprison` / qb-prison；写逮捕记录 + 审计 |
| `police_call_draft` | L2 调度 | `title`(3–120), `details?`, `code?`, `priority?`(1–4), `raw_text?`, `x/y/z?` | `pending_approval` | **always** | `exports['custom-police']:DraftCallSystem('action:<id>', params)`：写一行 `status='draft'` 的 call 卡（复用唯一写者 `insertIncidentRow`），审计 `incident.draft`；**不广播、不派 NPC、不上在勤看板**，由警员采纳后才变成 `open`。未知 code 降级为 `911`，priority 夹到 1–4 |
| `police_warrant_request` | L3 司法 | `citizenid`, `reason`(3–128) | `pending_approval` | **always** | `exports['custom-police']:RequestWarrantSystem('action:<id>', params)`：与 `RequestWarrant` 共用同一条 `police_warrants` INSERT，写 `status='requested'`、审计 `actor_kind='agent'`；**不批准、不 BOLO、不入狱** |
| `police_draft_report` | L2 文书 | `title`(3–160), `body`(3–4000), `citizenid?`, `incident_id?`, `case_id?` | `pending_approval` | **always** | `exports['custom-police']:DraftReportSystem('action:<id>', params)`：委托唯一写者 `PoliceRecords.InsertReport` 写一行 `status='draft'`、`kind='report'` 的报告，审计 `report.draft`；**不提交、不罚款、不带 BOLO、不生成证据** |
| `police_incident_create` | L1 调度 | `title`, `code?`, `priority?`, `details?` | `executed`（免审） | 否 | `exports['custom-police']:CreateIncidentSystem('action:<id>', params)`：写 `police_incidents`、审计 `actor_kind='agent'`、推送给在勤警员；`blast_radius = "single"`（无目标玩家） |
| `police_run_e2e` | L1 测试 | `suite?`（仅 `police_e2e`）, `timeout_s?` (30–180) | `executed`（免审） | 否 | `exports['custom-agent-ops']:RunTest(suite)` → `exports['custom-testing']:RunTestSuite` → `Test.run`；返回结构化 `{ok, suite, result}`，测试写/清 `E2E_*` 命名空间 |
| `kick` | L4 惩罚 | `citizenid`, `reason` | `pending_approval` | **always** | `QBCore.Functions.Kick(source, reason)` inside `pcall`; no offline read-back; `compensation = "manual"`, no undo |

`police_run_e2e` is L1 and has **no target player** (registered in
`WORLD_ACTIONS` so the player-online gate is skipped), but it is **test-only**:
the suite name is pinned to `police_e2e`, the action writes and cleans test rows
in `police_incidents` / `police_incident_units` / `police_units` /
`police_outbox` / `justice_sentences` under the `E2E_*` namespace, and it is
never a production police write path. A failing suite still ends as
`executed` with `result.ok = false`; only a missing `custom-agent-ops` /
`custom-testing` export or a thrown call becomes `failed` with
`execution_failed: ...`.

`police_incident_create` is L1 and has **no target player** (its `citizenid` is
absent, but it is registered player-scoped so the L1 auto-execute gate stays
valid); it is audited in `police_audit` as an agent action. Anything else is
rejected with `code: "unsupported_action"`.

The three L2 world actions (`announce`, `set_weather`, `set_time_of_day`) are
**world-scoped**: they have no `citizenid`, they are valid even while nobody is
online, and their `ACTIONS` metadata carries `blast_radius = "world"`.
`blast_radius` is exposed by `GET /agent/v1/policy` for those actions (`nil` for
player-scoped actions). L2 always means `requires_approval = true` and
`auto_execute = false`: a human approves every broadcast/weather/time change
before it runs. `set_job_duty` is also L2 but player-scoped
(`blast_radius = "single"`): it never auto-executes either. `send_phone_message`
is L2 as well, player-scoped (`blast_radius = "single"`), and always requires
human approval.

### 1.1 Argument normalization

| Field | Rule |
|:---|:---|
| `agent_id` | 1–64 chars, `[A-Za-z0-9_.:-]`, trimmed |
| `citizenid` | 1–11 chars, `[A-Za-z0-9_-]`, trimmed (matches `players.citizenid VARCHAR(11)`) |
| `idempotency_key` | 1–128 printable non-space chars, globally unique |
| `notify.text` | non-empty; ≤ `agent_actions_max_notify_chars` UTF-8 chars; C0 controls except tab/LF/CR rejected |
| `notify.kind` | `info` \| `success` \| `warning` \| `error` \| `primary`; default `info` |
| `announce.message` | non-empty; ≤ `agent_actions_max_announce_chars` UTF-8 chars (default `300`, clamped `1..2000`); C0 controls except tab/LF/CR rejected |
| `announce.kind` | same enum as `notify.kind`; default `info` |
| `set_weather.weather` | `EXTRASUNNY` \| `CLEAR` \| `CLOUDS` \| `SMOG` \| `FOGGY` \| `OVERCAST` \| `RAIN` \| `THUNDER` \| `CLEARING` \| `NEUTRAL` \| `SNOW` \| `BLIZZARD` \| `SNOWLIGHT` \| `XMAS` \| `HALLOWEEN`; case-insensitive, normalized to uppercase |
| `set_time_of_day.hour` | integer `0..23` |
| `set_time_of_day.minute` | optional integer `0..59`, default `0` |
| `add_money.account` | `cash` \| `bank` \| `crypto` |
| `add_money.amount` | finite whole number, 1..`agent_actions_max_money` |
| `add_money.reason` | 1–128 chars, no C0 controls |
| `start_quest.quest_id` | 1–64 chars, `[A-Za-z0-9_.:-]`; must exist in `GetQuestCatalog` |
| `set_job.job` | 1–64 chars, `[A-Za-z0-9_.-]`, lowercased; must exist in `QBCore.Shared.Jobs` |
| `set_job.grade` | optional integer `0..100`, default `0`; must exist in `jobs[job].grades` when that table is present |
| `set_job_duty.onduty` | boolean (no strings/numbers); the target must have a live `PlayerData.job` (`job_unavailable` otherwise) |
| `set_metadata.key` | `hunger` \| `thirst` \| `stress` \| `armor` only; `isdead`/`inlaststand`/`ishandcuffed` are not accepted |
| `set_metadata.value` | integer `0..100` (whole number; floats, NaN, ±inf and strings rejected) |
| `send_phone_message.message` | non-empty; 1–500 bytes (`#message`, the same rule as `custom-phone`'s callback, so multi-byte UTF-8 counts per byte); C0 controls rejected except LF (`\n`), so multi-line SMS is allowed; no trim |
| `police_run_e2e.suite` | optional; only `police_e2e`; defaults to `police_e2e` |
| `police_run_e2e.timeout_s` | optional integer `30..180`; recorded in preview/result, `police_e2e` itself has a 180 s hard timeout |
| `teleport.x` / `teleport.y` | finite number within `-4500..8500` (GTA map bounds; NaN/±inf rejected) |
| `teleport.z` | finite number within `-200..3000` (GTA map bounds; NaN/±inf rejected) |
| `teleport.heading` | optional finite number `0..360`; omitted when not supplied |
| `spawn_vehicle.model` | 1–64 chars, `[A-Za-z0-9_-]`, trimmed and lowercased; must resolve to a non-zero `GetHashKey` |
| `spawn_vehicle.plate` | optional, 1–8 chars, `[A-Z0-9]`, trimmed and uppercased |
| `delete_vehicle.plate` | optional, 1–8 chars, `[A-Z0-9]`, trimmed and uppercased; must match the current vehicle plate when supplied |
| `grant_item.item` | 1–64 chars, `[A-Za-z0-9_.:-]`; must exist in `QBCore.Shared.Items` |
| `grant_item.amount` | integer `1..agent_actions_max_item_amount` (default 50, clamped 1..1000) |
| `grant_item.reason` | 1–128 chars, no C0 controls |
| `remove_item.item` | 1–64 chars, `[A-Za-z0-9_.:-]`; must exist in `QBCore.Shared.Items` |
| `remove_item.amount` | optional integer `1..agent_actions_max_item_amount`; defaults to the configured cap (50 by default) |
| `remove_item.reason` | 1–128 chars, no C0 controls |
| `set_bucket.bucket` | integer `0..65535` |
| `kick.reason` | 1–128 chars, no C0 controls |
| `approver` | 1–64 chars, no C0 controls (e.g. `discord:alice`, `console`) |
| reject `reason` | optional, 1–255 chars |

Unknown keys inside `args` are dropped for `notify`, `add_money` and
`start_quest`, but rejected with `invalid_params` for `set_job`, `grant_item`,
`remove_item`, `set_bucket`, `kick`, `announce`, `set_weather`,
`set_time_of_day`, `teleport`, `spawn_vehicle`, `revive`, `delete_vehicle`,
`set_job_duty`, `set_metadata`, `send_phone_message`, `police_call_draft`, `police_warrant_request`, `police_draft_report` and `police_run_e2e`.
Unknown action types are rejected. There is no client-side validation path.

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

### 3.6 `announce`

```json
{
  "action_type": "announce",
  "risk": "L2",
  "requires_approval": true,
  "player_found": false,
  "length": 27,
  "kind": "warning",
  "preview": "Server restart in 5 minutes"
}
```

`length` is the UTF-8 length of `message`; `preview` is its first 40 UTF-8
characters. There is no `citizenid` or `player_source`: the broadcast is
resolved at execution time.

### 3.7 `set_weather`

```json
{
  "action_type": "set_weather",
  "risk": "L2",
  "requires_approval": true,
  "player_found": false,
  "weather": "RAIN",
  "before": "CLEAR"
}
```

`before` is the live `exports['qb-weathersync']:getWeatherState()` captured
while building the preview; it is omitted when the resource is unavailable.

### 3.8 `set_time_of_day`

```json
{
  "action_type": "set_time_of_day",
  "risk": "L2",
  "requires_approval": true,
  "player_found": false,
  "hour": 22,
  "minute": 30
}
```

No `before` is recorded: this slice does not read the weathersync clock back.

### 3.9 `teleport`

```json
{
  "action_type": "teleport",
  "risk": "L3",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "target": { "x": 300.0, "y": 400.0, "z": 20.0, "heading": 90.0 },
  "from": { "x": 10.5, "y": -20.25, "z": 30.0 }
}
```

`target.heading` is absent when the caller did not supply one. `from` is the
live `GetEntityCoords(GetPlayerPed(source))` captured while building context
(or absent when `GetPlayerPed` returns `0`, e.g. the player is still loading);
it is advisory and may be stale by approval time.

### 3.10 `spawn_vehicle`

```json
{
  "action_type": "spawn_vehicle",
  "risk": "L3",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "model": "sultan",
  "plate": "ABC123",
  "from": { "x": 10.5, "y": -20.25, "z": 30.0 }
}
```

`model` is the normalized lowercase model name. `plate` is omitted when the
caller did not supply one. `from` is the live
`GetEntityCoords(GetPlayerPed(source))` captured while building context (also
absent while the ped is `0`); the actual spawn point is recomputed at execution
time as 1.5 m in front of the ped.

### 3.11 `remove_item`

```json
{
  "action_type": "remove_item",
  "risk": "L4",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "item": "bread",
  "amount": 2,
  "reason": "confiscated",
  "before": 5
}
```

`before` is the current held quantity from `Player.Functions.GetItemByName(item)`
(`0` when the player holds none). It is omitted while the player is offline
(policy rejects that proposal with `player_not_found`). `amount` is the
normalized value after applying the `agent_actions_max_item_amount` cap.

### 3.12 `set_bucket`

```json
{
  "action_type": "set_bucket",
  "risk": "L3",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "bucket": 42,
  "from": 0
}
```

`from` is the current `GetPlayerRoutingBucket(source)` value, captured while
building context. It is omitted while the player is offline. Routing buckets
are **session state**: they are not persisted and reset when the player
reconnects.

### 3.13 `kick`

```json
{
  "action_type": "kick",
  "risk": "L4",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "reason": "cheating"
}
```

Kick is irreversible: there is no preview undo and no automatic restore. The
execution result records `kicked: true` once `QBCore.Functions.Kick` returns
without throwing.

### 3.14 `revive`

```json
{
  "action_type": "revive",
  "risk": "L3",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "metadata": { "isdead": true, "inlaststand": true }
}
```

`metadata` is read from the live `PlayerData.metadata` while building context.
`isdead` / `inlaststand` are omitted when the key is missing; the whole
`metadata` object is omitted while the player is offline (policy rejects that
proposal with `player_not_found`). It is advisory: the executor re-reads the
metadata after clearing it.

### 3.15 `delete_vehicle`

```json
{
  "action_type": "delete_vehicle",
  "risk": "L4",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "plate": "ABC123",
  "target": { "entity": 1234, "model": -12345, "plate": "ABC123" }
}
```

`plate` is omitted when the caller did not supply one. `target` is the live
vehicle captured with `GetVehiclePedIsIn(GetPlayerPed(source), false)` while
building context: `entity` is the vehicle handle, `model` is `GetEntityModel`
and `plate` is the whitespace-stripped uppercase plate. `target` is absent when
the player is on foot (policy rejects with `not_in_vehicle`). The caller can
never pass an arbitrary entity id.

### 3.16 `set_job_duty`

```json
{
  "action_type": "set_job_duty",
  "risk": "L2",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "onduty": true,
  "from": false
}
```

`from` is the current `PlayerData.job.onduty` boolean captured while building
context; it is omitted when the player has no job table (policy rejects that
proposal with `job_unavailable`). Approval recomputes the preview, so `from`
reflects the duty state at approval time.

### 3.17 `set_metadata`

```json
{
  "action_type": "set_metadata",
  "risk": "L3",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "key": "hunger",
  "value": 80,
  "from": 42
}
```

`from` is the current `PlayerData.metadata[key]` value captured while building
context; it is omitted when that key is absent. `key` is restricted to the
whitelist `hunger`, `thirst`, `stress` and `armor` (see §5.13); `isdead`,
`inlaststand` and `ishandcuffed` are deliberately rejected because they change
gameplay/authority state and must go through `revive` or a human operator.

### 3.18 `send_phone_message`

```json
{
  "action_type": "send_phone_message",
  "risk": "L2",
  "requires_approval": true,
  "citizenid": "ABC12345",
  "player_found": true,
  "player_source": 12,
  "length": 55,
  "preview": "Your vehicle has been impounded. Contact"
}
```

`preview` is the first 40 characters of `message` (UTF-8-safe truncation);
`length` is the full message length in bytes, the unit `custom-phone` enforces.
The preview never includes the target phone number: the phone is only read from
the live player during context building (§5.14).

### 3.19 `police_run_e2e`

```json
{
  "action_type": "police_run_e2e",
  "risk": "L1",
  "requires_approval": false,
  "player_found": false,
  "suite": "police_e2e",
  "timeout_s": 180,
  "test_namespace": "police_e2e",
  "writes_database": true
}
```

`player_found` is `false` because the action has no target player (it is in
`WORLD_ACTIONS`). `writes_database` is explicit so an approver/agent never
mistakes this for a read-only probe: the suite writes `E2E_*` test rows and
cleans them before returning. There is no `citizenid` and no player source.

---

## 4. Status lifecycle

```text
dry_run = true
  propose ──► proposed                         (terminal; no execution)

notify (dry_run = false)
  propose ──► approved ──► executed
                       └─► failed             (notify/AddMoney/quest execution error)

police_run_e2e (dry_run = false)
  propose ──► approved ──► executed             (suite failure keeps executed, result.ok=false)
                       └─► failed             (agent-ops/custom-testing unavailable)

add_money / start_quest / set_job / set_job_duty / set_metadata / grant_item / remove_item / set_bucket / kick / announce / set_weather / set_time_of_day / teleport / spawn_vehicle / revive / delete_vehicle (dry_run = false)
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

`X-Agent-Id` is a **self-declared label**. Set `agent_actions_agent_id` to pin
the identity server-side: the convar wins, a missing header is accepted, and a
conflicting header is rejected with `agent_id_mismatch` instead of being
trusted. Without it, a holder of the shared token can attribute rows to another
agent id or read that id's `/actions` rows.

### 5.6 Jobs and items

- `job` must exist in `QBCore.Shared.Jobs` at propose and approve time
  (`job_not_found` otherwise).
- If `jobs[job].grades` is present, `tostring(grade)` must be one of its keys
  (`grade_not_found` otherwise). Jobs without a `grades` table accept any
  in-range grade.
- `item` must exist in `QBCore.Shared.Items` at propose and approve time
  (`item_not_found` otherwise) for both `grant_item` and `remove_item`.
- `grant_item.amount` and `remove_item.amount` are capped by
  `agent_actions_max_item_amount` (default `50`, clamped `1..1000`).
  `remove_item.amount` defaults to that cap when omitted. Neither action
  consumes the `add_money` daily budget; there is no item budget in this slice.
- All three actions (`set_job`, `grant_item`, `remove_item`) require the target
  player to be online.

### 5.7 World and presentation actions

- `announce`, `set_weather` and `set_time_of_day` are **L2**, `blast_radius =
  "world"`: one approval changes what every connected player sees/hears. They
  never target a single player and work with zero players online.
- All three always require human approval (`pending_approval`), even when
  `dry_run` is false and regardless of the proposing agent.
- `announce.message` is capped by `agent_actions_max_announce_chars` (default
  `300`, clamped `1..2000`) and rejects C0 control characters except tab/LF/CR,
  matching `notify`.
- `set_weather` and `set_time_of_day` require
  `GetResourceState('qb-weathersync') == 'started'` at propose **and** approve
  time; otherwise the proposal is rejected with
  `weather_sync_unavailable` (a pending row is rejected at approval time).
- `set_weather.weather` is validated against the static enum above, not against
  a live resource config; the executor still verifies the applied state.
- `set_time_of_day` reads `getTime()` back after `setTime` and compares
  hour/minute; older weathersync builds without that export degrade to trusting
  the `setTime` return value with `result.verify_result = false`.
  `qb-weathersync.setTime` also freezes the clock as a side effect of that
  resource; this slice does not change that behaviour.
- An `announce` that reaches zero players is `executed` with
  `result.delivered = 0`; that is a normal result, not a failure.

### 5.8 Teleport / executor dependency

- `teleport` is **L3** and `blast_radius = "single"`: it moves exactly one
  player. Like every non-notify action it always goes through human approval.
- Propose **and** Approve require
  `GetResourceState('custom-agent-client') == 'started'`; otherwise policy
  rejects with `executor_unavailable` (a pending row is rejected at approval
  time).
- `x`/`y`/`z` are validated by `policy.lua` against the same GTA map bounds
  used by the effect channel, so an out-of-bounds or non-finite value never
  reaches `custom-agent-client`. `heading` is optional and must be `0..360`.
- Unknown fields are rejected (`invalid_params`); the only accepted keys are
  `citizenid`, `x`, `y`, `z` and `heading`.
- The executor can still refuse at dispatch time: effect channel disabled
  (`executor_disabled`), no `tcity:agent:ready` handshake
  (`handshake_missing`), target dropped (`player_offline`), or no client ack
  within 5 s (`timeout`). Those become execution failures; the director does
  not retry automatically.
- A dispatch must run on a coroutine (the HTTP request handler or a
  `CreateThread`). A caller outside a coroutine gets `not_yieldable` and no
  client event is sent.

### 5.9 Vehicles (`spawn_vehicle`)

- `spawn_vehicle` is **L3** and `blast_radius = "single"`: it spawns exactly one
  vehicle next to the target player. Like every non-notify action it always
  goes through human approval.
- Propose **and** Approve require the target player to be online
  (`player_not_found` otherwise). `model` must resolve through `GetHashKey` to a
  non-zero hash at propose and approve time; otherwise the proposal is rejected
  with `model_not_found`. Policy stays native-free: `main.lua` injects
  `ctx.model_hash`.
- Execution re-resolves the player and ped (`GetPlayerPed(source) == 0` →
  `player_offline`), captures `GetEntityCoords`/`GetEntityHeading`, and spawns
  1.5 m in front of the ped using `GetEntityForwardVector` (or at the same point
  when that native is unavailable).
- Vehicle creation uses server-side `CreateVehicleServerSetter(model,
  'automobile', x, y, z, heading)`; when that native is absent it falls back to
  `CreateVehicle(model, x, y, z, heading, true, false)`.
- **Bounded wait**: existence is polled for at most 2000 ms (`GetGameTimer`
  deadline). `QBCore.Functions.SpawnVehicle` is deliberately not used because
  its `while not DoesEntityExist(veh) do Wait(0) end` has no timeout. On timeout
  the entity is deleted (pcall) and the action fails with
  `vehicle_spawn_timeout`.
- Optional `plate` is written with `SetVehicleNumberPlateText` and read back
  with `GetVehicleNumberPlateText` (whitespace stripped); a mismatch fails with
  `verification_failed`. There is no automatic entity deletion on that path.
- `spawn_vehicle` itself does **not** hand over keys, change the routing
  bucket, or write `player_vehicles`; spawned vehicles are not persisted as
  owned vehicles. A bucket change requires the separate `set_bucket` action.

### 5.10 Buckets and kicks

- `set_bucket` is **L3** and `blast_radius = "single"`. `bucket` is an integer
  `0..65535`; the target must be online at propose and approve time
  (`player_not_found` otherwise). The executor calls
  `QBCore.Functions.SetPlayerBucket(source, bucket)` and reads the value back
  with `GetPlayerRoutingBucket(source)`; a mismatch is `verification_failed`.
  Buckets are **session-scoped**: nothing is written to the database and the
  bucket resets on reconnect. The audit `result.notes` says so explicitly.
- `kick` is **L4**, `blast_radius = "single"`, `compensation = "manual"` and has
  **no undo**. The target must be online. The executor calls
  `QBCore.Functions.Kick(source, reason)` inside `pcall`; a thrown call is
  `execution_failed`, otherwise the result is `{ kicked = true, reason }`.
  `DropPlayer` is asynchronous, so the executor deliberately does **not**
  require the player to be offline after the call.
- Neither action is reversible: there is no inverse action and no automatic
  re-bucket/reconnect.

### 5.11 Revive and vehicle deletion

- `revive` is **L3** and `blast_radius = "single"`. The target must be online at
  propose and approve time (`player_not_found` otherwise). There is no
  "must be dead" gate: reviving an already-alive player succeeds with a
  `before`/`after` of `false/false`.
- `revive` depends on `qb-ambulancejob`'s client handler
  (`hospital:client:Revive`) for the actual resurrection animation/health
  reset. The event is dispatched inside `pcall` and is **best-effort**: if
  ambulancejob is stopped, the metadata mutation still succeeds. The server
  `PlayerData.metadata.isdead` / `inlaststand` read-back is the authority.
- `delete_vehicle` is **L4**, `blast_radius = "single"` and
  `compensation = "manual"`. It only deletes the vehicle the target player is
  currently in; no entity id is accepted. The target must be online and in a
  vehicle at propose and approve time (`not_in_vehicle` otherwise). If `plate`
  is supplied it must match the current vehicle (`plate_mismatch`), and the
  executor re-checks it at execution time.
- Deletion is irreversible: the entity is removed, not impounded, not stored in
  `player_vehicles` and not regenerated by a garage. The only recovery is a
  garage/resource respawn outside this action.
- Unknown fields are rejected for both actions (`invalid_params`).

### 5.12 Approval matrix

| Action | Risk | Auto-execute | Human approval | Budget / cap |
|:---|:---|:---|:---|:---|
| `notify` | L1 | yes (policy only) | no | `max_notify_chars` |
| `announce` | L2 | no | **always** | `max_announce_chars`; `blast_radius = world` |
| `set_weather` | L2 | no | **always** | weathersync started + enum; `blast_radius = world` |
| `set_time_of_day` | L2 | no | **always** | weathersync started + `0..23` / `0..59`; `blast_radius = world` |
| `start_quest` | L3 | no | **always** | quest catalog |
| `set_job` | L3 | no | **always** | `QBCore.Shared.Jobs` + grades |
| `set_job_duty` | L2 | no | **always** | online player + live job table + boolean `onduty` + duty read-back |
| `send_phone_message` | L2 | no | **always** | online player + non-empty `charinfo.phone` + 1–500 byte message + `custom-phone` export returns `true, nil` |
| `set_metadata` | L3 | no | **always** | online player + key whitelist + integer `0..100` + metadata read-back |
| `teleport` | L3 | no | **always** | `custom-agent-client` started + map bounds + client ack (5 s) |
| `spawn_vehicle` | L3 | no | **always** | online player + non-zero model hash + bounded 2 s spawn wait |
| `revive` | L3 | no | **always** | online player + `isdead`/`inlaststand` metadata read-back; ambulancejob client event best-effort |
| `delete_vehicle` | L4 | no | **always** | online player in vehicle + optional plate match + entity-gone read-back; manual compensation |
| `remove_item` | L4 | no | **always** | `max_item_amount`; manual compensation |
| `set_bucket` | L3 | no | **always** | online player + `0..65535` + routing-bucket read-back; session-scoped |
| `kick` | L4 | no | **always** | online player + non-throwing `Kick`; irreversible |
| `add_money` | L4 | no | **always** | `max_money` + daily budget |
| `grant_item` | L4 | no | **always** | `max_item_amount` only |
| `police_run_e2e` | L1 | yes | no | only `police_e2e`; `timeout_s` 30–180; writes/cleans `E2E_*` test rows |

`blast_radius` is `world` only for the three L2 world actions; all other actions
are player-scoped (`teleport`, `spawn_vehicle`, `revive`, `delete_vehicle`,
`remove_item`, `set_bucket`, `kick`, `set_job_duty`, `set_metadata` and
`send_phone_message` set `single` explicitly). `police_run_e2e` has no target
player but also declares `single`: it only touches the `E2E_*` test namespace.
`agent_actions_enabled = 0` disables every action. A proposal rejected by
policy before persistence is not an approval-matrix exception: it never
executes.

### 5.13 Duty and metadata

- `set_job_duty` is **L2** but player-scoped (`blast_radius = "single"`); it is
  never auto-executed. The target must be online **and** have a live
  `PlayerData.job` table (`job_unavailable` otherwise, e.g. a partial player
  copy while loading). `onduty` must be a JSON boolean; strings and numbers are
  rejected with `invalid_params`. The executor calls
  `Player.Functions.SetJobDuty(onduty)` and reads `PlayerData.job.onduty` back;
  qb-core may only set `IsDirty` without a broadcast, so the read-back is the
  authority. A mismatch is `verification_failed`.
- `set_metadata` is **L3** and `blast_radius = "single"`. The target must be
  online. `key` is a fixed whitelist — `hunger`, `thirst`, `stress`, `armor` —
  and `value` must be an integer `0..100`. The whitelist deliberately excludes
  `isdead`, `inlaststand` and `ishandcuffed`: those flags decide whether a
  player is dead or restrained, so an agent-triggered flip would bypass
  `revive`/ambulancejob or police restraint and leave client/server state
  inconsistent. They stay operator-only. The executor calls
  `Player.Functions.SetMetaData(key, value)` and requires the numeric read-back
  `tonumber(PlayerData.metadata[key]) == value`; otherwise
  `verification_failed`. Unknown keys and unknown fields are rejected with
  `invalid_params`.
- Neither action has an inverse/undo in this slice; the audit `result.before`
  is the recovery reference.

### 5.14 Phone messages

- `send_phone_message` is **L2**, player-scoped (`blast_radius = "single"`),
  and always requires human approval; it never auto-executes.
- The target must be online at propose and approve time. `main.lua` injects
  `ctx.player.phone = PlayerData.charinfo.phone`; an absent or empty phone is a
  policy rejection with `phone_unavailable`. There is **no** fallback to
  `notify`: a player without a phone is refused, not silently pinged in-game.
- Delivery goes through a new server-only export,
  `exports['custom-phone']:SendSystemMessage(receiverNumber, message,
  senderLabel)`. That resource writes the `phone_messages` row and, when the
  receiver is online, emits `phone:client:newMessage` plus
  `phone:client:newNotification`. No net event or callback is registered for
  the export, so a client cannot invoke it.
- The sender is chosen by the director (`'City Services'`), never by a client
  or by the request body. `phone_messages.sender_number` stores that label
  rather than a number: the table has no foreign key, so a non-numeric system
  sender is allowed and is rendered as-is by the phone UI. The export strips
  control characters and caps the label at 32 chars; the default label fits the
  `VARCHAR(20)` column.
- Message bounds mirror `custom-phone`'s own callback exactly: 1–500 **bytes**
  (`#message`, so multi-byte UTF-8 counts per byte). C0 control characters are
  rejected except LF, so multi-line SMS is allowed (tabs and CR are not).
- The export itself validates the receiver number (1–15 chars) and the message
  (1–500 bytes) again: bad input is `false, 'invalid_params'` and a failing
  insert is `false, 'db_error'`.
- `custom-phone` returning `false, 'db_error'` (or any other non-nil code) is
  `execution_failed: <code>`; a thrown export, e.g. because `custom-phone` is
  not started, is `phone_unavailable`. A successful call requires the export's
  first return value to be `true` **and** its error slot to be `nil`.
- **The phone number is not audited.** `result` only contains
  `{ message_length, phone_masked, at }`, with `phone_masked` keeping the first
  3 and last 2 characters (`555-0100` → `555***00`); numbers of 5 chars or fewer
  are fully masked. The full number is never written to `result`, `error` or
  the console logs. The target citizenid remains in `params`/`preview` like
  every other player-scoped action.
- Unknown fields are rejected (`invalid_params`); the only accepted keys are
  `citizenid` and `message`.

### 5.15 Police E2E test runner

- `police_run_e2e` is **L1**, has no target player (it is listed in
  `WORLD_ACTIONS`), auto-executes, and is deliberately restricted to
  `suite = "police_e2e"`. It exists so an agent can run the real-server E2E and
  receive structured stats instead of scraping `/test run` console output.
- Execution is a two-hop server export chain:
  `exports['custom-agent-ops']:RunTest(suite)` →
  `exports['custom-testing']:RunTestSuite(suite, source)` →
  `Test.run(suite, source)`. `Test.run` is synchronous (its async cases wait
  internally), so the result is the completed run, not a ticket id.
- A suite assertion failure is a **successful execution** with
  `result.ok = false` and `result.result = {pass, fail, error, skip}`. Only a
  missing export/resource or a thrown call becomes `execution_failed`.
- The suite writes only the `E2E_*` test namespace and cleans it up (audit rows
  are retained). Running two `police_e2e` instances concurrently can delete each
  other's fixtures; serialize E2E runs. `timeout_s` (30–180) is recorded in the
  preview/result; the suite itself has a 180 s hard timeout.

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
| `action_type` | `notify` \| `announce` \| `set_weather` \| `set_time_of_day` \| `add_money` \| `start_quest` \| `set_job` \| `set_job_duty` \| `set_metadata` \| `teleport` \| `spawn_vehicle` \| `revive` \| `delete_vehicle` \| `grant_item` \| `remove_item` \| `set_bucket` \| `kick` \| `send_phone_message` \| `police_assign_unit` \| `police_jail_player` \| `police_call_draft` \| `police_warrant_request` \| `police_draft_report` \| `police_incident_create` \| `police_run_e2e` |
| `params` | Normalized JSON args (unknown fields dropped for legacy actions, rejected for the strict actions) |
| `status` | See §4 |
| `idempotency_key` | Caller key, unique |
| `preview` | Last computed preview JSON |
| `result` | Execution result JSON (balances/quest message/masked phone) or rejection reason |
| `error` | Short failure/rejection reason, ≤255 chars |
| `requested_at` | `DATETIME(3)` insert time |
| `approved_by` | Approver label, or `auto` for notify; `system:expired` on TTL |
| `approved_at` | Approval time |
| `executed_at` | Execution attempt completion time (also set on failure) |
| `expires_at` | Approval deadline (pending only) |

`params`/`preview`/`result` never contain tokens, licenses or IPs. Tokens are
not stored.

### 7.1 Policy denials (`agent_denials`)

A proposal rejected by policy is **not** written to `agent_actions`: its
idempotency key has to stay reusable after an operator raises a cap or the
player reconnects. The rejection is audited separately, in `agent_denials`
(migration [`v2.5_agent_denials.sql`](../../migrations/v2.5_agent_denials.sql)),
so an over-privileged request is never invisible:

- **When:** `Propose` fails `CheckPolicy`, or `Approve` fails the policy
  re-check (the world changed between propose and approve). Normalization
  failures (`invalid_params`, `invalid_account`, `unsupported_action`, and the
  per-action cap check that runs while normalizing) **are** denial rows too.
  Only failures before normalization runs (resource disabled, bad token, missing
  `X-Agent-Id`, bad idempotency key) return too early to be recorded.
- **Response unchanged:** the denial insert is best-effort (`pcall`, warning
  only) and never changes the response body, the status code or the idempotency
  semantics. A rejected proposal still gets no action id.

| Column | Content |
|:---|:---|
| `id` | Denial id |
| `agent_id` | Caller identity from `X-Agent-Id` / export argument |
| `action_type` | Denied action |
| `code` | Policy code (`daily_budget_exceeded`, `job_not_found`, `item_not_found`, `weather_sync_unavailable`, `player_not_found`, `phone_unavailable`, ...) |
| `message` | Policy message, ≤255 chars (may name a cap or a target label) |
| `param_keys` | Sorted, comma-separated parameter **names** only, ≤255 chars |
| `params_hash` | 64-bit djb2 of the normalized params JSON as 16 hex chars |
| `dry_run` | `1` when the denied proposal was a dry run |
| `created_at` | `DATETIME(3)` insert time |

**Privacy:** the params blob is never copied. Only the parameter names, a
non-reversible hash and the policy's own message are stored — no citizenid,
inventory count, reason text or full params object. The message is produced by
`policy.lua` and may repeat a cap, job, grade or plate from the request; it
never contains tokens. `param_keys` plus `params_hash` still let an operator
group identical attempts and see which fields a denied call carried. The denial
export is safe to feed to [`tools/agent_eval.py`](EVAL.md) via `--denials` to
compute `denial_rate`.

**Switch:** `agent_actions_denial_log` defaults to `1`; set it to `0` to stop
writing denial rows (the rejection response is identical either way). A failed
insert logs `[custom-director] DB insert failed: ...` and is otherwise ignored;
there is no retry and no extra query on the rejection path.

---

## 8. Execution and failure semantics

### `police_run_e2e`

1. Normalization already pinned `suite` to `police_e2e` and validated
   `timeout_s` (30–180).
2. Calls `exports['custom-agent-ops']:RunTest(suite)` inside `pcall`. That export
   calls `exports['custom-testing']:RunTestSuite(suite, source)`, which calls
   `Test.run` and returns `{ ok, suite, result }`.
3. Success `result` is `{ ok, suite, timeout_s?, result = {pass, fail, error,
   skip} }`. `ok=false` means the suite failed its assertions; the action is
   still `executed` because the runner completed.
4. A thrown export or an error table without runner stats becomes
   `execution_failed: <code>` and the row is `failed`.

### `notify`

- Resolves the online player by citizenid, uses
  `Player.Functions.Notify(text, kind, 5000)` with `QBCore:Notify` fallback.
- No delivery acknowledgement. If the call does not throw, the row becomes
  `executed`.

### `send_phone_message`

1. Re-resolves the online player and reads `PlayerData.charinfo.phone`; a
   missing/empty phone becomes `phone_unavailable`.
2. Calls `exports['custom-phone']:SendSystemMessage(phone, message,
   'City Services')` inside `pcall`.
3. Success requires `true, nil`; `false, <code>` becomes
   `execution_failed: <code>` and a thrown export becomes `phone_unavailable`
   (for example when `custom-phone` is stopped). There is no retry and no
   fallback to `notify`.
4. Success `result` is `{ message_length, phone_masked, at }`. The full phone
   number is deliberately never written to `result`, `error` or the console.

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

### `set_job_duty`

1. Re-resolve the online player and record
   `before = PlayerData.job.onduty`.
2. `Player.Functions.SetJobDuty(onduty)` inside `pcall`; a thrown call becomes
   `failed` (`execution_failed: SetJobDuty threw: ...`).
3. Read `PlayerData.job.onduty` back and require it to equal the requested
   boolean; otherwise `failed` with `verification_failed`.
4. Success `result` is `{ onduty, before, verify_result, at }`. No automatic
   restore of the previous duty state; `before` is the audit reference.

This is an L2 action but player-scoped: it never auto-executes, even if
`dry_run` is false. qb-core's `SetJobDuty` may only mark the player dirty without
a broadcast, so `PlayerData.job.onduty` is the verification authority.

### `set_metadata`

1. Re-resolve the online player and record `before = PlayerData.metadata[key]`.
2. `Player.Functions.SetMetaData(key, value)` inside `pcall`; a thrown call
   becomes `failed` (`execution_failed: SetMetaData threw: ...`).
3. Read `PlayerData.metadata[key]` back and require the numeric comparison
   `tonumber(after) == value`; otherwise `failed` with `verification_failed`.
4. Success `result` is `{ key, value, before, verify_result, at }`.

Only the `hunger`/`thirst`/`stress`/`armor` whitelist reaches this executor;
`isdead`/`inlaststand`/`ishandcuffed` are rejected during normalization (use
`revive` or a human operator). This is an L3 action: it never auto-executes,
even if `dry_run` is false, and there is no automatic restore of `before`.

### `teleport`

1. Re-resolve the online player and read `source = Player.PlayerData.source`.
2. Capture `from = GetEntityCoords(GetPlayerPed(source))` for the audit result;
   it is absent when the ped is `0` (loading/dropping).
3. Dispatch
   `exports['custom-agent-client']:Execute(source, 'teleport', { x, y, z,
   heading }, 5000, { agent_id = 'director:<id>' })`.
4. Success requires the export's first return value to be `true`. The success
   `result` is `{ ack, from, at }`: `ack` is the effect channel's result table
   (including its request id and client detail), `from` is the pre-dispatch
   position and `at` is the audit timestamp.
5. Failure mapping:
   - `executor_disabled` → `executor_disabled`;
   - `not_yieldable` → `not_yieldable: teleport must run inside a coroutine`;
   - `timeout`, `player_offline`, `handshake_missing`, `rate_limited`,
     `too_many_inflight`, `client_rejected`, `client_failed` and any other
     executor code → `execution_failed: <code>: <message>`;
   - a thrown export reference/call (resource or export missing) →
     `executor_unavailable`.

   Every failure marks the row `failed` with that text in `error` and
   `result.error`; no automatic retry is queued. The director does not verify
   the final position or interpret `ack.detail`; the client's `ok` ack is the
   authority for that leg. `custom-agent-client` must have
   `agent_effect_enabled = 1` and a live `tcity:agent:ready` session.

   In addition to the `custom-logs` line, every settled effect is written to
   `agent_effects` (migration
   [`v2.6_agent_effects.sql`](../../migrations/v2.6_agent_effects.sql)) when
   `agent_effect_audit` is not `0` (default `1`). The row holds only
   `request_id`, `agent_id`, `target_source`, `action`, terminal `status`
   (`ok`/`rejected`/`failed`/`cancelled`/`timeout`/`player_offline`/
   `executor_stopped`), a bounded `error_code` and `latency_ms`. It deliberately
   stores **no payload or free text**: notify body, `open_text_ui` title/body,
   phone numbers and all other parameter values never enter the table. The
   insert is best-effort — a missing table or DB error is logged (throttled)
   and never changes the effect result.

This is an L3 action: it never auto-executes, even if `dry_run` is false.

### `spawn_vehicle`

1. Re-resolve the online player and `source`; `GetPlayerPed(source)` returning
   `0` (loading/dropping) fails with `player_offline`.
2. Read `GetEntityCoords(ped)` and `GetEntityHeading(ped)`. The spawn point is
   shifted 1.5 m along `GetEntityForwardVector(ped)`; if that native is not
   available the vehicle spawns at the ped's exact position.
3. Create with
   `CreateVehicleServerSetter(model, 'automobile', x, y, z, heading)`, falling
   back to `CreateVehicle(model, x, y, z, heading, true, false)` when the
   server-setter native is absent.
4. Wait for existence with a hard deadline:
   `deadline = GetGameTimer() + 2000; while not DoesEntityExist(veh) and
   GetGameTimer() < deadline do Wait(0) end`. On timeout the entity is deleted
   inside `pcall` and the action fails with `vehicle_spawn_timeout` (the broker
   surfaces `execution_failed` with that text).
5. If `plate` was supplied, `SetVehicleNumberPlateText(veh, plate)` then compare
   `GetVehicleNumberPlateText(veh)` with whitespace stripped; a mismatch fails
   with `verification_failed` (the vehicle is left in place for operator
   review).
6. Success `result` is `{ entity, model, plate, coords = { x, y, z } }`.
   No keys, no bucket change and no `player_vehicles` row are produced.

This is an L3 action: it never auto-executes, even if `dry_run` is false.

### `revive`

1. Re-resolve the online player and `source`; record
   `before = { isdead, inlaststand }` from `PlayerData.metadata`.
2. `Player.Functions.SetMetaData('isdead', false)` and
   `SetMetaData('inlaststand', false)` inside `pcall`.
3. `TriggerClientEvent('hospital:client:Revive', source)` inside `pcall`. The
   event is best-effort: `qb-ambulancejob` may be stopped or its handler may
   throw, and the executor still continues to verification.
4. Read `PlayerData.metadata` back and require both values to be exactly
   `false`; otherwise `verification_failed`.
5. Success `result` is `{ before = { isdead, inlaststand },
   after = { isdead, inlaststand }, at }`.

This is an L3 action: it never auto-executes, and it depends on
`qb-ambulancejob`'s client event for the visual/health reset (the server
metadata is the verified state).

### `delete_vehicle`

1. Re-resolve the online player, `source` and ped (`GetPlayerPed(source) == 0`
   → `player_offline`).
2. `GetVehiclePedIsIn(ped, false)`; `0` → `not_in_vehicle`. There is no
   arbitrary entity-id parameter.
3. If `plate` was supplied, compare it with the current vehicle plate
   (whitespace stripped, uppercased); a mismatch → `plate_mismatch`. This
   re-check after approval prevents a stale/TOCTOU target.
4. `pcall(DeleteEntity, entity)`. `DeleteEntity` returns `nil` even on success,
   so its return value is ignored; only `DoesEntityExist` is trusted.
5. Poll `DoesEntityExist(entity)` for at most 1000 ms (`GetGameTimer`
   deadline). If it still exists, fail with `verification_failed`.
6. Success `result` is `{ entity, model, plate, at }`. The vehicle is gone from
   the world; it is not impounded or persisted as a garage vehicle.

This is an L4 action: it never auto-executes, its compensation is `manual`,
and the deletion is irreversible except for a garage/resource respawn.

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

### `remove_item`

1. Re-resolve the online player and record `before` from
   `Player.Functions.GetItemByName(item)` (`0` if none).
2. `Player.Functions.RemoveItem(item, amount)` (the player method, **not** the
   `exports['qb-inventory']:RemoveItem` export); a return other than `true`
   becomes `failed` (`execution_failed`).
3. Re-read the held quantity and require `before - after == amount`.
4. On mismatch, mark `failed` with a `verification_failed` message. **No
   automatic rollback**; operators use the audit row.

The success `result` contains `{ item, amount, before, after, reason,
verify_result }` (plus `at`). This is an L4 action: it never auto-executes and
its compensation is `manual` (the removed items are not re-granted silently).
Execution failures surface as `code: "execution_failed"` with the detailed
`verification_failed ...` / `execution_failed ...` text in `error` and
`result.error`.

### `set_bucket`

1. Re-resolve the online player and `source`; record
   `before = GetPlayerRoutingBucket(source)` (best-effort).
2. `QBCore.Functions.SetPlayerBucket(source, bucket)`; anything other than
   `true` becomes `failed` (`execution_failed`).
3. Read the native bucket back and require it to equal the requested bucket;
   otherwise `failed` with `verification_failed`.
4. Success `result` is `{ bucket, before, notes, verify_result, at }`. `notes`
   states that the routing bucket is session-scoped and resets on reconnect.
   There is no automatic restore of the previous bucket.

This is an L3 action: it never auto-executes, even if `dry_run` is false.

### `kick`

1. Re-resolve the online player and `source`.
2. Call `QBCore.Functions.Kick(source, reason)` inside `pcall`; a thrown call
   becomes `failed` (`execution_failed`).
3. A call that returns without throwing is success:
   `result = { kicked = true, reason, at }`. No "player is offline" read-back is
   performed: `DropPlayer` is asynchronous, so the player may still be online
   when the executor returns. There is no undo.

This is an L4 action: it never auto-executes, its compensation is `manual`, and
it is irreversible.

### `announce`

1. Calls `QBCore.Functions.GetPlayers()` and, for each source,
   `QBCore.Functions.GetPlayer(source).Functions.Notify(message, kind, 5000)`.
2. Counts successful notify calls as `result.delivered`. A player whose player
   object/Notify method is unavailable is skipped.
3. `delivered == 0` (nobody online) still marks the row `executed`; it is **not**
   an execution failure. If `GetPlayers()` itself throws, the row becomes
   `failed`.

### `set_weather`

1. Record `before = exports['qb-weathersync']:getWeatherState()` (best effort).
2. `exports['qb-weathersync']:setWeather(weather)`; anything other than `true`
   becomes `failed` (`execution_failed`).
3. Re-read `getWeatherState()` and require it to equal the requested uppercase
   weather; otherwise `failed` with `verification_failed`.
4. Success `result` is `{ weather, before, verify_result, at }`.

### `set_time_of_day`

1. `exports['qb-weathersync']:setTime(hour, minute)`; anything other than
   `true` becomes `failed` (`execution_failed`).
2. Reads `getTime()` back and compares hour/minute; a mismatch is
   `verification_failed`. If the export is absent (older weathersync), success
   `result` is `{ hour, minute, at }` with `verify_result = false`.

Both world-state actions require `qb-weathersync` to be `started` before the
approval is executed (re-checked in `Approve`); a stopped resource rejects the
pending row with `weather_sync_unavailable`.

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
| `job_unavailable` | 400 | Target player has no live `PlayerData.job` (`set_job_duty`) |
| `grade_not_found` | 400 | Grade not in `jobs[job].grades` |
| `item_not_found` | 400 | Item not in `QBCore.Shared.Items` |
| `text_too_long` | 400 | Notify/announce text over cap |
| `weather_sync_unavailable` | 400 | `qb-weathersync` is not started |
| `executor_unavailable` | 400 | `custom-agent-client` is not started (teleport) |
| `model_not_found` | 400 | `spawn_vehicle.model` hashes to `0` |
| `not_in_vehicle` | 400 | `delete_vehicle` target is not in a vehicle |
| `plate_mismatch` | 400 | `delete_vehicle.plate` does not match the current vehicle |
| `phone_unavailable` | 400 | `send_phone_message` target has no phone, or the `custom-phone` export threw |
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

Teleport dispatch failures (`executor_disabled`, `not_yieldable`, `timeout`,
`handshake_missing`, ...) are wrapped by the broker: HTTP callers see
`execution_failed` (409) with the executor code embedded in the `error` text.
At propose/approve time, a stopped `custom-agent-client` is a policy rejection
with `executor_unavailable`.

`spawn_vehicle` execution failures (`player_offline`, `vehicle_spawn_failed`,
`vehicle_spawn_timeout`, `verification_failed`) are wrapped the same way:
HTTP callers see `execution_failed` (409) and the specific code is in the
`error`/`result.error` text.

The same wrapping applies to `remove_item`, `set_bucket`, `kick`, `revive`,
`delete_vehicle`, `set_job_duty`, `set_metadata` and `send_phone_message`:
`execution_failed` (409) is returned, with `verification_failed ...`,
`execution_failed: RemoveItem ...`, `execution_failed: SetPlayerBucket ...`,
`execution_failed: Kick ...`, `execution_failed: SetJobDuty ...`,
`execution_failed: SetMetaData ...` or `execution_failed: db_error` in the
`error` text. `player_not_found` / `item_not_found` / `not_in_vehicle` /
`plate_mismatch` / `job_unavailable` / `phone_unavailable` remain policy
rejections before execution.

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
10. `add_money`, `start_quest`, `set_job`, `set_job_duty`, `set_metadata`,
    `grant_item`, `remove_item`, `set_bucket`, `kick`, `announce`,
    `set_weather`, `set_time_of_day`, `teleport`, `spawn_vehicle`, `revive`,
    `delete_vehicle` and `send_phone_message` always require
    `pending_approval`, regardless of the proposing agent.
11. `send_phone_message` reaches `custom-phone` only through a server-only
    export: no client-visible net event/callback exists for system SMS, and the
    sender label is chosen by the director, never by the request.
12. `police_run_e2e` is the only auto-executing write action besides `notify`
    and `police_incident_create`. It stays L1 because its suite is pinned to
    `police_e2e`, which writes only the `E2E_*` test namespace and cleans up;
    it cannot be pointed at a production suite or an arbitrary resource.

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
- World actions: `announce` counts per-player Notify calls; `set_weather`
  verifies with `getWeatherState()`; `set_time_of_day` verifies with
  `getTime()` (see §8). `AgentPolicy` (the
  registry) rejects a weather value before any resource call.

---

## 12. Out of scope / next slices

- Discord/Web approval UI, approval notifications.
- Per-agent rate limiting beyond FXServer's HTTP limiter (10/s, burst 25) and
  the daily money budget.
- Background TTL worker (currently lazy sweep on `List`/`Approve`).
- World-state/atmosphere/scene/NPC actions beyond `announce`, weather and time
  (L2+ from the design doc).
- Undo/rollback for money; compensation flows for quests, removed items,
  routing buckets and kicks. `remove_item` and `kick` are explicitly
  `compensation = "manual"`; `set_bucket` is `none`.
- Teleport position verification, bucket/combat/vehicle guards and named
  locations: this slice sends exact coordinates and trusts the client's `ok`
  ack; the full v2.1 teleport contract is still open.
- Vehicle keys, automatic bucket selection for `spawn_vehicle`,
  `player_vehicles` persistence and garage integration: this slice only creates
  the entity (and an optional plate) next to the player. Bucket changes require
  the explicit `set_bucket` action.
- LLM/Hub implementation; this resource only accepts proposals.
- Offline-player money operations (QB `GetPlayerByCitizenId` is online-only).
