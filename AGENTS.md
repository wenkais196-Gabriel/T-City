# AGENTS.md — T-City 项目 Agent 指南

> 给新开的对话/新 agent 的入口文件。先读这一页，再读 `T-CityLite.base/docs/agent/STATUS.md`。
> 最后更新：2026-10-23（master/dev 同步于 `653f4f1` 之后的手机改动）。

---

## 0. 一分钟了解

T-City 是一个 **QBCore / FiveM RP 服务器**（"T-City Lite"），外加一套 **LLM agent 接管栈**：

- 30+ 资源、MariaDB、OneSync；
- `custom-director`：服务端动作代理（18 个动作，L1–L4 风险分级，L3/L4 必须人审）；
- `tools/agent_tools.json`：31 个 agent 工具的唯一事实源 → MCP / 文档 / Lua 镜像；
- 实时感知 `/agent/v1/live/*`、客户端效果通道 `custom-agent-client`、评测 `agent_eval.py`、实机冒烟 `agent_smoke.py`；
- 手机是自研 Svelte 应用 `custom-phone`（不是 qb-phone，但借鉴其交互）。

**当前状态**：PR #42 已合并；`master` = `dev`；服务器可由 `start.sh` 拉起；手机基础交互、短信、通话、语音、通话记录、设置、铃声已修/已补；职业 App 注册表与相机/相册尚未做。

---

## 1. 工作区、分支与运行中的服务

```
/home/swk/Documents/deepseek-harness/default-workspace/
├── T-City/          # git worktree，分支 dev，运行服务器的工作区（有 alpine/、server.cfg）
├── T-City-agent/    # git worktree，分支 master，主要开发/文档/CI 工作区
└── .agent-state.md  # 长期交接笔记（非仓库文件）
```

- `master` 与 `dev` 现在指向同一提交；改完一边要同步另一边：
  ```bash
  git push origin dev
  cd ../T-City-agent && git fetch origin && git merge --ff-only origin/dev && git push origin master
  # 或反向：push master，再在 T-City 里 pull --rebase
  ```
- **不要在 `T-City/` 和 `T-City-agent/` 同时改同一文件后各自提交**，先 `git status` 看清。
- `T-CityLite.base/server.cfg`、`alpine/`、`cache/` 均被 gitignore；`server.cfg` 里有 DB 密码、license key、agent token，**永远不要提交**。
- 服务器：`cd T-City && ./start.sh`（alpine musl loader），端口 `30120/tcp+udp`，日志 `/tmp/fxserver.log`。
- 本地控制台用 FIFO：启动时 `mkfifo /tmp/fxserver.in`，`setsid bash -c 'exec ./start.sh <>/tmp/fxserver.in'`；发命令：
  ```bash
  printf 'restart custom-phone\n' > /tmp/fxserver.in
  printf 'phone_call <serverId> "City Dispatch" 台词...\n' > /tmp/fxserver.in
  ```
- 玩家重连后 **server id 会变**（5 → 6 …），所有按 id 的操作先 `curl -s localhost:30120/players.json`。
- `cache/files/<resource>/resource.rpf` 是 FXServer 资源缓存；改了 manifest/新文件后 `restart <resource>`，异常时删缓存或整服重启。
- 测试 token 在 `~/.tcity-agent-test.env`（600，未入库）：director/admin/live token、`AGENT_AGENT_ID`。
### txAdmin（本地）

- 配置文件：`alpine/txData/admins.json`（在 `alpine/` 下，已被 gitignore；**永不入库**）。
- 启动参数（本地 `server.cfg`，gitignored）：`set monitorMode "true"`、`set citizen_root "<repo>/alpine/opt/cfx-server/citizen/"`、`set txAdminPort "40120"`，并 `ensure monitor`。
- 面板：`http://<vm-ip>:40120`；首次 setup 用终端 PIN 创建管理员。
- txAdmin 在 Linux 下按 `fxsPath/../../opt/cfx-server/...` 推导 loader，而本仓库的 alpine 布局会多一层 `opt`；已在 `alpine/opt/` 下建兼容软链 `opt -> .`（本地、gitignored）。
- **开发期用手动 `start.sh` + FIFO**（当前状态，便于 agent 直接敲 console）；**上线前再切 txAdmin 托管**：
  - 独立 monitor 进程（40120）spawn 游戏服子进程（30120）；
  - monitor 启动命令：FXServer + `+set monitorMode true +set txAdminPort 40120 +set citizen_root ...`（不 `+exec server.cfg`），并设置 `TXHOST_TXA_DATA=<repo>/alpine/txData`；
  - 游戏服由 txAdmin 的 Start 拉起；此时把 `server.cfg` 的 `set onesync on` 注释掉（由 txAdmin 设置页接管）。
  - 两种模式不要同时跑：手动服占 30120 时 txAdmin 的 Start 会报端口占用。
