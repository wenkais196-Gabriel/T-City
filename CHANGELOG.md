# Changelog

All notable changes to T-City Lite will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]


### Added
- **修「手机开着没有游标、点不动」**：`SetNuiFocus` 是**按资源**的 —— 在 custom-ui（没有 ui_page）里调用，
  等于把焦点交给一个不存在的页面，手机页面因此收不到任何鼠标事件（背包/目标盘却正常）。
  现在栈只做决定，按焦点通过 `exports[owner]:ApplyFocus(...)` 回调**拥有页面的资源**。
  真机验证：自绘光标跟着鼠标走、点击 App 图标能进入。
- **手机默认改为完全接管输入**（`phone_keep_input` 默认 0）：真机实测 keepInput=true 时 OS 游标被钉在屏幕角落、既看不见也动不了；关掉后 GTA 把鼠标交出来，游标恢复、键盘导航照常（原始按键不受影响）。代价是手机开着不能走路；想边走边看就 `setr phone_keep_input 1`。
- **输入分层落地（S2+S3）**：手机不再自己 `SetNuiFocus`，焦点与控制屏蔽交给 custom-ui 的交互路径栈；打开 App 压一层 `phone:<app>`、聚焦输入框再压一层 `phone:text`，Esc/Backspace 逐层退出，退到底再按 Esc 就是 GTA 原生暂停菜单。`nav.lua` **不再禁用 172-175**（那正好会点亮转向灯），`indicators.lua` / `cruise.lua` 改为先问 `IsTaken()`。
- **`custom-ui` 增加交互路径栈**（`Push/Pop/Top/Path/IsTaken/Owns/ResetInput`）：世界 → 手机 → App → 输入框每一层是一帧，**只有栈顶拥有键盘**；栈顶声明 `allow` 白名单（放行走路等），其余控制整组屏蔽；栈空时立刻把输入还给游戏 —— 所以 Esc 每次退一层，退到底再按一次就是 GTA 原生暂停菜单。这是把“每处各自 SetNuiFocus + IsNuiFocused()”换成单一仲裁者的第一步（仅新增 API，未迁移资源）。
- **修「键盘只有 agent 能用、玩家按没反应」**：手机开着时 `KeepInput(true)` 让游戏继续吃硬件按键，CEF 收不到、`IsControlJustPressed(172-175)` 也读不到（注入的按键反而能到 CEF，所以此前一直没发现）。键盘改读 `IsRawKeyDown(VK)`（跟 GTA 控制映射无关），手柄仍走控制轮询；同一帧两边都命中时只走原始按键，不会一次挪两格。Tab/PageUp/PageDown/Home/End 也一并纳管。
- **键盘导航补翻页与滚动**：`PageUp`/`PageDown` 一次 7 格、`Home`/`End` 跳首尾；`End` 会留在焦点所在的可滚容器里（真机在 MDT 列表按 End 会跳到壳层「回桌面」）。输入框里这些键仍归输入框自己。滚动容器实测是 `T-CityLite.base/resources/[custom]/custom-phone/web/src` 下的 `.pane`。
- **修 `adc` 的 911 白名单永远不匹配**：Lua 的 pattern 没有 `{n,m}`，`'^911 [^%c;]{1,80}$'` 写成了正则的形状，结果 911 全部被拒（只回 `not_allowed`）。改成 `+` 并在代码里限长 96。
- **切 App 时回吐页面 id**：切到不报状态的 App（Settings、Banking 等）时状态里还挂着上一个 App（真机：屏幕是 Settings，`/live/clients` 说 police_mdt）。现在 `activeApp` 一变就报，回桌面报空。
- **键盘/手柄操作补完：Tab 进出输入框 + 焦点可读**。方向键和 Enter 在输入框里属于输入框自己（移光标 / 提交），所以 Tab = 下一个、Shift+Tab = 上一个，且在处理可编辑元素之前拦截；每次焦点变化都把标签回吐给 Lua（`aria-label` → 文字 → 标签名），`/live/clients` 的 `phone.focus` 现在能读到「焦点停在哪个控件」，agent 不用再盲按方向键（真机第一次盲按 Enter 落到的是"分享"）。
- **手机/平板可以用键盘和手柄操作了**：方向键移焦点、Enter 确认、Backspace 返回上一级；焦点环 + 开屏自动聚焦。键盘走 NUI 的 `keydown`（Tab 被 GTA 占了、方向键有效），手柄走 Lua 轮询 GTA 控制后发 `phone:nav` —— 两条腿落到同一组动作（`T-CityLite.base/resources/[custom]/custom-phone/web/src/core/nav.ts`），为手柄正式适配留好了底层。真机：Down×2 + Enter 打开 Contacts。
- **MDT 也回吐页状态**：警用终端在调度/人车/文书/案件/我的之间切换、以及选中某条警情时上报 `{app:'police_mdt', tab:<page>, selected:<警情 id>}`。只报 id，不报搜索词与案卷正文；离开调度页后 selected 自动清空，免得让人以为他还在看那条警情。
- **agent 能确定性地打开手机里的某个 App**：`/phoneui <app>`（`setr phone_ui_nav "1"` 才生效，生产默认关）→ `phone:navigate` 消息 → NUI 切页。起因是真机上 OS 光标被 GTA 锁在屏幕右下角（`SetCursorPos` 被每帧覆盖，`GetCursorPos` 恒为 2559,1439），合成点击永远落在手机外——这条通道是鼠标点不进去时的替代路径。
- **agent 能读客户端 UI 状态了**。`custom-phone` 导出 `GetUiState()`（`open` / `surface` / `focused` / `keep_input` / `focus_owner` / `nui_focus_native`，只回枚举与布尔），`custom-agent-client` 每 5s 推一份快照，服务端白名单 + 夹紧 + 1s/源限流 + 15s 过期 + 掉线清理，`custom-director` 暴露 `GET /agent/v1/live/clients[/{citizenid}]` 与 `/live/server`，配两个只读工具 `get_client_state` / `get_server_state`（registry 1.7.0，41 tools）。快照是自述，永不作为权限或策略输入。
- **App 停在哪一页也能问到了**。任务 App 通过 `fetchNui('appState')` 回吐 `{app, tab, selected}`（三个短 token，白名单校验），手机侧存起来放进 `GetUiState().app`，服务端再消毒一次。MDT/银行尚未接，`app` 是可选字段。
- **手机和平板是同一台设备的两个 surface**。`PhoneShell` 换成 `DeviceShell`，`surface` 只是一个 prop：外壳差异（尺寸/圆角/刘海/状态栏）全部由 `presetOf()` 驱动，业务组件不知道自己长在什么设备上。形态判定唯一源在客户端 Lua（客户端 core/surface_rules.lua 的纯函数 Decide()，优先级为入口 > 来电 > 载具 > 玩家偏好 > 默认手机）——判定不放 NUI，因为 `keepInput` 是 focus 的一部分，必须在打开这一刻定下来。平板打开时逐帧 `DisableControlAction(30–35)` 锁移动（不用 `FreezeEntityPosition`/`SetPlayerControl(false)` 这类粘性状态），六条失败出口统一收敛到 `Surface.Reset() + DeviceLock.End()`。
- **平板的排布靠 pane 契约，不靠 surface 身份**。新增 core/panes.ts + AppSurface.svelte + Pane.svelte：按容器宽度决定单栏还是分栏，窄了就按 `drill`/`flow` 降级。PoliceMDT 三栏（单位 300 / 接警 348 / 详情 344），Messages 用 drill、Quests 用 flow；手机形态保持原有单屏，详情栏只在 grid 渲染——手机上不该在 DOM 里多留一份重复按钮。
- **三道架构闸门**（`tests/architecture/test_surface_contracts.py`）：禁止 `Tablet*/Phone*App.svelte` 这类分叉组件（含改名克隆的相似度检查）、用了 AppSurface 的 app 必须有 `contracts/<id>.panes.ts` 且 pane id 与 `<Pane id="...">` 双向相等、`TABLET_GRANTS` 必须为空（平板不许新增任何查询/动作/字段）、服务端脚本不许读 `surface`。每条闸门自带反向注入：先扫真仓库要求干净，再往 tmp 写坏形状断言变红。
- **`/tablet` 与 `/phone` 命令**（带控制台 `tcity_tablet <id>` 分支）。以前平板只有设计稿，没有任何入口；已经打开时切换会以 `reason=switch` 关闭再重开，当前 app 不丢。

### Fixed
- **平板偶尔只剩一栏**：`AppSurface` 的 `width` 初始为 0、布局据此退回 `stack`，要等 `ResizeObserver` 第一次回调才切成两栏——快机器看不出来，慢机器（CI）上就是「平板只有列表」。现在 `onMount` 里先用 `getBoundingClientRect()` 同步量一次，之后仍由 observer 跟踪变化。
- **读到的状态总是慢半拍**：状态快照以前只有 5s 心跳，按完 M 立刻去查还是旧值。现在 `custom-phone` 在开/关/换页/`/phonefix` 时广播 `phone:client:stateChanged`，`custom-agent-client` 收到就立刻采一份推给服务端，心跳降级为兜底（15s 过期仍生效）；服务端每源限流从 1s 放宽到 250ms，否则事件推送会被心跳挤掉。真机：按 M 后 ~1s 内 `open` 翻转，之前最多要等 5s。
- **按 M 有时开、有时不开**：`keepInput=true` 让同一次按键同时到达游戏与 CEF —— 游戏（`RegisterKeyMapping`）打开手机，同一帧 NUI 的 `window.keydown('m')` 又把它关掉。密钥只有一个主人：`m/M` 归 Lua，NUI 只留 `Escape` 与自己独占的鼠标手势。真机复验：开→（4.5s 后按）关，`/live/clients` 的 `open` 与截图一致。
- **按 M 关不掉手机**（真机症状：点一次闪一下、再点也关不掉）。两个原因叠在一起：① `RegisterCommand('phone')` 被注册了两次，后一个（`/phone` 强制形态，已经开着就直接 `return`）覆盖了前一个 toggle——同名命令后注册者胜；② 剩下那条 toggle 用 `IsNuiFocused()` 判断"焦点还在不在"，而这个原生在本 build **恒 false**（61 条 focus 遥测里 0 条 true），于是每次"关闭"都走进"复位重开"分支。现在开关只看 `Surface.IsOpen()`、焦点只看 `PhoneFocus.State()`，原生降级为诊断字段 `nui_focus_native`；`/phone [phone|tablet]` 保留强制形态语义，去抖初值改为 `-300ms` 以免资源刚起第一下被吞。无头用例复现了原生撒谎的场景（`env.nui.focus_native_lies`）。
- **窗口大不等于要平板**。旧规则「宽 ≥ 900 且横向 → 平板」在 FiveM 里等于「每次按 M 都锁住移动」，因为 NUI 视口永远是整个游戏窗口（1080p 起）。已删除该规则：平板由意图（入口/偏好）触发，视口只保留一个降级作用——玩家要平板但窗口真装不下时退回手机。
- **`player_not_found` 曾经是时序，不是事实**。手机的 NUI 早于服务端加载玩家就绪，MDT 在这个空窗期查询会拿到"查无此人"，界面显示"角色尚未加载"。现在服务端回 `player_not_ready`，传输层只对这一码重试一次（1.2 秒），设备在角色加载完成前不打开（登录事件 / `SetPlayerData` / 每秒轮询三路判定）。
- **ESC 关闭触发两次 `closePhone`**：`DeviceShell` 与 `App.svelte` 各有一份 keydown。删掉外壳的监听，`closePhone()` 改为幂等。
- **MDT 详情栏显示 citizenid**（`COP002`）：新增 `callsignOf()`，显示呼号 `2-Lincoln-30`，无映射时回退 id 保证老数据可读。
- **NUI 首屏瓦片等待 5 秒不够**：慢机器上首次 `getPhoneApps` 会 `AbortError`，首页短暂为空。瓦片等待改 10 秒。

