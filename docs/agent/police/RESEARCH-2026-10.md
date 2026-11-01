---
id: agent-police-research-2026-10
type: research
status: active
system: justice
owner: hermes
updated: 2026-10-30
review_by: 2027-01-30
supersedes: [agent-police-research-2026-10-v1]
---

# T-City Lite 警察模块调研 v2

> **状态**：调研定稿，**未实现、未提交**。日期 2026-10-29。
> **施工图**：[BLUEPRINT.md](BLUEPRINT.md)（分几个阶段、谁改哪个文件、怎么验收）。
> **本文回答**：做什么、为什么、体验应该长什么样。
> **证据口径**：外部事实附 URL；仓库事实附 `路径:行号`（均为实测，非推断）；标 **建议** 的是设计取舍。
> **历史版本**：v1 存档于同目录 [RESEARCH-2026-10-ARCHIVED.md](RESEARCH-2026-10-ARCHIVED.md)（仅作差异对照，不要照它开工）。

## v2 相对 v1 的改动

| # | 改动 | 原因 |
|---|---|---|
| 1 | AI 支援单位从「不建议」改为**分层 L0–L3，只禁 L4** | 「小服空场时犯罪内容没有对手」是可玩性问题，不是观感问题 |
| 2 | 补上支援单位被打车的**引擎依据**（vehicles.meta flag 31 + 警笛），并给出六条出生配方 | v1 只写了「成本高收益低」，没解释机制 |
| 3 | 建议清单改为**四层收录**（数据 / 动作 / 表面 / Agent） | 扁平清单读不出依赖关系 |
| 4 | 「司法链是死代码**且全内存**」升格为核心结论 | v1 只在审计表里躺了一行，但这是本模块最大的一块已付成本 |
| 5 | 补上**四层资源拆分**的架构结论 | v1 只有优先级表，没说清「谁拥有什么」 |
| 6 | 修掉 v1 的笔误（"五米警察资源"）与其他不一致 | — |

---

## 0. 七个结论

1. **这个服的警察模块是「执法动作齐全、文书与调度全缺」**：能抓、能关、能扣车、能取物证，但没有一个地方写下"刚才发生了什么"。
2. qb-policejob 的所谓 MDT 只是三块 HUD 浮层（CCTV / 直升机 ANPR / 指纹屏），`tablet-frame.png` 是贴图，**没有一条记录查询、没有一页文书**。
3. `custom-justice` 的罪名、律师、减刑、庭审、入狱全写好了，但 `justice:server:registerArrest` **全仓 0 调用方**，而且**数据全在内存里**，重启即清空。整条司法链既没跑过，也存不住。
4. 报案入口有三条（/911p、手机 911、抢劫脚本直发 alert），**出口只有一个 blip**：没有队列、没有优先级、没有"谁接了"、没有"到没到"；自研的 `custom-crime` 一条警情都不发。
5. 所以缺口不是"再加几个功能"，而是**一条从接警到入狱的数据流**。真正要建的是四个资源各管一段：`custom-dispatch`（发生了什么）→ `custom-police`（记下了什么）→ `qb-policejob`（手上能做什么）→ `custom-justice`（怎么判）。
6. 本项目有一个别的服抄不走的抓手：**agent 栈**。AI 调度员（自然语言报案 → 结构化 call 卡）+ 文书起草，天然落在既有的 L2 人审档位。
7. AI 支援单位可以做，但要分层：**AI 只吃无聊的部分（等待、包围、后勤），不碰裁决权**（不逮捕、不对玩家开火、不结案）。

---

## 1. 现状审计（仓库实测）

