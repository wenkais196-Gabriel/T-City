# T-City Lite — 全局审查、修复与三阶段路线图

> **审计日期**: 2026-10-21
> **审计对象**: `wenkais196-Gabriel/T-City` @ `4b53496`（6,030 文件 / 1,403 Lua / 130 资源）
> **方法**: 静态代码审计 + 依赖图/事件图交叉验证 + 配置与 DB schema 对照 + 旧审计（2026-06-20）复核
> **限制**: **未启动 FXServer**（仓库不含 `alpine/` 运行时）。所有结论标注"静态确认 / 高置信推断 / 未验证"。
> **配套文档**: [Agent 导演架构设计](../../../docs/server-design/08-agent-director.md)

---

## 0. 执行摘要

这套代码的问题不是"功能少"，而是**大量架构组件写好了但没有接线**：

- `core-framework` 的 fxmanifest 引用了两个**从不存在的文件** → 核心框架无法启动 → 任务、剧情、市场、卡特尔、司法等 9 个硬依赖资源全部无法启动；
- 启动顺序与 `fxmanifest` 依赖冲突 11 处 → 警察、EMS、机修、市政厅等即使文件齐全也会被跳过；
- `custom-quest` / `custom-taxes` / `core-framework` 没有注入 `MySQL` 全局 → 任务进度、税务、离线转账**静默失效**；
- 任务四张表**没有建表脚本**；冷却查询是"发起异步后立刻返回 false" → 冷却永久失效；
- 至少 21 个客户端可触发的事件存在越权/刷钱/删实体问题，其中 5 个可直接稳定获利或破坏他人游戏；
- 跨资源 `Bus` 依赖 `_G` 共享，而 FiveM 每个 resource 是独立 Lua state → 20+ 个消费方看到的 `Bus` 是 `nil`，全部走 `if Bus then` 静默降级；
- 真正的持久化定时器不存在（core-framework 的 tick 看不到 qb-core 的脏表）→ 崩溃/重启会丢在线期间的数据。

**本次已修复 40+ 处 P0/P1**（见 §4），使"从空库启动 → 框架加载 → 任务/剧情可跑 → 下线不丢档"这条主链在静态层面成立。**仍需一次真实 FXServer 启动验证**。

### 真实完成度评估

| 层 | 声称 | 实际（修复前） | 修复后（静态） |
|:---|:---|:---|:---|
| 启动链 | v0.7 完成 | ❌ core-framework 起不来 | ✅ 依赖图/顺序通过 |
| 经济统一出口 | 已落地 | ❌ 卖货扣物不付钱、core_economy 报错 | ✅ 主路径已接 |
| 任务系统 | v0.6 完成 | ❌ 无表、冷却失效、可跳步 | 🟡 表/冷却/步骤/奖励幂等已修，待实机验收 |
| 剧情系统 | v0.7 完成 | ❌ 从未启动 + 登录事件名错 | ✅ 已接入并加防越权 |
| 持久化 | DirtyFlush | ❌ 无定时刷盘 | ✅ qb-core 侧补 tick |
| Bus 总线 | "统一总线" | ❌ 跨资源不可见 | 🔴 仅修了经济出口，整体待重构 |
| Agent 导演 | 目标 | ❌ 无入站/无外发/无动作层 | 🔴 设计稿已出，未实现 |

---

## 1. 审查范围与方法

### 1.1 范围

| 维度 | 覆盖 |
|:---|:---|
| 启动与配置 | `server.cfg.template`、17 个 `configs/modules/*.cfg`、130 个 `fxmanifest.lua` |
| 自研资源 | `[custom]/*`、`[standalone]/custom-*`、`[system]/*`、`core-framework` |
| 核心链路 | qb-core 玩家/经济/持久化、custom-quest、story-engine、core-framework、custom-vehicles |
| 安全 | 277 个 `RegisterNetEvent`（范围内）、SQL 调用、经济写入口 |
| 文档 | `PROJECT_PROGRESS.md`、`ROADMAP.md`、`docs/00_SERVER_MASTER_MANUAL.md`、`docs/server-design/*` |
| 旧审计 | `docs/audit/2026-06-20-full-audit-report.md` 的 11 项修复复核 |

### 1.2 方法

