# core-framework — 核心服务框架 (v0.5 Data-Access Layer)

> **路径**: `resources/[standalone]/core-framework/` | **状态**: ✅ ENABLED | **CFG 模块**: custom.cfg
> **依赖**: oxmysql, qb-core, production-freeze | **被依赖**: custom-quest, custom-vehicles, custom-market, custom-storage, custom-mining, custom-cartel, custom-justice, tcity-dashboard

---

## 文件清单

| 文件 | 角色 |
|:---|:---|
| `fxmanifest.lua` | 资源清单 |
| `bus.lua` | 全局服务总线 — 注册/查找/发布/订阅 |
| `compat.lua` | QBCore API 向后兼容包装器 |
| `cache/dirty_flush.lua` | 脏数据异步刷盘管道 |
| `services/economy_service.lua` | 经济服务（AddScaled + Transfer） |
| `services/job_service.lua` | 职业/帮派服务 |
| `services/metadata_service.lua` | 元数据服务 |
| `services/persistence_manager.lua` | 持久化管理器（定时刷盘） |
| `services/security_service.lua` | 安全服务（五层校验链 L0） |

---

## Bus 服务总线 (`bus.lua`)

### 已注册服务 (5 个)

| 服务名 | 方法数 | 职责 |
|:---|:---:|:---|
| `economy` | 3 | `GetBalance`, `AddScaled`, `Transfer` |
| `job` | 10 | `GetJob/SetJob/RemoveJob/SetOnDuty/GetGang/SetGang/GetOnDutyCount/GetGangOnlineCount/GetOnlinePlayersByJob/GetOnlinePlayersByGang` |
| `metadata` | 6 | `GetJob/SetJob/GetGang/GetMetadata/SetMetadata/SaveAll` |
| `persistence` | 5 | `StartFlushTick/FlushAll/ForceFlushPlayer/Stats/StartHealthReport` |
| `security` | 14 | 输入清理/校验/速率限制/事件审计 |

### Plugin Contract API

第三方模组集成接口：
| 方法 | 描述 |
|:---|:---|
| `Bus.Plugin.Register(name, schema)` | 注册插件 |
| `Bus.Plugin.Subscribe(eventName, handler)` | 订阅总线事件 |
| `Bus.Plugin.Publish(eventName, ...)` | 发布事件（pcall 包裹） |
| `Bus.Plugin.GetEconomy/Security/Persistence()` | 获取核心服务引用 |
| `Bus.Plugin.List()` | 列出所有已注册插件 |

### Bus 七项 DirtyFlush Exports
| Export | 描述 |
|:---|:---|
| `BusStatus` | 总线健康状态 |
| `DirtyFlushMarkDirty` | 标记玩家数据脏 |
| `DirtyFlushStats` | 刷盘统计 |
| `DirtyFlushFlushAll/FlushAllAsync` | 全量刷盘 |
| `DirtyFlushForceFlush/ForceFlushAsync` | 单玩家强制刷盘 |

---

## DirtyFlush 脏数据管道 (`cache/dirty_flush.lua`)

### 核心机制
- **脏标记**: `_dirty[citizenid] = { money_dirty, metadata_dirty, job_dirty, gang_dirty, last_flush_attempt }`
- **定时刷盘**: 每 900 秒（15 分钟，可通过 `dirty_flush_tick_interval` Convar 配置，最低 30 秒）
- **刷盘 SQL**: `INSERT INTO players (...) VALUES (...) ON DUPLICATE KEY UPDATE ...` — 原子 UPSERT
- **失败保留**: 刷盘失败时不清除 dirty 标记，下次 tick 自动重试

### 安全机制
- **PlayerDropped**: 同步 `.await` 强制刷盘 — 保证不掉数据
- **服务器关机**: 轮询 `txAdmin-stop-type` / `server_shutting_down` Convars — 检测到关机信号后两次全量刷盘（间隔 2 秒）
- **双保险**: 第一次 IterateAll + 等待 2 秒 + 第二次安全网扫描

---

## Compat 向后兼容 (`compat.lua`)

### GetPlayer 缓存包装
```lua
-- 原始: QBCore.Functions.GetPlayer(source)
-- 包装后: 内存缓存 + GetPlayerPing 活性检查
```
- `playerDropped` 时清除缓存
- `QBCore:Server:PlayerLoaded` 时填充缓存
- 每 10 分钟打印 shim vs fallback 比率统计

### AddMoney 桥接
```lua
-- 原始: Player.Functions.AddMoney(moneytype, amount, reason)
-- 桥接: Bus.EconomyService.AddMoney(citizenid, moneytype, amount, reason) (pcall)
-- 失败时回退到原始函数
```

---

## EconomyService (`services/economy_service.lua`)

| 函数 | 操作 | 特点 |
|:---|:---|:---|
| `GetBalance(source, accountType?)` | 读取余额 | 纯内存 |
| `AddScaled(source, accountType, amount, reason)` | 加钱 | ✅ 应用 `economy_wage_multiplier` 倍率、标记 DirtyFlush |
| `Transfer(fromSource, toCitizenId, amount, reason)` | 转账 | 在线→AddMoney；离线→异步 `JSON_SET` |

⚠️ **离线转账竞态**: 异步 `MySQL.update` 不等待结果就返回 true — 若 DB 宕机，发送方已扣款但接收方未到账。

---

## JobService (`services/job_service.lua`)

| 函数 | 验证 |
|:---|:---|
| `SetJob(source, jobName, grade, reason)` | ✅ `SecurityService.ValidateJobEvent` |
| `RemoveJob(source, reason)` | → SetJob(source, 'unemployed', 0) |
| `SetOnDuty(source, onDuty)` | 触发 `QBCore:Client:OnJobUpdate` |
| `SetGang(source, gangName, grade, reason)` | ✅ `SecurityService.ValidateGangEvent` |

---

## SecurityService (`services/security_service.lua`)

五层校验链的 **L0 层（输入清理与源验证）**：

| 方法 | 校验内容 |
|:---|:---|
| `SanitizeNumber(val, min, max)` | 类型强制、NaN/Inf 截断、范围裁剪 |
| `SanitizeString(val, maxLength, pattern?)` | trim、长度裁剪、正则模式匹配 |
| `ValidatePlayer(source)` | `GetPlayer(source)` + PlayerData 完整性检查 |
| `ValidateMoneyEvent(source, amount, reason)` | 金额校验、大额熔断 (>5M) |
| `ValidateJobEvent(source, jobName, grade)` | 源验证、职业白名单 |
| `ValidateGangEvent(source, gangName, grade)` | 源验证、帮派白名单 |
| `ValidateItemEvent(source, itemName, count)` | 物品名清理、数量截断 (≤100) |
| `ValidateInteraction(source, targetId, maxDistance?)` | 物理距离校验 |
| `CheckRateLimit(source, action, cooldownMs)` | 每操作冷却 |
| `LogSecurityEvent(type, data)` | 安全事件记录 |

---

## 与 qb-core 同名服务的双重实现

| 服务 | qb-core | core-framework | 关系 |
|:---|:---|:---|:---|
| economy_service | citizenid 凭证，全功能 | source 凭证，仅 AddScaled + Transfer | core-framework 是上层封装 |
| security_service | 基础校验 | 完整五层链 L0 | core-framework 更全面 |
| persistence_manager | 简单标记 | 完整 DirtyFlush 管道 | core-framework 替代 |
