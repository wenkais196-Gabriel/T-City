# 情景制造器（Scenario Engine）设计稿

> 状态：设计稿（L4 架构级，未写代码、未改任何现有文件）
> 日期：2026-10-29
> 读前必读：`docs/engineering/CONSTITUTION.md`、`docs/engineering/ARCHITECTURE.md`、`docs/engineering/REUSE.md`

---

## 0. 一页结论

**它是什么**：一个跨模块的「临时 NPC 场景」运行时。用一组简单行为原语（节点图 + 动作枚举 + 阶段状态机 + leash），给警察、cartel、剧情提供同一套「服务端授权 + 客户端表现 + 服务端收口」的行为与生命周期层；生成（选模型/选坐标）仍由调用方负责。

**它不是什么**：

1. 不是 NPC 生成器——模型、外观、固定坐标已经在各模块的模板/配置里（`T-CityLite.base/resources/[custom]/custom-police/shared/npc_callouts.lua:31-160`、`T-CityLite.base/resources/[custom]/custom-cartel/config.lua:100-140`）。本层只补「行为 + 生命周期」。
2. 不是寻路/导航算法实现——寻路是 GTA 客户端能力，本层只「调用导航系统」并做可达性校验，不实现路径搜索。
3. 不是建单/派单系统——警情的建单、派单、单位状态归 `custom-police` 的 P0/P2（`police_incidents`、`police_incident_units`），引擎只对一个「已经存在的 owner 场景」跑行为。
4. 不是奖励/经济系统——奖励走调用方自己的结算路径（今天 `custom-police` 的 `Player.Functions.AddMoney`，`server/p4_npc.lua:271-275`），引擎只上报 outcome，不发钱。
5. 不是静态 NPC 摆放层——cartel 农场那种 login→resource_stop 常驻 NPC 不接入（见 §7）。
6. 不是 UI/地图层——blip、3D 提示、MDT 展示归调用方；引擎只交付场景数据与阶段告警，不带任何 NUI 语义。

**为什么值得抽这一层（用重复作证据）**：仓库里已有三套 NPC 实现，各写各的「生成、清理、超时」：

- 常驻静态：`custom-cartel/client/main.lua:40-70` 自己 `CreatePed` + `FreezeEntityPosition` + `TaskStartScenarioInPlace`，`client/main.lua:394-403` 自己清理；
- 呼叫支援（backup）：服务端只有占位 set、无状态/TTL（`docs/police/architecture/02-state-machines.md:693-698`），客户端自管驾驶/步行/战斗与清理（`docs/police/architecture/02-state-machines.md:701-714`）；
- 场景警情（callout）：`custom-police/client/npc_callouts.lua:264-343` 建场景、`client/npc_callouts.lua:112-130` 清理，服务端 `server/p4_npc.lua:298-421` 用内存 map 推场景。

三套东西里「行为层 / 阶段机 / ack 超时重发 / leash / 参与人」都缺或各写一遍。抽这一层避免第四套再抄一次。

**最大的抽象风险**：把它做成「万能层」——把派单、经济、UI、静态摆放都吸进来。本稿用 §2 的两列表格锁死边界；一旦出现「引擎要写 `police_incidents`」或「引擎要发钱」的诉求，就说明边界被突破了。

---

## 1. 现状审计（用代码说话）

### 1.1 三处 NPC 实现对比

| 维度 | 常驻静态（cartel） | 呼叫支援（backup） | 场景警情（callout） |
|---|---|---|---|
| 生成方 | 客户端 `CreatePed`（`custom-cartel/client/main.lua:53`） | 请求者客户端（`docs/police/architecture/02-state-machines.md:695-697` 记录的 `T-CityLite.base/resources/[custom]/custom-police/client/backup.lua` 实体层） | 被推场景的客户端 `CreateVehicle`/`CreatePed`（`custom-police/client/npc_callouts.lua:183,201`） |
| 预算走不走 | 不走 | 走（`backup=1` slot，`shared/npc_budget.lua:19-22`） | 走（`callout=2` slot，`server/p4_npc.lua:140`） |
| 行为表达方式 | 单一 scenario 动画（`client/main.lua:61-63`） | 客户端驾驶/步行/战斗阶段（`02-state-machines.md:708-712`） | 模板里一个字符串 `behavior='hostile'|'flee_or_fight'`（`shared/npc_callouts.lua:82,112,154`），客户端 `configureSuspect` 解释（`client/npc_callouts.lua:249-253`） |
| 生命周期 | login → resource_stop | 服务端占位 set + 预算 TTL 10 分钟（`Sweep` 释放，不通知客户端），客户端 5 分钟寿命 | 服务端内存 `spawned` map + `police_incidents` 状态；客户端 300m/60s/End 清理 |
| 谁清理 | 客户端 `onResourceStop`（`client/main.lua:394-403`） | 客户端 cleanup → `police:server:backupEnded`；服务端 `playerDropped`（`02-state-machines.md:712-714`） | 客户端 `cleanupScene`（`client/npc_callouts.lua:112-130`）+ 服务端 `broadcastEnd`/`releaseCalloutBudget`（`server/p4_npc.lua:193-207,282`） |