1. **依赖图**：解析 `dependencies{}`/`dependency`，与 cfg 的 `ensure` 顺序做拓扑比对（已固化为 `tests/check_dependencies.py`）。
2. **事件图**：`RegisterNetEvent` / `AddEventHandler` / `TriggerEvent` 配对抽样。
3. **数据图**：代码中的表名 vs `migrations/` + 资源内 `.sql`。
4. **运行时假设核对**：FiveM 资源隔离、`SetHttpHandler`、exports 序列化语义（查官方文档 + 社区）。
5. **旧审计复核**：逐条读代码确认"已修复"是否真实、是否可绕过。

---

## 2. 核心结论：链路是否闭环

| 环节 | 判定 | 关键原因 |
|:---|:---|:---|
| **启动** | ✅ 修复后静态通过 | 原先 core-framework 缺文件 + 11 处顺序冲突 + 3 个硬依赖缺失 |
| **玩家加载** | 🟡 基本通 | qb-core 链路完整；位置落盘有 0,0,0 风险（已修） |
| **经济变动** | 🟡 主路径通 | 卖货/奖励已接；Bus 服务名不一致导致仓库/市场仍降级 |
| **任务** | 🟡 可跑但需验收 | 表/冷却/步骤/组队/多任务缓存/奖励幂等已补；待实机验收 |
| **剧情** | 🟡 可跑 | 已接入；决策越权/超时卡死已修；放弃任务收口已补 |
| **存档** | 🟡 改善 | qb-core 补 15min tick + 停机刷盘；仍需压测确认 |
| **断线** | 🟡 改善 | force 刷盘存在；位置回退已修 |
| **观测** | 🔴 断 | 事件只发不收、无进程外出口；`world_events` 无写入 |
| **Agent 导演** | 🔴 未开始 | 无 bridge、无 action schema、无身份/预算/人审 |

**一句话**：修复后达到"**能启动、能玩任务、下线不丢档**"的基线；距离"玩家涌现扮演 + AI 导演"还差**观测层、动作层、治理层**三块地基。

---

## 3. 发现清单

> 严重度：P0 = 阻断启动/可稳定刷钱/可破坏他人；P1 = 功能失效/数据错误；P2 = 降级/维护风险。
> 证据标注：`[静态确认]` 逐行读过；`[高置信]` 基于平台语义推断；`[未验证]` 需实机。

### 3.1 P0 — 启动与数据（已修）

| # | 问题 | 证据 | 状态 |
|:---|:---|:---|:---|
| 1 | `core-framework` 引用不存在的 `cache/cache_manager.lua`、`cache/dirty_flush.lua` → 资源无法启动，9 个下游硬依赖全部停摆 | `core-framework/fxmanifest.lua`（原 25-26 行）；`git ls-files` 无 `cache/` | ✅ 已移除两行，补 `@oxmysql/lib/MySQL.lua` |
| 2 | 11 处 `fxmanifest` 依赖与 `ensure` 顺序冲突，8 个资源启动即 stopped | `custom-justice→qb-policejob`、`qb-cityhall→custom-certificates`、`qb-mechanicjob→custom-vehicles`、`tcity-dashboard→qb-policejob` 等 | ✅ 重排 exec + 移动资源（见 §4） |
| 3 | 硬依赖缺失：`custom-justice→qb-prison`、`qb-houserobbery→qb-minigames`、`custom-cartel` 运行时调 `safecracker` | 各 fxmanifest / `custom-cartel/client/main.lua:337` | ✅ 补 3 个 ensure |
| 4 | `MySQL` 全局未注入：`custom-quest`、`custom-taxes`、`core-framework`、`qb-recyclejob` 用 `MySQL.*` 但 manifest 无 `@oxmysql/lib/MySQL.lua` | 各 manifest；`quest_db.lua` 首行 `if not MySQL then return end` 导致静默失败 | ✅ 4 个 manifest 已补 |
| 5 | 任务四表无建表脚本 | `quest_db.lua` 引用 `player_quests`/`quest_cooldowns`/`quest_event_log`/`quest_daily_limits`；`migrations/` 无 | ✅ 新增 `migrations/v0.7_quest_system.sql` |
| 6 | 无定时刷盘：qb-core 的 `ThinDirtyFlush` 只有 `ForceFlush`；core-framework 的 tick 在另一资源、看不到 qb-core 的 `_dirty` | `qb-core/server/services/persistence_manager.lua`（原 84-139） | ✅ qb-core 侧补 tick + `onResourceStop` |
| 7 | 断线/存档位置可能写 `0,0,0` | `player.lua` 先 `GetEntityCoords(ped)` 再判 `ped ~= 0` | ✅ 两处改为位置回退 |
| 8 | `core_economy` 引用未定义全局 `EconomyService` → 含钱奖励全部 nil 报错 | `core_economy/server/main.lua`（原 166/176） | ✅ 改走 `Player.Functions.AddMoney` |
| 9 | `custom-market` / `custom-cartel` 卖货后调用 `Bus.EconomyService.AddScaled`（不存在/跨资源不可见）→ **扣物不付钱** | `custom-market/server/main.lua:264`；`custom-cartel/server/npc_manager.lua:192` | ✅ 改走 `service_economy_AddScaled` export，失败回退直接加钱 |
| 10 | 任务冷却异步查询后立即返回 `false,0`，且缓存命中返回空表 → 冷却永久失效、可无限重接刷奖励 | `quest_cooldown.lua`（原 13-36） | ✅ 改为内存权威 + 登录从 DB 回填 |

