---
id: police-flow-research
type: research
status: final
system: justice
owner: hermes
updated: 2026-10-24
review_by: 2027-01-30
---

# 警察扮演流程调研（FLOW_RESEARCH）

> **问题**：FiveM（QBCore / ESX）警察扮演里，怎样在「功能精简」的同时保证扮演质量？
> **范围**：从平民报警到结案/入狱的**流程**（不是功能清单）。功能与架构对照见同目录 [research-external.md](research-external.md)；本地逐步审计见 [FLOW_INTERNAL.md](FLOW_INTERNAL.md)；一体化设计见 [DESIGN.md](DESIGN.md)。
> **方式**：只读本地代码 + 公开文档/README/源码；**未改代码、未主动 commit、未碰 FXServer**。
> **日期**：2026-10-24。仓库 `T-City-agent`，分支 `master`。

---

## 0. 一页结论：保持精简的 7 条原则

| # | 原则 | 外部证据 | 对 T-City 的意思 |
|---|---|---|---|
| 1 | **一个入口**：现场动作与文书在同一块屏上完成，不切聊天/不切弹窗/不换设备 | ps-mdt 的 `/mdtimpound` 复用 MDT 同一张扣押表单，README 原话「an officer only ever learns one screen」（S\*） | 现在上铐在聊天、入狱在 `qb-input`、记录在手机 MDT，是三个入口；先并成一个 |
| 2 | **罪名目录即罚则**：金额与刑期由 penal code 求和，警员永不手填数字 | rcore_mdt 的 charge 自带 fine + jail 区间，提交报告即按罪名开罚单（D）；ESX `fine_types` 目录（S）；本地 `Config.Justice.Crimes` 已有 13 条罪名（S） | MDT 罚单仍手填金额、`/fine` 只有一个数字；应改成「选罪名 → 金额自动」 |
| 3 | **一次提交产出全部记录**：报告提交 = 指控 + 罚单 + 案件链接，不做「报告/罚单/逮捕登记」三次填表 | rcore_mdt「file report → each charge 自动 bill」（D）；ps-mdt 报告内嵌 people/charges/evidence（S\*） | 本地三张表三次填：`police_reports`、`police_citations`、`police_arrests` 互不引用 |
| 4 | **默认值、模板、自动填充**：坐标/时间/警员/案号/警情 id/嫌疑人全自动，正文才让人写 | ps-dispatch 的 alert 自带 street、vehicle、plate、weaponTier、callsign（S）；fivenet 文档模板（D） | MDT 的 `citizenid`、`incident_id`、`case_id` 都要人手查/手抄 |
| 5 | **机械步骤 ≤3 次输入**：超过 3 步的那一步必须是 RP 判断，而不是填表 | wasabi 到场自动标记、rcore 罚单预设、ESX fine 目录（D/S） | 目标：罚单 3 步、报告 1 个正文框、逮捕 ≤6 步 |
| 6 | **只在不可逆处设卡**：入狱、搜查令、封存证据设硬门槛；清场/报告/结案可先跳过、事后补 | ps-dispatch 的 call 生命周期与 MDT 报告完全解耦（README 未要求「有报告才能关单」）（S\*）；ps-mdt 报告可留草稿；本地 [`DESIGN.md`](DESIGN.md) 的 `report_missing` 明确不阻断关单（S） | 不要为了「流程完整」逼玩家在枪战现场填 4 个字段 |
| 7 | **每条链都有降级路径**：没人审批、没人接单、当事人离线时流程不能死 | ox_mdt「无调度员时警员自管单位」；rcore 离线只记罚单不扣款（D） | 没有法官 → 警长代判/认罪协议；没有律师 → 放弃减刑；没人接单 → 90s 回 open |

**一句话**：48 人服的上限是「一次执法 60 秒内把记录写完、一次逮捕不超过 6 步」。超过这条线，玩家会**跳过文书**；文书一空，MDT 做得再全也只是空表。

---

## 1. 口径与证据等级

**步数定义**（本文所有「步」都按这个算）：

- 1 步 = 1 次**玩家主动输入**：按一个键、点一个按钮、填一个字段、说一句命令。
- **UI 切换**单独计：聊天 → 弹窗（`qb-input`）→ 手机 → 手机内另一个 App/Tab，各算 1 次切换。
- 打字算 1 步，但另记「打字量」（句 / 段）。「写一段报告正文」和「填一个 citizenid」都是 1 步，但扮演价值差 100 倍。
- 只统计**最少必要路径**（熟练玩家、无查证、无失败重试）。

> **与 [FLOW_INTERNAL.md](FLOW_INTERNAL.md) 的口径差异**：那份文档把「整张表单提交」算 1 步、并把上勤计入每条流程，所以同一条逮捕链记 12 步；本文按「字段/点击」逐个计、不重复计上勤，记 11–13 步。两套数字**不矛盾**，跨系统比较时只用同一口径内的相对值。

**证据等级**（沿用 `research-external.md` 的口径）：

| 等级 | 含义 |
|---|---|
| **S** 源码级 | 读过实际 Lua/TS/SQL（本仓库、ESX policejob、本地 custom-police） |
| **S\*** README 级 | 读的是仓库 README/官方示例代码，未逐文件读源码（ps-mdt、ps-dispatch 本轮）；**63 表 / 62 权限 / `CheckPermission` 缺失**等源码级统计沿用 [`research-external.md`](research-external.md) 的 2026-10-23 快照 |
| **D** 文档级 | 只读官方文档，源码不可见（wasabi、rcore、fivenet） |
| **R** 描述级 | 只有 README/商店页/社区文章 |

**找不到 / 已换源的对象**（按要求逐条注明）：

