---
id: archive-2026-11-abstraction-audit
type: research
status: archived
system: meta
owner: hermes
updated: 2026-11-15
review_by: 2027-03-31
---

> 本文件放在归档目录：它是 2026-11-15 的**时点证据**，正文里的资源内相对路径当时成立、现在不保证，
> 所以不进活跃文档的断链闸门。仍可执行的施工计划见 `docs/engineering/2026-11-abstraction-convergence-plan.md`（S1–S7，已全部合入）的
> **唯一来源**。审计是只读的：所有结论带 `path:line`，⛔ 项表示当时未取证。
> 施工计划落地的部分见计划文档与 CHANGELOG；本文件保留当时的完整判断与证据，不随后续改动更新。

# T-City 抽象设计审计（2026-11-15）

> 审计对象：`E:/T-City`（master）。工作区中 10 个已修改 + 2 个未跟踪的热狗任务文件与本次审计无关，本文未评价、未触碰。
> 事实来源：`abstraction_facts_final.md`（下称“底稿”，引用到节号）。**底稿只提供数字，本文所有判断都回到源码核实**。
> 路径约定：未特别说明时，`path:line` 均相对 `T-CityLite.base/`，例如 `resources/[custom]/custom-market/server/main.lua:265`。
> 三态标记：✅ 有代码/闸门/数字支撑；⚪ 结构上成立（附推理链）；⛔ 未验证（写明缺什么证据）。
> 本次审计只读仓库：除本报告外没有写入、格式化或修改任何仓库文件。

## 0. 结论摘要

四平面设计对：结构规则全仓执行，语义规则（查询/导出契约）只覆盖最大几个资源。Bus 不是执行失败，是**设计选错机制**：`_G.Bus` 每个资源私有，跨资源永远拿不到，`RegisterService` 只生成 `service_*` 导出。所谓“26 服务、中位采纳 0”统计的是导出调用；真正跨资源的 `Bus.<service>` 成功调用点 **0**，`exports[...]:service_*` **33**。总线那一半从未存在，另一半只是导出命名器。风险不在数量而在语义分叉：钱/奖励网关、DB 结果归一化、反滥用限流、证据广播会丢钱/丢物品/绕限流/泄数据；`DebugPrint`、通知、3D 文字、进度条参数属观感，已定案或不该合并。

| 问题 | 根因 | 处置 |
|---|---|---|
| 服务注册了却没人用、调用点静默失效 | `_G.Bus` 资源私有 + 无跨资源方法契约 + 5 个 Phase 2/3 占位服务 + 生成式导出名不可静态验证 | 保留 `exports[...]:service_*` 为唯一写法；补方法级导出契约闸门；删除/降级占位服务 |
| 钱/物品/DB 各写一套 | 资源拆分后 owner 被删或改名，调用点未迁；oxmysql 返回值归一化至少有 6 处独立实现（19 个文件出现这些结果形状） | 先修 `custom-main`/`custom-economy` 死调用并迁到 `core_economy:TriggerReward`/`Player.Functions`；再抽 DB 结果适配器 |
| 安全原语重复而闸门是绿的 | 限流闸门只认固定变量名，`liveBuckets`/`policeAlertCooldown` 等别名绕过；证据用 `-1` 广播给所有人 | 扩展限流闸门的语义标记；广播按受众收口，证据只发在岗警察 |

## 1. 判定：哪层抽象对了、哪层错了

### 1.1 四平面：设计正确，执行只到“结构”一层 ✅/⚪

`docs/engineering/ARCHITECTURE.md:19-43` 的四平面是有向无环的：P1→P2→P3→P4，P0 只被引用、不反向依赖。它和 FiveM 的真实运行时边界一致（NUI 在 CEF、客户端/服务端各自 Lua 状态、DB 只在服务端）。**这一层的设计判为正确**，不需要推翻。

但“执行”要分两半看：

| 规则 | 闸门 | 实际覆盖 | 判定 |
|---|---|---|---|
| 平面越界（client 碰 DB、server 碰 NUI、shared 注册事件、manifest 把 server 塞进 client） | `tests/architecture/test_plane_boundaries.py:71-94` | **全仓** `resources/**` 的 `client/`、`server/`、`shared/` 目录 | ✅ 结构层已执行 |
| net event 鉴权 | `test_net_event_auth.py:48-55` + `test_net_event_inventory.py:1-16` + `test_net_event_scope.py:109-124` | `test_net_event_scope` 对**全仓服务端**未登记事件兜底；`test_net_event_auth` 对 4 个资源做更强的 allowlist/helper 形状验证；其余用基线棘轮 | ⚪ 结构层全仓已执行，语义层是“存量债 + 只许变少” |
| 查询纪律（`SELECT *`/`LIMIT`/拼接） | `test_query_discipline.py:41-47` | 只扫 custom-police、custom-phone、custom-justice、qb-prison | ⚪ 最大的 SQL 资源覆盖了，其余没扫 |
| 导出契约（鉴权/审计/错误码/敏感读） | `test_export_contracts.py:47-49` | **只有 custom-police**（且阈值 `>= 42` 个导出） | ⚪ 单资源样板，不是全仓规则 |
| 表归属 | `test_cross_resource_writes.py:41-52` | 10 个资源 + `police_*`/`justice_*`/`phone_*` 热点表 | ⚪ 有 owner 的表才判，未登记的表不判 |
| 资源接线 | `test_resource_wiring.py:350-367` | 只验证 `exports['<res>']` 里的 **资源名** 已启动；`EXPORT_RE` 在 `:51` 只抓资源名，**不抓方法名** | ✅ 已证明：跨资源方法契约没有闸门 |

**结论**：四平面的“依赖方向”是对的，也真的被结构闸门守住了；“跨资源调用”这一层只守住了“资源存在”，没守住“方法存在/签名/失败语义”。后文所有 Bus 与死调用问题都落在这个缺口里。

另外有一个**闸门自身的分类漏洞**：`bus.lua` 放在 core-framework 资源根目录、由 `shared_scripts` 加载（`resources/[standalone]/core-framework/fxmanifest.lua:14-19`），它不是纯数据/纯函数（调用 `exports()`、`print()`、维护可变表），却因为不在 `shared/**` 下而逃过 P0 检查（`test_plane_boundaries.py:83-87` 只扫 `shared/**`）。这不是平面模型错，是“平面判定按目录而不是按副作用”的执行缺口。

### 1.2 Bus：设计错误，不是执行失败（✅ 已证明）

Bus 的失败不是“大家不知道/懒得用”，而是**它承诺的机制不存在**。五条可证伪的判据：

**判据 1：`_G.Bus` 跨资源不可见。**
`bus.lua:13-14` 写 `_G.Bus = _G.Bus or {}`，注释称 “lua54: 显式 _G 确保跨资源可见”。这是错的。FiveM 每个 resource 一个 Lua 状态；仓库自己的闸门就写明了这一点：`tests/architecture/test_economy_service_single_registrar.py:8-9`——“`_G.Bus` 是**资源私有**的（FiveM 每个 resource 一个 Lua 状态）”。custom-market 的实现注释也写明了：“Bus 是每个资源独立的 Lua state，跨资源拿不到”（`resources/[custom]/custom-market/server/main.lua:265-266`）。**同一仓库里，注释和闸门对同一个事实给出了相反说法，而闸门是对的。**

**判据 2：跨资源 `Bus.<service>.<method>` 成功调用点 = 0。**
在注册资源之外，所有 `Bus.<service>` / `_G.Bus.<service>` 读取都落在 nil 上。可以逐个点名的失败点（细节见 §5）：

| 位置 | 写法 | 结果 |
|---|---|---|
| `resources/[custom]/custom-police/server/p2_system.lua:1904` | `Bus.JobService.SetJob` | `Bus` 为 nil；fallback 到 `Player.Functions.SetJob` |
| `resources/[custom]/custom-police/server/vehicle.lua:95` | `Bus.SafeCall('atmosphere','PlayScene')` | nil，**无 fallback**，追车 BGM 不放 |
| `resources/[qb]/qb-ambulancejob/server/main.lua:120,284` | 同上 | nil，**无 fallback**，重生/死亡场景不放 |
| `resources/[qb]/qb-storerobbery/server/main.lua:552` | 同上 | nil，**无 fallback** |
| `resources/[qb]/qb-vehicleshop/server/integration.lua:65-66` | `Bus.vehicles.GetState` | nil；pcall 捕获后走静态导出兜底 |
| `resources/[custom]/custom-taxes/server/transaction_monitor.lua:58,106` 等 5 处 | `_G.Bus.SinkService.Withdraw` | nil；fallback 到 `RemoveMoney`，但 sink 记账/热度不算 |
| `resources/[qb]/qb-shops/server/main.lua:52-53` | `_G.Bus.NPCPricing.GetBuyPrice` | nil；fallback 到 basePrice |
| `resources/[system]/production-freeze/server/main.lua:113-116` | `_G.Bus.HeatService` | nil；guarded，热力重置不执行 |
| `resources/[custom]/custom-phone/server/banking.lua:35` | `_G.Bus.EconomyService` | nil；fallback 到原语 `Player.Functions` |
| `resources/[qb]/qb-core/server/functions.lua:784-785` | `_G.Bus.notify.Send` | qb-core 自己的 Bus 里没有 notify；fallback 到 `QBCore:Notify` |

**判据 3：`Bus.RegisterService` 只是导出生成器，不是总线。**
`bus.lua:22-33` 的唯一实际动作是 `Bus[name][method] = fn` + `exports('service_<name>_<method>', fn)`。前者只对注册进程可见，后者才是跨资源通道。也就是说：**Bus 的唯一有价值产物是 `service_*` 导出名**，而调用方也确实只用了这些导出名（见 §2）。`Bus.GetService`/`SafeCall` 只在注册进程内有意义。

**判据 4：五个服务是字面量占位。**
`resources/[standalone]/core-framework/contracts.lua:36-216` 注册的 `reputation`/`chronicle`/`governance`/`cosmetics`/`funnel` 全部返回 `false, 'Phase 2'`、`nil`、`'tutorial'`。它们被 `Bus.RegisterService` 导出成真实可调用的 `service_reputation_*` 等名字——**导出存在，能力不存在**。这不是“采纳率为 0”，是“没有可采纳的东西”。

**判据 5：目标用户不存在。**
`Bus.Plugin`（`bus.lua:82-198`）是给第三方模组用的注册/订阅契约；全仓没有任何 `Bus.Plugin.Register(...)` 调用点，只有 atmosphere 和 notify 在各自进程里 `Subscribe/Publish`（`resources/[system]/tcity-atmosphere/server/atmosphere_service.lua:490-495`、`resources/[standalone]/core-framework/services/notify_service.lua:171-189`）。所谓“第三方模组”从未出现。一个为不存在的消费者设计的 API，采纳率当然是 0。

**反过来，哪层抽象是对的？** 同目录的 `CFShared` 是一个正例：`core-framework/client/shared.lua:1-16` 明确写“逐帧调用的东西用 `@resource` 加载期包含，不过 exports”，`DrawText3D`/`LoadModel` 都按这个规则做，REUSE.md §5 也把 `DrawText3D` 记为已收敛（`reuse_budget.json` 的 `DrawText3D` 条目）。**加载期包含 vs 调用期导出**这个区分是对的，Bus 恰恰错在把“调用期导出”包装成了“进程内全局”。

## 2. 采纳率为 0 的根因

### 2.1 先纠正统计口径：底稿 G 统计的不是 Bus

底稿 G 的“调用方资源数”来自 `service_*` 导出的调用点，不是 `Bus.<service>.<method>` 的调用点。把两者拆开（底稿 F 表 + 本次逐点核实）：

| 写法 | 实际调用点 | 说明 |
|---|---|---|
| `exports['<owner>']:service_<name>_<method>` | **33**（cartel 10、notify-test 11、mining 5、justice 4、market 1、crime 1、police 1） | 这是**导出**在跨资源工作，不是 Bus |
| `Bus.<service>.<method>`（注册资源内部） | 约 20 个 token，绝大多数是注册/自补丁 | 只在注册进程内有效 |
| `Bus.<foreign service>.<method>`（跨资源） | **0 个成功**；11 个文件、约 15 个失败点 | 见 §1.2 判据 2 |
| `Bus.Plugin.Register` | 0 | 目标用户不存在 |

所以“26 个服务 / 174 个导出，中位采纳率≈0”要改写成：**174 个动态导出里，只有 33 个调用点、集中在 9 个服务；其余 18 个服务的导出从未被外部调用。** 这不是需求不足，是供给机制错位。

### 2.2 根因分类（不是“大家都懒”）

先把问题提示里的五个猜测映射到根因，避免“逐条回答”变成散点：

