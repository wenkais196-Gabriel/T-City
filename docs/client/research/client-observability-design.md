# 手机四段往返可观测设计（`phone:server:diag`）

> 状态：**设计稿**，不含实现。生产代码未改动。
> 适用：`resources/[custom]/custom-phone`（client / server / web）。
> 目标：四段里任何一段断掉，**运维从一行日志就能读出断在第几段**。

---

## 0. TL;DR — 六个决定

| # | 决定 | 一句话理由 |
|---|---|---|
| 1 | 新事件 `phone:server:diag`，旧事件 `phone:server:focusState` 保留为**别名 shim** | 旧通道已被 15 个 phase 复用为通用诊断，直接改名会打断现有 grep 与排障习惯 |
| 2 | `phase` 用 `域.阶段` 两级命名（`req.*` / `ui.*`），白名单精确匹配 | 旧 phase 全部可无损映射成 `ui.<原样>`；新增请求域不污染焦点域 |
| 3 | trace id 在 **NUI 边缘生成**（`tid`），客户端 bridge 直接把它当 `request_id` | 现在 id 在 Lua 里生成，前端根本不知道自己那条请求的 id，四段无法串成一条线 |
| 4 | 一次请求**攒成一条批次**（`mode=trace`）在结束时发，不在每个 phase 发 | 8 次 net event → 最多 1 次；且"快且成功"的请求 0 次 |
| 5 | 采样判据在**链尾**做：慢 / 失败 / 缺段才发，另给 0–100 的随机比例采样 | 每秒每请求打日志在 64 人服就是每分钟数万行 |
| 6 | 服务端是**唯一能拼齐三视图**的地方（NUI 批次 + 客户端批次 + 服务端内存环） | 客户端看不见 `srv.*`，NUI 看不见 `cli.*`；断点判定必须由服务端合成，不能信客户端自述 |

---

## 1. 现状：为什么只能看到 `query_failed` / `timeout`

真实链路（`client/core/bridge.lua`、`client/main.lua:937-948`、`server/main.lua:1370-1410`）：

```
NUI fetchNui('appQuery')
  └─① POST https://custom-phone/appQuery
client RegisterNUICallback('appQuery')            client/main.lua:937
  └─② TriggerServerEvent('phone:server:appQueryRequest', id, data)
server RegisterNetEvent('phone:server:appQueryRequest')   server/main.lua:1370
  └─③ TriggerClientEvent('phone:client:appQueryResponse', src, id, res)
client RegisterNetEvent(derived) → PhoneBridge.Resolve    bridge.lua:62
  └─④ cb(response) → CEF fetch resolve
```

现存观察能力与盲区：

| 已有 | 位置 | 能回答 | 不能回答 |
|---|---|---|---|
| `origin/main.lua:939` `phase='appQuery-hit'` | 客户端刚进 handler | "客户端收到了 NUI 调用" | 转发后发生了什么 |
| `bridge.lua:89-96` 8s `timeout` | 客户端 | "没在 8s 内回包" | 是没发出去、服务端没回、还是回包丢了 |
| `request.ts:31,46-52` `query_failed` | NUI | "fetch 抛错/被 abort" | 抛在 4 段中的哪一段 |
| `server/main.lua:1247-1263` `FOCUS_PHASES` | 服务端 | 焦点生命周期 | 请求链路 |

三个具体缺口：

1. **前端不知道 `request_id`**。id 由 `bridge.lua:34-37` 的 `GetGameTimer():seq` 生成，NUI 侧完全看不到，所以 NUI 的耗时、abort、commit 无法和服务端日志对齐。
2. **服务端在坏 id 上静默返回**（`server/main.lua:1372` `if not validAppRequestId(requestId) then return end`）。客户端已经 `TriggerServerEvent` 成功，日志里却什么都没有 —— 这正是"客户端没转发"和"服务端拒收"无法区分的原因。
3. **`diagRateLimited` 是 per-(phase, src) 的 5s 窗口**（`server/main.lua:1270-1291`）。用于焦点事件是对的，但若直接拿来限流请求 phase，`PoliceMDT.refresh()` 的 `Promise.all([units, incidents])` 会在同一帧发两条 `cli.recv`，第二条被静默吞掉 —— **限流器自己制造假断点**。

---

## 2. 事件模型

### 2.1 通道

| 方向 | 事件 | 说明 |
|---|---|---|
| client → server | `phone:server:diag` | 唯一上报通道（`mode=trace` / `mode=event`） |
| server → client | 无 | 诊断**单向**，服务端不回执，避免再引入一条可能断掉的腿 |
| NUI → client | NUI callback `phoneDiag` | 前端上报；客户端 `cb({ok=true})` 立即应答，不等待 |
| client → NUI | `SendNUIMessage{action='phone:diag:config'}` | 下发 level，避免前端每次启动都拉 |

> 不加 server→client 的 diag 回执是刻意的：诊断本身若需要四次往返，它自己就会成为新的故障源。

### 2.2 payload

```lua
-- mode = 'trace'：一次请求的完整批次（推荐，也是默认）
{
  v      = 1,
  mode   = 'trace',
  from   = 'nui' | 'client',      -- 发送侧自称，服务端不信任（见 §6.4）
  tid    = 'k3f9a2b1c',           -- 3..64，[%w:%-_]
  kind   = 'query' | 'action' | 'probe',
  app    = 'police_mdt',          -- 可选，白名单字符集，≤32
  code   = 'ok' | 'timeout' | ...,-- 本条 trace 的终态
  why    = 'slow' | 'fail' | 'sample' | 'warmup',
  phases = {                      -- 按发生顺序，≤8
    { p = 'req.cli.recv', seq = 1, dt = 0 },
    { p = 'req.cli.fwd',  seq = 2, dt = 2 },
    { p = 'req.cli.answer', seq = 3, dt = 8001, code = 'timeout' },
  },
}

-- mode = 'event'：单点生命周期事件（ui 域，等价于今天的 focusState）
{
  v = 1, mode = 'event', from = 'client',
  tid = 'k3f9a2b1c',              -- 也带，便于和同一帧的 open 事件串联
  kind = 'ui',
  phase = 'ui.open-start',
  seq = 1, dt = 0,
  attempt = 2,                    -- 旧字段，原样保留
  focused = true, keepInput = true,
}
```

### 2.3 字段语义

