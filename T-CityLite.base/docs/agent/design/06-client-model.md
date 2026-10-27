# 06 · 客户端模型：性质、可验证性、双端 Agent 准备

> 目标：把「客户端开发」从"改了要开游戏看一眼"变成"改了能断言"。
> 本文先回答**客户端到底有哪些性质**（P01–P14），再给出每条性质**用什么手段验证**，
> 最后落到未来服务端 agent 同时掌握双端需要什么。
>
> 落地物：`T-CityLite.base/tests/agent/lua/stubs/client.lua`（无头客户端运行时）
> + `cases_client/{phone_focus,agent_effects}.lua`（23 条断言，已绿）。
> 实测命令见 §4.4。
> 行号已按 `custom-phone` 模块化（`client/core/*`）后的布局校准。
>
> 相关：[`07-harness-channel.md`](07-harness-channel.md)（把 §3 之外的部分变成 console 断言）、
> [`docs/qbcore-client-code-analysis.md`](../../../docs/qbcore-client-code-analysis.md)（上游 QBCore 客户端代码面盘点）。

---

## 0. 结论先行

| # | 结论 |
|:--|:---|
| 1 | 客户端与服务器的差别不在"语言"，在**执行上下文**：服务端一个 Lua 状态；客户端每个玩家一个进程、有帧循环、世界是本地副本、原生随构建而变。 |
| 2 | 我们踩过的客户端 bug 全部落在 14 条性质里的 5 条：**焦点状态机(P04)、线程/帧预算(P02/P11)、原生可用性(P09)、服务端事件入参(P06)、跨资源 exports(P10)**。 |
| 3 | 14 条里 **11 条可以无头断言**，**3 类必须实机**（CEF 真输入、原生渲染/流式加载、GPU/编码）。"必须开客户端"远比想象的小。 |
| 4 | 本仓库原有的客户端覆盖是**断的**：`tests/client/quest_client_test.lua` 的 `assert` 只打印、恒定通过（§6.1）；`CLIENT_HARNESS.md` 需要真人 + Windows 客户端；NUI 无头只测 DOM。 |
| 5 | 补上无头桩后：`lua5.4 .../runner_client.lua` → **2 suites / 23 checks / 0 failed**；3 个变异（keepInput、Wait(0)→Wait(100)、去掉来电自动开）**全部被对应断言抓住**。 |
| 6 | 双端 agent 的边界已经由 `custom-agent-client` 定死：**服务端决定策略，客户端只执行字面表 + 回 ack**；客户端永远不是命令总线。缺的是"客户端状态可读"和"动作面太窄"。 |

---

## 1. 客户端与服务器：六个维度的差别

| 维度 | 服务端 | 客户端 | 后果 |
|:---|:---|:---|:---|
| 执行上下文 | 1 个 Lua 状态，全服 | 每个玩家 1 个进程 | 任何"全局状态"在不同玩家身上不一样 |
| 时间 | 无帧；`Wait` 不可用 | 帧循环 + 协程；`Wait(0)`=下一帧 | 同一段代码的耗时语义完全不同 |
| 世界真相 | DB | 本地实体副本，流式加载 | 句柄随时可能失效/为 0 |
| 输入 | 无 | 焦点、光标、控制禁用 | 我们能"锁死"玩家，也能"卡住"玩家 |
| 原生 | 服务端 native 子集 | 全量 native，但**随构建增删** | 裸调用可能 nil |
| 失败症状 | 报错 + 回滚 | 半聚焦、WASD 冻结、看不到但点得到 | 屏幕才能看出来 → 必须转成断言 |

规模（当前仓库 `T-CityLite.base/resources`）：

| 范围 | 文件 | 行数 | 现有测试 |
|:---|---:|---:|:---|
| `[custom]/*/client/*.lua` | 30 | 8 126 | 新增 2 suites（本文） |
| `[qb]/*/client/*.lua` | 131 | 44 352 | 无 |
| 其中 `qb-core/client` | 6 | 1 874 | 无 |
| 合计 | **161** | **52 478** | 覆盖 ≈ 2 %（按行） |

---

## 2. 十四条性质（P01–P14）

每条固定四段：**定义 / 代码证据 / 违反后的症状 / 验证层级**。

