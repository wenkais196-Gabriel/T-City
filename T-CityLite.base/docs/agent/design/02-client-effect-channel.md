# 02 — 客户端效果通道（Effect Channel）v1 设计

- 状态：**Draft for build**；目标资源：`T-CityLite.base/resources/[custom]/custom-agent-client/`（新建，server + client）
- 通道版本 `1`（信封 `v:1`，只做加法）；Lua 5.4；无重依赖
- 上位约束：server 唯一权威、client 永远不可信、写不走 DB
- 关联：[ACTIONS.md](../ACTIONS.md)、[DIRECTOR.md](../DIRECTOR.md)、[03 工具面](03-tool-contract.md)

---

## 0. 结论

1. **新建 `custom-agent-client`**，不给 `custom-director` 加 `client_script`。director 保持 `server_only 'yes'`，
   效果通道是可独立启停/替换/审计的单元。
2. **单向发起**：只有 server 能发起，client 只能回 `ack`/`cancel`；没有"客户端请求执行"的入口。
3. **执行位置是动作属性**：6 个动作在 client 执行，`give_vehicle_keys` 在 **server 执行**（状态在服务端，
   client 事件只同步 HUD）。通道不是通用 `TriggerClientEvent` 转发器。
4. **ack 是遥测，不是事实**：服务端不因 ack 修改任何游戏状态；`Verify()` 只产出审计字段与 `unverified`。
5. **不用 `TriggerClientCallback`**：它按 `name` 索引全局表、ack 无 rid、ack 不校验 source，并发必串包（§3）。
6. 默认值：总开关关、20 次/分钟/玩家、4 个在飞、超时上限 10s、`teleport`/`give_vehicle_keys` 默认需审批。

---

## 1. 读代码得到的事实

| 事实 | 位置 |
|:---|:---|
| `TriggerClientCallback` 以 **name** 为键写全局表，`Await` 时再次按 name 取表 | `[qb]/qb-core/server/functions.lua:459-479` |
| ack 处理按 name 解析，**不校验 source / 不校验请求** | `[qb]/qb-core/server/events.lua:118-128` |
| client 端 ack 只回传 `name`，无 rid | `[qb]/qb-core/client/events.lua:237-243` |
| director 是 `server_only 'yes'`，已有 `SetHttpHandler`/`respond`/错误码/`agent_actions` 审计 | `custom-director/fxmanifest.lua`；`server/main.lua:1006-1131,1294-1301` |
| director 执行是**字面量 if/elseif**；HTTP 映射 `disabled→503`、`execution_failed→409` | `server/main.lua:417-425,1116-1131` |
| 钥匙权威在服务端，且服务端已主动推送 client 事件 | `custom-vehicles/server/compat.lua:82-137`；`client/main.lua:172` |
| 连 txAdmin 的传送都在 client 侧执行（`SetPedCoordsKeepVehicle`） | `[system]/monitor/resource/menu/client/cl_main_page.lua:145,194` |
| 已有 `promise.new()`+`Citizen.Await` 惯例；bucket 原生用法有先例 | `custom-quest/server/quest_security.lua:210-214`；`monitor/.../server/sv_player_modal.lua:25-31` |
| 手铐字段有两种写法（`handcuffed`/`ishandcuffed`） | `custom-security/server/security.lua:63` |

server 侧基础设施（HTTP、审批、审计）现成，缺的只是"server→单个 client 的可回执执行"。不改 qb-core。

---

## 2. 资源划分

| 维度 | 新建 `custom-agent-client`（选定） | director 加 client_script（否决） |
|:---|:---|:---|
| 权限隔离 | 审批/预算/策略代码不出 server | 策略阈值与审批逻辑随 client 包下发 |
| 可关停 | `stop` 只断表现层，审批/审计照常 | 停通道会连带停审批（无法分级止血） |
| 可替换 | 整体换 NUI/ox_lib 版不碰 director | 换执行器要动审批资源 |
| 失败域 | client 崩溃只影响表现 | client 崩溃可能拖累 HTTP handler |
| 部署顺序 | 先于 director；director **不声明** dependency，运行时探测 | 声明依赖会导致缺资源时 director 起不来，无法降级 |

```text
custom-agent-client/  fxmanifest.lua | shared/actions.lua（纯数据：动作名/ANIM_DICTS/MAP_BOUNDS/上限）
  server/config.lua（convar） | server/actions.lua（Normalize/CheckState/TimeoutFor/Cancellable/Verify/RunServer）
  server/audit.lua（agent_effect_log + console） | server/main.lua（pending/限流/clientExec/ack/exports）
  client/main.lua（握手/去重/dispatch/ack/cancel） | client/actions.lua（6 个 handler 字面量表）
```

```lua
-- fxmanifest.lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City'
description 'Agent effect channel v1: server-issued, per-player client effects with ack + audit'
version '0.1.0'
shared_scripts { 'shared/actions.lua' }
server_scripts { 'server/config.lua', 'server/actions.lua', 'server/audit.lua', 'server/main.lua' }
client_scripts { 'client/actions.lua', 'client/main.lua' }
dependencies { 'qb-core' }   -- custom-vehicles 仅 give_vehicle_keys 时懒检查
```