- **报警终于会变成一条警情**。`police:server:policeAlert`（qb-drugs / storerobbery / houserobbery / custom-vehicles 的热接线报警）与 `police:server:autoAlert`（系统警报）以前只给在勤警察发一条通知、在地图上插个旗就结束了——MDT 的警情板上什么都没有，于是"被抢了报警"在系统里等于没发生：不能派单、不能清场、不留记录、进不了统计。两条路径现在都走 `PoliceDispatch.CreateIncident`（系统来源走 `CreateIncidentFromSystem`），通知由建单统一发出，地图插旗与提示音仍然保留。
- **通知标题带警情单号**（`#38 911: 有人持枪抢店`）。以前手机上的"有人报警"和板上哪一行对不上，只能靠猜。
- **重复报警会并进同一单**：同 code、同地点 60 米内、5 分钟内的报警不再新建行，只刷新 `last_activity_at`，并且不再二次通知——一次抢劫被五个人报警不该变成五条单、响五遍。
- **手机里的 911 是真的入口了**。以前「热线」页的 911 只是一段拨号动画，真正的报警只有聊天命令 `/911`，新玩家不可能知道。现在热线页有报警卡片（输入一句原因 → 拨 911），服务端 `phone:server:report911` 做限流与清洗后调用 custom-police 建单，并把警情单号回显给玩家。
- **MDT 不再直接印 ISO 原文**：警情时间统一成 `HH:MM · 3 分钟前`（`created_at` 是 DB 的 `2026-10-26T09:43:42.000Z`，以前原样贴在板上）。

- **建单即投影：地图标记现在由建单统一发出**。以前地图插旗是各个报警处理器自己广播的，于是控制台派单、系统建单（`/911p`、车牌雷达）在板上看得见、地图上找不到。现在 `projectIncident` 是唯一发送点：任何来源建出一张单，在勤警察同时收到手机通知（带单号）+ 屏幕一句话 + 提示音 + 临时地图标记，合并的重复报警则一次都不响。`/911p` 和车牌雷达也一并改成建单（以前完全进不了警情板），NPC callout 复用同一条投影，通知也开始带单号。

- **MDT 点「前往」现在会画导航路线**：以前只把状态改成「前往中」，坐标得自己从板子上抄。现在按下「前往」就把现场画成一条带距离的 GPS 路线（画法与任务引导一致：route blip + 距离 + 路点），点「到场」时自动收掉，换目标时先清上一条，资源停止时也清。没有坐标的老单据（NPC 之前的单）只改状态、不领路。
- **警情全生命周期设计稿**（docs/server-design/10）：复核确认「前往/到场/清场只有下一个能点、只有被派遣者能点」三条约束一条都没落地——open 状态点「前往」必然 invalid_transition、清场不建档（police_cases 一直没被写过）、disposition 前端硬编码、多单位状态被 markIncidentUnits 一把刷。设计给出：allowed_actions 由服务端下发（判定与执行同源）、primary/support 单位模型与进度派生、清场 = 清场命令 + 归档（disposition 四选一 + case_id），并排入 P5-1..P5-4。

- **警情生命周期设计改成「自动结算 + 两个按钮」**（docs/server-design/10 v2）：到场不该由人点——坐标就在引擎里，让玩家汇报"我到了"既多一步又能造假。现在「前往」= 单人申领（assign + enroute + 自动领路一步到位），「到场」删除、改为客户端检测 30 米 + nonce + 服务端用 ped 坐标复算后自动结算，「清场」只在到场后出现并归档成案卷。文档补了状态机 / 时序 / ER 三张 UML 与端到端流程表，另附单文件前端 demo（docs/server-design/assets/10-mdt-lifecycle-demo.html），申领→自动路线→自动到场→清场归档全流程可点。

- **P5-1 落地：警情到场不再由玩家点按钮**。「前往」现在是一次申领（assign + enroute + 服务端推路线，一步到位），「到场」按钮删除——客户端每秒检测 30 米内（垂直 15 米、连续 2 次、离开 45 米重置），命中后申请一次性 nonce，服务端用 ped 坐标复算（35 米）才结算；自动检测失灵时菜单里有「补录到场」（≤100 米，审计标 manual）。GetIncidents 现在每行下发 units / primary / allowed_actions，MDT 的按钮由服务端判定渲染（不可点时置灰并给中文原因），前端不再复制状态机。新增能力位 incident.claim / incident.arrive / incident.clear，几何参数集中在 shared/policy.lua 的 PoliceIncidentRules（客户端与服务端同一份）。

- **p0 拆分（纯搬迁，零行为变化）**。1224 行 → 5 个模块：`p0.lua`（常量 + SM-02 转移表 + 共享助手）、`p0_units.lua`（值班/状态/指派/进度派生）、`p0_lifecycle.lua`（申领/到场/判定表/路线）、`p0_incidents.lua`（建单/合并/投影/状态机/清扫/911）、`p0_read.lua`（警情板/公民/车辆/审计）。模块之间不共享 local：共享名挂 `P.internal`，各模块按名字绑定、调用时解析，跨模块调用写成同名懒包装，所以函数体一字未改。每个模块自己登记自己的 exports（谁实现谁登记），否则 FIT-04 查不到实现体会变成装饰。附带把 `ArriveIncident` 里那条裸 `UPDATE police_units` 收进 `arriveUnitRow`（单位表现在只在 `p0_units.lua` 写）。闸门同步跟上：单写者规则从"单个文件"改成"p0 家族的固定文件集合"，导出/网络事件/number-budget 白名单路径更新，导出契约扫描器修了两个真 bug（单行函数体会吞掉后面的行；同名转发壳会覆盖实现，导致"委派给写者"被误判成"什么都没写"）。测试侧新增 `tests/p0_sources.py`，块查找不再跨模块。

- **手机 / 平板统一为一台设备的两种形态**。手机和平板不再是两台设备：一个 `DeviceShell(surface)`、一份 app 清单、一套权限。形态由客户端 Lua 的 `SurfaceRules.Decide()` 决定（入口 > 来电 > 载具 > 玩家偏好 > 窗口 ≥900×560 且横向 > 默认手机），因为 `keepInput` 属于 focus，必须在打开那一刻定下来；UI 只照做，不自己嗅探窗口。同一时刻只有一个面在前台（`Surface` 里一个 `current`，不是两个布尔）。**平板锁移动**用逐帧 `DisableControlAction`（30–35），不用 `SetPlayerControl`/`FreezeEntityPosition` 那种粘性状态——粘性状态加一次异常就是永久钉在原地。关闭路径（用户、M 键、切换、ack 超时、`/phonefix`、资源停止）统一走 `Surface.Reset() + DeviceLock.End()`。

- **pane 契约：一个 app 一个组件，两种排布**。`panes.ts` 的 `definePanes` + `AppSurface`（ResizeObserver 测容器宽度）+ `Pane`，排布只由**宽度**决定，不读 surface 身份。首批三个：警用终端（三栏，详情栏只在平板渲染，行内「前往/清场」保留——巡逻时一击不能变两击）、Messages（drill，手机二选一/平板并存，且不自动选会话，因为那会 `markMessagesRead` 把未读清掉）、任务（flow，手机不动、平板加详情栏并收窄列表）。其余 12 个 app 有意不加栏。

- **三道闸门守住"不慢慢长成两个产品"**：① 禁止分叉组件（`*Tablet.svelte` 或相似度 ≥0.9 的改名副本）② 用 `AppSurface` 的 app 必须有 pane 契约且与 DOM 的 `data-pane` 双向相等、`TABLET_GRANTS` 必须为空 ③ 服务端不许读 `surface`、app 不许自己判断形态。三条各自带反向注入（往 tmp 目录写坏形状 → 必须红），所以没有推高未证明预算。NUI 另加 6 个场景，含 parity：同一交互在两种形态下发出的 `appQuery/appAction` 集合必须完全相等。

### Added
- `custom-police` 新增导出 `CreateIncidentFromSystem(createdBy, data)`：给没有玩家 source 的系统来源建单，与玩家路径共用去重、审计与通知。`CreateIncident` 在导出契约里登记为 civilian_entry（平民 911 必须人人可调）。


### Fixed
- **通知的时间不再显示成 NaN:NaN**。`new Date(v).getHours()` 这种写法被复制了四份（通知托盘 / 城市动态 / 短信 / 帮派频道），只要字段缺失或是对象就直接印出 "NaN:NaN"——玩家会以为手机坏了。现在统一走 `utils/time.formatClock`：接受 Date、秒/毫秒时间戳、ISO、MySQL 的 "YYYY-MM-DD HH:MM:SS"，解析不出来回退成 `--:--`，并**只在第一次**遇到坏值时打一条带原始值的 warn（下次再出现，控制台会直接点名是谁）。NUI 新增一条场景守住它：一条有效时间戳 + 一条缺失时间戳，界面必须出现 HH:MM、出现 `--:--`、且整页不含 NaN。


### Changed
- **手机任务列表只摆"现在能接的"**。需求清单摊开之后反而变成噪音：一张吃不到的菜单对玩家没价值。不可接的任务不再出现在列表里（数据仍在服务端，`/listquests` 与控制台诊断照旧能看到全部）。
- **需求清单只显示真正有约束力的项**。`min_police = 0`、`cooldown_hours = 0` 这类"没门槛"的声明不再渲染成"在勤警力 ≥ 0（当前 0）"——之前 18 条剧情任务就是靠这种废话凑出一行。

