---
id: client-phone-architecture
type: manual
status: active
system: comms
owner: hermes
updated: 2026-10-27
review_by: 2027-01-30
---

# 手机架构（目标态 v2）

> 原则：**模块化 / 高性能 / 可扩展 / 安全**。本文是目标架构与迁移边界；现有 UI 行为不变。

## 1. 分层

```
┌─────────────────────────────────────────────┐
│ UI Shell    路由 / 焦点 / 设计系统 / 全局 store │
├─────────────────────────────────────────────┤
│ App SDK     manifest + component + lifecycle  │
├─────────────────────────────────────────────┤
│ Transport   request_id / timeout / schema     │
├─────────────────────────────────────────────┤
│ Client Lua  bridge / focus / events / phone   │
├─────────────────────────────────────────────┤
│ Server      core (identity/notify/events/rl)  │
│             domains (contacts/messages/calls) │
│             apps (registry + MDT service)     │
└─────────────────────────────────────────────┘
```

## 2. 模块与职责

### Server core

| 模块 | 职责 | 不做什么 |
|---|---|---|
| `resources/[custom]/custom-phone/server/core/identity.lua` | `PhoneIdentity.Resolve/From/IsLeader` | 不查业务表 |
| `resources/[custom]/custom-phone/server/core/notify.lua` | 通知规范化、落库、单播推送 | 不决定业务 |
| `resources/[custom]/custom-phone/server/core/events.lua` | 统一 `phone:client:event` 通道 | 不写业务表 |
| `resources/[custom]/custom-phone/server/core/rate_limit.lua` | 通用 token bucket（NUI app/action/短信） | 不鉴权 |
| `main.lua` | 只做 wiring：回调注册、领域调用 | 不写大段 SQL |

### Server domains

服务端 domains 层（目标态）：contacts / messages / notifications / calls / cityfeed / hotlines / vehicles 各一个 domain 模块。
每个 domain 暴露函数（`List/Send/MarkRead...`），SQL 只在本域；main 只转发。

### Server apps

目标态的 registry（现为 `resources/[custom]/custom-phone/server/phone_apps.lua`）+ `resources/[custom]/custom-phone/server/apps/police_mdt.lua`。
App 只通过 registry 暴露 query/action；不直接注册 NUI 回调。

### Client

| 模块 | 职责 |
|---|---|
| `resources/[custom]/custom-phone/client/core/bridge.lua` | 注册 NUI callback、request_id、超时、错误归一 |
| `resources/[custom]/custom-phone/client/core/focus.lua` | 焦点栈 owner：phone / fingerprint / story / vehicle |
| `resources/[custom]/custom-phone/client/core/events.lua` | 订阅 `phone:client:event`，分发到 NUI |
| `phone` 模块（目标态） | 打开/关闭/动画/按键，调用 bridge/focus；当前实现在 `resources/[custom]/custom-phone/client/main.lua` |
| `main.lua` | 只做 wiring |

### Frontend

| 模块 | 职责 |
|---|---|
| `resources/[custom]/custom-phone/web/src/core/appRegistry.ts` | App manifest：id/label/icon/component/audience/schemaVersion |
| `resources/[custom]/custom-phone/web/src/core/request.ts` | 统一 `phoneRequest`：超时、错误码、schema 校验 |
| `App.svelte` | 只渲染 shell + 查 registry |
| `apps/*` | 只依赖 App SDK，不直接碰 window/fetch |

## 3. 关键契约

### NUI 请求

```ts
type PhoneResponse<T> =
  | { success: true; data: T }
  | { success: false; error: string; detail?: string };
```

- 每个请求带 `request_id`（客户端生成，服务端回传）；
- 默认 8s 超时；
- 所有 handler 必须返回，不返回视为协议错误；
- 错误码稳定、可本地化。

### 打开握手（open ack）

`SendNUIMessage` 是「发了就走」的：CEF 正在加载（`restart custom-phone` 之后必然发生）时帧被静默丢弃，Lua 侧以为手机已打开，屏幕上却没有界面。

