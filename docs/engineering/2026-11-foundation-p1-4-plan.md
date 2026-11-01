---
id: p1-4-plan
type: plan
status: active
system: infra
owner: hermes
updated: 2026-11-01
review_by: 2026-12-31
---

# P1-4 开发计划与交付标准（实施方 + 验收方联合定稿）

> 两份**独立**调研：实施方 `docs/engineering/2026-11-foundation-p1-4-research.md`；
> 验收方（CC）在同一天未读该文档前独立完成另一份。本文件是合并结论，冲突处标注取舍。
> 结论：**不是"迁 900 多处调用"，而是删掉 3 个猴补点**；其中 `AddMoney` 包装今天是**死代码**，
> 真正有生产风险的是 `GetPlayer` 缓存与"core-framework 重启后 funcref 悬空"。

## 1. 决策摘要

1. `core-framework` 的 compat 只覆盖三个符号：`QBCore.Functions.GetPlayer`（活）、
   `QBCore.Functions.Notify`（活）、`Player.Functions.AddMoney`（**死代码**）。
2. **`_G` 不跨 FiveM 资源**。`_G.Bus` 是各资源自己的表：qb-core 把 `EconomyService` 写进**自己状态**的
   `_G.Bus`，core-framework 的 compat 里 `_G.Bus.EconomyService` 恒为 `nil` → ES 分支永不成立。
   `bus.lua:14` 那句"显式 _G 确保跨资源可见"的注释是错的。
3. `AddMoney` 包装即使被"修好"也是三重错位（`ES` 多传一参、`self` 形参与 3 参 dot 调用不匹配、
   跨资源取不到 ES）→ **只能纯删除，不能修好再删**：修好会把死代码变成全服 SCRIPT ERROR
   或"先加钱后抛错 + pcall 回落"的**双倍加钱**。
4. `GetPlayer` 缓存是净负数：qb-core 本来就是一次表查，缓存命中反而多一次 `GetPlayerName` native；
   且 **Logout 后不清**（`OnPlayerUnload` 没监听）→ 选人界面期间全服拿到已登出的 Player 表。
5. 经济链路的唯一写入口是 **qb-core 的 `_G.Bus.EconomyService`**；core-framework 那份只注册成
   `Bus.economy` + `service_economy_*` exports，两者命名空间不交叉。**不得**把后者挂到前者
   （它内部回调 `Player.Functions.AddMoney` → 无限递归）。
6. `Notify` 包装是活的，但会**静默改变语义**（每源 200ms 一条、超时丢弃、正文截断 300 字符），
   且让 `QBCore.Functions.Notify` 依赖 core-framework 的运行状态。

## 2. 最终范围

口径：`grep -rho` **出现次数** / 文件数，范围 `T-CityLite.base/resources/**/*.lua`。
（验收方独立测量为 GetPlayer 703/120，差异来自是否计入 `[qb]` 上游与测试；本计划不依赖精确值。）

| 猴补点 | 位置 | 活的？ | 依赖量 | 删除后谁接管 |
|---|---|---|---|---|
| `QBCore.Functions.GetPlayer` | core-framework 的 compat.lua:77 | 活（缓存） | 936 处 / 164 文件 | qb-core `server/functions.lua:46`（一次表查） |
| `QBCore.Functions.Notify` | 同文件:111 | 活（转发 Bus.notify） | 服务端 17 处 / 6 文件（客户端是另一个对象，够不着） | qb-core `server/functions.lua:739`（原五层校验） |
| `Player.Functions.AddMoney` | 同文件:25 | **死**（三条独立原因都指向回落） | 60 处 / 27 文件 | qb-core `player.lua:357`（已路由 ES） |
| `QBCore.Debug / ShowError / ShowSuccess` | production-freeze/server/main.lua:26-32 | 活（生产模式静音） | 该资源自身（测试工具） | 单列为 dev-only，不在本计划删除 |

## 3. 缺陷清单（D 编号为本文档统一口径）

