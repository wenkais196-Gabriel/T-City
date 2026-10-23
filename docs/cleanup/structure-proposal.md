# T-City 仓库结构与分类整改提案

> **状态**：提案（未执行任何移动）
> **基线**：`chore/repo-cleanup` @ `99e0c27`，工作区干净
> **范围**：只读分析 + 可执行搬迁方案；不含 FXServer 操作、不含 `git commit`
> **方法**：所有引用均来自 `git grep`（命令见附录 A），未凭印象填写；行号以 `99e0c27` 为准

---

## 0. 基线数字

| 指标 | 数值 |
|:---|:---|
| 跟踪文件 | 6,216 |
| Markdown 总数 | 497（第三方资源内 317，非第三方 180） |
| `docs/` | 46 个文件（44 篇 md + 2 份 HTML 报告） |
| `T-CityLite.base/docs/` | 83 个文件（80 篇 md，含 40 篇根级散落） |
| 资源目录 | 114 个，分 7 类 |
| `ensure` 行数 | 82（`configs/modules/*.cfg`） |
| 顶层目录 | 10 个（含 `design/`、`storys/`、`default/`、`QBCore_Lite_versions/`、`.hermes/`） |

---

## 1. 结论摘要：现状的 3 个最大问题

### P1 两个文档根，同名主题各存一份，入口文档缺失

`docs/`（44 篇 md + 2 份 HTML）与 `T-CityLite.base/docs/`（80 篇 md）是平级的两个文档根，同一主题分散在两边：

| 主题 | 位置 A | 位置 B | 说明 |
|:---|:---|:---|:---|
| Agent 文档 | `T-CityLite.base/docs/agent/` 23 篇（STATUS/ACTIONS/TOOLS/EVAL/SMOKE/DIRECTOR/API/CLIENT_HARNESS + design/5 + reviews/8） | `docs/agent/phone/` 3 篇 | `docs/agent/` 下**只有** `phone/`，没有任何 agent 正文 |
| Bus API | `docs/04_call_reference/bus_api_reference.md` | `T-CityLite.base/docs/bus-api-reference.md` | 两篇都是 Bus API 手册 |
| 开发工作流 | `T-CityLite.base/docs/dev-workflow-guide.md`（145 行） | `T-CityLite.base/docs/standards/dev_workflow.md`（72 行） | 同目录内两份 |
| 商店抢劫 / 转义重构 | `docs/store-robbery-redesign-20260601.md`（200 行）、`docs/refactor-escape-sqli-20260601.md`（84 行） | `design/store-robbery-redesign-20260601.md`（219 行）、`design/refactor-escape-sqli-20260601.md`（71 行） | 同名不同内容，同属 `106ba48` 一次提交 |

**直接后果**（已实测）：

- `AGENTS.md` 有 8 处写成 `docs/agent/STATUS.md`、`docs/agent/ACTIONS.md` 等（`:136`、`:189`–`:194`、`:204`），而该路径在仓库根**不存在**，真身在 `T-CityLite.base/docs/agent/`。能"看懂"只是因为读者自己猜了第二个根。
- `T-CityLite.base/docs/audit/2026-10-21-review-and-three-phase-plan.md:140` 已经把这件事记为缺陷：*"`docs/server-design/*` 在仓库根 `docs/`，但代码注释按 `T-CityLite.base/docs/server-design` 引用 | 路径漂移"*。
- 全仓相对链接扫描命中 20 条，剔除代码片段误报后**真实失效 12 条**：`docs/agent/phone/qb-phone-research.md` 9 条（`%5Bcustom%5D` URL 编码成假路径）、`QBCore_Lite_versions/README.md`→`../quest-system-design.md`、`T-CityLite.base/docs/audit/2026-10-21-test-report.md`→`../migrations/v0.7.2_schema_reconcile.sql`、`T-CityLite.base/docs/agent/reviews/03-contract-ci.md`→`TOOLS.md`。
- 失效**不会被 CI 拦住**：`docs-check` job 只 `print` 缺失列表，脚本没有 `sys.exit(1)`（`.github/workflows/ci.yml:107-131`），永远 exit 0。
- 仓库根**没有** `README.md`；`docs/` 与 `T-CityLite.base/docs/` 都**没有** README 索引（`T-CityLite.base/docs/agent/README.md` 是 read-layer 规格而非全集索引；`standards/README.md`、`docs/server-design/README.md` 只为各自子目录做索引）。

### P2 两棵同名 `tests/agent/` + `T-CityLite.base/tests/` 根目录平铺 31 个文件

- 根 `tests/agent/`：8 个 pytest，测 `tools/*.py`（`REPO_ROOT = parents[2]` + `sys.path.insert(REPO_ROOT/"tools")`）。
- `T-CityLite.base/tests/agent/`：Lua harness（`lua/runner.lua` + 9 个 case + 3 个 stub）+ `test_director_rules.lua` + `test_agent_actions_policy.lua` + `test_lua_harness.py`。
- 两者**同名不同含义**，`git grep 'tests/agent'` 命中 **139 行 / 43 个文件**，需要读者根据上下文猜是哪一个。CI 自己也从同一工作目录分别跑两个（`.github/workflows/ci.yml:66-67`：`pytest tests/agent` 与 `pytest ../tests/agent`）。

`T-CityLite.base/tests/` 根目录平铺 31 个文件，混杂 7 类东西：

| 类别 | 数量 | 例 |
|:---|:---:|:---|
| CI 检查脚本 | 8 | `check_cfgs.py`、`check_dependencies.py`、`check_bus_wiring.py`、`check_db_schema.py`、`check_lua_syntax.py`、`light_lint.py`、`run_all.py`、`conftest.py` |
| 游戏内 Lua 测试 | 18 | `vehicle_*_test.lua`(6)、`simulate_aviation_routes{,_v2,_v3,_v4}.lua`(4)、`validate_aviation_medical_airlift{,_v2}.lua`(2)、`run_all_tests.lua`、`integration_test.lua`、`v0.5_e2e_test.lua`、`architecture_stress_test.lua` 等 |
| JS | 3 | `db_check.js`、`db_chain_check.js`、`package-lock.json` |
| 其它 | 2 | `package.json`、`README.md` |

**搬迁陷阱**：4 个检查脚本用 `BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))`（`check_cfgs.py:11`、`check_dependencies.py:11`、`check_bus_wiring.py:23`、`light_lint.py:12`）——把 `tests/` 下移一层，`BASE_DIR` 会静默变成 `T-CityLite.base/tests`，CI 报的是"0 个 CFG / 0 个资源"而不是报错。`conftest.py` 必须留在 `tests/` 根（它是 `tests/unit`、`tests/integration` 的 fixture 来源）。

