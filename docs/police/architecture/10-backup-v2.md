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

> 进度：**S1 已实施**（2026-10-29，pr/94 之后的实现 PR）。其余四步未开始。

1. **只加审计** ✅：`backup.ended`（reason 白名单 `shared/backup_contract.lua` + 服务端归一 + 审计带 `live=` 存活秒数；`backup.spawned` 留给 S2，因为要等 ack 才有"已生成"的确切时刻）；
2. **加 ack 与阶段**：服务端内存表 + `backupAck` 事件；不设超时（观察一周数据）；
3. **开 ack 超时**：10s/15s 释放；`expires_at` 300s；
4. **统一寿命**：删客户端的 `UNIT_LIFETIME_MS` 自计时，改由 `BackupEnd` 驱动；
5. **任务门控**：`runBackup` 改 `GetScriptTaskStatus` 门控 + 降频。

每一步都能回滚（1–2 纯新增，3–5 有 convar 开关 `police_backup_v2`）。

---

## 12. 未采纳的方案与理由

| 方案 | 为什么不做 |
|---|---|
| 服务端 `CreatePed` + routing bucket | 424 焦点区 + 服务端 task 是 RPC（迁移后丢任务、重发会 rubber-band）；bucket 只解决可见性，且 [官方文档](https://docs.fivem.net/docs/cookbook/2020/11/27/routing-buckets-split-game-state/) 明确它是「实例化」而不是「扩大可见范围」的工具 |
| 驱动原生 wanted level（APB 那类） | 零实体管理成本，但完全不可控：不能指定单位数量、步行/开车、到场位置 |
| state bag 做 ack | 客户端实体没有服务端句柄，绑不上；且 `sv_stateBagStrictMode` 之外客户端可写 |
| 落 `police_backup_units` 表 | 生命周期 5 分钟闭环，审计行够用；长期记录留给 scenario-engine 的 `scenario_runs`，避免两张表争同一个事实 |
