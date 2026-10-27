# 01 — 实时感知层 v2（Live Perception）

> 目标：让 agent 看到**当前**世界（`position/health/vehicle/bucket/ping/job/money/quest` + `join/leave/death/job.change/money.change/quest.completed`），
> 而不是等 DirtyFlush 落盘。约束源：`docs/agent/{README,ACTIONS,API,sequencing}.md`、`docs/server-design/08-agent-director.md`。
> 本文是施工契约；字段名与路由冻结于此。

---

## 0. 一句话结论

在 `custom-director` 内新增**内存快照 + 内存事件流**（`/agent/v1/live/*`，独立 token、独立 kill switch、独立 `epoch:seq`），
DB 视图退化为**耐久投影与补课通道**。实时值以 FXServer 内存为权威，DB 永不用于判断"现在"；
live 与 DB 的合并发生在 Hub/sidecar，**不发生在 FXServer**。

### 0.1 读代码后确认的事实（决定方案形状）

| 事实 | 出处 | 后果 |
|:---|:---|:---|
| 快照视图刻意排除 `position/inventory/metadata/phone/license`；读层自认在线数是估算（"does not expose live session state"） | `README.md:83-84`、`v2.2_agent_read_layer.sql:60-63`、`API.md:387` | "在哪/血多少/在线"在**契约上**拿不到，不是延迟问题 |
| `agent_events` 只由 4 张表的 AFTER INSERT trigger 写入 | `v2.2.1_agent_event_triggers.sql:47,75,99,127` | `player.join/leave/death/job.change/money.change` **根本不存在**；这些不是 insert-only 表，加 trigger 也补不出 |
| 落盘是批量且可跳过：`persistence_flush_interval` 默认 900s；`Save` 在 `IsDirty=false` 且非 force 时直接 return | `persistence_manager.lua:109`、`player.lua:588-591` | DB 快照可落后 15 分钟，position 是落盘瞬间值 |
| `QBCore:Server:PlayerLoaded` 在 `Players[src]=self` **之后**触发；`playerDropped` 先发 `QBCore:Server:PlayerDropped` 再清表 | `player.lua:496-499`、`events.lua:10-17` | 两个 hook 到达时数据可读，是可靠的生命周期锚点 |
| money 变动必发 `QBCore:Server:OnMoneyChange(src,type,amount,op,reason)`；job/gang 必发 `OnJobUpdate`/`OnGangUpdate` | `qb-core/server/services/economy_service.lua:50,112`、`player.lua:228,271,293` | 冷字段有一等事件源，无需轮询 |
| 任务侧有 `quest:server:onQuestCompleted/onStepCompleted/onQuestFailed` | `custom-quest/server/quest_manager.lua:809,836,1035` | `quest.completed` 可零延迟 |
| 服务端 `GetCoords` 用 `GetEntityCoords`+`GetEntityHeading`；`SetPlayerBucket` 用 `SetPlayerRoutingBucket`；`GetPlayerByCitizenId` 是 O(n) 线性扫描 | `functions.lua:13-19,57-66,294-305` | 位置/朝向/bucket 服务端可得；live 必须自建 `cid→source` 索引 |
| `metadata` 含 `fingerprint/walletid/phone/callsign`；死亡/手铐用 `metadata.isdead/inlaststand/ishandcuffed`（仓库两种拼写都有） | `qb-core/config.lua:63-100`、`custom-security/server/security.lua:62-63` | 必须白名单投影；读取要兼容 `handcuffed` |
| 一个 resource 只有一份 `SetHttpHandler`；`makeResponder/matchRoute/secureEquals` 是 main.lua 的 local；错误形状 `{error, code}` + `httpStatusForResult` | `main.lua:85,1006,1093,1116-1131,1294` | live 必须挂同一 handler、共享工具、沿用错误形状 |

---

## 1. 读通道选型：为什么是"内存读端点"，为什么放在 custom-director

### 1.1 三个候选

| 方案 | 实时性 | 主线程成本 | 结论 |
|:---|:---|:---|:---|
| A. 继续查 DB 视图（现状） | 15min 量级，且字段被契约删除 | 不在游戏线程（好） | **不可行**：不是慢，是没有这个数据 |
| B. 新起 `custom-live-observer` | 好 | 好 | 暂不取（见 1.3） |
| C. `custom-director` 内加 live 模块 | 好（缓存年龄 ≤100ms） | 好（100ms tick，见 §5） | **采用** |

澄清硬约束「读不走游戏线程」：本意是**不在游戏线程做 DB/网络 I/O、不强制落盘**。live 只读进程内内存（`QBCore.Players` + 服务端原生），**零 SQL、零出站、零 `Wait`**，因此不违反；违反的是"在 handler 里 `MySQL.*.await`"。

### 1.2 与 DB 视图的分工与权威

| 数据 | source of truth | 另一侧角色 |
|:---|:---|:---|
| online/offline、position、health、vehicle、bucket、ping、idle | **FXServer 内存（live）** | DB 无此数据 |
| job/gang/money/metadata 标志 | **FXServer 内存（live）** | DB 是延迟投影（可达 900s） |
| 历史事件、审计、离线玩家、经济聚合 | **MariaDB（`agent_events`/`agent_*`）** | live 环形仅 2048 条、重启即失 |
| 已执行写动作的结果 | **MariaDB `agent_actions`** | live 不记录写行为 |

冲突裁决（写进 Hub 规则，不是 FXServer 规则）：

1. `online/pos/vitals/vehicle/bucket/ping`：**live 无条件胜出**；DB `last_updated` 不得用于推断在线。
2. `money/job`：live 胜出（内存先改后落盘）；DB 仅用于离线玩家与跨会话历史。
3. 同一事实两路事件：**DB 行做审计，live 做触发**；去重键不同（§4.4），不合并成一个流。
4. "DB 与 live 不一致"：live 响应带 `freshness.*_ms` 与 `state`，由 Hub 判"不确定"；**FXServer 不做交叉校验查询**（会把 DB await 拉回主线程）。
5. live⋈DB 的 join 由 `tools/agent_gateway.py`/Hub 完成。

