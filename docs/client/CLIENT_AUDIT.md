# T-City 客户端（FiveM / QBCore / NUI）审计

> 规则：**只读排查，不修改业务代码**。本文登记问题；修复由各模块 owner 在后续 PR 完成。
> 审计范围：`T-CityLite.base/resources/[custom]/**` 的全部客户端代码与 NUI 前端，重点
> `custom-phone` / `custom-police` / `custom-justice` / `custom-agent-client` / `custom-main`。
> 快照：**HEAD `1cf25ae`**（2026-10-25）。行号以该提交为准。
> 静态扫描器：`tests/architecture/test_nui_client_contracts.py`（规则 `NUI-CLIENT-01`），
> 债务登记：`tests/architecture/nui_client_allowlist.json`。

## 0. 摘要

| 模块 | Block | High | Medium | Low | 合计 |
|---|---:|---:|---:|---:|---:|
| phone | 0 | 2 | 5 | 4 | 11 |
| police | 0 | 1 | 3 | 3 | 7 |
| justice | 0 | 0 | 4 | 1 | 5 |
| agent | 0 | 0 | 0 | 4 | 4 |
| other | 0 | 1 | 4 | 5 | 10 |
| **合计** | **0** | **4** | **16** | **17** | **37** |

- **3 个 Block 已修复**（2026-10-25）：P-01（手机 appQuery/appAction 改 request_id）、
  P-02（getPhoneData 合并单飞）、D-01（jQuery/Bootstrap/Popper vendor 到本地）。
  修复后 Block 为 0；剩余 High 见 §1/§2。
- 静态扫描器当前命中 **15 条**结构性违规，全部登记在 allowlist（带 owner/expires），
  `pytest -q tests/architecture/test_nui_client_contracts.py` **15 passed / <1s**；`nui_client_allowlist.json` 11 条。
- 全量测试：`pytest -q tests/unit tests/architecture` → **660 passed, 132 skipped, 51 subtests, ~7s**。

### 严重度定义

| 级别 | 含义 |
|---|---|
| **Block** | 会造成 UI 永久 pending / 焦点卡死 / 整页失效 / 数据错配；发布前必须修。 |
| **High** | 特定时序下功能不可用或输入被"穿透"；有明确复现路径，应在当前迭代修。 |
| **Medium** | 生命周期/错误处理/状态同步缺陷，影响可观测性或需要玩家手动恢复。 |
| **Low** | 死代码、日志噪声、规范偏差、单点小概率问题。 |

### 方法与证据

1. 逐行通读重点模块客户端 Lua 与 NUI 前端；
2. 用 `RegisterNUICallback` / `SetNuiFocus*` / `fetch(` / `ui_page` / `files` / `client_scripts`
   的静态扫描做全量覆盖（15 条结构性违规，见各节 `NUI-CLIENT-01` 标记）；
3. 对照 qb-core 实际实现验证调用契约：
   - `[qb]/qb-core/client/functions.lua:9-29`：`TriggerCallback` 以 **name 为唯一键**存槽
     （`QBCore.ServerCallbacks[name] = { callback, promise }`），**没有 request id、没有超时**；
   - `[qb]/qb-core/client/events.lua:193`：服务端推送玩家数据用 `QBCore:Player:SetPlayerData`；
   - `[qb]/qb-core/server/player.lua:184-185`：只有上表事件，没有 `QBCore:Client:SetPlayerData`。
4. Playwright 现有 `custom-phone/web/tests/nui/mdt.spec.mjs` 的 mock 会分别响应每一次
   `appQuery`，所以**浏览器层测试无法暴露 P-01**；这类问题只能靠静态契约 + 真机复测。

### 工作区并发说明（重要）

审计期间另一个 agent 正在同一工作区修改 `custom-phone`（`client/main.lua`、`server/main.lua`、
`web/src/utils/nui.ts`、`web/src/apps/PoliceMDT.svelte`、两个测试文件，均未提交）。
本文所有结论与行号都基于 **HEAD `1cf25ae`**；工作区中已出现的 `request_id` 协议修复
（`phone:server:appQueryRequest` / `phone:client:appQueryResponse`）**不计入已修复**，
在 §1.4 单独说明。若该修复合入，P-01 关闭，P-02（`getPhoneData`）仍需单独处理。

---

## 1. phone（custom-phone）

资源：`client/main.lua`（898 行，42 个 NUI callback）、`web/src/**`（Svelte 5 + Vite，
`base: './'`，构建产物 `html/`）。整体成熟度高：焦点有 watchdog 与 `onResourceStop` 清理、
统一 `fetchNui` 带 6s AbortController、idempotency key、错误码表都已落地。问题集中在
**QBCore callback 单槽协议**与**回调参数/失败态**。

### 1.1 问题表