| 提示里的猜测 | 对应根因 | 结论 |
|---|---|---|
| 签名不匹配 | R5 | 部分成立：`economy` 返回 `scaledAmount, multiplier`，调用方当布尔用；`notify` 的 native/NUI 通道不同 |
| 启动顺序依赖 | R6 | 存在，但不是主因；`service_*` 是调用期解析，真正的问题是 Bus 跨资源恒 nil |
| 不知道存在 | R7 | 成立但责任在治理：`ARCHITECTURE.md`/`REUSE.md` 都不认 Bus，闸门还推荐它 |
| 文档缺失 | R7 | 成立：Bus 从未进入“唯一通道速查”；服务方法没有参数/返回/失败码文档 |
| 后来者自己写更快 | R8 | 成立：导出一行、可静态检查；Bus 要跨进程、名字更长、失败被压成 `false, nil` |
| 抽象是给谁写的、那个“谁”不存在 | R9 | 成立：`Bus.Plugin.Register` 0 调用；`contracts.lua` 的 5 个 Phase 2/3 服务没有产品 |

**R1｜没有实现，只有占位（5 个服务）。** `reputation`/`chronicle`/`governance`/`cosmetics`/`funnel` 在 `contracts.lua:36-216` 是 Phase 2/3 占位。注册它们会让 `BusStatus` 与 `service_*` 导出看起来“已就绪”，但调用即返回失败。**这一类不该用“采纳率”衡量，应该直接从 Bus 注册表里删掉或标成 `planned`，不要导出。**

**R2｜跨资源机制不存在（所有 `Bus.<foreign>` 调用）。** `_G.Bus` 是资源私有（判据 1）。调用方写 `Bus.storage.CanAccess` 在**任何非 custom-storage 的资源里**都是 nil。这不是签名不匹配，也不是不知道，是**physically cannot work**。custom-market 的注释已经把这件事写明并改用了导出（`main.lua:265-266`）；其余资源没有改，于是留下死分支。

**R3｜调用方绕过 Bus，直接用生成的导出名（9 个服务）。** `storage`（`custom-cartel/server/drug_lab.lua:193`、`custom-mining/server/smelter.lua:64`）、`economy`（`custom-cartel/server/npc_manager.lua:201`、`custom-market/server/main.lua:270`）、`job`（`custom-cartel/server/main.lua:144`、`custom-justice/server/main.lua:182`）、`security`（`custom-cartel/server/drug_lab.lua:82`、`custom-mining/server/main.lua:120`）、`market`（`custom-cartel/server/npc_manager.lua:93`）、`cartel`（`custom-crime/server/crime.lua:392`）、`atmosphere`（`custom-cartel/server/drug_lab.lua:251`、`custom-justice/server/prison.lua:266`）、`world_trace`（`custom-police/server/p0_incidents.lua:282`）、`notify`（`notify-test/server/test.lua:37-99`）。**这些调用能工作，恰恰因为它们是 exports，不是 Bus。** 底稿 G 把它们算成“Bus 采纳”，是口径错误。

**R4｜只有 owner 自己用 / 根本没有消费者（13 个服务）。** `patron`、`persistence`、`metadata`、`world_state`、`rateLimit`、`justice`、`mining`、`quest`、`vehicles`、`story`、`dashboard`、`police`、`dealership` 的 `service_*` 导出没有任何外部调用点。以 `vehicles` 为例：`custom-vehicles` 同时注册静态导出 `GetVehicleState`/`HasKeys`（`server/vehicle_state.lua:376`、`server/main.lua:318-324`）和 `service_vehicles_*`（`server/vehicle_state.lua:414-428`），外部唯一实际调用是静态 `exports['custom-vehicles']:HasKeys`（`resources/[system]/tcity-dashboard/server/security.lua:93`）；`service_vehicles_*` 只出现在注册代码和启动日志里。`dealership` 更彻底：qb-vehicleshop 的 `server/bus.lua` 从未定义 `Bus`、fxmanifest 也没有包含 `@core-framework/bus.lua`（`resources/[qb]/qb-vehicleshop/fxmanifest.lua:15-23`），所以 `Bus.RegisterService('dealership', ...)`（`server/bus.lua:330-331`）根本不会执行；fxmanifest 第 50-58 行列出的 8 个 `service_dealership_*` 导出**一个都不存在**。这是“注册代码在，服务不存在”的极端例子。

**R5｜同名/近义但语义不同，采纳会改变行为（3 个关键服务）。**
- `metadata`：core-framework 的 `MetadataService` 维护一份与 qb-core 并行的缓存，并**直接改 `Player.PlayerData.job` 和 `entry.metadata[key]`**（`services/metadata_service.lua:55-63,84-95`），绕过 qb-core 的 `Player.Functions.SetJob/SetMetaData` 及其安全校验。它的 0 采纳是**好事**；如果被采纳，就是第二条玩家状态写路径，违反“表有唯一 owner”和 qb-core 的校验链。**这类服务不是“没人用”，是“不该用”。**
- `notify`：服务端 `NotifyService.Send` 走 native/NUI 通道（`services/notify_service.lua:196-206`），而 custom-police 等资源用的是 `TriggerClientEvent('QBCore:Notify', ...)`（例如 `custom-police/server/evidence.lua:368`），custom-phone 又有自己的 NUI 通知（`custom-phone/server/core/notify.lua`）。三种通道语义不同，合并会改观感/延迟。
- `economy`：`EconomyService.AddScaled(source, accountType, amount, reason)` 返回 `scaledAmount, multiplier`（`services/economy_service.lua:39-73`），而调用方 custom-cartel/custom-market 用 `pcall` 只取“调用没抛错”，并不检查返回值（`custom-cartel/server/npc_manager.lua:199-207`、`custom-market/server/main.lua:267-275`）。签名是“返回值协议”，调用方当“布尔协议”用；目前靠 fallback 掩盖。

**R6｜启动顺序/调用期解析（不是主因，但会放大失败）。** `RegisterService` 在 owner 启动时执行；调用方若在加载期缓存 `Bus.x` 或 `exports[...]:service_*`，启动顺序变化就会拿到 nil。REUSE.md §2 已经把正确写法写成“调用时解析”（`docs/engineering/REUSE.md:35-40`），`test_reuse_budget.py:111-133` 也钉住了 `loadAnimDict` 的惰性包装。但 Bus 的文档从未把这条规则写成契约，于是出现 atmosphere 的 30 秒重试（`tcity-atmosphere/server/atmosphere_service.lua:499-509`）——Bus 就在同一个 shared_scripts 里，重试是无效的防御；真正需要重试的是跨资源导出的存在性。

**R7｜治理/文档缺位：Bus 从未被架构文档承认。** `ARCHITECTURE.md:65-74` 的“唯一通道速查”只列了 exports 和 net events，**没有 Bus**；`REUSE.md` 全文没有 Bus；`CONSTITUTION.md` 也没有。也就是说，后来者按“应然”文档写代码时，正确做法就是 `exports`/`TriggerClientEvent`，而 Bus 是一个未登记的第二通道。更糟的是，`test_no_monkey_patch.py:38-39` 在给出修法时还写着“优先改成 export / Bus 服务”——闸门本身在推荐一个跨资源不可用的抽象。**这是“不知道它存在”的根因，但责任在治理，不在开发者。**

**R8｜抽象没有成本优势。** 一个跨资源调用，直接写 `exports['custom-storage']:service_storage_CanAccess(src, org)` 是一行；用 Bus 要先确保本进程有 Bus、再确保服务在本进程注册过（不可能），或者退回导出。生成名 `service_storage_CanAccess` 比静态名 `CanAccess` 更长，且没有类型/错误码/版本；`Bus.SafeCall` 只多做一次 `pcall`，却把失败压成 `false, nil`，调用方拿不到原因（`bus.lua:51-68`）。**在没有类型/契约收益的前提下，后来者写导出更快且更可靠。**

**R9｜“抽象是给谁写的、那个谁不存在”。** `Bus.Plugin` 面向第三方模组（`bus.lua:70-80`）；仓库里没有第三方模组，`Bus.Plugin.Register` 0 调用。`contracts.lua` 面向“Phase 2/3 的游戏设计”（编年史/声誉/共治/外观/漏斗），这些系统在代码里没有实现、在配置里没有开关、在启动集里没有消费者。**这两类 API 都是为尚未存在的产品阶段写的。**

### 2.3 逐 service 判定（底稿 G 的 27 个服务名）

> 口径说明：提示里写“26 个 service”，底稿 G 的表实际列了 27 行（`dealership_client` 是 qb-vehicleshop 的客户端服务，未入表）。本文按 G 表的 27 行逐条；多出来的一行不影响结论。

| service | 注册位置 | 实现状态 | 外部实际调用 | 根因 | 判定 |
|---|---|---|---|---|---|
| `chronicle` | `core-framework/contracts.lua:70-92` | 占位（返回 nil/false） | 0 | R1 | 删导出或标 planned |
| `cosmetics` | `contracts.lua:154-186` | 占位 | 0 | R1 | 同上 |
| `funnel` | `contracts.lua:193-216` | 占位 | 0 | R1 | 同上 |
| `governance` | `contracts.lua:99-137` | 占位 | 0 | R1 | 同上 |
| `reputation` | `contracts.lua:36-63` | 占位 | 0 | R1 | 同上 |
| `economy` | `core-framework/services/economy_service.lua:159-166` | 真实，内部走 `Player.Functions.AddMoney` | 2：`custom-cartel/server/npc_manager.lua:201`、`custom-market/server/main.lua:270` | R3/R5 | 保留，但只作为便利层；奖励统一走 `core_economy:TriggerReward` |
| `job` | `services/job_service.lua:293-306` | 真实，`SetJob` 走 `Player.Functions.SetJob` | 2 个资源 / 4 个调用点：`custom-cartel/server/main.lua:144`、`custom-justice/server/main.lua:182`、`arrest.lua:65,133` | R3 | 保留；只读计数是有效能力 |
| `metadata` | `services/metadata_service.lua:118-127` | 真实但**直接改 PlayerData** | 0 | R4/R5 | **降级为只读，或删除**；写入必须回 qb-core |
| `notify` | `services/notify_service.lua:196-206` | 真实 | 真实外部只有 `notify-test/server/test.lua:37-99`；底稿把 custom-notify 计为调用方，但 custom-notify 实际用的是 `exports['core-framework']:RateLimitWindow`（`custom-notify/server/main.lua:24-28`），没有 `service_notify_*`；qb-core 的 `_G.Bus.notify` 是死分支（`qb-core/server/functions.lua:784`） | R3/R5 | 保留给服务端 native 通知；不要吞并 `QBCore:Notify`/phone NUI |
| `patron` | `services/patron_service.lua:250-258` | 真实，唯一能力 | 0 | R4 | 保留，等产品接入；不是重复 |
| `persistence` | `services/persistence_manager.lua:123-134` | 门面，委托 qb-core Store | 0（调用方用 qb-core 的 `StoreMarkDirty` 等） | R4 | 保留为兼容门面，或标 deprecated |
| `rateLimit` | `server/rate_limit.lua:154-161` | 真实 owner | 0 个 service 调用（调用方用静态 `RateLimitCooldown/Window/TokenBucket`，如 `custom-phone/server/core/rate_limit.lua:68`） | R4 | 服务注册冗余；保留静态导出，删 `service_rateLimit_*` |
| `security` | `services/security_service.lua:529-548` | 真实 | 2：`custom-cartel/server/drug_lab.lua:82`、`custom-mining/server/main.lua:120` | R3 | 保留；这是少数真正被跨资源使用的安全能力 |
| `world_state` | `services/world_state_service.lua:279-290` | 真实，唯一能力 | 0 | R4 | 保留，等玩法接入 |
| `world_trace` | `services/world_trace_service.lua:166-174` | 真实 | 1：`custom-police/server/p0_incidents.lua:282` | R3 | 保留；这是“服务导出能工作”的正面样例 |
| `cartel` | `custom-cartel/server/main.lua:167-177` | 真实 | 1：`custom-crime/server/crime.lua:392` | R3 | 保留 |
| `justice` | `custom-justice/server/main.lua:193-206` | 真实 | 0 个 `service_justice_*`；调用方用静态导出（如 `custom-police/server/p2_system.lua:1896` 的 `ReleaseSentence`） | R4 | 保留能力，删无用的 service_* 面 |
| `market` | `custom-market/server/main.lua:390-400` | 真实 | 1：`custom-cartel/server/npc_manager.lua:93,184,215` | R3 | 保留 |
| `mining` | `custom-mining/server/main.lua:180-186` | 真实 | 0 个外部 `service_mining_*`（自身/文档） | R4 | 无消费者；可先保留但不要扩散 |
| `quest` | `custom-quest/server/main.lua:745-759` | 真实 | 0 个外部 `service_quest_*`（只有 `main.lua:1440` 的启动日志） | R4 | 保留静态导出；删无用的 service_* 面 |
| `storage` | `custom-storage/server/main.lua:121-134` | 真实，**只有 service_* 导出** | 2：`custom-cartel/server/drug_lab.lua:193,197`、`custom-mining/server/smelter.lua:64,68` | R3 | 保留；补静态别名或保留 service_* 为正式契约 |
| `vehicles` | `custom-vehicles/server/main.lua:350-362` + `vehicle_state.lua:414-428` | 真实，但服务面与静态面重复 | 0 个 `service_vehicles_*`；外部用静态 `HasKeys`（`tcity-dashboard/server/security.lua:93`） | R4 | 删 `service_vehicles_*` 重复面，保留静态导出 |
| `story` | `story-engine/server/main.lua:244-259` | 真实 | 0 个外部 `service_story_*` | R4 | 无消费者；保留能力，删 service_* 面 |
| `atmosphere` | `tcity-atmosphere/server/atmosphere_service.lua:483-489` | 真实 | 2：`custom-cartel/server/drug_lab.lua:251`、`custom-justice/server/prison.lua:266` | R3 | 保留；同时修 3 个 `Bus.SafeCall` 死调用 |
| `dashboard` | `tcity-dashboard/server/main.lua:47-53` | 真实，唯一能力 | 0 个外部 `service_dashboard_*` | R4 | 保留，等接入 |
| `police` | `tcity-dashboard/server/police_api.lua:275-281` | 真实，车牌标记 | 0 个外部 `service_police_*` | R4 | 保留，等接入 |
| `dealership` | `qb-vehicleshop/server/bus.lua:330-331` + `integration.lua:81-96` | **运行时不存在**（该资源没有 `Bus` 定义，也没 include bus.lua） | 0；fxmanifest 的 8 个导出都是文档 | R4/R8 | 要么补 `@core-framework/bus.lua`，要么删掉整段 Bus 注册、保留静态导出 |

