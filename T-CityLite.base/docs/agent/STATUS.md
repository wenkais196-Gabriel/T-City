---
id: base-agent-status
type: spec
status: active
system: agent
owner: hermes
updated: 2026-10-27
review_by: 2027-04-30
---

# Agent 接管 · 实现状态

> 快照：2026-10-27 · master（#48/#50–#57 已合并）· 真机已联调（FXServer 37872 @30130 + FiveM 3258）
> 目的：一页说明"设计里要求什么、现在实际有什么、还缺什么"，避免从 30 个工具和几万行 diff 里自己拼全貌。

## 1. 分层总览

| 层 | 载体 | 状态 |
|---|---|---|
| 只读 DB 层 | `agent_gateway.py` + `agent_*` 视图 + `agent_ro` | 已上线（v1 契约未破坏） |
| 实时感知层 | `custom-director` `/agent/v1/live/*` | 已实现，48 人 ≈2.2ms，默认关闭 |
| 动作代理（写） | `custom-director` `/agent/v1/act` | 18 个动作，L1–L4 分级 + 人审 |
| 效果通道（client） | `custom-agent-client` | 6 个客户端动作 + 服务端 `give_vehicle_keys`（未接）；终态落 `agent_effects` |
| 客户端状态探针 | `custom-phone` 的 `GetUiState` + `custom-agent-client` 每 5s 快照 → `/agent/v1/live/clients` | 已实现；15s TTL、1s/源限流、掉线清理、原生焦点值单列 |
| 客户端无头 harness | `tests/agent/lua/runner_client.lua` | 2 suites / 26 checks（焦点、M 键、appState） |
| 工具面 | `tools/agent_tools.json` → MCP / TOOLS.md / Lua 表 | 41 工具 / 41 active（另 3 个 harness 工具需 `TCITY_HARNESS=1`） |
| MCP 路由 | `tools/agent_mcp.py` | 读→gateway、写→director、live 独立 token |
| 评测 | `tools/agent_eval.py` + `agent_denials` | 成功/审批/拒绝/时延/幂等 |
| 实机冒烟 | `tools/agent_smoke.py` | 10 项三段式检查 |

## 2. 动作覆盖

已实现 21 个（另 `run_police_e2e` 是测试用写动作，不对玩家生效）：`notify`、`add_money`、`start_quest`、`set_job`、`set_job_duty`、`set_metadata`、`teleport`、`spawn_vehicle`、`grant_item`、`remove_item`、`set_bucket`、`kick`、`announce`、`set_weather`、`set_time_of_day`、`revive`、`delete_vehicle`、`send_phone_message`、`police_incident`、`police_assignment`、`police_jail`。

与设计 04 的差异：

| 设计动作 | 状态 | 原因 |
|---|---|---|
| `send_phone_message` | 已实现 | `custom-phone` 新增服务端导出 `SendSystemMessage`；号码由服务端解析，审计只留掩码 |
| `set_money` | **明确不做** | 见设计 04 §14：绕过预算/delta 护栏，反向操作受 `MinusLimit` 限制不可靠 |
| `delete_vehicle` | 以 `remove_player_vehicle` 落地 | 只删玩家当前所在载具，不接受任意 entity id |

## 3. 安全边界（实现层面）

- 客户端永远不可信：效果通道只接受带 session 的 server 签发消息，ack 只作遥测。
- L3/L4 永远 `pending_approval`；agent token 无审批权。
- 执行后回读：`set_job`/`grant_item`/`remove_item`/`set_weather`/`set_time_of_day`/`set_bucket`/`set_metadata`/`set_job_duty` 都做服务端回读；失败记 `verification_failed`。
- 拒绝审计：`agent_denials` 记录 Normalize/CheckPolicy/审批复核失败，不存参数值。
- 效果审计：`agent_effects` 每个请求落一行终态（request_id/agent/target/action/status/error_code/latency），notify 正文、UI 文本、手机号等 payload **不入库**；`agent_effect_audit=0` 可关闭，写入失败只告警、不改变动作结果。
- 效果通道 `not_yieldable` 显式失败，不降级为 fire-and-forget。
- `agent_actions_agent_id` 可固定 agent 身份，伪造的 `X-Agent-Id` 会被拒（`agent_id_mismatch`）。
- live 读端点是令牌桶限流（`agent_live_rate_per_min`，默认 120/min，burst 40），超限 429。