```cfg
setr agent_effect_enabled 0          # 总开关，实时生效
setr agent_effect_allow_teleport 0   # teleport 二次开关
setr agent_effect_allow_keys 0       # give_vehicle_keys 二次开关
setr agent_effect_rate_per_min 20
setr agent_effect_burst 5
setr agent_effect_max_inflight 4
setr agent_effect_max_timeout_ms 10000
```

`configs/modules/custom.cfg` 在 `custom-logs` 之后加 `ensure custom-agent-client`。
`shared/actions.lua` 只放常量——校验函数必须留在 server，否则会被误当成校验层。

---

## 3. 为什么不能用 `QBCore.Functions.TriggerClientCallback`

```lua
-- [qb]/qb-core/server/functions.lua:459-479（节选）
QBCore.ClientCallbacks[name] = { callback = cb, promise = promise.new() }
TriggerClientEvent('QBCore:Client:TriggerClientCallback', source, name, table.unpack(args))
Citizen.Await(QBCore.ClientCallbacks[name].promise)   -- 再次按 name 取，已被别人覆盖
-- [qb]/qb-core/server/events.lua:118-128
RegisterNetEvent('QBCore:Server:TriggerClientCallback', function(name, ...)
    if QBCore.ClientCallbacks[name] then
        QBCore.ClientCallbacks[name].promise:resolve(...)   -- 无 source 校验
        QBCore.ClientCallbacks[name] = nil
    end
end)
-- [qb]/qb-core/client/events.lua:237-243：ack 只带 name
QBCore.ClientCallbacks[name](function(...) TriggerServerEvent('QBCore:Server:TriggerClientCallback', name, ...) end, ...)
```

**串包（可复现）**：`t0` A(src=5) 写 `fx`；`t1` B(src=7) 覆盖 `fx`（P_A 丢失）；`t2` A `Await` 拿到的是 P_B；
`t3` src=5 的 ack 解析到 P_B → **B 收到 A 的结果**；`t4` src=7 的 ack 因表已 nil → 静默丢弃 → A **永久挂起**
（无超时）。同玩家并发同 name 同样串。

**伪造 ack**：`QBCore:Server:TriggerClientCallback` 是普通 net event，任何玩家可
`TriggerServerEvent('QBCore:Server:TriggerClientCallback','fx',false)` → 解析或抢先置空别人的回调。

| 能力 | TriggerClientCallback | 本设计 |
|:---|:---|:---|
| 归属 | `name` | `(src, request_id)` |
| 超时 / 取消 | 无 / 无 | 每动作默认 + 全局上限 / `Cancel()` |
| 并发 | 同 name 覆盖 | 每玩家 4 个在飞、独立 rid |
| 参数 | `...` 任意 | 字段白名单 + 上限，未声明字段拒绝 |
| ack 校验 | 无 | session + rid + 未结算 + 类型 |
| 断线清理 | 无（promise 泄漏） | `playerDropped` 全量 settle |

不修 qb-core（影响 15+ 老脚本），只在自有通道实现 `pending[src][request_id]`。

---

## 4. RPC 契约

| 事件 | 方向 | 载荷 | 信任 |
|:---|:---|:---|:---|
| `tcity:agent:ready` | client→server | 空 | 唯一上行入口，不携带请求意图 |
| `tcity:agent:hello` | server→client | `{v, session}` | session 仅存 client 内存 |
| `tcity:agent:exec` | server→client | 见下 | server 签发 |
| `tcity:agent:ack` | client→server | 见下 | **不可信**，只作遥测 |
| `tcity:agent:cancel` | server→client | `{v, session, request_id}` | server 签发 |

```json
{"v":1,"request_id":"9f2c41a7-17-3b0e","session":"9f2c41a7d1e04b22","action":"play_anim",
 "timeout_ms":2500,"issued_at":1761512345,
 "payload":{"dict":"amb@world_human_smoking@male@male_a@idle_a","clip":"idle_a","duration_ms":6000}}
{"v":1,"request_id":"9f2c41a7-17-3b0e","session":"9f2c41a7d1e04b22","status":"failed",
 "error_code":"anim_load_timeout","detail":{"message":"dict not loaded in 1000ms"}}
```

`status ∈ {ok,rejected,failed,cancelled}`：`rejected` = 本地校验未过（无副作用）、`failed` = 执行中失败
（可能有部分副作用）、`cancelled` = 收到 cancel 后中止。每个 rid **只 settle 一次**（删 timer + 写审计）：

```text
pending ─ack ok & Verify≠false→ ok        ├─ack rejected/failed→ client_*
        ├ack ok & Verify==false→ unverified├─ack cancelled / Cancel()→ cancelled
        └playerDropped / onResourceStop → player_offline | executor_stopped
```

### 4.1 server 骨架（`server/main.lua`，完整约 220 行）

