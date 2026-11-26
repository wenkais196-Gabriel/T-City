---
id: ux-menu-system-design
type: spec
status: draft
system: ux
owner: hermes
updated: 2026-11-25
review_by: 2027-02-28
---

# 游戏内菜单系统：从五套并存收敛到一个契约 + 三个平面

> **一句话**：现在至少 **5 套菜单实现**（qb-menu / qb-input / menuv / custom-ui 栈 / 手机与看板 CEF）彼此没有共同契约，
> 焦点与控制各自抢、按键各写一套轮询、样式各复制一份。这份稿子给出**一个契约（MenuSpec）+ 三个平面**的收敛路径，
> 并切成 **7 个文件所有权互不重叠的分片**，供两个 agent 并行开发。
>
> 来源：Antigravity（`gemini-4-hydrogen-high`，`--mode plan` 只读取证）独立调研 + Hermes 抽样复核。
> 复核结果逐条标在 §2 / §9：**没核过的都写明没核过**。

---

## 1. 结论先讲

| # | 结论 | 依据 |
|---|---|---|
| 1 | **焦点必须收归一个 owner**（`custom-ui` 的 Input 栈），并把"开关判定"从恒假的原生换到自己的账 | §2 第 1 行；§3 不变量 |
| 2 | **菜单描述要收敛成一个 JSON-safe 的 `MenuSpec`**，Lua 闭包只留在本地 handler 表里，绝不进 JSON | §3 Q1 |
| 3 | **按键路径只有两条**：菜单未开走 `RegisterKeyMapping`（全局唯一表 + 250–300ms 边沿防抖）；菜单已开走单点 `IsRawKeyDown` 键泵 | §4 Q3 |
| 4 | **性能红线**：CEF 里不许 `backdrop-filter`、不许外链 CDN、不许逐帧 `SendNUIMessage`；Lua 里不许每帧 `DisableAllControlActions` | §5 |
| 5 | **不要统一 `qb-target` 的实体交互语义**，只把它接进焦点栈 | §6 四象限 |

---

## 2. 现状盘点

引用规模（两种口径都给，避免拿错数）：

| 实现 | 文件数（仅 .lua） | 文件数（全部类型） | 性质 |
|---|---|---|---|
| qb-target | 48 | 56 | 眼标轮盘 + 实体交互 |
| qb-menu | 33 | 37 | 传统列表菜单 |
| menuv | 12 | 17 | 第三方 OO 菜单库 |
| custom-ui | 12 | 15 | 自研 UI/焦点栈 |
| custom-prompt | 10 | 12 | 屏幕提示 |
| qb-input | 10 | 16 | 表单/对话框 |

> Antigravity 报的是 38/17/57/29/16/12（口径偏宽，`menuv` 把大小写与 dist 也算进去了）。
> 两种数都对，差在「按文件还是按匹配、是否含 html/js/dist」。**排期按 .lua 口径算改动面，按宽口径算风险面。**

| 面 | 载体 | 入口 | 焦点 | 性能风险 |
|---|---|---|---|---|
| qb-menu | CEF 列表 | `exports['qb-menu']:openMenu` / `showHeader` | 走 custom-ui 的 `OpenMenu`/`ApplyFocus` | 关闭跑 300ms 守卫线程；外链字体 |
| qb-input | CEF 表单 | `exports['qb-input']:ShowInput` | **绕过 custom-ui 直调原生** | 每次打开 `Wait(150)`；单参 `SetNuiFocus(false)` 易留半聚焦 |
| menuv（qb-adminmenu） | CEF Vue2 | `MenuV:OpenMenu` | **不调 `SetNuiFocus`**，靠 14 条全局按键映射 | 常驻 250ms 线程；`DisableAllControlActions(0)`；5 个 CDN |
| qb-target | CEF 眼标 | `LMENU` 按住 | 直调原生 + **用恒假的 `IsNuiFocused()` 判重** | 每帧 `DisableAllControlActions(0)` + 每帧射线 |
| custom-ui | 纯 Client Lua 栈 | `exports['custom-ui']:Push` | 栈顶 `ApplyFocus` 回调 | 栈非空时 `Wait(0)` 屏蔽 34 键；另有 1s 小地图轮询 |
| custom-prompt | CEF 提示 | `Show` / `SetContext` | 无焦点（纯展示） | `SetContext` 无去重 |
| custom-phone | Svelte 5 CEF | `/phone`、`/tablet` | `PhoneFocus` 委托 custom-ui | 开屏 + `PhoneNav.Tick()` 两条 `Wait(0)`；平板再叠 `DeviceLock` |
| tcity-dashboard | Vue3 CEF | `/dashboard` | 锁回调 | `backdrop-filter`；双 `keydown` |