> 计数：27 个服务名里，**5 个占位**、**9 个有外部导出调用**、**13 个 0 外部调用**（其中 1 个运行时不存在）。底稿 G 的“0–2 个调用方”是对的，但它掩盖了三种完全不同的原因：没实现、没消费者、机制不可用。

### 2.4 被“采纳”的 storage/vehicles/atmosphere/notify 为什么被采纳

底稿把四个列为“被采纳”，逐一核对后，共同点不是 Bus，而是**一个 owner + 一个显式导出 + 调用期解析 + 低频**：

- **storage**：owner 只有 custom-storage；它没有静态导出，`service_storage_*` 是唯一 API；调用方写 `exports['custom-storage']:service_storage_CanAccess(...)`，在调用时解析，低频（开仓库/加物品）。**它被采纳的是导出名，不是 Bus。**
- **atmosphere**：同一模式；`custom-cartel`/`custom-justice` 用 `exports['tcity-atmosphere']:service_atmosphere_PlayScene` 成功。反面是 `custom-police`/`qb-ambulancejob`/`qb-storerobbery` 用 `Bus.SafeCall`，全部静默失败。
- **vehicles**：底稿的 2 个调用方是误判。`service_vehicles_*` 0 外部调用；真正被采纳的是静态 `exports['custom-vehicles']:HasKeys`（`tcity-dashboard/server/security.lua:93`）。**它是“静态导出”的采纳，不是服务面的采纳。**
- **notify**：真实外部调用只有 `notify-test`（测试套件）；底稿把 custom-notify 计为调用方，但它实际用的是 `RateLimitWindow`（`custom-notify/server/main.lua:24-28`），不是 `service_notify_*`；qb-core 的 `_G.Bus.notify` 是死分支，custom-police 用 `QBCore:Notify`。**notify 服务没有被业务采纳。**

共同点可以写成可复用判据：**当且仅当“一个能力只有一个 owner、对外只暴露一个显式导出、调用方在调用时解析、调用频率低”时，跨资源复用才稳定。** Bus 不是这个判据的一部分；`exports` 是。

### 2.5 这个抽象原本是给谁写的，那个“谁”为什么不存在

- `Bus.Plugin` 的目标是“第三方模组”（`bus.lua:70-80`）。仓库的启动集里没有第三方模组；唯一的扩展面是 `[custom]` 自己的资源，它们都直接依赖 `qb-core`/`core-framework`，没有动机走 Plugin Contract。
- `contracts.lua` 的目标是 Phase 2/3 的“编年史/声誉/共治/外观/漏斗”（`contracts.lua:11-16`）。这些系统没有实现、没有配置、没有消费者。把它们注册成可调用导出，只会让 `BusStatus` 看起来比实际更完整。
- `Bus.GetService`/`SafeCall` 的目标是“调用方在同一个 Lua 状态里拿服务引用”。这个场景在 FiveM 里只发生在**注册资源自己**——而注册资源自己不需要 Bus，直接调用本地表更快。

**结论**：Bus 的“总线”消费者（跨资源调用方）不存在于机制里，“插件”消费者不存在于产品里。它不是“没人用”，是**为两个不存在的用户写的**。

### 2.6 要让采纳成为可能，缺的前置条件

1. **先承认 `service_*` 导出就是契约**，把 `Bus.<service>` 从文档和代码里降级为“owner 进程内的注册辅助”。（问题：`ARCHITECTURE.md` 目前不认 Bus；修法是把它写成“owner 侧生成导出的实现细节”，而不是跨资源通道。）
2. **给导出补方法级契约**：owner、方法名、参数、返回、失败码。没有这个，调用方只能抄字符串，抄错就是 `No such export`（qb-pawnshop 的现成例子）。
3. **删掉/隔离占位服务**：`contracts.lua` 的 5 个 Phase 2/3 服务不应出现在 `service_*` 命名空间里。
4. **统一失败行为**：要么 `pcall` + 稳定错误码，要么调用前用闸门保证存在；不能像 `Bus.SafeCall` 那样把失败压成 `false, nil`。
5. **调用期解析**：所有跨资源调用都写成 `function(...) return exports[...]:... end` 或直接调用，不在文件顶部缓存。

### 2.7 服务注册的准入判据（这次审计的正面产物）

把 27 个服务过一遍后，能总结出 5 条准入判据。后续任何“要不要注册成 service”的决策都可以直接套：

1. **单一 owner**：能力有且只有一个资源写它的状态/表。反例：`metadata` 服务直接改 `Player.PlayerData`，而 owner 是 qb-core（§2.3）。
2. **至少一个真实外部消费者**：没有消费者就不注册；如果只是“以后可能有人用”，写进设计文档，不要导出。反例：13 个 0 外部调用的服务（§2.3）。
3. **签名稳定且可写清**：参数名+类型+返回+失败码能在一屏内写完。反例：`economy.AddScaled` 返回 `scaledAmount, multiplier`，调用方当布尔用（§2.2 R5）。
4. **调用期解析**：调用方不缓存导出引用；owner 重启/加载顺序变化不能改变行为。正例：`custom-security/server/security.lua:280-288` 在 qb-core 重启后重试 `GetCoreObject`；反例：任何在文件顶部 `local x = exports[...]` 的跨资源引用。
5. **失败可观察**：失败要返回稳定错误码或 nil+日志，不能像 `Bus.SafeCall` 一样压成 `false, nil`（`bus.lua:51-68`），也不能像 `qb-core` 的 `_G.Bus.notify` 分支一样永远走 fallback（`qb-core/server/functions.lua:784-787`）。

按这 5 条打分，27 个服务里只有 9 个“可继续保留为跨资源服务”（economy/job/security/storage/market/cartel/atmosphere/world_trace/notify），5 个应下线（stubs），13 个应降级为“资源内部能力/等消费者”。**这就是“提取核心模块”之前必须先做的服务面收敛**——不先删掉 18 个没有消费者的导出，任何新抽象都会被同一批无主 API 淹没。

## 3. 重复的稳定性风险分级

### 3.1 先修正“数字”：底稿 D 的多数条目是调用点，不是重复实现

底稿 D 的口径是“同一概念在多少个文件里出现”，其中很多是**对 owner 的正常调用**，不是第二份实现。按风险重排前必须先拆开：

| 概念 | 底稿 D 数字 | 核实后的“重复实现” | 说明 |
|---|---|---|---|
| rate-limit / cooldown | 101 文件 / 17 资源 | **8 个文件 / 9 张限流表**（custom-police 7 文件 / 8 表 + custom-director 1 文件 / 1 桶）；其余是业务冷却 | custom-quest 的 52 个文件里，绝大多数是持久化的 `quest_cooldowns`（`custom-quest/server/quest_db.lua:157-206`、`quest_cooldown.lua:1-73`），不是进程内限流；合并会改变“重启后仍生效”的语义，**不能并** |
| db wrapper | 69 文件 / 20 资源 | 19 个文件出现 `insertId/affectedRows/MySQL.insert`；**至少 6 处是归一化实现**（§4.2 列了位置） | 其余是各资源的业务查询；只有“结果形状适配”是同一能力 |
| notify | 47 文件 / 14 资源 | **7 个文件定义 Notify 函数**；其余是调用点 | custom-police 的 47 处基本都是 `TriggerClientEvent('QBCore:Notify')`（如 `custom-police/server/evidence.lua:368`），这是 owner 通道，不是重复实现 |
| permission check | 26 文件 / 14 资源 | **绝大多数是 `QBCore.Functions.HasPermission` 调用**；域内策略 `PolicePolicy.Can` / `OrgStorage.CanAccess` 语义不同 | 没有一份“通用权限实现”被抄 14 遍；不要合并 |
| money mutation | 30 文件 / 13 资源 | **4 套“奖励/加钱网关”**（`core_economy`、core-framework `economy`、`custom-main`（已删）、`custom-economy`（已删））+ 正常 `Player.Functions` 调用 | 真正的风险是“网关被删了调用点没迁”，不是 `Player.Functions` 用得多 |
| money 格式化 | 底稿 C：6 资源 × `Money()` | **9 份实现 / 9 个资源**（8 个 `[custom]` + qb-drugs），用了 4 个名字 | 见 §3.2；名字不同，`reuse_scan` 数不到 |
| cache table | 14 文件 / 5 资源 | 各资源的业务缓存（TTL/失效键不同） | 没有统一语义；抽通用 Cache 会把不同失效策略强行合并 |
| 3D 文字 | 5 文件 / 4 资源 | 已合并到 `CFShared.DrawText3D`（`reuse_budget.json` 已登记） | 已完成，不再议 |
| load model/anim | 13 文件 / 4 资源 | `LoadAnimDict` 已合并；`LoadModel` 仍有 **7+ 份客户端实现** | 其中 2 份是无超时 `while`（见 §4.3） |
| input focus | 19 文件 / 11 资源 | 手机焦点已有 `PhoneFocus` 单点；其余是各 NUI 的简单开关 | 手机那套的 keepInput 语义特殊，不适合全仓合并；本报告未深读全部 11 个资源 ⛔ |

### 3.2 风险 × 复用收益二维排序

判据：**碰钱/物品/权限/限流/DB 写入/幂等/状态单写者 = 高风险；纯展示 = 低风险；同名不同语义 = 不是问题。**