### P01 · 生命周期是 manifest 决定的一次性顺序

- 定义：`client_scripts` 里的文件按声明顺序加载完，才会触发 `onClientResourceStart`；`onResourceStop` 是最后一次清理机会。**多文件不等于都会执行**。
- 证据：`T-CityLite.base/resources/[custom]/custom-phone/fxmanifest.lua` 现在按序挂 4 个客户端脚本（`core/bridge` → `core/focus` → `core/events` → `main`，多文件不等于都会执行，仍要看 manifest）；`client/main.lua:12`（启动即 `PhoneFocus.Reset()`）、`client/core/focus.lua:155-158`（`onClientResourceStop` 兜底）、`client/main.lua:799-801`（main 自己的 stop 清理）；`AGENTS.md` §5 记录的 call_history.lua（该文件已不存在） 实机不执行、桥接被迫并入 `main.lua`。
- 症状：注册了但永不触发的 NUI callback / net event；资源重启后残留焦点。
- 验证：**无头**（`env.loaded_files`、`StartResource()`、`StopResource()`）+ **静态**（`tests/check_dependencies.py` 核对 cfg 与 manifest）。

### P02 · 线程是协程，`Wait` 是让出；空闲线程必须降频

- 定义：`CreateThread(fn)` 每次调用就是一个协程；`Wait(ms)` 让出并把唤醒时间排到 `now+ms`；`Wait(0)` 语义是"下一帧"（本文桩里建模为 +1 ms）。死在 `while true` 里不让出的线程 = 客户端卡死。
- 证据：`qb-core/client/loops.lua:22-53`（`sleep` 变量：未登录时 1 s，登录后按 `UpdateInterval`）；`custom-vehicles/client/dashboard.lua:106-115`（`Wait(dashboardOpen and 200 or 1000)`）；`custom-phone/client/main.lua:232`（`Wait(0)`：手机唯一每帧循环，仅在打开时存在）。
- 量级：`[custom]` 客户端共 **55** 处 `CreateThread`、**21** 处 `Wait(0)`。
- 症状：进服掉帧；关闭 UI 后仍空转；一个资源把主线程吃满。
- 验证：**无头**（resume 计数即"每虚拟秒的唤醒次数"）+ **静态**（`Wait(0)` 是否出现在无 UI 守卫的 `while true` 里）。

### P03 · 客户端只持有视图状态，真值在服务端

- 定义：客户端变量（`isPhoneOpen`、`dashboardOpen`、`currentVehicle`）是**视图状态**；权威在服务端/DB。任何"请求-授权-打开"的流程必须由服务端回调驱动，且重复执行要幂等。
- 证据：`custom-phone/client/main.lua:6`（`isPhoneOpen`）、`:66`（打开时置位）、`:260-261`（关闭/phonefix 复位）；`custom-vehicles/client/dashboard.lua:14-15,232-253`（服务端 `dashboardLockResult` 授权后才 `open`）。
- 症状：两人同时开车机；本地认为开着、服务端已回收锁。
- 验证：**无头**（连开两次只应产生一条 `phone:open`）。

### P04 · NUI 焦点是一个三元组状态机（最贵的一条）

- 定义：客户端 UI 可见性由 `(focused, cursor, keepInput)` 决定，只有四种合法组合：

| focused | cursor | keepInput | 含义 | 合法 |
|:---|:---|:---|:---|:---|
| false | false | 任意 | 游戏态 | ✅ |
| true | true | **true** | UI 可点 + 角色可走（手机/车机） | ✅ |
| true | true | false | UI 可点 + 角色定住（全屏菜单） | ✅ |
| true | **false** | 任意 | **半聚焦**：页面可见但没光标 | ❌ 症状源 |

