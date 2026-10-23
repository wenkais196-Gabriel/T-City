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
python3 -m pytest -q tests/agent
cd T-CityLite.base && python3 -m pytest -q tests/unit && cd ..
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua
python3 tools/agent_tools.py --check
```

## 目录

| 路径 | 内容 |
|---|---|
| `T-CityLite.base/` | 服务器数据目录（resources、configs、migrations、tests、docs） |
| `tools/` | agent 工具注册表/MCP/评测/冒烟（Python 标准库） |
| `tests/agent/` | agent 契约/路由/评测测试（Python） |
| `T-CityLite.base/tests/agent/` | Lua golden harness（效果/动作/实时/手机） |
| `docs/` | 项目级文档、审计、清理提案与归档 |
| `.github/` | CI（Config/Python/Lua/Docs/Sonar/DB/NUI） |

## 约定

- 不提交 `server.cfg`、token、`alpine/`、`cache/`、`node_modules`、本地 admins。
- Lua 5.4；服务端权威；SQL 参数化 + LIMIT；迁移幂等。
- 改前端（`custom-phone/web`）后必须 `npm run build`。
- 详见 [`AGENTS.md`](AGENTS.md) 与 [`docs/agent/STATUS.md`](T-CityLite.base/docs/agent/STATUS.md)。
