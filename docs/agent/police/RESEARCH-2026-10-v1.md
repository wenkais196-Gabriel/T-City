# T-City Lite 警察模块调研：功能清单 + UX 设计

> 状态：**调研 / 提案**（未实现、未提交）。日期 2026-10-29。
> **施工图在 [BLUEPRINT.md](BLUEPRINT.md)** —— 本文只回答「做什么、为什么」；蓝图回答「分几个阶段、谁来改哪个文件、怎么验收」。
> 分工：外部调研（LSPDFR 生态 + 现代 FiveM 警察资源）= Claude Code 抓 12 页；仓库实测审计 + UX 与优先级裁决 = Hermes。
> 文中 URL 为外部事实来源；`路径:行号` 为仓库实测证据；标 **建议** 的是设计取舍而非既有事实。

---

## 0. 结论摘要

1. **这个服的警察模块是「执法动作齐全、文书与调度全缺」**：能抓、能关、能扣车、能取证物件，但没有任何地方写下"刚才发生了什么"。
2. qb-policejob 的所谓 MDT 只是三块 HUD 浮层（CCTV / 直升机 ANPR / 指纹屏），`tablet-frame.png` 是贴图，**没有一条记录查询、没有一页文书**。
3. `custom-justice` 的罪名表、律师、减刑、庭审、入狱全部写好了，但 `justice:server:registerArrest` **全仓 0 调用方** —— 整条司法链是死代码，一次都没跑过。（`T-CityLite.base/tests/architecture_stress_test.lua:337` 对这块的"验证"原文是 *"verified in code review"*，也就是说它只被读过，没被跑过。）
4. 报案入口有三条（/911p、手机 911 热线、抢劫脚本直发 alert），**出口只有一个 blip**：没有队列、没有优先级、没有"谁接了"、没有"到没到"。
5. 所以真正的缺口不是"再加几个功能"，而是**一条从接警到入狱的数据流**。P0 只有三件事：接警总线、盘查动作、案卷（含把司法链接上）。
6. 本项目有一个别的服没有的抓手：**agent 栈**。AI 调度员（文本报案 → 自动生成 call 卡）+ 文书起草，是这个模块最大的差异化。

---

## 1. 现状审计（仓库实测）