### 1.3 为什么不新起 resource（以及何时该起）

不新起：① 一个 HTTP 面更易做鉴权/限流/审计与防火墙；② 与 `/act` 共用 `X-Agent-Id`、kill switch 语义、错误形状；③ 依赖同一批事件源，拆开会有两套生命周期处理。该起的条件：live 需在 `stop custom-director` 后继续服务，或读写权限模型必须彻底分离——届时把 `server/live_*.lua` 原样搬走，路由前缀不变。

---

## 2. 数据面：字段、脱敏、精度、分页、体积

### 2.1 字段表

`L`=`GET /live/players`，`D`=`GET /live/players/:citizenid`。来源：`H`=100ms 热采样原生，`C`=事件驱动冷缓存，`Q`=按需拉取。

| 字段 | L | D | 源 | 说明/上限 |
|:---|:-:|:-:|:-:|:---|
| `citizenid` | ✓ | ✓ | C | 稳定主键（QBCore 角色 id，非 license） |
| `display_name` | ✓ | ✓ | C | `GetPlayerName`，≤32 字符、去控制字符、**不可信文本** |
| `source` / `session` | ✓ | ✓ | C | `source` 仅会话内有效，**禁止当主键**；`session` 每次 PlayerLoaded +1 |
| `state` | ✓ | ✓ | H | `active` / `stale`（ped 0）/ `unresponsive`（ping=0 超时） |
| `pos` | ✓ | ✓ | H | 默认 25m 量化 `{x,y,z,heading,grid,precision_m}`；非 active 为 `null` |
| `vitals.health`/`health_max`；`vitals.armor` | ✓/– | ✓ | H | `GetEntityHealth`（上限 200）；armor 原生不可用时 `null`+`armor_source:"unavailable"` |
| `vitals.is_dead/is_laststand/is_cuffed`；`hunger/thirst/stress` | ✓/– | ✓ | C | metadata 优先、`health<=0` 兜底；hunger 等 0–100 仅 detail |
| `job` / `gang` | ✓ | ✓ | C | `{name,grade_level,grade_name,onduty}` / `{name,grade_level}` |
| `money` | – | ✓ | C | `{cash,bank,crypto}`（与 DB 快照同类，不新增 PII 面） |
| `vehicle` | ✓ | ✓ | H | `{model,plate,seat}` 或 `null` |
| `bucket` / `ping_ms` | ✓ | ✓ | H | 缺原生则 `null`；ping 0 视为不可用 |
| `idle_s` / `session_s` | ✓ | ✓ | H/C | 启发式（§3） |
| `quest`（`D` 另有 `quests[]≤5`） | ✓ | ✓ | C+Q | `{id,step_id}` |
| `inventory` | – | ✓ | Q | `{items_count,slots_used,weight_g,top_items[]≤5}`，项仅 `{name,count}` |
| `metadata` | – | ✓ | C | 白名单 `isdead/inlaststand/ishandcuffed/injail` + `other_keys_count` |
| `freshness` / `unavailable` | ✓/– | ✓ |  | 各段年龄毫秒；降级原因列表 |

**绝不出现**（任何响应、`debug=1`、日志）：`license`、`identifiers`（discord/steam）、`cid`、IP/`GetPlayerEndpoint`、token、`charinfo.phone/account/birthdate`、`metadata.fingerprint/walletid/phone`、`items[].info/serial/unique`、原始 `metadata`、原始 `PlayerData`、SQL。

### 2.2 位置精度

| 档位 | 量化 | 条件 |
|:---|:---|:---|
| `coarse`（默认） | x/y 取 25m 网格中心，z 取 5m，heading 取 15°，`grid="gx:gy"` | 永远可用 |
| `fine` | x/y 取 5m，z 取 1m，heading 取 5° | 需 `agent_live_allow_fine_position=1` **且**请求 `precision=fine`；否则 `403 precision_denied` |

理由：精确坐标 + 身份 = 可被注入的模型用来精准蹲点；导演决策（区域张力、距离）25m 粒度足够（≈一个街区）。`grid` 供"同区域"比较，避免 agent 索要更细坐标；量化在 `live_rules.QuantizePosition` 完成，不是输出时四舍五入字符串。

### 2.3 分页与体积上限

- `GET /live/players`：`limit` 默认 48、硬上限 48（`sv_maxclients 48`，`server.cfg:7`）；`citizenid ASC` 排序，`after=<citizenid>` 游标分页，超限给 `has_more`+`next_cursor`。
- `fields`：逗号分隔白名单（`summary`(默认)/`vitals`/`job`/`vehicle`/`pos`）；未知字段 400。字节预算：`agent_live_max_bytes` 默认 **32768**（硬上限 131072）。超预算按固定顺序降级并置 `truncated:true`+`omitted:[...]`：`pos 精度 → vehicle → vitals → job → limit 折半`；**绝不截断 JSON 字符串**。
- detail ≤8192B，`top_items` ≤5（`item_limit` 最大 20）；events `limit` 默认 50（上限 200），单事件 ≤512B，整包 ≤32768B。

满载估算：48 人 × summary ≈ 320B ≈ **15KB**；detail ≈1.2KB；50 条事件 ≈8–20KB。均不含 license/IP，可直接进 LLM 上下文（Hub 可再用 `budget_tokens` 裁剪，复用 `agent_data.fit_digest_budget` 思路）。

---

## 3. 生命周期边界

槽位以 `citizenid` 为键，`source` 只是字段，`session` 用于丢弃过期异步结果。

