---
id: client-research-input-layers-and-keybindings
type: research
status: active
system: ux
owner: hermes
updated: 2026-10-27
review_by: 2027-01-30
---

# 输入层与键位冲突（调研）

> 起因：手机上用方向键导航时，**车上的转向灯跟着乱闪**（左/右/下三个方向键）。
> 这份文档回答两件事：键位都绑在哪、游戏里的输入/焦点分成几层，以及该怎么排。
> 键盘导航本身的实测见 `docs/client/research/keyboard-and-gamepad-navigation.md`。

## 1. 这个 build 的三个畸形事实（先记住，后面全靠它解释）

| 事实 | 后果 |
|---|---|
| `IsNuiFocused()` **恒为 false**（61 条 focusThe 事件里 0 条 true） | 所有拿它做仲裁的代码都在"永远没人占着 NUI"的假设下跑 |
| 手机开着时 `SetNuiFocus(true,true)` + `KeepInput(true)` | 游戏继续吃输入，**玩家硬件按键到不了 CEF** |
| `RegisterKeyMapping` 是**全局**的 | 不管 NUI 开没开，命令都会触发（除非资源自己挡） |

## 2. 输入的三层

| 层 | 谁在用 | 判据 | 备注 |
|---|---|---|---|
| **L1 游戏控制**（INPUT_*） | 移动、瞄准、车辆、`IsControlJustPressed` | 引擎每帧的状态 | 可被 `DisableControlAction` 压掉 |
| **L2 资源键位**（`RegisterKeyMapping`） | 手机 M、库存 TAB、目标盘 LMENU、巡航 Y/U、安全带 B、中控 I 等 | 全局，与 NUI 无关 | 同一键只能有一个绑定，重复注册后者覆盖 |
| **L3 NUI 焦点**（`SetNuiFocus`） | 手机、库存、qb-menu、目标盘、中控屏、menuv | 同时只有一方"应该"持有 | **本 build 没有仲裁**：`IsNuiFocused()` 恒 false |
| **L4 我们的键盘轮询**（原始按键） | `T-CityLite.base/resources/[custom]/custom-phone/client/core/nav.lua` | 手机开着时每帧 | 绕过 L1/L2，见 §5 |

## 3. 当前键位清单（L2）

| 键 | 命令 | 资源 |
|---|---|---|
| `M` | phone | custom-phone |
| `TAB` | openInv | qb-inventory |
| `Z` | toggleHotbar | qb-inventory |
| `1`–`5` | slot_N | qb-inventory |
| `I` | menu / dashboard | **qb-hud 与 tcity-dashboard 都绑了 `I`** |
| `HOME` | scoreboard | qb-scoreboard |
| `E` / `H` | doorlock / remote door | qb-doorlock |
| `B` | toggleseatbelt | custom-vehicles |
| `Y` / `U` | togglecruise / quickcruise | custom-vehicles |
| `LMENU`（Alt） | playerTarget / +radiotalk | qb-target **与 pma-voice 都绑了 Alt** |
| `F11` | cycleproximity | pma-voice |
| 无默认键 | txAdmin 一组 | monitor |

## 4. 控制号占用（L1）

| 控制 | 含义 | 谁在读 |
|---|---|---|
| 172 / 173 | FRONTEND_UP / DOWN | `T-CityLite.base/resources/[custom]/custom-vehicles/client/cruise.lua`（Lock 模式微调 ±5km/h，group 2） |
| **174 / 175** | FRONTEND_LEFT / RIGHT | **`T-CityLite.base/resources/[custom]/custom-vehicles/client/indicators.lua`：左/右转向灯** |
| **187** | FRONTEND_DOWN（菜单组） | **`indicators.lua`：双闪 toggle** |
| 177 | FRONTEND_CANCEL | `T-CityLite.base/resources/[custom]/custom-police/client/camera.lua` |
| 25 | AIM | custom-phone（右键关手机） |
| 24 | ATTACK | qb-weapons |
| 47 | 拾取/交互 | qb-inventory、qb-drugs、qb-ambulancejob、custom-vehicles |

## 5. 这次冲突的根因（实测链条）

```
导航要读方向键
  → nav.lua 每帧 DisableControlAction(172-175)（怕同一下触发游戏动作）
  → indicators.lua 读的是 IsDisabledControlJustPressed(174/175/187)
  → "被禁用 + 被按下" 正好是它的触发条件
  → 手机里按方向键，车上的转向灯跟着切
```

