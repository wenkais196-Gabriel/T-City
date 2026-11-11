---
id: ux-phone
type: manual
status: active
system: ux
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

# 手机 · UX 设计

> 覆盖 `custom-phone`（自研 Svelte 手机）与 `custom-ui`（焦点/层栈）。
> 状态：**active** —— 文字输入链路已修并真机验证；Garage 标注已加。

## 1. 调研（现状）

### 1.1 触点清单

| 触点 | 实现 | 现象 |
|---|---|---|
| 开/关手机 | `M`（client/main.lua 第 527 行 RegisterKeyMapping）、右键关（`:395`） | 正常；开屏有 120ms 防抖（一次按键实测会进两次） |
| 桌面 / App 切换 | web/src/App.svelte `activeApp` store | 正常 |
| 文字输入 | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Messages.svelte` `<input>` | **曾完全不能打字**（见 1.2） |
| 手机内导航 | 方向键/Enter/Backspace 走 `T-CityLite.base/resources/[custom]/custom-phone/client/core/nav.lua` 原始键 → `phone:nav` | 正常，Tab 拿不到（GTA 占） |
| 通知中心 | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Notifications.svelte`，服务端 `exports['custom-phone']:Notify` | 只有列表，**无 toast、无提示音** |
| 短信 | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Messages.svelte` | 关了手机收到消息**完全没有提示** |
| Garage 标注 | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Garage.svelte` 的「📍 地图」 | 2026-11-11 新增，按需解析坐标 |
| 焦点所有权 | `T-CityLite.base/resources/[custom]/custom-phone/client/core/focus.lua` + `custom-ui` 的 `Input.Push` | 单一 owner，业务不许直接 `SetNuiFocus` |

### 1.2 曾经打不了字的三个根因（已修，留档防回归）

| 层 | 原因 | 依据 |
|---|---|---|
| 键盘归属 | `PushFrame` 把 `keepInput` 写死读 convar（默认 1）→ 键盘归游戏，CEF 收不到字符 | `T-CityLite.base/resources/[custom]/custom-phone/client/core/focus.lua`:170-185（修复前） |
| 入栈时机 | `uiFocus` 只在 `T-CityLite.base/resources/[custom]/custom-phone/web/src/core/nav.ts` 的 `paint()` 里发；**鼠标点输入框不入栈** | `T-CityLite.base/resources/[custom]/custom-phone/web/src/core/nav.ts`:51-58 |
| 反向抢键 | `T-CityLite.base/resources/[custom]/custom-phone/client/core/nav.lua` 在 text 帧期间仍注入 back/move，`Backspace` 会把输入框 `blur()` | `T-CityLite.base/resources/[custom]/custom-phone/client/core/nav.lua`:100-118 |

修法：`textFocus` NUI 回调 → `PushFrame('phone:text', {keepInput=false})`；`T-CityLite.base/resources/[custom]/custom-phone/client/core/nav.lua` 在
`LocalPlayer.state.phoneTextFocus` 为真时整帧不注入；前端 `T-CityLite.base/resources/[custom]/custom-phone/web/src/core/layers.ts` 提供 `use:textFocus`。

### 1.3 玩家会卡住的场景

| # | 场景 | 现在 |
|---|---|---|
| 1 | 关着手机收到短信 | 毫无提示，玩家永远不知道 |
| 2 | 在 Messages 里按 Esc | 已修为"只失焦"（原来会关整台手机、丢草稿） |
| 3 | 打开 Garage 想知道车库在哪 | 有「📍 地图」，但**取车后不知道车停哪**（无"车在附近"提示） |
| 4 | 手机开着时按 E/ALT | 已修为不触发游戏交互（`custom-ui` 屏蔽 38/19） |

## 2. 设计（目标）

### 2.1 状态机

```
关 → [M] → 开（keepInput=true，键盘归游戏，nav 注入）
开 → 点输入框 → text 层（keepInput=false，键盘归 CEF，nav 静默）
text 层 → Esc / 失焦 / 关手机 → 回到"开"
开 → [M] / 右键 → 关（保留 keepInput 语义，见 AGENTS）
```

### 2.2 触点规则

| 事件 | 表现 | 参数 |
|---|---|---|
| 新消息（手机开着） | 手机内提示音 + 会话未读角标；不弹屏幕通知 | 音效 1 次 / 3 秒内合并 |
| 新消息（手机关着） | 右上角手机推送小条（`kind=phone` 落地） | 7 秒 / 最多 3 条 |
| 银行入账 | 只进通知中心（凭证要能回查） | 永久 |
| 调度/报警（值班警察） | 通知中心 + 屏幕 toast | 2.5 秒 |
| 取车成功 | feed 一行"已取车 TESTCAR1 · pillboxgarage" | 5 秒 |

### 2.3 空态与失败

| 情形 | 文案 | 通道 |
|---|---|---|
| 加载中 | 骨架屏 + "同步中…"（不许白屏） | 页内 |
| 无车辆 | "名下没有登记车辆" + 指路"去车行看看" | 页内 |
| 服务端超时 | "网络忙，稍后再试"（**不许**静默） | 页内 toast |
| 坐标解析失败（标注） | 按钮保持可点，点了给"这间车库没有坐标记录" | error |

## 3. 计划（任务）

| # | 任务 | 文件 | 风险 | 验收方式 |
|---|---|---|---|---|
| P-1 | 新消息提示音 + 未读角标（手机开着时） | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Messages.svelte`、App.svelte | 低（纯前端） | 真机：另一角色发短信 |
| P-2 | 关手机时的推送小条（复用 `custom-notify` 的 phone 落地） | client/main.lua、`custom-notify` | 中（要避免与手机内提示重复） | 真机：关手机收短信 |
| P-3 | 取车后 "车在附近" 提示 + 地图标注已取车辆 | `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Garage.svelte`、client/main.lua | 低 | 真机：车库取车 |
| P-4 | 手机内 toast 统一（成功/失败都走同一样式） | `T-CityLite.base/resources/[custom]/custom-phone/web/src/core/layers.ts` 扩展 | 低 | 真机：存钱/转账 |

## 4. 验收（步骤）

1. 关手机 → 另一角色发短信 → **右上角出现小条**，7 秒后消失；
2. 开手机 → 该会话有未读角标 → 点进去角标清零；
3. 在输入框打字 → 能输入、能删除 → 按 Esc 只失焦（手机仍在、草稿在）；
4. Garage → 点「📍 地图」→ 地图出现车库标记；
5. 取车 → HUD feed 出现"已取车 …"，Garage 状态从 Stored 变 Out。

**反例（必须不成立）**：打字时按 Esc 关掉整台手机；手机开着按 E 打开商店；
无坐标的车库点了没任何反应。

## 5. 已知未决

- 手机与平板的形态切换（`ClosePhone('switch')`）尚未做 UX 评审；
- `custom-ui` 的 `inert` 只做了视觉遮挡，键盘仍可能落到下层（待验证）。