| 能力 | 现状 | 证据 |
|---|---|---|
| 上手铐 / 押送 / 入狱 / 软铐 / 搜身 | 有（命令 + qb-target 交互，`Config.UseTarget` 开关） | qb-policejob/server/commands.lua:207 cuff、`:217` escort、`:228` jail、`:238` unjail、`:259` sc |
| MDT（人员 / 车辆 / 记录 / 报告 / 通缉） | **没有** | qb-policejob/html/index.html 全文 241 行，body 仅 `#camcontainer` / `#fingerprint` / `#helicontainer`；`tablet-frame.png` 是贴图 |
| 调度（队列 / 应答 / 单位状态） | **没有队列**，只有一次性 blip + 文字 | qb-policejob/server/main.lua:148-176，事件参数仅 `coords, text` |
| 谁在发案 | 抢车、银行、毒品、入室、珠宝、商店、越狱会发；**自研 `custom-crime` 一条都不发** | `T-CityLite.base/resources/[custom]/custom-vehicles/client/main.lua:766`、`archive/qb/qb-bankrobbery/cl_config.lua:37`、`T-CityLite.base/resources/[qb]/qb-drugs/client/cornerselling.lua:33`、`T-CityLite.base/resources/[qb]/qb-houserobbery/client/main.lua:74`、`archive/qb/qb-jewelery/client/main.lua:38`、`T-CityLite.base/resources/[qb]/qb-storerobbery/client/main.lua:598`、`T-CityLite.base/resources/[qb]/qb-prison/client/prisonbreak.lua:110`；`T-CityLite.base/resources/[custom]/custom-crime/server/crime.lua` grep 无 `policeAlert` |
| 报案入口 | /911p 命令；手机 Hotlines（911 / 911-SURR 自首，带排队 IVR） | commands.lua:530；`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Hotlines.svelte:6-8` |
| 罪名 / 刑期 / 律师 / 减刑 / 庭审 | 配置齐全，**链路断开且不持久** | `T-CityLite.base/resources/[custom]/custom-justice/config.lua`（13 项罪名、5 种减刑、律师费模型）；`T-CityLite.base/resources/[custom]/custom-justice/server/arrest.lua:10`（无调用方）；server/main.lua:7,24,64（`activeCases` / `inmates` 全内存） |
| 证据（弹壳 / 血迹 / 指纹） | 有世界物件与清场命令；**无案件绑定、无化验、无保管链** | `T-CityLite.base/resources/[custom]/custom-police/client/evidence.lua:93-168`；commands.lua:314/324/334 |
| 罚单 / 没收 / 执照 | 有命令级实现，无罚则表 UI、无文书 | commands.lua:269 fine、`:249` seizecash、`:10/35/61/86` 执照增删吊恢、`:354` checkid、`:396` checklicense |
| 车库 / 扣押 / ANPR / 追踪器 / 直升机 | 有 | config.lua Locations；`T-CityLite.base/resources/[custom]/custom-police/client/anpr.lua`、`T-CityLite.base/resources/[custom]/custom-police/client/tracker.lua`、`T-CityLite.base/resources/[custom]/custom-police/client/heli.lua` |
| 路障 / 锥桶 / 钉刺带 | 有 | config.lua Config.Objects；commands.lua:122 |
| 无线电 / 频道 | 只有 pma-voice + 手机 FactionChannel（按 role 广播，内存留 50 条）；无 TAC 频道、无 panic | `T-CityLite.base/resources/[custom]/custom-phone/server/faction.lua:5-30` |
| 指挥 / 值班 | 手机 `SheriffApp`「Tactical Command」可下发巡逻指令 + GPS 点；无值班表 / roster / 状态码 | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/leader/SheriffApp.svelte`（226 行） |
| 部门 / 辖区 | 有，已对齐 custom-career（lspd → job police） | qb-policejob/config.lua:15-27；`T-CityLite.base/resources/[custom]/custom-career/configs.lua:23` |
| 等级门禁 | 无（grade 0–4 存在，但不控制工具） | `T-CityLite.base/resources/[qb]/qb-core/shared/jobs.lua`（police：Recruit / Officer / Sergeant / Lieutenant / Chief）；config.lua 仅 `LicenseRank = 2` |
| 审计 | 有现成出口 | `T-CityLite.base/resources/[custom]/custom-logs/server/logs.lua:132` LogGeneric、`:112` LogSecurity |
| 车载中控屏 | 有通用 App 注册 API + 警用控制台（PA / 警笛 / 限速） | `T-CityLite.base/resources/[custom]/custom-vehicles/server/dashboard_api.lua:24`、`:354` |
| 手机 App 注册表 | **还没有**（AGENTS.md 待办 P1） | `T-CityLite.base/resources/[custom]/custom-phone/web/src/App.svelte:1-21` 硬编码 import |
| Agent 动作面 | 18 个动作里无警政动作 | `T-CityLite.base/resources/[custom]/custom-director/server/main.lua` |
| 可直接复用的件（别重建） | 执照状态 → `custom-certificates` 导出；车牌标记 → `plate_flags` 表；呼号 → QBCore metadata；车辆登记 / 文书 → `custom-documents`；截图 → `screenshot-basic` | 各自 `exports(...)` 与 `T-CityLite.base/tests/fixtures/tcity_schema.sql` |

### 1.1 三个致命发现（细节）

**① MDT 是贴图。** html/index.html 241 行全是浮层样式：`#camcontainer`（CCTV）、`#fingerprint`（指纹扫描）、`#helicontainer`（直升机 ANPR）。没有表格、没有查询、没有记录模型。"我们有 MDT"这句话在本服不成立。

