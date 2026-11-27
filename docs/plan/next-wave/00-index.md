---
id: plan-next-wave-index
type: plan
status: active
system: meta
owner: hermes
updated: 2026-11-27
review_by: 2027-03-31
---

# 下一轮（2026-12 → 2027-01）：可运营化与收口

> **基线**：本计划从 `2f092048` 切出。master 之后只多了 `28dbf0aa`（菜单 §9.6 信息行语义，纯文档），
> 不改变本文结论；M6 的本地分支 `refactor/m6-adminmenu-menuv` 目前还没有新提交。
>
> **输入**：产业线 S1–S8 已合入（#333–#338、#375、#381）；菜单线 M1–M5 已合入
> （#343–#347、#371、#376）；M6/M7 仍未完成（#348、#349）。

## 1. 这一轮要解决什么

三句话：

1. **产业默认数值仍是“证明机制”的取值，不能对玩家开放。** 默认 `industry_demand_seed=10`、单组织上限 50%，
   一个周期最多卖 20 件、收入约 **$1,000**（20 × 单价 $50，不含市场波动）；而“设施 + 1 个工位”就要 **$100,000**。同一份配置里，
   设计稿写 30 天周期（10/10/5/3/2），代码只有四个阶段（10/10/5/3 = **28 天**）。
   见 `T-CityLite.base/resources/[custom]/custom-industry/config/sales.lua`:28、
   `T-CityLite.base/resources/[custom]/custom-industry/config/facility.lua`:12、
   `T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua`:37、
   `docs/server-design/12-industry-operations.md`:103。

2. **手机端产业只读、周期只发 CityFeed。** 卖出入口只有 Boss 菜单（S5 计划 §2 的明确取舍）；
   S7 的 issue 验收写了“CityFeed + 手机推送”，实现里只做了 CityFeed，代码注释也写明“留给后续片”。
   见 `T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua`:107、
   `T-CityLite.base/resources/[custom]/custom-industry/server/announce.lua`:3、
   `T-CityLite.base/resources/[custom]/custom-phone/server/core/notify.lua`:38。

3. **菜单线与技术债还差三个出口。** M6 仍在另一条分支上；M7 的棘轮基线还没建，
   而 `menu_surface_baseline.json` 已经和当前代码不一致（M7 开工前必须重测）；
   #379 的 Sonar 三项 **2027-01-15** 到期；#369 已实现但尚未合入。

这一轮不新增结构机制，只做“可运营化 + 收口”：把产业变成能开放的经济，把手机入口补齐，
把菜单线和技术债封口。

## 2. 本轮做 / 不做

| 结论 | 项 | 一句话理由 |
|---|---|---|
| **做** | I0 产业数值卡与真实周期长度 | 不修就不能开放；改的是配置与测试，不动 schema |
| **做** | I1 手机端产业动作入口 | 管理者不必回到 Boss 菜单坐标；服务端已有 sell，只缺 hire 与前端 |
| **做** | I2 周期公告推送 | S7 验收欠账；结算前无通知 = 玩家资产被清且不知情 |
| **做** | M7 手机双 `Wait(0)` 收口 + 菜单架构棘轮 | M6 之后的收口片；把一次性清理变成只许下降的基线 |
| ~~做~~ **已完成** | D1 #369 命令清单去行号 | 2026-11-27 已合入 `e75de4ad`（PR #382），本条只作记录 |
| **做** | D2 #379 Sonar 三项 | 硬到期日 2027-01-15，没有别的 owner |
| **不重复派工** | M6 #348 | 已派给另一个 agent；本计划只消费它的输出 |
| **不做（本轮）** | I3 循环型职业并入产业岗位 | 单设施、无地点模型，“运库存”没有落点；会变成改文案 |
| **不做（本轮）** | I4 多设施 / 多地块 / 跨区物流 | 要把 `industry_facility` 的 `org_id` 主键拆开，先等数值与真实数据 |
| **不做（本轮）** | I5 组织治理两条提案 | 提案引擎不存在，且当前金库余额不足以谈分红 |
| **不做（本轮）** | I6 NPC 对手 / 抢单 | 默认配额 10 的情况下 NPC 会先把订单吃光；先做数值 |
| **不做（本轮）** | M8 qb-menu 全量迁移 | 适配层已可用且默认关闭；触发条件写在 `01-candidates.md` |

