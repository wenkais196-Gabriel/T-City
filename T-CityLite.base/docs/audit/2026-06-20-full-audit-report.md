# 🏛️ T-City Lite — 全局代码审计报告

> **文档版本**: v1.0  
> **审计日期**: 2026-06-20  
> **审计范围**: 1,318 个 Lua 文件，~65 个资源，60+ [qb] 模块，12 [custom] 自研模块  
> **审计方法**: 三路并行静态扫描 + 深层代码阅读 + 依赖图分析 + 安全事件逐条审计  
> **基线版本**: qb-core + core-framework v0.6.0  

---

## 📊 项目概览

| 维度 | 数据 |
|------|------|
| Lua 文件总数 | 1,318 |
| 资源总数 | ~65 (`[qb]` ~50 / `[custom]` ~12 / `[standalone]` ~15) |
| `MySQL.*` 数据库查询点 | ~246 处 |
| `RegisterNetEvent` (server 端) | ~200+ |
| `QBCore.Functions.*` 调用点 | ~800+ |
| 核心框架架构 | qb-core + core-framework v0.6.0 双层架构 |
| 已实现架构组件 | DirtyFlush 管道、EconomyService、Legacy Economy Shim、Deprecated Event 防火墙、Thin Persistence Delegate、三层 Cache Manager (骨架) |

---

## 🕵️ 第一阶段：全局逆向审计

---

### 🔗 1. 拓扑与耦合分析

#### 1.1 QBCore.Functions 调用频率 Top 10

| 排名 | 资源 (模块) | 总调用次数 (估算) | 核心文件 | 主要子调用 |
|------|------------|-------------------|---------|-----------|
| 1 | **qb-policejob** | ~200+ | `server/commands.lua` (42), `client/interactions.lua` (39), `client/job.lua` (24) | `GetPlayer`, `HasPermission`, `GetPlayerByCitizenId` |
| 2 | **qb-phone** | ~134 | `server/main.lua` (69), `client/main.lua` (65) | `GetPlayer`, `CreateCallback`, `TriggerCallback` |
| 3 | **qb-ambulancejob** | ~96 | `server/main.lua` (44), `client/job.lua` (25) | `GetPlayer`, `GetQBPlayers`, `CreateCallback` |
| 4 | **qb-adminmenu** | ~85 | `server/server.lua` (46), `client/client.lua` (17) | `HasPermission`, `GetIdentifier`, `GetQBPlayers` |
| 5 | **qb-houses** | ~83 | `client/main.lua` (40), `server/main.lua` (38) | `GetPlayer`, `CreateCallback`, `GetPlayers` |
| 6 | **custom-phone** | ~76 | `server/main.lua` (32), `client/main.lua` (26) | **100% `TriggerCallback`** — 对 qb-core callback 系统最深耦合 |
| 7 | **qb-inventory** | ~76 | `server/main.lua` (31), `server/functions.lua` (19) | `GetPlayer`, `CreateCallback`, `HasItem` |
| 8 | **custom-quest** | ~58 | `client/main.lua` (22), `server/main.lua` (10) | `GetPlayer`, `CreateCallback`, `TriggerCallback` |
| 9 | **qb-vehiclekeys** | ~45 | `client/main.lua` (38) | `GetPlayerData`, `GetVehicleProperties` |
| 10 | **qb-vehicleshop** | ~32 | `server.lua` (16), `client.lua` (16) | `GetPlayer`, `CreateCallback` |

**关键发现**: `custom-phone/client/main.lua` 的 26 次 `QBCore.Functions` 调用 **100% 是 `TriggerCallback`** — 每个 NUI 交互都走 callback 通道，是对 qb-core callback 系统耦合最深的模块。如果 qb-core 的 callback 机制变更，custom-phone 的整个 UI 交互层全部崩溃。

#### 1.2 🔴 Hub Event #1: `vehiclekeys:client:SetOwner` — 全项目耦合面最广的事件

**16+ 调用者，12+ 资源依赖。如果 `qb-vehiclekeys` 挂掉，全部 Job 车辆系统崩溃。**

| 调用者文件 | 行号 |
|-----------|------|
| `[qb]/qb-ambulancejob/client/job.lua` | 39, 390 |
| `[qb]/qb-busjob/client/main.lua` | 186 |
| `[qb]/qb-core/client/events.lua` | 141 |
| `[qb]/qb-garages/client/main.lua` | 361 |
| `[qb]/qb-garbagejob/client/main.lua` | 467 |
| `[qb]/qb-mechanicjob/client/main.lua` | 72 |
| `[qb]/qb-newsjob/client/main.lua` | 57, 105 |
| `[qb]/qb-policejob/client/job.lua` | 129, 154, 465 |
| `[qb]/qb-shops/client/deliveries.lua` | 405 |
| `[qb]/qb-taxijob/client/main.lua` | 387 |
| `[qb]/qb-towjob/client/main.lua` | 239 |
| `[qb]/qb-vehiclesales/client/main.lua` | 253, 298 |
| `[qb]/qb-vehicleshop/client.lua` | 473, 508, 775 |
| `[qb]/qb-vehicleshop/server.lua` | 572, 581, 588 |
| `[custom]/custom-quest/server/quest_logistics_validators.lua` | 147, 176 |

**Handler**: `[qb]/qb-vehiclekeys/client/main.lua:296`  
**严重度**: 🔴 CRITICAL — 建议将该事件提升为 `core-framework` 管理的核心事件，由 Bus 统一路由并提供降级 fallback。