```lua
local Actions, Audit = EffectActions, EffectAudit
local sessions, pending, inflight, AgentClient = {}, {}, {}, {}   -- pending[src][rid] = entry
local function mkerr(code, msg, detail) return { code = code, message = msg, detail = detail } end

local function settle(src, rid, ok, result, e)     -- 幂等；ok/unverified/timeout/cancelled/... 全走这里
    local entry = pending[src] and pending[src][rid]
    if not entry or entry.settled then return false end
    entry.settled, pending[src][rid] = true, nil
    inflight[src] = math.max(0, (inflight[src] or 1) - 1)
    if entry.timer then ClearTimeout(entry.timer) end
    entry.promise:resolve({ ok = ok, result = result, err = e })
    Audit.record(entry, ok, e)                     -- 审计失败只告警，不改动作结果
    return true
end

RegisterNetEvent('tcity:agent:ready', function()   -- 回 hello；session 每玩家一个，client 重启沿用
    local src, s = source, sessions[source]
    if not s then
        s = { token = ('%08x%08x'):format(math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)), seq = 0 }
        sessions[src] = s
    end
    TriggerClientEvent('tcity:agent:hello', src, { v = 1, session = s.token })
end)

---@param src integer   玩家 server id，只能由 server 侧解析，绝不来自 payload
---@param opts table|nil  { agent_id = 'director.rules' }
---@return boolean ok, table|nil result, table|nil err
function clientExec(src, action, payload, timeoutMs, opts)
    local cfg, agentId = EffectConfig(), opts and opts.agent_id
    if not cfg.enabled then return false, nil, mkerr('executor_disabled', 'channel disabled') end
    if type(src) ~= 'number' or src <= 0 or GetPlayerPed(src) == 0 then
        return false, nil, mkerr('player_offline', 'player is not online') end
    if not coroutine.isyieldable() then return false, nil, mkerr('not_yieldable', 'need a coroutine') end

    local normalized, nerr = Actions.Normalize(action, payload, cfg)      -- 白名单/字段/上限
    if not normalized then return false, nil, nerr end
    local gate = Actions.CheckState(src, action, normalized, QBCore)      -- 死亡/手铐/载具/bucket
        or rateGate(src, action, cfg, agentId)                            -- §8
    if gate then return false, nil, gate end
    if (inflight[src] or 0) >= cfg.max_inflight then
        return false, nil, mkerr('too_many_inflight', 'too many in-flight effects') end
    if Actions.ExecutionSite(action) == 'server' then                     -- give_vehicle_keys
        return Actions.RunServer(src, action, normalized, cfg, agentId) end

    local session = sessions[src]
    if not session then return false, nil, mkerr('handshake_missing', 'client has not sent ready') end
    session.seq = session.seq + 1
    local rid = ('%s-%d-%04x'):format(session.token:sub(1, 8), session.seq, math.random(0, 0xffff))
    local timeout = math.min(timeoutMs or Actions.TimeoutFor(action, normalized), cfg.max_timeout_ms)
    pending[src] = pending[src] or {}
    local entry = { src = src, requestId = rid, action = action, payload = normalized,
        session = session.token, startedAt = GetGameTimer(), agentId = agentId or 'unknown',
        promise = promise.new() }
    pending[src][rid] = entry
    inflight[src] = (inflight[src] or 0) + 1

    entry.timer = SetTimeout(timeout, function()
        if entry.settled then return end
        if Actions.Cancellable(action) then         -- best effort 清理，仍按失败结算
            TriggerClientEvent('tcity:agent:cancel', src, { v = 1, session = session.token, request_id = rid }) end
        settle(src, rid, false, nil, mkerr('timeout', ('no ack within %dms'):format(timeout)))
    end)
    TriggerClientEvent('tcity:agent:exec', src, { v = 1, request_id = rid, session = session.token,
        action = action, timeout_ms = timeout, issued_at = os.time(), payload = normalized })

    local r = Citizen.Await(entry.promise)
    return r.ok, r.result, r.err
end

local ACK_FAIL = { rejected = 'client_rejected', cancelled = 'cancelled', failed = 'client_failed' }
RegisterNetEvent('tcity:agent:ack', function(ack)
    local src, rid = source, type(ack) == 'table' and ack.request_id
    local entry = type(rid) == 'string' and pending[src] and pending[src][rid]
    if not entry or entry.settled or ack.session ~= entry.session then return end   -- 伪造/迟到丢弃
    if ack.status == 'ok' then
        if Actions.Verify(entry.action, entry.payload, ack.detail, src) == false then
            return settle(src, rid, false, ack.detail, mkerr('unverified', 'post-condition failed')) end
        return settle(src, rid, true, ack.detail, nil)
    end
    settle(src, rid, false, nil, mkerr(tostring(ack.error_code or ACK_FAIL[ack.status] or 'client_failed'),
        tostring(ack.detail and ack.detail.message or 'client error'), ack.detail))
end)

AddEventHandler('playerDropped', function()
    local src = source
    for rid in pairs(pending[src] or {}) do settle(src, rid, false, nil, mkerr('player_offline', 'dropped')) end
    pending[src], inflight[src], sessions[src] = nil, nil, nil
end)
AddEventHandler('onResourceStop', function(name)   -- 停资源时把在飞请求全结算，避免调用方挂死
    if name ~= GetCurrentResourceName() then return end
    for src in pairs(pending) do
        for rid in pairs(pending[src]) do settle(src, rid, false, nil, mkerr('executor_stopped', 'stopped')) end
    end
end)

---@return boolean accepted   false = 未知 rid / 已结束 / 不可取消
function AgentClient.Cancel(src, rid)
    local entry = pending[src] and pending[src][rid]
    if not entry or entry.settled or not Actions.Cancellable(entry.action) then return false end
    TriggerClientEvent('tcity:agent:cancel', src, { v = 1, session = entry.session, request_id = rid })
    return settle(src, rid, false, nil, mkerr('cancelled', 'cancel requested by server'))
end

exports('Execute', clientExec)
exports('Cancel', AgentClient.Cancel)
exports('Ping', function() return { ok = true, version = 1, enabled = EffectConfig().enabled } end)
```