**② 司法链既没跑过，也存不住。**
- `justice:server:registerArrest` 跨资源 grep = 0 命中；`justice:server:imprison` 同样没有调用方。
- 架构测试 `T-CityLite.base/tests/architecture_stress_test.lua:337` 对这块的"验证"原文是 *"verified in code review"* —— 只被读过，没被跑过。
- 案卷与刑期都在 `activeCases` / `inmates` 两个内存表里；fxmanifest.lua 声明了 `oxmysql` 却没有任何查询。**重启服务器 = 所有案子消失。**

**③ 有入口没有出口。** 7 个第三方资源在发 `police:server:policeAlert`，7 个发件方共用一个接收方，接收方只做 `TriggerClientEvent` 发 blip。没有 call 表，所以"接了几起、谁接了、到没到、结没结"这四个问题在系统里无解。

---

## 2. 外部调研 A：LSPDFR 生态能搬什么

来源：BejoIjo 系列（Stop The Ped / Ultimate Backup / CompuLite / ALPR Lite / Speed Radar Lite）与 LCPDFR 脚本索引。「裁决」列是本项目取舍。

| # | 灵感 | 它解决什么 | 裁决 | 来源 |
|---|---|---|---|---|
| 1 | 盘查交互菜单（证件 / 搜身 / 酒测 / 药检 / 警告 / 跪下 / 释放） | 盘查全靠语音，新人不知道能做什么 | **值得**（qb-target 已装，做成目标菜单） | bejoijo/stop-the-ped |
| 2 | 交通拦停专用流程（步行接近两侧车门、举停车棒、让司机跟到安全处） | 拦停变尬聊或直接开打 | **值得**（做成对话 + 一张罚单卡，不做独立菜单树） | 同上 |
| 3 | 情境菜单（搜车 / 搜尸 / 叫验尸官 / 拖车 / 封路 / CPR） | 现场收尾全靠管理员 | **值得**，只做 3 项：拖车、验尸、封路 | 同上 |
| 4 | 证据 / 尸体持久化（现场不被引擎刷掉） | 到场时现场已被刷没 | **值得**（成本低、体验差别大） | 同上 |
| 5 | Code 2 / Code 3 语义与"到场待命直到被解散" | 支援单位乱跑 | **值得**：先给玩家单位，AI 支援沿用同一套 | bejoijo/ultimate-backup |
| 6 | 车载电脑 + 平板双入口（查档案、开罚单 / 逮捕报告、看法庭结果） | 文书必须回警局才能做 | **值得**（正是本项目缺的两块屏） | bejoijo/compulite |
| 7 | ALPR 四角扫描 + 命中分级（失窃 / 过期 / 通缉 / 吊销） | 巡逻缺"发现"的乐趣 | **值得**（ANPR 已有，缺告警分级与命中后的拦停流程） | bejoijo/alprlite |
| 8 | 测速雷达四模式 | 超速缺客观依据 | **降级**：只做前向测速 + 超速提示 | bejoijo/speed-radar-lite |
| 9 | GSR / 毒品快检（试剂分阶段：疑似→确认） | 案发现场只剩截图 | **值得**：把"化验"做成延迟产出的案卷条目，天然产出 RP 等待 | lcpdfr evidencesystem / cryptic-evidence |
| 10 | 手持警务电话 + AI 联系人（叫拖车、查赃车、向警长要建议） | 警察要切出游戏查资料 | **重点**：本服已有手机 + TTS 调度 + agent 栈，差异化最大 | lcpdfr 10-21-police-phone |
| 11 | 空中单位（红外 / 探照灯） | 追车缺视野 | **降级 P2**：现有直升机相机加探照灯即可 | lcpdfr air-one |
| 12 | 无线电 16×16 频道皮肤 | 语音频道缺"设备感" | **不建议**：纯皮肤 | lcpdfr apxradio-ui |
| 13 | 支援单位 AI（SWAT / 空中 / 救护） | 人少时缺"到场感" | **有条件值得**：按 §6 分层，只禁 L4 | bejoijo/ultimate-backup |