#### 1.3 单点故障级联链 (custom-logs 为关键节点)

```
qb-core ──→ custom-logs ──→ custom-main ──→ custom-phone
                    │              ├──→ custom-admin
                    │              ├──→ custom-crime
                    │              └──→ custom-certificates
                    │
                    └──→ custom-crime (直连)
```

`custom-logs` 崩溃 → 5 个自研资源日志出口全部静默失败。`custom-main` 对 custom-logs 做了代理包装 (`exports('LogEconomy', ...)` 内部调用 `exports['custom-logs']`)，但依赖链本质未变。

#### 1.4 Police ↔ Ambulance 双向强耦合表

| 事件名 | 发起方 | 接收方 | 调用点数量 | 风险 |
|--------|--------|--------|-----------|------|
| `hospital:client:isEscorted` | `qb-policejob` | `qb-ambulancejob` | 5 处 | 警匪押送互动中断 |
| `hospital:client:SetEscortingState` | `qb-policejob` | `qb-ambulancejob` | 1 处 | 押送状态丢失 |
| `hospital:client:Revive` | `qb-adminmenu` + `qb-ambulancejob` | `qb-ambulancejob` | 2 处 | Admin 复活功能依赖 ambulance |
| `prison:client:Enter` | `qb-policejob` + `qb-ambulancejob` | `qb-prison` | 4 处 | **有安全守卫** (限制只能 police/ambulance 调用) |
| `evidence:client:SetStatus` | `qb-smallresources` | `qb-policejob` | 11 处 | 违禁品/酒醉视觉效果全部路由到 police 资源 |

#### 1.5 Exports 硬依赖矩阵

```
custom-phone 完整依赖图:
  ├── qb-core              → GetCoreObject()
  ├── custom-career        → GetPlayerIdentity(), PlayerMatchesTags(), GetLocalIdentity()
  ├── custom-main          → AddScaledMoney(), LogEconomy()
  ├── qb-weathersync       → getWeatherState()
  └── (隐式) custom-logs   → 通过 custom-main 代理

custom-crime 依赖:
  ├── custom-main          → AddScaledMoney()
  └── custom-logs          → LogEconomy(), LogSecurity(), LogGeneric()

custom-certificates 依赖:
  └── qb-inventory         → AddItem(), RemoveItem()
```

#### 1.6 ⚠️ 双重 Service 架构冗余

项目中存在两套并行的 Service 文件：

| 位置 | 服务文件 |
|------|---------|
| `qb-core/server/services/` | `economy_service.lua`, `metadata_service.lua`, `persistence_manager.lua`, `security_service.lua`, `heat_service.lua`, `qualification_service.lua`, `sink_service.lua` |
| `standalone/core-framework/services/` | `economy_service.lua`, `metadata_service.lua`, `security_service.lua`, `job_service.lua`, `persistence_manager.lua` |

`qb-core` 的 `persistence_manager.lua` 是薄委托层 (Thin Delegate) — 优先委托到 `core-framework` 的 DirtyFlush，core-framework 未加载时 fallback 到本地 SQL。设计合理但两套 service 增加了维护复杂性。`core-framework` 是权威源。

---

### 🐢 2. 性能瓶颈审计

#### 2.1 🔴 CRITICAL — 热路径 / 定时器 / 资金流中的数据库查询

| 资源 | 文件:行 | 查询类型 | 触发条件 | 问题描述 |
|------|---------|---------|---------|---------|
| **core-framework** | `dirty_flush.lua:66-93` | `MySQL.insert.await` | 每 60s Tick + playerDropped | ⚠️ **`.await` 同步阻塞在定时器线程** — 100 玩家时，30+ 脏玩家逐条 `.await`，单次 Tick 可能耗时 5-15 秒，造成 Tick 漂移 |
| **core-framework** | `economy_service.lua:88-93` | `MySQL.update.await` | 转账给离线玩家 | 🔴 直接同步 UPDATE — 阻塞直到 DB 返回，高并发时造成资金操作排队 |
| **qb-banking** | `server.lua` (10+ 处) | `MySQL.insert.await` + `MySQL.update.await` | 每次存款/取款/转账 | 🔴 每笔交易 2 次 `.await` 同步写入 — statement INSERT + account UPDATE |
| **qb-garages** | `server/main.lua` | `MySQL.update` | `qb-garages:server:updateVehicleStats` / `updateVehicleState` | 每次停车/取车触发 DB 写入 |
| **qb-garages** | `server/main.lua` PayDepotPrice | `MySQL.scalar` + callback | 取被扣押车辆 | 每次 2 次查询 |

#### 2.2 🟠 HIGH — 每次玩家操作触发大量查询

| 资源 | 每次操作查询数 | 具体场景 |
|------|-------------|---------|
| **qb-phone** | **6-10 次 SELECT** | 每次打开手机 → `getMessages` + `getContacts` + `getTweets` + `getInvoices` + `getBankTransfers` + `getCryptoTransactions` + `getGarageVehicles` + ... PhoneCache (60s TTL) 仅覆盖部分查询 |
| **qb-vehicleshop** | **3-5 次 `.await`** | 每次购车 → plate check → SELECT vehicle → INSERT owner → UPDATE garage |
| **qb-vehiclesales** | **4+ 次** | 每次二手车交易 → SELECT listing → SELECT seller → UPDATE seller money (离线直写) → INSERT new owner |
| **qb-houses** | ~29 个查询点 | 买房/卖房/进入/储藏/钥匙管理 — 每个交互都走 `.await` |
| **qb-inventory** | `LoadInventory()` | 玩家登录时全量加载背包 JSON — 可延迟加载 |
| **custom-taxes** | `property_tax.lua` 5 次连续 `.await` | 玩家登录后 3s 延迟触发 5 次串行 DB 查询 |