### Fixed
- **已通关的剧情线仍显示"可接"**。`TriggerQuest` 的 4c 门控一直拦着"已完成的剧情线"（每轮只能玩一遍），但列表层不查，于是 18 条带 `story_arc` 的任务通关后照样出现在可接列表里、点下去才被拒。现在通关即从列表消失，需求文案写明"每轮只能玩一遍"；arc 被 DLC 开关关掉时也会如实显示"暂未开放"。


### Added
- **任务需求逐条摆出来了，不再是一句 "You do not meet the requirements"**。手机里每条任务现在带一份 `requirements`：身份/职业/资历、在勤警力（含当前人数）、执照、剧情线前置、剧情抉择、冷却，每条都标注是否满足；未满足的单独标红，被拒原因取"第一条不满足的"那句人话。
- **补上两个以前完全没检查的准入条件**：`conditions.prerequisite_arc`（要先走完某条剧情线）和 `conditions.player_choices`（要先做出某个剧情选择）。TriggerQuest 会拒这两类，但 availability 层之前不查——于是在手机上看是"可接"、点下去被拒。涉及 9 条任务（cartel/police/civilian 的第四章分支）。


### Added
- **任务奖励发放现在有一行可核对的控制台审计**。`QuestRewards.GrantRewards` 成功后只往 `custom-logs`（Discord webhook）发一条审计；没配 webhook 时，玩家说"奖励没到"本地完全无从核对——日志里只有失败会打印。现在成功也打一行 `[quest-rewards] 💰 玩家 (citizenid) quest=... → $6000 (bank), item xN, rep +80`，一次任务测试结束就能对着日志确认发了什么。


### Fixed
- **重复启动的代价是一次 licence 配额：`start.sh` 现在有单实例锁**。今天修 systemd 时留下过一个 screen 残留进程，之后 systemd 的四次启动全部先通过 licence 校验、再在绑定 30120 时失败——那四次校验把 429 限流重新打了回来，服务被启动限流判 `failed`。现在 `start.sh` 用 `flock` 抢锁，第二个实例在启动二进制之前就被挡住并告诉你去停谁。
- **自检把 429 说成人话**：日志里出现 `HTTP 429` 时，`healthcheck.py` 直接报"Cfx.re 的 license 校验返回了 429（启动太快太多次）：停机等 20-30 分钟再起，期间每次尝试都会续命限流"，而不是只报"资源 0 个 / 标记缺失"让人去猜。

### Added
- **自检只看最后一次启动**：systemd 的日志是追加的，上一次崩溃留下的 `SCRIPT ERROR` 会让之后每次自检都红，人就开始忽略它。现在从最后一条启动横幅开始解析（上次的报错不算，这次的必须算）。


### Fixed
- **systemd 单元会让崩溃循环无限重试，把自己锁死在外部限流里**。实测：一次 Cfx.re license 429 之后，`Restart=always` + `RestartSec=5` 在半小时内重启了 **323 次**，每次都去打一次 license 校验——"等一会儿就好"的限流被续成了死锁。现在单元文件带 `StartLimitIntervalSec=300` + `StartLimitBurst=5`（5 次 / 5 分钟后 systemd 放弃并进入 failed，等人来看），`RestartSec` 放宽到 10 秒；`install_service.py` 的校验器把"缺启动限流"和"限流额度太小"都判为坏单元（反向用例：删掉 `StartLimitBurst`、改成 `StartLimitBurst=1` 都必须被拒）。

### Added
- **任务 App：30 个任务模板第一次有了玩家入口**。此前 `custom-quest` 的 14,903 行与 `config/quests/` 下 30 个模板（平民/警察/卡特尔/物流/矿业…）只有 `custom-director` 的 agent 动作和 e2e 测试能触发，玩家在游戏里根本接不到任务。
  - custom-quest/server/quest_availability.lua：只读的「这个玩家现在能接什么」计算层，同步检查职业标签 / 在勤警力 / 执照 / 重复接取 / 冷却，五种原因码可区分；依赖资源缺失时与 `TriggerQuest` 同样采取宽松策略，不会把全部任务藏起来。**接取权威仍在 `quest_manager.TriggerQuest`**，这里算错最多是显示错，不会让玩家凭空接到任务。
  - 新增导出 `GetAvailableQuests(source)` / `GetQuestDetail(source, questId)`；详情只给步骤标题与类型，不暴露坐标等执行细节。
  - custom-phone/server/apps/quests.lua：注册 `quests` App（对所有职业可见，平民也有平民线）。`quest_id` 由客户端提供，所以在这一层先清洗（≤64 字符、`[A-Za-z0-9_]`），非法 id **不会**下沉到 custom-quest；接取/放弃走 `TriggerQuest`/`AbandonQuest`，被拒时把下游给玩家的原句带回 UI。
  - web/src/apps/Quests.svelte + core/appRegistry.ts：可接/进行中两个页签；不可接的任务**照样显示**并写明原因（"Not enough officers on duty"），而不是从列表里消失。没有专属组件的 App 仍然回退到 `DynamicApp`。
  - `/listquests` 支持控制台调用（`source == 0` 时直接 print）：运维在服务器上就能确认模板加载了多少条，而不是拿到 `native Argument at index 1 was null`
  - 启动自证：`custom-quest` 导出注册后打印「手机任务入口已就绪」，手机 App 注册后打印「quests app registered」；`tools/ops/healthcheck.py` 的启动标记从 3 条扩到 5 条 —— 否则「入口挂了」和「入口没写」在日志上长得一模一样
  - 一条**跨资源导出调用约定**的回归：`exports['res']:Method(a)` 的第一个参数是 proxy 自己，少传 self 会静默把 `source` 当成 tags、把 tags 丢成 nil（真实表现是"所有带标签的任务都不可接"，而只看返回值的测试仍然全绿）。现已断言导出收到的参数各就各位，并做过去掉 self 必须变红的反向校验
  - 测试：`test_quest_availability.py`（lua5.4 真跑模块，5 种不满足条件逐个要求被拒）、`test_quest_phone_app.py`（注册契约 + 边界清洗，非法 id 时下游调用计数必须为 0）、`test_quest_entrypoint.py`（接线闸门，反向禁止手机层出现 `MySQL`/`QuestDB`/`QuestManager` 等旁路）、NUI 2 个新场景（列表渲染 + 点接取真的发 `appAction` 并显示下游拒绝原因）
- **P0 运维基础设施：服务器现在会自己起来、自己备份、自己体检**（见 `docs/ops/RUNBOOK.md`）
  - `tools/ops/healthcheck.py`：把「84 资源 / 0 SCRIPT ERROR / 三条启动标记 / 74 张表」从人眼判断变成一条命令的退出码，`--json` 供 agent 消费；失败项每句都能照着修，而不是只说 failed
  - `tools/ops/backup_db.py`：每日 `mysqldump` + 保留策略。口令从 `server.cfg` 读、经 `MYSQL_PWD` 传给子进程（不进命令行，`ps` 看不到）；`mysqldump` 非 0 或产出 0 字节都判失败并删掉半截文件，避免 cron 里静默成功；已装 `0 4 * * *` 定时任务，并用「导入临时库」验证过 74 张表可恢复
  - `tools/ops/persistence_check.py`：重启前后快照对比。**实测纠正了一个认知错误**：玩家背包在 `players.inventory`，不在 `inventories` 表里（后者存的是后备箱/公寓/组织仓库，键是 `glovebox-XXX` 而不是 citizenid）
  - `tools/ops/install_service.py` + `tools/ops/tcity.service`：systemd 守护，`Restart=always`、控制台进 `/var/log/tcity/console.log`；安装前先校验（缺 `[Install]`、`Restart=no`、`ExecStart` 指向不存在脚本、`User=root` 都会被拒）
  - 四个工具各配架构闸门：`tests/architecture/test_ops_healthcheck.py`、`tests/architecture/test_ops_backup.py`、`tests/architecture/test_ops_persistence.py`、`tests/architecture/test_ops_service_unit.py`，**每条规则都带反向校验**（抽掉标记 / 破坏单元文件 / 伪造空 dump 都必须被抓到）
