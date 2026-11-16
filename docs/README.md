---
id: readme-2
type: meta
status: active
system: meta
owner: hermes
updated: 2026-11-16
review_by: 2027-04-30
---

# docs/ — 项目级文档

服务器/资源内部技术文档在 [`T-CityLite.base/docs/`](../T-CityLite.base/docs/README.md)。

| 目录 | 内容 |
|---|---|
| `engineering/` | **Agent 运行模型**：宪法（10 条不变量）、四平面架构、五阶段模板、工作树与环境表（§0 是唯一写盘符的地方） |
| `plan/` | 版本与阶段计划（如 `jobs-content/`） |
| `police/` | 警察模块：蓝图、架构 fitness 报告、验收 |
| `client/` | 客户端/手机：`PHONE_ARCHITECTURE.md`、UX 模块、排查 playbook、设计研究 |
| `agent/` | agent 栈设计（警察 BLUEPRINT、phone、评审）；资源级 agent 文档在 `T-CityLite.base/docs/agent/` |
| `server-design/` | 服务端系统设计（经济、世界痕迹、付费模型等） |
| `analysis/` | 分析报告（系统覆盖与缺口） |
| `standards/` | 编码/维护规范（含文档生命周期） |
| `ops/` | 运维手册 |
| `cleanup/` | 2026-10 仓库整理三份审计与 PLAN |
| `archive/` | 历史设计稿与归档资料（**只读快照**，路径不回溯改写） |
| `07_narrative/middle-east-narrative-design.md` | 剧情节点的叙事设计全案（中东翻版剧情线） |
| `reasonix-hooks-config.md` | Reasonix（编辑器/agent 钩子）配置说明 |
| `01_module_manuals/` `02_script_index/` `03_maintenance_manuals/` `04_call_reference/` | 资源手册与索引（v0.x 时代产物，多数已 `archived`，现状以代码为准） |

`docs/` 之外的常用入口：`T-CityLite.base/docs/audit/`（全局审查与三阶段计划）、`T-CityLite.base/docs/agent/STATUS.md`（agent 栈现状）、`../PROJECT_PROGRESS.md`（版本与任务进度）。

Agent 文档（状态/动作/工具/评测/评审/手机设计）已统一在 `T-CityLite.base/docs/agent/`。

入口建议：[`AGENTS.md`](../AGENTS.md) → [`STATUS.md`](../T-CityLite.base/docs/agent/STATUS.md)。