| 情形 | 检测 | 行为 |
|:---|:---|:---|
| 已连接但未 PlayerLoaded | `QBCore.Players[src]==nil`（`functions.lua:46`） | 不进列表；detail → 404 `player_not_found` + `hint:"not_loaded"` |
| 正常上线 / `source` 复用 | `QBCore:Server:PlayerLoaded`；同 cid 已有槽且 `source` 不同即复用 | 建槽、`session+1`、emit `player.join`；复用时先 emit `player.leave(reason="source_replaced")`，旧 `session` 的在途 detail 结果丢弃 |
| 断线瞬间 | `QBCore:Server:PlayerDropped`（此时 Player 可读） | emit `player.leave`；列表立即移除；槽位保留 30s tombstone，detail 返回 `state:"gone"`、`pos:null` |
| ped 不存在（OneSync 未复制/加载屏/刚掉线） | `GetPlayerPed(src)==0` 或 `not DoesEntityExist(ped)` | `state:"stale"`、`pos/vehicle=null`，**不报错**；超 `agent_live_grace_ms`(5000) 仍无 leave → `unresponsive` |
| 玩家在载具 | `GetVehiclePedIsIn(ped,false)`（服务端可用，`custom-vehicles/server/dashboard_api.lua:86`） | `vehicle={model,plate,seat}`；为 0 则 `null` |
| 死亡/倒地/被铐 | `metadata.isdead/inlaststand/ishandcuffed`（或 `handcuffed`），`health<=0` 兜底 | `is_dead`/`is_cuffed`；仅 false→true 发 `player.death`，反向发 `player.revive`；被铐只做字段 |
| AFK | 位移 <0.5m 且 heading 变化 <5° 持续 `agent_live_afk_ms`(600000) | `idle_s` 递增、`afk_suspected:true`；**启发式**，不参与任何写策略 |
| ping=0 | `GetPlayerPing(src)==0` | `ping_ms:null`、`state:"unresponsive"`（`compat.lua:70` 已记录该原生对无效玩家也返回 0，不能当存在性判据） |
| 资源重启 | `onResourceStart` | 新 `epoch`，清空环与缓存，emit `live.epoch` |

防串数据规则：**任何事件/响应里的 `session` 落后于当前槽位即丢弃**——这是 source 复用下唯一可靠的保障。

---

## 4. 实时事件流

### 4.1 与 DB outbox 的对比（为什么必须双通道）

| 维度 | `agent_events`（DB） | live tap（内存） |
|:---|:---|:---|
| 产生 | 4 张表 AFTER INSERT trigger | 服务端事件 + 热采样差分 |
| 延迟 | insert→commit→（director 默认 15s 轮询，`director.lua:65`）→查询 | 回调内通常 <5ms；位置类 ≤tick(100ms) |
| 覆盖 | 仅 quest/story/bank/vehicle | §4.2 的 12 类，含 join/leave/death/job/money |
| 持久性 | 永久、append-only、审计真源 | 环形 2048，重启丢失 |
| 用途 | 审计、复盘、离线补课 | 实时触发、<100ms 反应 |

不是替代关系：live 先到、DB 后到且更权威；类型名对齐（`quest.completed` 等），但 live 多出的 `player.*/money.change/job.change` 在 DB 侧暂无对应行——这是**已知并接受的契约缺口**（§11-D4）。

### 4.2 事件源（均已核实）

| type | hook | payload（脱敏后） |
|:---|:---|:---|
| `player.join` | `QBCore:Server:PlayerLoaded` | `source,session,job{name,grade_level},gang{name}` |
| `player.leave` | `QBCore:Server:PlayerDropped` | `source,session,reason`(≤64，不可信文本) |
| `player.death` / `player.revive` | metadata 差分；`health<=0` 兜底 | `session,cause ∈ {metadata, health},pos?`(coarse) |
| `player.job.change` | `QBCore:Server:OnJobUpdate` | `job,prev` |
| `player.gang.change` | `QBCore:Server:OnGangUpdate` | `gang,prev` |
| `money.change` | `QBCore:Server:OnMoneyChange` | `account,delta,operation ∈ {add,remove,set},reason≤64,after?` |
| `quest.completed` / `quest.step` / `quest.failed` | `quest:server:onQuestCompleted/onStepCompleted/onQuestFailed` | `quest_id[, step_id 或 reason]` |
| `live.overflow` / `live.epoch` | 发射器限速/资源启动 | `dropped,window_ms` / `epoch,started_at_s` |

> 不以 `QBCore:Player:SetPlayerData` 作主 hook：该事件每次 `UpdatePlayerData()` 都带**整份 PlayerData（含 inventory）**跨资源复制，48 人满载是可观测的 CPU/GC 成本。metadata（死亡/手铐）变化二选一（§11-D3）：推荐在 `player.lua:UpdatePlayerData` 旁加一行 `TriggerEvent('QBCore:Server:OnMetaUpdate', src, meta, val)`；过渡期用 `SetPlayerData` + 每玩家 500ms 节流，convar `agent_live_meta_source=event|throttled` 切换。

### 4.3 环形缓冲 + 游标

- `epoch`：资源启动生成 8 位 hex；`seq`：从 1 单调递增；游标 `v1:<epoch>:<seq>`。
- 容量 `agent_live_event_buffer` 默认 2048（256–8192）；写满覆盖最旧并 `dropped_total++`。
- `GET /live/events?since=<cursor>&limit=&types=` 返回 `[since, newest]` **升序**。
- 游标错误：epoch 不匹配 → `409 cursor_epoch_mismatch`（带 `epoch/oldest_seq/newest_seq`）；`since.seq < oldest_seq-1` → `410 cursor_expired`（带 `oldest_cursor`、`dropped_before`）。
- 允许纯数字 `since=1024`（等价当前 epoch，响应 `meta.epoch_assumed=true`）；文档要求客户端持久化完整游标。
- 响应头附 `X-Agent-Live-Epoch`/`X-Agent-Live-Seq`，供廉价探活，省一次 JSON 解析。

