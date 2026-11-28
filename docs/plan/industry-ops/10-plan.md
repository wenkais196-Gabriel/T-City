---
id: industry-ops-two-clock-plan
type: plan
status: active
system: economy
owner: hermes
updated: 2026-11-28
review_by: 2027-03-31
stage: P
plan_status: 1
---

# 计划：产业两时钟（四季 × 季度结算）与参数定值

```plan-status
ALL | wip | - | 2026-11-28
```

---

## 1. 口径（用户 2026-11-28 拍板）

| 层 | 长度 | 作用 | 重置什么 | 保留什么 |
|---|---|---|---|---|
| **四季（内层）** | **一周走完一个循环**（7 天拆 4 段，天数每周不同） | 像 Kittens Game 的四季：改产能/售价/配额倍率，形成周节奏 | 每季配额用完即弃 | 金库、设施、工位、库存升级、威望 |
| **大周期（外层）** | **一个现实季度 = 13 周**（≈91 天，≥12 个四季循环） | 开新一轮，打断马太效应 | 设施、工位、库存、金库（软重置） | **威望**、个人银行 |

配套决定：

1. 提现**抽税 + 有周额度**；金库也能在季度结算时**按比例分配**；
2. 库存上限是**花钱升级的基本项**（与工位并列），具体数值由仿真定；
3. 冬天 = **黑五**：产不出，但卖得掉、价格高；
4. **设施跨季保留**，只有大周期结束才结算重置。

## 2. 参数定值（全部由仿真得出）

| 参数 | 值 | 依据 |
|---|---|---|
| 库存升级 | 每级 **+900**（满级 5,940），价格 $40,000×1.6^级 | +180 时"囤货过冬"比"能卖就卖"低 41%；+900 时打平（+0.6%） |
| 提现周额度 | **$25,000** | 额度 $50k 时 Boss/成员 = 12.6x、$100k 时成员为 0；$25k + 20% 税时 5.3x |
| 提现税 | **20%** | 税率 0→40% 只把 Boss 个人压掉约 35%，额度是主开关 |
| 结算分配 | **Boss 40%**，其余成员平分 | 分配比例对总财富影响远小于额度：20%→8.7x，40%→12.6x |
| 冬天（黑五） | 产能 **0.25** / 配额 **1.30** / 价 **1.50** | 三者对结果不敏感（囤货增益 1.7–4.6%），按观感定 |
| 四季天数 | 从 7 种分配轮转：`2/3/1/1`、`1/1/3/2`、`2/2/2/1`、`1/2/2/2`、`3/1/1/2`、`1/3/1/2`、`2/1/2/2` | 确定性可复现（做数值监控必须可复现） |

推荐组合跑一个季度（囤货过冬）：季度收入 **$2,340,000 量级**，工位从 1 长到 7，库存升到 4 级（4,140），
"卖光"与"囤货"两种策略收入差 **+0.6%** —— 都成立。

## 3. 与现有实现的距离（这是落地的真正成本）

| 现状 | 需要变成 | 位置 |
|---|---|---|
| `industry_state` 只有 `cycle_no / phase / settled_cycle_no`（单时钟） | 增加 `quarter_no / season_no / season_ends_at / quarter_ends_at` | `T-CityLite.base/migrations/v4.4_industry_cycle.sql` |
| `SettleCycle` 一个函数清一切 | 拆成 `RollSeason`（清配额/库存）与 `SettleQuarter`（软重置 + 分配 + 威望） | `T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua` |
| `industry_sales` **没有 phase 列** | 加 `phase`（顺带 `season`），写入/读取/CAS/对账全部带维度 | `T-CityLite.base/migrations/v4.3_industry_sales.sql`、`T-CityLite.base/resources/[custom]/custom-industry/server/sale.lua` |
| 提现无税、无额度（`/orgfundwithdraw` 直接进个人银行） | 加周额度桶 + 抽税 + 审计；结算按比例分配 | `T-CityLite.base/resources/[custom]/custom-industry/server/commands.lua`、`T-CityLite.base/resources/[custom]/custom-industry/server/treasury.lua` |
| 库存上限是常量 540 | 变成可升级（等级落库 + 价格曲线） | `T-CityLite.base/resources/[custom]/custom-industry/config/facility.lua`、`industry_facility` |

**前置 blocker**：`industry_sales` 缺 `phase` 会让"单组织 50% 配额"按**全周期累计**算，
第一阶段卖满后后续阶段一律 `org_cap_reached`。已在仓库 harness 复现
（扩张期卖 5,500 后，竞争期卖 1 件即被拒，且竞争期 `quota_used` 被回填成 5,500）。
参数基线必须在该 bug 修复之后才有效。

## 4. 仿真与 demo

| 产物 | 位置 | 用途 |
|---|---|---|
| 参数扫描 | `sim_seasons.py`（scratch，未入库） | 四张表：库存步长 / 提现额度×税 / 黑五三维 / 分配比例 |
| 交互 demo | `demo.html`（scratch） | 一周四季 + 库存/工位升级 + 提现 + 季度结算，可点 |
| 参数报告 | `report.html`（scratch） | 上面四张表 + 推荐值 + "没证明什么" |

三者都是**模型**：数值抄自配置，决策是脚本策略。它们证明算术与配置形状，不证明玩家行为、留存或全服通胀。

## 5. 待建 issue（按 `docs/engineering/ISSUE_STANDARD.md`）

| 标题 | type / priority / area | 前序核验（第一项） |
|---|---|---|
| `fix(industry): industry_sales 缺 phase，跨阶段卖单被 org_cap_reached 拒` | bug / P0 / economy | 用 harness 复现"扩张卖满 → 竞争卖 1 件被拒" |
| `feat(industry): 两时钟状态机（周=四季 / 季度=软重置）` | feature / P0 / economy | 上一条已合并（配额口径正确） |
| `feat(industry): 提现周额度 + 抽税 + 季度按比例分配` | feature / P1 / economy | 两时钟已合并（结算钩子存在） |
| `feat(industry): 库存上限可升级（+900/级，价格 40k×1.6^n）` | feature / P1 / economy | 库存上限当前是常量 540 |
| `feat(tools): 产业仿真器 MVP（驱动真实 Lua）+ 指标落盘` | feature / P2 / ci | 上面四项的设计已定（本文档） |

## 6. 不做（这一轮）

- 不做多组织抢配额的时序模型（单组织参数先定，抢单时序留到仿真器 MVP）；
- 不做 core_economy 全局系数耦合（售价只吃季节倍率）；
- 不把 demo 里的脚本策略当成"玩家行为预测"。