---

## 3. 外部调研 B：现代 FiveM 警察脚本矩阵

列来源：**ps-mdt** = github.com/Project-Sloth/ps-mdt；**ps-dispatch** = github.com/Project-Sloth/ps-dispatch；**wasabi v2** = docs.wasabiscripts.com/advanced-series/wasabi-police-v2/；**qbx** = github.com/qbox-project/qbx_policejob；**ox_mdt** = github.com/overextended/ox_mdt。

| 能力 | ps-mdt | ps-dispatch | wasabi v2 | qbx | ox_mdt |
|---|---|---|---|---|---|
| MDT | 有（F11 / /mdt，Svelte 5） | 无（调度板） | 有（wasabi_mdt） | 无 | 有（WIP） |
| 调度 | 部分（可应单） | **本体**：优先级 0–3、接单键、看板、major incident | 有（内建 + ps / cd 桥） | 仅 /911p | 有 |
| 证据链 | 有（chain of custody、移交、关联案件） | 无 | 有（chain-of-custody 数据） | 部分（物证袋） | 部分 |
| ANPR / 测速 | 仅查牌 | 手动查牌日志 | radar gun + radar posts | 全图测速雷达 + /flagplate | 无 |
| bodycam | 有（实时画面 + 行车记录仪） | 无 | 有（Medal 录制） | 无 | 无 |
| 罚单 / 保释 | 部分（charges 含罚款刑期） | 无 | 有（billing + 罚金预设） | /fine（5 米内） | 部分 |
| 通缉 / BOLO | 有（跨部门） | 无 | 未记载 | 无 | 有 |
| 分级权限 | 有（62 项按 rank） | 部分（按 grade） | 有（job → 最低 grade） | 无 | 部分 |
| K9 | 无 | 无 | 未记载 | 无 | 无 |

**读法**：ps-mdt 记录与权限最深，ps-dispatch 调度交互最细，wasabi v2 现场设备最全，qbx 轻量命令式几乎无 UI。**保释与 K9 在这五款里都不存在**——不要拿它们当"标配"。

**为什么不能直接装一个进来**：

- 它们都自带一整套记录模型（表 + 权限 + UI），与本服 `custom-justice` 的罪名表、`custom-phone` 的应用层会双写。
- UI 栈不同：多数是 React / NUI 单页，而本服前端是 Svelte 5。
- ps-mdt 是 **Svelte 5 + Lua**，与本服 `custom-phone` 同栈——可以参照它的组件组织与交互，但记录模型要按我们的表写。

---

## 4. 建议新增：按层收录

### 4.1 数据层

新表走 migrations/v*.sql，并同步 `T-CityLite.base/tests/fixtures/tcity_schema.sql`（CI 的 DB schema job 会查）。

| 表 | 作用 | 关键约束 |
|---|---|---|
| `police_calls` | 接警卡（唯一原子） | `ref` 幂等键；精确坐标只留服务端 |
| `police_call_units` | 谁接了、到没到 | `(call_id, citizenid)` 主键 |
| `police_cases` | 案卷（司法链唯一事实源） | `call_id` 可空；`court_status` 回写 |
| `police_case_charges` | 罪名绑定 | `charge_id` 复用 justice 的 key |
| `police_evidence` | 证据条目 | `payload` 存化验结果 / 序列号 |
| `police_evidence_chain` | 保管链 | **append-only**，纠错靠新增行 |
| `police_reports` | 逮捕 / 事件报告 | `draft → submitted` |
| `police_warrants` | 通缉 / BOLO | `wtype` 区分；车辆侧复用 `plate_flags` |
| `police_bodycam` | 事件触发的截图组 | 存 URL 数组，不存视频 |

