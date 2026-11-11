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

## 2. 设计（目标）

_待写。_

## 3. 计划（任务）

_待写。_

## 4. 验收（步骤）

_待写。_

## 5. 已知未决

- MDT 的空态与加载态没有设计（真机只验过"有数据"那条路）；
- 罚款/通缉/扣押三类警用动作的文案格式不统一（中英混排）；
- 56 条命令没有面向警员的清单入口。