---

## 3. 三个最痛的问题

### 3.1 焦点与开关判定分裂 → 跨资源叠窗、光标/视角锁死

- **现象**：手机开着仍能叠开目标盘；弹窗关掉后光标丢失或 WASD 冻住。
- **根因**：本 build 的 `IsNuiFocused()` / `IsNuiFocusKeepingInput()` **恒 false**，而 qb-target 仍拿它判重；
  同时 qb-input / qb-inventory / qb-hud / story-engine 绕过 custom-ui 直调原生，其中还有**单参** `SetNuiFocus(false)`；
  custom-ui 判跨资源关闭回调用的是 `type(current.close) == 'function'`，对 CfxLua 的函数引用表恒假。
- **不解决的后果**：无法建立单一仲裁，任何菜单切换都会互抢或泄漏焦点。

✅ **本行我复核过**：qb-input 的 client/main.lua 第 22/29 行是单参 `SetNuiFocus(false)`、第 42 行 `SetNuiFocus(true, true)`；
custom-ui 的 client/main.lua 第 278 行确为 `type(current.close) == 'function'`（且在 `esc == true` 分支内）；
qb-target 的 client.lua 第 293 行确以 `IsNuiFocused()` 作门卫、第 308 行确在 `Config.DisableControls` 时每帧 `DisableAllControlActions(0)`。

### 3.2 多套互相冲突的按键与控制通道 → 人按不动、误触发、重复绑定

- **现象**：开着菜单方向键不响应、一次按挪两格、连带触发车辆转向灯；重启后热键重复派发。
- **根因**：`keepInput=true` 下硬件按键既不到 CEF 也不到 172–175 控制组，于是分裂成三种读法
  （`IsRawKeyDown` 自轮询 / 全局 `RegisterKeyMapping` / CEF `onkeyup`），各端只好各自写防抖。
- ✅ **复核后的补充**：menuv 的"14 条全局映射"不是一个函数里 14 次 `RegisterKeyMapping`，而是
  **14 次 `MenuV:RegisterKey(...)`（7 键盘 + 7 手柄），最终都落到 menuv 的 menuv/menuv.lua 第 157 行那一次 `RegisterKeyMapping` 调用**。
  排期时按"14 个注册"算，别按"14 处调用点"算。
- **不解决的后果**：菜单描述统一了，键盘/手柄/Esc/车辆控制仍然打架并拖帧。

### 3.3 无共同契约与重渲染陷阱 → UI 碎片化、掉帧、重启级联

- **现象**：列表/表单/管理菜单在多套宿主重复实现；部分 NUI 打开掉帧；`restart` 依赖资源后菜单静默失效。
- **根因**：数据模型割裂（qb-menu 扁平数组 / qb-input 同步表单 / menuv OO / 手机 queries+actions）；
  三个资源用了 `backdrop-filter`（**本机实测帧率无变化，见 §10.3 第 6 条**；仍按 CEF 规范清理，但不再作为性能论据）；四个资源依赖外链 CDN；强依赖资源在 `restart` 后不被拉起。
- **不解决的后果**：每加功能继续复制样式/权限/回调，CEF 内存与帧耗时持续膨胀。

---

## 4. 目标架构：一个契约 + 三个平面

依赖方向 `P1（渲染）→ P2（焦点/输入）→ P3（服务端权威）`，三者都单向依赖 `P0（纯数据）`。