### 3.2 P0 — 安全（已修）

| # | 问题 | 证据 | 状态 |
|:---|:---|:---|:---|
| 11 | `custom-admin` 对所有玩家自动授予 `admin`，且每次上线再授 | `custom-admin/server/commands.lua`（原 104-123） | ✅ 改为 `admin_autogrant` convar，默认 `false` |
| 12 | `quest:server:nodeComplete` 跳过 nonce，`ValidateNode` 是恒真 stub，clientData 为空则距离校验整段跳过 → 可远程推进任务链领奖 | `custom-quest/server/main.lua`；`quest_manager.lua:94` | ✅ `ValidateNode` 实现类型 + 服务端距离校验 |
| 13 | `story:server:makeDecision` 只校验选项白名单，不绑定 quest/step，也不校验是否当前步骤 → 可跨任务跳步/领奖 | `story-engine/server/decision_engine.lua` | ✅ 服务端 pending offer + 上下文绑定 + 超时兜底 |
| 14 | 决策超时发 `'timeout'` 不在白名单 → 校验失败、NUI 已关 → 任务永久卡死 | `story-engine/client/main.lua:106-123` | ✅ 服务端接受超时哨兵并按默认选项收口 |
| 15 | 剧情登录事件名写错：`QBCore:Server:OnPlayerLoaded`（不存在）→ 已完成剧情线重登后可重开 | `story-engine/server/main.lua:69` | ✅ 改为 `QBCore:Server:PlayerLoaded` |
| 16 | `quest:server:cleanupTrailers(citizenid)` 无鉴权，可删任意 netId 实体 | `custom-quest/server/main.lua:617` | ✅ 改为非网络 `AddEventHandler`，仅服务端内部可调 |
| 17 | `quest:server:registerTrailer` 信任客户端 netId，可注册他人车辆后被回收删除 | 同上 :527 | ✅ 校验实体存在 + 50m 距离 |
| 18 | `qb-hotdogjob:server:Sell` 不校验职业/物品，数量×单价上限 100 → **$10,000/秒**；距离比对客户端坐标 | `qb-hotdogjob/server/main.lua:35` | ✅ 职业校验 + 数量≤5 + 单价按 Config 边界 |
| 19 | `qb-streetraces` 整张 `RaceTable`（含 `pot`）由客户端提交；领奖后赛局不销毁 → 可造任意奖池并重复领奖 | `qb-streetraces/server/main.lua:5,33` | ✅ 服务端重建赛局/奖池，领奖前销毁，加入去重 |
| 20 | `custom-vehicles` 载具事件族无车主校验：`GiveKeys` 知道车牌即得钥匙；`SaveVehicleProps` 可给任意车满改；`updateComponents` 可免费维修 | `compat.lua:57`；`vehicle_state.lua:192-226,294-323` | ✅ 统一 `CanModifyPlate`（车主或执勤机修），部件值夹紧 0-100 |
| 21 | `justice:server:sentenceComplete` 无刑期校验，服刑者一条事件秒出狱 | `custom-justice/server/prison.lua:117` | ✅ 按 `startTime + sentenceMinutes` 校验 |
| 22 | `justice:server:imprison` 刑期无上限 | 同上 :9 | ✅ clamp 到 `Config.Justice.MaxSentence`（默认 120） |
| 23 | `quest:server:dashboardStampDelivery` 信任客户端传入 `callerSrc`，可替他人推进任务 | `custom-quest/server/main.lua:649` | ✅ 客户端触发时必须 `callerSrc == source` |

