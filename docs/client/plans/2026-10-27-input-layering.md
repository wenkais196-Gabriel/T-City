# 输入分层提案：让 UI 像 GTA 暂停菜单那样接管输入

> 现状：每次加玩法就撞键（转向灯 ← → ↓、巡航 ↑ ↓、背包 TAB、记分板 HOME、中控 I、电台 Alt）。
> 这份提案回答"能不能分层"：**能，而且仓库里已经有半成品（PhoneFocus / custom-ui），只是没打通**。
> 键位清点见 `docs/client/research/input-layers-and-keybindings.md`。

## 1. GTA 原生菜单是怎么做的

| 层级 | 行为 | FiveM 里对应的原语 |
|---|---|---|
| 世界（无 UI） | 全部输入归游戏 | — |
| 暂停菜单打开 | 所有控制停摆，只有菜单自己的导航 | `DisableAllControlActions(0)` + 白名单 `EnableControlAction` |
| 进子菜单 | 上一层的动作让位，只剩"返回/确认" | 同一套，属于**层内**语义 |
| 文本输入（改名、金额） | 键盘归输入框，Enter 归提交 | 焦点在 DOM 元素上，层把 Enter 让出去 |

关键点：**"谁在最上层"是唯一的输入仲裁者**，游戏本身不判断"现在有没有 UI"，它只是被
`DisableAllControlActions` 停下来。FiveM 官方文档也明说 NUI 焦点是**按最近一次
`SetNuiFocus` 排的栈**（后开的资源在上，且资源之间没有点击穿透）。

社区给的推荐写法（citizenfx/fivem#4079 里维护者自己也这么建议）：

```lua
SetNuiFocus(true, false)          -- 焦点给 NUI，但不让游戏继续吃键盘
SetNuiFocusKeepInput(false)
-- 每帧：
DisableAllControlActions(0)
for _, c in ipairs(允许的控制) do EnableControlAction(0, c, true) end
```

## 2. 别人怎么做的（调研结论）

| 项目 | 做法 | 够不够用 |
|---|---|---|
| **ox_lib**（菜单/上下文） | `MenuProps.disableInput`（默认 true）；打开时 `lib.setNuiFocus(not disableInput, true)`，每帧 `DisablePlayerFiring` + `DisableControlAction(0, 140)`；关掉时恢复 | 只有**一个**菜单在管，且只禁攻击类。它不做跨资源仲裁 |
| **ox_lib** clipboard 文档 | 明说"focus 已被别的 NUI 占用时不可用" | 说明社区共识是"有人占着焦点"，但没有公共实现 |
| **qb-target**（RedM 分支） | 导出 `EnableNUI/DisableNUI`，内部一个 `hasFocus` 布尔 | 资源级布尔，不是全局栈 |
| **qb-inventory / qb-menu / qb-spawn** | 直接 `SetNuiFocus`，用 `IsNuiFocused()` 挡并发 | **本 build `IsNuiFocused()` 恒 false** → 挡不住（我们实测手机开着按 TAB 背包会叠上来） |
| **FiveM 本体** | 内部按"最近聚焦"排资源栈，资源间不能点击穿透 | 只解决"谁在上"，不解决"游戏还在吃键" |

**结论：没有一个主流 QBCore 项目实现了跨资源的输入分层**（ox_lib 是资源内最完整的，
qb-* 只靠一个不可靠的原生）。这正好是我们要补的那层。

## 3. 仓库里已经有的两块拼图

| 文件 | 现在是什么 | 缺什么 |
|---|---|---|
| `T-CityLite.base/resources/[custom]/custom-phone/client/core/focus.lua`（158 行） | **真的栈**：`Acquire/Release/Reset`，所有 `SetNuiFocus` 都从这里出，还记录了 keepInput | 作用域在手机资源内；其他资源拿不到 |
| `T-CityLite.base/resources/[custom]/custom-ui/client/main.lua`（102 行） | `OpenMenu/CloseMenu/GuardControls/IsMenuOpen` | 只有一个布尔 `isOpen`；没栈、没层级、没白名单；手机根本没用它 |

所以不用从零造：**把 PhoneFocus 的栈语义挪进 custom-ui，把 GuardControls 换成按层计算的控制白名单**。

## 4. 提案：一个 `Input` 层（住在 custom-ui）

### 4.1 数据结构

```lua
-- 一层 = 一个想接管输入的 UI
{
  id      = 'custom-phone',       -- 谁
  layer   = 'modal',              -- 'overlay' | 'modal' | 'text'
  capture = 'all' | 'none',       -- 键盘/鼠标归不归它
  allow   = { 27, 30 },           -- 例外：允许穿透给游戏的控制号（比如走路）
  keepInput = false,              -- 是否让游戏继续处理输入
  close   = function() ... end,   -- 让下层强制关掉它（栈被从下面抽走时用）
}
```