## 4. 验证现状

```
lua5.4 tests/agent/lua/runner.lua            13 suites / 253 checks
lua5.4 tests/agent/lua/runner_client.lua      2 suites /  26 checks
python3 -m pytest -q tests/tools             227 passed
cd T-CityLite.base && pytest -q tests/unit   679 passed / 132 skipped
cd T-CityLite.base && pytest -q tests/architecture  286 passed / 15 skipped
python3 tools/agent_tools.py --check         41 tools, no drift
web/tests/nui/run.mjs --surface=phone|tablet 18 / 6 passed
# harness（本地只读）需 TCITY_HARNESS=1 + TCITY_HARNESS_SERVER_LOG 才出现在 tools/list
```

**已在真机验证**（2026-10-27，30130 + 真客户端 `DXI50064` / 角色 `DEV00001`）：

- live roster 跟随加入/离开（修复了 QBCore 导出被缓存导致的冻结）；
- `set_weather` 走完 审批 → 执行 → 回读（`verify_result=true`，before/after 都对）；
- M 键开关：`open=true/surface=phone/focused=true` 与 `nui_focus_native=false` 并存，
  证明引擎原生会撒谎、判定必须走自己的账；
- `/live/clients` 快照：citizenid、2560×1440、ped 血量/载具、app 页状态；
- `/live/server`：83/117 起，34 个未启动资源**具名**（`custom-agent-ops` 等）；
- gateway `/agent/v1/players` 读到真实行（`DEV00001`）；
- **截图可用**：窗口模式下 `PrintWindow` 返回真实画面（亮度 96–99%），手机/平板、任务页、
  MDT 都靠它对账；独占全屏才是全黑（§7.3）；
- **平板两栏**：`/tablet` 后任务页左列表 + 右详情并排（1000×676 居中），换形态不丢当前页；
- **客户端驱动**：devcon 的 29200 在监听但握手不完成，改用 `adc <src> <cmd>`（RCON → 客户端
  白名单命令），agent 可以自己开屏/换形态/切 App，不再需要人敲 F8；
- **App 页状态**：任务（`tab`）与 MDT（`tab` + 选中的警情 id）都回吐到 `phone.app`。

**仍未在真机验证**：客户端动作 ack 的端到端（动画/传送落点）、银行/ Garage 等其余 App 的
`appState`、真实平板上的像素点击（做不到，见 playbook §3.0d）。

## 5. 上手（按顺序）

```bash
# 1. 建表（缺表会导致拒绝/效果审计告警；效果写入有打印限流）
mysql ... < T-CityLite.base/migrations/v2.3_agent_actions.sql
mysql ... < T-CityLite.base/migrations/v2.5_agent_denials.sql
mysql ... < T-CityLite.base/migrations/v2.6_agent_effects.sql

# 2. 开 convar（server.cfg 或独立 cfg）
set agent_actions_enabled "1"
set agent_actions_token "<random>"
set agent_actions_admin_token "<different-random>"
set agent_live_enabled "1"
set agent_live_token "<third-random>"   # 与 actions token 必须不同
set agent_effect_enabled "1"            # 需要客户端效果时
set agent_effect_audit "1"              # 效果通道 DB 审计，默认开；"0" 关闭

# 3. 冒烟（只读 → dry_run → 受控写）
python3 tools/agent_smoke.py
python3 tools/agent_smoke.py --allow-write --json

# 4. 评测
mysqldump/导出 agent_actions + agent_denials 为 JSONL
python3 tools/agent_eval.py --input actions.jsonl --denials denials.jsonl --out report.json
```

