---
id: plan-readme
type: meta
status: active
system: meta
owner: hermes
updated: 2026-11-16
review_by: 2027-05-31
---

# docs/plan/ — 计划与路线图索引

> 本目录放**「什么时候做什么」**：版本路线图、阶段计划、分批施工清单。
> 状态以各文件 frontmatter 的 `status` 为准，本页只做导航（不重复内容）。
> 判断「一份新计划该放哪」见 `docs/engineering/TREE.md` §2。

| 计划 | 主题 | 状态 |
|---|---|---|
| [agent-control-plane-upgrade.md](./agent-control-plane-upgrade.md) | Agent 控制平面升级 | 见文件 |
| [agent-module-execution.md](./agent-module-execution.md) | Agent 模块化执行顺序与依赖 | 见文件 |
| [automated-testing-plan.md](./automated-testing-plan.md) | 自动化测试体系建设（M8b 从 `T-CityLite.base/docs/` 归入） | `active` |
| [jobs-content-roadmap.md](./jobs-content-roadmap.md) | 职业内容填充总规划（R0–R6，含硬约束） | `draft` |

## 子目录

| 目录 | 内容 | 入口 |
|---|---|---|
| `jobs-content/` | 内容填充的调研 / 设计 / 执行清单 / 数值 / 验收（01–14 + hotdog 系列） | [jobs-content-roadmap.md](./jobs-content-roadmap.md) → [03-plan.md](./jobs-content/03-plan.md) |

## 相关但不在本目录

| 内容 | 位置 |
|---|---|
| 版本与任务进度看板 | [`PROJECT_PROGRESS.md`](../../PROJECT_PROGRESS.md) |
| 基石加固阶段计划（P0/P1/P2）与出口判据 | [`docs/engineering/2026-11-foundation-plan.md`](../engineering/2026-11-foundation-plan.md) |
| 历史版本规格（v0.1–v1.0，只读） | [`docs/archive/QBCore_Lite_versions/`](../archive/QBCore_Lite_versions/) |