### 4.1 Q1 · `MenuSpec`（P0，JSON-safe）

| 层 | 必填 | 可选与语义 |
|---|---|---|
| `MenuSpec` | `id`, `title`, `surface: 'modal'|'drawer'|'form'|'phone_app'`, `items[]` | `subtitle`, `position`, `keepInput`, `allow: number[]`, `submitText` |
| `MenuItem` | `id`, `kind: header|action|submenu|checkbox|select|range|text|number|password|color`, `label` | `description`, `icon`, `disabled`, `hidden`, `value`, `default`, `min/max/step`, `options[]`, `required`, `intent: { target: client|server|command|submenu, event?, args? }` |

**硬规则**：Lua 闭包只进 P2 的本地 `handlers[menuId][itemId]`，**绝不进 JSON**——这是跨资源回调在 CfxLua 下失败的根因（函数引用是表）。

### 4.2 Q2 · 三个平面与焦点不变量

- **P1 统一渲染（新资源 `custom-menu`，Svelte 5 单页）**：按 `MenuSpec` 渲染列表/表单/滑块/确认；带 `openAck` 握手（复用手机已有的 `AwaitAck` 模式）；手机 `DynamicApp` 复用同款渲染器。
- **P2 唯一焦点仲裁（`custom-ui`）**，不变量五条：
  1. 除 `exports[owner]:ApplyFocus` 外，**任何脚本禁止直接调** `SetNuiFocus` / `SetNuiFocusKeepInput`；
  2. 开焦点严格 `KeepInput(keep)` → `SetNuiFocus(true, cursor)`；空栈释放先 `KeepInput(false)` 再 `SetNuiFocus(false, false)`，**每次显式传布尔**；
  3. 开关与互斥只读 `custom-ui:IsTaken()` / `Top()`，**禁止读恒假的原生**；
  4. 跨资源关闭走 `exports[owner]:ForceClose(frameId, reason)`，**不传 Lua 闭包**；
  5. `onClientResourceStop` 自动 `Pop` 该 owner 全部帧，防幽灵 `Wait(0)` 阻塞。
- **P3 服务端权威**：菜单动作一律服务端复验身份/职业/金额与限流；**不信任 P1 传回的 `hidden`/`disabled`**。

### 4.3 Q3 · 按键路径

| 状态 | 路径 | 必须的防护 |
|---|---|---|
| 菜单未开 | 游戏控制正常；热键走全局唯一 `RegisterKeyMapping` 表 | 入口先查 `not IsTaken() and not IsPauseMenuActive()`；**250–300ms 边沿防抖**挡重启重复绑定 |
| 已开 + `keepInput=true` | custom-ui 按 `BLOCKED_CONTROLS` 放行 `frame.allow`；Lua 单点 `IsRawKeyDown` + 手柄控制兜底（**不禁用 172–175**） | 打开瞬间预填 `rawPrev` + **250ms 启动宽限**（防开即关）；NUI 对同源键 **120ms 去重** |
| 已开 + 文本输入 | 键盘直达 CEF `keydown`；Lua 只刷 `rawPrev` 吃掉边沿 | 关后 **400ms 禁 199/200**，防弹出暂停菜单 |

---

## 5. Q4 · 性能边界

- **绝对不能进 CEF**：`backdrop-filter: blur()`、外链 CDN 字体/CSS、逐帧 `SendNUIMessage`、函数/元表字段。
- **绝对不能每帧跑**：`DisableAllControlActions(0)`、业务自建的 `Wait(0)` 距离轮询（未交互时退避）、同屏叠加多条 `Wait(0)`、
  循环内重复 `GetEntityCoords(PlayerPedId())` / `GetResourceState()`。

---

## 6. 复用四象限

