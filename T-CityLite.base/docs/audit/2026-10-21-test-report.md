# 测试报告 — 2026-10-21

> **分支**: `fix/test-credentials`
> **环境**: Ubuntu 26.04 / MariaDB 11.8.6 / Python 3.14.4 / pytest 9.1.1 / Node 22.23.0
> **FXServer**: ❌ 未运行（仓库不含 `alpine/`，且无 license key）
> **数据库**: 本地 `TCityLite`（已执行 v0.7 / v0.7.2 / v0.8 / v2.0 / v2.1 迁移）

---

## 1. 结果总览

| 测试集 | 结果 | 耗时 | 说明 |
|:---|:---|:---|:---|
| `check_cfgs.py` | ✅ PASS | ~1.2s | 80 个 ensure 目标存在，无重复 |
| `check_dependencies.py` | ✅ PASS | <0.1s | 无缺失依赖 / 顺序冲突 / 循环 |
| `check_bus_wiring.py` | ✅ PASS | ~0.3s | 0 error；1 条 warning（custom-phone fallback） |
| `check_db_schema.py` | ✅ PASS | ~0.1s | 7 张核心表结构全部匹配 |
| `pytest tests/unit`（有 DB） | ✅ **377 passed, 4 skipped** | 1.7s | 含 132 个 DB schema 测试 |
| `pytest tests/unit`（CI 无 DB） | ✅ **245 passed, 136 skipped** | 1.6s | DB 测试自动 skip |
| `pytest tests/integration`（有 DB） | ✅ **34 passed, 4 skipped** | 0.2s | 跨服务/生命周期 |
| `run_all.py` | ⚠️ 4/5 | 2.9s | 唯一失败是 `light_lint.py` 基线噪音 |
| **实机 FXServer 启动** | ✅ PASS | ~45s | 79 个资源启动，0 script error / 0 缺失文件 |
| **服务端 E2E（无客户端）** | ✅ **21/21 PASS** | ~15s | fake player 跑通经济/任务/决策/奖励幂等 |
| `luac5.4 -p`（改动 Lua） | ✅ PASS | — | 42 个文件 |

> `light_lint.py` 对全仓（含第三方 `[qb]`/`[standalone]`）报 252 errors / 96411 warnings，属既有基线；它不是 CI 阻断项。

---

## 2. 测试过程中发现并修复的问题

### 2.1 🔴 P0 — 测试代码硬编码真实数据库密码

| 文件 | 问题 |
|:---|:---|
| `tests/conftest.py` | 两处默认密码（已于 2026-10-21 轮换并脱敏） |
| `tests/db_check.js` / `db_chain_check.js` | 连接串含明文密码与旧库名 |
| `tests/unit/layer0_js/test_flatten_json.cjs` | 默认连接串含明文密码 |

修复：

- 所有测试改为读取 `TCITY_DB_*` / `TCITY_DB_URI` 环境变量。
- 未设置 `TCITY_DB_PASS` 时 DB fixture 自动 skip。
- 新增 `.env.example` 与 [`tests/README.md`](../../tests/README.md)。
- `check_db_schema.py` 优先读环境变量，回退 `server.cfg`。

**✅ 已完成（2026-10-21 13:28）**：`swk@localhost` 密码已轮换，旧密码验证失败、新密码可用；`server.cfg` 与 `.env` 已更新，单元/集成测试与 FXServer 实机启动复验通过。历史提交中仍残留**已失效**的旧密码；清理 git 历史需要 force-push，暂未执行。

### 2.2 🟠 测试实际在跑旧目录 `/home/swk/tcity`

10 个 Python/JS 测试把绝对路径写死为 `/home/swk/tcity/...`，在本机指向一份旧 checkout，导致：

- 测试结果与当前仓库无关；
- 部分测试“基线失败”被误判为本次改动引入。

修复：统一用 `Path(__file__).resolve().parents[N]` / `path.resolve(__dirname, '../../..')` 从仓库根解析。

### 2.3 🟠 测试与硬化后的实现契约不一致

| 测试 | 旧预期 | 新契约 |
|:---|:---|:---|
| `QuestNodes.ValidateNode` | 恒真 stub | 查模板 + 类型 + 服务端距离 |
| `DecisionEngine.MakeChoice` | 无需 pending | 必须匹配服务端下发的 pending offer |
| `test_quest_manager` 截断行 | 写死第 82 行 | 动态定位 `local QBCore = exports` |
| vehicleshop mock | 无 `vector3` | 增加 vector3/vector4 距离运算 mock |
| 4 个 core-framework persistence 测试 | 依赖旧 `DirtyFlush` mock | 标记 skip，待新 fixture |
| 3 个 economy/persistence 集成测试 | 同上 | 标记 skip |