### 4.4 丢失 / 重放 / 背压

- **不保证 exactly-once**：消费幂等键 `(epoch, seq)`；跨重启/补课改用 DB `since_id`。重放仅在环形窗口内；窗口外必须走 `agent_gateway.py /agent/v1/events?since_id=` 补课，再以 live `next_cursor` 续接；不提供"从 DB 自动重放"的桥（会把 DB await 拉进主线程）。
- 背压：`Emit` 永不阻塞、不写盘、不出站。三重限幅：① 单事件 payload ≤512B，超出写 `truncated:true`+`dropped_fields`；② 全服速率上限 `agent_live_events_per_sec`(200)，超限**聚合**为 `live.overflow`（不逐个丢）；③ `money.change` 按 `(citizenid,account)` 500ms 窗口合并，`delta` 求和、`coalesced` 计数（`set` 操作 `delta:null`，只给 `after`）。
- 停读不停采：`agent_live_enabled=0` 只关 HTTP，事件继续进环，避免开关后出现不可解释空洞。

---

## 5. 性能与安全

### 5.1 48 人满载预算（P95，服务端）

| 路径 | 工作量 | 目标 |
|:---|:---|:---|
| 热采样 tick（100ms） | 48 ×（ped/coords/health/heading/veh/bucket/ping ≈7 原生） | **≤1.5ms/tick，P95 ≤3ms**；只用原生，不复制 PlayerData |
| 冷缓存更新 | 每条 money/job/meta 事件 O(1) | ≤0.2ms/事件（事件自带数据） |
| `GET /live/players` | 48×summary，≈15KB | **≤15ms** |
| `GET /live/players/:cid` | inventory/quest 按需（≤1/s/人）+ ≤8KB | **≤25ms**（memo 1s） |
| `GET /live/events` | ≤200 条 ≤32KB | **≤5ms**（总闸 `agent_live_global_rps`=100，超限 429） |

- 端到端新鲜度 = `缓存年龄 ≤ tick(100ms) + OneSync 复制 + agent 轮询间隔`。**不承诺**"端到端 <100ms"：服务端保证 `freshness.hot_ms ≤150`，agent 需 ≥10Hz 轮询才能把总延迟压到 100ms 量级。
- 请求路径零 SQL、零 `Wait`、零 `PerformHttpRequest`（验收 grep 必须为空）。
- tick 直方图（桶 0.5/1/2/5/10ms）+ EMA 暴露在 `/live/health` 与 `/agentlive status`。

### 5.2 限流与鉴权

| 项 | 设计 |
|:---|:---|
| Token | **独立** `agent_live_token`，不复用 `agent_actions_token`：只读凭证泄漏不应导致可加钱；可独立轮换 |
| Agent 身份 | `X-Agent-Id` 可选；合法时作为限流桶键与审计字段，否则 `anonymous`（用 `AgentPolicy.NormalizeAgentId`） |
| 限流 | 令牌桶 `agent_live_rate_limit`=20/s、burst 40；detail 桶 5/s；全局 100/s。超限 `429`+`Retry-After: 1` |
| 比较 / 暴露面 | 复用 `main.lua:993 secureEquals`（经 `_G.AgentHttp`）；`SetHttpHandler` 无 per-IP ACL，必须靠防火墙只放行 Hub 主机到 `:30120/custom-director/*` |
| 请求形状 | 仅 GET；未知 query 参数一律 400；不读 body |

### 5.3 别把 PII 拉进 LLM 上下文

默认响应即"最小够用集"（list 无 money/inventory/metadata/精确坐标）；文本字段（`display_name`、`reason`）限长、去控制字符、标注 `untrusted_text`，提示 Hub 按"数据块"注入。`agent_gateway.py` 侧建议对 `live_*` 再做白名单投影与 `budget_tokens` 裁剪；日志只记 `route/status/bytes/agent_id`，**不记** query 原串、header、token、IP。

---

## 6. 与 `custom-director` 的集成点

### 6.1 文件与加载顺序（`fxmanifest.lua`，全部插在 `main.lua` 之前）

```lua
'server/policy.lua',
'server/live_rules.lua',    -- 纯函数，无 FiveM/MySQL（可被 lua5.4 直接测试）
'server/live_events.lua',   -- 环形缓冲 + 事件 tap + 聚合限速
'server/live_cache.lua',    -- 槽位、热采样 tick、生命周期
'server/live_http.lua',     -- 路由/鉴权/限流/预算/降级
'server/live_selftest.lua', -- agent_live_selftest=1 时跑纯函数自检
'server/selftest.lua',
'server/main.lua',
'server/director.lua',
```

### 6.2 对 `main.lua` 的两处最小改动（不动既有路由/错误码）

```lua
-- (1) SetHttpHandler 顶部拦截 live 前缀（4 行）
SetHttpHandler(function(req, res)
    local respond = makeResponder(res)
    if _G.AgentLiveHttp and _G.AgentLiveHttp.TryHandle(req, res, respond) then return end
    local ok, err = pcall(dispatchHttp, req, res, respond)
    ...
end)

-- (2) 在 makeResponder/secureEquals 之后暴露 HTTP 工具（1 行）
_G.AgentHttp = { MakeResponder = makeResponder, SplitPath = splitPath, ParseQuery = parseQuery,
                 GetHeader = getHeader, BearerToken = bearerToken, SecureEquals = secureEquals,
                 Failure = failure, Truncate = truncate }
```