另外：18 个 Lua 测试**不在任何 fxmanifest、也不在 CI**，只能人工 `exec`；`docs/v0.5-architecture-migration.md:127` 已经登记过一条待办——"迁移 `tests/architecture_stress_test.lua` 到 `custom-testing/suites/`"。

### P3 资源目录把"来源"和"用途"混在一起

| 类别 | 目录数 | 实际构成 | 问题 |
|:---|:---:|:---|:---|
| `[standalone]` | 19 | 第三方库 11（PolyZone/oxmysql/menuv/progressbar/connectqueue/bob74_ipl/interact-sound/screenshot-basic/safecracker/cartel-gates/…）+ **自研 8**（`custom-cartel`、`custom-justice`、`custom-market`、`custom-mining`、`custom-storage`、`core-framework`、`notify-test`、`aaa_silence`、`hud-position-tool`） | 自研与第三方混放，"能不能改"无法从目录看出 |
| `[system]` | 7 | 自研 6（`core_economy`、`economy-dashboard`、`tcity-dashboard`、`tcity-atmosphere`、`atom_nodes`、`production-freeze`）+ 第三方 1（`monitor` = txAdmin） | 第三方 txAdmin 混在自研系统里 |
| `[custom]` | 20 | 18 个 `custom-*` + `story-engine`、`tcity-e2e` | 命名不一致；`custom-testing`、`custom-debug`、`tcity-e2e` 是测试/调试资源而非玩法 |
| `[cfx-default]` / `[defaultmaps]` | 6 / 3 | 引擎默认内容 | `AGENTS.md:53` 的资源分类只列了 5 类，这两类在文档里不存在 |

**关键事实（决定了风险等级）**：`ensure` 用的是**资源名**不是路径（`configs/modules/*.cfg`），`fxmanifest` 的 `@resource/file.lua` 也是按资源名解析。全仓 `[standalone]/` 的路径引用只有 **36 行**，其中 27 行是 `core-framework`；在 `.lua` 里只有 **1 行且是注释**（`[qb]/qb-core/server/services/persistence_manager.lua:5`）。**因此资源换类目录基本不动运行时**，成本集中在文档、CODEOWNERS 和 `tests/conftest.py:resolve_resource`。

### 附带：仓库根目录卫生（一并处理，风险极低）

| 文件 | 问题 | 证据 |
|:---|:---|:---|
| `admins.json` | 已入库的 txAdmin 管理员文件，含 **bcrypt 密码哈希** + `fivem:15797584` 标识符，且**未在 `.gitignore` 中** | 初始提交 `1e39c45` 引入；`.gitignore` 只忽略 `T-CityLite.base/default/` 与 `config.json`，不含 `admins.json` |
| `default/config.json` | txAdmin profile，含 `"dataPath": "F:/t-city/T-CityLite.base/"`（别人的机器路径） | 虽被 `config.json` 规则匹配，但已跟踪，故仍入库 |
| `design/` | 2 篇与 `docs/` 同名不同内容的重复稿 | 见 P1 表 |
| `storys/` | 目录名拼写错误（应为 `stories`），1 篇 30KB 叙事设计，**0 处引用** | `git grep '中东翻版'` 只命中文件自身 |
| `start_txadmin.bat` | 硬编码 `cd /d D:\server`，`%~dp0` 与 `D:\server` 混用 | 本地启动脚本，0 处引用 |
| `fxmanifest_inventory.json` | 64KB 生成物，`"path"` 用 Windows 反斜杠，已过期 | 0 处代码引用 |
| `simulation_report.json` | `tools/oneoff/sandbox_simulator.py` 的输出物 | `sandbox_simulator.py:443` `--output` 默认值即 `simulation_report.json`（写 cwd） |
| `QBCore_Lite_versions/` | 16 篇 v0.1–v1.0 历史版本规格 | 仅 `PROJECT_PROGRESS.md:30-39` 引用 |

---

## 2. 目标结构（只列要动的部分）

图例：`[NEW]` 新增 · `[MOVE]` 搬迁 · `[KEEP]` 明确保留 · `[DEL]` 删除

```
T-City-agent/
├── README.md                          [NEW]  仓库入口（现在没有）
├── AGENTS.md                          [edit] 全部改为「带根的完整路径」
├── .gitignore                         [edit] +admins.json +default/config.json
│                                             +simulation_report.json +fxmanifest_inventory.json
├── docs/                              # 唯一「产品 / 运营 / 设计 / 分析」文档根
│   ├── README.md                      [NEW]  索引：00–04 + 05–08 + archive
│   ├── 00_SERVER_MASTER_MANUAL.md     [KEEP]
│   ├── 01_module_manuals/ … 04_call_reference/   [KEEP]
│   ├── 05_agent/                      [NEW]  Phase 3 才考虑；Phase 2 只把 phone 汇入 base
│   ├── 06_design/                     [MOVE] docs/design 两篇 + 根 design/ 两篇（去重后留一份）
│   ├── 07_narrative/                  [MOVE] storys/中东翻版剧情_叙事设计全案.md
│   ├── analysis/                      [KEEP] tuning_shop_* / agent-e2e-testing-*
│   ├── server-design/                 [KEEP] 08-agent-director.md 被 3 处基座文档引用
│   └── archive/                       [NEW]  一次性报告（refactor-escape-sqli 等）
│
├── T-CityLite.base/
│   ├── docs/
│   │   ├── README.md                  [NEW]  base 文档索引（6 个目录 + 40 篇归档候选）
│   │   ├── agent/                     [KEEP] 唯一 agent 文档簇
│   │   │   └── phone/                 [MOVE] ← docs/agent/phone/（3 篇）
│   │   ├── standards/ architecture/ systems/ audit/   [KEEP]
│   │   └── archive/                   [MOVE] 40 篇根级 v0.x-*.md / *-report.md
│   ├── tests/
│   │   ├── README.md                  [edit] 更新 65/66/75 行的路径
│   │   ├── conftest.py                [KEEP] pytest 根级 fixture，不能动
│   │   ├── check_*.py / run_all.py / light_lint.py   [KEEP] CI 直连，路径写死
│   │   ├── game/                      [MOVE] 18 个 .lua（run_all_tests、vehicle_*、simulate_aviation_* …）
│   │   ├── js/                        [MOVE] db_check.js / db_chain_check.js / package*.json
│   │   └── unit/ integration/ fixtures/ nui/ agent/   [KEEP]  agent 见「不建议动」
│   └── resources/
│       ├── [custom]/                  [MOVE] +5 个误放的自研 custom-*，+3 个自研 dev 工具
│       ├── [system]/                  [KEEP] 自研系统服务（monitor 见「不建议动」）
│       ├── [standalone]/              [KEEP] 收敛为「只放第三方库」
│       ├── [qb]/ [voice]/ [cfx-default]/ [defaultmaps]/   [KEEP]
│       └── （不新增 `[dev]` 类别）      # 新增类别会让 conftest.resolve_resource 找不到
│
├── tests/                             # 仓库根测试 = 测 tools/ 的 pytest
│   └── tools/                         [MOVE] ← tests/agent/（8 个 .py，内部路径不变）
│
├── tools/
│   ├── agent_*.py / agent_tools.json  [KEEP] 见「不建议动」
│   ├── dev/                           [MOVE] install-hooks.sh、bootstrap_github.sh
│   ├── oneoff/                        [MOVE] ← tools/oneoff/（3 个一次性脚本）
│   └── windows/                       [KEEP] + start_txadmin.bat
│
├── design/                            [DEL]  内容并入 docs/06_design/ 后删除
├── storys/                            [DEL]  内容迁入 docs/07_narrative/ 后删除
├── default/                           [DEL]  运行时产物
├── admins.json                        [DEL]  安全项，见 M5
└── start_txadmin.{sh,bat}             [KEEP]/[MOVE bat→tools/windows/]
```