### 3.3 P0/P1 — 仍未修复（按优先级）

| # | 问题 | 影响 | 建议 |
|:---|:---|:---|:---|
| R1 | **Bus 跨资源不可见** | 组织仓库、市场价、律师通知等曾"代码在、功能不在" | 🟡 部分修复：9 个注册方 include `bus.lua`；cartel/mining/justice/crime 共 19 处改显式 `service_*` export；剩 `custom-phone` 一处（有 fallback） |
| R2 | **任务奖励不幂等** | 重复调用可重复发钱/物品 | ✅ 已修复：`CompleteQuest` affectedRows 回调 + 内存完成锁 + 10s 超时兜底 |
| R3 | **组队双锁** | 组队实例曾永远建不出来 | ✅ 已修复：只调 `CreateGroupInstance`；`RemoveGroupMember` 用真实 key；断线释放锁 |
| R4 | **多任务缓存覆盖** | 接新任务会把旧任务挤出缓存 | ✅ 已修复：读现有缓存后 append |
| R5 | **地址池任务顺序校验被绕过** | 可跳步 | ✅ 已修复：缓存空窗期改用 `_currentSteps` 内存步骤比对，不匹配即拒绝 |
| R6 | 其余未鉴权事件 | 刷资源/骚扰 | 🟡 部分修复：`mining`/`cartel`/`savePosCollection`/`registerTrailer`/`cleanupTrailers`/`ResetDeathStatus`/`policeHandoverAlert`/`plateFlagged` 已收口；仅剩 `nodeComplete` 跳过 nonce（需改客户端，另开 Issue） |
| R7 | `world_state_service` 用 `Citizen.Await` 同步查 DB，且 `prepare` 返回结构自相矛盾 | 首次读取阻塞主线程/返回错值 | 改 `execute` + `rows[1].state_value`，异步化 |
| R8 | `custom-testing` 在生产 cfg 中 ensure，`/test` 对所有玩家开放 | 攻击面/性能 | 生产 cfg 移除，或加 `admin` 限制 |
| R9 | `player_warns` / `server_logs` 等表无 DDL | 新库功能报错 | 补迁移（本轮只补了任务四表） |

### 3.4 P2 — 文档与维护

| 问题 | 证据 |
|:---|:---|
| `PROJECT_PROGRESS.md` 停在 v0.7a（56 资源 / 14 模块），实际 80 资源 / 17 cfg | 文件头 |
| `ROADMAP.md` 标记 Phase 1-4"完成"，但 Phase 3 组织外交、Phase 4 社区立法仍是"待开发" | `ROADMAP.md:185-203` |
| 旧审计"已修复"11 项中，2 项实际未修/可绕过（streetraces NewRace、hotdogjob）；1 项报告结论错误（JailPlayer 无上限） | 逐条复核 |
| `tests/check_dependencies.py` 只解析 `dependency('x')`，不解析主流的 `dependencies{}` → 长期"测试全绿、依赖全缺" | 已修复该脚本 |
| `docs/server-design/*` 在仓库根 `docs/`，但代码注释按 `T-CityLite.base/docs/server-design` 引用 | 路径漂移 |
| `quest.cfg` 曾是孤儿文件；现已接入 | — |

---

## 4. 本次实际改动

> 全部改动均通过 `luac5.4 -p` 语法检查；未启动服务器。

### 4.1 启动链

| 文件 | 改动 |
|:---|:---|
| `server.cfg.template` | 按依赖图重排 16 个模块：`core → career → player → voice → custom → quest → police → vehicles → jobs → banking → medical → economy → security → crime → story → atmosphere → admin` |
| `configs/modules/player.cfg` | `progressbar` 提前；移除 `qb-cityhall`（依赖 custom-certificates） |
| `configs/modules/custom.cfg` | 移除 `custom-quest`（改用 quest.cfg）；`safecracker` 先于 `custom-cartel`；`qb-cityhall` 放到 certificates 之后；`custom-justice` 移到 police.cfg |
| `configs/modules/police.cfg` | `qb-prison` → `qb-policejob` → `custom-justice` |
| `configs/modules/crime.cfg` | `qb-minigames` 先于 `qb-houserobbery` |
| `configs/modules/jobs.cfg` | 移除重复 `progressbar` |

### 4.2 框架与数据

