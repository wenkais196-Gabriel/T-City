---
id: ux-jobs
type: manual
status: draft
system: jobs
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

# 职业与任务 · UX 设计

> 状态 **draft**：目前只完成 §1 调研（数字均为实测扫描）。§2/§3/§4 待设计。
> 工作流见 [00-workflow.md](../00-workflow.md)。

## 1. 调研（现状）

### 1.1 触点规模（实测）

| 资源 | 通知类调用 | 交互热区 | 命令 |
|---|---|---|---|
| `custom-quest` | 125 | 0 | 17 |
| `qb-management` | 71 | 6 | 0 |
| `custom-career` | 9 | 0 | 3 |

### 1.2 玩家会卡住的场景

| # | 场景 | 现在 |
|---|---|---|
| 1 | 做任务时进度更新 | `custom-quest` **125 处**通知调用，进度/奖励/失败全混在一起，容易刷屏 |
| 2 | 老板菜单/黑帮菜单 | `qb-management` 6 个热区全是 ALT |
| 3 | 职业面板看晋升条件 | `custom-career` 只有 9 处提示，缺"还差什么"的说明 |

### 1.3 外部实践（我的调研，2026-11-11）

| 来源 | 关键做法 | 对我们的意义 |
|---|---|---|
| **BetonQuest**（Minecraft 的任务引擎，工业级文档） | 任务反馈按用途拆成**四种通道**：开始 → chat；下一步提示 → actionbar（常驻短提示）；**进度 → bossbar（常驻进度条）**；完成 → title（大字 + 音效）。并强调"可复用 category"保证同类消息长得一样 | 直接对应我们的四通道：开始走 `feed`、下一步提示走 `prompt`、**进度用常驻进度条（不是 toast）**、完成走 `toast` + 音效。这条正是"125 处通知刷屏"的解药 |
| **Agency Scripts《FiveM Notifications System》** | 默认通知的最大问题是"所有提示长得一样"，玩家分不清错误/成功/信息；建议自建 NUI，把**排队、去重、音效**做成系统能力 | 我们已经有 `custom-notify`，缺的是**队列与音效**（去重本轮已做） |
| 同文（进度条部分） | 进度类反馈用**进度条**而不是文字通知（`ox_lib` 的 progressBar） | 我们的任务是"3/5 个"这种，应该给**常驻进度**，而不是每完成一个弹一次 |

**外部结论三条**：

1. **进度不是通知**：任务进度应挂在 HUD/任务面板上常驻刷新；只在**跨阶段**（1/3、2/3、3/3）时才发一条 `feed`；
2. **完成才值得打断**：完成给 `toast` + 音效，失败给 `error`，日常进度不发；
3. **可复用分类**：同类消息（任务/职业/组织）用同一套标题与图标，玩家才认得出来。

### 1.4 CC 调研补充（2026-11-11）

**外部做法**：

| 问题 | 主流做法 | 来源 |
|---|---|---|
| 进度 1/3→2/3 | 不逐次弹窗：放常驻菜单/屏幕 hint，只在完成或关键节点发通知 | force_quests 的 `ShowHints`；anox-carquest 的菜单内进度 |
| 失败/超时 | 常见静默取消（缺口）；成熟做法用 `error` 说明原因 | force_quests；ox_lib notify（`error` 类型、默认 3s、`id` 去重） |
| 老板菜单回执 | 成功/失败回执给**老板**；录用/解雇/晋升同时通知**被操作员工**；存取款只回执老板 | qb-bossmenu qb-bossmenu 的 server/sv_boss.lua |

**仓库统计（125 处里可判 type 的 118 处）**：`error` 68 / `primary` 26 / `success` 24，
另约 16 处是 admin/debug 命令。

**同一件事发多条（重点）**：

| 事件 | 条数 | 位置 |
|---|---|---|
| 任务完成 | **3+** | `quest_manager.lua:846-847` + `client/main.lua:274` + `quest_rewards.lua:156-157` |
| 步骤推进 | **3** | 节点成功处 + `quest_manager.lua:1019-1020` + `client/main.lua:260` |
| 物流失败 | **3–4** | `quest_logistics_client.lua:681,722` + `server/main.lua:860` + `client/main.lua:287` |
| 死亡 | 2+ | `server/main.lua:1253,1276` + `client/main.lua:287` |
| **逐秒提示** | 每秒 | `client/main.lua:687,702`、`quest_logistics_client.lua:718` |

**老板菜单**：`qb-management/client/cl_boss.lua:148,163,198` 只把 hire/fire/grade 作为菜单参数发出，
**客户端没有任何回执渲染**。


## 2. 设计（目标）

> 综合我的 §1.3 与 CC 的 §1.4。核心一句：**进度不是通知**。

### 2.1 任务反馈的四通道

