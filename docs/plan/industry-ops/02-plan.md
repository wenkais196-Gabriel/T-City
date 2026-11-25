---
id: industry-ops-s2-plan
type: plan
status: draft
system: economy
owner: hermes
updated: 2026-11-25
review_by: 2027-02-28
stage: P
plan_status: 1
---

# 计划：S2 设施 / 工位 / 库存（industry facility）

> 阶段 P 的产物。上游：[12 — 产业运营与组织运营](../../server-design/12-industry-operations.md)（spec），
> 前一片：[01-plan.md](./01-plan.md)（S1 组织金库，已合并 #339）。
> 施工单元：[#334](https://github.com/wenkais196-Gabriel/T-City/issues/334)。

```plan-status
Q1 | done | #350 | 2026-11-25
Q2 | done | #350 | 2026-11-25
Q3 | done | #350 | 2026-11-25
Q4 | done | #350 | 2026-11-25
Q5 | done | #350 | 2026-11-25
Q6 | done | #350 | 2026-11-25
```

---

## 1. 范围

**要做**

- 一处产业设施（**一组织一设施**）+ 等级 + 工位数 + 库存
- 建设施 / 雇工位：**只花钱不赚钱**，所以它是整条链里最安全的一片
- 工位成本 `base × 1.35^(n-1)`（三道通胀闸里的"防垄断"那一道）
- 配方 config（形状抄 `custom-cartel`），本片只落配置、不跑生产

**明确不做**（防膨胀）

| 不做 | 为什么 |
|---|---|
| 生产结算 / 库存增长 | S3；本片只让 `stock` 列存在并恒为 0 |
| 销售 / 配额 | S4 |
| NPC 工位实体 | 工位是设施表的一个整数列；实体化吃掉全部工期与帧率预算 |
| 多设施 / 地块 / 坐标 | 一组织一设施；多地块要先解决位置、归属、冲突 |
| 拆除返还 | 先只做"建"，拆除返还涉及折旧口径，等 S6 转让机制一起定 |

---

## 2. 溯源：验收倒推出来的硬依赖

| 验收要成立 | 倒逼出的实现约束 | 依据 |
|---|---|---|
| 成本曲线正确 | `cost(n) = floor(base × 1.35^(n-1))`，n = 已建工位数 + 1 | 设计 §10 |
| 扣的是**组织的钱** | 复用 S1 的 `Treasury.Withdraw`，不新开写路径 | S1 已验收 |
| 余额不足时不建 | `Treasury.Withdraw` 返回 `insufficient_funds` 时**不得**留下半成品行 | 宪法 5（可重试/幂等） |
| 一组织一设施 | `industry_facility.org_id` 是 PK | 设计 §8 |
| 上限生效 | `workstations >= max` → `cap_reached`，**不扣钱** | 设计 §11 |
| 新表被闸门看见 | 迁移 + fixture + `table_owners`（owner 已存在，加表名） | FIT-02 / FIT-06 |
| 命令真的注册了 | **加载全部 server 脚本**的接线用例（S1 真机 P0 教训） | 01-plan §10 |

---

## 3. 验收标准（可执行）

| # | 标准 | 怎么验证 |
|---|---|---|
| 1 | 迁移幂等 | 连跑两次无错；`test_migration_versions.py` 绿 |
| 2 | fixture 与迁移一致 | `test_fixture_schema.py` 绿 |
| 3 | 建造成本 | 第 1/2/3 个工位分别扣 `base` / `floor(base×1.35)` / `floor(base×1.35²)` |
| 4 | 余额不足 | 不扣钱、不建行、返回 `insufficient_funds` |
| 5 | 上限 | 第 N+1 个返回 `cap_reached`，`workstations` 与余额都不变 |
| 6 | 一组织一设施 | 同一组织第二次建 → 复用同一行（升级），不产生第二行 |
| 7 | 审计 | 每次购买一行；失败也留痕 |
| 8 | 接线 | 加载全部 server 脚本（**不提供全局 QBCore**）后，新命令名出现在注册表里 |
| 9 | 全量闸门 | `pytest tests/unit tests/architecture -q` 绿；`docs_lifecycle --check` 无新增 error |
| 10 | 真机 | 建 3 个工位 → 库与余额对得上；`restart` 后仍在；控制台 0 `SCRIPT ERROR` |

---

## 4. 切片

| # | 切片 | 影响文件（精确） | 验证 |
|---|---|---|---|
| **Q1** | 迁移 + 三处登记 | 新增 `T-CityLite.base/migrations/v4.1_industry_facility.sql`；改 `tests/fixtures/tcity_schema.sql`；改 `tests/architecture/table_owners.json`（owner 块加 `industry_facility`） | 标准 1–2 |
| **Q2** | 设施类型 + 配方 config | 新增 `custom-industry/config/` 下的设施与配方定义（纯数据，P0 平面） | 配置加载用例 |
| **Q3** | 金库对接的服务端动作 | 新增 server/facility.lua（Build / AddWorkstation / Get），全部经 Treasury | 标准 3–7 |
| **Q4** | 命令 | 新增 server/commands_facility.lua，改 main.lua 接线 | 标准 8 |
| **Q5** | 测试 | 改 `tests/unit/layer3_business/test_industry_treasury.py` 同目录新增 `test_industry_facility.py` + probe | 标准 3–9 |
| **Q6** | 真机 | 无代码改动（只跑） | 标准 10 |

**依赖**：Q1 → Q2 → Q3 → Q4 → Q5。Q6 需要 Q1–Q5 全绿。

---

## 5. 关键实现约束（写错就白写）

1. **支付只有一个入口**：`Treasury.Withdraw(orgId, cost, reason, {actor, ref})`；本片**不许**出现第二条余额写路径。
2. **先付钱、再写设施行**；写行失败要把钱退回（补偿），失败方向永远是"钱没少、设施没建"。
3. **一个组织一行**：用 `INSERT ... ON DUPLICATE KEY UPDATE` 或先查后插都不行（并发下会双行），
   必须靠 PK 冲突 + 单条 `UPDATE` 推进等级，形状与 S1 的余额守卫一致。
4. **上限检查放在同一条 UPDATE 的 WHERE 里**（`AND workstations < ?`），`affected = 0` → `cap_reached`，
   不要先读再判。
5. **审计不落 PII**；`ref` 由服务端生成。
6. **客户端零参与**：本片没有客户端代码，全是命令。

---

## 6. 先红后绿的证据要求

| 反向注入 | 期望变红 |
|---|---|
| 删掉 `AND workstations < ?` 上限守卫 | 上限用例红 |
| 把成本公式改成线性（去掉 1.35 指数） | 成本曲线用例红 |
| 先扣钱后校验上限（顺序颠倒） | 「上限时不扣钱」用例红 |
| 删掉 main.lua 里的命令注册 | 接线用例红（这条对应 S1 的 QBCore 事故） |

---

## 7. 架构对照

- **涉及平面**：P3（server）、P4（一张新表）、P0（config 纯数据）
- **跨平面契约变化**：无（无 net event / 无 NUI / 无 exports）
- **宪法对照**：1（服务端权威）、2（钱只走既定出口）、5（幂等）、6（表 owner）、9（测试）

---

## 8. 登记表同步清单

- [ ] `tests/fixtures/tcity_schema.sql`：建 `industry_facility`
- [ ] `tests/architecture/table_owners.json`：`custom-industry` 的 `tables` 加 `industry_facility`
- [ ] `docs/client/ux/admin-commands.md`：跑 `python tools/dev/scan_commands.py` 重生成
- [ ] `CHANGELOG.md`
- [ ] 不需要动：`economy.cfg`（S1 已 `ensure`）、`net_events_*`、`service_contracts.json`

---

## 9. 回滚

- **代码**：`industry_enable` 默认 `false`，关掉后新命令不注册；`git revert`
- **数据**：`industry_facility` 保留不读即可
- **运行时**：`restart custom-industry`

---

## 10. 施工记录

| 日期 | 事件 |
|---|---|
| 2026-11-25 | Q1–Q5 交付（`800f7ee1`）。单测 9 条 + S1 的 16 条共 **25 passed**；`architecture` 880 passed。 |
| 2026-11-25 | **四段反向注入全部变红**（CC 报告）：删上限守卫 / 成本改线性 / 先扣钱后判上限 / 删 main.lua 注册。第 1 条的行为用例逻辑上与「预读 + 乐观锁」重叠，故额外断言**实际执行的 UPDATE SQL** 含守卫——这是有意为之，写在用例 docstring。 |
| 2026-11-25 | Hermes 独立复核：自己把成本公式改成线性 → `test_workstation_cost_curve_is_exponential` 红；还原 → 绿。 |
| 2026-11-25 | **Q6 真机通过**（玩家实测 + 库对账）。`orgbuild mining_co mine` 扣 50000；`orghire mining_co 3` 扣 **208625 = 50000+67500+91125**，与 `base × 1.35^(n-1)` 完全一致；`industry_facility` = `mine/L1/workstations=3/stock=0`；`org_ledger` 4 行 `balance_after` 连续（306300→256300→206300→138800→47675）；`industry_audit` build + 3 次 hire，每条带 ref 与 workstations 序号。 |

**真机顺手暴露的一条设计约束**：`orgbuild` / `orghire` 都需要 **actor citizenid + Grade 4**，因此**控制台跑不了**（返回「该命令只能由在线玩家执行」），
与 S1 的 grant/query 不同。这意味着 S3（生产）/ S4（销售）/ S6（周期）的真机验收都会卡在「需要有人在键盘前」。
→ 已作为待定项记录：是否给后续分片补一条 convar 门控的后台命令（默认关、仅 `source == 0`、调**同一个**生产入口）。
