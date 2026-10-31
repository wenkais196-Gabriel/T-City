# 把 MCP 接到 T-City 上（本地全链路）

> 结论先说：`tools/agent_mcp.py` 本身只是**路由壳**。它要有东西可路由，必须同时具备
> ① MariaDB 里的 agent 视图 ② `agent_gateway.py`（读） ③ FXServer 跑着 `custom-director`
> （写 + live）。缺任何一环，`tools/list` 会少工具、`tools/call` 会 `unauthorized`。
>
> 本文记录 2026-10-26 在 Windows 单机实测通过的接法，以及每一步的验证命令。

---

## 1. 拓扑

```text
MCP host (Claude Code / Cursor / 任意 stdio 客户端)
   │  stdio JSON-RPC
   ▼
tools/agent_mcp.py ──┬─ route=gateway  → agent_gateway.py :8787 → agent_* VIEWS → MariaDB
                     ├─ route=director → FXServer :30130 /custom-director/agent/v1/*  (写 + 审批)
                     ├─ auth=live      → 同上，/agent/v1/live/*（live token）
                     └─ route=harness  → 本地日志（design 07，需 TCITY_HARNESS=1）
```

三条通道的 token **必须互不相同**：agent token 不能审批（实测 401），live token 只读。

## 2. 一次性准备

```bash
bash tools/dev/local_stack.sh      # 起 mariadb:11.8 容器、导 fixture、跑迁移、建 agent_ro
```

脚本做四件事（幂等）：容器 `tcity-mariadb` → `127.0.0.1:3307`；空库时导入
`tests/fixtures/tcity_schema.sql`；按版本序执行 `migrations/*.sql`；建只读账号 `agent_ro`
（只授 5 个 agent 视图的 SELECT）。结尾会打印可直接 `export` 的环境变量块。

`server.cfg`（gitignored）里补三行 token 与两个开关：

```cfg
set agent_actions_enabled 1
set agent_actions_token "dev-agent-token"
set agent_actions_admin_token "dev-admin-token"
set agent_live_enabled 1
set agent_live_token "dev-live-token"
set agent_actions_agent_id "mcp.local"
set mysql_connection_string "mysql://root:***@127.0.0.1:3307/TCityLite?charset=utf8mb4"
ensure custom-director          # 它不在 configs/modules/*.cfg 里，必须单独 ensure
```

> `oxmysql` 是 JS 资源，`resources/[standalone]/oxmysql` 需要一次
> `npm install --omit=dev --ignore-scripts --legacy-peer-deps`，否则整个栈报
> `Cannot find module 'mysql2'`，qb-core 与所有 SQL 资源跟着红。

## 3. 起服务

```bash
# 读通道
AGENT_TOKEN=devgw-token AGENT_DB_HOST=127.0.0.1 AGENT_DB_PORT=3307 \
AGENT_DB_USER=agent_ro AGENT_DB_PASS=agentro AGENT_DB_NAME=TCityLite \
  python3 tools/agent_gateway.py            # :8787

# 游戏侧（写 + live）
cd T-CityLite.base && ../FXServer/FXServer.exe +exec server.cfg
```

## 4. 验证（实测输出）

| 步骤 | 命令 | 期望 |
|---|---|---|
| 视图可读 | `docker exec tcity-mariadb mariadb -uagent_ro -pagentro -e "SELECT COUNT(*) FROM TCityLite.agent_player_snapshot"` | 数字，非 access denied |
| 网关 | `curl -H "Authorization: Bearer devgw-token" 127.0.0.1:8787/agent/v1/health` | `"reachable":true` |
| 网关鉴权 | 不带 token | `401` |
| 动作策略 | `curl -H "Authorization: Bearer dev-agent-token" -H "X-Agent-Id: mcp.local" 127.0.0.1:30130/custom-director/agent/v1/policy` | 200 + `actions{...}`（L2/L3/L4 的 `requires_approval`） |
| live | `curl -H "Authorization: Bearer dev-live-token" …/agent/v1/live/players` | `{"count":0,"players":[]}` |
| MCP 工具面 | `tools/list` | 36（director+gateway）；加 `TCITY_HARNESS=1` → 39 |
| 读 | `query_players {"limit":2}` | 真实行（本次 2 个种子玩家） |
| 感知 | `get_live_players {}` | `count` + `players` |
| 写（dry-run） | `set_weather {"weather":"EXTRASUNNY"}` + `dry_run` | `kind=ok`, `status=proposed`, `preview.requires_approval=true` |
| 写（L2） | `set_weather {"weather":"THUNDER"}` | `kind=approval_required`, `action_id`, `expires_at` |
| 审批隔离 | agent token 调 `/actions/<id>/approve` | `401` |
| 审批执行 | admin token 调同一路径 | `status=executed`, `verify_result=true`, `before=EXTRASUNNY` |
| 回读 | `get_action {"action_id":<id>}` | `status=executed` + 时间戳 |

## 5. 常见断点

| 症状 | 原因 |
|---|---|
| `tools/list` 只有 8 个（无 director 工具） | `AGENT_DIRECTOR_URL/TOKEN` 没设，或 FXServer 没 `ensure custom-director` |
| 所有 read 都 `unauthorized` | `AGENT_GATEWAY_TOKEN` 与 `agent_gateway.py` 的 `AGENT_TOKEN` 不一致 |
| `player_not_found`（写） | 目标 citizenid 不在线；`notify` 这类 L1 要求在线 |
| `Cannot find module 'mysql2'` | oxmysql 没 `npm install`（见 §2 注意） |
| `no such export query in resource oxmysql` | 同上，oxmysql 没起来，所有 SQL 资源连带失败 |
| `EADDRINUSE` 30130 | 端口被占（本机曾遇到 `vmnat.exe` 占 30120） |
| 审批 503 | `agent_actions_admin_token` 为空 |

## 6. MCP 宿主配置

仓库根放一份 `.mcp.json.example`；复制成 `.mcp.json`（已 gitignore）后指向本机路径即可。
宿主需要先把 §2/§3 的 env 导出，或把值直接写进该文件的 `env` 块（**不要提交带 token 的版本**）。
