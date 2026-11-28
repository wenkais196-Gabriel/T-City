---
id: research-industry-optimization
type: research
status: draft
system: economy
owner: hermes
updated: 2026-11-28
review_by: 2027-02-28
---

# 产业线 MVP 之后的优化调研

> **范围**：只做调研与取证，**不改任何源码 / 测试 / `tools/dev/*`**。本轮唯一新增文件就是本文。
>
> **分支与基线**：`docs/industry-opt`，基线 `origin/master`（最近提交 `e6f154cb`）。
>
> **证据等级**：
> - **强**：本轮真实跑过的命令输出，或代码里可逐行核对的事实；
> - **中**：代码路径 + 静态推导，没有独立复现；
> - **弱**：设计推断、未实现功能的成本估计。
>
> **仿真口径**：`tools/dev/industry_sim/run_sim.py` 驱动真实 `T-CityLite.base/resources/[custom]/custom-industry/server/*.lua`，假 DB；
> 单组织 `mining_co`，初始金库 $200,000，每周顶格提现 $25,000。它证明算术与配置形状，
> **不证明玩家行为、留存或全服通胀**（`tools/dev/industry_sim/README.md:5`）。
>
> **已知缺陷**：#418、#420 已建 issue，本文不重复发现；#420 仅作为第 5 节可观测性的案例引用。

---

> **可复现性说明**：本文的三处补充实验（4 季度 rebuild、hoard 阈值扫描、SQL 计数）用的是**未入库的临时脚本**，
> 数字无法由他人一键复现。核心方向已由仓库内工具独立确认：
> `run_sim.py --weeks 13` 的 `max`（能卖就卖）收入 **2,571,061** vs `hoard` **1,494,075**（差 72%），
> 与「sell-all 支配 hoard」一致；凡标注"临时脚本"的数字按**中**级证据对待，进 CI 前必须脚本化。


## 1. 摘要

1. **数值**：四条内置策略跑满 52 周后，Q2–Q4 收入全部为 0 —— 季度结算会 `DELETE FROM industry_facility`，
   而四条策略都不会重建设施。所以“季度软重置”在当前仿真里实际是“删设施 + 发起跑金”；
   要回答第二季度起的问题，必须补一个重建策略（本文用 TEMP 补充实验补了）。
2. **马太效应**：组织层的净现金差距没有指数复利 —— 4 工位对 1 工位的季度净现金倍率稳定在
   **4.16× / 4.35× / 4.71× / 4.28×**（Q1–Q4），10 工位反而因 1.35 成本曲线不优于 4 工位。
   但重置压不住**个人层**：周提现 $25k + 结算分配把财富转到 Boss 个人银行；起跑金还随 prestige
   点数**无上限**增长（rebuild10：200k→270k→350k→440k→530k），这是真正会复利的漏口。
3. **性能**：`industry_tick_seconds=30` 的心跳每 tick 发 **3N+2 条 SELECT**（N = 有设施的组织数），
   1 组织实测 5 条、2 组织实测 8 条；每条组织 3 次逐组织查询（设施 / `industry_state` / `org_treasury.prestige`），
   存在明显 N+1；工位数不增加查询数，只影响 CAS UPDATE 的频率。
4. **UX**：手机端已经有卖出、雇工位（单个）、库存升级、提现；**没有建厂、存款、流水、倒计时、威望**。
   建厂全仓唯一入口是聊天命令 `/orgbuild`，而季度结算每 13 周都会删掉设施 —— 每次重置后必须打字才能复工。
   手机空状态写“先在 Boss 菜单里建厂”，Boss 菜单却写“建造入口仍由 `/orgbuild`（控制台）负责”，两条提示互相指向空处。
5. **玩法/可观测性**：冬季“囤货过冬”被“每季配额用完即弃 + 冬季产能 0.25”结构性压制 ——
   5 工位 sell-all 净现金 $1,389,275，而内置 hoard 只有 $313,973；P3 库存升级在“每小时都能卖”的操作下不回本。
   可观测性方面，#420 类静默卡死的根因是 `IndustryCycle.Tick` 返回 `false` 时调用方不落日志；
   目前没有状态命令、审计查询、季度结果查询或指标导出。

---

## 2. 数值：52 周仿真与马太效应

### 2.1 命令与口径

**结论**：任务指定的四条内置策略可以稳定复现；13 周基线 `BASELINE OK`，但 52 周基线不存在，
四条策略在 Q2–Q4 全部归零，不能直接用来回答“越富越富”。

**证据**：

```bash
python tools/dev/industry_sim/run_sim.py --weeks 52 --policy idle   --out %TEMP%/industry-opt-sim/idle.jsonl
python tools/dev/industry_sim/run_sim.py --weeks 52 --policy steady --out %TEMP%/industry-opt-sim/steady.jsonl
python tools/dev/industry_sim/run_sim.py --weeks 52 --policy max    --out %TEMP%/industry-opt-sim/max.jsonl
python tools/dev/industry_sim/run_sim.py --weeks 52 --policy hoard  --out %TEMP%/industry-opt-sim/hoard.jsonl

# 13 周基线复核
python tools/dev/industry_sim/run_sim.py --weeks 13 --policy steady \
  --out %TEMP%/industry-opt-sim/steady13.jsonl \
  --baseline T-CityLite.base/tests/architecture/industry_sim_baseline.json
```

真实输出（52 周 summary 行，`季度收入` 是最后一个季度 SettleQuarter 的汇总）：

```text
[sim] policy=idle weeks=52 季度收入=0 工位=0 库存级=0 提现=800000 税=160000
[sim] policy=steady weeks=52 季度收入=0 工位=0 库存级=0 提现=925000 税=185000
[sim] policy=max weeks=52 季度收入=0 工位=0 库存级=0 提现=1050000 税=210000
[sim] policy=hoard weeks=52 季度收入=0 工位=0 库存级=0 提现=1000000 税=200000
```

真实输出（13 周基线）：

```text
[sim] policy=steady weeks=13 季度收入=401760 工位=1 库存级=0 提现=325000 税=65000
BASELINE OK: 关键字段在 ±10% 内
```

**风险**：`T-CityLite.base/tests/architecture/industry_sim_baseline.json:4` 的基线只有 `weeks: 13`，
CI 不会发现“Q2 起没有产出”这类跨季度回归；52 周运行目前是人工步骤，不是闸门。

### 2.2 内置四策略的四季度走势

**结论**：Q1 之后所有策略的工位与库存等级都被结算清零；Q2–Q4 的收入为 0，提现只来自季度起跑金。

**证据**：按 JSONL 每周行聚合（`quarter` 字段分组，取每季最后一周的工位 / `stock_cap` 反推库存等级）：

| 策略 | Q1 收入 | Q2 收入 | Q3 收入 | Q4 收入 | Q1 末工位 | Q2–Q4 末工位 | Q1 末库存级 | Q2–Q4 末库存级 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| idle | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| steady | 401,760 | 0 | 0 | 0 | 1 | 0 | 0 | 0 |
| max | 2,571,061 | 0 | 0 | 0 | 9 | 0 | 0 | 0 |
| hoard | 1,494,075 | 0 | 0 | 0 | 5 | 0 | 5 | 0 |

| 策略 | Q1 末金库 | Q2 末金库 | Q3 末金库 | Q4 末金库 | Q1 末威望 | Q2 末威望 | Q3 末威望 | Q4 末威望 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| idle | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| steady | 176,760 | 20,000 | 20,000 | 20,000 | 0 | 2 | 2 | 2 |
| max | 436,243 | 20,000 | 20,000 | 20,000 | 0 | 7 | 7 | 7 |
| hoard | 263,973 | 0 | 0 | 0 | 0 | 5 | 5 | 5 |

