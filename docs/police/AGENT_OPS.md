# Agent Ops — 警察服务器实时观测与介入

> 资源：`T-CityLite.base/resources/[custom]/custom-agent-ops/`
> 定位：给 agent / 运维提供**实时事件环 + 状态快照 + 健康检查 + 控制台介入**。
> 只读 `police_*` / `justice_sentences`，不写警察/司法表，不新增表，不新增依赖。

## 1. 为什么需要它

`custom-director` 负责**动作**（提案/审批/执行），`custom-agent-client` 负责**客户端效果**，
但两者都不知道"刚刚发生了什么"：谁上勤、哪条警情被派单、outbox 是否积压、DB 是否变慢。
`custom-agent-ops` 补的是**观测面**：

```
police_audit ─┐
police_outbox ├─> 2s/5s 轮询 ─> 500 条内存事件环 ─┬─> /agent events|status|health
police_incidents │                                ├─> GetAgentEvents/GetAgentSnapshot
justice_sentences │                               └─> logs/agent-events.jsonl（关键事件）
police_units ─┘
```

它**不替代** director 的动作能力，也不重复 agent-client 的效果通道；它只回答：

- 服务器现在怎么样？`/agent status` / `GetAgentSnapshot()`
- 最近发生了什么？`/agent events [n]` / `GetAgentEvents(sinceId, limit)`
- 有没有隐藏故障？`/agent health` / `HealthSnapshot()`
- 某个测试套件怎么跑？`/agent test <suite>`
- 原始审计/outbox 长什么样？`/agent tail [n]`

## 2. 命令

所有命令只接受 **FXServer 控制台（source 0）** 或持有 ACE `agent.ops` 的玩家。
控制台命令如果由其他资源用 `ExecuteCommand` 转发（`GetInvokingResource() ~= nil`），会被拒绝，
避免资源伪造控制台操作。输出只写**服务端控制台**；本资源没有 client script、没有 net event。

```text
/agent status
/agent events [n]        # 1..100，默认 20；每条一行 JSON
/agent tail [n]          # 1..50，默认 20；police_audit + police_outbox 原始行
/agent health
/agent test <suite>      # custom-testing 未运行时报 custom_testing_not_running
```

示例：

```text
> /agent status
{"schema_version":1,"ok":true,"boot_id":"...","sampled_at":1761330000000,
 "resources":{"custom-police":"started","custom-testing":"started","oxmysql":"started",
 "qb-core":"started","custom-director":"started","custom-agent-client":"started"},
 "missing_resources":[],"optional_down":[],"players":7,"police_on_duty":3,
 "incidents_open":2,"sentences_active":1,
 "outbox":{"pending":0,"failed":0,"stale_pending":0},
 "npc_budget":{"used":1,"max":6},"db":{"ok":true,"latency_ms":2},
 "ring":{"capacity":500,"count":42,"last_id":42,"dropped":0},
 "file_log":{"enabled":true,"mode":"io","path":".../logs/agent-events.jsonl",
 "writes":12,"failures":0,"rotations":0}}

> /agent events 2
{"id":41,"ts":1761330000000,"type":"duty","source":0,"citizenid":"ABC123",
 "data":{"actor_kind":"player","action":"duty.set","target":"onduty","detail":"go on duty"}}
{"id":42,"ts":1761330002100,"type":"incident","source":0,"citizenid":"ABC123",
 "data":{"open":2,"delta":1}}

> /agent health
{"schema_version":1,"ok":true,"healthy":true,"db":{"ok":true,"latency_ms":2},
 "resources":{"missing":[],"optional_down":[]},
 "outbox":{"pending":0,"failed":0,"stale_pending":0,"threshold":20},
 "old_pending":0,"ring":{...},"file_log":{...}}

> /agent test smoke
{"ok":true,"suite":"smoke"}
```

### ACE 配置

```cfg
# 给管理员组或某个 license 授予命令权限
add_ace group.admin agent.ops allow
# 或者
add_ace identifier.license:xxxxxxxx agent.ops allow
```