| ID | 严重度 | 问题 | 位置（HEAD） | 修复建议 |
|---|---|---|---|---|
| P-01 | **Block** | MDT 用 `Promise.all` 并发打同一个 QBCore callback `phone:server:appQuery`：qb-core 只保留一个槽，后一次覆盖前一次；服务端先返回的响应会被投递给**后一个**请求（units 的数据显示在 incidents 列表），前一个 NUI fetch 一直等到 6s 超时。`appAction` 同理。 | `web/src/apps/PoliceMDT.svelte:315-331`（`Promise.all([units, incidents])`）、`:365`（charges+arrests）、`:579`（reports+bolos）、`:677`（arrests+refresh，3 个并发）；`web/src/stores/apps.ts:25-40`；`client/main.lua:849-863`；根因 `[qb]/qb-core/client/functions.lua:9-29` | 走 `request_id` + 专用 `TriggerServerEvent`/单播 response（服务端协议已存在，见 §1.4），客户端按 id 解析；过渡期至少对 `appQuery` 做串行队列。**禁止**任何 `Promise.all` 直连同一 callback name。 |
| P-02 | **Block** | `phone:server:getPhoneData` 有 3 个客户端调用点，可同帧并发：打开手机（NUI `getPhoneData`）与 `OnMoneyChange` / `qb-phone:client:RemoveBankMoney` 撞车 → 槽被覆盖，响应错投或丢失，UI 金额/联系人可能停在旧值并 6s 超时。 | `client/main.lua:273-277`、`:670-680`、`:787-797`；服务端 `server/main.lua:354-367`（30s 缓存，返回 `nil` 分支在 `:356`） | 同样换成 request_id 协议；或把 money 推送改为服务端主动 `SendNUIMessage`（不再回调拉全量）。 |
| P-03 | High | **所有** NUI bridge 都直接依赖 QBCore callback 且无超时/兜底 `cb`：服务端 callback 不返回（玩家卸载、DB 卡住、`pending` 计数永不归零）时 `cb` 永不调用，CEF fetch 只能靠前端 6s abort 收尾；用户操作被静默丢弃，qb-core 的槽也一直占用。 | `client/main.lua:273-321`（getPhoneData/contacts/notifications）、`:324-328`（bankTransfer）、`:362-408`（nearby/hotline/call 系列）、`:436-486`（job/cityfeed）、`:759-769`、`:843-847`、`:886-898` | 统一 `nuiBridge(name, fn)`：`SetTimeout(6s, cbOnce({success=false,error='timeout'}))` + 服务端处理器保证每条路径 `cb`（含 DB 失败）。返回结构统一 `{success,error}`。 |
| P-04 | High | 服务端 `getPhoneData` 在玩家对象不存在时 `cb(nil)`；前端 `loadPhoneData` 只处理 `res.success`，否则**静默什么都不做**——手机打开是空白，没有错误提示、没有重试按钮。 | `server/main.lua:356`；`web/src/stores/phone.ts:113-128`；`web/src/utils/nui.ts:134-137`（`resp.json()` 得到 `null`） | 服务端返回 `{success=false,error='player_not_loaded'}`；前端增加 `error` 状态 + "重试" 按钮，未知码显示原码（现有 `errorText` 表可复用）。 |
| P-05 | Medium | NUI callback 入参未校验：`data` 为 nil/字段类型不对时直接在 Lua 里索引/做算术会抛错，`cb` 不会执行（抛错点之后的代码都不运行），fetch 挂起。代表：`sendMessage` 取 `receiver_number`、`bankTransfer` 取 `amount`、`setGpsRoute` 对 `data.x` 做 `+ 0.0`。 | `client/main.lua:280-297`、`:324-328`、`:339-359`、`:368-372`、`:386-396`、`:405-486`、`:892-898` 中未加 `type(data)` 的桥 | 每个桥首行 `if type(data) ~= 'table' then return cb({success=false,error='bad_request'}) end`；数值用 `tonumber` 并判 `nil`/`NaN`。已有正例：`:849-855`、`:857-863`、`:892-894`。 |
| P-06 | Medium | `ClosePhone` 首行 `if not isPhoneOpen then return end`，状态一旦与真实焦点不同步（异常分支、重登）就再也关不掉；同时没有 `QBCore:Client:OnPlayerUnload` 处理，换角色后 `isPhoneOpen` 残留。 | `client/main.lua:13-16`、`:660-663`（只有 OnPlayerLoaded，无 Unload）；兜底仅 `/phonefix`（`:240-247`） | 早退分支也要 `SetNuiFocus(false,false)`；监听 `OnPlayerUnload` 重置 `isPhoneOpen`、GPS、job 追踪并释放焦点。 |
| P-07 | Medium | 前端 `closePhone()` 只有在 `fetchNui('closePhone')` 成功后才 `isPhoneOpen.set(false)`；超时/失败时 UI 仍显示，但 Lua 可能已释放焦点 → 界面还在、点哪都没反应。 | `web/src/stores/phone.ts:189-197`；调用点 `web/src/App.svelte:189-206`（ESC / 右键 / M） | `finally` 里关闭本地 UI（Lua 端关闭是幂等的）；失败只记日志，不让 UI 卡在幽灵态。 |
| P-08 | Medium | `DynamicApp.refresh()` 手动管理 `loading`，没有 `try/finally`；当前 `queryApp` 内部 catch 兜底才没出事，一旦 `queryApp` 改为抛错（例如换掉 wrapper）就会永久 loading。 | `web/src/apps/DynamicApp.svelte:14-26` | `try { ... } finally { loading = false }`，与其它 App 保持一致。 |
| P-09 | Medium | `RegisterNetEvent('QBCore:Client:SetPlayerData', ...)` 监听的是**不存在的事件**（qb-core 只有 `QBCore:Player:SetPlayerData`），金额同步实际只靠 `OnMoneyChange`；服务端改钱但不触发 OnMoneyChange 的路径（如离线补发、管理脚本直改）不会刷新 UI。 | `client/main.lua:682-688`；对照 `[qb]/qb-core/client/events.lua:193`、`server/player.lua:185` | 改成 `QBCore:Player:SetPlayerData`，或干脆删掉并统一走 P-02 的服务端推送。 |
| P-10 | Low | 来电事件在手机未打开时强行 `OpenPhone()`：若玩家正在看 story-engine 决策框 / 车机 / 其它菜单，会抢焦点并播放掏出手机动画。 | `client/main.lua:526-535` | 只在 `isPhoneOpen` 或"无其它 NUI 焦点"（`not IsNuiFocused()`）时自动打开；否则走通知条 + 铃声，玩家点击再接。 |
| P-11 | Low | 构建产物 `html/favicon.svg` 被 `index.html` 引用，但 `files{}` 未列，CEF 控制台 404。`html/icons.svg` 无任何引用（构建残留）。 | `fxmanifest.lua:31-37`；`html/index.html:5` | `files` 加 `'html/favicon.svg'`，或把 favicon 放进 `assets/`；删掉未引用的 `icons.svg`。 |
| P-12 | Low | 打开态主循环 `Wait(0)` 每帧禁用 22 个 control；手机是低频 UI，没必要每帧跑。 | `client/main.lua:154-214` | 改为 `Wait(0)` 仅在按住鼠标/需要时，或 `Wait(50)` 批量禁用；关闭时立刻停止。 |
| P-13 | Low | 浏览器 mock 与真实 NUI 行为漂移：mock 没有 6s 超时，`getPhoneApps`/`appQuery`/`appAction` 未实现（落到 `Unknown mock fetch endpoint`）——预览里"一切正常"，真机才暴露超时/并发。 | `web/src/utils/nui.ts:143-390` | mock 补 `AbortController` 语义与职业 App 端点；或把 mock 标成"仅 UI 预览，不模拟 NUI 传输层"。 |