| 策略 | Q1 提现 / 税 | Q2 提现 / 税 | Q3 提现 / 税 | Q4 提现 / 税 |
|---|---:|---:|---:|---:|
| idle | 200,000 / 40,000 | 200,000 / 40,000 | 200,000 / 40,000 | 200,000 / 40,000 |
| steady | 325,000 / 65,000 | 200,000 / 40,000 | 200,000 / 40,000 | 200,000 / 40,000 |
| max | 300,000 / 60,000 | 250,000 / 50,000 | 250,000 / 50,000 | 250,000 / 50,000 |
| hoard | 250,000 / 50,000 | 250,000 / 50,000 | 250,000 / 50,000 | 250,000 / 50,000 |

**关键代码事实**：季度结算 `settleOrg` 在清分时执行
`DELETE FROM industry_facility WHERE org_id = ?`（`T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua:489-490`）
和 `DELETE FROM industry_sales WHERE org_id = ?`（`:500-502`），随后发放起跑金（`:505-519`）。
`RollSeason` 只更新 `industry_state` 并补配额种子，不删设施（`T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua:762-789`）；
所以设施是在**季度末**被删，不是每周换季被删。

**风险**：这不是“玩家不努力”，而是当前季度结算的硬删除语义。任何“第二季度起”的数值结论都必须先把
“重建”纳入策略，否则 Q2–Q4 的 0 只是策略缺口，不是经济结论。

### 2.3 补充实验：重建策略下的四季度走势

**结论**：为了回答“第二季度起会不会越富越富”，我用 TEMP 脚本给内置 `max` 策略补了两件事：
设施不存在时调 `Facility.Build`、把工位目标从 `workstationCap` 改成固定值。**没有改仓库**
（脚本在 临时脚本 rebuild_probe.py（未入库），通过 `industry_harness.run_sim_script` 驱动真实 Lua）。
结果：三条重建策略都能在 Q2–Q4 继续生产；收入逐季上升，但净现金倍率没有爆炸。

**证据**（真实输出，Q1–Q4 收入与净现金；净现金口径见下）：

| 补充策略 | Q1 收入 | Q2 收入 | Q3 收入 | Q4 收入 | Q4/Q1 | Q1 净现金 | Q4 净现金 |
|---|---:|---:|---:|---:|---:|---:|---:|
| rebuild1（1 工位） | 401,760 | 430,550 | 456,900 | 485,100 | 1.21× | 301,760 | 455,100 |
| rebuild4（4 工位） | 1,636,873 | 1,856,843 | 2,141,954 | 2,160,870 | 1.32× | 1,255,230 | 1,949,227 |
| rebuild10（目标 10 工位，Q1 末 9） | 2,571,061 | 3,579,348 | 4,160,625 | 4,377,305 | 1.70× | 536,243 | 1,837,800 |

> 净现金 = 当季末金库 + 当季提现 − $200,000。它**包含当季起跑金**（超过 200k 的部分是
> prestige 津贴），所以衡量的是“总现金生成”，不是纯生产利润；资本成本见 2.4 的回本表。
> 数据来自 `rebuild_probe.py` 的四季度聚合。

原始 stdout（Q 行保留关键字段、SUMMARY 为节选字段；脚本自动把 `policy` 字段写成 driver 的 `max`）：

```text
===== rebuild1 =====
Q1: revenue=401760 ... end_ws=1 end_level=0 end_treasury=176760 end_prestige=0
Q2: revenue=430550 ... end_ws=1 end_level=0 end_treasury=225550 end_prestige=2
Q3: revenue=456900 ... end_ws=1 end_level=0 end_treasury=271900 end_prestige=4
Q4: revenue=485100 ... end_ws=1 end_level=0 end_treasury=330100 end_prestige=7
SUMMARY: {"quarter_revenue":485100,"workstations":1,"stock_level":0,"total_revenue":1774310,"total_withdrawals":1300000,"total_tax_burned":260000,"treasury_before_settle":330100,"prestige_before_settle":7,"treasury_after_roll":300000,"starter_granted":300000}
===== rebuild4 =====
Q1: revenue=1636873 ... end_ws=4 end_level=0 end_treasury=1155230 end_prestige=0
Q2: revenue=1856843 ... end_ws=4 end_level=0 end_treasury=1400200 end_prestige=5
Q3: revenue=2141954 ... end_ws=4 end_level=0 end_treasury=1745311 end_prestige=11
Q4: revenue=2160870 ... end_ws=4 end_level=0 end_treasury=1824227 end_prestige=17
SUMMARY: {"quarter_revenue":2160870,"workstations":4,"stock_level":0,"total_revenue":7796540,"total_withdrawals":1275000,"total_tax_burned":255000,"treasury_before_settle":1824227,"prestige_before_settle":17,"treasury_after_roll":430000,"starter_granted":430000}
===== rebuild10 =====
Q1: revenue=2571061 ... end_ws=9 end_level=0 end_treasury=436243 end_prestige=0
Q2: revenue=3579348 ... end_ws=10 end_level=0 end_treasury=744843 end_prestige=7
Q3: revenue=4160625 ... end_ws=10 end_level=0 end_treasury=1406120 end_prestige=15
Q4: revenue=4377305 ... end_ws=10 end_level=0 end_treasury=1712800 end_prestige=24
SUMMARY: {"quarter_revenue":4377305,"workstations":10,"stock_level":0,"total_revenue":14688339,"total_withdrawals":1275000,"total_tax_burned":255000,"treasury_before_settle":1712800,"prestige_before_settle":24,"treasury_after_roll":530000,"starter_granted":530000}
```

**净现金倍率（rebuild4 / rebuild1）**：Q1 **4.16×**、Q2 **4.35×**、Q3 **4.71×**、Q4 **4.28×** ——
没有随季度放大；10 工位（rebuild10）Q4 净现金 **1,837,800**，反而低于 4 工位的 **1,949,227**。
这是 1.35 指数成本曲线 + 13 周季度的直接结果：**多建工位不等于更富**。

**起跑金轨迹**（`200,000 + 10,000 × prestige_after`；prestige 点数不封顶，只有产能加成封顶）：

| 策略 | Q1 结算后 → Q2 起跑金 | Q2 → Q3 | Q3 → Q4 | Q4 → 下一季 |
|---|---:|---:|---:|---:|
| rebuild1 | 220,000 | 240,000 | 270,000 | 300,000 |
| rebuild4 | 250,000 | 310,000 | 370,000 | 430,000 |
| rebuild10 | 270,000 | 350,000 | 440,000 | 530,000 |

任务给定的 2026-11-28 真机读数 `starter=410000` 与这条公式一致：`410,000 = 200,000 + 10,000 × 21`，
即结算后 prestige 点数为 21（产能加成仍封顶 +20%，但起跑金继续按点数线性增长）。

**风险**：TEMP 补充脚本不是仓库资产，不进 CI；它验证的是“重建后数值会怎样”，不是玩家会重建。
真正要长期回答这个问题，应把 rebuild 策略作为 `run_sim.py` 的第五种策略或独立工具入库（见第 7 节）。

### 2.4 回本与建造档位：季度化把摊销期从 4 周拉到 13 周

**结论**：按本次仿真的 Q1 净现金与配置成本计算，1 工位回本 **4.31 周**、4 工位 **3.95 周**
（rebuild 策略），5 工位 **5.13 周**（sell-all 对照），9 工位 **49.33 周**。
设计卡的目标是 6.95 / 6.14 周（28 天周期口径）；季度化后低资本档回本落在 **3.95–5.13 周**，
低于 6–10 周目标的下沿，而高资本档在季度内根本回不来。

**证据**：