- 证据：`custom-ui/client/main.lua:44-79`（`OpenMenu` 先 reset 再授权，失败后 1 帧 / 100 ms 各重试一次；`CloseMenu` 只释放焦点、不动 keepInput）；`custom-phone/client/core/focus.lua:41-66`（`setFocus`/`applyTop` 是唯一的 `SetNuiFocus`/`SetNuiFocusKeepInput` 调用点）、`:79-94`（`Acquire`）、`:101-117`（`Release`）、`:122-129`（`Reset`）、`client/main.lua:12`。
- 症状（三个都真踩过）：页面可见但鼠标在转视角（半聚焦）；关闭后 WASD 冻结（`keepInput=false` 残留）；点关闭时打一拳/开枪（控制未 guard）。
- 规则（写进 harness 断言）：
  1. 开 = `SetNuiFocus(true,true)` + `SetNuiFocusKeepInput(true)`；
  2. 关 = `SetNuiFocus(false,false)`，**不要**顺手把 keepInput 置 false（只在 `onResourceStop` 归零）；
  3. `DisableControlAction` 只禁 1–6（视角）、24/25/37/44（攻击/瞄准/换武器/掩体），**永不禁 30–35（移动）**。
- 验证：**无头**（三元组 + 控制禁用集合 + watchdog 次数上限）；**必须实机**：真实光标与合成输入（`CLIENT_HARNESS.md` §1 已记录合成键鼠送不到 CEF）。

### P05 · NUI 消息是有顺序的契约，DOM 就绪有延迟

- 定义：`SendNUIMessage` 的 `action`/`type` 是字符串枚举；"先 open 再推数据"，因为前端要在 open 时才建 DOM。
- 证据：`dashboard.lua:245-249`（发 `open` → `Citizen.Wait(50)` → `sendSlowData()`，注释写明避免数据先到）；`custom-phone/client/main.lua:168`（打开路径先推 `phone:updateTime`）与 `:225`（循环内只在整分钟变化时再推）。
- 症状：首帧空白/仪表盘读数为 0；前端收到未知 action 静默丢弃，表现为"没反应"。
- 验证：**无头**（消息序列断言：open 必须早于第一条数据）；**NUI 无头**（playwright 渲染，`tests/nui/run_ui_tests.py`）。

### P06 · 服务端→客户端事件必须把入参当不可信

- 定义：`RegisterNetEvent` 注册的事件名对全服可见，任何客户端都能 `TriggerServerEvent` 后由服务端转发，也能直接构造畸形 payload。handler 第一件事是形状校验 + 早退。
- 证据：`custom-phone/client/main.lua:543`（`if not notif then return end`）、`:824`（`type(data) ~= 'table' or type(data.text) ~= 'string'`）、`custom-agent-client/client/main.lua:103-112`（`v`/`session`/`request_id` 三重校验）。
- 量级：`[custom]` 客户端 **97** 处 `RegisterNetEvent`。
- 症状：一条畸形事件把客户端线程打死（在实机上就是"某个功能突然没了"）。
- 验证：**无头**（用错类型 payload 触发，断言无副作用、无线程错误）。

### P07 · 客户端→服务端两条路径：有回答 / 没回答

- 定义：`QBCore.Functions.TriggerCallback(name, cb, ...)` 有回调但**可能永不返回**；`TriggerServerEvent` 没有回答。凡是"必须成功才能继续"的流程，NUI 侧要有超时或占位，服务端侧要复验参数。
- 证据：`custom-phone/client/main.lua:312`（`TriggerCallback('phone:server:getPhoneData')`，同帧多次调用被合流）、`:817-820`（`getMessages` 分页）；全 `[custom]` 客户端 33 处 `TriggerCallback`。
- 症状：手机某个页面永远转圈（服务端没注册该 callback，客户端的 cb 永不执行）。
- 验证：**无头**（未注册 callback → `missing_callbacks` 记录 + `result.called == false`，把"挂住"变成可断言事实）。

### P08 · 本地句柄 ≠ 服务端实体；流式加载让"存在"变成概率

- 定义：客户端拿到的 entity handle 只在本地有效，且会因为距离/流式加载变成 0 或失效；跨端传递必须用 netId，并在使用前重新校验"这个实体还是不是我要的那个"。
- 证据：`dashboard.lua:259-264`（`NetworkGetEntityFromNetworkId` 后还要比对 `GetVehiclePedIsIn`）、`:428-443`（`GetGamePool('CVehicle')` 雷达，逐车算距离/夹角）；`AGENTS.md` §6（远程 ped 的 `DoesEntityExist` 不可靠）。
- 症状：车机读的是上一辆车的油量；雷达把远处的车算进来。
- 验证：**无头**（注入句柄 900 / 0 两条分支）+ **静态**；**必须实机**：真实流式加载时序。