`live_http.lua` 在**请求时**才 deref `_G.AgentHttp`（其加载早于 main.lua），缺失则 500。`matchRoute` 保持原样，live 在模块内自解析 `^/agent/v1/live/`，避免改变既有 404/405/`disabled` 的优先级。备选（不推荐）：给 `matchRoute` 加 `group='live'` 并在 `dispatchHttp` 前置分支——会改变 `disabled` 与 `404` 的优先级，属回归风险。

### 6.3 路由表（逻辑路径；外部前缀 `/<resource>/`）

| Method | Path | 说明 |
|:---|:---|:---|
| GET | `/agent/v1/live/health` | epoch/seq/缓存年龄/限流余量/tick 分位 |
| GET | `/agent/v1/live/players` | 在线列表（summary、分页、预算） |
| GET | `/agent/v1/live/players/:citizenid` | 单玩家 detail |
| GET | `/agent/v1/live/events` | 增量事件（cursor） |

### 6.4 Convar 与 kill switch（每次请求读，热生效）

| Convar | 默认 | 语义 |
|:---|:---|:---|
| `agent_live_enabled` | `0` | `1` 才服务；否则 503 `live_disabled`（**不**停事件采集） |
| `agent_live_token` | *(空)* | 空 ⇒ 503 `live_token_not_configured`（与 actions token 独立） |
| `agent_live_tick_ms` / `_grace_ms` | `100` / `5000` | 热采样周期（50–1000）/ ped 消失容忍 |
| `agent_live_max_bytes`；`_event_buffer` / `_events_per_sec` | `32768`；`2048`/`200` | 单响应预算（4096–131072）；环形容量 / 全服事件速率 |
| `agent_live_rate_limit` / `_burst` / `_detail_rate_limit` / `_global_rps` | `20`/`40`/`5`/`100` | 令牌桶（普通/detail/全局；`_burst` 为突发） |
| `agent_live_allow_fine_position` | `0` | 允许 `precision=fine` |
| `agent_live_afk_ms` | `600000` | AFK 判定窗口 |
| `agent_live_meta_source`；`agent_live_selftest` | `throttled`；`0` | `event`（依赖 qb-core 新事件）/`throttled`；selftest=1 启动打印 `[AGENT-LIVE-SELFTEST]` |

控制台命令（与 `/agentapprove` 同款守卫：console 或 `qbcore.god`，资源不可调用）：
`/agentlive status`（epoch/seq/槽位数/tick p95/事件速率/丢弃数）、`/agentlive probe <citizenid>`（打印脱敏后全字段 + `age_ms`）、`/agentlive bench [n]`（n 次列表构建的 p50/p95）。

### 6.5 失败与降级矩阵

| 失败 | 行为 |
|:---|:---|
| `qb-core` 未启动 | 503 `core_unavailable`，tick 空转 |
| 首个 tick 未完成 | 503 `live_cache_warming` + `Retry-After: 1` |
| `qb-inventory` / `custom-quest` 缺失 | 对应字段 `null` + `unavailable:[...]`，200 |
| 原生缺失（armour/bucket/plate） | 字段 `null` + `*_source:"unavailable"`，200 |
| 环形溢出 | `dropped_before>0` + `live.overflow`；游标过期 → 410 |
| 响应超预算 | 按序降级 + `truncated/omitted`，200 |
| detail 刷新异常 | 返回过期缓存并放大 `freshness.*_ms`，200（宁可旧也不 500） |

---

## 7. API 契约（v1）

信封 `{"live_schema_version":1,"data":...,"meta":{...}}`——**刻意不复用** DB 读层的 `schema_version`，避免消费方把 live 当视图。错误 `{"error":"...","code":"..."}`（与 `main.lua:85 failure()` 同形）；`*_ms` 为相对毫秒，`*_at_s` 为 Unix 秒。

### 7.1 `GET /agent/v1/live/players?limit=48&fields=summary&after=&precision=coarse`

```json
{"live_schema_version":1,
 "data":[{"citizenid":"ABC12345","display_name":"Vito Maretti","source":12,"session":7,"state":"active",
   "pos":{"x":125.0,"y":-1040.0,"z":27.5,"heading":180,"grid":"5:-42","precision_m":25},
   "vitals":{"health":172,"health_max":200,"is_dead":false,"is_laststand":false,"is_cuffed":false},
   "job":{"name":"police","grade_level":2,"grade_name":"Officer","onduty":true},"gang":{"name":"none","grade_level":0},
   "vehicle":{"model":-1216765807,"plate":"TC123AB","seat":-1},"bucket":0,"ping_ms":42,"idle_s":3,"session_s":1840,
   "quest":{"id":"police_ch1_first_shift","step_id":"report_in"},
   "freshness":{"hot_ms":47,"cold_ms":900,"inventory_ms":null,"quests_ms":null}}],
 "meta":{"count":1,"online":1,"limit":48,"applied_limit":48,"truncated":false,"omitted":[],"agent_id":"director.local",
   "epoch":"9f3ac21b","seq":8841,"server_time_s":1761136800,"rate_limit":{"remaining":37,"reset_ms":50}}}
```
翻页时附 `meta.has_more=true` 与 `meta.next_cursor`。

### 7.2 `GET /agent/v1/live/players/ABC12345?precision=coarse&item_limit=5`

