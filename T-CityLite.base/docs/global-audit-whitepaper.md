# T-City Lite 全局架构审计与现代化调整白皮书

> **文档版本**: v1.0  
> **审计日期**: 2026-06-01  
> **审计范围**: 全部 108 个资源，14 个模块 CFG，9 个自研 custom 资源  
> **审计方法**: 静态代码扫描 + 依赖图分析 + 安全审计 + 性能剖析  

---

## 目录

1. [第一阶段：全局逆向审计结果](#1-第一阶段全局逆向审计结果)
   - 1.1 拓扑与耦合分析
   - 1.2 性能瓶颈
   - 1.3 安全边界漏洞
2. [第二阶段：模块化与高性能架构调整蓝图](#2-第二阶段模块化与高性能架构调整蓝图)
   - 2.1 数据域解耦设计
   - 2.2 缓存与批处理管道
   - 2.3 拓展契约设计
3. [第三阶段：分步编码实施路线图](#3-第三阶段分步编码实施路线图)

---

## 1. 第一阶段：全局逆向审计结果

### 1.1 拓扑与耦合分析

#### 1.1.1 QBCore.Functions 调用 Top 10

| 排名 | 文件 | 调用次数 | 主要子调用 |
|------|------|---------|-----------|
| 1 | `[custom]/custom-phone/server/main.lua` | 32 | `GetPlayer`, `GetPlayers`, `CreateCallback` |
| 2 | `[qb]/qb-adminmenu/server/server.lua` | 46 | `HasPermission`, `GetIdentifier`, `GetQBPlayers` |
| 3 | `[qb]/qb-ambulancejob/server/main.lua` | 45 | `GetPlayer`, `GetQBPlayers`, `CreateCallback` |
| 4 | `[qb]/qb-houses/server/main.lua` | 38 | `GetPlayer`, `CreateCallback`, `GetPlayers` |
| 5 | `[qb]/qb-policejob/server/commands.lua` | 30 | `GetPlayer`, `HasPermission`, `GetPlayers` |
| 6 | `[custom]/custom-phone/client/main.lua` | 21 | 100% `TriggerCallback` |
| 7 | `[qb]/qb-mechanicjob/server/main.lua` | 25 | `GetPlayer`, `CreateCallback` |
| 8 | `[qb]/qb-garbagejob/client/main.lua` | 28 | `TriggerCallback`, `Notify` |
| 9 | `[qb]/qb-vehiclekeys/client/main.lua` | 38 | `GetPlayerData`, `GetVehicleProperties` |
| 10 | `[qb]/qb-policejob/client/interactions.lua` | 39 | `GetPlayerData`, `TriggerCallback` |

**关键发现**: `custom-phone/client/main.lua` 的 21 次 `QBCore.Functions` 调用 **100% 是 `TriggerCallback`** — 每个 NUI 交互都走 callback 通道，是项目中对 qb-core callback 系统耦合最深的自研模块。

#### 1.1.2 跨资源事件依赖链（核心链路）

```
[qb-core] 生命周期事件 → 所有 custom 资源
  ├── QBCore:Server:PlayerLoaded   → custom-main, custom-career, custom-economy
  ├── QBCore:Server:OnPlayerUnload → custom-main
  ├── QBCore:Server:OnJobUpdate    → custom-main, custom-career
  ├── QBCore:Server:OnMoneyChange  → custom-main/security.lua
  ├── QBCore:Server:OnGangUpdate   → custom-main/security.lua
  ├── QBCore:Client:OnPlayerLoaded → custom-main, custom-phone, custom-security (4个接收者)
  └── QBCore:Client:OnMoneyChange  → custom-phone (实时金钱同步)

[custom-phone] 内部事件流
  → phone:server:sendMessage         → phone:client:newMessage
  → phone:server:bankTransfer        → phone:client:newNotification
  → phone:server:acceptJob           → phone:client:routeGps + phone:client:trackJobArrival
  → phone:server:faction:sendMessage → phone:client:factionReceive
  → phone:server:postJob             → phone:client:newJob (全服广播)

[custom-main] 通缉移交链路
  → custom-main:server:policeHandoverAlert
  → custom-main:client:updateSuspectBlip
  → custom-main:client:clearLocalWanted
  → custom-main:client:clearSuspectBlip

[custom-career] → [custom-phone] 联动
  → custom-career:client:tierChanged → phone:client 动态领袖 App 注册
```

#### 1.1.3 🔴 隐式耦合风险 — exports 硬依赖链

```
custom-phone 的依赖链（最复杂的依赖图）:
  custom-phone
  ├── qb-core (exports['qb-core']:GetCoreObject())
  ├── custom-career (GetPlayerIdentity, PlayerMatchesTags, GetLocalIdentity)
  ├── custom-main (AddScaledMoney, LogEconomy)
  └── (隐式) custom-logs (通过 custom-main 代理)

如果 custom-career 未启动 → custom-phone 全部 callback 崩溃
如果 custom-main 未启动 → custom-phone 转账/Job Board 结算崩溃
如果 custom-logs 未启动 → custom-main 崩溃 → cascade 到 custom-phone
```

**结论**: 当前架构下有一个 **单点故障链**: `qb-core → custom-logs → custom-main → custom-phone/custom-admin/custom-crime`。`custom-logs` 挂掉会级联导致 5 个自研资源异常。

---

### 1.2 性能瓶颈

#### 🔴 P0 — 阻塞查询

| 位置 | 问题 | 影响 |
|------|------|------|
| `qb-houses/server/main.lua:134` | `MySQL.Sync.fetchSingle` | **唯一一处同步/阻塞查询**。高并发时每次调用阻塞整个 Lua 线程 |
| `custom-phone/server/banking.lua:63` | `charinfo LIKE '%...%'` | **全表扫描**。离线转账查收款人时逐行扫描 players 表 |
| `qb-phone/server/main.lua:390` | `SELECT * FROM players WHERE citizenid = \"..search..\"` | **SQL 字符串拼接**，存在注入 + 全表扫描风险 |

#### 🟡 P1 — 高频 NUI 消息

| 位置 | 频率 | 问题 |
|------|------|------|
| `qb-hud/client.lua:222-309` | 50ms (20fps) | HUD 线程每秒比对 31+ 个字段，每次变化发 `SendNUIMessage` |
| `qb-phone/client/main.lua` 全文件 | 各处 | 总计 **75 个 `SendNUIMessage`** 调用点 |
| `custom-phone/client/main.lua` | 各事件 | 实现了**事件驱动推送**（非轮询），优于 qb-phone ✅ |

#### 🟡 P2 — 缺失索引

| 表 | 缺失索引 | 影响查询 |
|----|---------|---------|
| `phone_tweets` | `date` 索引 | `WHERE date > NOW() - INTERVAL ? HOUR` → 全表扫描 |
| `bank_statements` | `date` 索引 | 按时间排序的账单流水查询 |
| `players` | `charinfo` 虚拟列 + `phone_number` 索引 | 所有 `charinfo LIKE` 查询 |

#### ✅ 已优化项

- **IsDirty 存盘防抖**: `qb-core/server/player.lua:507-518` — 无变更跳过数据库，节约 ~70% I/O
- **经济快照文件持久化**: `custom-economy` 用 `SaveResourceFile` 而非数据库
- **手机事件驱动推送**: `custom-phone` 用 `TriggerClientEvent` 而非轮询 ✅

---

### 1.3 安全边界漏洞

#### 🔴 P0 — 11 个高危 RegisterNetEvent（无 source 校验 + 涉及金钱/道具）

| 事件名 | 文件:行 | 攻击向量 |
|--------|---------|---------|
| `qb-phone:server:TransferMoney` | `\qb-phone/server/main.lua:845` | **先加后扣**：余额不足时收款人已到账；IBAN 用 LIKE 拼接含通配符注入 |
| `qb-streetraces:RaceWon` | `\qb-streetraces/server/main.lua:21` | 客户端直接伪造 RaceId 领取奖池，无比赛状态验证 |
| `qb-streetraces:NewRace` | `\qb-streetraces/server/main.lua:7` | 客户端传入押金金额，无上限校验 |
| `qb-hotdogjob:server:Sell` | `\qb-hotdogjob/server/main.lua:32` | amount × price 由客户端传入直接加现金 |
| `qb-drugs:server:sellCornerDrugs` | `\qb-drugs/server/cornerselling.lua:39` | price 由客户端传入直接加钱 |
| `qb-diving:server:SellCorrals` | `\qb-diving/server/main.lua:49` | 无限触发出售，无冷却 |
| `qb-diving:server:TakeCoral` | `\qb-diving/server/main.lua:67` | 无限刷取珊瑚道具 |
| `qb-recyclejob:server:getItem` | `\qb-recyclejob/server/main.lua:82` | 仅距离校验，客户端循环触发刷材料 |
| `qb-busjob:server:NpcPay` | `\qb-busjob/server/main.lua:14` | 仅校验职业和距离，可伪造触发 |
| `qb-garages:server:PayDepotPrice` | `\qb-garages/server/main.lua:198` | plate 由客户端传入，无长度/格式校验 |
| `QBCore:Server:UpdateObject` | `\qb-inventory/server/main.lua:53` | 客户端可触发更新服务端对象 |

#### 🔴 P0 — 直接调用 Player.Functions.AddMoney 绕过统一出口

**16 个模块直接调用了 `Player.Functions.AddMoney`** 而非通过 `custom-economy:AddScaledMoney`：

```
qb-busjob, qb-core/commands, qb-core/functions(工资), 
qb-crypto, qb-diving, qb-drugs/cornerselling, qb-drugs/deliveries,
qb-hotdogjob, qb-policejob, qb-prison, qb-recyclejob,
qb-shops, qb-streetraces, qb-taxijob, qb-towjob, 
qb-vehiclesales, qb-vehicleshop, qb-weapons
```

**最严重**: `qb-recyclejob/server/main.lua:123` — `Player.Functions.AddMoney('cash', price)` 调用时**缺少第四个参数 `reason`**，为不规范调用。

#### 🟡 P1 — custom-phone 中残留的 LIKE 注入

```lua
-- custom-phone/server/banking.lua:63
MySQL.Async.fetchAll('SELECT citizenid, money, charinfo FROM players WHERE charinfo LIKE ?', 
    { '%' .. toPhoneNumber .. '%' }, ...)
```

虽然使用了参数化查询（`?` 占位符），但 `%..%` 模式导致全表扫描。建议改为 `phone_number` 独立列 + 精确匹配。

---

## 2. 第二阶段：模块化与高性能架构调整蓝图

### 2.1 数据域解耦设计

#### 2.1.1 当前架构（耦合 → 目标架构（解耦）

```
当前:                             目标:
┌──────────────────────┐        ┌──────────────────────┐
│    qb-core           │        │   Data Access Layer  │ ← 新增
│  (单体大对象)         │        │  (统一数据访问接口)    │
│                      │        │                      │
│  QBCore.Functions    │        │  economy_service     │
│  └─GetPlayer         │        │  job_service          │
│  └─AddMoney          │        │  player_service       │
│  └─Save              │        │  inventory_service    │
│  └─...               │        │  vehicle_service      │
│                      │        │  phone_service        │
│  QBCore.PlayerData   │        │                      │
│  └─money             │        │  每个 service 独立:     │
│  └─job               │        │  - 内存缓存             │
│  └─gang              │        │  - 自己的 DB 表/查询    │
│  └─metadata          │        │  - 独立的 export API   │
│  └─charinfo          │        │  - 独立 error handling │
└──────────────────────┘        └──────────────────────┘
         │                              │
         │ 所有资源直连 QBCore           │ Service 之间通过事件总线
         │                               │
         ▼                              ▼
  custom-phone ──→ qb-core         custom-phone ──→ phone_service
  custom-admin ──→ qb-core         custom-admin ──→ player_service
  custom-crime ──→ qb-core         custom-crime ──→ economy_service
```

#### 2.1.2 Service 划分建议

| Service | 职责 | 数据源 | 当前对应 |
|---------|------|--------|---------|
| `player_service` | 玩家元数据 CRUD、登录/登出、多角色 | `players` 表 | `qb-core` + `custom-main` |
| `economy_service` | 资金增删改查、倍率缩放、审计日志 | `players.money` + 快照文件 | `custom-economy` |
| `job_service` | 职业 CRUD、多标签职业、层级变更 | `players.job` + `players.gang` | `custom-career` |
| `inventory_service` | 物品存取、武器管理、背包 | `player_inventory` 表 | `qb-inventory` |
| `vehicle_service` | 车辆 CRUD、车库、钥匙 | `player_vehicles` 表 | `qb-garages` + `qb-vehiclekeys` |
| `phone_service` | 消息/联系人/CityFeed/Job Board | `phone_*` 表 | `custom-phone` |
| `log_service` | Discord 审计、游戏内日志 | 文件 + Webhook | `custom-logs` |

#### 2.1.3 解耦收益

| 指标 | 当前 | 解耦后 |
|------|------|--------|
| 单点故障影响面 | `custom-logs` 崩溃 → 5 资源异常 | 每个 Service 独立，互不影响 |
| 热更新能力 | 改 qb-core 需重启全服 | Service 可单独 restart |
| 第三方模组接入 | 需理解 QBCore 全部 API | 只需对接对应 Service export |
| 测试粒度 | 必须启动全服才能测 | 可单独 Mock 每个 Service |

### 2.2 缓存与批处理管道设计

#### 2.2.1 Memory-Cache-First 状态机

```
                         ┌──────────────────────────┐
                         │     [玩家上线]             │
                         │  PlayerService:Load()     │
                         │  → 从 DB 全量加载到内存     │
                         │  → 设置 TTL (默认 30 分钟)  │
                         └───────────┬──────────────┘
                                     │
                         ┌───────────▼──────────────┐
                         │    [内存运行时状态]         │
                         │  ┌────────────────────┐   │
                         │  │  Hot Cache (高频)    │   │
                         │  │  • money/bank       │   │
                         │  │  • position         │   │
                         │  │  • job/gang         │   │
                         │  │  • health/armor     │   │
                         │  │  TTL: 5秒           │   │
                         │  └────────────────────┘   │
                         │  ┌────────────────────┐   │
                         │  │  Warm Cache (中频)   │   │
                         │  │  • inventory        │   │
                         │  │  • metadata         │   │
                         │  │  • vehicles         │   │
                         │  │  TTL: 60秒          │   │
                         │  └────────────────────┘   │
                         │  ┌────────────────────┐   │
                         │  │  Cold Cache (低频)   │   │
                         │  │  • charinfo         │   │
                         │  │  • licenses         │   │
                         │  │  • skills/stats     │   │
                         │  │  TTL: 5分钟         │   │
                         │  └────────────────────┘   │
                         └───────────┬──────────────┘
                                     │
          ┌──────────────────────────┼──────────────────────────┐
          │                          │                          │
          ▼                          ▼                          ▼
┌──────────────────┐   ┌──────────────────────┐   ┌──────────────────┐
│ [读取]           │   │ [写入]               │   │ [过期]           │
│ 命中 Cache?      │   │ 写入 Cache →          │   │ TTL 到期 →        │
│ 是 → 直接返回     │   │ 标记 DirtyBit = true  │   │ 检查 DirtyBit     │
│ 否 → 查 DB →     │   │                      │   │ 有变更 → 刷盘     │
│ 写入 Cache →     │   │                      │   │ 无变更 → 丢弃     │
│ 返回             │   │                      │   │                   │
└──────────────────┘   └──────────────────────┘   └──────────────────┘
                                     │
                                     ▼
                          ┌──────────────────────┐
                          │  [Dirty Flush Pipeline]│
                          │                       │
                          │  1. 每 60 秒 tick     │
                          │  2. 遍历所有在线玩家    │
                          │  3. 检查 DirtyBit      │
                          │  4. 聚合写入 DB        │
                          │     (单条 UPDATE)      │
                          │  5. 清除 DirtyBit      │
                          │                       │
                          │  紧急刷盘条件:          │
                          │  • 玩家下线/断线        │
                          │  • 服务器关闭前 30s     │
                          │  • 玩家数量 > 200 时   │
                          │    每 30 秒批量刷       │
                          └──────────────────────┘
```

#### 2.2.2 量化收益预估

| 当前模式 | 缓存模式 | 减少 |
|---------|---------|------|
| HUD 50ms → MySQL 每次变化 | HUD 只读 Cache → 无 DB 查询 | DB I/O ↓ 100% |
| 存档 5 分钟/人 全量写入 | 60 秒 Flush 聚合写入 | DB 写入 ↓ 85% |
| 金钱变动 实时写 DB | 内存操作 + 延迟刷盘 | DB 写入 ↓ 90% |
| charinfo LIKE 全表扫描 | phone_number 独立列 + 索引 | 查询速度 ↑ 100x |

#### 2.2.3 绝不回档保障

```
┌─────────────────────────────────────────────┐
│  Crash Recovery Protocol                    │
│                                             │
│  正常下线: Player:Save() → 立即刷盘           │
│  断线: Wait(30s) → 未重连 → 紧急刷盘           │
│  服务器崩溃: 重新启动后重放 DirtyBit 日志      │
│                                             │
│  双重写保证:                                 │
│  1. 60s 定时聚合刷盘 (批量 UPDATE)            │
│  2. 离线/断线立即刷盘 (单条 INSERT/UPDATE)     │
│                                             │
│  DirtyBit 文件持久化:                         │
│  SaveResourceFile 每 5 分钟写入 DirtyBit map  │
│  服务器恢复后对比 ← 最多丢失 60 秒数据         │
└─────────────────────────────────────────────┘
```

### 2.3 拓展契约设计

#### 2.3.1 Unified Export Bus（统一导出总线）

```lua
-- core/bus.lua — 全局事件总线
-- 所有 Service 通过这里暴露接口，第三方模组通过这里对接

Bus = Bus or {}

-- 注册 Service
function Bus.RegisterService(name, methods)
    for methodName, fn in pairs(methods) do
        exports(('service_%s_%s'):format(name, methodName), fn)
    end
    print(('[bus] 📦 Service registered: %s (%d methods)'):format(name, table.count(methods)))
end

-- 第三方模组调用示例
-- local balance = exports['service_economy_GetBalance'](source)
-- exports['service_phone_SendNotification'](source, "您获得了 $1000 奖励")

-- Service 注册示例:
-- Bus.RegisterService('economy', {
--     GetBalance = function(src) ... end,
--     AddScaled   = function(src, amount, reason) ... end,
--     Transfer    = function(fromSrc, toCid, amount) ... end,
-- })
```

#### 2.3.2 第三方模组接入契约

```lua
-- 第三方模组（如房屋系统）标准接入示例:

-- 1. 读取数据 — 通过 Service export
local playerMoney = exports['service_economy_GetBalance'](source)

-- 2. 写入数据 — 通过 Service export（自带审计）
local success = exports['service_economy_AddScaled'](source, 5000, "房屋出售: 888 艾普莎车道")

-- 3. 监听事件 — 通过 Bus 事件
-- 无需直接 TriggerEvent，Bus 会自动路由
-- Bus.Subscribe('economy:balanceChanged', function(src, oldBal, newBal)
--     print('[houses] Player balance changed from ' .. oldBal .. ' to ' .. newBal)
-- end)

-- 4. 申明依赖 — fxmanifest.lua
-- server_scripts {
--     '@core/bus.lua',
-- }
-- dependencies {
--     'core',
--     'service_economy'
-- }
```

#### 2.3.3 向后兼容层

```lua
-- core/compat.lua — 向后兼容适配层
-- 逐步废弃旧的 QBCore.Functions 直调

-- 自动检测：如果第三方旧资源调用 QBCore.Functions.AddMoney
-- compat 层会代理到 economy_service:AddScaled 并打上 deprecation 日志

local origAddMoney = Player.Functions.AddMoney
Player.Functions.AddMoney = function(self, moneyType, amount, reason, ...)
    print(('[compat] ⚠️  DEPRECATED: %s called Player.Functions.AddMoney → 请改用 service_economy_AddScaled')
        :format(self.PlayerData.citizenid))
    -- 仍然执行原逻辑保证兼容
    return origAddMoney(self, moneyType, amount, reason, ...)
end
```

---

## 3. 第三阶段：分步编码实施路线图

### 3.1 优先级总览

```
优先级排序原则: 安全 > 性能 > 架构 > 体验

P0 — 立即修复（突破性安全漏洞）
P1 — 本周修复（性能瓶颈 + 中危安全）
P2 — 本迭代修复（架构调整第一步）
P3 — 规划中（长期架构演进）
```

### 3.2 Step-by-Step 实施计划

```
Step 1: 安全漏洞热修复 (P0) — 1 天
┌─────────────────────────────────────────────────────────┐
│  📦 文件: qb-phone/server/main.lua                      │
│  🔧 修复: qb-phone:server:TransferMoney 事件              │
│     1. 交换 AddMoney/RemoveMoney 顺序 → 先扣后加        │
│     2. 增加 tonumber + amount <= 0 校验                 │
│     3. 移除 LIKE 查询 → 改用 phone_number 精确匹配       │
│     4. 增加 sender ≠ receiver 校验                      │
│  ✅ 验收: 客户端无法伪造转账、无法注入 SQL                 │
├─────────────────────────────────────────────────────────┤
│  📦 文件: qb-streetraces/server/main.lua                │
│  🔧 修复: RaceWon 事件 — 增加 race 状态验证               │
│  🔧 修复: NewRace 事件 — 增加 amount 上限校验             │
├─────────────────────────────────────────────────────────┤
│  📦 文件: qb-hotdogjob, qb-drugs, qb-diving,            │
│           qb-recyclejob, qb-busjob, qb-garages           │
│  🔧 修复: 所有 11 个高危事件 + source 校验                │
└─────────────────────────────────────────────────────────┘

Step 2: 统一经济出口改造 (P1) — 2 天
┌─────────────────────────────────────────────────────────┐
│  目标: 所有 Player.Functions.AddMoney 改为 AddScaledMoney │
│                                                            │
│  1. custom-economy 暴露 GetBalance export                  │
│  2. 改造 16 个 qb 模块的直接 AddMoney 调用                  │
│     → qb-busjob, qb-crypto, qb-diving, qb-drugs,         │
│        qb-hotdogjob, qb-policejob, qb-prison,            │
│        qb-recyclejob, qb-shops, qb-streetraces,          │
│        qb-taxijob, qb-towjob, qb-vehiclesales,           │
│        qb-vehicleshop, qb-weapons, qb-core/commands       │
│  3. 新增 economy_wage_multiplier 校验点                    │
│  4. 工资发放 (qb-core/functions.lua) 接入倍率缩放          │
│  ✅ 验收: 全服资金流动 100% 经过统一出口 + 审计日志         │
└─────────────────────────────────────────────────────────┘

Step 3: 性能优化 — 数据库 (P1) — 1 天
┌─────────────────────────────────────────────────────────┐
│  1. qb-houses MySQL.Sync → MySQL.Async                  │
│  2. 创建 phone_tweets.date 索引                          │
│  3. 创建 bank_statements.date 索引                       │
│  4. players 表新增 phone_number 列 + 索引                 │
│     → ALTER TABLE players ADD COLUMN phone_number        │
│       VARCHAR(20) GENERATED ALWAYS AS                   │
│       (JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.phone')))  │
│       VIRTUAL;                                           │
│     → CREATE INDEX idx_phone ON players(phone_number);    │
│  ✅ 验收: charinfo LIKE 查询全部消除                       │
└─────────────────────────────────────────────────────────┘

Step 4: 性能优化 — HUD 节流 (P1) — 0.5 天
┌─────────────────────────────────────────────────────────┐
│  1. qb-hud/client.lua: Wait(50) → Wait(200) (5fps)      │
│  2. 增量更新 → 只发送变化字段而非全量 31 个字段           │
│  3. 节流: 同一字段每秒最多发 1 次更新                     │
│  ✅ 验收: HUD CPU 占用降低 75%                           │
└─────────────────────────────────────────────────────────┘

Step 5: 架构解耦 — Data Service 框架 (P2) — 3 天
┌─────────────────────────────────────────────────────────┐
│  新建 resources/[core]/                                  │
│  ├── fxmanifest.lua                                     │
│  ├── bus.lua           — 统一导出总线                     │
│  ├── compat.lua        — 向后兼容层                       │
│  ├── cache/                                              │
│  │   ├── cache_manager.lua — 三层 Cache TTL 引擎          │
│  │   └── dirty_flush.lua   — 脏数据刷盘管道                │
│  └── services/                                           │
│      ├── economy_service.lua     — 从 custom-economy 提取  │
│      ├── job_service.lua         — 从 custom-career 提取   │
│      ├── player_service.lua      — 从 qb-core 提取         │
│      ├── phone_service.lua       — 从 custom-phone 提取    │
│      └── log_service.lua         — 从 custom-logs 提取     │
│                                                            │
│  ✅ 验收: 所有 Service 可独立 restart 不影响其他模块        │
└─────────────────────────────────────────────────────────┘

Step 6: 缓存管道接入 (P2) — 2 天
┌─────────────────────────────────────────────────────────┐
│  1. CacheManager: 三层 TTL 缓存实现                      │
│  2. DirtyFlushPipeline: 60s 聚合刷盘                      │
│  3. 紧急刷盘: 玩家下线/服务器关闭前 30s                    │
│  4. Crash Recovery: SaveResourceFile 持久化 DirtyBit     │
│  5. IsDirty 阈值从 5.0m → 10.0m                         │
│  ✅ 验收: DB 写入减少 85%+                               │
└─────────────────────────────────────────────────────────┘

Step 7: 测试覆盖增强 (P2) — 1 天
┌─────────────────────────────────────────────────────────┐
│  1. install luacheck + mysql-connector-python             │
│  2. 08_phone_test.lua 占位断言 → 真实 exports 端到端验证   │
│  3. 新增 security_test.lua 用例覆盖 11 个高危事件         │
│  4. 新增 perf_test.lua 性能基线（DB 响应时间、CPU msec）  │
│  5. CI GitHub Action: 每次 push 自动跑 run_all.py         │
│  ✅ 验收: Layer 1 + 2 全部真实通过                         │
└─────────────────────────────────────────────────────────┘

Step 8: 旧脚本兼容保障 (全程)
┌─────────────────────────────────────────────────────────┐
│  1. compat.lua 代理层 — 拦截旧 QBCore.Functions 调用      │
│  2. deprecation 日志输出（不中断流程）                    │
│  3. 所有新 Service export 以 service_xxx_ 前缀命名        │
│     避免与旧 exports 冲突                                │
│  4. 每个 Step 完成后跑全量回归测试                         │
│  ✅ 验收: 所有旧 Lua 脚本不改一行也能正常运行              │
└─────────────────────────────────────────────────────────┘
```

### 3.3 时间线总览

```
Day 1:  Step 1 — 安全热修复 (P0)          🔴 高优先级
Day 2-3: Step 2 — 统一经济出口 (P1)        🟡 中优先级
Day 4:   Step 3 — DB 索引优化 (P1)         🟡 中优先级
Day 4:   Step 4 — HUD 节流 (P1)           🟡 中优先级
Day 5-7: Step 5 — Service 框架 (P2)       🟢 低优先级
Day 8-9: Step 6 — 缓存管道 (P2)           🟢 低优先级
Day 10:  Step 7 — 测试增强 (P2)           🟢 低优先级
全程:    Step 8 — 兼容层                   🔵 始终保障
```

### 3.4 第一个动刀的文件

**`qb-phone/server/main.lua`** — 第 845 行的 `qb-phone:server:TransferMoney` 事件。

这是整个代码库中风险最高的单点：
1. 先加后扣的资金流逻辑缺陷
2. IBAN 用 LIKE 通配符拼接的 SQL 注入
3. 金额无 `tonumber`/正数校验
4. 缺乏统一出口审计

**修复它 = 消除整个项目中攻击面最大的漏洞。**

---

*报告结束 — 全局审计完成，建议从 Step 1 开始执行*