| 能力 | 现状 | 证据 |
|---|---|---|
| 上手铐 / 押送 / 入狱 / 软铐 / 搜身 | 有（命令 + qb-target 交互，`Config.UseTarget` 开关） | qb-policejob/server/commands.lua:207 cuff、`:217` escort、`:228` jail、`:238` unjail、`:259` sc |
| MDT（人员/车辆/记录/报告/通缉） | **没有** | qb-policejob/html/index.html 全文 241 行，body 仅 `#camcontainer` / `#fingerprint` / `#helicontainer` |
| 调度（队列/应答/单位状态） | **没有队列**，只有一次性 blip + 文字 | qb-policejob/server/main.lua:148-176，事件参数仅 `coords, text` |
| 谁在发案 | 抢车、银行、毒品、入室、珠宝、商店、越狱都会发；**自研 `custom-crime` 一条都不发** | `T-CityLite.base/resources/[custom]/custom-vehicles/client/main.lua:766`、`archive/qb/qb-bankrobbery/cl_config.lua:37`、`T-CityLite.base/resources/[qb]/qb-drugs/client/cornerselling.lua:33`、`T-CityLite.base/resources/[qb]/qb-houserobbery/client/main.lua:74`、`archive/qb/qb-jewelery/client/main.lua:38`、`T-CityLite.base/resources/[qb]/qb-storerobbery/client/main.lua:598`、`T-CityLite.base/resources/[qb]/qb-prison/client/prisonbreak.lua:110`；`T-CityLite.base/resources/[custom]/custom-crime/server/crime.lua` grep 无 `policeAlert` |
| 报案入口 | /911p 命令；手机 Hotlines（911 / 911-SURR 自首，带排队 IVR） | commands.lua:530；`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Hotlines.svelte:6-8` |
| 罪名/刑期/律师/减刑/庭审 | 配置齐全，**链路断开** | `T-CityLite.base/resources/[custom]/custom-justice/config.lua`（13 罪名、5 种减刑、律师费）；`T-CityLite.base/resources/[custom]/custom-justice/server/arrest.lua:10`（无调用方） |
| 证据（弹壳/血迹/指纹） | 有世界物件与清场命令；**无案件绑定、无化验、无保管链** | `T-CityLite.base/resources/[custom]/custom-police/client/evidence.lua:93-168`；commands.lua:314/324/334 |
| 罚单/没收/执照 | 有命令级实现，无罚则表 UI、无文书 | commands.lua:269 fine、`:249` seizecash、`:10/35/61/86` 执照增删吊恢、`:354` checkid、`:396` checklicense |
| 车库/扣押/ANPR/追踪器/直升机 | 有 | config.lua Locations；`T-CityLite.base/resources/[custom]/custom-police/client/anpr.lua`、`T-CityLite.base/resources/[custom]/custom-police/client/tracker.lua`、`T-CityLite.base/resources/[custom]/custom-police/client/heli.lua` |
| 路障/锥桶/钉刺带 | 有 | config.lua Config.Objects；commands.lua:122 |
| 无线电/频道 | 只有 pma-voice + 手机 FactionChannel（按 role 广播，内存留 50 条）；无 TAC 频道、无 panic | `T-CityLite.base/resources/[custom]/custom-phone/server/faction.lua:5-30` |
| 指挥/值班 | 手机 `SheriffApp`「Tactical Command」可下发巡逻指令 + GPS 点；无值班表/roster/状态码 | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/leader/SheriffApp.svelte`（226 行） |
| 部门/辖区 | 有，已对齐 custom-career（lspd → job police） | config.lua:15-27；`T-CityLite.base/resources/[custom]/custom-career/configs.lua:23` |
| 等级门禁 | 无 | config.lua 仅 `LicenseRank = 2` |
| 审计 | 有现成出口 | `T-CityLite.base/resources/[custom]/custom-logs/server/logs.lua:132` LogGeneric、`:112` LogSecurity |
| 车载中控屏 | 有通用 App 注册 API + 警用控制台（PA/警笛/限速） | `T-CityLite.base/resources/[custom]/custom-vehicles/server/dashboard_api.lua:24`、`:354` |
| 手机 App 注册表 | **还没有**（AGENTS.md 待办 P1） | `T-CityLite.base/resources/[custom]/custom-phone/web/src/App.svelte:1-21` 硬编码 import |
| Agent 动作面 | 18 个动作里无警政动作 | `T-CityLite.base/resources/[custom]/custom-director/server/main.lua` |

---

## 2. 从离线 mod（LSPDFR 生态）能搬什么

来源：BejoIjo 系列（Stop The Ped / Ultimate Backup / CompuLite / ALPR Lite / Speed Radar Lite）、LCPDFR 脚本索引。
**裁决栏是本项目的取舍**：值得 / 降级 / 不建议。

| # | 灵感 | 它解决什么 | 本项目裁决 | 来源 |
|---|---|---|---|---|
| 1 | 盘查交互菜单（要证件/搜身/酒测/药检/警告/跪下/释放） | 盘查全靠语音，新人不知道能做什么 | **值得**（qb-target 已装，直接做成目标菜单） | bejoijo/stop-the-ped |
| 2 | 交通拦停专用流程（步行接近两侧车门、举停车棒、让司机跟到安全处） | 拦停变尬聊或直接开打 | **值得**（但做成 qb-target 对话 + 一张罚单卡，不做独立菜单树） | 同上 |
| 3 | 情境菜单（G 键：搜车/搜尸/叫验尸官/拖车/封路/CPR） | 现场收尾全靠管理员 | **值得**（现场服务 3 项就够：拖车、验尸、封路） | 同上 |
| 4 | 证据持久化（尸体/空车不被引擎刷掉） | 到场时现场已被刷没 | **值得**（成本低，体验差别巨大） | 同上 |
| 5 | Code 2 / Code 3 语义与"到场待命直到被解散" | 支援单位乱跑 | **降级**：人是玩家，只保留语义标签（救援/紧急），不做 AI 单位 | bejoijo/ultimate-backup |
| 6 | 车载电脑 + 平板双入口（车内查档案、开罚单/逮捕报告、看法庭结果） | 文书必须回警局 | **值得**（正是本项目缺的两块屏） | bejoijo/compulite |
| 7 | ALPR 四角扫描 + 命中分级（失窃/过期/通缉/吊销） | 巡逻缺"发现"的乐趣 | **值得**（ANPR 已有，缺告警分级与命中后的拦停流程） | bejoijo/alprlite |
| 8 | 测速雷达四模式（Auto/Front/Left/Rear） | 超速缺客观依据 | **值得（小）**：只做"前向测速 + 超速提示"，不做四方向 | bejoijo/speed-radar-lite |
| 9 | GSR / 毒品快检（试剂分阶段：疑似→确认） | 案发现场只剩截图 | **值得**：把"化验"做成时间延迟的案卷条目，天然产出 RP 等待 | lcpdfr evidencesystem / cryptic-evidence |
| 10 | 手持警务电话 + AI 联系人（10-21 插件：叫拖车、查赃车、向警长要建议） | 警察要切出游戏查资料 | **重点**：本项目已有手机 + TTS 调度 + agent 栈，这是差异化最大的一项 | lcpdfr 10-21-police-phone |
| 11 | 空中单位（红外/探照灯） | 追车缺视野 | **降级 P2**：现有直升机相机加探照灯即可 | lcpdfr air-one |
| 12 | 无线电 16×16 频道皮肤 | 语音频道缺"设备感" | **不建议**：纯皮肤，RP 收益低 | lcpdfr apxradio-ui |
| 13 | 支援单位 AI（SWAT/空中/救护） | 人少时缺"到场感" | **不建议**：本服单位就是玩家，AI 单位会抢玩家戏份 | 同上 |

---

## 3. 现代 FiveM 警察脚本功能矩阵（外部事实）

列来源：**ps-mdt** = github.com/Project-Sloth/ps-mdt；**ps-dispatch** = github.com/Project-Sloth/ps-dispatch；**wasabi v2** = docs.wasabiscripts.com/advanced-series/wasabi-police-v2/；**qbx** = github.com/qbox-project/qbx_policejob；**ox_mdt** = github.com/overextended/ox_mdt。

| 能力 | ps-mdt | ps-dispatch | wasabi v2 | qbx | ox_mdt |
|---|---|---|---|---|---|
| MDT | 有（F11//mdt，Svelte 5） | 无（调度板） | 有（wasabi_mdt） | 无 | 有（WIP） |
| 调度 | 部分（可应单） | **本体**：优先级 0-3、接单键、看板、major incident | 有（内建 + ps/cd 桥） | 仅 /911p | 有 |
| 证据链 | 有（chain of custody、移交、关联案件） | 无 | 有（chain-of-custody 数据） | 部分（物证袋） | 部分 |
| ANPR/测速 | 仅查牌 | 手动查牌日志 | radar gun + radar posts | 全图测速雷达 + /flagplate | 无 |
| bodycam | 有（实时画面 + 行车记录仪） | 无 | 有（Medal 录制） | 无 | 无 |
| 罚单/保释 | 部分（charges 含罚款刑期） | 无 | 有（billing + 罚金预设） | /fine（5 米内） | 部分 |
| 通缉/BOLO | 有（跨部门） | 无 | 未记载 | 无 | 有 |
| 分级权限 | 有（62 项按 rank） | 部分（按 grade） | 有（job→最低 grade） | 无 | 部分 |
| K9 | 无 | 无 | 未记载 | 无 | 无 |

读法：**ps-mdt 记录与权限最深，ps-dispatch 调度交互最细，wasabi v2 现场设备最全，qbx 轻量命令式几乎无 UI**。保释五款都没有。K9 在这五个资源里都不存在——不要拿它当"标配"。

> 一个直接的工程便利：ps-mdt 是 **Svelte 5 + Lua**，和本项目 `custom-phone` 前端同栈（Svelte 5 + Vite）。它的组件组织与交互可以参照，但记录模型要按我们的表来写。

---

## 4. 建议新增的功能（按层，不是按清单）

### 4.1 数据层（新表，全部走 migrations/v*.sql + `T-CityLite.base/tests/fixtures/tcity_schema.sql`）

| 表 | 关键列 | 说明 |
|---|---|---|
| `police_calls` | id, type, priority, street, zone, x/y/z, radius, suspect_cid, plate, status, created_at, closed_at | 一个 call 卡 = 最小单元 |
| `police_call_units` | call_id, citizenid, callsign, status(attached/enroute/onscene/cleared) | 谁接了、到没到 |
| `police_cases` | case_id, title, summary, lead_cid, status(open/closed), court_status | 案卷 |
| `police_case_charges` | case_id, charge_id, fine, minutes | 复用 `custom-justice` 的罪名 id，不另建罚则表 |
| `police_evidence` | id, case_id, kind, payload(json), collected_by, coords, created_at | 世界证据与案卷绑定 |
| `police_evidence_chain` | evidence_id, action(collect/transfer/test/present), actor, at, note | **append-only**，改错靠新增行 |
| `police_reports` | id, case_id, author, body, submitted_at | 逮捕/事件报告 |
| `police_warrants` / `police_bolo` | id, cid/plate, reason, expires_at, issued_by | 通缉 / BOLO |

### 4.2 动作层（能做的事）

| 动作 | 入口 | 现状 |
|---|---|---|
| 接警 / 应答 / 到场 / 结案 | 手机卡片、车载屏、指令 | 新增 |
| 盘查：查证件、搜身、酒测、药检、GSR | qb-target 目标菜单 | 新增（`checkid`/`checklicense` 已有服务端逻辑可复用） |
| 交通拦停：测速 → 靠边 → 罚单 | 车载屏 + 目标菜单 | 半新增（/fine 已有） |
| 逮捕登记 → 案卷 + 通知律师 | 逮捕后自动 | **把死代码接上**：调 `justice:server:registerArrest` |
| 现场服务：拖车、验尸、封路 | 情境菜单（长按 G） | 新增（/pobject、`paytow` 已有） |
| 证据采集 → 化验（延迟结果）→ 移交 | 世界交互 + 平板 | 半新增（物件已有，缺绑定与链） |
| 通缉 / BOLO 发布与推送 | 平板 → 手机推送 | 新增 |
| 无线电：TAC 频道、panic、状态码 | 手机 / 快捷键 | 新增（pma-voice 通道已有） |

### 4.3 表面层（三块屏 + 世界）

见 §5.3。

### 4.4 Agent 层（本项目独有）

| 能力 | 风险级 | 说明 |
|---|---|---|
| `police.query_case` / `police.query_person` | L1 只读 | agent 回答"昨晚 Mission Row 那起抢劫有哪些证据" |
| AI 调度员：手机文本报案 → 自动生成 call 卡（类型/优先级/街区/涉案描述） | L1/L2 | 玩家不必打字就能报案；调度仍由人（Sheriff 角色）确认 |
| 逮捕报告起草（把 call + 证据 + 罪名自动填模板） | L2 人审后提交 | 直接对标本项目"有界工具循环 + L1/L2 评测"的既有范式 |
| 发布通缉 / 冻结账户 | L3 必须人审 | 走现有 `pending_approval` + admin token |

---

## 5. UX 设计

### 5.1 call 卡：全模块的唯一原子

```lua
call = {
  id = 'CALL-1042',
  type = 'armed_robbery',        -- 来自罪名/事件类型表
  priority = 1,                  -- 0 危急 / 1 紧急 / 2 常规 / 3 信息
  street = 'Spanish Ave',
  zone = 'MissionRow',
  radius = 80.0,                 -- 只下发半径，不下发精确坐标
  suspect = { cid = nil, desc = '两名男性，黑色面包车', plate = '4ABC123' },
  status = 'pending',            -- pending → enroute → onscene → cleared
  units = {},                    -- callsign + 状态
  case_id = nil,                 -- 结案时回填
}
```

三条硬规则（**建议**）：
- **精确坐标永不下发到客户端**，只给 `radius` 内的偏移点（照 ps-dispatch 的做法，防 meta）。
- **一个案件只能由 lead 警员结案**，其他人只能"离开"。
- **priority 0 由主管授予**，不由事件自动累加。

### 5.2 一次出警的完整体验

| 阶段 | 玩家看到什么 | 在哪 | 关键设计 |
|---|---|---|---|
| ① 接警 | 手机震动 + 一张卡：优先级、街区、报案摘要、车牌样式、地图缩略 | 手机 | 只有一次弹窗，不做滚动播报 |
| ② 出发 | 车机自动显示这条 call、已附着单位、一键导航 | 车载屏 | 上车即聚焦，不用手动切 |
| ③ 到场 | 世界 blip 变"已到场"，手机卡片自动进入"现场"页 | 世界 + 手机 | 自动判定（进入 radius + 停稳 2 秒） |
| ④ 盘查 | 准星指向人：查证件 / 搜身 / 酒测 / 药检 / 警告 / 逮捕 | 世界（qb-target） | 一屏一决策，每项结果一行文字 + 进案卷 |
| ⑤ 逮捕 | 手铐动画 → 押送 → 手机自动弹出"登记罪名"页 | 世界 + 手机 | 罪名勾选后自动算刑期/罚款并显示 |
| ⑥ 文书 | 平板打开报告：罪名已填、证据已附、可补正文 | 平板 | 模板 + 富文本，不要求长篇 |
| ⑦ 结案 | 平板提交 → 系统生成案卷号 → 通知律师/法庭 | 平板 | 提交即调 justice，触发庭审排期 |
| ⑧ 服刑/后续 | 入狱、减刑、出狱；MDT 里能查到这条案卷的最终结果 | qb-prison / custom-justice | 结果回写 `police_cases.court_status` |

### 5.3 屏幕分工（这是本设计最核心的一张表）

| 屏幕 | 只放这些 | 明确不放 | 理由 |
|---|---|---|---|
| **手机**（custom-phone App） | 接警卡、应答/到场、人车快查、罚单草稿、BOLO 推送、状态码切换、AI 报案 | 长报告、证据链编辑、权限、视频 | 单手、走路、被打断时也能用 |
| **车载中控**（custom-vehicles dashboard app） | 当前 call 终端、测速/ALPR HUD、车辆状态与追踪、行车记录仪入口 | 全量档案、案件管理 | 驾驶中只能"读一眼" |
| **平板 NUI**（新 Svelte 应用） | 记录查询、案件、证据链、通缉/BOLO、人事与权限、审计、法庭日历 | 实时驾驶操作 | 静止、双手、需要键盘 |
| **3D 世界** | blip、地面搜索圈、target 提示、手铐/搜查动画、语音 | 任何超过两行的文本 | 站在街上读字=死 |

推论（**建议**）：**不要**把 MDT 塞进 qb-policejob/html/（那里是 jQuery + Vue 2 的 HUD，15KB 全是浮层），新开一个 Svelte 5 应用，与手机同栈，共享组件与设计 token。

### 5.4 通知纪律（防刷屏）

- 同时最多 3 条 call 提示，单条 5 秒；同一 `type + zone` 在 90 秒内合并为一条（显示"×3"）。
- 三档音效：常规一声、紧急两声、危急循环但只在**状态变化**时再响。
- 危急用**重量**表达（更粗的边框 + 慢脉冲），不是"更多红色"；尊重 reduced-motion 时只留边框。
- 主管可宣布 major incident：常规呼叫对已附着单位静音，但 priority 0、增援请求、点名呼叫**永远穿透**。
- 静音只针对屏幕噪音，**不影响入库**：查牌日志、案卷照常记录。

### 5.5 输入

- 键盘：`E` 交互、长按 `G` 情境菜单、`F11`//mdt 平板、`O` 看板。
- **不用双击触发**（网络延迟下不可靠，这是 LSPDFR 在单机的做法不可照搬的地方）；用长按或轮盘。
- 手柄：方向键组合（`DPadLeft + A` 情境、`DPadUp` 追捕、`DPadRight` 解散），与现有 qb-radialmenu 风格保持一致。
- 平板里的搜索框默认聚焦，↑/↓ 选记录、`Enter` 打开、`Esc` 后退——不需要鼠标。

### 5.6 视觉与信息密度

- 一屏一个决策；同一屏最多一个主按钮。
- 时间/日期格式全模块统一（跟系统区域设置），不要三块屏三种格式。
- 档案页固定三段式：**身份 → 状态（执照/通缉/前科）→ 最近记录**，不折叠。
- 证据用"类型图标 + 采集人 + 时间"，缩略图只在平板里出现（手机装不下）。

---

## 6. 优先级与落地路径

| 优先级 | 事项 | 为什么先做 | 改动面 | 成本 | 验收标准 |
|---|---|---|---|---|---|
| **P0-1** | **接通司法链**：逮捕后调 `justice:server:registerArrest`，结案回写 `court_status` | 现成代码一次没跑过；半天就能让律师/减刑/庭审/入狱全部活过来 | `qb-policejob` + `custom-justice`（后者几乎不用改） | **小（0.5–1 天）** | 逮捕→律师收到通知→庭审→入狱→案卷显示结果 |
| **P0-2** | **调度总线 `custom-dispatch`**：call 表 + 状态机 + 事件入口（qb-policejob / custom-crime / 各抢劫脚本）+ 手机卡片 + 车机终端 + blip 纪律 | 没有它，其余功能没有入口；`custom-crime` 现在一条 alert 都不发 | 新资源 + 手机新增 1 个 App + 车机 1 个 App；旧事件保留 shim | **中（1.5–2 周）** | 一次抢劫 → 手机/车机同时收到同一张卡 → 两人接单 → 到场自动翻转 |
| **P0-3** | **盘查动作层**：qb-target 目标菜单（证件/搜身/酒测/药检/GSR/逮捕）+ 服务端复验 + 结果进案卷 | 盘查是核心循环，现在只有"戴手铐" | qb-policejob/client + `server` | **中（1 周）** | 每个动作有动画/进度条/服务端校验，结果写入 `police_evidence` |
| **P0-4** | **平板 MDT 最小可用**：人车查询 + 案件 + 逮捕报告 + 通缉/BOLO | "文书"是 RP 的产出物，也是 agent 动作的载体 | 新 Svelte 5 应用 + 新表迁移 + 权限 | **中（2 周）** | 能在平板里完成"查人 → 立案 → 写报告 → 发通缉"全流程 |
| **P1-1** | 证据链：世界证据绑定 case + append-only 移交 + 延迟化验结果 | 没链的 MDT 只是记事本 | `police_evidence*` 表 + 平板视图 | 中（1–1.5 周） | 一件证据可查完整时间线，改错以新条目体现 |
| **P1-2** | BOLO/通缉推手机 + 状态码/Callsign 看板 | 让离线警员被拉回现场 | `custom-phone` + Roster | 小（3–4 天） | 手机关机也能收到 BOLO；看板显示 10-8/10-6/10-7 |
| **P1-3** | 分级权限矩阵（grade → 工具/查询/立案/发通缉） | 小服靠信任，但 agent 动作必须可审计 | `qb-policejob` + 平板 | 小（3 天） | 每个平板动作服务端校验 grade，越权写 `agent_denials` 同类审计 |
| **P1-4** | 照片型 bodycam（事件触发生图，不录视频） | `screenshot-basic` 已装，成本远低于视频录制 | 新模块 + 存储 + 平板回放 | 中（1 周） | 开枪/被击倒/panic 自动抓 3 张图并挂到案卷 |
| **P2-1** | 无线电语义：TAC 频道、panic 键、频道纪律 | 提升协同感，非阻塞 | `custom-phone` + pma-voice | 小（3 天） | panic 触发一次全局高优 call 卡 |
| **P2-2** | 交通：前向测速 + 罚单模板 + 驾照罚点 | 交通组目前只有 /fine | `qb-policejob` + 车机 | 中（1 周） | 超速 → 拦停 → 罚单 → 执照扣分可查 |
| **P2-3** | 站点化：更衣室/军械库按 grade、站点面板 | 仪式感，非阻塞 | `qb-policejob` | 中（1–2 周） | 配置驱动，加站点不改代码 |
| **P2-4** | K9 / 现场重建（把案件证据在 3D 里重放） | 叙事价值高、频率低 | 新模块 | 大（3 周+） | — |

**建议的落地顺序**：P0-1（半天，先把死链救活，立刻能看到 RP 效果）→ P0-2 → P0-3 → P0-4。P0-1 单独做成一个 PR，风险最低、演示效果最好。

---

## 7. 明确不建议做的

| 项 | 理由 |
|---|---|
| AI 支援单位 / 伙伴（Code 2-3 自动到场） | 本服 10–30 人，单位就是玩家；AI 单位会抢戏，且要在 FiveM 里实现可靠的寻路与交火，成本高收益低 |
| 完整视频 bodycam（录制/存储/回放） | 存储与性能代价大；用"事件触发生图"覆盖 80% 的审计需求 |
| 16×16 频道无线电皮肤 | 纯视觉，对 RP 无增益 |
| 多警员实时协同编辑同一份报告（带光标） | 小服一天写不了几份报告，是过度设计 |
| K9 系统（作为 P0/P1） | 五款主流五米警察资源都没有；叙事价值高但使用频率低 |
| 把 MDT 塞进 qb-policejob/html/ | 那里是 jQuery+Vue2 的 HUD 浮层，扩成 MDT 会变成第二个技术栈；新开 Svelte 5 应用与手机同栈 |
| 替玩家写死 SOP（10-code 全套、罚则 100 条） | 小服由玩家自定规程更好；系统只提供**工具**与**记录**，不规定流程 |

---

## 8. 与 agent 栈的结合（差异化）

- 现有约束照旧：L1 只读、L2 人审后写、L3/L4 必须 admin 审批，拒绝写 `agent_denials`，效果写 `agent_effects`。
- 新增动作建议：`police.query_case`、`police.query_person`、`police.draft_report`（L2）、`police.issue_warrant`（L3）。
- **AI 调度员**是最值得做的一项：玩家在手机里用自然语言报案 → agent 生成结构化的 call 卡（类型/优先级/街区/涉案描述）→ 由值班 Sheriff 一键确认。这既解决了"新人不会报案"，也天然落在 L2（人审）档位，并把 `tools/agent_tools.json` 的"唯一事实源"扩展到警政域。
- 演练与评测可以接进 `agent_eval.py`：调度分类准确率、优先级误判、报告起草的字段完整率。

---

## 9. 来源

**外部**：bejoijo.com（stop-the-ped / ultimate-backup / compulite / alprlite / speed-radar-lite）；github.com/Project-Sloth/ps-mdt、ps-dispatch；github.com/qbox-project/qbx_policejob；github.com/overextended/ox_mdt；docs.wasabiscripts.com（wasabi-police-v2、wasabi_mdt）；lcpdfr.com 脚本索引及 10-21-police-phone / apxradio-ui / evidencesystem / cryptic-evidence / lspdfr-enhanced-reborn / air-one；ybnlimax.com MDT 对比；docs.sonoransoftware.com/store/bodycam；vicedrip.com/fivem-chain-of-custody-script；oxidestudios.dev/docs/oxide-police；forum.cfx.re（Pickle's Police Job、Realistic Evidence System V2、Officer Job V2）。

**仓库内**：qb-policejob/{config.lua,server/*,client/*,html/index.html}、custom-justice/{config.lua,server/arrest.lua,prison.lua}、`T-CityLite.base/resources/[custom]/custom-crime/server/crime.lua`、custom-phone/{server/faction.lua,web/src/App.svelte,web/src/apps/leader/SheriffApp.svelte,web/src/apps/Hotlines.svelte}、`T-CityLite.base/resources/[custom]/custom-vehicles/server/dashboard_api.lua`、`T-CityLite.base/resources/[custom]/custom-logs/server/logs.lua`、`T-CityLite.base/resources/[custom]/custom-career/configs.lua`、`T-CityLite.base/resources/[custom]/custom-director/server/main.lua`。