## 6. 仍然缺的

1. **每个 App 的页状态**：任务与 MDT 已接；银行/Garage/联系人还没接，agent 答不了"他在看哪张卡/哪辆车"。
2. **客户端的焦点真值**：`IsNuiFocused()` 恒 false，只有 NUI 侧的 `document.hasFocus()` 能作准，尚未上报。
3. **gateway / director 没有进程守护**：都要手工起（`tools/dev/local_stack.sh` 打印的命令）；
   凭据不一致时只报 `database_auth`，不看日志很难定位。
4. **SonarCloud 把提交进仓库的压缩产物当新代码**（Security D / Maintainability C）；
   仓库用自动分析，排除项只能在 SonarCloud UI 加 `**/html/**`。
5. `custom-phone:SendSystemMessage` 只有临时冒烟脚本，尚无仓内单测。
6. 客户端动作 ack 的端到端验证（NUI、动画、传送落点）。
7. 越权拒绝率只覆盖 normalization 之后的拒绝；token/资源开关层失败仍需 HTTP 日志。

## 7. agent 现在能看见什么（双端）

一句话：**壳层看得清，App 内部看不清；写路径全，读路径偏服务端。**

### 7.1 服务端

| 能看见 | 手段 |
|---|---|
| 什么在跑、谁没起（具名） | `GET /agent/v1/live/server` → `resources.not_started` |
| 谁在线、坐标、职位、血量 | `GET /agent/v1/live/players[/{src}]` |
| 实时事件流 | `GET /agent/v1/live/events` |
| 控制台输出（按行 / 按正则） | harness `get_console_lines` / `get_console_match`（需 `TCITY_HARNESS=1` + 日志路径） |
| DB 里的既成事实 | gateway `/players`、`/world_state`、`/metrics`、`/timeline`（只读账号） |
| 动作是否真的生效 | `/act` 执行 + 回读；`agent_actions` / `agent_effects` / `agent_denials` |

看不见：单个资源的内部状态（只有"起/没起"）、异步任务与队列进度、RCON（本栈没有，
只有 `screen` 注入，且要先发 DEL 清行防命令拼接）。

### 7.2 客户端

| 能看见 | 手段 |
|---|---|
| 手机壳：开着吗 / 哪一面 / 焦点归谁 / keepInput | 5s 快照 → `GetUiState()` → `/live/clients` |
| 用键盘操作手机 UI（方向键移焦点、Enter 确认、Backspace 返回、Tab 进出输入框） | NUI `keydown` → `T-CityLite.base/resources/[custom]/custom-phone/web/src/core/nav.ts`；真机已验证 Down×2+Enter 打开 Contacts |
| 现在焦点停在哪个控件上 | 每次移动焦点 NUI 回吐标签 → `phone.focus`（`aria-label` 优先，限 24 字） |
| 某个 App 停在哪一页（任务、MDT） | App 的 `appState` 回吐（`tab` + 选中项 id） |
| ped 血量/死亡/载具类型、屏幕分辨率、登录态 | 同一份快照 |
| 客户端错误 | `phone:server:clientError`、`story-engine` 遥测心跳 |
| 客户端日志文件 | harness `get_client_log`（需 env 路径） |

### 7.3 看画面

窗口模式下 `screenshot` 抓的是真实画面（`PrintWindow`，亮度 96–99%），但有两个前提：
**必须窗口模式**（独占全屏只有黑帧），且**截图前先 `focus_window`**（窗口不在前台时
`PrintWindow` 返回 2% 亮度的黑图，重新聚焦后恢复）。

看不见：独占全屏下的画面、CEF DOM 内部（只有 NUI 自愿上报的部分）、
焦点真值（`IsNuiFocused()` 恒 false，需要 NUI 侧 `document.hasFocus()`）、
`custom-police`/`custom-economy` 等非手机资源的客户端状态（没有导出点）。
