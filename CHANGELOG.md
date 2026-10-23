# Changelog

All notable changes to T-City Lite will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- 客户端 MCP 测试 harness：Windows FiveM Legacy + `fivem-mcp-server`，经 FXServer 30120 HTTP 轮询桥接；提供 `client_command` / `screenshot` / `read_client_log` / `nuitest` 测试钩子
- Agent 接管栈：统一工具契约（`tools/agent_tools.json`，30 工具）、MCP 路由层、`custom-director` 17 个动作（L1–L4 分级 + 人审 + 执行后回读）、`custom-agent-client` 客户端效果通道
- 实时感知接口 `/agent/v1/live/*`（内存采样、25m 位置量化、独立 token）
- 拒绝审计 `agent_denials`（迁移 `v2.5`）与评测器 `tools/agent_eval.py`（成功率/审批/拒绝/P95/幂等）
- 实机冒烟 `tools/agent_smoke.py`（只读 → dry_run → 受控写三段式）
- Agent 文档：`docs/agent/{STATUS,TOOLS,EVAL,SMOKE,ACTIONS}.md` 与 `docs/agent/design/` 五份设计
- 全局审查报告与三阶段路线图：`T-CityLite.base/docs/audit/2026-10-21-review-and-three-phase-plan.md`
- Agent 中枢导演架构设计：`docs/server-design/08-agent-director.md`
- 任务系统建表脚本：`migrations/v0.7_quest_system.sql`（player_quests / quest_cooldowns / quest_event_log / quest_daily_limits）
- DevOps 工作流：CI（配置/依赖/Lua 语法）、Release、PR/Issue 模板、CODEOWNERS、CONTRIBUTING、SECURITY
- GitHub 初始化脚本：`tools/dev/bootstrap_github.sh`（标签 / 里程碑 / 待办 Issue）
- 开发工作流指南 (`docs/dev-workflow-guide.md`)，涵盖目录结构、分支策略、日常开发流程、Git 速查
- `start_server.bat` 一键启动脚本（UTF-8 编码，自动切换工作目录）

### Security
- `custom-vehicles`: `qb-vehiclekeys:server:AcquireVehicleKeys` 此前只校验会话内车主，任何客户端可伪造车牌远程认领载具；现改为车牌格式校验 → 会话车主 → `player_vehicles` 登记车主 → 无主载具 10m 邻近（`vehicles_claim_max_dist`）+ 1s 限流 + 审计
- `custom-vehicles`: `KeyManager.*` 拒绝非字符串车牌；`GiveKeys` 对无主载具要求先持有钥匙；`RemoveKeys` 仅车主可移除他人钥匙
- `qb-inventory`: `SetInventoryData` 对 `otherplayer-*` 容器增加 3m 距离校验（管理员豁免），堵住伪造事件远程搬运他人物品；槽位/数量先 `tonumber` 再比较，避免非法类型报错
- `custom-admin`: 全量自动 admin 改为 `admin_autogrant` convar（默认关闭）
- `story-engine`: 决策绑定服务端 pending offer（quest/step/decision），拒绝跨任务伪造；超时由服务端按默认选项收口
- `custom-quest`: `ValidateNode` 实现类型 + 服务端距离校验；`registerTrailer` 校验实体与距离；`cleanupTrailers` 改为非网络事件；`savePosCollection` 限制管理员
- `custom-vehicles`: 钥匙/改装/部件/氮气事件统一校验车主或执勤机修；部件值夹紧 0–100
- `qb-hotdogjob`: 职业校验 + 数量≤5 + 单价按 Config 边界，堵住 `$10k/秒`
- `qb-streetraces`: 服务端重建赛局与奖池，领奖前销毁，加入去重
- `custom-justice`: 出狱按刑期校验；入狱刑期上限
- `custom-mining` / `custom-cartel`: 矿点距离、生产开始/时长校验
- `custom-main`: `ResetDeathStatus` 仅在医疗未启用且服务端判定死亡/倒地时允许，10s 冷却；`policeHandoverAlert` 加 5s 冷却 + 坐标/星级/街道校验
- `tcity-dashboard`: `police:server:plateFlagged` 要求值班 LEO/admin，车牌规范化 + 2s 冷却；内部同步改为本地调用
- `custom-testing` 移出生产 cfg，改由 `configs/modules/dev.cfg` 按需启用

