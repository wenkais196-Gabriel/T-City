---
id: industry-ops-s6-s7-plan
type: plan
status: active
system: economy
owner: hermes
updated: 2026-11-26
review_by: 2027-03-31
stage: P
plan_status: 1
---

# 计划：S6 周期状态机 + S7 结算转生（同一片）

> **S8 上线前收口（#375）追加在 §12**；S6/S7 的既有契约不变（`SettleSale` 仍是唯一组织入账点）。
>
> 阶段 P 的产物。上游：[12 — 产业运营与组织运营](../../server-design/12-industry-operations.md)（spec §5/§12），
> 前一片：[05-plan.md](./05-plan.md)（S5 产业 UI，已合并 #362）。
> 施工单元：[#338](https://github.com/wenkais196-Gabriel/T-City/issues/338)；
> 分支 `feat/industry-cycle`（按任务要求未 push、未开 PR）。

```plan-status
R1 | done | #338 | 2026-11-26
R2 | done | #338 | 2026-11-26
R3 | done | #338 | 2026-11-26
R4 | done | #338 | 2026-11-26
R5 | done | #338 | 2026-11-26
R6 | done | #338 | 2026-11-26
R7 | done | #375 | 2026-11-26
R8 | done | #375 | 2026-11-26
R9 | done | #375 | 2026-11-26
```

---

## 1. 范围

S6 与 S7 **必须同一个 PR**：阶段机本身没有清空能力，先上线回环会让库存与金库跨周期累积；
停在末期又会让线上卡在衰退期。本片把「这一轮结束了」的钩子补上。

| 做 | 不做 |
|---|---|
| `industry_state` 单行表 + 30 秒心跳推进（guarded UPDATE / 补推不跳段） | 玩家侧延长/缩短周期（只有控制台 `industry_setphase`） |
| 四阶段倍率接到 S2/S3/S4 的既有读点 | 新 NUI（公告走手机 CityFeed / 控制台） |
| `industry_cycle_results`（`UNIQUE(org_id, cycle_no)`）+ prestige | 二级市场 / 玩家间交易 / 负债 |
| 表级显式清分 + dry-run + 审计 + CityFeed 公告 | 个人层任何写入（现金/物品/车辆/房产） |
| 结算失败可重试（结果行 `applied` 水位 + prestige 绝对值） | 跨表事务（`db.lua` 不提供，见 §5） |

## 2. 溯源：为什么必须这么切

| 上游事实 | 推出来的约束 |
|---|---|
| `world_state` 唯一键是 `(region_id, state_key)`，且 `GetRegionState` 冷缓存返回 nil（spec §2 第 4 行） | 周期权威状态必须独立单行表；每次推进都查库，不靠内存或可能为空的读 |
| S4 的 `industry_demand` / `industry_sales` 以 `(cycle_no, phase, item)` 为维度 | 阶段推进必须为**新阶段**播种配额行；旧阶段的卖单与配额保留到结算 |
| `Treasury.Deposit` 是全仓唯一「无对应玩家扣款」的净增点（S4 静态闸门） | 结算**不能**再走 Deposit；清余额必须复用金库写入口的新函数 `Treasury.ApplySettlement` |
| `db.lua` 没有事务适配器 | 清分靠「幂等 + 可重试」：结果行唯一键、`applied` 水位、prestige 写绝对值 |
| `players` 表 owner 是 qb-core | 结算文件的 SQL 白名单里没有个人层；fixture 对提到 `players` 的语句直接标记越界 |

## 3. 验收标准（可执行）

- [x] `industry_phase_seconds=60` → 四阶段按 60/120/180/240 秒推进，每次只推进一格，重启边界不重算
- [x] 停机跨多个边界 → 一次 tick 一格，序列 `competition → maturity → recession → expansion`，不跳段
- [x] 压缩跑完一周期 → 设施 0 行、stock 0、配额 0、金库 0、prestige +N、结果表 1 行
- [x] **`players` 表在结算前后 checksum 完全一致**（`rows=2;len=224;hash=152383662` 前后相同）
- [x] 同一 `(org_id, cycle_no)` 第二次结算被拒（`already_settled`，零写入、零重复 prestige、零重复公告）
- [x] 衰退期仍可卖出（`$50 × 2 × 0.80 = $80`），但 `Build` / `AddWorkstation` 返回 `purchases_closed`
- [x] dry-run `Preview` 只打印将删/将写行数，`__sqlWrites == 0`
- [x] 结算前 7 天公告：默认提前量 `604800` 秒，每周期只发一次；结果公告同样只发一次
- [x] 结算失败一半时重试不重复入账（prestige 写入前 / `applied` 标记前两种崩溃点都覆盖）

## 4. 切片

| 片 | 内容 | 结果 |
|---|---|---|
| R1 | `v4.4_industry_cycle.sql`（单行 state + 结果表 UNIQUE）+ fixture + `table_owners.json` | ✅ |
| R2 | `resources/[custom]/custom-industry/server/cycle.lua`：`Current` / `Initialize` / guarded `Tick` / `SetPhase` / convar 压缩 | ✅ |
| R3 | 倍率接线：S3 产能、S4 售价与配额种子、S2 购置闸、S5 快照阶段字段 | ✅ |
| R4 | `resources/[custom]/custom-industry/server/settlement.lua`：显式表级清分、prestige、dry-run、`applied` 崩溃恢复、审计 | ✅ |
| R5 | `resources/[custom]/custom-industry/server/announce.lua` + `commands_cycle.lua`：CityFeed 两段公告、控制台换阶段/结算 | ✅ |
| R6 | 25 条新单测（含 4 条反例、个人层 checksum、幂等、补推不跳段）+ 结构闸门 | ✅ |
| R7 | prestige 永久加成接线：每级 +2%、上限 +20%，**只走读取路径**（生产结算 + 快照现读 `org_treasury.prestige`），无账户=无加成，读库失败 fail closed | ✅ |
| R8 | `tools/dev/industry_cycle_probe.py --scale 60 --cycles 2`：四阶段顺序 / 不跳段 / 重启续跑 / 结算前后 `CHECKSUM TABLE players` / 幂等，跑完自清理 | ✅ |
| R9 | 结算崩溃恢复演练：删一半进程没了 → 重跑收敛、审计只剩一条 `applied` | ✅ |

## 5. 关键实现约束（写错就白写）

1. **推进许可只有一条**：`UPDATE industry_state ... WHERE cycle_no/phase/phase_ends_at <= ?`
   的 `affected == 1`。副作用（配额种子、审计）只在拿到 1 之后执行；一次 tick 只推一格。
2. **公告是每周期一次，不是每阶段一次**：提前量按**周期末端**（衰退结束）算，
   阶段推进不清 `warning_announced_at`，只有跨周期才重置。
3. **结算顺序**：结果行（`applied=0`） → 金库清零 + prestige 绝对值 → 删设施/卖单 → `applied=1`
   → 删全服配额 → `settled_cycle_no`。任何一步失败保持 `applied=0`，下一 tick 重试。
4. **个人层三层证明**：SQL 白名单静态扫描 + fixture 对 `players` 语句打越界标记 + 运行时 checksum。
5. **配额倍率在写种子行时落地**：`quota_total = floor(SeedQuota × phase.quota)`；
   S4 的库存 CAS / 配额 CAS / 50% 上限一行不改。
6. **衰退期只关购置**：`Facility.Build` / `AddWorkstation` 前置 `purchases_closed`；
   卖出路径（`sale.lua`）不读取 `purchasable`。
7. **周期 tick 不新增线程**：挂到 S3 已有的 30 秒生产心跳（`IndustryProduction.Start({ onTick })`），
   `io_budget` 的 unknown-interval 档不涨。

## 6. 先红后绿

首跑（实现文件移开，模块不存在）：

```
FAILED test_industry_cycle.py::test_downtime_catchup_is_sequential_and_never_skips_a_phase
FAILED test_industry_cycle.py::test_state_advance_rejects_when_guarded_update_affected_zero
FAILED test_industry_cycle.py::test_recession_still_sells_but_blocks_purchases
FAILED test_industry_settlement.py::test_second_settlement_of_same_org_and_cycle_is_rejected
4 failed in 0.23s
  stdin:2763: attempt to index a nil value (global 'IndustryCycle')
  stdin:2775: attempt to index a nil value (global 'IndustrySettlement')
```

反向注入（每条都真跑过）：

| 注入 | 期望 | 实际 |
|---|---|---|
| 删掉售价倍率 `* phasePrice` | 衰退期收入 80 → 100 | **1 failed**（`+ 100`） |
| 删掉推进 UPDATE 的 cycle/phase/边界守卫 | guarded 用例红 | **1 failed**（`'true' == 'false'`） |
| 把 `nextPhase` 强制成 `recession` | 补推跳段 | **1 failed**（`recession,expansion,...`） |
| 删掉 `settled_cycle_no` 水位检查 | 第二次结算不再 `already_settled` | **1 failed**（`'nil' == 'true'`） |
| 在 `settleOrg` 里加一条 `UPDATE players` | 个人层两层断言红 | **2 failed**（静态 `['players']`；运行时 `PERSONAL_SQL '1' == '0'`） |

## 7. 架构对照

| 宪法条款 | 本片怎么守 |
|---|---|
| 服务端权威 | 推进只看 `os.time` + DB 绝对时间；客户端没有任何周期入口 |
| 钱只走两个出口 | 结算不新增货币点；金库清零走 `Treasury.ApplySettlement`（同一 owner） |
| SQL 参数化 + 列白名单 + LIMIT | 全部 `Db.*` 参数化；显式列名；组织列表与预览查询带 LIMIT |
| 表有唯一 owner | `industry_state` / `industry_cycle_results` 登记在 `table_owners.json` |
| 幂等 | 结果表 `UNIQUE(org_id, cycle_no)` + `applied` 水位 + prestige 绝对值 |
| 没有测试的修复不算完成 | 25 条新单测；4 条反例先红后绿；个人层 checksum 实际输出贴在施工记录 |

## 8. 登记表同步清单

`migrations/v4.4_industry_cycle.sql`、`tests/fixtures/tcity_schema.sql`、
`tests/architecture/table_owners.json`、`docs/client/ux/admin-commands.md`
（`scan_commands.py` 重生成，354 → 356 条）、`CHANGELOG.md`。

## 9. 回滚

- **代码**：`industry_enable=false` + `restart custom-industry`：周期心跳、命令、倍率全部不生效。
- **数据**：两张新表保留不读即可；`industry_state` 单行清空即回退到静态占位（`Current` 回落 cycle 0 / static）。
- **运行时**：结算只删产业层，个人层未动；回滚不需要恢复玩家资产。

## 10. 施工记录

| 日期 | 事件 |
|---|---|
| 2026-11-26 | 前序核验：`org_ledger` / `industry_sales` 均有 `UNIQUE(org_id, ref)`；`Treasury.Deposit` 净增点只有 `sale.lua`；基线 `layer3_business` **814 passed, 1 skipped**（issue 写 811，S5 后 +3）。 |
| 2026-11-26 | CC 实现：迁移 v4.4、`resources/[custom]/custom-industry/config/cycle.lua` 与 `resources/[custom]/custom-industry/server/cycle.lua` / `settlement.lua` / `announce.lua` / `commands_cycle.lua`，并把倍率接到 production / sale / facility / ui / main。 |
| 2026-11-26 | 先红后绿：实现文件移开首跑 **4 failed**（`IndustryCycle` / `IndustrySettlement` 为 nil）；恢复后 **4 passed**。 |
| 2026-11-26 | 压缩验收（离线假 DB，显式 `now`）：`t+60 competition / t+120 maturity / t+180 recession / t+240 expansion(cycle 2)`，`settled=1`；中途 `IndustryCycle.Start()` 后边界不变（重启续跑）。 |
| 2026-11-26 | 个人层：`PLAYERS_BEFORE=rows=2;len=224;hash=152383662`，`PLAYERS_AFTER` 完全相同；注入 `UPDATE players` 后静态与运行时两层同时红。 |
| 2026-11-26 | 全量产业用例 **102 passed**；受影响结构闸门 **88 passed**；`scan_commands.py` 356 条。 |

## 11. 已知风险（本片未改）

| 风险 | 现状 | 后续 |
|---|---|---|
| 结算没有跨表事务 | 失败靠 `applied=0` 重试；极端情况下「金库归零、设施未删」会在下一 tick 继续收尾 | 引入事务适配器后把单组织清分包成事务 |
| 公告失败不阻断结算 | 结果表是权威事实；公告失败只记日志，下一 tick 补发 | 运营告警接入 dashboard |
| 控制台可提前结算当前周期 | `industry_settle confirm` 会清空设施但周期继续；下一轮结算前玩家无产出 | 命令仅控制台；后续可加二次确认参数 |
| 阶段切换瞬间的读数窗口 | `Current()` 每 tick/请求实时读库；同一请求内只读一次，但不同请求可能跨越边界 | 可接受（秒级窗口，金额仍由服务端算） |
| ~~永久加成未接线~~ | **S8 已接线（#375）**：每级 +2% 产能、第 10 级封顶 +20%；读取路径生效（生产结算 / `Inspect` / 快照），不写进任何行 | 已解决；数值仍待真人试玩标定（见 §12.5） |

---

## 12. S8 上线前收口（#375）

三件事都是「上线前必须有」：prestige 看得见、周期能被一条命令验收、结算崩一半能收敛。
S1–S7 的契约不变：`SettleSale` 仍是唯一组织入账点、结算仍不碰个人层、SQL 仍走
`Db.*` + 显式列 + `LIMIT`。

### 12.1 prestige 永久加成：只乘产能，读取时生效

| 项 | 决定 | 理由 |
|---|---|---|
| 加成对象 | **产能**（`IndustryProduction.Compute` 的 `multiplier`） | ① spec §10 的意图是「让下一轮更快」；② 售价已叠 `core_economy` 全局/热度与阶段倍率，再加货币倍率会把通胀从「库存上限 × 配额」挪到没有第二道闸的价格上；③ 产能仍受库存上限与每周期配额约束 |
| 等级 | `prestige` 点数，1 点 = 1 级 | 与结算公式 `floor(sqrt(销售额 / K))` 直接对齐，不需要第二张等级表 |
| 数值 | 每级 +2%，`min(points, 10)` 级封顶 +20% | spec §10；第 10 级之后不再增长 |
| 读点 | `T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua` 的 `IndustryCycle.PrestigeForOrg(orgId)`；生产结算与 `IndustrySales.Inspect` 调用 | 每次结算读当前值；结算后的下一轮自动生效 |
| 写点 | 无 | 设施 / 卖单 / 结果表不新增倍率列；结算只写 `prestige` 绝对值 |
| 缺账户 | 无加成（不是错误） | 新组织还没攒过 prestige，生产必须照常跑 |
| 读库失败 | `db_error`，本次结算不写库存 | 与阶段倍率同一条 fail-closed 方向，不按 1 倍继续产 |
| 展示 | `Inspect` / UI 快照返回 `prestige = { points, level, maxLevel, bonusPercent, multiplier }` | 玩家能看见等级与加成；快照只展示，不参与报价 |

配置在 `T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua`：`PrestigeBonusPerLevel`
（convar `industry_prestige_bonus_per_level`，默认 0.02）与 `PrestigeBonusMaxLevel`
（convar `industry_prestige_max_level`，默认 10）。生产公式的 `floor` 补了 `1e-9`：
`1.2 × 150` 在 IEEE754 里会落到 179.999…，不补会少产 1 单位；整数倍率下结果不变。

### 12.2 真机脚本：一条命令，自己清理

```
python3 tools/dev/industry_cycle_probe.py --scale 60 --cycles 2
```

| 检查 | 判据 |
|---|---|
| 四阶段依次推进 | `industry_audit` 的 `cycle.advance` 序列 = 每周期 `expansion→competition→maturity→recession`，跨周期 `recession→expansion` |
| 不跳段 | 第二个周期的 `phase_ends_at` 被改到过去后，仍逐格补推（序列与上一条完全一致） |
| 重启续跑 | 竞争期 `restart custom-industry`，`cycle_no / phase / phase_started_at / phase_ends_at` 不回退、不重算 |
| 个人层零改动 | 结算前后 `CHECKSUM TABLE players / player_vehicles / inventories / player_houses` 完全一致；不一致打印差异表并失败 |
| 幂等 | 衰退期连发两次 `industry_settle confirm <cycle>`：第二次打印 `already settled`，结果表恰好 1 行 `applied=1`、无 `applied=0` 残行、`cycle.settle` 审计恰好 1 条 |

脚本边界：

* 周期号取 `max(当前 cycle, settled_cycle_no, 结果/卖单/配额的最大 cycle) + 1`，不会撞历史结果行；
* 种一个临时设施 `probe_org`，让结算真的有设施要删；
* SQL 静态守卫：任何 `UPDATE/INSERT/DELETE` 个人层的语句直接失败；个人表只允许
  `CHECKSUM TABLE` / `SELECT COUNT(*)`；
* 默认拒绝「有玩家在线」或「库里已有设施/金库数据」；确认是空库验收后分别加
  `--allow-players-online` / `--allow-industry-data`；
* 结束时 `stop custom-industry` → 恢复 `industry_state` / 结果 / 配额 / 设施 / 金库 →
  恢复 convar → `start custom-industry`；`industry_audit` 保留为验收痕迹（append-only，不删）。

### 12.3 结算崩溃恢复演练

新增假 DB 钩子 `__failNextSalesDelete`：结算顺序是「结果行 → 金库绝对值 → 删设施 →
删卖单 → `applied=1`」，在**删完设施、还没删卖单**时抛错，模拟「删到一半进程没了」。
用例断言：

1. 第一次返回 `false:db_error`；设施已删（0 行）、卖单还在（2 行）、配额未清（2 行）、
   金库 0、prestige 10（绝对值）、结果行 `applied=0`、`settled_cycle_no=0`、审计 0 条；
2. 重跑返回成功，最终设施/卖单/配额/余额全 0、prestige 仍 10、结果表 1 行 `applied=1`、
   `cycle.settle` 审计**恰好 1 条**、个人层 checksum 前后一致。

### 12.4 测试与反向注入（实际输出）

| 项 | 命令 | 结果 |
|---|---|---|
| prestige 新用例 | `pytest tests/unit/layer3_business/test_industry_prestige.py -q` | **5 passed** |
| 结算（含新崩溃用例） | `pytest tests/unit/layer3_business/test_industry_settlement.py -q` | **14 passed** |
| 探针离线契约 | `pytest -q tests/tools/test_industry_cycle_probe.py` | **45 passed** |

| 反向注入 | 期望 | 实际 |
|---|---|---|
| 删掉 `min(points, maxLevel)`（+20% 上限） | 封顶用例红 | **1 failed**（`11|11|22|122` ≠ `11|10|20|120`） |
| 删掉生产 `multiplier` 里的 `prestige.multiplier` | 生产读取路径红 | **2 failed**（库存 25 ≠ 30；重试后 25 ≠ 30） |
| 删掉推进 UPDATE 的 `AND phase = ?`（阶段顺序守卫） | 周期用例红 | **6 failed**（`false:conflict`、无推进） |

三次注入都已恢复；恢复后 `test_industry_cycle.py + test_industry_prestige.py` **17 passed**。

### 12.5 验收记录 / 未验证

* 2026-11-26：离线用例与反向注入按上表跑过。
* **真机 `industry_cycle_probe.py --scale 60 --cycles 2` 未在本次施工环境执行**（本 worktree
  没有运行中的 FXServer / MariaDB）。脚本的离线契约、`--help`、语法已验；真机结论以实际跑完的
  输出为准，跑完后把报告表贴进 PR。

### 12.6 回滚

* 代码：`set industry_prestige_bonus_per_level 0`（或 `industry_prestige_max_level 0`）后
  `restart custom-industry`，加成归零；不需要改数据。
* 探针：纯工具，不参与运行时；`stop/start` 与恢复逻辑只在显式运行时生效。
* 结算崩溃：仍保持「`applied=0` 下一 tick 重试」的既有方向，无 schema 变化。