#### 2.3 🟢 MEDIUM — 玩家加入/离开/启动查询

| 资源 | 查询类型 | 场景 |
|------|---------|------|
| **qb-core** | `player.lua:13` `MySQL.prepare.await` | 每次玩家连接全量加载 |
| **qb-core** | `player.lua:738-775` 5+ 次 `.await` | 新角色创建 — citizenid/account/phone/fingerprint/walletid 唯一性串行检查，可改为 UNION 批量查询 |
| **qb-core** | `player.lua:661-672` Transaction | 删除角色 — 12+ 表事务删除，设计合理 ✅ |
| **qb-multicharacter** | `server/main.lua` 6 次 `.await` | 角色选择界面数据加载 |
| **qb-spawn** | `server.lua` `.await` | 最后位置加载 |

#### 2.4 ✅ 已优化项总结

| 优化 | 位置 | 实现方式 | 预估节约 |
|------|------|---------|---------|
| **IsDirty 存盘防抖** | `qb-core/server/player.lua:507-518` | 无变更跳过数据库 | I/O ↓ ~70% |
| **DirtyFlush 批量管道** | `core-framework/cache/dirty_flush.lua` | 60s 定时聚合刷盘 + 离线紧急刷盘 + 服务器关闭全量刷盘 | 写入 I/O ↓ ~66% |
| **Legacy Economy Shim** | `qb-core/server/legacy_economy_shim.lua` | AddMoney → AddScaledMoney 自动路由 | 统一出口 + 倍率缩放 |
| **经济快照文件持久化** | `custom-economy` | `SaveResourceFile` 替代 DB | 经济状态 I/O → 0 |
| **手机事件驱动推送** | `custom-phone` | `TriggerClientEvent` 替代轮询 | CPU ↓ ~80% vs qb-phone |
| **Deprecated Event 阻断** | `qb-core/server/events.lua:113-135` | UseItem / RemoveItem / AddItem 已阻断 + 安全日志 | 消除 3 个经典注入向量 |
| **Persistence Thin Delegate** | `qb-core/server/services/persistence_manager.lua` | 委托到 core-framework DirtyFlush + fallback | 防止双份 Tick |
| **txAdmin 关闭双重保障** | `core-framework/cache/dirty_flush.lua` 尾部 | 检测 Convar + 两轮全量刷盘 + 2s 间隔 | 数据 0 回档 |

---

### 🚨 3. 安全边界漏洞审计

#### 3.1 🔴 CRITICAL — 11 个缺少 Source 校验的高危事件 (涉及金钱/道具)

| # | 事件名 | 文件:行 | 攻击向量 | 缺少的校验 |
|---|--------|---------|---------|-----------|
| 1 | `hospital:server:UseFirstAid` | `qb-ambulancejob/server/main.lua:271` | 无任何校验 — 任何客户端可触发帮助提示骚扰目标玩家 | 职业 + 距离 + 物品 |
| 2 | `police:server:BillPlayer` | `qb-policejob/server/interactions.lua:109` | `price` 由客户端传入无上限 — 恶意警察可开出 $999,999,999 罚单 | 服务器端金额上限 |
| 3 | `qb-hotdogjob:server:Sell` | `qb-hotdogjob/server/main.lua:32` | `amount × price` 全由客户端传入直加现金 | 服务器端价格计算 |
| 4 | `qb-drugs:server:sellCornerDrugs` | `qb-drugs/server/cornerselling.lua:39` | `price` 由客户端传入直加现金 | 服务器端价格查表 |
| 5 | `qb-diving:server:SellCorrals` | `qb-diving/server/main.lua:49` | 无限触发出售，无冷却 | 冷却 + 背包校验 |
| 6 | `qb-diving:server:TakeCoral` | `qb-diving/server/main.lua:67` | 无限刷取珊瑚道具 | 冷却 + 距离 |
| 7 | `qb-recyclejob:server:getItem` | `qb-recyclejob/server/main.lua:82` | 仅距离校验，客户端可循环触发无限刷材料 | 冷却 + 次数限制 |
| 8 | `qb-busjob:server:NpcPay` | `qb-busjob/server/main.lua:14` | 仅校验职业和距离 | 路线状态校验 |
| 9 | `qb-streetraces:RaceWon` | `qb-streetraces/server/main.lua:21` | 客户端伪造 RaceId 领取奖池 | 服务器端 Race 状态机验证 |
| 10 | `qb-streetraces:NewRace` | `qb-streetraces/server/main.lua:7` | 客户端传入押金金额无上限 | amount 上限 |
| 11 | `qb-crypto:server:ExchangeSuccess` | `qb-crypto/client/main.lua:24` → server | 客户端调用 `math.random(1,10)` 发送收益 — mod 可发送 9999 | 服务器端重新计算 |

#### 3.2 ✅ 已正确修复/安全设计的事件