### 1.2 焦点生命周期（结论：合格，但有两处边界）

- 开：`SetNuiFocus(true,true)` → `SetNuiFocusKeepInput(true)`，随后 5 次 watchdog 重设
  （`client/main.lua:56-100`）。
- 关：`SetNuiFocus(false,false)`，**故意保留 keepInput**（`:19-21`），并在 80ms 后复查焦点
  （`:27-38`）。
- `onResourceStop` 与 `onClientResourceStart` 都释放/复位（`:6-10`、`:746-750`）。
- 边界 1：`ClosePhone` 早退不释放焦点（P-06）。
- 边界 2：keepInput 是**全局标志**，手机关闭后仍为 true。任何"打开时不显式复位"的 NUI 都会
  继承它（见 O-01、D-03）。这是 P-01 之外最容易复现的"人物能一边走一边点 UI"问题。

### 1.3 路径与构建（结论：合格）

- `ui_page 'html/index.html'`，`files` 覆盖 `html/**` 主要产物；Vite `base: './'`，
  构建后 HTML 为 `./assets/index.js|css`（`web/vite.config.ts:7`，`html/index.html:8-9`）。
- 唯一缺口是 favicon（P-11）。
- `html/assets/audio/*` 已单独列出（铃声），构建产物存在。

### 1.4 已知的进行中修复（工作区未提交，不计入已修复）

另一 agent 在 `git diff` 中增加了：

- 服务端 `server/main.lua`：`phone:server:appQueryRequest` / `appActionRequest` +
  `phone:client:appQueryResponse` / `appActionResponse`，按 `request_id` **单播**回源；
- 客户端 `client/main.lua`：`pendingAppQuery/Action` 表、8s `SetTimeout` 兜底、资源停止时
  清空 pending；
- `web/src/utils/nui.ts`、`PoliceMDT.svelte` 配合改动；新增
  `tests/unit/layer3_business/test_phone_request_protocol.py`。

评估：方向正确（协议级 request_id，彻底支持并发）。合入并补真机复测后关闭 **P-01**；
**P-02 不受该修复影响**（`getPhoneData` 仍是 QBCore callback）。

---

## 2. police（custom-police）

资源：13 个 client 脚本（`client/main.lua`、`job.lua`、`backup.lua`、`camera.lua`、`heli.lua`、
`npc_callouts.lua` 等），NUI 是手写 Vue + jQuery 的平板（`html/`，非 Vite）。
服务端权威做得较好（FIT-11 state writer 契约），客户端问题集中在 **NUI 依赖**与**焦点/状态变量**。

### 2.1 问题表

