---
id: police-architecture-09-outbox
type: spec
status: active
system: justice
owner: hermes
updated: 2026-10-24
review_by: 2027-04-30
---

# 09 · Intent TTL + Outbox（SM-03 残留补偿）

> 落地：`migrations/v3.12_police_outbox.sql`、`custom-police/server/p2_system.lua`
> 语义：**至少一次**投递 + **幂等账本 TTL**；没有数据库事务（后端不提供 `transaction` export）。
> 关联：[02-state-machines.md](02-state-machines.md) SM-03、[07-fitness-tests.md](07-fitness-tests.md) FIT-02、[04-data-ownership.md](04-data-ownership.md)。

---

## 1. 为什么是“账本 + outbox”而不是事务

`ArrestSubmit` / `ReportSubmit` 是跨多张表的写（report + citation + evidence + case + audit），而本项目使用的 oxmysql 构建只导出 `scalar/single/query/insert/update/prepare/rawExecute`，**没有 `transaction`**。所以：

- **写路径**：先 claim 幂等键，再按顺序写，失败时用提交自带的 DELETE 补偿（saga）；
- **通知路径**：先落 `police_outbox`，再由 worker 投递；通知失败不回滚业务，只重试；
- **不承诺原子性**：崩溃窗口仍可能留下半写；账本 TTL 与 outbox 只负责“不要把键卡死、不要把通知丢光”。

---

## 2. `police_write_intents` TTL

| 状态 | 含义 | 处理 |
|---|---|---|
| `pending` | 写事务进行中（claim 成功） | 重复调用 → `in_progress`；**超过 10 分钟**视为提交进程已死 → 删除该行，允许重试 |
| `done` | 写已提交，`result_json` 可回放 | **7 天有效**（`expires_at = NOW() + INTERVAL 7 DAY`）；过期后扫描删除，同键重新执行 |
| `failed` | 保留状态（当前写路径失败会直接删除，不写 failed） | 每次扫描直接删除，允许重新 claim |

新增列（v3.12，均 `information_schema` 守卫）：

- `expires_at DATETIME NULL`：done 的到期时间；老行为 NULL，读取时用 `COALESCE(expires_at, created_at + INTERVAL 7 DAY)` 兜底。
- `completed_at DATETIME NULL`：进入 done 的时间。

扫描（`sweepIntents`）在 **资源启动** 与 **每次 claim 之前** 执行，`LIMIT 200`：

```sql
DELETE FROM police_write_intents
 WHERE (status = 'done'
        AND COALESCE(expires_at, created_at + INTERVAL 7 DAY) < NOW())
    OR (status = 'pending' AND created_at < NOW() - INTERVAL 10 MINUTE)
    OR status = 'failed'
 LIMIT 200
```

claim 时的 SELECT 直接用 SQL 算出两个布尔列（`stale_pending` / `expired`），避免在 Lua 里解析 DATETIME：

```sql
SELECT idem_key, status, result_json,
       (status = 'pending' AND created_at < NOW() - INTERVAL 10 MINUTE) AS stale_pending,
       (status = 'done'
        AND COALESCE(expires_at, created_at + INTERVAL 7 DAY) < NOW()) AS expired
  FROM police_write_intents WHERE idem_key = ? LIMIT 1
```

**语义后果**：同一个 `idempotency_key` 在 7 天内重放返回原结果；7 天后重放会真正再执行一次。客户端应把 key 当作“一次提交会话”，不要跨天复用。

---

## 3. `police_outbox`

```sql
police_outbox (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  topic VARCHAR(32) NOT NULL,              -- 目前只有 'notification'
  payload TEXT NOT NULL,                   -- JSON
  status ENUM('pending','done','failed') NOT NULL DEFAULT 'pending',
  attempts INT UNSIGNED NOT NULL DEFAULT 0,
  next_attempt_at DATETIME NULL,           -- NULL = 立即可投递
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_status_next (status, next_attempt_at)
)
```

### 3.1 入队

