# Changelog

All notable changes to T-City Lite will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- 开发工作流指南 (`docs/dev-workflow-guide.md`)，涵盖目录结构、分支策略、日常开发流程、Git 速查
- `start_server.bat` 一键启动脚本（UTF-8 编码，自动切换工作目录）

### Fixed
- `txAdminPort 0` 禁用管理员模式，避免端口冲突

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

[Unreleased]: https://github.com/YOUR_USER/T-City-Lite/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/YOUR_USER/T-City-Lite/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/YOUR_USER/T-City-Lite/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/YOUR_USER/T-City-Lite/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/YOUR_USER/T-City-Lite/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/YOUR_USER/T-City-Lite/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/YOUR_USER/T-City-Lite/releases/tag/v0.1.0