| # | 重复项 | 风险 | 复用收益 | 为什么 | 处置 |
|---|---|---|---|---|---|
| 1 | 奖励/加钱网关的死调用（`custom-main:AddScaledMoney`、`custom-economy:AddScaledMoney/GetEconomyRewardScale`） | **高** | **高** | 已删的 owner + 未迁的调用点：`qb-pawnshop/server/main.lua:74` 先调 `custom-main:CheckRateLimit`（导出不存在）→ 卖物品事件在扣物品前就报错；`:98` 在 `RemoveItem` 成功后调不存在的 `AddScaledMoney` → **物品已扣、钱没到**。`qb-storerobbery/server/main.lua:446,674` 调 `custom-economy:GetEconomyRewardScale`，而 custom-economy 只剩 config、没有 server 脚本（`custom-economy/fxmanifest.lua:15-17`）→ 抢劫奖励路径报错 | 立刻修调用点，迁到 `core_economy:TriggerReward` / `Player.Functions`；这是 Q6 第 1 件 |
| 2 | DB 结果归一化（`insertId` 表/数字/字符串、`affectedRows`） | **高** | **高** | 每份实现都有不同的 bug：custom-police 的 `InsertId` 认 `insertId/[1]/id`（`custom-police/shared/insert_id.lua:4-9`）；custom-phone 的 `PhoneDb.InsertId` 只认 `insertId`（`custom-phone/server/sms.lua:21-24`）；custom-director 的 `dbInsert` 把 `affectedRows` 当 `insertId` 兜底（`custom-director/server/main.lua:140-142`）→ 没有自增 id 时会把“影响行数 1”当成记录 id | 抽 `Db` 适配器；见 §4.2 |
| 3 | 反滥用限流的本地表（custom-police 7 文件 / 8 表 + custom-director 1 文件 / 1 桶） | **高** | **中高** | 这些是 net-event 入口的防刷：`forensics.lua:46,79`、`tow.lua:14,79`、`coroner.lua:16,95`、`evidence.lua:175`、`p2_system.lua:556,763`、`p0_incidents.lua:469,478`、`main.lua:6,11,250-301`；`custom-director/server/live_api.lua:113-145` 是完整令牌桶。限流闸门只认 `UserCooldowns|opCooldowns|rateLimits[src]|rateLimiter={` 等固定名（`test_rate_limit_single_owner.py:41-44`），这些全绕过，**闸门是绿的** | 迁到 `RateLimit.Cooldown/TokenBucket`；扩展闸门；见 §4.5 |
| 4 | 证据广播 `TriggerClientEvent(..., -1)` | **高（泄露）** | 中 | `custom-police/server/evidence.lua:307` 把 `dna, blood, where` 发给**所有客户端**；`:322` 指纹 + 坐标；`:447` 弹壳 + 武器 + 序列号。客户端可以不听，但改过的客户端一定能听（宪法①：NUI 隐藏 ≠ 权限） | 按受众收口：只发在岗警察/范围内玩家；见 §4.6 |
| 5 | 金额格式化（9 份、4 个名字） | 中 | **高（低代价）** | `Money`（custom-market/main/cartel/security/crime）`custom-phone/shared/money_format.lua:10` 的 `PhoneMoney`、`custom-quest/shared/money_format.lua:10` 的 `QuestMoney`、`custom-taxes/shared/money_format.lua:10` 的 `TCMoney`、`qb-drugs/shared/money_format.lua:10` 的 `Money` —— 函数体逐行相同。真正的事故不是重复，是 `$%d` 遇小数抛错（`tests/architecture/test_money_format.py:1-10`，钱已进账、审计没写） | 8 个 `[custom]` 合并到 `FormatMoney`；qb-drugs 不动；见 §4.4 |
| 6 | 客户端模型加载（`LoadModel`） | 中 | **高** | `custom-police/client/entity_util.lua:11-20` 自己一份（5s 超时）；`custom-cartel/client/main.lua:42-44` 和 `custom-quest/client/main.lua:593-594` 是**无超时 `while`**，模型缺失会卡死客户端脚本线程；core-framework 已有带 `IsModelInCdimage` + 超时 + 上报的 `CFShared.LoadModel`（`core-framework/client/shared.lua:69-96`） | 删本地副本，改用 `CFShared.LoadModel`；见 §4.3 |
| 7 | `GetCoreObject` 重试样板 | 低（[custom]） | 低 | 底稿 C 的 19 个资源里 **18 个是 `[qb]`**（qb-adminmenu/qb-banking/qb-clothing/qb-crypto/qb-doorlock/qb-garages/qb-houserobbery/qb-lapraces/qb-pawnshop/qb-prison/qb-scoreboard/qb-shops/qb-spawn/qb-streetraces/qb-weathersync/qb-weapons/qb-weed/qb-hud），`[custom]` 只有 custom-security 1 处（`custom-security/server/security.lua:280-288`）。REUSE.md 已定案不迁上游 | **不抽**；见 §6“不做” |
| 8 | 通知封装 | 低 | 低 | 三种通道（`QBCore:Notify` 原生、`custom-notify` 资源、phone NUI）语义不同；custom-police 的 47 处是对 owner 的调用 | 不合并 |
| 9 | 权限检查 | 低 | 低 | `QBCore.Functions.HasPermission` 是 qb-core 的 owner；`PolicePolicy.Can`/`OrgStorage.CanAccess` 是域内策略 | 不合并 |
| 10 | 业务冷却（quest_cooldowns 等） | 低（对“限流”而言） | 无 | 持久化冷却的语义是“跨重启/跨会话”，与进程内 `RateLimit` 不同；合并会丢持久性 | 不合并 |
| 11 | 缓存表 | 中（脏数据） | 低 | `custom-quest` 的 cache 有 TTL/失效键；`custom-phone`/`custom-vehicles` 各有不同的失效策略。没有证据表明存在一个可共享的“cache 契约” | 暂不抽；需要单独设计 |
| 12 | 3D 文字 / 进度条 option 表 | 低 | 低 | `DrawText3D` 已合并（`reuse_budget.json`）；进度条 option 表是调用参数，不是实现 | 不动 |
| 13 | 输入焦点 | 中（手机 keepInput） | 低 | 手机已有 `PhoneFocus` 单点；其余资源是简单 NUI 开关。把手机的 keepInput 语义推广到所有 NUI 风险大于收益 | 不合并；只保留 AGENTS.md 的焦点规则 |

**一句话结论**：需要动手的是 #1–#6；#7–#13 要么已定案，要么不是重复，要么语义不同。

## 4. 待提取的核心模块（≤8）

> 排序按“先让跨资源契约可验证，再收高风险语义”，不是按代码量。每个模块都写了独立回滚的第一批。

### 4.1 模块 1：服务契约登记表 + 方法级导出闸门

| 字段 | 内容 |
|---|---|
| 模块名/归属资源 | `service_contracts`（静态登记表 + 校验器）。归属 `core-framework`（`resources/[standalone]/core-framework/shared/service_contracts.lua` 或 `tests/architecture/` 的 JSON）；**不新增运行时总线** |
| 现在被谁各自实现 | ① `bus.lua:22-33` 动态生成 `service_*` 导出；② custom-storage 只用生成导出（`custom-storage/server/main.lua:121-134`）；③ custom-vehicles 同时生成导出和静态导出（`custom-vehicles/server/vehicle_state.lua:414-428` + `:376`）；④ qb-vehicleshop 在 `server/bus.lua:330-331` 注册但运行时没有 `Bus`（fxmanifest 没 include）；⑤ 33 个调用点手抄 `service_<name>_<method>` 字符串（§2.1 的清单） |
| 接口草案 | 登记表条目：`{ service = 'storage', owner = 'custom-storage', method = 'CanAccess', args = {'source:number','orgId:string'}, returns = 'boolean, string|nil', failure = 'false + error_code' }`。语义：**每个 `service_*` 导出必须在表里有且仅有一条登记；每个调用点必须能解析到登记**。失败行为：闸门在 CI 红；运行时不做重试/超时。是否跨资源：**是**（登记的是导出边界）。可选运行时 `CoreService.Call(service, method, ...)`：`pcall` 解析 `exports[owner][exportName]`，失败返回 `false, nil, 'service_not_found'|'method_not_found'|'call_failed'`；无重试、无超时（exports 同步）。⛔ `exports[owner][name]` 的字符串下标访问需真机探针确认；确认前只提供闸门、不提供运行时 helper |
| 为什么现在能抽 | `service_*` 的方法集合已经稳定（storage 10、economy 4、job 10、security 20+、atmosphere 4、notify 7、world_trace 5）；`Bus.RegisterService` 的 `methods` 表就是现成的登记来源，可以脚本生成初始 JSON；33 个调用点已枚举完（§2.1） |
| 迁移批次 | 批 0：生成登记表 + 新闸门，**不改运行时**（可独立回滚）；批 1：按 §5.1 E 修 6 组自研死调用（qb-pawnshop 的 `CheckRateLimit/AddScaledMoney`、qb-storerobbery 的 `GetEconomyRewardScale`、custom-taxes 的 `SetItemInfo`、custom-crime/qb-drugs 的 fallback 调用点、custom-main/custom-economy 的残留导出），≤8 文件；批 2：把 custom-storage/custom-mining/custom-justice 的 `service_*` 调用点纳入闸门（不改代码，只登记），≤5 文件；批 3：给 qb-vehicleshop 补 `@core-framework/bus.lua` 或删掉整段 Bus 注册（二选一），≤2 文件 |
| 验收证据 | 新 `tests/architecture/test_service_contracts.py`：① 每个 `exports('service_*')` 有登记；② 每个 `exports['res']:service_*` 调用点的 `(res, method)` 在登记里；③ 反向用例（缺方法/错 owner/拼写错误必须红）。`test_resource_wiring.py` 继续管资源名；`test_export_contracts.py` 继续管 custom-police 的鉴权/审计。**闸门记账**：新加的前向规则本身仍是 unproven（除非加入 `tools/dev/gate_mutation_smoke.py`）；同文件的反向用例只证明它自己。要么给前向规则加一条 mutation 用例，要么把 `gate_coverage_budget.json` 的 `max_unproven` +1 并在 `history` 写理由与到期条件——不能假装不增 |
| 稳定性收益 | 消灭“调用不存在的导出”这一类故障。真实素材：qb-pawnshop 卖物品在 `RemoveItem` 之后调 `custom-main:AddScaledMoney`（`qb-pawnshop/server/main.lua:98`）——物品已扣、钱没到；custom-taxes 调 `qb-inventory:SetItemInfo`（`custom-taxes/server/item_durability.lua:120,160`），而 qb-inventory 只导出 `SetItemData`（`qb-inventory/server/functions.lua:217`）——耐久更新静默失败。闸门在 CI 就能抓住，不需要真机 |

**特别说明**：这个模块**不**试图让 `Bus.storage.CanAccess` 跨资源工作。它把 `service_*` 导出确认为唯一写法，把 Bus 降级为 owner 侧实现细节。这样不需要 33 个调用点改名，也不需要新的运行时总线。**“统一”不等于“改名”，先把存在性钉住。**

### 4.2 模块 2：DB 结果适配器（`Db`）

| 字段 | 内容 |
|---|---|
| 模块名/归属资源 | `Db`（server-side 共享 include）。归属 `core-framework`：`resources/[standalone]/core-framework/server/db.lua`，调用方在 `server_scripts` 里 `@core-framework/server/db.lua`（在 `@oxmysql/lib/MySQL.lua` 之后） |
| 现在被谁各自实现 | ① `custom-police/shared/insert_id.lua:4-9`（`InsertId`）；② `custom-phone/server/sms.lua:21-24`（`PhoneDb.InsertId`）；③ `custom-director/server/main.lua:128-144`（`dbInsert`，且 `:141` 把 `affectedRows` 当 id）；④ `custom-police/server/p0_incidents.lua:372`、`p2_evidence.lua:224`、`citations.lua:135`、`records.lua:195` 各自写 `type(x)=='table' then x.affectedRows`；⑤ `story-engine/server/story_db.lua:28` 用 `exports.oxmysql:execute` 的 `affectedRows` 形状；⑥ `custom-quest/server/quest_db.lua:24-47` 用 `MySQL.Async.*` 回调，另一套风格 |
| 接口草案 | `Db.Insert(sql, params) -> number|nil, string|nil`（id 归一化：`insertId`/`[1]`/`id`/数字；字符串视为错误）；`Db.Update(sql, params) -> number, string|nil`（affectedRows/affected_rows/[1]；0 是成功）；`Db.Query/Single/Scalar(sql, params) -> result|nil, string|nil`。语义：只做结果适配与 `pcall`，**不拼 SQL、不改列名、不做重试**。失败行为：DB 抛错 → `nil, 'db_error'`（日志截断 160 字）；不重试；不超时（`MySQL.*.await` 本身是异步等待，禁止引入 `Citizen.Await`，`test_no_server_await.py` 已钉住）。跨资源：**否**（server-side include，不是 export） |
| 为什么现在能抽 | oxmysql 是 vendored 固定版本（`@oxmysql/lib/MySQL.lua` 已在每个资源清单里）；返回值形状的坑已在 AGENTS.md 记录（`[custom]/AGENTS.md:69`：`insert` 可能返回 `{insertId, affectedRows}`）；19 个文件出现这些结果形状、至少 6 处写了适配器，说明契约稳定；`test_query_discipline.py` 继续管 SQL 本身，适配器不碰 SQL |
| 迁移批次 | 批 0：新增 `db.lua` + 单元测试（用 stub `MySQL` 覆盖 number/table/string/nil 四种返回），不改调用方；批 1：`custom-director/server/main.lua` + `director.lua`（2 文件，独立回滚，先修 `:141` 的 id 混淆）；批 2：`custom-phone/server/sms.lua` + `main.lua`（2 文件）；批 3：`custom-police` 的 `records.lua`/`citations.lua`/`p0_incidents.lua`/`p2_evidence.lua`（4 文件）；批 4：`custom-quest`/`story-engine`（回调风格，最后做）。每批 ≤5 文件 |
| 验收证据 | 新 `tests/architecture/test_db_result_adapter.py`：① `insertId`/`affectedRows` 的归一化只允许出现在 `db.lua`；② `Db.Insert` 的四种返回形状测试全绿；③ 反向用例：表里只有 `affectedRows` 时不得当 id。`test_economy_single_owner.py`、`test_query_discipline.py`、`test_cross_resource_writes.py` 必须保持绿。`reuse_scan` 没有对应名字（`InsertId` 只有 2 份），所以**不能**靠它验收；靠新语义闸门 |
| 稳定性收益 | 消除“把 `affectedRows=1` 当 `insertId`”这一类错误 id/幂等故障。真实素材：custom-director 的 `dbInsert` 在结果表没有 `insertId` 时返回 `affectedRows`（`custom-director/server/main.lua:140-142`），而 `agent_actions` 的后续 `completeApproved(insertId, ...)` 会拿这个值去更新行（`:1606-1617`）——在“INSERT ... ON DUPLICATE KEY”路径上可能更新错行。custom-police 的 `records.lua:9-12` 还记录了“参数数组中间 nil 会被 oxmysql 截断”的真实事故；适配器至少把“字符串错误/表 id”归一化，减少第二套语义 |

