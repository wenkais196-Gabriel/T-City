# 04 — 写操作扩展 v2：15 个动作与治理闭环

> 状态：**Draft for build**（P0 可直接施工；teleport 延后到 v2.1）
> 范围：`custom-director` 的 action registry、执行器、审批、预算、熔断、审计
> 前置：[08 §5](../../../../docs/server-design/08-agent-director.md)（L0–L4）、[03](03-tool-contract.md)（工具面/envelope/审批）、[ACTIONS.md](../ACTIONS.md)
> 不改变：写不走 DB；client 不可信；L3/L4 永远人审；agent token 无审批权

## 0. 结论（施工口径）

1. **15 个在册动作**（含 v1 的 `notify`/`add_money`/`start_quest`），`teleport` 只登记不实现。
2. `policy.lua` 从 if-chain 改为 **per-action 声明**（`risk/approval/channel/compensation/normalize/check`）；副作用 `execute/verify/inverse` 放 `server/executors.lua`，保持 policy 纯函数、可 `lua5.4` 单测。
3. **inverse 在执行时捕获**（不是提案时），存 `inverse_params`；L4 一律 `manual`，不自动回滚钱（对齐 03 §6）。
4. 批量只支持 `saga`/`best_effort`，**明确拒绝 `all_or_nothing`**；部分失败返回 `partial_success` + 补偿明细。
5. 预算升级为 `agent_action_limits`；熔断落 `agent_circuit_breaker`；审计同时写 `agent_actions` 与 `agent_events`。
6. 金额动作统一走 `MoneyGuard`：**stale 校验 + 执行后 delta 校验**；不匹配即 `failed`，不自动重试、不自动回滚。

---

## 1. 代码基线（只列影响施工的事实）

| 事实 | 位置 | 约束 |
|:---|:---|:---|
| `ACTIONS` 只有 3 项、无 risk 之外的元数据；`Normalize/Preview/CheckPolicy` 是三段 if-chain | `policy.lua:17-33, 189-286, 332-466` | 重构为声明式，保持函数签名可测 |
| `Propose` 先 policy 后落库；policy 拒绝不落行；L1 落库后立即执行 | `main.lua:478-637` | 沿用“拒绝不落库、键可复用” |
| `executeAddMoney` 已做 DB before/after 校验（0.001），**不自动回滚** | `main.lua:330-391`（校验 376-381） | 抽成 `MoneyGuard` 供三种金额动作共用 |
| `agent_actions` 已有 `agent_id`，缺 `batch_id/step_index/inverse_of/verify_result/target_citizenid/risk` | `v2.3_agent_actions.sql:21-42` | v2.4 必须 ALTER（§7） |
| `SetJob` 返回 bool；写 DirtyFlush `job` 并广播事件。`SetJobDuty` 只置 `IsDirty`；`SetMetaData` 对 `hunger/thirst` **不标 dirty** | `player.lua:188-233, 291-297, 308-323` | 执行后必须重读验真；duty 与 hunger/thirst 要 `Save(true)` |
| `AddMoney` 路由 `Bus.EconomyService`；`RemoveMoney` 受 `DontAllowMinus`(cash/crypto)/`MinusLimit(-5000)`；`SetMoney` 过 `SecurityService`（单笔 5,000,000） | `player.lua:357-436`；`security_service.lua:19,166-199` | inverse remove 可能因已消费失败；set_money 仍可能被拒 |
| 发物品是 `player.Functions.AddItem(item, amount, slot, info, reason)`（qb-inventory 注册） | `qb-inventory/server/main.lua:70-80`；`functions.lua:707,810` | **不要**用 `exports['qb-core']:AddItem`——那是物品定义注册（`exports.lua:126-143`） |
| phone 只有客户端回调 `phone:server:sendMessage`，无服务端推送；复活是服务端触发客户端 `hospital:client:Revive` → 客户端回写 metadata | `custom-phone/server/main.lua:312-358`；`qb-ambulancejob/server/main.lua:254-292` | 两者都是 client 通道，必须以服务端状态验真 |
| 车库用 `CreateVehicleServerSetter`；`QBCore.Functions.SpawnVehicle` 含无超时 `while Wait(0)` | `qb-garages/server/main.lua:137-171`；`qb-core/server/functions.lua:362-377` | spawn 必须自己 create + 2s 超时 |
| `SetPlayerBucket` 设 `state.instance` + routing bucket，无持久化 | `qb-core/server/functions.lua:294-307` | 重连即失效，inverse 只在会话内有效 |
| `agent_events` 只有 story-engine 与 SQL 触发器在写，无 action 事件 | `story-engine/server/main.lua:124`；`v2.2_agent_read_layer.sql:44-69` | 新增 writer 与 `agent.action.*` |
| 03 已定：L1 自动；L2 默认审批（`l2_auto=1` 且有 undo 才自动）；L3/L4 永远 pending | `03-tool-contract.md:16-17,150-152` | 审批矩阵必须一致，不得放宽 |

---

## 2. 动作清单（15 在册 + 1 延后）