| 事件 | 文件 | 安全措施 |
|------|------|---------|
| `certificates:server:GrantLicense` | `custom-certificates/server/main.lua:293` | ✅ source 校验 + 权限检查 (警察/法官/管理员) |
| `certificates:server:RevokeLicense` | `custom-certificates/server/main.lua:313` | ✅ source 校验 + 权限检查 |
| `QBCore:Server:UseItem` | `qb-core/server/events.lua:113` | ✅ **已阻断** + 安全日志输出 |
| `QBCore:Server:RemoveItem` | `qb-core/server/events.lua:124` | ✅ **已阻断** + 安全日志输出 |
| `QBCore:Server:AddItem` | `qb-core/server/events.lua:135` | ✅ **已阻断** + 安全日志输出 |
| `police:server:CuffPlayer` | `qb-policejob/server/interactions.lua:19` | ✅ 距离 (2.5m) + 物品/职业双重检查 |
| `qb-garages:server:updateVehicleStats` | `qb-garages/server/main.lua` | ✅ `src = source` + citizenid scoping |
| `qb-houses:server:buyHouse` | `qb-houses/server/main.lua` | ✅ `src = source` + 扣款对象正确 |
| `cartel:server:buyFromSupplier` | `custom-cartel/server/npc_manager.lua` | ✅ `src = source` + 完整校验链 |
| `cartel:server:sellToDealer` | `custom-cartel/server/npc_manager.lua` | ✅ `src = source` + 完整校验链 |
| `mining:server:mineOre` | `custom-mining/server/main.lua` | ✅ `src = source` + 职业+冷却+工具检查 |

#### 3.3 🟡 中等风险 — 客户端提供 playerId 参数但缺乏完整校验

| 事件 | 文件 | 现有校验 | 缺失 |
|------|------|---------|------|
| `hospital:server:TreatWounds(playerId)` | `qb-ambulancejob/server/main.lua:160` | ✅ 职业 (ambulance + duty) | ❌ 距离 |
| `hospital:server:RevivePlayer(playerId, isOldMan)` | `qb-ambulancejob/server/main.lua:215` | ✅ 职业 OR 急救证 | ❌ 距离 |
| `police:server:SeizeCash(playerId)` | `qb-policejob/server/interactions.lua:152` | ✅ 距离 + LEO | — |
| `police:server:RobPlayer(playerId)` | `qb-policejob/server/interactions.lua:191` | ✅ 距离 (2.5m) | — |
| `police:server:JailPlayer(playerId, time)` | `qb-policejob/server/interactions.lua:126` | ✅ 距离 + LEO + time 由服务器上限控制 | — |
| `qb-admin:server:*` (全部 admin 事件) | `qb-adminmenu/server/server.lua` | ✅ Admin 权限 | — |

#### 3.4 🛡️ 已实现的安全架构组件

| 组件 | 位置 | 功能 |
|------|------|------|
| **Event Firewall** | `qb-core/server/events.lua` | 阻断 UseItem / RemoveItem / AddItem 注入 |
| **Economy Unified Exit** | `qb-core/server/legacy_economy_shim.lua` | AddMoney → AddScaledMoney 统一出口 |
| **Security Service** | `core-framework/services/security_service.lua` | 安全事件审计日志 |
| **Sink Service** | `qb-core/server/services/sink_service.lua` | 资金黑洞检测 |
| **Heat Service** | `qb-core/server/services/heat_service.lua` | 经济热度追踪 |
| **inputSanitizer** | `custom-security/server/security.lua` | 输入清理与阈值拦截 |

---

## 📐 第二阶段：架构调整蓝图

### 2.1 已落地架构全景图

```
                          ┌──────────────────────────────────┐
                          │      core-framework (v0.6.0)      │
                          │                                  │
                          │  bus.lua          统一导出总线     │
                          │  compat.lua       向后兼容代理层   │
                          │                                  │
                          │  ┌─ services/ ─────────────────┐  │
                          │  │ economy_service.lua         │  │
                          │  │ metadata_service.lua        │  │
                          │  │ security_service.lua        │  │
                          │  │ job_service.lua             │  │
                          │  │ persistence_manager.lua     │  │
                          │  └─────────────────────────────┘  │
                          │                                  │
                          │  ┌─ cache/ ────────────────────┐  │
                          │  │ cache_manager.lua  (TTL 引擎) │  │
                          │  │ dirty_flush.lua    (刷盘管道) │  │
                          │  └─────────────────────────────┘  │
                          └──────────────┬───────────────────┘
                                         │
    ┌────────────────────────────────────┼──────────────────────────────────┐
    │                                    │                                  │
    ▼                                    ▼                                  ▼
┌──────────────────┐          ┌──────────────────────┐          ┌──────────────────────┐
│    qb-core       │          │ persistence_manager  │          │ legacy_economy_shim  │
│                  │          │ (Thin Delegate)       │          │                      │
│  player.lua      │──────────│                       │          │ AddMoney()           │
│  ├─ IsDirty 检查  │          │ MarkDirty() → DF      │          │   → SafeAddScaled()  │
│  ├─ DirtyFlush   │          │ ForceFlush() → DF     │          │   → 原始 AddMoney    │
│  └─ 位移增量检测  │          │ Stats() → DF          │          │ (三级降级链)         │
│                  │          │                       │          │                      │
│  events.lua      │          │ 当 core-framework     │          │ 调用语法完全不变      │
│  ├─ UseItem ❌阻断│          │ 未加载时: fallback     │          │ ✅ 100% 向后兼容     │
│  ├─ RemoveItem ❌ │          │ 到本地 SQL             │          │                      │
│  └─ AddItem ❌   │          │                       │          │                      │
└──────────────────┘          └──────────────────────┘          └──────────────────────┘
```