没有 `agent.ops` 的玩家执行 `/agent ...` 只会看到：

```text
[custom-agent-ops] denied source=5 command=status reason=ace_denied
```

被拒绝的尝试会以 `security` 事件进入事件环（若已启动也会写 JSONL）。

## 3. 事件模型

内存环固定 **500 条**，满后淘汰最旧一条；`id` 每次资源启动从 1 递增，
`boot_id` 标识本次生命周期。事件结构：

```json
{
  "id": 42,
  "ts": 1761330002100,
  "type": "incident",
  "source": 0,
  "citizenid": "ABC123",
  "data": { "open": 2, "delta": 1 }
}
```

| 字段 | 说明 |
|---|---|
| `id` | 本次资源生命周期内单调递增；重启后从 1 开始 |
| `ts` | epoch 毫秒（`os.time()*1000 + GetGameTimer()%1000`） |
| `type` | 事件类型，见下表 |
| `source` | 玩家 server id；系统/审计/导出事件为 `0` |
| `citizenid` | 审计 actor 或被推事件的主题；截断 50 字符，可能是 `agent:<id>` / `system` |
| `data` | 脱敏、截断后的对象；最多 20 键、3 层、字符串 160 字符 |

### 事件类型

| type | 来源 |
|---|---|
| `duty` | `duty.set` / `unit.status` / `unit.drop` / `unit.stale`；在勤人数变化 |
| `incident` | `incident.create/view/assign/unassign/close/status/stale/update`；open 数变化 |
| `arrest` | `arrest.create/register/view` |
| `sentence` | `justice.verdict`；`justice_sentences` active 数变化 |
| `npc` | `npc.spawn/despawn/stale`、`npc.callout.create/resolve` |
| `backup` | `backup.request` |
| `outbox` | 合成事件：`status=failed` / `stale` / `backlog` |
| `citation` / `report` / `case` / `evidence` / `bolo` / `warrant` | 对应 `action` 前缀 |
| `lookup` / `audit` | 敏感读；只保留动作与 actor，**丢弃 target/detail** |
| `player` | 在线人数变化（合成） |
| `resource` | 资源启动/停止/状态变化（合成） |
| `test` | `/agent test` 触发 |
| `security` | 未授权 `/agent` 尝试（合成） |
| 自定义 | 其他资源通过 `PushAgentEvent(type, data)` 推入 |

### 关键事件落盘

`duty/incident/arrest/sentence/npc/backup/outbox/resource/test/security` 会追加到
`logs/agent-events.jsonl`（单行 JSON）。路径解析顺序：

1. `<resource>/logs/agent-events.jsonl`（`GetResourcePath`，正常 checkout）；
2. `<server-root>/logs/custom-agent-ops-events.jsonl`（资源目录只读时）；
3. `SaveResourceFile` 回到资源内（仍只读时，文件大小受限）。

文件超过 `file_log_max_bytes`（默认 2 MiB）时轮转为 `.1`，更旧的归档被删除
（`file_log_keep`，默认 1）。`config.lua` 的 `file_log = false` 可完全关闭。

## 4. 导出

全部是 **server export**；没有 client 侧，也没有 net event。

```lua
-- 只读缓存快照；不查 DB，适合高频轮询
local snapshot = exports['custom-agent-ops']:GetAgentSnapshot()

-- sinceId 之后的事件，最多 200 条；sinceId 来自上一次的 next_id。
-- reset=true 表示资源重启过，游标失效，返回的是最新一段。
local page = exports['custom-agent-ops']:GetAgentEvents(cursor, 50)
cursor = page.next_id

-- 只有 server export 调用可用（GetInvokingResource 必须非 nil）。
-- 返回 event id；失败返回 false, error。
local id, err = exports['custom-agent-ops']:PushAgentEvent('incident', {
    label = 'agent observed a pursuit',
    note = 'custom-director',
})

-- 实时健康探测：会查 DB（SELECT 1）与 outbox 计数，按需调用
local health = exports['custom-agent-ops']:HealthSnapshot()
```

