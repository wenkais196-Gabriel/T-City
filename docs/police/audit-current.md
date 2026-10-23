# T-City 警察能力现状审计（local audit）

> 审计对象：`feat/police-roleplay` 工作树，只读代码 + 只读启动日志，未改任何 Lua/配置。
> 审计日期：2026-10-23 ｜ 服务器日志：`/tmp/fxserver.log`（589 行，当次启动）
> 结论口径：**可用** = 有服务端鉴权且主链路能闭环；**半成品** = 有代码但链路断/不持久/只做一半；**缺失** = 无实现；**冲突** = 两套以上实现互不相认或语义打架。

---

## 0. 一页结论（三个最大问题）

### 问题 1：判刑 → 入狱链路是断的，且存在两套互不相认的监狱

- `custom-justice` 的入狱入口由**嫌疑人自己的客户端**发起：`justice:client:verdictReceived` → `TriggerServerEvent('justice:server:imprison', 自己 citizenid, 刑期)`（`resources/[custom]/custom-justice/client/main.lua:89-101`）。
- 服务端却要求调用者职业为 `police`/`judge`（`server/prison.lua:17-21`），普通嫌犯必然被拒。→ **判决永远进不了监狱**。
- 即便绕过，写入 `JusticeService.Inmates[citizenid]`（`server/prison.lua:34,47`）也必然报 `attempt to index a nil value`：`JusticeService` 只暴露了 `GetInmates/GetInmate/ReleaseInmate`，**从未定义 `Inmates` 字段**（`server/main.lua:4-107`；全仓 grep 只有 `GetInmates` 一处）。
- 真正可用的监狱是 `qb-prison`：`/jail` → `police:client:SendToJail` → `prison:client:Enter`（`qb-policejob/client/main.lua:196-203`、`qb-prison/client/main.lua:174`）。它还会把囚犯职业改成 `unemployed`、暂存背包（`qb-prison/server/main.lua:5-44`）。
- `custom-justice` 自己另写了一套 `enterPrison` 传送 + 客户端倒计时（`client/main.lua:42-75`），既不写 `injail` metadata，也不进 qb-prison 的牢房/劳动逻辑 → **玩家只是被传送到监狱门口，可以走掉**。

**影响**：法庭/律师/减刑/探视全部悬空；一旦修 MDT 或案件系统，会先撞上这条断链。

### 问题 2：案件/证据/罚单/通缉/出警记录全部没有持久化，MDT 没有数据源

- `custom-justice` 的 `activeCases`、`inmates` 都是纯内存表（`server/main.lua:7,11`），**整个资源没有一处 SQL**（grep `MySQL|oxmysql` 只命中 manifest 依赖行）。重启即清零，离线恢复只在同一进程内有效（`server/main.lua:132-141`）。
- `qb-policejob` 证据也是内存表：`Casings/BloodDrops/FingerDrops/PlayerStatus`（`server/evidence.lua:1-4`），只能变成背包里的 `filled_evidence_bag` 物品，**没有 case_id 概念**。
- 车牌 BOLO 有两套存储：`qb-policejob` 的 `Plates` 内存表（`server/vehicle.lua:1,101-136`）与 `tcity-dashboard` 的 SQL 表 `plate_flags`（`tcity-dashboard/server/police_api.lua:19-49`）。两边互不同步：`/flagplate` 只写内存，dashboard 的 ANPR 只读 SQL。
- 通缉只是 qb-core metadata `wanted` + 内存 `WantedPlayers`（`custom-main/server/dispatch.lua:2,38-95`），没有通缉令/搜查令/审批/有效期。
- 罚单：`/fine`、`/bill` 直接扣钱，失败时写 `phone_invoices` 并触发 `qb-phone:client:AcceptorDenyInvoice`（`qb-policejob/server/commands.lua:303-308`）——**custom-phone 不实现该事件，也没有账单 UI**（custom-phone 无 invoice UI/事件处理，只在 `qb_phone_compat` 注释里提到），所以"付不起的罚单"静默丢失。
- 数据库现有可复用表里没有任何 `case/evidence/warrant/citation/report/dispatch` 表（`tests/fixtures/tcity_schema.sql` 47 张表，grep 无命中）。

**影响**：手机 MDT 目前只能查"谁在执勤"，任何案件面板都会是无源之水。

### 问题 3：警察身份判定分裂（`job.type == 'leo'` vs `job.name == 'police'`）+ 若干客户端信任漏洞

- 同一份代码里两种判定并存：`qb-policejob` 主路径用 `job.type == 'leo'`（如 `server/main.lua:12,35,120`），但 `server/vehicle.lua:88` 用 `job.name == 'police'`；`custom-justice`（`server/arrest.lua:16`、`server/prison.lua:18`）、`custom-main`（`server/dispatch.lua:88,145,204`）、`custom-phone`（`server/apps/police_mdt.lua:16`）、`tcity-dashboard`（`server/police_api.lua:71-78` 做了兼容）混用两套。当前 `qb-core/shared/jobs.lua:63-76` 里 `police` 同时 `name='police'`、`type='leo'`，所以"碰巧"能跑；任何改名/新增执法职业（BCSO/SASP）立刻分叉。
- 客户端可触发的越权/伪造面（服务端未鉴权或鉴权不完整）：
  - `police:server:autoAlert` 完全无鉴权，任意客户端可伪造坐标+文案刷警情（`server/main.lua:167`）。
  - `police:server:RobPlayer` 没有任何 LEO 校验，任意玩家在 2.5m 内可抢走对方全部现金并打开其背包（`server/interactions.lua:196-214`）。
  - `police:server:SetTracker`、`police:server:SendTrackerLocation` 无 LEO 校验，可伪造"脚环定位"（`server/main.lua:225,250`）。
  - `police:server:showFingerprint` 无职业校验，可对任意玩家刷指纹界面（`server/main.lua:211`）。
  - `qb-policejob:server:evidence` 的仓库名由客户端传入（`client/job.lua:455` → `server/main.lua:137-146`），值班警察可打开任意名字的库存。
  - `justice:server:registerArrest` 的 `officerSrc` 来自客户端参数（`server/arrest.lua:11-16`），可冒用其他警员身份登记案件。
  - `prison:server:SetJailStatus` 任何客户端可调用（`qb-prison/server/main.lua:5`），会把 metadata `injail` 改成任意值（含 0）。
- 反之，有些路径又"过度信任服务端命令"：`/impoundplayer`、`/impoundnear` 注册时带 `permission='admin'`（`server/vehicle.lua:180,191`），普通警察按设计**用不了**（`QBCore.Commands.Add` 会 `add_ace qbcore.admin`，`qb-core/server/commands.lua:18-52`）。