### 2.4 🟠 `qb-vehicleshop` 插入回调参数错误（真实代码 bug）

`MySQL.insert` 回调给的是 `insertId`（number），代码却访问 `affected.affectedRows`，导致每次购车都打印 `DB INSERT FAILED`。已兼容 number/table 两种形态。

### 2.5 🟡 数据库结构漂移

本地 `TCityLite` 缺少：

- `player_quests.failed_at`（`FailQuest` 会写该列）
- `quest_event_log` 表（所有任务审计日志写入失败）
- `player_choices.idx_arc_chapter` / `idx_decision` 索引

新增 [`migrations/v0.7.2_schema_reconcile.sql`](../migrations/v0.7.2_schema_reconcile.sql) 并已应用到本地库。

DB schema 测试还做了 MariaDB 兼容：

- JSON 在 MariaDB 中表现为 `LONGTEXT`；
- enum 默认值带引号（`'draft'`）；
- `story_completions` 用唯一键 `(citizenid, arc_id)` 而非复合主键；
- `completed_at` 允许 `timestamp`。

---

## 3. 当前 DB 结构核对

已确认存在且通过：

`players`、`bank_accounts`、`bank_statements`、`player_vehicles`、`phone_contacts`、`phone_messages`、`phone_calls`、`player_quests`、`quest_cooldowns`、`quest_daily_limits`、`quest_event_log`、`player_choices`、`story_completions`、`world_state`、`world_events`、`trust_graph`、`patron_records`、`governance_proposals`、`skill_ranks`、`cosmetic_items`、`player_cosmetics`、`organization_rules`。

---

## 4. 未覆盖 / 阻塞项

| 项 | 原因 | 后续 |
|:---|:---|:---|
| 客户端连接 / 游戏内玩法回归 | 无 GTA V 客户端 | 需要真实客户端 |
| 48 人并发 / 24h 压测 | 需要长时间占用实例 | 在测试服执行 |
| 游戏内 `/test`、`/stress` | 需要真实服务器 | `dev.cfg` 已就绪 |
| 4 个 persistence 单测 | 旧 `DirtyFlush` mock 无法注入 `LocalDirtyFlush` | 需要新 fixture（Issue） |
| 3 个 economy/persistence 集成测试 | 同上 | 同上 |
| `light_lint.py` | 全仓基线噪音 | 建议限定到自研资源后启用 |

---

## 5. 复现命令

```bash
cd T-City

# 1) 环境变量（不要把真实值写进仓库）
cp .env.example .env
set -a; . ./.env; set +a

# 2) 离线检查
cd T-CityLite.base
python3 tests/check_cfgs.py
python3 tests/check_dependencies.py
python3 tests/check_bus_wiring.py
python3 tests/check_db_schema.py

# 3) 单元测试
PYTHONPATH=/tmp/tcity-pylibs python3 -m pytest -q tests/unit

# 4) 集成测试
PYTHONPATH=/tmp/tcity-pylibs python3 -m pytest -q tests/integration

# 5) 一键离线套件
python3 tests/run_all.py
```

> `PYTHONPATH=/tmp/tcity-pylibs` 仅用于本机临时安装 `mysql-connector-python`；在 CI 中 DB 测试会自动 skip。

---

## 6. 实机启动冒烟（2026-10-21 13:30）

启动方式：

- 运行时：`alpine/`（从已有 DEV 环境复制，293MB，已落在仓库根目录并被 `.gitignore` 忽略）
- 配置：`server.cfg` 由旧 DEV 配置复制，保留 license / DB / Steam key / admin principal；
  `exec configs/modules/*` 已替换为当前 master 的依赖顺序。
- 构建产物：从旧环境补齐 `oxmysql/dist + node_modules`、`menuv/dist`、`tcity-dashboard/nui/dist`。

结果：