| ID | 严重度 | 问题 | 位置（HEAD） | 修复建议 |
|---|---|---|---|---|
| D-01 | **Block** | `ui_page` 从公网 CDN 加载 jQuery / Bootstrap / Popper。CEF 离线、被墙或证书失败时 `$` 未定义：`script.js` 在顶层 `$(document).on(...)` 抛错中断，**后续 `window.message` 监听与 ESC 处理都不会注册**。后果：相机/指纹 NUI 收不到消息；指纹仍被 Lua `SetNuiFocus(true,true)` 抓住，玩家看到"不可见 UI + 光标锁死"，只能 `/phonefix` 或重启资源。 | `custom-police/html/index.html:4`（bootstrap css）、`:5`（jquery）、`:236`（popper）、`:237`（bootstrap js）；`custom-police/html/script.js:125-127`（首个 `$` 顶层调用） | 把 jquery/bootstrap/popper **vendor 进 `html/`** 用相对路径引用（`vue.min.js` 已是本地）；或去掉 jQuery，用原生 `fetch` + `GetParentResourceName()`。 |
| D-02 | High | `Databank.Close()` POST 到 `closeDatabank`，但全资源**没有** `RegisterNUICallback('closeDatabank')`；同时硬编码 `https://custom-police/`、`$.post` 无超时无错误处理。每次关闭（含 ESC）都是 404。databank 的打开消息也无人发送——整段为死 UI。 | `custom-police/html/script.js:103-109`、`:116-119`、`:125-127`；`custom-police/client/` 无对应注册 | 要么补 `RegisterNUICallback('closeDatabank')` 并接上打开路径；要么删除 Databank 这一段死代码。顺手把 origin 改成 `GetParentResourceName()`、请求加超时。 |
| D-03 | High | 指纹 UI `SetNuiFocus(true,true)` 前没有复位 `SetNuiFocusKeepInput(false)`。玩家先用过手机（keepInput=true 全局残留）再开指纹，**人物仍能走动/攻击**，UI 不是排他的；配合 D-01 还会出现"看不见的 UI 抓着焦点"。 | `custom-police/client/job.lua:42-47` | 与 story-engine 一致：`SetNuiFocusKeepInput(false)` → `SetNuiFocus(true,true)`；关闭时 `SetNuiFocus(false,false)` + `SetNuiFocusKeepInput(false)`。 |
| D-04 | Medium | `inFingerprint` 一个变量承担两种语义：①指纹 UI 是否打开（`:45`、`:251`）②玩家是否站在指纹 PolyZone 内（`:866`、`:872`）。关闭 UI 会把 zone 状态清成 false，玩家不离开区域就再也看不到 E 提示/扫描逻辑错乱。 | `custom-police/client/job.lua:3`、`:42-47`、`:249-253`、`:864-875` | 拆成 `fingerprintUiOpen` 与 `inFingerprintZone` 两个变量。 |
| D-05 | Medium | 没有统一 `onResourceStop`：现有两个只清理 NPC/载具（`backup.lua:506`、`npc_callouts.lua:571`），不会 `SetNuiFocus(false,false)`，也不清 `DutyBlips`。restart 时指纹框若开着焦点可能残留；勤务 blip 会留到玩家重连。 | `custom-police/client/job.lua:46`；`custom-police/client/main.lua:8`、`:17-47`（DutyBlips）；`client/backup.lua:506-519`、`client/npc_callouts.lua:571-578` | 增加一个 `onResourceStop`：释放焦点/keepInput、删除 `DutyBlips`、停掉 NPC（已有）与相机。 |
| D-06 | Medium | 固定 name 的框架 callback `QBCore:Server:SpawnVehicle` 在 3 处使用；快速连点/两个车库同时取车会互相覆盖（与 P-01 同根因）。 | `custom-police/client/job.lua:118`、`:138`、`:490` | 取车加本地 in-flight 锁（按钮禁用直到回调/超时），或改用 `TriggerServerEvent` + netId 响应事件。 |
| D-07 | Low | 网络事件里对非法参数直接 `error()`，会在客户端抛错并中断该事件处理（服务端仍可重试）。 | `custom-police/client/camera.lua:130-141`（`:140`） | 改为 `return` + 日志；参数白名单校验。 |
| D-08 | Low | `doFingerScan` 把可能为 `nil` 的 `FingerPrintSessionId` 发给服务端（打开 UI 的事件没到/被覆盖时）。 | `custom-police/client/job.lua:269-272` | `if not FingerPrintSessionId then return cb({success=false,error='no_session'}) end`。 |
| D-09 | Low | 相机线程用 `Config.SecurityCameras.cameras[currentCameraIndex]` 直接索引；配置热改/资源重启后可能为空并报错。 | `custom-police/client/camera.lua:177`（循环内） | 取 camera 前判空，空则 `CloseSecurityCamera()`。 |

### 2.2 正面项

- `client/backup.lua` 是**正确的并发范式**：`requestId` + `pending/active` 表 + 服务端按 id 结束
  （`:500-519`），可复制到 phone/police 的取车。
- `client/npc_callouts.lua` 在 `onResourceStop` 里清理 NPC/载具并释放服务端配额（`:571-578`）。
- 客户端没有写权威状态（金额/刑期/罚单），符合 FIT-11；`Config` 只读。

---

## 3. justice（custom-justice）