### Fixed
- `custom-quest`: 服务端重启后 `QuestCache` 未从 DB 预加载，`step_decision` 重连不弹窗；改为 `QBCore:Server:PlayerLoaded` 预加载 + `/questrestore`
- `story-engine`: decision NUI 增加焦点/`keepInput` 遥测、300s 看门狗、`SetNuiFocusKeepInput(false)`，避免重连软锁与手机 UI 抢焦点
- `core-framework` 引用了不存在的 `cache/*.lua`，导致自身及 9 个下游资源无法启动
- 启动顺序与 `fxmanifest` 依赖冲突（11 处）；补齐 `qb-prison`、`qb-minigames`、`safecracker`
- `custom-quest` / `custom-taxes` / `core-framework` / `qb-recyclejob` 缺少 `@oxmysql/lib/MySQL.lua`
- qb-core 无定时刷盘：补 15min tick + `onResourceStop`；断线位置回退，避免写 `0,0,0`
- 任务冷却异步查询导致永久失效；改为内存权威 + 登录回填
- `core_economy` 未定义 `EconomyService`；市场/卡特尔卖货扣物不付钱
- 剧情登录事件名错误（`QBCore:Server:OnPlayerLoaded` → `PlayerLoaded`）
- 组队任务双重抢锁、`RemoveGroupMember` 错误 key、断线不释放锁
- 接新任务覆盖活跃任务缓存；步骤尝试次数不重置
- 任务完成奖励幂等：`CompleteQuest` 回调只看 affectedRows，内存锁 + 10s 超时兜底，避免重复发奖
- 地址池任务步骤顺序绕过：缓存空窗期改用 `_currentSteps` 内存步骤比对，不再直接放行
- Bus 跨资源调用：7 个注册方 manifest include `@core-framework/bus.lua`，cartel/mining/justice 共 18 处改为显式 `service_*` export
- `core-framework/compat.lua`: `GetPlayer` 缓存改用 `GetPlayerName` 做活性校验（`GetPlayerPing >= 0` 恒真）
- `txAdminPort 0` 禁用管理员模式，避免端口冲突

### Changed
- `server.cfg.template` 按依赖图重排：`core → career → player → voice → custom → quest → police → vehicles → jobs → banking → medical → economy → security → crime → story → atmosphere → admin`
- `custom-quest` 从 `custom.cfg` 移到 `quest.cfg`；`custom-justice` 移到 `police.cfg`；`progressbar` 提前到 `player.cfg`
- `custom-testing` 从 `custom.cfg` 移到 `dev.cfg`（生产默认不加载）
- CI 增加 `check_bus_wiring.py`，防止注册方再次漏 include `bus.lua`

---

## [0.7a] — 载具重构与物流 — 2026-10-21

> 代码完成于 2026-06-22，tag 于 2026-10-21；实机验收仍待完成。

### Added
- **custom-vehicles**：替换 `qb-vehiclekeys`，事件驱动钥匙/锁车/共享，O(1) 内存缓存，兼容旧 exports/events；含安全带、巡航、转向灯、氮气、车辆损耗
- **tcity-dashboard v2.1**：Vue 3 车载中控屏，6 类载具模板，警用控制台 / ANPR / 雷达 / 追踪 / CCTV
- **custom-quest**：数据驱动任务状态机、外部脚本 API、安全门控、DB 持久化（v0.6 基础设施）
- **story-engine**：决策树与玩家选择追踪
- **物流任务模板**：`quest_logistics` 取货 → 运输 → 交付，含车辆/到达/货损校验
- **GitHub Actions CI**：CFG 完整性 + Lua 语法 + 依赖图 + pytest + oxmysql JS + MariaDB schema
- **运行时构建产物入库**：oxmysql `dist/web`、menuv `dist`、tcity-dashboard `nui/dist`
- **custom-ui**：统一 NUI 焦点、关闭后 300ms 防误触、距离校验；车店/车库/qb-menu/手机/中控屏接入
- **NUI 无头冒烟**：Playwright 覆盖车店 / 中控屏 / 车库 / 手机四个页面
- 开发工作流指南（`docs/dev-workflow-guide.md`）与一键启动脚本