| 象限 | 内容 |
|---|---|
| **直接复用** | 手机的 `AnswerFn` / `AwaitAck` / `Request` 桥、`surface.lua`、`panes.ts`、`appRegistry.ts`、custom-notify 页、`custom-vehicles` 转向灯（41–46 行） |
| **加适配层** | qb-menu（38 文件）→ `AdaptQbMenu(items)` 交给 `custom-menu`；qb-input（17 文件）→ `AdaptQbInput(d)` 走表单面；qb-inventory/qb-hud/story-engine 的裸 `SetNuiFocus` 与恒假判据换成 `custom-ui` 的 `Push/Pop/IsTaken`；custom-prompt 的 `SetContext` 补同内容去重；三个 `backdrop-filter` 资源删样式并合并重复 `keydown` |
| **需要重写** | ① `custom-ui` 栈边界（ForceClose / 资源停自动弹栈 / 单点键泵）② 统一 CEF 宿主 `custom-menu` ③ `qb-adminmenu` 迁出 menuv ④ `qb-management` 的 `cl_boss`/`cl_gang` 合并进 `cl_org` |
| **保持独立** | qb-target 的**实体交互语义**（眼标/距离/射线）不并入菜单层，只接焦点 |

---

## 7. 分片与文件所有权（并行开发用）

**任意两片的文件所有权不重叠**，两个 agent 可同时开工。

| 片 | 目标 | 拥有的文件/目录 | 依赖 | 验收判据 |
|---|---|---|---|---|
| **M1** | `custom-ui` 升级为唯一焦点栈 + 修跨资源关闭 + 接管单点键泵 | `T-CityLite.base/resources/[custom]/custom-ui/**`、`T-CityLite.base/configs/modules/core.cfg`、`T-CityLite.base/configs/modules/custom.cfg`、`T-CityLite.base/tests/architecture/test_input_layer_contracts.py` | 无 | `test_input_layer_contracts.py` 绿；栈非空时全客户端仅 1 条 `Wait(0)`，关闭后栈为空 |
| **M2** | 新建 P0 `MenuSpec` + 轻量 CEF 宿主 `custom-menu` | `T-CityLite.base/resources/[custom]/custom-menu/**`、`T-CityLite.base/configs/modules/player.cfg`、新增的 MenuSpec 单测（tests/unit 下的 test_menu_schema.py） | M1 | `npm run build` 退出 0，产物含 0 处 `backdrop-filter` / `https://` |
| **M3** | qb-menu / qb-input 零破坏适配，停用各自旧页面 | `T-CityLite.base/resources/[qb]/qb-menu/**`、`T-CityLite.base/resources/[qb]/qb-input/**` | M1, M2 | `luac5.4.exe -p` 全过；qb-input 不再有单参 `SetNuiFocus(false)` |
| **M4** | qb-target / qb-inventory / qb-hud / story-engine 接入焦点栈 | `T-CityLite.base/resources/[qb]/qb-target/**`、`T-CityLite.base/resources/[qb]/qb-inventory/**`、`T-CityLite.base/resources/[qb]/qb-hud/**`、`T-CityLite.base/resources/[custom]/story-engine/**` | M1 | 四目录内**门卫用途**的 `IsNuiFocused()` = 0（诊断用途逐条进 allowlist）；**菜单路径上**无 `DisableAllControlActions`（`noclip` / 死亡 / `spawn` 等合法调用点进 allowlist） |
| **M5** | 清 `backdrop-filter` 与重复监听（**排除 `[system]/monitor` 这个第三方面板**） | `T-CityLite.base/resources/[system]/tcity-dashboard/**`、`T-CityLite.base/resources/[qb]/qb-banking/**`、`T-CityLite.base/resources/[custom]/hud-position-tool/**`、`T-CityLite.base/tests/architecture/test_dashboard_focus.py` | M1 | 三资源源码与产物中 `backdrop-filter` = 0；看板构建成功；基线里 monitor 的 6 处**显式登记为排除项** |
| **M6** | qb-adminmenu 迁出 menuv + 冻结 menuv + 收敛 qb-management | `T-CityLite.base/resources/[qb]/qb-adminmenu/**`、`T-CityLite.base/resources/[qb]/qb-management/**`、`T-CityLite.base/resources/[standalone]/menuv/**` | M2, M3 | 除 menuv 自身外全仓 menuv 引用归 0；qb-management 仅留 `cl_org.lua` |
| **M7** | 收敛手机双 `Wait(0)` + prompt 去重 + 固化架构闸门 | `T-CityLite.base/resources/[custom]/custom-phone/**`、`T-CityLite.base/resources/[custom]/custom-prompt/**`、新增的菜单架构闸门（tests/architecture 下的 test_menu_architecture.py）、`T-CityLite.base/configs/boot.json` | M1, M2, M4, M5, M6 | 全量 pytest 绿；手机 NUI harness 通过；平板态仅 1 条屏蔽循环 |

