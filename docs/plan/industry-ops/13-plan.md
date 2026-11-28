---
id: industry-ops-next-round-plan
type: plan
status: active
system: economy
owner: hermes
updated: 2026-11-28
review_by: 2027-03-31
stage: P
plan_status: 1
---

# 计划：产业线下一轮优化（Hermes 方案 × CC 调研 合并）

```plan-status
ALL | todo | - | 2026-11-28
```

---

## 0. 两份方案怎么合的

| | 我的方案（独立分析） | CC 调研（`docs/research/industry-optimization.md`） |
|---|---|---|
| 方法 | 自己跑 52 周仿真 + 读快照/手机 actions + 数 tick SQL | 同样跑仿真，另加三处**临时脚本实验**（4 季度 rebuild、hoard 阈值扫描、SQL 计数） |
| 长处 | 用真机读数交叉验证（季度结算 210,000 = 200k + 10k×prestige） | 找到我漏掉的两条经济漏洞，并给出可执行修法 |
| 短板 | 漏了"起跑金随 prestige 增长"与"囤货策略其实不成立" | 临时脚本未入库，数字无法复现；引用的临时路径踩断链闸门（已修） |

**合并原则**：CC 的结论我只采纳**我能独立复核**的部分；复核不了的标注证据等级并降优先级。

## 1. 对照表（逐项）

| 议题 | 我的判断 | CC 的判断 | 合并结论 |
|---|---|---|---|
| 仿真器跨季度 | **阻断级**：52 周四策略 Q2–Q4 全 0（week14 起工位=0） | 同（并提出 rebuild 策略补实验） | **一致，P0** |
| 起跑金漏口 | 我**漏了** | 强：`base + stipend × prestige`，`MAX_GRANT=1e15` 形同无上限 | **采纳，P0**（我用真机 210,000 = 200,000 + 10,000×1 复核成立） |
| 囤货是否成立 | 我此前据 Python 模型说"+900 打平（+0.6%）" | 强：sell-all **支配** hoard（1,389,275 vs 313,973 净现金） | **CC 对，我错** —— 见 §2 的更正 |
| 季节不可见 | 强：快照无 `season/quarter` 字段 | 同（并指出手机没有倒计时/威望） | **一致，P1** |
| 手机缺建厂 | 强：actions 只有 sell/hire/upgrade_stock/withdraw | 同（并指出空状态文案互相指向空处） | **一致，P0** |
| 可观测性 | 强：`conflict` 无日志（#420 真机卡死 6 分钟） | 同（并提出状态命令/结果查询/指标导出） | **一致，P0（最小集）** |
| 性能 N+1 | 我判"不急"：3 SQL/组织/tick，N=100 也才 10 qps | 实测 3N+2 条 SELECT，排 P2 | **折中**：批限不一致是**正确性**问题先修；合并查询排 P2 |
| 组织金库开户 | 我漏了 | 中：`EnsureAccount` 只在存款路径调用 | **采纳但降级 P1**（无行时快照返回 0，不会崩，属体验） |
| 玩法加内容 | 一律排到数据之后 | 同样把订单/配方放 P3/P4 | **一致** |
| 跨季保留设施 | 不做（抵消软重置） | 同 | **一致，不做** |

## 2. 必须更正的一条既有结论（我的错）

`docs/plan/industry-ops/10-plan.md` 的参数表写着：

> 库存升级每级 +900 时「囤货过冬」与「能卖就卖」打平（+0.6%）

**这个结论不成立。** 它来自 Python 模型（`tools/dev/industry_sim/sim_seasons.py` 的前身），
那个模型**没有建模"每季配额用完即弃"**。用仓库内的真实 Lua 仿真（`tools/dev/industry_sim/run_sim.py`，13 周）：

| 策略 | 季度收入 | 工位 | 库存级 |
|---|---|---|---|
| `max`（能卖就卖） | **2,571,061** | 9 | 0 |
| `hoard`（只在 ≥1.2 倍价卖） | 1,494,075 | 5 | 5 |

差 **72%**。原因：四季各自有独立配额，只卖冬季等于放弃春夏秋三季配额（理论收入上限只有全季的 43%）。
所以库存升级的真实价值**不是"囤货套利"**，而是"玩家不能 hourly 上线时的缓冲"——这需要另一个模型（玩家上线频率）才能评估。

**行动**：本轮 P1 里包含"更正 10-plan 参数表 + 把阈值×库存×工位扫描脚本入库"，
在此之前**任何"库存等级该是几级"的讨论都无效**。