`clientExec` 必须在协程内调用（HTTP handler / `CreateThread` / 事件回调都满足）；主线程直调返回
`not_yieldable` 而不是崩溃。`handshake_missing`（client 尚未 `ready`）按可重试处理，客户端加载完成后重试一次。
### 4.2 client 骨架（`client/main.lua`）

```lua
local Handlers = EffectHandlers            -- client/actions.lua，字面量表
local session, current, seen, order, MAX_SEEN = nil, {}, {}, {}, 64

RegisterNetEvent('tcity:agent:hello', function(msg)
    if type(msg) == 'table' and msg.v == 1 and type(msg.session) == 'string' then session = msg.session end
end)

RegisterNetEvent('tcity:agent:exec', function(msg)
    if type(msg) ~= 'table' or msg.v ~= 1 or msg.session ~= session then return end   -- 未握手/会话不符
    if seen[msg.request_id] then return end                                          -- 重放
    seen[msg.request_id] = true; order[#order + 1] = msg.request_id
    if #order > MAX_SEEN then seen[table.remove(order, 1)] = nil end
    local handler, rid, t0 = Handlers[msg.action], msg.request_id, GetGameTimer()   -- 查表，不转发事件
    if not handler then
        return TriggerServerEvent('tcity:agent:ack',
            { v = 1, request_id = rid, session = session, status = 'rejected', error_code = 'action_not_allowed' })
    end
    local ok, status, errCode, detail = pcall(handler, msg.payload or {}, msg.timeout_ms or 2000)
    if not ok then
        return TriggerServerEvent('tcity:agent:ack', { v = 1, request_id = rid, session = session,
            status = 'failed', error_code = 'client_error', detail = { message = tostring(status):sub(1, 200) } })
    end
    detail = detail or {}
    detail.latency_ms = GetGameTimer() - t0
    if type(detail.on_cancel) == 'function' then current[rid] = detail.on_cancel end
    TriggerServerEvent('tcity:agent:ack', { v = 1, request_id = rid, session = session,
        status = status or 'failed', error_code = errCode, detail = detail })
end)

RegisterNetEvent('tcity:agent:cancel', function(msg)
    if type(msg) ~= 'table' or msg.session ~= session then return end
    local onCancel = current[msg.request_id]; current[msg.request_id] = nil
    if onCancel then pcall(onCancel) end
    TriggerServerEvent('tcity:agent:ack',
        { v = 1, request_id = msg.request_id, session = session, status = 'cancelled' })
end)

CreateThread(function() Wait(1000); TriggerServerEvent('tcity:agent:ready') end)   -- client 重启也重发
```

server 不轮换 session（client 资源重启不影响在飞请求；换会话只发生在玩家断开）。

### 4.3 错误码

| code | 触发 | 可重试 |
|:---|:---|:---|
| `executor_disabled` / `executor_unavailable` | 总开关关 / 资源未启动 | 后者是 |
| `player_offline` / `handshake_missing` | src 无效或已断线 / client 未 ready | 否 / 是 |
| `action_not_allowed` / `invalid_params` / `text_too_long` / `anim_not_whitelisted` | 白名单或参数校验失败 | 否 |
| `state_conflict` | 死亡/手铐/载具等前置不满足 | 是（换时机） |
| `rate_limited` / `too_many_inflight` / `server_busy` | 限流（detail 带 `retry_after_ms`） | 是 |
| `timeout` | 客户端未回执 | 是（幂等动作） |
| `client_rejected` / `client_failed` | 本地校验拒绝 / pcall 异常 | 否 / 一次 |
| `unverified` | ack ok 但后置条件不成立 | 否（审计） |
| `dependency_unavailable` | `custom-vehicles` 未启动 | 是 |

### 4.4 边界行为

- **同玩家并发**：独立 rid，上限 4；不同动作可并行。需要严格顺序的调用方自己 `Await`（不要并发两次 `teleport`）。
- **重复/迟到 ack**：`settled` 为真直接丢弃，不报错、不计数（防伪造流量放大日志）。
- **玩家中途退出**：`playerDropped` 全量 settle 并清 `session/inflight`，src 复用安全。
- **客户端 pcall 失败**：`client_error` + 截断 200 字符，**不自动重试**（副作用不确定）。
- **客户端不回执**：timer settle `timeout` + best-effort cancel，**不重发**。
- **rid**：`<session8>-<seq>-<rand4>`，同会话内不复用。

---

## 5. 动作白名单 v1

