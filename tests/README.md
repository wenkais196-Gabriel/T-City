# tests/（仓库根）

| 路径 | 内容 |
|---|---|
| `agent/` | Python 契约/路由/评测/冒烟测试（`pytest -q tests/agent`） |
| `tools/`（规划中） | tools/ 目录的单测；当前仍在 `agent/` |

服务器内部测试（Lua golden、单元、集成、DB fixture、NUI）在
[`T-CityLite.base/tests/`](../T-CityLite.base/tests/)。