**不建的表**：`police_charges`（用 justice config）、`police_officers`（呼号 / 值班在 metadata + 内存）、`police_licenses`（用 `custom-certificates` 导出）。
DDL 已在 MariaDB 11.8 实跑两遍（9 表 / 30 索引，幂等通过），细节见蓝图 §4.1。

### 4.2 动作层

| 动作 | 入口 | 现状 |
|---|---|---|
| 接警 / 应答 / 到场 / 结案 | 手机卡片、车载屏 | 新增 |
| 盘查：证件、搜身、酒测、药检、GSR | qb-target 目标菜单 | 新增（`checkid` / `checklicense` 服务端逻辑可复用） |
| 交通拦停：测速 → 靠边 → 罚单 | 车载屏 + 目标菜单 | 半新增（/fine 已有） |
| 逮捕登记 → 案卷 + 通知律师 | 逮捕后自动 | **把死代码接上** |
| 现场服务：拖车、验尸、封路 | 情境菜单（长按 G） | 新增（/pobject、/paytow 已有） |
| 证据采集 → 延迟化验 → 移交 | 世界交互 + 平板 | 半新增（物件已有，缺绑定与链） |
| 通缉 / BOLO 发布与推送 | 平板 → 手机 | 新增 |
| 无线电：TAC 频道、panic、状态码 | 手机 / 快捷键 | 新增（pma-voice 通道已有） |

### 4.3 表面层

三块屏 + 世界，见 §5.3。

### 4.4 Agent 层（本项目独有）

| 能力 | 风险级 | 说明 |
|---|---|---|
| `police.query_case` / `police.query_person` | L1 只读 | agent 回答"昨晚 Mission Row 那起抢劫有哪些证据" |
| AI 调度员：手机自然语言报案 → 结构化 call 卡 | L2 人审 | 解决"新人不会报案"；调度仍由值班人确认 |
| 逮捕报告起草（call + 证据 + 罪名自动填模板） | L2 人审后提交 | 直接对标既有"有界工具循环 + L1/L2 评测"范式 |
| 发布通缉 / 冻结账户 | L3 必须审批 | 走现有 `pending_approval` + admin token |

评测可以接进 `agent_eval.py`：调度分类准确率、优先级误判、报告字段完整率。

---

## 5. UX 设计

### 5.1 call 卡：全模块的唯一原子

```lua
call = {
  id       = 'CALL-1042',
  kind     = 'armed_robbery',
  priority = 1,                  -- 0 危急 / 1 紧急 / 2 常规 / 3 信息
  street   = 'Spanish Ave',
  zone     = 'MissionRow',
  radius   = 80.0,               -- 只下发半径，不下发精确坐标
  suspect  = { desc = '两名男性，黑色面包车', plate = '4ABC123' },
  status   = 'pending',          -- pending → enroute → onscene → cleared
  units    = {},                 -- callsign + 状态
  case_id  = nil,                -- 结案时回填
}
```

三条硬规则：

1. **精确坐标永不下发客户端**，只给 `radius` 内的偏移点（防 meta）。
2. **一个案件只能由 lead 警员结案**；其他人只能"离开"。
3. **priority 0 由主管授予**，不由事件自动累加。

### 5.2 一次出警的八阶段

| 阶段 | 玩家看到什么 | 在哪 | 关键设计 |
|---|---|---|---|
| ① 接警 | 手机震动 + 一张卡：优先级、街区、摘要、车牌样式、地图缩略 | 手机 | 只弹一次，不做滚动播报 |
| ② 出发 | 车机自动显示这条 call、已附着单位、一键导航 | 车载屏 | 上车即聚焦 |
| ③ 到场 | 世界 blip 变"已到场"，手机卡片进"现场"页 | 世界 + 手机 | 服务端按半径 + 停稳 2 秒判定 |
| ④ 盘查 | 准星指向人：查证件 / 搜身 / 酒测 / 药检 / 警告 / 逮捕 | 世界（qb-target） | 一屏一决策，每项结果一行 + 进案卷 |
| ⑤ 逮捕 | 手铐动画 → 押送 → 手机弹"登记罪名" | 世界 + 手机 | 勾选罪名后自动算刑期 / 罚款 |
| ⑥ 文书 | 平板打开报告：罪名已填、证据已附、可补正文 | 平板 | 模板 + 富文本，不要求长篇 |
| ⑦ 结案 | 提交 → 生成案卷号 → 通知律师 / 法庭 | 平板 | 提交即调 justice，触发庭审排期 |
| ⑧ 服刑 | 入狱、减刑、出狱；MDT 能查到最终结果 | qb-prison / justice | 结果回写 `court_status` |

