# AGENTS.md — `[custom]` 资源（自研部分）

> 目录：`T-CityLite.base/resources/[custom]/`。这里是**我们自己的代码**，
> 可以按需要重构；`[qb]` 下的上游资源另有守则（见 `T-CityLite.base/resources/[qb]/AGENTS.md`）。

## 范围

`custom-phone`、`custom-police`、`custom-director`、`custom-agent-client`、`custom-vehicles`、
`custom-quest`、`custom-career`、`custom-ambulance`(如存在)、`story-engine`、`custom-ui` 等。

## 唯一入口（跨平面调用只认这些）

| 方向 | 入口 |
|---|---|
| NUI → 客户端 | `RegisterNUICallback(name, function(data, cb) … end)`；应答一律 `PhoneBridge.AnswerFn(cb)` |
| 客户端 → 服务端 | `PhoneBridge.Request(event, payload, cb, timeoutMs, responseEvent, trace)` |
| 服务端 → 客户端 | `TriggerClientEvent('phone:client:…')` / 各资源自己的 `:client:` 事件 |
| 服务端 → DB | 本资源的 `*Db` helper（如 `PhoneDb.InsertId/AffectedRows`），不直接 `MySQL.*` |
| 钱/物品 | `Player.Functions.*`、`core_economy:TriggerReward` |

## 禁止

- 在 `client/**` 里出现 `MySQL.`、`exports['oxmysql']`、直接改钱（闸门会红）。
- 在 `server/**` 里调用 `SetNuiFocus` / `SendNUIMessage`（客户端原生，服务端没有）。
- NUI 回调里写 `if type(cb) ~= 'function' then return end`——本 build 的 `cb` 可能是
  可调用表，这条守卫会静默丢掉每一次应答（2026-10-25 实际故障，见 playbook §3.0）。
- 把诊断/遥测事件当 RPC 用（永不回包），或把 payload 打出来（宪法第 7 条）。
- 通知"收到就回存"（无限回环）：服务端单播 + `origin='server'`。

## 改动前必读

- 手机相关：`docs/client/PHONE_ARCHITECTURE.md`（§3.5 应答通道与自证握手）、
  `docs/client/research/nui-debug-playbook.md`（排查顺序：缓存 → 应答通道 → 追踪）。
- 焦点语义（血泪）：开 = `SetNuiFocus(true,true)` + `SetNuiFocusKeepInput(true)`；
  关 = `SetNuiFocus(false,false)` 且**保留** keepInput；不要禁 movement 控制 30–35。
- 焦点所有权由 `PhoneFocus` 单点管理，不要在业务代码里直接调 `SetNuiFocus`。
- 一次按键派发多条命令的坑：`RegisterKeyMapping` 只能在启动时注册一次，
  命令入口要有防抖（见 `custom-phone/client/main.lua` 的 `TOGGLE_DEBOUNCE_MS`）。

## 已知坑

- 换形态（手机↔平板）时 `ClosePhone('switch')` → `OpenPhone(kind, 'switch')`：**reason 必须是
  switch**，NUI 靠它决定"留在当前页还是回桌面"；传别的值会出现"画面回桌面但状态仍报旧 App"。
- **手机开着时（keepInput）玩家硬件按键进不了 CEF，控制号 172-175 也轮询不到** ——
  键盘必须用 `IsRawKeyDown(VK)` 读原始按键（见 client/core/nav.lua），控制号只留给手柄。
  症状很有迷惑性：agent 注入的按键能用、玩家自己按没反应。
- NUI 的键盘导航：**Tab 在游戏里拿不到**（GTA 占），方向键/Enter/Backspace 能到 CEF；
  手柄走 Lua 轮询控制再发 `phone:nav`。两条腿都落到 T-CityLite.base/resources/[custom]/custom-phone/web/src/core/nav.ts，别在 app 里
  各自监听方向键（见 docs/client/research/keyboard-and-gamepad-navigation.md）。
- 真机 OS 光标被 GTA 锁在屏幕角（`SetCursorPos` 无效），合成鼠标点击进不了 NUI；驱动 UI 走
  `/phoneui <app>`（`setr phone_ui_nav "1"`）或 `adc <src> <cmd>`（`setr agent_devcmd_enabled "1"`）。
- `IsNuiFocused()` / `IsNuiFocusKeepingInput()` 在本 build **恒 false**：判定开关/焦点一律用
  自己的账（`Surface.IsOpen()` / `PhoneFocus.State()`），原生只当诊断字段，见
  `docs/client/research/nui-debug-playbook.md` §3.0a。同名 `RegisterCommand` 后注册者覆盖先注册者。
- **Lua 的 pattern 没有 `{n,m}`**（那是正则的写法）。写 `'^911 [^%c;]{1,80}$'` 永远不会匹配，
  而且失败得很安静：命令只回 `not_allowed`，看起来像"白名单没加"。长度用 `#cmd` 判。
- `_G.QBCore` 在资源内不保证存在：用 `exports['qb-core']:GetCoreObject()` 惰性解析并缓存。
- `PlayerData.source` 不可靠，roster key 才是 source；重连后 id 会变。
- oxmysql 定制版 `insert` 可能返回 `{insertId, affectedRows}`：用 helper 取，不要当裸数字。
- 服务端 `DoesEntityExist` 对远程 ped 可能 false，坐标采样不能以它为前提。
- 命令处理器（`QBCore.Commands.Add` / `RegisterCommand`）里 `GetPlayer(source)` 可能是 nil
  （控制台 `source = 0`，或玩家本帧掉线），索引 `PlayerData` 前必须判空。
- 跨脚本全局：`rawget(_G, 'X')` 在 FiveM 各脚本独立 env 下取不到别的脚本定义的全局，
  直接用全局名。

## 验收命令

```bash
cd T-CityLite.base && /usr/bin/python3 -m pytest tests/unit tests/architecture -q
luac5.4 -p resources/[custom]/<res>/server/main.lua      # 全部改过的 Lua
tcity-cmd -w 8 "restart <res>"                            # 控制台应无 SCRIPT ERROR
tcity-cmd --page | grep -a "\\[custom-<res>\\]"            # 资源自检日志
```

手机还要看自证握手：`[nui-ready] build=… parent=custom-phone`、`[probe] code=ok`、
`[diag] … break=none`。三条都出现才算前端真的跑起来了。