| 文件 | 改动 |
|:---|:---|
| `core-framework/fxmanifest.lua` | 删除 2 个不存在的 cache 脚本；补 `@oxmysql/lib/MySQL.lua` |
| `custom-quest/fxmanifest.lua`、`custom-taxes/fxmanifest.lua`、`qb-recyclejob/fxmanifest.lua` | 补 `@oxmysql/lib/MySQL.lua` |
| `migrations/v0.7_quest_system.sql` | 新增 4 张任务表（含索引；不建 `(citizenid, quest_id, status)` 唯一键，避免重复完成的唯一键冲突） |
| `qb-core/server/services/persistence_manager.lua` | 新增 15min tick（`persistence_flush_interval`）+ 资源停止刷盘；位置回退 |
| `qb-core/server/player.lua` | 位置回退，避免断线写 `0,0,0` |
| `core_economy/server/main.lua` | 未定义 `EconomyService` → `Player.Functions.AddMoney` |
| `custom-market/server/main.lua`、`custom-cartel/server/npc_manager.lua` | `Bus.EconomyService.AddScaled` → `service_economy_AddScaled` export，失败回退直接加钱 |
| `tests/check_dependencies.py` | 支持 `dependencies{}`；新增"启动顺序"检查；过滤 `/server:xxxx` 误报 |

### 4.3 任务与剧情

| 文件 | 改动 |
|:---|:---|
| `custom-quest/server/quest_cooldown.lua` | 重写：内存权威 + 登录回填 + DB 异步只做回填 |
| `custom-quest/server/quest_manager.lua` | `ValidateNode` 实现（类型 + 服务端距离）；决策节点下发前登记 pending；`CancelAllNodes` 清理 pending；组队锁只抢一次；活跃任务缓存 append |
| `custom-quest/server/quest_mutex.lua` | `RemoveGroupMember` 使用真实锁 key；`playerDropped` 释放锁并移除组成员 |
| `custom-quest/server/quest_security.lua` | 新增 `ResetStepAttempts`，步骤推进时清零，避免可重复任务跑满上限被永久锁死 |
| `custom-quest/server/main.lua` | `dashboardStampDelivery` 防伪造；`registerTrailer` 校验实体/距离；`cleanupTrailers` 改为非网络事件 |
| `story-engine/server/decision_engine.lua` | 新增 pending offer、超时兜底、上下文绑定、幂等消费、日志 |
| `story-engine/server/main.lua` | 修正登录事件名；新增 `OfferDecision`/`ClearDecision` exports；断线/任务失败清理 |

### 4.4 安全

| 文件 | 改动 |
|:---|:---|
| `custom-admin/server/commands.lua` + `admin.cfg` | 自动 admin 改为 `admin_autogrant`（默认 false） |
| `qb-hotdogjob/server/main.lua` | 职业校验、数量/单价服务端边界 |
| `qb-streetraces/server/main.lua` | 服务端重建赛局、奖池按人数计算、领奖销毁、加入去重 |
| `custom-vehicles/server/{compat,vehicle_state}.lua` | 统一车主/执勤机修校验；部件值夹紧 |
| `custom-justice/server/prison.lua` | 刑期校验 + 刑期上限 |
| `custom-mining/server/main.lua` | 矿点距离校验（服务端坐标） |
| `custom-cartel/server/{main,drug_lab}.lua` | 生产会话记录 + 配方时长校验 + 断线清理 |

### 4.5 Phase 1 收尾（多 agent 并行，第二轮）

| 文件 | 改动 |
|:---|:---|
| `custom-quest/server/{quest_db,quest_manager,quest_security}.lua` | 奖励幂等（affectedRows 回调 + 内存完成锁 + 10s 超时）、`_currentSteps` 步骤比对、完成锁清理 |
| `custom-main/server/{main,dispatch}.lua` | `ResetDeathStatus` 医疗启用时拦截 + 10s 冷却；`policeHandoverAlert` 坐标/星级/街道校验 + 5s 冷却 |
| `tcity-dashboard/server/police_api.lua` | `plateFlagged` 值班 LEO/admin 鉴权 + 车牌规范化 + 2s 冷却；内部同步改本地调用 |
| 9 个注册方 `fxmanifest.lua` + cartel/mining/justice/crime 9 个 server Lua | include `@core-framework/bus.lua`；19 处 `Bus.PascalCase` → 显式 `service_*` export，保留 fallback |
| `core-framework/compat.lua` | `GetPlayer` 缓存活性校验改用 `GetPlayerName`（`GetPlayerPing >= 0` 恒真） |
| `configs/modules/{custom,dev}.cfg` + `server.cfg.template` | `custom-testing` 移出生产，改由 `dev.cfg` 按需启用 |
| `tests/check_bus_wiring.py` + CI / `run_all.py` | 新增 Bus 接线检查：注册方漏 include `bus.lua` 直接 CI 失败 |

