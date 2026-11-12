---
id: agent-control-plane-upgrade-plan
type: plan
status: active
system: agent
owner: hermes
updated: 2026-11-12
review_by: 2027-03-31
tracks: [custom-director, custom-agent-client, agent-tools]
topic: agent-control-plane-upgrade
source_of_truth: true
---

# Agent 控制平面升级计划

> **一句话**：把仓库从「生产级工具面 + 控制平面」推进到「可观测、可控、可回归」的完整 Agent 系统。
> **Issue**：Epic #234 ｜ 执行项 #235–#240 ｜ 检索专题 #233
> **盘点基线**：master `86b9993`（2026-11-12），静态代码分析，未复跑测试。
> **定位**：本仓是企业级 Agent 控制平面的一个**真实部署案例**，FiveM 是宿主环境而非主题。

---

## 0. 这份文档怎么来的

两轮**独立**分析，合并定稿：

| 来源 | 方法 | 产出 |
|---|---|---|
| A（主会话） | 基于仓库结构与 5 篇业界标准原文 | 6 项主攻判断 + 5 个调研锚点 |
| B（Claude Code，274 行） | 逐文件静态盘点（带行号）+ 联网调研 | 15 项能力判定 + 15 个工作项 |

**合并原则**：事实以 B 的可复现行号为准；取舍以 A 的交付约束（4 周可见成果）为准。下文 §0.1 / §0.2 记录一致点与修正点，后续开发以**修正后**版本为准。

### 0.1 两轮一致（可直接采信）

- 检索（RAG）是唯一**完全缺失**的能力类 → 已由 #233 立项，本计划不重复
- 评测（golden set + 回归门禁）是投入产出比最高的一块
- 风险分级必须补动态信号，但**不能用 LLM 做分类器**
- OTel GenAI trace 是最具「标准对齐」价值的可观测性动作

### 0.2 被修正的判断（重点）

| # | 原判断 | 修正后 | 依据 |
|---|---|---|---|
| M1 | `tools/agent_harness.py` 是 agent 循环 | **它是 FXServer/客户端控制台的只读日志观察层**（observe/wait/status，354 行）。全仓无 LLM SDK、无 prompt、无 agent loop，循环在外部 MCP 客户端 | 静态 grep `anthropic\|openai\|chat/completions` 仅命中密钥扫描正则 |
| M2 | 成本计量可单独立项 | **并入 runtime**（run ledger）。没有 run 维度，token 数无法归属到任务 | 无 run 概念时 cost 是孤儿指标 |
| M3 | 4 周可完成核心工作项 | 按每周 20h 有效投入，实为 **8 周**。原估是按全职、熟悉仓库的工程师口径 | 学生口径 ≠ 全职口径 |
| M4 | 自建 runtime 疑似重复造轮子 | **是唯一能演示「执行前挂起等人批」的载体**。现成框架的 tool-calling 无审批中断语义，必须在 README 写明选择理由 | L1–L4 闸门需嵌在 loop 内部 |

---

## 1. 定位修正（开发前必读）

当前形态是「**生产级工具面 + 控制平面**」，不是「一个 Agent 系统」。这不是缺陷，是尚未补齐的一层：工具面、权限、审计、人审闸门都已生产级，缺的是运行这一层的 orchestrator。

对外表述必须精确：**「工具面 + 控制平面已生产级，运行时是本计划的 P0 补齐项」**。若宣称「完整 Agent 系统」，被追问 loop 在哪会立刻失分。

---

## 2. 现状盘点（15 项）

| 能力项 | 判定 | 关键证据 |
|---|---|---|
| 工具注册与契约 | 充分 | registry 1.9.0，45 active，`agent_tools.py --check` 三面一致（FIT-08） |
| 错误处理与重试 | 充分 | 读 3 次/写 2 次；`write_outcome_unknown` 明确「结果未知勿重试」；jitter 退避；5 次/30s 熔断 |
| 幂等 | 充分 | 全局 UNIQUE + 409 + dry-run 占键，契约/实现/测试一致 |
| 权限分层 | 部分 | 三 token + `agent_ro` 只读正确；但单 `AGENT_AGENT_ID`、无 per-tool scope |
| 人审闸门 | 部分 | 22/45 需审批、L3/L4 恒 `pending_approval`、TTL 900s；无动态信号、无升级、审批人是自由文本 |
| 执行后回读 | 部分 | 25/25 声明 verify，但 18 个只断言 `get_action.status==executed`（自证），仅 2 个比较真实状态 |
| 审计留痕 | 部分 | 无正文/无参数值（隐私设计优秀）；但 `agent_actions` 无 trace_id，前置拒绝不入库 |
| 评测指标 | 部分 | 7 个 rate + p50/p90/p95 + 幂等；无 golden set、无回归门禁、无 judge |
| 可观测性/trace | 缺失 | 全仓无 `traceparent`/span，只有一行 stderr JSON |
| 检索能力 | 缺失 | 45 工具 0 个检索类；语料 300 份 md / 72,043 行 → 见 #233 |
| 上下文管理 | 缺失 | 工具 schema 实测 25,657 字符 ≈ 6.4k tokens，只有 read/all 两档 |
| 成本计量 | 缺失 | 无 token/cost 列 |
| 多 Agent 编排 | 缺失 | 无 supervisor/handoff |
| 不可信内容隔离 | 部分 | 16 个读工具标注 `untrusted_fields` 且有清洗测试；无 LLM 在环的对抗验证 |
| 部署与运维 | 部分 | gateway/director 无进程守护，手工起 |

---

## 3. 业界标准与差距