- **`docs/ops/RUNBOOK.md`**：启停（systemd 与 screen 两种）、自检、备份与恢复、持久化回归、排障速查、工具一览
- 值班警察在 25 米内能看到**地面证据**落点提示：弹壳（红）/ 血迹（暗红）/ 指纹（青）各一根细柱 + `▼ 标签 · 8.0m` 浮字（平民与下班看不到；拾取流程不变，仍是 1.5 米内按 ~g~G~s~ 且要有空证据袋）。原生玩法只有手电照到才浮出文字，实测结果是「地上有东西但没人发现」；三种证据的发现门槛完全一样，所以一起加
- 客户端 MCP 测试 harness：Windows FiveM Legacy + `fivem-mcp-server`，经 FXServer 30120 HTTP 轮询桥接；提供 `client_command` / `screenshot` / `read_client_log` / `nuitest` 测试钩子
- Agent 接管栈：统一工具契约（`tools/agent_tools.json`，30 工具）、MCP 路由层、`custom-director` 17 个动作（L1–L4 分级 + 人审 + 执行后回读）、`custom-agent-client` 客户端效果通道
- 实时感知接口 `/agent/v1/live/*`（内存采样、25m 位置量化、独立 token）
- 拒绝审计 `agent_denials`（迁移 `v2.5`）与评测器 `tools/agent_eval.py`（成功率/审批/拒绝/P95/幂等）
- 实机冒烟 `tools/agent_smoke.py`（只读 → dry_run → 受控写三段式）
- Agent 文档：`docs/agent/{STATUS,TOOLS,EVAL,SMOKE,ACTIONS}.md` 与 `docs/agent/design/` 五份设计
- 全局审查报告与三阶段路线图：`T-CityLite.base/docs/audit/2026-10-21-review-and-three-phase-plan.md`
- Agent 中枢导演架构设计：`docs/server-design/08-agent-director.md`
- 任务系统建表脚本：`migrations/v0.7_quest_system.sql`（player_quests / quest_cooldowns / quest_event_log / quest_daily_limits）
- DevOps 工作流：CI（配置/依赖/Lua 语法）、Release、PR/Issue 模板、CODEOWNERS、CONTRIBUTING、SECURITY
- GitHub 初始化脚本：`tools/dev/bootstrap_github.sh`（标签 / 里程碑 / 待办 Issue）
- 开发工作流指南 (`T-CityLite.base/docs/archive/dev-workflow-guide-2026-06-01.md`)，涵盖目录结构、分支策略、日常开发流程、Git 速查
- `start_server.bat` 一键启动脚本（UTF-8 编码，自动切换工作目录）
- `tests/architecture/test_nui_baseline.py` + `test_command_guards.py`：把「MDT 永远查询失败」与「控制台 /status 崩溃」两次教训钉成 CI —— 禁 NUI 回调里的 `type(cb) ~= 'function'` 守卫、要求 `PhoneBridge.AnswerFn` 覆盖三种应答通道、禁 `GetConvarInt` 判 diag 门禁、client/server trace 相位表必须同序、判定只用可观测槽位、诊断投影不带业务字段、NUI 产物必须内容哈希、`_diag` 只在边界三处出现、命令处理器索引 `PlayerData` 前必须判空（各含反向校验）
- 新增三条架构闸门：`test_agent_docs.py`（根索引必须登记分区文件、固定小节、`CLAUDE.md` 只能是指针）、`test_plane_boundaries.py`（client 不碰 DB / server 不调 NUI 原生 / shared 不注册事件 / manifest 不把 server 代码列进 client）、`test_docs_links.py`（约束区文档的路径引用必须存在）；三条都带反向校验；新增 `tools/dev/release_check.py`（凭据 + 债务到期 + CHANGELOG）与 `tools/dev/reuse_scan.py`（同名实现复用报告）
- **CI 转绿：五处"本地绿、流水线红"的根因**。GitHub Actions 从 `chore(tools)` 起就一直是红的，原因不是某一个提交，而是**测试依赖了本地独有的东西**：
  1. 脚本根的 docs_links_report.py 多一个右括号 —— `compileall` 直接失败（这个文件与 T-CityLite.base 下那份是两份拷贝，我改错了那份）。
  2. 干净克隆里没有 server.cfg（含凭据，gitignored），于是 FIT-10 的"谁是导出消费者"扫描看到的是**模板链**，而模板链漏了 `ensure custom-director` —— CI 与生产看到两个不同的启动集合。补进 quest.cfg（它依赖 custom-quest，必须排在之后）。
  3. agent 的 Lua harness 从来没加载 core-framework 的 shared/util.lua，  而 director 读 convar 走的是 `exports['core-framework']:ConvarString`；更糟的是 harness 的 exports 桩对任何未注册的方法**一律返回 true**，所以 `enabled` 永远是 false → HTTP 适配器全 503，10 个用例里 9 个红。修法是两份：harness 先加载 util.lua，且 exports 桩优先调用本 env 里真正注册过的导出。
  4. integration harness 缺 ConvarInt 等全局（同样的 util.lua 缺失），以及 qb-core 的导出代理只提供了 GetCoreObject，离线入账走的 EconomyAddMoneyOffline 拿到 nil 直接炸。
  5. 两处文档指向 gitignored 的文件（运行时的 admins.json、含凭据的 server.cfg）—— 改成不带反引号的叙述。
  验证方式也换了：**在干净克隆里跑 CI 的四条命令**（`compileall`、tests/unit、tests/architecture、tests/agent、tests/integration），而不是只跑本地那两条目录。结果 920 passed / 132 skipped。
- **技能入库（`.agents/skills`）+ 同步工具 + SKILL-01 闸门**：技能是"这个项目怎么做"的程序性知识，却只活在 ~/.hermes/skills 里——不进 CI、不进 review、换机器就没了，而它描述的正是这台机器上的服务器。现在仓库是准的：`.agents/skills/fivem-resource-development/` 入库，tools/dev/skills_sync.py 负责 --to-hermes / --from-hermes / --check 三个方向，闸门先构造三种漂移（内容不同、副本缺文件、副本多文件）验证检测器能看见，再检查每个技能都有 SKILL.md。文档断链闸门把 .agents 排除（技能里的路径按"安装后位置"写，不是相对仓库根）。
- **端口暴露面收口（有证据，不是看起来）**：ufw 里 40120/tcp+udp 是直连模式下不存在的服务留下的残留规则，已删；现在只剩 30120 tcp/udp（v4+v6）。3306 一直有争议：mysqld 仍监听 0.0.0.0:3306（改 bind-address 需要 root），但 ufw 默认 deny incoming 且没有任何 3306 放行规则——外部连不进来。本机直连自己的局域网 IP 能通是因为走回环接口（lo 默认放行），不能当成外部可达的证据；这条判断已写进总领手册的端口与暴露面一节，并给出从另一台机器验证的命令。
- **客户端可观测性真的接上了（20 个资源，此前只有 2 个）**：`CFShared.Report` + 就绪信标的文档写了很久，但只有 custom-phone / custom-police 真接上——其余二十多个自有资源的客户端错误没有任何上行通道。现在 `[custom]`/`[system]` 里已 ensure 的资源全部把 @core-framework/client/shared.lua 放进 client_scripts 第一位，并声明 `dependencies { 'core-framework' }`。
  过程中挖出两个真问题：①**启动顺序**：production-freeze、hud-position-tool、custom-career 原本都在core-framework 之前启动，`@` 包含会在加载期找不到文件——把 `ensure core-framework` 从 custom.cfg 挪到 core.cfg 的 production-freeze 之后（core-framework 依赖它加载 `_L` i18n）、hud-position-tool 之前。②**环**：production-freeze 与 core-framework 互相依赖，所以它反向包含会成环——撤回并登记为例外。
  闸门 CLI-01（tests/architecture/test_client_observability.py）：缺包含点名、不在第一位点名、豁免双向校验、上游目录与 vendored 库也要校验没被注入；每条规则先构造坏形状证明能红。顺带修好解析盲点：`client_script 'x.lua'`（单数写法）此前完全不在扫描范围内，改成单数就能绕过。
  验证：全量 927 passed / 132 skipped；整机重启 84 资源 Started、0 SCRIPT ERROR、无 could not find / failed to load。
- **CI 全绿（6/6 job）**：最后两个 job 也是同一类毛病——**测试桩与它测的代码脱节**。
  agent 工具注册表：TOOLS.md 是 `tools/agent_tools.py --write` 的生成物，但有人在末尾手写了一段控制台驱动手册（tcity-cmd），`--check` 于是永远报 drift。那段内容本身有价值，搬到 T-CityLite.base/docs/agent/CONSOLE.md（并从 agent/README.md 索引），生成物恢复纯生成。
  NUI 冒烟：Playwright 的 fetch 桩返回**空正文**（`text: async () => ''`），而 custom-phone 现在把 `await resp.text()` 交给 JSON.parse（web/src/utils/nui.ts），于是每个回调都抛 "NUI <event> replied HTTP 200: "，这些 console error 把用例判红。桩改成按事件名返回非空 JSON（nuiReady/phoneOpenAck/closePhone/getPhoneData/getPhoneApps/getCallHistory）。
  验证：`python tests/nui/run_ui_tests.py` 4/4（截图是真渲染的手机主屏，不是空壳）、agent_tools --check OK、全量 920 passed / 132 skipped，GitHub Actions 六个 job 全 success。
- **警察模块收口（第三步完成）：案卷 / 逮捕 / 报告，例外表清零**。`police_cases` 有两个写者（p2 的逮捕建卷、p3 的玩家建卷，两段几乎逐字相同）、`police_arrests` 两个且**列集合不同**（p2 的 Sys.Jail 三列、p3 的 RegisterArrest 五列）、`police_reports` 三处 INSERT 加两处 UPDATE（p1 五列、p2 十四列/十二列、p3 只更新判决字段）。
  又碰到同一个 bug 家族：`case_id`/`incident_id` 位于参数数组**中间**，调用方常传 nil，数组出洞 → oxmysql 截断 → 参数少于占位符 → MariaDB 语法错 → `InsertId()` 拿到错误字符串。真库对照确认：旧形状 `ok=true` 但结果是错误字符串 —— 也就是说**不带案卷/事件建报告这条路是坏的**，而报告创建是逮捕与录入流程的必经环节。
  新增 custom-police 的 records.lua 作为三张表的唯一写者：`InsertCase`（案号 CASE-年-六位，插入后补写）、`InsertArrest`（incident/case 只在提供时出现）、`InsertReport`（kind/status/BOLO/charges 按需拼接）、`LinkReport`（case_id 数字、justice_case_id 字符串，只更新实际给的列）、`RecordVerdict`（返回 ok 与 affected，保留"写失败"与"没匹配到行"的区别）。p1/p2/p3 的 9 处写入全部改为委派。
  闸门里 `police_*` 的**例外表现在是空的**：14 张表全部有唯一写者。顺带修掉 `test_deprecations` 的误报来源 —— 它把注释里写的示例 SQL 当成真实写入（`police_arrests` 的预算因此被散文污染），现在先剥注释。
  验证：879 passed / 132 skipped；真库探针 —— 无案卷报告 `case_id` 为 NULL、案号 `CASE-2026-000001`、逮捕无 case 时该列为 NULL、字符串司法 id 链接与判决（`justice_status=closed`）都成功；84 资源零错误；探针数据已清理
- **警察模块收口（第二步）：证据 + 证据链，顺带修好一条整条死掉的路径**。`police_evidence` 与 `police_evidence_chain` 原本双写（p2_evidence 的登记 + p2_system 在逮捕/报告提交里各抄了一遍）。收口时在真库上对照两种形状，发现 **登记路径本身是坏的**：
  `INSERT INTO police_evidence (exhibit_no, ...) VALUES (?, ...)` 配 `{ nil, incidentId, ... }` —— 参数数组第一个就是洞，oxmysql 在洞处截断，发出的参数少于占位符，MariaDB 报 "syntax error near '?)'"，`InsertId()` 拿到的是错误字符串，于是**每一次证据登记都返回 db_error**，服务端日志里只有业务层一句"登记失败"。链记录的 `note` 为 nil 时同样留洞（`pcall` 看不见，因为错误是返回值）。
  修法：新增 `PoliceEvidenceWriter.Register` / `.Chain` 作为唯一写者，列集合按需拼接（不存在的字段写 NULL 进 SQL，参数数组永不留洞），展品号 EX-%06d 在写者内补齐，首条 'collected' 链记录一起写，返回值带 `chain_ok` 让"链失败必须回滚"的调用方保持原语义。p2_system 的两处拷贝改为一次委派（保留各自的回滚路径）。
  验证：867 passed / 132 skipped；真库探针 —— 登记成功 `EX-000002`、链记录 1 条、`chain_ok=true`、缺父级/短标签分别被拒为 `missing_case`/`invalid_label`；84 资源零错误。单玩家可验的部分（写库、链完整性、校验、审计）全测；"两个玩家在案发现场采集"这条仍需真实双人