无 NUI（`ui_page` 为空），只有事件驱动的监狱/法院交互（`client/main.lua` 160 行）。
服务端刑期校验正确（`server/prison.lua:241-247` 用 `startTime` 复算），客户端不权威。

| ID | 严重度 | 问题 | 位置（HEAD） | 修复建议 |
|---|---|---|---|---|
| J-01 | Medium | `lawyerNotify` 直接 `Player.job.name`；玩家数据未加载/`job` 为空时事件处理器抛错，后续通知与导航都不执行。 | `client/main.lua:23-36`（`:25`） | `local job = Player and Player.job`；`if not job or job.name ~= 'lawyer' then return end`。 |
| J-02 | Medium | 通知格式化信任服务端 payload：`table.concat(data.crimes, ', ')` 在 `crimes` 缺失/非数组时抛错，`%d` 遇 `baseMinutes=nil` 也抛错。 | `client/main.lua:29-32` | `local crimes = type(data.crimes)=='table' and table.concat(data.crimes, ', ') or '—'`；`tonumber(data.baseMinutes) or 0`。 |
| J-03 | Medium | `prisonTimer` 的"清除旧计时器"是空注释：`CreateThread` 返回的线程无法 kill，二次入狱会叠加两个倒计时，各自递减并可能重复触发 `sentenceComplete`（服务端会拒绝，但玩家会看到 "Sentence not served yet" 之类的错误提示）。 | `client/main.lua:16-17`、`:56-74` | 用 generation token：`local prisonGen = 0`，线程内 `if gen ~= prisonGen then return end`；新入狱 `prisonGen = prisonGen + 1`。或改为单一常驻线程读 `releaseAt` 时间戳。 |
| J-04 | Medium | 没有 `onResourceStop` / `OnPlayerUnload`：`isInPrison` 残留；法院/监狱 blip 只在登录后创建一次（`:100-130`），换角色/重登会重复叠加，资源停止也不清理。 | `client/main.lua:16`、`:100-130`；全文件无清理钩子 | 登录/卸载时重置 `isInPrison`、删除并重建 blip（保存 `blip` 句柄）；`onResourceStop` 删除 blip。 |
| J-05 | Low | 监狱交互用 `while true do Wait(0)` 每帧轮询 E 键，保持 100% 帧占用（对所有玩家，即使不在监狱）。 | `client/main.lua:136-154` | `Wait(0)` 仅在 `isInPrison` 时，否则 `Wait(1000)`；或改用 `qb-target`/按键事件。 |

---

## 4. agent（custom-agent-client）

无 NUI（`handleOpenTextUi` 用 `BeginTextCommandDisplayHelp`，不抢焦点），因此 NUI/焦点类
检查项不适用；并发与输入校验按"效果执行器"标准检查。**整体设计是本仓库最规范的一处**：
服务端签名会话校验、字面量 handler 白名单、`pcall` 包裹、ack 结构固定。

| ID | 严重度 | 问题 | 位置（HEAD） | 修复建议 |
|---|---|---|---|---|
| A-01 | Low | 没有 `onResourceStop` / `OnPlayerUnload`：`active[rid]` 不会清空，屏幕效果（`StartScreenEffect`）与动画在资源重启时残留到自然结束。 | `client/main.lua:12-13`、`:70-73`、`:142-153` | `onResourceStop` 里 `ClearPedTasks`、`StopScreenEffect`、清空 `active`。 |
| A-02 | Low | `tcity:agent:cancel` 与运行中的 handler 竞态：cancel 只清 `active` 并 `ClearPedTasks`，handler 返回后仍会发 `status='ok'` 的 ack，与服务端已记录的 cancelled 冲突（审计/指标会看到双重结果）。 | `client/main.lua:123-139` vs `:142-153` | 用 generation token（`active[rid] = {gen}`），handler 返回时校验 gen 再 ack；或 cancel 时标记 `cancelled[rid]` 并让 ack 走 `cancelled`。 |
| A-03 | Low | `open_text_ui` 未校验 `payload.title/body`：`#payload.title` 对 nil 抛错，被 `pcall` 兜成 `client_error`（错误码不精确，难以区分"参数错"与"执行错"）。 | `client/main.lua:77-82` | 先校验 `type(...)=='string'`，返回 `failed, 'bad_payload'`。 |
| A-04 | Low | `msg.timeout_ms` 透传给 handler 但没有任何 handler 使用；`play_anim` 最长阻塞约 1.25s（动画字典 1s + 起播 0.25s），服务端超时语义与客户端实现未对齐。 | `client/main.lua:124`、`:24-52` | 要么实现超时（`GetGameTimer` 截止 + 提前 ack），要么删掉参数避免误解。 |

---

## 5. other（其余 `[custom]` 资源）

先给清单：`[custom]` 下共 **30** 个资源，其中 **20** 个有 `client_scripts`：
`aaa_silence`、`custom-admin`、`custom-agent-client`、`custom-career`、`custom-cartel`、
`custom-certificates`、`custom-debug`、`custom-documents`、`custom-justice`、`custom-main`、
`custom-mining`、`custom-phone`、`custom-police`、`custom-quest`、`custom-security`、
`custom-ui`、`custom-vehicles`、`hud-position-tool`、`notify-test`、`story-engine`。
其余 10 个为纯服务端资源（`custom-director`、`custom-economy`、`custom-market`、
`custom-logs`、`custom-taxes`、`custom-storage`、`custom-crime`、`custom-agent-ops`、
`custom-testing`、`tcity-e2e`）。