| 字段 | 类型/范围 | 语义 | 服务端处理 |
|---|---|---|---|
| `v` | int，必须 `1` | 协议版本 | 非 1 → 丢弃并计数 |
| `mode` | `trace`\|`event` | 批次形态 | 白名单 |
| `from` | `nui`\|`client` | 自称来源 | 枚举校验；日志里标 `from=`，**不参与判定** |
| `tid` | 3..64，`^[%w:%-_]+$` | 贯穿四段的关联 id | 非法丢弃；同时作为 `request_id` 使用 |
| `kind` | `query`\|`action`\|`probe`\|`ui` | 业务类型 | 枚举 |
| `app` | `^[%w_%-]+$`，≤32 | app_id | 不在注册表 → `app=other` |
| `code` | 见 2.5 | 终态/该 phase 的结果 | 枚举，未知 → `unknown` |
| `why` | `slow`\|`fail`\|`sample`\|`warmup` | 为什么发这条 | 枚举 |
| `seq` | 1..8，严格 +1 | 批内序号 | 非严格递增 → 整批丢弃 |
| `dt` | 0..600000 | **距离同一 tid 上一个 phase 的毫秒数** | 钳位 |
| `phase` | 白名单 | `mode=event` 时用 | 精确匹配 |

`dt` 的时钟边界（重要，写进实现注释）：

- 客户端与服务端是两台机器，`GetGameTimer()` 各自从自己的进程启动计时，**绝对不能相减**。
- 因此协议只传 **同侧相对量 `dt`**，不传绝对时间戳：跨段耗时只做"上界推断"（如 `cli.fwd → cli.answer` 包含网络 + 服务端处理）。
- 服务端打印日志时用自己的单调时钟记录到达顺序，用于判定**顺序**而非延迟。
- 前端 `dt` 用 `Date.now()` 而非 `performance.now()`：手机大部分时间处于隐藏页，CEF 会节流隐藏页的 timer/rAF，`performance.now()` 在重新可见时会出现跳跃，`Date.now()` 至少是墙钟且跨进程可比对（同机）。

### 2.4 phase 枚举（白名单，共 8 + 15）

请求域 `req.*` —— 恰好四对，一对对应一段边界：

| # | phase | 发出方 | 含义 | 槽位 |
|---|---|---|---|---|
| 1 | `req.nui.send` | NUI | 即将 `fetch`（含 `_diag.tid`） | `NS` |
| 2 | `req.cli.recv` | client | NUI callback 进入 | `CR` |
| 3 | `req.cli.fwd` | client | 即将 `TriggerServerEvent` | `CF` |
| 4 | `req.srv.recv` | server | 服务端 handler 进入（**服务端权威**） | `SR` |
| 5 | `req.srv.done` | server | 即将 `TriggerClientEvent`（**权威**） | `SD` |
| 6 | `req.cli.resp` | client | response 事件命中了 pending 槽 | `CP` |
| 7 | `req.cli.answer` | client | 即将调用 NUI `cb()` | `CA` |
| 8 | `req.nui.done` | NUI | fetch resolve + 信封解析完成 | `ND` |

**成对关系**（§5 断言的基础）：

```
①NS↔②CR   ②CR↔③CF   ③CF↔④SR   ④SR↔⑤SD   ⑤SD↔⑥CP   ⑥CP↔⑦CA   ⑦CA↔⑧ND
   seg1       seg1'      seg2       seg3产      seg3送      seg3'      seg4
```

焦点域 `ui.*` —— 迁移自现有 15 个 phase，**名字只加前缀，语义不变**（见 §3.2）。

### 2.5 结果码

| code | 来源 | 含义 |
|---|---|---|
| `ok` | 任意 | 正常 |
| `timeout` | client | 8s 截止（`bridge.lua:95`） |
| `abort` | NUI | `fetchNui` 的 AbortController 触发（`nui.ts:139`） |
| `no_response` | client/NUI | 回包为空或非表（`bridge.lua:54`） |
| `bad_request` | client/server | 入参非表 |
| `bad_id` | server | `request_id` 未过 3..64 校验（今天静默 `return`，**必须补发**） |
| `rate_limited` | server | `PhoneRateLimit.Allow` 拒绝（`server/main.lua:1378`） |
| `handler_error` | client | NUI handler 抛错（`bridge.lua:203`） |
| `app_error` | server | `PhoneApps.Query/Action` 返回 `false` |
| `resource_stopped` | client | `PhoneBridge.Clear`（`bridge.lua:103`） |
| `late` | client | 超时后才到的回包（`Resolve` 返回 false） |
| `unknown_id` | client | 伪造/重复 id |
| `dropped` | server | 被限流丢弃（只出现在汇总行） |

`code` 必须**粗粒度**：不得把 SQL 错误原文、堆栈、表名放进 `code`（那等于把诊断通道变成服务端内部探测器）。

---

## 3. 与 `phone:server:focusState` 的兼容与迁移

### 3.1 兼容原则

1. **不删旧事件**。`phone:server:focusState` 在迁移期继续注册，行为逐字节等价（同样的 `[custom-phone][focus]` 前缀、同样的字段顺序、同样的 5s per-phase 限流）。
2. **字段名不改**。`phase` / `attempt` / `focused` / `keepInput` 原样保留 —— 现有排障脚本和 `docs/client/PHONE_ARCHITECTURE.md:95` 的记录继续有效。
3. **一个限流器**。旧 handler 内部改为调用 `PhoneDiag.LegacyFocus(state)`，避免两套 `diagAt/diagDropped` 表各自计数。
4. **旧通道只认 `ui.*`**。`focusState` 的白名单只含 ui 域，防止有人把 `req.*` 塞进旧通道绕过 trace 限流。

### 3.2 phase 映射表

| 旧 phase（focusState） | 新 phase（diag, mode=event） | 备注 |
|---|---|---|
| `close-start` | `ui.close-start` | |
| `close` | `ui.close` | 带 `focused`/`keepInput`/`owner` |
| `open-start` | `ui.open-start` | |
| `open-nui-sent` | `ui.open-nui-sent` | |
| `open-ack` | `ui.open-ack` | |
| `open-ack-timeout` | `ui.open-ack-timeout` | |
| `anim-timeout` | `ui.anim-timeout` | |
| `reassert` | `ui.reassert` | 带 `attempt` |
| `loop-exit` | `ui.loop-exit` | |
| `phonefix` | `ui.phonefix` | |
| `probe-start` / `probe` / `probe-end` | `ui.probe-start` / `ui.probe` / `ui.probe-end` | 焦点探针，与 §5.3 的四段探针**不是**一回事，命名上已区分 |
| `appQuery-hit` | `req.cli.recv`（`kind=query`） | **语义升级**：不再是孤立事件，而是 trace 第 2 槽 |
| `appAction-hit` | `req.cli.recv`（`kind=action`） | 同上 |