### 返回结构

`GetAgentEvents(sinceId, limit)`：

```json
{
  "schema_version": 1,
  "ok": true,
  "boot_id": "1761330000:123",
  "events": [],
  "count": 0,
  "next_id": 42,
  "dropped": 0,
  "reset": false
}
```

`HealthSnapshot()`：

```json
{
  "schema_version": 1,
  "ok": true,
  "boot_id": "1761330000:123",
  "sampled_at": 1761330000000,
  "healthy": true,
  "db": { "ok": true, "latency_ms": 2 },
  "resources": {
    "states": { "qb-core": "started", "oxmysql": "started", "custom-police": "started",
                "custom-director": "started", "custom-agent-client": "started",
                "custom-testing": "started" },
    "required": ["qb-core", "oxmysql", "custom-police"],
    "missing": [],
    "optional_down": []
  },
  "outbox": { "pending": 0, "failed": 0, "stale_pending": 0, "threshold": 20 },
  "old_pending": 0,
  "ring": { "capacity": 500, "count": 42, "last_id": 42, "dropped": 0 },
  "file_log": { "enabled": true, "mode": "io", "path": "...", "writes": 12,
                "failures": 0, "rotations": 0 }
}
```

`PushAgentEvent` 的安全约束：

- `type` 必须匹配 `^[a-z][a-z0-9_.-]{0,47}$`；
- `data` 必须是 table 或 nil；
- 只有 `GetInvokingResource()` 非 nil 的 server export 调用通过；
- 默认每秒 20 次（`external_push_per_second`，0 关闭）；
- 与审计事件共用同一个 500 条环和脱敏/截断管道。

## 5. 如何接入 custom-director / agent-client

`custom-agent-ops` 不修改 director。接入只需在 director 的只读路径加一次 export 调用：

```lua
-- custom-director/server/live_api.lua（示例，未在本资源内实现）
local function opsSnapshot()
    local ok, snapshot = pcall(function()
        return exports['custom-agent-ops']:GetAgentSnapshot()
    end)
    if not ok or type(snapshot) ~= 'table' then
        return nil, 'agent_ops_unavailable'
    end
    return snapshot
end
```

然后在 director 的 live HTTP 路由（如 `GET /agent/v1/live/ops`）返回 `opsSnapshot()`；
或在 `custom-agent-client` 的审计事件里调用 `PushAgentEvent('effect', {...})`，
让 agent 的效果执行也进入同一个事件时间线。

注意启动顺序：`custom-agent-ops` 在 `configs/modules/dev.cfg` 里 `ensure`，
排在其他业务资源之后；director 如果在 `onResourceStart` 阶段调用 export，必须
先判断 `GetResourceState('custom-agent-ops') == 'started'`，请求时调用则无需判断。

### Agent 使用方式

1. **看当前状态**：控制台 `/agent status`，或让 director 的只读工具返回
   `GetAgentSnapshot()`；只读缓存，不产生 DB 查询。
2. **增量看事件**：第一次 `GetAgentEvents(0, 100)`，之后用上次 `next_id` 作为
   `sinceId`；`reset=true` 时从返回的最新一段重新开始。
3. **定位故障**：`/agent health` 关注 `db.ok` / `db.latency_ms` / `missing` /
   `outbox.failed` / `old_pending`；`outbox` 的 `stale_pending` 超过 0 说明有
   pending 行超过 `outbox_stale_minutes`（默认 10 分钟）没有投递。
4. **看原始证据**：`/agent tail 50` 同时打印 `police_audit` 与 `police_outbox`
   最近 50 行；`detail` 截断 160 字符，不打印 outbox payload。
5. **跑套件**：确认 `custom-testing` 已启动（dev 环境默认在 `dev.cfg`），
   控制台 `/agent test <suite>`；它会复用 `/test run <suite>`，最终在
   `custom-testing` 内调用 `Test.run(suite)`。
