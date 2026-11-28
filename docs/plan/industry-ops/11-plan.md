---
id: industry-ops-two-clock-build-plan
type: plan
status: active
system: economy
owner: hermes
updated: 2026-11-28
review_by: 2027-03-31
stage: P
plan_status: 1
---

# 计划：产业两时钟落地施工（P0–P4）

```plan-status
ALL | wip | - | 2026-11-28
```

---

## 0. 依赖树（顺序不能反）

```
P0 配额维度修正  ── 阻断一切
      │
      ▼
P1 两时钟状态机（周=四季 / 季度=软重置）
      │
      ├──► P2 提现额度/税 + 季度按比例分配
      └──► P3 库存上限可升级（+900/级）
                 │
                 ▼
            P4 仿真器 MVP（驱动真实 Lua + 指标基线）
```

判定依据：P0 决定"能卖多少"，是所有数值的前提；P1 决定"什么时候结算"，
P2/P3 都是 P1 结算钩子上的行为；P4 必须在规则稳定后才有意义（否则基线就是错的）。

## 1. P0 —— 配额维度修正（`industry_sales.phase`）→ **#408**

**前序核验**：用仓库 harness 复现「扩张期卖满 5,500 → 竞争期卖 1 件被 `org_cap_reached` 拒」，
并确认竞争期 `quota_used` 被回填成 5,500。复现不出来说明前提已变，先停下来重新定位。

| 项 | 内容 |
|---|---|
| 为什么 | 设计口径是"**每阶段**单组织上限 = 当阶段配额 × 50%"（配置注释与数值卡都这么写），实现却按"全周期累计已卖"当分子，导致后三阶段全部锁死；同一 bug 还让对账把全周期流水回填到当前阶段 |
| 范围 | `T-CityLite.base/migrations/v4.3_industry_sales.sql` 加 `phase`（顺带 `season`，为 P1 预留）；`industry_sales` 的所有写入、读取、CAS、对账全部带维度 |
| 验收 | 跨阶段用例：扩张卖 5,500 → 竞争卖 4,675 成功（不是被拒）；两家组织同阶段各卖 5,500 时竞争期 `quota_used` 不超 `quota_total`；`test_industry_sales.py` 全绿 + 新增跨阶段用例；迁移连跑两次幂等 |
| 不做 | 不改配额总量（11,000）、不改 50% 比例、不做两时钟（那是 P1） |

## 2. P1 —— 两时钟状态机 → **#409**

**前序核验**：P0 已合并；`industry_state` 当前只有 `cycle_no / phase / settled_cycle_no` 单时钟；
`settlement.lua` 只有一个 `SettleCycle`。

| 项 | 内容 |
|---|---|
| 为什么 | 一周一个四季（节奏快）+ 一个季度软重置（防马太）是既定设计；现在是 28 天清空一切，第二个周期直接停摆 |
| 范围 | `industry_state` 增加 `quarter_no / season_no / season_ends_at / quarter_ends_at`；`SettleCycle` 拆成 `RollSeason`（清库存与配额，保留金库/设施/工位/库存等级）与 `SettleQuarter`（软重置 + 分配 + 威望）；季节天数按 7 种分配轮转（确定性） |
| 验收 | 13 周跑通 13 个循环；季节切换不动设施与工位；季度结束才清零并发放起跑金；重启续跑（中途 restart 不跳季） |
| 不做 | 不在本片加提现税/额度（P2）、不加库存升级（P3） |

## 3. P2 —— 提现额度/税 + 季度分配 → **#410**

**前序核验**：P1 已合并（存在季度结算钩子）；确认 `/orgfundwithdraw` 当前**无税无额度**（`T-CityLite.base/resources/[custom]/custom-industry/server/commands.lua`）。

| 项 | 内容 |
|---|---|
| 为什么 | 提现没有摩擦时，"结算只清产业层"会被绕过：Boss 结算前把金库提进个人银行，软重置形同虚设 |
| 范围 | 提现加**周额度 $25,000**（按自然周桶）+ **20% 税**（税去处需明确：销毁或进城市账本）；季度结算把剩余金库 **Boss 40% / 成员平分**；两者都写审计 |
| 验收 | 一周内第二次顶格提现被拒；税计入审计；结算分配按人数分摊且留痕；`players` 表在结算前后**字节级一致**（个人层不动） |
| 不做 | 不改个人银行余额（宪法：个人层一个字节都不能动） |

## 4. P3 —— 库存上限可升级 → **#411**

**前序核验**：P1 已合并；确认 `stockCap` 当前是配置常量 540（`T-CityLite.base/resources/[custom]/custom-industry/config/facility.lua`）。

| 项 | 内容 |
|---|---|
| 为什么 | 540 = 满建 10 工位跑 12 小时的产量；一周产出约 7,560 件，囤货必然溢出 5/6 → "囤货过冬"永远 −41%。升级到 5,940（+900/级）才与"能卖就卖"打平 |
| 范围 | `industry_facility` 加 `stock_level`；价格 $40,000×1.6^级；上限 = 540 + 900×等级；手机端显示升级入口 |
| 验收 | 升级后 `stockCap` 生效（生产截断到新上限）；价格曲线与仿真一致；手机端能升、能看余量 |
| 不做 | 不改工位阶梯（$50k×1.35^n 保持） |

## 5. P4 —— 仿真器 MVP（驱动真实 Lua + 指标基线）→ **#412**

**前序核验**：P1–P3 已合并；`tools/dev/industry_sim/sim_v4.py` 仅作参考（它用 Python 复刻规则，会漂移）。

| 项 | 内容 |
|---|---|
| 为什么 | 参数要长期可调，必须有"改配置 → 离线跑 → 与基线比 → 超阈值报警"的闭环；Python 复刻规则会与线上漂移 |
| 范围 | 复用 `T-CityLite.base/tests/unit/layer3_business/industry_harness.py` 装配链，驱动真实 `production/sale/settlement/cycle`；策略只实现 `decide(ctx)`；输出 JSONL（每周一行）+ 汇总；基线 JSON 进 CI |
| 验收 | 同参数两次跑结果一致（确定性）；改一个配置项，基线比对能报出超阈值；CI 耗时 < 5 分钟 |
| 不做 | 不做多组织抢单时序（下一片）；不模拟玩家在线时长 |

## 6. 施工纪律

- 每片先红后绿：先写复现用例（贴失败输出），再改代码；
- 迁移必须连跑两次幂等；
- `players` / `player_vehicles` / `inventories` 在**任何**结算相关改动前后 checksum 一致；
- 每片一个 PR，标题 `<type>(industry): …`，提交信息里写清"前序核验"的实测结论；
- 真机验收按 `docs/engineering/LIVE_VERIFICATION.md` §2.1（`industry_phase_seconds` 等 convar 改完要重启资源）。
