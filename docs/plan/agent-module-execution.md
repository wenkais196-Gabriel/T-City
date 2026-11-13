---
id: agent-module-execution-plan
type: plan
status: draft
system: agent
owner: hermes
updated: 2026-11-13
review_by: 2027-02-28
tracks: [custom-director, agent-tools, agent-runtime]
topic: agent-module-execution
source_of_truth: false
---

# Agent 模块化施工计划（M1–M7）

> **一句话**：把 `agent-control-plane-upgrade.md` 的 15 个工作项收敛成 7 个**可独立验收、可独立回滚**的模块，
> 按 M1→M6 串行推进（#233 检索作为并行轨道）。每个模块结束都必须能拿出一条可判定的数字或一次可复现的演示。
> **本文不改上游的范围判断**，只回答三件事：先做什么、每个模块改哪里、怎么算做完。

---

## 0. 事实基线（2026-11-13 实测，不引用二手数字）

| 项 | 实测值 | 怎么测的 |
|---|---|---|
| `tests/tools` | **239 passed / 3 skipped / 716 subtests**（4.6s） | `pytest tests/tools -q`（Python 3.12） |
| registry | 45 tools，全 active；22 需审批；25 声明 verify；L0×20 / L1×3 / L2×8 / L3×9 / L4×5 | 读 `tools/agent_tools.json` 计数 |
| `agent_actions` 列 | 14 列，**无** `run_id` / `trace_id` / token / cost | `migrations/v2.3_agent_actions.sql` |
| `agent_denials` 列 | 只有 Normalize / CheckPolicy / 审批复核失败落库，**前置拒绝不入库** | `migrations/v2.5_agent_denials.sql` |
| 审批身份 | `approver` 来自**请求体自由文本**，admin token 只证明"是管理员"，不证明"是谁" | `server/http_api.lua:204`、`policy.NormalizeApprover` |
| 动态风险信号 | 只有 `add_money` 的日预算（`daily_spent`）；无频率/连续拒绝/金额异常 | `server/policy.lua:1669-1673` |
| trace | 全仓无 `traceparent` / `gen_ai.*` / span | grep 命中 0 |
| 运行环境 | `tcity-mariadb` Up、FXServer `:30130` 200 | `docker ps` / `players.json` |

> `T-CityLite.base/docs/agent/STATUS.md` 记的是 `227 passed`，实测 239 —— 该文件在 M1 顺带修正。

---

## 1. 顺序决策

两轮独立判断（本文 + Claude Code 只读复盘），结论一致：**不采纳上游文档的 W4→W3v1→W2→W3v2→W1 顺序**，但也不推翻它的优先级。

| 争议点 | 上游文档 | 本计划 | 技术理由 |
|---|---|---|---|
| W4 动态风险是否第一 | 是，投资最小差异化最大 | **第 5 位** | 验收口径「误拒率 ≤2%」需要有「本应放行」的标注集作分母，而标注集只能由 golden 提供；先做等于无法验收 |
| W3v1 能否跑在审计回放上 | 能，且不依赖 W2 | **不能** | `agent_actions` 无 `run_id`，前置拒绝不入库 → 多步 episode 串不起来，风控拒绝也测不到 |
| runtime 排第几 | 周 5–6 | **第 3 位** | 它是「loop 在哪」的唯一答案，但 golden v1 只覆盖动作面、不需要 loop；推迟到周 5 风险过高 |
| trace | 最后 | 最后（同意） | semconv 仍在 Development；且没有 run_id 时 span 无法按会话归并 |

**最终顺序**：`M1 血缘 → M2 golden v1 → M3 runtime → M4 golden v2 → M5 动态风险 → M6 trace`；M7 有余力再做；#233 检索并行。

---

## 2. 模块表