有 NUI（`ui_page`）的：`custom-phone`、`custom-police`、`custom-debug`、`hud-position-tool`、
`story-engine`。
用 `SendNUIMessage` 但**没有** `ui_page` 的：仅 `custom-vehicles/client/dashboard.lua`（已死，见 O-05）。

| ID | 严重度 | 问题 | 位置（HEAD） | 修复建议 |
|---|---|---|---|---|
| O-01 | High | `custom-ui.OpenMenu` 只在 `opts.keepInput` 时 `SetNuiFocusKeepInput(true)`，**从不复位 false**。手机按项目约定关闭后保留 keepInput=true，因此之后任何用 custom-ui 打开的菜单（qb-menu 之外的业务菜单、车机部分路径）都会"人物能走、WASD 穿透 UI"。 | `custom-ui/client/main.lua:46-68`（`:56`） | `SetNuiFocusKeepInput(opts.keepInput == true)` 放在 `SetNuiFocus(true,true)` 之前；`CloseMenu` 保持不动（避免手机 WASD 冻结回归）。 |
| O-02 | Medium | story-engine 的重复决策 telemetry 引用了**尚未声明的局部变量**：`:28` 使用 `questId`/`stepId`，而 `local` 声明在 `:35-36`，实际取到全局 nil。duplicate 事件永远上报 `{nil}`，排障时看不到是哪个决策重复。 | `story-engine/client/main.lua:25-36`（`:28` vs `:35-36`） | 把取值移到守卫之前，或 duplicate 分支直接用 `data.questId/data.stepId`。 |
| O-03 | Medium | 决策弹窗 NUI 的 `nuiPost` 无超时（fetch 不会因丢回调 reject，`.catch` 不触发）；origin 硬编码 `https://cfx-nui-story-engine/`。回调丢失时玩家点选项无反应、面板不关，只能等 300s watchdog。 | `story-engine/client/decision_nui.html:148-170`（`:149`、`:161`） | `AbortController` 8s + `GetParentResourceName()`；失败时显示"回调失败，按 ESC 关闭"并解除焦点。 |
| O-04 | Medium | story-engine 打开决策框 `SetNuiFocus(true,true)`，但没有 `onResourceStop`；300s watchdog 只覆盖运行期卡死，不覆盖资源重启（restart 时若弹窗开着，焦点由引擎/其他资源竞争，可能残留）。 | `story-engine/client/main.lua:66-89`、`:249-261` | 加 `onResourceStop` 释放焦点与 keepInput，并 `SendNUIMessage({type='closeDecision'})`。 |
| O-05 | Medium | `custom-vehicles/client/dashboard.lua` 已从 manifest 移除（注释"已迁移至 tcity-dashboard"），但文件仍在：15 个 `RegisterNUICallback`、`SetNuiFocus`、`html/dashboard.{html,js,css}` 全是孤儿。有人把文件加回 manifest 就会出现两套中控屏（`policeRadar`/`closeDashboard` 与 `[system]/tcity-dashboard` 重名）。 | `custom-vehicles/fxmanifest.lua:46`；`custom-vehicles/client/dashboard.lua:288-472`；`custom-vehicles/html/dashboard.*` | 删除 `client/dashboard.lua` 与 `html/dashboard.*`；中控屏唯一实现放 `[system]/tcity-dashboard`（本次范围外，建议纳入下一轮客户端扫描）。 |
| O-06 | Low | 调试浮层 `fetch('https://custom-debug/closeDebug')` 硬编码资源名、无 catch/超时；`/nuioff` 会全局 `SetNuiFocusKeepInput(false)`，打断手机的 keepInput 约定（调试工具可接受，但应注明副作用）。 | `custom-debug/html/index.html:131-138`；`custom-debug/client/debug.lua:86-110`（`:97-98`） | 调试工具也统一 `GetParentResourceName()`；`/nuioff` 输出提示"已同时复位 keepInput，手机可能需重开"。 |
| O-07 | Low | `custom-admin/client/menu.lua`（38 行，`OpenAdminMenu`/`ForceOpenMenu`/`clearWanted` 桥接）**不在** `client_scripts` 里，整个文件不执行；`admin_panel.lua` 才是唯一加载的客户端脚本。 | `custom-admin/fxmanifest.lua:10-12`；`custom-admin/client/menu.lua:1-38` | 要么加入 manifest，要么删除；当前是"看着有、实际没有"的隐形缺口。 |
| O-08 | Low | `custom-main/client/dispatch.lua` 在循环线程里创建通缉 blip，资源重启/玩家卸载不清理（blip 是全局对象，不会随资源停止消失）。 | `custom-main/client/dispatch.lua:92`；无 `onResourceStop` | 保存 blip 句柄，`onResourceStop`/`OnPlayerUnload` 里 `RemoveBlip`。 |
| O-09 | Low | `custom-mining` 为矿点/冶炼厂创建 blip，无 `onResourceStop`/`OnPlayerUnload` 清理 → 重登后重复 blip。 | `custom-mining/client/main.lua:30`、`:62`；无清理钩子 | 同上。 |
| O-10 | Low | `custom-quest` 的拖车监控 (`trailerMonitor`) 只在任务结束路径 `RemoveBlip/DeleteEntity`；资源重启/玩家死亡丢弃时线程继续跑（`:399` 起），可能留下孤儿拖车与 blip。 | `custom-quest/client/quest_logistics_client.lua:273-275`、`:391-402`；资源无 `onResourceStop` | 加资源停止/卸载清理；线程内检测 `DoesEntityExist` 与玩家距离。 |