---

## 8. 取证状态（谁核过什么）

| 论断 | 状态 |
|---|---|
| qb-input 直调原生 + 单参 `SetNuiFocus(false)` | ✅ Hermes 复核（第 22/29/42 行） |
| custom-ui 用 `type(current.close) == 'function'` 判跨资源关闭 | ✅ Hermes 复核（第 278 行，`esc` 分支内） |
| qb-target 用恒假 `IsNuiFocused()` 判重 + 每帧 `DisableAllControlActions(0)` | ✅ Hermes 复核（第 293 / 308 行） |
| menuv 14 条全局按键映射 | ✅ Hermes 复核（14 次 `RegisterKey` → 第 157 行唯一 `RegisterKeyMapping`） |
| 引用规模 49/33/12/12/10/10（.lua 口径） | ✅ Hermes 实测 |
| 手机 `keepInput` 下按键不进 CEF、`172–175` 轮询不到 | ⚪ 结构上已知（仓库文档与 skill 反复记录），本轮未真机复测 |
| `IsNuiFocused()` 恒 false 的原生返回值 | ⛔ 只能真机（需客户端进服采样） |
| 跨资源 `close` 回调的实机表现 | ⛔ 只能真机（进服开中控按 Esc） |
| 删 `backdrop-filter` 的帧率收益 | ⛔ 只能真机（需要性能采样） |
| 其余调用方逐行兼容性 | ⚪ 未逐行展开（引用文件数已核，行级未核） |

---

## 9. 下一步

1. 先定 **M1**（焦点栈）——它是所有片的前置，且单独上线就能止血「叠窗/光标丢失」。
2. **M2** 与 M1 可并行开工（文件不重叠），但 `custom-menu` 的渲染器要等 M1 的 `IsTaken/ForceClose` 契约定稿。
3. M3–M7 在 M1/M2 定稿后可以多片并行；每片的验收判据都是命令或计数，不依赖真机。
4. 真机项（§8 的 ⛔ 四条）攒成一次客户端验收，一次跑完。

---

## 9.5 跨资源 intent 契约（2026-11-26 真机定为硬约束）

**结论：intent 路由不许携带函数。**

真机证据（qb-menu 往 custom-menu 注册路由）：

| 调用形状 | 对面收到 | 结果 |
|---|---|---|
| `fn(id, route)` | `intentId` 是路由表 | `invalid_intent_id` |
| `fn(api, id, route)` | `intentId` 正确，`route.handler` 为 nil | `client_route_requires_event_or_handler` |

两条合起来只解释得通一种模型：exports 代理**吃掉第一个实参（self）**，且**表跨资源被序列化复制，函数字段变 nil**。所以 `type='client'` 的 `handler`、`type='submenu'` 的 `builder` 只能同资源使用（custom-menu 自己的 `/cmenudemo` 就是这样）。

跨资源回调统一走新路由：

```lua
-- 注册方（qb-menu / qb-input）
exports['custom-menu']:RegisterIntent('qb-menu:<owner>:item', {
    type = 'resource',          -- 只有字符串
    resource = 'qb-menu',
    method = 'MenuIntent',
})

-- 分发方（custom-menu）→ 调对方导出，参数只有 intentId + JSON-safe ctx
exports['custom-menu']:RegisterIntent(...)  -- 内部：exports[route.resource][route.method](intent, ctx)
```