### 5.3 屏幕分工（本设计最核心的一张表）

| 屏幕 | 只放这些 | 明确不放 | 理由 |
|---|---|---|---|
| **手机**（custom-phone App） | 接警卡、应答 / 到场、人车快查、罚单草稿、BOLO 推送、状态码、AI 报案 | 长报告、证据链、权限、视频 | 单手、走路、被打断也能用 |
| **车载中控**（custom-vehicles dashboard app） | 当前 call 终端、测速 / ALPR HUD、车辆追踪、行车记录仪入口 | 全量档案、案件管理 | 驾驶中只能"读一眼" |
| **平板**（新 Svelte 5 应用） | 查询、案件、证据链、报告、通缉、人事 / 权限、审计、法庭日历 | 实时驾驶操作 | 静止、双手、要键盘 |
| **3D 世界** | blip、地面搜索圈、target 提示、动画、语音 | 任何超过两行的文本 | 站在街上读字 = 死 |

推论：**不要**把 MDT 塞进 qb-policejob/html/（jQuery + Vue2 浮层），新开 Svelte 5 应用与手机同栈。

### 5.4 通知纪律（防刷屏）

| 规则 | 数值 |
|---|---|
| 同屏最多 | 3 条 |
| 单条存活 | 5 秒 |
| 同 `kind + zone` 合并窗口 | 90 秒（显示 `×N`） |
| 音效 | 常规 1 声 / 紧急 2 声 / 危急循环但**只在状态变化时** |
| major incident | grade≥2 可宣布；常规呼叫对已附着单位静音，priority 0 / 增援 / 点名**穿透** |
| 静音 | 只影响提示，不影响入库（查牌日志、案卷照常写） |

### 5.5 输入

- 键盘：`E` 交互、长按 `G` 情境菜单、`F11` / /mdt 平板、`O` 看板。
- **不用双击**（多人延迟下不可靠，LSPDFR 的单机做法不能照搬）；用长按或轮盘。
- 手柄：方向键组合，与现有 qb-radialmenu 风格一致。
- 平板搜索框默认聚焦：↑/↓ 选、`Enter` 打开、`Esc` 后退、`Ctrl+Enter` 提交。

### 5.6 视觉与信息密度

- 一屏一个决策；一屏最多一个主按钮。
- 时间 / 日期全模块统一（跟系统区域设置），不要三块屏三种格式。
- 档案页固定三段式：**身份 → 状态（执照 / 通缉 / 前科）→ 最近记录**，不折叠。
- 危急用**重量**表达（粗边框 + 慢脉冲），不是更多红色；`prefers-reduced-motion` 时只留边框。
- 配色沿用 `custom-phone` 的 token，暗色底。

---

## 6. AI 支援单位：分层，不是一刀切

### 6.1 一条必须先知道的引擎事实

GTA 里**没有"让 AI 躲开我"的原生开关**。真正起作用的是 vehicles.meta 的模型 flag（原文见 gtamods 的 `vehicles.meta` 文档）：

| flag | 原文要点 | 含义 |
|---|---|---|
| `FLAG_LAW_ENFORCEMENT` (31) | *"If the vehicle's siren is on, oncoming traffic vehicles will stop."* | **警笛开着 ⇒ 迎面车流停下**，这是唯一一条引擎主动清路的规则 |
| 同上 | *"Peds that are driving cars with this flag will not stop in the event of an accident blocking the road."* | 警车不会为路障停车 → 不会堵在车流里被追尾 |
| 同上 | 轮子脱落率 −50%，爆胎率 30% → 15% | 被蹭也不容易报废（别把它当成"AI 让行"的证据） |
| `FLAG_BIG` (1) | *"Increases the amount of space between traffic vehicles… avoid ramming during chases."* | SUV / 大车天然被让开 |