```
OpenPhone() ─ SendNUIMessage(phone:open) ─┬─ 250ms 重发 ─┬─ ... 最多 2500ms
              (PhoneBridge.AwaitAck)      │              │
                                          │              └─ 超时：isPhoneOpen=false
                                          │                 + PhoneFocus.Release('phone')
                                          │                 + 聊天提示「界面无响应」
                                          └─ NUI 收到后 fetchNui('phoneOpenAck')
                                             → PhoneBridge.Ack('phone:open') 停止重发
```

- `phoneOpenAck` 是「界面真的存在」的唯一证据；没收到就复位半开状态，避免下一次按 M 被 `isPhoneOpen` 吞掉。
- 同一 name 再次 `AwaitAck` 会顶掉上一个循环（不会两个循环同时跑）；`ClosePhone` 里也 `Ack` 一次收尾。
- 诊断：`phone:server:focusState` 的 `open-nui-sent` / `open-ack` / `open-ack-timeout` 三个阶段按阶段单独限流（`FOCUS_COOLDOWN`），能区分「NUI 没应答」和「焦点没生效」。

### 统一事件

```lua
TriggerClientEvent('phone:client:event', src, {
  type = 'notification.new' | 'message.new' | 'money.update' | 'call.incoming' | ...,
  app_id = 'police_mdt' | nil,
  payload = {...},
  ts = os.time(),
})
```

过渡期同时发旧事件；App 迁移后删除旧事件。

### App manifest

```ts
interface PhoneApp {
  id: string;
  label: string;
  icon: string;
  component: Component;
  audience?: { jobs?: string[]; onduty?: boolean };
  schemaVersion: number;
}
```

## 3.5 NUI 应答通道与自证握手

### 应答通道不一定是 function

`RegisterNUICallback(name, function(data, cb) ... end)` 里的 `cb` 在本 build 上是
**可调用表**（`{ __cfx_functionReference = '<ref>' }` + `__call`）。所以：

- 禁止写 `if type(cb) ~= 'function' then return end` —— 那是静默丢弃应答，
  前端只会看到 9s 后的 `AbortError` → `query_failed` / `action_failed`；
- 所有回调统一走 `PhoneBridge.AnswerFn(cb)`，它按 function → `__call` 表 →
  `Citizen.InvokeFunctionReference` 的顺序取应答通道，取不到时返回 nil，
  `RegisterNui` 直接**不执行 handler**（宁可不跑，也不要跑一半）；
- 直连 `RegisterNUICallback` 的地方（`getPhoneData` 等）也要用同一套适配。

### 自证握手（每次页面加载一次）

`resources/[custom]/custom-phone/web/src/main.ts` 在挂载前做两件事，结果都投到服务端日志：

1. `nuiReady { build, host, href, parent }` —— 证明**跑的是哪个 bundle**、宿主名是否
   为 `custom-phone`、路由是否通。日志格式：`[custom-phone][nui-ready] src=.. build=.. host=.. parent=..`
2. **四段探针**：用一次真实 `appQuery`（`police_mdt/units`）走完整条链路，再回报
   `[custom-phone][probe] src=.. build=.. code=.. dur=..ms`。

判定：`code=ok` 且 `dur` 在百毫秒级 = 整条链路健康；`code=query_failed` + `dur≈9000ms`
= 应答没回到 CEF；只有 `nui-ready` 没有 `probe` = 探针请求自身卡住。这样
`restart custom-phone` 之后不需要人点，就能判断"改的东西到底生效没有"。

### 请求追踪（stage 0/3）

`resources/[custom]/custom-phone/client/core/diag.lua` + `resources/[custom]/custom-phone/server/core/diag.lua` 提供 `phone:server:diag` 通道：
NUI 传 `_diag.tid`（没有则由客户端生成），trace 的 tid **就是 request_id**，
服务端内存环记录 `Recv/Done` 作为 SR/SD 的唯一事实源，链尾按
`level2 / ≥400ms / 失败 / 前 3 次` 采样上报，服务端打印

```
[custom-phone][diag] src=4 tid=c00065e22664 kind=query app=police_mdt code=ok why=ok
  path=CR|CF|SR|SD|CP|CA break=none dt=0,0,134,134
```

6 个槽位对应 `NUI→Lua 回调`(CR) → `转发服务端`(CF) → `服务端收到`(SR) →
`服务端回包`(SD) → `回包命中 pending`(CP) → `调用 NUI cb`(CA)。默认开启，
`setr phone_diag 0` 关闭。