**影响**：修警察系统前必须先收敛"谁是警察/是否在勤"的唯一判定，否则每加一个功能就多一个分叉。

---

## 1. 范围、方法与运行时事实

### 1.1 已检查的范围

| 资源 | 关键文件 |
|---|---|
| `[qb]/qb-policejob` | `fxmanifest.lua`、`config.lua`、`server/{main,commands,interactions,evidence,vehicle,objects}.lua`、`client/{main,job,evidence,interactions,heli,anpr,tracker,stolen_radar}.lua` |
| `[custom]/custom-justice` | `config.lua`、`server/{main,arrest,trial,prison}.lua`、`client/main.lua` |
| `[qb]/qb-prison` | `server/main.lua`、`client/{main,jobs,prisonbreak}.lua` |
| `[custom]/custom-career` | `configs.lua`、`server/main.lua` |
| `[custom]/custom-phone` | `server/{phone_apps,main,faction,qb_phone_compat}.lua`、`server/apps/police_mdt.lua`、`client/main.lua`、`web/src/{App.svelte,apps/*,stores/apps.ts}` |
| `[custom]/custom-director` | `server/{policy,main,live_api,live_events}.lua`、`tools/agent_tools.json` |
| `[custom]/custom-vehicles` | `config.lua`、`server/dashboard_api.lua`、`client/{main,dashboard}.lua` |
| `[system]/tcity-dashboard` | `server/police_api.lua`、`client/police.lua`、`nui/src/components/tabs/PoliceConsole.vue` |
| `[custom]/custom-main` | `server/dispatch.lua`（通缉/警星，范围外但属于警察能力） |
| `[custom]/custom-quest` | `config/quests/quest_police_*.lua`、`server/quest_registry.lua` |
| DB | `migrations/v*.sql`、`tests/fixtures/tcity_schema.sql`、`tcity-dashboard/sql/plate_flags.sql` |
| 配置/日志 | `configs/modules/{police,career,vehicles,quest,custom}.cfg`、`/tmp/fxserver.log` |

### 1.2 运行时事实（当次启动）

- 启动顺序符合配置：`qb-prison` → `qb-policejob` → `custom-justice`（`/tmp/fxserver.log:300-310`，对应 `configs/modules/police.cfg:4,7,11`）。
- `custom-justice` 三个子模块均打印已加载（`log:305-309`）；`custom-phone` 注册 `police_mdt`（`log:137`），并在 QBCore 就绪后 `loaded=police_mdt callbacks=ready`（`log:444`）。
- 本次日志 **无 `SCRIPT ERROR`/traceback**；唯一报错是服务器列表上报失败（`log:446,566`，与 `sv_listingIpOverride` 有关，非警察资源）。
- `custom-quest` 注册 6 条警察剧情（`log:222-233,272-283`），`story-engine` 注册 3 个警察决策点（`log:394-399`）。
- 文档漂移：`docs/01_resource_inventory.md:124` 仍写 "qb-prison v0.2 deferred / 旧资源未启用"，但 `police.cfg:4` 明确 `ensure qb-prison` 且日志已启动 → 文档需回写（不在本次改动范围）。
- `LegacyFuel` 不是缺失资源：`qb-fuel` 通过 `provide 'LegacyFuel'` 提供同名导出（`resources/[qb]/qb-fuel/fxmanifest.lua`），`Config.FuelResource='LegacyFuel'` 可解析。
- `custom-vehicles/client/dashboard.lua` 仍在磁盘上但 manifest 已不加载（`custom-vehicles/fxmanifest.lua:46` 注释"已迁移至 tcity-dashboard"）→ 死代码，容易误改。

### 1.3 本审计**没有**验证的内容

- 未起服、未进游戏，所有"可用/断链"结论来自静态代码与启动日志；`SetEntityCoords`/`DropPlayer`/OneSync 行为未实测。
- 未查线上 MariaDB 实际表结构（`plate_flags` 存在两套列名，见 §2 冲突行与 §5 风险）。
- 未核对 Discord webhook 是否真的收到 `custom-logs` 的审计消息。

---

## 2. 能力矩阵

> 状态口径见页首。`file:line` 均相对仓库根 `T-City-agent/`。为压缩表格，`policejob/` = `T-CityLite.base/resources/[qb]/qb-policejob/`，`justice/` = `.../[custom]/custom-justice/`，`phone/` = `.../[custom]/custom-phone/`。

### A. 身份、等级与执勤

| 能力 | 现有实现(file:line) | 状态 | 证据 | 建议 |
|---|---|---|---|---|
| A1 上下班（On/Off Duty） | `policejob/client/job.lua:462-466`；`policejob/client/job.lua:767-800` 值班点 | 可用 | `QBCore:ToggleDuty` + `job.onduty`，qb-core 权威 | 保留；补一条统一审计（见 F4） |
| A2 在线执勤名册 | `phone/server/apps/police_mdt.lua:9-28`；`custom-director/server/live_api.lua:4-8` | 可用 | 手机 `officers` 查询按 `job.name=='police' and onduty` 过滤；live API 支持 `?job=police` | 名册加 department/district/callsign |
| A3 部门 / 辖区分配 | `policejob/server/commands.lua:155-203`；`custom-career/server/main.lua:316-336` | 半成品 | 值写入 `players.department/district` 并同步 state，但**无任何玩法读取**：`Config.Departments` 仅出现在 config 与分配命令（`config.lua:11-16`，全仓无 `allowOffdutyCuff` 消费方），警械库也没实现 | 要么让部门驱动装备/车库/权限，要么删掉假字段 |
| A4 职业/等级/组织权威 | `qb-core/shared/jobs.lua:63-76`（0 Recruit–4 Chief）；`custom-career/server/main.lua:84-93,115-157` | 可用 | `job.grade.level` 被车库、罚款、执照命令使用；career 只做组织映射与镜像，不反向写 job | 继续以 qb-core job 为唯一权威 |
| A5 执照/证照查验 | `policejob/server/commands.lua:10-108,334-428`；`custom-certificates`、`custom-documents` | 可用 | `/grantlicense`、`/revokelicense`、`/suspendlicense`、`/reinstatelicense` 全走 certificates；`/checkid`、`/checklicense` 有 3.5m 距离 + onduty | 把 `LicenseRank=2` 与 grade 语义写进文档 |

### B. 现场处置与装备