| action | 执行位置 | risk | 可取消 | 默认超时 | ack 时机 |
|:---|:---|:---|:---|:---|:---|
| `notify` | client | L1 | 否 | 1500ms | `Notify()` 返回后 |
| `play_anim` | client | L1 | 是 | 2500ms | `IsEntityPlayingAnim` 为真后 |
| `clear_anim` | client | L1 | 否 | 1000ms | `ClearPedTasks` 后（无副作用也 ok） |
| `teleport` | client | L2 | 否 | 4000ms | 坐标 + 碰撞校验后 |
| `screen_effect` | client | L1 | 是 | 2000ms | 特效开始后 |
| `open_text_ui` | client | L1 | 是 | 2000ms | 开始绘制后 |
| `give_vehicle_keys` | **server** | L3 | 否 | 本地 | `GiveKeys` 返回后 |

风险等级对齐 [03 §5](03-tool-contract.md)：L1 自动、L2 默认审批、L3/L4 永远 `pending_approval`。
L2/L3 由 director 审批；executor 只用 `allow_teleport`/`allow_keys` 做二次开关。

**`notify`** — `{"text":"导演：今晚码头有动作","kind":"primary","duration_ms":5000}`
校验 UTF-8 1..300、禁 C0 控制符（除 `\t\n\r`）、`kind ∈ {info,success,warning,error,primary}`、`duration_ms` 1000..10000；
client 调 `QBCore.Functions.Notify(text, kind, duration_ms)`，失败 `client_failed`。
director 现有服务端直发 `notify` v1 保持不动；通道版用于需要排序/ack 证据的场景。

**`play_anim`** — `{"dict":"amb@world_human_smoking@male@male_a@idle_a","clip":"idle_a","duration_ms":6000,"blend_in":0.2,"playback_rate":1.0,"flags":49}`
校验 `dict` 必须命中 `ANIM_DICTS`（**禁止自由字符串**）、`clip` `^[%w_@%-]+$` ≤64、`duration_ms` 500..30000 **必填**（不许无限循环）、
`blend_in/out` 0..1、`playback_rate` 0.1..2.0、`flags` 0..511。执行 `RequestAnimDict` → 轮询 `HasAnimDictLoaded` ≤1000ms →
`TaskPlayAnim` → 250ms 后 `IsEntityPlayingAnim` 校验 → 到点自动 `ClearPedTasks`。失败 `anim_load_timeout`/`anim_not_found`/`client_error`；
死亡/手铐/载具内 → `state_conflict`。

**`clear_anim`** — `{}`；无参数，多余字段拒绝。执行 `ClearPedTasks` + `ClearPedSecondaryTask` + 清本资源计时器。
总是 `ok`（幂等），因此是 `play_anim` 超时后的标准收尾。

**`teleport`** — `{"x":-1023.5,"y":-2748.2,"z":12.9,"heading":180.0,"keep_vehicle":true,"snap_to_ground":true,"reason":"director scene: docks"}`
校验 `x/y/z` 有限数（拒 NaN/Inf）且 `MAP_BOUNDS = x[-4000,4500] y[-4000,8000] z[-200,2000]`、`heading` 0..360、
`reason` 1..128。执行（client）：`snap_to_ground` → `GetGroundZFor_3dCoord` 吸附；车内且 `keep_vehicle` → `SetPedCoordsKeepVehicle`，
否则 `SetEntityCoords`；`SetEntityHeading`；`RequestCollisionAtCoord` ≤1000ms；250ms 后核对 `#(coords-target) < 5.0`。
服务端后置：ack 后 `GetEntityCoords(GetPlayerPed(src))` 与目标差 <10，否则 `unverified`（服务端读的是客户端上报位置，
只能发现诚实失败，不能证明位置）。失败 `in_vehicle`（`keep_vehicle=false` 且人在车里，绝不静默拽下车）/`player_dead`/
`player_cuffed`/`landing_failed`/`bucket_restricted`。

**`screen_effect`** — `{"effect":"blur","duration_ms":1500,"intensity":0.6}`
校验 `effect ∈ {blur,fade_out,fade_in}`、`duration_ms` 200..10000、`intensity` 0..1（仅 blur）。执行
`TriggerScreenblurFadeIn`/`DoScreenFadeOut`，到期自动反向恢复。同玩家只允许一个屏幕特效，新请求先 cancel 旧的（两者都写审计）。
取消 `TriggerScreenblurFadeOut`/`DoScreenFadeIn`；`onResourceStop`/死亡时务必恢复，防永久黑屏。

**`open_text_ui`** — `{"title":"任务提示","body":"去码头找老陈，别带枪。","duration_ms":8000,"position":"center"}`
校验 `title` ≤80、`body` 1..1000 无控制符、`duration_ms` 1000..15000、`position ∈ {top,center,bottom}`。执行原生 `DrawText`
逐帧绘制，**无 NUI、无焦点、无按键/鼠标回调**（玩家无法借此向 server 发任何东西）。同玩家新请求替换旧的。v2 若上 NUI：
必须 HTML 转义 + `textContent`，agent 提供的 HTML/URL 一律拒绝。