### 1.2 `npc_budget.lua` 已经提供了什么（真实签名）

P0 常量与纯函数（`T-CityLite.base/resources/[custom]/custom-police/shared/npc_budget.lua`）：

- `NPCBudget.MAX_GLOBAL = 6`、`NPCBudget.MAX_PLAYER = 2`、`NPCBudget.TTL_SECONDS = 600`、`NPCBudget.SWEEP_INTERVAL_MS = 60000`、`NPCBudget.SLOT_COST = { backup = 1, callout = 2 }`（`:15-22`）
- `NPCBudget.Normalize(id) -> string|nil`（`:27-32`）
- `NPCBudget.Cost(kind) -> number|nil`（`:37-40`）
- `NPCBudget.Usage(entries) -> used, byPlayer`（`:45-57`）
- `NPCBudget.CanAcquire(entries, kind, id, citizenid) -> true, cost | false, error`（`:68-88`），错误码 `invalid_kind` / `invalid_id` / `invalid_citizenid` / `duplicate` / `global_limit` / `player_limit`

服务端（`T-CityLite.base/resources/[custom]/custom-police/server/npc_budget.lua`）：

- `NPCBudget.Acquire(kind, id, citizenid) -> true | false, error`（`:39-53`）
- `NPCBudget.Release(id, reason) -> boolean`（幂等，`:60-71`）
- `NPCBudget.Sweep() -> number`（`:77-90`）
- `NPCBudget.Get() -> { used, max, byPlayer, entries }`（`:94-118`）
- `GetNpcBudget()` + `exports('GetNpcBudget')`（`:116-120`）

**结论**：预算只解决了「实体槽位计数 + TTL」，没有行为、没有阶段、没有 ack、没有 leash、没有参与人。它是本设计的输入，不是本设计本身。

### 1.3 缺什么

- **行为层/阶段**：模板只有静态 `scene` 表（车/人/偏移/朝向），行为是单字符串，没有节点图、没有阶段机。服务端 `spawned` 是内存 map，回答不了「场景是否真的建起来」（ADR-0008 代价第一条，`docs/police/architecture/06-adr/0008-npc-callout.md:39`）。
- **ack 与超时重发**：`spawned[incidentId]` 一旦置位，watcher 不再推给第二个警员；客户端 `buildScene` 失败只清本地（`client/npc_callouts.lua:545-547`），服务端仍以为已推送。ADR-0008 后续第 1 条点名要 `police:server:NpcCalloutAck`（`06-adr/0008-npc-callout.md:56`）。
- **leash**：客户端只按「玩家离场景中心」计时（`client/npc_callouts.lua:491-499`），不按 NPC 位置，AI 跑出场景无拉回（`02-state-machines.md:852`、ADR-0008 后续第 2 条 `:57`）。
- **参与人记录**：奖励只发给真正执行 close 的上报者（`server/p4_npc.lua:271-275`），`police_incident_units` 没有「参与/离场」状态，另一个从 MDT 关单的警员不参与分配（`02-state-machines.md:854`、ADR-0008 后续第 4 条 `:59`）。

### 1.4 为什么 FIT-07 从 PASS 降为 PARTIAL

ADR-0008 原文（`docs/police/architecture/06-adr/0008-npc-callout.md:42`）：

> 新增了 `T-CityLite.base/resources/[custom]/custom-police/client/npc_callouts.lua` 的 `CreateVehicle`/`CreatePed` 路径，绕过 `RequestBackup` 的预算接口；FIT-07 因此从 PASS 降为 PARTIAL（见 07）。

FIT-07 规则原文要求「客户端实体创建只允许出现在 `T-CityLite.base/resources/[custom]/custom-police/client/backup.lua`」（`docs/police/architecture/07-fitness-tests.md:252`）。callout 在 `client/npc_callouts.lua:183,201` 开了第二条生成路径，按字面规则不再是 PASS（`07-fitness-tests.md:270`）。

**当前状态（诚实交代）**：后来 `server/p4_npc.lua:140` 已把 callout 接入 `NPCBudget.Acquire('callout', ...)`，所以预算子规则已修复（`07-fitness-tests.md:23` 与 `:412` 记 PASS：backup+callout 都接入，全局 6/每人 2/TTL 10min）。但「只允许出现在 backup.lua」这个静态文件白名单仍然没改——它没有把 callout 的新文件、也没有把未来的 scenario-engine 客户端文件算进去。所以严格按 FIT-07 的规则字面，它仍停在 PARTIAL。本设计的收口动作是把这个白名单改成「所有 `CreatePed*`/`CreateVehicle*` 必须由预算 owner 收费」，见 §9。

---

## 2. 边界（管什么 / 不管什么）