> 设计稿里的 NS（NUI 即将 fetch）/ND（NUI 已 resolve）两槽**没有实现**：NUI 只把
> tid 带下来，CEF 侧 resolve 不通知 Lua，这两段在 Lua 侧不可观测。硬留在判定里会把
> 正常请求误报成 `seg4`（实测踩过）。它们由 `nuiProbe` 自证代替。

> 注意：**新增脚本文件必须 `refresh`（不是 `restart`）才会进清单**——`restart` 复用
> 服务端缓存的 fxmanifest，只重跑已有文件；漏了 `refresh` 的表现是"文件明明在、代码
> 明明没错、日志里就是没有它"，非常容易误判成缓存或加载错误。

### 输入归属（谁拿键盘/鼠标）

手机开着时输入归谁，完全由 `SetNuiFocus(hasFocus, hasCursor)` 与
`SetNuiFocusKeepInput(keep)` 这两个原生决定。默认是"边走边看"：

| 模式 | convar | 能走路 | 键盘谁收 | 鼠标指针 |
|---|---|---|---|---|
| 边走边看（**默认**） | `phone_keep_input 1` | ✅ | Lua 原始按键（T-CityLite.base/resources/[custom]/custom-phone/client/core/nav.lua，`IsRawKeyDown`） | 可见（焦点归页面后引擎会用） |
| 完全接管 | `phone_keep_input 0` | ❌ | CEF `keydown`（Svelte） | 可见 |

三条必须记住的硬约束：

1. **`SetNuiFocus` 是按资源的** —— 必须由**拥有 ui_page 的资源**调用。在 `custom-ui`
   （无页面）里调用等于把焦点交给不存在的页面：界面能显示，但收不到任何鼠标事件，
   也没有游标。输入栈因此只做决定，按焦点通过 `exports[owner]:ApplyFocus(...)` 回调。
2. **跨资源 exports 不能传函数** —— 帧里只放资源名（字符串），函数字段会被丢掉。
3. **`keepInput` 决定键盘归谁**：`false` 时游戏不再处理输入，`IsRawKeyDown` 和
   `RegisterKeyMapping` 都读不到键（M 键曾因此完全失效）；`true` 时按键走 Lua 原始按键，
   CEF 也可能同时收到（NUI 侧有 120ms 去重，避免一次按键挪两格）。

诊断：`/live/clients` 的 `phone` 里看 `keep_input` / `frames`（交互路径，关屏后必须为空）/
`focus_trace` / `nav_edges`（Lua 最近收到的原始按键边沿）。

## 4. 性能预算

| 指标 | 目标 |
|---|---|
| 首屏 bootstrap（bootstrap 查询） | ≤150ms P95 |
| appQuery/action | ≤250ms P95 |
| bundle（gzip） | ≤80KB（当前约 56KB） |
| 每帧 `SendNUIMessage` | 0（只事件驱动） |
| 缓存 | 每个 domain 有 TTL + 事件失效 |

## 5. 安全

- NUI 输入不可信：每个 action 做类型/范围/权限校验；
- `PhoneApps` audience 是唯一可见性来源；NUI 隐藏不是权限；
- 所有 app query/action 限流（token bucket）；
- 不把密码/token/其他玩家 PII 发到 NUI；
- 服务端日志不打印敏感字段。

## 6. 迁移顺序

1. **core 基础设施**：identity/notify/events/rate_limit + client bridge/focus/events；行为不变。
2. **domain 拆分**：contacts/messages/calls/cityfeed 从 main.lua 抽出，SQL 收口。
3. **App SDK**：manifest 注册 MDT/leader；App.svelte 去掉硬编码分支。
4. **统一事件 + bootstrap 拆分**：getPhoneData 拆 bootstrap + 按需。
5. **删除旧桥/旧事件**，跑 NUI + E2E + 真机回归。

## 7. 验收

- 现有 NUI callback/事件名不变；
- `npm run test:nui`、`pytest tests/unit tests/architecture`、`agent test police_e2e` 全绿；
- 真机：M 打开、MDT 五页、刷新、电话、通知、指纹焦点。