- `Outbox.Enqueue(topic, payload)`：校验 topic 白名单与 payload 类型 → JSON 编码 → `INSERT ... status='pending', next_attempt_at=NOW()`；
- 入队成功后立即 `Outbox.Kick()`：`CreateThread` 里跑一次 `Outbox.Work()`，保证通知仍然是“近即时”的（不是等 30 秒）；
- 对外导出 `exports('EnqueueOutbox', ...)`，供其他 police 模块与测试使用。

### 3.2 投递

worker 每 **30 秒** 跑一次（`OUTBOX_INTERVAL_MS = 30000`），每次：

1. `Cleanup()`：删除 7 天前的 done/failed 行（`LIMIT 200`）；
2. `SELECT ... WHERE status='pending' AND (next_attempt_at IS NULL OR next_attempt_at <= NOW()) ORDER BY id ASC LIMIT 50`；
3. 每行先写 60 秒 lease（`next_attempt_at = NOW() + 60s`），防止重叠 worker 重复推送；
4. `topic='notification'` → `pcall(exports['custom-phone']:Notify(...))`；
5. 成功 → `status='done', attempts=attempts+1, next_attempt_at=NULL`；
6. 失败 → `attempts+1`，按 **30s / 2m / 10m** 退避；第 **5** 次失败 → `status='failed'`，不再重试；
7. payload 不是合法 JSON / topic 未知 → 同样走失败路径（不调用 phone）。

| 第 n 次失败 | next_attempt_at |
|---|---|
| 1 | +30s |
| 2 | +2m |
| 3 | +10m |
| 4 | +10m |
| 5 | `failed`（NULL） |

### 3.3 至少一次与重复

outbox 是 **at-least-once**：进程在“推送成功、写 done 失败”之间崩溃时，60 秒后这一行会再投递一次。通知是幂等容忍的业务（重复一条通知可接受），所以这里选择可用性而不是 exactly-once。若未来要 exactly-once，需要在 `phone_notifications` 上加 outbox id 唯一键。

---

## 4. 通知归 owner（FIT-02）

`custom-phone` 导出：

```lua
exports('Notify', function(citizenid, title, content, appId, meta)
    -- citizenid 非空 ≤50；title/content 可 nil 但必须是 string
    -- title 截 200 bytes，content 截 1000 chars，app_id 白名单 {banking, police_mdt}
    -- 在线则推送 phone:client:newNotification；离线也落库
    -- meta = { source = <online src>, app_id = <fallback> }
    return true, id  -- 失败 false
end)
```

police 侧的 5 处通知全部改为 `Outbox.Enqueue('notification', {...})`（`p0` 911、`p1` 罚单、`p2_system` 广播 + 罚单、`p4_npc` NPC 警情）；`custom-phone/server/apps/police_mdt.lua` 的 alert 同资源直接调用 `exports['custom-phone']:Notify`。`p0/p1/p4` 保留一条降级路径：outbox 未加载时直接调 owner export，绝不回退到 SQL。

**延迟风险**：入队是同步 SQL，立即 Kick 后通常在同一 tick 内推送；最坏情况（phone 导出暂时不可用）会退避到 30s/2m/10m，最长约 10 分钟。玩家侧表现为通知晚到，业务（罚单/逮捕）不受影响。

---

## 5. 运维与验证

- 迁移：`migrations/v3.12_police_outbox.sql`，可重复执行（information_schema 守卫）。
- 观察：
  ```sql
  SELECT status, COUNT(*) FROM police_outbox GROUP BY status;
  SELECT * FROM police_outbox WHERE status = 'failed' ORDER BY id DESC LIMIT 20;
  SELECT * FROM police_write_intents WHERE status = 'pending' AND created_at < NOW() - INTERVAL 10 MINUTE;
  ```
- 测试：
  - `tests/unit/layer3_business/test_police_outbox.py`（静态 SQL/TTL/边界 + 驱动 Lua harness）；
  - `tests/agent/lua/cases/police_outbox.lua`（入队、成功、退避、上限、无效 payload、清理、重入）；
  - `tests/architecture/test_cross_resource_writes.py`（`phone_notifications`/`police_reports` 单写者）。
- 失败处理：`failed` 行保留 7 天供排查；修好 phone 后可手工把行改回 `pending` 并用 `EnqueueOutbox`/worker 重投。