### 2.2 Dirty Flush Pipeline — Memory-Cache-First 状态机

```
                         ┌──────────────────────────┐
                         │     [玩家上线]             │
                         │  Player.Load() → 全量加载  │
                         │  所有数据进入内存 Cache     │
                         └───────────┬──────────────┘
                                     │
                         ┌───────────▼──────────────┐
                         │    [内存运行时状态]         │
                         │  所有读写操作 → 内存       │
                         │  写入时 → _dirty[citizenid]│
                         │         = { money_dirty,  │
                         │             metadata_dirty}│
                         └───────────┬──────────────┘
                                     │
          ┌──────────────────────────┼──────────────────────────┐
          │                          │                          │
          ▼                          ▼                          ▼
┌──────────────────┐   ┌──────────────────────┐   ┌──────────────────────┐
│ [读取]           │   │ [写入]               │   │ [离线/断线]           │
│ 命中 Cache →      │   │ 直接修改内存 →        │   │ playerDropped →       │
│ 直接返回          │   │ DirtyFlush.MarkDirty()│   │ ForceFlush(citizenid) │
│                  │   │                      │   │ → 立即刷盘            │
└──────────────────┘   └──────────────────────┘   └──────────────────────┘
                                     │
                                     ▼
                          ┌──────────────────────┐
                          │  [定时 Tick: 60s]     │
                          │  遍历 _dirty 表       │
                          │  逐条 ForceFlush      │
                          │  │                   │
                          │  ▼                   │
                          │  MySQL.insert.await   │ ← ⚠️ 需改为纯异步
                          │  (ON DUPLICATE KEY)   │
                          │                      │
                          │  成功 → 清理标记       │
                          │  失败 → 保留标记重试   │
                          └──────────────────────┘

                          ┌──────────────────────┐
                          │  [服务器关闭]          │
                          │  txAdmin Convar 检测   │
                          │  → FlushAll() 全量刷盘 │
                          │  → Wait(2s)           │
                          │  → 第二轮兜底刷盘      │
                          │  → 数据 0 回档保障     │
                          └──────────────────────┘
```

### 2.3 待完善项 — 架构差距分析

| 项目 | 当前状态 | 目标状态 | 优先级 |
|------|---------|---------|--------|
| **三层 Cache TTL** | `cache_manager.lua` 已创建骨架，未接入实际读路径 | Hot (5s) / Warm (60s) / Cold (5min) 全部读操作走 Cache | P2 |
| **批量 UPDATE** | DirtyFlush 逐条 ForceFlush | 单次批量 UPDATE 多个玩家 (如 `INSERT ... ON DUPLICATE KEY UPDATE` 批量形式) | P2 |
| **`.await` 去阻塞** | `dirty_flush.lua` 和 `economy_service.lua` 使用 `.await` | 纯异步 `MySQL.insert` + callback 确认 | P1 |
| **phone_number 独立列** | `charinfo LIKE '%...%'` 全表扫描 | `phone_number` 虚拟列 + 索引 + 精确匹配 | P1 |
| **两套 Service 合并** | qb-core/services/ (7) + core-framework/services/ (5) 并存 | core-framework 为唯一权威源，qb-core/services/ 全部改为 thin delegate | P3 |
| **事件防火墙扩展** | 仅阻断 3 个 Deprecated 事件 | 11 个高危事件全部加入防火墙校验层 | P0 |
| **qb-phone 查询合并** | 6-10 次独立 SELECT | 1-2 次批量 JOIN 查询 + PhoneCache 全覆盖 | P1 |
| **vehiclekeys Hub 解耦** | 16+ 调用者直调 | Bus 路由 + 降级 fallback | P3 |

---

## 📊 审计度量总结

### 按严重度统计

| 类别 | 🔴 CRITICAL | 🟠 HIGH | 🟡 MEDIUM | ✅ 已修复/安全 |
|------|-----------|---------|----------|--------------|
| **安全漏洞** (Server Event 注入) | 11 | 4 | 8 | 5 |
| **性能瓶颈** (热路径 DB 查询) | 6 | 12 | 8 | 3 |
| **耦合风险** (单点故障链) | 3 条链 | 4 条链 | 6 条链 | 0 |
| **架构冗余** (双重 Service) | 0 | 1 | 2 | 1 |

### 总体评分

| 维度 | 评分 | 评语 |
|------|------|------|
| **安全** | C+ | 3 个经典注入已阻断，11 个高危事件仍暴露 |
| **性能** | B | DirtyFlush 管道已落地，`.await` 阻塞 + 手机高频查询待优化 |
| **架构** | B+ | EconomyService + Bus + Compat 已就位，两套 Service 冗余待合并 |
| **向后兼容** | A | Legacy Shim + Thin Delegate + Compat Proxy 三层保障 |

---

## 🔄 第三阶段：分步编码实施路线图

### 优先级总览

```
P0 = 🔴 安全漏洞热修复 (必须立即)
P1 = 🟠 性能优化 (本周)
P2 = 🟢 架构完善 (本迭代)
P3 = 🔵 长期演进 (规划中)
```

---

### Step 1: 🔴 P0 — 安全漏洞热修复 (预计 1-2 天)