### P09 · 原生可用性随构建变化：nil-guard 与 pcall 是契约

- 定义：FiveM 的 native 集合随 build 增删（`DisableDisplayControlActions` 就曾在某构建上不存在），exports 也可能因对方未启动而抛错。所以"能调"必须显式判断，降级路径要被测试到。
- 证据：`custom-phone/client/main.lua:181`（`if DisableDisplayControlActions then`，注释写明真机上抛过 "attempt to call a nil value" 并杀死手机循环）、`dashboard.lua:128`（`(GetVehicleBatteryHealth and GetVehicleBatteryHealth(veh)) or 100`）、`dashboard.lua:142-147`（三个 `pcall` exports）、`custom-phone/client/main.lua:150`（`pcall exports['qb-weathersync']:getWeatherState()` + 哈希表降级）。
- 症状：一次调用 nil → 整个线程死 → 功能"莫名其妙不能用"。
- 验证：**无头**（桩不提供某 native ⇒ 客户端应走降级分支，且 `thread_errors` 为空）+ **静态**（裸调用清单）。

### P10 · 跨资源 exports 是运行期契约

- 定义：`exports['x']:Fn()` 在对方未 `started` 时直接抛错；调用方必须 `pcall` 并定义降级。
- 证据：`custom-phone/client/main.lua:29`（`pcall custom-ui.CloseMenu`）、`:686-687`（`pcall custom-career.GetLocalIdentity`）、`dashboard.lua:44-45,61-62`（同款）。
- 症状：单独重启一个资源后 UI 打不开/关不掉。
- 验证：**无头**（`export_overrides` 提供 / 不提供两条路径都跑）。

### P11 · 每帧预算：采集频率 ≠ 推送频率

- 定义：客户端每帧能做的事很少；采集要按"变化"触发，推送要按"UI 是否需要"分频。事件驱动 + 低频兜底是标准解。
- 证据：`dashboard.lua:18-19`（`DIAG_INTERVAL=200`、`SLOW_INTERVAL=5000`）、`:106-115`（只在开着时按 200 ms 推）、`:218-225`（5 s 兜底）、`:278-282`（`gameEventTriggered` 即时补一次）；`custom-phone/client/main.lua:210-231`（`timeTick` 每 60 帧才检查一次时间，且 `hour/minute` 真正变化才推，注释写明避免每秒重渲染）。
- 症状：UI 开着就掉帧；状态栏闪烁。
- 验证：**无头**（单位虚拟时间内的 native 调用与 resume 数上限——**这个上限同时是"输入延迟"上限**：循环改成 100 ms，右键关闭的响应就从 1 帧变成 100 ms，变异测试 B 抓到的正是这个连锁）。

### P12 · 客户端不可信，NUI 隐藏 ≠ 权限

- 定义：客户端代码对玩家完全透明，改一行就能让"隐藏按钮"出现。所有授权、限额、复验在服务端；客户端只做**字面分发表**和**形状检查**。
- 证据：`custom-agent-client/client/main.lua:1-5`（"客户端不决定策略，也没有『请执行』入口"）、`:114-121`（未知动作 → `rejected/action_not_allowed`，**绝不转发**）；`custom-agent-client/server/main.lua:288-320`（ack 只做 telemetry、按 `settled` 去重、剥离控制字符并截断）。
- 验证：**无头**（握手前 / 外来 session / 未知动作 / 畸形信封四种非法输入全部断言"零副作用"）。

### P13 · 客户端必须上报状态，而不是让人看屏幕

- 定义：凡是"看不见的状态"（焦点、keepInput、打开的是哪个 UI、执行到哪一步），都要有一条到服务端的遥测；否则 agent 与 CI 都只能靠人眼。
- 证据：`T-CityLite.base/resources/[custom]/custom-phone/client/main.lua` 中 13 处 `phone:server:focusState`（close-start / close / reassert / loop-exit / probe-start / probe / probe-end）+ `server/main.lua:1348` 接收；`custom-agent-client` 的 `tcity:agent:ack`；`CLIENT_HARNESS.md` §5 的 `[client-telemetry]` 日志前缀。
- 症状：只能截图取证；回归无法自动判定。
- 验证：**静态**（遥测覆盖率：每个 UI 资源是否都有 open/close 遥测）+ **实机**（日志）。