| 主题 | 管（引擎负责） | 不管（归谁） |
|---|---|---|
| 奖励 | 不碰钱。只上报 outcome 与 `resolved_by`/`participants` | 调用方结算：`custom-police` 走 `Player.Functions.AddMoney`（`server/p4_npc.lua:271-275`）；cartel 走 `custom-cartel` 自己的交易事件（`server/npc_manager.lua:45-228`） |
| 建单/表 | 只写自己的 `scenario_*` 表（运行记录/事件） | `police_incidents`/`police_incident_units` 归 `custom-police`（`tests/architecture/table_owners.json` 里 `custom-police` 拥有 `police_*`）；引擎通过 `owner_ref` 关联，不跨写 |
| UI | 不碰 NUI/手机/看板。只给阶段告警事件 | MDT/手机/blip/3D 提示归 `custom-police`、`custom-phone`；引擎的客户端 runner 只负责实体与任务，不画任何 UI |
| 权限 | 只校验「这个 source 是否拥有这条 pushed scene」（session 归属） | 业务权限（在勤、警衔、ACE、是否 cartel 成员）归调用方：`custom-police` 的 `PolicePolicy`，`custom-cartel` 的 `CartelService.IsMember`（`server/npc_manager.lua:21,51`） |
| 寻路算法本身 | 不实现。只调用导航系统并做「可达性校验」（§4.6） | GTA 客户端导航（native 标 `[待核实]`） |
| 静态 NPC | 不接常驻静态 NPC（结论见 §7） | `custom-cartel/client/main.lua:40-70` 维持现状 |

---

## 3. 分层落位（严格按四平面）

| 平面 | 放什么 | 具体内容 |
|---|---|---|
| P0 Shared（纯数据/纯函数） | 模板 schema、节点/边 schema、动作枚举、阶段枚举、错误码表、leash/超时默认常量 | `scenario-engine/shared/*`；纯 table + 纯函数，供 server/client/tests 引用 |
| P2 Client | 场景 runner：模型加载、`CreatePed`/`CreateVehicle`、动作任务分发、leash、可达性探测、ack/resolve 上报、实体清理 | scenario-engine 的客户端 runner（client/runner.lua，尚未创建） |
| P3 Server | 场景权威：Create / Push / Ack / Resolve / Release / Sweep，并发与生命周期预算，运行记录落库，诊断 | scenario-engine 的服务端 service（server/service.lua，尚未创建） |
| P4 DB | 运行记录与事件表（`scenario_runs`、`scenario_events`），owner = `scenario-engine` | 迁移文件（建议 v3.13，幂等）+ `table_owners.json` 登记 |

**绝对不能进 P0**（违反 = `tests/architecture/test_plane_boundaries.py` 打回）：

- 任何 `RegisterNetEvent` / `RegisterServerEvent` / `RegisterNUICallback`；
- 任何 `TriggerServerEvent` / `TriggerClientEvent` / `TriggerEvent`；
- 任何 native（`CreatePed`、`TaskGoToCoord`、`GetEntityCoords` 等，哪怕是 `pcall` 包裹的也不行）；
- 任何 IO：`MySQL.*`、`exports[...]` 调用、`GetConvar`/`SetConvar`、`os.time()` 之外的文件/网络访问；
- `SetNuiFocus`、`SendNUIMessage`、任何 NUI 语义。

P0 里只允许：常量、`math.*`、`string.*`、`table.*`、纯函数（输入确定 → 输出确定，无副作用）。这与 `T-CityLite.base/resources/[custom]/custom-police/shared/npc_callouts.lua` 里「坐标是纯 table，不用 vector3」的理由一致（`shared/npc_callouts.lua:15-16`）。

---

## 4. 行为原语设计（本稿重心）

### 4.1 节点图模型

场景 = 一张有向图，落在 P0 纯数据。节点是「一个点 + 一个动作」，边是「怎么走过去」。

```lua
-- P0 纯数据；pos 支持世界坐标或相对锚点偏移（由调用方在模板里二选一）
Node = {
    id          = 'suspect_1',      -- 场景内稳定 id
    pos         = { x, y, z },      -- 世界坐标（或 offset = { x, y, z } 相对锚点）
    heading     = 0.0,
    action      = 'idle',           -- 见 §4.2 动作枚举
    duration_ms = 4000,             -- idle/aim/loot 等有持续时间的动作用
    label       = '嫌疑人 A',        -- 诊断与参与人展示用，不进审计 PII
    tags        = { 'hostile', 'weapon_pistol' },  -- 给策略钩子/调用方权限用
}

Edge = { from = 'suspect_1', to = 'flee_point', mode = 'run' }  -- mode ∈ walk|run|drive|teleport
```

服务端只拥有「模板 id + 锚点 + 授权」；节点图是模板的一部分（P0）。客户端在 `scene_ready` 时把图实例化并执行。这样服务端永远不需要知道 ped 的运行时状态，只知道阶段。

### 4.2 动作枚举（每项注明在哪端实现）