---

## 5. 三阶段路线图

> 你提到"基础功能 / 角色扮演 / 多系统 / Agent 导演"四项、三个阶段。我建议映射为：
> **阶段 1 = 基础功能**；**阶段 2 = 角色扮演 + 多系统（并行，按依赖顺序）**；**阶段 3 = Agent 导演**。
> 理由：导演必须建立在"可观测 + 可安全执行"的多系统之上，不能倒过来做。

### 阶段 1 — 基础功能：让它稳定地跑（2–3 周）

**目标**：空库部署 → 启动无错误 → 24h 压测不掉档 → 无 P0 漏洞。

| 工作流 | 交付 | 验收 |
|:---|:---|:---|
| 启动链 | 本报告 §4.1；console 无 `Could not start resource` / `Failed to load script` | 80 个资源全部 started |
| 数据层 | 执行全部 `migrations/*.sql`；补 `player_warns`/`server_logs` DDL | 新库无 "table doesn't exist" |
| 持久化 | qb-core tick + 停机刷盘；压测崩溃恢复 | kill -9 后重启，最近 15min 数据在 |
| 安全 | 本报告 §4.4/§4.5；剩余 R6 事件加校验 | 5 个"印钞/删实体"路径复测失败 |
| 观测底座 | 统一结构化日志（事件名/actor/quest/action id）；`/health` 输出资源状态 | 能回答"刚才发生了什么" |
| 测试 | 修好依赖检查；加启动冒烟脚本（资源状态 + DB 表 + 关键 export） | CI 红灯能拦住本次这类问题 |

**退出标准**：连续 24h 无脚本错误；48 人并发无掉档；P0 清零。

### 阶段 2 — 角色扮演 + 多系统：让它有戏可演（3–4 周）

**目标**：三条剧情线可完整通关；玩家在 30 分钟内能与真人产生第一次互赖；组织/司法/经济形成闭环。

| 工作流 | 交付 | 验收 |
|:---|:---|:---|
| 剧情 | R2/R5 已完成，补实机回归；决策选择持久化；三线 Ch1–Ch4 可通 | 选择重登后仍在；完成度门控正确 |
| 角色扮演 | quest + phone + job + justice 联动；RP 动词（/me、/do、911/311、场景标记）；新手引导 → 桥接 → 涌现漏斗 | 新玩家 30min 内首次真人交互；3 条弧线可玩 |
| 多系统 | `world_state` 真正接线；组织仓库/市场/司法用显式 export 调用（R1 的渐进修复）；`world_events` 开始写入 | 一次帮派易主能在世界状态/编年史看到 |
| 社交信号 | `funnel:social_signal` 从 quest/career 真实发射并被消费 | 能统计"完成任务的玩家有多少进入组织" |
| 运营工具 | GM 面板（场景投放、任务补偿、玩家回溯）；`custom-testing` 移出生产 | GM 不写 SQL 也能处理 80% 现场问题 |

**退出标准**：7 天公测；D1 留存与"首次真人交互时间"达标；无经济异常。

### 阶段 3 — Agent 中枢导演：让世界自己动（4–8 周）

**目标**：外部 Agent 能"看见"世界、提出 beat、经规则裁决后执行，并在玩家不接时体面退场。

| 工作流 | 交付 | 验收 |
|:---|:---|:---|
| Bridge | 新增 `custom-director`（server-only）：`SetHttpHandler` + Bearer token + `/v1/snapshot` `/v1/observe` `/v1/act` `/health` | 外部脚本可读状态、执行 L1 动作 |
| Action 层 | 白名单（L0–L4）、幂等键、预算、TTL、undo、审计 | 越权/超预算/重复动作全部被拒 |
| 规则导演 | 无 LLM 的节奏控制器：区域无事件 → 通知/氛围/世界状态 | 连续 7 天无事故，beat 接受率可测 |
| LLM 导演 | Planner（慢循环）+ Scene Director（中循环）；L3 需人审 | 72h 公测；失败率 < 2%；成本可控 |
| NPC 演员 | 只对玩家接触的 NPC 启用；记忆/反思/计划；服务端执行动作 | 对话不越权、不泄露玩家隐私 |
| 治理 | `director` ACE、Kill switch、自动熔断、Discord 审批、A/B | 事故可追责、可一键停用 |