### 3.3 迁移步骤（可回滚）

| 步 | 动作 | 验收 | 回滚 |
|---|---|---|---|
| **0** | 新增 `server/core/diag.lua`、`client/core/diag.lua`；注册 `phone:server:diag`。不动任何调用点 | `pytest tests/unit/layer3_business/test_phone_diag_protocol.py` 全绿 | 删文件 |
| **1** | `focusState` handler 体改为委托 `PhoneDiag.LegacyFocus`，日志格式不变 | 真机开/关手机一次，`grep '\[focus\]'` 输出与旧版逐行一致 | 恢复旧 handler（git revert 单文件） |
| **2** | 客户端 15 个 `TriggerServerEvent('phone:server:focusState', …)` 调用点改为 `PhoneDiag.Emit('ui.<旧名>', {…})`；`phone_diag_dual=1` 时**同时**发旧事件 | 日志里同一 phase 出现 `[diag]`+`[focus]` 各一行，字段一致 | `phone_diag_dual=0` |
| **3** | 请求链路接 trace：`PhoneBridge.Request` 读 `_diag.tid` 并剥离；`Resolve` 发 `req.cli.resp`；NUI 侧发 `req.nui.*`；服务端发 `req.srv.*` 并入内存环 | `npm run test:nui` + 新增 `diag.spec.mjs` | `phone_diag=0` |
| **4** | 全量默认 `phone_diag_dual=0`（只发新事件），`focusState` handler 仅作 shim，10 分钟打一次 deprecation | 一个版本无 `[focus]` 消费方 | `dual=1` |
| **5** | 删除 `focusState` handler、`FOCUS_PHASES`、`diagRateLimited`（逻辑已进 diag 模块） | grep 无残留 | 无（此步在 2 个版本后） |

**双写期成本**：只有 ui 域事件（开/关手机，人手触发，低频），请求域 trace **不双写**（不需要，旧通道本来就没有请求 phase 的完整链路）。所以 `dual` 开关不产生请求量级开销。

---

## 4. 采样与限流

### 4.1 为什么不能"每次都打"

单玩家 `appQuery` 上限 120/min（`server/main.lua:1378`）。若每 phase 一行：

```
120 req/min × 8 phase = 960 行/min/玩家
32 人同时刷 MDT ≈ 30 720 行/min ≈ 1.8M 行/小时
```

后果不只是磁盘：`print` 在 FXServer 主线程同步写 stdout，日志 I/O 会直接变成 tick 抖动；同时把真正有用的失败样本淹没。

### 4.2 三级开关

| level | convar | 行为 | 典型场景 |
|---|---|---|---|
| **0** | `phone_diag 0` | 客户端 `StartTrace` 直接返回 nil（零分配、零事件、零计时器）；服务端 handler 首行 return；NUI 不发 `_diag` | 生产默认**可关**；性能敏感/隐私敏感服务器 |
| **1** | `phone_diag 1`（**默认**） | 只在 `why ∈ {slow, fail, warmup, sample}` 时发一条批次 | 生产常态 |
| **2** | `phone_diag 2` | 每条 trace 都发（仍受 §4.3 限流）；ui 域事件全量 | 排障、压测、CI |

采样判据（链尾一次性判断，不逐 phase 判断）：

```lua
local slow = (t_finish - t_start) >= SLOW_MS       -- 默认 400ms
local fail = (code ~= 'ok')
local warm = (requestsSinceStart <= WARMUP)        -- 默认 3
local rand = math.random(1, 100) <= SUCCESS_SAMPLE -- 默认 0
local send = LEVEL == 2 or slow or fail or warm or rand
```

- `SLOW_MS = 400` 的依据：`docs/client/PHONE_ARCHITECTURE.md:128` 的 P95 预算是 250ms；400ms 即"已越过预算 60%"，属于值得看的样本。
- `WARMUP = 3`：`restart custom-phone` 之后头几次请求必然伴随 CEF 重载，是最容易出问题也最值得留证据的窗口。
- `SUCCESS_SAMPLE` 默认 0：成功且快的请求默认零日志。要统计分布时临时调到 1–5。

客户端缓存 level 5 秒（`GetConvar` 在热路径上不值得每次调），`setr` 改动 5s 内生效。

### 4.3 限流（按通道区分，这是关键修正）

| 通道 | 键 | 限额 | 为什么 |
|---|---|---|---|
| `mode=trace` 批次 | `diag:<citizenid 或 src>` | **20/min，burst 5**（`PhoneRateLimit`） | 批次已把 8 条压成 1 条，再按 phase 限流只会误杀并发 |
| `mode=event` ui 事件 | `(phase, src)` | **5s 冷却**（沿用 `FOCUS_COOLDOWN`） | 单次开手机几帧内连发 3 个不同 phase，per-phase 才不会互相吞 |
| 任意 diag | `src` | 120/min 硬顶 | 兜底 Flood 防护 |
| 服务端打印 | 全局 | 50 行/s，600 行/min | 保护 stdout；超额 → 丢弃计数 |
| NUI→client `phoneDiag` | 单页 | 60/min | 前端也可能写错循环 |
| 客户端缓冲 | 单客户端 | 32 条 in-flight trace × 8 phase | 内存上界 ≈ 32×8×40B ≈ 10KB |

**为什么 trace 不做 per-phase 限流**（§1 缺口 3）：`Promise.all([units, incidents])` 在同一帧产生两条 `cli.recv`。per-(phase,src) 5s 窗口会把第二条吞掉，日志上表现为"少了一条 trace"，与"真断"不可区分。批次模式下一个请求一条事件，天然的粒度就是请求，用请求级 token bucket 才语义正确。

**丢包不静默**：复用 `server/main.lua:1284-1288` 的做法，在下一次成功打印时追加

```
[custom-phone][diag] dropped src=7 n=14 window=60s reason=rate_limit
```

否则"没有日志"会被误读成"没有请求"。

### 4.4 服务端相关内存环（`mode=trace` 能拼齐三视图的前提）