| 动作 | 哪一端实现 | 说明 | 本地已有 / `[待核实]` |
|---|---|---|---|
| `walk` | P2 | 步行到下一节点。服务端只记阶段 | `TaskGoToCoordAnyMeans` `[待核实]`（本地无此名） |
| `run` | P2 | 跑步到下一节点（追击/逃离） | 同上 `[待核实]` |
| `drive` | P2 | 上车开往下一节点；需要场景里已有 vehicle | `TaskVehicleDriveToCoord` `[待核实]`（本地无此名） |
| `idle` | P2 | 原地停留 `duration_ms` 或 scenario 动画 | `TaskStartScenarioInPlace`（本地已有：`custom-police/client/npc_callouts.lua:222`） |
| `aim` | P2 | 举枪瞄准某目标/方向 | `TaskAimGunAtEntity` / `TaskGunAimedAtCoord` `[待核实]`（本地无） |
| `loot` | P2（动画）+ P3（效果） | 客户端只放动作，实际「拿了什么」是调用方服务端 effect，绝不让客户端写结果 | 动画 `TaskStartScenarioInPlace` `[待核实]`；效果走调用方导出 |
| `flee` | P2 | 逃离玩家 | `TaskSmartFleePed`（本地已有：`client/npc_callouts.lua:367`） |
| `despawn` | P2（删实体）+ P3（放预算 + 记结束） | 客户端删实体，服务端 `Release` + audit | `DeleteEntity`/`DeleteVehicle`（本地已有：`client/npc_callouts.lua:98-109`） |

`hostile`（战斗）不单列成一个动作，而是节点 `tags` 里的一个策略：客户端对带 `hostile` 的 ped 在玩家进入射程后套 `TaskCombatPed`（本地已有：`client/npc_callouts.lua:372`）。这样「动作 = 意图」与「战斗 = 策略」分开，避免枚举膨胀。

### 4.3 阶段状态机（从出现到结束）

| 阶段 | 进入条件 | 退出条件 | 对外告警 |
|---|---|---|---|
| `created` | owner 调 `Create` 成功：run 行落库、并发槽已占 | `Push` 成功 → `pushed`；TTL/owner 取消 → `stale`/`cancelled` | audit `scenario.create`（不含 PII） |
| `pushed` | 服务端选定目标 source，下发场景 | 收到 `ready` ack → `ready`；ack 超时 → 重推或 `stale` | `scenario:client:Push`（server→client）+ 内部重推计数 |
| `ready` | 客户端 `Ack(runId,'ready')`：实体建成、可达性通过 | 行为图开始执行 → `running`；`reachability_failed` → `failed` | `scenario:server:Ack`（client→server，session 鉴权） |
| `running` | 客户端开始跑节点图 | 客户端上报结果 → `resolved`；实体丢失/leash 失败 → `despawned`；TTL/owner 关闭 → `stale` | 阶段变化 ack（可采样）+ audit `scenario.phase` |
| `resolved` | `Resolve(runId, outcome, detail)` 成功 | 终态 | 释放槽位 + audit `scenario.resolve` + `scenario:client:End` |
| `despawned` | 客户端上报实体丢失 / 清理完成 | 终态 | 同上，audit `scenario.despawn` |
| `stale` | Sweep 命中 TTL，或 owner 主动取消 | 终态 | 同上，audit `scenario.stale` |
| `failed` | `reachability_failed` / 内部错误 | 终态 | 同上，audit `scenario.fail` |

「对外告警」只有两类通道：net event（业务状态）与 audit（审计），诊断走 `scenario:server:diag`（宪法第 7 条，只写日志、不回包、不落 PII）。这与 `server/p4_npc.lua:298-421` 的 `sceneWatcher` 本质相同，但把 `spawned` 内存 map 换成 `scenario_runs` 落库，从而修复 ADR-0008 的「服务端没有场景生命周期表」缺口。

**迁移守卫与幂等重放**：阶段推进用「条件 UPDATE + `affectedRows` 判定」，仿 `custom-police` 的 `INCIDENT_TRANSITIONS` 表驱动（`docs/police/architecture/02-state-machines.md:407-418`）。同阶段重试 ack = 幂等成功不写第二行事件；非法阶段跳变返回 `invalid_phase`，不写任何行。`Resolve` 对已终态 run 重放返回 `idempotent=true`（仿 `server/p4_npc.lua:231-236`）。

### 4.4 路径来源：手写锚点 vs 自动生成 vs 混合

**推荐：混合，锚点手写 + 围绕锚点的局部细节自动生成。**

- **手写锚点**：模板作者给 1 个（或 3 个，像 `shared/npc_callouts.lua:41-43` 那样）确定可玩的锚点。可评审、可回归、服务端只需复验锚点合法性。
- **自动生成**：在锚点周围由客户端在 `scene_ready` 前生成 flee 点、掩体点、drive 目标等局部节点（服务端无 navmesh，生成不了）。
- **理由**：锚点全自动 = 不可评审 + 可能落在不可达处；锚点全手写 = 复用性差、卡死无法自我修复。混合把「谁负责什么」划清楚：服务端负责「在哪」、客户端负责「怎么走通」。

### 4.5 leash（对应 ADR-0008 后续第 2 条）

双层拉回，阈值放 P0 常量（默认 `LEASH_SOFT=120.0m`、`LEASH_HARD=180.0m`、`LEASH_GRACE=10s`）：