- 自动化管理员账号 `agent` 的凭据在 `~/.txadmin-agent.env`（600，不入库）。API：
  - 登录：`POST /auth/password`，body `{username,password}`，响应含 `csrfToken` 并设置 cookie；
  - 后续请求带 cookie + `X-TxAdmin-CsrfToken` 头；
  - 资源：`POST /fxserver/commands`，body `{action:"restart_res"|"start_res"|"stop_res"|"ensure_res"|"refresh_res", parameter:"<resource>"}`；
  - 服务器：`POST /fxserver/controls`，body `{action:"start"|"stop"|"restart"}`。
  - 任意 console 命令不在 REST 里（仅面板 Live Console / WebSocket）。
- 密码轮换后确认：`git check-ignore -v alpine/txData/admins.json`；历史里的旧哈希不会因轮换消失，必要时 filter-repo。


---

## 2. 项目基础

- 资源目录：`T-CityLite.base/resources/{[custom],[qb],[system],[standalone],[voice]}`
- 启动顺序：`server.cfg` → `exec configs/modules/*.cfg` → 每个模块 `ensure` 资源。
- 关键资源：
  - `core-framework`（bus/economy 等）、`qb-core`、`oxmysql`
  - `custom-director`（agent 动作 + live API）
  - `custom-agent-client`（客户端效果 + `agent_effects` 审计）
  - `custom-phone`（自研手机）
  - `custom-vehicles`（含中控屏 `RegisterDashboardApp` 职业 App 范式）
  - `story-engine`、`custom-quest`、`custom-career`
- DB：MariaDB 11.8，库名 `TCityLite`；连接串只在 `server.cfg`。
- 迁移：`T-CityLite.base/migrations/v*.sql`，必须幂等（information_schema 判断 + 存储过程），新表/改表同时更新 `tests/fixtures/tcity_schema.sql`。

---

## 3. 开发标准与设计准则

### 3.1 代码

- **Lua 5.4**；新增依赖要克制，前端用现有 Svelte 5 + Vite（`custom-phone/web`）。
- 服务端权威：客户端传来的任何数据都要服务端复验；NUI 隐藏 ≠ 权限。
- 写路径优先走 `Player.Functions.*` / `core_economy:TriggerReward`，**不要直接 SQL 改钱/物品**。
- SQL：参数化、列白名单、`LIMIT`、复合索引；禁止 `SELECT *` 全表拉取。
- 幂等：所有动作/接口要能重试；DB 迁移可重复执行。
- 时间/金额/坐标统一用现有 helper（`PhoneDb.InsertId`、`AgentPolicy`、`LiveRules.clamp_limit`）。

### 3.2 Python / 工具

- `tools/**` 只用 **Python 3.12 标准库**；离线、确定性测试。
- 工具注册表 `tools/agent_tools.json` 是唯一事实源；改完跑：
  ```bash
  python3 tools/agent_tools.py --write   # 生成 TOOLS.md / Lua 镜像
  python3 tools/agent_tools.py --check   # CI 会跑，必须 OK
  ```
- 新增工具必须：schema、risk、requires_approval、verify、idempotency、`since`，并同步动作/策略/测试。

### 3.3 测试与 CI

```bash
# Python agent 测试（仓库根，T-City-agent）
python3 -m pytest -q tests/tools

# 单元/集成（T-CityLite.base）
cd T-CityLite.base && python3 -m pytest -q tests/unit

# Lua golden（9 suites，236 checks）
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua

# 工具注册表一致性
python3 tools/agent_tools.py --check

# 实机冒烟（需要服务器 + online 玩家）
source ~/.tcity-agent-test.env
AGENT_SMOKE_CITIZENID=<cid> python3 tools/agent_smoke.py --allow-write --allow-approve --json
```

