# Agent 接管 · 实现状态

> 快照：2026-10-22 · 分支 `feat/agent-takeover-v2` · PR #42
> 目的：一页说明"设计里要求什么、现在实际有什么、还缺什么"，避免从 30 个工具和几万行 diff 里自己拼全貌。

## 1. 分层总览

| 层 | 载体 | 状态 |
|---|---|---|
| 只读 DB 层 | `agent_gateway.py` + `agent_*` 视图 + `agent_ro` | 已上线（v1 契约未破坏） |
| 实时感知层 | `custom-director` `/agent/v1/live/*` | 已实现，48 人 ≈2.2ms，默认关闭 |
| 动作代理（写） | `custom-director` `/agent/v1/act` | 18 个动作，L1–L4 分级 + 人审 |
| 效果通道（client） | `custom-agent-client` | 6 个客户端动作 + 服务端 `give_vehicle_keys`（未接）；终态落 `agent_effects` |
| 工具面 | `tools/agent_tools.json` → MCP / TOOLS.md / Lua 表 | 31 工具 / 31 active |
| MCP 路由 | `tools/agent_mcp.py` | 读→gateway、写→director、live 独立 token |
| 评测 | `tools/agent_eval.py` + `agent_denials` | 成功/审批/拒绝/时延/幂等 |
| 实机冒烟 | `tools/agent_smoke.py` | 10 项三段式检查 |

## 2. 动作覆盖

已实现 18 个：`notify`、`add_money`、`start_quest`、`set_job`、`set_job_duty`、`set_metadata`、`teleport`、`spawn_vehicle`、`grant_item`、`remove_item`、`set_bucket`、`kick`、`announce`、`set_weather`、`set_time_of_day`、`revive`、`delete_vehicle`、`send_phone_message`。

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
lua5.4 tests/agent/lua/runner.lua        8 suites / 229 checks
python3 -m pytest -q tests/agent         203 passed
cd T-CityLite.base && pytest -q tests/unit   262 passed
python3 tools/agent_tools.py --check     30 tools, no drift
```

**没有做过的**：真实 FXServer + GTA 客户端联调。所有 Lua 断言都在 stub 下；`DropPlayer` 异步、`DoesEntityExist` 延迟、`SetEntityCoords` 的 OneSync 时序均未在真机验证。

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

1. 真机联调（最高优先级，见上）。
2. `custom-phone:SendSystemMessage` 只有临时冒烟脚本，尚无仓内单测。
3. 客户端 ack 的端到端验证（NUI、动画、传送落点）。
4. 越权拒绝率只覆盖 normalization 之后的拒绝；token/资源开关层失败仍需 HTTP 日志。
