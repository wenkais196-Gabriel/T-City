# 车机中控的输入管线审查（2026-10-31）

> 起因：面板能打开，**没有游标、视角还在转**，职业页点不到。
> 结论：车机用的是一套 2025 年的旧写法（自己 `SetNuiFocus`），
> 而手机/平板早已改走 `custom-ui` 的**交互路径栈**。两者不是"风格不同"，是能力不同。

## 1. 手机/平板的管线（现状）

| 环节 | 实现 |
|---|---|
| 谁掌管焦点 | `custom-ui` 的 `Input.Push/Pop`（全客户端唯一仲裁），`PhoneFocus` 只是它的门面 |
| 光标 | `frame.cursor`（默认 true），由 `apply()` 传给 `SetNuiFocus(true, cursor)` |
| 视角/操作屏蔽 | 栈非空时起一条线程，每帧 `DisableControlAction` 黑名单（1–6 视角、攻击、瞄准…） |
| keepInput | `apply()` **每次**先 `SetNuiFocusKeepInput(keepInput)` 再给焦点（本 build 会粘住，必须每次设） |
| 页面就绪握手 | NUI ack 之后 `RefreshFocus()` 再施一次（页面没加载完时 SetNuiFocus 会被忽略） |
| 键盘 | `T-CityLite.base/resources/[custom]/custom-phone/web/src/core/nav.ts`（方向键/Enter/Backspace）+ `T-CityLite.base/resources/[custom]/custom-phone/client/core/nav.lua`（手柄轮询 → `phone:nav`） |
| 关闭 | `Pop(id)`，焦点归还由栈自己算 |

## 2. 车机原来的写法（问题所在）

```lua
local ok = pcall(function() exports['custom-ui']:OpenMenu({ keepInput = false }) end)
if not ok then SetNuiFocus(true, true) end
```

四个后果，正好对应真机四个症状：

| 后果 | 症状 |
|---|---|
| 没有进栈 → `apply()` 的屏蔽线程根本不启动 | **视角还能转** |
| `OpenMenu` 只管 `if opts.keepInput then`，显式 false 被当没传 | keepInput 沿用手机上粘住的 true |
| 没有任何"就绪后再施一次" | **游标时有时无** |
| 没有 ack 握手，NUI 挂载时机不确定 | 打开瞬间的查询被限流拒掉 |

## 3. 本轮已改（PR #142）

* 车机改走 `Input.Push({ id='dashboard', kind='modal', keepInput=false, close=_closeNui })`
* 关闭改成 `Pop('dashboard')`，换座浮层同理（`dashboard:seats`）
* 打开 150 ms 后 `RefreshFocus()`（页面就绪再施一次焦点）
* `dashboard_debug 1` 打印 `input=<栈路径>`，真机确认 `input=dashboard`
* `custom-ui:OpenMenu` 区分"没传"与"显式 false"（这一层是根因，上一层只是表象）

真机证据：

```
[dashboard][debug] open veh=46594 class=18 job=police duty=true input=dashboard
[dashboard][debug] NUI asked for dispatchList
[dashboard][debug] dispatchList ok=true n=15
```

## 4. 还没同步的部分（下一轮）

| 缺口 | 手机有 | 车机 | 影响 |
|---|---|---|---|
| 键盘导航 | `custom-phone` 的 `nav.ts` + `nav.lua` | 无 | 手柄/键盘用户只能靠鼠标 |
| Esc / Backspace 关闭 | 有（层自己处理） | 无（`custom-ui` 不替层按 Esc） | 只能再按一次 I |
| NUI ack 握手 | 有 | 固定 150 ms 延时 | 机器慢时仍可能空窗 |
| 一次按键触发两条命令 | — | `open` 日志打两遍 | 反复 restart 后 `RegisterKeyMapping` 重复注册 |

## 5. 判定标准（下一轮验收）

1. 打开中控：**有游标**、**视角锁死**（鼠标不能转镜头）、WASD 不动（`keepInput=false` 的语义）
2. 方向键能在页签与列表间移动，Enter 选中，Backspace 关闭
3. `input=dashboard` 只出现一次（重复绑定修掉）
4. 关闭后：游标消失、视角恢复、手机能正常打开（栈没有残留帧）