**分类原则（写进 `docs/README.md`，后续靠它判断）**

1. `[custom]` = 自研、需要人读人改；`[standalone]` = 第三方、按上游原样保留。
2. `[system]` = 自研的**基础设施/服务**（不进玩法），`[qb]` = QBCore 上游。
3. 目录类别 ≠ 运行时依赖；`ensure` 只认资源名，换类目录不动 `configs/modules/*.cfg`。
4. 文档只有一个"人读根" `docs/`；`T-CityLite.base/docs/` 只放**与代码同生命周期**的工程规范与生成物。

---

## 3. 迁移表

每行都是可独立提交、可独立回滚的单元。风险等级：🟢 低（无代码影响）· 🟡 中（需改脚本或 CI）· 🔴 高（跨运行时/历史）。

### M1 手机文档汇入 agent 文档簇 🟢

| 原路径 | 新路径 | 理由 | 需同步修改的引用（文件:行） | 风险 |
|:---|:---|:---|:---|:---|
| `docs/agent/phone/qb-phone-research.md` | `T-CityLite.base/docs/agent/phone/qb-phone-research.md` | `T-CityLite.base/docs/agent/` 已是 agent 文档唯一簇（23 篇 md），`docs/agent/` 只剩 phone，根目录留一个空壳 | `AGENTS.md:193`（表格行）、`AGENTS.md:204`（`docs/agent/phone/DESIGN.md`）；`qb-phone-research.md:844-848` 共 9 条相对链接需 `../../../`→`../../../../`，并顺手把 `%5Bcustom%5D` 还原为 `[custom]`（这 9 条当前本来就是坏的） | 🟢 纯文档；3 个文件，2 处外部引用 + 9 条内部链接，全部在同一次提交内可验证 |
| `docs/agent/phone/custom-phone-audit.md` | 同上目录 | 同上 | 无外部引用；文件内无相对链接 | 🟢 |
| `docs/agent/phone/DESIGN.md` | 同上目录 | 同上 | `AGENTS.md:204`；文件内无相对链接 | 🟢 |

> 收益：`docs/agent/` 消失后，`docs/agent/X` 只剩一种解析方式，`AGENTS.md` 的 8 处歧义自动收敛。

### M2 根 `tests/agent/` 改名 `tests/tools/` 🟡

| 原路径 | 新路径 | 理由 | 需同步修改的引用（文件:行） | 风险 |
|:---|:---|:---|:---|:---|
| `tests/agent/*.py`（8 个） | `tests/tools/*.py` | 这 8 个文件测的是 `tools/*.py`，与 `T-CityLite.base/tests/agent/`（Lua harness）同名不同义；改名后 `tests/agent` 只剩一种含义。目录深度不变 → `REPO_ROOT = parents[2]` 与 `sys.path.insert(REPO_ROOT/"tools")` **无需改动** | `.github/workflows/ci.yml:67`（`../tests/agent` → `../tests/tools`）；`AGENTS.md:92`、`:188`、`:214`；`T-CityLite.base/docs/agent/EVAL.md:10`、`:49`；`T-CityLite.base/docs/agent/STATUS.md:46`；`T-CityLite.base/docs/agent/design/03-tool-contract.md:481`；`T-CityLite.base/docs/agent/design/05-test-and-eval.md:307`、`:312` | 🟡 8 个文件移动 + 10 行引用；CI 必须同改 1 行。**不要**改 `docs/agent/reviews/*` 里的引用（历史快照） |
| — | `tests/README.md` [NEW] | 说明「根 `tests/` 测 `tools/`，`T-CityLite.base/tests/` 测资源」 | — | 🟢 |

> 替代方案（零风险，二选一）：不改名，只在 `tests/README.md` + `T-CityLite.base/tests/agent/README.md` 写清两者区别，并在 `AGENTS.md` 一律用带根路径。若本次只求稳，选这个。

### M3 根 `design/` 与 `docs/` 去重 🟢

| 原路径 | 新路径 | 理由 | 需同步修改的引用（文件:行） | 风险 |
|:---|:---|:---|:---|:---|
| `design/store-robbery-redesign-20260601.md` | `docs/archive/design-notes/store-robbery-redesign-20260601.md` | 与 `docs/store-robbery-redesign-20260601.md` 同名不同内容（219 行 vs 200 行，前者是设计稿、后者是用户手册），需人工决定哪份是正本；`git grep` 显示**两处都 0 引用** | 无（`git grep -n 'store-robbery-redesign\|refactor-escape-sqli'` 仅命中文件自身） | 🟢 0 引用；但内容有差异，**不要自动删**，先归档再由人合并 |
| `design/refactor-escape-sqli-20260601.md` | `docs/archive/design-notes/…` | 同上（71 行 vs 84 行） | 无 | 🟢 |

### M4 `storys/` → `docs/07_narrative/` 🟢

| 原路径 | 新路径 | 理由 | 需同步修改的引用（文件:行） | 风险 |
|:---|:---|:---|:---|:---|
| `storys/中东翻版剧情_叙事设计全案.md`（30KB） | `docs/07_narrative/中东翻版剧情_叙事设计全案.md` | 目录名拼写错误（`storys`）；内容仍有效（叙事设计），但游离在文档体系外；**0 处引用** | 无 | 🟢 |