### 4.3 模块 3：`CFShared.LoadModel` 采纳（已有实现，迁移）

| 字段 | 内容 |
|---|---|
| 模块名/归属资源 | `CFShared.LoadModel` / `CFShared.ReleaseModel`。归属 `core-framework/client/shared.lua:69-104`（加载期 include，不走 exports） |
| 现在被谁各自实现 | ① `custom-police/client/entity_util.lua:11-20`（5s 超时，无上报）；② `custom-cartel/client/main.lua:42-44`（**无超时 while**）；③ `custom-quest/client/main.lua:593-594`（**无超时 while**）；④ `custom-quest/client/quest_logistics_client.lua:415-422`（有 timeout 50×10ms）；⑤ 热狗两个客户端文件（`quest_hotdog_client.lua:290`、`quest_hotdog_vendor_client.lua:290`）也各有一份；**这两个是工作区已修改文件，本次不动** |
| 接口草案 | `CFShared.LoadModel(modelHash:number, timeoutMs?:number) -> boolean`。语义：先 `IsModelInCdimage` 挡掉不存在的模型；`RequestModel` 后每 10ms 等 `HasModelLoaded`；默认 10s 超时；失败只上报一次（`CFShared.Report`，每进程 50 条上限）。`CFShared.ReleaseModel(hash)` 释放。失败行为：参数非法/不在 cdimage/超时 → `false`，不抛错；无重试（调用方决定）。跨资源：**否**（`@resource` 加载期包含，零调用开销；这正是 REUSE.md 对逐帧/高频调用的规则） |
| 为什么现在能抽 | 实现已经在 core-framework 且带启动自证（`core-framework/client/shared.lua:119`）；custom-police、custom-cartel、custom-quest 的 fxmanifest **已经包含** `@core-framework/client/shared.lua`（`custom-police/fxmanifest.lua:28`、`custom-cartel/fxmanifest.lua:24`、`custom-quest/fxmanifest.lua:115`），不需要新增依赖；`test_reuse_budget.py` 已有 `loadAnimDict` 的惰性包装先例 |
| 迁移批次 | 批 1：custom-police 的 `coroner.lua:16`、`tow.lua:16`、`scenery.lua:45`、`lockdown.lua:14` 改用 `CFShared.LoadModel`，删除 `entity_util.lua` 的 `LoadModel`（保留 `Delete`）——4 文件，独立回滚；批 2：`custom-cartel/client/main.lua`（1 文件）；批 3：`custom-quest/client/main.lua` + `quest_logistics_client.lua`（2 文件）；热狗文件留给热狗任务自己收 |
| 验收证据 | `reuse_scan` 的 `LoadModel` 计数下降（当前 7+ 份；实施前先跑 `python3 tools/dev/reuse_scan.py --min 3` 确认精确值 ⛔）；`reuse_budget.json` 新增 `LoadModel` 条目并把 `max` 设成剩余份数（迁移后应为 0 或仅剩工作区热狗副本）。新增 `tests/architecture/test_load_model_single_owner.py`（或在 `test_reuse_budget.py` 新增同类函数）：这 4+2+1 个文件必须出现 `CFShared.LoadModel`，且不得出现本地 `while not HasModelLoaded`/`RequestModel` 循环；现有 `loadAnimDict` 的 `migrated` 列表不动。反向用例：合成一个本地循环必须红 |
| 稳定性收益 | 消除“模型缺失 → 客户端脚本线程永久卡死”的故障类。真实素材：REUSE.md §5 已记录 `loadAnimDict` 原实现无上限 `while … Wait(n)` 会把客户端线程卡死（`docs/engineering/REUSE.md:72-74`）；`LoadModel` 是同一形状，`custom-cartel/client/main.lua:42-44` 和 `custom-quest/client/main.lua:593-594` 现在就是这个形状 |

### 4.4 模块 4：`FormatMoney` 金额格式化

| 字段 | 内容 |
|---|---|
| 模块名/归属资源 | `FormatMoney`。归属 `core-framework/shared/util.lua`（与 `Convar*` 同文件），`exports('FormatMoney', FormatMoney)` 两端注册；调用方用惰性包装或直接调用 |
| 现在被谁各自实现 | 9 份、4 个名字：`Money`（`custom-market/shared/money_format.lua:10`、`custom-main/shared/money_format.lua:10`、`custom-cartel/shared/money_format.lua:10`、`custom-security/shared/money_format.lua:10`、`custom-crime/shared/money_format.lua:10`、`qb-drugs/shared/money_format.lua:10`）、`PhoneMoney`（`custom-phone/shared/money_format.lua:10`）、`QuestMoney`（`custom-quest/shared/money_format.lua:10`）、`TCMoney`（`custom-taxes/shared/money_format.lua:10`）。函数体逐行相同：`tonumber` → nil 返回 `'0'` → 整数 `%d` → 小数 `%.2f` |
| 接口草案 | `FormatMoney(value:any) -> string`。语义：非数字/ nil → `'0'`；整数值 → 无小数点；小数值 → 两位小数；负数保留符号（`TCMoney` 的注释要求）。失败行为：**永不返回 nil/不抛错**；不重试、无超时。跨资源：可以走 export（低频，通常是文案拼接），也可以 `@core-framework/shared/util.lua` include；推荐 export，避免调用方再定义一份 `Convar*` 全局 |
| 为什么现在能抽 | 9 份实现体逐行相同（差异只有函数名和文件头注释）；调用方已经在用这些函数（grep 命中 29 个文件、76 个调用点），说明签名稳定；`money_format_baseline.json` 已存在（66 条 `$%d` 债），说明这里已经做过一次治理，缺的只是“实现只有一份” |
| 迁移批次 | 批 1：`custom-security`（2 调用点）+ `custom-crime`（4 调用点）——2 文件，独立回滚；批 2：`custom-market`（2）+ `custom-main`（2）；批 3：`custom-cartel`（9）；批 4：`custom-phone`/`custom-quest`/`custom-taxes`（15+ 调用点，分 2 个 PR）。每批 ≤5 文件；删除对应的 `shared/money_format.lua` 并同步删 fxmanifest 条目（`test_no_orphan_scripts.py` 会抓漏删） |
| 验收证据 | 底稿 C 的 `Money` 组是 6 个资源；本次按文件核实是 9 份/4 个名字。`reuse_scan` 当前是否把这 9 份都计入、`Money` 是否已在预算里，本次没有 shell 不能实跑 ⛔；实施第一步先跑 `python3 tools/dev/reuse_scan.py --min 3` 确认。预期 `Money` 计数从 6 降到 1（只剩 qb-drugs，按 REUSE.md 不迁上游）；`PhoneMoney`/`QuestMoney`/`TCMoney` 从未被 name-based 扫描计入，所以必须加语义闸门：`tests/architecture/test_money_format_single_owner.py` 禁止在 `core-framework` 之外出现 `tonumber(value)` + `num % 1 == 0` + `%.2f` 的组合（反向用例用改名副本证明它抓得住 `PhoneMoney` 这种别名）。`money_format_baseline.json` 的 `$%d` 条目随调用点改为 `$%s` + `FormatMoney` 而下降；`test_money_format.py` 双向相等，必须同 commit 更新基线 |
| 稳定性收益 | 防止 `$%d` 遇小数抛 `number has no integer representation` 的真实事故（`test_money_format.py:1-10`：`givemoney 1 cash 0.5` 连抛 10 次，钱已进账、审计没写、调用方收到错误）。合并本身只消除“9 份实现分叉”的维护风险；**真正的收益要配合 `$%d` 基线下降**，所以这个模块必须和 money_format 基线一起验收 |

### 4.5 模块 5：`RateLimit` 收口（已有 owner，补迁移与闸门）

| 字段 | 内容 |
|---|---|
| 模块名/归属资源 | `RateLimit`。归属 `core-framework/server/rate_limit.lua`（已有 `Cooldown/Window/TokenBucket/Reset/Sweep` + 静态导出 `RateLimitCooldown/Window/Reset/TokenBucket`） |
| 现在被谁各自实现 | ① `custom-police/server/forensics.lua:46,79-80`；② `tow.lua:14,79-91`；③ `coroner.lua:16,95-112`；④ `evidence.lua:175`；⑤ `p2_system.lua:556,763-764`；⑥ `p0_incidents.lua:469,478-483`；⑦ `main.lua:6,11,250-301`；⑧ `custom-director/server/live_api.lua:113-145`（完整令牌桶，`liveBuckets`）；⑨ 业务冷却的 `quest_cooldowns`（**不迁**，见 §3.1）。另外 `custom-security/server/security.lua:21-31`、`custom-phone/server/core/rate_limit.lua:50-69` 已经是门面，属于正确样例 |
| 接口草案 | 复用现成签名：`exports['core-framework']:RateLimitCooldown(key:string, cooldownMs:number) -> boolean`；`RateLimitWindow(key, limit, windowMs) -> boolean, count`；`RateLimitTokenBucket(key, ratePerMinute, burst) -> boolean, retryAfterMs`；`RateLimitReset(prefix)` 清键。语义：键建议 `('<src>:<action>'):format(...)` 或 `('<cid>:<action>')`；玩家下线用 `RateLimitReset('sec:<src>:')`（`custom-security/server/security.lua:41` 已是这个用法）。失败行为：返回 boolean，**不抛错、不重试**；调用方决定拒绝还是放行。跨资源：**是**（静态导出；service 注册冗余，可删） |
| 为什么现在能抽 | owner 已实现三类语义并有单测/注入时间（`test_rate_limit_single_owner.py:72-79`）；`RateLimit.Reset` 支持精确键/前缀清理；custom-police 的 7 个文件（8 张表）都是“`now - last < ms`”或“每键时间戳”，可以一一映射；custom-director 的令牌桶与 `RateLimit.TokenBucket` 语义一致，且 owner 已经修过首次请求不扣令牌的 off-by-one（`rate_limit.lua:99-102`） |
| 迁移批次 | 批 1：custom-police `forensics.lua`/`tow.lua`/`coroner.lua`（3 文件，独立回滚）；批 2：`evidence.lua`/`p2_system.lua`/`p0_incidents.lua`/`main.lua`（4 文件）；批 3：`custom-director/server/live_api.lua`（1 文件，替换 `liveBuckets`）；批 4：扩展 `IMPL_MARKERS`（`test_rate_limit_single_owner.py:41-44`）把 `liveBuckets|policeAlertCooldown|autoAlertCooldown|call911Cooldown|towCooldown|coronerCooldown|backupCooldown` 纳入，并把迁移后的文件加进 `CALLERS` |
| 验收证据 | 先红后绿：批 4 的 marker 扩展在迁移前必须让 `test_no_new_rate_limiter_grows` 红（证明闸门有牙），迁移后绿。`test_migrated_callers_use_the_owner` 加入这些文件；`test_phone_facade_delegates_instead_of_reimplementing` 继续管手机门面。没有 `reuse_scan` 计数（名字是 `CheckRateLimit`/`cooldown` 等别名），所以验收靠 marker 闸门 + 文件清单 |
| 稳定性收益 | 消除“每个 net event 入口一套边界行为”的类。真实素材：owner 注释记录 `burst=2` 能连过 3 次的 off-by-one 是真实探针抓到的（`rate_limit.lua:99-102`）；custom-director 的 `liveBuckets` 首次请求给满 `burst` 且不扣（`live_api.lua:128-130` 与 owner 修过的行为不一致）——两套令牌桶就是两种边界。限流是安全原语，重复 = 可利用 |

### 4.6 模块 6：受众感知广播（`BroadcastScope`）