| 时机 | 通道 | 表现 | 依据 |
|---|---|---|---|
| 接受任务 | `feed` | 「已接受：<任务名>」 | 结果是玩家主动动作 |
| 逐步进度（1/5 → 2/5） | **不发通知** | 手机 Quests App 的 `current_step` 常驻刷新 | BetonQuest 用 bossbar，我们用既有 App |
| **跨阶段**（阶段 1→2） | `feed` | 「<任务名>：进入第二阶段 · <阶段名>」 | 阶段变化值得一条 |
| 完成 | `toast` + 音效 | 「<任务名> 完成 · 奖励 $X」 | 只有完成值得打断 |
| 失败/超时 | `error` | 「<任务名> 失败：<原因>」 | 失败要说原因 |
| 放弃 | `feed` | 「已放弃 <任务名>」 | — |

**同一件事只发一条（CC 实测）**：

| 事件 | 现在 | 改成 |
|---|---|---|
| 任务完成 | 3+ 条（结算 + 客户端 + 奖励） | **1 条**：由 `quest_rewards` 统一发（含奖励汇总） |
| 步骤推进 | 3 条 | **1 条**：只在服务端发，客户端不重复 |
| 物流失败 | 3–4 条 | **1 条** `error`，带原因 |
| 逐秒倒计时 | **每秒一条** | 改成 HUD/面板常驻倒计时；只在 30s / 10s 各提醒一次 |

**为什么进度不发通知**：`custom-quest` 现在 45 处通知集中在 `T-CityLite.base/resources/[custom]/custom-quest/server/main.lua`，其中大量是逐步进度 ——
每完成一步弹一条，一个 5 步任务就刷 5 条，把真正的失败提示挤掉了。

### 2.2 文案与语言

| 问题 | 规则 |
|---|---|
| 硬编码英文（`Quest system is disabled` / `Please wait before accepting another quest` / `Node validation failed`） | 一律改中文；任务名/阶段名来自数据，不翻译 |
| 同一件事 success 与 primary 混用 | 统一：成功 `feed`、失败 `error`、需注意 `toast` |

### 2.3 老板 / 组织菜单（qb-management）

| 动作 | 执行者看到 | 当事人看到 |
|---|---|---|
| 招人 / 开除 | `feed` 一行 | `phone` 一行（可回查） |
| 发薪 | `feed`（金额与人数） | `phone`（金额） |
| 调整职级 / 调价 | `feed` | `phone`（仅涉及本人时） |
| 失败（权限/资金不足） | `error` | — |

热区：6 个 ALT 热区里凡是**单一动作**的，改成 `prompt` 的 `[E]`；只有"同一位置多选项"才留 ALT。

### 2.4 职业面板（custom-career）

| 情形 | 表现 |
|---|---|
| 看晋升条件 | 列出「已满足 / 还差什么」（现在只说"不够"，不说差多少） |
| 晋升成功 | `toast`「已晋升为 <职级>」+ `phone` 留档 |
| 考核失败 | `error` 带差距 |


## 3. 计划（任务）

| # | 任务 | 文件 | 风险 | 验收 |
|---|---|---|---|---|
| J-1 | 逐步进度不再发通知，只在**跨阶段**发一条 feed | `T-CityLite.base/resources/[custom]/custom-quest/server/main.lua`（进度回调处） | 中（要认出哪些是逐步） | 做一个 3 步任务：只在阶段变化时看到 feed，逐步无通知 |
| J-2 | 45 处通知接三层通道（成功→feed、失败→error），硬编码英文改中文 | 同上 | 低（机械 + 逐条看） | 接受/放弃/失败三类表现不同 |
| J-3 | 同一事件去重：完成 3→1 条、步骤 3→1 条、物流失败 3–4→1 条（带原因） | `quest_manager.lua:846,1019`、`quest_rewards.lua:156`、`quest_logistics_client.lua:681,722`、`client/main.lua:274,287` | 中（多文件） | 完成一次任务只看到 1 条结算 |
| J-3b | 逐秒倒计时改常驻：只在 30s / 10s 各发一条 toast | `client/main.lua:687,702`、`quest_logistics_client.lua:718` | 中 | 运输过程中不再每秒刷屏 |
| J-3c | 任务完成 toast + 失败 error（不再混用 success/primary） | 同上 | 低 | 完成弹中央，失败弹左下红 |
| J-4 | qb-management 的 6 个 ALT 热区：单动作改 `[E]` | `T-CityLite.base/resources/[qb]/qb-management/client/` | 中（要实测距离） | 更衣室/储物柜按 E 直接可用 |
| J-5 | 老板菜单回执：执行者 feed、当事人 phone（现在客户端零渲染，`cl_boss.lua:148,163,198`） | `qb-management` 客户端与服务端动作 | 中 | 发薪后员工手机有记录，老板看到 feed |
| J-6 | custom-career 晋升条件给"差多少" | `T-CityLite.base/resources/[custom]/custom-career/` | 低 | 面板显示「还差 X 点 / Y 小时」 |

**顺序**：J-2（通道统一，最快见效）→ J-1（降噪，效果最大）→ J-3（完成/失败区分）→ J-4/J-5 → J-6。


## 4. 验收（步骤）

_待写。_

## 5. 已知未决

- 任务进度（1/3 → 2/3）应走 feed 还是 toast 未定（当前混用）；
- 晋升条件、考核失败原因没有文案。
