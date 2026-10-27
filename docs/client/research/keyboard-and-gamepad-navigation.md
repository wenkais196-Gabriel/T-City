# 手机/平板 NUI 的键盘与手柄导航（研究 + 设计）

> 2026-10-27。起因：agent 的合成鼠标进不了 NUI（GTA 把 OS 光标锁在屏幕角，见
> `docs/client/research/nui-debug-playbook.md` §3.0d），只能靠消息驱动。要真正"操作"界面，
> 需要一套**焦点 + 激活**的输入抽象，键盘和手柄共用。

## 1. 现状（实测）

| 项 | 现状 |
|---|---|
| 全局键盘处理 | `T-CityLite.base/resources/[custom]/custom-phone/web/src/App.svelte` 只有一处 `keydown`：`Escape` 关屏；`m/M` 已交回 Lua（§3.0c） |
| 焦点样式 | 只有 `PoliceMDT` 的 `.refresh:focus-visible` 一条；其余按钮没有可见焦点圈 |
| `tabindex` | 只有 `Notifications` 的通知行 |
| 手柄 | 无任何处理 |
| 浏览器原生 Tab 导航 | **实测无效**：开屏后连按 3 次 Tab + Enter，界面不动（Tab 在 GTA 里有绑定） |
| 方向键 + Enter | **实测有效**：Down×2 + Enter 打开了 Contacts（`ArrowDown`/`Enter` 能到 CEF） |
| 通过 GTA 控制轮询看合成方向键 | **看不到**：Lua 侧 `IsControlJustPressed(0,172)` 没被合成按键触发（键被 CEF 吃掉） |

结论：浏览器原生的 Tab 顺序不能作为方案。原因是**按键所有权**——`keepInput=true` 时游戏
仍在处理输入，Tab 在 GTA 里是记分板/广播轮盘一类绑定，CEF 收不到（`Escape` 能收到，
因为它在那个上下文里没有游戏绑定）。

## 2. 方案：Lua 轮询控制 → NUI 焦点模型

不在浏览器里抢 Tab，而是把"输入"放在**客户端 Lua**，因为它既能看见键盘也能看见手柄：

```
玩家/agent 按键 ──► GTA 输入层 ──► custom-phone/client/core/nav.lua（轮询 IsDisabledControlJustPressed）
                                      │  SendNUIMessage({action='phone:nav', kind, dir})
                                      ▼
                              NUI core/nav.ts（焦点环 + 激活/返回）
```

三个好处：

1. **一套实现同时覆盖键盘与手柄**：GTA 的输入控制本身就把 WASD/方向键、d-pad、A/B 映射到同一批
   `INPUT_*`，Lua 只认控制，不认设备。
2. **不和游戏抢键**：轮询 + `DisableControlAction` 是 FiveM 的惯用做法，游戏不会"吃掉"按键。
3. **焦点模型在 NUI**：UI 知道哪些元素可聚焦，Lua 只管发方向/确认/返回。

## 3. 控制映射（键盘 ↔ 手柄共用）

| 语义 | 控制 | 键盘 | 手柄 |
|---|---|---|---|
| 上/下/左/右 | 172/173/174/175（`INPUT_CELLPHONE_*`）或 27/28/29/30 | ↑↓←→ / WASD | d-pad / 左摇杆 |
| 确认 | 176 / 191（`INPUT_FRONTEND_ACCEPT`） | Enter / Space | A / ✕ |
| 返回 | 177 / 194（`INPUT_FRONTEND_CANCEL`） | Backspace / Esc | B / ○ |
| 关闭设备 | 由 `M` 或 `Escape` 的既有路径处理 | — | — |

`nav.lua` 只在 `Surface.IsOpen()` 时轮询，关闭时不注册任何 tick。

## 4. NUI 侧的焦点模型

`T-CityLite.base/resources/[custom]/custom-phone/web/src/core/nav.ts`：

- **可聚焦集合**：当前活动 app 根节点下 `button, [href], input, select, textarea, [data-nav]`，
  按 DOM 顺序（视觉顺序）排序；`[disabled]`、`aria-hidden`、不可见的跳过。
- **焦点环**：`data-nav-focus="true"` 唯一存在；样式用 `:focus-visible` 同款 outline。
- **动作**：`move(dir)` 在集合里前后移动（grid 里 4 向 = 上下按行、左右按列，简化为顺序移动，
  后续再按 grid 几何排序）；`activate()` 对当前元素 `click()`；`back()` →
  有 app 时回桌面，桌面时关屏。
- **打开时**：焦点落到第一个可聚焦元素；关闭时清空。