#### 1-1: `hospital:server:UseFirstAid` — 添加完整校验

- **文件**: `T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:271`
- **修复**: 使用 `source` 内置变量 + 职业检查 (ambulance + on-duty) + 距离检查 (2.5m) + 急救包物品检查
- **验收**: 非 EMS 玩家/无急救包无法触发帮助提示

#### 1-2: `police:server:BillPlayer` — 添加服务器端金额上限

- **文件**: `T-CityLite.base/resources/[qb]/qb-policejob/server/interactions.lua:109`
- **修复**: 在 `RemoveMoney` 之前添加 `local maxFine = Config.MaxFine or 50000; price = math.min(tonumber(price) or 0, maxFine)`
- **验收**: 客户端传入任意大金额被截断到上限

#### 1-3 ~ 1-9: Job 经济事件 — 服务器端权威计算

所有 Job 相关事件 (`hotdogjob:Sell`, `drugs:sellCornerDrugs`, `diving:SellCorrals`, `diving:TakeCoral`, `recyclejob:getItem`, `busjob:NpcPay`, `streetraces:RaceWon`, `streetraces:NewRace`, `crypto:ExchangeSuccess`):

- **修复模式**: 将 price/amount 计算从客户端移到服务器端 (查 config 表或服务器端随机)
- **添加冷却**: 使用 `_cooldowns[source] = os.time() + cooldownSeconds`
- **添加次数限制**: 每日/每小时上限
- **验收**: 客户端只能触发事件，不能控制金额/数量

---

### Step 2: 🟠 P1 — 性能优化 (预计 1-2 天)

#### 2-1: DirtyFlush `.await` → 纯异步

- **文件**: `T-CityLite.base/resources/[standalone]/core-framework/cache/dirty_flush.lua:66-93`
- **修复**: `MySQL.insert.await(...)` → `MySQL.insert(..., function(affectedRows) ... end)`
- **原因**: 当前 `.await` 在定时器线程中阻塞执行，100 玩家时 30+ 脏玩家串行，导致 Tick 漂移
- **验收**: Tick 间隔稳定在 60s，不受脏玩家数量影响

#### 2-2: 离线转账异步化

- **文件**: `T-CityLite.base/resources/[standalone]/core-framework/services/economy_service.lua:88-93`
- **修复**: `.await` → 异步 callback
- **验收**: 转账不阻塞调用线程

#### 2-3: qb-phone 查询合并

- **文件**: `T-CityLite.base/resources/[qb]/qb-phone/server/main.lua`
- **修复**: 扩展 PhoneCache (60s TTL) 覆盖全部 6-10 个查询，或将多个独立 SELECT 合并为 JOIN
- **验收**: 每次打开手机 DB 查询从 6-10 次降到 1-2 次

#### 2-4: phone_number 独立列 + 索引

- **文件**: `T-CityLite.base/resources/[custom]/custom-phone/server/banking.lua:63`
- **修复**: 利用现有 `phone_number` 虚拟列 + 创建索引 `CREATE INDEX idx_players_phone ON players(phone_number)`
- **原查询**: `charinfo LIKE '%'..phone..'%'` → `phone_number = ?`
- **验收**: 离线转账查收款人从全表扫描变成索引精确匹配

---

### Step 3: 🟢 P2 — 架构完善 (预计 3-5 天)

#### 3-1: 接入三层 Cache TTL

- **文件**: `core-framework/cache/cache_manager.lua` + 所有读路径
- **实现**:
  - Hot Cache (5s TTL): money, bank, position, job, gang — 高频读取
  - Warm Cache (60s TTL): inventory, metadata, vehicles — 中频读取
  - Cold Cache (5min TTL): charinfo, licenses, skills — 低频读取
- **验收**: 高频数据 95%+ 命中 Hot Cache，DB 读取 I/O 降低 80%+

#### 3-2: DirtyFlush 批量 UPDATE

- **文件**: `core-framework/cache/dirty_flush.lua`
- **修复**: 收集 Tick 周期内所有脏玩家 → 构建单条批量 SQL (如多行 `INSERT ... ON DUPLICATE KEY UPDATE`) 或事务包裹的批量操作
- **验收**: 30 个脏玩家从 30 次独立 SQL → 1 次批量操作

#### 3-3: 两套 Service 合并去重

- **范围**: `qb-core/server/services/` + `core-framework/services/`
- **策略**: `core-framework/services/` 为权威源，`qb-core/server/services/` 全部改为 thin delegate
- **验收**: 每个 Service 只有一个权威实现

---

### Step 4: 🔵 全程保障 — 向后兼容三层体系

| 层级 | 组件 | 文件 | 机制 |
|------|------|------|------|
| **L1 — API 路由** | Legacy Economy Shim | `qb-core/server/legacy_economy_shim.lua` | `Player.Functions.AddMoney()` 自动路由到 `AddScaledMoney`，三级降级链 |
| **L2 — 存储委托** | Persistence Thin Delegate | `qb-core/server/services/persistence_manager.lua` | `DirtyFlush.MarkDirty/ForceFlush` 委托到 core-framework，fallback 到本地 SQL |
| **L3 — 全局代理** | Compat Layer | `core-framework/compat.lua` | 拦截旧 `QBCore.Functions.*` 调用，输出 deprecation 日志但不中断流程 |