服务端必须为**每个**请求记录 `req.srv.recv`/`req.srv.done`，否则客户端批次到达时无法判断 seg2/seg3 —— 但又不能为此发网络事件。

```lua
-- 定长环形，插入即覆盖最旧；条目 ~64B
diagRing = { size = 128, head = 0, ttl = 60 }
--  { tid=, src=, kind=, recvAt=, doneAt=, code= }
```

- 插入：`req.srv.recv`（handler 第一行）。
- 补写：`req.srv.done`（`replyAppRequest` 之前）。
- 消费：客户端批次到达时按 `tid` 取，取到即删。
- 淘汰：`head` 覆盖 + TTL 懒清理（不发定时器）。

128 × 64B ≈ 8KB 常驻，可忽略；即使 level=0 也不开（handler 首行 return 之前先判 level）。

---

## 5. 断点断言

### 5.1 槽位路径串

服务端打印时固定 8 槽，缺失用 `.`：

```
NS|CR|CF|SR|SD|CP|CA|ND
```

判定表（`break=` 由服务端合成，客户端不可自证）：

| 槽位 | `break` | `reason` | 现场该看什么 |
|---|---|---|---|
| 全 8 格 | `none` | — | 正常；耗时/`code` 是关注点 |
| `NS` 缺，其余在 | `seg1-partial` | `nui-not-recorded` | NUI 批次丢了（页面被卸载/`phoneDiag` 未注册），但链路是通的 |
| `CR` 缺，`NS` 在 | **`seg1`** | `nui-fetch-lost` | 回调名/资源名拼错；CEF 未就绪（`restart` 后立即操作）；CSP/URL 错 |
| `CR` 在，`CF` 缺 | `seg1.5` | `handler-abort` | handler 在转发前 return：入参非表（`bad_request`）或抛错（`handler_error`） |
| `CF` 在，`SR` 缺 | **`seg2`** | `no-server-recv` | 事件名/注册点不匹配；服务端在 `RegisterNetEvent` 之前抛错；服务端 `phone_diag=0`（先排除这个） |
| `SR` 在，`SD` 缺 | **`seg3-produce`** | `server-no-reply` | `PhoneApps.Query` 抛错、handler 走了 `bad_id` 静默 return（应已改成 `code=bad_id`）、限流分支漏了 reply |
| `SD` 在，`CP` 缺 | **`seg3-deliver`** | `response-lost` | response 事件名与 `defaultResponseEvent` 推导不一致（`bridge.lua:39-45`）；`request_id` 被服务端判非法 |
| `CP` 在，`CA` 缺 | `seg3.5` | `answered-locally` | 8s 超时已先解除 pending（或 `Clear`），回包属 `late` |
| `CA` 在，`ND` 缺 | **`seg4`** | `nui-never-settled` | CEF 侧 fetch 已 abort（9s > 8s，理论不该先 abort）；页面崩溃；`JSON.parse` 抛错 |
| `why=slow` 但 `code=ok` | `none` | — | 只是慢：看 `dt` 最大的一段 |

### 5.2 日志长这样

```
[custom-phone][diag] src=7 tid=k3f9a2 kind=query app=police_mdt code=timeout why=fail
  path=NS|CR|CF|-|-|-|CA|- break=seg3 reason=server-no-reply dt=0,2,51,8001
[custom-phone][diag] src=7 tid=k3f9a2 part=nui path=NS|.|.|.|.|.|.|ND code=abort dt=0,9002
[custom-phone][diag] dropped src=7 n=14 window=60s reason=rate_limit
```

三行读法：客户端批次给出 `NS CR CF … CA`（`SR/SD/CP` 空，因为客户端根本看不到），服务端内存环里**也没有** `SR` → 服务端确实没收到 → `seg3` 是假象，`break` 应由"服务端环里没有该 tid"优先判为 `seg2`。

**判定优先级（实现必须照这个顺序）**：

```lua
-- 1. 服务端内存环是 SR/SD 的唯一事实来源，客户端批次里的 self-report 一律忽略
if not ring[tid] then return 'seg2', 'no-server-recv' end
if not ring[tid].doneAt then return 'seg3-produce', 'server-no-reply' end
-- 2. 之后才允许看客户端/ NUI 批次推断其余段
```

这一条是整份设计里最容易写错的地方：客户端批次里"没有 `srv.*`"是**正常**的，不能据此判 `seg2`。

### 5.3 最小探针集（"四段全部可达"的证明）

一个不碰业务的合成探针，`kind='probe'`，四段各走一次，路径与真实请求**完全同形**（同一组 phase），因此**不需要单独的断言逻辑**：

```
NUI  fetchNui('phoneProbe', {_diag:{tid}})
 └─ client  RegisterNUICallback('phoneProbe')        → 发 req.nui.send 的对端
     └─ TriggerServerEvent('phone:server:diagProbe', tid)
         └─ server 立即回 TriggerClientEvent('phone:client:diagProbeResponse', src, tid, { ok = true })
             └─ client  cb({success=true}) → NUI resolve
```

- 服务端 `diagProbe` handler 是 6 行常量返回，**不查库、不鉴权、不读玩家数据**（不能让它变成新的攻击面）。
- 每玩家 30s 最多 1 次（token bucket），管理员命令 `phonedoctor [id]` 可强制一次。
- 判定输出一行：`probe src=7 tid=… seg1=ok seg2=ok seg3=ok seg4=ok rtt=41ms`；失败直接 `break=segN reason=…`。
- `kind=probe` 的 trace **不参与**"失败率"统计，避免污染指标。

**何时跑**：

| 时机 | 采样 | 说明 |
|---|---|---|
| 手机首次打开成功后 1 次 | `warmup` | 覆盖 `restart custom-phone` 后的冷启动 |
| `/phonedoctor` 手动 | `force` | 运维现场判定 |
| 连续 3 次 `code=timeout` 后 | `fail` | 自动取证，一次会话最多 2 次，防抖 |

### 5.4 负向自检（证明"检测器本身有效"）

只有"探针全绿"不能证明检测器能发现断裂。加一个**仅开发环境**的故障注入：

```
setr phone_diag_fault "drop.cli_fwd"   -- 在 client 转发前吞掉，不发向服务端
setr phone_diag_fault "drop.srv_done"  -- 服务端算完不回包
setr phone_diag_fault "strip.nui_emit" -- NUI 不发 _diag
```