- **客户端热路径：8 段逐帧轮询收成一个（可测的）实现**。custom-police 的 job.lua 里有 8 段几乎一样的循环（值班、储物柜、垃圾桶、直升机、拖车场、车库、指纹、证据），每段 14~17 行，差别只有"哪个 flag""要不要在车里""按下做什么"；其中 6 段还带着 `if PlayerJob.onduty then sleep = 5 end` —— `sleep` 全局从未被读取，纯拷贝残留。
  新增 interact.lua 的 `PoliceInteract.Watch{active, allowed, requireVehicle, onPress, after}`：退出条件写成显式的 `active`（离开区域即退出，不再藏在 else 分支里），可选的车内/职业/拒绝重试都在一处。job.lua 的 8 处调用点改为一行配置，`Wait(0)` 与手写按键轮询在该文件里归零（980 行，少 67 行）。
  evidence.lua 的弹壳/血迹/指纹提示循环原本每个分支各自 `GetEntityCoords(PlayerPedId())`，改为循环开头取一次复用；这个循环保留手写形态（三个目标各有就近判定与不同副作用，硬合并会改变行为），在闸门里以带理由的例外登记。
  新增闸门 `test_client_hot_paths.py`：逐帧循环里同时出现 `IsControlJustReleased` 与 `Wait(0|1)` 即红（唯一实现是 `PoliceInteract.Watch`）、每帧循环体内 `GetEntityCoords(PlayerPedId())` 最多一次，带反向校验、例外痕迹校验与变异冒烟（注入手写轮询 → 红）。
  验证：861 passed / 132 skipped；job.lua、interact.lua、fxmanifest 过 luac；84 资源零错误。
  诚实边界：客户端脚本的运行时行为要真客户端才能验，本轮证到的是"结构正确 + 语义单测"（`test_police_interact.py` 6 例：按下只触发一次、离开区域不按键、职业不符即退、车内门槛、onPress 可拒绝重试）
- **警察模块收口（第一步）：审计与建单各归一个写者**。`police_audit` 原先有 **8 份**各自实现的 `INSERT`，分两种写法；在真库上实测发现其中一种**在 `detail = nil` 时静默失败**——参数数组末尾的空洞被 oxmysql 截断，MariaDB 报语法错，而 `pcall` 返回的是 **true**（错误以字符串形式返回，不抛异常），于是调用方的 `if not audit(...)` 把失败当成了成功，**审计行根本没写**。
  新增 custom-police 的 audit.lua 作为唯一写者：`NULL` 直接写进 SQL（参数数组永不留洞）、把数据库返回的错误字符串判为失败、统一截断（target 64 / detail 500）、支持 `actor_kind`（player/agent/system）。七个文件的本地 `audit()`/`auditPlayer()`/`auditNpc()` 改为同名委托，调用点一行未改。
  `police_incidents` 从三个写者（p0 玩家 911、p2_system 的 agent 路径、p4_npc 的 NPC callout）收成一个：p0 里新增 `insertIncidentRow(createdBy, data, opts)`，列集合按需拼接（`npc_template` 这类可选列不再靠传 nil 参数），agent 路径保留自己的 fail-closed 预审计（`opts.audit = false` 避免一次建单记两条审计），NPC 路径保留预算回滚。
  新增闸门 `test_police_single_writer.py`：8 张表定下唯一写者，6 张未收口的表登记理由与"痕迹"（痕迹消失=例外失效要删表）；判据是"这张表只有它该有的那个文件在写"，并带反向校验与变异冒烟（注入第二个写者 → 红）。
  验证：840 passed；真库探针确认 nil 字段审计**写入成功**（此前静默丢失）、agent 建单 `created_by=agent:probe-agent`、`npc_template` 落库、`x` 为 NULL、一次建单只产生一条审计；84 资源全 Started、零错误
- **安全：关闭公网 3306**。主机 ufw 原本对 `3306/tcp` 全网放行，而 mysqld 监听在 `0.0.0.0:3306` —— 数据库（全部玩家数据）暴露在公网。已删除该规则（`sudo ufw delete allow 3306/tcp`），30120/tcp+udp 保持放行；服务器经 localhost 连库不受影响（重启后 84 资源全部正常、经济探针写入成功）。建议后续把 `bind-address` 收成 `127.0.0.1`（需要 root 改 `/etc/mysql/mysql.conf.d/mysqld.cnf` 并重启 mysql，本轮未做）
- **客户端可观测性：服务端能看见客户端了**。客户端的 `print` 只进玩家 F8、服务端永远看不到，于是"新客户端代码到底有没有加载""跨资源导出是不是缺了"这类问题只能靠对方截图——这个坑咬过两次（`loadAnimDict` 导出缺失、core-framework 客户端共享文件包含失效后的静默降级）。
  新增两个诊断事件（登记在 `net_events_allowlist.json`，category=diagnostic）：`clientReady` 在客户端资源加载后发一次 → `[client-ready] custom-police v1.7.0 Tester(#7)`；`clientReport` 是 `CFShared.Report(kind, msg)` 的出口 → `[client-report] error <player>: <msg>`。
  安全面按"输入完全由客户端控制、输出是服务端日志"来设计：去所有控制字符（尤其换行，防伪造日志行）、截断（消息 400 / 资源名 64 / 版本 32 且限字符集）、kind 白名单、每玩家限流走 owner（就绪 3/60s、上报 10/60s）、`src == 0` 直接忽略。
  顺带修了闸门的两个盲点：net event 扫描只覆盖两个资源（框架自己的事件从没被扫过）；以及 `RegisterNetEvent(EVENT_NAME, ...)` 用变量名注册时扫描器完全看不见——新增规则`test_net_event_registration_uses_a_literal_name` 钉死必须写字面量。allowlist 的 owner/path 校验也不再写死两个资源名（框架资源原先根本登记不进去）。
  验证：服务端一半与客户端一半都有真跑 Lua 的单测（`test_client_reports.py` 7 例、`test_client_shared.py` 5 例，桩只替换 FiveM 原生），启动探针实测 `ready_window_3 = YYYNN`、`report_window_10 = YYYYYYYYYYNN`。遗留："玩家登录后确实看到 `[client-ready]`"要真玩家才能验
- **闸门覆盖率：把"从未被证明会红"变成预算**。新增 `tools/dev/gate_coverage.py`——一条规则算"已证明"当且仅当：在 `gate_history` 里失败过 / 是变异冒烟用例 / 自身是反向校验；其余算未证明（技术债）。当前 211 条规则里 55 条已证明（冒烟 15 + 自带反向校验 40），未证明 156 条，写进 `gate_coverage_budget.json`：超上限红，明显低于上限也红（逼着收紧）。同时把变异冒烟从 8 条扩到 15 条，新增覆盖：net event 鉴权、状态写路径、跨资源写表、`SELECT *` / 无 LIMIT、命令处理器守空、SetJobDuty 写路径、分区 AGENTS.md 固定章节。扩容过程本身抓到两个"我以为会红"的坑：状态写扫描只认规则跟踪的列（写 `title` 不触发，写 `status` 才触发），跨资源写 `player_vehicles` 是已登记的豁免（拖车），得换 `player_houses` 才红
- **限流最后一处也收掉了，例外表清空**。`tcity-atmosphere` 原本在每玩家 state 里自己数窗口（`requestCount` / `requestWindowStart`）。当初保留它的理由是"与场景状态机耦合、要重构状态机"——实际 grep 全仓后发现这两个字段**没有任何外部读者**（唯一命中是 oxmysql 的 node_modules），于是三行就换成了 `exports['core-framework']:RateLimitWindow(key, 3, 10000, now)`，并在 `playerDropped` 里显式 `RateLimitReset`（原来是随 state 一起丢的）。至此 `test_rate_limit_single_owner.py` 的例外表为空：全仓限流只有一个实现
- **文档断链改成"活跃层必须 0 + 历史归档显式豁免"**。范围从"逐个目录收编"（每次都要改闸门代码，而且没收编和已修好"在报告里长得一样"）改成全仓 md 默认全覆盖，唯一例外是带 `LEGACY.md` 且登记在 `tests/architecture/legacy_docs.json` 的历史归档目录。豁免是**双向校验**的：有标记没登记 → 红（不许自己贴标记逃避闸门）；登记了但目录或标记没了 → 红（豁免不许烂在表里）；归档文档数 ≥ 活跃文档数 → 红（防止归档变成默认）。5 个历史目录（police 172 / audit 88 / 02_script_index 82 / cleanup 45 / archive 27 处）已标记并登记，活跃层 213 处断链全部修掉——多数是指向真实新位置（`qb-jewelery` 等进了 `archive/`，五处路径统一成 `resources/[组]/<res>/<file>`），确实已删除的文件改成不带反引号的叙述而不伪造路径。`docs_links_report.py` 现在分开报活跃层与归档，避免"414 处断链"这种数字让人以为闸门失守
- **删掉 1,233 行"看起来在跑"的死代码**。custom-main/server/security.lua（260 行）与 `T-CityLite.base/resources/[custom]/custom-security/server/security.lua` 是同一份安全服务的两份拷贝（差 26 行：日志前缀、`custom-main` → `custom-logs` 导出名），按"重复实现"思路该合并——但 `T-CityLite.base/resources/[custom]/custom-main/fxmanifest.lua` **根本没列这个文件**，它是资源拆分后的残骸。同批残骸：`custom-main` 的 server/crime.lua、server/logs.lua、client/security.lua，custom-admin/client/menu.lua（其监听的事件已由 `qb-adminmenu` 接管），custom-vehicles/client/dashboard.lua（531 行，中控屏已迁到 `[system]/tcity-dashboard`）及其 `html/` 下三个再无人引用的页面。
  全部删除，运行时行为不变（都没有被清单加载）。新增闸门 `test_no_orphan_scripts.py`：`[custom]` 下每个 `.lua` 必须出现在自己资源的 fxmanifest 里（含 `dir/*.lua` 通配），临时文件用 `_` 前缀、测试放 `tests/` 目录，否则红。
  连带更新了六张登记表（table_owners 的 `main-player-metadata`、NUI 白名单的 `vehicles-dead-dashboard-client`、NUI 回调下限 60 → 53、convar 调用方清单、限流调用方清单、复用预算 DebugPrint 14 → 11）——闸门全部按预期报"登记项已失效"，这正是棘轮该有的反应
