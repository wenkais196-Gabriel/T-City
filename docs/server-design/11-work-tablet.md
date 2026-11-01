---
id: server-design-11-work-tablet
type: spec
status: active
system: ux
owner: hermes
updated: 2026-10-26
review_by: 2027-04-30
---

# 11 · 工作平板：一台设备的两种形态

> **状态**：P1–P4 已落地并通过线上重启（2026-10-26）。
> 设计 demo（可点）：`assets/11-tablet-demo.html`，截图 `11-tablet-home.png` / `11-tablet-mdt.png` / `11-tablet-mechanic.png`。
> **实现截图**：`assets/11-tablet-impl.png`（真实构建产物，平板形态三栏：单位 300 / 接警 348 / 详情 344）。

## 1. 命题

手机和平板**不是两台设备**，是同一套 App 的两个 surface：

| | 手机（phone） | 平板（tablet） |
|---|---|---|
| 尺寸 | 375 × 780 竖屏 | ~1034 × 676 横屏 |
| 位置 | 右下角（不挡视野） | 视角中央（挡视野） |
| 排布 | 单列堆叠 | 2–3 栏并存 |
| 打开时 | 可以边跑边看一眼 | 站定才能用（锁移动） |
| App 集合 | 同一份 `audience` 下发 | 同一份 |

差异只允许出现在**外壳**与**排布**两层。数据、命令、权限判定完全共用——
这一条决定了它是一件事还是两件事。

## 2. 现状（为什么说已经成立了一半）

- **App 注册与职业门控已经存在**：`server/phone_apps.lua:39` `audienceAllows`，
  `:74` 注册时收 `audience`，`:87` 按下发清单过滤，`:108` 禁用时返回 `app_forbidden`。
  `server/apps/police_mdt.lua:74` 写 `audience = { jobs = { 'police' } }`，
  `server/apps/quests.lua:37` 写 `audience = {}`（全职业）。
  → demo 里"全职业可用、软件按职业下发"不是新设计，是既有规则。
- **外壳是唯一需要改造的地方**：`web/src/components/PhoneShell.svelte:82`
  `position: fixed; right: 30px; bottom: 30px; 375 × 780`，带刘海、边框、下滑入场。
- **焦点已经是有主的栈**：`client/core/focus.lua:69` owners 栈、`:79` Acquire、
  `:101` Release、`:122` Reset。互斥不该新造机制，应该复用这套。
- **单一入口**：`web/src/App.svelte:242` `{#if $isPhoneOpen}`，状态在
  `web/src/stores/phone.ts:7-8`（`isPhoneOpen` / `activeApp`）。
- **退出兜底已存在**：`client/main.lua:838` `onResourceStop` → `PhoneFocus.Reset()`。

## 3. 已拍板

1. **同一台设备两种形态**：一个物品/一个入口，surface 由窗口尺寸与玩家偏好决定，
   不是"手机 + 平板两个物品"。
2. **平板打开时锁定移动**：居中全屏面板不能边跑边看。手机不锁。

## 4. 四条不变量（比功能更重要）

1. **同一时刻只有一个 surface 在前台。** 复用 `PhoneFocus` 的 owner 栈：
   `acquire('phone'|'tablet')`，开第二个前必须先释放第一个。
2. **一个 app 只有一个组件。** 禁止 `PoliceMDTTablet.svelte` 这类分叉；
   排布差异由 pane 契约表达，surface 决定横排/竖排。
3. **判定不下放。** `allowed_actions` 仍由服务端算，surface 只决定摆哪儿。
4. **surface 不放大权限。** 平板看得更宽 ≠ 看得更多；右栏只能放调用者本就有权看的东西。

## 5. 方案结论（三块并行细化后合并）

### A. surface 层

| 决定 | 结论 | 理由 |
|---|---|---|
| 组件 | 一个 `DeviceShell.svelte`，`surface` 是 prop | 唯一挂载点（`App.svelte:242`），context 会给同一个值开第二条投递路径且 Svelte 5 不自动响应 |
| 类型 | `surface.ts`（custom-phone 的 web/src/core 下，零依赖叶子） | 放 store 会让 settings 反向依赖数据 store |
| 谁决定 | **Lua 纯函数** `SurfaceRules.Decide()` | keepInput 是 focus 的一部分，必须在打开这一刻定；NUI 在 CEF 加载期还收不到消息 |
| 优先级 | 入口 > 来电 > 载具 > 玩家偏好 > 窗口(≥900×560 且横向) > 默认 phone | 来电/载具强制小窗：整屏+锁移动不能边开车边接电话 |
| 互斥 | `Surface` 里一个 `current`，切换先 `Release` 再 `Acquire` | focus 栈按 owner 名去重；两个不同 owner 会同时留在栈里，出现"关不掉" |
| 锁移动 | 逐帧 `DisableControlAction` 30–35 | `SetPlayerControl(false)`/`FreezeEntityPosition` 是粘性状态，循环一死人就永久钉住 |
| 失败出口 | ack 超时 / 心跳丢 / 焦点被抢 / ped 死亡 / 资源停止 / `/phonefix` → 全部走同一个 `Surface.Reset() + DeviceLock.End()` | 焦点没了但人还钉着是最难查的故障 |
| 外壳差异 | 手机：右下角 375×780 + 刘海 + 侧键 + 手势条；平板：居中 1034×676 + 状态栏「主页/关闭」 | 平板没有电源键，必须有看得见的关闭入口 |

### B. pane 契约