**推论**：脚本生成的支援单位被打车，九成是两个原因叠加——**警笛没开**（让行规则不触发）和**被塞进原车道里**（AI 只有 0.5–1 秒反应时间）。跟"AI 聪不聪明"无关。

### 6.2 分层

| 层 | 内容 | 抢戏？ | 成本 | 建议 |
|---|---|---|---|---|
| **L0 无线电层** | TTS 调度播报（已有 `systemSpeech`）、单位代号应答、CAD 背景音 | 否，只是声音 | ≈0 | 立刻做，性价比最高的"不空" |
| **L1 布景层** | 站点守卫、巡逻车巡航、封锁线、临检点 | 否 | 3–5 天 | 做 |
| **L2 后勤层** | 验尸官、拖车、法医采样、动物控制 | 否，办完就走 | 1–2 周 | **最推荐** |
| **L3 反应层** | 接警到场：堵路 / 包围、TTS 喊话、掩护射击（仅对敌对 NPC） | 边缘，需权限表 | 2–3 周 | 做，但受 §6.3 约束 |
| **L4 执法层** | AI 独立破案、逮捕玩家、击杀嫌疑人 | **是** | — | **永久禁止** |

### 6.3 L3 的硬约束与出生配方

**硬约束（写进代码，不写进 SOP）**：

1. 永不逮捕玩家——AI 只"控制现场"，逮捕只能由在线警员或系统判定完成。
2. 永不对玩家开火，除非记录到该玩家先开火。
3. 到场 120 秒无人类警员接管 → 自动撤退并销毁。
4. 卡住 10 秒无位移 → 清理重派，最多 3 次。
5. 不结案：无人接管的 call 只能标 `ai_handled`，不入案卷。

**出生配方（缺一条就会被打车）**：

1. 在离现场 **80–150 m** 的路口出生（`GetNthClosestVehicleNodeWithHeading`），**绝不生成在玩家车道内或视野锥里**；
2. `SetEntityAsMissionEntity(veh, true, true)` + `SetVehicleOnGroundProperly`；
3. `SetVehicleSiren(veh, true)`——触发让行的那一下（只想要灯：`SetVehicleHasMutedSirens`，**是否仍触发让行需实机验证**）；
4. `CreatePedInsideVehicle`（不要先建车外再 warp：那一瞬间是空车，还会"坐车顶"）；
5. `SetPedAsCop(ped, true)` + `SetDriverAbility(ped, 0.9)` + `SetDriverAggressiveness(ped, 0.1)`；
6. 驾驶风格固定 **786603**（`DrivingModeStopForVehicles` = 会让车 / 让人 / 等红灯）；禁止 0、262144、以及不含 `StopForVehicles` 的组合。

**三个对照实验（开工第一步，各 60 秒）**：警笛关 vs 开（A）、原版 vs addon 包（B）、车道内 20 m vs 120 m 外（C）。**A 和 C 通常各占一半**；B 只在引入 addon 车辆包后才会出现（本仓库当前无 addon 包，用原版 `police` / `ambulance`，flag 自带）。

### 6.4 技术边界

| 能做 | 做不好 | 根本做不到 |
|---|---|---|
| 生成 ped / 车（`onesync on`）、跟车、堵路、拔枪、TTS 喊话、掩护射击 | 高速追车（`TASK_VEHICLE_CHASE` 会撞会卡）、室内寻路、PIT | qb-target / UI 交互、搜身、罚单、被逮捕、入狱、计费、进案卷 |

所以 AI 支援的价值只在**世界行为**这一段；任何走系统交互的事，仍然必须由玩家或 agent 动作完成。

**两个连带项**（不做等于埋雷）：AI 到场后**抢劫奖励必须重算**（砍到 40%，或改成"人类警员接管才结算"）；**排期必须跟调度总线走**（L3 需要 call 卡才知道去哪）。

---

## 7. 优先级

