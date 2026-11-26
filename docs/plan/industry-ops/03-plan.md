---
id: industry-ops-s3-plan
type: plan
status: draft
system: economy
owner: hermes
updated: 2026-11-26
review_by: 2027-03-31
stage: P
plan_status: 1
---

# 计划：S3 离线生产（惰性结算 + 库存上限）

> 阶段 P 的产物。上游：[12 — 产业运营与组织运营](../../server-design/12-industry-operations.md)（spec），
> 前一片：[02-plan.md](./02-plan.md)（S2 设施/工位，已合并 #350）。
> 施工单元：[#335](https://github.com/wenkais196-Gabriel/T-City/issues/335)，交付 PR **#358**。

```plan-status
Q1 | done | #358 | 2026-11-26
Q2 | done | #358 | 2026-11-26
Q3 | done | #358 | 2026-11-26
Q4 | done | #358 | 2026-11-26
Q5 | done | #358 | 2026-11-26
Q6 | done | #358 | 2026-11-26
```

---

## 1. 范围

放置感的核心是「我不在的时候产业在长」，而这也是整条链里最危险的一片：做错就是印钞机。
所以本片**只做物化产出**，不接钱。

| 做 | 不做 |
|---|---|
| 惰性结算（`dt` 由 `last_tick_at` 推，不跑每秒循环） | 卖出 / 变现 / 配额（S4） |
| 库存上限（`stockCap`，满了冻结） | 周期与结算（S6+S7） |
| 停机追赶封顶（`max_catchup`，convar 可压小） | 任何客户端上报入口 |
| `produced_units` 累计（S7 结算要用） | UI（S5） |
| 后台验收入口 `/orgproduce`（convar 门控、仅控制台） | 第二条生产路径 |

## 2. 溯源：为什么必须这么切

| 上游事实 | 推出来的约束 |
|---|---|
| S2 的 `industry_facility` 已有 `workstations` / `stock` / `last_tick_at` | 结算只需这三个数 + 配置，不需要新表 |
| 玩家/组织资金没有逐笔账（S1 对账结论） | 产出**绝不能**直接进银行，否则又一条无法对账的造钱口 |
| S1 的三条不变量是承重墙 | 本片不碰 `Treasury`，连读都不读 |
| S1/S2 真机都卡在「需要在线玩家」 | 本片起，后台入口用 convar 门控 + 仅 `source==0`，调**同一个**入口 |

## 3. 验收标准（可执行）

- [ ] `industry_tick_seconds=1` → 库存涨到 `stockCap` 后**冻结**，不再增长
- [ ] 停服 5 分钟重启 → `stock ≤ cap`，`last_tick_at` 前进 ≤ `max_catchup`
- [ ] 满仓 / `cap=0` / 无工位 → 只推进时间，**不产出、不通知**
- [ ] 客户端上报的任何「这段时间产了多少」都不影响结果（无此入口，且 `Compute` 只吃服务端入参）
- [ ] 结算函数是纯函数，覆盖 `dt=0` / `dt` 极大 / `cap=0` / 部分空间截断 / 取整

## 4. 切片

| 片 | 内容 | 结果 |
|---|---|---|
| Q1 | 纯函数 `Compute`（取整与前进规则写进注释） | ✅ |
| Q2 | `SettleFacility` 双条件 CAS + 重试 | ✅ |
| Q3 | `SettleAll` / `SettleForPlayer` / tick 线程接线 | ✅ |
| Q4 | `produced_units` 迁移 + fixture 同步 | ✅ |
| Q5 | `/orgproduce` 后台入口（convar + 仅控制台） | ✅ |
| Q6 | 14 条单测 + 反向注入 + 文档/CHANGELOG | ✅ |

## 5. 关键实现约束（写错就白写）

1. **CAS 必须是双条件**：`last_tick_at` 与 `stock` 一起进 `WHERE`，否则两个 tick 交错会重复计产。
2. **不产出时也要推进时间**（满仓 / 无工位），否则 S4 卖出后会把满仓那段时间一次性补出来。
3. **不足 1 单位的时间留在 `last_tick_at`**，否则 30 秒 tick × 低速率会永远产出 0。
4. **时钟回拨按 0 处理**，不能让 `last_tick_at` 倒退。
5. **`last_tick_at` 用 epoch 比较**：读侧 `UNIX_TIMESTAMP(last_tick_at)`，写侧 `FROM_UNIXTIME(?)`，两边同一会话时区。

## 6. 先红后绿的证据要求

- 新用例首跑必须红（模块不存在）：`9 failed`
- 反向注入至少两条，且**跑过**：`min(expected, space)` → 去掉截断；`effectiveDt` → 去掉 `max_catchup` 截断
- 红证据贴在 PR 里，不是「我认为会红」

## 7. 架构对照

| 宪法条款 | 本片怎么守 |
|---|---|
| 服务端权威 | `now` 只来自 `os.time()`；无客户端入参 |
| 钱只走 `Player.Functions.*` | 本片**完全不碰钱** |
| SQL 参数化 + 列白名单 + LIMIT | `Db.Update/Db.Single` 全参数化；读单行带 `LIMIT 1` |
| 表有唯一 owner | `industry_facility` 属 `custom-industry` |
| 幂等 | CAS + `affected==1`；`dt=0` 不写库 |

## 8. 登记表同步清单

`migrations/v4.2_industry_production.sql`、`tests/fixtures/tcity_schema.sql`、
`docs/client/ux/admin-commands.md`（`scan_commands.py` 重生成，349 → 350 条）、`CHANGELOG.md`。

## 9. 回滚

整片可单独 revert：新文件（server/production.lua、server/commands_production.lua、config/production.lua）删除即可，
`main.lua` 里两处 `Register/Start` 调用随之失效；`produced_units` 列留着无害（默认 0）。

## 10. 施工记录

| 日期 | 事件 |
|---|---|
| 2026-11-26 | CC 实现（`06806874`，worktree `E:/T-City-s3`）。14 条新单测 + S1/S2 25 条 = **39 passed**。 |
| 2026-11-26 | CC 自报反向注入：`min(expected, space)` → `expected`，红并贴出实际数字（期望 20、空间 4、产出 20）。 |
| 2026-11-26 | **Hermes 独立复核**：39 passed；我自己注入两条（去掉 `max_catchup` 截断 / `space` 写死）各 **3 failed**，还原 14 passed；结构闸门（fixture/migration/命令清单/跨资源写/manifest/wiring/orphan）**68 passed**。 |
| 2026-11-26 | 复核结论：`Compute` 的边界处理比 issue 要求更稳（时钟回拨、`cap<=0`、`rate<=0`、坏 `last_tick_at` 都单独归类）。真机三条仍未验。 |