| 字段 | 内容 |
|---|---|
| 模块名/归属资源 | `Broadcast`（server-side 共享 include）。归属 `core-framework/server/broadcast.lua`；第一批调用方是 `custom-police`（证据广播最集中） |
| 现在被谁各自实现 | 底稿 E：`[custom]` 内 28 处 `TriggerClientEvent(..., -1)` / 9 个文件。高风险的 9 处：`custom-police/server/evidence.lua:307,322,447`（DNA/血型/指纹/弹壳/坐标）、`:334,364,394,456,489`（删除证据）、`:142`（TTL 清理）；性能类：`custom-vehicles/server/vehicle_state.lua:272,279`、`main.lua:189,285,469`、`dashboard_api.lua:193,233,285,292`；`custom-phone/server/jobboard.lua:75,136,265`；`custom-police/server/main.lua:96,327,422`（`SetCopCount` 是合理的全服广播） |
| 接口草案 | `Broadcast.Scope(eventName:string, audience:table, ...) -> number`。audience：`{all=true}` / `{job='police', onduty=true}` / `{source=src}` / `{coords=vec3, radius=number}`。语义：服务端解析收件人（`QBCore.Functions.GetPlayersByJob(job, true)` 已存在：`qb-core/server/functions.lua:138,179`），逐个 `TriggerClientEvent`；返回收到的人数。失败行为：未知 audience/空收件人 → 返回 `0`，不抛错；开发环境可 `print` 一次；不重试、无超时。跨资源：**否**（server-side include；不新增 net event） |
| 为什么现在能抽 | qb-core 已有 `GetPlayersByJob/GetPlayersOnDuty`；custom-police 已有 `dutyPlayers` 名单（`server/main.lua:96`）；广播点已经枚举（28/9 文件）；`io_budget.json` 的 `broadcast_sites` 已经在数 152 个全仓点，收口后可以下调。注意：这**不是**把所有 `-1` 都改掉——`SetCopCount`/车辆同步/手机 jobboard 是合理的全服广播，保留并登记 |
| 迁移批次 | 批 1：`custom-police/server/evidence.lua` 的 9 处改为 `Broadcast.Scope(event, {job='police', onduty=true}, ...)`——1 文件，独立回滚，安全收益最高；批 2：`custom-police/server/main.lua` 的 2 处（`UpdateBlips`/`SetCopCount`）登记为 `{all=true}` 并保留；批 3：custom-vehicles 的 9 处按“车辆附近/车主”评估，能收则收，不能收则登记 `{all=true}` + 理由；批 4：phone jobboard 3 处登记/收口 |
| 验收证据 | 新 `tests/architecture/test_broadcast_scope.py`：每个 `TriggerClientEvent(..., -1, ...)` 必须在 `broadcast_allowlist.json` 登记 `{file, event, audience, reason, expires}`；新增未登记 → 红；登记失效 → 红；反向用例用 `-1` 合成文件证明会红。`io_budget.json` 的 `broadcast_sites` 从 152 下调（收口后实测）；`test_budget.py` 要求每个 metric 有 note，新增 metric 需同步 |
| 稳定性收益 | 消除“证据/坐标/PII 发给所有客户端”的泄露面（宪法①：NUI/客户端隐藏 ≠ 权限；改过的客户端能读任何 `-1` 事件）。真实素材：`evidence.lua:307` 把 `dna, blood, where` 广播给所有人；`:447` 广播武器与序列号。另一个收益是广播成本从 O(全体玩家) 降到 O(目标玩家)，`io_budget.json:28-31` 已经说明“广播成本随在线人数线性放大” |

> **没有进入前 6 的候选**：`Cache`（语义不统一）、`CoreAccess`（见 §6 不做）、`Notify` 门面（通道不同）、`Permission`（域内策略）、`Idempotency`（证据不足，需单独审计 ⛔）。

### 4.7 三个“特别候选”的判定

| 候选 | 判定 | 理由 |
|---|---|---|
| ① `exports['qb-core']:GetCoreObject` 重试样板（底稿 C 组 1–3，19 个资源） | **不做** | 19 个资源里 18 个是 `[qb]` 上游（清单见 §3.2 #7）；REUSE.md 已定案不迁上游。`[custom]` 只有 `custom-security/server/security.lua:280-288` 一处（另一个是工作区热狗文件）。为 1–2 个调用点造 `CoreAccess` 抽象，违反“宁少勿多”；如果未来出现第 3 个 `[custom]` 调用点，再按 `LoadAnimDict` 的惰性包装模式抽 |
| ② rate-limit 在 17 个 `[custom]` 资源各写一遍 | **部分做，但不新建模块** | 17 个资源的数字被业务冷却放大（`custom-quest` 的 52 个文件绝大多数是持久化 `quest_cooldowns`，见 §3.1）；真正该收的是 custom-police 7 文件 / 8 表 + custom-director 1 文件 / 1 桶。owner 已有 `RateLimitCooldown/Window/TokenBucket/Reset`，做的是迁移 + 扩展闸门 marker，不是新模块 |
| ③ `Money()` 金额格式化在 6 个资源各一份 | **做，但按低风险样板做** | 底稿 C 只数到 6 个同名 `Money`；按文件核实是 **9 份 / 4 个名字**（`Money`/`PhoneMoney`/`QuestMoney`/`TCMoney`），8 个 `[custom]` + qb-drugs。qb-drugs 不动；8 个 `[custom]` 合并到 `FormatMoney`。它的主要收益不是“少 8 份代码”，而是把 `$%d` 债的修复路径统一；所以必须和 `money_format_baseline.json` 一起验收（§4.4） |

## 5. 耦合治理清单

### 5.1 逐信号定性

#### 信号 A：`_G.Bus` 跨资源全局 —— 保留“owner 侧注册”，拆掉“跨资源读取”

- **该不该保留**：`Bus.RegisterService` 作为 owner 侧“注册一组导出”的辅助可以保留（它确实在工作，如 custom-storage）；`Bus.<service>` 作为**跨资源读取**必须拆掉。`Bus.Plugin` 在没有真实插件前应删除或标 `planned`，否则它会继续误导“有第三方生态”。
- **怎么钉住**：新增闸门 `test_bus_scope.py`——
  1. 允许 `Bus.RegisterService(...)` 只出现在“注册了该服务”的资源里；
  2. 禁止 `Bus.<service>.<method>` 出现在注册资源之外（`custom-police`、`qb-ambulancejob`、`qb-storerobbery`、`qb-vehicleshop` 是重点）；
  3. 禁止 `_G.Bus.<service>` 读取，除非文件属于该 service 的 owner（qb-core 的 `_G.Bus.EconomyService` 已由 `test_economy_service_single_registrar.py` 单独管）。
  反向用例：在 tmp 目录写一个 `Bus.storage.CanAccess`，必须红。
- **替代**：跨资源读取改 `exports['<owner>']:service_<name>_<method>`（或 §4.1 的契约 helper）；owner 侧内部直接调用本地表，不需要 Bus。
- **代价**：约 11 个文件、15 个失败点；一部分有 fallback（custom-police SetJob、qb-vehicleshop、custom-phone banking、qb-core notify），另一部分是静默功能缺失（atmosphere 3 处、custom-taxes sink 5 处、qb-shops 定价、production-freeze 热力）。改动量小，但**验证需要真机**（听不到 BGM、税率没进 sink 这类问题静态看不出来）。⚪ 工时估计 2–3 天。
- **保留的例外**：`test_economy_service_single_registrar.py:8-9` 已明确 `_G.Bus` 资源私有；`Bus.Plugin.GetEconomy()` 必须继续返回原语层（`test_economy_single_owner.py:146-153`），不能借“删 Bus”把它一起删掉。

#### 信号 B：`rawget(_G, ...)` —— 只保留“原生库查找”，禁止“跨脚本配置读取”

- **现状**：`custom-phone/server/core/rate_limit.lua:25`（`rawget(_G,'GetConvar')`）、`:30`（`rawget(_G,'Config')`）、`:59`（`rawget(_G,'exports')`）；`custom-director/server/director_rules.lua:44`（`rawget(_G,'json')`）。
- **该不该保留**：`GetConvar`/`exports`/`json` 是运行时全局，`rawget` 作为防御式查找可以保留；`Config` 是**另一个脚本定义的业务全局**，按 AGENTS.md:73 的结论在独立 env 下取不到，应该改用显式 include/`exports['core-framework']:Convar*`。
- **怎么钉住**：在 `[custom]` 内禁止 `rawget(_G, 'Config')`（或任何业务全局名）；允许 `rawget(_G,'json'|'GetConvar'|'exports')` 并写理由。反向用例：合成 `rawget(_G,'Config')` 必须红。
- **代价**：2 个文件；phone 的 rate-limit 默认值改为直接读 `Config`（同文件 include）或 convar；director 的 json 保留。⚪ 0.5 天。
- **⛔ 未验证**：`rawget(_G,'Config')` 在这个 FiveM build 上到底是否返回 nil——AGENTS.md 的结论是“独立 env 下取不到”，但 phone 的 `Config` 是否同脚本可见需要真机打印一次。若实际能取到，这条降级为“风格统一”，不是 bug。

#### 信号 C：28 处 `TriggerClientEvent(..., -1)` —— 按受众拆分，不搞“一刀切”

| 类别 | 证据 | 处置 |
|---|---|---|
| **泄露/权限**（必须拆） | `custom-police/server/evidence.lua:307`（`dna, blood, where`）、`:322`（指纹+坐标）、`:447`（弹壳+武器+序列号）、`:334,364,394,456,489`（删除证据）、`:142`（TTL 清理） | 改为只发在岗警察（`GetPlayersByJob('police', true)`）或在范围/维度内；玩家只应收到“自己那一条” |
| **合理的全服同步**（保留+登记） | `custom-police/server/main.lua:327,422`（`SetCopCount`）、`custom-vehicles/server/vehicle_state.lua:272,279`（氮气火焰）、`main.lua:189,285,469`（被盗/驾驶模式）、`custom-phone/server/jobboard.lua:75,136,265`（新工作） | 保留 `-1`，在 `broadcast_allowlist.json` 登记 `audience='all'` + 理由；不改行为 |
| **可疑待判**（先登记） | `custom-police/server/main.lua:96`（`UpdateBlips` 把在岗警察名单发给所有人）、`custom-police/server/vehicle.lua:34`（直升机探照灯）、`custom-cartel/server/drug_lab.lua:235`（cartel 突袭警报） | 逐个看是否需要全服；`UpdateBlips` 建议只发警察/相关玩家 |
- **该不该保留**：保留“世界状态同步”的 `-1`；拆“证据/PII”的 `-1`。
- **怎么钉住**：`test_broadcast_scope.py` + `broadcast_allowlist.json`（`file/event/audience/reason/expires`）；`io_budget.json` 的 `broadcast_sites` 收口后下调（当前 152，`io_budget.json:28-31`）。
- **代价**：`evidence.lua` 9 处（1 文件，1 天）+ custom-police main/vehicle/objects 另 6 处（评估 0.5 天）+ vehicles 9 处（评估 2 天）+ phone 3 处（0.5 天）；真机验证需要至少 1 个警察 + 1 个平民客户端，确认平民收不到证据事件。⚪ 3–5 天。
- **爆炸半径**：`-1` 发给所有在线玩家；成本 O(玩家数)，且改过的客户端能读任何广播。证据广播是本次审计里**最直接违反宪法①**的一类。

#### 信号 D：同一服务两套写法 —— 只保留 exports，Bus 写法退役

- **现状**：
  - `storage`：调用方用 `exports['custom-storage']:service_storage_CanAccess`（`custom-cartel/server/drug_lab.lua:193`、`custom-mining/server/smelter.lua:64`）；**没有** `Bus.storage.CanAccess` 的调用点。
  - `vehicles`：同时注册静态导出和 `service_vehicles_*`（`custom-vehicles/server/vehicle_state.lua:376,414-428`）；外部只用静态 `HasKeys`（`tcity-dashboard/server/security.lua:93`）。
  - `dealership`：fxmanifest 文档列了 8 个 `service_dealership_*`（`qb-vehicleshop/fxmanifest.lua:50-58`），但资源没有 `Bus`，注册代码不执行（`server/bus.lua:330-331`）。
  - `custom-vehicles` 还在 `main.lua:318-324` 和 `compat.lua:71-84` **重复注册** `GiveKeys`/`HasKeys`，签名不同（`(plate,citizenid)` vs `(plate)`/`(id,plate)`）；靠 fxmanifest 顺序（`compat.lua` 先、`main.lua` 后，`fxmanifest.lua:31-34`）让 main 覆盖。**这个顺序是唯一契约，没有闸门。**
- **该不该保留**：保留 `service_*` 导出为唯一跨资源写法（它已经工作，改 33 个调用点不划算）；删除 `Bus.<service>` 读取；删除/标注未使用的 `service_vehicles_*`/`service_dealership_*` 面。重复注册的 `GiveKeys`/`HasKeys` 必须登记“覆盖关系 + 签名”，或者合并成一个函数。
- **怎么钉住**：§4.1 的契约登记表 + 新闸门；额外加一条“同一资源内同名导出必须显式登记 `overrides`，且 fxmanifest 顺序必须与登记一致”。反向用例：同名导出不同签名未登记 → 红。
- **代价**：33 个调用点**不改名**（只登记）；删 2 组无用的 service 面（custom-vehicles、custom-quest/justice/mining/story 的 service_* 可先保留但标 deprecated）；qb-vehicleshop 补 include 或删 Bus 注册（2 文件）。⚪ 2 天。