| # | 动作 | 风险 | 通道 | 审批 | QBCore / 依赖 API | 参数范围 | 主要失败码 | 可逆性 |
|:-:|:---|:---|:---|:---|:---|:---|:---|:---|
| 1 | `notify` | L1 | server | 自动 | `Player.Functions.Notify(text, kind, 5000)` | text 1–300；kind ∈ 5 值 | `player_offline` `text_too_long` | 无 |
| 2 | `send_phone_message` | L1 | server→phone | 自动 | 新 export `custom-phone:SendSystemMessage(cid, sender, text)` | text 1–300；sender=`T-CITY` | `phone_unavailable` | 无 |
| 3 | `set_job_duty` | L2 | server | 默认人审，`l2_auto=1` 可自动 | `Player.Functions.SetJobDuty(bool)` | bool；同玩家 5 分钟冷却 | `invalid_job` | 精确 |
| 4 | `set_bucket` | L2 | server | 默认人审，`l2_auto=1` 可自动 | `SetPlayerBucket` + `GetPlayersInBucket` | 1000–1999；TTL≤900s；桶内仅本人 | `bucket_occupied` | 精确 |
| 5 | `add_item` | L3 | server | **永远** | `player.Functions.AddItem(item, amount, false, info, reason)` | item 存在；1–5；类目白名单 | `item_not_found` `inventory_full` `item_verification_failed` | 有损 |
| 6 | `remove_item` | L3 | server | **永远** | `player.Functions.RemoveItem(item, amount, slot, reason)` | 1–5；数量足够 | `insufficient_items` `quest_item_protected` | 有损 |
| 7 | `set_metadata` | L3 | server | **永远** | `Player.Functions.SetMetaData(field, value)` | 仅 4 字段，0–100 | `forbidden_metadata` | 精确 |
| 8 | `revive` | L3 | server→client | **永远** | `hospital:client:Revive` + 验 `isdead=false` | 目标 dead/laststand；`injail==0` | `not_dead` `player_in_jail` `revive_timeout` | 无 |
| 9 | `spawn_vehicle` | L3 | server | **永远** | `CreateVehicleServerSetter` + 车牌 | 车型白名单；≤50m；TTL600s；同时 1 辆 | `model_invalid` `spawn_timeout` | 精确 |
| 10 | `delete_vehicle` | L3 | server | **永远** | 临时车 `DeleteEntity`；自有车软删 `state=2` | 车牌存在；自有车须 owner | `vehicle_not_found` `vehicle_occupied` | 有损 |
| 11 | `start_quest` | L3 | server | **永远** | `exports['custom-quest']:TriggerQuest` | catalog id；未在进行中 | `quest_not_found` `quest_active` | 有损 |
| 12 | `set_job` | L4 | server | **永远**（dual 可选） | `Player.Functions.SetJob(job, grade)` | `QBShared.Jobs` + 该 job 的 grades | `job_not_found` `grade_not_found` `security_rejected` | 有损 |
| 13 | `add_money` | L4 | server | **永远** | `Player.Functions.AddMoney` | 1..`max_money`(1000) | `account_unavailable` `daily_budget_exceeded` `delta_mismatch` | 有损 |
| 14 | `set_money` | L4 | server | **永远 + 双人** | `Player.Functions.SetMoney` | `0..max_set_money`；`|Δ|≤max_delta`；before 未变 | `stale_preview` `delta_cap_exceeded` `security_blocked` | 有损 |
| 15 | `kick` | L4 | server | **永远 + 双人** | `QBCore.Functions.Kick` → `DropPlayer` | reason 1–128；同玩家 24h≤1 次 | `player_offline` `drop_unconfirmed` | 无 |
| 16 | `teleport`（v2.1） | L3 | **client+ack** | **永远** | `SetEntityCoords` + 客户端 `teleport:ack` | 仅命名地点；脱战；跨桶须同时改 bucket | `no_ack` `out_of_bounds` `in_combat` | 精确 |

### 2.1 逐项要点（只写非显然部分）

- **`send_phone_message`**：先在 `custom-phone` 加服务端 export（写 `phone_messages` + 在线端推送）；不存在返回 `phone_unavailable`，**不允许**静默降级成 notify。
- **`add_item`**：`CanAddItem` 只降失败率，不能替代执行后校验；用 `exports['qb-inventory']:GetItemCount(src,item)` 做 before/after，差值必须等于 amount。武器/毒品/钱类不在自动白名单（但仍走 L3 人审）。
- **`remove_item`**：`item.info.quest_id` 存在即拒（防破坏任务链）；快照 `{slot, amount, info}` 存 `inverse_params`，恢复优先原 slot，占用则任意空位。
- **`set_metadata`**：禁止 `isdead/inlaststand/ishandcuffed/injail/licences/qualifications/criminalrecord/rep`；`hunger/thirst` 改后必须 `Save(true)`。
- **`revive`**：触发客户端事件后轮询服务端 metadata ≤2s，超时 `revive_timeout`；`injail>0` 拒绝；不回血包、不收钱。
- **`spawn_vehicle`**：不用 QB 的 `SpawnVehicle`；`CreateVehicleServerSetter` + 2s 超时；临时车不写 `player_vehicles`，内存表 `AgentTempVehicles[actionId]={netId,plate,expires}`；上车 TTL 延一次（+300s），到期前 30s warning。
- **`delete_vehicle`**：自有车永不 `DELETE`，软删 `state=2, garage='impound', depotprice=300`（0 在外/1 车库/2 扣押）；临时车才 `DeleteEntity`；玩家在车内 → `vehicle_occupied`，不强制拖出。
- **`set_bucket`**：1000–1999 为 agent 保留段；进桶前 `GetPlayersInBucket` 必须空或仅目标；TTL 到期自动回原桶。
- **`kick`**：只踢不 ban；reason 会展示给玩家；依赖 `playerDropped` 5s 验真，超时 `drop_unconfirmed`，不自动重踢。
- **`set_money`**：`before == preview.before`、`|Δ|≤max_delta`、双人、永不自动、无自动 inverse；审批页必须显示 before/target/delta。
- **`teleport`**：v2 不实现；服务端 `SetEntityCoords` 会被客户端/桶/载具状态打回，无 ack 无法验真；v2.1 先定 ack 与脱战契约。

---

## 3. inverse（补偿）定义

| 动作 | inverse | 类别 | 捕获内容（execute 时） | 自动补偿 |
|:---|:---|:---|:---|:---|
| `notify`/`send_phone_message`/`kick`/`revive` | — | none | 无 | 否 |
| `set_job_duty`/`set_bucket`/`set_metadata` | 同动作 | exact | `before={onduty,bucket,field:value}` | 是（saga 内） |
| `spawn_vehicle` | `delete_vehicle` | exact | `{netId, plate, temp=true}` | 是（未上车时） |
| `add_item` | `remove_item` | lossy | `{item, amount, slot?}` | 是（物品仍在时） |
| `remove_item` | `add_item` | lossy | `{slot, amount, info}` 列表 | 是（最大努力） |
| `delete_vehicle`(临时) | — | none | 实体已销毁 | 否 |
| `delete_vehicle`(自有) | `restore_vehicle` | lossy | `{state, garage, depotprice}` | **manual** |
| `start_quest` | `fail_quest` | lossy | `{quest_id}` | **manual** |
| `set_job` | `set_job` | lossy | `{name, grade}` | **manual** |
| `add_money` | `remove_money` | lossy | `{account, before, after}` | **manual** |
| `set_money` | `set_money` | lossy | `{account, before}` | **manual** |
| `teleport`(v2.1) | `teleport` | exact | `{x,y,z,heading,bucket}` | 是 |