### 4.2 语义（三层就够）

| 层 | 谁 | 行为 |
|---|---|---|
| `overlay` | 通知、字幕、HUD | 不碰输入，纯显示 |
| `modal` | 手机、背包、目标盘、qb-menu、中控屏 | **接管**：`SetNuiFocus(true,false)` + 每帧 `DisableAllControlActions(0)`，只放行 `allow` |
| `text` | modal 里的输入框状态 | 在同一套 NUI 里，`modal` 把 Enter/方向键让给 DOM 输入框（我们已经在 `isEditableTarget` 里这么做了，只是要提成规则） |

规则一句话：**只有栈顶那层能拿到键；栈顶之下的层连"确认/返回"都收不到。**

### 4.3 API

```lua
exports['custom-ui']:Push({ id = 'custom-phone', layer = 'modal', allow = { 30, 31 }, close = ClosePhone })
exports['custom-ui']:Pop('custom-phone')
exports['custom-ui']:Top()            -- { id, layer }
exports['custom-ui']:IsTaken()        -- 有没有 modal 占着（给 indicators / cruise 这类玩法脚本问）
exports['custom-ui']:Owns('custom-phone')
```

内部只维护一个循环：栈顶变了就重算
`DisableAllControlActions(0)` + `allow` 白名单 + `SetNuiFocus`；栈空时恢复。

### 4.4 各资源怎么接（这张表就是迁移清单）

| 资源 | 现在 | 接入后 |
|---|---|---|
| `custom-phone` | 自带 PhoneFocus + 每帧禁 172-175 | `Push('phone', modal, allow={步行控制})`，**不再禁方向键**（键盘走原始按键） |
| `custom-vehicle indicators` | 直接读 `IsDisabledControlJustPressed(174/175/187)` | 先问 `IsTaken()`，开着 UI 就不响应 |
| `custom-vehicles cruise` | 同上（172/173） | 同上 |
| `qb-inventory` | `IsNuiFocused()` 挡 | `Push('inventory', modal)`；`IsNuiFocused()` 那条删掉 |
| `qb-menu` / `qb-target` | 各自 SetNuiFocus | `Push/Pop`；Alt 的冲突由"栈顶才吃键"自然解决 |
| `tcity-dashboard` | `I` 与 qb-hud 撞 | 同上 + 键位表闸门 |
| `custom-police camera` | 177 自己用 | 以 `Push('police-camera', modal)` 表达 |

## 5. 迁移顺序（每步都能单独回滚）

| 步 | 内容 | 验收 |
|---|---|---|
| **S1** | custom-ui 加 `Push/Pop/Top/IsTaken`，内部用现有的 PhoneFocus 语义；**先只给新代码用**，谁都不迁 | 单测：栈顺序、allow 白名单、栈空恢复 |
| **S2** | 手机迁到 `custom-ui:Push`，`PhoneFocus` 变薄壳（或删掉）；nav.lua 不再禁 172-175 | 真机：手机里方向键不点灯、能导航 |
| **S3** | indicators / cruise 加 `IsTaken()` 门卫 | 车上开手机，转向灯与巡航都不动 |
| **S4** | qb-inventory / qb-menu / qb-target / 中控屏接进来，删掉 `IsNuiFocused()` 判断 | 手机开着按 TAB/Alt/I 不叠 UI |
| **S5** | 键位表闸门（同一键不许两个资源注册） | CI 红→绿 |

## 6. 代价与风险（说清楚再动手）

| 风险 | 说明 | 缓解 |
|---|---|---|
| `keepInput` 在部分 build 上会掉光标（citizenfx#3593） | 我们已经踩过"关掉 keepInput 后 WASD 冻住" | 分层里把 `keepInput` 变成层属性，不用全局开关 |
| 全禁控制会把"开手机时还能走路"搞没 | 现在手机是 keepInput=true，走着也能看手机 | `modal` 的 `allow` 里显式放行走路控制（30-35 绝不全局禁） |
| qb-* 是上游资源 | 改动会破坏合并 | 只加 3-5 行 `exports['custom-ui']` 调用并标注 `-- T-City:` |
| 一次性迁 5 个资源风险大 | | 按 S1→S5 分 5 个 PR，每步都可回滚 |

## 7. 需要拍板的点

1. **层数**：我提议 3 层（overlay/modal/text）。要不要再加一层 `hud-input`（比如地图、雷达那种只吃少量键的）？
2. **modal 是否允许走路**：GTA 暂停菜单是全停；我们的手机现在是"可以边走边看"。两种体验要选一个当默认。
3. **范围**：先做 S1+S2（手机 + 转向灯/巡航，改动小、你今天的痛点就没了），还是直接推到 S4（连 qb-* 一起）？