在 CI/单测里对四个注入点各跑一次探针，断言 `break=` 恰好等于预期段。这个测试的价值高于任何正向用例：它把"判定表"变成了可执行断言。

---

## 6. 安全

### 6.1 为什么绝不能把完整 payload 打进日志

| 风险 | 具体后果 |
|---|---|
| **PII 落盘** | `messages`/`contacts`/`banking`/`police_mdt` 的 payload 含 `citizenid`、手机号、私信正文、余额、罚单、MDT 案件描述。日志会进 `txData`/控制台滚动缓冲，常被截图、贴进 issue、打包发给外部 |
| **越权读取** | 能看 console 的人（值班管理、外包运维、录屏观众）不等于有权读玩家私信 |
| **日志注入** | 客户端可控字符串里的 `\n` 能伪造整行日志（`server/main.lua:1301` 的 `gsub('%c',' ')` 已在 focus 通道做了，diag 必须同样做且覆盖所有字符串字段） |
| **放大攻击** | 一条 64KB 的私信正文 × 采样 = 日志体积 DoS；`clientError` 的 `stack` 同理（现截 500） |
| **不可信输入** | 改过的客户端可以往 diag 里塞任意内容；服务端日志就成了**未认证的写入原语** |
| **合规** | 玩家数据留存需要告知与期限；诊断日志不该成为影子数据库 |

### 6.2 禁止入日志的字段清单

`citizenid` · `phone_number` / `sender_number` / `receiver_number` · `name` / `title` / `content` / `message` / `description` · `amount` / `balance` / `price` · `coords` / `x,y,z` · `params`（整体） · `data`（响应体） · `stack`（可能带实参） · 任何 `playerData` 快照。

替代做法：

| 想知道 | 记录的替代量 |
|---|---|
| 是哪个 app | `app=police_mdt`（枚举，非自由文本） |
| 参数长什么样 | `plen=2k`（分桶 `<1k/1-8k/8k+`）+ `keys=mode,limit`（键名列表，≤8，每个 `^[%w_]+$`，≤24 字符） |
| 是哪个玩家 | `src=`（会话内可映射；**不落 citizenid**） |
| 是否同一条请求 | `tid`（随机，不含身份信息） |

> 若确实需要跨会话关联同一玩家，用 `cid8 = 前 8 位 HMAC(SERVER_SECRET, citizenid)`，密钥只存在服务端环境变量里；**不要**用裸 hash（citizenid 空间小，彩虹表可逆）。本期不做。

### 6.3 脱敏实现（白名单投影，不做黑名单过滤）

```lua
local ALLOW = {
  v=1, mode=1, from=1, tid=1, kind=1, app=1, code=1, why=1,
  phases=1, phase=1, seq=1, dt=1, attempt=1, focused=1, keepInput=1,
}

--- 只拷贝白名单字段；未知字段直接消失（不是过滤，是不存在）
function PhoneDiag.Sanitize(msg) end

--- 类型/字符集/长度三重收敛
function PhoneDiag.Str(value, limit, charset)  -- 非字符串 → ''；%c → ' '；超长截断
end
```

调用约定：**任何 `print` 的实参都必须是 `Sanitize` 之后的值**，且禁止 `json.encode(payload)` / `tostring(data)` 这种整表序列化 —— 白名单投影之外一律不落地。

### 6.4 伪造与滥用防护

| 攻击 | 防护 |
|---|---|
| 刷日志 | §4.3 双层层限流 + 全局打印预算；超额合并成汇总行 |
| 伪造 phase 误导排障 | 白名单精确匹配；`from` 只是自称；**判定以服务端内存环为准**（§5.2 优先级） |
| 用 `app` 字段注入 | `^[%w_%-]{1,32}$`，且不在 `PhoneApps` 注册表 → `app=other` |
| 用 `tid` 破坏日志行 | `^[%w:%-_]{3,64}$`；与 `validAppRequestId` 同界 |
| 用 `code` 探测内部 | `code` 是固定枚举，未知值 → `unknown`；不透传异常文本 |
| 用 diag 通道当免费 RPC | diag handler **无返回值、无 `TriggerClientEvent`**；`diagProbe` 是唯一的回包，且常量返回 + 30s/人 |
| 探针打别人 | `phonedoctor <id>` 需 `phone.diag` ace 权限；自探针不需要 |
| 时序侧信道 | 不把服务端内部耗时（SQL、缓存命中）细分到 phase，只对外给粗 `dt` |

---

## 7. 性能预算

| 场景 | 客户端 | 网络 | 服务端 |
|---|---|---|---|
| `phone_diag=0` | 1 次 convar 读（5s 缓存）+ 1 次比较 | 0 | handler 首行 return |
| L1 快且成功 | 3 次表写 + 1 次比较 + 1 次 `Date.now()` | **0** | 环插入 + 删除（~64B） |
| L1 慢/失败（典型） | 同上 + 1 次 JSON 序列化（~250B） | 1 条事件 | 合批 + 1 行日志 |
| L2 全量 | 同上 | ≤1 条/请求（仍然是批次！） | ≤20 条/min/玩家 |

不引入任何 `SetTimeout`/`CreateThread`：trace 的生命周期完全由现有调用点驱动（进入 handler → 回包 → 结束）。这是"低开销"的硬约束 —— **诊断不得增加计时器数量**，否则它自己会改变被观测系统的时间行为。

---

## 8. 测试接法

### 8.1 Lua 单测（pytest + lua5.4 沙箱）

复用仓库既有模式（`tests/unit/layer3_business/test_phone_request_protocol.py:34-151`）：从源码里按 marker 抽块，用确定性 stub 跑真代码。

新增 `tests/unit/layer3_business/test_phone_diag_protocol.py`，在 `client/core/diag.lua` 与 `server/core/diag.lua` 里放 `-- [phone-diag] begin/end` 标记（与 `[phone-app-protocol]` 同风格），抽取器可复用 `_protocol_block()`。

```python
DIAG_STUBS = r"""
local convars = { phone_diag='1', phone_diag_slow_ms='400',
                  phone_diag_dual='1', phone_diag_warmup='0' }
local clock = 1000
local sent, prints = {}, {}

function GetConvar(k) return convars[k] end
function GetGameTimer() return clock end
function SetTimeout(_, _) error('diag must not create timers') end  -- 硬约束
function TriggerServerEvent(name, msg) sent[#sent + 1] = { name=name, msg=msg } end
function print(...) prints[#prints + 1] = table.concat({...}, ' ') end

local function advance(ms) clock = clock + ms end
local function diagMsgs() local out={} for _,e in ipairs(sent) do
    if e.name == 'phone:server:diag' then out[#out+1] = e.msg end end return out end
"""
```

