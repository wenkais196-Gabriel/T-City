---
id: ux-police
type: manual
status: draft
system: justice
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

# 警务 · UX 设计

> 状态 **draft**：目前只完成 §1 调研（数字均为实测扫描）。§2/§3/§4 待设计。
> 工作流见 [00-workflow.md](../00-workflow.md)。

## 1. 调研（现状）

### 1.1 触点规模（实测）

| 资源 | 通知类调用 | 交互热区 | 命令 |
|---|---|---|---|
| `custom-police` | 195 | 6 | 56 |
| `custom-justice` | 43 | 0 | 7 |

### 1.1b 通知最密集的文件（谁在吵）

| 文件 | 通知类调用 |
|---|---|
| `T-CityLite.base/resources/[custom]/custom-police/server/commands.lua` | **75** |
| `T-CityLite.base/resources/[custom]/custom-police/client/job.lua` | 19 |
| `T-CityLite.base/resources/[custom]/custom-police/server/vehicle.lua` | 18 |
| `T-CityLite.base/resources/[custom]/custom-police/client/interactions.lua` | 18 |
| `T-CityLite.base/resources/[custom]/custom-police/server/interactions.lua` | 14 |

> 75 处集中在 commands.lua：绝大多数是**命令执行回执**（改职级、改车牌、发罚单…），
> 这类不该上屏幕，应该进"操作回执"的独立通道或日志。这是本次降噪的主战场。

### 1.2 玩家会卡住的场景
| # | 场景 | 现在 |
|---|---|---|
| 1 | 站在尸体旁想验尸 | 要按 **ALT** 才出「叫验尸官」，按 E 没反应（真机已复现） |
| 2 | 一名值班警察每分钟收到的通知 | `custom-police` 有 **195 处**通知调用，全部走同一条通道 → 真正重要的报警会被淹没 |
| 3 | 打开 MDT 但没数据 | 空页/空白列表，没有"暂无案件"的文案 |

### 1.3 外部实践（我的调研，2026-11-11）

| 来源 | 关键做法 | 对我们的意义 |
|---|---|---|
| `ps-mdt` v3（331★，QBCore） | 一屏涵盖 citizens / reports / cases / evidence / warrants / BOLOs / vehicles / **dispatch** / department，按警衔分权；`F11` 或 `/mdt` 打开 | 我们是手机里的 `police_mdt`（dispatch/person/report/case/me 五页），结构接近，**不必重做信息架构** |
| codem「BLVCK MDT」设计文 | 常见失败模式是"警情在 dispatch 系统、记录在 MDT 系统、两套 DB 互不相认"，于是"出警记录查不到案号"；他们的解法是 dispatch + 记录 + 证据**同库互引** | 我们已经是同库互引（`Unit.incident_id`、报案表单带 `incident_id` / `case_id`），**这一点不用改**；要补的是"接到报警 → 到现场 → 结案"这条链上的**回执** |
| `roclicks` 反馈模式（游戏 UI 实践） | toast 短 3–4s / 长 6s；**相同文案去重并重启计时**；突发多条目**合并成一条带累计**；栈上限约 4；文案 ≤40 字符、一个动词；位置要避开准星与关闭按钮 | 直接可用的 4 条规则：去重、合并、上限、限长。我们现在的 `custom-notify` 有上限（feed 4 / toast 2），**缺去重与合并** |
| Smart Interface Design Patterns（通知 UX 指南） | 大多数通知**根本不该是通知**；"状态指示 / 校验反馈 / 通知"三者要分清，否则疲劳后玩家一律无视 | 对应我们的四通道：常驻状态走 HUD 圆环（不弹），校验反馈走 `error`，真事件才走 `feed`/`toast` |

**外部结论三条**（写进设计阶段的约束）：

1. **不要把状态做成通知**：饥饿 29% 应该是 HUD 圆环的颜色，不是一条 feed；
2. **同文案去重 + 突发合并**：报警雪崩时必须合成一条"3 起新警情"而不是三条；
3. **MDT 的信息架构别动**：我们已有 dispatch/person/report/case/me 且与警情同库互引，
   改动集中在"报警怎么进来、处理完怎么回执"。

> CC 的同题调研（外部 + 仓库 195 处通知归类）正在跑，回来后与本表一起进 §2 设计。

### 1.4 CC 调研补充（2026-11-11）