**`give_vehicle_keys`** — `{"plate":"ABC123","vehicle_net_id":1234,"key_type":"shared"}`
校验 `plate` `^[A-Za-z0-9 ]{1,8}$` 转大写、`vehicle_net_id` 可选正整数、`key_type ∈ {owner,shared}` 默认 `shared`。
前置：玩家在线；`GetResourceState('custom-vehicles')=='started'` 否则 `dependency_unavailable`；给定 netId 时实体必须存在且
`GetVehicleNumberPlateText` 等于 `plate`，否则 `vehicle_not_found`/`plate_mismatch`。执行
`exports['custom-vehicles']:GiveKeys(src, plate)`（`compat.lua:82`，内部已推 `custom-vehicles:client:keysUpdated`）。
失败 `keys_rejected`。**状态变更在 server 完成，client 事件只同步 HUD，不走 RPC。**

---

## 6. 安全模型

| 主体 | 能力 | 权威性 |
|:---|:---|:---|
| server 进程/其它 server 资源 | 调用 export、读写 DB | 可信（不防恶意 server 资源） |
| agent（HTTP，token + `X-Agent-Id`） | 只能 propose/approve | 不可信输入，必须过 policy/审批 |
| client / 玩家 | 读全部 client 代码、本地 `TriggerEvent` 任意事件、伪造 ack | **完全不可信**，只能执行表现 |

不变量（review checklist）：

1. **server 发起、server 判定**：server 只注册 `tcity:agent:ack` 的接收端；`exec` 在 server 端没有接收端。
2. **`source` 永不来自参数**：`src` 由 director 从 `citizenid` 解析；payload 出现 `source/src/player/event/action`
   等保留键 → 显式 `invalid_params`（不静默丢）。
3. **不做通用转发**：`Handlers`/`Actions` 均为字面量表；禁止 `TriggerClientEvent(payload.event, ...)`、
   动态 `TriggerEvent(name, ...)`、`loadstring`/`load(...)`。
4. **未声明字段拒绝**：每动作字段白名单，多一个就 `invalid_params`。
5. **ack 不可信**：ack 只决定审计行与返回值；所有服务端状态变更都在 ack 之前完成。
6. **nonce 的真实作用**：`session` + 未见 rid 只挡"不知道协议的脚本误触发 + 重放"。作弊者可 dump 内存拿到 session，
   所以 **nonce 不是安全边界**；边界是"没有 pending 就没有副作用"。
7. **失败即失败**：不允许"executor 不可用 → 静默成功"。
8. **审计不可省**：每次 dispatch 都有终态行，不允许只有成功才写。

**玩家能否伪造 `tcity:agent:exec`？** 不能对别人发（client 无 `TriggerClientEvent`），但**能对自己本地触发**
（任意 client 脚本/作弊菜单 `TriggerEvent('tcity:agent:exec', {...})` 会命中本地 handler）。因此 client 侧
session/rid/白名单只是"防误触发、防崩溃"；伪造 exec 不产生任何服务端副作用；伪造的 ack 匹配不上 pending 就被丢弃。
**这也是 `give_vehicle_keys` 必须在 server 执行的原因**：若靠 client ack 再发钥匙，玩家伪造一个 ok 就白拿钥匙。

---

## 7. OneSync 细节

| 主题 | 结论 |
|:---|:---|
| 传送位置 | **client 执行**：`NetworkRequestControlOfEntity` 是 client-only；OneSync 下玩家 ped 位置以拥有者客户端为准，server 侧 `SetEntityCoords` 会被纠正。仓库内 txAdmin 也在 client 侧传送（`cl_main_page.lua:194`） |
| 载具内 | `keep_vehicle=true`（默认）→ `SetPedCoordsKeepVehicle`；`false` 且 `IsPedInAnyVehicle` → `in_vehicle` 拒绝 |
| 死亡/手铐 | `IsEntityDead(GetPlayerPed(src))` 或 `metadata.isdead` → `player_dead`；`metadata.handcuffed or metadata.ishandcuffed` → `player_cuffed`。`notify` 不受限，其余拒绝 |
| bucket | teleport 保持 `GetPlayerRoutingBucket(src)`；坐标是 bucket 内坐标，跨 bucket 会传进空副本。v1 不实现 `target_bucket`，`bucket≠0` 且未显式允许 → `bucket_restricted` |
| 实体存在性 | `GetPlayerPed(src)==0` → `player_offline`；netId 取车时校验实体仍在 |
| 流式加载 | 传送后 `RequestCollisionAtCoord`，ack 带 `collision_loaded`；未加载不判失败（会短暂下坠） |
| 位置可信度 | 传送后的 `GetEntityCoords` 是客户端上报值；**严禁**用它做进入区域/领奖判定 |

---

## 8. 限流与审计

| 层 | 默认 | 超限 |
|:---|:---|:---|
| 每玩家令牌桶 | 20/分钟，burst 5 | `rate_limited` + `detail.retry_after_ms` |
| 每玩家在飞 | 4 | `too_many_inflight` |
| 每 agent 令牌桶 | 120/分钟（`agent_id` 由 director 传） | `rate_limited` |
| 全局在飞 | 200 | `server_busy` |

动作冷却（同玩家同动作）：`teleport` 3000ms、`give_vehicle_keys` 2000ms、`screen_effect`/`open_text_ui` 1000ms、
`play_anim`/`notify` 500ms、`clear_anim` 0。与 03 的 facade 限流（effect 2/min）**叠加**：后者约束 agent 调用频率，
本层约束单个玩家的表现频率。限流是滥用防护，不是安全边界。