必测断言：

| 用例 | 断言 |
|---|---|
| 正常快请求（40ms，ok） | `#diagMsgs() == 0`（L1 默认不采样） |
| 慢请求（512ms，ok） | 恰好 1 条；`why=='slow'`；`#phases==3`；`seq` 严格 1,2,3；`dt[3] >= 512` |
| 超时 | 1 条；`code=='timeout'`；最后一条 phase 是 `req.cli.answer` 且 `code=='timeout'` |
| `phone_diag=0` | 失败路径也 0 条 |
| 并发两条 trace（模拟 MDT `Promise.all`） | **2 条**（回归 §4.3 的限流误杀），`tid` 不同，互不覆盖 |
| 缓冲上界 | 第 33 条 trace 挤掉最旧，`#traces <= 32` |
| 脱敏 | 传入 `{ message='x\nFAKE [custom-phone][admin] src=1', citizenid='CID7' }` → 任何 `diagMsgs()` 与 `prints` 中都不含 `FAKE`、`CID7`、`\n` |
| 禁计时器 | stub 里 `SetTimeout` 直接 `error()`，全套用例通过即证明零计时器 |
| level 缓存 | 改 convar 后 5s 内仍用旧值，`advance(5001)` 后生效 |

服务端沙箱（复用 `SERVER_STUBS`）：

| 用例 | 断言 |
|---|---|
| `validAppRequestId` 失败 | 仍写入环形 `code='bad_id'`（回归"静默 return"） |
| 客户端批次早于服务端 `SD` 到达 | 判定 `seg3-produce`，不是 `seg2` |
| 环形无该 tid | 判定 `seg2`，即使客户端批次自称有 `srv.*`（伪造） |
| 21 条 trace/分钟 | 第 21 条被丢，下一次打印含 `dropped n=1` |
| `Sanitize` | 输入未知字段 `password='x'` → 输出不含该键 |
| `path` 拼接 | 8 槽恒长，缺失为 `.`，`break=` 与判定表逐行一致（参数化 9 个用例） |

**故障注入用例**（§5.4）：`drop.cli_fwd` → 断言 `break=='seg2'`；`drop.srv_done` → `seg3-produce`；`strip.nui_emit` → `seg1-partial`；`abort.nui_after_send` → `seg4`。

### 8.2 Playwright NUI（`web/tests/nui/`）

现有 harness 已在网络边界拦截 `https://custom-phone/**`（`harness.mjs:1-14`），所以断言"前端发出了什么诊断"不需要改架构，只需记录 POST body。新增 `tests/nui/diag.spec.mjs`，在 `run.mjs:22` 的 `scenarios` 里并入。

```js
// diag.spec.mjs — 断言前端发出的诊断（不是断言 UI）
import { checkEqual, checkTruthy, waitFor } from './harness.mjs';

function requestsTo(world, name) {
  return world.requests.filter((r) => r.url.endsWith(`/${name}`));
}

export const scenarios = [
  {
    name: 'appQuery 携带 _diag.tid 且不含业务数据',
    async run({ page, world }) {
      await page.evaluate(() => window.triggerMockPhoneOpen?.('police', 'entry'));
      const reqs = requestsTo(world, 'appQuery');
      checkTruthy('发出了 appQuery', reqs.length > 0);
      const body = JSON.parse(reqs[0].postData ?? '{}');
      checkTruthy('_diag 存在', !!body._diag);
      checkEqual('tid 形状', /^[a-z0-9:_-]{6,32}$/.test(body._diag.tid), true);
      // 诊断头不得夹带业务字段（防回归：有人图省事把 params 塞进 _diag）
      checkEqual('_diag 键集合', Object.keys(body._diag).sort(), ['tid', 't0', 'v']);
    },
  },
  {
    name: 'fetch abort 时上报 code=abort',
    async run({ page, world }) {
      world.delay = 12_000;            // 超过 fetchNui 的 9000ms
      await page.evaluate(() => window.__phoneDebug?.query('police_mdt', 'units'));
      const diag = await waitFor(
        () => requestsTo(world, 'phoneDiag').map((r) => JSON.parse(r.postData)),
        15_000, 'abort 后应上报一条 diag');
      const last = diag.at(-1);
      checkEqual('终态', last.code, 'abort');
      checkEqual('末 phase', last.phases.at(-1).p, 'req.nui.done');
    },
  },
];
```

要点：

- 断言的**对象是请求体**，不是 UI 文本 —— 诊断是协议行为，不该靠像素验证。
- `world.delay` 需要在 `installNuiMock` 的路由里读，属于 harness 的小扩展（加一个 `world.delay` 字段）。
- 三条必须覆盖的路径：成功（`_diag` 存在且纯净）、abort（`code=abort`）、HTTP 500（`code=no_response` 且 `_diag` 仍在）。
- 失败时的报错沿用 harness 的「期望/实际」diff 风格（`CheckError`），CI 日志可直接读。

### 8.3 静态契约（防漂移）

仿 `test_client_protocol_uses_dedicated_events` 加一条纯文本断言：

```python
def test_diag_channel_is_shared_by_client_and_server():
    for path in (CLIENT_DIAG, SERVER_DIAG):
        src = path.read_text(encoding="utf-8")
        assert "phone:server:diag" in src
        assert "Sanitize" in src           # 脱敏函数必须在
    assert "phone:server:focusState" in SERVER.read_text(encoding="utf-8")  # 迁移期别名仍在
```

---

## 9. 落地接口签名

### 9.1 Lua（客户端 `client/core/diag.lua`）

