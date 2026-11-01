---
id: police-readme
type: meta
status: active
system: justice
owner: hermes
updated: 2026-10-24
review_by: 2027-04-30
---

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
| `P4_AGENT.md` | P4 证据链的 agent 侧接法 |
| `plans/` | 阶段施工单（P2 调度、P3 盘查、P4 证据、P6 agent、备份 NPC、UI 重构）；逐份见下方「plans/ 索引」 |

结论：`custom-police` 是唯一服务端权威，MDT 是 `custom-phone` 的 `police_mdt` App；
`qb-policejob` 保留现场动作层。已落地 P0–P5、SM-01/02/03/05 状态机、NPC 支援/警情、13 条 fitness 规则、真实 E2E 与 Agent Ops。

## plans/ 索引

| 施工单 | 内容 |
|---|---|
| `plans/2026-10-29-backup-v2.md` | NPC 支援 v2：分层调度与到场 |
| `plans/2026-10-29-backup-spawn-v3.md` | NPC 支援 v3：生成点与脱困 |
| `plans/2026-10-31-cc-brief-minimap-dashboard.md` | 车机小地图与 dashboard 简报 |
| `plans/2026-10-31-log-cleanup.md` | 日志清理与降噪 |
| `plans/2026-10-31-map-key-quest.md` | 地图键位与任务联动 |
| `plans/2026-10-31-p6-4-ai-dispatcher.md` | P6.4 AI 调度员 |
| `plans/2026-10-31-quest-storyengine-and-sonar.md` | 任务叙事引擎与声呐 |
| `plans/2026-11-01-decision-ui-refactor.md` | 决策 UI 重构 |

每个 `-audit` 后缀的文件是同阶段的完成后审计（`final`，写完即冻结）。