1. **软拉回**：客户端每 tick 取每个 ped 距锚点最大距离；超过 `LEASH_SOFT` → 重新下发「回最近在界节点」的移动任务（`TaskGoToCoord*` `[待核实]`）。
2. **硬拉回**：软拉回 `LEASH_GRACE` 后仍超 `LEASH_HARD` → 把 ped 重定位到锚点/最近可行走节点（重定位用「删除重建」而非瞬时传送，避免瞬移穿墙；重建走 §4.6 的可达性探测）。

同时修掉现状的一个 bug：场景放弃计时从「玩家离中心」改为「NPC 离中心」——`client/npc_callouts.lua:491-499` 现在只看玩家位置，`02-state-machines.md:852` 已记这个缺陷。

### 4.6 可达性（客户端生成模式下保证 NPC 真能走通）

服务端没有 navmesh，只能做两件事：授权锚点 + 记录失败。真正保证可达的活全在客户端 `scene_ready` 之前完成。需要求导航系统做的事（**不臆造 native 名**，具体函数一律 `[待核实]`）：

1. 给定 `(x, y)` 返回最近可行走面的 z（本地已有 `GetGroundZFor_3dCoord`，`client/npc_callouts.lua:80`；但它只给地面高度，不等于「可行走」）。
2. 判断两点之间是否存在行人可行路径，返回布尔（`[待核实]`）。
3. 把离路太远的节点吸附到最近道路/人行道点（`[待核实]`）。
4. 对 `drive` 动作返回最近可通行车道点与朝向（`[待核实]`）。

流程：客户端收到 `scenario:client:Push` → 对每个节点做「z 吸附 + 两点可行走校验」→ 全部通过才 `Ack(runId,'ready')` → 任一失败回 `Ack(runId,'reachability_failed', {node_id})`，服务端换锚点重推或置 `failed`。这样「真能走通」变成一次可观测的 ack，而不是寄希望于生成时运气。

### 4.7 复用现有客户端原语（不进 P0）

客户端 runner 不重写已经存在的能力，直接复用 `T-CityLite.base/resources/[custom]/custom-police/client/npc_callouts.lua` 里验证过的几件事（迁移时上提到引擎，`reuse_budget.json` 计数应下降）：

- 模型加载走 `CFShared.LoadModel`（`client/npc_callouts.lua:64-77`），而不是再写一个阻塞 `RequestModel` 循环（cartel `client/main.lua:42-51` 那个 300 次轮询正是 REUSE 里点名的 `loadModel` 同款隐患）；
- 关系组仇恨走 `setupRelationshipGroups`（`client/npc_callouts.lua:46-62`）；
- 地面 z 用 `GetGroundZFor_3dCoord` 的 `pcall` 包裹（`client/npc_callouts.lua:79-84`），缺失时回退到模板 z；
- 删除统一走 `SetEntityAsMissionEntity` + `DeleteEntity`/`DeleteVehicle`（`client/npc_callouts.lua:98-110`）。

这些是 P2 运行时依赖，**不进 P0**；P0 只保留它们的「要不要用」开关常量。

---

## 5. 契约

### 5.1 Bus Service（遵循 `bus.lua` 的 `Bus.RegisterService`）

模块名 `scenario`。`bus.lua:22-37` 会自动把每个方法导出为 `service_scenario_<Method>`，并对 `Bus[name]` 建命名空间；资源需按 `tests/check_bus_wiring.py` 的要求在 manifest 里 include `T-CityLite.base/resources/[standalone]/core-framework/bus.lua`。

```lua
Bus.RegisterService('scenario', {
    --- 授权一个场景实例（并发/生命周期槽位 + 落库）
    ---@param owner_module string 调用方资源名，如 'custom-police'
    ---@param owner_ref    string 调用方自己的关联键（如 police incident id），引擎不跨表
    ---@param template_id  string P0 模板 id
    ---@param anchor       table { x, y, z, heading } 服务端选定的锚点
    ---@param opts         table|nil { ttl_ms, participants_limit, owner_citizenid }
    ---@return boolean ok
    ---@return string|nil run_id 或错误码
    CreateScenario = function(owner_module, owner_ref, template_id, anchor, opts) end,

    --- 把场景推给一个目标 source（进入 pushed）
    ---@param run_id string
    ---@param source number
    ---@return boolean ok
    ---@return string|nil error
    PushScene = function(run_id, source) end,

    --- 客户端阶段回报（session 鉴权）
    ---@param run_id string
    ---@param source number
    ---@param phase  string 'ready'|'running'|'reachability_failed'|'despawned'
    ---@param payload table|nil
    ---@return boolean ok
    ---@return string|nil error
    Ack = function(run_id, source, phase, payload) end,

    --- 场景收口
    ---@param run_id string
    ---@param source number
    ---@param outcome string 'resolved'|'arrest'|'failed'|'false_alarm'
    ---@param detail  string|nil
    ---@return boolean ok
    ---@return string|nil error
    Resolve = function(run_id, source, outcome, detail) end,

    --- 幂等释放（TTL/取消/掉线兜底）
    ---@param run_id string
    ---@param reason string
    ---@return boolean released
    Release = function(run_id, reason) end,

    --- 投影只读（无 PII，字段白名单）
    ---@param run_id string
    ---@return table|nil
    Get = function(run_id) end,

    ---@return number released
    Sweep = function() end,
})
```