| 策略 | 工位数 | 资本 C | Q1 净现金 | 回本周 = 13×C / 净现金 | 对照设计卡 |
|---|---:|---:|---:|---:|---:|
| rebuild1 | 1 | 100,000 | 301,760 | **4.31** | 6.95 |
| rebuild4 | 4 | 381,643 | 1,255,230 | **3.95** | 6.14 |
| sell-all 5 工位（TEMP 对照） | 5 | 547,718 | 1,389,275 | **5.13** | — |
| rebuild10 | 9（Q1 末） | 2,034,818 | 536,243 | **49.33** | 不回本 |

> C 按 `T-CityLite.base/resources/[custom]/custom-industry/config/facility.lua:16-17` 的
> `baseCost=50,000` 与 `workstationCap=10`、`T-CityLite.base/resources/[custom]/custom-industry/server/facility.lua:90-96` 的 `floor(50,000×1.35^current)`
> 逐级求和；净现金来自 2.3 的仿真输出。设计卡的 6.95/6.14 见
> `docs/server-design/12-industry-operations.md:294-296`，其口径是 28 天 10/10/5/3 阶段，
> 与当前“13 周 + 每周四季”不同，只作方向对照。

**补充对照**：同样“能卖就卖”，5 工位净现金 **1,389,275**，7 工位 **1,303,536**，9 工位 **536,243**；
本次扫描的利润峰值在 **5 工位**，不是 `workstationCap=10`。也就是说 `max` 策略（有钱就建）是
**过度投资**，不是利润最优；设计卡 §10.3 的“满建不是利润最优”在季度化后更加明显。

**口径纠错（引用 `docs/research/kittens-game-loop.md` 时注意）**：该文 §4.4 的季度回本公式写作
`4C / (N×R − C)`（`docs/research/kittens-game-loop.md:337-338`）。按 4N 周季度推导，正确应为
`4C / (R − C/N)`（等价于 `4N·C / (N×R − C)`）；原文公式少了因子 N，所以表中 1.07 / 1.01 周
偏低约 3 倍。方向（季度化 → 资本摊销拉长 → 回本缩短）成立，但引用具体周数时应按本文口径重算。

**风险**：回本数字是“仿真策略每小时都能卖”的上界；真实玩家上线频率低，库存会先满，收入会低于此。
另外，季度结算删除设施意味着资本每 13 周重投一次；如果后续调整季度长度或资本价格，必须重跑本表。

### 2.5 马太效应判断：组织层被压住，个人层没有

**结论**：

- **组织层**：季度软重置确实压住了“资产复利”——设施 / 工位 / 库存 / 金库余额每季清零，
  净现金倍率稳定在 **4.16–4.71×**，没有随季度放大；10 工位不优于 4 工位。
- **个人层**：重置压不住已经从金库提走 / 分配走的钱。Boss 每周最多提现 $25k（13 周 = $325k 毛额、
  $260k 净额，20% 税销毁）全部进 Boss 个人银行；季度结算再把剩余金库按 **Boss 40% / 非 Boss 成员平分**
  分配（只有在线成员参与；单人 Boss 拿 100%）。这两个通道都不经过季度清零。
- **Boss vs 成员**：以 rebuild4 Q4 为例（剩余金库 $1,824,227，Boss 已提满 $325k 毛额），
  1 Boss + 3 名成员时 Boss 净收入约 **$989,691**，每名成员约 **$364,845**，比值 **2.71×**；
  1 Boss + 9 名成员时每名约 **$121,615**，比值 **8.14×**。rebuild1（小组织）1 Boss + 3 人时
  Boss 约 **$392,040**、成员每名 **$66,020**，比值 **5.94×** —— 与 `docs/plan/industry-ops/10-plan.md:40`
  的“$25k + 20% 税时 5.3x”同一量级。
- **单人组织最优**：`planShares` 在没有非 Boss 在线成员时把 `total` 全给 Boss
  （`T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua:150-168`；
  前提是 Boss 本人结算时在线——离线 Boss 拿不到分配，余额会被清零）。
  所以从 Boss 个人收入看，**不招成员 / 让成员结算时离线** 是严格更优的；这与“组织经营”的设计目标相反。
- **idle 免费提现**：`idle` 策略 0 收入、0 设施，52 周仍提现 **$800,000 毛额 / $640,000 净额**。
  原因是季度结算对任何在 `listOrgs` 里的组织都发 `200,000 + 10,000×prestige`
  （`T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua:69-78`、`:505-519`），
  而 `listOrgs` 包含所有有 `org_treasury` 行的组织（`:275-295`）。**起跑金不需要重建，也不需要设施。**

**证据**：代码路径同上；分支/函数位置：
`T-CityLite.base/resources/[custom]/custom-industry/server/treasury.lua:182-283`（周额度 + 税 + 审计）、
`:394-414`（开户）、`:446-493`（结算清零）；
`T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua:104-131`（只收集在线成员）、
`:138-175`（Boss 40% / 成员平分；单人 Boss 100%）、`:210-267`（分配流水）。

**风险**：
1. 起跑金是“无条件 + prestige 津贴无上限”，会随老组织 prestige 点数增长而放大；
   真机 `starter=410000`（prestige 21）说明这个通道已经在线上发生。
2. 分配只覆盖在线成员，离线成员拿不到；Boss 可以通过“让成员离线 / 不招人”提高个人份额。
3. 本次仿真没有模拟在线成员（`GetQBPlayers` 返回空），所以分配额在仿真里是 0；上面的 Boss/成员数字
   是按 `planShares` 代码 + 仿真剩余金库推导的**结构值**，不是仿真输出，也不是玩家行为预测。

---

## 3. 性能：心跳 SQL 与复杂度

### 3.1 心跳路径

**结论**：`industry_tick_seconds` 默认 30 秒；同一个线程先跑 `IndustryCycle.Tick`，再跑
`IndustryProduction.SettleAll`。每条 tick 的 SQL = 1 条周期状态读 + 1 条设施清单读 + 每组织 3 条读 + 可选的 CAS 写。

**证据**：

- 线程与等待：`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:299-324`
  （`Wait(waitMs)`，`waitMs = TickSeconds × 1000`）。
- 默认 30 秒：`T-CityLite.base/resources/[custom]/custom-industry/config/production.lua:33`。
- 顺序：`onTick`（即 `IndustryCycle.Tick`）先于 `SettleAll`（`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:310-317`；
  `T-CityLite.base/resources/[custom]/custom-industry/server/main.lua:63`）。
- `SettleAll` 先查组织清单，再逐组织调 `SettleFacility`（`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:262-274`）。

### 3.2 每个 tick 的 SQL 清单

**结论**：逐组织查询是 N+1；`industry_state` 单行被每个组织重复读，`org_treasury.prestige` 也是逐组织读。

**证据**（按 tick 执行顺序）：

1. 周期状态（`IndustryCycle.Tick` → `Current`）：
   `T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua:374-385`
   ```sql
   SELECT id, cycle_no, phase,
          UNIX_TIMESTAMP(phase_started_at) AS started_epoch,
          UNIX_TIMESTAMP(phase_ends_at) AS ends_epoch,
          (warning_announced_at IS NOT NULL) AS warning_done,
          settled_cycle_no, result_announced_cycle,
          quarter_no, season, season_no,
          UNIX_TIMESTAMP(season_started_at) AS season_started_epoch,
          UNIX_TIMESTAMP(season_ends_at) AS season_ends_epoch,
          UNIX_TIMESTAMP(quarter_started_at) AS quarter_started_epoch,
          UNIX_TIMESTAMP(quarter_ends_at) AS quarter_ends_epoch
   FROM industry_state WHERE id = 1 LIMIT 1
   ```
2. 组织清单：`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:263-265`
   ```sql
   SELECT org_id FROM industry_facility ORDER BY org_id LIMIT ?
   ```
   `?` = `SETTLE_BATCH_LIMIT = 200`（`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:23`），**不是**配置里的 500。