```json
{"live_schema_version":1,
 "data":{"citizenid":"ABC12345","display_name":"Vito Maretti","source":12,"session":7,"state":"active",
  "pos":{"x":125.0,"y":-1040.0,"z":27.5,"heading":180,"grid":"5:-42","precision_m":25},
  "vitals":{"health":172,"health_max":200,"armor":35,"armor_source":"native","is_dead":false,"is_laststand":false,
            "is_cuffed":false,"hunger":88,"thirst":71,"stress":12},
  "job":{"name":"police","grade_level":2,"grade_name":"Officer","onduty":true},"gang":{"name":"none","grade_level":0},
  "money":{"cash":340,"bank":18220,"crypto":0},"vehicle":{"model":-1216765807,"plate":"TC123AB","seat":-1},
  "bucket":0,"ping_ms":42,"idle_s":3,"session_s":1840,"quest":{"id":"police_ch1_first_shift","step_id":"report_in"},
  "quests":[{"id":"police_ch1_first_shift","step_id":"report_in","age_s":240}],
  "inventory":{"items_count":14,"slots_used":11,"weight_g":18400,"top_items":[{"name":"bread","count":3},{"name":"bandage","count":2}]},
  "metadata":{"isdead":false,"inlaststand":false,"ishandcuffed":false,"injail":0,"other_keys_count":18},
  "freshness":{"hot_ms":47,"cold_ms":900,"inventory_ms":1200,"quests_ms":2100},"unavailable":[]},
 "meta":{"epoch":"9f3ac21b","seq":8841,"authority":"live","server_time_s":1761136800}}
```

### 7.3 `GET /agent/v1/live/events?since=v1:9f3ac21b:8820&limit=50&types=player.join,money.change`

```json
{"live_schema_version":1,
 "data":[{"seq":8821,"ts_ms":1761136798123,"type":"player.join","citizenid":"ABC12345","session":7,
          "payload":{"source":12,"job":"police","gang":"none"}},
         {"seq":8830,"ts_ms":1761136800010,"type":"money.change","citizenid":"ABC12345","session":7,
          "payload":{"account":"bank","delta":-250,"operation":"remove","reason":"vehicle repair","after":18220,"coalesced":1}}],
 "next_cursor":"v1:9f3ac21b:8830",
 "meta":{"count":2,"epoch":"9f3ac21b","seq":8841,"oldest_seq":7001,"dropped_before":0,"truncated":false,
   "types_applied":["player.join","money.change"],"epoch_assumed":false}}
```

### 7.4 错误码

| HTTP | code | 触发 |
|:---|:---|:---|
| 400 | `bad_request` / `invalid_cursor` | query 参数非法 / `since` 形状非法 |
| 401 | `unauthorized` | 缺/错 Bearer（附 `WWW-Authenticate`） |
| 403 | `precision_denied` | `precision=fine` 但 convar 未开 |
| 404 | `not_found` / `player_not_found` | 未知路径 / 无该 cid 会话（`hint ∈ {not_loaded, offline, gone}`） |
| 405 | `method_not_allowed` | 非 GET（附 `Allow: GET`） |
| 409 | `cursor_epoch_mismatch` | epoch 不匹配（附 `epoch/oldest_seq/newest_seq`） |
| 410 | `cursor_expired` | 游标早于环窗口（附 `oldest_cursor`） |
| 429 | `rate_limited` | 桶空（附 `Retry-After: 1`） |
| 503 | `live_disabled` / `live_token_not_configured` / `live_cache_warming` / `core_unavailable` | 见 §6.5 |
| 500 | `internal_error` | 未捕获异常（不泄漏堆栈/路径） |

---

## 8. 关键 Lua 签名与伪代码

```lua
-- server/live_rules.lua（纯函数；无 FiveM/MySQL；与 policy.lua 同风格）
LiveRules.VERSION = 1
function LiveRules.NewEpoch() -> string                                  -- 8 hex
function LiveRules.EncodeCursor(epoch, seq) -> string                    -- "v1:<epoch>:<seq>"
function LiveRules.DecodeCursor(raw) -> {epoch=,seq=} | nil, err
function LiveRules.QuantizePosition(coords, heading, precisionM) -> {x,y,z,heading,grid,precision_m}
function LiveRules.ProjectVitals(metadata, health, armor) -> table
function LiveRules.ProjectInventory(items, itemLimit) -> table           -- {items_count,slots_used,weight_g,top_items}
function LiveRules.ProjectMetadata(metadata) -> table                    -- 白名单 + other_keys_count
function LiveRules.SanitizeText(text, maxLen) -> string                  -- trim/去控制字符/截断
function LiveRules.FitBudget(build, maxBytes, dropOrder) -> payload, meta
function LiveRules.RingNew(capacity) -> ring;  RingPush(ring, event) -> dropped  -- 0/1
function LiveRules.RingSince(ring, seq, limit, typeSet) -> events, meta
function LiveRules.BucketTake(bucket, nowMs) -> ok, remaining, resetMs
```

```lua
-- server/live_events.lua
LiveEvents.Start(capacity)
function LiveEvents.Emit(etype, citizenid, payload, opts)   -- opts={session,coalesce_key,coalesce_ms}
function LiveEvents.Pull(sinceRaw, limit, typesCsv) -> events, meta, errCode
function LiveEvents.Stats() -> {epoch,seq,oldest_seq,dropped,rate_1s}
-- server/live_cache.lua
LiveCache.Start() / LiveCache.Stop()
function LiveCache.OnLoaded(player) / OnDropped(player, reason)
function LiveCache.OnJobUpdate(src, job) / OnGangUpdate(src, gang)
function LiveCache.OnMoneyChange(src, account, amount, operation, reason)
function LiveCache.OnMetaUpdate(src, key, value)            -- agent_live_meta_source=event
function LiveCache.HotTick(nowMs)                           -- 只用原生；差分时才发事件
function LiveCache.List(opts) -> array, meta
function LiveCache.Get(citizenid, opts) -> detail, errCode
function LiveCache.Probe(citizenid) -> debugTable           -- 仍走脱敏投影
-- server/live_http.lua
function AgentLiveHttp.TryHandle(req, res, respond) -> handled:boolean
```

