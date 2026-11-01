---
id: docs-home
type: meta
status: active
system: meta
owner: hermes
updated: 2026-10-31
review_by: 2027-04-30
tracks: [docs/INDEX.md]
topic: docs-home
source_of_truth: true
---

# T-City 文档总入口

> 3 分钟读完。**找文档去 [`INDEX.md`](INDEX.md)（自动生成），找方向留在本页。**

## 三条阅读路径

| 目的 | 读这条 |
|---|---|
| **新会话 / 新 agent 接手** | [`../AGENTS.md`](../AGENTS.md) → [`../T-CityLite.base/docs/agent/STATUS.md`](../T-CityLite.base/docs/agent/STATUS.md) → [`INDEX.md`](INDEX.md) |
| **要改某个系统** | [`INDEX.md`](INDEX.md) 找该系统 → `spec`（做什么）→ `manual`（现状）→ frontmatter 的 `tracks` 指向代码 |
| **要知道还缺什么** | [`analysis/2026-10-31-systems-coverage-survey.md`](analysis/2026-10-31-systems-coverage-survey.md)（缺口）→ [`../PROJECT_PROGRESS.md`](../PROJECT_PROGRESS.md)（排期） |

## 当前版本入口（≤5 条，其余进 INDEX）

| 文档 | 说明 |
|---|---|
| [`analysis/2026-10-31-systems-coverage-survey.md`](analysis/2026-10-31-systems-coverage-survey.md) | 全服 17 系统覆盖与规划缺口（含外部调研） |
| [`agent/police/BLUEPRINT.md`](agent/police/BLUEPRINT.md) | 警察模块施工图（设计定稿，未实现） |
| [`agent/phone/DESIGN.md`](agent/phone/DESIGN.md) | 手机系统设计 |
| [`../T-CityLite.base/docs/agent/STATUS.md`](../T-CityLite.base/docs/agent/STATUS.md) | Agent 接管栈实现状态 |
| [`standards/doc-lifecycle.md`](standards/doc-lifecycle.md) | 文档规则本身 |

## 目录约定

| 目录 | 放什么 |
|---|---|
| `standards/` | 规范（meta） |
| `spec/<system>/` | 施工图：要做什么、怎么验收 |
| `manual/<system>/` | 手册：描述现在是什么（90 天复审） |
| `adr/` | 决策记录（只增不改） |
| `plan/` | 版本路线与阶段计划 |
| `audit/` | 审计/验收快照（final 后冻结） |
| `research/` | 调研结论（会过期，180 天复审） |
| `runbook/` | 运维与应急 |
| `archive/` | 已归档，只读 |
| `analysis/`、`server-design/`、`agent/` | **存量区**：按 Phase 2/3 逐步迁入上面的结构 |

工具：`python tools/docs_lifecycle.py --report|--index|--check`。规则全文见 [`standards/doc-lifecycle.md`](standards/doc-lifecycle.md)。
