# T-CityLite 全项目资源清单与启用矩阵

> **生成日期**: 2026-06-05 | **阶段**: Phase 1 — 地基扫描
> **统计**: 107 个非系统资源 | 67 启用 · 40 禁用 | 15 个模块 CFG

---

## 1. 模块 CFG 加载总览

`server.cfg` 按顺序 exec 以下模块配置文件：

| # | CFG 文件 | 加载资源数 | 职责 |
|:---|:---|:---:|:---|
| 1 | `core.cfg` | 14 | 基础设施：DB、核心框架、静默、管理菜单 |
| 2 | `player.cfg` | 15 | 玩家流：角色、出生、背包、HUD、计分板 |
| 3 | `voice.cfg` | 1 | 语音：pma-voice |
| 4 | `custom.cfg` | 20 | 自研核心：框架服务、经济、任务、安全、帮派、矿业、司法 |
| 5 | `economy.cfg` | 3 | 经济网关 + 仪表盘 + 原子节点 |
| 6 | `security.cfg` | 0† | 安全 ConVars（无 ensure 语句） |
| 7 | `jobs.cfg` | 3 | 职业管理 + 修车工 |
| 8 | `banking.cfg` | 1 | 银行系统 |
| 9 | `vehicles.cfg` | 7 | 车辆系统：油量、钥匙、车库、商店、中控屏 |
| 10 | `police.cfg` | 1 | 警察职业 |
| 11 | `medical.cfg` | 2 | 医院地图 + EMS 职业 |
| 12 | `crime.cfg` | 5 | 犯罪系统：门锁、商店/房屋抢劫、毒品、当铺 |
| 13 | `career.cfg` | 1 | 多标签职业系统 |
| 14 | `admin.cfg` | 1 | 高安全审计管理指令 |

> † `security.cfg` 仅设置 ConVars（速率限制、限额、距离等），不 `ensure` 任何资源。安全资源 `custom-security` 在 `custom.cfg` 中加载。

另有 `quest.cfg` 存在但**未在 server.cfg 中被 exec** — `custom-quest` 已在 `custom.cfg` 中直接 ensure。

---

## 2. 全资源清单（按分类）

### 图例
- ✅ **ENABLED** — 在某个模块 CFG 中 ensure，随服务器启动
- ❌ **DISABLED** — 资源目录存在但未被任何 CFG 引用
- 🔶 **CFX-DEFAULT** — FiveM 内置系统资源，不计入启用统计

---

### 2.1 [custom] — 自研资源 (15/15 启用)

| 资源 | 状态 | 描述 | 依赖 |
|:---|:---:|:---|:---|
| custom-admin | ✅ | 高安全审计管理指令面板 + Webhook | qb-core, custom-career, custom-main |
| custom-career | ✅ | 高性能多标签职业系统 | qb-core |
| custom-certificates | ✅ | 证照系统（驾驶证/武器证/医疗执照） | qb-core, qb-inventory |
| custom-crime | ✅ | 中央抢劫与犯罪校验 | qb-core, custom-logs |
| custom-debug | ✅ | 黑屏诊断与强制修复工具 | — |
| custom-documents | ✅ | 统一证件展示与验证系统 | qb-core, qb-target |
| custom-economy | ✅ | 统一经济 API + 自适应宏观经济稳定器 | qb-core, custom-logs |
| custom-logs | ✅ | 自定义日志与审计分发 | qb-core |
| custom-main | ✅ | 中央自定义逻辑入口 | qb-core, custom-logs, production-freeze |
| custom-phone | ✅ | 高性能 Phone-First 手机系统 | qb-core, oxmysql |
| custom-quest | ✅ | 数据驱动任务系统（状态机+安全守卫+外部 API） | qb-core, oxmysql, core-framework, production-freeze |
| custom-security | ✅ | 安全防火墙、速率限制与反作弊分发 | qb-core, custom-logs |
| custom-taxes | ✅ | 经济虹吸系统：房产税/车辆生命周期/NPC定价/耐久度 | qb-core, oxmysql |
| custom-testing | ✅ | 自动化游戏内测试框架 (`/test` 命令) | qb-core, custom-logs |
| custom-vehicles | ✅ | 统一车辆系统：钥匙+状态+驾驶辅助，O(1)缓存，事件驱动 | oxmysql, qb-core, core-framework, custom-quest |