| 模块 | 目标（一句话） | 主要改动面 | 验收门（可判定） | 投入 | Issue |
|---|---|---|---|---|---|
| **M1 运行血缘** | 任何一次工具调用都能归属到一次 run | 新迁移 v3.16（新表 `agent_runs` + `agent_actions.run_id`）、`resources/[custom]/custom-director/server/main.lua`（Propose/Approve/Execute 写入）、`resources/[custom]/custom-director/server/policy.lua`（4 类前置拒绝落库）、`tools/agent_mcp.py`（`X-Run-Id` 透传）、`tools/agent_contract.py`、`tools/agent_data.py`（视图）、`tests/architecture/table_owners.json` | `pytest tests/tools -q` 全绿且新增 ≥8 用例；迁移 up/down 各跑一次幂等；真机 45 工具冒烟后 `SELECT COUNT(*) FROM agent_actions WHERE run_id IS NULL` = 0；4 类拒绝各入库 1 行 | 20h | #236（前置）+ W8 |
| **M2 golden v1** | 50 条人工 episode，CI 下降 >5% 即红 | 新增 tools/agent_golden.py（replay 器，fake HTTP / fake DB）、tests/tools/golden/episodes 下的 episode 文件、同目录 baseline.json、`.github/workflows/ci.yml` | golden 套件 50 passed / <60s；把一条策略改坏后 CI **exit 1**（留一次红的日志）；基线 diff 打印 pass rate | 24h | #237 |
| **M3 runtime** | 能跑「plan → 调工具 → 观察 → 再决定」的循环，且在人审处真的挂起 | 新增 tools/agent_runtime.py、tools/agent_llm.py（可插拔，FakeLLM 供离线测试）、tests/tools 下 test_agent_runtime.py 与 test_approval_resume.py | 离线：脚本化 transcript 回放 10 条用例全绿；审批中断后恢复 10/10；循环上限/预算超限有确定性失败码；`--dry-run` 只读不写 | 30h | #236 |
| **M4 golden v2** | episode 覆盖 loop 行为 + judge 校准 | 同上目录，新增 loop episodes 与 judge 标注文件（30–50 条专家标注） | loop episodes ≥15 条；judge 报 per-class P/R；基线回归门禁同样生效 | 16h | #237 |
| **M5 动态风险** | 确定性动态信号叠加进策略，先 shadow 后拦截 | 新增 resources/[custom]/custom-director/server 下的 policy_signals.lua（纯函数，无 FiveM 依赖）、policy.lua 调用点、`agent_risk_scores` 表、convar `agent_risk_shadow`（默认 1）、`tests/agent/lua/` 扩到 ≥280 checks、新增 tools/dev 下的 shadow 报表脚本 | 5 个信号各有单测 + 反向校验；shadow ≥7 天误拒率 ≤2%；开启拦截后 `agent_denials` 新增信号类 code 有据可查；architecture 测试断言 policy 模块无网络/无 LLM 依赖 | 40h（含 7 天观察） | #238 |
| **M6 trace** | 工具调用产出 OTel GenAI span，可按 run 串起来 | 新增 tools/agent_telemetry.py（手写 OTLP/JSON，零新依赖）、`tools/agent_mcp.py` 埋点、registry `_meta.semconv_version`、新增 span 属性测试 | 45/45 工具 span 含 `gen_ai.operation.name` / `gen_ai.tool.name` / `gen_ai.tool.call.id`；同一次 run 的 span 共享 trace_id；semconv 版本被测试锁定 | 24h | #235 |
| **M7 治理增强**（可裁） | 审批身份可验证 + verify 2.0 | `http_api.lua`（approver 取自 token claim）、`main.lua`（超时升级）、registry `verify` 描述、`tests/architecture/*` | 请求体自带 approver → 403；900s 超时进入二级审批；25 个 verify 中 ≥10 个比较真实状态且各配 1 个负例 | 24h | #239 #240 |
| **P 并行轨道：检索** | 语料可检索（BM25+dense+RRF） | 见 #233 立项文档 | recall@k / MRR / nDCG 有基线数字 | — | #233 |

---

## 3. 8 周日历（按每周 20h 有效投入）