3. 每组织读设施：`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:148-157`
   ```sql
   SELECT org_id, facility_type, workstations, stock_level, stock,
          UNIX_TIMESTAMP(last_tick_at) AS last_tick_epoch
   FROM industry_facility WHERE org_id = ? LIMIT 1
   ```
4. 每组织读周期状态：`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:194` 调 `IndustryCycle.Current()`，SQL 同 1。
5. 每组织读威望：`T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua:87-89`
   ```sql
   SELECT prestige FROM org_treasury WHERE org_id = ? LIMIT 1
   ```
6. 可选 CAS 写（只有本 tick 产出 ≥1 单位时）：`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:231-239`
   ```sql
   UPDATE industry_facility
   SET stock = stock + ?, produced_units = produced_units + ?,
       last_tick_at = FROM_UNIXTIME(?)
   WHERE org_id = ? AND last_tick_at = FROM_UNIXTIME(?) AND stock = ?
   ```

**边界情况**：季节切换时 `RollSeason` 会多一条 `UPDATE industry_state`（`T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua:762-779`）、
`EnsureSeed` 的 `INSERT IGNORE` + `UPDATE industry_demand`（`T-CityLite.base/resources/[custom]/custom-industry/server/sale.lua:318-327`）
和一条审计 `INSERT`（`T-CityLite.base/resources/[custom]/custom-industry/server/audit.lua:38-47`）。
实测单次 `Tick` 最大 7 条 SQL（见 3.3）。

### 3.3 实测

**结论**：假 DB 上实测 1 组织每 tick 5 条读（无写入）、2 组织 8 条读；每组织 3 条读是固定的。

**证据**：用 TEMP 脚本 临时脚本 measure_sql.py（未入库） 包装 `SettleFacility` / `SettleAll` /
`IndustryCycle.Tick`，统计 `__sqlLog` 增量；真实输出：

```text
MEASURE|driver_1week_1org|settle_calls=168|settle_total=672|settle_max=4|settle_last=4|tick_calls=168|tick_total=192|tick_max=7|tick_last=7|...
MEASURE|settleall_1org_nowrite|ok=true|err=nil|settle_last=3|all_last=4|settled=1|failed=0
MEASURE|settleall_1org_write|ok=true|err=nil|settle_last=4|all_last=5|settled=1|failed=0
MEASURE|settleall_2orgs_nowrite|ok=true|err=nil|settle_last=3|all_last=7|settled=2|failed=0
MEASURE|cycle_tick_not_due|ok=true|err=nil|tick_last=1
```

读法：
- `settle_last=3`：每组织 3 条读（设施 / `industry_state` / `org_treasury.prestige`）。
- `settle_last=4`：本 tick 有产出，多一条 CAS UPDATE。
- `all_last=4`（1 组织无写）= 1 条组织清单 + 3 条逐组织读；`all_last=7`（2 组织）= 1 + 2×3。
- `cycle_tick_not_due` 1 条：未到换季边界时 `Tick` 只读一次 `industry_state`。
- 小时级 driver 的 168 次 `SettleFacility` 共 672 条（每次 4 条：3 读 + 1 写），
  168 次 `Tick` 共 192 条（平均 1.14，换季最大 7）。

**风险**：这是假 DB 的**语句计数**，不是真实 MySQL 延迟 / 连接池 / 主线程阻塞的测量；
没有做 200+ 组织的压测。真实延迟需要 FXServer + MariaDB 才能测。

### 3.4 复杂度与 N+1

**结论**：每 tick 的读 SQL 是 **3N + 2**；写 SQL 期望是 **0.0375 × 工位数 × N**（30 秒 tick、
4.5 单位/小时/工位，`floor` 后不足 1 单位不写；10 工位时每组织 0.375 条/ tick）。
工位数增加不会增加查询数，只增加写频率。

**证据 / 折算**（读 = 3N+2；写 = N × 工位 × 4.5 × 30 / 3600）：

| 组织数 N | 每 tick 读 SQL | 每 tick 写 SQL（每组织 10 工位） | 读 QPS（30 秒 tick） |
|---:|---:|---:|---:|
| 1 | 5 | 0.375 | 0.17 |
| 2 | 8 | 0.75 | 0.27 |
| 10 | 32 | 3.75 | 1.07 |
| 200（当前硬上限） | 602 | 75 | 20.1 |
| 500（`MaxOrgsPerSettle` 配置值，若放开） | 1,502 | 187.5 | 50.1 |

> 折算值是公式推导（读 QPS = 读 SQL / 30 秒），不是压测输出；`MaxOrgsPerSettle` 见
> `T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua:90`，
> 生产心跳的硬上限见 `T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:23`。

**N+1 的具体形状**：
- `industry_state` 是单行表，但每个组织都重读一次（`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:194` → `T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua:391`）；
  一次 tick 里同一个 1 行结果被读 N+1 次（Tick 1 次 + 每组织 1 次）。
- `org_treasury.prestige` 每组织 1 次（`T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua:87-89`），可以并进设施查询。
- 设施本身每组织 1 次（`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:149-153`），而清单查询已经扫了 `industry_facility`；
  可以在清单查询里直接取 `facility_type / workstations / stock_level / stock / last_tick_at / prestige`。
- 优化后形状：每 tick 1 条状态读 + 1 条设施+威望联表读 + 每组织 1 条 CAS 写（只在有产出时）。
  在 N=200 时，读从 602 降到 ~2，写从 75 降到 ~75（写不能省，但可以减少往返）。

**另一个问题（不是性能，是公平）**：`SETTLE_BATCH_LIMIT=200` 与
`Config.Industry.Cycle.MaxOrgsPerSettle=500` 不一致，且 `ORDER BY org_id LIMIT 200` 每次选同一批
字典序前 200 的组织；第 201 个及以后的组织**永远不会被心跳结算**，只能靠玩家上线
（`SettleForPlayer`，`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:279-291`）或控制台 `orgproduce`（`T-CityLite.base/resources/[custom]/custom-industry/server/commands_production.lua:27-42`）。
当前只有 2 个组织，不受影响；组织数增长后是静默饥饿。

**风险**：在 2 个组织的当前规模，3N+2 的 N+1 不是瓶颈（8 条读 / 30 秒）；优化是**规模准备**，不是救火。
但如果把 `MaxOrgsPerSettle` 当成真实上限（500）而不同步 `SETTLE_BATCH_LIMIT`，会出现“配置说 500、
实际只结算 200”的静默不一致。

---

## 4. UX：手机与命令的缺口

### 4.1 对照口径

**结论**：设计稿 S5 的口径是“Boss 菜单完成 S1–S4，成员手机只读快照”
（`docs/server-design/12-industry-operations.md:182-183`）；实际 W1/P3/P5 已经把卖出、雇工位、
库存升级、提现做进手机（`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte:405-490`、
`T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua:185-268`），
但**建厂、存款、流水、周期倒计时、威望**仍然没有 UI。

**证据**：手机 App 的 `actions` 只有 `sell / hire / upgrade_stock / withdraw`
（`T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua:185-268`）；
快照字段含 `prestige` 与 `phase.endsAt`（`T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua:184`、`:189`），
但 Svelte 的类型与模板都没有用它们（`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte:17`、`:53-65`、`:337-342`）。

### 4.2 操作矩阵