---

### 2.2 [qb] — QBCore 标准资源 (30/61 启用)

#### 已启用 (26)

| 资源 | CFG 模块 | 描述 | 依赖 |
|:---|:---|:---|:---|
| qb-adminmenu | core | 服务器与玩家管理菜单 | menuv |
| qb-ambulancejob | medical | 玩家生命/死亡/受伤系统 + EMS 职业 | qb-core, qb-inventory, custom-career, custom-certificates |
| qb-apartments | player | 玩家加入时分配公寓 | qb-core, qb-interior, qb-clothing, qb-weathersync |
| qb-banking | banking | 银行存款/取款/共享账户 | — |
| qb-cityhall | player | 身份证/执照购买 + 职业变更 | qb-core, qb-inventory, custom-certificates |
| qb-clothing | player | 服装与配饰更换菜单 | — |
| qb-core | core | QBCore 核心框架 | oxmysql, core-framework |
| qb-doorlock | crime | 门锁管理系统 | — |
| qb-drugs | crime | 毒品包裹配送 + NPC 销售 | qb-core, production-freeze |
| qb-fuel | vehicles | 简易燃油系统 | qb-target |
| qb-garages | vehicles | 车辆存储 + 职业车辆取出 | — |
| qb-houserobbery | crime | 房屋入室抢劫 | qb-minigames |
| qb-hud | player | HUD：饥饿/口渴/压力等 | — |
| qb-input | player | 信息输入菜单 | — |
| qb-interior | player | 室内壳模型集合 + 创建导出 | — |
| qb-inventory | player | 玩家背包系统 | qb-weapons |
| qb-loading | core | 加载画面 | — |
| qb-management | jobs | 雇员管理系统（雇佣/解雇） | qb-core, qb-inventory, production-freeze |
| qb-mechanicjob | jobs | 修车工职业（修理/改装） | qb-core, qb-inventory, custom-career, custom-vehicles |
| qb-menu | player | 交互选项菜单 | — |
| qb-multicharacter | player | 多角色创建 | qb-core, qb-spawn |
| qb-pawnshop | crime | 物品出售换钱 | — |
| qb-policejob | police | 警察工具/证据/职业功能 | qb-core, qb-inventory, custom-career, custom-certificates, custom-documents |
| qb-scoreboard | player | 服务器/玩家信息计分板 | — |
| qb-spawn | player | 出生点选择 | — |
| qb-storerobbery | crime | 商店抢劫 | qb-core, production-freeze |
| qb-target | player | 世界实体交互（第三人称瞄准） | PolyZone |
| qb-vehicleshop | vehicles | 车辆购买 + 商店管理 | — |
| qb-weapons | player | 武器弹药/配件管理 | — |
| qb-weathersync | player | 时间天气同步 + 指令修改 | — |

#### 已禁用 (31)

| 资源 | 禁用原因 | 备注 |
|:---|:---|:---|
| qb-bankrobbery | v0.5+ 犯罪扩展 | 银行抢劫，依赖 PolyZone |
| qb-busjob | 未列入当前版本 | 公交司机职业 |
| qb-crafting | 未列入当前版本 | 物品制作系统 |
| qb-crypto | v0.2 deferred | 加密货币 (qbit)，依赖 qb-minigames |
| qb-diving | 未列入当前版本 | 潜水打捞 |
| qb-garbagejob | 未列入当前版本 | 垃圾工职业 |
| qb-hotdogjob | 未列入当前版本 | 热狗摊贩职业 |
| qb-houses | 未列入当前版本 | 房屋系统（壳+家具），被 custom-* 替代规划中 |
| qb-jewelery | v0.5+ 犯罪扩展 | 珠宝店抢劫 |
| qb-lapraces | v0.5+ 竞速扩展 | 圈速赛 |
| qb-mapsidebar | 加载但存在 | 地图侧栏 NUI — 存在但未 ensure |
| qb-minigames | 依赖项（部分启用） | 小游戏合集，qb-houserobbery 依赖它 |
| qb-newsjob | 未列入当前版本 | 记者职业 |
| qb-phone | v0.2 deferred | 旧手机系统，已被 custom-phone 替代 |
| qb-prison | v0.2 deferred | 监狱系统，被 custom-justice 部分引用 |
| qb-radialmenu | 未列入当前版本 | 径向菜单 |
| qb-recyclejob | 未列入当前版本 | 回收厂职业 |
| qb-scrapyard | 未列入当前版本 | 废车场 |
| qb-shops | 未列入当前版本 | 商店（物品购买） |
| qb-smallresources | v0.2 deferred | 杂项小功能合集 |
| qb-streetraces | v0.5+ 竞速扩展 | 街头竞速 |
| qb-taxijob | 未列入当前版本 | 出租车职业 |
| qb-towjob | 未列入当前版本 | 拖车职业 |
| qb-truckrobbery | 未列入当前版本 | 卡车抢劫 |
| qb-vehiclesales | 未列入当前版本 | 玩家间车辆出售 |
| qb-vineyard | 未列入当前版本 | 葡萄园职业 |
| qb-weed | 未列入当前版本 | 大麻种植 |