### M5 清掉根目录的运行时产物与凭据 🔴（安全优先，但需单独处理）

| 原路径 | 新路径 | 理由 | 需同步修改的引用（文件:行） | 风险 |
|:---|:---|:---|:---|:---|
| `admins.json` | 删除（`git rm --cached` + `.gitignore`） | 含 master 账号 bcrypt 哈希与 `fivem:15797584`，可离线爆破；属 txAdmin 运行时文件，不应入库 | `.gitignore` 新增 `admins.json`；无代码引用 | 🔴 **历史里仍有哈希**：删文件不等于删历史。必须同时轮换密码（txAdmin 后台改密码会重写该文件），或对 `1e39c45` 做 `git filter-repo` |
| `default/config.json` | 删除 + `.gitignore` 补 `default/` | 含他人机器路径 `F:/t-city/...`；`default/` 是 txAdmin profile | `.gitignore` 现只忽略 `default/data/`、`default/logs/` | 🟡 已跟踪，忽略规则不生效，需 `git rm --cached` |
| `start_txadmin.bat` | `tools/windows/start_txadmin.bat` | 只有一个 `.bat` 游离在根，`tools/windows/` 已有 Windows 专用脚本；且脚本内 `cd /d D:\server` 已失效，顺手修 | 无引用 | 🟢 |
| `simulation_report.json` | 删除 + `.gitignore` | `sandbox_simulator.py:443` 的输出物 | 无 | 🟢 |
| `fxmanifest_inventory.json` | `tools/generated/fxmanifest_inventory.json` 或直接删 + `.gitignore` | 64KB 生成物、Windows 反斜杠路径、已与 114 个资源脱节；`git grep` 0 引用 | 无 | 🟢 决定"留档还是删"：留档就放 `docs/archive/` |

### M6 资源换类：把自研从 `[standalone]` 收回 `[custom]` 🟢

| 原路径 | 新路径 | 理由 | 需同步修改的引用（文件:行） | 风险 |
|:---|:---|:---|:---|:---|
| `[standalone]/custom-cartel` | `[custom]/custom-cartel` | 自研，`fxmanifest author 'T-City Lite'`；`[standalone]` 应收敛为第三方库 | 0 处代码引用；`docs/audit/2026-10-21-review-and-three-phase-plan.md:46` 已把它归为"自研资源" | 🟢 `ensure` 用资源名，cfg 不动；`conftest.py:resolve_resource` 会命中 `[custom]` |
| `[standalone]/custom-justice` | `[custom]/custom-justice` | 同上 | 0 | 🟢 |
| `[standalone]/custom-market` | `[custom]/custom-market` | 同上 | 0 | 🟢 |
| `[standalone]/custom-mining` | `[custom]/custom-mining` | 同上 | 0（`docs/*` 各 1 行历史报告提到路径，可不改） | 🟢 |
| `[standalone]/custom-storage` | `[custom]/custom-storage` | 同上 | 0 | 🟢 |
| `[standalone]/notify-test` | `[custom]/notify-test` | 自研调试工具 | 0 | 🟢 |
| `[standalone]/aaa_silence` | `[custom]/aaa_silence` | 自研启动链静音补丁 | 0 | 🟢 |
| `[standalone]/hud-position-tool` | `[custom]/hud-position-tool` | 自研 UI 调试工具 | 0 | 🟢 |
| `[standalone]/core-framework` | **不动** | 27 行引用 / 8 个文件（`CODEOWNERS:7`、`DELIVERY_MANUAL`、`audit/*`、`v0.5-*`），且它是"自研核心框架"，放 `[standalone]` 是历史约定 | 见 M6 备注 | 🟡 单独评估，不并入本次 |

> **M6 的判定依据**：`ensure` 与 `fxmanifest` 的 `@resource` 都按资源名解析；`.lua` 里唯一的类别路径引用是注释（`[qb]/qb-core/server/services/persistence_manager.lua:5`）。8 个目录移动，**cfg 零改动**，只需同批更新 `fxmanifest_inventory.json`（若保留）。
> `CODEOWNERS:7` 只登记了 `core-framework`，所以这 8 个移动**不需要改 CODEOWNERS**；若将来动 `core-framework`，必须同步 `CODEOWNERS:7`。

### M7 `T-CityLite.base/tests/` 根级 Lua/JS 归位 🟢

| 原路径 | 新路径 | 理由 | 需同步修改的引用（文件:行） | 风险 |
|:---|:---|:---|:---|:---|
| `tests/*.lua`（18 个，含 `run_all_tests.lua`、`vehicle_*_test.lua`(6)、`simulate_aviation_routes{,_v2,_v3,_v4}.lua`(4)、`validate_aviation_medical_airlift{,_v2}.lua`(2)、`validate_checkpoint_config.lua`、`integration_test.lua`、`v0.5_e2e_test.lua`、`architecture_stress_test.lua`、`police_dashboard_test.lua`） | `T-CityLite.base/tests/game/` | 它们不在任何 fxmanifest、不在 CI，只在服务端控制台 `exec`；与 CI 检查脚本混在根目录，看不出"要不要跑" | `T-CityLite.base/tests/README.md:75`；`T-CityLite.base/docs/v0.5-architecture-migration.md:127`；`REASONIX.md:311`；`T-CityLite.base/docs/audit/2026-06-20-delivery-report.md:151`；`run_all_tests.lua:15,19,27,29,32,34,137-147`（自身移动，内部 `exec tests/xxx` 提示串要改成 `exec tests/game/xxx`） | 🟢 无 CI、无 fxmanifest；但 4 代 `simulate_aviation_routes` 与 2 代 `validate_aviation_medical_airlift` 是**历史版本**，建议只保留最高版本，其余进 `tests/game/legacy/` 或删（需人确认） |
| `tests/db_check.js`、`tests/db_chain_check.js`、`tests/package.json`、`tests/package-lock.json` | `T-CityLite.base/tests/js/` | JS 冒烟测试与 pytest 混放；`npm install` 的落点更清晰 | `T-CityLite.base/tests/README.md:65`、`:66`（`cd T-CityLite.base/tests && npm install` → `cd T-CityLite.base/tests/js`） | 🟢 |
| `tests/conftest.py`、`run_all.py`、`check_*.py`、`light_lint.py` | **不动** | 见 P2 的搬迁陷阱：4 个脚本的 `BASE_DIR` 写死两层深度；`conftest.py` 是 `tests/unit`、`tests/integration` 的 fixture 源 | — | 🟢 不动就是最安全 |