```sql
-- migrations/v2.4_agent_effect_channel.sql
CREATE TABLE IF NOT EXISTS agent_effect_log (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  request_id CHAR(32) NOT NULL,
  agent_id VARCHAR(64) NOT NULL,
  action VARCHAR(32) NOT NULL,
  citizenid VARCHAR(11) NULL,
  source INT NOT NULL,
  session CHAR(16) NOT NULL,
  status ENUM('ok','rejected','failed','timeout','cancelled','aborted') NOT NULL,
  error_code VARCHAR(64) NULL,
  detail JSON NULL,                -- 归一化参数摘要 + client detail；不含 token/license
  latency_ms INT NULL,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  UNIQUE KEY uk_request (request_id),
  KEY idx_player_time (citizenid, created_at),
  KEY idx_agent_time (agent_id, created_at)
);
```

```text
[agent-effect] agent=director.rules action=play_anim src=12 player=ABC12345 rid=9f2c41a7-17-3b0e status=ok 212ms
[agent-effect] agent=director.rules action=teleport  src=12 player=ABC12345 rid=... status=timeout 4000ms
```

审计插入失败不改变动作结果，但必须 `[agent-effect] AUDIT FAILED` 告警；`agent_events` outbox 由 director 统一写，
executor 不双写。

---

## 9. 与 custom-director 集成

用 **export**（不是 event）：event 是全局广播面，无法区分调用者；export 有明确调用点与 `pcall` 边界。

```lua
---@param opts table|nil  { timeout_ms=3000, agent_id='director.rules' }
---@return boolean ok, table|nil result, table|nil err
exports['custom-agent-client']:Execute(src, action, payload, opts)
exports['custom-agent-client']:Cancel(src, request_id)
exports['custom-agent-client']:Ping()   -- {ok,version,enabled,pending}
```

```lua
-- 新增 custom-director/server/effects.lua
local EXECUTOR = 'custom-agent-client'
local function executorExecute(src, action, payload, timeoutMs, agentId)
    if GetResourceState(EXECUTOR) ~= 'started' then
        return false, nil, { code = 'executor_unavailable', message = 'custom-agent-client is not started' }
    end
    local ok, rOk, result, rErr = pcall(function()
        return exports[EXECUTOR]:Execute(src, action, payload, { timeout_ms = timeoutMs, agent_id = agentId })
    end)
    if not ok then return false, nil, { code = 'executor_api_mismatch', message = tostring(rOk):sub(1, 160) } end
    return rOk, result, rErr
end
```

- **每次调用现探测，不缓存**：executor 后启动也能立刻恢复。
- `executeAction` 加字面量分支（对齐 `server/main.lua:417-425`）；`src` 用现有 `getPlayerByCitizenId` + `playerSource`
  解析（`server/main.lua:236-247`），**不读 `params.source`**。
- 动作名映射（工具名以 `tools/agent_tools.json` 为准）：`send_notify→notify→notify`；
  `teleport_player→teleport_player→teleport`；03 M1/M2 规划项（`play_anim`/`screen_effect`/`open_text_ui`）同名；
  `grant_vehicle_keys→give_vehicle_keys→give_vehicle_keys`。

失败降级（**绝不静默成功**）：

| 场景 | director 返回 | HTTP |
|:---|:---|:---|
| executor 未启动 | `executor_unavailable` | 503（`httpStatusForResult` 新增映射） |
| 通道被关 | `executor_disabled` | 503 |
| `timeout` / `rate_limited` | `execution_failed` + `result.executor_code` | 429（新增映射） |
| 其它执行失败 | `execution_failed` + `result.executor_code` | 409（沿用） |
| `custom-vehicles` 缺失 | `dependency_unavailable` | 503 |

`result` 固定字段：`{executor_code, executor_detail, request_id, latency_ms}`，agent 据此判断是否重试；
失败时 `agent_actions` 记 `failed`，不写 `executed`。

---

## 10. 不做什么（反模式）

1. **不做通用事件转发器**：`TriggerClientEvent(payload.event, ...)` 或查表之外的任何分发。
2. **不做 client→server 的"执行请求"**：那会把权限模型翻过来。
3. **不把服务端权威动作搬进 client**：钥匙、钱、任务、job、bucket 一律 server 侧。
4. **不以 ack 作为状态依据**：除审计与返回值外不写任何状态。
5. **不自动重试**：表现层重试会双份动画/通知；重试由 director/agent 用幂等键决定。
6. **不做自由动画字符串**：字典白名单 + clip 字符集限制，否则等于开放"加载任意资源"。
7. **不做无限动画/持续特效**：所有时长有上限，防止永久卡住或黑屏。
8. **不做 NUI 输入、不抢焦点**：v1 只读 DrawText；上 NUI 先过 HTML 转义评审。
9. **不在 payload 里传玩家标识**：`source/citizenid` 只能来自服务端解析。
10. **不改 qb-core**，也不 monkey-patch `TriggerClientCallback`。
11. **不做跨 bucket 自动切换**：bucket 是玩法状态，必须显式授权。
12. **白名单之外没有 fallback**（不存在 `default → notify`）。

