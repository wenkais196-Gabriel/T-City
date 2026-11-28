---
id: industry-ops-live-audit-plan
type: plan
status: active
system: economy
owner: hermes
updated: 2026-11-28
review_by: 2027-03-31
stage: V
plan_status: 1
---

# 记录：产业线 P0–P4 真机验收（MVP 收口）

```plan-status
P0 | wip | #413 | 2026-11-28
P1 | done | #414 | 2026-11-28
P2 | done | #416 | 2026-11-28
P3 | done | #415 | 2026-11-28
P4 | done | #417 | 2026-11-28
```

---

## 1. 结论

产业运营 MVP **在真机上跑通了完整闭环**：建施 → 雇工位 → 生产 → 卖出 → 提现 → 季度结算 → 新季度起跑。
五片（P0–P4）全部合并，四片真机通过，一片（P0 跨阶段卖单）未取得决定性读数。

| 片 | 结论 | 关键读数 |
|---|---|---|
| P0 配额按阶段独立 | **部分验证** | 跨阶段卖单未单独取数；但竞争期 quota 行独立播种已被观察到 |
| P1 两时钟 + 季度软重置 | **通过** | `facility=1 sales=16 demand=11 prestige=+1 starter=410000 distributed=90246` |
| P2 提现额度/税/分配 | **通过** | 提 $20,000 → 净 $16,000；第二次 $25,000 被 `weekly_quota_exceeded` 拒 |
| P3 库存上限升级 | **通过** | $40,000（0→1）、$64,000（1→2），与 `40k×1.6^n` 曲线一致 |
| P4 仿真器 | 离线通过（无真机项） | 两次跑逐字节一致；改价 50→60 → `BASELINE MISMATCH` 退出码 2 |

## 2. 真机读数（2026-11-28，端口 30130）

### 2.1 建造与升级（P3）

| 时间 | 流水 | 金额 | 结果 |
|---|---|---|---|
| 13:41:15 | `workstation-hire` | −$123,018 | 工位 3 → 4 |
| 13:41:16 | `stock-upgrade` | −$40,000 | `stock_level` 0 → 1 |
| 13:42:18 | `stock-upgrade` | −$64,000 | `stock_level` 1 → 2 |

价格阶梯与配置一致：`floor(40,000 × 1.6^level)`。

### 2.2 提现（P2）

| 时间 | 请求 | 结果 |
|---|---|---|
| 13:56:12 | $20,000 | ok，`net=16000`，`tax_burned=4000` |
| 13:56:30 | $25,000 | `weekly_quota_exceeded`（本周已提 20,000） |
| 13:56:53 | $4,800 | ok，`net=3840`，`tax_burned=960` |
| 13:56:59 | $25,000 | `weekly_quota_exceeded`（额度用满 24,800/25,000） |

### 2.3 季度结算（P1 + P2 分配）

```
settlement done quarter=1 orgs=2 settled=2 skipped=0
  facility=1 sales=16 demand=11 prestige=+1 starter=410000 distributed=90246
```

| 项 | 结算前 | 结算后 |
|---|---|---|
| 设施 | mining_co 4 工位 / 库存级 2 | 表清空 |
| 卖单 | 16 条 / 1,091 件 | 0 |
| 配额行 | cycle 13 | 删除 11 行 |
| 金库 | 90,246 | 210,000（起跑金 200,000 + 威望津贴 10,000） |
| 威望 | 0 | +1 |
| `settled_cycle_no` | 0 | 1 |

`org_ledger` 两条一对：

| delta | balance_after | reason |
|---|---|---|
| −90,246 | 0 | `quarter-distribute` |
| +210,000 | 210,000 | `quarter-starter` |

分配：`boss_total=90246 / member_count=0` → 单人组织 Boss 拿 100%（设计如此）。

### 2.4 账户对账（逐笔）

| 项 | 金额 |
|---|---|
| 结算前 bank | 34,427 |
| 提现净额（16,000 + 3,840） | +19,840 |
| 季度分配 | +90,246 |
| 工资 paycheck（miner Grade4） | +180 |
| **合计 / 实测** | **144,693 / 144,693** |

两条防重：`cycle.settle(quarter_no=1)` **1 次**、`treasury.distribute` **1 次** —— 中途 `restart custom-industry`
与手工改库都没有造成重复结算。

## 3. 真机暴露的三个坑（都已建 issue）

| # | 现象 | 根因 | issue |
|---|---|---|---|
| 1 | 首次升级后第一个季节长达 **864,000 秒（10 天）** | `upgradeToTwoClock` 拿旧 `phase_ends_at` 当首季结束 | **#418** |
| 2 | 季节推进**静默卡死**：`updated_at` 不动、日志一行没有、心跳仍活 | `RollSeason` 的乐观守卫 `AND phase = ?` 撞上"phase 与 season 不一致"→ 永远 `conflict`，且无日志 | **#420** |
| 3 | 分配后 `players.money.bank` 在 DB 里看不到变化 | qb-core `AddMoney` 走 EconomyService **内存优先 + DirtyFlush**，落盘滞后 | 非缺陷（已确认 ~2 分钟内落盘） |

第 2 条是我手工改库（只改 `season` 没改 `phase`）触发的，但**代码不该让这种不一致变成无声死锁** —— issue 要求自愈 + 节流日志 + `/orgcycle` 诊断。

## 4. 运维事实（下次起服直接用）

| 事实 | 说明 |
|---|---|
| 起服**必须**用 `start.cmd` / `start-tcity.ps1` | 它 `Start-Process -WindowStyle Hidden` 脱离调用方；用后台进程直接拉 FXServer 会被 Hermes 清理时 SIGTERM（本次实测 `exit -15`，玩家客户端随即卡死） |
| 控制台日志 | `%TEMP%/tcity_console.log`（不是仓库内） |
| 手工改 `industry_state` 会破不变量 | `phase` 必须等于 `PhaseForSeason(season)`；改季节必须同时改 phase（见 #420） |
| 测试旋钮 | `set industry_season_seconds "120"`（每季 2 分钟；启动时读进 Config，改后 `restart custom-industry`） |
| 采购窗口 | 冬天（recession）`purchasable=false`；测试配置下每季仅 2 分钟，容易连撞"建不了" |
| 季度结算触发 | 达到第 13 周且第 4 季（`season_no >= 4 and weekIndex >= 13`）才结算 |

## 5. 未验项（下一轮优先补齐）

| 项 | 为什么没验到 |
|---|---|
| P0 跨阶段卖单不被 `org_cap_reached` 拒 | 需要"扩张期卖满 5,500 → 竞争期继续卖"的连贯操作，测试窗口只有 2 分钟/季 |
| #419 手机提现点击路径 | 代码在 PR #421 合并、服务器已 `restart custom-phone`，但未点击验证 |
| 非 Boss 只读（#397 遗留） | 需要第二个 Grade1/Grade2 角色 |
| 平板面产业 App | 未在平板布局下打开 |