### Changed
- **qb-vehicleshop Phase 1–5**：`while insideShop` 轮询改事件驱动；`finance.lua` 拆分为 lifecycle + payments；NUI 模式接通；客户端 Bus 注册；试驾独立车牌与钥匙清理
- `vehicles.cfg` 启用 `custom-vehicles` + `tcity-dashboard`，停用 `qb-vehiclekeys`

### Fixed
- **qb-garages**：SELECT 查询从 `rawExecute` 改为 `query/single`，并补充空车库诊断
- **qb-vehicleshop NUI**：加载顺序与 ConVar 同步修复
- **custom-taxes**：为未实现的车辆税 / NPC 定价补桩，避免调用报错
- **菜单交互**：车店改为按 E 主动打开（3.5m 距离），服务端购买距离 8m/30m；关闭菜单不再误触攻击
- **车店购买**：Processing/错误态 + 2s 防连点；Change Vehicle 不再跳 qb-menu
- **车库**：修复 NUI 回传 vector4 丢失导致的 spawnPoint nil；spawn 被拒时不再死循环；开发期共享车库
- **手机**：qb-phone 式 keepInput + DisableDisplayControlActions；状态栏/主时钟统一游戏时间
- **测试夹具**：对齐 `LocalDirtyFlush` 与 oxmysql `insert` 回调契约；测试路径改为相对仓库根目录
- **DB schema 测试**：兼容 MariaDB（JSON=LONGTEXT、ENUM 默认值引号、COLUMN_KEY）；新增 `v2.2_schema_reconcile.sql` 补齐 story-engine 索引
- `txAdminPort 0` 禁用管理员模式，避免端口冲突

### Testing
- `pytest tests`：**426 passed**（含 MariaDB schema；无 DB 连接时 286 passed / 132 skipped）
- oxmysql JS 单测：**148 passed**
- NUI 冒烟：**4/4 passed**（Playwright Chromium）
- 游戏内 `/test run all`：**298 PASS / 0 FAIL / 9 SKIP**（有玩家上下文；无玩家时 225 PASS / 8 SKIP；见 `docs/v0.7a-acceptance-report.md`）
- 离线检查：CFG / 依赖图 PASS；`light_lint` 仍为 advisory（vendor 资源遗留 ~250 条 `Wait(0)` / `MySQL.Sync`）

### Known
- 车店 NUI、车库、物流任务尚未完成真人客户端验收
- 8 个手机用例需要真实玩家上下文（无客户端环境会 SKIP）

---

## [0.6.0] — 核心架构安全与性能加固 — 2026-06

### Security
- **SQL 注入修复**: `qb-management` `sv_boss.lua` + `sv_gang.lua` 的 `LIKE '%jobname%'` 拼接改为 `JSON_EXTRACT` 参数化查询
- **弃用事件硬拒绝**: `QBCore:Server:UseItem` / `RemoveItem` / `AddItem` 从"打印警告+放行"改为"安全日志+拒绝执行"
- **SecurityService 集成**: `AddMoney` / `RemoveMoney` / `SetMoney` / `SetJob` / `SetGang` 全部接入 `Bus.SecurityService` 校验层（source 验证 + 输入清洗 + 阈值熔断）
- **qb-banking Rate Limit**: withdraw / deposit / transfer ×4 回调添加 2 秒冷却防刷
- **compat.lua 缓存加固**: `GetPlayer` 缓存添加 `GetPlayerPing >= 0` 活性校验，消除幽灵对象风险