也就是说：**不是"抢键"，是"我们把键禁掉了，正好踩中别人的触发条件"。**

另外两条隐患：

- `custom-phone` 的开屏循环禁了 24/25/37/44/81-83/140-142（攻击、瞄准、切枪、掩体、电台……）。
  这是逐帧禁用、关屏即停，所以没有残留；代价是**开手机期间按左键/开枪前要先关手机**（有意的取舍，
  但 24 与 qb-weapons 是隐式耦合，改任何一边都要想到另一边）。
- `qb-inventory` 用 `IsNuiFocused()` 挡"别在 NUI 上开背包"，而它恒 false → **手机开着时按 TAB 会再开背包**，
  两套 NUI 抢焦点（手机上再叠一个背包）。

## 6. 冲突矩阵

| 键 | 手机导航 | 其他用途 | 现在会发生什么 |
|---|---|---|---|
| ← → ↓ | 移焦点 | 转向灯 / 双闪 | **都触发**（实测） |
| ↑ ↓ | 移焦点 | 巡航微调（Lock 模式） | 车上同时改巡航速度 |
| TAB | 下一个控件 | 开背包 | 手机开着按 TAB → 背包叠上来 |
| HOME / END | 首/尾 | scoreboard（HOME） | 打开记分板 |
| ENTER | 确认 | 聊天发送（T 打开后） | 聊天框里按 Enter 会同时"确认"一次 |
| BACKSPACE | 返回 | 文本删除 | 输入框里我们已跳过，非输入框没事 |

## 7. 计划（先 P0，再结构）

### P0 让手机不碰车辆键（今天能做）

1. `nav.lua` 不再 `DisableControlAction(172-175)`：键盘走原始按键，本来就不需要禁控制号；
   只保留"手柄那组"的禁用（186-189），并且只在检测到手柄输入时禁。
2. `indicators.lua` / `cruise.lua` 加一句开门卫：手机开着（`exports['custom-phone']:GetUiState().open`）就不响应。
   这是它们本来就该做的判断，跟手机无关的写法都能受益。
3. 用例：CLIENT 侧加"手机开着时导航不发 DisableControlAction(174/175)"的断言；indicators 加门卫用例。

### P1 键位表收敛 + CI 闸门

4. 把 §3 的表落成 shared 目录下的 keybinds.json（计划新增）（键、命令、资源、是否可被 NUI 占用），
   tests/architecture 下加一条闸门：**同一个键不允许两个资源注册**（`I` 与 Alt 这两处现在就是红的）。
5. 网关允许"按键可被重绑"：文档写清楚玩家在五M 设置里改哪个，别在代码里硬编码第二处。

### P2 NUI 焦点仲裁（结构性）

6. 建一个 `tcity-focus` 的小客户端资源（或 `custom-ui` 里加一层）：`Acquire(name)/Release(name)/Owner()`，
   所有 `SetNuiFocus` 都经它；它自己是唯一相信"谁占着焦点"的地方（不依赖 `IsNuiFocused`）。
7. `qb-inventory` 的 `IsNuiFocused()` 门卫改成问这一层；手机、qb-menu、目标盘、中控屏、menuv 接进来。
8. 手机开着时，L2 键位（TAB/HOME/I）在网关里被临时让位——这是"层"该做的事，不是每个资源各写一遍。

### P3 键位重新分配（要人拍板）

9. 转向灯/双闪从 ← → ↓ 挪到不冲突的键（例如 `Q`/`E` 会不会又和 doorlock 的 `E` 撞，要一起定），
   或者只在"手机没开 + 在车里"时生效。
10. `HOME`（记分板）与 `Home/End`（手机首尾）只能留一个：建议手机里不接管 HOME/END，改用 `PageUp/PageDown` + 首尾由方向键长按实现。

## 8. 验收

| 项 | 怎么验 |
|---|---|
| 手机箭头不再碰转向灯 | 车上开手机，方向键走一圈，转向灯不动 |
| 巡航不被改 | 车上开手机，↑↓ 走一圈，巡航目标不变 |
| 背包不叠手机 | 手机开着按 TAB，背包不开 |
| 键盘导航仍可用 | 原始按键用例 + 真机 Tab/Down/Enter |
| 键位不重复 | pytest tests/architecture -k keybind（加闸门后） |