| 优先级 | 事项 | 为什么 | 成本 |
|---|---|---|---|
| **P0-1** | 接通司法链：逮捕后调 `registerArrest`，案卷落库，结案回写 `court_status` | 现成代码一次没跑过；同时把"重启即清空"治掉 | **0.5–1 天** |
| **P0-2** | 调度总线 `custom-dispatch`：call 表 + 状态机 + 手机卡片 + 车机终端 + blip 纪律 | 没它其余功能没入口；`custom-crime` 现在一条警情都不发 | 1.5–2 周 |
| **P0-3** | 盘查动作层：qb-target 目标菜单 + 服务端复验 + 结果进案卷 | 盘查是核心循环，现在只有"戴手铐" | 1 周 |
| **P0-4** | 平板 MDT 最小可用：人车查询 + 案件 + 报告 + 通缉 / BOLO | 文书是 RP 的产出物，也是 agent 动作的载体 | 2 周 |
| P1 | 证据链 append-only、BOLO 推手机、grade 权限矩阵、照片型 bodycam | — | 各 3 天–1 周 |
| P2 | TAC 频道 / panic、前向测速 + 罚单、站点化、K9 / 现场重建 | — | — |

阶段拆分、依赖、验收标准、测试矩阵见 [BLUEPRINT.md](BLUEPRINT.md) §7。

---

## 8. 不建议做

| 不做 | 理由 |
|---|---|
| AI 独立执法（破案 / 逮捕玩家 / 击杀） | 夺走玩家的戏与裁决权；且 ped 无法做系统交互（§6.4） |
| 完整视频 bodycam | 存储 / 性能差一个数量级；截图流覆盖 80% 的审计需求 |
| 16×16 频道无线电皮肤 | 纯视觉，对 RP 无增益 |
| 多警员实时协同编辑同一份报告（带光标） | 小服一天写不了几份，过度设计 |
| K9 系统作为 P0 / P1 | 五款主流 FiveM 警察资源都没有，使用频率低 |
| 重写 qb-policejob | 物理动作层是它的强项（重写≈两个月白干） |
| 把 MDT 塞进 qb-policejob/html/ | jQuery + Vue2 浮层，会变成第二个技术栈 |
| 替玩家写死 SOP（全套 10-code、100 条罚则） | 系统只提供工具与记录，流程由玩家自定 |

---

## 9. 来源与证据

**外部事实**：bejoijo.com（stop-the-ped / ultimate-backup / compulite / alprlite / speed-radar-lite）；github.com/Project-Sloth/ps-mdt、ps-dispatch；github.com/qbox-project/qbx_policejob；github.com/overextended/ox_mdt；docs.wasabiscripts.com（wasabi-police-v2、wasabi_mdt）；lcpdfr.com 脚本索引及 10-21-police-phone / apxradio-ui / evidencesystem / cryptic-evidence / lspdfr-enhanced-reborn / air-one；gtamods.com/wiki/Vehicles.meta（flag 31 / flag 1 原文）；docs.fivem.net vehicle-flags；github.com/scripthookvdotnet（`VehicleDrivingFlags` 位掩码语义）；ybnlimax.com MDT 对比；docs.sonoransoftware.com/store/bodycam；vicedrip.com/fivem-chain-of-custody-script；oxidestudios.dev/docs/oxide-police；forum.cfx.re（Pickle's Police Job、Realistic Evidence System V2、Officer Job V2、traffic / emergency-vehicle 相关讨论）。

**仓库证据**：qb-policejob/{config.lua,server/*,client/*,html/index.html}、custom-justice/{config.lua,server/main.lua,server/arrest.lua}、`T-CityLite.base/resources/[custom]/custom-crime/server/crime.lua`、custom-phone/{server/faction.lua,web/src/App.svelte,web/src/apps/leader/SheriffApp.svelte,web/src/apps/Hotlines.svelte}、`T-CityLite.base/resources/[custom]/custom-vehicles/server/dashboard_api.lua`、`T-CityLite.base/resources/[custom]/custom-logs/server/logs.lua`、`T-CityLite.base/resources/[custom]/custom-career/configs.lua`、custom-certificates/server/*、`T-CityLite.base/resources/[qb]/qb-core/shared/jobs.lua`、`T-CityLite.base/tests/architecture_stress_test.lua`、`T-CityLite.base/tests/fixtures/tcity_schema.sql`。
