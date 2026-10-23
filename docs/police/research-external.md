# 外部警察 / 调度 / MDT / 监狱 / 法庭模组调研

> 调研对象：FiveM（QBCore / ESX / QBox / ox）主流警察业务模组，含本地基线 `qb-policejob`。
> 目的：为 T-City（48 人 QBCore Lite + 自研 `custom-phone` 职业 App 注册表 + `custom-director`/`custom-career`/`custom-justice`）提炼可落地的功能与架构。
> 调研日期：2026-10-23。仓库数据（星数、最后 push）为该日快照。
> 本文只引用公开可访问内容；付费 escrow 脚本**看不到源码**，相关结论仅基于官方文档，已逐条标注证据等级。

## 证据等级（本文所有结论的可信度）

| 等级 | 含义 | 涉及对象 |
|---|---|---|
| **S** 源码级 | 读过实际 Lua/SQL/前端源码 | 本地 `qb-policejob`、`ps-mdt`、`ps-dispatch`、`esx_policejob`、`bub-mdt`（README+package.json）、`fivenet`/`ox_mdt`/`snaily`/`fl-dispatch`/`ars`/`fenix`（README 级） |
| **D** 官方文档级 | 只读官方文档站，源码不可见 | `wasabi_police_v2` / `wasabi_mdt` / `wasabi_evidence`、`rcore_police` / `rcore_dispatch` / `rcore_prison` / `rcore_mdt`、`codesign` 系 |
| **R** README/描述级 | 只有仓库 README 与元数据 | 其余小仓库 |

**找不到的对象（已换源/注明）**

