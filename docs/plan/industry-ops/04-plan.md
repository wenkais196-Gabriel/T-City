---
id: industry-ops-s4-plan
type: plan
status: draft
system: economy
owner: hermes
updated: 2026-11-26
review_by: 2027-03-31
stage: P
plan_status: 1
---

# 计划：S4 销售 / 配额（第一次造钱）

> 阶段 P 的产物。上游：[12 — 产业运营与组织运营](../../server-design/12-industry-operations.md)（spec §9 钱出口），
> 前一片：[03-plan.md](./03-plan.md)（S3 离线生产，已合并 #358）。
> 施工单元：[#336](https://github.com/wenkais196-Gabriel/T-City/issues/336)，交付 PR **#360**。

```plan-status
Q1 | done | #360 | 2026-11-26
Q2 | done | #360 | 2026-11-26
Q3 | done | #360 | 2026-11-26
Q4 | done | #360 | 2026-11-26
Q5 | done | #360 | 2026-11-26
Q6 | done | #360 | 2026-11-26
```

---

## 1. 范围

前三个分片让组织「有资产」，只有卖出去才叫生意。本片是**闭环成立**的那一片，也是**全仓唯一造钱口**。

| 做 | 不做 |
|---|---|
| `industry_demand`（全服配额）+ `industry_sales`（卖单流水） | 周期推进（S6 只改 `cycle_no/phase` 的值） |
| `SettleSale` 单一出口（定价 × `core_economy` 系数 → 组织金库） | 玩家侧逐笔账（S1 已确认真实缺口，另行立项） |
| 单组织 50% 上限写进**同一条 UPDATE** | 分级授权（S5/治理） |
| dashboard 看见组织入账 | 任何第二条净增货币路径 |

## 2. 溯源：为什么只有一条出口

| 上游事实 | 推出来的约束 |
|---|---|
| `TriggerReward` 第一步 `GetPlayer(source)`（S1 已核实） | 组织入账走不了它，必须新增无 source 的出口 |
| `custom-economy` 的自适应刹车**不存在**（设计 §2 第 2 行） | 产业的净增必须自己埋点，不能假设有旋钮兜底 |
| `economy-dashboard` 只统计玩家 `OnMoneyChange` | 组织入账是通胀盲区 → 同 PR 必须补 |
| 顺序执行下「Lua 侧提前判」与「SQL 侧 CAS」逻辑重叠 | 并发保护必须靠 SQL，且必须有用例钉住**参数** |

## 3. 验收标准（可执行）

- [x] 配额 20、价 50 → 单组织上限 10 → 卖 10 入账 `10×50×倍率`，`quota_used` = 10（**原文写"配额 10"，与 50% 不变量矛盾，已修**）
- [x] 耗尽 → `demand_exhausted`，不扣库存不扣钱
- [x] 第二家组织超总量 50% → `org_cap_reached`
- [x] 同一 `ref` 重复卖 → 第二次拒，`industry_sales` 只有一行
- [x] dashboard 能看到这条组织入账
- [x] 全服货币净增量只来自 `SettleSale`（静态扫描用例）

## 4. 切片

| 片 | 内容 | 结果 |
|---|---|---|
| Q1 | 两张表 + 迁移 + 种子行 + fixture/owner 登记 | ✅ |
| Q2 | `SettleSale`（定价、库存 CAS、配额 CAS、卖单、入账） | ✅ |
| Q3 | 玩家入口 `SellForPlayer`（复用 `IsOrgBoss`） | ✅ |
| Q4 | dashboard `industry:sale` 流入 | ✅ |
| Q5 | `/orgsell` 后台入口（convar + `restricted` + `source==0`） | ✅ |
| Q6 | 21 条单测 + 三次失败回滚 + 唯一造钱点扫描 | ✅ |

## 5. 关键实现约束（写错就白送钱）

1. **本组织 50% 判定必须排在「全服剩余截断」之前**：否则第二家请求 6 件、全服只剩 5 时会被截断成 5，
   正好绕过 50% 闸门。
2. **配额的三个条件在同一条 UPDATE**：`quota_used + ? <= quota_total` 与
   `SUM(s.qty) + ? <= FLOOR(quota_total * ?)`。
3. **失败方向永远是「钱没进、库存还在」**：库存 CAS → 配额 CAS → 卖单 → 入账，逐级回退；
   退不掉打 `CRITICAL` + 审计 `rollback_failed`。
4. **幂等是数据库事实**：`industry_sales` 的 `UNIQUE(org_id, ref)` 与 `org_ledger` 的 `sale:<id>` 两层。
5. **价格只由服务端决定**：配置文件里的 `UnitPrices`（`industy` 的 config/sales.lua）+ `core_economy` 系数；客户端字段一律忽略。

## 6. 先红后绿的证据要求

- 反向注入三条（我做的）：Deposit 失败不退回库存 / 幂等键随机化 / **`cfg.OrgCapRatio` → `1.0`**
- 第三条原本**全绿**：静态钉子只断言 SQL 里有 `FLOOR(quota_total * ?)`，没断言那个 `?` 收到的是配置比例。
  已补断言（`test_quota_update_carries_both_global_and_org_cap_cas`），注入后必红。

## 7. 架构对照

| 宪法条款 | 本片怎么守 |
|---|---|
| 钱只走 `Player.Functions.*` / `core_economy` | 玩家侧不变；组织侧新增 `SettleSale` 且复用同一套系数（设计 §9） |
| 服务端权威 | 价格、倍率、配额余量全在服务端；客户端只说「卖 N 件」 |
| SQL 参数化 + 列白名单 + LIMIT | 全部 `Db.*` 参数化 |
| 表有唯一 owner | 两张新表登记进 `table_owners.json` |
| 幂等 | 两层唯一键 + `rollback` 路径 |

## 8. 登记表同步清单

`migrations/v4.3_industry_sales.sql`、`tests/fixtures/tcity_schema.sql`、`table_owners.json`、
`docs/client/ux/admin-commands.md`（350 → 351 条，补 `/orgsell`）、`CHANGELOG.md`。

## 9. 回滚

单表级可 rollback：删 `industry_sales` / `industry_demand` 两表 + 撤 `sale.lua` 与 `commands_sales.lua` 注册；
金库侧已有流水不受影响（`org_ledger` 的 `sale:*` 行保留即可对账）。

## 10. 施工记录

| 日期 | 事件 |
|---|---|
| 2026-11-26 | CC 实现（`b2cff40c` / `d7817afb`，worktree `E:/T-City-s4`）。21 条新单测；四套 industry 共 **60 passed**。 |
| 2026-11-26 | CC 主动指出 **#336 验收自相矛盾**（配额 10 + 50% 上限 → 单家最多 5，"卖 10" 不可能）。改 issue 而非改代码。 |
| 2026-11-26 | Hermes 注入三条：Deposit 不回滚 → 红；幂等键随机化 → 红；`OrgCapRatio→1.0` → **绿（缺口）**。补断言后 → 红。 |
| 2026-11-26 | CI 红两处：`test_admin_commands_doc`（命令清单未重生成）与 `test_reuse_budget`（`validOrg` 4 份实现）。前者重生成，后者**合并**到新的共享模块（`IndustryOrgId.IsValid`，fxmanifest 排在 treasury 之前），单测 harness 同步加 `prereqs`。复跑 **805 passed**。 |
| 2026-11-26 | **真机四条通过**：卖 5 入账 250（金库 47675→47925，配额 0→5）；卖 6 → `org_cap_reached`（零变化）；同一 ref 两次 → `duplicate_ref`（金库只加一次）；全服只剩 1 时请求 5 → **卖成 1 件**（截断不报错）。 |
| 2026-11-26 | 收尾：测试残留清空（删卖单、金库回退 400、配额回 `10/0`）、`industry_sales_debug` 关回默认。 |