### P14 · 幂等与重复投递：去重必须在服务端

- 定义：服务端可能重发（超时重试、玩家重连），客户端没有持久状态、做不了真正的去重；因此"最多一次"由服务端 `settled` 保证，客户端只需保证**重复执行不叠加副作用**。
- 证据：`custom-agent-client/server/main.lua:295-320`（`entry.settled` → `dropAck()`）、`:255-260`（服务端自己的 `SetTimeout` 到点即 `timeout`）；客户端 `:142-153` 的 `cancel` 只清 `active[rid]` 与动画，**不中断正在执行的 handler** → 之后还会补一个 `failed` ack。
- 验证：**无头**（本文 case 明确断言"cancel 之后同一个 rid 会有两个 ack，服务端必须靠 settled 兜住"）。

---

## 3. 可验证性矩阵

| 性质 | 纯静态（lint/AST/grep） | 无头 Lua 桩 | NUI 无头（playwright） | 必须实机 |
|:---|:---:|:---:|:---:|:---:|
| P01 生命周期/顺序 | ✅ manifest 与文件对账 | ✅ | – | – |
| P02 线程/帧预算 | ✅ `Wait(0)` 扫描 | ✅ resume 计数 | – | 帧率实测 |
| P03 视图状态/幂等 | ⚠️ 人工 | ✅ | – | – |
| P04 NUI 焦点 | ✅ 调用点扫描 | ✅ 三元组断言 | – | ✅ **真光标/真输入** |
| P05 NUI 消息契约 | ✅ action 枚举对账 | ✅ 序列断言 | ✅ 渲染 | – |
| P06 事件入参防御 | ⚠️ | ✅ 畸形 payload | – | – |
| P07 callback 通路 | ✅ 名字对账（client↔server） | ✅ 缺失即观测 | – | – |
| P08 实体/netId | ⚠️ | ✅ 句柄 0/有效两路 | – | ✅ **流式加载时序** |
| P09 原生可用性 | ✅ 裸调用清单 | ✅ 缺失→降级 | – | – |
| P10 跨资源 exports | ✅ 依赖声明 | ✅ 有/无两条路 | – | – |
| P11 推送分频 | ✅ | ✅ native/时间单位 | ✅ 重渲染次数 | – |
| P12 客户端不可信 | ✅ 授权点扫描 | ✅ 非法输入矩阵 | – | – |
| P13 遥测覆盖 | ✅ | ⚠️ 只到桩边界 | – | ✅ 真实日志 |
| P14 幂等/去重 | ⚠️ | ✅ 双 ack 场景 | – | 重连/重试压测 |

**只剩三类必须实机**（这也是 `CLIENT_HARNESS.md` 的适用面）：

1. **CEF 真输入**：合成键鼠送不进 NUI 页面（已有记录），只有真人或 `nuitest` 钩子能走通"UI→fetch→Lua"全链；
2. **原生渲染 / 物理 / 流式加载**：`DrawMarker`、handling 修改、实体同步、`IsVehicleAConvertible` 之类只有游戏内才成立；
3. **GPU / 编码 / 字体**：黑屏、闪烁、CJK 字形回退、TTS 语音包缺失。

---

## 4. 无头客户端桩（已落地）

### 4.1 建模了什么

| 机制 | 桩里的实现 | 可断言的东西 |
|:---|:---|:---|
| 虚拟时钟 + 协程调度 | `Wait(0)`=+1 ms/帧，按唤醒时间推进；**resume 预算**（默认 20 万/次 `Step`） | 每帧循环、空闲降频、忙循环（超预算直接报错并指出线程名） |
| NUI 焦点 | `(focused, cursor, keepInput)` + 全部调用流水 | 半聚焦、keepInput 残留、watchdog 次数上限 |
| NUI 通道 | `nui_messages[]`（带时间戳）、`nui_callbacks{}`、`env.NuiCallback()` 记录应答 | 消息顺序、单次开屏、callback 是否应答 |
| 事件 | `net_handlers` / `event_handlers` / `local_events`、`env.Emit()` | 非法 payload、握手/会话、local vs net |
| 命令 / 键位 | `env.Command('phone')`、`key_mappings` | 配置驱动（`Config.OpenKey`） |
| 原生 | 我们代码真用到的那一批；**没建模的保持 nil** | 缺 native → 线程报错进 `thread_errors` = **一个发现，不是静默通过** |
| exports / QBCore / LocalPlayer | 代理 + `export_overrides` + `server_callbacks`；state bag 支持读写 | 跨资源降级、callback 缺失、GPS 状态镜像 |

