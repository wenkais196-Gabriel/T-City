# QBCore 客户端代码面分析（T-City 实测 + 上游对照）

> 口径：本仓库 `T-CityLite.base/resources`（HEAD 时点）+ 上游 `qbcore-framework/qb-core@main` + 官方文档。
> 结论只针对"客户端"这一侧：客户端脚本、客户端 API 面、客户端与服务端的信任边界。
> 更新：2026-10-26

---

## 1. 代码盘点

### 1.1 qb-core 客户端文件（本仓库）

| 文件 | 行数 | 职责 |
|---|---:|---|
| `client/functions.lua` | 1179 | 全部客户端 API：callback、Notify、Progressbar、载具属性读写、坐标/池查询、粒子/动画 |
| `client/events.lua` | 306 | net 事件消费：登录、传送、刷车、PlayerData 同步、callback 回包、Shared 热更 |
| `client/native_notify.lua` | 225 | **本仓库新增**：GTA 原生 The Feed / Award / HelpText 封装，`_G.NativeNotify` |
| `client/drawtext.lua` | 60 | DrawText NUI（`SendNUIMessage`） |
| `client/loops.lua` | 54 | 两个常驻线程：定期 `QBCore:UpdatePlayer`、饥饿/口渴掉血 |
| `client/main.lua` | 50 | **本仓库新增**：构建 `QBCore` 全局壳 + `GetCoreObject`/`GetSharedItems` 等 exports |
| 合计 | **1874** | 上游同目录为 4 文件 / 1495 行（无 main、无 native_notify） |

### 1.2 与上游的结构差异

| 项 | 上游 qb-core | 本仓库 |
|---|---|---|
| `QBCore` 全局在哪建 | `config.lua` 第 1 行 `QBCore = {}`（shared 脚本，先于一切加载） | `client/main.lua:1`（客户端）+ `shared/main.lua` 改用 `QBShared` 命名空间 |
| 客户端脚本数 | 4（functions/loops/events/drawtext） | 6（多 main + native_notify） |
| 通知通道 | 单轨：全部 `SendNUIMessage` → Quasar toast | **三轨**：插件总线 → NUI → 原生 The Feed（失败回退 NUI） |
| 心跳 | 固定 60s×`UpdateInterval` | 首登随机 1–30s 错峰 + 按静止/奔跑/射击/通缉计算 `multiplier` |
| exports | `GetCoreObject` / `GetShared` | `GetCoreObject` + 5 个 Shared 导出 + `QBCore.Functions.*` **整体自动导出**（`functions.lua:1172`） |
| 服务端 | 单文件 functions/player/events | 拆出 `services/*.lua`（security/economy/metadata/qualification/persistence/heat/sink） |

---

## 2. 技术特点（5 条）

1. **"薄客户端 + 全局单例"**：客户端不持有权威数据，只缓存 `QBCore.PlayerData` 与 `QBCore.Shared`；一切通过一个 `QBCore` 全局表访问。资源间没有依赖注入，谁都能 `GetCoreObject()` 拿到同一张表。
2. **双向 callback 走同一套名字空间**：客户端 `QBCore.ServerCallbacks[name] = {callback, promise}`（`functions.lua:18`），服务端 `QBCore.ServerCallbacks[name] = cb`（`server/functions.lua:484`）。名字是全局字符串，靠命名约定（`qb-garages:server:*`）避免冲突。
3. **事件总线混搭 NUI**：689 处 `RegisterNetEvent`（客户端目录）+ 246 处 `SendNUIMessage`。UI 层是"客户端推、CEF 渲染"，没有请求-应答语义，也没有 schema。
4. **数据同步是"整表覆盖 + 事件通知"**：`QBCore:Player:SetPlayerData` 直接 `QBCore.PlayerData = val`（`events.lua:194`）；`QBCore:Client:SharedUpdate` 直接整表替换 `QBCore.Shared`（`events.lua:305`）。没有 diff，也没有版本号。
5. **状态双轨**：`isLoggedIn`/`isSpawnFinished` 走 state bag（全仓 90 处 `LocalPlayer.state`），而 job/money/metadata 走 net 事件 + 本地表。两套机制并存，导致"何时能读 PlayerData"没有单一判据。

---

## 3. 全仓使用面（实测计数）

| 指标 | 数值 | 说明 |
|---|---:|---|
| 客户端 Lua 总行数（`[qb]/*/client` + `[custom]/*/client`） | 52,109 | qb-core 自身占 3.6% |
| `GetCoreObject` 出现次数 | 89 | 每个资源各自 import 一次 |
| `TriggerCallback` 调用 | 211 | 客户端→服务端 |
| `RegisterNetEvent`（客户端目录） | 689 | 客户端消费的事件面 |
| 服务端 `CreateCallback` 注册 | 177 次 / 173 个唯一名字 | 全部可被任意客户端按名字调用 |
| 客户端 `CreateClientCallback` | 2 | 服务端→客户端 callback 几乎没用起来 |
| `SendNUIMessage` | 246 | NUI 通道被当作通用消息总线 |
| `CreateThread` | 324 | |
| `Wait(0)` 出现点 | 152 | 每帧轮询（含 native 忙等）的规模 |
| `LocalPlayer.state` | 90 | |