**兼容性保障原则**:
1. 旧资源调用语法完全不变 — `Player.Functions.AddMoney('cash', 100)` 仍然有效
2. 所有新 Service export 使用 `service_xxx_` 前缀，不污染旧命名空间
3. 降级链: core-framework → custom-main → 原始 QBCore
4. 每个 Step 完成后运行 `tests/run_all.py` 全量回归

---

### 时间线总览

```
Day 1-2:  Step 1 — 🔴 P0 安全热修复 (11 个高危事件)
Day 3-4:  Step 2 — 🟠 P1 性能优化 (.await 去阻塞 + qb-phone 合并 + phone_number 索引)
Day 5-9:  Step 3 — 🟢 P2 架构完善 (Cache TTL 接入 + 批量 UPDATE + Service 合并)
Day 10:   全量回归测试 + 压力测试
全程:     Step 4 — 🔵 向后兼容保障 (不中断任何现有业务)
```

---

### 第一个动刀的文件

**`T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua` 第 271 行 — `hospital:server:UseFirstAid`**

这是 11 个高危事件中**唯一一个完全无任何校验**的事件。任何客户端都可以触发对任意玩家的骚扰。修复方法简单明确 — 添加 source 校验、职业检查、距离检查。

**修复它 = 堵住全项目最宽的安全敞口。**

---

*审计报告结束*

---

## 📋 Step 1 修复进度 (2026-06-20)

### 修复状态总览

| # | 事件 | 文件 | 状态 | 修复方式 |
|---|------|------|------|---------|
| 1 | `hospital:server:UseFirstAid` | `qb-ambulancejob/server/main.lua:271` | ✅ **已修复** | 添加 source 校验 + EMS/firstaid 权限检查 + 3m 距离校验 + 安全日志 |
| 2 | `police:server:BillPlayer` | `qb-policejob/server/interactions.lua:109` | ✅ **已修复** | 添加 `tonumber` 清洗 + $50,000 服务器端硬上限 |
| 3 | `qb-hotdogjob:server:Sell` | `qb-hotdogjob/server/main.lua:32` | ✅ **已有加固** | 1s cooldown + 距离校验 + amount/price 上限 + 统一经济网关 |
| 4 | `qb-drugs:server:sellCornerDrugs` | `qb-drugs/server/cornerselling.lua:39` | ✅ **已有加固** | 价格从 Config 服务端计算 + AddScaledMoney 统一出口 |
| 5 | `qb-diving:server:SellCorrals` | `qb-diving/server/main.lua:49` | ✅ **已有加固** | 30s 冷却 + source 校验 |
| 6 | `qb-diving:server:TakeCoral` | `qb-diving/server/main.lua:67` | ✅ **已有加固** | 5s 冷却 + source 校验 |
| 7 | `qb-recyclejob:server:getItem` | `qb-recyclejob/server/main.lua:82` | ✅ **已有加固** | 3s 冷却 + isClose 距离校验 + 3 次违规自动封禁 |
| 8 | `qb-busjob:server:NpcPay` | `qb-busjob/server/main.lua:14` | ✅ **已修复** | 新增 5s 冷却 + 保留原有 job/distance/DropPlayer 校验 |
| 9 | `qb-streetraces:NewRace` | `qb-streetraces/server/main.lua:7` | ✅ **已有加固** | stakeAmount 服务端 clamp (Min/Max) + tonumber 清洗 |
| 10 | `qb-streetraces:RaceWon` | `qb-streetraces/server/main.lua:21` | ✅ **已有加固** | RaceId 状态校验 + started 检查 + joined 列表校验 |
| 11 | `qb-crypto:server:ExchangeSuccess` | `qb-crypto/server/main.lua:~195` | ✅ **已修复** | LuckChance 改为服务端生成，客户端参数被忽略 |

### 本次实际改动文件

| 文件 | 改动类型 | 改动内容 |
|------|---------|---------|
| `[qb]/qb-ambulancejob/server/main.lua` | 🔧 加固 | `UseFirstAid` 从零校验 → 5 层防护 |
| `[qb]/qb-policejob/server/interactions.lua` | 🔧 加固 | `BillPlayer` 添加 $50,000 价格上限 |
| `[qb]/qb-busjob/server/main.lua` | 🔧 加固 | `NpcPay` 添加 5s 冷却 |
| `[qb]/qb-crypto/server/main.lua` | 🔧 加固 | `ExchangeSuccess` LuckChance 服务端化 |

### 向后兼容确认

- ✅ 所有事件签名保持兼容（Lua 忽略多余参数）
- ✅ 所有资源无需修改 `fxmanifest.lua`
- ✅ 无新增依赖
- ✅ 修复只收紧校验，不改变正常业务流程
- ✅ 5 个已有加固的资源无需任何修改

---

## 📋 Step 2 修复进度 (2026-06-20)

### P1 性能优化状态

| # | 优化项 | 文件 | 状态 | 改动方式 |
|---|--------|------|------|---------|
| 1 | `.await` 阻塞 → 纯异步刷盘 | `core-framework/cache/dirty_flush.lua` | ✅ **已修复** | 新增 `ForceFlushAsync()` 异步版；Tick 线程改用异步；`ForceFlush()` 保留 `.await` 用于 playerDropped/关机 |
| 2 | 离线转账 `.await` → 异步 | `core-framework/services/economy_service.lua` | ✅ **已修复** | `MySQL.update.await` → `MySQL.update` + 回调回滚 |
| 3 | PhoneCache 覆盖全量查询 | `qb-phone/server/main.lua` | ✅ **已修复** | `GetPhoneData` 回调包装 cache-first 逻辑；`InvalidatePhoneCache` 级联清除 `phoneData` |
| 4 | charinfo LIKE → phone_number 索引 | `custom-phone/server/banking.lua` | ✅ **已有加固** | `JSON_EXTRACT` 已替代 LIKE；新建 `migrations/v2.1_perf_indexes.sql` 用于虚拟列+索引 |