### 4.2 用例覆盖

| Suite | checks | 覆盖性质 |
|:---|---:|:---|
| `T-CityLite.base/tests/agent/lua/cases_client/phone_focus.lua` | 12 | P01 P02 P03 P04 P05 P06 P07 P10 P13 |
| `T-CityLite.base/tests/agent/lua/cases_client/agent_effects.lua` | 11 | P06 P09 P12 P14 + 握手/ack 契约 |
| 合计 | **23** | 0 failed |

### 4.3 变异测试（证明断言有牙，而不是恒绿）

| 变异 | 期望被抓的断言 | 结果 |
|:---|:---|:---|
| 开屏 `SetNuiFocusKeepInput(true)` → `false` | `keepInput must stay on so WASD works` | ✅ 被抓（真实 WASD bug 复现） |
| 手机每帧循环 `Wait(0)` → `Wait(100)` | `the open loop must poll per frame` + 右键关闭 50 ms 内不生效 | ✅ 被抓（并证明**循环周期就是输入延迟上限**） |
| 删除"来电时若未打开则 `OpenPhone()`" | `incoming call must open the phone (audit B04)` | ✅ 被抓 |

### 4.4 怎么跑

```bash
# 全部客户端 suite（无服、无库、无玩家）
lua5.4 T-CityLite.base/tests/agent/lua/runner_client.lua

# 单个 suite（JSON 到 stdout，人类诊断到 stderr）
lua5.4 T-CityLite.base/tests/agent/lua/runner_client.lua --case phone_focus

# CI 入口（无 lua5.4 时自动 skip）
cd T-CityLite.base && python3 -m pytest -q tests/agent/test_client_harness.py
```

退出码与服务器 golden 一致：`0` 全绿 / `1` 断言失败 / `2` 桩自身错误。

---

## 5. 双端 Agent：现在有什么、缺什么

### 5.1 已有分层

```text
read    /agent/v1/live/*           只读感知（玩家/世界/事件）
decide  custom-director + policy   18 动作、L1-L4、人审
exec    custom-agent-client        6 个客户端效果 + ack + 审计(agent_effects)
verify  ack 回读 + DB 回读          settled 去重、超时、拒绝留痕
```

客户端一侧的契约（`T-CityLite.base/resources/[custom]/custom-agent-client/client/main.lua`）值得原样保留：

| 约束 | 含义 |
|:---|:---|
| 只有服务端能发起 | 客户端没有"请执行"的入口 |
| `Handlers` 是字面表 | 未知动作 → `rejected`，永不转发成事件 |
| session 校验 | 每次资源重启换 token，旧 token 的 exec 直接丢弃 |
| 一律 ack | ok / rejected / failed / cancelled 四态 + `error_code` |

### 5.2 缺口（按优先级）

| # | 缺口 | 影响 | 建议 |
|:--|:---|:---|:---|
| 1 | **客户端状态不可读**：除 `focusState` 与 ack 外没有通用 `client_state` 遥测 | agent 无法回答"手机开着吗/在哪个 app/车机锁给谁了" | 加 `tcity:agent:probe`（只读，返回 UI 状态快照，不含正文），由 director 暴露成 read 工具 |
| 2 | **动作面太窄**：只有 6 个 handler，且 `open_text_ui` 是原生 help text | 无法驱动手机/车机/任务 UI | 先扩 `ui_open(app)` / `ui_close`，走 NUI 消息而非焦点劫持 |
| 3 | **没有 NUI 断言通道**：`nuitest` 只服务 quest | UI→Lua 链路无法回归 | 把 `nuitest` 泛化成 `client.nui_test{selector}`，返回命中/未命中 |
| 4 | **桩只覆盖 2 个资源**（899 / 8 126 行 custom client） | 车机、任务、载具的客户端逻辑仍靠实机 | 下两个目标：`dashboard.lua`（分频+锁+netId）、`quest_checkpoint.lua`（轮询+区域） |
| 5 | **`qb-core/client` 1 874 行零测试** | 通知、drawtext、事件桥接无回归 | 先接 `native_notify` + `events`（纯逻辑，容易断言） |