```lua
-- [phone-diag] begin (extracted by test_phone_diag_protocol.py)
PhoneDiag = {}
PhoneDiag.PROTOCOL = 1
PhoneDiag.MAX_PHASES = 8
PhoneDiag.MAX_TRACES = 32

--- 0|1|2；convar 缓存 5s，热路径无 syscall
---@return integer
function PhoneDiag.Level() end

--- 读取 payload 里的保留字段 _diag 并剥离（返回 tid 供 request_id 复用）
---@param payload table|nil 会被就地修改：_diag 被移除，绝不下发到服务端业务层
---@return string|nil tid 合法且 <=64 字节时返回；否则 nil（调用方回退到自增 id）
function PhoneDiag.TakeTraceId(payload) end

--- 开启一条 trace；level=0 时返回 nil，后续 Phase/Finish 全部空转
---@param tid string
---@param kind string 'query'|'action'|'probe'|'ui'
---@param app string|nil
---@return table|nil trace
function PhoneDiag.StartTrace(tid, kind, app) end

--- 记录一个 phase（不发送）。超过 MAX_PHASES 时丢弃并置 trace.overflow=true
---@param trace table|nil
---@param phase string 白名单内
---@param code string|nil
---@return boolean recorded
function PhoneDiag.Phase(trace, phase, code) end

--- 结束并按采样策略决定是否上报（0 或 1 条事件）
---@param trace table|nil
---@param code string 终态
---@param opts table|nil { answered = boolean }  -- 影响 break 推断
---@return boolean sent
function PhoneDiag.Finish(trace, code, opts) end

--- ui 域单点事件（等价旧 focusState），受 per-(phase,src) 5s 冷却
---@param phase string 'ui.*'
---@param fields table|nil { attempt, focused, keepInput, owner }
---@return boolean sent
function PhoneDiag.Emit(phase, fields) end

--- 白名单投影 + 类型/字符集收敛；print 前必须过这一层
---@param msg table
---@return table
function PhoneDiag.Sanitize(msg) end

--- 四段探针；返回 tid（NUI 侧负责发起 phoneProbe）
---@return string tid
function PhoneDiag.NewProbeId() end
-- [phone-diag] end
```

客户端调用点（改造后）：

```lua
PhoneBridge.RegisterNui('appQuery', function(data, cb)
    if type(data) ~= 'table' then return cb({ success = false, error = 'bad_request' }) end
    local trace = PhoneDiag.StartTrace(PhoneDiag.TakeTraceId(data), 'query', data.app_id)
    PhoneDiag.Phase(trace, 'req.cli.recv')
    PhoneDiag.Phase(trace, 'req.cli.fwd')
    PhoneBridge.Request('phone:server:appQueryRequest', data, function(res)
        PhoneDiag.Phase(trace, 'req.cli.resp', res and res.code or res and res.error)
        PhoneDiag.Phase(trace, 'req.cli.answer', res and res.error)
        PhoneDiag.Finish(trace, (res and res.error) or 'ok', { answered = true })
        cb(res)
    end)
end)
```

### 9.2 Lua（服务端 `server/core/diag.lua`）

```lua
-- [phone-diag] begin
PhoneDiag = {}
PhoneDiag.RING_SIZE = 128
PhoneDiag.RING_TTL  = 60
PhoneDiag.TRACE_PER_MIN = 20
PhoneDiag.TRACE_BURST   = 5

---@return integer 0|1|2
function PhoneDiag.Level() end

--- 唯一的入口：校验 + 限流 + 合并 + 打印。永不回包。
---@param src number
---@param msg table 客户端原始 payload（不可信）
---@return boolean accepted
function PhoneDiag.Accept(src, msg) end

--- handler 第一行调用：写入内存环，供后续批次合并
---@param src number
---@param tid string
---@param kind string
---@return boolean recorded
function PhoneDiag.RecordRecv(src, tid, kind) end

--- replyAppRequest 之前调用：补写 doneAt/code
---@param src number
---@param tid string
---@param code string
function PhoneDiag.RecordDone(src, tid, code) end

--- 拼装 8 槽 path，返回 break 段与原因（判定优先级见 §5.2）
---@param slots table { NS=,CR=,CF=,SR=,SD=,CP=,CA=,ND= }
---@return string|nil segment  nil 表示无断点
---@return string|nil reason
function PhoneDiag.Verdict(slots) end

--- 旧通道 shim：行为与 today 的 focusState handler 完全一致
---@param src number
---@param state table { phase, attempt, focused, keepInput, owner }
function PhoneDiag.LegacyFocus(src, state) end

--- /phonedoctor 用：按 src 汇总 counters
---@param src number|nil nil = 全服
---@return table { traces, slow, fail, dropped, lastBreak }
function PhoneDiag.Summary(src) end

--- 白名单投影（服务端重做一遍，不信任客户端已脱敏）
---@param msg table
---@return table
function PhoneDiag.Sanitize(msg) end
-- [phone-diag] end
```

服务端接线：

```lua
RegisterNetEvent('phone:server:appQueryRequest', function(requestId, data)
    local src = source
    local tid = PhoneDiag.Level() > 0 and requestId or nil
    if not validAppRequestId(requestId) then
        PhoneDiag.RecordRecv(src, tostring(requestId), 'query')
        PhoneDiag.RecordDone(src, tostring(requestId), 'bad_id')  -- 不再静默
        return
    end
    PhoneDiag.RecordRecv(src, requestId, 'query')
    ...
    if not PhoneRateLimit.Allow(appRateKey(src, 'query'), 120, 40) then
        PhoneDiag.RecordDone(src, requestId, 'rate_limited')
        return replyAppRequest(..., { success = false, error = 'rate_limited' })
    end
    local ok, result = PhoneApps.Query(...)
    PhoneDiag.RecordDone(src, requestId, ok and 'ok' or 'app_error')
    replyAppRequest(...)
end)
```

### 9.3 TypeScript（`web/src/core/diag.ts`）

```ts
export type DiagLevel = 0 | 1 | 2;

export type ReqPhase =
  | 'req.nui.send' | 'req.cli.recv' | 'req.cli.fwd' | 'req.srv.recv'
  | 'req.srv.done' | 'req.cli.resp' | 'req.cli.answer' | 'req.nui.done';

export interface DiagHeader {
  v: 1;
  tid: string;
  t0: number;          // Date.now()，同机可比对
}

export interface DiagPhase {
  p: ReqPhase;
  seq: number;
  dt: number;          // 距上一 phase 的 ms（同侧）
  code?: string;
}

export interface DiagBatch {
  v: 1;
  mode: 'trace';
  from: 'nui';
  tid: string;
  kind: 'query' | 'action' | 'probe';
  app?: string;
  code: string;
  why: 'slow' | 'fail' | 'sample' | 'warmup';
  phases: DiagPhase[];
}

/** 16 位 base36；collision 概率在单客户端单会话内可忽略。 */
export function newTraceId(): string;

/** level 由 Lua 通过 SendNUIMessage('phone:diag:config') 下发，默认 0（关）。 */
export function setDiagLevel(level: DiagLevel): void;
export function getDiagLevel(): DiagLevel;

/** 挂到请求体上的最小诊断头；level=0 时返回 undefined（不上线任何字节）。 */
export function diagHeader(kind: string): DiagHeader | undefined;

/**
 * 记录一个 phase。永不抛错、永不 await、永不阻塞调用方。
 * 超出 MAX_PHASES 静默截断并置 overflow。
 */
export function notePhase(phase: ReqPhase, code?: string): void;

/**
 * 结束并按采样策略上报（最多 1 条 POST /phoneDiag）。
 * `code !== 'ok' || dur >= slowMs || level === 2` 才真正发送。
 */
export function finishTrace(code: string, opts?: { abort?: boolean }): void;

/** fire-and-forget；调用方不 await，失败静默（诊断不能反向影响业务）。 */
export function emitDiag(batch: DiagBatch): void;
```