规则：

1. **捕获时机**：执行前读前置状态，写 `result.inverse` 与 `inverse_params`；提案 preview 只用于展示，审批可能延迟，不能作为 inverse 依据。
2. **补偿是一等公民行**：新 `agent_actions` 行，`agent_id='system:compensator'`、`inverse_of=原 id`、`budget_amount=0`、`status=executed|failed`；不占配额，但必须过熔断（仅补偿可 `bypass_breaker`）。
3. **L4 永不自动补偿**：只生成 `pending_approval` inverse + `LogSecurity` 告警，由人决定。钱可能已被消费，自动 remove 会制造负余额/二次伤害。
4. **补偿窗口**：金钱类 inverse 仅原动作后 300s 内允许一键执行；超窗只能人工核对流水。
5. **不可补偿**：`kick`、`revive`、已发送消息、已销毁临时车、已消费 item——批量结果必须列入 `uncompensated[]`，不能假装 `compensated`。

---

## 4. 原子性与批量

### 4.1 结论

- QBCore 写是**跨资源内存操作 + 异步 DirtyFlush**，没有跨表事务。因此：
  - **不提供 `all_or_nothing`**，请求该模式返回 `unsupported_mode`。
  - 默认 `saga`：顺序执行，失败对已执行且 `compensation=inverse` 的步骤逆序补偿。
  - `best_effort`：失败继续执行后续无依赖步骤，最终 `partial_success`。
- 单请求最多 8 步；`batch risk = max(step.risk)`；任一步需双人 → 整批双人。

### 4.2 Envelope

```json
POST /agent/v1/batch
{"batch_key":"beat_123/saga/1","mode":"saga","dry_run":false,"steps":[
  {"step_id":"pay","type":"add_money","args":{"citizenid":"ABC12345","account":"bank","amount":250,"reason":"wage"}},
  {"step_id":"job","type":"set_job","depends_on":["pay"],"args":{"citizenid":"ABC12345","job":"taxi","grade":1}},
  {"step_id":"msg","type":"notify","args":{"citizenid":"ABC12345","text":"Your new job starts now."}}]}
```

- 每步派生键 `batch:<batch_key>/<step_id>`（≤128；`batch_key` ≤64）；重放返回同一 `agent_batches` 行，不重复执行。
- `depends_on` 未成功 → `skipped`；`/agent/v1/act` 不变；`batch_key` 与单动作 key 共用一个命名空间。

### 4.3 执行算法

```text
executed = []
for step in steps:
  if not deps_ok(step, executed): step.status='skipped'; continue
  ok, err, res = Executors[step.type].execute(...)
  if ok: executed.append(step); continue
  step.status='failed'
  if mode=='saga':
    for s in reverse(executed):
      if s.compensation=='inverse': compensate(s)    # 自动，写补偿行
      elif s.compensation=='manual': queue_manual(s) # 建 pending inverse + 告警
  break
```

### 4.4 `partial_success`（`data` 部分，外层沿用 03 §5 envelope）

```json
{"batch_id":77,"status":"partial_success","mode":"saga","all_succeeded":false,"requires_operator":true,
 "steps":[{"step_id":"pay","action_id":41,"status":"executed"},
          {"step_id":"job","action_id":42,"status":"failed","code":"job_not_found"},
          {"step_id":"msg","action_id":43,"status":"skipped"}],
 "compensation":[{"inverse_of":41,"action_id":44,"status":"executed"}],
 "uncompensated":[{"step_id":"pay","reason":"L4_manual"}]}
```

HTTP 200 + `status:partial_success`（**不是** 5xx，避免自动重试）；`ok:true` 只表示“批次已处理完”，`all_succeeded:false` 才是结果。`partial_success` 禁止自动重放。

### 4.5 表

```sql
CREATE TABLE IF NOT EXISTS `agent_batches` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, `batch_key` VARCHAR(128) NOT NULL,
  `agent_id` VARCHAR(64) NOT NULL, `mode` ENUM('saga','best_effort') NOT NULL DEFAULT 'saga',
  `status` ENUM('proposed','pending_approval','approved','executing','executed',
                'compensated','partial_success','failed','rejected') NOT NULL DEFAULT 'proposed',
  `plan` LONGTEXT NOT NULL, `result` LONGTEXT NULL, `error` VARCHAR(255) NULL,
  `requested_at` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  `approved_by` VARCHAR(64) NULL, `approved_at` DATETIME(3) NULL,
  `executed_at` DATETIME(3) NULL, `expires_at` DATETIME NULL,
  PRIMARY KEY (`id`), UNIQUE KEY `uq_batch_key` (`batch_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

---

## 5. 预算与限流

### 5.1 模型

四个维度：**quota_key（动作组）× agent_id × target_citizenid × window**；金额与次数分开计。`quota_key` 并池（`money`/`item`/`vehicle`/`intervention`/`message`），避免每动作一张表。

