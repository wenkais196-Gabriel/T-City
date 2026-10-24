# 警察系统架构基线

> 基线：`master @ 568acd2`（2026-10-24）。这是 **as-built（现状）** 基线，不是目标态。
> 目标态见 [../DESIGN.md](../DESIGN.md)；已知债见 [../TECH_DEBT.md](../TECH_DEBT.md)。

## 文档地图

| # | 文档 | 回答的问题 |
|---|---|---|
| 00 | [overview](00-overview.md) | 系统由什么组成、信任边界、请求怎么流动 |
| 01 | [domain-model](01-domain-model.md) | 限界上下文、聚合、不变量、统一语言 |
| 02 | [state-machines](02-state-machines.md) | 7 个关键对象的状态、迁移、失败回退 |
| 03 | [contracts](03-contracts.md) | 46 export / 18 事件 / 17 query / 21 action 的契约面 |
| 04 | [data-ownership](04-data-ownership.md) | 每张表谁写谁读、单一事实源、一致性等级 |
| 05 | [nfr](05-nfr.md) | 48 人、NPC 预算、延迟、可靠性、安全、可观测 |
| 06 | [adr](06-adr/) | 关键决策记录（为什么这样选） |
| 07 | [fitness-tests](07-fitness-tests.md) | 13 条架构约束的自动检查与评分卡 |
| 08 | [scenarios](08-scenarios.md) | 5 条端到端场景走查（含失败与权限） |

## 怎么用

1. **新增玩法前**：先回答 02（状态机）与 04（数据归属），再写 03（契约），最后才写代码。
2. **设计评审**：按 08 的 5 条场景逐条走，失败场景必须给回退。
3. **每个关键取舍**：写一页 ADR，不写“口头决定”。
4. **CI**：把 07 中标记为 blocking 的规则实现为 Python 检查，禁止架构退化。

## 基线结论（先看这五条）

1. `custom-police` 是唯一执法写入口；`custom-justice` 只应负责量刑，`qb-prison` 只应负责刑期执行。
2. 当前最大架构风险是**双状态**（`job.onduty` vs `police_units.status`）与**内存判决**（justice `activeCases`）。
3. 契约面大且不统一：13 个 MDT action 把错误压成 boolean，只有 4 个契约有结构化错误码。
4. 数据所有权总体清晰，但 `phone_notifications` 有 6 个写者、`players.*` 有 7 个资源直写。
5. 安全与取证类 fitness test 当前 5 条中 4 条 FAIL；这是下一步最该补的自动化。


## 基线校正（以代码为准）

- **agent 风险等级**：DESIGN/B_PLAN 写“建警情 L2”，代码是 `police_incident_create` **L1 自动执行**（`custom-director/server/policy.lua`）；派单 L2、入狱 L3。安全评审以代码为准。
- **`police_arrests` 未完全停写**：新 `ArrestSubmit` 只写 `police_reports(kind='arrest')`，但 agent `Sys.Jail` 与 legacy `RegisterArrest` 仍写 `police_arrests`；`GetArrests` 只读 reports，legacy 行仅在案件详情 UNION 可见。
- **敏感读 fail-closed**：3 个导出（lookup.citizen / lookup.vehicle / GetCaseDetail），不是 2 个。
- **数据所有权**：00 的所有权矩阵是“一句话级”，与 04 冲突时**以 04-data-ownership.md 为准**。
- **`police_units.dept`** 目前无写入点；MDT 单位恒显示 PATROL。
- **`police_warrants`** 只有 citizenid/reason/status，没有搜查令地址/范围字段。
- **`police_*` 无 `idem_key`**：B_PLAN 的幂等验收尚未实现。