| 编号 | 缺陷 | 触发条件 → 后果 | 来源 |
|---|---|---|---|
| D1 | `AddMoney` 包装三条独立死因：① ES 跨资源恒 nil（`compat.lua:29` 的 `_G.Bus.EconomyService`）；② 若可见，`pcall(ES.AddMoney, ES, cid, …)` 多传一个 `ES` 实参 → 参数整体错位（qb-core 的 ES 是 dot 定义，`qb-core/server/services/economy_service.lua:93`）；③ 即使传参正确，compat 的形参是 `function(self, moneytype, amount, reason)`（`compat.lua:25`）而 60 处调用点是 3 参 dot 调用 → `self='cash'`，`self.PlayerData` 为 nil | **今天**：① 使 `if ES then` 整段跳过，**不执行 pcall**，直接回落 orig（行为等于原生直调，只是多一次 `if`）；**若把可见性"修好"**：② 生效 → 恒 false 无害，或③生效 → 全服加钱点 SCRIPT ERROR；若同时修好 ②③ → ES 内 `fireAuditLog`（`qb-core/.../economy_service.lua:66-76`，`%d` 格式化小数会抛）先加钱后抛错，pcall 吞错回落原生再调 ES = **双倍加钱** | 双方（②③ 的机制与 `%d` 出处由验收方给出） |
| D2 | Logout 后缓存返回前任角色 | `QBCore.Player.Logout` → `OnPlayerUnload` → **200ms 后**才置 nil，compat 不监听 `OnPlayerUnload`，且 `isOnline` 用 `GetPlayerName` 恒真 → 玩家停在选人界面时 `GetPlayer(src)` 返回**已登出**的表，`if not Player then return end` 全线失效 | 双方（实施方初稿的触发路径写错，已按验收方更正） |
| D3 | `isOnline` 对字符串 source 抛错 | `source <= 0` 与 `"1"` 比较 → `attempt to compare string with number`；发生在 orig 已成功**之后** → 从"返回玩家"变成"抛错" | 验收方 |
| D4 | core-framework 重启后 funcref 悬空 | 加载时捕获 `origGetPlayer/origNotifyFn`；`restart core-framework` 后 qb-core 表里留着旧 shim → 新实例捕获到失效引用 | 验收方 |
| D5 | 重复加载叠层 | 同一进程多次重启 → shim2→shim1→qb-core，两层缓存、两次 native | 验收方 |
| D6 | Notify 静默改语义 | `notify_service.lua:15-16` 每源 200ms 仅 1 条、`:125` 超限静默丢弃、`:131` 正文截断 300 字符并去 HTML、`:119` `GetPlayerPing==0` 直接丢；**没有丢弃计数** | 验收方 |
| D7 | `Bus.RegisterService` 无重名守卫 | `bus.lua:22-37` 同名再注册会静默覆盖 `Bus[name]` 并再次 `exports(...)`（重复 exports 的行为**预期如此、未在 FiveM 层验证**） | 验收方 |
| D8 | compat 统计日志混合指标 | `shimmed_count` 被 Notify 与（永不成立的）AddMoney 共用 → 日志"X% 直连"误导运维 | 验收方 |

## 4. 分阶段施工

每个阶段 = 一个可独立合并/回滚的 PR。**B、C、D 按顺序**（同改一个文件）。

### 阶段 A：静态闸门冻结新增猴补
- 新增 tests/architecture 下的 test_no_monkey_patch.py + monkey_patches_allowlist.json；
- 扫描根：`T-CityLite.base/resources/**/*.lua`；**排除** `[qb]/qb-core/**`（API owner）、任何 `tests/`、`docs/`；
- 覆盖 **4 种形态**：`function <prefix>.<Name>(`、`<prefix>.<Name> =`、`<prefix>["<Name>"] =` 与 `<prefix>['<Name>'] =`（单双引号都要）、裸 `QBCore.<Name> =`；
  `<prefix> ∈ {QBCore, QBCore.Functions, Player.Functions, _G.Bus}`；
- 登记项 `{file, symbol, owner, reason, expires}`；三条失败条件：**未登记命中 / 登记已过期 / 登记项 0 命中（死条目）**；
- 变异用例：`tmp_path` 造 4 个形态各一的 fixture + 1 个排除路径下的对照，闸门必须红 4 放过 1。

### 阶段 B：删 `GetPlayer` 缓存
- 删 compat 里 origGetPlayer / playerCache / isOnline / `function QBCore.Functions.GetPlayer` 及两个 handler；
- 判据见 G3–G5；allowlist 删对应行且不留死条目。

### 阶段 C：删 `AddMoney` 包装（**一行不修**）
- 删 compat 里 PlayerLoaded 内的包装与相关计数；
- 不动 qb-core 的 `player.lua`（它本来就路由 ES）；
- 判据见 G6–G8。

### 阶段 D：删 `Notify` 包装并下线 compat.lua
- 删 Notify 包装与统计线程 → 删除 compat.lua → 从 core-framework 的 fxmanifest 移除该行；
- **显式不做**：不改 17 处服务端调用点、不新增 `exports['core-framework']:Notify` 第二入口；
  若日后要保留 `notify_service` 的限流收益，应在 qb-core 的 `Notify`（owner）里实现，另开 PR；
- 判据见 G10–G11。

## 5. 交付标准（DoD）