```sql
CREATE TABLE IF NOT EXISTS `agent_action_limits` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, `quota_key` VARCHAR(32) NOT NULL,
  `agent_id` VARCHAR(64) NOT NULL DEFAULT '*', `target_citizenid` VARCHAR(11) NOT NULL DEFAULT '*',
  `window_seconds` INT UNSIGNED NOT NULL, `max_amount` DECIMAL(18,2) NULL,
  `max_count` INT UNSIGNED NULL, `note` VARCHAR(255) NULL,
  `updated_at` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_limit` (`quota_key`,`agent_id`,`target_citizenid`,`window_seconds`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

用 `'*'` 而非 NULL 做通配（MySQL 唯一索引不约束 NULL）。`agent_actions` 增 `budget_key/budget_amount`；金额动作写金额（`set_money` 写 `abs(delta)`），其余写 1。

### 5.2 检查 SQL（按非通配维度动态拼 WHERE，保证走索引）

```sql
SELECT COALESCE(SUM(budget_amount),0) AS used_amount, COUNT(*) AS used_count
FROM agent_actions
WHERE status IN ('pending_approval','approved','executed')
  AND requested_at >= NOW(3) - INTERVAL ? SECOND AND id <> ?
  AND budget_key = ? AND agent_id = ? AND target_citizenid = ?;  -- 后两项仅非通配时拼
```

索引：`(budget_key,status,requested_at)`、`(target_citizenid,budget_key,requested_at)`、`(agent_id,budget_key,requested_at)`。

### 5.3 默认额度（seed，可调）

| quota_key | 维度 | window | max_amount | max_count |
|:---|:---|:---:|---:|---:|
| `money` | 全局 / 单玩家 | 86400 | 5000 / 1000 | — |
| `money` | agent=director.local | 86400 | 2000 | — |
| `money_set` | 全局 | 86400 | 2500 | — |
| `item` | 全局 / 单玩家 | 86400 | 20 / 5 | 20 / 5 |
| `vehicle` | 全局 / 单玩家 | 3600 | — | 12 / 2 |
| `intervention`（job/kick/bucket/duty） | 全局 / 单玩家 | 86400 | — | 50 / 6 |
| `message`（notify/phone） | 全局 / 单玩家 | 3600 | — | 120 / 6 |

规则：pending 预占（沿用 v1），reject/expire/fail 释放；审批时排除当前行再加一次避免双计；补偿行 `budget_amount=0`；`agent_actions_daily_budget` convar 仅在 `money` 配额表为空时兜底，表优先并在 `/policy` 返回 `limits_source`；超限 `budget_exceeded`(400) 带 `retry_after_seconds`，与 `rate_limited`(429) 区分。

---

## 6. 熔断

| 触发 | 阈值 | 动作 | 恢复 |
|:---|:---|:---|:---|
| 连续执行失败 | 3 次 | open 15m | 半开 1 次探测；成功 close，失败 open ×2（上限 24h） |
| 失败率 | 最近 20 次 ≥30% | open 30m | 同上 |
| 越权尝试 | 10 分钟 ≥5 次 `forbidden_*`/`unsupported_*`/`out_of_range` | open 60m + Security 告警 | 同上，每次 transition 只告警一次 |
| 金额异常 | 单笔 `budget_amount > max(anomaly_amount, 5×p95_7d)` | 直接拒 `amount_anomaly` | 不自动恢复；调阈值或人工放行 |
| 频率异常 | propose >30/min/agent | 429 `rate_limited` | 滑动窗口，不计入 deny |
| 全服失败率 | 15 分钟 >10% | 降级 `degrade_to=L1`（L2+ 全拒） | 人工 `agent_breaker reset` |
| 补偿失败 | 任意 inverse failed | `requires_operator` + Security 告警 | 人工处理，不自动重试 |

```sql
CREATE TABLE IF NOT EXISTS `agent_circuit_breaker` (
  `agent_id` VARCHAR(64) NOT NULL,
  `state` ENUM('closed','open','half_open') NOT NULL DEFAULT 'closed',
  `reason` VARCHAR(64) NULL, `fail_streak` INT UNSIGNED NOT NULL DEFAULT 0,
  `deny_streak` INT UNSIGNED NOT NULL DEFAULT 0, `opened_at` DATETIME(3) NULL,
  `expires_at` DATETIME(3) NULL,
  `updated_at` DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (`agent_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

- 检查点：`Propose` 前、`Approve`/执行前各一次；`*` 行代表全局。open 时 propose/approve 返回 `breaker_open`，但 **reject 与补偿永远放行**。
- 内存滚动窗口只算速率/失败率，**状态持久化**（重启不丢 open），启动时 `SELECT` 载入。
- 告警：`LogSecurity` + `agent_events:agent.breaker.open`（含 `reason/until/fail_streak`，不带 params）。
- **身份可伪造**：`X-Agent-Id` 自报、可轮换。v2 增加 `agent_actions_allowed_agents` 白名单（不在名单 → `unknown_agent`），建议一 agent 一 token；token↔agent_id 绑定是 v2.1。

---

## 7. 审计与可回溯

### 7.1 `agent_actions` 变更（v2.4）

```sql
ALTER TABLE `agent_actions`
  MODIFY `status` ENUM('proposed','pending_approval','approved','executed',
                       'rejected','failed','skipped','undone') NOT NULL DEFAULT 'proposed',
  ADD COLUMN `risk` VARCHAR(4) NULL, ADD COLUMN `target_citizenid` VARCHAR(11) NULL,
  ADD COLUMN `batch_id` BIGINT UNSIGNED NULL, ADD COLUMN `step_index` SMALLINT UNSIGNED NULL,
  ADD COLUMN `required_approvals` TINYINT UNSIGNED NOT NULL DEFAULT 1,
  ADD COLUMN `approval_count` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  ADD COLUMN `inverse_of` BIGINT UNSIGNED NULL, ADD COLUMN `inverse_action` VARCHAR(32) NULL,
  ADD COLUMN `inverse_params` LONGTEXT NULL, ADD COLUMN `verify_ok` TINYINT(1) NULL,
  ADD COLUMN `verify_result` LONGTEXT NULL, ADD COLUMN `budget_key` VARCHAR(32) NULL,
  ADD COLUMN `budget_amount` DECIMAL(18,2) NOT NULL DEFAULT 0,
  ADD COLUMN `origin` VARCHAR(16) NOT NULL DEFAULT 'http',
  ADD COLUMN `undone_at` DATETIME(3) NULL, ADD COLUMN `undone_by` VARCHAR(64) NULL,
  ADD KEY `idx_budget` (`budget_key`,`status`,`requested_at`),
  ADD KEY `idx_target_budget` (`target_citizenid`,`budget_key`,`requested_at`),
  ADD KEY `idx_batch` (`batch_id`,`step_index`), ADD KEY `idx_inverse_of` (`inverse_of`);
```

`agent_id` v1 已有（`v2.3:23`）。`MODIFY status` 非幂等；迁移用 `information_schema` 守卫或只跑一次（需在脚本头部注明）。

### 7.2 `agent_events` 事件

| event_type | 何时 | payload 关键字段 |
|:---|:---|:---|
| `agent.action.executed` | 执行并验真通过 | `action_id,batch_id,action_type,risk,agent_id,citizenid,status` |
| `agent.action.failed` | 执行/验真失败 | 同上 + `code,verify_ok` |
| `agent.action.rejected` | 人审拒绝/过期/审批时 policy 失败 | 同上 + `code` |
| `agent.action.undone` | 补偿成功 | `action_id,inverse_of,status` |
| `agent.batch.partial_success` | 批次部分成功 | `batch_id,steps_total,failed,compensated,uncompensated` |
| `agent.breaker.open` | 熔断打开/升级 | `agent_id,reason,until` |
| `agent.approval.granted`/`.denied` | 每次审批 | `action_id,approver,approval_count,required` |

payload **只放引用与状态，不重复 params/preview**（params 已在 `agent_actions`，重复扩大 PII 面并让事件膨胀）。director 自己消费时必须跳过 `agent.*`，避免“看见自己的动作 → 再提议”的正反馈。

### 7.3 writer（best-effort，不改变动作状态）

```lua
local function writeAuditEvent(eventType, citizenid, payload)
    local ok, idOrErr = pcall(function()
        return MySQL.insert.await(
            'INSERT INTO agent_events (event_type, citizenid, payload, schema_version) VALUES (?, ?, ?, 1)',
            { eventType, citizenid and citizenid:sub(1, 11) or nil, safeEncode(payload) })
    end)
    if not ok then
        print(('[custom-director] audit event failed %s: %s'):format(eventType, truncate(idOrErr, 160)))
        return nil
    end
    return tonumber(type(idOrErr) == 'table' and idOrErr.insertId or idOrErr)
end
```

顺序：先更新 `agent_actions`（事实源）→ 再写事件（feed）。事件写失败只告警，不回滚动作；反之会产生“事件说成功、行是 pending”的假账。

---

## 8. 审批体验

| 风险 | 默认 | 可预授权？ | TTL | 人数 |
|:---|:---|:---|:---:|:---:|
| L1 `notify`/`send_phone_message` | 自动 | 是（永久） | — | 0 |
| L2 `set_job_duty`/`set_bucket` | **人审** | 仅 `agent_actions_l2_auto=1` 且 `compensation=exact` | 900s | 1 |
| L3 其余 6 个 | **人审** | 否 | 900s | 1 |
| L4 `set_job`/`add_money` | **人审** | 否 | 1800s | 1（`set_job` 可配 2） |
| L4 `set_money`/`kick` | **人审** | 否 | 600s | **2** |

- **预授权不是“信任 agent”**，而是“动作有精确 inverse + 有额度 + 可回放”。L3/L4 没有例外。
- **双人审批**：`agent_action_approvals(action_id, approver, decision, reason, created_at, UNIQUE(action_id, approver))`；`approval_count >= required_approvals` 才转 `approved` 并执行；两个 approver 必须不同 label。
- **防自批**：agent/admin token 分离（`main.lua:1213-1229` 已实现）+ `approver /= agent_id` + approver 不得以 `agent:` 开头 + `/agentapprove` 只允许真实 console 或 `qbcore.god`（`main.lua:1308-1332`）。
- **审批超时**：60s 定时 worker（替代仅 `List` 懒扫）把过期行置 `rejected/expired` 并写事件；过期后必须换新 key 重新提案，**不自动续期、不自动重提**。
- **审批页必须展示**：preview diff、`inverse_action` 与参数、同 agent 近 24h 同动作次数、额度剩余、batch 其它步骤。缺任一项不得批准（UI 层约束）。

---

## 9. 经济安全

### 9.1 `MoneyGuard`（`server/money_guard.lua`）

```lua
-- 返回 ok, err, verifyTable
function MoneyGuard.Apply(actionId, params, opts)
    local player = getPlayerByCitizenId(params.citizenid)
    if not player then return false, 'player_offline' end
    local before, readErr = dbMoney(params.citizenid, params.account)
    if not before then return false, 'account_unavailable: ' .. tostring(readErr) end
    -- stale：审批期间余额变了就不写（set_money/remove_money 必开）
    if opts.expect_before and math.abs(before - opts.expect_before) > 0.001 then
        return false, ('stale_preview before=%s expected=%s'):format(before, opts.expect_before)
    end
    local expectedAfter = opts.expected_after or (before + params.amount)
    -- 调 qb-core 原函数（保留 nparams 兼容，见 main.lua:342-360）
    local ok, err = callMoneyFn(player, opts.fn, params.account, opts.amount, 'agent_action:' .. actionId)
    if not ok then return false, ('money_fn_failed: %s'):format(truncate(err, 150)) end
    -- 强制单玩家刷盘 + 重试读 DB（DirtyFlush 异步）
    pcall(function() player.Functions.Save(true) end)
    local after
    for _ = 1, 3 do
        Wait(50)
        after = dbMoney(params.citizenid, params.account)
        if after and math.abs(after - expectedAfter) <= 0.001 then break end
    end
    if not after then return false, 'verify_timeout' end
    local verify = { account = params.account, before = before, after = after,
                     expected = expectedAfter, delta = after - before,
                     ok = math.abs(after - expectedAfter) <= 0.001 }
    if not verify.ok then return false, 'amount_verification_failed', verify end
    return true, nil, verify
end
```

- `opts.fn ∈ {AddMoney, RemoveMoney, SetMoney}`；`expect_before` 对 `set_money`/`remove_money` 必填。
- `set_money` 的 `expected_after = params.amount`；`remove_money` 为 `before - amount`。`RemoveMoney` 的 `DontAllowMinus`/`MinusLimit` 先失败 → `money_fn_failed`，不进入验真。
- 失败处理：`status=failed` + `verify_result` + `LogEconomy` + `LogSecurity` + 熔断 `fail_streak+1`。**不自动回滚**（v1 既有决策）；`set_money` 也不做“补偿性 set 回去”。
- `add_money` 的 inverse 若因余额不足失败，标记 `uncompensated`，人工按流水追回或放弃。

### 9.2 `set_money` 额外硬约束

1. `0 ≤ target ≤ max_set_money`（默认 50000）。
2. `|target-before| ≤ max_set_money_delta`（默认 25000）。
3. `before == preview.before`，否则 `stale_preview`。
4. `required_approvals = 2`，两个 approver 不同。
5. 永不 `auto_execute`，永不进 L2 自动白名单。
6. `budget_amount = abs(delta)`，与 add_money 共用 `money` 池。

---

## 10. `policy.lua` 扩展结构与骨架

### 10.1 结构

```lua
AgentPolicy.ACTIONS = {
    set_job = { risk='L4', approval='always', channel='server', compensation='manual',
        undo_action='set_job', undo_template={job='$before.job.name', grade='$before.job.grade'},
        budget={key='intervention', amount=1},
        normalize=NormalizeSetJob, check=CheckSetJob, capture=CaptureSetJob },
}

function AgentPolicy.Normalize(actionType, params, cfg)
    local def = AgentPolicy.ACTIONS[actionType]
    if not def then return fail('unsupported_action', 'unsupported action type') end
    local citizenid, err = AgentPolicy.NormalizeCitizenId(params.citizenid)
    if not citizenid then return nil, err end
    local normalized, nerr = def.normalize(params, cfg or {})
    if not normalized then return nil, nerr end
    normalized.citizenid = citizenid
    return normalized
end

function AgentPolicy.RequiresApproval(actionType, params, cfg)
    local d = AgentPolicy.ACTIONS[actionType]
    if not d or d.approval == 'always' or d.approval == 'dual' then return true end
    if d.approval == 'never' then return false end
    if type(params) ~= 'table' or type(d.auto_ok) ~= 'function' then return true end
    return not d.auto_ok(params, cfg or {})
end
```

`buildContext` 扩展（main.lua）：`player={source,money,job,metadata,items,coords,bucket}`、`jobs=QBCore.Shared.Jobs`、`items=QBCore.Shared.Items`、`quests`、`bucket_counts`；只传引用/只读副本，不写回。`RequiredApprovals = required_approvals or (approval=='dual' and 2) or 1`。

### 10.2 `set_job`（完整骨架：policy + executor）

```lua
local function NormalizeSetJob(params)
    local job, err = AgentPolicy.NormalizeToken(params.job, 'job', 32)
    if not job then return nil, err end
    local grade = type(params.grade) == 'number' and tostring(math.tointeger(params.grade)) or params.grade
    if type(grade) ~= 'string' or not grade:match('^%d+$') then
        return nil, AgentPolicy.Error('invalid_params', 'grade must be a non-negative integer')
    end
    return { job = job:lower(), grade = grade }
end

local function CheckSetJob(params, ctx)
    local jobs = ctx.jobs
    if type(jobs) ~= 'table' or not jobs[params.job] then
        return false, AgentPolicy.Error('job_not_found', 'job does not exist')
    end
    if not (jobs[params.job].grades or {})[params.grade] then
        return false, AgentPolicy.Error('grade_not_found', 'grade does not exist for that job')
    end
    return true
end

Executors.set_job = { execute = function(actionId, params)
    local player = getPlayer(params.citizenid)
    if not player then return false, 'player_offline' end
    local job = player.PlayerData.job or {}
    local before = { name = job.name, grade = job.grade and job.grade.level or 0 }
    local ok, result = pcall(function() return player.Functions.SetJob(params.job, params.grade) end)
    if not ok then return false, 'set_job_failed: ' .. truncate(result, 150) end
    local after = getPlayer(params.citizenid)
    if result ~= true or not after or after.PlayerData.job.name ~= params.job then
        return false, 'job_verification_failed'
    end
    return true, nil, { job = params.job, grade = tonumber(params.grade), before = before,
        inverse = { action = 'set_job', params = { job = before.name, grade = tostring(before.grade) } } }
end }
```

### 10.3 `add_item`（policy + 执行后校验）

```lua
local function NormalizeAddItem(params, cfg)
    local item, err = AgentPolicy.NormalizeToken(params.item, 'item', 64)
    if not item then return nil, err end
    local amount, aerr = AgentPolicy.NormalizeInt(params.amount, 1, cfg.max_item_amount or 5, 'amount')
    if not amount then return nil, aerr end
    return { item = item:lower(), amount = amount, info = {} }
end

local function CheckAddItem(params, ctx)
    if type(ctx.items) ~= 'table' or not ctx.items[params.item] then
        return false, AgentPolicy.Error('item_not_found', 'item does not exist')
    end
    local ok, reason = exports['qb-inventory']:CanAddItem(ctx.player.source, params.item, params.amount)
    if not ok then return false, AgentPolicy.Error('inventory_full', 'cannot add: ' .. tostring(reason)) end
    return true
end

-- executor 验真：qb-inventory 侧实时计数，跨资源返回值可靠
local before = exports['qb-inventory']:GetItemCount(source, params.item)
local ok = player.Functions.AddItem(params.item, params.amount, false, params.info, 'agent_action:' .. actionId)
local after = exports['qb-inventory']:GetItemCount(source, params.item)
if not ok or (after - before) ~= params.amount then return false, 'item_verification_failed' end
```

### 10.4 `spawn_vehicle`（executor 骨架：超时 + TTL + inverse）

```lua
Executors.spawn_vehicle = { execute = function(actionId, params)
    local player = getPlayer(params.citizenid)
    if not player then return false, 'player_offline' end
    local model = joaat(params.model)
    if not IsModelInCdimage(model) or not IsModelAVehicle(model) then return false, 'model_invalid' end
    local veh = CreateVehicleServerSetter(model, params.vehicle_type or 'automobile',
                                         params.x, params.y, params.z, params.heading)
    local deadline = GetGameTimer() + 2000
    while not DoesEntityExist(veh) and GetGameTimer() < deadline do Wait(50) end
    if not DoesEntityExist(veh) then return false, 'spawn_timeout' end
    local plate = ('AG%05d'):format(math.random(0, 99999))
    SetVehicleNumberPlateText(veh, plate)
    AgentTempVehicles[actionId] = { netId = NetworkGetNetworkIdFromEntity(veh), entity = veh,
        plate = plate, citizenid = params.citizenid, expires = os.time() + (params.ttl_seconds or 600) }
    return true, nil, { net_id = AgentTempVehicles[actionId].netId, plate = plate,
        inverse = { action = 'delete_vehicle', params = { plate = plate, temp = true } } }
end }
```

TTL 线程 30s tick：过期 → `delete_vehicle(temp=true)`；玩家在车内先 warning，延 60s 仍不下车则 `vehicle_occupied` 告警并跳过（不强制拖出）。

---

## 11. 不做什么（反模式）

| 反模式 | 为什么不做 | 正确做法 |
|:---|:---|:---|
| 直接 `UPDATE players SET money` / `DELETE FROM player_vehicles` | 绕过 DirtyFlush/事件/审计，客户端不同步 | 只走 `Player.Functions.*` 或已审计 export |
| 批量 `all_or_nothing` | QBCore 无跨资源事务，承诺原子性就是撒谎 | `saga` + 显式补偿 + `partial_success` |
| 失败后自动重试整批 | 钱可能已到账，重试＝二次发放 | 新 `batch_key` 或人工 |
| L4 自动 inverse（自动扣回钱） | 玩家可能已消费，造成负余额/二次伤害 | `manual` + 告警 + 流水核对 |
| 用 `exports['qb-core']:AddItem` 给玩家发物品 | 那是**物品定义**注册，同名不同义 | `player.Functions.AddItem` / `qb-inventory:AddItem(src,...)` |
| `set_metadata` 改 `isdead/ishandcuffed/injail/licences` | 越过医疗/司法/资质域规则 | 只允许 4 个白名单字段；死亡走 revive |
| `remove_item` 不拍快照 | 无法恢复，任务物品可能被删 | 存 `{slot,amount,info}`；任务物品直接拒 |
| 自有车硬删除 | 玩家资产永久丢失，不可审计 | 软删 `state=2`+`depotprice`，可恢复 |
| 让 agent 通过 client 事件直接改状态（teleport/revive） | 客户端可伪造/忽略，无法验真 | v2 不开放 teleport；revive 以 metadata 验真 |
| 把 `X-Agent-Id` 当可信身份 | 自报、可轮换，绕过配额/熔断 | 白名单 + 一 agent 一 token，v2.1 绑定 |
| 审批页只显示“加 250 块” | 审批人无法判断上下文与后果 | 展示 before/after、inverse、额度、batch 其它步骤 |
| 让 agent 消费自己产生的 `agent.*` 事件 | 正反馈循环，越演越烈 | director 跳过 `agent.*` |
| 把 `partial_success` 当失败重试 | 会重复执行已成功步骤 | 视为“需人工”，不自动重放 |
| 在 policy 里做 DB/QBCore 调用 | 破坏纯函数可测性 | 副作用留在 executors，policy 只读 ctx |

---

## 12. 交付任务清单（checkbox + 验收 + 依赖）

| # | 任务 | 验收方式 | 依赖 |
|:-:|:---|:---|:---|
| 1 | `v2.4_agent_write_actions.sql`：ALTER `agent_actions` + `agent_batches`/`agent_action_limits`/`agent_action_approvals`/`agent_circuit_breaker` | 空库与 v2.3 库各跑一次；`SHOW CREATE TABLE` 对比；重跑不报错（`IF NOT EXISTS`；`MODIFY` 有守卫） | v2.3 |
| 2 | `policy.lua` v2 声明式 registry + 公共 Normalize 助手 + `RequiresApproval/RequiredApprovals/StatusFor` 兼容 | `lua5.4 tests/agent/test_agent_actions_policy.lua` 全绿；旧 selftest 不改也过 | 1 |
| 3 | `server/executors.lua` 注册表 + `MoneyGuard` 抽取（add_money 行为不变） | 现有 add_money live smoke 通过；`luac5.4 -p`；失败注入返回 `delta_mismatch` | 2 |
| 4 | 审批 v2：`approval_count/required_approvals`、双人、60s 过期 worker、审计事件 | 单审/双审/过期/自批 4 用例；`agent.action.rejected` 仅对已落库行产生 | 1,3 |
| 5 | 批量：`agent_batches` + saga 补偿 + `partial_success` + 补偿行 | 强制第 2 步失败：第 1 步 inverse 执行、状态 `compensated`/`partial_success`、`inverse_of` 正确 | 1,3,4 |
| 6 | 额度表 + 查询 + `/policy` 暴露 `limits_source`/`quota_used` | pending 预占、reject 释放、补偿不占额；`EXPLAIN` 走索引 | 1 |
| 7 | 熔断器 + 降级 + 告警 | 3 连败 open；半开成功 close；`breaker_open` 不阻塞 reject/补偿 | 1,6 |
| 8 | `agent_events` writer + `agent.*` 事件 | 每个 executed/failed 行恰好 1 条事件；事件写失败不回滚动作 | 1,3 |
| 9 | L1/L2 动作：`send_phone_message`（含 custom-phone export）、`set_job_duty`、`set_bucket`、`spawn_vehicle` | 各 3 用例；spawn 2s 超时、TTL 到期删除、bucket 恢复 | 2,3,6,7 |
| 10 | L3 动作：`add_item/remove_item/set_metadata/revive/delete_vehicle/start_quest` | 每个动作 before/after 验真；revive 2s 验真；自有车软删不 DELETE | 9 |
| 11 | L4 动作：`set_job/add_money/set_money/kick` | `set_money` stale/delta/双审 3 负例；kick 5s `drop_unconfirmed` | 10 |
| 12 | 文档同步：`ACTIONS.md` v2、`README.md` convar 表、`schema_version: 2`、`/policy` 矩阵 | 文档与 `/agent/v1/policy` 输出字段一致；CI golden 更新 | 2-11 |
| 13 | 回归：旧 3 动作行为不变、幂等、kill switch、token 分离 | v1 smoke 全跑；`enabled=0` → 全 `disabled` | 3 |
| 14 | v2.1：`teleport` 客户端 ack 契约 + 脱战/桶校验 | 单独 issue；不阻塞 v2 | 9 |

**依赖顺序**：1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12/13。6/7/8 可与 4/5 并行，但必须在 L3/L4 动作前完成。

**验收基线**：`lua5.4 tests/agent/test_agent_actions_policy.lua`、`luac5.4 -p` 所有新增 server 文件、v1 live smoke，以及每动作至少 1 正例 + 2 负例（越界/离线/验真失败）。批量与熔断需脚本化失败注入，不能只靠人工点。

---

## 13. 实现回填 · 第一片（2026-10-22）

本片只增加两个动作，**没有**做声明式重构：`policy.lua` 仍是 if-chain。理由：现有 3 个动作的校验逻辑已被 selftest 与生产使用验证，一次性重写会把"已验证"换成"未验证"；先以增量方式补齐高风险动作，等动作数逼近 10 个再重构，收益更大、回归面更小。

已落地：
- `set_job`（L3，必须人审）：`job` 必须在 `QBCore.Shared.Jobs`，`grade` 必须在职业的 grades 中；`SetJob` 返回 true 后**回读** `PlayerData.job.name` 与 `grade.level`，不一致记 `verification_failed`；结果含 `before/after`。
- `grant_item`（L4，必须人审）：`item` 必须在 `QBCore.Shared.Items`；`AddItem` 后回读数量差必须等于 `amount`；上限用 `agent_actions_max_item_amount`（默认 50，clamp 1..1000），不参与 `add_money` 的每日预算。
- 两者都**严格拒绝未知字段**（旧 3 个动作保持"丢弃未知字段"的历史行为，未改）。

偏差：
1. 执行失败仍映射为 API `code=execution_failed`，`verification_failed` 只出现在 `error`/`result.error` 与审计里；未新增失败码，避免改变既有 HTTP 映射。
2. 未预检负重/槽位，`AddItem` 返回 false 即 `execution_failed`；不做 undo。
3. `grant_item.reason` 严格拒绝 tab/LF/CR（比 `add_money.reason` 更严，后者暂未收紧）。
4. 未做真实 FXServer/QBCore 联机冒烟。

下一步：`set_job`/`grant_item` 已在 registry 由 `planned` 改为 `active`（23 工具 / 18 active），MCP 可直接调用；剩余 5 个动作（`send_announce`/`set_weather`/`set_time_of_day`/`teleport_player`/`spawn_vehicle`）留待后续。

### 13.1 第二片（世界/表现类，2026-10-22）

新增 `announce` / `set_weather` / `set_time_of_day`，均为 L2 + `requires_approval=true` + `blast_radius='world'`：

| 动作 | 执行 | 校验 |
|---|---|---|
| `announce` | 遍历在线玩家逐个 `Notify` | 统计 `delivered`；0 人在线视为成功（无人可发不是失败） |
| `set_weather` | `qb-weathersync:setWeather` | 回读 `getWeatherState() == weather`，否则 `verification_failed` |
| `set_time_of_day` | `qb-weathersync:setTime` | 回读 `getTime()` 的 hour/minute，不一致 `verification_failed`；无 `getTime()` 的旧版本退化为只信返回值（`verify_result=false`） |

`blast_radius` 先前在 registry 里误写为 `single`（广播/世界状态应是 `world`），本片一并修正；该字段与 `risk` 正交，`world` 强制要求审批。

三个工具已由 `planned` 改为 `active`（23 工具 / 21 active）。仍余 `teleport_player` 与 `spawn_vehicle`：前者需要把 `custom-agent-client` 接进执行链（`Citizen.Await` 可让出性），后者需要服务端实体创建与超时控制。

### 13.2 第三片（teleport，2026-10-22）

`teleport`（L3，必须审批）把动作代理接到 `custom-agent-client`：

- 参数严格白名单 `citizenid/x/y/z/heading?`；坐标必须有限且在地图边界内。
- `CheckPolicy` 要求玩家在线且 `custom-agent-client` 已启动（`ctx.executor_ready`），否则 `executor_unavailable`。
- 执行：`exports['custom-agent-client']:Execute(src,'teleport',{...},5000,{agent_id='director:<id>'})`。
  - 成功返回 `{ack, from, at}`；
  - `not_yieldable` **显式失败**（提示必须在 coroutine 内），不静默降级为 fire-and-forget；
  - `timeout`/`player_offline`/`handshake_missing`/`executor_disabled` 原样映射；
  - export 调用抛错 → `executor_unavailable`。
- 不做落点回读、不解析 `ack.detail`、无 bucket/战斗/载具守卫、无重试/回滚。

**关键结论**：`Propose`/`Approve` 在 FiveM 的 HTTP 回调协程内执行，`Citizen.Await` 可正常让出；非协程调用会得到 `not_yieldable`。因此审批路径不需要改成两段式队列。

`teleport_player` 已由 `planned` 改为 `active`（23 工具 / 22 active），仅剩 `spawn_vehicle`。

### 13.3 第四片（spawn_vehicle，2026-10-22）

`spawn_vehicle`（L3，必须审批）补齐 15 个在册动作里的最后一个：

- 参数严格白名单 `citizenid/model/plate?`；`model` 小写化后用 `GetHashKey` 判存（hash 由 main 注入 `ctx.model_hash`，policy 保持无 native）。
- 执行：玩家上前方 1.5m 生成，`CreateVehicleServerSetter` 优先、`CreateVehicle` 回退。
- **有界等待**：`deadline = GetGameTimer() + 2000`，`DoesEntityExist` 轮询；超时 `DeleteEntity` 后返回 `vehicle_spawn_timeout`。**不使用** qb-core 的 `SpawnVehicle`（内部 `while Wait(0)` 无上界）。
- plate 写入后回读、去空格比较，不一致 `verification_failed`；该路径**不删除实体**（已文档化，避免"报错但车还在"变成"报错且车没了"）。
- 不发钥匙、不写 `player_vehicles`、不设 bucket——这些属于车库/钥匙领域，不应由 agent 动作直接越权完成。

至此 v1 工具面 **23 工具 / 23 active** 全部落地，`planned` 集合为空。

---

## 14. 安全评审：为什么 `set_money` 不实现

设计 §2 把 `set_money`（绝对值改余额）列为"最危险"。实现到第 14 个动作后，明确决定**不上线**，理由不是工作量：

1. **它绕过所有现有护栏。** `add_money` 受单笔上限、每日预算、delta 二次校验三重约束；`set_money` 的语义是"把余额设成 X"，上限和预算都失去意义——一次调用可以把整个经济体的货币供应改掉。
2. **反向操作不可靠。** 回滚需要 `RemoveMoney`，而它受 `DontAllowMinus`（cash/crypto）与 `MinusLimit`（默认 -5000）限制；玩家在两次操作之间消费过，回滚会失败，留下"审计说已回滚、实际没回滚"的状态。
3. **崩溃窗口无法证明前值。** 执行前读到的余额是内存值，执行后崩溃/重启，审计行里的 `before` 无法证明与落盘值一致；这不是加锁能解决的，是跨存储的原子性问题。
4. **它奖励错误行为。** 一旦 agent 知道有 `set_money`，它会用"设成 5000"替代"加 500"，而前者没有任何预算语义。

**替代方案**：需要发钱就用 `add_money`（有上限、有预算、有 delta 校验）；需要纠正错误余额就人工走 `qb-banking`/管理面板，并在 `custom-logs` 留痕。

如果未来确实要开，最低门槛是：双人审批 + 执行前把余额快照写入独立表 + 硬上限（例如不得超过当前值的 ±10%）+ 只允许 `bank` 账户 + 独立 convar 默认关闭。在这些条件满足前，`set_money` 保持未实现。