### Changed
- **DirtyFlush 管道集成**: `QBCore.Player.Save()` 从直接 SQL 改为 DirtyFlush 代理——非强制存盘仅标记脏数据，批量定时落盘（默认 15 分钟），IO 削减 ~66%
- **ForceFlush 去循环**: `DirtyFlush.ForceFlush` 改为直接 SQL 写入，避免 `Save → ForceFlush → Save` 循环
- **hunger/thirst 优化**: `SetMetaData` 中饥饿/口渴不再标记 `IsDirty`，消除每 5 分钟全字段 UPDATE
- **qb-houses 死循环消灭**: 7ms 轮询改为一次性加载后线程退出
- **qb-vehicleshop 异步化**: `playerDropped` + `removePlayer` 中的 `.await` 改为异步回调
- **qb-phone 缓存层**: 新增 `PhoneCache` + GetInvoices 异步化 + mail 缓存失效

### Documentation
- 新建 `docs/bus-api-reference.md`，完整记录 Economy / JobService / SecurityService / PersistenceService / DirtyFlush 接口

---

## [0.5.0] — 犯罪玩法系统 — 🚧 开发中

### Added
- `custom-crime` 资源（犯罪逻辑服务端）
- `custom-main` 集成犯罪事件处理（server/crime.lua）
- 模块化 CFG: `configs/modules/crime.cfg`

---

## [0.4.0] — 自研手机系统 — 2026-06-01

### Added
- **自研手机系统** (`custom-phone`): Svelte + Vite + TypeScript 构建，Phone-First 架构
  - 前端 gzip 仅 42KB（远低于 250KB 目标）
  - 应用: Banking / Contacts / Messages / CityFeed / JobBoard / FactionChannel / Garage / Hotlines / Notifications / PhoneCall
  - 领袖应用: GangBossApp / MayorApp / SheriffApp
  - `PhoneShell.svelte` 统一 UI 壳
  - `stores/phone.ts` 状态管理 + `utils/nui.ts` NUI 通信层
- **数据库表自动创建**: `phone_messages`, `phone_contacts`, `phone_cityfeed`, `phone_jobboard`
- 服务端子模块: `banking.lua` / `faction.lua` / `jobboard.lua` / `main.lua`

### Security
- **H1 RED**: `completeJob` 守卫条件修复 — 跳过 career-tag 直接完成 open 任务
- **H2 RED**: `bankTransfer` 离线转账竞态条件 — `JSON_SET` 原子操作
- **H3 RED**: `shareContactNearby` 输入校验 — name≤30 + number≤15
- **M4 YELLOW**: `postJob` 奖励上限 $50,000
- **M5 YELLOW**: `bankTransfer` 单笔上限 $100,000
- 全文件乱码 emoji 修复

### Testing
- `08_phone_test.lua`: 23 占位 → 38 真实断言
- 覆盖 10 组: UI / DB / API / 消息 / 联系人 / 银行 / JobBoard / 安全 / 事件 / 架构

### Documentation
- `docs/v0.4-validation-plan.md`
- `docs/v0.4-joint-test-scenarios.md`
- `docs/v0.4-nui-standard.md`

---

## [0.3.0] — 基础设施层 — 2026-05

### Added
- **统一经济出口** (`custom-economy`): 所有资金变动通过 `AddScaledMoney`，Convar 热调节
- **安全防火墙** (`custom-security`): Rate Limit、距离校验、服务端事件拦截、Discord 审计日志
- **审计日志** (`custom-logs`): 结构化日志记录
- **多标签职业** (`custom-career`): 支持多职业切换
- **管理面板** (`custom-admin`): 服务端命令集
- 模块化 CFG: `economy.cfg` / `security.cfg` / `career.cfg` / `admin.cfg`
- `docs/v0.3-technical-manual.md` / `docs/v0.3-banking-refactor.md` / `docs/v0.3-test-checklist.md` / `docs/v0.3-test-manual.md`