错误码对齐 `npc_budget.lua` 风格（`shared/npc_budget.lua:68-88`）：`invalid_template`、`invalid_anchor`、`invalid_owner`、`invalid_kind`、`invalid_id`、`invalid_citizenid`、`duplicate`、`global_limit`（并发场景上限）、`player_limit`（每 owner/公民上限）、`limit_reached`、`not_found`、`not_owner`、`invalid_phase`、`invalid_outcome`、`reachability_failed`、`ack_timeout`。

### 5.2 net event

| 事件名 | 方向 | 鉴权方式 | `diagnostic` 登记 |
|---|---|---|---|
| `scenario:server:Ack` | client → server | session：服务端校验 `source` 是否为当前 `pushed` 目标（等价 `server/p4_npc.lua:401` 的 `spawned[incidentId].source` 归属校验） | 否，进 `net_events_allowlist.json` 类别 `session` |
| `scenario:server:Resolve` | client → server | session + 服务端复验 outcome 枚举与 `owner_ref` 仍活动 | 否，类别 `session` |
| `scenario:server:diag` | client → server | 无业务载荷，白名单字段 + 限流 | **是**，类别 `diagnostic`（宪法第 4/7 条） |
| `scenario:client:Push` | server → client | 客户端校验 id/模板/锚点为合法形状（防御性）；权威仍在服务端 | 不适用（非 `RegisterNetEvent`） |
| `scenario:client:End` | server → client | 同上 | 不适用 |

服务端收到的事件全部要登记；诊断通道「永不回包、永不落 PII」（宪法第 7 条），只接受 `run_id`/`phase`/`node_id` 之类白名单字段，不做 RPC。

---

## 6. 数据模型

### 6.1 需要哪些表

**结论：需要两张新表**，因为 ADR-0008 的头号缺口就是「服务端没有场景生命周期表」（`06-adr/0008-npc-callout.md:39`），而引擎不能依赖 `police_incidents`（cartel/剧情没有这张表）。

| 表 | owner | 内容 | 备注 |
|---|---|---|---|
| `scenario_runs` | `scenario-engine` | `run_id`（服务端生成，不接受客户端）、`owner_module`、`owner_ref`、`template_id`、`anchor_x/y/z/heading`、`phase`、`status`、`pushed_source`、`resolved_by`、`end_reason`、`created_at`、`updated_at`、`ended_at` | 幂等：`CREATE TABLE IF NOT EXISTS` + `information_schema` 守卫 |
| `scenario_events` | `scenario-engine` | append-only：`run_id`、`seq`、`from_phase`、`to_phase`、`actor_kind`、`actor_id`、`detail`、`created_at` | 生命周期/审计轨迹；只 INSERT，不 UPDATE/DELETE |

owner 登记：`tests/architecture/table_owners.json` 增加一条 `{ "owner": "scenario-engine", "tables": ["scenario_*"] }`。`owner_ref` 用 `VARCHAR` 字符串关联调用方（如 police 的 `incident_id`），**不建跨表外键**，避免把两张不同 owner 的表锁死。

迁移文件名建议：迁移文件 migrations/v3.13_scenario_engine.sql（尚未创建）（幂等，仿 `migrations/v3.11_police_npc_callout.sql:16-38` 的 `information_schema` 判断）。

**资源启动落位（FIT-10 要校的第三样）**：`scenario-engine` 必须在 T-CityLite.base/configs/modules/ 下有归属——新增一个 scenario.cfg 写 ensure scenario-engine，并在 server.cfg 的 exec 列表里接上（server.cfg 是机器本地文件、不入库）；否则资源进了 resources/ 也不会被 start，FIT-10 的 cfg ↔ manifest ↔ 文件三方核对同样会报未登记。**新增资源文件后要 refresh 再 ensure**（restart 不重读 fxmanifest）。

### 6.2 落库 vs 内存

- **落库**：`scenario_runs`、`scenario_events`（场景运行记录，重启后可恢复/可对账）。
- **只在内存**：活动场景 map（`run_id -> { source, phase, last_ack_at }`）、客户端实体 handle、节点图执行状态。理由与 `server/p4_npc.lua:188-190` 的注释一致：实体句柄是进程局部的，重启后由 `Sweep` 读 `scenario_runs` 重新武装（仿 `sceneWatcher` 的恢复语义，`02-state-machines.md:855`）。

### 6.3 读投影与限流

`Get(run_id)` 返回投影字段白名单：`run_id / owner_module / owner_ref / template_id / phase / status / created_at / ended_at / end_reason`。**不回传** `resolved_by` 的 PII、不传 `pushed_source` 的裸 server id 到非 owner。列表接口（如 `ListActive`）必须 `LIMIT` 且按 `owner_module` 过滤（仿 `server/p4_npc.lua:449-455` 的 `GetActiveCallouts` 投影风格）。诊断与 `Get` 都带每 source 限流，避免把场景查询变成刷屏通道（宪法第 4/7 条）。