#### 信号 E：43 处“调用了目标资源并未导出/无法证实存在”的调用 —— 先去掉噪声，再修真的

底稿 B 的 43 处 / 23 组，按“是否真的会炸”重排：

| 类别 | 组（底稿 B 的数字） | 判定 |
|---|---|---|
| **qb-core 动态导出（不是坏契约）** | `qb-core:GetPlayer`×6、`GetPlayerByCitizenId`×1、`GetPlayerData`×1、`Notify`×1 | ✅ **误报**。qb-core 在 `server/functions.lua:812-816` 和 `client/functions.lua:1195-1199` 用 `for functionName, func in pairs(QBCore.Functions) do exports(functionName, func) end` 把函数表全部导出；`GetPlayer` 定义在 `:46`、`GetPlayerByCitizenId` 在 `:57`、`Notify` 在 `:757`，都在循环之前。`custom-police/client/stolen_radar.lua:15` 的 `GetPlayerData` 同理 |
| **注释/占位符** | `qb-banking:GetBalance`×1（`custom-testing/suites/01_banking_test.lua:16` 是注释）、`res:method`×2（文档占位符） | ✅ **误报**；扫描器应剥注释 |
| **外部资源/示例，不归我们改** | `LegacyFuel:SetFuel/GetFuel`×7、`money:addMoney/removeMoney`×3、`qb-vehiclekeys:HasKeys`×2（资源不存在）、`safecracker:StartSafeCracker`×1、`qb-jobs:AddJobs`×1、`qb-interior:CreateFurniMotelStandard`×1、`oxmysql:isConnected`×1 | ⛔ 部分无法证实；`qb-vehiclekeys` 可确认不存在（无 `fxmanifest.lua`）。这些不属于“抽象失败”，属于外部依赖缺失 |
| **真的 ours、且会炸** | `custom-main:AddScaledMoney`×4、`custom-main:CheckRateLimit`×1、`custom-main:CheckStoreRobbery`×1、`custom-economy:GetEconomyRewardScale`×3、`custom-economy:AddScaledMoney`×2、`qb-inventory:SetItemInfo`×2、`qb-fuel:GetFuel`×1（qb-fuel 自调用）、`custom-career:GetLocalIdentity`×1（pcall 兜底） | **13 处自研坏调用 + 2 处兜底/上游**。最高风险：qb-pawnshop 卖物品（`server/main.lua:74,98`）、qb-storerobbery 奖励（`server/main.lua:446,674`）、custom-taxes 耐久（`server/item_durability.lua:120,160`） |

> **注意**：`service_*` 的 18 处调用**不在 43 里**——底稿 §0 的动态导出解析已经把 `Bus.RegisterService` 生成的导出算作“存在”，所以它们没有进入“真正无实现”清单。它们是**真契约**（注册位置见 `custom-storage/server/main.lua:121-133`、`core-framework/services/security_service.lua:529-548`、`tcity-atmosphere/server/atmosphere_service.lua:483-489`、`core-framework/services/job_service.lua:293-306`、`economy_service.lua:159-166`、`custom-market/server/main.lua:390-400`），不是坏契约。

**结论**：43 这个数字不能直接当“坏契约数”。约 **28 处是动态导出/注释/外部资源**（9 + 3 + 16）；真正的自研坏调用约 **13 处、集中在 3 个 owner 被删/改名的资源**（custom-main 6、custom-economy 5、qb-inventory 2），另有 2 处是兜底/上游（qb-fuel 自调用、custom-career 的 pcall）。修它们不需要新抽象，需要的是“方法级存在性闸门”防止下一批。

### 5.2 扇入/扇出最高的边与爆炸半径

底稿 B 的被依赖表：

| 边 | 调用点 | 调用方资源 | 性质 | 爆炸半径/判定 |
|---|---|---|---|---|
| `qb-core` | 354 | **65** | 上游框架：`GetCoreObject` + 动态 `QBCore.Functions.*` | 改一个导出签名 = 65 个资源；**不要动**，只做兼容/钉版本 |
| `qb-inventory` | 123 | 29 | 上游物品 owner | 改 `AddItem/RemoveItem` = 29 个资源丢失物品；不要动 |
| `qb-interior` | 108 | **3** | 少数调用方重度使用 | 3 个调用方的爆炸半径，不是全仓；上游 |
| `qb-menu` | 86 | 13 | 上游 UI | 显示层，低风险 |
| `custom-logs` | 71 | **17** | 自研日志门面 | 改签名 = 17 个资源的日志断；**可见、非关键**，但应 append-only |
| `core-framework` | 62 | **17** | 自研核心：`Convar*`/`RateLimit*`/`LoadAnimDict`/`service_*` | **本次最该治理的边**：静态导出改签名 = 17 个资源；174 个动态 `service_*` 没有登记，改名会打断未知子集 |
| `custom-police` | 56 | 7 | 自研警察 | 7 个调用方；MDT/justice 等，改动要通知 |
| `custom-notify` | 38 | 16 | 自研通知 | 显示层；16 个调用方 |
| `custom-prompt` | 28 | 6 | UI | 显示层 |
| `custom-ui` | 25 | 8 | UI | 显示层 |

**按“后果”而不是“调用数”排序**：

1. **`players.money` 数据边**：owner 是 qb-core（`test_economy_single_owner.py:28`），13 个 `[custom]` 资源通过 `Player.Functions.*` 调用（底稿 D）。这是**唯一一条坏了会直接丢钱/生钱**的边；已有 owner 闸门，不能再开第二条写路径（`custom-main`/`custom-economy` 的死网关正是第二条）。
2. **`core-framework` 的 174 个动态导出**：17 个调用方资源，零登记；一次改名就是“未知子集 + 运行时 No such export”。爆炸半径 17，且失败是静默/半静默。**这是“改一个资源连带炸 N 个资源”的自研热点。**
3. **`custom-logs`**：17 个调用方；失败可见、非关键；append-only 即可。
4. **通知通道（含 `QBCore:Notify`）**：底稿 D 的 notify 概念是 14 个资源 / 47 个文件；显示层，最坏是通知不显示。
5. **`qb-core` / `qb-inventory`**：65/29 个调用方，但上游且稳定；不要改，只 pin + 兼容。

**结论**：真正需要“显式契约 + 闸门”的是第 2 条（core-framework 服务导出），不是调用数最多的 qb-core。qb-core 的问题不是耦合高，是**不能改**；我们的问题不是调用多，是**改了没人知道**。

### 5.3 每个信号的代价与批准人

| 信号 | 动多少处 | 谁能批准 | 多久能验完 | 回滚方式 |
|---|---|---|---|---|
| A `_G.Bus` 跨资源 | 11 文件 / 15 点 | core-framework owner + 各调用资源 owner | 2–3 天（含真机听 BGM/看税率） | 按资源逐个回滚；每个调用点保留旧分支直到真机确认 |
| B `rawget` | 2 文件 | phone/director owner | 0.5 天 + 真机一次 | 单文件回滚 |
| C `-1` 广播 | 9 文件 / 28 点（证据 9 点优先） | custom-police owner（证据）、各资源 owner | 3–5 天（2 客户端验证） | 按事件回滚；allowlist 条目随 PR 删除 |
| D 两套写法/重复导出 | 33 调用点登记 + 2 组无用面 + 2 文件 | 架构 owner | 2 天 | 登记表可独立回滚；不改调用点 |
| E 43 坏调用 | 6 组自研 + 2 组兜底/上游 / 约 15 点 | 各调用资源 owner + core_economy owner | 1 天修 + 1 天真机（卖物品/抢劫/耐久） | 逐文件回滚；先加闸门再修 |

> 以上工时是静态估算，未实跑 ⚪；真实成本取决于真机验证排队。

## 6. 执行顺序：如果只能做 3 件事

### 第 1 件：方法级导出契约闸门 + 修掉它抓出来的死调用

**理由**：这是唯一一个能同时防住“丢物品/丢钱/静默失败”的**低成本**动作。qb-pawnshop 的 `custom-main:CheckRateLimit`（`server/main.lua:74`）在扣物品之前就报错，`:98` 在 `RemoveItem` 之后调不存在的 `AddScaledMoney`——玩家丢物品、拿不到钱。qb-storerobbery 的 `custom-economy:GetEconomyRewardScale`（`:446,674`）让奖励路径报错。这些都和抽象设计无关，**是“owner 删了、调用点没迁、没有闸门”**。先立闸门，再修 6 组自研坏调用 + 2 组兜底/上游；以后任何新调用点抄错名字都会在 CI 红。

**做完怎么知道成了**：
- 新 `tests/architecture/test_service_contracts.py` 在真实仓库上绿；它的反向用例（错 owner/错方法/缺登记）红。
- `grep` 结果：`exports['custom-main']:AddScaledMoney|CheckRateLimit`、`exports['custom-economy']:GetEconomyRewardScale|AddScaledMoney`、`exports['qb-inventory']:SetItemInfo` 全部为 0。
- 真机探针：卖一次 pawn 物品，日志出现 `AddScaled`/`AddMoney` 成功，物品与钱同时变化；抢一次 store，奖励不再报 `No such export`。
- `test_resource_wiring.py` 仍绿（资源名层），新闸门补方法名层。

### 第 2 件：退役跨资源 `Bus`，只保留一种写法

**理由**：Bus 是“采纳率 0”的根因，也是“同一服务两套写法”的来源。它不是性能问题，是**每个 `Bus.<foreign>` 调用都必然 nil**：custom-police 的追车 BGM、qb-ambulance 的重生 BGM、qb-storerobbery 的追逐场景都不会播；custom-taxes 的税不会进 sink 记账。把这些死分支改成 `exports[...]:service_*`（或直接删掉），并让 `Bus` 退化为 owner 侧注册辅助，才能让后来者只看到一种正确写法。

**做完怎么知道成了**：
- 新 `test_bus_scope.py` 绿：注册资源之外 0 个 `Bus.<service>` 读取；`_G.Bus.<service>` 读取 0（qb-core 的 EconomyService 例外由既有闸门管）。
- `custom-police/server/vehicle.lua:95`、`qb-ambulancejob:120,284`、`qb-storerobbery:552` 改为直接导出调用；真机听到场景音乐（至少 1 条路径）。
- `ARCHITECTURE.md` 的“唯一通道速查”加一行：“跨资源服务调用 = `exports['<owner>']:service_<name>_<method>`；Bus 仅是 owner 侧注册实现”；`REUSE.md` 加同一句。
- `Bus.Plugin` 要么删除，要么标 `planned` 且不再出现在对外文档。

### 第 3 件：把反滥用限流收口到 `RateLimit`，并补上闸门盲区

**理由**：这是安全原语里**闸门明确是绿的、实现明确是重复的**一类（custom-police 7 文件 / 8 表 + custom-director 1 文件 / 1 桶）。限流重复不是观感问题：每一份的边界行为不同，任何一份的 off-by-one 都是可利用的。owner 已有三种语义、可注入时间、可清理键；迁移成本最低、验证最直接。

**做完怎么知道成了**：
- `test_rate_limit_single_owner.py` 的 `IMPL_MARKERS` 扩展后，迁移前**红**（列出 `liveBuckets`/`policeAlertCooldown`/`towCooldown` 等），迁移后绿；`CALLERS` 包含 8 个迁移文件（custom-police 7 + custom-director 1）。
- `grep -n "now - .*<.*COOLDOWN|local .*Cooldown = {}|liveBuckets"` 在 `[custom]` 返回 0（业务冷却 `quest_cooldowns` 除外，登记为 not-rate-limit）。
- `RateLimit.Size()` 在玩家下线后不随在线时长单调增长（`RateLimitReset('sec:<src>:')` 已在 custom-security 使用，`server/security.lua:41`）。
- 真机：连续触发 forensics/tow/coroner/backup 事件，超过阈值的请求被拒绝，且 `core-framework` 日志没有 `RateLimit` 错误。

### 下一批（不在 3 件里，但同一季度）

4. `Db` 结果适配器（§4.2）——风险最高、迁移最大，放在契约闸门之后做才安全。
5. `CFShared.LoadModel` 采纳（§4.3）——1 天，消掉两个无超时循环。
6. `FormatMoney` 合并（§4.4）——低风险样板，顺便把 `$%d` 债往下压。
7. 证据广播收口（§4.6）——安全收益高，但需要 2 客户端验证。

### 明确不做（否则下一轮会重复提）