---

### 2.3 [standalone] — 独立资源 (14/18 启用)

| 资源 | 状态 | 描述 | 依赖 |
|:---|:---:|:---|:---|
| aaa_silence | ✅ | 生产模式静默 + print 过滤器 | — |
| bob74_ipl | ✅ | IPL 地图加载与自定义 | — |
| cartel-gates | ✅ | 帮派基地大门生成与放置工具 | — |
| connectqueue | ❌ | 连接队列系统 | — |
| core-framework | ✅ | 核心服务框架：统一 DAL、缓存引擎、脏数据刷新管道、事件防火墙 | oxmysql, qb-core, production-freeze |
| custom-cartel | ✅ | 帮派组织核心：毒品产业链 + NPC 盟友 + 领地管理 | oxmysql, qb-core, qb-inventory, qb-target, qb-menu, progressbar, core-framework, custom-storage, custom-market, custom-security, production-freeze |
| custom-justice | ✅ | 司法系统：逮捕→律师→审判→监狱 | oxmysql, qb-core, qb-menu, qb-target, core-framework, qb-policejob, qb-prison, custom-career, production-freeze |
| custom-market | ✅ | 动态商品市场（供需定价引擎） | oxmysql, qb-core, qb-inventory, core-framework |
| custom-mining | ✅ | 矿业系统：采矿→冶炼→组织仓库 | oxmysql, qb-core, qb-inventory, qb-target, qb-menu, progressbar, core-framework, custom-storage, custom-market, production-freeze |
| custom-storage | ✅ | 通用组织仓库系统（job & gang 分容量） | oxmysql, qb-core, qb-inventory, core-framework |
| interact-sound | ✅ | 通用音效库（安全带/警报等） | — |
| menuv | ✅ | FiveM 菜单库 | — |
| menuv_example | ❌ | menuv 示例（非功能资源） | menuv |
| oxmysql | ✅ | FXServer → MySQL 通信（node-mysql2） | — |
| PolyZone | ✅ | 多边形区域检测库 | — |
| progressbar | ✅ | 进度条依赖库 | — |
| safecracker | ❌ | 保险箱破解小游戏 | — |
| screenshot-basic | ❌ | 截图基础功能 | — |

---

### 2.4 [system] — 系统级资源 (5/6 启用)

| 资源 | 状态 | 描述 | 依赖 |
|:---|:---:|:---|:---|
| atom_nodes | ✅ | 事件驱动原子任务节点：GOTO/INTERACT/DELIVER（PolyZone 零轮询） | qb-core, PolyZone, production-freeze |
| core_economy | ✅ | 统一经济奖励网关 — 所有金钱/物品/声望奖励的单一入口 | qb-core |
| economy-dashboard | ✅ | 实时经济遥测仪表盘（资金流/活跃度热图/资产分布） | qb-core, oxmysql |
| monitor | ❌ | FiveM/RedM 官方服务器 Web/游戏内管理平台 | — |
| production-freeze | ✅ | 生产模式冻结：i18n + 调试关闭 + 实体 GC + PolyZone 打磨 | qb-core |
| tcity-dashboard | ✅ | 通用多模态车辆中控屏 — Vue 3 NUI，6类模板，事件驱动 | qb-core, core-framework, qb-policejob |

---

### 2.5 [voice] — 语音资源 (1/2 启用)

| 资源 | 状态 | 描述 | 依赖 |
|:---|:---:|:---|:---|
| pma-voice | ✅ | VOIP 语音系统 | — |
| qb-radio | ❌ | 无线电系统（已由 pma-voice 内置替代） | pma-voice |