- **真实调用验证抓到两个 bug（静态闸门都看不见）**。用一个资源启动时自动执行、结果 `SaveResourceFile` 落盘的探针，直接调 `exports['qb-core']:EconomyAddMoneyOffline` 与`exports['core-framework']:RateLimit*` 跑真实 DB 与真实限流表：
  - `cash +0.55` 存成 `100.5499999999999545` —— 参数以 DOUBLE 绑定，DECIMAL 相加后漂移；改为 `ROUND(COALESCE(CAST(JSON_EXTRACT(money, ...) AS DECIMAL(20,2)), 0) + ?, 2)`，并在经济闸门里加了一条"必须 ROUND 到分"的断言；
  - `TokenBucket` 的 burst=2 放过了**第 3 次**请求 —— 首个分支建桶时给了满 tokens 却没扣本次那一个；改为建桶即扣，并补 `tests/unit/layer1_core/test_rate_limit.py`（8 个用例真跑 Lua，时间用桩注入）把三种语义、前缀 Reset、Sweep、脏参数钉住。
  修复后同一探针复跑：`cash` 精确为 `100.55`、`tokenbucket_burst2 = true,true,false retry=1000`；同时确认 `keep` 这类未知字段在入账后仍在（不再是整块覆盖）、并发两次 +10 都在（无丢更新）、四类非法入账全部拒绝且余额不变
- **文档断链闸门再收编一层**：范围加上 `docs/client/**`、`docs/analysis/**`、`docs/server-design/**`，12 处文件、82 条引用改成可解析路径（规则本身未放宽、未加豁免）。全仓断链 706 → 619，约束区（agent 会照着做的那一层）现为 0 断链。仍未收编的是 `audit/`、`archive/`、`02_script_index/`、`cleanup/` 这类历史目录，由 `docs_links_report` 继续出报告
- **闸门变异冒烟：证明"这些规则真的会红"**。`tools/dev/gate_mutation_smoke.py` 把"往仓库里塞一个该被拦住的形状 → 跑那条闸门 → 确认变红 → 撤掉 → 确认恢复绿"变成可重复执行的工具，覆盖 8 条核心闸门（经济单写者 / 整块覆盖 / 限流 / 平面越界 / 复用预算 / 文档断链 / AGENTS 登记 / manifest 语法），实测 7 条全部"注入后红、撤掉后绿"（第 8 条因文档目录正在收编而暂时常红）。配套 `test_gate_mutation_smoke.py` 钉住"用例指向的闸门必须真实存在"——测试改名后用例会静默空跑，那是比没有冒烟更加危险的状态
- **限流收口：7 份实现 → 1 个 owner**。新增 `T-CityLite.base/resources/[standalone]/core-framework/server/rate_limit.lua`，提供三种语义（`Cooldown` 每键冷却 / `Window` 固定窗口计数 / `TokenBucket` 令牌桶 + 突发），带 `Reset(前缀)` 与 `Sweep`，时间参数可注入便于单测，并以 `RateLimitCooldown/Window/TokenBucket/Reset` 对外导出。迁了 7 处：`notify_service`（窗口）、`tcity-dashboard`（冷却）、`custom-vehicles` 的 `main` 与 `dashboard_api`、`custom-security`/`custom-main` 两份 security、`custom-agent-client`（令牌桶）。两处**刻意保留**并登记理由：`tcity-atmosphere`（计数在每玩家 state，与场景状态机耦合）、`T-CityLite.base/resources/[custom]/custom-phone/server/core/rate_limit.lua`（带 diag 钩子的令牌桶，有独立单测）。新增闸门 `test_rate_limit_single_owner.py`（含"例外失效要删表"与"注释里的旧实现不误报"两条反向校验）
- **新增 manifest 语法闸门**：`test_manifest_syntax.py`。起因是给 6 个资源补 `core-framework` 依赖时漏了逗号，`dependencies { 'qb-core' 'core-framework', }` 让 manifest 变成非法 Lua——而 `restart <resource>` **不会报错**（FiveM 复用已解析的元数据），直到整机启动才以"6 个资源 failed to load、只剩 76 个在跑"的形式炸出来。闸门同时对 `dependencies` 里的自有资源名做存在性校验
- **经济写路径收口（宪法②）**：三处绕过内存层、直接 `UPDATE players SET money` 的离线入账（core-framework 的 Transfer、custom-phone 的离线汇款、qb-crypto 的离线转账）统一到 owner `T-CityLite.base/resources/[qb]/qb-core/server/services/economy_service.lua` 新增的 `AddMoneyOffline`（JSON_SET 算术 + 货币类型白名单+ 影响行数校验 + 失败回滚），对外以 `exports['qb-core']:EconomyAddMoneyOffline` 暴露。其中 **qb-crypto 那份原本是 `SET money = ?` 整块覆盖**——先读快照再写回，中间任何人动过 bank/cash 都会被静默回滚，属丢更新，本轮一并修掉。`Bus.Plugin.GetEconomy()` 现在只返回原语层（原来 `Bus.economy or Bus.EconomyService` 两套不同方法集共用一条链，谁先注册谁生效），分层便利方法走新的 `GetEconomyTools()`；新增闸门 `test_economy_single_owner.py`（4 条规则 + 反向校验）
- **convar 助手族收敛（23 → 0 份本地实现）**：`GetIntConvar`/`GetBoolConvar`/`GetFloatConvar`/`GetStrConvar`/`GetNumConvar`/`convarInt`/`convarString` 统一到 `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua` 的 `ConvarString/Int/Float/Bool`；12 个调用文件改成惰性包装，6 个资源补 `dependencies { 'core-framework' }`（这批在 `config.lua` 加载期就调用，没有依赖声明会整个资源加载失败）；新增两条闸门钉住「不许留私货」与「加载期调用方必须声明依赖」
- **`docs/agent/TOOLS.md` 记录控制台注入的三个坑**：回显不可信（会混入日志片段，命令其实执行了，要按效果校验）、输入行不清空（只有"先发回车丢掉残留"有效）、被拼坏的命令会让资源静默停掉；另记新增脚本文件必须 `refresh` 才会交付给已连接的客户端
- **共享导出的真实调用已验证，并补上启动自证**：端到端探针发现 `restart` 后的客户端根本拿不到新增的 `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua`（`restart` 只重读清单里已有的文件），导出缺失要到玩家触发动画时才炸 `No such export LoadAnimDict in resource core-framework`——静态闸门与"重启无报错"都盖不住这个坑。现在 `util.lua` 客户端侧带一行启动自证 print（F8 可见），`refresh` + `restart` 后实测 `ok=true returned=true hasAnimDictLoaded=1`；`docs/engineering/REUSE.md §6` 增加了三步验证配方（自证行 / 导出存在 / 字典真的加载出来）
- **组件复用第一轮收敛**：新增 `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua`（客户端侧 `exports('LoadAnimDict')`，比原实现多 5s 超时，避免字典缺失把客户端脚本线程卡死）；`[custom]` 的 5 处重复实现（custom-police ×2、custom-vehicles ×2、custom-agent-client）改为惰性包装调用，`loadAnimDict` 17 → 12 份；`qb-*` 与 `standalone` 按「不迁上游」保留并写进预算理由；新增 `docs/engineering/REUSE.md` 与棘轮闸门 `test_reuse_budget.py` + `reuse_budget.json`（预算只许往下调，新增 ≥4 份同名必须登记决策）
- **文档断链闸门扩到 `docs/agent/**`**：该目录 17 份文档的 107 处相对路径改为可解析路径（`T-CityLite.base/docs/agent/**` 现为 0 断链），规则本身未放宽、未新增豁免
- **规则命中率可采集**：新增 `tools/dev/gate_stats.py`（`--record` 把整套架构闸门的结果追加进 `gate_history.jsonl`，`--report` 输出每条规则的最近结果/通过失败次数/长期 0 命中清单）与 `test_gate_stats.py`；首份基线 205 条规则全绿
- **Agent 运行模型（L0–L5）**：`docs/engineering/CONSTITUTION.md`（十条不变量，每条带可执行落点）、`docs/engineering/ARCHITECTURE.md`（四平面 + 依赖方向矩阵 + 唯一通道表）、`docs/engineering/agent-operating-model.md`（六层模型与落地路线）；根 `AGENTS.md` 瘦身为索引（88 行）+ 四份分区 `AGENTS.md`（`[custom]` / `[qb]` / `tests` / `custom-phone/web`）；`CLAUDE.md` 改为指针（避免与 `AGENTS.md` 分叉），原通用准则归档为 `docs/engineering/llm-craft.md`；五份流程模板 `docs/engineering/templates/*.md`（R/P/D/V/S）

### Security
- 地面证据（弹壳/血迹/指纹）现在会**过期消失**：默认 30 分钟，服务端每分钟扫一次，过期就删并广播 `evidence:client:Remove*` 让客户端把屏幕上的箭头一并抹掉。此前 TTL 只在「表满 500」时才顺手跑一次，没到上限就整局不清、而且清的时候一声不响（客户端留着换不出东西的幽灵标记）。TTL 可用 `set tcity_evidence_ttl <秒>` 覆盖（现场验证用 60 很合适），清扫周期常量 `TTL_SWEEP_INTERVAL`。客户端拾取块也补了空值守卫：记录被扫掉后仍按 G 不会让脚本崩在 "attempt to index a nil value"
- **地面证据拾取改为服务端权威**：拾取只校验「有权限 + 有空证据袋」，既不核对 id 是否真在服务端的掉落记录里，serie / 武器 / 血型 / DNA / 指纹 也全部采信客户端发来的描述 —— 改过的客户端可以凭空换证据袋，或者把枪号、指纹、血型写成别人的来栽赃。现在必须先查到自己那张记录表（`Casings` / `BloodDrops` / `FingerDrops`）里的行，身份字段一律取自服务端记录，唯一还采信客户端的只有街道名（只有客户端拿得到原生街道名）
- `custom-vehicles`: `qb-vehiclekeys:server:AcquireVehicleKeys` 此前只校验会话内车主，任何客户端可伪造车牌远程认领载具；现改为车牌格式校验 → 会话车主 → `player_vehicles` 登记车主 → 无主载具 10m 邻近（`vehicles_claim_max_dist`）+ 1s 限流 + 审计
- `custom-vehicles`: `KeyManager.*` 拒绝非字符串车牌；`GiveKeys` 对无主载具要求先持有钥匙；`RemoveKeys` 仅车主可移除他人钥匙
- `qb-inventory`: `SetInventoryData` 对 `otherplayer-*` 容器增加 3m 距离校验（管理员豁免），堵住伪造事件远程搬运他人物品；槽位/数量先 `tonumber` 再比较，避免非法类型报错
- `custom-admin`: 全量自动 admin 改为 `admin_autogrant` convar（默认关闭）
- `story-engine`: 决策绑定服务端 pending offer（quest/step/decision），拒绝跨任务伪造；超时由服务端按默认选项收口
- `custom-quest`: `ValidateNode` 实现类型 + 服务端距离校验；`registerTrailer` 校验实体与距离；`cleanupTrailers` 改为非网络事件；`savePosCollection` 限制管理员
- `custom-vehicles`: 钥匙/改装/部件/氮气事件统一校验车主或执勤机修；部件值夹紧 0–100
- `qb-hotdogjob`: 职业校验 + 数量≤5 + 单价按 Config 边界，堵住 `$10k/秒`
- `qb-streetraces`: 服务端重建赛局与奖池，领奖前销毁，加入去重
- `custom-justice`: 出狱按刑期校验；入狱刑期上限
- `custom-mining` / `custom-cartel`: 矿点距离、生产开始/时长校验
- `custom-main`: `ResetDeathStatus` 仅在医疗未启用且服务端判定死亡/倒地时允许，10s 冷却；`policeHandoverAlert` 加 5s 冷却 + 坐标/星级/街道校验
- `tcity-dashboard`: `police:server:plateFlagged` 要求值班 LEO/admin，车牌规范化 + 2s 冷却；内部同步改为本地调用
- `custom-testing` 移出生产 cfg，改由 `configs/modules/dev.cfg` 按需启用