- `Project-Sloth/ps-police`：**不存在**（404）。Project Sloth 的警察栈 = `ps-mdt` + `ps-dispatch` + `ps_lib`。
- `wasabi-policejob` / `wasabi_mdt` 源码仓库：**无公开源码**（付费 + escrow），只有 [docs.wasabiscripts.com](https://docs.wasabiscripts.com/advanced-series/wasabi-mdt/)。
- `esx_mdt`：**不存在**；`esx_policejob` 已并入 [ESX-Legacy-Addons monorepo](https://github.com/esx-framework/ESX-Legacy-Addons/tree/main/%5Besx_addons%5D/esx_policejob)，本文读的是该仓库源码。
- `fivem.pl` 的 traffic stop / MDT 报告两篇波兰语指南：抓取时 **HTTP 521（源站宕机）**，改用 [LSPD TR 的 SOP 文章](https://lspd.tr/bloglar/spd-guc-kullanimi-ve-orantili-mudahale-protokolu-use-of-force-continuum)。
- `fivenet` 的 Dispatch Center 正文页：抓取只返回导航（站点为 Nuxt 渲染，正文被截断），**只用它的 Features/README 级信息**，并标注为 D/R。

---

## 2. 逐系统提炼

每个系统固定五段：**完整链路 / 强扮演 vs 机械 / 精简技巧 / 过度设计 / 可量化指标**。

### 2.1 本地 `qb-policejob`（已合并进 `custom-police`）

**完整链路（S）**

1. **接警**：平民在聊天打 `/911 <文本>` → [server/p0.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-police/server/p0.lua) 写 `police_incidents`（含坐标、priority 默认 2）→ 给所有在勤警察写 `phone_notifications`（`app_id='police_mdt'`）并推手机通知（`/911` 固定 priority 1，未传时默认 2）。
2. **调度**：**没有调度台**。单位状态靠 `/10-8` `/10-6` `/10-7` 三条聊天命令；派单只能进手机 MDT「接警」tab，用下拉框选一个单位点「派单」（[PoliceMDT.svelte:298–327](../../T-CityLite.base/resources/%5Bcustom%5D/custom-phone/web/src/apps/PoliceMDT.svelte#L298-L327)）。
3. **现场**：全是聊天命令，共 **30 条**：`/cuff` `/escort` `/jail` `/fine` `/seizecash` `/sc` `/checkid` `/checklicense` `/spikestrip` `/impoundnear` ……（[server/commands.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-police/server/commands.lua)）。
4. **记录**：手机 → MDT App → **13 个 tab**（首页/单位/接警/人员/车辆/罚单/报告/证据/案件/BOLO/搜查令/逮捕/审计）。
5. **逮捕**：三条互不相认的路径 —— `/jail`（`qb-input` 填分钟 → qb-prison）、`/arrest`（`custom-justice` 选罪名 id → 建案 → 通知律师 → 开庭 → 判决入狱）、MDT「逮捕」tab（只写 `police_arrests`，**不入狱**）。
6. **法庭/监狱**：`custom-justice` 的链路是完整的（法官 `/startTrial` → 有律师减刑 30% + 代码里**一律**适用的初犯减免 20% → 服务端入狱），但**要求法官 + 律师同时在线**；`qb-prison` 是唯一真正执行刑期的资源。

**强扮演 vs 机械**

| 环节 | 判定 | 依据 |
|---|---|---|
| 拦停对话、上铐时机、是否拔枪 | 强扮演（零 UI） | 全部靠玩家动作，无系统约束 |
| 输入 `citizenid` | 机械 | MDT 逮捕/罚单都要手打，且要先去「人员」tab 查 |
| 输入刑期分钟数 | 机械 | `/jail` 的 `qb-input` 只有一个数字，无罪名、无上限 |
| 选罪名 | 半机械 | 点一次即可，但只在 justice 的 `/arrest` 里有目录，MDT 是自由文本 |
| 写报告正文 | **强扮演** | 唯一值得保留的自由输入 |
| 证据登记 | 机械（4 个字段 + 提交） | label + incident_id + location + description |

**精简技巧（本地已有的好东西）**

- 罚单金额默认值 `500` 已预填（`citationForm.amount = '500'`）。
- MDT 首页一次 `Promise.all` 并行拉 units + incidents，不是逐 tab 轮询。
- 报告/证据的 `incident_id`、`case_id` 是**可选**的，不阻断提交。
- `police_audit` 已经记录每个动作的 actor/action/target，可直接当流程埋点用。

**过度设计 / 断点**

- **入口分裂**：聊天命令（现场）+ `qb-input`（刑期/罚款）+ 手机 MDT（记录）= 3 套交互、3 次焦点切换。
- **三套逮捕**：`/jail`、`/arrest`、MDT 逮捕 tab。三者写三张不同的表，语义还不一致（一个进监狱、一个进法庭、一个只留痕）。
- **两套证据**：`qb-policejob` 的弹壳/血迹/指纹在**服务端内存**（重启即失），MDT 的 `police_evidence` 是另一套带保管链的登记簿，互不引用。
- **自由文本罪名**：MDT `charges` 是 `<input>`，可写「随便」；justice 的 13 条罪名目录根本没被 MDT 使用。
- **前端表单字段顺序不合理**：罚单是 `citizenid → amount → plate → reason`，最重要的「原因」在最后，且 citizenid 最该自动带入。

**指标（实测/估算）**

- 罚单（有记录）：7–9 步，2 次 UI 切换（手机 + tab），打字 0–1 段。
- 报告：6–7 步（手机 → App → tab → 标题 → 正文 → 提交），打字 1 段。
- 完整逮捕 + 入狱 + 留痕：**11–13 步，3 次 UI 切换**（详见 §6）。

---

### 2.2 ps-mdt + ps-dispatch（Project Sloth）

**完整链路（S\*）**

1. **接警**：资源内部 30+ 个硬编码 alert（抢劫/枪击/超速/车辆盗窃…）→ `ps-dispatch:server:notify` → 服务端按 `Config.Jobs` + 在勤过滤后**只发给合格玩家**（`FilteredBroadcast`）。
2. **调度**：屏幕 alert（`E` 响应）→ `O` 打开 dispatch menu（Calls / Plates 两个 tab）→ 选中 call → **Attach** 单位 → 主管可把 call 标为 **major incident**（置顶 + banner + 对已附着单位静音 routine，二段确认）。
3. **现场**：`ps-mdt` 的 F11 MDT（或 `/mdt`）；ps-dispatch 自身不做现场动作。
4. **记录**：报告（富文本 + people/charges/evidence + 标签 + 部门可见性）→ 案件（聚合多报告）→ 证据（type/serial/location + 照片 + 保管链转移）→ 通缉/BOLO → 扣押 → 法庭日历。
5. **逮捕**：**没有独立「逮捕登记」**。逮捕的事实由报告 + charges 表达；真正送监靠外部监狱资源。
6. **法庭/监狱**：MDT 里只有**法庭日历**（hearing 排期、分类权限、缺席追踪、提醒），判决与执行都在外部资源。

**强扮演 vs 机械**

- 强扮演：现场对话（无 UI）、报告叙事、案件串联（reports → case）、法庭排期与出庭。
- 机械：F11 → 报告 → 逐条 `add person` / `add charge` / 上传照片；每个都是搜索框 + modal。

**精简技巧**

- 报告是**唯一容器**：people/charges/evidence 全在报告内联，不另开「罚单页」「逮捕页」。
- `/mdtimpound` 与 MDT 内扣押**共用同一张表单**（README 明说「only ever learns one screen」）。
- 权限默认值（`PermissionDefaults`）+ 部门共享（Mutual/OneWay），减少逐人配权。
- 分页（`LIMIT/OFFSET`）+ 进程内缓存 + `officer_status` 内存读路径。

**过度设计（本文最重要的反面教材）**

- **63 张 `mdt_*` 表**（源码级统计见 `research-external.md`）、**62 个权限键**（README 自述）、30+ 个 server 模块。
- 48 人服一辈子用不到的 8 个模块：FTO（带教评分）、IA（内部调查 7 状态）、PPR（绩效面谈）、SOP（签收追踪）、Leaderboard（逮捕排行）、Awards、Court Calendar、Civilian Mode。
- 权限名不副实：`cases.lua` 21 处 `CheckAuth` / 0 处 `CheckPermission`（源码级），62 个权限键大半只挡 UI。

**指标**

- 报告：**10–14 步 / 3–4 个 modal**（标题、类型、逐人、逐罪名、正文、保存）。
- 罚单：走 charges 内联，6–8 步；扣押 5–7 步。
- 逮捕：无独立登记，= 报告步数 + 外部监狱命令。

---

### 2.3 wasabi_police_v2 + wasabi_mdt（闭源，文档级）

**完整链路（D）**

1. **接警**：内建 dispatch/panic（可桥 ps-dispatch / cd_dispatch），枪声自动告警。
2. **调度**：MDT 的 Dispatch 页建 priority call、派单位、pin、设 waypoint；**到场自动标记**；calls 可选跨重启持久化。
3. **现场**：soft/hard cuff、zipties、surrender/compliance、tackle、搜身、押运、雷达枪、测速柱、脚环、钉刺带、breathalyzer。
4. **记录**：MDT 16 个核心页：Dashboard / Dispatch / Map / Citizens / Vehicles / Weapons / Properties / Incidents / Evidence / Charges / Penal Codes / Warrants / BOLOs / Officers / Announcements / Cameras。
5. **逮捕**：现场动作 + MDT 报告（charges 内联）→ 内建 jail 或外部监狱桥。
6. **法庭/监狱**：无内建法庭；监狱靠 `wasabi_police` 的 `/jailpanel` 或外部 prison 桥。

**强扮演 vs 机械**

- 强扮演：现场合规/投降、搜身与对话、报告叙事、Report Link Graph 追关系。
- 机械：MDT 16 页导航、逐条关联记录、照片上传（FiveManage）、bodycam（Medal）。

**精简技巧**

- **到场自动标记**（省掉「我到场了」这一步点击）。
- **AutoSync**：公民/车辆直接读框架表，MDT 只存备注/标记/照片/指纹 —— 绝不复制一套 `mdt_citizens`。
- dispatch 持久化（重启不丢 call）。
- 每部门每 grade 的权限矩阵 + 默认值。

**过度设计**

- 16 个页面 + 站内建站器（DB 存 station 布局）+ CCTV 布点 + bodycam 录制 + 雷达柱 + 追踪脚环。
- 依赖链重：FiveManage 图床、Medal、object_gizmo；闭源不可审计，出问题只能等作者。

**指标（D 级估算，无法源码验证）**

- 罚单 3–5 步（预设 + 自动金额）；报告 8–12 步；逮捕 8–12 步（含 MDT 记录 + 送监）。

---

### 2.4 rcore（police / dispatch / mdt / prison，闭源，文档级）

**完整链路（D）**

1. **接警**：`rcore_dispatch` 的 `/911` `/anon911` `/sos` → switchboard（`/dispatch`）/ panel（`/panel`）；兼容 cd_dispatch、qs-dispatch 的入站。
2. **调度**：dispatch 面板接单/拒单/派单位；`rcore_police` 有独立 emergency button。
3. **现场**：radial menu + context menu；smart interaction 自动锁定最近目标（多人时可选）；cuff/tackle 带**小游戏**（嫌犯可挣扎逃脱）；search、impound、spike strip、megaphone、雷达、测速相机自动开单。
4. **记录**：`rcore_mdt` 的 **Incident**：Title / Report / Criminals / Officers / Civilians / Charges / Evidence / Tags / Photos；另有 Case Files（回复/提及/表情）、Evidence Boards（拖拽关系图）、BOLOs、Bulletins、Units & Duty、Audit Logs。
5. **逮捕**：现场上铐 → MDT 写 incident 并挂 charges → **file 报告时按每条 charge 自动给每个 criminal 开罚单** → 送监（`rcore_prison`）。
6. **法庭/监狱**：无内建法庭（只有 MDT 记录）；`rcore_prison` 有 jail、Prolog（入狱镜头序章，可跳过）、Solitary、Canteen、Prison Break、Dealer、MDW 面板（可调刑期/看事件日志）。

**强扮演 vs 机械**

- 强扮演：上铐/擒拿小游戏、报告叙事、证据板关系推理、监狱 prolog + 食堂/劳动。
- 机械：incident 的 9 类字段、charge 逐条添加、罚单状态手改、MDW 手调刑期。

**精简技巧**

- **报告即罚单**：`file` 一次，charges → 自动 bill（在线扣现金/离线只记记录）。少掉整个「开罚单」界面。
- **penal code 驱动量刑**：charge 自带 fine + jail 区间，报告页直接显示「建议刑期」；**jail time 只是建议，MDT 不自动送监**（避免误判，也避免流程卡在监狱资源）。
- 罚单预设列表（现场 1–2 步）。
- 自动建表（省迁移脚本，但代价见下）。

**过度设计**

- 拆成 4 个独立付费产品（police / dispatch / mdt / prison），配置与兼容矩阵爆炸。
- `rcore_prison` 9 个特性：雪茄包装、食堂、交易商、椅子系统……对一个 48 人服是纯装饰。
- **自动建表**：没有 SQL 迁移文件 → 无法 code review、无法回滚、无法与 `tests/fixtures/tcity_schema.sql` 对齐。
- 小游戏与动画强耦合（cuff/tackle 逃脱），网络差时体验崩。

**指标（D 级估算）**

- 报告：8–10 步（字段多但一次提交出罚单）。
- 罚单（独立）：3–4 步；逮捕（报告 + 送监）：8–10 步。

---

### 2.5 fivenet（德国社区，重流程）

**完整链路（D/R）**

1. **接警**：游戏内 `/911` 或网页/平板 → Dispatch Center（接单 / 拒单 / **自动派单**）。
2. **调度**：网页端 dispatch 面板 + livemap + 单位状态；可跨部门。
3. **现场**：FiveM 插件只做轻量桥接（DBSync 同步玩家/车辆），实际记录在**外部 Web**。
4. **记录**：Documents（**模板** + 访问级别 + 评论）、Citizens、Vehicles、Jobs（排班/资质）、Calendar（法庭/会议）。
5. **逮捕/法庭**：没有游戏内逮捕登记；法庭以 Calendar + Documents 承载，是「社区流程」而非脚本流程。

**强扮演 vs 机械**

- 强扮演：文档写作（模板约束下的长文本）、部门角色/权限扮演、法庭排期与会议。
- 机械：**切出游戏**（Web/平板）、双写同步、跨系统找入口。

**精简技巧**

- **模板先行**：先选模板（报告/搜查令/事故），再填字段 —— 比空白富文本框快得多，也保证格式统一。
- 访问级别 + 评论，让文档可协作，不需要「报告审批」流程。
- 自动派单（无人调度时降低门槛）。

**过度设计**

- 部署栈：Go 服务 + NATS + Postgres + Docker/K8s；48 人服属于杀鸡用牛刀。
- 游戏内/外割裂：玩家要离开游戏画面去写文档，直接杀死「现场感」。
- 采用率低：26★（2026-10 快照，见 `research-external.md`），社区支持有限。

**指标（R 级估算）**

- 文档 2–3 步（选模板 + 填字段 + 保存）；dispatch 接单 1 步；但每次**至少 1 次出游戏**（成本极高）。

---

### 2.6 ESX Legacy `esx_policejob`（源码级）

**完整链路（S）**

1. **接警**：无。靠 `esx_phone` 的「police」特殊联系人转发消息。
2. **调度**：无面板、无单位状态；只有全服警察 blip。
3. **现场**：站点 marker（更衣室/军械库/车库/直升机/老板菜单）→ 按 `E`；现场动作走 `F6` → `police_actions` → `citizen_interaction`（8 项：身份证/搜身/上铐/拖拽/上车/下车/罚款/欠款）或 `vehicle_interaction`（车辆信息/撬锁/扣押/查库）或 `object_spawner`（锥桶/路障/钉刺带/箱子/现金箱）。
4. **记录**：**不存在**。没有报告、案件、证据、通缉、BOLO。
5. **逮捕**：上铐（`F6`→公民交互→上铐 = 3 步）→ **没有登记** → 送监靠外部 jail 脚本（`esx_jail` 等）。
6. **法庭/监狱**：无。

**强扮演 vs 机械**

- 强扮演：全部靠玩家自由发挥（脚本不提供任何流程）。
- 机械：三层 ox_lib 菜单（F6 → 动作类别 → 具体动作）；撬锁动画等 20s、扣押等 10s。

**精简技巧（值得抄的两点）**

- **`fine_types` 目录**：罚款按「交通/轻微/一般/重大」4 类分，每类下是预置条目（label + amount），警员只选条目 → **金额不可能填错**，也不可能开天价罚单。
- **物理入口**：走到站点 marker 才能更衣/取枪/取车，把「流程」藏进世界，而不是藏进菜单。

**过度设计**

- 反向的过度设计：功能缺失到无法支撑扮演（无记录 → 累犯不可见、无案件 → 侦探不存在）。
- 菜单层级过深：3 层菜单 + 每个动作一个子菜单，点 5 次才开一张罚单。

**指标**

- 罚单：**5 步**（F6→公民交互→罚款→类目→条目），金额自动。
- 逮捕：3 步（F6→公民→上铐）+ 外部 jail 命令 ≈ 4–5 步，零记录。
- 报告：0 步（不存在）。

---

### 2.7 社区流程资料：真正决定扮演质量的东西

| 资料 | 关键内容 | 对流程设计的含义 |
|---|---|---|
| [LSPD TR：Traffic Stop 程序](https://lspd.tr/bloglar/trafik-durdurma-traffic-stop-proseduru-ve-yasal-cerceve)（R） | Terry Stop 的「合理怀疑」、PBT/SFST 酒测、6 条黄金动作：选安全区 → 扩音器指令（手放方向盘、否则使用武力）→ **路过车尾用手摸一下**（留指纹）→ 要求降下左前左后两窗 → 右手慢递证件 → 警灯灭前不许走 | 这些**全部是零 UI 的强扮演**。系统只需要 1 个「开始拦截」入口，自动记录车牌+时间+坐标；剩下交给玩家 |
| [LSPD TR：Use of Force Continuum](https://lspd.tr/bloglar/spd-guc-kullanimi-ve-orantili-mudahale-protokolu-use-of-force-continuum)（R） | 4 级：presence/verbal → soft hands（OC）→ less-lethal（taser/baton/beanbag）→ deadly；**所有使用武力必须录入 MDC 并上报 IA** | 「1 张表单换 10 分钟 RP」性价比最高的点：武力等级 + 一句理由，自动进审计/IA |
| [agencyg：FiveM Court & Legal System](https://agencyg.de/blog/fivem-court-legal-system)（R） | 案件状态机 `filed → arraignment → pretrial → trial → verdict → closed`；warrant 分 arrest/search/bench + 有效期；动议（suppress/dismiss/continuance…）；保释与量刑指南 | 法庭是**最重、最容易没人**的流程。只保留「起诉 → 认罪/开庭 → 判决」三态即可 |
| [Cfx Forum：m-CourtSystem](https://forum.cfx.re/t/padi-m-courtsystem-the-most-realistic-court-justice-system-for-fivem/5362104)（R） | 律师/法官考试、法官选举、税务、营业执照、旁听登记…… | 典型过度设计：**48 人服凑不齐 1 个法庭**，这些模块只会让服务器看起来复杂 |
| [gfxscripts：Improving Police Roleplay Loops](https://gfxscripts.com/blog/fivem-mdt-script-police-ems-dispatch-system-guide)（R） | 痛点是「报告/前科/通缉散在外部文档和聊天记录里」→ 需要 single source of truth | 支持原则 1：**不是缺功能，是缺入口**。记录一旦要切窗口，玩家就不写 |

---

## 3. 系统对照表

> ✅ 有 / 🟡 部分 / ❌ 无。步数为最少必要路径；`~` 表示按文档/README 估算、**未逐点击验证**。

| 系统 | 接警 | 调度 | 现场 | 记录 | 逮捕 | 法庭/监狱 | 强扮演点 | 精简技巧 | 坑 |
|---|---|---|---|---|---|---|---|---|---|
| **本地 qb-policejob（并入 custom-police）** | 🟡 `/911` 聊天命令 → `police_incidents` → 手机通知 | 🟡 无调度台；`/10-8` 三条命令；MDT 下拉派单 | ✅ 30 条聊天命令（铐/押/搜/罚/拖车/雷达） | 🟡 手机 MDT 13 tab；证据两套（内存 + 表） | 🟡 三条路：`/jail`、`/arrest`、MDT tab（互不相认） | 🟡 justice 链路完整但需法官+律师在线；qb-prison 执行 | 拦停对话、上铐时机、报告正文 | 金额默认 500、`incident_id` 可空、并行 refresh、审计已就位 | 3 套入口、3 套逮捕、2 套证据、自由文本罪名、citizenid 手抄 |
| **ps-mdt + ps-dispatch** | ✅ 30+ 预设 alert + 平民报警 | ✅ 过滤广播、合并、坐标模糊、major incident、Plates 日志 | 🟡 只有 MDT（现场靠别的资源） | ✅ 报告/案件/证据/通缉/BOLO/扣押/法庭日历 | 🟡 无独立登记，靠报告 + charges | 🟡 只有法庭日历；执行在外部 | 报告叙事、案件串联、出庭 | 报告内联 people/charges；`/mdtimpound` 复用同一表单 | 63 表 / 62 权限 / 8 个没人用的模块；权限只挡 UI |
| **wasabi_police_v2 + wasabi_mdt** | ✅ 内建 dispatch/panic + 枪声 | ✅ 派单、pin、waypoint、**到场自动标记**、calls 持久化 | ✅ soft/hard cuff、surrender、tackle、雷达、脚环 | ✅ 16 页（记录+人员+车辆+证据+通缉） | ✅ 现场 + MDT charges → 内建/外部 jail | 🟡 无法庭；jailpanel | 合规/投降、搜身对话、Report Link Graph | 到场自动标记、AutoSync 不复制框架表、grade 权限矩阵 | 16 页、CCTV/bodycam/Medal/FiveManage 依赖、闭源 |
| **rcore（dispatch/police/mdt/prison）** | ✅ `/911` `/anon911` `/sos` + switchboard | ✅ 面板接单/拒单/派单 | ✅ radial/context、smart target、cuff/tackle 小游戏 | ✅ incident（9 类字段）、case files、证据板、BOLO | ✅ 报告挂 charges → 自动开罚单 → 送监 | 🟡 无内建法庭；prison 有 prolog/solitary/canteen/break/MDW | 上铐/擒拿小游戏、证据板推理、监狱 prolog | **报告即罚单**、penal code 自动量刑、jail time 仅建议 | 4 个独立产品、prison 9 个装饰特性、自动建表无迁移 |
| **fivenet** | ✅ 游戏内 + Web | ✅ Dispatch Center（接单/拒单/**自动派单**） | 🟡 插件只做桥接 | ✅ Documents（**模板**）/公民/车辆/排班/日历 | ❌ 无游戏内逮捕登记 | 🟡 法庭用 Calendar + 文档承载 | 长文档写作、部门角色扮演 | 模板先行、访问级别、自动派单 | Go+NATS+Postgres+K8s；**每次要出游戏**；26★ |
| **ESX Legacy policejob** | ❌ 靠 esx_phone 转发 | ❌ 无 | ✅ F6 三层菜单（铐/搜/押/罚/路障） | ❌ 全无 | 🟡 上铐 3 步 + 外部 jail；无记录 | ❌ 无 | 全部靠玩家自由发挥 | **`fine_types` 目录**（金额不可能填错）、物理站点入口 | 无记录=累犯不可见；3 层菜单点击多 |
| **社区 SOP（LSPD TR / agencyg）** | — | — | 拦截 6 步、武力 4 级 | 报告写作、法庭文件 | — | 案件 6 态 + 动议 + 保释 | **武力等级与理由**、拦截程序、法庭陈述 | 表单只收 1 句理由，其余靠 SOP | 没有系统支撑就全靠自觉，新人学不会 |

---

## 4. 「流程步数」对比

### 4.1 三个核心动作

| 动作 | 系统 | 最少步数 | UI 切换 | 打字量 | 说明 |
|---|---|---|---|---|---|
| **罚单** | ESX policejob | **5** | 0（同一菜单树） | 0 | F6→公民交互→罚款→类目→条目；金额自动 |
| | 本地 `/fine` | **1** | 0（聊天） | 0 | `/fine <id> <金额>`；**无理由、无记录、无上限** |
| | 本地 MDT 罚单 | **7–9** | 2（手机 + tab） | 1 句 | 4 字段，citizenid 要手打（+2 去查） |
| | ps-mdt | **6–8** ~ | 2（F11 + modal） | 1 句 | charges 内联 |
| | rcore | **3–4** ~ | 1 | 0–1 句 | 预设 + penal code 自动金额 |
| | wasabi | **3–5** ~ | 1 | 0–1 句 | 预设 + grade 权限 |
| **报告** | ESX policejob | **0** | — | — | 不存在 |
| | 本地 MDT | **6–7** | 2 | 1 段 | 手机 → App → tab → 标题 → 正文 → 提交 |
| | ps-mdt | **10–14** ~ | 4 | 1 段 + 逐条关联 | 每个关联都是搜索 + modal |
| | rcore | **8–10** ~ | 1 | 1 段 | 一次提交同时出罚单 |
| | fivenet | **2–3** ~ | 1（但出游戏） | 1 段 | 选模板 + 填字段 |
| **逮捕** | ESX policejob | **4–5** | 0 | 0 | 上铐 3 步 + 外部 jail 命令；无记录 |
| | 本地（含记录 + 入狱） | **11–13** | 3（聊天/qb-input/手机） | 1 句 + 1 数字 | 见 §6 分解 |
| | 本地（只入狱不记录） | **5** | 1（qb-input） | 1 数字 | `/cuff`→`/escort`→`/jail`→填分钟→提交 |
| | ps-mdt（报告 + 外部监狱） | **12–16** ~ | 4 | 1 段 | 报告本身 10–14 步 |
| | rcore（报告 + 送监） | **8–10** ~ | 1–2 | 1 段 | 报告即罚单，少一步 |
| | wasabi | **8–12** ~ | 1–2 | 1 段 | 到场自动标记省 1 步 |

### 4.2 步数预算（建议写进验收）

| 动作 | 预算 | 超出后会发生什么 |
|---|---|---|
| 罚单 | **≤3 步**（人、罪名、可选备注） | 玩家宁可不给罚单，直接用 `/fine` 打字 → 记录丢失 |
| 报告 | **≤3 步 + 1 段打字**（自动带警情/人/罪名，只剩「写正文 → 提交」） | 报告变成「下班前补」→ 内容失真、案件断链 |
| 逮捕（含记录 + 入狱） | **≤6 步** | 玩家跳过登记 → `police_arrests` 空 → 累犯/通缉/法庭全部失效 |
| 一次执法全程 | **≤60 秒**（不含 RP 对话） | 玩家把 RP 时间花在 UI 上，现场变安静 |

> 关键洞察：**rcore 的 8 步逮捕之所以能成立，是因为它把「报告」和「罚单」合并成一次提交**；ps-mdt 的 12–16 步之所以劝退，是因为报告里每加一个人/罪名都是一次搜索 modal。**步数不是问题，「切换」才是问题。**

---

## 5. 过度设计清单（跨系统，带数字）

| 系统 | 过度设计 | 数字 | 48 人服的真实使用率 |
|---|---|---|---|
| ps-mdt | 表 / 权限 / 模块 | 63 表、62 权限、30+ server 模块、8 个 HR 类模块（FTO/IA/PPR/SOP/排行/奖励/法庭日历/民事模式） | 表 1/4 有用；权限大半只挡 UI；HR 模块 ≈ 0 |
| wasabi | 页面 / 依赖 | 16 个核心页 + 建站器 + CCTV + bodycam + 雷达柱 + 脚环 | 常用 ≤6 页；CCTV/bodycam 少数人玩 |
| rcore | 产品拆分 / 监狱特性 | 4 个独立产品；prison 9 个特性（雪茄/食堂/交易商/椅子…） | 监狱只用 jail + break；其余装饰 |
| fivenet | 部署栈 | Go + NATS + Postgres + Docker/K8s + Web 前端 | 运维成本 > 玩法收益 |
| 法庭类（m-CourtSystem / agencyg 示例） | 角色门槛 | 律师考试、法官选举、税务、营业执照（m-CourtSystem）；动议 6 种、保释、量刑指南（agencyg 示例） | 开庭次数 ≈ 0；考试/选举无人参加 |
| 本地 | 入口 | 30 条聊天命令 + 13 tab + 3 套逮捕 + 2 套证据 | 常用命令 ≤8 条（估）；逮捕三套互相打架 |

**规律**：过度设计几乎总是发生在**「记录层」**（表、权限、页面、审批），而**「现场层」**反而功能不足（本地现场只有聊天命令）。精简的正确方向是：**把记录层压到 3 张表 1 个入口，把现场层补 1 个统一菜单。**

---

## 6. T-City 现状：断点与实际步数

### 6.1 五个断点（源码级）

1. **入口断点**：上铐/押运在聊天命令，刑期在 `qb-input`，记录在手机 App —— 一次逮捕要换 3 次焦点。
2. **语义断点**：`/jail` 只写 `injail` metadata（无罪名），MDT 逮捕 tab 只写 `police_arrests`（不入狱），`/arrest` 写 justice 案件（需律师+法官）。**三张表没有一张能回答「这个人为什么在监狱里」。**
3. **罪名断点**：MDT 的 `charges` 是自由文本 `<input>`（[PoliceMDT.svelte:485](../../T-CityLite.base/resources/%5Bcustom%5D/custom-phone/web/src/apps/PoliceMDT.svelte#L485)），而 `Config.Justice.Crimes` 的 13 条罪名目录只被 `/arrest` 使用。
4. **证据断点**：`qb-policejob` 的弹壳/血迹/指纹在服务端内存，MDT 的 `police_evidence` 表是另一套；两者无外键。
5. **法庭断点**：`/startTrial` 要求法官在线、律师在线（`minOnlineForAssignment=1`），任一缺失 → 案件永远 `pending`；没有「认罪协议 / 警长代判」降级路径。

### 6.2 本地「完整逮捕」步数分解（实测代码路径）

| # | 动作 | 入口 | 步数 | 产生什么 |
|---|---|---|---|---|
| 1 | `/cuff` | 聊天 | 1 | 上铐状态（服务端） |
| 2 | `/escort` | 聊天 | 1 | 拖拽 |
| 3 | `/jail` | 聊天 | 1 | 打开 `qb-input` |
| 4 | 输入分钟 + 提交 | `qb-input` | 2 | `prison:client:Enter` |
| 5 | 打开手机 | 键位 | 1 | 手机 UI |
| 6 | 进入 MDT App | 手机 | 1 | MDT |
| 7 | 切「逮捕」tab | MDT | 1 | 表单 |
| 8 | 查 citizenid（人员 tab → 查询 → 抄） | MDT | 2–3 | — |
| 9 | 填 charges（自由文本） | MDT | 1 | — |
| 10 | 填 incident_id / case_id（可空，多数人跳过） | MDT | 0–2 | — |
| 11 | 提交 | MDT | 1 | `police_arrests` 一行 |
| | **合计** | | **11–13** | 监狱有一条记录，`police_arrests` 有一条记录，两者无关 |

**对照**：如果按 §7 方案 B 改造，同一条链可压到 **6 步**（见下）。

---

## 7. 推荐给 T-City 的三个精简方案

> 三案共用前提：**MDT 只保留一个入口**（手机 App，`police_mdt`）；**罚单金额由罪名目录求和**；**报告自动带 incident/时间/警员/坐标**；**qb-prison 是唯一刑期执行器**（与 `DESIGN.md` 的取舍一致）。

### A. 极简（"巡逻 + 开单"，1–2 天可落地）

| 保留 | 砍掉 | 代价 |
|---|---|---|
| 10-8/10-6/10-7；`/911` → incident；派单/前往/到场/清场；人员/车辆查询；**罚单（选罪名 → 金额自动）**；**报告（1 个正文 + 自动关联）**；`/jail` 入狱 | 案件、BOLO、搜查令、证据保管链、审计 UI（只写不读）、法庭、`police_arrests` 表（合并进报告） | 无长线调查、无通缉、累犯不可见；侦探/法官角色不存在；`/arrest` 与 justice 链路要下线（否则又分裂） |

- 表：`police_units / police_incidents / police_incident_units / police_citations / police_reports / police_audit` = **6 张**（现有 12 张，砍 6 张）。
- 指标：罚单 3 步、报告 2 步 + 打字、逮捕 4 步（上铐→押运→入狱→自动生成报告草稿）；单次执法 < 45 秒。
- 适合：现在就想让警察「有记录、不卡流程」。

### B. 平衡（**推荐**，1–2 周）

| 保留 | 砍掉 | 代价 |
|---|---|---|
| A 的全部 + **案件 = 报告上的标签 + 一个 Case 页**（不做独立容器）+ **搜查令（申请/批准一屏）** + **证据 = 报告的附件（label + 1 张图，保管链自动写 1 条）** + **逮捕 = 报告的一种**（charges 求和 → 自动建议刑期 → 可选开庭） | 独立证据板、独立 BOLO 页（改为报告上的 `flag`）、FTO/IA/PPR/SOP、法庭日历、多部门共享矩阵 | 多 1 个审批角色（grade ≥3 批搜查令）；开庭需法官在线，但**缺席时降级为「认罪协议」自动判决**（不卡流程） |

- 表：A 的 6 张 + `police_cases` + `police_warrants` + `police_evidence` = **9 张**（`police_arrests` 合并进 `police_reports`，用 `kind='arrest'` 区分）。
- MDT 页面从 13 个 tab 压到 **5 个**：`Dispatch`（单位/接警/派单）/ `Person`（人车查询 + 前科）/ `Report`（报告 + 罚单 + 证据，一屏三段）/ `Case`（案件 + 搜查令）/ `Me`（状态 + 我的记录）。
- 指标：罚单 3 步、报告 3 步 + 打字、**逮捕 6 步**（上铐→押运→打开 MDT 自动带入→选罪名→提交（入狱+记录）→可选开庭）；UI 切换 ≤1 次。
- 适合：T-City 现在这套代码（P0–P3 已交付，改造是「合并 + 收敛」，不是重写）。

### C. 重扮演（"能上电视"，1–2 个月）

| 保留 | 砍掉 | 代价 |
|---|---|---|
| B 的全部 + **Use of Force 表单**（4 级 + 必填 1 句理由，自动进审计/IA）+ **法庭**（起诉/辩护/判决三屏，判决写 justice）+ **监狱 intake**（prolog + 物品清单 + 权利告知）+ 拦截记录（车牌/时间/结果三选一：警告/罚单/逮捕） | 巡回法庭、动议系统、保释金、律师考试、法官选举、税务 —— 全砍 | 每次逮捕 8–10 步、5–10 分钟；需要法官/律师/警长**同时在线**，否则必须有降级（B 的认罪协议）；开发量大、平衡难调 |

- 表：C = B 的 9 张 + `police_uof_reports` + `police_court_cases` + `police_evidence_chain` = **12 张**。
- 指标：开庭 ≥2 次/周才算成立；UOF 表单填写率 ≥80%（低于此说明步骤太多）。
- 适合：已经有稳定 8+ 警察、1 法官、1 律师的社区；否则先做 B。

### 三案对比

| | 表 | MDT 页 | 罚单步 | 报告步 | 逮捕步 | 在线角色要求 | 风险 |
|---|---|---|---|---|---|---|---|
| A 极简 | 6 | 3 | 3 | 2 | 4 | 警察 | 无长线，玩家会觉得「没内容」 |
| **B 平衡** | 9 | 5 | 3 | 3 | **6** | 警察 + 1 审批 | 审批人不在时会等（已有降级） |
| C 重扮演 | 12 | 7 | 3 | 4 | 8–10 | 警察 + 法官 + 律师 | 角色不在线就卡死；新人学不会 |

---

## 8. 怎么验证「精简没把扮演砍没」

`police_audit` 已经在写 actor/action/target/timestamp，**不需要新埋点**，用 SQL 就能出这四个指标：

| 指标 | 算法 | 目标 | 说明 |
|---|---|---|---|
| 记录覆盖率 | `police_reports` 数 / `police_incidents`（closed）数 | ≥70% | 低于 50% 说明报告太麻烦，玩家在跳过 |
| 罚单有据率 | `police_citations.reason` 非空且 ≥3 字 / 全部罚单 | ≥95% | 剩下 5% 应该是 `/fine` 兼容路径，且应逐步归零 |
| 一次逮捕步数 | `police_audit` 中 `arrest.register` 与最近 `incident.update(on_scene)` 的时间差 + 前端按钮计数 | ≤6 步 / ≤90 秒 | 时间差比步数更好采 |
| 武力记录率 | 有 UOF 记录的逮捕 / 全部逮捕（仅 C 案） | ≥80% | 低于 60% 说明表单太重，应压到 2 个字段 |
| 开庭转化 | `justice` 案件 `sentenced` 数 / `police_arrests` 数 | 5%–15% | 过高说明「什么都要开庭」，过低说明法庭是摆设 |

---

## 9. 参考链接

**源码级（S）/ README 级（S\*）**

- 本地 [custom-police](../../T-CityLite.base/resources/%5Bcustom%5D/custom-police/)：[server/p0.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-police/server/p0.lua)（911 → incident → 通知）、[server/p1.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-police/server/p1.lua)（罚单/报告）、[server/p3_cases.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-police/server/p3_cases.lua)（逮捕登记/案件）、[server/commands.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-police/server/commands.lua)（30 条命令）、[shared/policy.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-police/shared/policy.lua)（21 个 capability）
- 本地 [client/p0.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-police/client/p0.lua)（`/911` `/10-8`）、[client/interactions.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-police/client/interactions.lua)（`/jail` 的 `qb-input`）
- 本地 [PoliceMDT.svelte](../../T-CityLite.base/resources/%5Bcustom%5D/custom-phone/web/src/apps/PoliceMDT.svelte)、[police_mdt.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-phone/server/apps/police_mdt.lua)
- 本地 [custom-justice](../../T-CityLite.base/resources/%5Bcustom%5D/custom-justice/)：[config.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-justice/config.lua)（13 条罪名 + 5 种减刑）、[server/arrest.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-justice/server/arrest.lua)、[server/trial.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-justice/server/trial.lua)、[server/prison.lua](../../T-CityLite.base/resources/%5Bcustom%5D/custom-justice/server/prison.lua)
- [Project Sloth · ps-dispatch](https://github.com/Project-Sloth/ps-dispatch)（README：过滤广播、priority 0–3、critical、合并、坐标偏移、major incident、Plates 日志）
- [Project Sloth · ps-mdt](https://github.com/Project-Sloth/ps-mdt)（README：62 权限、报告/案件/证据/通缉/法庭日历/FTO/IA/PPR、on-site impound 复用表单）
- [ESX-Legacy-Addons · esx_policejob](https://github.com/esx-framework/ESX-Legacy-Addons/tree/main/%5Besx_addons%5D/esx_policejob)（`client/main.lua`：F6 菜单树、`fine_types` 类目、无 MDT）

**文档级（D）**

- [wasabi_mdt](https://docs.wasabiscripts.com/advanced-series/wasabi-mdt/)、[wasabi_police_v2](https://docs.wasabiscripts.com/advanced-series/wasabi-police-v2/)
- [rcore_police](https://documentation.rcore.cz/paid-resources/rcore_police) / [features](https://documentation.rcore.cz/paid-resources/rcore_police/features)
- [rcore_prison](https://documentation.rcore.cz/paid-resources/rcore_prison) / [Prolog](https://documentation.rcore.cz/paid-resources/rcore_prison/features/prolog)
- [rcore_mdt · Incidents and Fines](https://documentation.rcore.cz/paid-resources/rcore_mdt/features/incidents-and-fines)（报告即罚单、penal code 量刑、jail time 仅建议）
- [rcore_dispatch](https://documentation.rcore.cz/paid-resources/rcore_dispatch)
- [FiveNet · Features](https://fivenet.app/getting-started/features)、[FiveNet · Dispatch Center](https://fivenet.app/user-guides/centrum)（正文未取到，仅导航）、[FiveNet README](https://github.com/fivenet-app/fivenet)
- [ox_mdt](https://github.com/overextended/ox_mdt)（原则 7 的「无调度员时警员自管」出处；无源码，README/设计文档级）

**社区流程（R）**

- [LSPD TR · Use of Force Continuum](https://lspd.tr/bloglar/spd-guc-kullanimi-ve-orantili-mudahale-protokolu-use-of-force-continuum)
- [LSPD TR · Traffic Stop 程序](https://lspd.tr/bloglar/trafik-durdurma-traffic-stop-proseduru-ve-yasal-cerceve)
- [Agency Scripts · FiveM Court and Legal System](https://agencyg.de/blog/fivem-court-legal-system)
- [Cfx Forum · m-CourtSystem](https://forum.cfx.re/t/padi-m-courtsystem-the-most-realistic-court-justice-system-for-fivem/5362104)
- [GFX · Improving Police Roleplay Loops](https://gfxscripts.com/blog/fivem-mdt-script-police-ems-dispatch-system-guide)

**本仓库内的证据与设计**

- [research-external.md](research-external.md)：63 表 / 62 权限 / 许可证结论 / 各模组 3 借 3 不借
- [FLOW_INTERNAL.md](FLOW_INTERNAL.md)：本地三链路逐步审计（基线 `4603d4b`）、摩擦清单 F1–F14、断点 B1–B9、落地方案与文件清单
- [audit-current.md](audit-current.md)：判刑断链、零持久化、身份分裂、客户端信任（**早于 P0–P3，结论部分已过期**）
- [DESIGN.md](DESIGN.md)：警情状态机、交通拦截、逮捕 → 登记 → 保释/庭审 → 监狱、MDT 页面清单

---

最值得保留的 3 个强扮演点：**拦停对话（Terry stop 程序）**、**使用武力等级 + 1 句理由**、**报告正文叙事**（三者都是零/低 UI 输入，却撑起 80% 的警察 RP）。
最该砍的 3 个机械步骤：**手打 citizenid**（应自动带入最近/目标玩家）、**手填刑期分钟数与罚款金额**（应由罪名目录求和）、**在 MDT 里逐条 add person/charge 的 modal**（应在报告一屏内完成）。
逮捕最少步数：**6 步**（上铐 → 押运 → 打开 MDT 自动带入 → 选罪名 → 提交（入狱 + 记录）→ 可选开庭）。
罚单最少步数：**3 步**（选人 → 选罪名（金额自动）→ 提交）。
报告最少步数：**3 步 + 1 段打字**（自动带警情/人/时间 → 写正文 → 提交）。
推荐方案：**B（平衡）**。
