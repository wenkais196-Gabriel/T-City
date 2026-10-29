# SM-06 v2：NPC 支援的生命周期契约

> 状态：设计稿（L3，写代码前评审）
> 日期：2026-10-29
> 相关：02-state-machines §6（SM-06 现状）、06-adr/0003-npc-authority.md、06-adr/0008-npc-callout.md、
> docs/engineering/scenario-engine/DESIGN.md（将来由引擎接管的形态）、FIT-07

本文只补 SM-06 缺的那一半——**服务端对「单位生命周期」的知情权**；生成方式、AI 行为仍按 ADR-0003
留在客户端。范围是「让服务端能回答这个单位到哪一步了」，不是把 NPC 搬到服务端。

---

## 0. 先对齐三条外部事实（决定方案边界）

| 事实 | 出处 | 对设计的影响 |
|---|---|---|
| OneSync 的焦点区硬编码 ~424 单位，区外实体不在客户端创建 | [OneSync 文档](https://docs.fivem.net/docs/scripting-reference/onesync/) | 服务端 `CreatePed` 不等于「服务端能控制」；远处玩家看不到 |
| 服务端建的 ped「**直到有玩家进入范围、在本地把它建出来之前，不会存在**」，此前 `NetworkGetEntityFromNetworkId` 返回 0 | [Cfx 论坛](https://forum.cfx.re/t/onesync-spawning-server-side-peds/5055919) | 「服务端生成 + 服务端 task」会给每次下发加不确定性 |
| **PATHFIND 命名空间 0 个服务端 native**（59 个全是 client-only） | [cfxnatives](https://cfxnatives.dev/natives?namespace=PATHFIND&side=server) | 可达性校验只能在客户端做，服务端只能做静态规则（距离/锚点白名单） |

另外三条生态事实：开源实现（[AIBackup2](https://github.com/blackfirefly000/AIBackup2)、
AxNaash 版）**全部客户端生成、无服务端状态、且没有 `onResourceStop`**；生产级 AI 巡逻
[gr_patrols](https://github.com/grouse-labs/gr_patrols) 用 `spawn=500 / despawn=1000` + 无人在场 dormant +
**owner 变更后重新 task**。这三点分别对应我们要补的：生命周期、清理兜底、任务重发条件。

**反例（2026-10-29 读代码确认）**：[Fenix-police](https://github.com/FenixPK/fenix-police) 确实在服务端生成——
`CreateVehicleServerSetter(...)`（server.lua:314）、服务端 `CreatePed(...)`（server.lua:347，带重试循环），
再把 `NetworkGetNetworkIdFromEntity` 得到的 netId 发给客户端（server.lua:423），客户端 `NetToVeh`/`NetToPed` 解析。
但它的注释恰好证明我们 §0 的判断：

- 客户端解析要**轮询重试**："one call isn't enough, and it can take multiple NetToVeh calls before it is not nil
  or == 0 regardless of the time that has passed since spawn"（client.lua:300）；
- 服务端 `CreatePedInsideVehicle` **不可靠**："This did NOT work, it fails far too often and gets stuck spawning
  empty vehicles"（server.lua:340）→ 只好在 +20/+20 单独生成 ped 再重试；
- **tasking 仍在客户端**：`SetPedAsCop`（client.lua:539）、`TaskVehicleDriveToCoord`（client.lua:556）。

所以"服务端生成"是可做的，但它换来的代价正是我们要避的：解析重试、ped-in-vehicle 不可靠、任务依然得回到
客户端。ADR-0003 的选择不因此改变，反而被这条反例佐证。

---

## 1. 目标 / 非目标

**目标**

1. 服务端知道每个单位处在哪个阶段，且「客户端没回报」不会把名额永久占住；
2. 结束有原因（可审计、可算指标），不再只有 `backup.request`；
3. 客户端任务下发从「每 500ms 重发」变成「事件驱动 + 任务状态门控」；
4. 全部改动可在现有结构上分步上线，不引入新资源。

**非目标**

- 不把 NPC 搬到服务端生成（理由见 §0 与 §12）；
- 不做全服可见的支援单位（那属于 routing bucket/实例化，成本见 §12）；
- 不改奖励合成（仍归调用方，见 DESIGN.md §2）；
- 不做 AI 行为原语抽象（那是 scenario-engine 的 P1/P2）。

---

## 2. 现状（代码定位，2026-10-29 核对）

| 层 | 现在是什么 | 文件 |
|---|---|---|
| 服务端 | `backupUnits[cid][requestId] = true` 占位集合；`backupCooldown[cid]`、`backupSource[src]`；`NPCBudget` 管 6/2/600s | T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua |
| 客户端 | `pending[requestId]` → `active[requestId] = {phase='driving'/'foot', combat, peds, vehicle}`；`runBackup` 每 500ms 轮询 | T-CityLite.base/resources/[custom]/custom-police/client/backup.lua |
| 持久化 | 无（只有一条 `backup.request` 审计） | — |

缺的三件事（与 02 §6.3 一致）：服务端无阶段、无生成确认、无结束审计。

---

## 3. 阶段机

阶段是**服务端记录的状态**，客户端只上报「我这边到了哪一步」。任一阶段都可以直接进 `ended`。

| phase | 进入条件 | 谁上报 | 服务端动作 | 超时 |
|---|---|---|---|---|
| `requested` | `RequestBackup` 通过权限/冷却/预算/审计 | 服务端 | 记录 `expires_at = now + 300s`，下发 `SpawnBackup` | 10s 内无 `spawning` → `expired` |
| `spawning` | 客户端收到事件、模型开始加载 | 客户端 ack | 记 `spawned_at`（第一次） | 15s 内无 `enroute` → `expired` |
| `enroute` | 车 + 2 人创建成功、开始驶向请求者 | 客户端 ack | 记 `entity_count` | 受 `expires_at` 约束 |
| `onscene` | 距请求者 ≤20m 或 30s escort 超时后下车 | 客户端 ack | 清 `enroute_at` 语义，记录到场时刻（指标） | 同上 |
| `engaged` | 发现敌对 ped（只用于指标，不影响权限） | 客户端 ack（采样） | 累加 `engaged_count` | 同上 |
| `ended` | 见下表的 reason 枚举 | 客户端 `backupEnded` 或服务端 sweep | 释放预算、写 `backup.ended`、清 `backupSource` | — |

`ended.reason` 枚举（客户端上报，服务端白名单校验）：
`timeout | dead | left | resource_stop | spawn_failed | vehicle_lost | no_alive_ped | expired`。
`expired` 保留给服务端判定（客户端不上报这个词，防伪造）。

**状态迁移规则**：只接受「同 requestId、同 source、阶段向前」的 ack；退回（`onscene`→`enroute`）
一律忽略并记 `backup.ack_rejected`（限流采样），不接受客户端指定任意 phase。

---

## 3.5 实例与目标（S7）

### 为什么支援单位**不做** routing bucket 隔离

官方 cookbook 把 routing bucket 定义为「实例化」工具，并明确写着它的用途**不包括**把
同一张地图切成可见范围：同一个桶里的人才互相可见，换个桶就意味着换一个世界（连人口、
其他玩家都换掉）。所以：

| 请求者所在桶 | 支援单位可见性 | 结论 |
|---|---|---|
| 0（主世界） | 所有人可见 | 正确：警车开在共享世界里，这才像 RP；隔离会让请求者自己变成"独自表演" |
| 非 0（私有实例） | 只在那个桶里可见 | 客户端建出来的实体天然落在本地桶，无需额外处理 |

因此 S7 只做一件事：**把请求者当时的桶记进阶段条目并在投影里暴露**（`bucket` 字段 +
控制台 `police_backup_state` 的 `bucket=`），让运维/agent 能分辨"这单在哪个实例里"，
而不是去实现一个会破坏共享世界的隔离。

### 通缉目标：支援单位该打谁

原先客户端只按关系组找"敌对 ped"，**被通缉的玩家完全不在候选里**——支援车开到场、下车、
站着。S7 补服务端权威的嫌疑人来源：

| 项 | 取值 |
|---|---|
| 数据源 | custom-main 写在 `PlayerData.metadata.wanted` 的星级（服务端读，不信客户端） |
| 半径 / 上限 | 120m / 3 人（`truncated` 标记是否被截断） |
| 投影字段 | `net_id`、`distance`、`stars`——**不含坐标、不含 citizenid** |
| 通道 | `police:server:backupTargets`（client→server 问，server 答） |
| 鉴权 | 必须持有自己的活动支援单位；每 source 3 秒限流 |
| 开关 | `police_backup_engage_wanted` 默认 **0**（NPC 打玩家容易被投诉，先让服主验手感） |

客户端拿 `net_id` 换本地 ped，只保留"活着且在 1.5×交战半径内"的，并入 `findEnemies` 的候选——
通缉玩家优先于路上的普通敌对 ped。

**S5 真机读数（2026-10-29，任务门控）**

同一晚的单 `BU-1-1793300566-1`：`spawning → enroute → onscene` 在 7 秒内走完，
此后 49 秒稳定停在 `onscene entities=3`；截图里警车已经停在玩家身边、手机停在 MDT 调度页。
也就是说"只在任务不在跑时才重发"没有把护送弄坏——车照样开到、照样下车。

门控的具体判定在 P0（`BackupContract.ShouldRetask`），golden 覆盖 1/3/7 与不可知四态；
真机只能验证"行为没退"，重发次数的差异要靠代码阅读（驱动心跳 5s、跟随心跳 6s，
原先是无条件 2.5s / 2s）。

**S4 真机读数（2026-10-29，回滚开关双向验证）**

同一张单 `BU-1-1793299992-1`（请求 18:53:12，`police_backup_ttl 20`）：

| 时刻 | `police_backup_v2` | 读数 |
|---|---|---|
| t+10…40s | `0` | `phase=onscene age=49s` —— **超过 20s TTL 仍然活着**：sweep 停手，寿命回到旧行为 |
| t+12s（切到 1 之后） | `1` | `ending=true`（BackupEnd 已发，宽限中） |
| t+18s | `1` | `no live units`；审计 `backup.expired phase=onscene;why=ttl;live=74`；客户端日志 `cleaned (reason=expired)` |

结论：寿命只有一个主人在 v2 打开时成立（客户端 `UNIT_LIFETIME_MS` 自计时被 `serverOwnsLifetime()`
守卫住，只有回滚时才生效），而回滚开关两个方向都真的生效。

**S3 真机读数（2026-10-29，`police_backup_ttl 25` 把寿命压到 25s）**

```
191 backup.request  BU-1-1793299404-1                              18:43:24
192 backup.spawned  BU-1-1793299404-1  entities=3;took=0           18:43:24
194 backup.expired  BU-1-1793299404-1  phase=enroute;why=ttl;live=38  18:44:02
```

控制台逐 5 秒读数：`enroute`（age 7/14/21/28s）→ t+25s 出现 `ending=true`（BackupEnd 已发、宽限中、
名额仍占着）→ t+30s `no live units`（宽限过、名额释放）。客户端日志同一单：
`[custom-police] backup BU-1-1793299404-1 cleaned (reason=expired)` —— 实体确实是由客户端删的。

`live=38` 而不是 25，是因为 sweep 每 10 秒一轮：过期在下一轮（≤+10s）被发现，宽限 5s 再等下一轮
（≤+10s）才释放，所以实际释放在 `ttl … ttl+25s` 之间，这是设计内的抖动。

**S2 真机读数（2026-10-29，同一次会话）**

```
169 backup.request  BU-1-1793298020-1        18:20:20
170 backup.spawned  BU-1-1793298020-1        entities=3;took=0
174 backup.request  BU-1-1793298118-2        18:21:58
175 backup.spawned  BU-1-1793298118-2        entities=3;took=0
178 backup.ended    BU-1-1793298020-1        reason=timeout;live=300   18:25:20
```

`police_backup_state`（控制台）在 18:21:58 读到 `phase=enroute entities=3`，102 秒后同一单读到
`phase=onscene`；18:25:20 该单以 `reason=timeout;live=300` 结束，**投影里立刻消失**，只剩另一单。
也就是说：`requested → spawning → enroute → onscene` 全部真的有人上报，且 ended 会清阶段。

**顺带发现的边界**：`resource_stop` 这个原因**无法在重启 `custom-police` 自身时留痕**——
客户端 `onResourceStop` 发 `backup:server:backupEnded` 的那一刻，接收它的服务端正在重启，
事件被丢掉（名额本身在内存里，随重启一起清空，不会泄漏）。所以 S3 的 sweep 才必须
自己写 `expired` 审计；不要指望 `resource_stop` 出现在审计里。

1. **只加审计** ✅：`backup.ended`（reason 白名单 `shared/backup_contract.lua` + 服务端归一 + 审计带 `live=` 存活秒数；`backup.spawned` 留给 S2，因为要等 ack 才有"已生成"的确切时刻）；
2. **加 ack 与阶段**：服务端内存表 + `backupAck` 事件；不设超时（观察一周数据）；
3. **开 ack 超时**：10s/15s 释放；`expires_at` 300s；
4. **统一寿命**：删客户端的 `UNIT_LIFETIME_MS` 自计时，改由 `BackupEnd` 驱动；
5. **任务门控**：`runBackup` 改 `GetScriptTaskStatus` 门控 + 降频。

每一步都能回滚（1–2 纯新增，3–5 有 convar 开关 `police_backup_v2`）。

---

## 3.6 撤离（S8）：到点要"开走"，不是原地消失

到点直接 `DeleteEntity` 在真机上就是"警车凭空消失"。开源实现（Mooreiche/AIBackup 的 cancel 分支）
通行做法是 **`TaskVehicleDriveWander` + `SetEntityAsNoLongerNeeded`**，让单位开走、交给引擎自然回收。
S8 照此实现，并补三条硬约束：

| 项 | 值 | 为什么 |
|---|---|---|
| 触发 | 服务端 `BackupEnd`（到点/超时）且请求者在 `LEAVE_RADIUS` 内 | 玩家跑远时直接散场，看不见就不用演 |
| 上车 | `SetPedIntoVehicle`（确定性塞座位） | 真机实测：`TaskEnterVehicle` 让 AI 自己上车 25 秒都没成功，最后照样原地被删 |
| 回收条件 | 车没了 / 距玩家 > 220m / 已不在画面（>60m 且 `IsEntityOnScreen` 为假）/ 15s 硬超时 | 前两条保证"看不见了才删"，第三条兜住卡死 |

真机（TTL 压到 20s 的单 `BU-1-1793302666-1`）：客户端日志 `retreating` → `cleaned` 间隔 **13.6 秒**，
而 S8 之前这条间隔是 **0**（同一个 tick 删掉）。

## 3.7 响应级别（B1）：一次叫几辆车

| tier | 编成 | 预算成本 | 触发方式 |
|---|---|---|---|
| 1（默认） | 1 车 + 2 名警官 | 1 槽 | MDT 按钮 / `police_backup_default_tier` |
| 2 | 2 车 + 4 名警官（错开停车位） | 2 槽（用满每人上限） | `params.tier=2` 或 convar 设 2 |

规则：

* 一次请求 = `tier` 个**独立单位**，各有自己的 `requestId` / 预算槽 / 阶段条目 —— 生命周期互不影响；
* 任何一个单位抢不到槽就**整组回滚**（`request_rollback`）：半支队伍比没有更糟，玩家会以为叫了两车；
* `tier` 由服务端夹取到 1–2（`BACKUP_MAX_UNITS`），客户端给什么都不信；
* 客户端一次收到整组 id，第二辆车往侧后错开 11m / 7m 生成，避免两车叠在一起。

真机（`police_backup_default_tier 2`）：`police_backup_state` 同时出现两行
`BU-…-1` / `BU-…-2`，`entities=3`，两单都推进到 `onscene`。

## 3.8 指挥（B2）：`/backup follow|hold|dismiss`

| 命令 | 效果 | 边界 |
|---|---|---|
| `/backup follow` | 恢复跟随（默认行为） | 只作用于调用者 `active` 表里的单位 |
| `/backup hold` | 原地待命：刹停、停掉驾驶/跟随任务，战斗照旧 | 服务端寿命与名额不动，到点照样收 |
| `/backup dismiss` | 主动撤回：回报 `dismissed` → 服务端立刻放名额 → 客户端开走（S8 撤离） | 同上 |

实现要点：

* 命令只遍历本地 `active`，不碰服务端状态；`dismissed` 已加入 `BackupContract.CLIENT_REASONS`，
  审计里不再是 `unknown`；
* 真机验收要能确认命令进了客户端，所以 `applyOrder` 打一行 `backup order=<x> applied=<n>`；
* agent 侧走 `adc <src> backup hold`：devcmd 白名单必须**逐条**写
  （Lua 的 pattern 没有 `|` 交替，`'^backup (follow|hold|dismiss)$'` 永远匹配不上）。

真机（单 `BU-1-1793304355-1`）：`order=hold applied=1` → `order=dismiss applied=1`
→ 客户端 `retreating (reason=dismissed)` → 审计 `backup.ended | reason=dismissed;live=29`。

## 3.9 滥用防护（B4）：真人有空就不让 NPC 顶班

| 项 | 规则 |
|---|---|
| 开关 | `police_backup_min_real_cops`（默认 0 = 不限制） |
| 判定 | **不含请求者自己**的在勤警察数 ≥ 阈值 → 拒绝，错误码 `police_available` |
| 留痕 | 拒绝也写 `backup.denied`（`reason=police_available;others=N;threshold=M`） |
| 语义 | 阈值 1 = "只要还有另一个在勤警官，就别叫 NPC" |

为什么排除请求者：他本人就是"在现场的那个人"，把他算进去会让阈值 1 永远成立（等于关掉支援）。

真机只能验"没触发"这一侧（本机只有一个客户端）：`police_backup_min_real_cops 1` 下
在勤他人 0 → 请求照常通过、`backup.denied` 不出现。**拒绝侧**（有第二个在勤警官时）只有 golden
覆盖（3 个用例：达到阈值拒绝并留痕、低于阈值放行、off-duty 不计入），需要第二个账号才能补真机。

## 3.10 真警协同（B3）：跟着最近的警官

`PickBackupEscort(src)` 在请求时刻算一次「这单跟着谁」：

| 情况 | escort |
|---|---|
| 附近没有其它在勤警官 | 请求者自己 |
| 有其它在勤警官 | 离请求者最近的那位（`job.onduty == true` 才算） |
| off-duty 警官 / 平民 | 永不入选 |

只算一次而不是每帧重算：位置会变，但「跟着谁」通常 5 分钟内不会变，每帧重算会让单位在两名
警官之间反复横跳。escort 随阶段条目（`escort_source`）暴露给运维；客户端 `escortPed()`
把它解成本地 ped，开车/跟随都以它为准，解析不到就回落到请求者。

真机（单客户端）：`escort=1` —— 没有其它警官时就是请求者自己，行为与 B3 之前一致。
多警官路径由 golden 4 个用例覆盖（无他人→自己、取最近、off-duty/平民不入选、投影字段），
**需要第二个在勤账号才能补真机**。

## 4. 事件契约

| 事件 | 方向 | 鉴权 | 负载（白名单） | 登记 |
|---|---|---|---|---|
| `police:server:backupAck` | client → server | session：`requestId` 必须在**本 source** 名下的活动单位里，且 phase 可迁移 | `request_id` ≤64、`phase` 枚举、`entity_count` 0–8、`t`（客户端时刻，仅诊断） | `net_events_allowlist.json` 类别 `session` |
| `police:server:backupEnded` | client → server | 同上（已实现，保留语义） | `request_id`、`reason` 枚举 | 已登记 |
| `police:client:BackupEnd` | server → client | 非 `RegisterNetEvent` | `request_id`、`reason` | 不登记（服务端下发） |
| `police:server:backupDiag` | client → server | 无业务载荷；每 source 限流 1 条/5s | `request_id`、`phase`、`task_status` | `diagnostic` |

不用 state bag 做 ack：我们生成的是**客户端实体**，服务端没有该实体的句柄，`AddStateBagChangeHandler`
绑不到；net event 是这里唯一稳妥的通道（state bag 适合将来「服务端生成」的路线）。

---

## 5. 时间语义（两套计时合一）

现在有两套互不知道的计时：客户端 5 分钟（T-CityLite.base/resources/[custom]/custom-police/client/backup.lua）
与预算 10 分钟（server/npc_budget.lua 的 `TTL_SECONDS`）。v2 把它们收敛成**一个服务端权威时刻**：

| 时刻 | 值 | 谁用 |
|---|---|---|
| `expires_at` | `requested` 时刻 + **300s** | 服务端 sweep 判过期；客户端不再自己算寿命，只按 `BackupEnd` 收尾 |
| ack 超时 | `spawning` 10s / `enroute` 15s | 服务端 sweep |
| sweep 周期 | 10s | 服务端 |
| 结束宽限 | 到点后先发 `BackupEnd`，等 **5s** 再释放预算 | 服务端 |

释放预算**永远只在服务端发生**：客户端掉线、卡死、不发消息，都不影响名额回收（这是当前最大的洞）。

---

## 6. 审计与指标

| 审计 action | 时机 | detail |
|---|---|---|
| `backup.request` | 已实现 | `requestId` |
| `backup.spawned` | 收到 `enroute` ack | `entity_count` + 客户端耗时 |
| `backup.engaged` | 首次 `engaged`（采样：每单位一次） | — |
| `backup.ended` | `ended` 时 | `reason` + 存活秒数 |
| `backup.expired` | 服务端 sweep 判超时 | 最后 phase |

可算的指标（全部从审计聚合，不新增表）：请求成功率、生成成功率（`spawned/request`）、平均存活秒数、
战斗单位占比、异常结束率（`spawn_failed|vehicle_lost|no_alive_ped`）。

### 指标面板（B5）

`tools/dev/police_backup_metrics.py` 直接把审计行折叠成四个问题的答案，不新增表、不加埋点：

| 指标 | 口径 |
|---|---|
| 生成成功率 | `backup.spawned / backup.request` |
| 平均生成耗时 | `backup.spawned` 的 `took=` |
| 平均存活 | `backup.ended` 与 `backup.expired` 的 `live=` 合并平均 |
| 异常率 | `spawn_failed \| vehicle_lost \| no_alive_ped \| unknown \| dead` 占请求数 |

真机实测（最近 6 小时，21 单）：生成成功 18（85.7%），服务端过期 13（全部 `why=ttl`），
正常结束 4（`timeout` 3 + `dismissed` 1），平均存活 133.9 秒，异常 0。

**不新增表**：一次支援的生命周期在 5 分钟内闭环，审计行足够；等 scenario-engine P1 落地再由引擎的
`scenario_runs` 接管长期记录（DESIGN.md §6.1）。

---

## 7. 客户端行为层

### 7.1 任务下发（效率）

现状是 `runBackup` 每 500ms 醒来一次（`Citizen.Wait(500)`），其中驾驶任务**每 2.5s 重发一次**
（`state.lastDriveTask > 2500`）——不是每 500ms 重发。改成：

1. **任务下发一次**：`TaskVehicleDriveToCoordLongrange` / `TaskGoToCoordAnyMeans` 只在进入阶段时下发；
2. **用任务状态门控**：`GetScriptTaskStatus(ped, SCRIPT_TASK_ANY)` = 1 表示还在执行、3 表示空闲、
   7 表示完成/找不到——只有 3/7 才重发（这是官方语义，见
   [GetScriptTaskStatus](https://github.com/citizenfx/natives/blob/master/TASK/GetScriptTaskStatus.md)）；
3. **重发时机**：阶段切换、实体 owner 变化（`NetworkGetEntityOwner` 变了）、战斗开始/结束；
4. **循环降频**：500ms → 1000ms，且只在「有活动单位」时跑（现在就是，保持）；
5. **死亡/掉车/丢目标** 走事件回调，不靠轮询发现。

> 这一条与 gr_patrols 的做法一致（owner 变更后重新 task、无人在场 dormant），也是生态里
> 唯一被生产验证过的模式。

### 7.2 通缉玩家当目标（v1 的功能缺口）

v1 的 `findEnemies` 里有一句 `and not IsPedAPlayer(ped)`
（T-CityLite.base/resources/[custom]/custom-police/client/backup.lua:298），意思是：**支援只会打 NPC，
永远不会对通缉玩家开火**。这不是 bug 而是保守取舍，但如果产品要求"支援协助抓捕通缉犯"，就必须补，且必须
按下面的方向补：

| 规则 | 做法 |
|---|---|
| 谁是疑犯**只能服务端说了算** | 服务端在 `SpawnBackup` 里附上一份已授权的 source 列表（来自 `custom-main` 的 `WantedPlayers` 缓存 + `metadata['wanted'] > 0`），客户端只认这份白名单 |
| 客户端不得自行判定 | 客户端不许读 `metadata.wanted`、不许扫描 `GetActivePlayers()` 自己挑目标——否则就是"AI 警察见谁打谁"的外挂面 |
| 距离与身份二次校验 | 服务端下发前校验：目标在线、非警察、非请求者本人、与请求者距离 ≤150m；客户端拿到后仍要 `IsPedAPlayer` + `GetPlayerServerId` 反查一致才 `TaskCombatPed` |
| 误伤不变量 | 支援不得攻击：请求者本人、任何 police job 的玩家、白名单之外的平民。写成 golden 用例（喂一份伪造 suspects 列表，断言只对白名单内的 ped 下 `TaskCombatPed`） |
| 滥用面 | 玩家可以 bait（自己通缉→叫支援→绕圈）→ 必须有冷却与人数上限；已有 60s 冷却 + 每人 2 单位，够用 |
| 结束语义 | 疑犯被捕/死亡/星级清零后，支援回到 `onscene`，不能一直处于 `engaged` |

### 7.3 AI 质量（现在只是"武装保镖"）

`configureOfficer`（client/backup.lua:159-173）目前只设了 accuracy 50、armour 50、手枪、关系组、
`SetPedFleeAttributes(0,false)`、`SetBlockingOfNonTemporaryEvents`。缺这些让它们"像警察"的属性：

| native | 值 | 作用 |
|---|---|---|
| `SetPedAsCop(ped, true)` | — | 走警察行为（对通缉等级、掩体、喊话的反应都会变） |
| `SetPedCombatAbility` | 2（professional） | 0 poor / 1 average / 2 professional |
| `SetPedCombatRange` | 1 | 0 near / 1 medium / 2 far |
| `SetPedCombatMovement` | 2 | 0 stationary / 1 defensive / 2 offensive |
| `SetPedCombatAttributes(ped, 0/1/2/5, true)` | — | 用掩体 / 用车 / 车内射击 / always fight（部分构建编号不同，实机验一次） |
| `SetPedAlertness` | 3 | 警觉度（影响先发现谁） |
| `SetPedSeeingRange` / `SetPedHearingRange` | 60 / 40 | 感知半径，默认偏小，支援经常"看不到就在旁边开火的人" |
| `SetDriverAbility` / `SetDriverAggressiveness` | 1.0 / 0.5 | 驾驶质量；结合下面的远近任务切换 |

注意 `SetPedAsCop(true)` 会让 ped 与 GTA 原生通缉/警力系统产生互动，落地前要实机确认不会引出额外的原生警察
（这与 `custom-main` 的高星接管逻辑有交叉，属于必须实测的项）。

**驾驶任务按距离二选一**（现有代码一律用 `TaskVehicleDriveToCoord`）：

- 远距离（>100m）：`TaskVehicleDriveToCoordLongrange(driver, veh, x, y, z, speed, drivingStyle, stopRange)`
  ——**8 个参数**（没有 `p6`，也没有 `vehicleModel`）；
- 近距离：`TaskVehicleDriveToCoord(driver, veh, x, y, z, speed, p6, vehicleModel, drivingStyle, stopRange, p10)`
  ——11 个参数，现有调用（client/backup.lua:480）就是它，`p6=0`。

---

## 8. 可达性（只能在客户端做）

- 客户端在 `spawning` 阶段用 `GetClosestVehicleNodeWithHeading` 校验锚点；节点未 streamed 时该 native
  会失败 → 视为不可达，ack `phase='reachability_failed'`；
- 服务端收到后：换下一个锚点（模板里预置 2–3 个候选）重推一次；再失败则 `ended(reason='spawn_failed')`；
- 服务端**不做**任何寻路判断（PATHFIND 全为 client-only），只做距离/锚点白名单/上限校验。

---

## 9. 不变量

1. `requestId` 由服务端生成，客户端不得复用或猜测；不同 source 的 requestId 互不可见；
2. ack 只接受「本 source + 活动单位 + 阶段向前」，其余丢弃并计数；
3. 预算释放幂等：重复 `backupEnded` / sweep 命中同一个单位都不产生二次释放；
4. 上限仍由 `NPCBudget` 单点裁决（6/2/600s），v2 不引入第二本账；
5. 任何 `ended` 都必须有一条审计，且 `reason` 在白名单内。

---

## 10. 测试计划

| 层 | 用例 | 证明什么 |
|---|---|---|
| Lua golden（agent harness） | ack 超时释放、阶段乱序被拒、`expired` 不被客户端伪造、重复 ended 幂等 | 状态机与鉴权 |
| 架构闸门 | 新事件必须登记 allowlist；`backupAck` 的 payload 白名单与代码一致 | 宪法第 4 条 |
| 真机 | 开支援 → 看 `/live` 里单位阶段推进；直接把客户端 `active` 清掉模拟卡死 → 15s 内名额回收 | 兜底真的生效 |
| 回归 | 现有 `RequestBackup` 的权限/冷却/上限/审计用例全绿 | 不破坏已实现部分 |

---

## 11. 分步上线（每步可独立部署）

> 进度：**S1–S5、S7、S8（撤离）、B1–B5 全部实施**（2026-10-29）。证据见下方真机记录；S7 的战斗落地还需要第二个客户端才能验完。

### S1 真机记录（2026-10-29，真实客户端 `src=1 / DXI50064`）

```
164  backup.request  DXI50064  BU-1-1793296922-3  18:02:02   ← 手机 MDT「请求支援」真的发出去
148  backup.ended    BU-1-1793296384-1  reason=timeout;live=301  17:58:05  ← 客户端 5 分钟寿命 → cleanup → 服务端审计
146  backup.request  DXI50064  BU-1-1793296384-1  17:53:04
```

`live=301` 是服务端用预算条目的 `at` 算出来的存活秒数（5 分钟 + 1 秒轮询偏差），
说明"原因 + 时长"这条路端到端通了；白名单外的原因由 golden 用例覆盖（记 `unknown`）。

## 12. 未采纳的方案与理由

| 方案 | 为什么不做 |
|---|---|
| 服务端 `CreatePed` + routing bucket | 424 焦点区 + 服务端 task 是 RPC（迁移后丢任务、重发会 rubber-band）；bucket 只解决可见性，且 [官方文档](https://docs.fivem.net/docs/cookbook/2020/11/27/routing-buckets-split-game-state/) 明确它是「实例化」而不是「扩大可见范围」的工具 |
| 驱动原生 wanted level（APB 那类） | 零实体管理成本，但完全不可控：不能指定单位数量、步行/开车、到场位置 |
| state bag 做 ack | 客户端实体没有服务端句柄，绑不上；且 `sv_stateBagStrictMode` 之外客户端可写 |
| 落 `police_backup_units` 表 | 生命周期 5 分钟闭环，审计行够用；长期记录留给 scenario-engine 的 `scenario_runs`，避免两张表争同一个事实 |