### Fixed
- **弹壳从上线起就没有成功生成过一次**：客户端把 `GetOffsetFromEntityInWorldCoords` 返回的原生 vector3 直接丢给服务端，而 `sanitizeCoords` 要求 `type(coords) == 'table'`，于是每一枪都在第一步被判非法并静默丢弃（日志里只有一句笼统的 coords too far）。现在客户端发 `{ x, y, z }` 普通表，服务端也兼容 vector3，校验函数把 nil 拆成带原因的返回值（不是表 / 超距 / 无 ped），`tcity_evidence_debug` 打开后每条拒绝都会写明原因
- `custom-phone`: 一次按 M 会派发**两条** `phone` 命令（`RegisterKeyMapping` 在资源重启时重复注册），第二条看到 `isPhoneOpen=true` 且 `IsNuiFocused()=true` 立刻走 `ClosePhone` —— 界面被叫出来又秒关，玩家看到的是「按 M 没反应」。命令入口加 300ms 防抖（重复调用打 `phase=toggle-debounced`），`RegisterKeyMapping` 改为只注册一次
- `custom-phone`: **MDT「查询失败/操作失败」的真正根因**——本 build 的 `RegisterNUICallback` 把应答通道交成**可调用表**（`{ __cfx_functionReference = ... }` 带 `__call` 元方法），而 `PhoneBridge.RegisterNui` 的守卫 `if type(cb) ~= 'function' then return end` 会静默丢弃每一次应答：handler 跑了、服务端也回包了，CEF 的 fetch 却一直挂到 9s abort，前端只能报 `query_failed`/`action_failed`。新增 `PhoneBridge.AnswerFn`，兼容 function / 可调用表 / 裸函数引用（`Citizen.InvokeFunctionReference`），无法应答时直接不执行 handler，避免跑一半留副作用
- `qb-ambulancejob`: `/status`、`/heal`、`/revivep` 未判 `QBCore.Functions.GetPlayer(src)` 为 nil；同一形状的命令处理器共 39 处（`qb-hud` `/cash` `/bank`、`custom-police` 24 处、`qb-houses`、`qb-lapraces`、`qb-adminmenu`、`qb-inventory`、`qb-crypto`、`qb-cityhall`、`qb-vehicleshop`）一并加上判空，并新增 `tests/architecture/test_command_guards.py` 钉住该规则（事件处理器不在范围内：那里的 `source` 一定是真实玩家），从控制台（`source=0`）或玩家刚掉线时执行会抛 `attempt to index a nil value (local 'Player')`；现改为先判空（控制台没有可通知的客户端，`TriggerClientEvent` 传 0 会触发 native 参数 null 错误）
- `qb-core`: `QBCore.Commands.Add` 在缺少必需参数时对 `source` 发 `chat:addMessage`，控制台执行（`source = 0`）会抛 `native ...: Argument at index 1 was null`；改为控制台打印用法、玩家仍走原通知路径
- `custom-phone`: `phone:open` 是 fire-and-forget，CEF 加载期间（每次 `restart custom-phone` 后）帧被静默丢弃，Lua 侧 `isPhoneOpen=true` 但屏幕上没有界面；改为 `PhoneBridge.AwaitAck` 每 250ms 重发、NUI 回 `phoneOpenAck` 才停，2.5s 无回执则复位半开状态并提示
- `custom-phone`: `focusState` 诊断按来源 5s 限流，同一次打开的 `open-nui-sent`/`open-ack` 互相吞掉，无法区分「NUI 未应答」和「焦点未生效」；改为按 phase 单独限流
- `custom-phone`: appQuery/appAction 预算拆成 120/min burst 40 与 30/min burst 10 后，单元测试仍按 burst 10 断言；测试对齐真实预算并覆盖 action 桶独立耗尽
- `custom-phone`: 移除 appQuery 逐请求调试 `print`，handoff 追踪改由 `appQuery-hit`/`appAction-hit` 诊断阶段承担
- `custom-director`: `police_run_e2e` 调用的 `custom-agent-ops` 只在 `configs/modules/dev.cfg` 启动，FIT-10 导出门禁红；登记为 deferred repo 资源（未启动时动作返回 `execution_failed`，不影响正常流程）
- `custom-quest`: 服务端重启后 `QuestCache` 未从 DB 预加载，`step_decision` 重连不弹窗；改为 `QBCore:Server:PlayerLoaded` 预加载 + `/questrestore`
- `story-engine`: decision NUI 增加焦点/`keepInput` 遥测、300s 看门狗、`SetNuiFocusKeepInput(false)`，避免重连软锁与手机 UI 抢焦点
- `core-framework` 引用了不存在的 `cache/*.lua`，导致自身及 9 个下游资源无法启动
- 启动顺序与 `fxmanifest` 依赖冲突（11 处）；补齐 `qb-prison`、`qb-minigames`、`safecracker`
- `custom-quest` / `custom-taxes` / `core-framework` / `qb-recyclejob` 缺少 manifest 里声明的 @oxmysql/lib/MySQL.lua
- qb-core 无定时刷盘：补 15min tick + `onResourceStop`；断线位置回退，避免写 `0,0,0`
- 任务冷却异步查询导致永久失效；改为内存权威 + 登录回填
- `core_economy` 未定义 `EconomyService`；市场/卡特尔卖货扣物不付钱
- 剧情登录事件名错误（`QBCore:Server:OnPlayerLoaded` → `PlayerLoaded`）
- 组队任务双重抢锁、`RemoveGroupMember` 错误 key、断线不释放锁
- 接新任务覆盖活跃任务缓存；步骤尝试次数不重置
- 任务完成奖励幂等：`CompleteQuest` 回调只看 affectedRows，内存锁 + 10s 超时兜底，避免重复发奖
- 地址池任务步骤顺序绕过：缓存空窗期改用 `_currentSteps` 内存步骤比对，不再直接放行
- Bus 跨资源调用：7 个注册方 manifest include @core-framework/bus.lua，cartel/mining/justice 共 18 处改为显式 `service_*` export
- `T-CityLite.base/resources/[standalone]/core-framework/compat.lua`: `GetPlayer` 缓存改用 `GetPlayerName` 做活性校验（`GetPlayerPing >= 0` 恒真）
- `txAdminPort 0` 禁用管理员模式，避免端口冲突

### Changed
- `server.cfg.template` 按依赖图重排：`core → career → player → voice → custom → quest → police → vehicles → jobs → banking → medical → economy → security → crime → story → atmosphere → admin`
- `custom-quest` 从 `custom.cfg` 移到 `quest.cfg`；`custom-justice` 移到 `police.cfg`；`progressbar` 提前到 `player.cfg`
- `custom-testing` 从 `custom.cfg` 移到 `dev.cfg`（生产默认不加载）
- CI 增加 `check_bus_wiring.py`，防止注册方再次漏 include `bus.lua`

---

## [0.7a] — 载具重构与物流 — 2026-10-21

> 代码完成于 2026-06-22，tag 于 2026-10-21；实机验收仍待完成。

### Added
- **custom-vehicles**：替换 `qb-vehiclekeys`，事件驱动钥匙/锁车/共享，O(1) 内存缓存，兼容旧 exports/events；含安全带、巡航、转向灯、氮气、车辆损耗
- **tcity-dashboard v2.1**：Vue 3 车载中控屏，6 类载具模板，警用控制台 / ANPR / 雷达 / 追踪 / CCTV
- **custom-quest**：数据驱动任务状态机、外部脚本 API、安全门控、DB 持久化（v0.6 基础设施）
- **story-engine**：决策树与玩家选择追踪
- **物流任务模板**：`quest_logistics` 取货 → 运输 → 交付，含车辆/到达/货损校验
- **GitHub Actions CI**：CFG 完整性 + Lua 语法 + 依赖图 + pytest + oxmysql JS + MariaDB schema
- **运行时构建产物入库**：oxmysql `dist/web`、menuv `dist`、tcity-dashboard `nui/dist`
- **custom-ui**：统一 NUI 焦点、关闭后 300ms 防误触、距离校验；车店/车库/qb-menu/手机/中控屏接入
- **NUI 无头冒烟**：Playwright 覆盖车店 / 中控屏 / 车库 / 手机四个页面
- 开发工作流指南（`T-CityLite.base/docs/archive/dev-workflow-guide-2026-06-01.md`）与一键启动脚本

### Changed
- **qb-vehicleshop Phase 1–5**：`while insideShop` 轮询改事件驱动；`finance.lua` 拆分为 lifecycle + payments；NUI 模式接通；客户端 Bus 注册；试驾独立车牌与钥匙清理
- `vehicles.cfg` 启用 `custom-vehicles` + `tcity-dashboard`，停用 `qb-vehiclekeys`