| 操作 | 手机可做？ | 现在的入口 | 缺失点 |
|---|---|---|---|
| **建厂 build** | ❌ | 只有 `/orgbuild <orgId> <facilityType>`（Boss，在线），`T-CityLite.base/resources/[custom]/custom-industry/server/commands_facility.lua:52-89` | 手机和 Boss 菜单都没有按钮；手机空状态说“先在 Boss 菜单里建厂”（`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte:382-384`），Boss 菜单说“建造入口仍由 `/orgbuild`（控制台）负责”（`T-CityLite.base/resources/[custom]/custom-industry/client/main.lua:81-88`）。季度结算每 13 周删设施，所以每季都必须打字复工。 |
| **雇工位 hire** | ✅（单个） | 手机按钮 `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte:450-463`；手机 action `hire`（`T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua:216-228`） | 批量 1–10 个只有 `/orghire <orgId> [count]`（`T-CityLite.base/resources/[custom]/custom-industry/server/commands_facility.lua:91-154`）；手机一次一个。 |
| **卖出 sell** | ✅ | 手机数量 + 估价 + 确认（`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte:405-448`）；服务端 `IndustryUi.Sell`（`T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua:359-394`） | 无缺口；估价/成交都走服务端。 |
| **库存升级 upgrade_stock** | ✅ | 手机按钮（`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte:465-490`）；手机 action（`T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua:229-247`） | 无缺口；但季度结算会删设施，库存等级也一起清零，升级是**季度内**投资。 |
| **提现 withdraw** | ✅ | 手机提现卡（`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte:345-380`）；P5 与 `/orgfundwithdraw` 共用 `Treasury.WithdrawForPlayer`（`T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua:447-454`） | 无缺口；手机还会显示本周已提/额度/税后到账。 |
| **查到设施 facility** | ✅ | 手机设施卡（`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte:385-400`）；服务端快照 `T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua:209-285` | 没有 `last_tick_at`、生产速率、离满仓时间；玩家不知道“现在上线还能不能卖”。 |
| **周期信息 cycle** | ⚠️ 部分 | 手机标题显示 `phase.label`（季节）与 `phase.cycleNo`（全局周号），`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte:337-342` | 没有季度号、季度内第几周、季节结束倒计时、季度结束时间、下一季；`phase.endsAt` 在快照里但没渲染（`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte:17` 声明后未使用）。 |
| **存入资金 deposit** | ❌ | 只有 `/orgfunddeposit <orgId> <amount>`（`T-CityLite.base/resources/[custom]/custom-industry/server/commands.lua:122-169`） | 手机没有存款入口；季度重置后 Boss 想追加资本只能打字。 |
| **查流水 ledger** | ❌ | 只有 `/orgfund <orgId> [limit]`（`T-CityLite.base/resources/[custom]/custom-industry/server/commands.lua:70-120`） | 手机只显示余额，不显示最近流水 / 拒绝原因。 |
| **季度结果 history** | ❌ | 只有 CityFeed 公告 / 控制台日志 / `industry_cycle_results` 表 | 没有 `/industry_results` 或手机卡片；玩家看不到自己上季收入、威望、分配。 |
| **威望 prestige** | ❌ | 快照有 `prestige` 对象（`T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua:184`），手机类型/模板没有；Boss 菜单也没有 | 永久进度不可见；这是“下一轮更快”的唯一跨季钩子，却没有展示。 |
| **开户 account** | ❌ | 只有控制台 `/orgfundgrant` 调 `Treasury.EnsureAccount`（`T-CityLite.base/resources/[custom]/custom-industry/server/commands.lua:255-256`） | `/orgfunddeposit` 要求账户已存在（`Treasury.Deposit` → `apply`，`T-CityLite.base/resources/[custom]/custom-industry/server/treasury.lua:359-368` 返回 `no_account`），玩家无法自助开户；新组织必须先找管理员。 |

### 4.3 关键缺口（按影响排序）

1. **建厂没有 UI**：这是季度循环的“第一天动作”。季度结算删设施（`T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua:489-490`），
   手机/Boss 菜单都没有建厂入口；玩家必须在聊天框输入 `/orgbuild mining_co mine`。
   这不是“少一个按钮”，而是**每 13 周一次的重置后无法从 UI 复工**。
2. **周期倒计时不可见**：`phase.endsAt` 已经在快照里，手机没渲染；季度结束时间（`quarter_ends_at`）
   根本没进快照。玩家只能靠 7 天前的 CityFeed 警告（`T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua:327-340`、`:684-705`）或记忆。
3. **威望不可见**：跨季唯一永久收益不显示；玩家看不到“再打一季能多 +2%”的进度。
4. **存款 / 流水不可见**：Boss 在季度重置后追加资本、对账、解释拒绝原因，都要靠聊天命令。
5. **开户只能找管理员**：新组织无法自助开始；与“手机是主入口”的产品方向冲突。

**风险**：手机和 Boss 菜单已经分叉（手机有提现/库存升级，菜单只有雇/卖）；
再往手机加建厂/存款会继续扩大两套 UI 的差异。建议先明确**单一主入口**（手机），
Boss 菜单只保留“打开手机产业 App”或同等能力的只读摘要。

---

## 5. 可观测性：静默失败与诊断面

### 5.1 现在看不到什么

**结论**：目前只有“结算成功/失败”的控制台日志和 CityFeed 公告；没有状态查询、审计查询、
季度结果查询、指标导出。玩家与管理员对“周期卡住 / 生产停了 / 钱去哪了”都缺少可查的事实。

**证据**：

- 周期状态只在 `industry_state` 单行表；没有 `industry_status` 命令。
  `T-CityLite.base/resources/[custom]/custom-industry/server/commands_cycle.lua:86-117`
  只注册了 `industry_setphase` / `industry_settle`（restricted，仅控制台）。
- 审计只写不读：`T-CityLite.base/resources/[custom]/custom-industry/server/audit.lua:30-53`
  只有 `Write`；`Treasury.GetLedger` 读的是 `org_ledger`
  （`T-CityLite.base/resources/[custom]/custom-industry/server/treasury.lua:510-523`），不是 `industry_audit`。
- 季度结果只写表 + 公告：`T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua:826-846` 写 `cycle.settle` 审计；
  `T-CityLite.base/resources/[custom]/custom-industry/server/announce.lua:233-270` 发 CityFeed/推送；没有玩家可查的历史。
- 指标只有卖出流入：`T-CityLite.base/resources/[system]/economy-dashboard/server/main.lua:35-36`、
  `:86-96` 只订阅 `industry:sale`；税销毁、起跑金、季度分配、提现、满仓率、配额利用率、
  组织份额都没有进 dashboard。
- 手机快照没有 `last_tick_at` / 生产速率 / 满仓 ETA（`T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua:254-270` 只给 stock/cap）。

### 5.2 #420 类静默卡死的代码路径

**结论**：`RollSeason` 的 guarded UPDATE 返回 0 行时返回 `false, 'conflict'`；
`tickTwoClock` 把 false 继续往上抛；`IndustryCycle.Tick` 返回 false；而生产心跳只记录 **pcall 抛错**，
不记录 `ok == false`。所以 `phase`/`season` 不一致导致的季节推进失败不会留下任何日志。

**证据**：

```lua
-- T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua:779-781
local affected, updateErr = Db.Update(sql, params)
if updateErr then return false, 'db_error' end
if affected ~= 1 then return false, 'conflict' end
```

```lua
-- T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:310-321
if hooks.onTick then
    local called, tickErr = pcall(hooks.onTick, os.time())
    if not called then
        print(('[custom-industry] CRITICAL cycle tick failed: %s'):format(tostring(tickErr)))
    end
end
local ok, err = IndustryProduction.SettleAll({ trigger = 'tick' })
if not ok then
    print(('[custom-industry] production tick failed: %s'):format(tostring(err)))
end
```