```lua
-- 伪代码：热采样（每 agent_live_tick_ms，主线程，零 SQL）
CreateThread(function()
  while true do
    Wait(tickMs())
    if coreReady() then
      local now = GetGameTimer()
      for _, slot in pairs(LiveCache.slots) do
        local ped = GetPlayerPed(slot.source)
        if ped == 0 or not DoesEntityExist(ped) then
          slot.state = (now - slot.lastSeenMs > graceMs) and 'unresponsive' or 'stale'
          slot.pos, slot.vehicle = nil, nil
        else
          local c, h = GetEntityCoords(ped, false), GetEntityHeading(ped)
          slot.pos = LiveRules.QuantizePosition(c, h, precisionFor(slot))
          slot.vitals.health = GetEntityHealth(ped)
          local veh = GetVehiclePedIsIn(ped, false)
          slot.vehicle = veh ~= 0 and { model = GetEntityModel(veh), seat = -1,
            plate = LiveRules.SanitizeText(GetVehicleNumberPlateText(veh), 12) } or nil
          slot.bucket = GetPlayerRoutingBucket and GetPlayerRoutingBucket(slot.source) or nil
          slot.ping = (GetPlayerPing(slot.source) ~= 0) and GetPlayerPing(slot.source) or nil
          slot.state = slot.ping and 'active' or 'unresponsive'
          if slot.vitals.health <= 0 and not slot.vitals.is_dead then LiveCache.markDeath(slot, 'health') end
          LiveCache.accumulateIdle(slot, c, h, now)
        end
      end
      LiveEvents.flushCoalesced(now)                 -- money 合并窗口到期才发
      LiveCache.recordTickHistogram(GetGameTimer() - now)
    end
  end
end)
```
```lua
-- 伪代码：事件发射（永不阻塞）
function LiveEvents.Emit(etype, cid, payload, opts)   -- opts={session,coalesce_key,coalesce_ms}
  payload = LiveEvents.capPayload(payload, 512)                        -- 超限 -> truncated
  if opts.coalesce_key and LiveEvents.coalesce(opts.coalesce_key, 500) then
    LiveEvents.pending[opts.coalesce_key] = LiveEvents.mergeDelta(...)  -- money 合计
  elseif not LiveEvents.rateAllows(os.time()) then
    LiveEvents.overflowCount = LiveEvents.overflowCount + 1           -- 下个 tick -> live.overflow
  else
    LiveEvents.seq = LiveEvents.seq + 1
    LiveRules.RingPush(LiveEvents.ring, { seq = LiveEvents.seq, ts_ms = os.time() * 1000,
      type = etype, citizenid = cid, session = opts.session, payload = payload })
  end
end

-- 伪代码：HTTP 入口（main.lua 的 SetHttpHandler 顶部调用；顺序 = 开关 -> token -> 方法 -> 限流）
function AgentLiveHttp.TryHandle(req, res, respond)
  if not tostring(req.path or ''):find('/agent/v1/live/', 1, true) then return false end
  local cfg = LiveConfig()
  if not cfg.enabled then respond(503, {error='live perception disabled', code='live_disabled'}); return true end
  if cfg.token == '' then respond(503, {error='token not configured', code='live_token_not_configured'}); return true end
  if not AgentHttp.SecureEquals(AgentHttp.BearerToken(req), cfg.token) then
    respond(401, {error='unauthorized', code='unauthorized'}, {['WWW-Authenticate']='Bearer'}); return true
  end
  if tostring(req.method):upper() ~= 'GET' then
    respond(405, {error='method not allowed', code='method_not_allowed'}, {['Allow']='GET'}); return true
  end
  local agentId = AgentPolicy.NormalizeAgentId(AgentHttp.GetHeader(req, 'x-agent-id')) or 'anonymous'
  if not LiveRules.BucketTake(LiveHttp.bucket(agentId), GetGameTimer()) then
    respond(429, {error='rate limit exceeded', code='rate_limited'}, {['Retry-After']='1'}); return true
  end
  -- 路由 -> 参数校验 -> 读缓存 -> FitBudget -> 200 + X-Agent-Live-Seq
  return true
end
```

---

## 9. 不做什么（反模式）

1. **不做长轮询/SSE/WebSocket/阻塞 `Wait`**：FXServer 单线程，handler 里等 1 秒就是全服卡 1 秒；要低延迟让 agent 10Hz 轮询。
2. **不在 live 路径做任何 SQL**（含 `MySQL.single.await`），也不做 live⋈DB 交叉校验；合并放 sidecar。
3. **不靠给 `players` 加 trigger 造实时**：`players` 只在 flush 时 UPSERT，trigger 频率=落盘频率，还放大写；**不轮询整份 `PlayerData`**：跨资源复制含 inventory，48 人下纯浪费；冷字段靠事件，热字段靠原生。
4. **不返回 license/identifier/IP/fingerprint/walletid/phone/原始 metadata/items.info**，不做"管理员视图"或 `debug=1` 后门。
5. **不允许用 `source` 或 `display_name` 当主键**，一律 `citizenid` + `session`。
6. **不复用 `agent_actions_token`**，live 层不实现任何写动作；**不做"位置默认精确"**，`fine` 必须 convar 开启且可审计。
7. **不承诺 exactly-once / 不把 live 当审计真源**；环形缓冲不落盘（落盘是 DB 的事）。
8. **不在事件 handler 里做重活**（拉 quest、读 inventory、写文件），也**不信任客户端上报**（AFK/位置/血量一律服务端取）。

---

## 10. 交付任务清单