---

## 4. 分析

### 4.1 设计上成立的部分

- **API 面窄且稳定**：客户端只有 `QBCore.Functions.*` 一个入口，下游 50+ 资源用同一套调用；这对"给 LLM agent 做动作映射"是好事——可枚举、可包一层。
- **客户端不持有权威**：钱/物品/job 都在服务端 `Player.Functions.*`；客户端 `HasItem` 走 `exports['qb-inventory']`，不自己算。
- **本仓库的三处加固方向正确**：客户端心跳的 `multiplier` 在服务端被钳制到 0.1–3.0（`server/events.lua:149`）；`SecurityService` 对 job/gang/money 事件做了值与 source 清洗；通知加原生通道降低 CEF 负担。

### 4.2 结构性缺陷（按严重度）

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| 1 | **公共 callback 派发器无鉴权** | `server/events.lua:132`：任何客户端 `TriggerServerEvent('QBCore:Server:TriggerCallback', <任意名字>, ...)` 即可调用全部 173 个已注册 callback | 与 Qbox issue #771 同类；`QBCore:Server:SpawnVehicle`（`server/events.lua:290`）零权限校验，任何人可刷任意载具并 warp 入车 |
| 2 | **同名 callback 覆盖竞态** | `functions.lua:18`：以 name 为键写单槽；并发两次同名调用，先挂起的 promise 永远不 resolve | 玩家连着点两次同类交互 → 客户端协程永久卡住（`Citizen.Await` 无超时） |
| 3 | **客户端权威刷车** | `client/events.lua:121`：客户端 `CreateVehicle(..., true, ...)` 后自己注册钥匙 | 刷车/钥匙服务端无从校验，属于"UI 隐藏 ≠ 权限" |
| 4 | **资源加载忙等无超时** | `LoadModel`（`functions.lua:433`）、`RequestAnimDict`/`LoadAnimSet`/`LoadParticleDictionary` 全是 `while not loaded do Wait(0) end` | 模型损坏/资源缺失时该线程永久 spin；同文件 `PlayAnim` 有 5s 超时，说明是遗漏而非取舍 |
| 5 | **池全遍历 + 每帧轮询** | `GetClosestVehicle/GetClosestPed/GetClosestObject` 遍历整个 game pool；152 处 `Wait(0)` | 人多车多时是客户端帧时间的主要抖动源；没有距离预筛/空间索引 |
| 6 | **整表覆盖同步** | `events.lua:194`、`305` | 半更新（只改 job）会整体替换，订阅方拿不到 diff，容易读到中间态 |
| 7 | **NUI 无 schema/无背压** | 246 处 `SendNUIMessage`，`html/js/app.js` 只按 `data.action` 分支 | 拼错字段静默失败；通知风暴时 CEF 端无节流 |

### 4.3 与主流替代（Qbox / ox_lib）对照

| 维度 | QBCore（本仓库同源） | Qbox / ox 栈 |
|---|---|---|
| 玩家数据下发 | net 事件 + 客户端整表缓存 | state bag 镜像，客户端只读 |
| 客户端→服务端调用 | 全局名字空间的公共派发器 | `lib.callback`（按资源隔离注册 + await/callback 两种形态） |
| 物品权威 | qb-inventory，历史上信任客户端槽位参数 | ox_inventory，服务端权威槽位/重量 |
| 客户端刷车 | 客户端 `CreateVehicle` 是常规做法 | 服务端 `SpawnVehicle` 模块 + 权限 |
| 结论 | 生态最大、改造成本最低 | 信任模型更严，但迁移要动 inventory 层 |

---

## 5. 如果要改，按这个顺序

**P0（安全，1–2 天）**
1. 给 `QBCore:Server:TriggerCallback` 加**服务端白名单**：只放行"客户端可以调用"的 callback 名（注册时带 `clientCallable = true` 标记），其余直接丢弃并写审计。
2. 每个 callback 内做 source/距离/权限复验；`QBCore:Server:SpawnVehicle`、`qb-inventory:server:giveItem` 优先。
3. 关掉 `client/events.lua:121` 的客户端刷车路径，改走服务端 spawn 回调。

**P1（稳定性，2–3 天）**
4. callback 键改成 `name .. ':' .. requestId`，回包带 requestId；`Citizen.Await` 外套超时（`promise` + `SetTimeout` 5s 后 reject）。
5. 所有 `while not loaded do Wait(0)` 加 5s 超时 + `SetModelAsNoLongerNeeded` 兜底。
6. `GetClosest*` 先按 `#(coords - center) < radius` 预筛，再算精确距离；把调用点从每帧线程挪到"进入范围才起的线程"。

**P2（架构）**
7. PlayerData 改为 state bag 镜像 + 增量 patch 事件（`{path, value}`），保留旧事件做兼容层。
8. NUI 消息加统一 `action` 常量表与 payload 校验（CEF 端 zod 风格校验或 Lua 侧白名单）。
9. 把客户端 API 面导出为机器可读清单（类似本项目 `tools/agent_tools.json` 的做法），供 agent 动作映射与自动化审计复用。
