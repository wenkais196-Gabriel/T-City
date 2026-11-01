---
id: readme
type: meta
status: active
system: meta
owner: hermes
updated: 2026-10-26
review_by: 2027-04-30
---

# T-City Lite

QBCore / FiveM RP 服务器（"T-City Lite"），包含一套服务端权威的 **LLM agent 接管栈**与自研手机。

- 服务器主体：[`T-CityLite.base/`](T-CityLite.base/README.md)
- Agent 接入层：`T-CityLite.base/resources/[custom]/custom-director`、`custom-agent-client`，工具在 [`tools/`](tools/)
- 自研手机：[`custom-phone`](T-CityLite.base/resources/[custom]/custom-phone/PHONE_API_TECHNICAL_MANUAL.md)
- 新会话入口：[`AGENTS.md`](AGENTS.md)（开发标准、目录索引、常见坑、路线图）
- 当前状态：[`docs/agent/STATUS.md`](T-CityLite.base/docs/agent/STATUS.md)

## 快速开始

```bash
# 本机运行需要 alpine/ 运行时与 server.cfg（均不入库）
cp T-CityLite.base/server.cfg.template T-CityLite.base/server.cfg   # 填 license/DB/token
./start.sh                                                          # 默认 30120

# 离线测试
python3 -m pytest -q tests/tools
cd T-CityLite.base && python3 -m pytest -q tests/unit tests/architecture && cd ..
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua
python3 tools/agent_tools.py --check
```

本机把 agent 接到真实服务器（DB + gateway + director）的步骤见
[`T-CityLite.base/docs/agent/MCP_WIRING.md`](T-CityLite.base/docs/agent/MCP_WIRING.md)，一键依赖用
`bash tools/dev/local_stack.sh`。

## 目录

| 路径 | 内容 |
|---|---|
| `T-CityLite.base/` | 服务器数据目录（resources、configs、migrations、tests、docs） |
| `tools/` | agent 工具注册表/MCP/评测/冒烟（Python 标准库） |
| `tests/tools/` | agent 契约/路由/评测测试（Python） |
| `T-CityLite.base/tests/agent/` | Lua golden harness（效果/动作/实时/手机） |
| `docs/` | 项目级文档、审计、清理提案与归档 |
| `.github/` | CI（Config/Python/Lua/Docs/Sonar/DB/NUI） |

## 架构适应度（FIT）

警察架构 13 条 fitness 规则由 `T-CityLite.base/tests/architecture/` 的 pytest 扫描器保护（离线、无 FXServer/DB/网络）。当前 **100 / 100**（24/24；13 PASS / 0 PARTIAL / 0 FAIL）；评分口径、证据与 allowlist 数量见 [`07-fitness-tests.md`](docs/police/architecture/07-fitness-tests.md)。

| # | 规则 | 状态 | 检查器 |
|---|---|---|---|
| FIT-01 | `job.onduty` 单一写者 | ✅ PASS | `test_duty_writer.py` |
| FIT-02 | 禁止跨资源写别人拥有的表 | ✅ PASS | `test_cross_resource_writes.py` |
| FIT-03 | net event 鉴权 | ✅ PASS | `test_net_event_auth.py` |
| FIT-04 | export/action 错误码 + 审计 | ✅ PASS | `test_export_contracts.py` |
| FIT-05 | 审计 fail-closed | ✅ PASS | `test_audit_fail_closed.py` |
| FIT-06 | 迁移幂等 + fixture 覆盖 | ✅ PASS（静态） | `test_fixture_schema.py` |
| FIT-07 | NPC 生成走预算接口 | ✅ PASS | `test_npc_budget.py` |
| FIT-08 | 生成物/注册表一致 | ✅ PASS | `agent_tools.py --check` |
| FIT-09 | 查询纪律（禁 `SELECT *` / 需 LIMIT） | ✅ PASS | `test_query_discipline.py` |
| FIT-10 | 资源接线（cfg ↔ manifest ↔ 文件 ↔ 导出） | ✅ PASS | `test_resource_wiring.py` |
| FIT-11 | 状态机列只允许登记写者 | ✅ PASS | `test_state_writers.py` |
| FIT-12 | 弃用登记 | ✅ PASS | `test_deprecations.py` |
| FIT-13 | 文档数字与代码常量一致 | ✅ PASS | `test_number_budget.py` |

## 约定

- 不提交 `server.cfg`、token、`alpine/`、`cache/`、`node_modules`、本地 admins。
- Lua 5.4；服务端权威；SQL 参数化 + LIMIT；迁移幂等。
- 改前端（`custom-phone/web`）后必须 `npm run build`。
- 详见 [`AGENTS.md`](AGENTS.md) 与 [`docs/agent/STATUS.md`](T-CityLite.base/docs/agent/STATUS.md)。