| 产品 | 首屏答什么 | 分级做法 |
|---|---|---|
| `ps-mdt` | 在勤单位 / 新单 / 我的状态；档案文书退二级 | 自身不分级，调度继承 `ps-dispatch` |
| `aty_mdt` | 个人状态、Active Units（10s 刷新）、Recent Dispatches（≤50） | **无 priority 字段**，只在打开的 MDT 里进列表，无声音无弹窗 |
| `ps-dispatch` | 右侧警报栈（5s、最多 3 条）+ `O` 键调度板（≤25） | **P0 critical / P1 urgent / P2 routine / P3 low**；critical 置顶 + 粗边 + 脉冲；重大事件时 routine 静音，P1/求援/点名仍达 |

**仓库归类（199 处命中）**：

| 档 | 来源 | 例子 |
|---|---|---|
| 必须屏幕 | `T-CityLite.base/resources/[custom]/custom-police/client/main.lua`、`T-CityLite.base/resources/[custom]/custom-police/client/coroner.lua`、`T-CityLite.base/resources/[custom]/custom-police/client/incident_guidance.lua`、`T-CityLite.base/resources/[custom]/custom-police/server/p4_npc.lua` | `client/main.lua:162` 新警情（Notify+声音+blip，已有） |
| 可以 feed | `T-CityLite.base/resources/[custom]/custom-police/server/commands.lua`(77)、`T-CityLite.base/resources/[custom]/custom-police/server/interactions.lua`、`T-CityLite.base/resources/[custom]/custom-police/server/vehicle.lua`、`T-CityLite.base/resources/[custom]/custom-police/client/job.lua` | `server/commands.lua:23` 发执照；`server/vehicle.lua:146` 车辆标记 |
| 只进手机/日志 | `T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua`、`T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua`、`T-CityLite.base/resources/[custom]/custom-police/client/backup.lua`、`PoliceMDT.svelte` | `server/p2_system.lua:32` BOLO 只推手机 |

**发现的零反馈缺口**：`client/coroner.lua:235` 的 target action 只发事件，
`server/coroner.lua:75/83` 静默 `return` —— 成功与失败**都没有任何反馈**，
这正是"按 E 没反应"的体感来源。

## 2. 设计（目标）

> 综合两份 R 阶段调研：我的外部实践（§1.3）+ CC 的产品对照与仓库归类（见 §1.4）。
> 规则都能落成 if/else，不接受"视情况"。

### 2.1 警情分级（引入 P0–P3，照抄 ps-dispatch 的语义）

| 级别 | 判定（if 就能写） | 表现 |
|---|---|---|
| **P0** | 警员倒地 / 主动求援 / 银行劫案进行中 | `toast` + 声音 + 地图 blip + 手机留痕 |
| **P1** | 枪击、重伤、持械、正在进行的重罪 | `toast` + 声音 + blip |
| **P2** | 一般 911（噪音、违停、纠纷） | `feed` + MDT 列表 |
| **P3** | 事后上报、路人报告 | 只进 MDT 列表 |

**去重与合并**：同一 `code` + 同一区域 60 秒内重复 → 合并为一条，标题带 `×N`；
P2/P3 在 P0 进行中**静音**（只进列表），P0/P1 永不静音。

### 2.2 警员操作的回执（谁该看到什么）

| 动作 | 执行者看到 | 当事人看到 |
|---|---|---|
| 发罚单 / 扣押 / 入狱 | `feed` 一行（金额/时长） | `phone` 通知（可回查） |
| 发执照 / 改职级 / 改车牌 | `feed` 一行 | `phone` 一行 |
| 命令执行失败（权限/距离/离线） | `error` 左下红 | — |
| 新警情（P0/P1） | `toast` + 声音 | — |
| 警情被接手/到场/结案 | `feed` 一行 | — |

**铁律**：命令执行回执**不许**再上屏幕中央（现在 77 处全在 `commands.lua`）。

### 2.3 验尸官 / 尸体交互（修零反馈）

| 情形 | 表现 |
|---|---|
| 靠近尸体 | `prompt`：`[E] 呼叫验尸官` |
| 呼叫成功 | `feed`："验尸官已在路上（约 2 分钟）" |
| 附近没有尸体 | `error`："附近没有尸体" |
| 已在处理中 | `error`："这具尸体已经有人处理了" |

### 2.4 空态

| 情形 | 表现 |
|---|---|
| MDT 无警情 | "当前没有进行中的警情"（不是空白） |
| MDT 无在勤单位 | "暂无在勤单位" + 提示"按 E 上班" |
| 手机未连接 | 页内："连接中…"（不许空白页） |

## 3. 计划（任务）

> 分工：**我开发（P）**，CC 定验收标准（V，见 §4）。

