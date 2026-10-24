# 警察扮演（Police Roleplay）

| 文档 | 内容 |
|---|---|
| `research-external.md` | 外部模组调研（ps-mdt / ps-dispatch / wasabi_mdt / rcore / ESX 对照） |
| `audit-current.md` | 本地警察栈现状与能力矩阵 |
| `DESIGN.md` | 一体化设计（目标态） |
| `STATUS.md` | 已交付内容、验证命令、未完成项 |
| `TECH_DEBT.md` | 架构债登记 |
| `architecture/` | as-built 架构基线：上下文/领域/状态机/契约/数据归属/NFR/fitness/场景/ADR |
| `E2E_TESTING.md` | 真实服务端 E2E + MDT 浏览器测试怎么跑 |
| `AGENT_OPS.md` | `/agent status/events/health/test` 与 `run_police_e2e` |
| `AGENT_CONTROL_RESEARCH.md` | agent 接管服务器与自动化测试的边界调研 |
| `LIVE_TEST_NOTES.md` | 进服测试问题记录与修复状态 |
| `FLOW_RESEARCH.md` / `FLOW_INTERNAL.md` / `B_PLAN.md` | 流程调研、内部断点、方案 B |

结论：`custom-police` 是唯一服务端权威，MDT 是 `custom-phone` 的 `police_mdt` App；
`qb-policejob` 保留现场动作层。已落地 P0–P5、SM-01/02/03/05 状态机、NPC 支援/警情、13 条 fitness 规则、真实 E2E 与 Agent Ops。