| 不做项 | 理由 |
|---|---|
| 合并 `DebugPrint` | REUSE.md 已定案：同名不同语义，各带调试开关/前缀（`reuse_budget.json` 的 `DebugPrint` 条目） |
| 合并 `[qb]`/`[standalone]` 的重复 | REUSE.md 已定案：不迁上游/第三方，避免分叉 |
| 再合并 `DrawText3D` | 已合并到 `CFShared.DrawText3D`（`reuse_budget.json` 条目、`core-framework/client/shared.lua:33-48`） |
| 把业务冷却并进 `RateLimit` | `quest_cooldowns` 是持久化状态（`custom-quest/server/quest_db.lua:157-206`），进程内限流重启即丢；语义不同 |
| 合并通知封装 | `QBCore:Notify` 原生、`custom-notify` 资源、phone NUI 三种通道语义不同；合并会改观感/延迟 |
| 合并权限检查 | `QBCore.Functions.HasPermission` 已是 owner；`PolicePolicy.Can`/`OrgStorage.CanAccess` 是域内策略，不是通用权限 |
| 全仓抽 `GetCoreObject` 重试样板 | 19 个资源里 18 个是 `[qb]` 上游（§3.2 #7）；`[custom]` 只有 custom-security 1 处，抽出来是“为 2 个调用点造一个抽象” |
| 抽通用 `Cache` | 各资源的 TTL/失效键/一致性要求不同（quest/phone/vehicles），没有证据存在统一契约；强行合并会把“缓存脏读”变成全局问题 |
| 合并进度条 option 表 | 那是调用参数，不是实现；改参数会改 UX |
| 复活 `custom-economy` 的 server | 它被 `core_economy` 取代是正确方向（`custom-economy/fxmanifest.lua:15-17` 明写 removed）；正确做法是迁调用点，不是把死网关救活 |
| 把 `players.money` 的写路径迁到 core-framework | 宪法②/`test_economy_single_owner.py` 已定 owner 是 qb-core；core-framework 只能做便利层，不能做第二写者 |
| 为跨资源服务调用新增 net event | 会绕开 exports 契约与 `test_net_event_auth` 的登记；服务调用是同步导出，不是事件 |
| 把 `Bus` 做成真正的 `_G` 全局总线 | 跨资源 `_G` 不共享；唯一可行的是 exports/events，做“全局总线”只会再造一个 0 采纳层 |
| 合并 qb-drugs 的 `Money()` | `[qb]` 上游，REUSE.md 不迁 |

## 7. 与现有闸门的关系

### 7.1 会红/需要调整的闸门

| 变更 | 现有闸门 | 影响 | 需要的新增/调整 |
|---|---|---|---|
| 服务契约登记 + 方法级闸门 | `test_resource_wiring.py:350-367`（只查资源名）、`test_export_contracts.py:47-49`（只查 custom-police） | 不冲突；补的是方法名层 | 新增 `test_service_contracts.py`；**必须自带反向用例**（错 owner/错方法/缺登记），否则 `gate_coverage_budget.json` 的 `max_unproven` 要上调 |
| 退役跨资源 Bus | `test_economy_service_single_registrar.py:37-44`（`_G.Bus.EconomyService` 单写者）、`test_economy_single_owner.py:146-153`（`GetEconomy` 原语优先） | 不能删 `_G.Bus.EconomyService`/`Bus.Plugin.GetEconomy`；只删“跨资源读取” | 新增 `test_bus_scope.py`；保留上述两条测试不动 |
| `Db` 适配器 | `test_query_discipline.py:41-47`（SQL 扫描）、`test_cross_resource_writes.py`（表 owner）、`test_no_server_await.py:18-28`（禁止 `Citizen.Await`） | 适配器不拼 SQL、不写表、不使用 `Citizen.Await`，三者保持绿 | 新增 `test_db_result_adapter.py`；`@core-framework/server/db.lua` 必须进 core-framework 的 `server_scripts`（`test_no_orphan_scripts.py`） |
| `LoadModel` 采纳 | `test_reuse_budget.py:111-133`（loadAnimDict 的惰性包装先例）、`test_no_orphan_scripts.py`（删文件要同步删清单） | 现有 `migrated` 列表是 loadAnimDict 专用，不能直接复用；需要新增 LoadModel 的迁移清单/测试；`reuse_budget.json` 新增 `LoadModel` | 新反向用例“本地 `while not HasModelLoaded` 必须红”；`LoadModel` 计数下降后同步降预算 |
| `FormatMoney` 合并 | `test_money_format.py:28-48`（`$%d` 基线双向相等）、`test_reuse_budget.py`（`Money` 计数）、`test_no_orphan_scripts.py`（删 `shared/money_format.lua`） | 基线条目会减少，**必须同 commit 更新** `money_format_baseline.json`；`Money` 计数预期从 6 降到 1（以实跑为准 ⛔），预算要收紧 | 新增语义闸门 `test_money_format_single_owner.py`（抓 `PhoneMoney`/`QuestMoney` 这种别名）；`reuse_budget.json` 的 `Money` `max` 改为 1 或删除条目（若 <4） |
| 限流扩展 | `test_rate_limit_single_owner.py:41-44`（marker）、`:89-96`（CALLERS） | 扩展 marker 会让现有 8 个文件先红（custom-police 7 + director 1）；这是**故意的先红后绿** | 扩展 `IMPL_MARKERS` + `CALLERS`；加反向用例（合成 `liveBuckets = {}` 必须红）；不新增例外 |
| 广播收口 | `test_budget.py:29-42` + `io_budget.json:28-31`（`broadcast_sites` 152） | 收口后数字下降，预算必须同步下调（`budget_probe.py --update` 只允许往下） | 新增 `test_broadcast_scope.py` + `broadcast_allowlist.json`；`broadcast_sites` 下调 |
| 新共享文件/清单 | `test_manifest_syntax.py`、`test_resource_wiring.py:329-347`、`test_load_time_callers_declare_the_core_dependency`（`test_reuse_budget.py:161-181`） | 新文件必须存在、进清单；加载期 include 必须声明 `dependencies { 'core-framework' }` | `service_contracts.lua` 若走 `shared_scripts`，所有调用方要声明依赖；`db.lua` 走 server include，同理 |
| 新 net event | `test_net_event_auth.py`、`test_net_event_scope.py` | 本方案**不新增 net event**；广播收口只改收件人，不改事件名 | 不需要登记新事件；若要新增，必须同时更新 `net_events_allowlist.json` |
| 平面边界 | `test_plane_boundaries.py:71-94` | `db.lua` 只能放 server；`service_contracts.lua` 必须是纯数据/纯函数（不能有 `RegisterNetEvent`/`TriggerClientEvent`） | 新文件按平面放；`bus.lua` 若移动，不能进 `shared/**` 的纯函数目录（它有 `exports()` 副作用） |

### 7.2 闸门覆盖率的记账方式

`tests/architecture/test_gate_coverage.py:43-56` 用 `max_unproven` 做棘轮：

- 新增一条**前向规则**（只扫真仓库、没有反向用例）→ `unproven +1`；如果超过 `max_unproven`（当前 278），必须先上调预算并在 `history` 写 `date/previous/why`。这与“棘轮只许往下”冲突，所以**本报告要求每条新闸门要么加入 `tools/dev/gate_mutation_smoke.py`，要么显式接受 +1 并在 history 写理由；只加一个反向用例不够**。
- 反向用例的命名要能被 `gate_coverage.py` 认成“已证明”：文件名/测试名带 `reverse`/`injected`/`fires`/`detects`/`rejects`/`on_bad_shapes`（`test_gate_coverage.py:8-9`）。建议统一用 `test_reverse_...`。
- **准确记账**：新加“前向规则 + 反向用例”两条 test 时，前向规则仍是 unproven（+1），反向用例是 proven（不增）。所以不能写成“加了反向用例就不增”；要么把前向规则加入 `tools/dev/gate_mutation_smoke.py`（推荐），要么把 `max_unproven` +1 并在 `history` 写 `date/previous/why/到期条件`。如果新规则本身就是反向用例（名字带 `reverse`），它计入 proven，不需要改预算。
- 当前基线是 `max_unproven=278`（`gate_coverage_budget.json:2`）。本报告 6 个模块如果各加 1 条前向规则且都只带反向用例，就要 +6；这个数字必须在实施 PR 里显式写出来，不能靠“规则合并”藏掉。

### 7.3 不降级闸门的声明

- **不**把 `test_export_contracts.py` 的 `>= 42` 导出阈值降低，也**不**把 custom-police 的审计/错误码规则推广成“全仓豁免”。
- **不**给 `test_query_discipline.py` 加新的 allowlist 条目来容纳 `Db` 适配器；适配器不拼 SQL，SQL 仍留在调用点，扫描器继续按字面量表名工作（`custom-police/server/records.lua:47-49` 已说明“表名必须是字面量”）。
- **不**把 `test_rate_limit_single_owner.py` 的例外表重新打开；迁移而不是豁免。
- **不**把 `io_budget.json` 的 `broadcast_sites` 调高来容纳新广播；新增广播必须走 `Broadcast.Scope` 或登记。
- **不**删除 `test_no_orphan_scripts.py` 的任何规则；删文件必须同步删清单/预算条目。

## 8. 自检

### 8.1 结论数量

| 章节 | 结论/条目数 |
|---|---|
| §1 判定 | 3 条（四平面设计对/执行半覆盖；Bus 设计错；P0 目录判定漏洞） |
| §2 采纳率根因 | 9 类根因（R1–R9）+ 27 个 service 逐条判定 |
| §3 风险分级 | 13 行风险×收益表 + 6 类“数字纠正” |
| §4 模块 | 6 个（≤8），每个 7 个固定字段 |
| §5 耦合 | 5 类信号（A–E）+ 扇入/扇出表 + 代价表 |
| §6 执行 | 3 件事 + 4 个下一批 + 14 条不做 |
| §7 闸门 | 10 行闸门影响表 + 覆盖率记账 + 5 条不降级声明 |

### 8.2 带 `path:line` 的比例

- 结论性判断中约 **95%** 带 `path:line`。未带的集中在：工时估算、批准人、§6 的“下一批”排序（属于判断/成本，不是代码事实），以及明确标了 ⛔ 的条目。
- 所有引用的底稿数字都标了节号（A–H）；所有推翻底稿数字的地方（§2.1 的 33/0、§3.1 的 9 份 Money、§5.1 E 的 43 重分类）都给了源码位置。

### 8.3 ⛔ 未验证条目（缺什么证据）

1. **`exports[owner][dynamicName]` 的字符串下标访问**：§4.1 的可选运行时 helper 依赖它；缺一次真机探针（`print(type(exports['custom-storage']['service_storage_CanAccess']))`）。在确认前，方案只要求闸门，不要求运行时 helper。
2. **`rawget(_G,'Config')` 在本 build 是否真的取不到**：§5.1 B 的 bug 判定依赖 AGENTS.md:73 的结论；缺一次真机打印（phone rate-limit 的 `PhoneRateLimit.DefaultRate/Burst` 实际值 vs convar 配置）。
3. **外部资源是否存在/导出**：`LegacyFuel`、`safecracker`、`qb-interior:CreateFurniMotelStandard`、`oxmysql:isConnected` 的调用是否真的会炸，部分无法从仓库证实（有的资源不在树里，有的可能由运行时提供）。`qb-fuel:GetFuel` 在树里，是 qb-fuel 的客户端自调用，按静态代码看确实没有对应导出，但它是上游代码，不在本次修复范围。§5.1 E 已把这类归到“外部依赖/上游”，没有把它们算进自研坏调用。
4. **commit 历史**：本次没有 shell，不能读 `git log`；关于“为什么当初这么写”的判断全部来自代码注释/文档，不是提交记录。若需要，补 `git log -S 'Bus.RegisterService'` 才能确认 Bus 的引入时间与当时的意图。
5. **闸门实跑**：没有 shell，未运行 pytest；§7 的“会红/会绿”是读断言后的推断，不是实测输出。真正的验收必须在 CI 跑一遍 `pytest tests/unit tests/architecture`。
6. **真机行为**：atmosphere BGM 不播、qb-pawnshop 丢物品、税率不进 sink、证据广播可被平民客户端读到——这些是从静态代码推出的 ⚪/✅（代码路径明确），但没有真机复现。修完后需要 2 客户端验证。
7. **深度覆盖**：没有逐个深读 116 个资源；`custom-phone` 的 NUI 层、`custom-director` 的 HTTP 层、`story-engine` 的决策引擎只读到与抽象/耦合相关的部分。`input focus` 的 11 个资源只做了抽样，标了 ⛔。

### 8.4 我没做到的

- 没有修改仓库、没有修任何 bug；本报告只给建议和迁移顺序。
- 没有运行任何测试、没有起服、没有真机探针；所有“会炸/不会炸”都是静态推断，已在 §8.3 标明。
- 没有读 git 历史，无法判断 Bus 是“设计时误以为 `_G` 跨资源共享”还是“后来资源拆分才失效”；从 `bus.lua:14` 的注释看，更像前者。
- 没有评估工作区里热狗任务的 10 个修改文件（按要求不评价、不触碰）。
- 没有给出精确工时；§5.3 的数字是静态估算，需 owner 校准。