| 能力 | 现有实现(file:line) | 状态 | 证据 | 建议 |
|---|---|---|---|---|
| B1 上铐/护送/押运/搜身 | `policejob/server/interactions.lua:1-107`；`policejob/client/interactions.lua:242-355` | 可用 | 2.5m 距离校验 + `DropPlayer`；`handcuffs` 物品或 LEO 身份 | 补 `job.type` 统一判定（问题 3） |
| B2 没收现金 / 抢劫 | `policejob/server/interactions.lua:157-174,196-214` | 可用 | 现金 → `moneybag` 物品；`RobPlayer` 距离 2.5m | **立刻给 `RobPlayer` 补 LEO + onduty 校验**（当前任意玩家可抢） |
| B3 罚单 / 账单 | `policejob/server/commands.lua:269-310`；`server/interactions.lua:109-129` | 半成品 | 有 50k 上限与银行/现金扣款；付不起时写 `phone_invoices` 并触发 custom-phone 未实现的 `AcceptorDenyInvoice` | 用 `police_citations` 表 + 手机缴费页替换 invoice 兼容路径 |
| B4 现场证据（血迹/指纹/弹壳/证物袋） | `policejob/server/evidence.lua:1-159`；`client/evidence.lua:77-180` | 半成品 | 全部内存；`evidence:server:CreateBloodDrop` 无鉴权、可伪造 citizenid（`evidence.lua:69-76`）；无 case 关联 | 持久化 `police_case_evidence`，写入前服务端复算 DNA/指纹 |
| B5 警械库 / 装备领取 | `config.lua:5-6`（`ArmoryWhitelist`、`LicenseRank`） | 缺失 | `client/job.lua` 有 `inArmoury` 变量但**无任何军械库 zone/menu**；`ArmoryWhitelist`、`Config.Departments[*].weapons` 全仓无消费方 | 先做最小军械库（按 grade/department 发枪+弹+护甲） |
| B6 路障/钉刺带/警灯/直升机 | `policejob/server/objects.lua`；`client/objects.lua:74-300`；`client/heli.lua` | 可用 | `/spikestrip`、`/pobject`、直升机菜单，载具同步走 `police:client:SyncSpikes` | 直升机补 pilot 执照校验（`police_plan.md` 里已提出，未落地） |
| B7 警犬 K9 | 无 | 缺失 | 全仓 grep `k9/dog/canine` 无实现 | 可选；先用剧情/NPC 表现，别急着做实体犬 AI |
| B8 便衣 / 卧底（CID/SWAT 差异化） | `config.lua:14`（`CID.allowOffdutyCuff`） | 缺失 | 只有一个未被读取的配置键；SWAT/CID 与 PATROL 的装备、车库、权限完全一致 | 要么按部门切装备/车库，要么先删字段避免"看起来有" |

### C. 载具与警车

| 能力 | 现有实现(file:line) | 状态 | 证据 | 建议 |
|---|---|---|---|---|
| C1 警车车库（等级阶梯） | `policejob/config.lua:141-176`；`client/job.lua:162-188` | 可用 | `for grade=0,playerGrade` 累进解锁，按 0–4 级逐级累加（唯一车型 7 款，跨级重复）；`policet` 从 grade1 起 | 补部门限制（SWAT 才能取 `fbi`？） |
| C2 扣押 / 取回 | `policejob/server/vehicle.lua:10-83,157-191` | 可用 | 仅 onduty LEO；`player_vehicles.state=0/2`；取回有 10m 距离校验 | 加 `police_impound_log`（谁扣的/为什么/何时放） |
| C3 警车中控（ANPR/测速/GPS 追踪/CCTV/查人查车） | `tcity-dashboard/server/police_api.lua:124-277,328-418`；`client/police.lua`；`nui/.../PoliceConsole.vue` | 可用 | 服务端 `isOnDutyLeo` + 1s 限流 + 距离/驾驶席校验；NUI 有 🚨ANPR、🔊警笛、📡追踪器、🔍数据库查询 | 把它当"车载 MDT"复用，别在手机端重写一套查询 |
| C4 警笛 / PA / 共享钥匙 | `custom-vehicles/server/dashboard_api.lua:177-210`；`custom-vehicles/config.lua:103-112` | 可用 | 警笛经 dashboard 事件广播；`SharedKeys.police` 含 `police/police2` | `requireOnduty=false` 建议改 true（下班也能开警车） |

### D. 通缉、调度与情报

| 能力 | 现有实现(file:line) | 状态 | 证据 | 建议 |
|---|---|---|---|---|
| D1 车牌 BOLO | `policejob/server/vehicle.lua:1,101-154`；`tcity-dashboard/server/police_api.lua:19-49,124-171,291-326` | 冲突 | 两套存储：policejob 内存 `Plates`（`/flagplate`/`/plateinfo`）vs dashboard SQL `plate_flags`（ANPR/中控屏）。dashboard 还监听 `police:server:plateFlagged` 做桥接，但 policejob **从不触发**该事件 → 命令标了、ANPR 看不到 | 只留 SQL 一套；`/flagplate` 直接调 dashboard 服务（Bus `police.FlagPlate`） |
| D2 通缉 / 警星 / 嫌疑人雷达 | `custom-main/server/dispatch.lua:2,38-95,154-155,204`；`client` 的 `updateSuspectBlip` | 半成品 | `wanted` 写进 metadata（可离线恢复），但 `WantedPlayers` 是内存；无通缉令编号/罪名/签发人/有效期；`clearwarrant` 只是 `clearwanted` 的别名 | 新建 `police_warrants`，把 `wanted` 降级为缓存 |
| D3 911 / 警情广播 | `policejob/server/commands.lua:530-544`；`server/main.lua:148-179`；`phone/client/main.lua:773-805` | 可用 | `911p`/`policeAlert` 只发给 onduty LEO；custom-phone 用 `qb-phone:client:addPoliceAlert` 兼容层弹通知（负数 id，不落库） | 把广播同时落 `police_dispatch_calls`，让 MDT 能回看 |
| D4 911 热线电话接入 | `phone/server/main.lua:916-967`；`web/src/apps/Hotlines.svelte:6-13` | 半成品 | `triggerHotlineCall` 只给执勤警员发 notification，**不建立通话**；`911-SURR` 映射到不存在的 `surrender` 职业，永远走 IVR；IVR 有硬编码 mock（`Hotlines.svelte:29-33`） | 用现成 `StartSystemCall`/`phone_calls` 建真实 911 通话 |
| D5 出警记录 / 调度台 | 无 | 缺失 | 无表、无 UI、无"接单/到场/结案"状态；`custom-main` 只有 `/clearwanted`、`/duty` | 最小版：`police_dispatch_calls` + MDT 列表 + 接单/结案 |
| D6 搜查令 / 通缉令文书 | 无 | 缺失 | `custom-documents` 只有证照查验，未接令状 | 与 D2 合并做 `police_warrants`（类型 search/arrest，需上级审批） |