**退出标准**：72h 连续运行；`act` 失败率 < 2%；无经济异常；玩家调研"导演事件不烦人" > 70%。

### 阶段依赖关系

```
阶段 1（能跑）
   └─→ 阶段 2（有戏）──→ 阶段 3（会动）
          │                 ↑
          └─ 观测/动作底座 ──┘
```

**不要跳过阶段 1 直接做阶段 3**：没有可靠的事件流和动作层，LLM 只能"瞎编 + 乱改"。

---

## 6. 调研：AI 导演/多 Agent 的可借鉴结论

> 完整架构草案见 [08-agent-director.md](../../../docs/server-design/08-agent-director.md)。

### 6.1 四条被验证的路线

| 路线 | 代表 | 可借鉴 | 不能照搬 |
|:---|:---|:---|:---|
| **节奏导演** | Left 4 Dead AI Director | 用"强度曲线"调节事件密度，而非写死剧本 | 它是 PvE 关卡导演，不处理玩家间政治 |
| **戏剧节拍** | Drama Manager / AI GM 研究 | 候选 beat + 打分选择；玩家偏离就放弃 | 学术环境小、无 48 人并发与持久经济 |
| **生成式 agent** | Generative Agents（Park et al.） | 记忆流 → 反思 → 计划；NPC 可信度来自记忆 | 25 个 agent 的成本/延迟模型不适用于全服 NPC |
| **大规模 agent 社会** | Project Sid（PIANO） | 统一世界状态、并发仲裁、多输出流一致 | 需要极强算力与仿真基础设施 |

### 6.2 对 T-City 的五条硬结论

1. **导演是调度器，不是世界**：世界状态必须由 FXServer 权威维护；LLM 只产出"意图/beat"。
2. **先观测，后智能**：没有结构化事件流，模型看不到世界，只能编。T-City 当前事件是"只发不收"，必须先补 `world_events` 与 `/observe`。
3. **动作必须分级**：L1 表现（通知/氛围）可自动；L3 任务/奖励需预算+审计；L4 经济/权限默认人工。
4. **成本要按"被接触的 NPC"计**：全服 NPC 都上 LLM 不可行；背景用模板，玩家主动交互才激活。
5. **玩家能动性是产品底线**：beat 必须有 `abort_signal`，同一玩家不能被连续针对；否则"AI 导演"会变成"AI 骚扰"。

### 6.3 五矿（FiveM）工程约束