- 导出返回值 `{ ok = false, reason = ... }` 表示动作被拒；`{ ok = true, spec = <MenuSpec> }` 表示子菜单，宿主压栈 + `menu:update`（`dispatched` 归一为 `submenu`）。
- 闸门：`test_intent_routes_rejects_function_fields_and_non_resource_types`（带自证：把带闭包的路由喂进校验器必须被识别）。
- 教训：**测试替身必须复刻真机的限制**。沙箱里函数能过资源边界，所以这条缺陷在单测里完全隐形。

## 10. 取证结果（排期前实测，2026-11-25）

基线由 `tools/dev/menu_surface_census.py` 生成，落在 `T-CityLite.base/tests/architecture/menu_surface_baseline.json`（12 类、1560 处命中）。
**这是取证，不是闸门**：M1–M7 每落地一片，这个基线该变小；M7 的闸门拿它当棘轮。

| 类别 | 命中数 | 涉及资源数 | 主要资源（命中数） |
|---|---|---|---|
| `setnui_focus` | **197** | 28 | qb-minigames 26 / story-engine 23 / custom-phone 15 |
| `setnui_single_arg`（单参 `SetNuiFocus(false)`） | **8** | 6 | monitor 2 / qb-input 2 / qb-menu 1 |
| `isnuifocused_read` | **34** | 8 | custom-phone 18 / story-engine 8 / qb-inventory 2 |
| `disable_all_controls` | **10** | 6 | qb-adminmenu 5 / qb-spawn 1 / qb-target 1 |
| `backdrop_filter` | **24** | 9 | monitor 6 / qb-banking 5 / tcity-dashboard 4 |
| `cdn_ref` | 829 | 35 | `[system]` 429 / monitor 130 / qb-hud 42（多为 vendor 与注释） |
| `qb_menu_entry` | 145 | 20 | qb-management 22 / qb-mechanicjob 19 / qb-vehicleshop 14 |
| `qb_input_entry` | 19 | 7 | qb-mechanicjob 5 / qb-vehicleshop 4 / qb-pawnshop 3 |
| `menuv_entry` | 53 | 2 | menuv 29 / qb-adminmenu 24 |
| `customui_entry` | **16** | 7 | tcity-dashboard 4 / custom-ui 3 |
| `orgmenu_export` | **8** | 1 | qb-management（`cl_boss` / `cl_gang` / `cl_org` 三套并存） |
| `client_wait_zero` | 217 | 48 | qb-core 21 / monitor 15（宽口径，只作风险参考） |

### 10.1 取证改掉了方案里的四个错判（这是本轮最重要的产出）

| # | 原方案 | 实测后必须改 | 依据 |
|---|---|---|---|
| 1 | M5 把 `backdrop-filter` 清零 | **必须显式排除 `[system]/monitor`**（第三方管理面板的打包 CSS/JS，24 处里占 6 处），否则闸门永远红 | 基线 `backdrop_filter.resources.monitor = 6` |
| 2 | M4 把 `DisableAllControlActions` 清零 | **不能清零**：`qb-adminmenu` 的 noclip、`qb-ambulancejob` 的死亡态、`qb-spawn` 都是合法用法。规则要改成「**菜单路径上不许每帧调用**」，并用 allowlist 点名合法调用点 | 基线 10 处分布在 6 个资源，含 `noclip.lua` / `dead.lua` |
| 3 | M4 把 `IsNuiFocused()` 清零 | **不能清零**：`custom-phone` 的 18 处里含诊断用的读取，不是门卫。要做的是「**门卫用途**清零 + 诊断用途进 allowlist」 | 基线 `isnuifocused_read` 8 个资源 34 处 |
| 4 | M1 只改 5 个资源就完成焦点收编 | **`SetNuiFocus` 有 197 处在 28 个资源**：一片做不完。M1 必须先出**兼容层**（`custom-ui:ApplyFocus` 转发），让旧调用点不改也能跑；全量清扫拆成独立的棘轮任务 | 基线 `setnui_focus = 197 / 28 资源` |

### 10.2 仍然没证的（只能真机）