### E. 司法、监狱与案底

| 能力 | 现有实现(file:line) | 状态 | 证据 | 建议 |
|---|---|---|---|---|
| E1 逮捕登记（案件） | `justice/server/arrest.lua:11-92,147-162`；`justice/server/main.lua:17-58` | 半成品 | `/arrest` 能建内存 case + 通知律师；但**无调用方**（policejob 全仓 grep `justice` 零命中），`officerSrc` 可伪造，无 onduty/距离校验，重启即丢 | 改由 policejob 的 `/jail` 或 MDT 调用统一 `OpenCase` API |
| E2 法庭审判 | `justice/server/trial.lua:9-105,113-152` | 半成品 | 有完整量刑公式（罪名 baseMinutes、律师 -30%、初犯 -20%、最低 5 分钟）与 `/cases` 列表；但 **`startTrial` 只注册了事件，没有任何命令或 UI 触发**（全仓 grep 仅 server 自身） | 在 MDT 案件页加"开庭"按钮，走 judge 权限 |
| E3 量刑 / 入狱 | `justice/server/prison.lua:9-77`；`justice/client/main.lua:89-101` | 冲突 | 嫌疑人客户端触发 → 服务端只允许 police/judge → 必定被拒；`JusticeService.Inmates` 为 nil；`Config.Justice.MaxSentence` 不存在（`config.lua` 无此键，回退 120，与 murder 的 480 冲突）；不写 `injail` | 见问题 1；服务端 `Sentence()` 统一写 `police_prison_sentences` 并驱动 qb-prison |
| E4 监狱服刑 / 劳动 / 释放 | `qb-prison/server/main.lua:5-44`；`qb-prison/client/main.lua:174-270` | 可用 | `/jail` → `prison:client:Enter`（资源白名单 qb-policejob/ambulance）→ 随机牢房、换装、劳动、`injail` metadata、出狱还包 | 保留为唯一"实际关押"实现，justice 只负责量刑 |
| E5 减刑 / 探视 | `justice/server/prison.lua:83-119,164-185` | 半成品 | 减刑按比例扣内存刑期，探视只发通知；都依赖 E3 的 inmate 记录，实际不可达；`good_behavior` 定时器是空循环（`prison.lua:191-203`） | 与 E3 一起重做，否则先删按钮避免误导 |
| E6 罚金 / 前科 / 案底 | `custom-main/server/dispatch.lua:71-76`（`criminalrecord` 只记 hasRecord+date） | 缺失 | 无罚单历史、无犯罪记录明细、无查询入口；`criminalrecord` 在 qb-prison 里还会被月份逻辑改回 false（`qb-prison/server/main.lua:79-96`） | `police_citations` + `police_cases` 提供"案底"查询 |

### F. 记录、审计与 Agent

| 能力 | 现有实现(file:line) | 状态 | 证据 | 建议 |
|---|---|---|---|---|
| F1 MDT 案件/报告/记录 | 无 | 缺失 | `qb-policejob` 的 `html/` 只有摄像头/指纹/直升机 HUD（`html/script.js` 的 `CameraApp/HeliCam/Fingerprint`），无 MDT；无表 | 手机 MDT + 车载 PoliceConsole 共用一套只读 API |
| F2 手机 MDT App | `phone/server/apps/police_mdt.lua:30-78`；`phone/server/phone_apps.lua:54-140`；`web/src/apps/DynamicApp.svelte` | 半成品 | 只有 `officers` 查询 + `alert` 动作；UI 是通用 key/value 列表；alert 用裸 `MySQL.Async.insert` 绕过 `PhoneNotify`（不清 `phoneDataCache`） | 加 `cases/case/wanted/citations/dispatch` 查询与 `report/citation/wanted` 动作；改用 `PhoneNotify` |
| F3 操作审计 | `custom-logs/server/logs.lua:92-146` | 半成品 | 只写本地文件 + Discord webhook，**不落库**；`LogGeneric/LogSecurity` 在 policejob/justice 有零散调用 | 新增 `police_audit` 或复用 `agent_effects` 风格落库，MDT 可查 |
| F4 Agent 调度员/记录员 | `custom-director/server/policy.lua:29-140`（18 动作）；`live_api.lua:4-10`；`main.lua:469-493,829-857` | 半成品 | 能 `get_live_players?job=police` 读在勤警员、`send_notify` 单发、`send_announce` 全服；但 **notify 只走 QBCore 角标，不进手机/MDT，也不落调度记录**；`set_job_duty` 是 L2 需审批 | 加一条 `dispatch_call` 动作（L2，落 `police_dispatch_calls` + `PhoneNotify` 给在勤警员），并让 live 事件包含 `jail/arrest/wanted` |
| F5 警察剧情线 | `custom-quest/config/quests/quest_police_ch1..ch4*.lua`；`server/quest_registry.lua:250-262`；`story-engine` 决策 | 可用 | 6 章（ch1/ch2/ch3 + ch4 三分支），3 个决策点；只依赖 `reach/interact/decision`，不依赖 MDT | 后续把"提交证据给 IA"接到案件系统 |

### G. 跨资源冲突（显式列出，6 行同样计入最终冲突数）