`called == true` 但 `IndustryCycle.Tick` 返回 `false, 'conflict'` 时，上面没有任何分支会打印。
`SettleAll` 的逐组织失败也只汇总在 `stats.failed`（`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:268-273`），调用方
`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:317` 只检查 `ok`，不检查 `stats.failed`。同类静默返回还有：
`Tick` 重入 `return false, 'busy'`（`T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua:842-843`）、
`Current()` 的 `bad_season`（`T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua:418-421`）。

**风险**：加日志只能让 #420 可见，不能修 #420 的根因（`phase`/`season` 一致性校验）；
两者应分开建 issue：一个 fix 根因，一个 ops 加诊断。

### 5.3 应该有的诊断面与最小实现代价

| 诊断面 | 现在只有 | 最小实现 | 估工 |
|---|---|---|---|
| 周期状态 / 倒计时 | DB 单行表 + 控制台日志 | `industry_status`（restricted + source==0）：`cycle_no / quarter_no / season / week_of_quarter / season_ends_at / quarter_ends_at / settled_cycle_no / warning_done`，并把 `now` 与各边界的剩余秒数打印出来 | S |
| Tick 失败 | 只有 pcall 抛错日志 | `Tick` / `RollSeason` 返回非 ok 时打印 `errcode + cycle_no + phase + season_no`，按 `RetryLogSeconds` 节流；`SettleAll` 的 `stats.failed > 0` 也打一行 | S |
| 逐组织结算失败 | 汇总后丢弃 | `SettleAll` 在 `stats.failed > 0` 时打印 `settled/failed` 与第一个 errcode | S |
| 审计查询 | 只有 `industry_audit` 表 | `/industry_audit <orgId> [limit]`（Boss/admin/console），显式列 + LIMIT，payload 原样 | S |
| 季度结果 | CityFeed / 控制台 / 表 | `/industry_results <orgId> [limit]` 读 `industry_cycle_results`（quarter_no / revenue / produced_units / prestige_awarded / balance_cleared） | S |
| 组织侧指标 | dashboard 只有 `industry:sale` 流入 | 扩展 dashboard：`industry:withdraw` / `industry:settle` 事件，或周期导出 JSON（税销毁、起跑金、分配、提现、满仓率、配额利用率、组织份额） | M |
| 生产停滞 | `last_tick_at` 在 DB | 快照/状态命令显示 `now - last_tick_at`；超过 `2×TickSeconds` 标黄，超过 `MaxCatchupSeconds` 标红 | M |
| 手机倒计时 | `phase.endsAt` 未渲染 | 手机渲染季节倒计时 + 季度号/周序 + 季度结束时间 + 威望/下一级加成 | S |

**最小代价口径**：S ≤ 0.5 人日，M = 1–2 人日。以上都不需要改 schema；
`industry_audit` 已有 `(org_id, created_at)` 索引（`T-CityLite.base/migrations/v4.0_industry_treasury.sql:49`），
`industry_cycle_results` 已有 `UNIQUE(org_id, quarter_no)`（`T-CityLite.base/migrations/v4.5_industry_quarter.sql:151-171`）。

**风险**：状态/审计命令必须只读、带 `LIMIT`、不落 PII；日志不能每 tick 刷屏（#420 的 `conflict`
会持续存在，按 `RetryLogSeconds` 节流）。指标导出不要新增货币事件，只读现有表/事件。

---

## 6. 玩法深度：对照 Kittens Game

**结论**：当前实现已经有“离线生产 + 库存上限 + 下一工位价格 + 季度警告”这几条底座；
真正缺的是**可见的永久进度 / 倒计时 / 离线 check-in**、**能改变决策类型的季节平衡**、
以及**组织间竞争的可感知反馈**。按投入/收益，先做 UI 与提醒（S），再修季节平衡（M），
订单/配方放在经济修复之后（L）；跨季保留设施/库存不做（会抵消软重置）。
设施等级和 `iron_smelt` 配方目前是死配置，不要在修经济之前先做。

### 6.1 机制对照

对照 `docs/research/kittens-game-loop.md:192-215` 的“黏性八条”，当前实现的状态：

| Kittens 机制 | 当前实现 | 缺口 | 判断 |
|---|---|---|---|
| 离线进度（redshift） | 惰性生产 + 库存上限 + 1 小时追赶（`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:49-55`） | 库存满/换季没有提醒；离线玩家不知道“什么时候该回来” | ✅ 有，缺提醒 |
| 可见的下一步 | 手机显示下一工位价格、下一级库存价格（`T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Industry.svelte:452-476`） | 没有威望/下一级加成、离满仓时间、边际回本、季度目标 | ⚠️ 半有 |
| 损失厌恶（可预期） | 季度结束前 7 天 CityFeed 警告；库存满冻结 | 手机没有倒计时；没有“满仓提醒”；没有限时目标 | ⚠️ 半有 |
| 收藏与解锁 | 无 | 无称号/成就/编年史 | ❌ |
| 数值里程碑 | 威望存在（`T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua:184`）但不可见 | 手机/Boss 菜单都不显示；没有季度目标/排名 | ⚠️ 有数据无展示 |
| 主动检查（check-in） | 换季只推在线成员（`T-CityLite.base/resources/[custom]/custom-industry/server/announce.lua:272-292`）；季度警告/结果发 CityFeed | 离线成员错过换季；没有“冬季来了/库存满了”的持久提醒 | ⚠️ 半有 |
| 精通/优化 | 建/卖/提现/升级的数值选择 | 当前 sell-all 支配 hoard（见 6.2）；UI 不解释边际收益 | ❌ 决策不成立 |
| 社交/对比 | 全服配额 + 单组织 50% 上限 | 没有排行榜/份额反馈/季度荣誉 | ❌ |

### 6.2 具体缺失与实证

**结论 1：冬季“囤货过冬”不是优势策略。** 当前每周四季、每季配额独立且“用完即弃”
（`docs/plan/industry-ops/10-plan.md:25`、`T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua:112-137`），
冬季产能 0.25、售价 1.5、配额 1.3；只卖冬季会放弃春/夏/秋三季配额。用配置乘数算，
全季卖满的收入权重是 `1.0×1.0 + 0.85×0.95 + 0.7×1.1 + 1.3×1.5 = 4.5275`，
只卖冬季是 `1.3×1.5 = 1.95`，理论上限只有全季的 **43%**。

真实仿真对照（TEMP 脚本 临时脚本 hoard_sweep.py（未入库），13 周）：

| 策略 | 工位 | 库存级 | Q1 收入 | Q1 净现金 |
|---|---:|---:|---:|---:|
| sell-all 5 工位 | 5 | 0 | **1,936,993** | **1,389,275** |
| sell-all 5 工位 + 库存升级 | 5 | 5 | 1,571,832 | 391,730 |
| 内置 hoard（只卖 ≥1.2×，即冬季） | 5 | 5 | 1,494,075 | 313,973 |
| hoard 阈值 1.1、目标 5 工位 | 5 | 5 | 1,002,955 | 84,997 |
| sell-all 7 工位 | 7 | 0 | 2,378,127 | 1,303,536 |

原始 stdout：

```text
hoard_thr1.2_targetcap: rev=1494075 ws=5 treasury=263973 withdrawals=250000 prestige=0 net=313973
hoard_thr1.1_target5: rev=1002955 ws=5 treasury=109997 withdrawals=175000 prestige=0 net=84997
hoard_thr1.1_target7: rev=1002955 ws=5 treasury=109997 withdrawals=175000 prestige=0 net=84997
hoard_thr1.0_target7: rev=880200 ws=4 treasury=53317 withdrawals=275000 prestige=0 net=128317
sellall_target5: rev=1936993 ws=5 treasury=1289275 withdrawals=300000 prestige=0 net=1389275
sellall_target7: rev=2378127 ws=7 treasury=1203536 withdrawals=300000 prestige=0 net=1303536
sell5_plus_stock_upgrades: rev= 1571832 ws= 5 stock_level= 5 treasury= 316730 withdrawals= 275000 net= 391730
```