- CI：Config & dependency、Python unit、Lua syntax、Docs links、SonarCloud、DB schema、NUI（master 分支 6 job）。
- 改前端后必须 `cd web && npm run build`，产物在 `html/`，否则客户端不生效。
- 改 Lua client 后 `restart <resource>`；改服务端 Lua 同理。改 manifest 后 restart 仍异常 → 删 `cache/files/<resource>`。

### 3.4 Git / 评审

- 分支：`master` = `dev`（当前）；功能分支 → PR（CI + Sonar 必须绿）。
- 提交信息：`feat(scope): ...` / `fix(scope): ...` / `docs(...)`；正文写"为什么"。
- 不 `git add -A` 前先看 `git status`；不提交 `server.cfg`、token、`alpine/`、`cache/`、`node_modules`。
- 安全评审标准：能拒绝危险动作 ≥ 能执行；L3/L4 永远人审；agent token 不能审批；拒绝要留审计。

---

## 4. Agent 接管栈（简图）

```
LLM/MCP ── tools/agent_mcp.py ──┬─ read  → agent_gateway.py → DB views
                                ├─ write → custom-director /agent/v1/act → 人审 → 执行 → 回读
                                └─ live  → /agent/v1/live/*（独立 token）
custom-director ── 18 actions / policy.lua（L1-L4）
custom-agent-client ── 客户端效果（6 个动作）+ agent_effects 审计
agent_eval.py ── 成功率/审批/拒绝/P95/幂等（离线）
agent_smoke.py ── 实机三段式冒烟
```

- 31 个工具 / 18 个动作；L3/L4 需要 `pending_approval` + admin token 审批。
- 拒绝写入 `agent_denials`（不含参数值）；效果审计写 `agent_effects`（不存正文）。
- 特权接口：admin token 只用于审批；live token 只读；两者绝不能相同。
- 参考文档：`T-CityLite.base/docs/agent/{STATUS,ACTIONS,TOOLS,EVAL,SMOKE}.md`、`T-CityLite.base/docs/agent/design/01..05`、`T-CityLite.base/docs/agent/reviews/01..08`。

---

## 5. 手机系统（custom-phone）

- 前端：`web/src/App.svelte` + `apps/*.svelte` + `stores/*`；构建产物 `html/`（Vite）。
- 服务端：`server/main.lua`（主逻辑）、`banking.lua`、`jobboard.lua`、`faction.lua`、`sms.lua`（`Sms` + `PhoneDb` helper）。
- 客户端：`client/main.lua`（焦点、开屏、NUI 回调、systemSpeech 桥接）。
- 表：`phone_messages`（v2.7 新结构）、`phone_contacts`、`phone_calls`、`phone_notifications`、`phone_cityfeed`、`phone_jobboard`、`phone_numbers`。
- 焦点语义（血泪）：
  - 开：`SetNuiFocus(true,true)` → `SetNuiFocusKeepInput(true)`；**不要**在打开前/关闭后调 `SetNuiFocusKeepInput(false)`，否则下一次打开 WASD 冻结；
  - 关：`SetNuiFocus(false,false)`，保留 keepInput；`custom-ui.CloseMenu` 已按此实现；
  - 视角/近战每帧 `DisableControlAction(1..6 等)`，**不要禁 30–35**（movement）；
  - NUI 调用 `SetNuiFocus` 只用两参数形式；qb-menu 曾用单参数导致半聚焦。
- 通话：`pma-voice` 的 `setPlayerCall(src, callId)`；45s 无人接听自动 missed；系统来电 `exports['custom-phone']:StartSystemCall(src,label,number,speech)`；控制台 `phone_call <id> [label] [speech]`。
- 调度语音：服务端发 `phone:client:systemSpeech` → 客户端 `SendNUIMessage('phone:systemSpeech')` → NUI `speechSynthesis` + 字幕。CEF 无语音包时只有字幕。
- 短信分页：首屏 30 条 + `phone:server:getMessages`（id 游标）。
- 已知坑：`client/call_history.lua` 这类**额外 client 脚本在实机可能不执行**；NUI 桥接放 `client/main.lua` 更稳。

---

## 6. 常见坑 / 实机回归清单