| # | 任务 | 文件 | 风险 | 验收方式 |
|---|---|---|---|---|
| P-1 ✅(`2d96b89b`) | `custom-notify` 加去重 + 合并：同 kind+title 3 秒内重复重启计时并显示 ×N；同来源突发 20 秒内合并 | `T-CityLite.base/resources/[custom]/custom-notify/server/main.lua` | 低（纯服务端） | 连发 3 条同文案只出现 1 条带 ×3 |
| P-2 ✅(`61af6cb2`) | 验尸官零反馈修复：成功 feed / 无尸体 error / 处理中 error，ALT 改 E 提示 | `T-CityLite.base/resources/[custom]/custom-police/client/coroner.lua`、`T-CityLite.base/resources/[custom]/custom-police/server/coroner.lua` | 中（碰交互入口） | 站尸体旁按 E 有反馈；空地上按 E 得到 error |
| P-3 | 警情分级：incident 增加 priority（0–3），P0/P1 走 toast+声音，P2/P3 只进 feed/列表 | `T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua`、`T-CityLite.base/resources/[custom]/custom-police/client/main.lua`、MDT 查询 | 中（要兼容旧数据） | 不同 code 的警情表现分级正确 |
| P-4 ✅(`833a3b8a`) | 命令回执降噪：commands.lua 里 77 处 QBCore:Notify 改 feed，失败改 error | `T-CityLite.base/resources/[custom]/custom-police/server/commands.lua` | 低（机械替换 + 逐条看） | 改职级/发罚单不再弹屏幕中央 |
| P-5 | MDT 空态文案（无警情 / 无在勤单位 / 连接中） | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/PoliceMDT.svelte` | 低 | 断网/空库不是白屏 |

**顺序**：P-1（通用零风险）→ P-2（PO 点名的"按 E 没用"）→ P-4（降噪）→ P-3（分级，涉及数据）→ P-5。

## 4. 验收（步骤）

> 由 CC 定标准（PO 2026-11-11 分工），共 5 步。判定一律以**截图**为准（左下角 1 秒内截）。

### P-1 去重与合并

| 步骤 | 操作 | 期望现象 | 判定 |
|---|---|---|---|
| 0 | 控制台 `setr notify_dev 1`，进服 | `/notifydev` 可用 | 控制台回显 |
| 1 | 聊天框输入一次 `/notifydev`（A×3 + B） | 左下 2 条：A「支付 −$2 · 水 1 瓶」带 `×3`；B「案件 PC-2026-1104 已登记」无角标 | 1s 后截左下角 |
| 2 | 不操作，看同一次命令的第 4 条 B | B 独立成条，不与 A 同条，无 `×N` | 同图；带角标行只有 1 行 |
| 3 | 记 t0；t0+3.3～4.0s 再输 `/notifydev`（feed 5s 才消失） | A 出现**第二条独立条目**，旧条仍 `×3`；不得合并成 `×4`/`×6` | 输入后 0.5s 内截图；只数 A 行，仍 1 条即失败 |
| 4 | 连发 6 条不同 feed（`/notifydev` 只有 2 种文案，无 6 条入口则记「阻塞」，不得记通过） | 只留最新 4 条，最早 2 条被挤掉 | 截图计数，或 CEF 查 `#feed .item` 为 4 |

**反例（必须不成立）**

1. 3 条相同后 A 行 ≥2 条，或角标不是 `×3` → 不通过；
2. B 被并入 A 条目，或 B 带 `×N` → 不通过；
3. 3 秒后只有旧条被续命、没有独立新条 → 不通过；
4. 角标回退（`×3`→`×2`），或 3 秒后仍出现 `×4` 及以上 → 不通过；
5. 6 条不同文案时屏显 ≥5 条，或挤掉的是最新而不是最早 → 不通过。

### P-2 验尸官反馈 / P-4 命令回执（同批验收）

| 步骤 | 操作 | 期望现象 | 判定 |
|---|---|---|---|
| 5 | 站到尸体旁 → ALT → “叫验尸官” | 左下 feed「验尸官已在路上 · 约 2 分钟到达现场」 | 截图 |
| 6 | 立刻再叫一次 | 左下**红条**「验尸官正在路上，N 秒后可再叫」，中央**无** toast | 截图 |
| 7 | 发一张罚单（`/grantlicense` 或罚单命令） | 左下 feed 出现回执，**不再**在屏幕右侧弹 NUI 通知 | 截图 |

**反例**：第 6 步出现中央 toast、或第 7 步右侧仍有通知 → 不通过。


## 5. 已知未决

- MDT 的空态与加载态没有设计（真机只验过"有数据"那条路）；
- 罚款/通缉/扣押三类警用动作的文案格式不统一（中英混排）；
- 56 条命令没有面向警员的清单入口。
