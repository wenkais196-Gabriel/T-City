# Core Framework Bus API Reference

> **总线注册**: `Bus.RegisterService(name, methods)` → `Bus[name]` + 自动生成 exports

---

## economy

| 方法 | 签名 | Bus 路径 | Export 名 |
|:---|:---|:---|:---|
| `GetBalance` | `(source, accountType?)` → 余额 | `Bus.economy.GetBalance` | `service_economy_GetBalance` |
| `AddScaled` | `(source, accountType, amount, reason)` → (actualAmount, multiplier) | `Bus.economy.AddScaled` | `service_economy_AddScaled` |
| `Transfer` | `(fromSource, toCitizenId, amount, reason)` → bool | `Bus.economy.Transfer` | `service_economy_Transfer` |

---

## job

| 方法 | 签名 |
|:---|:---|
| `GetJob` | `(source)` → job 数据 |
| `SetJob` | `(source, jobName, grade, reason?)` → bool |
| `RemoveJob` | `(source, reason?)` → bool |
| `SetOnDuty` | `(source, onDuty)` → bool |
| `GetGang` | `(source)` → gang 数据 |
| `SetGang` | `(source, gangName, grade, reason?)` → bool |
| `GetOnDutyCount` | `(jobName)` → number |
| `GetGangOnlineCount` | `(gangName)` → number |
| `GetOnlinePlayersByJob` | `(jobName)` → source[] |
| `GetOnlinePlayersByGang` | `(gangName)` → source[] |

---

## metadata

| 方法 | 签名 |
|:---|:---|
| `GetJob` | `(source)` → job |
| `SetJob` | `(source, job, reason?)` ← 标记 dirty |
| `GetGang` | `(source)` → gang |
| `GetMetadata` | `(source, key?)` → 单个或全部 metadata |
| `SetMetadata` | `(source, key, value)` ← 标记 dirty |
| `SaveAll` | `(source)` → 保存到 DB |

---

## persistence

| 方法 | 签名 |
|:---|:---|
| `StartFlushTick` | `(intervalSec?)` — 启动定时刷盘 |
| `FlushAll` | `()` — 全量同步刷盘 |
| `ForceFlushPlayer` | `(citizenid)` — 单玩家强制刷盘 |
| `Stats` | `()` → { flush_count, force_count, ... } |
| `StartHealthReport` | `()` — 每 15min 打印健康统计 |

---

## security (五层校验链 L0)

| 方法 | 签名 |
|:---|:---|
| `SanitizeNumber` | `(val, min?, max?)` → number |
| `SanitizeString` | `(val, maxLength?, pattern?)` → string |
| `ValidatePlayer` | `(source)` → (bool, Player) |
| `ValidateMoneyEvent` | `(source, amount, reason?)` → bool |
| `ValidateJobEvent` | `(source, jobName, grade?, reason?)` → bool |
| `ValidateGangEvent` | `(source, gangName, grade?, reason?)` → bool |
| `ValidateItemEvent` | `(source, itemName, count?, reason?)` → bool |
| `ValidateInteraction` | `(source, targetId, maxDistance?)` → bool |
| `CheckRateLimit` | `(source, action, cooldownMs?)` → bool |
| `LogSecurityEvent` | `(type, data)` |

---

## Plugin Contract (第三方集成)

| 方法 | 签名 |
|:---|:---|
| `Bus.Plugin.Register` | `(name, schema)` → bool |
| `Bus.Plugin.Subscribe` | `(eventName, handler, pluginName?)` |
| `Bus.Plugin.Publish` | `(eventName, ...)` |
| `Bus.Plugin.GetEconomy` | `()` → economy service |
| `Bus.Plugin.GetSecurity` | `()` → security service |
| `Bus.Plugin.GetPersistence` | `()` → persistence service |
| `Bus.Plugin.List` | `()` → { name, version, author }[] |
| `Bus.Plugin.Unregister` | `(name)` |
| `Bus.Plugin.GetSchema` | `(name)` → schema |

---

## 其他 Bus 注册的服务

### vehicles (custom-vehicles)
`Bus.vehicles.GiveKeys/RemoveKeys/HasKeys/GiveTempKeys/GetOwner/SetOwner/GetKeyHolders/ClearTempKeys/KeyManagerStats`

### cartel (custom-cartel)
`Bus.cartel.GetOnlineMembers/GetOnlineCount/IsMember/CheckProductionCooldown/SetProductionCooldown/OpenStorage/CheckRaidConditions`

### mining (custom-mining)
`Bus.mining.GetSites/GetSmeltRecipes/GetToolStats`

### CoreEconomy (core_economy)
`Bus.CoreEconomy.TriggerReward/PreviewReward/GetGlobalMultiplier/GetActivityHeat/ResetAllHeat`

---

## DirtyFlush Exports (来自 core-framework)

| Export | 描述 |
|:---|:---|
| `BusStatus` | 总线健康 |
| `DirtyFlushMarkDirty` | `(citizenid, dataType)` — 标记脏数据 |
| `DirtyFlushStats` | 刷盘统计 |
| `DirtyFlushFlushAll` | 全量同步刷盘 |
| `DirtyFlushFlushAllAsync` | 全量异步刷盘 |
| `DirtyFlushForceFlush` | `(citizenid)` — 同步单玩家 |
| `DirtyFlushForceFlushAsync` | `(citizenid)` — 异步单玩家 |