- `_G.QBCore` 在资源内不保证存在；`live_api` 用 `exports['qb-core']:GetCoreObject()` 惰性解析并缓存。
- `PlayerData.source` 不可靠；roster key 才是 source。
- 服务端 `DoesEntityExist` 对远程 ped 可能 false；坐标采样不要以它为前提。
- NUI 焦点：单参数 `SetNuiFocus(false)`、`keepInput=false` 残留、半聚焦都是实机 bug 来源。
- `phone_messages` 旧库是 qb-phone 列；v2.7 迁移会保留 `phone_messages_legacy`，不自动展开 JSON。
- oxmysql 定制版 `insert` 可能返回 `{insertId,affectedRows}`；一律用 `PhoneDb.InsertId/AffectedRows`。
- 通知不要"收到就回存"，会无限回环；服务端单播 + `origin='server'`。
- `custom-career` 没有 `primary_role`，用 `PhoneIdentity.Resolve`。
- 玩家重连后 server id 变；`phone_call`/teleport 等按 id 操作前重新查 `players.json`。
- 改 `html/` 不等于改源码；必须 `npm run build`。
- 服务器 console 里 `status` 会命中 qb-ambulancejob 的 `/status`（source=0 报 nil），不是启动错误。

---

## 7. 文件索引（高频）

| 路径 | 用途 |
|---|---|
| `T-CityLite.base/server.cfg` | 本地配置（gitignored，含 token/DB/license） |
| `T-CityLite.base/configs/modules/*.cfg` | 资源 ensure 顺序 |
| `T-CityLite.base/resources/[custom]/custom-director/server/{main,policy,live_api,live_rules,http_api}.lua` | 动作代理 + live |
| `T-CityLite.base/resources/[custom]/custom-agent-client/server/main.lua` | 客户端效果 + 审计 |
| `T-CityLite.base/resources/[custom]/custom-phone/{server,client,web,html}` | 手机 |
| `T-CityLite.base/migrations/*.sql` | 数据库迁移（幂等） |
| `T-CityLite.base/tests/fixtures/tcity_schema.sql` | CI DB fixture |
| `T-CityLite.base/tests/agent/lua/runner.lua` | Lua golden 入口（9 suites） |
| `tools/agent_tools.{json,py}` | 工具注册表 + 生成器/校验 |
| `tools/agent_mcp.py` / `agent_gateway.py` / `agent_eval.py` / `agent_smoke.py` | MCP 路由 / 只读网关 / 评测 / 冒烟 |
| `tests/tools/*.py` | Python agent 契约/路由/评测测试 |
| `T-CityLite.base/docs/agent/STATUS.md` | 当前状态一页纸（先读） |
| `T-CityLite.base/docs/agent/ACTIONS.md` / `TOOLS.md` / `EVAL.md` / `SMOKE.md` | 动作/工具/评测/冒烟 |
| `T-CityLite.base/docs/agent/design/01..05` | 感知/效果/契约/写操作/测试设计 |
| `T-CityLite.base/docs/agent/reviews/01..08` | 评审记录 |
| `T-CityLite.base/docs/agent/phone/{qb-phone-research,custom-phone-audit,DESIGN}.md` | 手机调研/审计/设计 |
| `T-CityLite.base/resources/[custom]/custom-phone/PHONE_API_TECHNICAL_MANUAL.md` | 手机接口手册 |

---

## 8. 当前状态与下一步

**已闭环**：PR #42 合并；phone_messages v2.7、oxmysql 返回值、通知回环、来电/右键/M 键/WASD、真实通话语音、45s 超时、通话记录、设置、铃声、短信分页、调度 TTS。

**待办**（按建议顺序）：

1. **职业 App 注册表**（`T-CityLite.base/docs/agent/phone/DESIGN.md`）：`PhoneApps.Register/CanUse` + 通用 `app:query/action`，先接警察 MDT；
2. **相机/相册**（media 表、存储/清理、NUI 组件）；
3. **实机联调**：`agent_smoke.py` 全链路（需真人玩家）；
4. 手机 P2：旧 JSON 未展开、通话语音在真实客户端偶尔无 TTS 语音包（需 WAV 回退）、消息/头像 N+1。

**新对话开场 checklist**：

```bash
cd T-City-agent && git status --short && git log --oneline -3
sed -n '1,120p' T-CityLite.base/docs/agent/STATUS.md
python3 -m pytest -q tests/tools
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua
python3 tools/agent_tools.py --check
curl -s http://127.0.0.1:30120/players.json   # 服务器/玩家是否在线
```
