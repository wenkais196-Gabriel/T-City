---
id: client-research-fivem-nui-2026
type: research
status: active
system: ux
owner: hermes
updated: 2026-10-25
review_by: 2027-01-30
---

# FiveM 客户端 NUI/CEF 架构与调试实践（2026）

> 适用对象：`custom-phone`（Svelte 5 + Vite，`ui_page 'html/index.html'`）及后续所有 NUI 资源。
> 方法：官方文档（docs.fivem.net）优先；机制细节以 CitizenFX 官方源码（github.com/citizenfx/fivem）为准；社区帖仅作现象佐证。
> 源码链接指向 `master` 分支，行号会漂移；结论以"函数名/行为"为准，不以行号为准。

---

## 1. 结论速览

1. **NUI 不是"一个网页"，而是 root CEF 浏览器里的一个 full-screen iframe**：每个资源一个 frame，frame 之间不能点击穿透，焦点是全局栈。[官方](https://docs.fivem.net/docs/scripting-manual/nui-development/full-screen-nui/)
2. **`ui_page` 在资源 start 时解析，frame 默认"延迟创建"**：不写 `ui_page_preload` 时只登记 URL，浏览器实例要等首次展示才初始化；写了才在 start 时立刻创建。[源码 ResourceUI.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUI.cpp)、[源码 NUIWindow.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-core/src/NUIWindow.cpp)
3. **`SendNUIMessage` 是"投递后不管"**：frame 尚未加载、或 JS 监听器尚未注册时，消息被静默丢弃，没有返回值可判断、没有重发。[官方](https://docs.fivem.net/docs/scripting-manual/nui-development/full-screen-nui/)、[社区复现](https://forum.cfx.re/t/sending-nui-message-with-onresourcestart/5342213)
4. **回调未注册 = HTTP 404 + 空 body**（不是 500、不是 JSON 错误）。这是"资源明明在、页面明明开着，但某个回调失败"的第一嫌疑。[源码 RPCSchemeHandler.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/RPCSchemeHandler.cpp)、[社区复现](https://forum.cfx.re/t/nui-callback-issues/5414273)
5. **回调注册了但没调 `cb`，或 POST body 不是合法 JSON = fetch 永久 pending**：CEF 请求既不完成也不报错，只能靠前端 `AbortController` 兜底。[官方](https://docs.fivem.net/docs/scripting-manual/nui-development/nui-callbacks/)、[源码 ResourceUICallbacks.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUICallbacks.cpp)
6. **回调执行在游戏线程的 tick 队列里**，不在 CEF 线程、也不在请求到达的那一帧；回调里做重活会直接吃帧时间。[源码 ResourceUI.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUI.cpp)
7. **URL 必须用 `GetParentResourceName()`**，host 只认资源名（大小写不敏感）；用 `location.hostname` 会得到 `cfx-nui-xxx` 前缀，必然 404。[官方示例](https://docs.fivem.net/docs/scripting-manual/nui-development/nui-callbacks/)、[社区](https://forum.cfx.re/t/nui-callback-issues/5414273)
8. **CEF 不缓存资源文件**：资源文件响应头是 `cache-control: no-cache, must-revalidate`；"改了不生效"通常不是磁盘缓存，而是没重启资源 / 旧 frame / 构建产物没更新 / `localStorage` 脏数据。[源码 NUISchemeHandler.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-core/src/NUISchemeHandler.cpp)
9. **`restart <res>` 会销毁并重建 frame**：stop → `DestroyFrame`，start → `PrepareFrame`；重启瞬间在途的 POST 会丢（老客户端甚至会崩，2023 年回调重做后修复）。[源码](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUI.cpp)、[官方 bug 帖](https://forum.cfx.re/t/random-nui-crash-when-restarting-resource/5016569)
10. **生产环境拿不到 NUI 控制台**：`nui_devtools` 属于 developer 命令，需要 `+set moo 31337` 启动或以 Beta/Latest 通道运行；所以关键失败必须能从服务端日志看见（本项目已有 `clientError` 回传）。[官方 Console Commands](https://docs.fivem.net/docs/client-manual/console-commands/)、[社区](https://forum.cfx.re/t/command-profiler-nui-devtools-access-denied/2623709)

---

## 2. 逐条机制

### 2.1 对象模型：root 浏览器 + 每资源一个 iframe

- NUI 基于 Chromium Embedded Framework（CEF），官方定位是"异步的、用 Web 技术做游戏内 UI"。[官方总览](https://docs.fivem.net/docs/scripting-manual/nui-development/)
- 焦点栈的文档原文：最后获得焦点的资源排在最上层，资源目前实现为 **full-screen iframe**，因此资源之间**不能点击穿透**。[官方 Fullscreen NUI](https://docs.fivem.net/docs/scripting-manual/nui-development/full-screen-nui/)
- 推论（工程含义）：手机不是"独占浏览器"，其它资源（target、inventory、通知）是兄弟 iframe；谁最后 `SetNuiFocus` 谁在栈顶。

### 2.2 `ui_page` / `files` 与加载路径

- `ui_page` 只允许**一条**：源码里条目数 >1 会打 `more than one ui_page` 并直接 `return false`，即**没有 frame**。[源码 ResourceUI.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUI.cpp)
- `ui_page` 可以是相对路径，也可以是绝对 URL（外部托管页面）；相对路径指向的文件必须被 `files` 收录，否则请求会 404。[官方 Resource Manifest](https://docs.fivem.net/docs/scripting-reference/resource-manifest/resource-manifest/)
- 协议前缀由 manifest 版本决定：`cerulean`（2020-05）起 NUI 在**安全上下文**中加载，回调必须用 `https://` 而不是 `http://`；源码里 `nui://` vs `https://cfx-nui-` 的分支也按 manifest 版本切换。[官方 manifest 版本说明](https://docs.fivem.net/docs/scripting-reference/resource-manifest/resource-manifest/)、[源码](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUI.cpp)
- 文件服务行为（源码）：路径经 VFS 解析，找不到 → **404**；找到 → 200，MIME 按扩展名；响应头带 `access-control-allow-origin: *`；非内部 `/ui/app/` 资源带 `cache-control: no-cache, must-revalidate`。[源码 NUISchemeHandler.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-core/src/NUISchemeHandler.cpp)
- 工程含义：`files` 必须"逐文件覆盖"，不要赌通配符递归语义。本项目 `html/assets/*` + `html/assets/audio/*` 是显式列子目录的写法，新增目录时**必须同步加一行**。
- Vite 必须 `base: './'`，否则产物里的绝对路径 `/assets/…` 会解析到 `https://cfx-nui-<res>/assets/...`（丢掉 `html/` 前缀）。本项目 `resources/[custom]/custom-phone/html/index.html` 已是 `./assets/index-<hash>.js` 形式的相对引用，符合要求。

### 2.3 CEF 缓存与 `restart` 语义

按发生顺序（源码）：

| 阶段 | 行为 | 结果 |
|---|---|---|
| 资源 start | `ResourceUI::Create()` 读 `ui_page`，注册 scheme handler，`PrepareFrame`（无 preload）或 `CreateFrame`（有 preload） | frame 登记；无 preload 时浏览器实例**尚未创建**（`NUIWindow::Create(instant=false)` 只存 `m_initUrl`） |
| 首次展示 / 被发消息 | `DeferredCreate()` → `Initialize(url)` | 此时才开始加载 HTML/JS |
| 资源 stop | `ResourceUI::Destroy()`：`m_isDead = true` + `nui::DestroyFrame(name)` | iframe 与 JS 上下文销毁；**`localStorage` 等 CEF 用户数据不销毁** |
| 资源 start（重启） | 重新 `Create()` | 全新 frame、全新 JS 上下文；旧 bundle 不会"残留生效" |

- **没有"资源级 CEF 磁盘缓存"这回事**：资源文件是 `no-cache, must-revalidate`；`ReloadIgnoreCache` 只用于 root UI 的整体重载（`nui::ReloadNUI()`）。[源码](https://github.com/citizenfx/fivem/blob/master/code/components/nui-core/src/CefOverlay.cpp)
- **但持久化状态会跨重启**：`localStorage` / IndexedDB 落在客户端 `nui-storage` 目录，社区排查手段就是删这个目录（以及 cache）。旧版 UI 留下的 key 会让新代码读到脏状态。[社区](https://forum.cfx.re/t/solved-bad-binary-format-error/5210394)
- **重启瞬间的在途请求**：老客户端在"资源重启时正好有 NUI POST"会崩（2023-02 官方确认并重做回调，commit `dfa66db`）；现在不崩，但请求仍可能悬空/丢失。[官方 bug 帖](https://forum.cfx.re/t/random-nui-crash-when-restarting-resource/5016569)
- **诊断口径**：`restart` 后"UI 变了但没生效"→ 先确认构建产物时间戳与 `ui_page` 指向；"UI 没变但行为怪"→ 先怀疑 `localStorage` 和旧客户端未重连，而不是 CEF 缓存。

### 2.4 `SendNUIMessage` 的真实语义（以及丢失窗口）

- 官方：`SendNUIMessage(table)` 是 `SEND_NUI_MESSAGE` 的 Lua 便利包装，内部把 table 编码成 JSON 字符串；页面侧用 `window.addEventListener('message', ...)` 接收。[官方](https://docs.fivem.net/docs/scripting-manual/nui-development/full-screen-nui/)、[官方函数页](https://docs.fivem.net/docs/scripting-reference/runtimes/lua/functions/SendNUIMessage/)
- 源码路径：`nui::PostFrameMessage(frame, json)` → 往 **root UI** 发 `frameCall` 进程消息 → root 的 JS 再转发给目标 iframe。root window 有 `PushLoadQueue`（root 自己没加载完时排队），**资源 frame 侧没有等价队列**。[源码 CefOverlay.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-core/src/CefOverlay.cpp)
- 结论：**"frame 已登记" ≠ "页面能收消息"**。以下三个窗口内消息都会静默消失：
  1. 资源刚 start，frame 还没被创建（无 preload）；
  2. frame 在加载 HTML/JS，监听器还没注册；
  3. 资源刚 stop / 正在 restart，iframe 已销毁。
- 官方 dev（nta）在论坛里承认存在"发消息/设焦点时启发式自动加载 frame"的逻辑，并征集反例——但**自动加载只是开始加载**，不解决"监听器未就绪"。[社区（nta 回帖）](https://forum.cfx.re/t/user-interfaces-not-showing-up-after-reinstall-the-server/1304154)
- 社区复现：`onResourceStart` 里直接 `SendNUIMessage` 不生效，`Wait(50)` 或"由 NUI 反向通知 Lua"才可靠；回复明确指出 "you cannot send NUI messages until the NUI is loaded"，并建议在 JS 的 `window.load` 里回调 Lua。[社区](https://forum.cfx.re/t/sending-nui-message-with-onresourcestart/5342213)
- 可靠性做法（本项目 `PhoneBridge.AwaitAck` 已是正确形态）：**发消息 → 等 NUI 主动 `fetch` 一个 ack 回调 → 收到才认为"界面存在"**；超时则复位 Lua 侧状态并释放焦点。仅靠固定 `Wait(n)` 不可移植（机器性能/包体大小差异）。

### 2.5 `RegisterNUICallback`：注册时机、查找规则、三种失败态

**注册时机**
- 在脚本加载期同步注册最安全：资源 start 时 Lua 先执行，`ResourceUI::Create()` 随后才登记 frame，页面加载更晚，因此顶层 `RegisterNUICallback` 一定早于任何页面 fetch。
- 反例：把注册放在 `CreateThread` + `Wait`、`onPlayerLoaded`、或某个"首次打开手机"的回调里——页面一旦先发请求，就是 404。

**查找规则（源码）**
- 回调按 name 存在 multimap 里；先精确匹配，再**按第一个 `/` 截断**再匹配一次（`appQuery/xxx` 会落到 `appQuery`）。同名多注册会**全部**被调用。[源码 ResourceUI.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUI.cpp)
- `RegisterNUICallback` 在官方文档里已标为 **Legacy API**，新代码建议用 `REGISTER_NUI_CALLBACK` native；行为差别在于后者可显式传引用（本项目用 Lua 包装即可，无需迁移）。[官方函数页](https://docs.fivem.net/docs/scripting-reference/runtimes/lua/functions/RegisterNUICallback/)、[native 声明](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/RegisterNuiCallback.md)
- 同一资源内重复注册不会覆盖，会**都执行** → 一个 `cb` 被调用两次的最常见来源。本项目 `PhoneBridge.RegisterNui` 的 `answerOnce` 已挡住这种污染。

**三种失败态（必须区分，处置完全不同）**

| 现象 | 触发条件（源码） | 前端可见 | 服务端可见 |
|---|---|---|---|
| `HTTP 404`，空 body | 资源名 host 不匹配（资源不存在/拼错/用了 `location.hostname`）、回调名未注册、strict mode 拒绝 Origin | `resp.ok === false`；`resp.json()` 抛 `SyntaxError` | **什么都没有**（Lua 未执行） |
| fetch 永久 pending | 回调注册了但没调 `cb`；或 POST body `JSON.parse` 失败（源码 `HasParseError()` 分支**直接 return，不派发也不响应**）；或请求排队后资源 `m_isDead` 被丢弃 | 只能靠 `AbortController` 超时 | **什么都没有** |
| 正常 200 + 业务错误 | handler 返回 `{success=false,error=...}` | 结构化错误码 | 取决于是否打日志 |

- 官方对 pending 的表述是"request will time out and fail causing an error to bubble up into the calling fetch"，但**没有承诺时限**；实测必须自己加超时。[官方 NUI Callbacks](https://docs.fivem.net/docs/scripting-manual/nui-development/nui-callbacks/)
- 404 的实证：2026-07 的论坛帖复现"每个自定义资源都 404 + 空 body"，最终原因是 fetch URL 用了 `window.location.hostname` 而不是 `GetParentResourceName()`；回答还指出资源页面在 13172 里通常**嵌套在 CitizenFX root UI 下，不是顶层条目**。[社区](https://forum.cfx.re/t/nui-callback-issues/5414273)

### 2.6 fetch 的 URL / origin / 交叉资源

- 页面 origin 是 `https://cfx-nui-<resource>`；回调地址是 `https://<resource>/<callbackName>`（也接受 `http://`，但 `cerulean` 起应统一 https）。**host 是资源名本身，不是 `cfx-nui-` 前缀**。[官方](https://docs.fivem.net/docs/scripting-manual/nui-development/nui-callbacks/)
- `GetParentResourceName()` 是注入到 NUI 页面里的 JS 全局；离开 CEF（Vite dev server、普通浏览器）就不存在 → 本项目 `isBrowser()` 用 `!window.GetParentResourceName` 判断是合理的；**开发预览必须走 mock 分支**，否则 `https://undefined/appQuery` 必然失败。
- 请求由 `RPCResourceHandler` 接管（源码对**所有** http/https 请求挂 handler）：按 host 在**当前存活资源**里做大小写不敏感查找，找不到 → 404 空 body；找到了就 `ResourceUI::InvokeCallback(path)`。[源码 RPCSchemeHandler.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/RPCSchemeHandler.cpp)
- 交叉资源：每个资源只给自己登记 CEF cross-origin 白名单（`nui://<res>`、`https://cfx-nui-<res>`）；但 RPC handler 对任意 host 都生效，所以**默认状态下 A 资源的页面可以 POST B 资源的回调**（这也是 strict mode 要解决的问题）。[源码 ResourceUI.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUI.cpp)
- **NUI 里不要直接 fetch 外网 API**：外部 host 不会命中任何资源名 → 404（且 CEF 侧没有正常 CORS 语义）；正确做法是 NUI → Lua 回调 → Lua 用 `PerformHttpRequest`，密钥不落到前端。
- **NUI Callback Strict Mode**（官方实验，2024-08 起 Canary，未来默认开）：
  - manifest 加 `nui_callback_strict_mode 'true'`（源码要求字符串**恰好** `"true"`；`'yes'` 无效）；
  - 开启后只接受 `Origin: https://cfx-nui-<自己>`（或 `nui://<自己>`）的请求，其它资源调用会被拒 → **表现为 404 + 控制台 trace** `has been blocked by NUI Callback Strict Mode`；
  - 跨资源通信改用 JS exports 或事件。[官方公告](https://forum.cfx.re/t/experiment-nui-callback-strict-mode-requires-opt-in/5261145)、[源码](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUI.cpp)
  - 注意：如果页面是**外部 URL**（`ui_page 'https://...'`）或从 iframe/srcdoc 发起请求，Origin 头可能缺失/不等于资源名 → 开 strict mode 后会出现"页面能开、回调全 404"。

### 2.7 焦点：`SetNuiFocus` / `SetNuiFocusKeepInput` / `IsNuiFocused`

- 官方定义：`SET_NUI_FOCUS(BOOL hasFocus, BOOL hasCursor)`，把**当前资源**推到焦点栈，分别控制键盘焦点与鼠标光标；最近获得焦点的资源在最上层；资源是 full-screen iframe，**无点击穿透**。[官方](https://docs.fivem.net/docs/scripting-manual/nui-development/full-screen-nui/)、[native 声明](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/SetNuiFocus.md)
- 社区实测的参数语义：`(true,true)` 有焦点有光标但不能动；`(true,false)` 有焦点**没有光标**（想"只锁键盘"可以，但没法点）；`(false,true)` 等同 `(false,false)`——**hasCursor 依附于 hasFocus**。[社区](https://forum.cfx.re/t/how-can-i-use-nui-focus-exclusively-with-the-mouse/5128416)
- `SET_NUI_FOCUS_KEEP_INPUT(keepInput)`：让游戏继续接收输入（角色能动能开枪），通常与 `SetNuiFocus(true,true)` 组合使用，然后**自己**用 `DisableControlAction` 屏蔽会冲突的键（否则按 M/Esc/鼠标左键会同时打到游戏）。[native 声明](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/SetNuiFocusKeepInput.md)、[社区](https://forum.cfx.re/t/allow-player-to-move-when-setnuifocus-is-set-to-true/181285)
- `IS_NUI_FOCUSED()`：文档只说"返回此前用 `SET_NUI_FOCUS` 设置的状态"。**不要**把它当"我的资源是否在栈顶/是否该处理按键"的所有权判据；多 UI 场景下用它做断言会产生假阳性。可靠做法是自己维护 focus owner（本项目 `resources/[custom]/custom-phone/client/core/focus.lua` 的 owner 模型）。[native 声明](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/IsNuiFocused.md)
- 关闭必须成对：`SetNuiFocus(false,false)` **且** `SetNuiFocusKeepInput(false)`；资源 stop / 玩家卸载 / 打开失败（ack 超时）都要清理，否则"鼠标还在、键盘没反应/角色被冻"会跨会话残留。
- 常见的"多 UI 抢焦点"症状：鼠标能点但键盘无效、或按键穿透到游戏；根因是栈顶不是你以为的那个资源。[官方](https://docs.fivem.net/docs/scripting-manual/nui-development/full-screen-nui/)

### 2.8 DevTools 与日志获取

| 手段 | 前置条件 | 能看到什么 |
|---|---|---|
| Chromium 访问 `http://localhost:13172/` | 游戏运行中 | 所有 CEF target（含 root UI 与资源 iframe）、Console/Network/Performance |
| F8 输入 `nui_devtools` | **developer 模式** | 同上，弹出独立 devtools 窗口 |
| F8 控制台 | 无 | 客户端 Lua 的 `print`；**不含** NUI 的 `console.log` |
| 服务端日志 | 无 | 只有客户端主动上报的内容（本项目 `clientError`） |

- developer 模式的开启方式（官方）：启动参数加 `+set moo 31337`（任何通道都行），或使用非 production 通道（Beta/Latest）。否则 `resmon` / `profiler` / `nui_devtools` 会报 `Access denied`。[官方 Console Commands](https://docs.fivem.net/docs/client-manual/console-commands/)、[社区](https://forum.cfx.re/t/command-profiler-nui-devtools-access-denied/2623709)
- devtools 里的资源页面**不是顶层条目**：先选 CitizenFX root UI，再在其 iframe 树里找 `cfx-nui-<resource>`；找不到通常意味着 frame 还没创建（没 preload + 没打开过）。[社区](https://forum.cfx.re/t/nui-callback-issues/5414273)
- 官方 `SendNUIMessage` 示例注释写 `console.log` 会"print in the console (F8)"——**这是文档瑕疵**；以 devtools 的 Console 为准。[官方函数页](https://docs.fivem.net/docs/scripting-reference/runtimes/lua/functions/SendNUIMessage/)
- 玩家机器上一般没有 developer 模式，所以**生产诊断必须走"前端把错误回传 Lua → 服务端"**：捕获 `fetch` 的 `!resp.ok`、`AbortError`、`window.onerror`、`unhandledrejection`，带 `event/status/reason/message` 上报。本项目 `resources/[custom]/custom-phone/web/src/utils/nui.ts` + `clientError` 已是该形态；服务端做白名单字段 + 限流是必须的（客户端可控内容会污染日志）。
- 兼容性排查：`nui_useInProcessGpu <true|false>`（官方 convar，改后需重启）用于 CEF 渲染兼容问题，不是性能优化开关。[官方 Console Commands](https://docs.fivem.net/docs/client-manual/console-commands/)

### 2.9 客户端 Lua 与 NUI 的时序

权威顺序（源码 + 官方）：

```
资源 start
  → client.lua 依次执行（顶层 RegisterNUICallback 在此完成）
  → ResourceUI::Create()：登记 frame（无 preload 时仅 PrepareFrame）
  → 首次 show/发消息：DeferredCreate → CEF 加载 html/index.html → 加载 JS
  → JS 顶层代码执行 → addEventListener('message') / 首次 fetch 才可用
```

- 所以"Lua 先于页面"成立，但**Lua 的异步初始化可能晚于页面**：`QBCore.Functions.GetPlayerData()`、`oxmysql` 首查、`onPlayerLoaded` 都可能晚于用户点开 App。
- 双向握手是唯一稳妥解：NUI 在 `DOMContentLoaded`/`window.load` 后 `fetch('nuiReady')`；Lua 收到后推初始状态；Lua 主动推消息前先检查 ack/ready 标志。
- `onResourceStart` 里发消息会丢（见 2.4）；`SetNuiFocus` 会触发启发式加载，但**加载不等于监听器就绪**。

### 2.10 性能约束

- **回调在游戏线程执行**：`InvokeCallback` 只是把闭包推进 `g_nuiCallbackQueue`，由 `ResourceManager::OnTick`（优先级 `INT32_MAX`，即该帧很晚）统一执行；回调体内的一切 Lua 工作都算在帧预算里。数据库查询必须异步（`oxmysql` 回调/await），不要在回调里同步等。[源码 ResourceUI.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUI.cpp)
- **`SendNUIMessage` 成本 = JSON 序列化 + 跨进程消息 + 目标页 JS 处理**：社区实测 50ms 一次（20 次/秒）的速度表就能把其它资源的 UI 拖到卡顿；降到 250ms 才恢复。[社区](https://forum.cfx.re/t/cant-send-too-many-nui-messages-before-lagging-other-resources/1876042)
- **大 payload 会冻结游戏**：把字节数组塞进 JSON 数组回传曾导致数秒冻结（raw callback 更糟）；官方在 2023 年重做回调时修了线程/崩溃问题，但序列化成本仍在。二进制走 base64，且不要做 MB 级回传。[官方 bug 帖](https://forum.cfx.re/t/game-freeze-when-sending-big-data-payload-in-events-nui-callbacks/4857732)
- **`resmon` 只统计 Lua，不统计 NUI 页面**：NUI 卡顿要用 devtools 的 Performance 面板定位；服务端/客户端 Lua 的 profiler 看不到 iframe 里的死循环。[社区](https://forum.cfx.re/t/nui-lagging-for-players-when-100-players/5192593)、[官方 Profiler](https://docs.fivem.net/docs/scripting-manual/debugging/using-profiler/)
- 本项目预算（`docs/client/PHONE_ARCHITECTURE.md`）：每帧 `SendNUIMessage` = 0；首屏 ≤150ms P95；bundle gzip ≤80KB。这三条与上面的机制一致，应作为 review 门槛。

### 2.11 安全约束

- **NUI 输入一律不可信**：客户端事件可以被任意构造，NUI 回调同理（官方安全指南的核心论点：客户端可以以任意上下文触发事件）。`app_id` / `query` / `params` 必须在服务端做白名单与类型校验，不能因为"NUI 里没显示这个按钮"就认为调不到。[官方 Secure Your Events](https://docs.fivem.net/docs/developers/server-security/)
- **默认没有 strict mode 时，任何资源都能 POST 你的回调**（官方公告原文：most NUI callbacks can be accessed by any resource）；涉及发钱、给权限、读他人数据的回调必须在服务端再校验调用者身份与业务权限，不能只靠"回调名保密"。[官方公告](https://forum.cfx.re/t/experiment-nui-callback-strict-mode-requires-opt-in/5261145)
- 回调名可被枚举（`/appQuery` 之类），错误信息不要回传内部细节（SQL、堆栈）；日志侧要做字段白名单与长度截断（本项目服务端已实现 `diagField` + 限流）。
- 不要把 token、密码、他人 PII 推到 NUI：玩家可以开 devtools（`+set moo 31337` / Beta 通道），前端内存里的东西等同于公开。[官方 Console Commands](https://docs.fivem.net/docs/client-manual/console-commands/)
- 限流必须在服务端做（本项目 `PhoneRateLimit` token bucket）；NUI 侧的按钮禁用只是体验，不是防线。

### 2.12 把机制映射到本项目的故障（NUI 已加载、MDT 查询"查询失败"、服务端无 appQuery 诊断）

先固定三条事实：

1. **"查询失败"这个文案只对应 `query_failed`**（`resources/[custom]/custom-phone/web/src/apps/PoliceMDT.svelte` 的错误码表）。而 `query_failed` 同时是 `resources/[custom]/custom-phone/web/src/core/request.ts` 里**传输层异常的兜底码**——即"fetch 被 reject 或 abort"。业务错误（`app_forbidden`、`query_not_found`、`rate_limited`…）会显示各自的文案。⇒ 现象指向**传输层**，不是服务端业务拒绝。
2. **服务端本来就没有专门的 appQuery 日志**：`phone:server:appQueryRequest` 只在 `PhoneApps.Query` 抛错时 `print`；唯一的"请求到达"痕迹是客户端在 NUI 回调里发的 `phone:server:focusState { phase='appQuery-hit' }`，而它走 `diagRateLimited(..., 5s)`——**开手机的同一窗口内 `open-start` / `open-nui-sent` / `open-ack` 已经消耗了该 source 的配额**，`appQuery-hit` 极易被丢弃且不会补打。⇒ **"日志里没有 appQuery"不能证明请求没到客户端 Lua**。
3. 三种传输层失败（404 空 body / 永久 pending / 资源重启丢弃）在 UI 上都表现为 `query_failed`，在服务端都**零痕迹**（见 2.5 表）。

按可能性排序的机制假设：

- **H1｜NUI 回调 404**：页面里 `appQuery` 的 URL host 不是当前资源名（`GetParentResourceName()` 返回空/旧值、或代码用了 `location.hostname`）、或 `RegisterNUICallback('appQuery')` 未在该页面生命周期内注册（注册被挪进条件分支/延迟线程）、或开了 strict mode 而 Origin 不匹配。特征：devtools Network 里 `POST /appQuery` 状态 404、响应空；`clientError` 会带 `status=404`（若上报代码在新 bundle 里）。
- **H2｜已注册但永不应答**：handler 内部异常被 `pcall` 吃掉后仍会 answer（本项目有兜底），所以更可能是**请求排队后资源被 restart**（`m_isDead` 直接丢弃）或 **POST body 解析失败**（源码 `HasParseError` 分支不派发、不响应）。特征：devtools 里请求一直 pending，9s 后前端 abort → `query_failed`；服务端无任何记录。
- **H3｜诊断假阴性 + 服务端 `query_failed`**：请求确实到达，`PhoneApps.Query` 的 handler 抛错（会 print `[apps] query ... failed`，需确认日志级别/文件）或返回非 table（**不 print**，直接 `query_failed`）。若同时 `appQuery-hit` 被 focusState 冷却吞掉，就得到"UI 查询失败 + 服务端看起来什么都没有"的完整假象。

**建议的 15 分钟定位顺序**（不改生产代码）：

1. 13172 → root UI → 找 `cfx-nui-custom-phone` iframe → Network 过滤 `appQuery`：**看 status**。404 → H1；pending → H2。
2. 看 Console 是否有 strict mode trace / `Failed to fetch NUI event`。
3. 看服务端是否有 `[custom-phone][nui-error]`：有 `status=404` 直接坐实 H1；完全没有则可能是旧 bundle（不含上报代码）或 H2。
4. 临时在 `phone:server:appQueryRequest` 入口加一行无条件 `print`（排查后删除）：能打出来 → H3 方向；打不出来 → H1/H2。
5. 把 `appQuery-hit` 从 `focusState` 冷却通道里拆出来（独立 channel 或直接 print），避免以后再被自己的诊断误导。

---

## 3. 对本项目的可执行规则清单

> 每条一句话、可通过 code review / 脚本 / 真机操作检查。

### 清单与构建

1. `fxmanifest.lua` 里 `ui_page` 只能有一条，且指向真实存在的构建产物 `resources/[custom]/custom-phone/html/index.html`。
2. `files` 必须逐条覆盖 `html/` 下所有被引用的文件与子目录（新增 `html/assets/xxx/` 时同步加一行）。
3. 构建后检查 `resources/[custom]/custom-phone/html/index.html` 的 script/link 都是 `./assets/...` 相对路径（Vite `base: './'`）。
4. 需要"首次打开零等待"的常驻 UI 才加 `ui_page_preload`（值任意，源码只看键是否存在）；手机这类首开敏感的界面应先测量内存再决定。
5. 不要在 `ui_page` 里用外部 URL，除非明确接受 `GetParentResourceName()`/Origin 语义变化。

### 消息与生命周期

6. 任何 `SendNUIMessage` 都不得假设"页面已就绪"；对状态型消息必须有 ack 或幂等重发。
7. 打开类消息使用"发 → 等 ack → 超时复位"的握手，禁止只 `Wait(n)`。
8. NUI 在 `window.load` 后主动 `fetch('nuiReady')`，Lua 收到前不推初始状态。
9. `onResourceStop` / `onClientResourceStop` 必须清理：焦点、计时器、pending 请求（本项目 `PhoneBridge.Clear`）。
10. 每条 `SendNUIMessage` 都要能回答"页面没加载时这条丢了会怎样"，答不上来就改成拉取式。

### 回调与传输

11. 所有 `RegisterNUICallback` 放在脚本顶层同步注册，禁止放进 `CreateThread`/`Wait`/条件分支。
12. 回调名与前端 `fetchNui(name)` 的字面量必须由同一份常量/测试保证一致（本项目用静态契约测试）。
13. 每个回调的**每条**返回路径都调用 `cb(...)`，且只调用一次（用 `answerOnce` 或等价守卫）。
14. 回调入口先做 `type(data) == 'table'` 与字段白名单校验，非法直接返回结构化错误码。
15. 前端 `fetch` 必须带 `AbortController` 超时，并区分 `!resp.ok`（404/403）与 `AbortError`（挂起）。
16. 404 必须单独上报/记录（`status` 字段），不要让它退化成"网络错误"。
17. NUI 里禁止直接请求外网/其它资源，跨域数据一律经 Lua 回调代理。
18. `GetParentResourceName()` 只在 CEF 内可用，浏览器预览必须走 mock 分支。

### 焦点

19. `SetNuiFocus(true,true)` 与 `SetNuiFocusKeepInput(true)` 成对出现，关闭时两者都置 false。
20. 用 `SetNuiFocusKeepInput(true)` 时必须显式 `DisableControlAction` 屏蔽会冲突的键。
21. 焦点所有权由自己的 owner 模块维护，不用 `IsNuiFocused()` 判断"我是否该处理输入"。
22. 打开失败（ack 超时）/ 资源停止 / 玩家卸载都必须走统一的 `Release(owner)`。

### 性能

23. 禁止每帧 `SendNUIMessage`；HUD 类合并到 ≤10Hz，手机类只在事件发生时发。
24. 单条 NUI 消息 payload 控制在几十 KB 内，禁止回传字节数组/大表（二进制用 base64 且分页）。
25. NUI 回调体内不做同步重活（SQL、循环遍历大表），一律异步或下沉到服务端。
26. NUI 侧渲染用 `requestAnimationFrame` 节流，禁止在 `message` 监听里做 O(n²) 重算。

### 安全

27. 所有 NUI 请求在服务端重新鉴权（身份/职业/权限/归属），前端可见性不是权限。
28. 评估开启 `nui_callback_strict_mode 'true'`（值必须恰好是 `true`），并清理所有跨资源回调调用。
29. 不向 NUI 下发 token、密码、他人 PII；日志不打印敏感字段。
30. 服务端对所有 app query/action 限流，并对客户端上报的诊断字段做白名单 + 长度截断。

### 调试

31. 排 NUI 问题先开 13172 看 Network 的 **status**，不要先猜业务逻辑。
32. 生产诊断依赖 `clientError` 回传，且上报本身要有频率上限与去重（本项目 10s 窗口）。
33. 诊断事件不要复用有冷却的业务通道（如 `focusState`），否则日志缺失会伪装成"请求没到"。
34. 每次改 NUI 必做一次 `restart` 回归：打开、查询、关闭、再打开，确认焦点与 ack 都正常。

---

## 4. 参考资料

官方文档
1. https://docs.fivem.net/docs/scripting-manual/nui-development/
2. https://docs.fivem.net/docs/scripting-manual/nui-development/full-screen-nui/
3. https://docs.fivem.net/docs/scripting-manual/nui-development/nui-callbacks/
4. https://docs.fivem.net/docs/scripting-manual/nui-development/dui/
5. https://docs.fivem.net/docs/scripting-reference/resource-manifest/resource-manifest/
6. https://docs.fivem.net/docs/scripting-reference/runtimes/lua/functions/RegisterNUICallback/
7. https://docs.fivem.net/docs/scripting-reference/runtimes/lua/functions/SendNUIMessage/
8. https://docs.fivem.net/docs/client-manual/console-commands/
9. https://docs.fivem.net/docs/developers/server-security/
10. https://docs.fivem.net/docs/scripting-manual/debugging/using-profiler/

CitizenFX 源码 / native 声明
11. https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/RPCSchemeHandler.cpp
12. https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUICallbacks.cpp
13. https://github.com/citizenfx/fivem/blob/master/code/components/nui-resources/src/ResourceUI.cpp
14. https://github.com/citizenfx/fivem/blob/master/code/components/nui-core/src/CefOverlay.cpp
15. https://github.com/citizenfx/fivem/blob/master/code/components/nui-core/src/NUIWindow.cpp
16. https://github.com/citizenfx/fivem/blob/master/code/components/nui-core/src/NUISchemeHandler.cpp
17. https://github.com/citizenfx/fivem/blob/master/ext/native-decls/SetNuiFocus.md
18. https://github.com/citizenfx/fivem/blob/master/ext/native-decls/SetNuiFocusKeepInput.md
19. https://github.com/citizenfx/fivem/blob/master/ext/native-decls/IsNuiFocused.md
20. https://github.com/citizenfx/fivem/blob/master/ext/native-decls/RegisterNuiCallback.md

Cfx.re 论坛（官方公告 / 现象佐证）
21. https://forum.cfx.re/t/experiment-nui-callback-strict-mode-requires-opt-in/5261145 （官方：strict mode）
22. https://forum.cfx.re/t/sending-nui-message-with-onresourcestart/5342213 （NUI 未加载时消息丢失）
23. https://forum.cfx.re/t/nui-callback-issues/5414273 （404 空 body / GetParentResourceName）
24. https://forum.cfx.re/t/user-interfaces-not-showing-up-after-reinstall-the-server/1304154 （nta：ui_page_preload 与自动加载启发式）
25. https://forum.cfx.re/t/random-nui-crash-when-restarting-resource/5016569 （官方：restart 时 POST 崩溃，回调重做）
26. https://forum.cfx.re/t/command-profiler-nui-devtools-access-denied/2623709 （nui_devtools 需要非 production 通道）
27. https://forum.cfx.re/t/cant-send-too-many-nui-messages-before-lagging-other-resources/1876042 （20Hz 消息拖慢其它 UI）
28. https://forum.cfx.re/t/game-freeze-when-sending-big-data-payload-in-events-nui-callbacks/4857732 （大 payload 冻结）
29. https://forum.cfx.re/t/nui-lagging-for-players-when-100-players/5192593 （resmon 不测 NUI）
30. https://forum.cfx.re/t/how-can-i-use-nui-focus-exclusively-with-the-mouse/5128416 （焦点参数语义）
31. https://forum.cfx.re/t/allow-player-to-move-when-setnuifocus-is-set-to-true/181285 （KeepInput 与 DisableControlAction）
32. https://forum.cfx.re/t/solved-bad-binary-format-error/5210394 （nui-storage 持久化目录）