| 项 | 前置 |
|---|---|
| `IsNuiFocused()` / `IsNuiFocusKeepingInput()` 的原始返回值（项目内多处注释称恒 false） | 客户端进服 + 打开手机时读一次原生 |
| 跨资源 `close` 回调是否为 CfxLua 函数引用表（导致 `type()=='function'` 恒假） | 客户端进服 + 开中控按 Esc |
| 删 `backdrop-filter` 的帧率收益 | 客户端 + CEF 性能采样 |

这三条攒成一次客户端验收，不阻塞 M1/M2 开工（它们的验收都能离线判）。

### 10.3 真机读数（2026-11-25 晚，玩家实测）

| # | 场景 | 读数 | 结论 |
|---|---|---|---|
| 1 | Esc 关中控 / 手机 | 都能关 | `type(current.close)=='function'` 在这两条路径上**没有**阻断（或它们不走该分支）→ 该缺陷的真实影响面比原判小 |
| 2 | Esc 关 `/admin`（menuv） | **关不掉，且呼出游戏暂停菜单** | menuv 既不消费 Esc 边沿，也不屏蔽暂停菜单 → **M6 的直接证据** |
| 3 | 手机开着按 `Alt`（眼标） | 打不开 | qb-target 的手机互斥**有效** |
| 4 | 手机开着按 `I`（中控） | 提示「必须先关闭当前菜单」 | custom-ui 栈的互斥**生效** |
| 5 | 手机开着 `/admin` | **能叠开** | menuv 完全绕过 custom-ui 栈 → 焦点 owner 不覆盖它，**必须靠 M6 收编**，M1 兜不住 |
| 6 | FPS（中控 / 手机 开 vs 关） | **基本无变化** | `backdrop-filter` 的掉帧代价**在本机、本场景未复现** → §2 里「实机必掉帧」的说法不能作为排期理由 |

**这六条改了两处结论**：

1. **M6 从 P2 升到 P1**：障碍（admin 菜单）现在是**用户可见**的（关不掉 + 能叠在手机上 + Esc 呼出暂停菜单），不是架构洁癖。
2. **M5 的理由要改写**：`backdrop-filter` 保留清理（CEF 规范 + 128 处里含第三方 vendor），但**不再声称「实机必掉帧」**——
   本机实测无变化。若要为它排期，需要更硬的测量（CEF devtools 帧耗时采样），否则按"顺手清理"处理。

**顺带一条环境坑**：`/debugscreen` 与 `/watchscreen` 在 `configs/modules/dev.cfg` 里，**该模块不在默认启动集**，
所以第一次敲 `/watchscreen` 是「未知命令」。取证前先 `ensure custom-debug`；客户端 `print` 的输出去 **F8 控制台**看，不在聊天框。

### 10.4 取证第 1 项：`IsNuiFocused()` 是**活的**（原判被推翻）

`/watchscreen` 每 2 秒打印一次 `nuiFocus=<IsNuiFocused()>`，客户端日志（`FiveM.app/logs/CitizenFX_log_*.log`）实录 24 个采样点：

| 采样 | 场景 | `nuiFocus` |
|---|---|---|
| #1–#7 | 什么都不开 | **-1** |
| #8–#10 | 手机打开（日志同期出现 `[phone] GameTime=12:53`） | **1** |
| #11 | 手机关闭 | -1 |
| #12–#16 | 另一个界面打开 | **1** |
| #17–#24 | 全部关闭 | -1 |

**结论：`IsNuiFocused()` 在这个 build 上工作正常**——界面打开时返回真值，关闭时返回假值
（`-1` 是 `custom-debug` 里 `IsNuiFocused and IsNuiFocused() or -1` 这个写法的显示产物，不是原生缺失）。

**这一条推翻了两处既有判断**：

1. 设计稿原来写「qb-target 拿**恒假**的 `IsNuiFocused()` 当门卫」——**错**。
   `qb-target/client.lua:293` 的 `... or IsNuiFocused() or ...` 是**有效**门卫，玩家实测「手机开着按 Alt 打不开」正是它生效的证据。
   → **M4 不再需要"修恒假门卫"**，工作量与风险都下降。