结论：**sell-all 在 5 工位和 7 工位都支配 hoard**；把阈值降到 1.1 更差（秋季 1.1× 卖掉了本该留给冬季 1.5× 的库存）。
P3 库存升级在“每小时都能卖”的操作下不回本（净现金 391,730 vs 1,389,275），
因为它只增加缓冲、不增加配额；它的真实价值取决于玩家上线频率（仿真未建模）。
`docs/plan/industry-ops/10-plan.md:46-47` 说“囤货与卖光差 +0.6%”，本次用内置策略**没有复现**；
要么当时的策略/配额模型不同，要么需要一次显式的阈值×库存×工位扫描来重定。

**结论 2：P3 库存升级的“跨季价值”被季度结算抹掉。** `stock_level` 在 `industry_facility` 行上
（`T-CityLite.base/migrations/v4.1_industry_facility.sql`），季度结算删行（`T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua:489-490`），
所以 $40,000×1.6^n 的升级每 13 周重新买一次。它只在“本季内囤货/离线缓冲”有意义；
如果玩家不打算囤货，它是纯成本。

**结论 3：配方与设施等级是死配置。** `T-CityLite.base/resources/[custom]/custom-industry/config/facility.lua:26-36` 的 `iron_smelt`
（3 iron_ore → 1 iron_ingot，60 秒）没有被 `T-CityLite.base/resources/[custom]/custom-industry/server/production.lua` 读取；生产只按
`workstations × 4.5/h × 倍率` 直接产 `SeedItem`（`T-CityLite.base/resources/[custom]/custom-industry/config/production.lua:27`、
`T-CityLite.base/resources/[custom]/custom-industry/server/production.lua:113-143`）。`facility.maxLevel=5` 与 `industry_facility.level` 也没有升级函数
（`T-CityLite.base/resources/[custom]/custom-industry/server/facility.lua` 只有 Build/AddWorkstation/UpgradeStock）。所以 Kittens 的“转化损耗”和“建筑等级”
两条深度机制目前都不存在。

**结论 4：组织间竞争不可感知。** 只有 `industry_demand.quota_used` 与单组织 50% 上限
（`T-CityLite.base/resources/[custom]/custom-industry/config/sales.lua:31-39`），
没有“谁卖了多少 / 本季份额 / 排行榜”；玩家只能看到“全服剩 N 件”。多组织是 T-City 相对 Kittens 单机的优势，
现在没有变成可感知的反馈。

### 6.3 投入 / 收益排序

| 机制 | 投入 | 收益 | 依赖 / 风险 | 建议 |
|---|---|---|---|---|
| 手机显示威望 / 下一级加成 | S | 高（唯一永久进度不可见） | 数据已在快照，只改 UI | **做** |
| 手机显示季节/季度倒计时 + 离满仓时间 | S | 高（重置前决策 + 上线时机） | `endsAt` 已在快照；加 `quarter_ends_at` / 生产速率 | **做** |
| 离线换季/满仓提醒写 CityFeed | S/M | 高（check-in） | 复用 `custom-phone` CityFeed；不新增事件 | **做** |
| 季度结果 / 排行榜（荣誉，不改钱） | M | 中（社交对比 + 收尾） | 读 `industry_results` / `industry_sales` | **做** |
| 修季节平衡（让 hoard 有机会成立） | M | 高（“四季改变决策”是 Kittens 最值得搬的） | 需要参数扫描；可能要改配额/价格/产能 | **先扫描再定** |
| 限时订单 / 合同（消耗现有配额，不新增配额） | L | 高潜力（主动 check-in） | 必须服务端权威、限时限量、不新增货币/配额 | 经济修完后做 |
| 二段配方（ore→ingot，转化损耗） | L | 中（多一条链） | 新物品、销售价、UI、库存；MVP 范围外 | 以后 |
| 成就/称号/编年史 | M | 中（非经济留存） | 只给 cosmetic，不给经济加成 | 以后 |
| 设施等级 | M | 低（与工位/库存等级重复） | 第三条成本曲线 + UI | 暂不做 |
| 跨季保留设施/库存 | L | 负（抵消软重置） | 与反马太目标冲突 | **不做** |

### 6.4 与 `docs/research/kittens-game-loop.md` 的差异提醒

该文 §4.4 已经预警“季度化 + 设施跨季保留会把资本摊销拉长 3 倍”，并推荐路径 C（维护费）。
当前实现正是该文警告的“设施在一个季度内只建一次、季度末随结算删除”的场景
（13 周 ≈ 3.25 个 28 天周期）；所以摊销问题成立，只是它选择的回收方式是
“删除设施 + 无条件起跑金”，而不是维护费。该文表里的 1.07 / 1.01 周因公式缺因子 N
偏低约 3 倍；本文 2.4 用当前仿真重算为 1 工位 4.31 周、4 工位 3.95 周、9 工位 49.33 周。
引用时以本文的重算口径为准。

另外，`docs/plan/industry-ops/10-plan.md:54` 写 `RollSeason` “清配额/库存”，
但代码只更新状态 + 补配额种子，**不清库存**（`T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua:762-789`、`T-CityLite.base/resources/[custom]/custom-industry/server/sale.lua:305-330`）。
库存跨季保留是“囤货过冬”可行的前提；如果按文档清库存，hoard 策略直接不成立。
这是一处需要回写的文档/实现不一致。

### 6.5 风险

- 增加“限时订单/合同”如果**新增配额或新增货币**，会成为第二个印钞口；必须只消耗现有配额，
  并把奖励限制在价格倍率/声望/称号，不增加总销量上限。
- 二段配方需要新物品、价格、销售入口、手机展示，工作量远大于 UI；不要在修经济之前做。
- 设施等级会与工位成本曲线、库存等级形成第三条边际曲线；没有明确角色前不要加。
- 跨季保留会直接削弱反马太，和 `docs/server-design/12-industry-operations.md:318-343` 的“三道闸”冲突。

---

## 7. 优先表

> 估工：S ≤ 0.5 人日；M = 1–2 人日；L = 3–5 人日。
> 证据强度：强 = 真实命令输出或逐行代码；中 = 代码路径/静态推导；弱 = 设计推断/未实现。