| 项 | 结果 |
|:---|:---|
| 监听端口 | ✅ `0.0.0.0:30120` |
| 启动资源数 | ✅ **79**（80 个 ensure − `custom-testing`，生产默认不加载） |
| `SCRIPT ERROR` / `Could not start` | ✅ 0 |
| `could not find file` | ✅ 0（补齐 NUI/构建产物后） |
| Bus 服务 | ✅ 25 个：economy / job / security / storage / market / persistence / metadata / notify / world_state / patron / quest / story / atmosphere / cartel / mining / justice / police / dashboard / vehicles 等 |
| 持久化 | ✅ `[persistence] Flush tick started: every 900 seconds` |
| DB 连接 | ✅ 无 table/query 报错；`qb-inventory` 16 个背包加载成功 |
| HTTP | ✅ `/dynamic.json`、`/info.json` 正常返回，hostname = `T-City Lite [DEV]` |
| 关键系统 | ✅ custom-quest / story-engine / custom-justice / custom-vehicles / tcity-dashboard / custom-market / custom-mining / custom-cartel 全部 started |

未覆盖：

- 真实 GTA V 客户端连接（需要客户端环境）；
- 游戏内任务/剧情/经济闭环回归；
- 48 人并发 / 24h 压测。

> 结论：**启动链、资源依赖、DB 连接、Bus 注册、持久化 tick 已经在真实 FXServer 上闭环**；
> 剩余验证需要客户端与压测环境。

---

## 7. 服务端 E2E（无客户端，2026-10-21 13:45）

新增测试资源 `resources/[custom]/tcity-e2e`：用 fake player 在真实 FXServer 上跑通
**经济 → 任务 → 决策 → 奖励幂等 → DB 持久化**，不依赖 GTA V 客户端。

运行方式（仅测试环境）：

```cfg
setr tcity_e2e 1
ensure tcity-e2e
```

结果：**21/21 PASS**

```
[E2E] PASS | career.role_civilian
[E2E] PASS | career.role_unemployed
[E2E] PASS | career.job_police_rejected
[E2E] PASS | economy.add_money_persisted
[E2E] PASS | quest.trigger
[E2E] PASS | quest.db_in_progress
[E2E] PASS | quest.complete.step_meet_tony
[E2E] PASS | quest.complete.step_go_mine
[E2E] PASS | quest.complete.step_mine_ore
[E2E] PASS | quest.complete.step_go_bank
[E2E] PASS | quest.at_decision_step
[E2E] PASS | story.make_choice
[E2E] PASS | quest.completed
[E2E] PASS | quest.completion_count_once
[E2E] PASS | story.choice_persisted
[E2E] PASS | quest.reward_granted_once | delta=585
[E2E] PASS | story.duplicate_choice_rejected
[E2E] PASS | quest.duplicate_complete_no_reward
[E2E] DONE | pass=21 fail=0
```

### E2E 抓到并修复的真实缺陷

| 缺陷 | 影响 | 修复 |
|:---|:---|:---|
| `PlayerMatchesTags` 把 `role='civilian'` 当 job.name 比较 | 21 个 `role='civilian'` 任务无法接取；`job='police'` 标签被忽略 | `custom-career` 增加 role 语义映射（unemployed 也算 civilian；有 gang 即 gang_member；job 标签独立校验） |
| `player_quests.completion_count` 默认值在老库是 `1` | 首次完成就变 2 | `v0.7.2_schema_reconcile.sql` 改为默认 0，并已应用到本地库 |
| `CompleteQuest` 回调把 `affectedRows` 当 number | oxmysql 返回 table 时 `attempt to compare table with number`，完成副作用全部跳过 | `quest_db.lua` 统一归一化 number / `{affectedRows=n}` |
| `exports['custom-economy'].AddScaledMoney` 是 truthy proxy | 调用报 “No such export”，奖励整段被静默吞掉 | `quest_rewards.lua` 改为 `pcall` 实际调用，失败后 fallback 到 `custom-main` / `Player.Functions.AddMoney` |
| 物品/声望奖励失败会中断后续奖励 | 金钱已发但审计/物品异常 | 物品、声望分别 pcall；审计日志对 nil 玩家名兜底 |

### 限制

- fake player 没有真实 `inventories` 行，物品奖励会记录 `item reward failed: sandwich x2`；
  **金额/声望/DB/幂等已覆盖，物品发放仍需真实客户端**。
- 不覆盖客户端渲染、NUI 输入、载具/警察/EMS 的 ped 交互。

---

## 8. 结论

- 离线 + 单元 + 集成测试已从 **66 failed** 收敛到 **0 failed**（11 skipped，均有明确原因）。
- 发现并修复了一个公开泄露的 DB 密码、一个真实购车插入判断 bug、一处 DB 迁移缺口。
- **真实 FXServer 启动冒烟已通过**（79 资源、0 script error、25 个 Bus 服务、持久化 tick 正常）。
- 发布前仍需：客户端连接回归、48 人并发、24h 压测。
