# T-City Lite Changelog

## v0.6 — 核心架构安全与性能加固 (Architecture Hardening)

Date: 2026-06

### 🔒 安全加固 (Security)
- **SQL 注入修复**: `qb-management` sv_boss.lua + sv_gang.lua 的 `LIKE '%jobname%'` 拼接改为 `JSON_EXTRACT` 参数化查询
- **弃用事件硬拒绝**: `QBCore:Server:UseItem` / `RemoveItem` / `AddItem` 从"打印警告+放行"改为"安全日志+拒绝执行"
- **SecurityService 集成**: `AddMoney` / `RemoveMoney` / `SetMoney` / `SetJob` / `SetGang` 全部接入 `Bus.SecurityService` 校验层（source 验证 + 输入清洗 + 阈值熔断）
- **qb-banking Rate Limit**: withdraw / deposit / transfer ×4 回调添加 2 秒冷却防刷
- **compat.lua 缓存加固**: `GetPlayer` 缓存添加 `GetPlayerPing >= 0` 活性校验，消除幽灵对象风险

### ⚡ 性能优化 (Performance)
- **DirtyFlush 管道集成**: `QBCore.Player.Save()` 从直接 SQL 改为 DirtyFlush 代理——非强制存盘仅标记脏数据，批量定时落盘（默认 15 分钟），IO 削减 ~66%
- **ForceFlush 去循环**: `DirtyFlush.ForceFlush` 改为直接 SQL 写入，避免 `Save → ForceFlush → Save` 循环
- **hunger/thirst 优化**: `SetMetaData` 中饥饿/口渴不再标记 `IsDirty`，消除每 5 分钟全字段 UPDATE
- **qb-houses 死循环消灭**: 7ms 轮询改为一次性加载后线程退出
- **qb-vehicleshop 异步化**: `playerDropped` + `removePlayer` 中的 `.await` 改为异步回调
- **qb-phone 缓存层**: 新增 `PhoneCache` + GetInvoices 异步化 + mail 缓存失效

### 🧱 基础设施 (Infrastructure)
- **Bus API 手册**: 新建 `docs/bus-api-reference.md`，完整记录 Economy / JobService / SecurityService / PersistenceService / DirtyFlush 接口

### 📝 修改文件清单
| 文件 | 改动 |
|------|------|
| `qb-management/server/sv_boss.lua` | SQL 注入修复 |
| `qb-management/server/sv_gang.lua` | SQL 注入修复 |
| `qb-houses/server/main.lua` | 死循环消除 |
| `qb-core/server/events.lua` | 弃用事件硬拒绝 |
| `qb-core/server/player.lua` | DirtyFlush + SecurityService + hunger 优化 |
| `core-framework/cache/dirty_flush.lua` | ForceFlush 去循环 |
| `core-framework/compat.lua` | GetPlayer 活性校验 |
| `qb-vehicleshop/server.lua` | 异步化 |
| `qb-banking/server.lua` | Rate Limit |
| `qb-phone/server/main.lua` | PhoneCache + 异步化 |
| `docs/bus-api-reference.md` | 新建 |

---

## v0.2 - Basic RP modules

Date: 2026-05-28