| 项 | 类型 | 证据强度 | 影响面 | 估工 | 依赖 | 建议优先级 |
|---|---|---|---|---|---|---|
| 季度起跑金改成“上季有设施/有销售才发”，并给 prestige 津贴封顶 | fix | 强 | 经济 | S | 无 | **P0** |
| 组织金库开户自助（Boss 首次存款/进产业时 `EnsureAccount`） | fix | 强 | 玩家 | S | 无 | **P0** |
| 手机 / Boss 菜单增加建厂入口（复用 `/orgbuild` 的服务端校验） | feat | 强 | 玩家 | M | 无 | **P0** |
| `Tick`/`RollSeason`/`SettleAll` 非 ok 落日志 + `industry_status` 状态命令 | ops | 强 | 运维 | S | 无 | **P0** |
| 手机展示威望/下一级加成、季度号/周序、季节与季度倒计时、离满仓时间 | ux | 强 | 玩家 | S | 无 | **P1** |
| 手机展示上季结果/分配（读 `industry_cycle_results`） | feat | 中 | 玩家 | S | 上一条 | **P1** |
| `/industry_results <orgId> [limit]` 季度结果查询 | ops | 中 | 运维/玩家 | S | 状态命令 | P2 |
| `/industry_audit <orgId> [limit]` 审计查询 | ops | 中 | 运维 | S | 状态命令 | P2 |
| 指标导出（税/起跑金/分配/提现/满仓率/配额利用率/组织份额） | ops | 中 | 经济 | M | 状态命令 | P2 |
| 每 tick 只读一次 `industry_state`；设施+威望合并查询 | perf | 强 | 性能 | M | 无 | P2 |
| `SETTLE_BATCH_LIMIT` 与 `MaxOrgsPerSettle` 对齐 / 分页轮转 | fix | 强 | 公平/性能 | S | 上一条 | P2 |
| 手机存款 / 流水（复用 `/orgfunddeposit`、`/orgfund`） | ux | 中 | 玩家 | M | 建厂入口 | P2 |
| 换季/满仓提醒写 CityFeed（离线可见） | feat | 中 | 留存 | S/M | 无 | P2 |
| 季度排行榜/荣誉（只给称号/公告，不给钱） | feat | 中 | 留存 | M | 结果查询 | P3 |
| 手机批量雇工位（1–10，复用 `/orghire` 的循环） | ux | 中 | 玩家 | S | 无 | P3 |
| 52 周 rebuild 策略纳入 CI / 基线 | ops | 强 | 回归 | M | 无 | P2 |
| 限时订单/合同（只消耗现有配额，不新增货币） | feat | 弱 | 玩法 | L | 起跑金/指标 | P3（经济修完后） |
| 二段配方（ore→ingot，带转化损耗） | feat | 弱 | 玩法 | L | 新物品/销售/UI | P4 |
| 设施等级（`maxLevel=5` 死配置） | feat | 弱 | 玩法 | M | 无 | 暂不做 |
| 跨季保留设施/库存 | feat | 弱 | 经济 | L | 需重标全部数值 | **不做** |

---

## 8. 不建议做

1. **跨季保留设施 / 工位 / 库存（或按比例保留）**：会直接抵消季度软重置，回到
   `docs/research/kittens-game-loop.md:328-361` 的资本摊销问题；和
   `docs/server-design/12-industry-operations.md:318-325` 的“周期清零”闸冲突。
2. **提高或取消周提现额度、取消 20% 税**：`docs/plan/industry-ops/10-plan.md:40` 的定值依据显示
   “额度是主开关”（$50k 时 Boss/成员 12.6×，$25k + 20% 税时 5.3×）；放宽会让财富更快转到个人层，
   季度重置更失效。
3. **无条件 / 无上限的季度起跑金（现状）**：idle 0 产出仍能 52 周提现 $800,000 毛额 / $640,000 净额；
   应改成有条件 + 封顶，而不是继续加。
4. **无上限的限时订单 / 合同 / 新配额**：会变成第二个印钞口；如果做，必须只消耗现有配额、
   限时限量、服务端权威，且奖励不增加总销量上限。
5. **每组织独立随机天气 / 天灾**：多人经济里的运气税；`docs/research/kittens-game-loop.md:394`
   明确不建议每组织独立随机。
6. **猫口饥饿 / 幸福度**：T-City 玩家是管理者，工位不吃饭；会惩罚离线玩家，并把个人层拉进产业结算
   （`docs/research/kittens-game-loop.md:389-394`）。
7. **全量硬重置（清个人银行 / 物品 / 车辆 / 房产）**：违反宪法个人层不可动；
   `T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua:11-13` 的表级清单已经把个人层排除。
8. **永久经济加成超过 +20%，或让 prestige 点数直接乘产能**：`T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua:86-87` 的 +2%/级、
   10 级封顶是刻意保守；继续加是 power creep，且难以收回。
9. **现在做二段配方 / 多资源链**：需要新物品、价格、销售、库存、手机 UI 全套；MVP 范围外。
   先修经济，再谈链深。
10. **现在做设施等级**：与工位成本曲线、库存等级重复，形成第三条边际曲线；`maxLevel=5` 至今没有升级函数，
    说明它没有明确角色。
11. **产业 PVP / 抢单战斗 / 组织间掠夺**：RP 服冲突成本高；配额 + 排行榜已经能制造竞争感
    （`docs/server-design/12-industry-operations.md:356-371` 的 MVP 不做清单）。
12. **把 Boss 菜单和手机维护成两套完整 UI**：现状已经分叉（手机有提现/库存升级，菜单只有雇/卖）；
    应统一为一个主入口，避免两份权限/文案/测试。
13. **用玩家在线时长 / 随机数作为产出倍率**：违反服务端权威与离线公平；产出只来自工位与配置。

---

## 9. 未跑 / 未验证

| # | 事项 | 状态 / 原因 |
|---|---|---|
| 1 | 真实 MySQL 延迟、连接池、FXServer 主线程阻塞 | **未跑**：只有假 DB 的语句计数；需要 FXServer + MariaDB 压测。 |
| 2 | 200+ 组织的心跳负载与 `SETTLE_BATCH_LIMIT` 饥饿 | **未跑**：当前白名单只有 2 个组织；饥饿是静态推导。 |
| 3 | 多组织抢配额时序 | **未跑**：仿真器单组织；第二条设施只用于 SQL 计数，没有卖单竞争。 |
| 4 | 玩家行为 / 留存 / 上线频率 | **未跑**：策略是脚本；库存升级的真实价值取决于上线频率，仿真未建模。 |
| 5 | 2026-11-28 真机读数 | **未重复**：`facility=1 sales=16 demand=11 prestige=+1 starter=410000 distributed=90246` 来自任务给定，本文只做公式对照。 |
| 6 | #418 / #420 的根因复现 | **未重复**：已建 issue；本文只引用 #420 的静默路径作为可观测性案例。 |
| 7 | 52 周 rebuild 补充实验 | **TEMP 脚本**：临时脚本 rebuild_probe.py（未入库），不在仓库、不进 CI；不是玩家行为预测。 |
| 8 | hoard 阈值×工位×库存的全参数扫描 | **只跑了 6 组**（见 6.2）；没有覆盖全部阈值/工位/库存组合。 |
| 9 | 限时订单 / 配方 / 设施等级的工期 | **设计估计**：未实现，L/M 是量级，不是承诺。 |
| 10 | `docs/research/kittens-game-loop.md` §4.4 公式纠错的独立复核 | **静态推导**：按 4N 周季度推导；未找原作者确认。 |

---

## 10. 附录：复现命令与临时脚本

**仓库内命令**（不改代码）：

```bash
python tools/dev/industry_sim/run_sim.py --weeks 52 --policy idle   --out /tmp/idle.jsonl
python tools/dev/industry_sim/run_sim.py --weeks 52 --policy steady --out /tmp/steady.jsonl
python tools/dev/industry_sim/run_sim.py --weeks 52 --policy max    --out /tmp/max.jsonl
python tools/dev/industry_sim/run_sim.py --weeks 52 --policy hoard  --out /tmp/hoard.jsonl
python tools/dev/industry_sim/run_sim.py --weeks 13 --policy steady --out /tmp/steady13.jsonl \
  --baseline T-CityLite.base/tests/architecture/industry_sim_baseline.json
```

**临时脚本**（Windows 临时文件 %TEMP%/industry-opt-tools/，不属于仓库）：

| 脚本 | 用途 |
|---|---|
| `analyze.py` | 按 quarter 聚合四条策略的 JSONL |
| `measure_sql.py` | 包装 `SettleFacility` / `SettleAll` / `IndustryCycle.Tick` 统计 SQL |
| `rebuild_probe.py` | 52 周 rebuild1/4/10 补充实验 |
| `hoard_sweep.py` | hoard 阈值 / 工位对照 |
| `sell5.py`、`sell5_upgrade.py` | 5 工位 sell-all 与库存升级对照 |

> 这些脚本只 import 仓库的 `industry_harness` / `run_sim`，不写仓库文件；
> 本文所有“TEMP 补充实验”数字都来自它们的真实 stdout。