### M8 `T-CityLite.base/docs/` 根级 40 篇 → `archive/` 🟢（链接多，但零代码）

| 原路径 | 新路径 | 理由 | 需同步修改的引用（文件:行） | 风险 |
|:---|:---|:---|:---|:---|
| `T-CityLite.base/docs/v0.{1,2,3,4,5,7}*.md`、`v0.7a-acceptance-report.md`、`v0.7b-v1.0-decision.md`（约 30 篇） | `T-CityLite.base/docs/archive/v0.x/` | 全是版本化历史交付物；`docs/01_resource_inventory.md:3` 已自标"历史快照" | 每篇被 1–3 个文件引用，全部是 Markdown；最集中的是 `T-CityLite.base/docs/audit/2026-10-21-*.md`、`T-CityLite.base/docs/v0.5-architecture-migration.md` | 🟢 无 `.py`/`.lua`/`.yml` 引用（已验证）；改完用附录 A 的链接脚本自查 |
| `DELIVERY_MANUAL.md`、`automated-testing-plan.md`、`dev-workflow-guide.md`、`global-audit-whitepaper.md`、`interaction_memo.md`、`menu-interaction-design.md`、`attention-items-solutions.md`、`refactoring_manifest_v2.md`、`gps-message-pattern.md`、`vehicleshop-purchase-sequence.md`、`test-report-v0.1-v0.4.md`（10 篇） | 同上 `archive/` | 同上；其中 `dev-workflow-guide.md` 与 `standards/dev_workflow.md` 主题重复，建议**二选一保留为规范**，另一篇归档 | `automated-testing-plan.md` 外部 2 处、`dev-workflow-guide.md` 外部 1 处、`test-report-v0.1-v0.4.md` 外部 1 处、`v0.1-maintenance.md` 外部 3 处 | 🟢 纯 Markdown |