- Added modular startup cfg files for jobs, banking, vehicles, police, and medical.
- Enabled `progressbar`, `qb-management`, `qb-banking`, `qb-fuel`, `qb-vehiclekeys`, `qb-garages`, `qb-policejob`, and `qb-ambulancejob`.
- Kept startup loading modular through `exec configs\modules\*.cfg`; grouped `ensure [qb]` remains disabled.
- **Fixed `pma-voice` OneSync dependency**: Added `set onesync on` to `server.cfg` to resolve OneSync error and allow voice system to start successfully.
- Verified database tables (`bank_accounts`, `bank_statements`, `player_vehicles`) in `QBCore_CDB34E` are fully loaded and operational.
- Recorded v0.2 resource inventory, dependency notes, security preaudit, and deferred resources.
- Confirmed `qb-core\shared\jobs.lua` already includes police, ambulance, mechanic, taxi, and boss grade configuration.
- Deferred `qb-phone`, `qb-smallresources`, `qb-doorlock`, and `qb-prison` until future milestones.
- **Test Feedback Adjustments (2026-05-29)**:
  - Removed "Order Physical Debit Card" button from Svelte UI and disabled server-side card ordering callback since debit cards and ATMs are disabled.
  - Fixed NUI shared users list bug by decoding `users` JSON string into a Lua table in `openBank` and `openATM` callbacks (resolving the `[` and `]` display issue).
  - **Wanted Level Police Handover & Radar blips (New Custom Gameplay)**: Implemented custom client/server dispatch system inside `custom-main` where native GTA wanted levels >= 3 automatically clear native AI cops (preventing NPC clutter) and hand over the chase to player police. Triggered server-wide dispatch alerts, persistent metadata saving, radar triangulation red-blips updating every 8 seconds on on-duty cop HUDs, and a `/clearwanted [id]` police command. Includes a **local civilian NPC panic system** where pedestrians scream and flee in fear, and drivers slam the gas to speed away when within 25 meters of a wanted fugitive.
  - **Custom Duty Toggle Command**: Added a convenient chat command `/duty` allowing players with compatible careers (police, ambulance, mechanic, taxi) to quickly toggle between active duty (On Duty) and off duty (Off Duty) without needing to visit the physical duty markers inside target buildings.
- Completed and checked off all milestones in `v0.2-basic-rp.md` spec checklist.


## Active v0.2 resources

### Jobs

- progressbar
- qb-management

### Banking

- qb-banking

### Vehicles

- qb-fuel
- qb-vehiclekeys
- qb-garages

### Police

- qb-policejob

### Medical

- qb-ambulancejob

## v0.1 - Lite startup chain

Date: 2026-05-28

- **Spawn Death Prevention**: Implemented an automated health restoration and auto-revival fallback system in `custom-main` that automatically triggers when `qb-ambulancejob` is disabled, preventing players from spawning dead/downed during testing.
- Created Lite base from `D:\txData\QBCore_CDB34E.base`.
- Reworked startup loading away from grouped `ensure [qb]`.
- Added module configs under `configs\modules`.
- Added disabled resource tracking for v0.1.
- Added startup test log placeholder for first server run.
- Added user input checklist for sensitive or environment-specific config.
- Added required dependency exceptions discovered from manifests: `PolyZone`, `qb-interior`, `qb-clothing`, and `qb-weapons`.
- Added v0.1 maintenance documentation under `docs\v0.1-maintenance.md`.
- Recorded basic client test as passed.

## Active v0.1 resources

### Core

- oxmysql
- qb-core

### Player

- qb-menu
- qb-input
- qb-target
- PolyZone
- qb-multicharacter
- qb-spawn
- qb-apartments
- qb-interior
- qb-clothing
- qb-inventory
- qb-weapons
- qb-hud
- qb-weathersync

### Voice

- pma-voice

### Custom

- custom-main

## Known pending items

- [x] Reconnect persistence has been successfully tested and confirmed operational by the user.
- FiveM license key and public server metadata should be confirmed before public use.
- Continue capturing console and client F8 errors during later module expansion.


## v0.4 - Custom Phone（验证完善版）

Date: 2026-06-01

### 安全修复
- **H1 RED**: completeJob 守卫条件修复 — 跳过 career-tag 直接完成 open 任务
- **H2 RED**: bankTransfer 离线转账竞态条件 — JSON_SET 原子操作
- **H3 RED**: shareContactNearby 输入校验 — name<=30 + number<=15
- **M4 YELLOW**: postJob 奖励上限 $50,000
- **M5 YELLOW**: bankTransfer 单笔上限 $100,000
- 全文件乱码 emoji 修复

### 数据库增强
- 新增 4 张表自动创建: phone_messages, phone_contacts, phone_cityfeed, phone_jobboard

### 测试体系
- 08_phone_test.lua 23 占位 -> 38 真实断言
- 覆盖 10 组: UI/DB/API/消息/联系人/银行/JobBoard/安全/事件/架构

### 性能基线
- 前端 gzip 42KB << 250KB

### 文档
- docs/v0.4-validation-plan.md
- docs/v0.4-joint-test-scenarios.md