| 标准 | 要求 | 本仓现状 | 结论 |
|---|---|---|---|
| **风险分级** | 静态基线 + 动态信号（频率、金额异常、连续拒绝、漂移）；信号只升不降；超时默认拒绝 + 升级路径。**分类器不能用 LLM**（概率性，可被对抗内容诱导降级） | `policy.lua` 已是确定性规则（**做对了**），但无任何动态信号 | 补 W4 + W5 |
| **可观测性** | `execute_tool {gen_ai.tool.name}` span，必填 `gen_ai.operation.name` / `gen_ai.tool.call.id`；semconv 仍是 Development，须固定版本 | 仅 stderr 单行 | 补 W1 |
| **评测** | CI 用 20–50 条人工 golden，下降 >5% 阻断；judge 需 30–50 条专家标注校准，报 per-class P/R | 仅审计 rate + 单阈值 | 补 W3 |
| **检索** | 标识符密集语料纯 dense 会漏，须 BM25+dense+RRF(k=60)+rerank；评测用 recall@k/MRR/nDCG | 无检索层 | 已在 #233 |
| **MCP 安全** | 工具定义哈希固定（防 rug-pull）、per-agent scope、禁 token passthrough | 有静态 registry + `--check`；无 scope，`X-Agent-Id` 可自报 | W9（backlog） |

**权威出处**（2026-11 核验）：
- AWS Agentic AI Lens `AGENTSEC04-BP02`（risk-tiered approval）— https://docs.aws.amazon.com/wellarchitected/latest/agentic-ai-lens/agentsec04-bp02.html
- Microsoft Agent Governance ADR-0004（policy 评估必须确定性）— https://microsoft.github.io/agent-governance-toolkit/adr/0004-keep-policy-evaluation-deterministic/
- OpenTelemetry GenAI spans — https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/
- MCP Security Best Practices — https://modelcontextprotocol.io/docs/2025-11-25/tutorials/security/security_best_practices

---

## 4. 工作项 ↔ Issue 映射

| # | 工作项 | 优先级 | 工期 | Issue |
|---|---|---|---|---|
| W1 | OTel GenAI trace 标准化 | P0 | 4d | #235 |
| W2 | Agent 循环 + run ledger（token/cost） | P0 | 5d | #236 |
| W3 | 50 条 golden episode + CI 回归门禁 | P0 | 5d | #237 |
| W4 | 动态风险信号与熔断器 | P0 | 6d | #238 |
| W5 | 审批身份可验证 + 超时升级 + 双人复核 | P1 | 4d | #239 |
| W6 | verify 2.0：可度量的后置条件回读 | P1 | 4d | #240 |
| W7 | registry 声明的限流真正生效（32 个未生效） | P1 | 3d | backlog |
| W8 | 补齐前置拒绝审计（4 类） | P2 | 2d | backlog |
| W9 | Agent 身份与工具作用域 | P1 | 4d | backlog |
| W10 | 工具面渐进披露与上下文预算 | P2 | 3d | backlog |
| W11 | Trace 回放与事故时间线 | P1 | 3d | backlog |
| W12 | 多 Agent 监督者与交接契约 | P2 | 5d | backlog |
| W13 | 一键可复现演示栈 | P2 | 3d | backlog |
| W14 | 提示注入对抗测试集 | P2 | 3d | backlog |
| W15 | 补齐 Bank/Garage/Contacts 页状态 | P2 | 3d | backlog |

**backlog 项不单独立 issue**，避免开出无人认领的条目；开工时再从本表提升为 issue。

---

## 5. 排期（8 周口径）

```text
周 1–3   W4 动态风险信号（含 ≥1 周 shadow mode，误拒率 >2% 即调阈值）
周 4     W3 v1 —— golden 跑在审计回放上，不等 W2
周 5–6   W2 runtime + ledger
周 7     W3 v2 —— 接 runtime，加 judge 校准
周 8     W1 trace 标准化
```

W5 / W6 有余力再做。

**排序理由**
- W4 第一：本仓已有确定性策略引擎，补动态信号是**投入最小、差异化最大**的一步；且业界刚明确「风险分类不能用 LLM」，本项目恰好做对了，有权威出处可引用。
- W3 第二：最容易被面试验证的部分（「给我看你的数字」），且 v1 不依赖 W2，可解耦。
- W1 最后：可观测性价值高，但能用现有日志近似先用着。

---

## 6. 决策记录（明确不做）

| 不做 | 理由 |
|---|---|
| 多 Agent（W12） | 4 周内产不出可复现数字，易被当作 demo |
| 容器化（W13） | 除非需对外公开演示，否则收益低于成本 |
| 重复立项检索 | #233 已覆盖；本计划只要求其验收补 recall@k / MRR / nDCG |
| 用 LLM 做风险分类 | 违反确定性要求；`policy.lua` 保持纯规则 |

---

## 7. 验证与口径

- 全部盘点为**静态代码分析**，未独立复跑测试；「620+ 用例」来自 `STATUS.md` 与测试文件静态统计，引用前须实跑一次
- 业界结论来自公开文档；semconv 属性名随版本变动（`gen_ai.tool.call_id` → `gen_ai.tool.call.id`），W1 必须固定版本并写入 registry `_meta`
- 工期按 1 名熟悉仓库的工程师全职估算；实际投入按每周 20h 折算
- 动态风险规则上线前必须 shadow mode 观察 ≥1 周，否则可能把正常运营动作打成 429/拒绝
- W6 施工前须逐个动作核对 Lua 执行器，避免把「声明弱」误判成「实现错」

---

## 8. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-11-12 | 初版：合并两轮独立分析，建立 15 项工作项与 issue 映射 |