| # | 冲突 | 位置 | 证据 | 建议 |
|---|---|---|---|---|
| G1 | 两套监狱实现 | `justice/client/main.lua:42-75` vs `qb-prison/client/main.lua:174-270` | justice 自己传送、无 `injail`、无资源白名单；qb-prison 有劳动/换装/背包/职业 | 只保留 qb-prison 为"关押执行器"，justice 调它 |
| G2 | 三套上下班入口 | `policejob/client/job.lua:462-466,767-800`；`custom-main/server/dispatch.lua:216-247`（`/duty`）；`custom-director` `set_job_duty` | 三者都改 `job.onduty`，但审计/通知/防逃课规则只存在于 custom-main | 统一到一个 `PoliceDuty.Set(src, bool, reason)`，其余入口转调 |
| G3 | 警察身份判定分裂 | 见问题 3 | `job.type=='leo'` 与 `job.name=='police'` 混用；把 police 改名或加 BCSO 会静默失效 | 抽 `PoliceAuth.IsOfficer/IsOnDuty`（type 优先、name 兜底） |
| G4 | 文档/配置漂移 + BOLO 表结构双版本 | `configs/modules/police.cfg:4` vs `docs/01_resource_inventory.md:124`；`tcity-dashboard/sql/plate_flags.sql`（`reason`）vs `tests/fixtures/tcity_schema.sql:447`（`flag_reason`） | 资源 SQL 用 `reason`、dashboard 代码读写 `reason`，但 CI fixture 是 `flag_reason` 且**没有任何 migration 创建该表** | 写一个幂等 migration 定版 `plate_flags`，同步 fixture；改文档状态 |
| G5 | 两个 `RegisterDashboardApp` 导出 | `custom-vehicles/server/dashboard_api.lua:24-50`；`tcity-dashboard/server/compat.lua:14-44` | 两个资源都 `exports('RegisterDashboardApp', ...)` 并各自维护注册表；后启动者覆盖 export，先注册的 app 对方看不到 | 只保留 tcity-dashboard 的 export，custom-vehicles 转发 |
| G6 | 热线上"警察"与实际职业 | `phone/web/src/apps/Hotlines.svelte:7-8`；`phone/server/main.lua:919` | 911 映射 `police` 可用；`911-SURR` 映射 `surrender`，`qb-core/shared/jobs.lua` 无此职业 | 删 `surrender` 或实现"自首"作业 |

---

## 3. 职责重叠图

### 3.1 谁在管什么（现状）

```
                    ┌──────────────────────────────────────────────┐
                    │ custom-career                                │
                    │ 组织/等级镜像 + department/district/certs      │
                    │ 权威仍在 qb-core job（job.type / job.grade）   │
                    └───────────────┬──────────────────────────────┘
                                    │ GetPlayerIdentity / SetPlayerDepartment
        ┌───────────────────────────┼───────────────────────────┬────────────────────────┐
        │                           │                           │                        │
┌───────▼─────────┐      ┌──────────▼──────────┐     ┌──────────▼─────────┐   ┌──────────▼─────────┐
│ qb-policejob    │      │ custom-justice      │     │ custom-phone MDT   │   │ tcity-dashboard    │
│ 现场处置/罚单    │      │ 案件(内存)/审判/量刑 │     │ 名册 + 广播         │   │ 车载 ANPR/追踪/     │
│ 证据(内存)/车库  │      │ 与 qb-prison 双轨    │     │ DynamicApp 通用壳   │   │ CCTV/查人查车/BOLO  │
│ 扣押/执照/执勤   │      │ 无 DB               │     │ 只读，无案件        │   │ SQL plate_flags    │
└───┬─────────┬───┘      └──────────┬──────────┘     └──────────┬─────────┘   └──────────┬─────────┘
    │         │                     │                           │                        │
    │         │       ✗ 零调用       │                           │   ✗ 无数据/无案件        │
    │         └────────────────────►│                           │                        │
    │                               │                           │                        │
┌───▼─────────────┐      ┌──────────▼──────────┐     ┌──────────▼─────────┐   ┌──────────▼─────────┐
│ qb-prison       │      │ custom-main         │     │ custom-director    │   │ custom-quest       │
│ injail/劳动/释放 │      │ 通缉/警星/雷达 blip  │     │ 18 动作 + live API │   │ 6 章警察剧情       │
│ 唯一实际关押     │      │ /duty /clearwanted  │     │ 可读在勤名册        │   │ 3 个决策点         │
└─────────────────┘      └─────────────────────┘     └────────────────────┘   └────────────────────┘
```

### 3.2 重叠关系表

| 职责 | 主实现 | 也在做的人 | 结果 |
|---|---|---|---|
| 是否在勤 | qb-core `job.onduty` | policejob 值班点、custom-main `/duty`、director `set_job_duty` | 三入口，规则不一致（G2） |
| 关押 | qb-prison | custom-justice 自己传送 | 两套，justice 那套不锁人（G1） |
| 案件/量刑 | custom-justice（内存） | 无（policejob 的 `/jail` 直接给分钟数） | 断链（E1/E3） |
| 证据 | qb-policejob（内存物品） | 无 | 无 case 关联（B4） |
| BOLO/车牌 | tcity-dashboard（SQL） | qb-policejob（内存） | 两套（D1/G4） |
| 通缉 | custom-main（metadata+内存） | custom-justice 的 `cases`（未联动） | 概念重叠但数据不通 |
| 警情广播 | qb-policejob 事件 | custom-phone 兼容层、custom-main 通缉 | 三条通知通道，手机只持久化其中一条 |
| 市民/车辆查询 | tcity-dashboard | 无（MDT 未做） | 直接复用，别重写 |
| 警车功能入口 | tcity-dashboard | custom-vehicles `RegisterDashboardApp` 双导出 | 扩展点重复（G5） |

---

## 4. 可复用资产清单

### 4.1 数据表（现成，可直接读/写）

| 表 | 位置 | 可复用点 |
|---|---|---|
| `players` | `tests/fixtures/tcity_schema.sql:623` | `citizenid/charinfo/job/gang/metadata` + `rank_tier/department/district/certs`；`metadata` 内含 `wanted/injail/criminalrecord/ishandcuffed/tracker/callsign/fingerprint/jailitems/licences` |
| `player_vehicles` | `:578` | `state`（0 正常 / 2 扣押）、`depotprice`、`body/engine/fuel`、`plate/vehicle/garage` |
| `plate_flags` | `:447` + `tcity-dashboard/sql/plate_flags.sql` | 已有 BOLO 持久化；注意列名两版（`flag_reason` vs `reason`） |
| `phone_notifications` | `:401` | `citizenid/title/content/is_read/timestamp`；手机通知中心直接展示，适合"调度/案件提醒" |
| `phone_calls` | `:299` | `caller/receiver/duration/status/timestamp`；可做 911 通话记录 |
| `phone_messages` | `:383` | 可发"系统短信"（`exports['custom-phone']:SendSystemMessage`） |
| `phone_invoices` | `:350` | 旧账单表，custom-phone 无 UI；仅作迁移期兼容 |
| `player_choices` | `:461` | 剧情决策（`decision_id/chosen_option/arc_id/chapter`）；可复用于"认罪协商/保释"选择 |
| `player_quests` / `quest_cooldowns` | `:560/:669` | 剧情进度与冷却，警察剧情已在用 |
| `agent_actions` / `agent_denials` / `agent_effects` | `migrations/v2.3*.sql`、`v2.5`、`v2.6` | 审批/拒绝/效果审计范式；可复用为"调度动作审计" |
| `phone_gallery` | `:341` | 已存在但无照相 App；未来证据照片可复用 |

