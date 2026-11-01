---
id: p1-4-decompat-research
type: research
status: active
system: infra
owner: hermes
updated: 2026-11-01
review_by: 2026-12-31
---

# P1-4 调研：拆掉 compat 的全局猴补

> 结论先说：这一项的真实范围**不是** 988 处调用，而是 **3 个猴补点**（`QBCore.Functions.GetPlayer` /
`Player.Functions.AddMoney` / `QBCore.Functions.Notify`）+ **930 处**调用方。
调用方绝大多数**不需要改**——它们调的是同一个签名，只是实现换了位置。
真正要动的是这 3 个点本身和它们的启动顺序假设。

## 1. 现状实测（2026-11-01，`c50082bf` 之后）

| 猴补点 | 位置 | 干什么 | 依赖它的调用方 |
|---|---|---|---|
| `QBCore.Functions.GetPlayer` | core-framework 的 compat.lua 第 77 行 | 在 qb-core 的查表外再套一层 `playerCache[source]` + `GetPlayerName` 活性校验 | **930 处 / 164 文件**（`QBCore.Functions.GetPlayer`） |
| `Player.Functions.AddMoney` | 同上:25 | 每个玩家登录时把 `Player.Functions.AddMoney` 换成闭包，直连 `Bus.EconomyService`，失败回落 `origAddMoney` | 55 处（`Player.Functions.AddMoney`）+ 45 处 `RemoveMoney`（未包装） |
| `QBCore.Functions.Notify` | 同上:111 | 优先 `Bus.notify.Send`，否则回落原实现 | **521 处** |
| `QBCore.Debug` / `ShowError` / `ShowSuccess` | production-freeze/server/main.lua:26-32 | 生产模式下一个开关把它们换成空函数 | 仅该资源自身（测试用） |

core-framework 的 compat.lua 全文 **124 行**，`Bus.` 引用 283 处、`core-framework` 字样 253 处
（含文档与注释，不是调用数）。plan 里写的"988 处 / 185 文件"是 `GetPlayer` 的旧统计口径，
今天实测是 **930 处 / 164 文件**。

## 2. 三个猴补各自的真实问题

### 2.1 `GetPlayer` 的缓存层是净负数

qb-core 的 `GetPlayer(source)` 本来就是 `QBCore.Players[tonumber(source)]`——**一次表查**。
compat 在它外面加了：一次 `playerCache` 查 + 一次 `GetPlayerName` native 调用（跨 Lua/native 边界），
命中时反而**更慢**；未命中时是"两次查表 + 一次 native"。

更要紧的是正确性：`playerCache[source]` 只在 `playerDropped` 与 `QBCore:Server:PlayerLoaded` 时清。
**同一 source 换角色**（先 drop 再加载，或 #退出重进）时，若 `playerDropped` 先于本资源的 handler
执行、且新加载没触发我们挂的 `PlayerLoaded`，缓存里就留着**上一个人的 Player 表**——
读 job/citizenid 会拿到前任的数据。这正是 plan 里那条 DoD（"换角色后同 tick 读 job 得新值"）要防的事。

### 2.2 `AddMoney` 的每玩家闭包有三份路由

`player.lua` 里 `Player.Functions.AddMoney` 已经路由到 `Bus.EconomyService`；
compat 又在 `PlayerLoaded` 时包一层直连 `Bus.EconomyService`，失败再回落 `origAddMoney`。
结果是同一个语义有**两条路径 + 一个回落**，且 `RemoveMoney` 完全没被包（45 处调用走另一条路径）。
调试时看到的"钱扣了但没记账"就看不出走的是哪条。

### 2.3 `Notify` 直连 `_G.Bus`，没有资源生死守卫

`Bus` 是全局表，`core-framework` 停掉后 `_G.Bus` 仍指向旧表（Lua 全局不会自动清），
`notifySvc.Send` 会在已停止的资源里执行 → 调用方拿到静默失败或 native 错误。
同类问题在 `Bus.SafeCall`（7 处）也有：没有 `GetResourceState` 守卫。

## 3. 改造目标与验收