### Fixed
- **qb-garages**：SELECT 查询从 `rawExecute` 改为 `query/single`，并补充空车库诊断
- **qb-vehicleshop NUI**：加载顺序与 ConVar 同步修复
- **custom-taxes**：为未实现的车辆税 / NPC 定价补桩，避免调用报错
- **菜单交互**：车店改为按 E 主动打开（3.5m 距离），服务端购买距离 8m/30m；关闭菜单不再误触攻击
- **车店购买**：Processing/错误态 + 2s 防连点；Change Vehicle 不再跳 qb-menu
- **车库**：修复 NUI 回传 vector4 丢失导致的 spawnPoint nil；spawn 被拒时不再死循环；开发期共享车库
- **手机**：qb-phone 式 keepInput + DisableDisplayControlActions；状态栏/主时钟统一游戏时间
- **测试夹具**：对齐 `LocalDirtyFlush` 与 oxmysql `insert` 回调契约；测试路径改为相对仓库根目录
- **DB schema 测试**：兼容 MariaDB（JSON=LONGTEXT、ENUM 默认值引号、COLUMN_KEY）；新增 `v2.2_schema_reconcile.sql` 补齐 story-engine 索引
- `txAdminPort 0` 禁用管理员模式，避免端口冲突

### Testing
- `pytest tests`：**426 passed**（含 MariaDB schema；无 DB 连接时 286 passed / 132 skipped）
- oxmysql JS 单测：**148 passed**
- NUI 冒烟：**4/4 passed**（Playwright Chromium）
- 游戏内 `/test run all`：**298 PASS / 0 FAIL / 9 SKIP**（有玩家上下文；无玩家时 225 PASS / 8 SKIP；见 `docs/v0.7a-acceptance-report.md`）
- 离线检查：CFG / 依赖图 PASS；`light_lint` 仍为 advisory（vendor 资源遗留 ~250 条 `Wait(0)` / `MySQL.Sync`）

### Known
- 车店 NUI、车库、物流任务尚未完成真人客户端验收
- 8 个手机用例需要真实玩家上下文（无客户端环境会 SKIP）

---

## [0.6.0] — 核心架构安全与性能加固 — 2026-06

### Security
- **SQL 注入修复**: `qb-management` `sv_boss.lua` + `sv_gang.lua` 的 `LIKE '%jobname%'` 拼接改为 `JSON_EXTRACT` 参数化查询
- **弃用事件硬拒绝**: `QBCore:Server:UseItem` / `RemoveItem` / `AddItem` 从"打印警告+放行"改为"安全日志+拒绝执行"
- **SecurityService 集成**: `AddMoney` / `RemoveMoney` / `SetMoney` / `SetJob` / `SetGang` 全部接入 `Bus.SecurityService` 校验层（source 验证 + 输入清洗 + 阈值熔断）
- **qb-banking Rate Limit**: withdraw / deposit / transfer ×4 回调添加 2 秒冷却防刷
- **compat.lua 缓存加固**: `GetPlayer` 缓存添加 `GetPlayerPing >= 0` 活性校验，消除幽灵对象风险

### Changed
- **DirtyFlush 管道集成**: `QBCore.Player.Save()` 从直接 SQL 改为 DirtyFlush 代理——非强制存盘仅标记脏数据，批量定时落盘（默认 15 分钟），IO 削减 ~66%
- **ForceFlush 去循环**: `DirtyFlush.ForceFlush` 改为直接 SQL 写入，避免 `Save → ForceFlush → Save` 循环
- **hunger/thirst 优化**: `SetMetaData` 中饥饿/口渴不再标记 `IsDirty`，消除每 5 分钟全字段 UPDATE
- **qb-houses 死循环消灭**: 7ms 轮询改为一次性加载后线程退出
- **qb-vehicleshop 异步化**: `playerDropped` + `removePlayer` 中的 `.await` 改为异步回调
- **qb-phone 缓存层**: 新增 `PhoneCache` + GetInvoices 异步化 + mail 缓存失效

### Documentation
- 新建 `docs/bus-api-reference.md`，完整记录 Economy / JobService / SecurityService / PersistenceService / DirtyFlush 接口

---

## [0.5.0] — 犯罪玩法系统 — 🚧 开发中

### Added
- `custom-crime` 资源（犯罪逻辑服务端）
- `custom-main` 集成犯罪事件处理（server/crime.lua）
- 模块化 CFG: `configs/modules/crime.cfg`

---

## [0.4.0] — 自研手机系统 — 2026-06-01

### Added
- **自研手机系统** (`custom-phone`): Svelte + Vite + TypeScript 构建，Phone-First 架构
  - 前端 gzip 仅 42KB（远低于 250KB 目标）
  - 应用: Banking / Contacts / Messages / CityFeed / JobBoard / FactionChannel / Garage / Hotlines / Notifications / PhoneCall
  - 领袖应用: GangBossApp / MayorApp / SheriffApp
  - `PhoneShell.svelte` 统一 UI 壳
  - `T-CityLite.base/resources/[custom]/custom-phone/web/src/stores/phone.ts` 状态管理 + `T-CityLite.base/resources/[custom]/custom-phone/web/src/utils/nui.ts` NUI 通信层
- **数据库表自动创建**: `phone_messages`, `phone_contacts`, `phone_cityfeed`, `phone_jobboard`
- 服务端子模块: `banking.lua` / `faction.lua` / `jobboard.lua` / `main.lua`

### Security
- **H1 RED**: `completeJob` 守卫条件修复 — 跳过 career-tag 直接完成 open 任务
- **H2 RED**: `bankTransfer` 离线转账竞态条件 — `JSON_SET` 原子操作
- **H3 RED**: `shareContactNearby` 输入校验 — name≤30 + number≤15
- **M4 YELLOW**: `postJob` 奖励上限 $50,000
- **M5 YELLOW**: `bankTransfer` 单笔上限 $100,000
- 全文件乱码 emoji 修复

### Testing
- `08_phone_test.lua`: 23 占位 → 38 真实断言
- 覆盖 10 组: UI / DB / API / 消息 / 联系人 / 银行 / JobBoard / 安全 / 事件 / 架构

### Documentation
- `docs/v0.4-validation-plan.md`
- `docs/v0.4-joint-test-scenarios.md`
- `docs/v0.4-nui-standard.md`

---

## [0.3.0] — 基础设施层 — 2026-05

### Added
- **统一经济出口** (`custom-economy`): 所有资金变动通过 `AddScaledMoney`，Convar 热调节
- **安全防火墙** (`custom-security`): Rate Limit、距离校验、服务端事件拦截、Discord 审计日志
- **审计日志** (`custom-logs`): 结构化日志记录
- **多标签职业** (`custom-career`): 支持多职业切换
- **管理面板** (`custom-admin`): 服务端命令集
- 模块化 CFG: `economy.cfg` / `security.cfg` / `career.cfg` / `admin.cfg`
- `docs/v0.3-technical-manual.md` / `docs/v0.3-banking-refactor.md` / `docs/v0.3-test-checklist.md` / `docs/v0.3-test-manual.md`

### Testing
- 双层自动化测试框架 (`custom-testing`):
  - 离线 Python 检测: `check_cfgs.py` / `check_lua_syntax.py` / `check_db_schema.py` / `check_dependencies.py`
  - 游戏内测试框架: `test_runner.lua` + `mock_events.lua`
  - 9 个测试套件，118 个测试用例

---

## [0.2.0] — 基础 RP 模块 — 2026-05-28

### Added
- **职业系统**: `qb-management`（帮派/企业管理）
- **银行系统**: `qb-banking`
- **警察系统**: `qb-policejob`
- **医疗系统**: `qb-ambulancejob`
- **载具系统**: `qb-fuel` / `qb-vehiclekeys` / `qb-garages`
- **进度条**: `progressbar`
- 模块化 CFG: `jobs.cfg` / `banking.cfg` / `vehicles.cfg` / `police.cfg` / `medical.cfg`

### Fixed
- **pma-voice OneSync 依赖**: `server.cfg` 添加 `set onesync on`，解决语音系统启动失败

### Changed
- 启动加载保持模块化 `exec configs\modules\*.cfg`；`ensure [qb]` 保持禁用

### Gameplay
- **通缉等级警察接管系统** (`custom-main`):
  - 原生 GTA 通缉等级 ≥3 时自动清除 NPC 警察，移交追捕给玩家警察
  - 全服调度警报 + 持久化 metadata + 雷达三角定位红点（每 8 秒刷新）
  - `/clearwanted [id]` 警察命令
  - 本地平民 NPC 恐慌系统：行人尖叫逃窜、司机猛踩油门（25 米范围内）
- **自定义 Duty 切换命令**: `/duty` 快速切换执勤/下班，无需前往物理标记点

### Fixed
- Svelte UI 移除 "Order Physical Debit Card" 按钮（借记卡/ATM 已禁用）
- NUI 共享用户列表 bug 修复：`openBank` / `openATM` 回调中 `users` JSON 字符串解码为 Lua table

### Documentation
- `docs/v0.2-maintenance.md` / `docs/v0.2-test-checklist.md` / `docs/v0.2-master-test-manual.md`
- `docs/v0.2-wanted-handover-technical-memo.md` / `docs/v0.2-wanted-handover-test-guide.md`
- `docs/v0.2-status-persistence-technical-memo.md`
- `docs/v0.2-database-performance-maintenance-guide.md` / `docs/v0.2-hospital-optimization-guide.md`

---

## [0.1.0] — 精简启动链 — 2026-05-28

### Added
- 基于 `QBCore_CDB34E.base` 创建 Lite 版本
- **14 个模块化 CFG 启动体系**，废除 `ensure [qb]` 粗粒度加载
- 核心模块: `oxmysql` / `qb-core`
- 玩家流程: `qb-menu` / `qb-input` / `qb-target` / `PolyZone` / `qb-multicharacter` / `qb-spawn` / `qb-apartments` / `qb-interior` / `qb-clothing` / `qb-inventory` / `qb-weapons` / `qb-hud` / `qb-weathersync`
- 语音: `pma-voice`
- 自定义资源: `custom-main`

### Fixed
- **Spawn Death Prevention**: `custom-main` 实现自动血量恢复和复活回退系统（`qb-ambulancejob` 禁用时防止玩家出生即死亡）

### Infrastructure
- 依赖例外发现并添加: `PolyZone` / `qb-interior` / `qb-clothing` / `qb-weapons`
- 禁用资源追踪: `disabled-resources-v0.1.md`
- `server.cfg.template` 模板配置
- `docs/v0.1-maintenance.md`

### Testing
- 基础客户端测试通过
- 重连持久化验证通过

---

[0.7a]: https://github.com/wenkais196-Gabriel/T-City/releases/tag/v0.7a
[0.6.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/wenkais196-Gabriel/T-City/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/wenkais196-Gabriel/T-City/releases/tag/v0.1.0
