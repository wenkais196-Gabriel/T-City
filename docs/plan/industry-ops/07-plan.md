---
id: industry-ops-w0-balance-plan
type: plan
status: active
system: economy
owner: hermes
updated: 2026-11-27
review_by: 2027-03-31
stage: P
plan_status: 1
---

# 计划：W0 — 产业数值卡与真实周期长度（#387）

> 上游：[12 — 产业运营与组织运营](../../server-design/12-industry-operations.md) §5/§10/§20；
> 施工单元：[#387](https://github.com/wenkais196-Gabriel/T-City/issues/387)；
> 分支 `feat/industry-balance`（push 回该分支；未开 PR，PR 由 Hermes 开）。
>
> 本片只改**配置值 + 测试 + 文档**：不动 `industry_state` 的四个阶段枚举、不动 schema、
> 不加迁移、不改 `SettleSale` / `Treasury` 的写入口。

```plan-status
ALL | done | #387 | 2026-11-27
```

---

## 1. 范围

| 做 | 不做 |
|---|---|
| 周期定 **28 天（10/10/5/3）**，文档写清「结算不是阶段，是边界事件」 | 加第五个 `settlement` 阶段 / 改状态机 / 改补推逻辑 |
| 正式数值卡：产能、配额、售价、成本、库存上限、prestige | 改 `industry_facility` schema / 加表 / 加迁移 |
| `test_industry_balance.py` 9 条可执行断言 | 抬 `core_economy` 全局倍率让产业"看起来赚钱" |
| 三条反向注入实际跑红后恢复 | 真机起服务器（由 Hermes 跑 `industry_cycle_probe.py --scale 60 --cycles 2`） |
| 现有产业用例按新默认值更新（条数不减） | 14 天试玩报告（合并后单独跟踪） |

## 2. 目标与回本口径

**目标：单设施（设施 + 首个工位）净现金回本 8 周（2 个周期）。**

S7 每个周期会清空 `industry_facility` 与 `org_treasury.balance`，设施下个周期要重建。
因此不能用 `R / C`（毛收入 / 成本）当回本，否则会把一个每轮都在亏钱的方案算成"很快回本"。
本卡用：

```
C = 设施 baseCost + 首个工位成本
R = 单组织单周期收入
回本周期数 = C / (R − C)
回本周数   = 4 × C / (R − C)      -- 一个周期 28 天 = 4 周
```

8 周 = 2 个周期 → `R = 1.5C`，每周期净利率 50%。
6 周需要 `R = 1.67C`，对离线/库存损耗太敏感；10 周需要 `R = 1.4C`，净利率只剩 40%，
一个阶段卖不满就贴近盈亏线。8 周是 MVP 的稳健中点。

> 旧默认（配额 10 / 单价 $50 / 12 单位每小时）的真实收入是 **$685/周期**，不是 issue 初稿里的 $962：
> 竞争/成熟/衰退的配额倍率 0.85/0.70/0.40 会把每阶段 5 件压成 4/3/2 件。
> 按 $100,000 成本算，旧默认是 **146 个周期**。

## 3. 正式数值卡

| 项 | 正式值 | 推导 / 为什么 |
|---|---|---|
| 周期 | **28 天 = 10/10/5/3** | 结算不是阶段，是衰退结束边界上的一次事件 |
| 设施 `baseCost` | **$50,000** | 不动；满建 10 工位总资本 $2,779,505，落在 §20 的 $2–5M |
| 工位成本 | `floor(50,000 × 1.35^(n−1))` | 曲线不动；第 1/2/3/4 个 = 50k / 67.5k / 91.1k / 123.0k，第 10 个 744.7k |
| `C` = 设施 + 首工位 | **$100,000** | 回本基准 |
| `UnitsPerHour` | **4.5** | 满建 10×4.5=45 ≥ 衰退期 50% 配额所需 2,200/(72×0.70)=43.65；9 工位 40.5 不够 |
| 生产倍率 | `1.0`；阶段 1.25/1.00/1.00/0.70 | 不动 |
| 单价 | **$50** | 不动，对齐 `economy_baseline.json` 的 `iron_ore=$50` |
| `SeedQuota` | **11,000/阶段** | 上限 11,340（满建衰退产量 2,268 / (0.40×0.50)），取整留余量 |
| 单组织每阶段上限 | **5,500 / 4,675 / 3,850 / 2,200** | 四阶段合计 **16,225 件/周期** |
| `OrgCapRatio` | **0.5** | 不动；第二家超 50% 直接拒绝 |
| `stockCap` | **540** | `10×4.5×12h = 540` = 1 工位成熟期（5 天×1.0）产量；旧 144 是 1 工位×12/h×12h，满建 1.2h 就触顶 |
| `PrestigeK` | **50,000** | 1 工位约 1 点/周期，满建约 3 点/周期；$5M 累计正好 10 点 = +20% 封顶 |
| 永久加成 | **每级 +2%，上限 +20%** | 不动；只乘产能，不乘售价 |

### 3.1 三档建造

| 建造 | 单周期销量 | 收入 `R` | 资本 `C` | 净现金 `R−C` | 净回本 | 日毛利（售价×产量） |
|---|---|---|---|---|---|---|
| 设施 + 1 工位（入门） | 3,196 | $157,540 | $100,000 | $57,540 | **6.95 周** | $5,626/天 |
| 设施 + 4 工位（推荐） | 12,787 | $630,280 | $381,643 | $248,637 | **6.14 周** | $22,510/天 |
| 设施 + 10 工位（满建） | 16,225 | $796,812 | $2,779,505 | −$1,982,693 | 不回本 | $28,457/天 |

满建是**配额饱和上限**，不是利润最优：10 工位刚好能在四个阶段都吃满 50% 配额，
但 1.35 曲线让重建成本 $2.78M 高于单周期收入 $0.80M。利润最优在 2–4 工位；
这是 §11 防垄断闸的预期结果，不是 bug。

## 4. 改了哪些配置

| 文件 | 项 | 旧 → 新 |
|---|---|---|
| `T-CityLite.base/resources/[custom]/custom-industry/config/production.lua` | `industry_units_per_hour` | 12 → **4.5** |
| `T-CityLite.base/resources/[custom]/custom-industry/config/sales.lua` | `industry_demand_seed` | 10 → **11,000** |
| `T-CityLite.base/resources/[custom]/custom-industry/config/facility.lua` | `stockCap` | 144 → **540** |
| `T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua` | `industry_prestige_k` | 500 → **50,000** |
| `T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua` | 注释/口径 | 30 天 → **28 天**；结算写成边界事件 |

保持不动：`baseCost` 50,000、`1.35^(n-1)`、单价 50、`OrgCapRatio` 0.5、
`PrestigeBonusPerLevel` 0.02、`PrestigeBonusMaxLevel` 10、四阶段倍率。
没有改 schema / 迁移 / `industry_facility` / `SettleSale` / `Treasury`。

## 5. 新增断言清单（`test_industry_balance.py`，9 条）

| # | 用例 | 钉住的事 |
|---|---|---|
| 1 | `test_phase_days_sum_to_28_and_settlement_is_not_a_phase` | 四阶段 10/10/5/3、合计 28 天、总秒数 2,419,200；`Phases.settlement` 不存在 |
| 2 | `test_demand_seed_and_org_cap_match_the_card` | 走真实 `EnsureSeed`：配额 11,000/9,350/7,700/4,400，上限 5,500/4,675/3,850/2,200 |
| 3 | `test_single_workstation_cycle_revenue_and_payback` | 1 工位产量 1,350/1,080/540/226，收入 $157,540，净 $57,540，回本 6.95 周 |
| 4 | `test_full_build_saturates_the_org_cap_and_daily_gross_is_in_band` | 满建四阶段产量都 ≥ 50% 上限；收入 $796,812，日毛利 $28,457 ∈ $15k–$30k |
| 5 | `test_recommended_four_workstation_build_meets_both_targets` | 4 工位收入 $630,280、净 $248,637、回本 6.14 周、日毛利 $22,510 ∈ $15k–$30k |
| 6 | `test_stock_cap_is_twelve_hours_of_full_build_and_is_reachable` | 540 = 10×4.5×12h；1 工位扩张期能触顶；1 工位成熟期产量正好 540 |
| 7 | `test_two_orgs_split_demand_and_over_half_is_rejected` | 两家各卖 5,500；第二家 5,501 → `org_cap_reached`；全服卖满 → `demand_exhausted` |
| 8 | `test_prestige_k_matches_revenue_scale_and_caps_over_multiple_cycles` | K=50,000；1/4/满建 = 1/3/3 点；$5M → 10 点；+20% 封顶 |
| 9 | `test_workstation_cost_curve_and_full_build_capital_are_unchanged` | base 50,000、10 个工位成本逐项、满建 $2,779,505 ∈ $2–5M |

## 6. 反向注入（实际跑红后恢复）

| 注入 | 期望 | 实际 |
|---|---|---|
| `phases.expansion.days = 10 → 11` | 阶段天数/收入/回本断言红 | **4 failed, 5 passed**（#1、#3、#4、#5） |
| `industry_demand_seed = 11000 → 10` | 配额/收入/50% 上限断言红 | **5 failed, 4 passed**（#2、#3、#4、#5、#7） |
| `OrgCapRatio = 0.5 → 1.0` | 配额上限/两家组织断言红 | **3 failed, 6 passed**（#2、#4、#7） |

三次注入均已恢复；恢复后 `test_industry_balance.py` **9 passed**。

## 7. 测试结果

| 命令 | 结果 |
|---|---|
| `pytest tests/unit/layer3_business/test_industry_balance.py -q` | **9 passed** |
| `pytest tests/unit/layer3_business -q`（基线 → 本片） | **845 passed, 1 skipped, 51 subtests** → **854 passed, 1 skipped, 51 subtests**（+9，无掉条） |
| `pytest tests/tools/test_industry_cycle_probe.py -q` | **45 passed** |
| `pytest tests/architecture tests/unit/layer3_business -q` | **1781 passed, 16 skipped, 51 subtests passed**（exit 0，322s） |

按新默认值更新的既有用例（只改期望/注释，不删用例）：

* `test_industry_production.py`：配置默认值 12→4.5、144→540；写库用例的产量/`last_tick_at` 按 4.5 重算（7/3 件，560/540 秒，满仓 540）。
* `test_industry_cycle.py`：阶段倍率用例 25/14 → 9/5。
* `test_industry_prestige.py`：生产读取路径 30/25 → 11/9。
* `test_industry_ui.py`：快照与手机假数据的 `stockCap` 144 → 540。
* `test_industry_settlement.py`：`PrestigeFor` 公式用例改用默认 K=50,000（$5M → 10 点）；其余结算流程仍用 K=500 的 fixture convar。

## 8. 为什么不是靠改一个数凑出来的

本卡的四个改动是**同一组约束的解**，不是四个独立旋钮：

1. **满建必须吃掉自己的 50% 配额**：最差阶段（衰退）上限 2,200 件 / (72h × 0.70) = 43.65 单位/小时。
   → 10 工位 × `UnitsPerHour` ≥ 43.65 → **4.5**（9 工位 40.5 不够）。
2. **配额不能高于满建产能**：满建衰退产量 2,268 → `SeedQuota × 0.40 × 0.50 ≤ 2,268`
   → `SeedQuota ≤ 11,340` → 取 **11,000**。
3. **库存上限要跟满建产能自洽**：`stockCap = 10 × 4.5 × 12h = 540`；同时等于 1 工位成熟期产量，
   单工位也能摸到。旧 144 的 12h 是按 1 工位 × 12/h 算的，与 10 工位上限矛盾。
4. **prestige 不能一轮顶满**：新收入 $0.16M–$0.80M/周期，K=500 会给 17–39 点；
   K=**50,000** 把满建压到 3 点/周期，$5M 累计正好 10 点 = +20% 封顶。

成本与售价保持不动，是因为它们各自被别的约束钉住：`baseCost` 50k + 1.35 曲线让满建资本
$2.78M 落在 §20 的 $2–5M；单价 $50 对齐 `economy_baseline.json`。如果只改售价（例如抬到 $150）
而配额仍是 10，收入仍被配额卡死；如果只改配额而产能仍是 12/h，库存与配额的比例会反过来
（1 工位 12h 产 144，配额却要卖几千件，工位毫无意义）。所以必须同时给产能、配额、库存、prestige。

## 9. 文件清单

| 文件 | 变更 |
|---|---|
| `T-CityLite.base/resources/[custom]/custom-industry/config/production.lua` | `UnitsPerHour` 4.5 + 推导注释 |
| `T-CityLite.base/resources/[custom]/custom-industry/config/sales.lua` | `SeedQuota` 11,000 + 上限注释 |
| `T-CityLite.base/resources/[custom]/custom-industry/config/facility.lua` | `stockCap` 540 + 口径注释 |
| `T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua` | 28 天口径、`PrestigeK` 50,000 |
| `T-CityLite.base/tests/unit/layer3_business/test_industry_balance.py` | 新增 9 条 |
| `T-CityLite.base/tests/unit/layer3_business/test_industry_{production,cycle,prestige,ui}.py` | 期望值随新默认值更新 |
| `docs/server-design/12-industry-operations.md` | §5/§10/§20/§21 + 一致性行 |
| `docs/plan/industry-ops/07-plan.md` | 本文件 |
| `CHANGELOG.md` | `[Unreleased] / Changed` 条目 |

没有改 `migrations/`、`tests/fixtures/tcity_schema.sql`、`tests/architecture/table_owners.json`、
`service_contracts.json`、`net_events_allowlist.json`。

## 10. 真机兼容性

* 阶段天数仍是 10/10/5/3，`industry_phase_seconds` / `industry_cycle_scale` 的压缩路径不变；
  `tools/dev/industry_cycle_probe.py --scale 60 --cycles 2` 的序列/补推/重启/幂等断言不依赖数值卡。
* `pytest tests/tools/test_industry_cycle_probe.py -q` **45 passed**（离线契约）。
* 本 worktree 没有运行中的 FXServer / MariaDB，**真机未在本片执行**；由 Hermes 跑并给结论。
* 旧库的 `industry_demand` 种子行（migration 里的 10）会在 `EnsureSeed` 启动时按新默认值
  11,000 校准（只覆盖 `quota_used = 0` 的行），不需要数据迁移。

## 11. 回滚

* 配置：把四个值改回 12 / 10 / 144 / 500 并 `restart custom-industry`；不需要动数据库。
* 数据：`industry_demand` 已按新值写入的行会在下一阶段 `EnsureSeed` 时按配置校准；
  已卖出的配额不会被改小（`quota_used > 0` 的行保持原值）。
* 测试：`test_industry_balance.py` 是纯离线用例，删掉不影响运行时。

## 12. 施工记录

| 日期 | 事件 |
|---|---|
| 2026-11-27 | 读 #387 正文 + Hermes 两条口径评论；核对旧默认真实收入 $685/周期（146 周期），确认 issue 的 $962 未计配额倍率。 |
| 2026-11-27 | 定卡：净现金回本 8 周；U=4.5、SeedQuota=11,000、stockCap=540、PrestigeK=50,000；售价/成本/曲线/50% 上限不动。 |
| 2026-11-27 | 新增 `test_industry_balance.py` 9 条；基线 `layer3_business` **845 passed, 1 skipped, 51 subtests** → 改后 **854 passed, 1 skipped, 51 subtests**。 |
| 2026-11-27 | 三条反向注入：阶段天数 +1 → **4 failed**；SeedQuota 回 10 → **5 failed**；OrgCapRatio 1.0 → **3 failed**；均恢复后 **9 passed**。 |
| 2026-11-27 | `pytest tests/tools/test_industry_cycle_probe.py -q` → **45 passed**。 |
| 2026-11-27 | 全量闸门首跑 **1 failed**（`test_docs_links` 撞到新 plan 文件写入窗口，复现单跑 7 passed）；复跑 **1781 passed, 16 skipped, 51 subtests passed**（exit 0，322s）。 |