---

## 7. 迁移与兼容

### 7.1 现有 callout 怎么迁进来（每步可独立上线）

1. **P0 原语落库**：新增 scenario-engine 的 shared 原语（节点/边/动作/阶段/错误码）+ 离线测试。警察旧路径不动，纯加文件。
2. **引擎后端 + 客户端 runner**：新增 server/service.lua 与 client/runner.lua，带一个独立 demo 场景验证 Create→Push→Ack→Resolve 全链路。旧 callout 仍默认走老路。
3. **警察适配 + 双轨**：加 convar `scenario_engine_enabled`。`custom-police` 的 `CreateNpcCallout` 在新路径下「先 `NPCBudget.Acquire('callout')` 再 `scenario.CreateScenario`」；`sceneWatcher` 退化成薄适配器。默认仍 off，可单服灰度。
4. **翻转默认 + 删旧**：`scenario_engine_enabled` 默认 on，删除 `T-CityLite.base/resources/[custom]/custom-police/client/npc_callouts.lua` 的独立生成路径，更新 FIT-07 白名单与 `reuse_budget.json`（生成路径计数下降）。

每步验收都是可观测事实，见 §9。

### 7.2 迁移期间新老并存怎么避免双写

- **单写者标志**：同一 incident 由「创建路径」二选一决定——convar 在 `INSERT police_incidents` 之前选路，同一个单号只会被一条路径消费，不会两套都建场景。
- **预算不双计**：新路径下 `custom-police` 不再自己维护 `calloutBudget` map（`server/p4_npc.lua:37`），实体槽位仍走 `NPCBudget`，场景实例槽位走 `scenario.CreateScenario`；`CreateNpcCallout` 返回值带 `budgeted_by`，防止调用方把同一次创建扣两遍。
- **旧路径冻结**：灰度期间旧路径代码只读不改，任何 bug 都朝新路径修，避免两套逻辑同时演进。

### 7.3 `police_incidents.npc_template` 字段怎么处理

**保留不动**。它是警察侧 MDT/看板的标记（`migrations/v3.11_police_npc_callout.sql:22-26`），语义是「这条警情是 NPC 警情」，与引擎无关。引擎不写 `police_incidents`；关联用 `scenario_runs.owner_ref = <incident_id>`。未来若引擎长出模板目录，警察模板也只是「适配到引擎图模板」的映射，不替换 `npc_template` 这个字段。

### 7.4 cartel 静态 NPC 是否接入

**结论：不接（以后再说）。**

理由：cartel 的 3 个 NPC 是常驻静态——login 生成、`FreezeEntityPosition` + `SetEntityInvincible`、只有 scenario 动画、resource_stop 清理（`custom-cartel/client/main.lua:40-70,394-403`），没有阶段、没有 ack、没有 leash、没有预算诉求。把它接进来等于强迫引擎建模「永远在线」的场景，正是 §0 说的「万能层」化。等 cartel 出现**临时** NPC（raid 打手、押运护送、剧情事件）时，那些作为 scenario 接入；常驻的维持现状。

---

## 8. 宪法对照

| # | 条款 | 本设计怎么满足 |
|---|---|---|
| 1 | 服务端权威 | 锚点/模板/授权/收口全在服务端；客户端 ack 的 `phase`/`outcome` 服务端复验；`Resolve` 的 outcome 枚举服务端二次校验 |
| 2 | 写路径唯一 | 引擎不碰钱/物品；`loot` 的效果走调用方导出（`Player.Functions.*`/经济出口），引擎只发「该放这个动作」的意图 |
| 3 | SQL 参数化 | 新查询全部参数化 + 列白名单 + `LIMIT`，仿 `T-CityLite.base/resources/[custom]/custom-police/server/npc_budget.lua` 与 `server/p4_npc.lua:96-100` |
| 4 | 每个 net event 要么鉴权、要么 diagnostic | `scenario:server:Ack`/`Resolve` 走 session 鉴权并进 `net_events_allowlist.json`；`scenario:server:diag` 登记 `diagnostic`（§5.2） |
| 5 | 幂等 | `Release` 幂等（仿 `server/npc_budget.lua:60-71`）；`Resolve` 重放返回 `idempotent`（仿 `server/p4_npc.lua:231-236`）；迁移用 `information_schema` 守卫 |
| 6 | 表有唯一 owner | 新表 owner 全是 `scenario-engine`，进 `table_owners.json`；跨写 `police_*` 由 `custom-police` 自己写 |
| 7 | 诊断通道永不回包、永不落 PII | `scenario:server:diag` 只写日志、白名单字段、限流，不构成 RPC |
| 8 | 一次改动只动一个平面；跨平面显式声明契约 | 本设计跨 P0/P2/P3/P4，因此显式列出全部契约变化，见下方清单 |
| 9 | 没有测试的修复不算完成 | 每个阶段配离线测试（纯函数测 P0、静态契约测事件/表登记），先红后绿 |
| 10 | 交付三件套 | 代码 + 本设计 + `CHANGELOG.md`；push 前跑 `tools/dev/release_check.py` |

