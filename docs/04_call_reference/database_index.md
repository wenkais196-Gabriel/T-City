# 数据库表全量索引

> **数据库**: `QBCore_CDB34E` (从 `mysql_connection_string` 提取)
> **驱动**: oxmysql (node-mysql2)

---

## 核心表 (qb-core 创建)

### players — 玩家核心数据

| 列 | 类型 | 说明 |
|:---|:---|:---|
| `citizenid` | VARCHAR(50) PK | 公民 ID |
| `license` | VARCHAR(50) | Rockstar 许可证 |
| `name` | VARCHAR(255) | 角色名 |
| `money` | JSON | `{ cash, bank, crypto }` |
| `charinfo` | JSON | `{ firstname, lastname, birthdate, gender, nationality, phone }` |
| `job` | JSON | `{ name, label, grade, payment, onduty, type }` |
| `gang` | JSON | `{ name, label, grade }` |
| `metadata` | JSON | `{ hunger, thirst, stress, armor, ... }` |
| `inventory` | JSON | 物品数组 |
| `position` | JSON | `{ x, y, z, heading }` |

**刷盘策略**: DirtyFlush — 15min 定时 UPSERT + PlayerDropped 强制刷盘

---

### bans — 封禁记录

| 列 | 说明 |
|:---|:---|
| `id` | AUTO_INCREMENT |
| `name` | 玩家名 |
| `license` | 许可证 |
| `discord` | Discord ID |
| `ip` | IP |
| `reason` | 封禁原因 |
| `expire` | 过期时间 |
| `bannedby` | 操作者 |

---

### whitelist — 白名单

| 列 | 说明 |
|:---|:---|
| `license` | 许可证 |
| `discord` | Discord ID |
| `fivem` | FiveM ID |

---

## 车辆表

### player_vehicles

| 列 | 说明 |
|:---|:---|
| `plate` | 车牌 (PK) |
| `citizenid` | 车主 citizenid |
| `vehicle` | 车辆模型名 |
| `hash` | 模型哈希 |
| `mods` | 改装 JSON |
| `status` | 部件状态 JSON (radiator/axle/brakes/clutch/fuel) |
| `drivingdistance` | 累计里程 |
| `garage` | 当前车库 |
| `state` | 车辆状态 (stored/impounded/...) |

**写入频率**: ⚠️ custom-vehicles/vehicle_state 每次变异立即写 — 高频场景

---

## 库存表

### inventories — Stash 库存

| 列 | 说明 |
|:---|:---|
| `identifier` | 库存 ID (PK) |
| `items` | 物品 JSON |
| `maxweight` | 最大重量 |
| `slots` | 最大槽位 |

**写入频率**: ⚠️ 每次 `closeInventory` 执行 `INSERT ... ON DUPLICATE KEY UPDATE`

---

## 任务表 (custom-quest)

### player_quests

| 列 | 说明 |
|:---|:---|
| `id` | AUTO_INCREMENT |
| `citizenid` | 玩家 |
| `quest_id` | 任务模板 ID |
| `status` | not_started / in_progress / completed / failed / abandoned |
| `current_step` | 当前步 ID |
| `progress_data` | JSON |
| `started_at` | 开始时间 |
| `completed_at` | 完成时间 |
| `completion_count` | 完成次数 |

### quest_cooldowns

| 列 | 说明 |
|:---|:---|
| `citizenid` | 玩家 |
| `quest_id` | 任务 |
| `expires_at` | 冷却过期 |
| `completion_count` | 完成次数 |

### quest_event_log

| 列 | 说明 |
|:---|:---|
| `id` | AUTO_INCREMENT |
| `citizenid` | 玩家 |
| `quest_id` | 任务 |
| `step_id` | 步骤 |
| `event_type` | 事件类型 |
| `metadata` | JSON |
| `created_at` | 时间戳 |

### quest_daily_limits

| 列 | 说明 |
|:---|:---|
| `citizenid` | 玩家 |
| `quest_id` | 任务 |
| `limit_type` | daily / weekly / lifetime |
| `period_start` | 周期开始 |
| `count` | 当前计数 |

---

## 其他表

### player_houses (qb-houses — 已禁用)

| 列 | 说明 |
|:---|:---|
| `citizenid` | 房主 |
| `...` | 房屋数据 |

### 组织仓库表 (custom-storage — oxmysql 直连)

用于 job/gang 共享仓库的持久化。

### 市场数据 (custom-market — oxmysql 直连)

用于动态商品价格和供需数据的持久化。

---

## 性能热点

| 表 | 操作 | 频率 | 风险 |
|:---|:---|:---|:---|
| `players` | UPSERT | 15min tick + PlayerDropped | 🟢 通过 DirtyFlush 批处理 |
| `player_vehicles` | UPDATE | 每次驾驶事件 (退化/里程) | 🔴 同步直写，无批处理 |
| `inventories` | INSERT..ON DUPLICATE | 每次关背包 | 🟡 高频事件中的同步写 |
| `player_quests` | INSERT/UPDATE | 每次任务状态变更 | 🟢 按需写入 |

---

## 索引建议

根据 `migrations/v2.1_perf_indexes.sql`：

- `players` — `citizenid` (主键), `license` (查找用)
- `player_vehicles` — `plate` (主键), `citizenid` (车主查找)
- `player_quests` — `citizenid + quest_id` (玩家任务查找), `status` (活跃任务筛选)
- `inventories` — `identifier` (主键)