### 5.3 建议的客户端动作集（下一版）

| 动作 | 风险 | 执行位置 | 说明 |
|:---|:---|:---|:---|
| `client.ui_probe` | L1 | 客户端只读 | 返回 UI 状态（哪个 UI、焦点三元组、app 名），供 agent 决策 |
| `client.notify` | L1 | 客户端 | 已有（`send_notify`） |
| `client.ui_open(app)` | L2 | 客户端 | 打开指定 app，等价于玩家按键；失败要 ack 原因 |
| `client.ui_close` | L2 | 客户端 | 释放焦点 + guard |
| `client.play_anim` / `clear_anim` | L2 | 客户端 | 已有 |
| `client.teleport` | L3/L4 | 客户端 | 已有，保持人审 |
| `client.nui_test(selector)` | L1 | 客户端 | 仅测试 convar 下开放 |

---

## 6. 缺口与既有资产盘点

### 6.1 资产现状

| 资产 | 状态 | 结论 |
|:---|:---|:---|
| `tests/agent/lua/`（服务器 golden，9 suites / 236 checks） | ✅ 绿 | 服务端逻辑的基线 |
| `tests/agent/lua/{stubs/client,client_bootstrap,runner_client,cases_client/*}`（新增） | ✅ 绿 | 客户端逻辑的基线 |
| `tests/nui/run_ui_tests.py`（playwright） | ✅ | 只测 DOM 渲染，不测 Lua |
| `docs/agent/CLIENT_HARNESS.md`（MCP + Windows 客户端） | ⚠️ 需真人 | 只保留"必须实机"的部分（§3） |
| `tests/client/quest_client_test.lua` | ❌ **伪测试** | 见 §6.2 |
| `qb-core/client/*.lua`（1 874 行） | ❌ 无测试 | 见 §5.2 #5 |

### 6.2 必须点名的三个问题

1. **`tests/client/quest_client_test.lua` 永远不会失败。** 它的 `assert(cond, label)` 只做 `print`，用例里大量 `assert(true, ...)`，还有 `assert(#cleanupPoints == 4, ...)` 这种对常量自证的断言；文件头写"在 F8 运行"，实际产出的 `passed` 数字没有任何验证力。要么改成 `error()`，要么删除并把有价值的数据流断言迁进 `cases_client/`。
2. **`cancel` 与正在执行的 handler 有竞态。** `custom-agent-client/client/main.lua:142-153` 只清 `active[rid]` 并 `ClearPedTasks`，**不中断** handler；handler 到点后仍会补一个 `failed` ack。服务端 `settled` 兜住了（`:295-296`），但这是"靠对面容错"，客户端本可以持一个取消令牌。
3. **`custom-main/client/main.lua:121-136` 在未登录时以 100 ms 轮询**（每轮 4 个 native），而 `T-CityLite.base/resources/[qb]/qb-core/client/loops.lua` 的同类空闲轮询是 1 000 ms。进服/选角阶段是本机 CPU 最紧的时候，这条应降到 500–1 000 ms 或改为事件驱动。

---

## 7. 下一步

| 优先级 | 事项 | 判定标准 |
|:---|---:|:---|
| P1 | 把 `dashboard.lua` 接进桩 | 锁授权、200 ms/5 s 分频、netId 失效三条断言绿 |
| P1 | 修 §6.2 的 1、3 | 伪测试不再是假绿；未登录轮询 ≥500 ms |
| P2 | `quest_checkpoint.lua` 接桩 | 距离/高度容差、`Clear()` 后不残留 checkpoint |
| P2 | 静态扫描器：`Wait(0)` 无守卫、裸 native 调用、`RegisterNetEvent` 无 `type()` 校验 | 输出清单进 CI（advisory 起步） |
| P3 | `client.ui_probe` 遥测 + 动作 | director 多一个 read 工具，smoke 能断言"手机是开着的" |
| P3 | 把"必须实机"清单固化进 `CLIENT_HARNESS.md` | 每次实机回归只跑 §3 的三类 |