6. **文件回溯**：`tail -f T-CityLite.base/resources/[custom]/custom-agent-ops/logs/agent-events.jsonl`；
   只包含关键事件，不是全量审计。

## 6. 配置

`config.lua`（全部有 dev 友好默认值）：

| 键 | 默认 | 说明 |
|---|---|---|
| `poll_audit_ms` | `2000` | `police_audit` 轮询间隔；`id > cursor LIMIT 100` |
| `poll_snapshot_ms` | `5000` | 计数/资源状态轮询间隔 |
| `audit_batch` | `100` | 单次 audit 批次，上限 100 |
| `file_log` | `true` | 是否写 JSONL |
| `file_log_path` | `logs/agent-events.jsonl` | 资源内相对路径 |
| `file_log_max_bytes` | `2097152` | 轮转阈值（2 MiB） |
| `file_log_keep` | `1` | 保留归档数 |
| `outbox_pending_warn` | `20` | backlog 告警阈值 |
| `outbox_stale_minutes` | `10` | pending 行"旧"的阈值 |
| `event_text_limit` | `160` | 字符串截断（UTF-8 字符） |
| `event_target_limit` | `64` | `target` 截断 |
| `event_max_keys` / `event_max_depth` | `20` / `3` | 事件 data 边界 |
| `external_push_per_second` | `20` | `PushAgentEvent` 限流 |

## 7. 安全与隐私

- **无客户端面**：`server_only 'yes'`，无 `client_scripts`，无 `RegisterNetEvent`，
  无 `TriggerClientEvent`，无 NUI/HTTP。
- **命令鉴权**：source 0 或 ACE `agent.ops`；资源转发的 console 命令被拒绝。
- **导出鉴权**：`PushAgentEvent` 要求 `GetInvokingResource()` 非 nil；只读导出不含 PII。
- **不记录密码**：`password/passwd/token/secret/authorization/api_key/license/credential`
  等键被丢弃；字符串里的 `token=...`、`password: ...` 被替换为 `[redacted]`。
- **不记录敏感读内容**：`.view` / `.detail` / `.chain` / `lookup.*` / `audit.view`
  只保留动作和 actor，丢弃 `target` / `detail`。
- **截断**：所有字符串按 UTF-8 字符截断，控制字符（含换行）先替换为空格，
  防止伪造日志行。
- **有界**：事件环 500、单次轮询 100、事件导出 200、命令输出 100、
  JSONL 2 MiB 轮转、外部推送限流。

## 8. 测试

```bash
cd T-CityLite.base
python3 -m pytest -q tests/architecture/test_agent_ops.py
python3 -m pytest -q tests/unit tests/architecture
luac5.4 -p resources/\[custom\]/custom-agent-ops/server/main.lua
```

`tests/architecture/test_agent_ops.py` 同时做静态契约和 Lua 运行时契约：

- manifest 只 server、依赖 qb-core/oxmysql/custom-police；
- 5 个命令、4 个 export、ACE / console-only 校验；
- 无 net event / client script / HTTP；
- 真实加载 `config.lua` + `server/main.lua` 验证 500 条环形上限、淘汰与 `dropped`、
  `GetAgentEvents` 游标与 200 条上限；
- 脱敏/UTF-8 截断、日志轮转与归档清理；
- 反向验证：无 ACE 玩家被拒、资源转发 console 被拒、direct call 不能 `PushAgentEvent`。

## 9. 已知边界

- 进程内事件环在资源重启后清空；持久证据在 `police_audit` / `police_outbox`，
  用 `/agent tail` 或 DB 查询回看。
- `GetAgentEvents` 的 `id` 只在一次资源生命周期内单调；跨重启用 `boot_id` 判断。
- 事件环是**观测**，不是执法审计：关键写操作仍以 `custom-police` 的
  `police_audit` 为唯一事实源。
- `custom-testing` 不在生产启动链；`/agent test` 在生产会明确返回
  `custom_testing_not_running`，不会静默成功。
