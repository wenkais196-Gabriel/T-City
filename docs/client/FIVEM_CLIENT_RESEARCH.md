---
id: client-fivem-client-research
type: research
status: active
system: ux
owner: hermes
updated: 2026-10-25
review_by: 2027-01-30
---

# FiveM / QBCore 客户端与 NUI 深度调研

> 目标：解释“服务端完成度高、客户端反复出怪问题”的根因，并为后续客户端开发建立可复用资料库。
> 结论先行：**客户端不是薄薄一层 UI，而是 GTA 原生、CitizenFX 客户端 Lua、CEF/NUI、服务端同步四层组成的异步系统；大部分“前端波动”来自 NUI 回调/焦点/QBCore callback 的并发与生命周期，而不是 CSS。**

## 1. 四层模型

```
Browser (CEF)  <-- fetch / postMessage -->  Client Lua (CitizenFX)
      |                                          |
      | ui_page / files / https://cfx-nui-<res>/  | TriggerServerEvent / QBCore callbacks
      v                                          v
   HTML/JS/CSS                              Server Lua (FXServer, authority)
      ^                                          |
      +----------- SendNUIMessage ---------------+
```

| 层 | 运行位置 | 可信度 | 典型故障 |
|---|---|---|---|
| GTA 原生/游戏世界 | 客户端 | 不可信 | 实体不存在、ped 死亡、网络实体未流式加载 |
| Client Lua | 客户端 | 不可信 | 事件时序、协程、资源重启、焦点残留 |
| NUI/CEF | 客户端浏览器 | 不可信 | 回调不返回、fetch 挂起、资源路径 404、焦点栈 |
| Server Lua | 服务器 | 权威 | 只能看到客户端上报，必须校验/限流/审计 |

**原则**：客户端只表达意图；所有金额、状态、权限、冷却、奖励由服务端复算。

## 2. NUI/CEF 的真实行为

### 2.1 资源与路径

- `ui_page 'html/index.html'` 指定入口；`files` 必须列出所有资源（可用 `html/**`）。
- NUI 资源通过 `https://cfx-nui-<resource>/` 协议作用域提供；旧 `nui://` 已不是安全上下文。
- **Vite 必须 `base: './'`**，否则构建产物里的绝对路径 `/assets/…` 会解析到 `https://cfx-nui-<res>/assets/...`（少了 `html/`），页面空白。
- 我们的 `custom-phone` 已经用 `base: './'` + `./assets/...`，这一项是对的；但任何新 NUI 项目都必须先检查。
- `ui_page` 只有一个入口；多页面用前端路由/状态，不要指望多 HTML。

