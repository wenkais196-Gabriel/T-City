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

**统计口径（必须写明，否则数字对不上）**：上表所有调用方数字的统计范围是
`T-CityLite.base/resources/**/*.lua`。同一模式在**全仓（含 tests/ 与 tools/）**是
**1116 处 / 202 文件**。plan 里写的"988 处 / 185 文件"含测试 mock，和今天的 930 不是同一口径，
不要混着引用。

core-framework 的 compat.lua 全文 **124 行**；`Bus.SafeCall` 全仓 7 行 = **4 个真实调用点**
（ambulancejob 两处、custom-police 一处、storerobbery 一处；另 2 条注释 + 1 处定义在 bus.lua）。

## 2. 三个猴补各自的真实问题

### 2.1 `GetPlayer` 的缓存层是净负数

qb-core 的 `GetPlayer(source)` 本来就是 `QBCore.Players[tonumber(source)]`——**一次表查**。
compat 在它外面加了：一次 `playerCache` 查 + 一次 `GetPlayerName` native 调用（跨 Lua/native 边界），
命中时反而**更慢**；未命中时是"两次查表 + 一次 native"。

更要紧的是正确性，但触发路径和最初写的不同（2026-11-01 验收方复核后更正）：

- 正常换角色（drop → 重新加载）**不会**留前任数据：`playerDropped` 与 `QBCore:Server:PlayerLoaded`
  两条 handler 都会清/覆盖缓存，且新角色构造必然触发后者。
- **真正的窗口是登出**：`QBCore.Player.Logout` 触发 `OnPlayerUnload`，200ms 后 qb-core 把
  `QBCore.Players[source]` 置 nil，但 compat **没有监听 `OnPlayerUnload`**。此时连接仍在、
  `isOnline(src)` 仍为 true → `GetPlayer(src)` 继续返回**已登出的前任 Player 表**；
  如果新角色加载失败、或玩家停在选人界面，这个窗口可以无限延长。
- 另外 compat 的 `isOnline` 里写了 `source <= 0`，而 qb-core 的 `GetPlayer` 明确接受 `"1"` 这种
  **字符串 source** —— 字符串走这条路径会抛 "attempt to compare string with number"，
  这是删缓存前就已经存在的兼容性回归。

所以 P1-4.2 的判据不能写成"换角色后同 tick 读 job 得新值"（当前代码就能过），
必须写成"**Logout 之后、下一次 PlayerLoaded 之前**，`GetPlayer(src)` 必须返回 nil"。

### 2.2 `AddMoney` 的每玩家闭包有三份路由

`player.lua` 里 `Player.Functions.AddMoney` 与 `RemoveMoney` **都已经路由** `Bus.EconomyService`
（两个函数是对称的，原先写"RemoveMoney 走另一条路径"不准确）。compat 的问题不是"多一条路"，
而是**回落语义危险**：

- compat 的 `origAddMoney` 不是"原始内存操作"，它就是 `player.lua` 那个**同样调 ES** 的实现 →
  ES 抛错但已写库时，回落会**二次加钱**；回落再抛错则错误直接冒给调用方。
- 更危险的是**归属**：仓库里有两份 EconomyService（qb-core 的 server/services 下那份
  economy_service 与 core-framework 的 services 下那份），后者内部又调 `Player.Functions.AddMoney`。
  如果注册到 `_G.Bus.EconomyService` 的是后者，包装 → ES → `Player.Functions.AddMoney`（包装）→ ES
  就是**递归**。P1-4.3 必须先钉死"哪份实现注册到 Bus、注册顺序与覆盖规则"，再谈删包装。

### 2.3 `Notify` 直连 `_G.Bus`，没有资源生死守卫

`Bus` 是全局表，`core-framework` 停掉后 `_G.Bus` 仍指向旧表（Lua 全局不会自动清），
`notifySvc.Send` 会在已停止的资源里执行 → 调用方拿到静默失败或 native 错误。
同类问题在 `Bus.SafeCall` 也有：全仓 7 行里只有 **4 个真实调用点**（ambulancejob 两处、custom-police 一处、storerobbery 一处），全部没有 `GetResourceState` 守卫。

## 3. 改造目标与验收

| 目标 | 判据（可自动验证） |
|---|---|
| compat 不再给 `QBCore.Functions` 赋值 | 静态闸门：`resources/**`（**排除 `[qb]/qb-core`**）里 `QBCore.Functions.X =`、`QBCore.Functions['X'] =`、`Player.Functions.X =` 三种形态的**赋值**数量必须等于登记表（终态 0），新增即红 |
| 登出不串数据 | 离线单测：`Logout` 之后、下一次 `PlayerLoaded` 之前，`GetPlayer(src)` 必须为 **nil**（当前实现会返回已登出的 Player 表） |
| 钱只有一条路径 | ① 单测：`Bus.EconomyService` 的注册者**唯一**（启动后打印/断言归属），排除"包装→ES→包装"递归；② 单测：ES 抛错时 `AddMoney` 不得二次加钱（用 mock ES 统计调用次数与最终余额） |
| Notify 有生死守卫 | 静态断言：**所有**跨资源入口都带 `GetResourceState('core-framework') == 'started'`（"改走 export" 不算守卫——export 到已停止资源同样失败） |
| 不回归 | `pytest tests/unit tests/architecture tests/integration` 全绿；真机 85 资源 0 SCRIPT ERROR |