### 4.2 事件 / 回调（稳定契约，别改名）

- 警情与执勤：`police:server:policeAlert`、`police:server:autoAlert`、`police:client:policeAlert`、`police:server:UpdateBlips`、`police:client:UpdateBlips`、`police:server:UpdateCurrentCops`、`qb-policejob:ToggleDuty`。
- 手机兼容层：`qb-phone:client:addPoliceAlert`（custom-phone `client/main.lua:773` 已实现，负数 id、LEO+onduty 过滤）。
- 载具：`police:server:Impound`、`police:server:TakeOutImpound`、`police:GetImpoundedVehicles`、`police:server:FlaggedPlateTriggered`、`police:server:plateFlagged`、`heli:server:spotlight`。
- 监狱：`prison:client:Enter`、`prison:client:UnjailPerson`、`prison:server:SetJailStatus`、`prison:server:SaveJailItems`、`prison:server:GiveJailItems`、`police:client:SendToJail`。
- 通缉：`custom-main:server:policeHandoverAlert`、`custom-main:client:updateSuspectBlip`、`custom-main:client:clearSuspectBlip`、`custom-main:client:clearLocalWanted`。
- 回调：`police:GetDutyPlayers`、`police:GetCops`、`police:server:IsPoliceForcePresent`、`police:GetPlayerStatus`、`police:GetImpoundedVehicles`、`police:server:IsPlateFlagged`。

### 4.3 导出 / 服务

| 导出/服务 | 位置 | 用途 |
|---|---|---|
| `custom-career:GetPlayerIdentity` | `server/main.lua:157` | 统一身份（job/org/tier/department/district/certs），MDT 权限判断首选 |
| `custom-career:PlayerMatchesTags` | `:218` | `{role='police', department='CID', tier='leader'}` 标签过滤 |
| `custom-career:SetPlayerDepartment/SetPlayerDistrict` | `:325,336` | 已接 `/setdept`、`/setdistrict` |
| `custom-certificates:GrantLicense/RevokeLicense/SuspendLicense/ReinstateLicense` | 由 policejob 命令调用 | 执照全生命周期 |
| `custom-documents:server:verifyPlayer` | policejob 回调调用 | 证照/身份查验 |
| `custom-vehicles:GiveKeys/RemoveKeys/HasKeys/GiveTempKeys` | `custom-vehicles/server/key_manager.lua` | 警车钥匙/共享钥匙 |
| `custom-vehicles:RegisterDashboardApp` | `server/dashboard_api.lua:24`（另有重复 export，见 G5） | 车机第三方 App（`{id,label,icon,job,nui_event}`） |
| Bus `police.*` | `tcity-dashboard/server/police_api.lua:277` | `FlagPlate/UnflagPlate/IsFlagged/GetInfo`，最适合给 MDT/命令复用 |
| Bus `service_vehicles_*` | custom-vehicles | 车辆状态/钥匙查询 |
| Bus `justice`（9 方法） | `justice/server/main.lua:100-112` | 案件/囚犯服务；**但无持久化，先修再依赖** |
| `custom-phone:SendSystemMessage` / `StartSystemCall` | `phone/server/main.lua:639,1152` | 系统短信 / 调度来电（含 TTS 字幕） |
| `PhoneNotify`（全局函数，非 export） | `phone/server/main.lua:259` | 服务端通知落库+单播；建议加 export 包装供 police/justice 调用 |
| `custom-logs:LogGeneric/LogSecurity` | `custom-logs/server/logs.lua:112-146` | 现有审计出口（文件+Discord），非 DB |

### 4.4 UI 资产

| 资产 | 位置 | 复用方式 |
|---|---|---|
| 手机 App 注册表 + 通用壳 | `phone/server/phone_apps.lua`、`web/src/apps/DynamicApp.svelte`、`web/src/stores/apps.ts` | 新 MDT 只需在 `phone_apps.Register` 加 queries/actions；UI 可先沿用 key/value 列表 |
| 手机通知中心 / 通话 / 短信 | `web/src/apps/{Notifications,PhoneCall,Messages}.svelte` | 调度提醒/回拨/案件短信直接复用 |
| 手机 Hotlines | `web/src/apps/Hotlines.svelte` | 911 入口；需把 mock 换成真实通话 |
| 车载警察控制台 | `tcity-dashboard/nui/src/components/tabs/PoliceConsole.vue`（318 行） | ANPR/警笛/追踪器/查人查车 UI；可嵌"案件快查" |
| 车载 App 手势壳 | `tcity-dashboard/nui/src/components/{DashboardShell,TabBar}.vue` | 职业 tab 已按 `job` 显示（`TabBar.vue:12`） |
| 手机 Boss/Leader App | `web/src/apps/leader/{SheriffApp,MayorApp,GangBossApp}.svelte` | `SheriffApp` 已有"巡逻指令广播"表单，可升级为调度台 |
| 警察剧情 UI/流程 | `custom-quest` + `story-engine` | 章节/决策已经可跑，可直接挂案件结果 |

---

## 5. 需要新增的数据表与服务端 API 草案（只列字段与用途）

> 原则：所有写路径服务端权威；金额/刑期/坐标服务端复算；表名统一 `police_` 前缀；迁移必须幂等并同步 `tests/fixtures/tcity_schema.sql`。

### 5.1 表

1. **`police_cases`**（案件主表，替代 `activeCases` 内存）
   - `id`、`case_no`（对外编号，唯一）、`status`（open/trial/sentenced/closed/void）
   - `suspect_citizenid`、`suspect_name`（快照）、`opened_by_citizenid`、`opened_by_name`
   - `charges`（JSON：罪名 id 列表 + 快照 baseMinutes/fine）
   - `sentence_minutes`、`fine_amount`、`verdict_by_citizenid`、`verdict_at`
   - `created_at`、`updated_at`、`closed_at`
   - 用途：MDT 案件列表/详情、法庭、量刑、案底查询的唯一事实源。

2. **`police_case_evidence`**（证据，替代内存 `BloodDrops/FingerDrops/Casings`）
   - `id`、`case_id`、`kind`（blood/fingerprint/casing/photo/document/other）
   - `ref`（DNA 哈希/指纹 id/弹壳序列号/物品 uid）、`payload`（JSON：血型、武器、坐标）
   - `collected_by_citizenid`、`collected_at`、`coords_x/y/z`、`chain_note`
   - 用途：证据链与案件关联；物品只是"实体副本"，DB 才是权威。