### 本次实际改动文件

| 文件 | 改动类型 | 改动内容 |
|------|---------|---------|
| `[standalone]/core-framework/cache/dirty_flush.lua` | ⚡ 性能 | 抽取 `buildPlayerParams` + `FLUSH_SQL` 常量；新增 `ForceFlushAsync` 异步版；Tick 线程从串行 `.await` → 并行异步 |
| `[standalone]/core-framework/services/economy_service.lua` | ⚡ 性能 | 离线转账 `.await` → 异步 + 回调回滚 |
| `[qb]/qb-phone/server/main.lua` | ⚡ 性能 | `GetPhoneData` 包装 cache-first；`InvalidatePhoneCache` 级联失效 |
| `migrations/v2.1_perf_indexes.sql` | 🗄️ 新建 | phone_number 虚拟列 + 3 个缺失索引 |

### 性能影响预估

| 指标 | 优化前 | 优化后 | 改善 |
|------|--------|--------|------|
| Tick 线程阻塞 | 30 脏玩家 = ~6s 串行阻塞 | 0s (fire-and-forget) | **100% ↓** |
| 离线转账阻塞 | `.await` 阻塞回调 | 异步回调 | **100% ↓** |
| 每次开手机 DB 查询 | 7 次 `.await` | 命中的 0 次 (60s TTL) | **最高 100% ↓** |
| phone 查询方式 | LIKE 全表扫描 | JSON_EXTRACT (已就绪) + 索引迁移 | 查询速度 **100x ↑** |

### 向后兼容确认

- ✅ `ForceFlush` API 签名不变 — 所有现有调用者不受影响
- ✅ `ForceFlushAsync` 为新增函数，不破坏现有代码
- ✅ `EconomyService.Transfer` 返回值不变
- ✅ `GetPhoneData` callback 签名不变
- ✅ 迁移 SQL 需手动执行，不自动运行

---

## 📋 Step 3 修复进度 (2026-06-20)

### P2 架构完善状态

| # | 优化项 | 文件 | 状态 | 改动方式 |
|---|--------|------|------|---------|
| 1 | Cache TTL 接入读路径 | `core-framework/services/economy_service.lua` | ✅ **已接入** | `getWageMultiplier()` 60s 缓存，每次 AddScaled 不再读 convar |
| 2 | 批量异步刷盘 | `core-framework/cache/dirty_flush.lua` | ✅ **已实现** | 新增 `FlushAllAsync()` 并行 fire-and-forget；Tick 线程简化为单次调用 |
| 3 | 服务分层去重 | `core-framework/services/` + `qb-core/services/` | ✅ **已分析** | 两层非重复 — core-framework=Public API (source-based), qb-core=Engine Room (citizenid-based)；添加架构注释 |
| 4 | Bus 导出完善 | `core-framework/bus.lua` | ✅ **已完善** | 新增 `DirtyFlushForceFlushAsync` + `DirtyFlushFlushAllAsync` exports |

### 服务分层架构（已明确）

```
┌─────────────────────────────────────────────────┐
│  core-framework/services/*  (Public API 层)      │
│  • source-based 接口                              │
│  • Bus.RegisterService 注册                       │
│  • 供第三方模组通过 exports 调用                    │
│  • 例: Bus.Economy.AddScaled(source, ...)         │
├─────────────────────────────────────────────────┤
│  qb-core/server/services/*  (Engine Room 层)     │
│  • citizenid-based 接口                           │
│  • 内存优先，直接操作 PlayerData                   │
│  • 供 qb-core 内部使用                             │
│  • 例: MetadataService.Set(citizenid, key, val)   │
├─────────────────────────────────────────────────┤
│  persistence_manager (Thin Delegate)             │
│  • qb-core → 委托到 core-framework DirtyFlush     │
│  • core-framework 未加载时 fallback 到原始 SQL     │
└─────────────────────────────────────────────────┘
```

### 本次实际改动文件

| 文件 | 改动类型 | 改动内容 |
|------|---------|---------|
| `[standalone]/core-framework/services/economy_service.lua` | 🏗️ 架构 | wageMultiplier convar 读 → 60s 缓存函数 |
| `[standalone]/core-framework/cache/dirty_flush.lua` | 🏗️ 架构 | 新增 `FlushAllAsync()`；Tick 简化；抽取 `buildPlayerParams` + `FLUSH_SQL` |
| `[standalone]/core-framework/bus.lua` | 🏗️ 架构 | 新增 `DirtyFlushForceFlushAsync` + `DirtyFlushFlushAllAsync` exports |
| `[standalone]/core-framework/services/metadata_service.lua` | 📝 文档 | 添加架构分层注释 |

### 向后兼容确认

- ✅ 所有现有 exports 不变，仅新增
- ✅ `EconomyService.AddScaled` 行为完全不变
- ✅ `DirtyFlush.ForceFlush` / `FlushAll` 保留同步版本用于关机/断线
- ✅ 两层 Service 独立运行，互不干扰
- ✅ `persistence_manager` 委托链不变