## 3. 合并后的优先级

### P0（先做，四条互相独立可并行）

| # | 项 | 证据 | 为什么是 P0 |
|---|---|---|---|
| **A** | 起跑金：改成「上季有设施或有销售才发」，且 prestige 津贴封顶 | 强：结算 `base + stipend × prestige`（`T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua` 第 69–78 行），`MAX_GRANT = 1e15`（同文件第 38 行）形同无上限；真机 `starter_granted = 410000` 中 mining_co 拿 210,000 = 200,000 + 10,000×1 | **每一季凭空注入资本**，且随 prestige 递增 —— 这是唯一会跨季度复利的漏口 |
| **B** | 仿真器支持季度重建 + 52 周基线 | 强：`--weeks 52` 四策略 Q2–Q4 收入 0；根因 `tools/dev/industry_sim/run_sim.py` 只在开头 `Facility.Build`，策略的 build 只调 `AddWorkstation`（要求设施已存在） | **所有多季度平衡结论的前提** |
| **C** | 可观测性最小集：`Tick`/`RollSeason` 非 ok 落节流日志 + `/orgcycle` 状态命令 | 强：#420 真机卡死 6 分钟、日志零输出 | 出问题只能靠人肉查库 |
| **D** | 手机建厂入口（复用 `/orgbuild` 的服务端校验） | 强：`T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua` 的 actions 只有 sell/hire/upgrade_stock/withdraw | 新玩家第一步就断在命令上 |

### P1

| # | 项 | 证据 | 说明 |
|---|---|---|---|
| **E** | 快照暴露两时钟（`season{key,label,no,weekIndex,endsAt,quarterNo,quarterEndsAt}`）+ 手机季节条/倒计时/倍率 | 强：`T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua` 的 `grep season` 无结果 | 设计卖点"一周四季"玩家看不见 |
| **F** | 手机存款 / 金库流水（Boss 自助，`EnsureAccount` 前移） | 中 | 现在存款只能命令；新组织要先存一次才有账户 |
| **G** | 更正 `docs/plan/industry-ops/10-plan.md` 的"库存 +900 打平"，把阈值×库存×工位扫描**入库** | 强（本文 §2） | 不修就让后续平衡建在错的数字上 |

### P2

| # | 项 | 说明 |
|---|---|---|
| **H** | `SETTLE_BATCH_LIMIT = 200`（`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua` 第 23 行）与 `MaxOrgsPerSettle = 500`（`T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua` 第 90 行）不一致 | 超过 200 个组织时，排在后面的组织**永远不生产**；不是性能问题是正确性问题（现在 2 组织，风险潜伏） |
| **I** | 每 tick 一次 state 读 + 设施/威望合并查询 | 现在 3 SQL/组织/tick（实测 3N+2 条 SELECT）；N=100 尚可，先记边界 |
| **J** | 季度结果查询 / 审计查询 / 指标导出 | 运营与数值监控需要 |

### P3

排行榜与荣誉（只给称号不给钱）、换季/满仓 CityFeed 提醒、批量雇工位、订单契约、二段配方。

### 不做

| 项 | 理由 |
|---|---|
| 跨季保留设施/库存 | 直接抵消软重置的设计目的 |
| 设施等级（`maxLevel=5` 死配置） | 配置存在但无玩法，先让它继续死着 |
| 多组织抢配额时序模型 | 现在只有 2 个组织 |
| 调整冬季倍率/税率/额度 | 在 B + G 出结果之前没有新证据 |

## 4. 依赖树

```
B（仿真器跨季）──► G（重跑阈值扫描，更正文档）──► 订单/配方（P3）
A（起跑金）────┐
C（可观测性）──┤ 四条互不依赖，可并行
D（手机建厂）──┘
E（季节可见）──► F（存款/流水）
H（批限对齐）独立
```

## 5. 施工纪律（沿用上一轮经验）

- 每片先红后绿；**注入必须改代码路径**，不能改假 DB 不解析的 SQL 片段（上一轮踩过）；
- 迁移/改动在活库连跑两次；`players` 等个人层表结算前后一致；
- 真机验收只走 `start.cmd`（`start-tcity.ps1` detach），控制台命令走 `tools/dev/fivem_console.py`；
- 交付三件套：代码 + 文档 + `CHANGELOG`；push 前 `tools/dev/release_check.py`。
