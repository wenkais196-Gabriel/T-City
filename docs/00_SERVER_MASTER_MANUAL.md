# T-CityLite 服务器总领手册

> **版本**: v0.7 | **引擎**: QBCore + FiveM | **数据库**: MySQL (oxmysql)
> **生成日期**: 2026-06-05 | **维护者**: T-City 开发团队

---

## 目录

1. [系统全景](#1-系统全景)
2. [启动流程](#2-启动流程)
3. [模块速览](#3-模块速览)
4. [核心架构](#4-核心架构)
5. [数据流全景](#5-数据流全景)
6. [安全模型](#6-安全模型)
7. [运维 SOP](#7-运维-sop)
8. [已知技术债](#8-已知技术债)
9. [快速索引](#9-快速索引)

---

## 1. 系统全景

```
┌─────────────────────────────────────────────────────────────┐
│                    T-CityLite v0.7                           │
│                                                              │
│  67 启用资源 · 40 禁用资源 · 15 模块 CFG · 5 层安全边界     │
└─────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────┐
  │              客户端表现层                          │
  │  qb-hud  qb-scoreboard  qb-target  qb-menu       │
  │  qb-input  qb-loading  qb-radialmenu (禁用)       │
  │  custom-phone (NUI)  tcity-dashboard (Vue 3)     │
  └──────────────────┬───────────────────────────────┘
                     │ TriggerServerEvent / Callbacks
  ┌──────────────────┴───────────────────────────────┐
  │          安全与接口过滤层                           │
  │  SecurityService L0 (输入清理+源验证)              │
  │  custom-security L1-3 (速率限制+回调劫持+审计)     │
  │  custom-crime L4 (抢劫/洗钱/毒品校验)              │
  └──────────────────┬───────────────────────────────┘
                     │ Bus (服务总线)
  ┌──────────────────┴───────────────────────────────┐
  │           核心微服务总线层                          │
  │  EconomyService · JobService · MetadataService    │
  │  PersistenceManager · Plugin Contract             │
  └──────────────────┬───────────────────────────────┘
                     │ DirtyFlush
  ┌──────────────────┴───────────────────────────────┐
  │          缓存与数据隔离层                           │
  │  内存缓存 · DirtyFlush 脏标记 · 15min 定时刷盘    │
  │  PlayerDropped 强制刷盘 · 关机双保险               │
  └──────────────────┬───────────────────────────────┘
                     │ oxmysql
  ┌──────────────────┴───────────────────────────────┐
  │         外部数据持久化层                            │
  │  MySQL: players · player_vehicles · inventories   │
  │         player_quests · quest_* · bans · whitelist│
  └──────────────────────────────────────────────────┘
```

---

## 2. 启动流程

### server.cfg 执行顺序

```
1  core.cfg        14 资源  基础设施 (DB/框架/静默/管理)
2  player.cfg      15 资源  玩家流 (角色/出生/背包/HUD)
3  voice.cfg        1 资源  VOIP (pma-voice)
4  custom.cfg      20 资源  自研核心 (框架服务/任务/安全/v0.7组织)
5  economy.cfg      3 资源  经济网关+仪表盘
6  security.cfg     0 资源  安全 Convars (不 ensure 资源)
7  jobs.cfg         3 资源  职业管理+修车工
8  banking.cfg      1 资源  银行系统
9  vehicles.cfg     7 资源  车辆系统 (钥匙/车库/商店/中控屏)
10 police.cfg       1 资源  警察职业
11 medical.cfg      2 资源  医院地图+EMS
12 crime.cfg        5 资源  犯罪系统 (门锁/抢劫/毒品/当铺)
13 career.cfg       1 资源  多标签职业
14 admin.cfg        1 资源  管理指令
```

### 关键启动依赖链

```
oxmysql → qb-core → core-framework → 所有 custom-* 资源
                                     → custom-quest
                                     → custom-vehicles
                                     → v0.7 组织系统

qb-core → qb-weapons → qb-inventory → 所有交互资源

qb-core → PolyZone → qb-target → 所有 NPC/物体交互
```

---

## 3. 模块速览

| # | 模块 | 资源数 | 责任 |
|:---|:---|:---:|:---|
| 1 | 核心基础设施 | 30 | 数据库、框架、玩家流、HUD、语音 |
| 2 | 自研框架 | 20 | Bus 总线、安全三件套、v0.7 组织系统、任务系统 |
| 3 | 经济系统 | 4 | 统一奖励网关、仪表盘、银行、虹吸 |
| 4 | 车辆系统 | 7 | 钥匙(O(1)缓存)、状态、中控屏、车库、商店 |
| 5 | 职业与权限 | 8 | 管理、警察、医疗、修车工、多标签职业、管理指令 |
| 6 | 犯罪系统 | 5 | 门锁、商店/房屋抢劫、毒品、当铺 |

> 📄 详见: `01_module_manuals/`

---

## 4. 核心架构

### 4.1 双框架并存

```
┌─────────────┐     ┌──────────────────┐
│   qb-core   │ ←── │  core-framework  │
│  (传统 QBCore)│     │  (v0.5 DAL 层)  │
│             │     │                  │
│  50+ API    │     │  Bus 事件总线    │
│  Player 类  │     │  DirtyFlush 管道 │
│  经济服务   │     │  5 微服务        │
│  安全服务   │     │  Plugin Contract │
└──────┬──────┘     └────────┬─────────┘
       │                     │
       └──── compat.lua ─────┘
         (GetPlayer 缓存 + AddMoney 桥接)
```

### 4.2 核心概念

| 概念 | 实现 | 位置 |
|:---|:---|:---|
| **服务总线** | `Bus.RegisterService` → `Bus[name].method()` | core-framework/bus.lua |
| **脏数据管道** | DirtyFlush — 标记 → 定时刷盘 → PlayerDropped 强制 | core-framework/cache/dirty_flush.lua |
| **向后兼容桥** | compat.lua — GetPlayer 缓存 + AddMoney 路由 | core-framework/compat.lua |
| **插件契约** | `Bus.Plugin.Register/Subscribe/Publish` | core-framework/bus.lua |
| **五层安全链** | L0 (SecurityService) → L1-3 (custom-security) → L4 (custom-crime) | 多资源 |
| **统一奖励网关** | `core_economy.TriggerReward` — 全服唯一入口 | system/core_economy |
| **任务状态机** | TriggerQuest → AdvanceStep → CompleteQuest | custom-quest |

---

## 5. 数据流全景

### 5.1 玩家金钱流

```
外部资源 (任务/工作/抢劫)
  │
  ├─→ core_economy.TriggerReward()  ← 推荐路径 (含倍率+热度+自适应)
  │     └─→ EconomyService.AddMoney(cid, type, amount)
  │           └─→ Player.Functions.AddMoney → 标记 DirtyFlush
  │
  ├─→ Bus.EconomyService.AddScaled()  ← 自研路径 (含 wage_multiplier)
  │     └─→ Player.Functions.AddMoney → 标记 DirtyFlush
  │
  └─→ Player.Functions.AddMoney()  ← 老旧路径 (直接)
        └─→ 标记 DirtyFlush (通过 compat.lua 桥接)

DirtyFlush 管道:
  内存标记 (isDirty = true)
    ├─→ 15min 定时 tick → FlushAllAsync (只刷脏玩家)
    └─→ PlayerDropped → ForceFlush (同步 .await, 保证不掉数据)
          └─→ INSERT INTO players (...) ON DUPLICATE KEY UPDATE
```

### 5.2 物品流

```
qb-inventory (27 个 exports)
  ├─→ AddItem(source, item, amount)
  ├─→ RemoveItem(source, item, amount)
  ├─→ HasItem(source, item)
  └─→ SetInventoryData (fromInventory → toInventory)

custom-storage (组织仓库)
  └─→ Bus.StorageService.AddItem/RemoveItem
        └─→ qb-inventory exports

custom-market (动态市场)
  └─→ Bus.MarketService.GetPrice/RecordTransaction
```

---

## 6. 安全模型

### 6.1 五层安全链

| 层 | 资源 | 能力 |
|:---|:---|:---|
| **L0** | core-framework/SecurityService | 类型强制、NaN/Inf 截断、字符串清理、源验证、大额熔断 |
| **L1** | custom-security | 每操作 per-source 速率限制 |
| **L2** | custom-security | 回调劫持 (商店购买/车辆生成) |
| **L3** | custom-security | 事件审计 (金钱/帮派/职业变更) |
| **L4** | custom-crime | 抢劫校验 (警察人数/冷却/唯一键锁) |

### 6.2 铁律

1. **客户端数据不可信** — 所有 amount/price/item/citizenid 必须服务端重验证
2. **敏感事件首行校验 source** — `GetPlayer(src)` + PlayerData 完整性
3. **物理距离检查** — 交互/交易/抢劫必须有距离门禁
4. **大额熔断** — 单次加钱 > $50K 触发警报；> $500K 直接拒绝
5. **速率限制** — 关键操作 1s 冷却（可通过 `security_rate_limit_ms` 调整）

### 6.3 已知风险

| 等级 | 资产 | 问题 | 缓解 |
|:---|:---|:---|:---|
| 🔴 | `AcquireVehicleKeys` | 可声明车辆所有权 | 现有车主检查已存在 |
| 🟠 | `SetInventoryData` | otherplayer 间无距离检查 | 建议添加距离验证 |
| 🟠 | `mining:server:mineOre/smeltOre` | 无 SecurityService 调用 | 添加 ValidateItemEvent |
| 🟡 | `vehicle_state` 同步写 DB | 高频场景 DB 压力 | 迁移到 DirtyFlush |
| 🟡 | 两套 EconomyService | 双重实现未合并 | economy-refactor-memo P0 |

---

## 7. 运维 SOP

### 7.1 日常检查

```bash
# 1. 服务器进程
ps aux | grep fxserver

# 2. MySQL 连接
mysql -u root -p -e "SELECT COUNT(*) FROM QBCore_CDB34E.players"

# 3. DirtyFlush 状态 (游戏内 F8)
exports['core-framework']:BusStatus()     -- 总线健康
exports['core-framework']:DirtyFlushStats() -- 刷盘统计

# 4. 经济状态 (游戏内命令)
/econ       -- 经济仪表盘
/hotrank    -- 活动热度排名
/assets     -- 资产分布
/econreport -- 生成周报
```

### 7.2 安全重启

```bash
# txAdmin: 使用 txAdmin 面板规划重启 → 自动触发 DirtyFlush 全量刷盘
# 手动重启: 发送 shutdown 信号 → core-framework 检测 server_shutting_down → 两次全量刷盘
```

### 7.3 紧急操作

| 场景 | 操作 |
|:---|:---|
| 玩家数据丢失 | `exports['core-framework']:DirtyFlushForceFlush(citizenid)` |
| 经济失控 | `set economy_reward_scale 0.5` (立即减半奖励) |
| 刷钱攻击 | `set security_max_add_money_limit 1000` + 查 `/econ` 定位异常 |
| 禁用犯罪 | `set crime_enable false` (运行时立即生效) |
| 封禁玩家 | F8 `dump GetPlayerIdentifiers(PlayerId())` → 添加到 bans 表 |

### 7.4 备份策略

- **频率**: 每日全量 `mysqldump`
- **保留**: 最近 7 天
- **恢复**: 停止服务器 → 恢复 SQL → 重启（DirtyFlush 自动同步）

---

## 8. 已知技术债

| # | 问题 | 优先级 | 参考 |
|:---|:---|:---:|:---|
| 1 | 两套 EconomyService 需合并 | 🔴 P0 | economy-refactor-memo |
| 2 | AddScaledMoney 未实现全局出口 | 🔴 P0 | economy-refactor-memo |
| 3 | custom-main 中的代码重复 (security.lua + crime.lua) | 🟠 P1 | 本手册 §2.3 |
| 4 | vehicle_state 同步直写 DB — 需迁移到 DirtyFlush | 🟠 P1 | custom-vehicles §2 |
| 5 | custom-phone 独立数据路径 (不走 Bus) | 🟡 P2 | custom-phone.md |
| 6 | SetInventoryData 缺少 otherplayer 距离检查 | 🟡 P2 | qb-inventory §事件安全 |
| 7 | mining 缺少 SecurityService.ValidateItemEvent | 🟡 P2 | v07-org-systems.md |
| 8 | quest.cfg 孤儿文件 (未在 server.cfg exec) | 🟢 P3 | 01_resource_inventory.md §5 |
| 9 | security_max_interaction_distance Convar 未执行 | 🟢 P3 | security.cfg |
| 10 | qb-drugs 与 custom-cartel 并行运行 | 🟡 P2 | crime_system.md §6.5 |

---

## 9. 快速索引

### 文档地图

```
docs/
├── 00_SERVER_MASTER_MANUAL.md          ← 本文件
├── 01_resource_inventory.md            ← 103 资源清单+启用矩阵
├── 01_module_manuals/
│   ├── 01_core_infrastructure.md       ← 核心基础设施 (30 资源)
│   ├── 02_custom_framework.md          ← 自研框架 (20 资源)
│   ├── 03_economy_system.md            ← 经济系统
│   ├── 04_vehicle_system.md            ← 车辆系统
│   ├── 05_jobs_and_permissions.md      ← 职业与权限
│   └── 06_crime_system.md              ← 犯罪系统
├── 02_script_index/
│   ├── qb-core.md                      ← 框架核心 (50+ API)
│   ├── core-framework.md               ← DAL 层 (Bus+DirtyFlush)
│   ├── custom-quest.md                 ← 任务系统 (12 种步类型)
│   ├── custom-vehicles.md              ← 车辆系统 (钥匙+状态)
│   ├── custom-security-crime-main.md   ← 安全三件套
│   ├── v07-org-systems.md              ← v0.7 组织五件套
│   ├── qb-inventory.md                 ← 背包系统 (26 exports)
│   ├── qb-police-ambulance.md          ← 执法+医疗
│   ├── economy-systems.md              ← 经济网关+仪表盘
│   └── custom-phone.md                 ← 手机系统
├── 03_maintenance_manuals/
│   └── maintenance_guide.md            ← 维护排障 SOP
└── 04_call_reference/
    ├── events_index.md                 ← 跨资源事件全量索引
    ├── bus_api_reference.md            ← Bus 服务总线 API
    ├── convars_index.md                ← Convars 全集
    └── database_index.md               ← 数据库表全量索引
```

### 关键文件路径

| 文件 | 说明 |
|:---|:---|
| `T-CityLite.base/server.cfg` | 主配置文件 |
| `T-CityLite.base/configs/modules/*.cfg` | 16 个模块配置 |
| `T-CityLite.base/resources/[qb]/qb-core/` | QBCore 框架 |
| `T-CityLite.base/resources/[standalone]/core-framework/` | 核心服务框架 |
| `T-CityLite.base/resources/[custom]/custom-quest/` | 任务系统 |
| `T-CityLite.base/resources/[custom]/custom-vehicles/` | 车辆系统 |
| `T-CityLite.base/resources/[system]/core_economy/` | 经济网关 |
| `T-CityLite.base/migrations/` | 数据库迁移脚本 |

---

> **文档维护**: 当新增/删除资源时，更新 `01_resource_inventory.md` 和对应模块手册。当修改核心 API 时，更新 `04_call_reference/`。当发现新问题时，更新 §8 已知技术债。