---

## 11. 交付任务清单

依赖顺序 **A → B → C → D → E → F → G**；每项都能在本地 FXServer + 一个真实客户端验证。

**A 骨架（无行为）**
- [ ] **A1** 建 `custom-agent-client/{fxmanifest,shared/actions,server/config}` — 验收：`Ping()` 返回 `{ok=true,version=1,enabled=false}`。
- [ ] **A2** `shared/actions.lua` 写 7 个动作、`ANIM_DICTS`（≥5 条，需真机确认存在）、`MAP_BOUNDS`、上限 — 验收：`tests/agent/test_effect_actions.lua` 纯 Lua 断言表结构。

**B RPC 核心**
- [ ] **B1** `server/main.lua`：`ready/settle/clientExec/ack/playerDropped/onResourceStop` — 验收：无客户端时 `clientExec` 在 `timeout_ms+200ms` 内返回 `timeout`（不 hang）。
- [ ] **B2** `client/main.lua`：hello/ready/exec/cancel/去重/pcall — 验收：F8 触发 `TriggerEvent('tcity:agent:exec',{v=1,session='x'})` 被丢弃，server 无审计行。
- [ ] **B3** `exports('Execute'/'Cancel'/'Ping')` — 验收：console 调试命令可列 pending。

**C 动作（按风险递增）**
- [ ] **C1** `notify` + `clear_anim` — 验收：生效且审计 `ok`；多余字段 → `invalid_params`。
- [ ] **C2** `play_anim` — 验收：白名单外 dict → `anim_not_whitelisted` 且客户端零副作用；假 clip → `anim_not_found`。
- [ ] **C3** `open_text_ui` + `screen_effect` — 验收：`fade_out` 后立刻 `restart custom-agent-client`，屏幕恢复正常。
- [ ] **C4** `teleport` — 验收：车内且 `keep_vehicle=false` → `in_vehicle`；越界 → `invalid_params`；`bucket≠0` → `bucket_restricted`；成功后坐标差 <10。
- [ ] **C5** `give_vehicle_keys` — 验收：`custom-vehicles` 停止时 `dependency_unavailable`；netId 与 plate 不符 → `plate_mismatch`；成功后客户端收到 `keysUpdated`。

**D 限流与审计**
- [ ] **D1** 令牌桶 + 冷却 + 在飞/全局上限 — 验收：连发 30 次 `notify`，前 5 次 ok，其后 `rate_limited` 且 `retry_after_ms>0`。
- [ ] **D2** migration + `server/audit.lua` — 验收：`GROUP BY status` 覆盖 ok/timeout/rejected；`request_id` 唯一；timeout 也有行。
- [ ] **D3** console 摘要 — 验收：每次请求恰好一行 `[agent-effect]`。

**E 安全回归**
- [ ] **E1** 伪造 ack（错误 session / 真实 rid） — 验收：原请求照常 `timeout`，无 ok 行。
- [ ] **E2** 本地伪造 exec（带正确 session） — 验收：只有表现，无审计行、无状态变更。
- [ ] **E3** 保留字段注入 `source/src/event` — 验收：`invalid_params`，不进任何 handler。
- [ ] **E4** executor/director 交叉重启 — 验收：director 返回 `executor_unavailable`；重启 director 不影响在飞请求。

**F director 集成**
- [ ] **F1** `custom-director/server/effects.lua`（§9 helper）
- [ ] **F2** `executeAction` 增加 6 个 client 动作 + 1 个 server 动作（`src` 由 citizenid 解析）
- [ ] **F3** `policy.lua` 动作条目与风险（`teleport` L2、`give_vehicle_keys` L3 需审批）
- [ ] **F4** `httpStatusForResult` 增加 `executor_unavailable→503`、`rate_limited→429` — 验收：返回 `code/result.executor_code` 与 §9 表一致。
- [ ] **F5** `configs/modules/custom.cfg` 加 `ensure custom-agent-client` — 验收：冷启动后首次调用即成功。

**G 文档与总验收**
- [ ] **G1** 本文与 `docs/agent/ACTIONS.md` 交叉链接（新增动作矩阵一节）
- [ ] **G2** 验收脚本（console 命令或 `tcity-e2e` 场景）跑通下列 8 条

### 验收标准（DoD）

1. 同玩家 4 个不同动作并发 → 各自拿到自己的结果，审计 4 行、rid 互异。
2. 同玩家第 5 个并发 → `too_many_inflight`，前 4 个不受影响。
3. 客户端 3s 不回执 → `timeout`，总耗时 ≤ `timeout_ms+200ms`，审计 `status=timeout`。
4. 请求中途断线 → 无挂起协程、无 pending 残留（`Ping().pending == 0`）。
5. 伪造 ack / 伪造 exec / 保留字段注入按 §6 处理，无状态变更。
6. `stop custom-agent-client` → director 返回 `executor_unavailable`（503），`agent_actions` 无 `executed` 行。
7. 审计覆盖 ok/timeout/rejected/aborted 四种终态，行数 = dispatch 次数。
8. review 用 grep 确认：`settle(` 之后没有任何游戏状态写入。