3. **`police_citations`**（罚单，替代 `phone_invoices` 兜底）
   - `id`、`citation_no`、`case_id`（可空）、`citizenid`、`officer_citizenid`
   - `amount`、`reason`、`status`（unpaid/paid/void）、`issued_at`、`due_at`、`paid_at`、`payment_ref`
   - 用途：未缴罚单、手机缴费、案底统计、`/fine` 重写。

4. **`police_warrants`**（通缉令/搜查令）
   - `id`、`warrant_no`、`type`（arrest/search）、`target_citizenid`、`case_id`
   - `reason`、`issued_by_citizenid`、`approved_by_citizenid`、`issued_at`、`expires_at`
   - `status`（active/served/revoked）、`served_at`、`served_by_citizenid`
   - 用途：把 `metadata.wanted` 降级为缓存；支持审批与到期。

5. **`police_reports`**（报告/笔录，与案件多对一）
   - `id`、`case_id`、`author_citizenid`、`author_name`、`kind`（arrest/incident/supplement/IA）
   - `body`（限长文本）、`visibility`（unit/command/court）、`created_at`
   - 用途：MDT 记录、法庭证据、Agent 总结输入。

6. **`police_dispatch_calls`**（出警/调度记录）
   - `id`、`call_no`、`source`（911/system/player/agent）、`caller_citizenid`（可空）
   - `kind`、`priority`、`description`、`coords_x/y/z`、`status`（pending/assigned/onscene/closed）
   - `assigned_to`（JSON：citizenid 列表）、`created_at`、`assigned_at`、`closed_at`、`closed_by`
   - 用途：911 落单、MDT 调度列表、Agent "调度员"写路径。

7. **`police_duty_log`**（执勤审计，统一三入口）
   - `id`、`citizenid`、`onduty`（bool）、`reason`（duty_zone/command/agent/auto）、`job_grade`、`department`、`district`、`at`
   - 用途：出勤统计、防刷、Agent 只读视图。

8. **`police_impound_log`**（扣押审计，当前完全缺失）
   - `id`、`plate`、`owner_citizenid`、`officer_citizenid`、`full`（bool）、`price`、`reason`、`created_at`、`released_at`、`released_by`
   - 用途：扣押争议回溯、MDT 车辆历史。

9. **`police_prison_sentences`**（刑期，替代 justice 内存 `inmates`）
   - `id`、`case_id`、`citizenid`、`minutes`、`started_at`、`ends_at`、`reductions`（JSON）、`released_at`、`release_reason`、`jailed_by_citizenid`
   - 用途：跨重启刑期、减刑/探视、与 qb-prison `injail` metadata 双向校验。

### 5.2 服务端 API（统一放在一个警察域资源，建议 `custom-justice` 或新建 `custom-police`）

> 所有 API 入参都接受 `actorSrc`，内部统一做 `PoliceAuth.IsOnDuty(actorSrc, {minGrade, department})`；返回 `ok, resultOrErrorCode`。

- `PoliceAuth.IsOfficer(src)` / `IsOnDuty(src, opts)`：唯一身份判定（`job.type=='leo'` 或 `job.name=='police'` + `onduty`），读 custom-career 拿 department/district。
- `OpenCase(actorSrc, suspectSrc, charges) -> caseId`：校验嫌疑人在线/距离/罪名白名单；写 `police_cases`；发律师/警员通知。
- `AddEvidence(actorSrc, caseId, kind, ref, coords)` / `AddReport(actorSrc, caseId, kind, body)`。
- `SetVerdict(actorSrc, caseId, {minutes, fine, reductions})`：仅 judge/grade≥3；写库，状态 `sentenced`。
- `Sentence(actorSrc, caseId)`：服务端权威 → 写 `police_prison_sentences` → 调 qb-prison `prison:client:Enter`（**必须先把 custom-justice 加进 `qb-prison/client/main.lua:174-179` 的资源白名单**，或由 qb-prison 提供 server 端入口）。**不再由嫌疑人客户端触发。**
- `Release(citizenid, reason, actorSrc)`：清 `injail`、还包（复用 qb-prison 的 GiveJailItems 语义）。
- `IssueWarrant(actorSrc, targetCitizenid, type, reason, caseId)` / `ApproveWarrant(adminSrc, warrantId)` / `ServeWarrant(actorSrc, warrantId)` / `RevokeWarrant`。
- `CreateCitation(actorSrc, citizenid, amount, reason, caseId?)` / `PayCitation(citizenid, citationId)` / `VoidCitation(actorSrc, citationId)`。
- `CreateDispatchCall(source, payload)` / `AssignCall(actorSrc, callId)` / `CloseCall(actorSrc, callId, resolution)`。
- `GetCase(caseId)` / `ListCases(filter, cursor, limit)` / `ListCitations(citizenid, status)` / `ListWarrants(status)` / `ListDispatch(status)`。

### 5.3 手机 MDT（在现有 PhoneApps 上扩展，不新建通道）

- 查询：
  - `police_mdt:cases`（游标分页，`status/limit/cursor`）
  - `police_mdt:case`（`case_id`，含 evidence/report 摘要）
  - `police_mdt:wanted`（active warrants + 在线通缉）
  - `police_mdt:citations`（`status=unpaid`）
  - `police_mdt:dispatch`（pending/assigned）
- 动作：
  - `police_mdt:report`（`case_id, kind, body`）
  - `police_mdt:citation.issue`（`citizenid, amount, reason`）
  - `police_mdt:wanted.issue`（`citizenid, type, reason`）
  - `police_mdt:dispatch.assign` / `dispatch.close`
- 权限：`audience = { jobs = {'police'}, onduty = true }` 已由 registry 服务端强制（`phone_apps.lua:39-52,103-110`）；**建议扩展 `audience.min_grade` 与 `audience.departments`**，否则 CID/巡逻无法区分。
- 通知：服务端统一走 `PhoneNotify`（落 `phone_notifications` + 单播）；不要再用 `MySQL.Async.insert` 裸写（现 `police_mdt.lua:61` 的问题）。
- UI：先用 `DynamicApp` 出最小可用版本（案件列表 + 详情 + 开罚单/写报告），再决定是否做独立 Svelte 页。

---

## 6. 迁移风险（不能动 / 要小心的旧契约）

### 6.1 不能改名/改签名的事件