---

### 2.6 [defaultmaps] — 地图资源 (2/5 启用)

| 资源 | 状态 | 描述 |
|:---|:---:|:---|
| dealer_map | ✅ | 车辆经销商地图 |
| hospital_map | ✅ | Pillbox 医院 MLO 地图 |
| prison_main | ❌ | 监狱主地图（被 custom-justice 替代规划中） |
| prison_canteen | ❌ | 监狱食堂地图 |
| prison_meeting | ❌ | 监狱会面室地图 |

---

## 3. 禁用资源分类统计

| 禁用原因 | 数量 | 资源列表 |
|:---|:---:|:---|
| 未列入当前版本（延期功能） | 19 | qb-busjob, qb-crafting, qb-diving, qb-garbagejob, qb-hotdogjob, qb-houses, qb-newsjob, qb-radialmenu, qb-scrapyard, qb-shops, qb-taxijob, qb-towjob, qb-truckrobbery, qb-vehiclesales, qb-vineyard, qb-weed, connectqueue, safecracker, monitor |
| v0.5+ 犯罪/竞速扩展（延期） | 5 | qb-bankrobbery, qb-jewelery, qb-lapraces, qb-streetraces, qb-recyclejob |
| v0.2 deferred（被替代或推迟） | 5 | qb-phone, qb-prison, qb-crypto, qb-smallresources, screenshot-basic |
| 被自研资源替代 | 2 | qb-radio (pma-voice), qb-mapsidebar (存在但未 ensure) |
| 非功能/示例资源 | 1 | menuv_example |
| 依赖项（随主资源间接使用） | 1 | qb-minigames（仅被 qb-houserobbery 依赖，不算独立启用） |
| 地图（规划中被替代） | 3 | prison_main, prison_canteen, prison_meeting |

---

## 4. 关键架构关系速查

### 4.1 核心依赖链

```
oxmysql
  ├─ qb-core ──────────────────────────────────────────┐
  │   ├─ core-framework (DAL + DirtyFlush + Bus)       │
  │   │   ├─ custom-quest                              │
  │   │   ├─ custom-vehicles                           │
  │   │   ├─ custom-market                             │
  │   │   ├─ custom-storage                            │
  │   │   ├─ custom-mining                             │
  │   │   ├─ custom-cartel                             │
  │   │   ├─ custom-justice                            │
  │   │   └─ tcity-dashboard                           │
  │   ├─ production-freeze (i18n + 调试冻结)            │
  │   └─ 所有 qb-* / custom-* 资源                     │
  └─ (独立) custom-phone ───────────── oxmysql (直连)   │
```

### 4.2 玩家流启动顺序

```
aaa_silence → mapmanager/chat/spawnmanager/sessionmanager
  → basic-gamemode/hardcap/baseevents
  → oxmysql → qb-core → production-freeze → qb-loading
  → menuv → qb-adminmenu
  → PolyZone → qb-menu/qb-input/qb-target
  → qb-interior/qb-clothing/qb-weathersync
  → qb-apartments/qb-spawn/qb-multicharacter
  → qb-cityhall → qb-weapons → qb-inventory
  → qb-hud/qb-scoreboard
```

### 4.3 被替代/冗余资源

| 旧资源 | 新替代 | 状态 |
|:---|:---|:---|
| qb-phone | custom-phone | 旧资源未启用 |
| qb-vehiclekeys | custom-vehicles (key_manager) | 旧资源已删除 |
| qb-radio | pma-voice (内置) | 旧资源未启用 |
| qb-prison | custom-justice (司法生态) | 旧资源未启用但被 custom-justice 声明依赖 |
| qb-mechanicjob (车辆状态) | custom-vehicles (vehicle_state) | 旧资源保留（修车功能），状态管理迁出 |

---

## 5. 未引用的 CFG 文件

| CFG 文件 | 状态 | 说明 |
|:---|:---|:---|
| `quest.cfg` | ⚠️ 孤儿文件 | 存在但未在 server.cfg 中 exec；custom-quest 在 custom.cfg 中直接 ensure |

---

> **下一步**: Phase 2 — 逐资源深度扫描，分析每个启用资源的导出函数、网络事件、数据库调用和跨资源依赖。