**宪法第 8 条要求的「显式声明契约变化」清单**：

1. 新增 Bus Service `scenario`（7 个方法 + 错误码集合）——跨资源导出契约；
2. 新增 net event 5 个（§5.2），其中 3 个服务端接收事件需进 `net_events_allowlist.json`；
3. 新增表 2 张（`scenario_runs`、`scenario_events`），`table_owners.json` 增加 `scenario-engine` 条目；
4. 变更 FIT-07 静态规则：从「只允许 `T-CityLite.base/resources/[custom]/custom-police/client/backup.lua`」改为「每个 `CreatePed*`/`CreateVehicle*` 必须被预算 owner 收费」；
5. `custom-police` 的 `CreateNpcCallout`/`sceneWatcher` 在灰度期间新增一条委托路径（convar 开关，旧路径保留）。

---

## 9. 分阶段计划 + 技术债

### 9.1 阶段与可观测验收

| 阶段 | 内容 | 验收标准（全部是可观测事实） |
|---|---|---|
| P0 原语 | shared 原语 + 离线测试 | `pytest T-CityLite.base/tests/unit T-CityLite.base/tests/architecture` 绿（注意 `test_npc_budget.py` 在 architecture 层，不在 unit）；Lua 测试能加载 shared 模块并断言节点/边/动作/阶段枚举；`tools/dev/reuse_scan.py` 显示 NPC 生成路径仍为 3，不新增重复实现 |
| P1 引擎骨架 | server/service.lua + client/runner.lua + demo 场景 | `restart scenario-engine` 后日志出现 `[scenario-engine] loaded`；demo 场景 Create→Push→Ack(ready)→Resolve 全链路；T-CityLite.base/tests/architecture/test_npc_budget.py 仍绿（无新旁路） |
| P2 警察适配 | `custom-police` 双轨 + convar | `scenario_engine_enabled=1` 时 `police:server:NpcCalloutAck` 语义往返成功；`=0` 时旧路径不变；`net_events_allowlist.json`/`table_owners.json` 登记通过架构测试 |
| P3 翻转收口 | 默认 on、删旧路径、更新 FIT-07 | `T-CityLite.base/resources/[custom]/custom-police/client/npc_callouts.lua` 的 `CreateVehicle`/`CreatePed` 生成代码被删除；`reuse_budget.json` 生成路径计数下降；FIT-07 更新后的规则 + `test_npc_budget.py` 双绿 |

### 9.2 与 FIT-07 的关系

FIT-07 当前的字面状态停在 PARTIAL：预算子规则已修（`server/p4_npc.lua:140` 把 callout 接入 `NPCBudget`），但「实体创建只允许出现在 `T-CityLite.base/resources/[custom]/custom-police/client/backup.lua`」这条静态白名单没改（`07-fitness-tests.md:252,270`）。**P3 阶段把它修回 PASS**，靠三样证据：

1. FIT-07 规则改为「预算收费」而非「文件白名单」，把 callout 与 scenario-engine 客户端文件合法化；
2. `test_npc_budget.py` 继续绿，且新增反向校验：注入一个「未收费的 `CreatePed`」会红；
3. `T-CityLite.base/resources/[custom]/custom-police/client/npc_callouts.lua` 独立生成路径删除，`reuse_budget.json` 同步收紧。

### 9.3 技术债表（`TD-<模块>-<序号>` 格式，与 `docs/police/TECH_DEBT.md` 一致）

| 编号 | 债 | 优先级 | 说明 |
|---|---|---|---|
| TD-SE-01 | FIT-07 静态白名单未泛化 | 高 | `07-fitness-tests.md:252` 仍只认 `T-CityLite.base/resources/[custom]/custom-police/client/backup.lua`；不泛化则引擎客户端文件会误报 |
| TD-SE-02 | 服务端无 navmesh 可达性回退 | 中 | §4.6 的「换锚点重推」依赖客户端回 `reachability_failed`；重推上限与退避需要在 P1 落地，否则一个坏模板会反复重推 |
| TD-SE-03 | 奖励仍只给关闭者 | 中 | 承接 ADR-0008 后续第 4 条（`06-adr/0008-npc-callout.md:59`）；参与人归 `custom-police` 的 `police_incident_units`，本引擎只提供 `participants` 透传，不动警察表 |
| TD-SE-04 | 引擎并发预算与实体预算两本账 | 低 | `scenario_runs` 的并发上限（`global_limit`）与 `NPCBudget` 的实体槽位是两个维度，调用方要记「先实体、后场景」的顺序，否则会漏放或双计（§7.2） |
| TD-SE-05 | demo 场景的清理与资源 stop 对齐 | 低 | 客户端 runner 的 `onResourceStop` 必须与 `client/npc_callouts.lua:562-566` 同等严格，否则 restart 残留实体 |