- `Project-Sloth/ps-police`：**不存在**（404）。Project Sloth 的警察栈是 `ps-mdt` + `ps-dispatch` + `ps_lib`，没有独立 policejob。
- `wasabi-policejob` / `wasabi_mdt` 仓库：**无公开源码仓库**（付费 + escrow），只有 [docs.wasabiscripts.com](https://docs.wasabiscripts.com/)。
- `esx-framework/esx_policejob` 独立仓库：**404**，已并入 [`ESX-Legacy-Addons`](https://github.com/esx-framework/ESX-Legacy-Addons/tree/main/%5Besx_addons%5D/esx_policejob) monorepo；官方 `esx_mdt` **不存在**，ESX 侧 MDT 全是第三方（LTX-MDT、duckymdt 等）。
- `cd_police` / `codesign` 的 police、mdt：**不存在**。Codesign 实际只有 `cd_dispatch`、`cd_dispatch3d`、`cd_radar`（ALPR）、`cd_cctv`、`cd_vehiclecontrol`、`cd_identity` + `cd_bridge`。

---

## 0. 一页结论

### 0.1 最值得抄的 5 个机制

1. **服务端权威的「岗位 × 等级 → 权限集」**（ps-mdt `mdt_permission_roles` + `PermissionDefaults`、wasabi 每部门每 grade 配置）。
   NUI 只负责隐藏入口；每个 query/action 在服务端按 `job_name + grade + onduty + department` 再判一次。这是所有成熟 MDT 的共同底线。
2. **调度「过滤广播 + 优先级分层 + 坐标模糊化」**（ps-dispatch）。
   只推给 `job ∈ call.jobs` 且在勤的人；critical 单独一档且只能被"授予"不能被"累积"；近似坐标把真值留在服务端，客户端只拿到偏移后的点和搜索半径。48 人服务器上这是带宽与信息公平性的关键。
3. **报告 / 案件 / 证据 三层数据模型**（ps-mdt、rcore_mdt）。
   `report` 是一次事实陈述（谁、在哪、什么罪），`case` 是调查容器（多份报告、多个警员、优先级），`evidence` 有独立生命周期与**保管链**（custody）。三者用外键串起来，通缉/起诉/判决都从这三层派生。
4. **实时状态走事件 + 内存镜像，持久数据才落库**（ps-mdt `officer_status`：内存 map 为读路径、DB 为恢复路径、变更广播单播给同域警员）。
   MDT 打开时不做轮询；单位状态、值班表、通话中的单位都是推送。
5. **框架数据只做「自动同步 + MDT 覆盖层」**（wasabi_mdt AutoSync：公民/车辆直接从框架表读，MDT 只存备注、标记、照片、指纹）。
   我们已有 `players` / `player_vehicles` / `plate_flags`，绝不能再复制一套 `mdt_citizens`/`mdt_vehicles`。

### 0.2 对 T-City 的一句话结论

**不要引入整套外部 MDT，也不要往 `qb-policejob` 里继续堆功能。**
新建一个薄的 `custom-police` 服务层（调度 + 案件/通缉 + 审计，9–16 张表），把 UI 作为 `custom-phone` 的注册 App（`police_mdt`）交付；`qb-policejob` 只保留客户端交互（手铐、车库、证据、摄像头）；AI 调度通过 `custom-director` 新增 2–3 个 L1/L2 动作接入，而不是绕过策略层。

---

## 1. 本地基线：`qb-policejob` 现状

- 位置：`T-CityLite.base/resources/[qb]/qb-policejob`，`version 1.3.5`，**GPL-3.0**。
- 规模：约 6.4k 行（含 18 个 locale、`html/` 指纹 NUI）；server 1,453 行，client 3,049 行。
- 依赖：`qb-core`、`qb-inventory`、`custom-career`、`custom-certificates`、`custom-documents`（已做本地化改造）。

### 1.1 完整（能跑、有服务端校验）

| 能力 | 实现要点 |
|---|---|
| 值班开关 / 值班 blip | `QBCore:ToggleDuty`；`UpdateBlips()` **每 5s 对 `-1` 全服广播**所有 LEO/EMS 位置 |
| 车库 / 扣押 / 取回 | `player_vehicles.state`（0 在库 / 2 扣押）、`depotprice`、`body/engine/fuel` 回写 |
| 直升机 | 召唤 + 机载聚光灯 + heli cam（`client/heli.lua`） |
| 储物柜 / 证物柜 / 垃圾桶 | `policestash_<cid>`、`policetrash`、`currentEvidence` 走 `qb-inventory` 虚拟容器 |
| 指纹 UI | `html/`（`vue.min.js` + 手写 `script.js`）指纹扫描；`police:server:showFingerprint` |
| 证据系统 | 弹壳 / 血迹 / 指纹 / GSR / DNA / `filled_evidence_bag`；**状态全在服务端内存** |
| 监控摄像头 | `Config.SecurityCameras` 34 个预置点 + 断电/联网切换 |
| 测速雷达 | 9 个固定点（`Config.Radars`），值班警察驾车驶过触发 `police:server:FlaggedPlateTriggered` |
| 被盗车雷达 | `client/stolen_radar.lua`：3s / 50m 扫 `GetGamePool('CVehicle')`，读 `Entity(v).state.isStolen` |
| 手铐 / 押送 / 塞车 / 拖出 | `interactions.lua`（含 softcuff、kidnap） |
| 搜查 / 扣押现金 / 吊销驾照 | 距离校验 2.5m；驾照走 `custom-certificates` |
| 罚单 | `/fine <id> <amount>`：先扣 bank，再扣 cash，扣不到就开 `phone_invoices` |
| 执照管理 | `grant/revoke/suspend/reinstate license`，全部委托 `custom-certificates` |
| 部门 / 辖区 | `/setdept`、`/setdistrict` → `custom-career:SetPlayerDepartment/District`（grade ≥ 3） |
| 查证件 | `/checkid`、`/checklicense` → `custom-documents:server:verifyPlayer`，3.5m 距离校验 |
| 路障 / 锥桶 / 钉刺带 | `client/objects.lua` + 服务端同步 |
| 脚环追踪 | `tracker` metadata + `ankletlocation` |
| 拖车 / 律师付费 | `/paytow`、`/paylawyer`（各 500） |

### 1.2 残缺 / 死代码（必须知道，否则会在错误前提上做设计）

| 问题 | 证据 | 影响 |
|---|---|---|
| **没有 MDT / CAD / 案件 / 报告 / 通缉 / 搜查令 / BOLO / 罚单目录** | 全目录 grep 只有 locale 文案，无任何实现 | 目前"警察业务"只到"抓人+关人"，没有文书与信息流 |
| **没有军械库（armory）** | `local inArmoury = false` 只声明、无任何使用；没有 armory zone；`Config.ArmoryWhitelist`、`Config.Departments[*].weapons` 全是死配置 | 部门（SWAT/CID/TRAFFIC）只存在于分配命令，拿不到对应装备 |
| **没有更衣室 / 制服** | 无 `cloakroom`/`Config.Uniforms`；上游 README 列有 clothing，本地版本已裁掉 | 上岗无换装流程 |
| **没有 boss menu / 车队管理** | 只有按 grade 的 `Config.AuthorizedVehicles` | 无法做车队调度、车辆分配、损耗管理 |
| **罚单无目录、无理由、无上限** | `/fine` 只收 `amount`；金额无 `math.min` 上限 | 可开出天价罚单；无证据链 |
| **罚款失败路径是死的** | 落到 `INSERT INTO phone_invoices ...` 后触发 `qb-phone:client:AcceptorDenyInvoice`；本仓 **没有 `qb-phone` 资源**，`custom-phone` 也不支持 invoice | 玩家余额不足时罚款静默丢失 |
| **报警通知有一半是死的** | 每个 alert 同时发 `qb-phone:client:addPoliceAlert`（资源不存在）与 `police:client:policeAlert`（有效） | 只剩 QBCore notify + 地图 blip，没有可回看的"警情列表" |
| **`police:server:autoAlert` 无任何鉴权** | 源码注释自认"无职业鉴权，任何资源可触发" | 任意资源/客户端可伪造警情刷屏 |
| **证据全内存 + 客户端上报** | `evidence:server:CreateBloodDrop(citizenid, bloodtype, coords)` 直接信客户端；服务端三张内存表 | 重启全丢、可伪造 DNA/指纹、无保管链 |
| **`police:server:showFingerprint` 无校验** | 不校验 job、不校验距离，任意 source 可触发任意两人互看指纹 | 低危但属于典型的"事件即权限" |
| **`police:server:JailPlayer` 无刑期上限** | `time` 直接写 `metadata.injail` | 客户端可传超大刑期 |
| **`/911p` 无冷却/限流** | 命令直接群发 | 可刷屏 |
| **监狱无案件/刑期记录** | `qb-prison` 只写 `metadata.injail` + `criminalrecord`（`hasRecord/date`） | 无罪名、无判决、无出狱审计；`custom-justice` 的案件在内存里 |

### 1.3 与外部成熟模组的差距（一句话版）

本地 = **"动作层"完整、"信息层"为零**。外部模组的价值 80% 在信息层（调度/案件/通缉/文书/审计），而这恰好是我们最缺、也最适合放进手机 App 的部分。

---

## 2. 模组对照表

> 图例：✅ 有 ／ 🟡 部分 ／ ❌ 无 ／ ❓ 文档未说明。
> "维护状态"看最后 push；星数为 2026-10-23 快照。

| 模组 | 核心循环 | MDT / 调度 | 数据模型 | 优点 | 坑 | 许可证 / 维护状态 |
|---|---|---|---|---|---|---|
| **qb-policejob 1.3.5**（本地） | 巡逻→拦截→逮捕→扣押→关押 | ❌ MDT；🟡 只有 `/911p` + blip | 无新表（复用 `player_vehicles`/`plate_flags`/`inventories`/`phone_invoices`） | 轻、动作全、已接 `custom-*` | 无信息层；armory/cloakroom 被裁；罚单/报警有死路径；证据内存 | GPL-3.0；上游活跃（2026-08），本地已分叉 |
| **ps-mdt v3.1.4** | 查询→报告→案件→证据→通缉→BOLO→罚单/扣押→法庭→FTO/IA | ✅ MDT（F11/`/mdt`）+ 内嵌 dispatch 页 + ps-dispatch 集成 | **63 张 `mdt_*` 表**（profiles/reports/cases/evidence/custody/warrants/bolos/impound/weapons/cameras/court/IA/FTO/SOP/audit…） | 数据模型最完整；62 权限键；审计；分页；Svelte 5 | 表/权限过度工程；多数 handler 只 `CheckAuth` 不 `CheckPermission`；依赖 ps_lib+ox_lib+Fivemanage | **CC BY-NC-SA 4.0**（禁商用+相同方式共享）；331★，活跃（2026-07） |
| **ps-dispatch** | 报警→板子→接单→到场→结案 | ✅ 10 码 + priority 0–3 + critical 档 + 单位/plate log | **无 SQL**，calls 全内存 | 过滤广播；坐标模糊；合并/热点；`SendTargetedAlert` | 重启丢 calls；10 码不唯一（10-11 同时是 speeding/shooting）；30+ 硬编码 alert | GPL-3.0；223★，活跃（2026-08） |
| **wasabi_police_v2 + wasabi_mdt** | 上岗→巡逻→拦截→证据→逮捕→罚单→监狱 | ✅ MDT（React NUI）+ 内建 dispatch/panic，可桥 cd/ps dispatch | 自有表（stations 面板建站、records、incidents、calls）；DDL 未公开 | AutoSync 覆盖层；Report Link Graph（服务端遍历上限）；按 grade 权限；分页；dispatch 可跨重启持久化 | 闭源 escrow 不可审计；依赖 FiveManage 图床 / Medal bodycam；功能面极宽 | 付费（escrow）；文档活跃（2026） |
| **rcore_police / rcore_dispatch / rcore_prison / rcore_mdt** | 值勤→拦截→搜查→逮捕→监狱；MDT 报告/案件/BOLO；监狱 breakout/solitary/dashboard | ✅ 4 个独立产品：police、dispatch（`/911` `/anon911` `/sos` + switchboard）、prison（MDW 面板）、mdt | **自动建表**（无 SQL 文件）；DDL 未公开 | 监狱 dashboard 可调刑期/事件日志；MDT 证据板（拖拽关系图）；单位+值班时长 | 自动建表=无迁移审计；minigame/动画耦合重；闭源 | 付费（escrow）；文档活跃（2026） |
| **codesign cd_dispatch / cd_dispatch3d / cd_radar / cd_cctv** | 报警→面板→单位调度；ALPR/BOLO；CCTV | ✅ dispatch + 3D dispatch + radar（ANPR/BOLO/测速） | 自有表（未公开） | `cd_bridge` 统一框架/账单/dispatch 适配层；产品化程度高 | 无 police/MDT 产品；3D 模型开销大；强绑 `cd_bridge` | 付费（escrow）；文档活跃（2026） |
| **bub-mdt** | 8 页：Dashboard/Profiles/Incidents/Reports/Vehicles/Dispatch/Roster/Charges | ✅ 内建 dispatch + `CustomAlert` | 随资源 SQL（incidents/reports/dispatch） | 页面分组接近 ox_mdt；TS + React + Mantine + react-query；GPL 可读 | README 自认"仍未经充分测试"；驾照积分自认坏 | GPL-3.0；139★，活跃（2026-08） |
| **ox_mdt** | Dashboard/Profiles/Reports/Dispatch/Charges/Roster | ✅ 内建 dispatch（无调度员时警员自管单位） | ox_core 表 + 自有 SQL | "无 dispatcher 时降级给警员自助"的设计；charges 目录 | **WIP**；只支持 ox_core；文档在 docs 分支需自建 | GPL-3.0；56★，2026-05 |
| **fivenet** | 外部 Web 平台：公民/车辆/文档/排班/日历/资质/Livemap/调度中心 | ✅ Dispatch Center（接单/拒单/自动派单）+ 游戏内平板 | 独立 DB（Go 服务，多表）+ FiveM 插件 DBSync | 派系自管角色 + 管理员上限；文档模板/评论/访问级别；Apache-2.0 | 需 Docker/K8s/NATS/Postgres，48 人过重；双写同步复杂；与手机割裂 | **Apache-2.0**；26★，活跃（2026-10） |
| **esx_policejob（ESX Legacy Addons）** | 上岗→军械库→车库→搜查→逮捕→罚款→监狱 | ❌ MDT；调度靠 `esx_phone` | 全部是框架表：`fine_types` + `jobs`/`job_grades` + `addon_account`/`addon_inventory`/`datastore`（无业务表） | 极简可读；`fine_types` 罚单目录；距离/值班校验；2026 仍在维护 | 无案件/报告；society 体系与 QBCore 不兼容；无分页 | GPL-3.0；活跃（2026-10） |
| **其他参考**：snaily-cadv4 / fl-dispatch / ars_policejob / fenix-police / K9 | 外部 CAD / 10 系统 / 轻量 policejob / AI 通缉警力 / 警犬 | snaily ✅ 外部 CAD；fl ✅ 10 系统 + 在勤列表 | 各异 | snaily（MIT）单位/呼叫建模；fl（MIT）10 码表；ars（Apache）0.0ms idle；fenix（GPL）玩家警察在线才启用 AI | K9 无维护良好的免费方案（2018/2022 停更）；fenix 与 RP 警察角色冲突 | 见括号；snaily 170★，fl 37★，ars 98★（2024-06 停更） |

**许可证结论（能不能抄代码）**

- 可安全复用代码：**Apache-2.0**（fivenet、ars）、**MIT**（snaily、fl-dispatch）——保留版权/NOTICE 即可。
- **GPL-3.0**（ps-dispatch、bub-mdt、ox_mdt、esx_policejob、本地 qb-policejob）：可以改，但衍生资源也必须 GPL；我们已经在此许可下，**不能把 GPL 代码搬进闭源资源**。
- **CC BY-NC-SA 4.0**（ps-mdt）：**禁商业用途** + 相同方式共享。T-City 若接受捐赠/商业化，**不能复制其代码**，只能学习数据模型与交互（思想不受版权保护，但表结构+代码表达受）。
- **付费 escrow**（wasabi、rcore、codesign）：源码加密，**不能读、不能改、不能搬**；只能学文档描述的产品行为。

> 因此本文的建议一律是「抄机制、不抄代码」；真要复用代码，只从 MIT/Apache 项目取。

---

## 3. 逐个模组：核心循环 / 架构 / 性能安全 / 3 借 3 不借

### 3.1 ps-mdt v3（最完整的开源 MDT，也是最大的反面教材）

- **核心循环**：查询公民/车辆 → 写报告（涉事人/罪名/证据）→ 归入案件 → 申请/签发通缉与 BOLO → 罚单/扣押 → 法庭日历 → FTO/IA/PPR/SOP。
- **调度与 MDT**：MDT 内嵌 dispatch 页，和 `ps-dispatch` 双向集成；62 个权限键覆盖 citizens/reports/cases/evidence/bolos/warrants/vehicles/weapons/charges/dispatch/cameras/bodycams/dashcams/patrols/bulletin/SOP/FTO/court/management。
- **架构（S）**：
  - 前端 **Svelte 5 + Vite**，产物 `web/dist`；`ui_page` 指向 `web/dist/index.html`。
  - 服务端 30+ 个 `server/backend/*.lua` 模块（共 37 个文件），`server/main.lua` 只有一行注释（入口极薄）。
  - `server/auth.lua`：`CheckAuth`（job type ∈ police/medical/doj）+ `CheckPermission`（DB `mdt_permission_roles(job, grade, permissions JSON)` → config 默认值 → boss 全权）。
  - 63 张表；重关系：`mdt_profiles`（citizenid 唯一）← `mdt_reports` → `mdt_reports_people/charges/evidence`；`mdt_cases` ← `mdt_case_reports`；`mdt_evidence_items` → `mdt_evidence_custody`；`mdt_warrants`/`mdt_bolos`；`mdt_court_*`；`mdt_audit_logs`。
  - 导出：`IsCidFelon`、`registerWeapon`、`GetCitizenPhoneNumber`；客户端 `OpenMDT/CloseMDT/openCivilianMDT/impoundNearbyVehicle`。
- **性能/安全（S）**：
  - ✅ `LIMIT ? OFFSET ?` 分页（cases/reports 等）、`Cache.get/set(ttl)` 进程内缓存、`mdt_officer_status` 内存 map 读路径。
  - ⚠️ **权限名不副实**：抽查 `cases.lua` 21 处 `CheckAuth` / 0 处 `CheckPermission`；`reports.lua` 13/0；`citizens.lua` 20/0；只有 `warrants`、`management` 出现 2 次权限校验。至少这 5 个模块的服务端没有细粒度权限校验——62 个权限键在服务端只覆盖了少数入口，其余靠 UI 路由。
  - ⚠️ 报告正文 `contentyjs` 存 **longblob**（富文本 JSON）+ `contentplaintext` 双写；图片走 FiveManage 外部图床（额外 key、额外费用、隐私边界）。
  - ⚠️ `BroadcastActiveWarrants()` 用 `-1` 全服广播再让客户端按 LEO 过滤——48 人可接受，但不是最优。
- **3 借**：
  1. 三层模型 `report / case / evidence(+custody)` 与 63 表里真正有用的那 1/4；
  2. `mdt_permission_roles(job, grade, permissions)` + `PermissionDefaults` 的"DB 可配 + 代码兜底"；
  3. 每个写操作进审计（谁、何时、对谁、什么动作）。
- **3 不借**：
  1. 63 张表 / 62 权限（48 人用不到 20%）；
  2. 权限只做在 UI 层；
  3. 富文本 blob + 外部图床 + 4 个重依赖（ps_lib/ox_lib/screenshot-basic/Fivemanage）。

**→ T-City 落点**：只取三层模型 + 权限表 + 审计，落成 `custom-police` 的 9 张 MVP 表；不引入 ps_lib/ox_lib/图床。

### 3.2 ps-dispatch（调度设计的最佳参考）

- **核心循环**：事件/玩家报警 → 生成 call（code、priority、coords、street、vehicle/person 字段）→ 过滤广播给对应 job 在勤者 → 警员 `E` 接单（attach）→ 到场/结案。
- **调度与 MDT**：`code` 是 10 码徽标（10-11 shooting、10-35 vehicle theft、10-60 vehicle shots、10-66 suspicious、10-80 explosion、10-90 robbery、10-99 officer down、10-32 backup…），`priority` 0 critical / 1 urgent / 2 routine / 3 low；critical 名单**只能被授予**，重复报警只能升级到 priority 1。
- **架构（S）**：
  - calls **纯内存**（`local calls = {}`），无 SQL；code 表在 `Config.Blips`（per-codeName：sprite/colour/radius/sound/offset）。
  - `FilteredBroadcast` 只在服务端挑人发；`Config.OnDutyOnly` 连事件都不发。
  - `callOffsets` 只存服务端；`publicCall()` 在广播/菜单/列表三处都剥掉真实 `coords`（偏移 alert 只给 `displayCoords` + `mapRadius`）。
  - `SendTargetedAlert` 导出 + 同名事件，但事件里 `if source > 0 then return end` **只允许服务端触发**。
  - `mayModifyCall` 校验调用者 job ∈ call.jobs，防止任意人清别人的单。
- **性能/安全（S）**：
  - ✅ `NotifyRateLimit` 限流、`MaxCallList=25`、`CallLifetime=3600`、`UnattendedAfter=120`、合并窗口/热点抑制。
  - ⚠️ 无 QBCore 时 `FilteredBroadcast=false` 回退成 `-1` 全服广播（我们不会遇到，但说明其默认假设）。
  - ⚠️ 重启丢所有活动 call；plate 检查日志只存客户端（隐私好，但换机即失）。
- **3 借**：
  1. 过滤广播 + 在勤过滤（48 人下每个警情只发 8 份而不是 48 份）；
  2. 坐标模糊：真值留服务端、客户端只有圆和偏移点、同一 call 偏移固定（防三角定位）；
  3. 合并/热点/优先级/critical 的"噪声治理"。
- **3 不借**：
  1. 10 码不成体系（10-11 同时用于 speeding 和 shooting；10-90 覆盖所有抢劫）——我们要自建一张**唯一映射表**；
  2. 无持久化（`police_calls` 应落库，至少保留 7 天供复盘）；
  3. 30+ 个硬编码 alert 函数——我们只保留 ~12 类，其余走 `CustomAlert` 载荷。

**→ T-City 落点**：调度 MVP 直接按此实现；推送从 `-1` 改为 `custom-phone` 在勤单播，`police_calls` 落库 7 天。

### 3.3 wasabi（police_v2 + mdt + evidence）

- **核心循环**：建站（`/stationpanel`，DB 持久化）→ 上岗 → 巡逻/拦截 → 证据（`wasabi_evidence`：血迹/弹壳/指纹/GSR + chain-of-custody）→ 罚单 → 逮捕 → 内置监狱（`/jailpanel`）→ MDT 文书/案件/通缉/BOLO → 部门管理。
- **调度与 MDT（D）**：MDT 自己就是 dispatch（内建 calls/priority/units/arrival/pin/persist），同时可镜像到 ps-dispatch / cd_dispatch，或反向 ingest 外部 call；有 panic 与枪声自动告警；CCTV 可放置/修复；bodycam 走 Medal 桌面端。
- **架构（D）**：
  - 付费 escrow；`bridge/**` 做框架/房屋/调度/通知适配，`config/{shared,client,server}` 分层；`departments/*.lua` 每部门 label/color/**每 grade 权限**。
  - **AutoSync**：公民/车辆/房产直接从框架表读，MDT 只存 overlays（notes/flags/photos/fingerprints）。
  - **Report Link Graph**：记录间关系图，带**服务端遍历上限**（防止一次查询炸库）。
  - 客户端/服务端 export + integration events + state bags + lifecycle events。
- **性能/安全（D）**：分页、dispatch 可跨重启持久化、graph 遍历限深；权限按 grade；但闭源不可审计，且外部依赖多（FiveManage 图床、Medal、object_gizmo、pma-voice）。
- **3 借**：
  1. AutoSync 覆盖层思路（我们直接 join `players`/`player_vehicles`，只新建 `police_flags`/`police_notes`）；
  2. 关系图 + 服务端遍历上限（证据↔报告↔人↔车），但用固定 2 跳 SQL 而不是通用图引擎；
  3. 建站/部门配置进 DB（多警局、多辖区）而不是改 config.lua。
- **3 不借**：
  1. 闭源 escrow（出问题只能等作者）；
  2. CCTV/bodycam/Medal/图床全都自己做（我们已有 `custom-phone` 相机规划，别重复造）；
  3. 功能宽度优先于深度（48 人用不到 bodycam 录制与 3D 模型）。

**→ T-City 落点**：AutoSync 落成「`players`/`player_vehicles` + `police_*` 覆盖层」；建站表放 P2，不碰 bodycam。

### 3.4 rcore（police / dispatch / prison / mdt）

- **核心循环**：值勤 → 上下文/径向菜单交互（cuff/tackle/zip tie/headbag/search）→ 车辆（塞车/拖出/扣押/解锁/钉刺带）→ 测速相机/雷达 → 罚单/表单 → 逮捕 → 监狱（prolog/canteen/solitary/prison break/MDW 面板）→ MDT 报告/案件/BOLO/证据板。
- **调度与 MDT（D）**：`/911` `/anon911` `/sos` + switchboard + `/panel` + `/config_switch`；priority low/medium/high；`cd_dispatch`/`qs-dispatch` 向后兼容；MDT 有 incidents/fines、profiles/vehicles、BOLOs、case files（主题/回复/提及/表情）、**evidence boards（拖拽关系板）**、messages、medical records、bulletins、units & duty（值班时长）、photos、audit logs。
- **架构（D）**：4 个独立付费资源；**首次启动自动建表**（无 SQL 文件）；大量 exports/events（`IsPlayerCuffed`、`JailPlayer`、`registerListener("onState"/"onGroups")`）；服务端/客户端 API 文档齐全。
- **性能/安全（D）**：权限与集成点文档化；但自动建表意味着升级路径不可审计（对我们是硬伤）；minigame/动画/道具系统耦合重。
- **3 借**：
  1. 监狱 dashboard：**刑期可调 + 事件日志 + 囚犯进度**（比 `/jail` 一条命令强太多）；
  2. 证据板（关系图）作为案件页的第二视图；
  3. 值班时长统计（`duty time`，可直接喂给 `custom-career` 的考勤/工资）。
- **3 不借**：
  1. 自动建表（我们必须 `migrations/v*.sql` 幂等迁移 + `tests/fixtures/tcity_schema.sql`）；
  2. 交互 minigame 堆叠（48 人 RP 服更需要稳定与速度）；
  3. 4 个资源互相依赖的采购式架构。

**→ T-City 落点**：监狱 dashboard 的「刑期可调 + 事件日志」并入 `custom-justice` + `police_cases`；值班时长（`police_shifts`）放 P2。

### 3.5 codesign（cd_dispatch / 3d / radar / cctv）

- **核心循环**：报警 → dispatch 面板（blip、panic、job call）→ 单位调度；`cd_radar` 做 ALPR/BOLO/测速；`cd_cctv` 做摄像头；`cd_dispatch3d` 用 3D 模型展示警情。
- **调度与 MDT（D）**：dispatch 有 dispatcher 角色、panic button、job call commands；3D dispatch 有自定义车/人模型、实时跟踪；radar 有 BOLO/车辆库查询/ANPR。
- **架构（D）**：所有脚本强依赖 `cd_bridge`（框架、账单、dispatch、drawtext、duty、gang、HUD、inventory、notification 的适配层）；escrow 加密。
- **性能/安全（D）**：3D 模型与实时跟踪对客户端有实打实开销；bridge 自动探测降低接入成本，但形成供应商锁定。
- **3 借**：
  1. `cd_bridge` 式"一个适配层屏蔽框架差异"——我们已有 `core-framework`/Bus，思路一致，可借鉴其**能力矩阵**（billing/dispatch/duty 各自可插拔）；
  2. radar 产品化：BOLO + ANPR + 测速 + 车牌库查询做在一个 HUD 里（我们的 `tcity-dashboard` 中控屏已经在做，缺 BOLO 列表与历史）；
  3. dispatcher 角色（不是所有警察都能看到全部警情）。
- **3 不借**：
  1. 3D 警情模型（48 人 Lite 不需要，反而拖帧）；
  2. 强绑 `cd_bridge` 的单一供应商路线；
  3. 闭源。

**→ T-City 落点**：radar/BOLO 补进 `tcity-dashboard` 中控屏（已有 `plate_flags`/ANPR），不做 3D，不引入 `cd_bridge`。

### 3.6 bub-mdt / 3.7 ox_mdt（同源，轻量 MDT 参考）

- **bub-mdt（S/R）**：8 页（Dashboard/Profiles/Incidents/Reports/Vehicles/Dispatch/Roster/Charges），内建 dispatch + `CustomAlert`；TS + React + Mantine + react-query；README 明说"仍未经充分测试"、"驾照积分系统不工作"、"Lua 部分需要重构"。
- **ox_mdt（R）**：WIP；页面 Dashboard（公告/通缉/BOLO）、Profiles（富文本备注/驾照/车辆/前科/关联报告）、Reports（涉案警员/物品与图片证据/罪名减免）、Dispatch（地图/单位/呼叫，**没有 dispatcher 时警员自管单位**）、Charges、Roster（招聘/警号/警衔/解雇）。
- **3 借**：
  1. ox_mdt 的"**无调度员降级**"：没有 dispatcher 在线时，普通警员可自建/接管单位——48 人服务器几乎总是这种状态；
  2. charges 目录（罪名/刑期/罚款/点数）作为独立可维护数据；
  3. bub 的 `CustomAlert({coords, info[], code, offense, blip})` 载荷形态（简单、可序列化）。
- **3 不借**：
  1. bub 自认未测试的状态；
  2. 8 页一次性铺开（我们只做 5 页 MVP）；
  3. ox_mdt 的 WIP 依赖（ox_core 专属）。

**→ T-City 落点**：`police_units` 状态机内置「无调度员时警员自建/接管单位」的降级路径，48 人默认走这条。

### 3.8 fivenet（外部 Web 平台的架构参考）

- **核心循环**：公民/车辆库 → 文档（模板/评论/访问级别）→ 排班与工时 → 日历/资质 → Livemap → 调度中心（接单/拒单/自动派单）。
- **架构（S/R）**：独立后端（Go）+ Nuxt 4/Vue 3 前端 + NATS + 独立 DB；FiveM 侧只有 Lua/TS 插件与 DBSync；Apache-2.0。
- **性能/安全（R）**：派系自管角色，管理员设权限上限；文档级 ACL；但需要 Docker/K8s/Postgres 运维。
- **3 借**：
  1. **权限上限**（管理员给派系设"最多能授予什么"，派系内部再分配）——可直接映射到 `custom-career` 的 department/tier；
  2. 文档模板 + 评论 + 访问级别（比 ps-mdt 的富文本报告更适合"搜查令/判决书"）；
  3. "网页端 + 游戏内平板 deep link"的双端形态（未来可选，不是现在）。
- **3 不借**：
  1. 为 48 人部署一套独立 Web 平台（Docker/NATS/Postgres）；
  2. 游戏库与 Web 库双写同步；
  3. 与手机 App 割裂的第二入口。

**→ T-City 落点**：只借「管理员设权限上限」映射到 `custom-career` 的 department/tier；Web 端不做。

### 3.9 esx_policejob（最小对照系）

- **核心循环**：上岗 → 军械库（按 grade）→ 车库 → 搜查/手铐 → 罚款（`fine_types` 目录）→ 监狱（`esx_service`/society）。
- **架构（S）**：761 行 server；`xLib.validation` 做参数校验、`isNearPlayer` 做距离校验、`notifyOffDuty` 提示下班；**没有业务表**——只有 `fine_types`（罚单目录）与 `jobs`/`job_grades`/`addon_account`/`addon_inventory`/`datastore` 这些框架表。
- **性能/安全（S）**：距离/职业/在线校验齐；但无分页、无审计、无案件；society/addon_account 与 QBCore 不兼容。
- **3 借**：
  1. 罚单**目录化**（`fine_types(label, amount, category)`）——我们直接复用 `custom-justice` 的 `Config.Justice.Crimes` 作为罚单/罪名唯一来源；
  2. 每个交互都做"距离 + 值班 + 目标在线"三连校验的朴素做法；
  3. 轻量：没有 MDT 也能完整跑（我们的降级路径也要保证这点）。
- **3 不借**：
  1. 无案件/报告（业务断层）；
  2. society 账户模型（与 QBCore/banking 冲突）；
  3. 单人 callback、无分页/无缓存。

**→ T-City 落点**：`Config.Justice.Crimes` 作为罪名/罚单唯一来源，导入 `police_charges`；校验沿用「距离 + 值班 + 在线」。

### 3.10 其他（只取一点）

- **snaily-cadv4（MIT）**：外部 CAD（单位/警员/呼叫/记录）。借它的"单位与呼叫是两种状态机"的建模方式；不借外部 Web 依赖。
- **fl-dispatch（MIT）**：10 系统 + 在勤警员列表 + 队伍颜色/呼号。借"10 码表 + 呼号徽标"；不借它要求改 `qb-core/server/player.lua`（我们不改 core）。
- **ars_policejob（Apache，2024-06 停更）**：0.0ms idle、`pickle_prisons` 适配、按 grade 车库。借"性能预算意识"；不借其停更状态。
- **fenix-police（GPL）**：AI 通缉警力（服务端 spawn、按辖区/星级配单位，可配置"仅当玩家警察不在线时启用"）。借"玩家警察在线数决定 AI 兜底"的开关思路；不借（与 RP 警察角色冲突、维护成本高）。
- **K9**：无维护良好的免费方案（DaveYo1 2018、Jakats 2022 均已停更）。**不做**，未来若要 K9 应自研最小版（跟随/嗅探/坐下 + 冷却），而不是引入旧脚本。

**→ T-City 落点**：以上四项都不进第一批切片；fenix 的「AI 兜底开关」只在未来 `custom-director` 有人工审批动作时考虑。

---

## 4. 功能清单矩阵

### 4.1 矩阵

> ✅ 有 ／ 🟡 部分 ／ ❌ 无 ／ ❓ 文档未说明。列只保留有代表性的 7 个对象。

| 功能 | 本地 qb-policejob | ps-mdt + ps-dispatch | wasabi | rcore | codesign | ESX policejob | 其他开源 | 我们要 | 优先级 |
|---|---|---|---|---|---|---|---|---|---|
| 巡逻（区域/路线/单位） | ❌（仅 blip） | ✅ patrol zones + 单位拖拽 | ✅ patrol teams | 🟡 units（无区域） | ❌ | ❌ | fivenet ✅ livemap | ✅ 单位状态 + 区域可选 | P1（单位）/P2（区域） |
| 接警 / 911 / 10 码 | 🟡 `/911p` + blip，无列表 | ✅ 10 码 + priority + 板子 | ✅ 内建 dispatch | ✅ switchboard | ✅ dispatch/3D | 🟡 `esx_phone` | fl ✅ 10 系统；snaily ✅ CAD | ✅ 必须 | **P0** |
| 交通拦截 / 测速 / ANPR | 🟡 固定雷达 + 被盗车雷达，无拦截流程 | 🟡 接 lsn-radar | ✅ radar gun/雷达柱/酒精测试 | ✅ 测速相机/雷达 | ✅ ALPR/radar | 🟡 无 | snaily 🟡 | ✅ 拦截记录 + ANPR 告警 | P1 |
| 证据 | 🟡 内存、客户端可信 | ✅ 证据 + 保管链 | ✅ `wasabi_evidence` | ✅ 证据板 | ❌ | ❌ | — | ✅ 但只做"轻证据" | P1 |
| 通缉 / BOLO | ❌ | ✅ warrants（felony/misdemeanor/infraction + 过期） | ✅ warrants/BOLO | ✅ BOLO | 🟡 BOLO 告警 | ❌ | bub ✅ | ✅ | **P0** |
| 搜查令 | ❌ | ✅ `mdt_warrant_requests` + `warrant_reviews` + court orders | ✅ warrants | ✅ | ❌ | ❌ | — | 🟡 先做"通缉"，搜查令 P2 | P2 |
| 罚单 | 🟡 任意金额、失败路径死 | ✅ fines + penal codes + 上限/冷却 | ✅ 预设 | ✅ fines list | ❌ | ✅ `fine_types` 目录 | bub ✅ | ✅ 目录 + 上限 | **P0** |
| 报告 / 案件 | ❌ | ✅ reports + cases + 协作 | ✅ incidents + link graph | ✅ case files | ❌ | ❌ | bub ✅；fivenet ✅ documents | ✅ 报告必做，案件 P1 | **P0**（报告） |
| 监狱 | 🟡 `qb-prison` metadata + `custom-justice` 内存 | 🟡 sentencing/jail 页 | ✅ 内置 jail 面板 | ✅ 独立 prison（dashboard/break/solitary） | ❌ | 🟡 | — | ✅ 轻量（复用 `custom-justice`） | P1 |
| 法庭 / DOJ | 🟡 `custom-justice` 内存案件，无持久化 | ✅ court calendar/hearings/orders | ❌（文档未见法庭模块） | ❓ 文档未列 | ❌ | ❌ | ❌ | 🟡 只做"判决记录 + 日程" | P2 |
| 车队 / 车库 | ✅ grade 车库/扣押/取回 | 🟡 仅 impound | ✅ land/air/boat garage | ✅ garage+impound | 🟡 `cd_garage` | ✅ | ars ✅ | ✅ 已有，补"车队状态/归还" | P2 |
| 警犬 | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | 仅停更插件 | ❌ 不做 | — |
| 特警（SWAT） | 🟡 只有部门武器配置（无 armory） | ❌ | 🟡 部门/grade | 🟡 armoury | 🟡 vehicle control | 🟡 grade 军械库 | — | 🟡 先补 armory，再做 SWAT 流程 | P2 |
| 训练 / FTO | ❌ | ✅ FTO phases/DOR/competency | ❌ | ❌ | ❌ | ❌ | — | ❌ 48 人不需要 | — |

### 4.2 "我们是否需要"的判断依据

- **必须（P0）**：接警/10 码、通缉/BOLO、罚单、报告。这四项构成"警情 → 处置 → 文书"的最小业务闭环；缺任何一项，MDT 都只是个花名册。
- **应该（P1）**：单位状态、案件、轻证据（照片/物品/保管记录）、监狱记录、交通拦截记录。
- **可缓（P2）**：搜查令审批、法庭日程、车队调度、SWAT 流程、巡逻区域。
- **不做**：警犬、FTO/训练、bodycam 录制、3D 警情、独立 Web 平台。

---

## 5. 架构建议

### 5.1 分层（新增 `custom-police`，不把逻辑塞进 qb-policejob）

```
┌────────────────── custom-phone (Svelte 5 + Vite) ──────────────────┐
│ AppGrid ← PhoneApps.ForPlayer()   PoliceMdt.svelte（5 页 + 详情）  │
│ 推送：phone:client:newNotification（+ 未来 app_id 深链）            │
└───────────────▲───────────────────────────────▲───────────────────┘
                │ appQuery / appAction           │ 通知单播
┌───────────────┴───────────────────────────────┴───────────────────┐
│ custom-police（新，薄服务层）                                      │
│  PhoneApps.Register('police_mdt')  ·  Bus.RegisterService('police') │
│  PolicePerm.Check(src, action)  ·  PoliceAudit.Log(...)             │
│  事件：tcity-police:server:*  ·  export：CreateCall/Alert/...       │
└───────▲──────────────────────▲──────────────────────▲──────────────┘
        │ 读框架数据            │ 交互事件              │ 只读导出
   qb-core / custom-career   qb-policejob(动作层)    custom-justice / tcity-dashboard
        │                      │
   MariaDB: police_calls / police_units / police_reports / ...
```

**为什么新建资源**

- `qb-policejob` 是 GPL 上游分叉，继续加 MDT 会让它变成 10k 行怪物，且升级上游更难；
- 调度数据要被 `custom-phone`、`tcity-dashboard`、`custom-director`、`custom-justice` 同时消费，独立资源 + Bus/export 才是正确边界；
- 未来若要换 UI（手机/中控屏/网页），服务层不用动。

### 5.2 数据表建议（MVP 9 张 / 全量 16 张，上限 18）

> 命名用 `police_*`，不用 `mdt_*`（MDT 只是第一个消费端）。所有金额/时间的写入走 `Player.Functions.*` 与现有 helper；迁移必须幂等并同步 `tests/fixtures/tcity_schema.sql`。

**MVP（9 张，第一个切片就要）**

| 表 | 关键列 | 索引/约束 |
|---|---|---|
| `police_calls` | id, code, code_name, priority, status(open/assigned/onscene/closed/expired), title, detail, x,y,z, street, caller_citizenid(NULL=匿名), anonymous, created_at, closed_at, closed_by | `(status, created_at)`, `(priority, created_at)`, `(caller_citizenid)` |
| `police_call_units` | call_id, citizenid, callsign, attached_at, detached_at, role(primary/backup) | PK(call_id, citizenid), `(citizenid)` |
| `police_units` | citizenid PK, callsign, department, status(10-8/10-6/10-7/10-97), status_note, updated_at | `(status)`, `(department)`；内存镜像 + 30s 落库 |
| `police_charges` | code PK, label, class(felony/misdemeanor/infraction), minutes, fine, points, active | `(class)`, `(active)`；种子来自 `Config.Justice.Crimes` |
| `police_reports` | id, type(incident/arrest/traffic/use_of_force), title, body(text/JSON), author_citizenid, author_name, department, visibility(dept/leo/doj), created_at, updated_at | `(author_citizenid, created_at)`, `(type, created_at)` |
| `police_report_people` | report_id, citizenid, role(suspect/victim/witness/officer), note | `(report_id)`, `(citizenid)` |
| `police_report_charges` | report_id, charge_code, count, minutes, fine | `(report_id)`, `(charge_code)` |
| `police_warrants` | id, citizenid, report_id, charges_summary, felonies, misdemeanors, infractions, status(active/served/expired/recalled), issued_by, approved_by, expires_at, created_at | `(citizenid, status)`, `(expires_at)`, `(status, expires_at)` |
| `police_fines` | id, citizenid, officer_citizenid, report_id, amount, reason, status(unpaid/paid/void), invoice_ref, created_at, paid_at | `(citizenid, created_at)`, `(status)` |

（严格算 9 张；若把 `police_call_units` 并进 `police_units` 的历史列可压到 8 张。建议保留独立关联表——合并后无法回答"这单谁接的"。）

**P1（+7 张）**

| 表 | 用途 |
|---|---|
| `police_cases` | 案件容器：case_number UNIQUE、title、summary、status(open/in_progress/closed)、priority、lead_citizenid、department |
| `police_case_reports` | case ↔ report 多对多 |
| `police_evidence` | id, case_id, report_id, type(photo/item/weapon/drug/digital), label, serial, location, status(in_locker/checked_out/disposed), created_by |
| `police_evidence_custody` | evidence_id, action(check_in/check_out/transfer/dispose), from_citizenid, to_citizenid, note, at —— **只追加，不更新** |
| `police_bolos` | kind(person/vehicle), citizenid, plate, description, status, expires_at |
| `police_impounds` | plate, reason, fee, lot, officer, released_at, storage_days（与 `player_vehicles.state` 并存，只做历史） |
| `police_audit` | id, actor_citizenid, action, target_citizenid, target_ref, meta(JSON, 不含自由文本), at —— 只追加 |

**P2（可选 +2 张，合计 18）**：`police_shifts`（值班时长）、`police_warrant_reviews`（搜查令审批）。`police_training`（FTO）**不做**，不计入上限。

**明确不要**：63 张。也不要复制 `mdt_profiles`/`mdt_citizens`/`mdt_vehicles`（用 `players`/`player_vehicles` + `police_flags` 覆盖层）。

### 5.3 服务端 API（Bus + export + 事件）

**Bus（与 `tcity-dashboard` 同款，供资源间调用）**

```lua
Bus.RegisterService('police', {
    GetCalls      = function(filter) end,   -- {status=, limit=}
    GetCall       = function(id) end,
    CreateCall    = function(payload) end,  -- 服务端内部调用
    AttachUnit    = function(callId, citizenid) end,
    ClearCall     = function(callId, citizenid) end,
    GetUnits      = function() end,         -- 内存快照
    SetUnitStatus = function(citizenid, status, note) end,
    GetCitizen    = function(query) end,    -- 复用 players
    GetVehicle    = function(plate) end,    -- 复用 player_vehicles + plate_flags
    CreateReport  = function(author, payload) end,
    CreateWarrant = function(author, payload) end,
    ServeWarrant  = function(actor, warrantId) end,
    IssueFine     = function(actor, targetCid, payload) end,
    Log           = function(actor, action, target, meta) end,
})
```

**Export（给别的资源）**

- `exports['custom-police']:Alert(payload)` —— 任意资源报警（内部做 code 白名单 + 限流 + 服务端补坐标）；
- `exports['custom-police']:CreateCall(payload)`；
- `exports['custom-police']:IsWanted(citizenid)`、`GetActiveWarrants(citizenid)`（给 `custom-justice`/`custom-director` 只读）；
- `exports['custom-police']:GetUnitSnapshot()`（给 `tcity-dashboard` 中控屏）。

**事件（客户端可触发的只有这几个，且全部服务端复验）**

| 事件 | 校验 |
|---|---|
| `tcity-police:server:call911(text, anonymous)` | 30s 冷却、文本 ≤ 200、phone 物品（可选）、坐标取 `GetEntityCoords(src)` |
| `tcity-police:server:attachCall(callId)` | 在勤 LEO、call 未关闭、同单人数 ≤ 4 |
| `tcity-police:server:clearCall(callId, code)` | 在勤 LEO、是 attach 过的人或 grade ≥ 2 |
| `tcity-police:server:setUnitStatus(status, note)` | 状态枚举、1.5s 冷却、note ≤ 60 |
| `tcity-police:server:panic()` | 在勤 LEO、10s 冷却、强制 priority 0 的 `officerdown` |

**MDT 的写操作不要走裸事件**：全部走 `PhoneApps.Action`（见 5.4），这样鉴权、审计、幂等三件事只写一遍。

### 5.4 作为 `custom-phone` 注册 App 落地

现状（已确认）：

- `server/phone_apps.lua` 提供 `PhoneApps.Register/ForPlayer/Query/Action`，`audience = { jobs = {...}, onduty = true }`，handler 被 `pcall` 包裹；客户端用 `getPhoneApps` / `appQuery` / `appAction` 三个 NUI 调用。
- `server/apps/police_mdt.lua` 已注册最小版：query `officers` + action `alert`。
- 前端 `DynamicApp.svelte` 只会渲染 **key-value 列表 + 一个 alert 输入框**——对 MDT 不够。

建议（**扩展现有 App，不新建第二个手机 App**）：

| 项 | 内容 |
|---|---|
| app id | `police_mdt`，`audience = { jobs = { 'police' }, onduty = true }` |
| 判定 | 保持 registry 的 job/onduty 作为**粗筛**；`department`/`grade`/`permission` 在 handler 内用 `PolicePerm.Check(src, action)` 细判（因为 `audience` 目前不支持 department/tier） |
| queries | `calls`（open，LIMIT 20，cursor）、`call`（id）、`units`、`citizen`（cid/姓名/车牌三选一）、`vehicle`（plate）、`reports`（LIMIT 20）、`report`（id）、`warrants`（active）、`charges` |
| actions | `attach_call`、`clear_call`、`set_unit_status`、`create_report`、`create_warrant`、`serve_warrant`、`issue_fine` |
| 前端 | 新增 `PoliceMdt.svelte`（5 页：调度 / 查询 / 报告 / 通缉 / 我的），按 `dynamicApps` 里是否存在 `police_mdt` 决定是否挂载；不把 MDT 塞进 `DynamicApp` |
| 推送 | 服务端 `phone:client:newNotification` 单播给在勤 LEO；若要做"点通知直达警情"，需给 `phone_notifications` 加 `app_id`/`action_ref`（幂等迁移，P1） |
| 语音 | 911 可复用 `custom-phone` 的 `StartSystemCall` + `systemSpeech`（调度 TTS），这是 T-City 独有的优势：报警人能和"调度台"通话，而不是只收到一条文本 |

**与 `custom-director` 的接缝**：新增 `dispatch_alert`（L1，可自动）、`issue_warrant`（L2，需审批）、`jail_player`（L3，需审批）。**不要**用现有 `teleport`/`set_job` 拼警察动作——那会绕过审计语义。LLM 只读侧可加 `/agent/v1/live/police/calls`（limit ≤ 20）。

**与 `custom-justice` 的接缝（重要）**：`custom-justice` 目前 **`activeCases`/`inmates` 全是内存**、无表、无重启恢复，且 `first_offense` 减刑"一律适用"是写死的简化。MDT 不要复制它的状态；应让 `custom-justice` 把案件/判决写进 `police_cases`/`police_warrants`（或新增 `justice_verdicts`），MDT 只读。

**与 `tcity-dashboard` 的接缝**：`server/police_api.lua` 已有 `plate_flags` 持久化、`lookupCitizen`、`lookupVehicle`、ANPR 批量检查、tracker。**复用这些表和回调**，不要新建第二套车牌标记；MDT 的"查车"复用同一条 `player_vehicles` SQL，不另建视图。

### 5.5 性能预算（48 人，按 8 名在勤 LEO 估算）

| 指标 | 预算 | 做法 |
|---|---|---|
| 警情推送 | 每条 call ≤ 8 次单播（不是 48） | 服务端 `job ∈ call.jobs && onduty` 过滤 |
| 推送载荷 | ≤ 2 KB/条（无真实坐标、无列表全量） | 服务端公共视图裁剪（ps-dispatch 的 `publicCall`）+ offset 坐标 |
| 打开 MDT | ≤ 3 次 DB 查询 | `calls` + `units`（内存）+ 一次 `warrants`；其余按需 |
| 列表 | 每页 ≤ 20，最大 50 | cursor 分页（`created_at,id`），禁用 `OFFSET` 大偏移 |
| 单位状态 | 1 次写/状态变化 + 30s 落库 | 内存 map 读，DB 只做恢复 |
| 禁止 | 1s 轮询、`SELECT *`、全表 `LIKE '%x%'`、`-1` 广播业务数据 | code review checklist |
| 保留 | calls 7 天、audit 90 天、notifications 30 天；reports/charges 永久 | 每日低峰清理线程 |

### 5.6 安全清单（每条都要在 PR 里能指出来）

1. NUI 隐藏 ≠ 权限：`PhoneApps` 的 `audience` 只是粗筛，handler 内必须 `PolicePerm.Check`。
2. 所有写操作：`actor` 从 `source` 取，**绝不**信客户端传的 `officer_citizenid`。
3. 距离校验：查验/搜查/逮捕 ≤ 3.5m（沿用本地 `checkid` 的写法）；车辆操作 ≤ 6m。
4. 金额/刑期：`tonumber` + `clamp`（罚单 ≤ 100k、刑期 ≤ 480min）；罪名必须 ∈ `police_charges`。
5. 通缉/搜查令：`issued_by` 与 `approved_by` 分离；grade ≥ 2 才能签；`expires_at` 必填（默认 7 天）。
6. 限流：`call911` 30s、`attach/clear` 1s、`unit_status` 1.5s、`issue_fine` 30s、`panic` 10s。
7. 审计：每个 action 一行 `police_audit`（actor/action/target/meta 不含自由文本）。
8. 幂等：`actions` 带 `idempotency_key`（重复提交返回同一结果），沿用 `AGENTS.md` 的写路径规范。
9. 匿名报警：不落 `caller_citizenid`，但服务端仍保留真实 source 供管理员审计（`police_audit` 可见）。
10. 通知：`origin='server'`、只落库一次、单播一次，避免 qb-phone 式回环。

---

## 6. 参考链接

**源码 / README（可读）**

- 本地基线：[qbcore-framework/qb-policejob](https://github.com/qbcore-framework/qb-policejob)（GPL-3.0）
- [Project-Sloth/ps-mdt](https://github.com/Project-Sloth/ps-mdt)（CC BY-NC-SA 4.0）
- [Project-Sloth/ps-dispatch](https://github.com/Project-Sloth/ps-dispatch)（GPL-3.0）
- [Project-Sloth/ps_lib](https://github.com/Project-Sloth/ps_lib)
- [BubbleDK/bub-mdt](https://github.com/BubbleDK/bub-mdt)（GPL-3.0）
- [overextended/ox_mdt](https://github.com/overextended/ox_mdt)（GPL-3.0，WIP）
- [fivenet-app/fivenet](https://github.com/fivenet-app/fivenet)（Apache-2.0）
- [SnailyCAD/snaily-cadv4](https://github.com/SnailyCAD/snaily-cadv4)（MIT）
- [finalLy134/fl-dispatch](https://github.com/finalLy134/fl-dispatch)（MIT）
- [Arius-Scripts/ars_policejob](https://github.com/Arius-Scripts/ars_policejob)（Apache-2.0）
- [FenixPK/fenix-police](https://github.com/FenixPK/fenix-police)（GPL-3.0）
- [esx_policejob @ ESX-Legacy-Addons](https://github.com/esx-framework/ESX-Legacy-Addons/tree/main/%5Besx_addons%5D/esx_policejob)（GPL-3.0）

**官方文档（付费/闭源，只读）**

- [wasabi_police_v2](https://docs.wasabiscripts.com/advanced-series/wasabi-police-v2/)
- [wasabi_mdt](https://docs.wasabiscripts.com/advanced-series/wasabi-mdt/)
- [wasabi_evidence](https://docs.wasabiscripts.com/advanced-series/wasabi-evidence/)
- [rcore_police](https://documentation.rcore.cz/paid-resources/rcore_police) · [rcore_dispatch](https://documentation.rcore.cz/paid-resources/rcore_dispatch) · [rcore_prison](https://documentation.rcore.cz/paid-resources/rcore_prison) · [rcore_mdt](https://documentation.rcore.cz/paid-resources/rcore_mdt)
- [codesign dispatch](https://docs.codesign.pro/paid-scripts/dispatch) · [dispatch3d](https://docs.codesign.pro/paid-scripts/dispatch3d) · [radar](https://docs.codesign.pro/paid-scripts/radar)
- [fivenet features](https://fivenet.app/getting-started/features)

**本地上下文（本仓库）**

- `T-CityLite.base/resources/[qb]/qb-policejob/`（config/server/client/html）
- `T-CityLite.base/resources/[custom]/custom-phone/server/phone_apps.lua`、`server/apps/police_mdt.lua`、`web/src/apps/DynamicApp.svelte`、`web/src/stores/apps.ts`
- `T-CityLite.base/resources/[custom]/custom-director/server/policy.lua`（18 个动作）
- `T-CityLite.base/resources/[custom]/custom-career/server/main.lua`（`SetPlayerDepartment`/`SetPlayerDistrict`/`GetPlayerIdentity`）
- `T-CityLite.base/resources/[custom]/custom-justice/{config.lua,server/*.lua}`（内存案件/监狱/审判）
- `T-CityLite.base/resources/[system]/tcity-dashboard/server/police_api.lua`（`plate_flags`/ANPR/查询）
- `T-CityLite.base/docs/agent/phone/DESIGN.md`（职业 App 注册表设计）→ [DESIGN.md](../../T-CityLite.base/docs/agent/phone/DESIGN.md)

---

## 7. 结论（最后 6 行）

- **最值得借鉴的 3 个模组**：`ps-mdt`（报告/案件/证据/审计的数据骨架）、`ps-dispatch`（过滤广播/优先级/坐标模糊/合并）、`wasabi_mdt`（AutoSync 覆盖层 + 分页 + 服务端遍历上限）。
- **最不该抄的 3 个做法**：把权限交给 NUI（客户端隐藏当鉴权）、全表/全服轮询广播（qb-phone 60s、本地 qb-policejob 5s blip、ps-mdt `-1` 通缉广播）、把业务状态放内存（qb-policejob evidence、custom-justice cases、qb-prison）。
- **MDT 最小可行功能**：人员/车辆/车牌标记查询 + 通缉列表 + 报告（罪名/涉案人）+ 单位状态 + 审计；5 个页面、9 个 query、7 个 action。
- **调度最小可行功能**：`/911`→`police_calls`→在勤单播→接单(10-6)→到场(10-97)→结案(10-8)，含 10 码表、三级优先级、30s 限流、自动过期。
- **数据表建议数量**：MVP 9 张（可压到 8），全量 16 张，上限 18；不做 ps-mdt 的 63 张。
- **推荐先做的 2 个切片**：①调度闭环（`police_calls`/`police_units` + `custom-phone` 推送 + 单位状态）；②MDT 只读查询（citizen/vehicle/`plate_flags` + warrants 列表 + `police_audit`）。