| # | 任务 | 验收方式 | 依赖 |
|:-:|:---|:---|:---|
| ☐ T1 | `resources/[custom]/custom-director/server/live_rules.lua` 纯函数模块 + `tests/agent/lua/cases/live_rules.lua`（含 PII 扫描：构造含 `license/identifiers/fingerprint/walletid/phone` 的 PlayerData，序列化后不得出现这些值） | `lua5.4 .../test_live_rules.lua` 退出码 0；敏感词只出现在排除名单常量 | 无 |
| ☐ T3 | 槽位/cid 索引/生命周期/热 tick（M1 落在 live 模块，与路由同文件 `live_api.lua`） | `/agentlive status` 槽位数正确；2 客户端上下线各 5 次无残留，`session` 单调 | T1 |
| ☐ T4 | `resources/[custom]/custom-director/server/live_events.lua`：12 类事件/环/合并/聚合限速 | `agent_live_event_buffer=8` 压 100 条 → `dropped_before>0` 且有 `live.overflow`；过期游标 410 | T1,T3 |
| ☐ T5 | `resources/[custom]/custom-director/server/live_api.lua`：4 路由/独立 token/限流/预算/错误码；`main.lua` 两处改动 + manifest 顺序 | 无 token→401、`enabled=0`→503、`precision=fine` 未开→403、`limit=999`→400、48 人响应 ≤32768B；ACTIONS.md 既有请求逐条回归 | T3,T4 |
| ☐ T6 | `/agentlive status / probe / bench` | console 可跑、玩家身份被拒、`bench 1000` 输出 p50/p95 | T5 |
| ☐ T7 | 48 假人（`tcity-e2e`）满载性能 | list P95 ≤15ms、tick P95 ≤3ms；`live_*.lua` 无 `MySQL`/`Wait(`/`PerformHttpRequest`；RSS 增量 <20MB | T5,T6 |
| ☐ T8 | 实时性验收：移动 50m / 死亡 / 转账 / 完成任务 | `probe` 的 `hot_ms` ≤150；列表位置 ≤300ms 变化；四类事件 250ms 内可拉到（10Hz） | T7 |
| ☐ T9 | 文档：`API.md` 增 live 章节、`README.md` 增 convar 表、`ACTIONS.md` 交叉引用（可选：gateway/MCP `live_*` 工具；进程内 `LiveSnapshot()`/`LiveEventsSince()` 供 director 使用） | 文档 JSON 与真实响应逐字段 diff | T5 |

顺序：T1→T3→T4→T5→T6→T7→T8→T9；可选任务在 T5 之后并行。

---

## 11. 必须先决策（阻塞施工）

1. **D1 token 拆分**（推荐独立 `agent_live_token`）：Hub 要配两个凭证；不拆则须接受"只读泄漏 ⇒ 可写钱"。
2. **D2 位置默认精度**（推荐 25m，`fine` 需 convar）：影响 agent 能否做精确距离判断，以及是否审计 `fine` 请求。
3. **D3 metadata 事件取法**：`event` 需在 `resources/[qb]/qb-core/server/player.lua` 的 `UpdatePlayerData` 旁加一行 `TriggerEvent`（跨文件，需 owner 同意）；
   `throttled` 零改动但每次 `SetPlayerData` 都复制整份 PlayerData（48 人 CPU/GC 成本待实测）。
4. **D4 live 与 DB 的类型词表是否统一**：live 多出的 `player.*/money.change/job.change` 在 `agent_events` 无行。要么接受"DB 是子集"，要么后续补写 DB（不建议，会把实时路径绑回落盘）。
5. **D5 合并位置与暴露面**：Hub 直连 live，还是由 `agent_gateway.py` 统一代理（MCP 只认一个 base URL + 一个 token，需给 gateway 配 live token 与网络路径）？以及是否已用防火墙把 `:30120/custom-director/*` 限制为 Hub 主机——未限制前不应开 `agent_live_enabled=1`。

---

## 12. M1 实现回填（2026-10-22，commit `fe76857` + 评审修正）

落地时与本文档的差异，按实际实现为准：

1. **游标是十进制 `epoch:seq`，不是 `v1:<hex>:<seq>`**。`epoch` 取资源启动时的 `os.time()`，`seq` 从 1 递增。本文档 §4.3 的十六进制形式暂不实现；客户端应把游标当不透明字符串。纯 `since=<seq>` 也不支持（必须完整游标），`meta.epoch_assumed` 未实现。
2. **`agent_live_token` 无回退**。评审推翻了"未配置时代用 `agent_actions_token`"的兼容设计：那会让单 token 部署下"能读"等于"能写钱"，正是拆分 token 要避免的。未配置 ⇒ 503 `live_token_not_configured`，MCP 侧也不广告 live 工具。
3. **`money.change` 事件不再携带 `reason`**。该字段是自由文本，`custom-phone` 会写入 `"Transfer to <手机号>"`，与"phone 永不出现在读层"的约束冲突。事件只保留 `account/delta/operation/after`。
4. **文本截断按 UTF-8 边界**。按字节 `sub()` 会截断在多字节字符中间，产生非法 UTF-8 并让整份响应失败；`sanitize_text` 先按 `maxLength*4` 字节兜底、再按码点边界截断，并剔除零宽/双向控制符与 C1。
5. **未来游标钳制到最新**。`since > newest` 不再原样回显（否则 `next_cursor` 指向未来、事件被永久跳过），而是返回空列表并把游标收敛到当前 `seq`。
6. **精度只接受 ≥1 的整数**；`0.5` 曾向下取整为 0，等价于 `fine`（精确坐标）。
7. **列表与详情使用同一 `citizenid` 规范化**，避免列表能查到、详情 404。
8. **已实现**：429 令牌桶限流（`agent_live_rate_per_min`/`agent_live_burst`）。仍未实现：字节预算/`truncated`、`X-Agent-Live-Epoch` 响应头透传到 MCP、`/agentlive` 运维命令、单事件 512B 上限、epoch 同秒重启冲突。列为 M2 候选。

9. **列表与详情的字段集不同**：`/players` 列表省略 `money`（设计 §2.1），需要余额用 `/players/{citizenid}` 或 DB 快照；两者都保留 `metadata` 白名单字段。