- **只有 5 个 app 真有"主从/并存"信息**：Messages、PoliceMDT、Hotlines、Quests、Banking（勉强）。其余 12 个加栏只会得到空右栏——**内容多靠滚动和分组解决，不构成加栏理由**。
- 契约写在 `web/src/apps/contracts/<id>.panes.ts`（`PANE_CONTRACT`），组件 import 它 → 单一来源，且静态闸门有锚点。
- 两种形态，不发明第三种：`drill`（手机上主从互斥、平板并存，如 Messages）与 `flow`（手机不动、平板加一栏，如 MDT/Quests）。
- 降级阶梯写死：宽度 < `stackBelow` → 单栏；装不下先摘 `collapsible` 的 pane；只允许一次降级。
- 首批：**PoliceMDT（只动 dispatch 页）→ Messages（两栏）→ Quests（两栏）**。行内「前往/清场」**不搬走**——右栏是"加一栏"不是"搬一栏"，巡逻时一击不能变两击。
- Messages 平板上**不许自动选第一个会话**：`openThread` 会 `markMessagesRead`，自动选中等于"推开平板就清空未读"。
- Quests 的 `detail` query 服务端早就有（`server/apps/quests.lua:49`），只是没人调——不新建数据模型。

### C. 测试与闸门

- NUI 套件按 surface 参数化：同一套 spec 跑 375×780 与 1034×676 两遍；**游戏窗口视口固定 1920×1080**，设备盒才是被断言的对象（否则"右下角/居中"不可观测）。
- 核心一致性断言：**同一交互脚本在两种形态下发出的 appQuery/appAction 集合必须完全相等**（`tabletOnly` 初始为空集）。这是"不慢慢长成两个产品"的硬指标。
- 三个新闸门：① 禁止分叉组件（`*Tablet.svelte` / 就近重复）② 每个注册 app 必须有 pane 契约且 DOM `data-pane` 与契约双向相等 ③ surface 不得放大权限（服务端零 `surface`、取数不得被 surface 包裹、平板额外能力必须在服务端注册且带守卫）。
- 锁定移动只能测"结构 + 协议"（锁集合 ⊇ 30–35、有退出条件、关闭路径调 `DeviceLock.End()`），**不能测**控制是否真被禁；那一条进人工验收清单。
- 预算：架构规则 258 / 未证明 165 **零余量**，新规则必须自带反向校验才不顶红。所以本轮的 surface 测试先落在 `tests/unit/layer3_business/`（不计入预算），提升为架构闸门时再按"规则 + 反例 + 控制注入"三件套补账。

## 6. 施工顺序

| 阶段 | 内容 | 状态 |
|---|---|---|
| P1 | `DeviceShell(surface)` + 预设表 + 保留 `.phone-wrapper` 选择器 | ✅ 已落地 |
| P1 | `surface_rules.lua` / `surface.lua` / `device_lock.lua` + 优先级 + 锁 + 失败出口 | ✅ 已落地 |
| P1 | NUI 上报视口、读 Lua 下发的 surface、`reason=switch` 不丢当前 app | ✅ 已落地 |
| P1 | 双形态 NUI 场景（几何、刘海/手势条差异、关闭只发一次） | ✅ 13/13 |
| P2 | pane 契约 + `PoliceMDT` dispatch 三栏（pilot） | ✅ 已落地：`police_mdt.panes.ts` 契约，units/incidents/detail 三栏，详情栏只在 grid 渲染；行内「前往/清场」保留（巡逻时一击不变两击） |
| P3 | `Messages` 两栏、`Quests` 两栏 | ✅ 已落地：Messages 用 drill（手机二选一、平板并存，且**不自动选会话**——那会清未读）；Quests 用 flow（手机不动、平板加详情栏，列表收窄） |
| P4 | 三个架构闸门（分叉 / 契约 / 权限）+ 双视口参数化 | ✅ 已落地：`tests/architecture/test_surface_contracts.py` 三条，各自带反向注入；NUI 16 场景含 parity（两种形态 app 请求集合必须相等） |

## 7. 已验证

| 项 | 证据 |
|---|---|
| 两种形态同屏行为 | NUI 16/16：手机右下角 375×780 有刘海/手势条；平板居中 1034×676 无刘海、有关闭按钮；MDT 平板三栏 + 三列轨道；手机一次只显示一栏 |
| 形态切换不丢上下文 | `phone:close` 带 `reason='switch'` 时不清 `activeApp` |
| 一致性 | parity 场景：同一交互在 375 与 1034 下发出的 `appQuery/appAction` 集合**完全相等** |
| 权限不放大 | `TABLET_GRANTS` 三个契约全为空；闸门禁止服务端读 `surface`、禁止 app 自己判断形态 |
| 单组件 | 闸门 A：出现 `*Tablet.svelte` 或相似度 ≥0.9 的改名副本即红 |
| 双视口参数化 | NUI runner 对每个场景在手机和平板各跑一遍；与 pane 无关的 app（通知/急救）显式声明 `surfaces: ['phone']`，其余跑两遍 |
| 全部测试 | 1019 passed / 132 skipped；架构规则 261（已证明 96 / 未证明 165 不变） |

未做（有意）：
- 其余 12 个 app 不加栏（内容多靠滚动与分组，不构成加栏理由）；
- 设置页的"形态偏好"入口（`Surface.SetPreference` 已就绪，UI 留到需要时）；
- 平板的中控/物品入口（demo 里标为未决，属玩法决策）；
- 锁定移动的真机验收（离线只能测结构，必须在客户端跑一次）。

## 8. 不做什么

- 不做"第二套 app 清单"。`audience` 是唯一真值源。
- 不做"平板专属功能"。平板只是更大的窗口。
- 不为单个 app 复制组件。