- 每个 resource 独立 Lua state，跨资源只能用 **exports / events / state bags**（[官方 Script Runtimes](https://docs.fivem.net/docs/developers/script-runtimes/)）。
- 入站 HTTP 用 `SetHttpHandler`（server-only），必须绑定内网 + token；不要暴露公网。
- 出站用 `PerformHttpRequest`，必须异步 + 批量 + 重试；不要在主线程 `.await`。
- 客户端不可信：导演动作只能由服务端 bridge 执行，客户端只做表现。
- 已有先例：PedGPT 证明 FiveM 可跑 LLM peds，但它是客户端/外部驱动；T-City 应走"服务端权威"路线。

---

## 7. 验证清单（部署后逐项打勾）

### 7.1 启动

```bash
# 1) 依赖与顺序
python3 tests/check_dependencies.py     # 期望：无 ❌ / 🔴
python3 tests/check_cfgs.py             # 期望：0 缺失、0 重复
python3 tests/check_bus_wiring.py       # 期望：0 ERROR（WARN 可接受）

# 2) 数据库
mysql -u ... < migrations/v0.7_quest_system.sql
mysql -u ... < migrations/v0.7_story_engine.sql
mysql -u ... < migrations/v0.8_ownership_engine.sql
# 核对：SHOW TABLES LIKE 'player_quests'; 等
```

### 7.2 控制台

搜索并确认 **0 次**：

- `Could not start resource`
- `Failed to load script`
- `attempt to index a nil value (global 'MySQL')`
- `No such export`
- `dependency ... is not started`

确认出现：

- `[bus] 📦 Service registered: economy/job/...`
- `[story-engine] ✅ 剧情引擎已启动`
- `[persistence] ⏰ Flush tick started`
- `[custom-quest] ✅` 系列

### 7.3 功能冒烟

1. 新角色创建 → 出生 → 打开手机 → 接一个任务 → 完成 → 重登，进度仍在。
2. 接任务 A，再接任务 B，确认 A 仍能推进（R4 修复后）。
3. 决策任务：选一个选项 → 重登 → `player_choices` 有记录；故意关 NUI 等 2 分钟 → 任务不应卡死。
4. 卖一辆车/卖一次货 → 钱到账、日志有记录；重复调用完成事件不会二次发奖。
5. 断线重连 → 位置不是 `0,0,0`。
6. `/test` 是否仍对普通玩家开放（R8，未修则手动移除）。

### 7.4 安全复测

- 非警察执行 `/tccops`？应被 ACE 拒绝（若仍 `user` 级，需改）。
- 客户端伪造 `story:server:makeDecision` 传别的 quest → 应返回 context mismatch。
- 客户端伪造 `quest:server:nodeComplete` 远程完成 → 带坐标步骤应被距离拒绝。
- 知道车牌触发 `qb-vehiclekeys:server:GiveKeys`（非车主）→ 应被拒。
- 热狗摊非摊主触发 Sell → 应被拒。
- 医疗启用时伪造 `ResetDeathStatus` → 应被拦截并写安全日志。
- 非警察伪造 `policeHandoverAlert` 坐标/999 星 → 应被丢弃或夹紧。
- 非警察触发 `police:server:plateFlagged` → 应被拒。

---

## 8. 风险与未验证项

| 项 | 风险 | 处理 |
|:---|:---|:---|
| 未实机启动 | 静态修复可能漏掉运行期错误（如 export 名拼写、资源加载顺序细节） | 第一次启动务必保留完整 console 日志；按 §7.2 搜索 |
| `_G` 跨资源隔离 | 若某些环境/框架有共享假设，Bus 相关结论需重估 | 用 `/busstatus` 或 `BusStatus` export 实测：在另一资源调用应返回空/失败 |
| `oxmysql lib` 注入 | `@oxmysql/lib/MySQL.lua` 在各资源重复加载，可能有版本差异 | 确认 oxmysql 版本；启动后看 `MySQL` 是否非 nil |
| 载具 owner 校验 | 任务/警车等无主车辆依赖"车内授权"；若流程在车外给钥匙会被拒 | 重点回归警察/EMS/机修取车流程 |
| 热狗价格边界 | 仍是"客户端报价 + 服务端夹紧"，不是完整服务端定价 | 阶段 2 做服务端库存/定价模型 |
| 任务奖励幂等 | 已修（R2），需实机回归 | 阶段 1 退出前验证 |
| Bus 架构 | 仅修了经济出口；仓库/市场/组织服务仍静默降级 | 阶段 1 末做 `BusCall` bridge + 统一命名 |

---

## 9. 参考

- FiveM Script Runtimes（资源隔离/序列化）— <https://docs.fivem.net/docs/developers/script-runtimes/>
- FiveM SetHttpHandler — <https://cfxnatives.dev/natives/SET_HTTP_HANDLER>
- Generative Agents — <https://arxiv.org/abs/2304.03442>
- Project Sid — <https://arxiv.org/abs/2411.00114>
- AI Game Masters in Tabletop RPGs — <https://www.taylorfrancis.com/chapters/edit/10.1201/9781003632269-16/architecture-ai-game-masters-tabletop-rpgs-matt-eland>
- LLM Drama Managers — <https://dl.acm.org/doi/10.1145/3807895.3807937>
- L4D Director 研究 — <https://github.com/zeljkovranjes/l4d2-director-system-research>
- PedGPT（FiveM AI peds）— <https://github.com/MickMelon/PedGPT>

---

## 10. 给决策者的三句话

1. **先别加新玩法**：把"能启动、不丢档、不被刷"这三件事做扎实，比再写 10 个系统更有价值。
2. **AI 导演不是 prompt 工程**：它是"事件流 + 动作白名单 + 预算/审批"的工程；这三块不做，模型越强越危险。
3. **阶段 2 的验收不是"功能列表"**：而是"新玩家 30 分钟内是否被真人接住"。这是涌现玩法唯一的早期信号。