| 事件 | 谁在用 | 风险 |
|---|---|---|
| `police:server:policeAlert` | qb-drugs、qb-storerobbery、qb-houserobbery、custom-vehicles、qb-policejob 自身（officer down） | 改名会静默丢警情 |
| `police:server:autoAlert` | custom-vehicles 热线/撬锁（`server/main.lua:202,210,306`） | 同上；加固鉴权时不能直接删事件 |
| `qb-phone:client:addPoliceAlert` | custom-phone 客户端、stolen_radar、prisonbreak | 是跨资源广播，非 qb-phone 私有 |
| `police:server:UpdateBlips` / `police:client:UpdateBlips` / `police:server:UpdateCurrentCops` | policejob 客户端、phone 警情门控 | 改名会导致地图 blip/警力统计停止 |
| `qb-policejob:ToggleDuty` + `QBCore:ToggleDuty` | 值班点、`/duty` | 三入口统一时保留事件名，内部转调 |
| `police:client:SendToJail` / `prison:client:Enter` / `prison:client:UnjailPerson` | policejob、qb-ambulancejob、qb-prison | `prison:client:Enter` 有资源白名单（`qb-prison/client/main.lua:174-179`），加新调用方必须同时改白名单 |
| `prison:server:SetJailStatus` / `SaveJailItems` / `GiveJailItems` | qb-prison 客户端 + policejob | 改语义会破坏出狱还包/职业恢复 |
| `police:server:Impound` / `TakeOutImpound` / `police:GetImpoundedVehicles` | qb-garages（`state=2`）、policejob 菜单 | `player_vehicles.state` 语义 0/2 不能改 |
| `police:server:FlaggedPlateTriggered` / `police:server:plateFlagged` | tcity-dashboard 雷达/桥接 | 统一 BOLO 时至少保留一个兼容转发 |
| `custom-main:server:policeHandoverAlert` + `custom-main:client:*SuspectBlip` | custom-main 客户端、通缉系统 | 重做通缉时保留事件名做适配层 |
| `heli:server:spotlight` | policejob heli | 低风险，但别顺手删 |

### 6.2 不能改名的命令/回调

- 命令：`/cuff /escort /jail /unjail /fine /seizecash /takedna /checkid /checklicense /impound /depot /flagplate /unflagplate /plateinfo /911p /cam /pobject /spikestrip /arrest /cases /inmates /clearwanted /clearwarrant /duty /mycareer`（玩家习惯、文档、快捷菜单）。
- 回调：`police:GetDutyPlayers`、`police:GetCops`、`police:server:IsPoliceForcePresent`、`police:GetPlayerStatus`、`police:GetImpoundedVehicles`、`police:server:IsPlateFlagged`。
- `/impoundplayer`、`/impoundnear` 的 `permission='admin'`（`server/vehicle.lua:180,191`）：如果改成 `'user'` 属于**放开权限**，必须同时补足服务端 LEO 校验，否则等于给所有玩家发扣押权。

### 6.3 不能动的数据/契约

- `players.metadata` 键：`injail`、`wanted`、`criminalrecord`、`ishandcuffed`、`tracker`、`callsign`、`fingerprint`、`jailitems`、`licences`——被 policejob/qb-prison/custom-main/certificates 共同消费。
- `player_vehicles.state`（0 正常 / 2 扣押）与 `depotprice/body/engine/fuel`。
- `plate_flags`：先确认线上列名是 `reason` 还是 `flag_reason`，写幂等 migration 统一后再改代码；否则 dashboard 的 INSERT 会直接报未知列。
- 手机 App 契约（被 `tests/unit/layer3_business/test_phone_apps.py` 锁定）：`PhoneApps.Register/ForPlayer/Query/Action`、`phone:server:appQuery/appAction`、`police_mdt` 的 `officers`/`alert`、`DynamicApp`/`dyn:` 前缀。扩展可以，**不要改已有名字**。
- `agent_tools.json` 是唯一事实源：新增 `dispatch_call` 等动作必须 `python3 tools/agent_tools.py --write && --check`，并同步 policy × tools × tests。
- `custom-logs` 审计调用是 fire-and-forget；不要指望它保证顺序或落库。

---

## 7. 建议的修复顺序（不作为本次改动）

1. **（P0）修判刑链路**：`justice` 定义 `Inmates`（或直接删内存表改用 DB），把 `imprison` 改由法官/警察服务端触发，写入 `police_prison_sentences` 后调用 qb-prison；加 `startTrial` 的 judge 入口。
2. **（P0）补 5 类关键鉴权**：`RobPlayer`、`autoAlert`、`SetTracker/SendTrackerLocation`、`showFingerprint`、`qb-policejob:server:evidence` 的仓库名。
3. **（P1）统一 `PoliceAuth`**：先替换核心 7 处 `job.name=='police'`（`vehicle.lua` ×1、justice ×2、custom-main ×3、`police_mdt` ×1；phone 的 faction/hotline 与 qb-prison 另计），dashboard 已有兼容写法，再谈 BCSO。
4. **（P1）BOLO 收敛到 SQL 一套**，写 `plate_flags` 幂等 migration + 同步 fixture。
5. **（P2）MDT MVP**：`police_cases` + `police_reports` + `police_citations` 三张表，先做"案件列表/详情/开罚单"。
6. **（P2）手机 911 真实通话**：`StartSystemCall` + `phone_calls`，去掉 IVR mock。
7. **（P3）Agent 调度员**：新增 `dispatch_call` 动作（L2，需审批）→ 写 `police_dispatch_calls` + `PhoneNotify`。

---

## 8. 最终计数

- **已可用能力：14**（A1、A2、A4、A5、B1、B2、B6、C1、C2、C3、C4、D3、E4、F5）
- **半成品：11**（A3、B3、B4、D2、D4、E1、E2、E5、F2、F3、F4）
- **缺失：7**（B5、B7、B8、D5、D6、E6、F1）
- **冲突：8**（矩阵内 D1、E3 + 跨资源 G1–G6；其中 G1 与 E3、G4 与 D1 部分同源，按独立议题去重为 7。A–F 34 行 + G 6 行 = 40 行，14+11+7+8=40）
- **最该先修的一个**：**E3 判刑→入狱链路**——`JusticeService.Inmates` 为 nil + 由嫌疑人客户端触发被服务端拒绝 + 与 qb-prison 双轨；修好这一条，法庭/减刑/探视/MDT 案件才有落点。
- **MDT 最小可行功能建议**：在现有 `PhoneApps` 上只加 **`cases`（列表/详情）+ `wanted`（通缉）+ `citations`（罚单）** 三个查询和 **`report` / `citation.issue`** 两个动作，落 `police_cases`、`police_reports`、`police_citations` 三张表；UI 先复用 `DynamicApp`，权限沿用 `{jobs={'police'}, onduty=true}`，不碰证据图片与法庭流程。
