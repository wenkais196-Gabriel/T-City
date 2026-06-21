# qb-core — QBCore 核心框架

> **路径**: `resources/[qb]/qb-core/` | **状态**: ✅ ENABLED | **CFG 模块**: core.cfg
> **依赖**: oxmysql, core-framework | **被依赖**: 几乎所有 qb-* 和 custom-* 资源

---

## 文件清单

| 文件 | 角色 |
|:---|:---|
| `fxmanifest.lua` | 资源清单 |
| `server/main.lua` | 核心对象创建、数据库表初始化、exports 注册 |
| `server/functions.lua` | `QBCore.Functions.*` 全部公共 API (~50 个函数) |
| `server/player.lua` | `Player` 类：登录、角色加载、存盘、登出 |
| `server/events.lua` | 核心事件处理（服务器开关、回调、玩家更新） |
| `server/services/economy_service.lua` | 纯内存金钱操作层（AddMoney/RemoveMoney/SetMoney） |
| `server/services/security_service.lua` | 安全校验层（ValidateMoneyEvent/ValidateJobEvent） |
| `server/services/persistence_manager.lua` | 持久化管理器 |
| `server/services/heat_service.lua` | 活动热度追踪 |
| `server/services/sink_service.lua` | 经济虹吸（税收等） |
| `client/events.lua` | 客户端事件处理 |
| `shared/locale.lua` | 多语言翻译表 |
| `config_blips.lua` | 地图标记配置 |

---

## 核心 Exports

### 框架级
| Export | 描述 |
|:---|:---|
| `GetCoreObject` | 返回完整 `QBCore` 表，支持 filter 参数 |
| `GetCoreVersion` | 返回框架版本号 |
| `GetSharedItems/Vehicles/Weapons/Jobs/Gangs` | 返回共享数据表 |
| `SetMethod/SetField` | 运行时扩展框架方法/字段 |
| `AddJob/AddJobs/RemoveJob/UpdateJob` | 动态职业注册 |
| `AddGang/AddGangs/RemoveGang/UpdateGang` | 动态帮派注册 |
| `AddItem/AddItems/RemoveItem/UpdateItem` | 动态物品注册 |
| `ExploitBan` | 作弊封禁（插入 bans 表 + 踢出） |

### 玩家查找 (QBCore.Functions.*)
| 函数 | 签名 |
|:---|:---|
| `GetPlayer` | `(source)` → 玩家对象 |
| `GetPlayerByCitizenId` | `(citizenid)` → 在线玩家 |
| `GetOfflinePlayerByCitizenId` | `(citizenid)` → 从 DB 加载离线玩家 |
| `GetPlayerByLicense` | `(license)` → 玩家 |
| `GetPlayerByPhone` | `(number)` → 玩家 |
| `GetPlayers` | `()` → 在线玩家 ID 数组 |
| `GetPlayersByJob` | `(job, checkOnDuty?)` → 按职业筛选 |
| `GetPlayersOnDuty` | `(job)` → 执勤玩家 |
| `GetDutyCount` | `(job)` → 执勤人数 |
| `GetClosestPlayer` | `(source, coords?)` → 最近玩家 |

### 权限与工具
| 函数 | 描述 |
|:---|:---|
| `HasPermission/AddPermission/RemovePermission` | ACE 权限管理 |
| `IsWhitelisted` | 白名单检查 |
| `Kick` | 踢出玩家 |
| `IsPlayerBanned` | 封禁检查（自动过期） |
| `Notify` | 客户端通知 |
| `TriggerClientCallback/CreateCallback` | 客户端回调系统 |
| `SpawnVehicle/CreateVehicle` | 车辆生成 |

---

## 服务端事件

| 事件 | 源验证 | 风险 | 说明 |
|:---|:---:|:---:|:---|
| `QBCore:Server:CloseServer` | ✅ | MEDIUM | 关闭服务器，踢非管理员 |
| `QBCore:Server:OpenServer` | ✅ | LOW | 重新开放服务器 |
| `QBCore:Server:TriggerCallback` | ✅ | LOW | 回调中继 |
| `QBCore:UpdatePlayer` | ✅ | MEDIUM | 更新玩家元数据（饥饿/口渴） |

---

## 经济服务 (server/services/economy_service.lua)

纯内存操作，不直接写 SQL — 通过标记 `IsDirty` 交由 PersistenceManager 异步刷盘。

| 函数 | 操作 | 安全 |
|:---|:---|:---|
| `AddMoney(citizenid, moneytype, amount, reason)` | 加钱 | 通过 `Player.Functions.AddMoney`，无独立验证 |
| `RemoveMoney(citizenid, moneytype, amount, reason)` | 扣钱 | `DontAllowMinus` 列表 + `MinusLimit` 限制 |
| `SetMoney(citizenid, moneytype, amount, reason)` | 设钱 | ✅ `Bus.SecurityService.ValidateMoneyEvent` — >500万熔断 |
| `GetMoney(citizenid, moneytype)` | 读取 | 纯内存 |
| `TransferMoney(fromCid, toCid, moneytype, amount, reason)` | 转账 | 扣→加→失败回滚 |

**触发事件链**: `QBCore:Server:OnMoneyChange` → 被 economy-dashboard, custom-logs, custom-security 等监听

---

## 安全服务 (server/services/security_service.lua)

五层校验链的一部分 (L0 层)：
- `ValidateMoneyEvent(source, amount, reason)` — 类型校验、NaN/Inf 截断、大额熔断 (>500万)
- `ValidateJobEvent(source, jobName, grade, reason)` — 源验证、职业白名单
- `ValidateGangEvent(source, gangName, grade, reason)` — 同 ValidateJobEvent
- `ValidateItemEvent(source, itemName, count, reason)` — 物品名校验、数量截断 (≤100)

---

## 数据库交互

`server/main.lua` 启动时创建/验证以下表：
- `players` — 玩家核心数据 (citizenid, license, money JSON, charinfo JSON, job/gang JSON, metadata JSON, inventory JSON, position)
- `bans` — 封禁记录
- `whitelist` — 白名单

---

## 架构备注

- qb-core 的 `economy_service` 和 `security_service` 与 `core-framework` 下的同名服务存在**双重实现** — 根据 `economy-refactor-memo`，两者需要合并
- `QBCore.Functions` 的 50 个函数通过 `for` 循环自动注册为 exports
- `PrepForSQL` 函数提供 SQL 注入模式检查