### Testing
- 双层自动化测试框架 (`custom-testing`):
  - 离线 Python 检测: `check_cfgs.py` / `check_lua_syntax.py` / `check_db_schema.py` / `check_dependencies.py`
  - 游戏内测试框架: `test_runner.lua` + `mock_events.lua`
  - 9 个测试套件，118 个测试用例

---

## [0.2.0] — 基础 RP 模块 — 2026-05-28

### Added
- **职业系统**: `qb-management`（帮派/企业管理）
- **银行系统**: `qb-banking`
- **警察系统**: `qb-policejob`
- **医疗系统**: `qb-ambulancejob`
- **载具系统**: `qb-fuel` / `qb-vehiclekeys` / `qb-garages`
- **进度条**: `progressbar`
- 模块化 CFG: `jobs.cfg` / `banking.cfg` / `vehicles.cfg` / `police.cfg` / `medical.cfg`

### Fixed
- **pma-voice OneSync 依赖**: `server.cfg` 添加 `set onesync on`，解决语音系统启动失败

### Changed
- 启动加载保持模块化 `exec configs\modules\*.cfg`；`ensure [qb]` 保持禁用

### Gameplay
- **通缉等级警察接管系统** (`custom-main`):
  - 原生 GTA 通缉等级 ≥3 时自动清除 NPC 警察，移交追捕给玩家警察
  - 全服调度警报 + 持久化 metadata + 雷达三角定位红点（每 8 秒刷新）
  - `/clearwanted [id]` 警察命令
  - 本地平民 NPC 恐慌系统：行人尖叫逃窜、司机猛踩油门（25 米范围内）
- **自定义 Duty 切换命令**: `/duty` 快速切换执勤/下班，无需前往物理标记点

### Fixed
- Svelte UI 移除 "Order Physical Debit Card" 按钮（借记卡/ATM 已禁用）
- NUI 共享用户列表 bug 修复：`openBank` / `openATM` 回调中 `users` JSON 字符串解码为 Lua table

### Documentation
- `docs/v0.2-maintenance.md` / `docs/v0.2-test-checklist.md` / `docs/v0.2-master-test-manual.md`
- `docs/v0.2-wanted-handover-technical-memo.md` / `docs/v0.2-wanted-handover-test-guide.md`
- `docs/v0.2-status-persistence-technical-memo.md`
- `docs/v0.2-database-performance-maintenance-guide.md` / `docs/v0.2-hospital-optimization-guide.md`

---

## [0.1.0] — 精简启动链 — 2026-05-28

### Added
- 基于 `QBCore_CDB34E.base` 创建 Lite 版本
- **14 个模块化 CFG 启动体系**，废除 `ensure [qb]` 粗粒度加载
- 核心模块: `oxmysql` / `qb-core`
- 玩家流程: `qb-menu` / `qb-input` / `qb-target` / `PolyZone` / `qb-multicharacter` / `qb-spawn` / `qb-apartments` / `qb-interior` / `qb-clothing` / `qb-inventory` / `qb-weapons` / `qb-hud` / `qb-weathersync`
- 语音: `pma-voice`
- 自定义资源: `custom-main`

### Fixed
- **Spawn Death Prevention**: `custom-main` 实现自动血量恢复和复活回退系统（`qb-ambulancejob` 禁用时防止玩家出生即死亡）

### Infrastructure
- 依赖例外发现并添加: `PolyZone` / `qb-interior` / `qb-clothing` / `qb-weapons`
- 禁用资源追踪: `disabled-resources-v0.1.md`
- `server.cfg.template` 模板配置
- `docs/v0.1-maintenance.md`

### Testing
- 基础客户端测试通过
- 重连持久化验证通过

---

[0.7a]: https://github.com/wenkais196-Gabriel/T-City/releases/tag/v0.7a
[0.6.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/wenkais196-Gabriel/T-City/releases/tag/v0.1.0