| 编号 | 断言 | 验证方式 |
|---|---|---|
| G1 | 闸门覆盖 4 种赋值形态 | `tmp_path` 注入 4 个 fixture，逐个必须命中（`function` 形态最易漏——现存两处猴补正是这种写法） |
| G2 | 登记表无死条目、无过期、每条命中 ≥1 | 扫描结果与 allowlist 双向 diff |
| G3 | Logout 之后、下一次 PlayerLoaded 之前，`GetPlayer(src) == nil` | Lua 单测（当前会返回前任表） |
| G4 | `GetPlayer(src) == QBCore.Players[src]`（同一引用） | identity 断言 |
| G5 | `GetPlayer('1')` / `GetPlayer('license:x')` 不抛错 | 单测（mock `GetPlayerName` 对字符串返回 nil） |
| G6 | `PlayerLoaded` 后 `Player.Functions.AddMoney` 引用不变 | identity 断言 |
| G7 | 一次 AddMoney = ES 调 1 次、余额 +1；ES"先写后抛错"时余额仍只 +1 | mock ES 计数 + 抛错用例 |
| G8 | `_G.Bus.EconomyService =` 全仓唯一写入点在 qb-core；core-framework 永不写 | 静态扫描 + 注册键断言（`economy` vs `EconomyService`） |
| G9 | 把 core-framework 的 ES 挂到 `_G.Bus.EconomyService` 会递归 → 必须有保护（超时/计数上限失败） | 单测 |
| G10 | `_G.Bus.notify = nil` 时 `QBCore.Functions.Notify` 仍 `TriggerClientEvent` | 单测 |
| G11 | manifest 不含 `compat.lua` 且文件已删除 | 静态断言 |
| G12 | 既有回归全绿 | `pytest tests/unit tests/architecture tests/integration` |
| G14 | 同名 `Bus.RegisterService` 再注册：断言当前语义（覆盖）被显式测试固定，或断言拒绝 | 单测：注册两次同名服务，断言 `Bus[name]` 的方法集与预期一致（本轮若不做防护，就把"覆盖"写成断言，防止未来悄悄改语义） |
| G15 | 删除 compat 后 `QBCore.Functions.Notify` 与 qb-core 原函数**同一引用**（D6 的限速/截断语义随之消失） | identity 断言 |
| G13 | 真机观察点 | ① 选人界面停 5 分钟：0 SCRIPT ERROR、无幽灵钱变动；② 换角色后余额/职业/物品为新角色；③ `restart core-framework` 后 GetPlayer/Notify 正常；④ 连续 10 次加钱（含小数 commission）无错 |

## 6. 施工纪律

1. **先删不修**：C 阶段必须纯删除。任何"顺手修好 ES 可见性/传参"的行为都会把死代码变成生产故障。
2. **验证时点**：缓存类断言必须卡在 **Logout 之后、下一次 PlayerLoaded 之前**；写成"换角色后立刻读"当前代码就能过。
3. **把 `_G` 当资源私有**：跨资源只走 `exports`；不要用 `_G.Bus` 传服务。
4. **闸门先行**：A 先合，B/C/D 的删除才能在闸门可见的 diff 里发生（allowlist 逐条减到**只剩 dev-only 登记项**，不是 0）。
5. **每阶段更新文档数字**（`research` / `plan` / `CHANGELOG` / AS-IS 四处），否则验收方会以"数字自相矛盾"打回。

## 7. 已知局限与不在范围内

- **不在范围内**：`[qb]` 上游资源的兼容事件（qb-vehiclekeys / qb-mechanicjob 旧事件桥，属 P1-3 的兼容面）；
  930+ 处调用点的批量改写；`production-freeze` 的 `QBCore.Debug/ShowError/ShowSuccess`（另开 dev-only 收敛）。
- **已知局限**：D4（重启后失效 funcref）**没有静态判据**，只能真机观察；D7 的 `exports` 重复注册行为
  未在 FiveM 源码层验证，G14 只固定"当前的覆盖语义"，不构成对未来的保护。
- **不做性能基准**：删除缓存只给出结构性结论（少一次 native），不编造数字。

## 8. 两方差异与取舍

| 议题 | 实施方初稿 | 验收方 | 采纳 |
|---|---|---|---|
| 换角色触发路径 | 写成 `playerDropped` 顺序问题 | 指出 `PlayerLoaded` 会覆盖，真实窗口是 `Logout/OnPlayerUnload` | **采纳验收方**（已更正） |
| AddMoney 风险 | 初稿只指出"两条路径 + 一个回落，调试看不出"（二次加钱是 e458 按验收意见补的） | 给出三条独立死因 + `%d` 浮点审计"先加后抛"（`economy_service.lua:66-76`） | **采纳验收方**，并据此得出"只能纯删除" |
| `_G` 跨资源 | 未识别（曾以为 `Bus = _G.Bus` 可跨资源） | 明确指出 `_G` 资源私有、`_G.Bus.EconomyService` 恒 nil | **采纳验收方** |
| 重启后 funcref | 未覆盖 | D4/D5 | **采纳验收方** |
| 阶段划分 | 4 阶段（含"AddMoney 路由下沉"） | 4 阶段（A 闸门 → B GetPlayer → C AddMoney 纯删 → D Notify+下线） | **采纳验收方**：C 改成纯删除，取消"路由下沉" |
| Notify 处理 | 初稿即主张"521 处不必全改，回退 qb-core 原实现" | 补充"改 export 不算守卫"，且会新增第二入口 | **双方一致**：回退 qb-core；验收方追加否掉 export-as-guard |
| 闸门形态 | 初稿 = `=` + `function` 两种 | 补 `['X']=`（单双引号）、排除 `[qb]/qb-core`、裸 `QBCore.X =`（production-freeze） | **合并**：`function` 形态两边都有；其余按验收方补齐（现存两处猴补正是 `function` 写法，只写 `=` 的闸门会全绿） |