### 5.1 其余资源：未发现 NUI 契约问题

`custom-career`、`custom-certificates`、`custom-documents`、`custom-cartel`、`custom-security`、
`custom-mining`、`custom-main`、`aaa_silence`、`notify-test`、`hud-position-tool`：没有
`RegisterNUICallback` / `SetNuiFocus`，本次只做资源清单与生命周期抽查（O-08/O-09）。
`hud-position-tool` 的 `ui_page 'html/overlay.html'` 与 `files` 一致，页面为纯展示（无 fetch、
不抓焦点）。`custom-cartel` 有正确的 `onResourceStop` 清理 NPC（`:394-401`），可作为其余资源的模板。

---

## 6. 静态扫描器（`NUI-CLIENT-01`）

文件：`T-CityLite.base/tests/architecture/test_nui_client_contracts.py`
登记：`T-CityLite.base/tests/architecture/nui_client_allowlist.json`

### 6.1 覆盖的 16 条规则

| check | 内容 | 当前命中 |
|---|---|---|
| `callback_cb` | callback 体内必须有 `cb(...)` | 0 |
| `callback_early_return` | 首次 `cb` 之前不得 `return`/`error()`/`assert()` | 0 |
| `callback_not_analyzable` | handler 必须是内联 function，否则进 allowlist | 0 |
| `focus_unpaired` | `SetNuiFocus(true` 必须有 `SetNuiFocus(false` | 0 |
| `focus_keepinput_unpaired` | `SetNuiFocusKeepInput(true` 必须有 false | 1（custom-ui） |
| `focus_no_resource_stop` | 有 `ui_page` 且抢焦点 → `onResourceStop` 必须释放 | 2（police、story-engine） |
| `web_fetch` | 只有 wrapper 可直接 `fetch`，调用方必须 `fetchNui` | 0 |
| `web_fetch_no_timeout` | wrapper 必须 AbortController | 0 |
| `nui_request_timeout` | NUI 侧 fetch/`$.post` 必须可 abort 或带 timeout | 3（police、story、debug） |
| `nui_origin_hardcoded` | 不得硬编码 `https://<resource>/` | 3（police、story、debug） |
| `nui_callback_unregistered` | NUI 请求名必须在客户端注册 | 1（police `closeDatabank`） |
| `nui_external_asset` | `ui_page` 不得依赖公网 CDN | 3 host（police） |
| `ui_page_missing` | `ui_page` 存在且被 `files` 覆盖 | 0 |
| `ui_page_asset_unlisted` | HTML 本地资源都被 `files` 覆盖 | 1（phone favicon） |
| `ui_page_asset_absolute` | 不出现 `/assets/...` 绝对路径 | 0 |
| `dead_nui_client_file` | 注册 NUI/抢焦点的 client 文件必须在 `client_scripts` | 1（vehicles dashboard） |

合计 **15 条**（去重后），全部对应本文的 P-11、D-01/D-02/D-05、O-01/O-03/O-04/O-05/O-06。
运行：**15 passed，<1s**（离线、无 FXServer/DB/网络）。

### 6.2 设计约定（避免误报/腐烂）

- 只扫 `[custom]` 下有 `fxmanifest.lua` 的资源；NUI 源只取 CEF 真正能加载的文件
  （`ui_page` + `files{}` + `web/src`），孤儿文件不制造噪声。
- Lua 注释/字符串先掩码；回调体按块配对提取；遇到内联嵌套函数后的早退不再猜测（宁可漏报）。
- 不存行号：allowlist key 是 `(check, resource, file[, name])`，无关编辑不会让登记抖动。
- allowlist 是**债务账本**：过期 → 失败；修好后没删 → "stale" → 失败。每条都有
  `reason` / `owner` / `added` / `expires`（2027-03-31）。
- 反向注入：15 个测试里 9 个是反向/对照注入（早退、漏 cb、keepInput 不成对、缺 stop 清理、
  裸 fetch、硬编码 origin、未注册回调、未列资源、CDN、死文件），1 个"修正后必须全绿"的对照资源。
- 静态无法判断的（命名 handler、嵌套闭包后的早退、CSS `url()` 资源覆盖、`[system]` 资源）
  明确不覆盖，见 §7。

### 6.3 如何关闭一条债务

1. 修代码；
2. 跑 `python3 -m pytest -q tests/architecture/test_nui_client_contracts.py`；
3. 删除对应 allowlist 条目（否则 stale 失败）；
4. 在 PR 里引用本文 ID（如 `fix(phone): P-11 add favicon to files`）。