## 4.1 实测之后的设计修正

原计划"全部输入都从 Lua 轮询控制来"只对**手柄**成立：合成方向键到不了 GTA 的控制状态
（CEF 先吃掉了），所以键盘这条路必须在 NUI 里处理。

最终实现是**两条腿、一个动作层**：

| 输入源 | 处理位置 | 说明 |
|---|---|---|
| 键盘（方向键 / Enter / Backspace） | NUI `keydown`（`T-CityLite.base/resources/[custom]/custom-phone/web/src/App.svelte`） | 输入框内不拦截，方向键仍移动光标 |
| 手柄（d-pad / A / B） | Lua 轮询控制 → `phone:nav` 消息 | `PhoneNav.Tick()` 挂在开屏循环里，不自建线程（否则每帧 tick 翻倍） |
| 共同落点 | `T-CityLite.base/resources/[custom]/custom-phone/web/src/core/nav.ts` | `move/activate/back`，焦点环 `data-nav-focus` |

手柄这条腿**尚未在真手柄上验证**（本机没有手柄）；控制号用 172-175（手机组）+ 186-189
（前端组），accept/cancel 用 176/177 —— 这组号要在真手柄上复核，见 §9。

## 5. 分期

| 期 | 范围 | 状态 |
|---|---|---|
| P1 | 方向/确认/返回 + 焦点环 + 打开即聚焦；键盘与手柄同时生效 | 本次 |
| P2 | grid 几何导航（按位置找最近元素，而不是 DOM 顺序） | 后续 |
| P3 | 每个 app 声明自己的 `data-nav` 优先级（主按钮优先） | 后续 |

## 6. 风险

| 风险 | 处理 |
|---|---|
| 和 app 自己的 `keydown` 冲突 | 统一在 shell 层处理，app 不再各自监听方向键 |
| 输入框里方向键要能移动光标 | 焦点在 `input/textarea` 时方向键交给控件，不切换焦点 |
| 平板两栏 | 焦点集合按 DOM 顺序天然跨栏；P2 再按几何排序 |
| 关屏后焦点残留 | `nav.reset()` 在 `phone:close` 时清空 |

## 4.2 焦点要能被读出来（否则 agent 还是瞎子）

真机第一次试键盘就暴露了问题：按 Tab / 方向键之后**没人知道焦点落在哪** ——
我连着按三次 Down，Enter 打开的是"分享"，想输的地方根本没碰到。

所以 `nav.ts` 在每次焦点变化时回吐标签：

```
paint(el) → fetchNui('uiFocus', {label}) → Lua focusHint → GetUiState().focus → /live/clients
```

- 标签取 `aria-label`，没有就取文字，再没有就取标签名；上限 40（Lua 侧截 40，服务端 24）；
- 空白标签（`"   "`）**不算焦点** —— 只折叠不 trim 会把空白当成有焦点，测试抓到过；
- 关屏、`/phonefix` 都清空；
- 服务端走 `labelText()`：剥控制字符、折叠空白、限长（中文标签原样保留）。

拿到 `focus` 之后 agent 的操作变成确定性的：看 `focus` 是不是目标控件 → 不是就继续移 →
是了再 activate → 输入。

## 4.3 Tab 必须处理

方向键和 Enter 在输入框里属于输入框自己（移光标 / 提交），**Tab 是唯一的出口**。
不处理 Tab 就会"焦点一旦落进搜索框就再也出不来"。现在 Tab = 下一个、Shift+Tab = 上一个，
并且在 `isEditableTarget` 判断**之前**处理。

## 4.4 翻页与滚动

方向键是 `scrollIntoView({block:'nearest'})`（最小滚动），所以焦点走一步列表才动一点；
24 条的任务列表要按十几次。补了 `PageUp/PageDown`（一次 7 格 ≈ 一屏）和
`Home/End`（首尾）。

**End 必须留在容器里**：真机在 MDT 列表按 End，焦点直接跳到壳层的"回桌面"，
一点用没有。现在 `jump()` 先找焦点所在的可滚祖先，只在那个容器里跳。

实测（NUI harness，24 条任务）：滚动容器是 `.pane`（不是 `.quests-app`）——
焦点走 14 步 `scrollTop` 从 0 到 3014/3024，焦点元素始终留在可视区内，往回走能回到顶部。

## 9. 待验证

1. 真手柄：d-pad 是否映射到 172-175 / 186-189；A/B 对应 176/177 还是 191/194。
2. P2：grid 几何导航（上下按行、左右按列），现在按 DOM 顺序走。
3. 平板两栏的焦点顺序（跨栏时按 DOM 还是按视觉位置）。