使用点（`core/request.ts` 内，不改 App SDK 契约）：

```ts
export async function phoneRequest<T>(event, payload = {}, { timeoutMs = 9000 } = {}) {
  const header = diagHeader(event);            // level=0 → undefined
  const body = header ? { ...payload, _diag: header } : payload;
  const t0 = Date.now();
  notePhase('req.nui.send');
  try {
    const res = await fetchNui<PhoneResponse<T>>(event, body, { timeoutMs });
    notePhase('req.nui.done', res?.success ? 'ok' : (res?.error ?? 'no_response'));
    finishTrace(res?.success ? 'ok' : (res?.error ?? 'no_response'));
    return res;
  } catch (err) {
    notePhase('req.nui.done', 'abort');
    finishTrace('abort', { abort: true });
    return { success: false, error: fallbackError };
  }
}
```

> `_diag` 只加 `{v, tid, t0}` 三个短字段（≈40 字节），**绝不**放 `payload`/`params` 的任何内容。

---

## 10. 风险与开放问题

| # | 风险 | 现状/对策 |
|---|---|---|
| 1 | 跨机时钟不可比 | 只断言**顺序**与**同侧 `dt`**，不输出"端到端精确延迟"，避免伪造精度 |
| 2 | CEF 隐藏页节流 | NUI 侧 `Date.now()` 可能跳跃；`req.nui.*` 的 `dt` 标记为 advisory，判定不依赖它的绝对值 |
| 3 | 客户端可撒谎 | 判定以服务端内存环为 SR/SD 唯一事实源（§5.2）；`from` 仅作标注 |
| 4 | 批次丢失 | 客户端批次丢了 → 仍有 `NS`（NUI 批次）+ 服务端环，可判 `seg1-partial`；两者都丢 → 至少还有服务端环的 `SR/SD` 可判 `seg3-deliver` |
| 5 | 环形被刷满 | 128 条 + TTL 60s；攻击者需每请求都带新 tid，而请求本身已限流 120/min |
| 6 | 双写期日志翻倍 | 仅 ui 域双写（人手触发），请求域不双写 |
| 7 | 探针被当 RPC | `diagProbe` 常量返回、无入参回显、30s/人 |
| 8 | 与 W3C `traceparent` 的关系 | 本期不做；`tid` 结构预留了 `[%w:_-]`，未来可直接塞 32 hex |

---

## 11. 验收清单

- [ ] `phone:server:diag` 在 client/server 双端注册，schema 版本 `v=1`，未知版本丢弃并计数
- [ ] 8 个 `req.*` phase + 15 个 `ui.*` phase 全在白名单；白名单外一律丢弃
- [ ] `phone_diag=0` 时：客户端零事件、零计时器、零分配（单测用 `SetTimeout → error()` 证明）
- [ ] 快且成功的请求默认 0 条日志；慢/失败各 1 条批次（不是 8 条）
- [ ] 并发两条 trace（MDT `Promise.all`）都能出日志（回归旧限流误杀）
- [ ] `bad_id` 不再静默：服务端写入环并计入 `code=bad_id`
- [ ] `path` 恒 8 槽，9 种断点场景的 `break=` 与服务端判定表逐条一致（参数化测试）
- [ ] 任何日志行不含 `citizenid` / 手机号 / 正文 / 换行（含 `gsub('%c',' ')` 生效）
- [ ] `focusState` 在迁移期仍有响应且日志格式字节级不变
- [ ] `/phonedoctor` 输出 `seg1..seg4=ok` 或 `break=segN reason=…`
- [ ] `npm run test:nui` 新增 3 个 diag 场景通过；`pytest tests/unit/layer3_business/test_phone_diag_protocol.py` 全绿

---

## 附录 A：phase ↔ 槽位 ↔ 判定 速查

```
seg1   NUI→Lua          NS req.nui.send    ↔ CR req.cli.recv
seg1.5 Lua 内部         CR req.cli.recv    ↔ CF req.cli.fwd
seg2   Lua→Server       CF req.cli.fwd     ↔ SR req.srv.recv
seg3产 Server 处理      SR req.srv.recv    ↔ SD req.srv.done
seg3送 Server→Lua       SD req.srv.done    ↔ CP req.cli.resp
seg3.5 Lua 内部         CP req.cli.resp    ↔ CA req.cli.answer
seg4   Lua→NUI          CA req.cli.answer  ↔ ND req.nui.done
```

## 附录 B：convar 一览

| convar | 默认 | 作用域 | 说明 |
|---|---|---|---|
| `phone_diag` | `1` | 双端 | 0 关 / 1 仅慢与失败 / 2 全量 |
| `phone_diag_dual` | `1`→`0` | client | 迁移期是否同时发旧 `focusState` |
| `phone_diag_slow_ms` | `400` | client | 慢阈值（P95 预算 250ms 的 1.6 倍） |
| `phone_diag_success_sample` | `0` | client | 成功请求的随机采样百分比 0–100 |
| `phone_diag_warmup` | `3` | client | 资源启动后强制采样的请求数 |
| `phone_diag_trace_per_min` | `20` | server | 每玩家 trace 批次上限 |
| `phone_diag_trace_burst` | `5` | server | 同上，桶容量 |
| `phone_diag_lines_per_sec` | `50` | server | 全局打印预算 |
| `phone_diag_fault` | `` | dev | 故障注入（`drop.cli_fwd` 等），仅 dev |