## 3. 依赖顺序

```
第一优先（可立即并行，文件不重叠）
  W4 #369 命令清单收口 ────────────────────────────┐
  W5 #379 Sonar 三项（2027-01-15 到期）────────────┤
  W0 产业数值 / 真实周期 ────────┬──────────────────┤
  W1 手机产业动作入口 ───────────┤（共用 phone 构建）│
  W2 周期公告推送 ───────────────┘（W1 后联调）     │
                                                   ▼
第二优先（有前置）
  M6 #348（外部在途）──→ W3 M7 棘轮基线 ──→ 菜单线出口
```

- **可并行**：W0、W1、W2、W4、W5 之间没有硬依赖；W1 与 W2 都碰
  `T-CityLite.base/tests/unit/layer3_business/test_phone_apps.py` 的少量断言，建议同一 agent 串行，
  或 W1 先合、W2 rebase。
- **必须串行**：M6 → W3。M7 的 `menuv_entry = 0` 只有在 M6 把 menuv 下线后才成立；
  M7 的第一项任务就是重跑 census，不能拿 2026-11-25 的旧基线直接当棘轮。
- **W0 是 W2 的文本前置**：推送文案里的“约 N 小时 / N 分钟”与周期长度必须同源；
  代码可以先合，最终联调排在 W0 之后。

## 4. 本轮出口判据

1. `cd T-CityLite.base && pytest tests/architecture tests/unit/layer3_business -q` 全绿
   （约 4–5 分钟；慢不是卡死）。
2. I0 的数值断言全绿：周期天数与配置一致；设施 + 1 工位回本 3–14 天、单设施日毛利 $15k–$30k、
   单组织单周期收入 ≤ $5M；`industry_demand_seed=10` 这类“证明机制”取值不能再作为默认值通过。
3. `python tools/dev/industry_cycle_probe.py --scale 60 --cycles 2` 在真机通过；
   额外的 14 天真机试玩报告给出“保留 28 天 / 改 30 天 / 改其他”的结论与数据。
4. 手机端：老板能在手机卖出与雇工位；非 Boss 看不到按钮且服务端拒绝伪造动作；
   周期警告与结果在通知托盘可见，点击能进产业 App。
5. 菜单线：M6 合入；M7 的 `test_menu_architecture.py` 绿，三条反向注入（新增 `SetNuiFocus`、
   回填 `backdrop-filter`、重新引入 menuv 引用）全部变红。
6. #369 合入：给含命令的 Lua 加一行注释后，命令清单闸门仍绿。
7. #379 在 2027-01-15 前关闭，或在 `docs/engineering/CONSTITUTION.md` 写明“质量门只对 src/ 生效”的
   决策与理由；没有 Sonar token 不算关闭。

## 5. 文档地图

| 文件 | 内容 |
|---|---|
| [01-candidates.md](./01-candidates.md) | 12 条候选的逐条字段：价值 / 路径 / 依赖 / 成本 / 风险 / 验收 |
| [02-shards.md](./02-shards.md) | 6 个 issue 草稿（标题 + 正文），按依赖排序，标明并行关系 |
| [03-gates.md](./03-gates.md) | 本轮复用与新增的闸门；哪些是只许下降的棘轮 |
| [12 — 产业运营与组织运营](../../server-design/12-industry-operations.md) | 产业线的上游 spec（§14/§15/§20） |
| [06-plan.md](../industry-ops/06-plan.md) | S6–S8 的施工与验收记录 |
| [menu-system-design.md](../../client/ux/menu-system-design.md) | 菜单线的契约与 M1–M7 分片 |