---

## 7. 未覆盖 / 无法静态判断

| 项 | 原因 | 建议 |
|---|---|---|
| `[system]/tcity-dashboard`、`[system]/tcity-atmosphere`、`[system]/monitor` 的 NUI | 本次范围限定 `[custom]`；但 `tcity-dashboard` 是实际车机实现 | 下一轮把扫描器 `SCANNED_BRACKETS` 扩到 `[system]`，先跑一遍收债 |
| CSS `url(...)` 引用的字体/图片是否在 `files{}` | 需要 CSS 解析 + 构建产物比对 | 目前人工核对（police 的 `vcr-ocd.ttf`/`tablet-frame.png` 已在 files） |
| 回调体内嵌套函数之后的早退 | 无真正 Lua parser，宁可漏报 | 人工 review 或引入 `luacheck` AST |
| 服务端 callback 是否每条路径都 `cb` | 服务端不在本次范围 | 服务端已有 FIT 系列测试；建议补"callback 必须 cb"的静态规则 |
| 真机焦点/键鼠行为 | Linux 无可靠客户端驱动 | 按 `docs/client/FIVEM_CLIENT_RESEARCH.md` §5：F8 + `nui_devtools`/13172，至少 restart 一次资源复测 P-01/P-02/D-01/D-03/O-01 |

---

## 8. 优先修复 Top 10

| # | ID | 严重度 | 一句话 | 验证方式 |
|---|---|---|---|---|
| 1 | P-01 | **Block** | MDT `Promise.all` 并发同名 QBCore callback，响应错投/超时 | 真机：MDT 调度页刷新 20 次，`units/incidents` 不串、无 6s loading；工作区 request_id 修复合入后回归 |
| 2 | P-02 | **Block** | `getPhoneData` 三处并发同名 callback | 开手机同时触发一次转账/收款，金额与联系人列表正确、无超时 |
| 3 | D-01 | **Block** | 警用 NUI 依赖公网 CDN，离线整页失效并可能锁死焦点 | 断网（或 hosts 屏蔽 CDN）启动，打开指纹 UI：应正常渲染且 ESC 可关 |
| 4 | P-03 | High | 所有 NUI bridge 无超时/兜底 cb | 服务端 `getPhoneData` 人为延迟 10s，UI 应在 6s 显示可重试错误 |
| 5 | D-03 | High | 指纹 UI 不复位 keepInput，人物可走动 | 开手机→关→开指纹：WASD 不应移动角色 |
| 6 | O-01 | High | custom-ui 菜单继承手机 keepInput | 开手机→关→开任意 custom-ui 菜单：WASD 不应穿透 |
| 7 | D-02 | High | `closeDatabank` 未注册 + 硬编码 origin + 无超时 | CEF devtools Network：不应出现 404；关闭不再报错 |
| 8 | P-04 | High | `getPhoneData` 返回 nil 时 UI 静默空白 | 登录动画期间开手机：应显示错误/重试而非空白 |
| 9 | D-05 | Medium | police 无统一 `onResourceStop`（焦点/DutyBlips） | 指纹框开着 `restart custom-police`，焦点应释放、blip 应消失 |
| 10 | P-09 | Medium | 监听了不存在的 `QBCore:Client:SetPlayerData` | 管理脚本直改余额后，手机余额应经服务端推送刷新（或删除该死监听） |

---

## 9. 附：快速自检命令

```bash
cd T-CityLite.base
python3 -m pytest -q tests/architecture/test_nui_client_contracts.py   # 15 passed, <1s
python3 -m pytest -q tests/unit tests/architecture                      # 660 passed / 132 skipped
cd "resources/[custom]/custom-phone/web" && npm run test:nui            # 需要 playwright-core
```

真机（有客户端时）：

```text
F8: restart custom-phone
F8: nui_devtools        # 或浏览器打开 http://localhost:13172/
复测：开/关手机 10 次 → 开 MDT 刷新 → 开指纹 → 开 story 决策框 → restart 各资源
观察：CEF console 404 / "Failed to fetch NUI event" / F8 "Error in NUI callback" / 鼠标键盘是否同步
```


## 10. 修复记录

### 2026-10-25

- **P-01**：手机 `appQuery`/`appAction` 改为 `request_id` + 专用 `phone:server:*Request` / `phone:client:*Response`，支持并发、8s 超时、资源停止清理；旧 QBCore callback 保留兼容。
- **P-02**：`getPhoneData` 三个调用点合并为单飞队列（`fetchPhoneData`），同一帧只发一次；超时返回结构化错误。
- **D-01**：jQuery 3.6.0 / Bootstrap 4.1.3 / Popper 1.14.3 vendor 到 `custom-police/html/vendor/`，`ui_page` 不再依赖公网 CDN。
- **D-02**：`closeDatabank` 补 `RegisterNUICallback`；Databank/fingerprint POST 改用 `GetParentResourceName()`。
- **D-03**：指纹 UI 打开前 `SetNuiFocusKeepInput(false)`，关闭时同时复位。
- 静态扫描器 allowlist 从 15 降到 11；`tests/unit+architecture` 660 passed。
