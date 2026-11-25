---
id: industry-ops-s1-plan
type: plan
status: draft
system: economy
owner: hermes
updated: 2026-11-25
review_by: 2027-02-28
stage: P
plan_status: 1
---

# 计划：S1 组织金库地基（industry treasury）

> 阶段 P 的产物。上游：[12 — 产业运营与组织运营](../../server-design/12-industry-operations.md)（spec，PR #331 已合并）。
> 施工单元：[#333](https://github.com/wenkais196-Gabriel/T-City/issues/333)。epic：[#332](https://github.com/wenkais196-Gabriel/T-City/issues/332)。
> 本计划**只覆盖 S1**；S2–S7 见各自 issue。

```plan-status
P1 | done | #339 | 2026-11-25
P2 | done | #339 | 2026-11-25
P3 | done | #339 | 2026-11-25
P4 | done | #339 | 2026-11-25
P5 | done | #339 | 2026-11-25
P6 | done | #339 | 2026-11-25
```

---

## 1. 范围

**要做**

- 一个**组织金库**：余额 + 幂等流水 + 审计，唯一 owner、唯一写入口
- 四张 SQL 脚本层面的同步：迁移 / 测试 fixture / `table_owners`（含 scan 清单）/ 启动 wiring
- 4 条控制台命令（存 / 取 / 查余额 / 查流水），Grade 4 才可用

**明确不做**（防膨胀）

| 不做 | 为什么 |
|---|---|
| 设施 / 工位 / 库存 | S2 |
| 任何 net event、任何 NUI | S1 只有控制台命令；手机要等 S5 |
| 跨资源 exports（`service_industry_*`） | 还没有第二个消费者；登记表为零时加导出只是噪声 |
| 组织治理 / 分红 / 工资 | epic §14 |
| 负债（余额可负） | 会让 `balance >= 0` 这条唯一约束失效，是第二层机制 |

---

## 2. 溯源：验收倒推出来的硬依赖

| 验收要成立 | 倒逼出的实现约束 | 依据 |
|---|---|---|
| 重启后余额不变 | 必须落库，内存态一律不算 | —— |
| 个人层 −1000 且组织 +1000 | 个人层只能 `Player.Functions.RemoveMoney` | 金额写路径闸门只允许 qb-core 的 `player.lua` 直接赋值 `PlayerData.money` |
| 同一 `ref` 重复入账被拒 | `UNIQUE(org_id, ref)` + 用受影响行判，**不许先读后写** | 先读后写是 TOCTOU，并发下双花 |
| 余额不为负 | `UPDATE … WHERE org_id = ? AND balance + ? >= 0`，`affected = 0` → `insufficient_funds` | 校验写在 Lua 里挡不住并发 |
| 测试库能建表 | 迁移 + `tests/fixtures/tcity_schema.sql` 同步 | FIT-06 会验 fixture 必须建出迁移建的每一张表 |
| 资源真的会启动 | `configs/modules/economy.cfg` 加 `ensure` | 不在模块 cfg 里的资源不会起 |
| 新表被闸门看见 | `table_owners.json` 加 owner 块 **并把资源名加进 `scan`** | 当前 scan 只列 10 个资源，新资源默认逃出扫描 |

---

## 3. 验收标准（可执行）

| # | 标准 | 怎么验证 |
|---|---|---|
| 1 | 迁移幂等 | 连跑两次 `v4.0_industry_treasury.sql` 无错；`pytest tests/architecture/test_migration_versions.py` 绿 |
| 2 | fixture 与迁移一致 | `pytest tests/architecture/test_fixture_schema.py` 绿 |
| 3 | 表 owner 唯一且被扫描 | `pytest tests/architecture/test_table_owners.py`（或同族闸门）绿；`scan` 里有 `custom-industry` |
| 4 | 正常存取 | 存 1000 → 余额 1000、流水 1 行、个人 `bank` −1000 |
| 5 | 余额不足 | 取 9999 → `insufficient_funds`，余额不变、流水不增 |
| 6 | 幂等 | 同一 `ref` 第二次 → `duplicate_ref`，流水仍 1 行 |
| 7 | 并发同 ref | 两个 Deposit 同 ref → 只有一次成功 |
| 8 | 权限 | 非 Grade 4 → `not_boss`；控制台 `source = 0` 不报错 |
| 9 | 全量闸门 | `pytest tests/unit tests/architecture -q` 绿；`python tools/docs_lifecycle.py --check` 无新增 error |
| 10 | 真机 | `restart custom-industry` 前后余额与流水一致，控制台 0 `SCRIPT ERROR` |

**运行环境**：本机没有装 pytest 的解释器，验收命令统一用
`uv run --with pytest python -m pytest <path> -q`（Hermes 实测可用）。

---

## 4. 切片

| # | 切片 | 影响文件（精确） | 验证 |
|---|---|---|---|
| **P1** | 迁移 + 三处登记 | 新增 `T-CityLite.base/migrations/v4.0_industry_treasury.sql`；改 `T-CityLite.base/tests/fixtures/tcity_schema.sql`；改 `T-CityLite.base/tests/architecture/table_owners.json` | 标准 1–3 |
| **P2** | 资源骨架 + 启动接线 | 新增 `T-CityLite.base/resources/[custom]/custom-industry/{fxmanifest.lua,config.lua,server/main.lua}`；改 `T-CityLite.base/configs/modules/economy.cfg` | `tools/dev/boot_cfg.py --check`；起服后资源在列表 |
| **P3** | 金库单一写入口 | 新增 server/treasury.lua、server/audit.lua | 标准 4–7（单测） |
| **P4** | 命令层 | 新增 server/commands.lua，改 server/main.lua 接线 | 标准 8 |
| **P5** | 测试（先红后绿） | 新增 `tests/unit/layer3_business/fixtures/industry_treasury_probe.lua`、`tests/unit/layer3_business/test_industry_treasury.py` | 标准 4–9 |
| **P6** | 真机验收 | 无代码改动（只跑） | 标准 10 |

**依赖**：P1 → P2 → P3 → P4 → P5。P6 需要 P1–P5 全绿。

---

## 5. 关键实现约束（写错就白写）

1. **不许先读后写**：余额判断与扣减必须是**一条** `UPDATE … WHERE balance + ? >= 0`，
   读 `affectedRows`；`Db.Update(sql, params)` 返回 `affectedRows, err`。
2. **不许自己解 oxmysql 返回形状**：用 `Db.Insert` / `Db.Update` / `Db.Single` 封装；
   数字与 `{insertId, affectedRows}` 两种形状都见过。
3. **不许出现 `PlayerData.money[...] =`**：个人层扣款只走 `Player.Functions.RemoveMoney`。
4. **不许 `SELECT *`、不许无 `LIMIT` 的列表查询**（FIT-09）。
5. **命令处理器必须判 `GetPlayer(source)` 为 nil**（控制台 `source = 0`、玩家本帧掉线）。
6. **流水与余额成对**：先 `UPDATE` 余额，`affected = 1` 后再插流水；流水插失败必须把余额加回去
   （或在同一段里保证顺序，让失败方向永远不产生"钱少了流水没记"）。
7. **审计不落 PII**：只写 `citizenid`、金额、动作、结果码。

---

## 6. 先红后绿的证据要求

每个反例用例必须先**跑一次红的**并贴输出（在 PR 描述里），再改到绿。至少三段：

| 反向注入 | 期望变红 |
|---|---|
| 删掉 `WHERE balance + ? >= 0` | 余额不足用例红 |
| 删掉 `UNIQUE(org_id, ref)`（迁移里） | 幂等用例红 |
| 把余额判断改成"先 `Db.Single` 再比较" | 并发同 ref 用例红（或永远绿 → 说明并发用例没测到点上，要重写） |

---

## 7. 架构对照

- **涉及平面**：P3（server）为主，P4（三张新表）
- **跨平面契约变化**：无（无 net event、无 NUI、无 exports）
- **宪法对照**：

| 条 | 满足方式 |
|---|---|
| 1 服务端权威 | 四张命令全在服务端；金额不接受客户端参数以外的东西 |
| 2 钱只走两个出口 | 个人层 `Player.Functions.RemoveMoney`；组织层只走 `Treasury.*` 四个函数 |
| 3 SQL 纪律 | 参数化 + 显式列名 + 列表查询带 `LIMIT` |
| 5 幂等 | `UNIQUE(org_id, ref)`；迁移可重复执行 |
| 6 唯一 owner | `table_owners.json` 登记三张表 |
| 9 没有测试的修复不算完成 | §6 的三段反向注入 |

---

## 8. 登记表 / 预算同步清单（漏一件就红）

- [ ] `T-CityLite.base/tests/architecture/table_owners.json`：owner 块 + `scan` 加资源名
- [ ] `T-CityLite.base/tests/fixtures/tcity_schema.sql`：建三张表
- [ ] `T-CityLite.base/configs/modules/economy.cfg`：`ensure custom-industry`
- [ ] `CHANGELOG.md`：Unreleased → Added
- [ ] `T-CityLite.base/tests/architecture/test_cross_resource_writes.py`：`RESOURCE_DIRS` 加一行
      （`scan` 认这个映射，不加则 FIT-02 直接 KeyError）——**施工时才发现，原计划漏了**
- [ ] `docs/client/ux/admin-commands.md`：跑 `python tools/dev/scan_commands.py` 重生成
      （新命令要进清单；文档里是**生成物**，手改会被下一次重生成覆盖）——**施工时才发现，原计划漏了**
- [ ] 不需要动：`net_events_*`（无事件）、`service_contracts.json`（无导出）、
      `resource_wiring_allowlist.json`（无跨资源硬引用）、预算文件（无新闸门）

---

## 9. 回滚

- **代码**：`configs/modules/economy.cfg` 删掉 `ensure` 行 + `git revert`；convar `industry_enable` 默认 `false`，关掉后命令返回"未开放"
- **数据**：三张表保留不读即可（不写破坏性 down 迁移）
- **运行时**：`restart custom-industry`；不改动任何现有资源，所以停用后全是空操作

---

## 10. 施工记录

| 日期 | 事件 |
|---|---|
| 2026-11-25 | P1–P5 交付（`be684252`）。`architecture` 全绿、单测 13 条。 |
| 2026-11-25 | **真机 P0 #1**：`commands.lua` 用未定义的全局 `QBCore`，资源启动成功但四条命令全没注册（单测只加载 treasury，看不见）。修复 `30f689dc` + 不提供全局的注册用例。 |
| 2026-11-25 | **真机 P0 #2**：没有任何命令会创建 `org_treasury` 行，`grant` 恒 `no_account`，验收「存 1000 → 余额 1000」在真机不成立。修复 `8904986e`（`EnsureAccount` + 仅控制台 grant 开户）。 |
| 2026-11-25 | P6 真机读数：grant/查询/控制台拒绝取款/`restart` 后余额不变；`cartel` 首次 grant 自动开户并留 `fund.open` + `fund.grant` 两条审计。玩家侧 Grade4 授权路径 ⛔ 仍需客户端。 |

**两条 P0 的共同教训**：静态闸门与只加载单个文件的单测，都看不见「跨脚本作用域」与「真机链路完整性」。
S2 起，每个分片必须有一条**加载全部 server 脚本**的注册/接线用例，而不是只测纯逻辑模块。