## 4. 分阶段施工（每一步独立可回滚）

**P1-4.1 冻结（先止血）**
新增闸门 tests/architecture/test_no_monkey_patch.py（本轮不建，P1-4.1 建）。三个必须写进扫描规则的坑：

1. **排除 `[qb]/qb-core`**：`function QBCore.Functions.GetPlayer(` 在那里是**自己定义公开 API**，
   不排除的话第一天就有几十条红，4 条 allowlist 远远不够。
2. **覆盖两种赋值形态**：`QBCore.Functions.X =` 与 `QBCore.Functions['X'] =`（表下标赋值同样能猴补）。
3. **production-freeze 的写法不是 `.Functions`**：它是 `QBCore.Debug = function() end` /
   `QBCore.ShowError` / `QBCore.ShowSuccess`，用 `.Functions` 正则命不中 —— allowlist 里按这个形状登记，
   否则是死条目。

存量登记在 monkey_patches_allowlist.json（GetPlayer / AddMoney / Notify + production-freeze 一组），
带 owner + expires 2027-03-31；变异用例：往 `resources/[custom]/custom-vehicles/server/` 塞一个
`QBCore.Functions.GetPlayer = function() end`，闸门必须红。

**P1-4.2 `GetPlayer` 去缓存（收益最大、风险最低）**
- 删掉 compat 里的 `playerCache` 与 `function QBCore.Functions.GetPlayer`；
- 单测：`test_player_cache_never_serves_previous_character`（同 source 换角色）；
- 性能口径：`GetPlayer` 从"1 次表查 + 1 native"回到"1 次表查"——不需要基准测试也成立；
- 风险：若有资源**依赖**缓存的"同一表引用"语义（改了 Player 表后用旧引用读），删缓存后行为不变（qb-core 本来就返回同一张表）。

**P1-4.3 `AddMoney` 路由下沉**
- **第一步：钉死 `Bus.EconomyService` 的注册者唯一**（仓库有两份实现，core-framework 那份内部
  又调 `Player.Functions.AddMoney` —— 注册错了就是递归）；用启动断言 + 单测把它固定下来；
- 确认 qb-core 的 player.lua 里 `AddMoney` 已走 `Bus.EconomyService`（读代码，不假设）；
- 若已走：删掉 compat 的每玩家包装；
- 若未走：把路由写进 `player.lua` 一次（而不是每个玩家一份闭包）；
- `RemoveMoney` 与 `AddMoney` 对齐（同一路由 + 同一审计）；
- 单测：一条钱流水在 `PlayerData.money` / DB / 审计三处一致。

**P1-4.4 `Notify` 与 `Bus.SafeCall` 的生死守卫**
- `Notify` 改为 export（`exports['core-framework']:Notify(...)`），调用点用
  `if GetResourceState('core-framework') == 'started' then` 守卫；
- 4 个真实 `Bus.SafeCall` 调用点同样加守卫（`GetResourceState` 判定），不能只改 export；
- 521 处调用点**不需要全改**：`QBCore.Functions.Notify` 是 qb-core 自己的 API，
  只要不再被 compat 覆盖就回到 qb-core 实现（五层校验仍在）。

## 5. 风险与回滚

| 风险 | 应对 |
|---|---|
| 删 `GetPlayer` 包装后，某些资源依赖"缓存里那份表" | qb-core 返回的本来就是 `QBCore.Players[src]` 同一张表，语义不变；先真机跑 30 分钟 |
| `AddMoney` 路由下沉改错，钱多/少一次 | 单测 + 真机用 `/addmoney` 命令走一遍，看 `bus_economy` 审计与 DB |
| 521 处 Notify 调用点里有资源在 `core-framework` 未启动时调用 | 守卫后静默跳过，不能 `error`；用 `GetResourceState` 而非 `IsDuplicityVersion` |
| 闸门误报 production-freeze（它确实在改全局） | 登记表里单列，并把它限定为 dev-only 资源（convar gate） |
| **EconomyService 双实现导致递归** | P1-4.3 前置：先钉死 Bus 上的注册者唯一（启动断言 + 单测），再删包装 |
| **compat 在加载时捕获 `orig`** | `compat.lua:67/:109` 顶层取 `QBCore.Functions.GetPlayer/Notify`；若 compat 早于 qb-core 完成定义，`orig` 为 nil → 加一条启动顺序/依赖断言 |

## 6. 本轮验证记录（2026-11-01）

```text
python3 -m pytest T-CityLite.base/tests/architecture -q   →  433 passed, 15 skipped
python3 tools/docs_lifecycle.py --check                    →  total=283 registered=283 errors=0 warnings=0
```

（验收方的环境里 `python` 没有 pytest 且工作目录不对，跑出 "file or directory not found"；
上面是本机标准环境 `tc-venv` 的输出。）

## 7. 不在这一项里做的

- `[qb]` 上游资源的兼容层（qb-vehiclekeys / qb-mechanicjob 的旧事件桥）—— 那是 P1-3 的
  兼容面登记，不属于 `QBCore.Functions` 猴补；
- 930 处调用点的批量改写 —— 目标是签名不变，调用方零改动；
- 性能基准 —— 只有"少一次 native 调用"这种结构性结论，不编造数字。