| 周 | 主线 | 周末可演示 | 并行 |
|---|---|---|---|
| W1 | M1 迁移 + Lua 写入 + Python 接线 | `DESCRIBE agent_runs`；一条 SQL 拉出单次调用的完整血缘 | — |
| W2 | M1 收尾（4 类拒绝、闸门、STATUS 修正）+ M2 骨架 | 4 类拒绝各 1 行；1 条 episode 回放 pass | — |
| W3 | M2 补到 50 条 + baseline + CI 门禁 | `pytest tests/tools/golden -q` → 50 passed；故意改坏策略 CI 变红 | — |
| W4 | M3 loop v1（FakeLLM、工具派发、上限） | 离线跑完一条 5 步任务，输出逐步 trace | #233 调研 |
| W5 | M3 审批挂起/恢复 + run ledger 写盘 + CLI | 一次真实 run：L2 动作挂起 → 审批 → 恢复执行 | — |
| W6 | M4 loop episodes 扩充 + judge 校准 | judge per-class P/R 表 | — |
| W7 | M5 信号实现 + shadow 开启 | shadow 表出现真实评分，线上拦截计数 = 0 | #233 实现 |
| W8 | M5 shadow 复盘 + M6 trace | 误拒率报表；45/45 span 检查通过 | — |

余力顺序：M7 → #233 → backlog（W7 限流落实 / W9 身份作用域 / W10 上下文预算 / W11 trace 回放）。

---

## 4. 回滚方式

| 模块 | 代码 | 数据 | 运行时 |
|---|---|---|---|
| M1 | `git revert`；所有读路径对 `run_id IS NULL` 兼容 | 每个迁移配 `down`（DROP COLUMN / DROP TABLE），先备份 `agent_actions` | convar `agent_run_ledger=0` 退化为不写 run_id |
| M2/M4 | 纯离线工具，删文件即回滚；CI 门禁加 `continue-on-error` 一天 | 无 | 不涉及服务器 |
| M3 | 纯离线 CLI，默认 `--dry-run` | 只写 `agent_runs`，可整表清空 | 不涉及服务器 |
| M5 | `agent_risk_shadow=1` 恒不拦截；`policy_signals.lua` 可整体摘除 | `agent_risk_scores` 可 DROP | `restart custom-director` |
| M6 | span 只落文件，不阻塞调用；`agent_trace=0` 关闭 | 文件级 | 无 |

---

## 5. 分工（Hermes / Claude Code）

| 角色 | 负责 |
|---|---|
| Hermes（主） | 迁移与 Lua 侧改动、闸门与 allowlist、真机验证、文档与 CHANGELOG、PR |
| Claude Code | 单点、可离线判定的子任务：episode 生成与回放器、judge 校准脚本、span 属性测试、只读代码盘点。每次给固定文件清单 + 行数预算，产出走 diff 评审 |
| 人 | 顺序与范围拍板、L4 类判断（表结构/鉴权）、真机审批演示 |

---

## 6. 风险

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| M1 改生产表导致线上动作丢失 | 中 | 高 | 迁移只加列不加约束；先备份；`run_id` 可空；灰度一个资源 `restart` 验证 |
| M2 episode 写得太像实现（复制实现逻辑） | 高 | 中 | episode 只写「输入 + 期望决策 + 期望终态」，不写调用细节；反向校验必带 |
| M3 用真 LLM 做测试导致不确定 | 高 | 中 | 测试一律 `FakeLLM`；真模型只做手动冒烟，结果不入 CI |
| M5 shadow 期间误拒真实运营动作 | 中 | 高 | shadow 只记不拦；上线前 ≥7 天；阈值调整留记录 |
| 时间被课程/实习切碎 | 中 | 中 | 每个模块可在一个周末独立收口；周历表允许整体后移，不允许跳序 |

---

## 7. 施工纪律（沿用仓库既有规则）

- 每个模块一个分支 `feat/agent-m<N>-<slug>`，从 `origin/master` 切；合并前停服。
- 新增表必须在 `tests/architecture/table_owners.json` 登记 owner（`custom-director`），否则 architecture 闸门红。
- 新 net event 一律登记 `net_events_allowlist.json`；M1–M6 预期**不新增 net event**（run_id 走 HTTP header）。
- 每个模块交付三件套：代码 + 文档（`T-CityLite.base/docs/agent/`）+ `CHANGELOG.md`；push 前 `tools/dev/release_check.py`。
- 先红后绿：每个模块的第一条 commit 必须是会失败的用例。

---

## 8. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-11-13 | 初版：合并 Hermes 盘点与 Claude Code 第二意见，确立 7 模块与 8 周顺序 |