参考：[Fullscreen NUI](https://docs.fivem.net/docs/scripting-manual/nui-development/full-screen-nui/)。

### 2.2 NUI Callback 的硬约束

```js
fetch(`https://${GetParentResourceName()}/appQuery`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json; charset=UTF-8' },
  body: JSON.stringify(payload),
});
```

```lua
RegisterNUICallback('appQuery', function(data, cb)
  cb({ success = true }) -- 必须调用，且只调用一次
end)
```

- **必须始终调用 `cb`**；不调用会让 `fetch` 永久 pending。
- NUI 数据的输入输出必须是 JSON 可编码。
- `fetch` 没有内建超时；CEF 丢回调/资源重启时就是永久 pending。
- 参考：[NUI Callbacks](https://docs.fivem.net/docs/scripting-manual/nui-development/nui-callbacks/)。

我们在 P1 已加 `AbortController` 6 秒超时；这是所有 NUI fetch 的基线要求。`appQuery`/`appAction` 走客户端 request_id 协议，客户端自己的截止时间是 8 秒，所以它们的 fetch 超时放宽到 9 秒，让 Lua 先把结构化 `timeout` 返回给 UI（`resources/[custom]/custom-phone/web/src/utils/nui.ts`）。

### 2.3 焦点（Focus）是全局栈

- `SetNuiFocus(hasFocus, hasCursor)` 把**当前资源**推入焦点栈；最后获得焦点的资源在最上层。
- 资源之间是 full-screen iframe，**不能点击穿透**。
- `SetNuiFocusKeepInput(true)` 让游戏继续接收输入；手机“按 M 打开后人物还能动/按键冲突”就是它。
- 关闭必须成对：`SetNuiFocus(false, false)` + `SetNuiFocusKeepInput(false)`；资源停止时也要清理。
- 多 UI 资源（手机、target、inventory）同时抢焦点时，表现为“鼠标能点但键盘没反应”或“游戏卡住”。

### 2.4 DevTools 与日志

- CEF remote debugging：`http://localhost:13172/`（游戏运行时）。
- 或 F8 执行 `nui_devtools`（需开启 developer mode）。
- `console.log` 在 NUI devtools，不在 F8；F8 只显示客户端 Lua。
- `nui_devtools` 相关 convar/服务端配置需开发环境显式开启；生产默认关闭。
- 参考：[NUI Development skill](https://tmhsdigital.github.io/CFX-Developer-Tools/skills/nui-development/SKILL/)。

### 2.5 CEF 限制

- 没有 Node.js API；不能 `require`/`fs`。
- 不能跨域请求；只应访问 `https://cfx-nui-*` 或同源资源。
- `localStorage` 在不同 FiveM/CEF 版本行为不一致，不要存关键数据。
- CEF 版本随客户端更新，不要依赖最新 Chromium 特性；以 `nui_devtools` 实际为准。
- 大 bundle 会增加 NUI 首次加载；Svelte 比 React 更小，但不是“自动更快”。

## 3. QBCore 客户端模型

### 3.1 Core Object 与 PlayerData 缓存

```lua
local QBCore = exports['qb-core']:GetCoreObject()
local data = QBCore.Functions.GetPlayerData() -- 本地缓存，可能为空/过期
```

- `GetPlayerData()` 读的是本地 `QBCore.PlayerData`，**不会等服务端加载完成**；登录早期可能是空表。
- 服务端通过 `QBCore:Player:SetPlayerData` 推送全量；`QBCore:Player:UpdatePlayerData` 触发重新拉取。
- 客户端事件：`QBCore:Client:OnPlayerLoaded`、`QBCore:Client:OnJobUpdate`、`QBCore:Client:OnMoneyChange`、`QBCore:Client:OnGangUpdate`、`QBCore:Client:OnPlayerUnload`。
- **不要**用客户端 `PlayerData.job.onduty` 作为服务端权限依据；它只是缓存。

参考：[QBCore Client Functions](https://qbcore.net/docs/api/client-functions)。

### 3.2 `TriggerCallback` 的并发陷阱（本次核心发现）

qb-core 的实现是：

```lua
QBCore.ServerCallbacks[name] = { callback = cb, promise = promise.new() }
TriggerServerEvent('QBCore:Server:TriggerCallback', name, ...)
```

回调表**只按 name 索引**，没有 request id。服务端返回：

```lua
RegisterNetEvent('QBCore:Client:TriggerCallback', function(name, ...)
  if QBCore.ServerCallbacks[name] then
    ... resolve/callback ...
    QBCore.ServerCallbacks[name] = nil
  end
end)
```

后果：

- 同一 callback name 发两次、第一次未返回 → 第二次**覆盖**第一次；第一个 `fetch` 永远不 resolve。
- 手机 MDT 的 `refresh()` 用 `Promise.all([queryApp('units'), queryApp('incidents')])`，两个请求都走 `phone:server:appQuery` → **必然并发同名 callback**。
- 症状正是：第一次点击/刷新失败或空白；第二次偶尔恢复；`appQuery` fetch 挂起；`loading` 永久 true。
- 这不是 CSS/Svelte 问题，是 **NUI → Client Lua → QBCore callback 的并发协议缺陷**。

**修复方向（按优先级）**：

1. **协议级**：NUI 请求带 `request_id`，客户端用 `TriggerServerEvent` + 专用 response event；服务端原样回传 `request_id`，客户端按 id resolve。彻底支持并发。
2. **过渡级**：客户端对 `appQuery`/`appAction` 做**串行队列**，一次只发一个；但超时后仍可能与迟到响应冲突，需配合 request id。
3. **禁止**：`Promise.all` 直接打同一个 QBCore callback name。

> 这条应写进所有 future client 代码 review checklist。

**已落地（方案 1 + 3）**：`custom-phone` 的 NUI `appQuery`/`appAction` 不再调用 QBCore callback，而是：

```
NUI fetch /appQuery
  → client: pendingAppQuery[id] = cb; TriggerServerEvent('phone:server:appQueryRequest', id, data)
  → server: 校验 id(3–64)/data(table) → PhoneApps.Query(source, ...)
  → server: TriggerClientEvent('phone:client:appQueryResponse', source, id, res)
  → client: 按 id resolve 对应 cb（未知/重复/迟到 id 直接忽略）
  → 8s 未响应：cb({ success=false, error='timeout' })，资源停止：error='resource_stopped'
```

- `id = GetGameTimer() .. ':' .. seq`，服务端原样回传，且只单播给调用者 `source`。
- `appQuery` 与 `appAction` 使用独立的 pending 表/响应事件，互不覆盖。
- 旧 `phone:server:appQuery`/`appAction` QBCore callbacks **保留**给其他调用方（例如中控屏），但 NUI 不再使用；新代码禁止再加同名并发 callback。
- 回归：`tests/unit/layer3_business/test_phone_request_protocol.py` 用 Lua stub 跑真实协议块（乱序响应、8s 单次超时、未知 id、资源停止），静态契约在 `test_phone_apps.py`。

### 3.3 客户端事件/回调 vs 网络事件

- QBCore callback 适合“请求-响应”，但有上述单槽限制。
- `TriggerServerEvent` + `RegisterNetEvent` 适合高频/并发/需要 request id 的场景。
- 客户端 `TriggerCallback` 的 await 形式只能在协程（`CreateThread`）中使用；NUI callback 里不要直接 await 阻塞。
- 事件参数必须 JSON/基础类型；不要传 entity/table 引用。

## 4. 为什么客户端“波动”而服务端稳定

| 根因 | 表现 | 为什么服务端没有 |
|---|---|---|
| QBCore callback 单槽并发 | 首次请求丢、fetch 挂起、loading 卡死 | 服务端 callback 每次独立 |
| NUI `cb` 漏调/异常 | fetch pending / Failed to fetch | 服务端没有 CEF |
| fetch 无超时 | 永久 loading | 服务端 await 有 DB 超时/错误 |
| 焦点栈/KeepInput | 按 M 卡住、鼠标键盘不同步 | 纯客户端 |
| 资源重启/缓存 | 新 UI 不生效、旧 bundle | 服务端重启即加载 |
| 相对路径/base | 空白页、404 | 不涉及 |
| 客户端数据缓存 | 显示旧 job/onduty/金额 | 服务端权威 |
| Svelte 非响应式变量 | UI 不更新 | 无 |
| 多资源抢焦点 | 点击穿透失败 | 无 |

## 5. 客户端开发的验证矩阵

| 层 | 工具 | 能抓什么 |
|---|---|---|
| 纯函数/状态 | Vitest / node | 解析、格式化、错误码 |
| NUI 组件 | Playwright + mock bridge（已落地） | 加载/刷新/错误/超时/列表 |
| Client Lua 契约 | Lua harness + 静态扫描 | 回调 cb、focus 配对、事件参数 |
| 真机 CEF | F8 + `nui_devtools` / 13172 | 真实 CEF、焦点、资源重启 |
| 端到端 | 第二客户端 / fivem-mcp（Windows） | 键鼠、截图、真实交互 |

现有资产：

- `custom-phone/web/tests/nui`：4 个 Playwright 场景，含挂起请求恢复。
- `tests/architecture/test_*`：静态契约。
- `custom-testing`：服务端 E2E。
- Linux 无可靠客户端驱动；Windows 可用 [fivem-mcp](https://github.com/VIRUXE/fivem-mcp) 做键鼠/截图/devcon。

## 6. 客户端开发基线清单

### NUI

- [ ] `ui_page` 指向构建后的 HTML；`files` 覆盖全部资源
- [ ] Vite `base: './'`；构建后检查 HTML 引用是 `./assets/...`
- [ ] 所有 `fetch` 有 AbortController 超时（建议 5–10s）
- [ ] 所有 `RegisterNUICallback` 的每条路径都 `cb(...)`，且只调一次
- [ ] NUI 消息有 `type` + `request_id`/schema_version
- [ ] 不依赖 localStorage 存关键状态
- [ ] 关闭时 `SetNuiFocus(false,false)` + `SetNuiFocusKeepInput(false)`
- [ ] `onResourceStop` 清理焦点
- [ ] 错误码渲染有 fallback；未知码不吞
- [ ] loading 用 `try/finally`，失败可重试
- [ ] 不并发打同一个 QBCore callback name

### Client Lua

- [ ] 所有 NUI 请求有 request id / 串行队列
- [ ] 服务端回调失败/超时返回结构化 error
- [ ] 客户端只做表现，不写权威状态
- [ ] 事件参数可 JSON；不传 entity
- [ ] 资源重启/玩家卸载时清理 UI/焦点/计时器
- [ ] 客户端 PlayerData 只读，不当作服务端权限

### 测试

- [ ] Playwright：首轮失败、断连、超时、刷新恢复
- [ ] 静态：callback/焦点/路径/错误码
- [ ] 真机：F8 + nui_devtools，至少一次资源重启
- [ ] 第二客户端或 fivem-mcp（可选）

## 7. 参考

- [FiveM Fullscreen NUI](https://docs.fivem.net/docs/scripting-manual/nui-development/full-screen-nui/)
- [FiveM NUI Callbacks](https://docs.fivem.net/docs/scripting-manual/nui-development/nui-callbacks/)
- [QBCore Client Functions](https://qbcore.net/docs/api/client-functions)
- [CFX NUI Development skill](https://tmhsdigital.github.io/CFX-Developer-Tools/skills/nui-development/SKILL/)
- [fivem-mcp（Windows 客户端驱动）](https://github.com/VIRUXE/fivem-mcp)