> 决策点：`dev-workflow-guide.md`(145 行，含 `D:\` 的 Windows 目录树，已过时) vs `standards/dev_workflow.md`(72 行，是规范体例)。建议保留 `standards/dev_workflow.md`，另一篇归档。

### M9 `tools/` 只搬"一次性脚本" 🟢

| 原路径 | 新路径 | 理由 | 需同步修改的引用（文件:行） | 风险 |
|:---|:---|:---|:---|:---|
| `tools/dev/install-hooks.sh` | `tools/dev/install-hooks.sh` | 开发环境配置，不是 CI 入口；与 `tools/dev/bootstrap_github.sh` 同类 | `docs/DEVOPS.md:91`；脚本自身 `:5` 的用法注释 | 🟢 2 处引用 |
| `tools/dev/bootstrap_github.sh` | `tools/dev/bootstrap_github.sh` | 一次性初始化 GitHub 标签/里程碑/Issue，只跑一次 | `docs/DEVOPS.md:127`；`CHANGELOG.md:23`；脚本自身 `:10` 用法注释 | 🟢 3 处引用 |
| `tools/oneoff/concurrency_stress_test.py` | `tools/oneoff/concurrency_stress_test.py` | 第二个 `tools/` 目录，只有 3 个一次性脚本，容易和根 `tools/` 混淆 | 0 外部引用（仅自身 `:3` 注释） | 🟢 |
| `tools/oneoff/i18n_replacer.py` | `tools/oneoff/i18n_replacer.py` | 一次性文本替换工具 | 0 外部引用 | 🟢 |
| `tools/oneoff/sandbox_simulator.py` | `tools/oneoff/sandbox_simulator.py` | 经济沙盒模拟器，输出 `simulation_report.json` 到 cwd | `T-CityLite.base/docs/DELIVERY_MANUAL.md:424`、`:576`；`T-CityLite.base/docs/refactoring_manifest_v2.md:107`；`docs/server-design/08-agent-director.md:314` | 🟡 4 处文档引用 + 输出路径改为 `--output` 显式传入（否则会写到 `tools/oneoff/`） |

### M10 `T-CityLite.base/tests/agent/` 与 `tools/agent_*` 不动（列出仅为"已评估"）

| 原路径 | 结论 | 依据 |
|:---|:---|:---|
| `tests/agent/`（根） | 只改名（M2），不并入 base | 并入需改 8 个文件的 `parents[2]`、CI 一行、以及"从哪个目录跑"的语义 |
| `T-CityLite.base/tests/agent/` | **不动** | 155 次 `tests/agent` 命中里约 2/3（101 次）落在 `T-CityLite.base/docs/agent/{design,reviews}`，其中 reviews 是历史评审快照，改写会篡改记录；`lua/runner.lua` 是 `AGENTS.md:185` 登记的入口 |
| `tools/agent_*.py`（8）+ `tools/agent_tools.json` | **不动** | 见第 5 节 |

---

## 4. 引用影响

### 4.1 CI（`.github/workflows/*.yml`）

只统计**真正会受搬迁影响的**行：

| 文件:行 | 内容 | 受哪个迁移影响 | 处理 |
|:---|:---|:---|:---|
| `ci.yml:29` | `python3 -m compileall -q tests ../tools` | 无（`tests` 是 `T-CityLite.base/tests`，`../tools` 是根 `tools`；移动子目录不影响） | 不改 |
| `ci.yml:33` | `python3 tools/agent_tools.py --check` | 无（M9 不搬 `agent_tools.py`） | 不改 |
| `ci.yml:36/40/44` | `python3 tests/check_{cfgs,dependencies,bus_wiring}.py` | 无（M7 明确不搬 `check_*.py`） | 不改 |
| `ci.yml:65` | `python3 -m pytest -q tests/unit` | 无 | 不改 |
| `ci.yml:66` | `python3 -m pytest -q tests/agent` | 无（指 base 的 agent） | 不改 |
| **`ci.yml:67`** | `python3 -m pytest -q ../tests/agent` | **M2** | 改为 `../tests/tools` |
| `ci.yml:187` | `python -m pytest tests -q`（db-schema job，`working-directory: T-CityLite.base`） | 无（只收 base） | 不改 |

**结论：如果只做 Phase 1 + M1/M3/M4/M5/M6/M9，CI 零改动；做 M2 才改 1 行。**

两个附带事实，影响"CI 能不能兜底"：

1. `on:` 只有 `master` / `dev`（`ci.yml:3-7`），当前分支 `chore/repo-cleanup` 提 PR 到 `master` 会触发，但**直接 push 不触发**。
2. `docs-check`（`ci.yml:107-131`）永远 exit 0，链接腐烂不会红。若想让搬迁有安全网，**Phase 1 可加一行 `sys.exit(1 if missing else 0)`**——但这会把现有 12 条失效链接变成红灯，所以只能在 M1/M3/M8 修完后开。

### 4.2 fxmanifest / 运行时

| 影响面 | 结论 | 证据 |
|:---|:---|:---|
| `fxmanifest.lua` 的 `dependencies{}` / `@resource/file.lua` | **不受 M6 影响** | 全部按**资源名**解析，`configs/modules/*.cfg` 的 `ensure` 同理（82 条 ensure 全是裸名） |
| 资源类别路径的硬引用 | 全仓 `.lua` 仅 1 处，且是注释 | `git grep -F '[standalone]/' -- resources` → `[qb]/qb-core/server/services/persistence_manager.lua:5` |
| `tests/conftest.py:resolve_resource` | 按 `[standalone]→[system]→[custom]→[qb]` 顺序查找，M6 后仍能找到 | `conftest.py:39-55` |
| 新类别 `[dev]` | **不要建** | `resolve_resource` 的 patterns 是写死的 4 类，新类别会让测试报 `FileNotFoundError` |
| `CODEOWNERS` | M6 不需改；仅当动 `core-framework` 才改 | `.github/CODEOWNERS:7` 只登记 `[standalone]/core-framework`；`:9` 是 `[custom]/story-engine` |

### 4.3 文档链接

- 搬迁必须**同批**改链接的只有 M1（9 条）、M2（10 行）、M8（约 40 行）。
- `docs-check` 的等价本地自查（比 CI 严格，会失败退出）：

```bash
python3 - <<'PY'
import pathlib, re, subprocess, sys
files = subprocess.check_output(['git','ls-files','*.md'], text=True).splitlines()
missing = []
for f in files:
    p = pathlib.Path(f)
    for m in re.finditer(r'\[[^\]]*\]\(([^)\s]+)\)', p.read_text(encoding='utf-8', errors='ignore')):
        t = m.group(1)
        if t.startswith(('http://','https://','file://','mailto:','#')) or '`' in t:
            continue
        t = t.split('#')[0]
        if t and not (p.parent / t).exists():
            missing.append(f'{f} -> {t}')
print(f'{len(missing)} broken')
print('\n'.join(missing[:60]))
sys.exit(1 if missing else 0)
PY
```

### 4.4 `AGENTS.md`

`AGENTS.md` 是唯一的 agent 入口，也是路径歧义的主要载体。搬迁后必须同步的行：

| 行 | 现状 | 迁移后应写 |
|:---|:---|:---|
| `:92` | `python3 -m pytest -q tests/agent` | `tests/tools`（M2） |
| `:136` | `docs/agent/{STATUS,ACTIONS,TOOLS,EVAL,SMOKE}.md` | `T-CityLite.base/docs/agent/...`（Phase 1 就该改，不依赖搬迁） |
| `:188` | `tests/agent/*.py` | `tests/tools/*.py`（M2） |
| `:189`–`:192` | `docs/agent/...` | `T-CityLite.base/docs/agent/...`（Phase 1） |
| `:193` | `docs/agent/phone/...` | `T-CityLite.base/docs/agent/phone/...`（M1） |
| `:204` | `docs/agent/phone/DESIGN.md` | 同上（M1） |
| `:214` | `python3 -m pytest -q tests/agent` | `tests/tools`（M2） |
| `:53` | 资源分类只列 5 类 | 补 `[cfx-default]`、`[defaultmaps]`（Phase 1，纯文档） |

`AGENTS.md:3`、`:98`、`:185`、`:213`、`:215` 已经是带根路径，保持不动——这正是目标风格。

### 4.5 测试路径

| 消费者 | 路径假设 | 受哪个迁移影响 |
|:---|:---|:---|
| 根 pytest（8 文件） | `REPO_ROOT = Path(__file__).resolve().parents[2]` | M2 目录深度不变 → **不改** |
| `tests/agent/test_agent_contract_parity.py:30` | `REPO_ROOT/"T-CityLite.base/docs/agent/ACTIONS.md"` | 无（agent 文档不动） |
| `T-CityLite.base/tests/conftest.py:14-16` | `TESTS_DIR = dirname(__file__)`、`BASE_DIR = dirname(TESTS_DIR)` | M7 只搬子目录、不搬 conftest → **不改** |
| `check_cfgs.py:11` 等 4 个 | `BASE_DIR = dirname(dirname(__file__))` | 若不搬 `check_*.py` → **不改** |
| `run_all.py:15-22` | `BASE_DIR = dirname(__file__)` 后 `join(BASE_DIR, script)` | 不搬 → **不改** |
| `.githooks/pre-commit:12` | `os.path.join(BASE_DIR, 'tests', 'run_all.py')` | 不搬 → **不改** |

---

## 5. 分阶段执行

### Phase 1 — 只建目录 / 加索引（零风险，立即可做）

**改动：6 个新文件 + 1 个文件的小编辑；不移动任何文件；CI 不变。**

```bash
# 1) 目录骨架（git 不跟踪空目录，用 .gitkeep 占位）
mkdir -p docs/06_design docs/07_narrative docs/archive/design-notes
mkdir -p T-CityLite.base/docs/archive
mkdir -p T-CityLite.base/tests/game T-CityLite.base/tests/js
mkdir -p tools/dev tools/oneoff
for d in docs/06_design docs/07_narrative docs/archive/design-notes \
         T-CityLite.base/docs/archive T-CityLite.base/tests/game \
         T-CityLite.base/tests/js tools/dev tools/oneoff; do
  : > "$d/.gitkeep"
done

# 2) 新增索引（内容见下）
#    仓库根 README.md
#    docs/README.md
#    T-CityLite.base/docs/README.md
#    tests/README.md
#    T-CityLite.base/tests/agent/README.md

# 3) 只改文档、不动的修复：AGENTS.md 8 处路径补根前缀 + :53 补两类资源
#    （这一条即使后续 Phase 2 不做，也应单独修）
```

**新增文件的最小内容清单**

| 文件 | 必须包含 |
|:---|:---|
| `README.md`（仓库根） | 项目一句话；`T-CityLite.base/README.md` 入口；`AGENTS.md`（agent）；`docs/README.md`（人读文档）；启动 `./start.sh`；测试三条命令 |
| `docs/README.md` | 00–04 的导读表；`server-design/`（设计哲学 00–08）；`analysis/`；`05_agent`（当前在 `T-CityLite.base/docs/agent/`，指路）；`archive/`；"文档落哪"的 3 条规则（本文 §2 分类原则） |
| `T-CityLite.base/docs/README.md` | 6 个目录的用途；40 篇根级 md 标注"归档候选（见结构提案 M8）"；生成物说明（`agent/TOOLS.md`、`agent/schema.json` 由 `tools/agent_*.py` 生成，**不要手改**） |
| `tests/README.md`（根） | 明确：根 `tests/` = 测 `tools/` 的 pytest；`T-CityLite.base/tests/` = 测资源；两条命令各一行 |
| `T-CityLite.base/tests/agent/README.md` | Lua harness 入口 `lua/runner.lua`、9 个 suite、如何加 case；与根 `tests/` 的区别 |

**Phase 1 验收**

```bash
git status --porcelain            # 只应有 A（新增）+ M AGENTS.md
python3 -m pytest -q tests/agent  # 仍应全绿（未改名）
cd T-CityLite.base && python3 -m pytest -q tests/unit
```

### Phase 2 — 搬迁（低到中风险，建议 1 个迁移 1 个 commit）

顺序按"收益/风险"排序，前 3 个是全仓性价比最高的：

```bash
# M1 手机文档（3 文件）
git mv docs/agent/phone T-CityLite.base/docs/agent/phone
#   然后改 AGENTS.md:193,204；改 qb-phone-research.md:844-848 的 ../../../ → ../../../../ 与 %5Bcustom%5D → [custom]
rmdir docs/agent 2>/dev/null || true

# M2 根 tests 改名（8 文件）
git mv tests/agent tests/tools
#   然后改 ci.yml:67、AGENTS.md:92,188,214、EVAL.md:10,49、STATUS.md:46、
#   design/03-tool-contract.md:481、design/05-test-and-eval.md:307,312
python3 -m pytest -q tests/tools   # 必须与改名前的收集数一致

# M3 + M4 归档重复稿与游离目录（0 引用，先归档不删）
git mv design/store-robbery-redesign-20260601.md docs/archive/design-notes/
git mv design/refactor-escape-sqli-20260601.md docs/archive/design-notes/
git mv storys/中东翻版剧情_叙事设计全案.md docs/07_narrative/
rmdir design storys

# M5 根目录产物（安全项，单独 commit，需人确认）
git rm --cached admins.json default/config.json simulation_report.json
printf '\nadmins.json\ndefault/\nsimulation_report.json\nfxmanifest_inventory.json\n' >> .gitignore
git mv start_txadmin.bat tools/windows/start_txadmin.bat

# M6 资源换类（8 个目录，cfg 零改动）
for r in custom-cartel custom-justice custom-market custom-mining custom-storage \
         notify-test aaa_silence hud-position-tool; do
  git mv "T-CityLite.base/resources/[standalone]/$r" "T-CityLite.base/resources/[custom]/$r"
done
#   验证：ensure 名单不变
grep -rhoP '^\s*ensure\s+\K\S+' T-CityLite.base/configs/modules/*.cfg | sort -u > /tmp/ensure.after
#   （与搬迁前快照 diff，必须完全一致）

# M9 工具脚本
git mv tools/dev/install-hooks.sh tools/dev/
git mv tools/dev/bootstrap_github.sh tools/dev/
git mv tools/oneoff/concurrency_stress_test.py tools/oneoff/
git mv tools/oneoff/i18n_replacer.py tools/oneoff/
git mv tools/oneoff/sandbox_simulator.py tools/oneoff/
#   改 docs/DEVOPS.md:91,127、CHANGELOG.md:23、DELIVERY_MANUAL.md:424,576、
#      refactoring_manifest_v2.md:107、server-design/08-agent-director.md:314
```

**Phase 2 验收**

```bash
# 1. 命名类引用不再歧义
git grep -n 'tests/agent' -- . ':!T-CityLite.base'    # 应为空（只剩 base 内部）
# 2. 资源启动链完全没变
python3 T-CityLite.base/tests/check_cfgs.py
python3 T-CityLite.base/tests/check_dependencies.py
python3 T-CityLite.base/tests/check_bus_wiring.py
# 3. 注册表生成物未漂移
python3 tools/agent_tools.py --check
# 4. 链接自查（§4.3 脚本），允许归档目录内的历史链接暂留
```

### Phase 3 — 历史归档与收尾（低风险但噪音大，建议独立 PR）

```bash
# M8 base 文档：40 篇 → archive/（先按前缀分组，便于回滚）
cd T-CityLite.base/docs
git mv v0.*.md archive/
git mv test-report-v0.1-v0.4.md DELIVERY_MANUAL.md automated-testing-plan.md \
       dev-workflow-guide.md global-audit-whitepaper.md interaction_memo.md \
       menu-interaction-design.md attention-items-solutions.md \
       refactoring_manifest_v2.md gps-message-pattern.md \
       vehicleshop-purchase-sequence.md archive/
cd -

# M7 测试脚本归位
git mv T-CityLite.base/tests/*.lua T-CityLite.base/tests/game/
git mv T-CityLite.base/tests/db_check.js T-CityLite.base/tests/db_chain_check.js \
       T-CityLite.base/tests/package.json T-CityLite.base/tests/package-lock.json \
       T-CityLite.base/tests/js/
#   改 tests/README.md:65,66,75、v0.5-architecture-migration.md:127、REASONIX.md:311
#   改了 run_all_tests.lua 的 exec 提示串（:15-34、:137-147）

# 历史文档簇（可选，需先确认无人在用）
# T-CityLite.base/docs/audit/ → docs/archive/audit-2026-06-20/ 与 -2026-10-21/
# QBCore_Lite_versions/ → docs/archive/versions/（PROJECT_PROGRESS.md:30-39 的 10 条链接要改）
```

**Phase 3 附加建议**：修完链接后，把 `ci.yml` 的 `docs-check` 从 advisory 改成阻断（`sys.exit(1)`），否则下一轮腐烂仍然看不见。

---

## 6. 不建议动的部分及理由

| 范围 | 规模 | 理由 |
|:---|:---:|:---|
| `T-CityLite.base/resources/[qb]/` | 57 个资源 | QBCore 上游代码。改动会制造与 upstream 的永久 diff，`CODEOWNERS:10` 还专门登记了 `qb-core`；而且它不参与本次分类问题（第三方就该在 `[qb]`） |
| `T-CityLite.base/resources/[cfx-default]/`、`[defaultmaps]/` | 6 + 3 | 引擎默认内容（yarn/builders/地图）。`[cfx-default]` 内的 `[builders]/yarn` 有 4.6 万行打包产物，任何移动都会让 `git log` 与 diff 不可读 |
| `T-CityLite.base/resources/[voice]/` | 2 | 第三方语音资源，分类已经正确 |
| `T-CityLite.base/resources/[system]/monitor` | 1（很大） | txAdmin 官方资源，虽分类不准（第三方放进 `[system]`），但 `start_txadmin.sh` 依赖 `monitorMode` 启动；移动 293MB 级目录收益极低、review 成本极高 |
| `tools/agent_*.py`（8）+ `tools/agent_tools.json` | 9 | **280 行引用 / 20 个文件**，其中 `agent_tools.py` 53 行、`agent_mcp.py` 45 行、`agent_tools.json` 42 行；8 个 pytest 用 `REPO_ROOT/"tools"` 做 `sys.path`（`tests/agent/test_*.py:15-28`）；生成器把 `T-CityLite.base/docs/agent/{TOOLS.md,schema.json}` 与 `custom-director/shared/agent_tools.lua` 当输出路径写死（`tools/agent_tools.py:30`、`tools/agent_schema.py:29`）。移到 `tools/agent/` 的唯一收益是目录好看，代价是全链路改动 |
| `T-CityLite.base/docs/agent/`（23 篇 md + `schema.json`） | 24 | 生成物落点（同上）+ 契约测试读取点（`tests/agent/test_agent_contract_parity.py:30` 读 `ACTIONS.md`）+ `reviews/01..08` 是历史评审快照，改写其内部路径=篡改记录 |
| `T-CityLite.base/tests/agent/` | 18 | 同上；`lua/runner.lua` 是 `AGENTS.md:185` 登记的唯一 Lua 入口，9 个 suite 的 case 文件名被 `design/05` 与 `reviews/02` 逐条引用 |
| `T-CityLite.base/tests/check_*.py`、`run_all.py`、`conftest.py` | 8 | `BASE_DIR = dirname(dirname(__file__))` 写死层级，`conftest.py` 是 pytest fixture 源；CI 4 个 job 直连这些路径。**搬它们只有坏处** |
| `T-CityLite.base/resources/[standalone]/core-framework` | 1 | 27 行引用 / 8 个文件 + `CODEOWNERS:7`；虽属"自研放错类"，但它是启动链核心，单独评估 |
| `.hermes/plans/`、`CLAUDE.md`、`REASONIX.md`、`SECURITY.md` | 4 | 外部工具（Hermes/Claude/Reasonix）的约定文件，移动会让工具找不到；0 内部引用 |

---

## 7. 预估工作量

| 阶段 | 移动/删除（路径） | 新增（文件） | 编辑（文件） | 合计触碰（文件） |
|:---|:---:|:---:|:---:|:---:|
| Phase 1 | 0 | 6 | 1（`AGENTS.md`） | **7** |
| Phase 2（M1/M2/M3/M4/M5/M6/M9） | 31 | 0 | 11 | **~42** |
| Phase 3（M7/M8 + 历史簇） | 62 | 0 | ~30 | **~92** |
| 合计（不含可选历史簇） | 93 | 6 | 42 | **~141** |

> 引用总量参考：`tests/agent` 139 行、`tools/` 280 行、`[standalone]/` 路径 36 行、40 篇 base 文档的外部引用约 45 行。

---

## 附录 A：本次使用的 `git grep` 命令（可复现）

```bash
# 两棵 tests/agent
git grep -n 'tests/agent' -- . ':!T-CityLite.base/resources' | wc -l          # 139
git grep -l 'tests/agent' -- . ':!T-CityLite.base/resources' | wc -l          # 43

# 文档双根
git grep -c 'docs/agent' -- . ':!T-CityLite.base/resources'
git grep -n -E '00_SERVER_MASTER_MANUAL|01_resource_inventory|02_script_index|03_maintenance_manuals|04_call_reference' -- . ':!T-CityLite.base/resources'

# tools/
git grep -o -E '(\.\./)*tools/[A-Za-z_0-9./-]+' -- . ':!T-CityLite.base/resources' ':!tools/*' | wc -l   # 280

# 资源分类
git grep -n -F '[standalone]/' -- 'T-CityLite.base/resources' | grep -vE '\.(json|md)$'   # 仅 1 条注释
git grep -n -F '[standalone]/custom' -- . ':!T-CityLite.base/resources' ':!fxmanifest_inventory.json'
grep -rhoP '^\s*ensure\s+\K\S+' T-CityLite.base/configs/modules/*.cfg | sort | wc -l      # 82

# 0 引用的游离文件
git grep -n 'store-robbery-redesign\|refactor-escape-sqli' -- . ':!T-CityLite.base/resources'   # 仅自身
git grep -n '中东翻版' -- . ':!T-CityLite.base/resources'                                        # 仅自身

# 根目录产物
git log --oneline --follow -- admins.json                                    # 1e39c45
git check-ignore -v admins.json default/config.json                           # 均未命中 → 未忽略
```

---

## 8. 结论（最后 5 行）

1. **最值得做的 3 个搬迁**：① `docs/agent/phone/` → `T-CityLite.base/docs/agent/phone/`（3 文件，一次性修掉 AGENTS.md 的 8 处歧义）；② 根 `tests/agent/` → `tests/tools/`（8 文件，消灭同名双目录，CI 只改 1 行）；③ `[standalone]` 里 8 个自研资源 → `[custom]/`（8 目录，cfg 零改动、`.lua` 零引用）。
2. **最不该动的 2 个**：① `[qb]/` 57 个第三方资源（上游 diff + CODEOWNERS）；② `tools/agent_*.py` + `agent_tools.json`（280 行引用、8 个 pytest 的 `sys.path`、生成物路径写死）。
3. **Phase 1 范围**：只建 8 个空目录 + 新增 6 个索引/说明文件（根 `README.md`、`docs/README.md`、`T-CityLite.base/docs/README.md`、`tests/README.md`、`T-CityLite.base/tests/agent/README.md`、本提案），并把 `AGENTS.md` 的 8 处 agent 文档路径补成完整路径 —— **零移动、零 CI 改动**。
4. **预估改动文件数**：Phase 1 ≈ 7；Phase 2（推荐 7 项）≈ 42；Phase 3 ≈ 92；全量约 141 个文件（移动/删除 93 个路径 + 新增 6 + 编辑 42）。
5. **是否需要改 CI**：**只需 1 行**——若执行 M2，把 `.github/workflows/ci.yml:67` 的 `../tests/agent` 改成 `../tests/tools`；其余迁移均不触碰 CI。附带建议在 Phase 3 结束后把 `docs-check` 从 advisory 改为阻断，否则链接腐烂仍不可见。