| 目标 | 判据（可自动验证） |
|---|---|
| compat 不再给 `QBCore.Functions` 赋值 | 静态闸门：`resources/**` 里 `QBCore.Functions.<X> =` / `Player.Functions.<X> =` 的**赋值**数量必须等于登记表（终态 0），新增即红 |
| 换角色不串数据 | 离线单测：同一 source 先加载 A（citizenid=A）再加载 B，同 tick 读 `GetPlayer(src).PlayerData.citizenid` 得 B |
| 钱只有一条路径 | 单测：`Player.Functions.AddMoney/RemoveMoney` 都只经过 `PlayerData.money` + `Bus.EconomyService`，且 `compatStats` 不再增长 |
| Notify 有生死守卫 | 静态断言：跨资源调用点必须 `GetResourceState('core-framework') == 'started'` 或走 export |
| 不回归 | `pytest tests/unit tests/architecture tests/integration` 全绿；真机 85 资源 0 SCRIPT ERROR |

## 4. 分阶段施工（每一步独立可回滚）

**P1-4.1 冻结（先止血）**
新增闸门 tests/architecture/test_no_monkey_patch.py（本轮不建，P1-4.1 建）：
- 扫 `resources/**/*.lua`，正则匹配 `^\s*(QBCore|Player)\.Functions\.[A-Za-z_]+ =` 与 `^function QBCore\.Functions\.[A-Za-z_]+\(`；
- 存量登记在 monkey_patches_allowlist.json（4 条：GetPlayer / AddMoney / Notify + production-freeze 的 3 个 QBCore.Debug/ShowError/ShowSuccess 记 1 组），每条带 owner + expires 2027-03-31；
- 变异用例：往 `resources/[custom]/custom-vehicles/server/` 塞一份 `QBCore.Functions.GetPlayer = function() end`，闸门必须红。

**P1-4.2 `GetPlayer` 去缓存（收益最大、风险最低）**
- 删掉 compat 里的 `playerCache` 与 `function QBCore.Functions.GetPlayer`；
- 单测：`test_player_cache_never_serves_previous_character`（同 source 换角色）；
- 性能口径：`GetPlayer` 从"1 次表查 + 1 native"回到"1 次表查"——不需要基准测试也成立；
- 风险：若有资源**依赖**缓存的"同一表引用"语义（改了 Player 表后用旧引用读），删缓存后行为不变（qb-core 本来就返回同一张表）。

**P1-4.3 `AddMoney` 路由下沉**
- 确认 qb-core 的 player.lua 里 `AddMoney` 已走 `Bus.EconomyService`（读代码，不假设）；
- 若已走：删掉 compat 的每玩家包装；
- 若未走：把路由写进 `player.lua` 一次（而不是每个玩家一份闭包）；
- `RemoveMoney` 与 `AddMoney` 对齐（同一路由 + 同一审计）；
- 单测：一条钱流水在 `PlayerData.money` / DB / 审计三处一致。

**P1-4.4 `Notify` 与 `Bus.SafeCall` 的生死守卫**
- `Notify` 改为 export（`exports['core-framework']:Notify(...)`），调用点用
  `if GetResourceState('core-framework') == 'started' then` 守卫；
- 7 处 `Bus.SafeCall` 同样加守卫或改 export；
- 521 处调用点**不需要全改**：`QBCore.Functions.Notify` 是 qb-core 自己的 API，
  只要不再被 compat 覆盖就回到 qb-core 实现（五层校验仍在）。

## 5. 风险与回滚

| 风险 | 应对 |
|---|---|
| 删 `GetPlayer` 包装后，某些资源依赖"缓存里那份表" | qb-core 返回的本来就是 `QBCore.Players[src]` 同一张表，语义不变；先真机跑 30 分钟 |
| `AddMoney` 路由下沉改错，钱多/少一次 | 单测 + 真机用 `/addmoney` 命令走一遍，看 `bus_economy` 审计与 DB |
| 521 处 Notify 调用点里有资源在 `core-framework` 未启动时调用 | 守卫后静默跳过，不能 `error`；用 `GetResourceState` 而非 `IsDuplicityVersion` |
| 闸门误报 production-freeze（它确实在改全局） | 登记表里单列，并把它限定为 dev-only 资源（convar gate） |

## 6. 不在这一项里做的

- `[qb]` 上游资源的兼容层（qb-vehiclekeys / qb-mechanicjob 的旧事件桥）—— 那是 P1-3 的
  兼容面登记，不属于 `QBCore.Functions` 猴补；
- 930 处调用点的批量改写 —— 目标是签名不变，调用方零改动；
- 性能基准 —— 只有"少一次 native 调用"这种结构性结论，不编造数字。