2. 「`IsNuiFocused()` 读数不可信，所以只能读自己的账」这个论证的**前提不成立**。
   结论仍然成立，但理由要换：原生只反映**NUI 焦点**，不反映「栈里有菜单但没设焦点」的状态（menuv 就是这种），
   所以「读自己的账」的理由是**覆盖面**，不是「原生坏了」。

> 取证方法论记一笔：**代码事实**（谁调了谁）和**运行时事实**（原生返回什么）必须分开取证。
> 前者 grep 就能定，后者只能真机；把 grep 出来的调用点当成运行时行为，就会写出这种结论。

### 10.5 M1 的底座比预计厚：`custom-ui` 已经有栈

custom-ui 的 client/main.lua 已导出（第 382–395 行）：

```
ApplyFocus / OpenMenu / CloseMenu / GuardControls / IsMenuOpen
Push / Pop / Top / Path / IsTaken / Owns / ResetInput / RefreshFocus / FocusTrace / DistanceToCoords
```

**缺的只有三样**（M1 的真实工作量）：

| 缺口 | 现状 |
|---|---|
| `ForceClose(frameId, reason)` 跨资源关闭 | **不存在**（现在的关闭靠各资源自己调 `CloseMenu`） |
| `onClientResourceStop` 自动弹栈 | **不存在**（资源崩了帧会留在栈里） |
| 单点键泵（菜单开着时全客户端一条 `Wait(0)`） | **不存在**（`IsRawKeyDown` 零命中） |

所以 M1 的定位从「**建**一个焦点栈」改成「**收口**已有的栈 + 清扫 197 处回头路」。
这一点直接降低了 M1 的风险：不变量已经在代码里跑着，本片是补齐 + 上闸门。

### 10.6 止血垫片已落地（#353，先于 M1/M6）

真机那两条症状（叠窗 + `Esc` 呼出暂停菜单）在 M6 之前先修掉了，做法是给 `qb-adminmenu` 加一层垫片，
**不改 menuv 本体、不新增第二处 `SetNuiFocus`**：

| 动作 | 实现 |
|---|---|
| 打开前问栈 | `custom-ui:IsTaken()`，被占用则拒绝并提示「Close the current menu first」 |
| 入栈/出栈 | 打开 `Push('adminmenu')`；关闭、强制关闭、`onResourceStop` 都 `Pop`（`Owns`/`Path` 判幂等） |
| `Esc` | 只屏蔽暂停控制 `199/200`，用 `IsDisabledControlJustPressed` 消费；关闭后再挡 300ms，吞掉同一次按键 |

两个设计点值得记住：

1. **垫片要向栈认领帧但不按焦点**：注册一个 `ApplyFocus` 导出直接 `return true`。否则栈会自己按
   `SetNuiFocus`，把键盘从「没有 `ui_page` 的 menuv」手里抢走——菜单还在，键全不响应。
2. **`allow` 名单要放导航键**：menuv 走的是 `RegisterKeyMapping`（方向/确认/返回），把 172–177 / 186–189
   一起禁掉菜单就没法用；`allow` 只保留这几个，其余照禁。

存量 5 处 `DisableAllControlActions`（输入框循环 2、noclip 3）**没动**——那是 #346（M4）的账，
本片只加棘轮禁止新增。垫片本身 0 处。

垫片是**临时件**，M6 把 menuv 下线时随之一并删除（代码里已留 `M6(#348)` 标记）。

**真机验收（2026-11-25，玩家实测）**：两条全部通过 —— ① 手机开着 `/admin` 不打开并提示
「Close the current menu first」；② `/admin` 开着按 `Esc` 菜单关闭、**没有**呼出暂停菜单。
对照：手机开着按 `Alt` 打不开、按 `I` 提示必须先关当前菜单。

结论：`DisableControlAction(0, 199/200)` + `IsDisabledControlJustPressed` 足够拦住暂停菜单，
**不需要** fallback 到 `DisableFrontendThisFrame()` / `SetFrontendActive`。
同一轮玩家未报「方向键失灵」或「人物被冻住」，这两条按随主流程通过记录。
