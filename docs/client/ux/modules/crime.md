---
id: ux-crime
type: manual
status: draft
system: crime
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

# 犯罪与组织 · UX 设计

> 状态 **draft**：§1 调研进行中（我的部分已入库，等 CC 的仓库拆分与外部来源）。
> 工作流见 [00-workflow.md](../00-workflow.md)。

## 1. 调研（现状）

### 1.1 触点规模（实测，2026-11-11 重扫）

| 资源 | 通知类调用 | 交互热区 | 命令 |
|---|---|---|---|
| `qb-storerobbery` | 32 | 2 | 2 |
| `custom-cartel` | 37 | 1 | 4 |
| `qb-drugs` | 48 | 3 | 7 |
| `custom-mining` | 17 | 2 | 1 |
| `custom-crime` | 16 | 0 | 0 |
| **合计** | **150** | **8** | **14** |

全仓库 `police:server:policeAlert` 调用点 **7 处**，其中带自定义文本的 2 处是英文/拼写错误（见 §1.4 第 5 行）。

### 1.2 状态语义

见 §1.3。

### 1.3 状态语义（我扫的）

| 概念 | 现在的实现 | 玩家能不能看见 |
|---|---|---|
| 已被抢过 | `qb-storerobbery` 服务端按次记录，客户端只有一句「该保险箱已被打开过了」 | 只有在按到那一瞬间才知道 |
| 冷却 | 抢劫结束后按位置进入冷却（`qb-storerobbery` 无独立 cooldown 表，靠 `isBusy` 内存态） | **完全不可见** —— 玩家会在同一家店反复试 |
| 警察门槛 | `需要至少 N 名执勤警察才能打开保险箱` | ✅ 这条写得好，是全模块最好的文案 |
| 犯罪收益 | `抢劫完成！战利品已放入背包`（success） | 只给一句，不给金额/物品清单 |
| 通缉 | `SetPlayerWantedLevel(src, 2)`（原生 2 星） | 原生星星，与 RP 报警单**两套并行** |
| 报警 | `police:server:policeAlert`，7 个调用点 | 警察端：自由文本工单标题 |

### 1.4 玩家会卡住的场景

| # | 场景 | 现在 | 依据 |
|---|---|---|---|
| 1 | 想抢收银机但站偏了 | 只回「当前位置附近没有可抢劫的收银机！(需在 1.8 米内)」，**不说往哪走** | qb-storerobbery 的 client/main.lua 收银机交互分支 |
| 2 | 保险箱要长按 ALT | `AddCircleZone` 走 qb-target（全服 `setr UseTarget true`），单动作却要 ALT | `qb-storerobbery/client/main.lua:107` |
| 3 | 抢完再回来 | 冷却不可见，玩家以为脚本坏了 | 见 §1.3 冷却行 |
| 4 | 抢到东西 | 只有一句 success，不知道抢了多少、进了背包还是黑钱 | `抢劫完成！战利品已放入背包` |
| 5 | 警察看见的告警 | 标题是**调用方自由文本**：`'Drug sale in progress'` / `'Suspicous activity'`（拼错）/ `Lang:t('email.storerobbery_progress')` | `qb-drugs/client/cornerselling.lua:33`、`deliveries.lua:144` |
| 6 | 被通缉 | 原生 2 星与 RP 报警单两套并行，玩家不知道该怕哪一套 | `qb-storerobbery/server/main.lua:546` |

**关于告警的一个好消息**：坐标是**服务端从报警者 ped 上取的**（custom-police 的 server/main.lua 的 `police:server:policeAlert` 处理），
客户端不发坐标，还有 15 秒/人 限流 —— 安全上没问题，问题**只在文案与分类**。

### 1.5 外部实践（我的调研，2026-11-11）

| 来源 | 关键做法 | 对我们的意义 |
|---|---|---|
| **FiveSecured《FiveM robbery script》** | 抢劫系统是"服务端拥有的地点表"：每个地点写死 `loot / seconds / cooldown / minPolice / stages`；客户端只拿渲染所需，服务端按地点 id 重读配置。提示只在范围内出现 | 我们的警察门槛已有（§1.3），缺的是**把 cooldown 变成可见状态**——表里有 `cooldown`，玩家界面里什么都没有 |
| **MX-Robbery（Cfx 论坛 RedM）** | 抢劫**开始就发警察告警**；带进度条；每地点 + 每玩家双冷却；`RestrictedJobTypes` 禁止体制内职业抢劫 | 我们发告警了但**没有进度条**（长按期间只有原生进度圈），冷却也不可见 |
| **Quasar《Drugs Creator 2.0》** | 毒品链是"采集 → 运输 → 实验室加工 → 分销"多阶段，每阶段风险不同；收益走**脏钱 + 洗钱**，不是直接给现金 | 我们的 `qb-drugs` 也是多阶段，但阶段间**没有统一反馈**；收益直接进背包/现金，缺"脏钱"这一层叙事 |

**外部结论三条**：

1. **冷却与门槛是可见状态，不是错误文案** —— 应该在交互提示里就写「冷却 3:12」「需 2 名警察（当前 0）」，而不是让玩家按下去吃一个 error；
2. **阶段推进要有进度条**，不是每完成一步弹一条通知（与任务模块同一条结论）；
3. **收益要能回看**：金额/物品清单应该留档（手机凭证），屏幕只给一句「已到账」。

## 2. 设计（目标）

_待写。_

## 3. 计划（任务）

_待写。_

## 4. 验收（步骤）

_待写。_

## 5. 已知未决

- 犯罪链路的"被发现/被通缉"反馈没有统一通道（现在混在 chat 与 notify 里）；
- 组织（cartel）内部消息走 chat，与 IC 消息通道不一致。
