# NUI POST 未到达客户端 Lua 回调 —— 系统排查手册

> 适用：T-City Lite `custom-phone`（Svelte 5 + Vite，`resources/[custom]/custom-phone`）。
> 症状原型：手机能打开、页面显示正常、`phoneOpenAck` 能回传，但 MDT 刷新只看到
> `查询失败，请重试`（`error='query_failed'`），服务端日志**一条 `appQuery-hit` 都没有**。
>
> 目标：把“请求没到 Lua 回调”这件事在 5 分钟内定位到唯一一层，而不是靠改代码试错。
> 本手册只做诊断，不改任何生产代码；标 **【临时】** 的片段用完必须撤掉。

相关文档：`docs/client/FIVEM_CLIENT_RESEARCH.md`（NUI/CEF 四层模型与硬约束）、
`docs/client/PHONE_ARCHITECTURE.md`（手机整体结构）。

---

## 0. 事实基线（先对齐，避免在错误前提上排查）

| 事实 | 出处 | 诊断含义 |
|---|---|---|
| `fetchNui` 打 `POST https://${GetParentResourceName()}/${event}`，`appQuery` 超时 9000ms | `resources/[custom]/custom-phone/web/src/utils/nui.ts` 110-152 | 事件名、host、超时都可从 Console 直接读到 |
| 前端把 fetch 抛错统一归一成 `query_failed` | `resources/[custom]/custom-phone/web/src/core/request.ts` 46-52 | **只要 UI 显示 `query_failed`，就说明 fetch 层失败了**，不是服务端业务错误、也不是 Lua 的 8s `timeout` |
| Lua 侧 `appQuery` 由 `PhoneBridge.RegisterNui('appQuery', …)` 注册，进入后第一句就是 `TriggerServerEvent('phone:server:focusState', { phase='appQuery-hit' })` | `resources/[custom]/custom-phone/client/main.lua` 937-943 | “没有 `appQuery-hit`” = 回调函数体**一行都没执行** |
| `PhoneBridge.RegisterNui` 用 `pcall` 包住 handler，抛错会打印 `[custom-phone][bridge] NUI appQuery failed:` 并 `cb({success=false,error='handler_error'})` | `resources/[custom]/custom-phone/client/core/bridge.lua` 194-208 | 若有这条 print，说明**进过**回调且抛错；若没有，说明连 `pcall` 都没执行到 |
| `PhoneBridge.Request` 8s 到点回 `{success=false,error='timeout'}` | `resources/[custom]/custom-phone/client/core/bridge.lua` 89-96 | 若 UI 显示的是 `timeout` 而不是 `query_failed`，那回调**已经命中**，问题在服务端/PhoneApps |
| 服务端 `focusState` 只接受白名单 phase，且**按 phase 5 秒限流** | `resources/[custom]/custom-phone/server/main.lua` 1244-1310 | 两次并发查询（`Promise.all([units, incidents])`）只会打印一条；日志“没有”也可能是被限流吞了 |
| `clientError` 回调已存在，服务端会打印 `[custom-phone][nui-error] src=… source=… event=… status=…`，按 source 10 秒限流 | `resources/[custom]/custom-phone/client/main.lua` 951-954、`resources/[custom]/custom-phone/server/main.lua` 1330-1350 | 这是现成的“探针回调”：一个 POST 就能同时验证路由、注册、Lua、服务端日志四段链路 |
| 构建产物文件名曾固定为 `index.js`（无 content hash；现已改为 `assets/[name]-[hash].js`） | `resources/[custom]/custom-phone/web/vite.config.ts` 的 `entryFileNames` | CEF HTTP 缓存容易命中旧 bundle，必须实测而不是假设 |

**推论链（很重要，先记住）**：

```
UI 显示 query_failed
  ⇒ fetchNui 的 fetch 抛错，或 resp.json() 解析失败
  ⇒ 请求在「CEF 发出 → NUI 路由 → Lua 回调」这条链上就断了
  ⇒ 与服务端业务、PhoneApps.Query、数据库、权限全部无关，先不要看那些
```

另外：`fetchNui` 里是 `return await resp.json()`，**没有检查 `resp.ok`**。
所以 404（空 body）在 JS 侧只会变成一个 `SyntaxError`，HTTP 状态码只能去
DevTools → Network 看。这就是为什么“UI 只显示查询失败”这件事本身信息量很低。

---

## 1. 60 秒分流：五个探针

按顺序做，任一步给出结论就停。

### 探针 0：确认你看的是“那个”日志

```bash
# 仓库内服务端日志（txAdmin 默认落盘位置）
cd /home/swk/Documents/deepseek-harness/default-workspace/T-City
grep -nE "script:custom-phone|\[custom-phone\]\[" txData/default/logs/fxserver.log | tail -30
```

坑：控制台行首是**右对齐补空格**的 `[     script:custom-phone]`，
`grep -F "[script:custom-phone]"` 会一条都匹配不到。

同时对照一条“已知一定会出现”的基线：手机成功打开时应有

```
[custom-phone][focus] src=1 phase=open-ack attempt=0 focused=true keepInput=true
```

- 有 `open-ack` 但没 `appQuery-hit` → 日志可信，问题真的在 appQuery 这条路径上（继续探针 1）。
- 连 `open-ack` 都没有 → **先修证据**（看的是旧文件/另一个实例/txAdmin 控制台没落盘），
  见 §4.3，此时任何“没有日志”的结论都不成立。

### 探针 1：看 JS 侧的错误类型

`nui_devtools` 打开 DevTools → Console，过滤词：`Phone request failed`（`request.ts:50` 必打）
和 `Failed to fetch NUI event`（`nui.ts:148` 必打）。

| Console 里的错误 | 含义 | 下一步 |
|---|---|---|
| `TypeError: Failed to fetch` | 请求根本没拿到可读响应：CORS/证书/CSP/协议/错误 host | 探针 2 + §3.7/§3.8 |
| `SyntaxError: Unexpected end of JSON input` | 拿到了 **200 或同源空 body** | 多半是回了个空响应，看 Network |
| `AbortError: signal is aborted without reason` | 9s 内没有任何响应（回调挂住/请求被吞） | 探针 4 |
| 没有上面任何一条（控制台干净） | 代码没跑到这里 → 旧 bundle / UI 没执行 refresh | 探针 2 的 bundle 指纹 |

### 探针 2：一枪打完四段链路（现成回调，不改代码）

DevTools Console 粘贴：

```js
(async () => {
  const res = GetParentResourceName();
  console.log('parentResource =', res, '| page =', location.href);
  const t0 = performance.now();
  try {
    const r = await fetch(`https://${res}/clientError`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify({ source: 'probe', event: 'manual', status: 0, message: 'nui probe', stack: '' }),
    });
    console.log('clientError probe ->', r.status, r.type, Math.round(performance.now() - t0) + 'ms');
  } catch (e) {
    console.log('clientError probe THREW', e.name, e.message, Math.round(performance.now() - t0) + 'ms');
  }
})()
```

判定：

- `200` + 服务端出现 `[custom-phone][nui-error] … source=probe …` → **CEF→路由→Lua→服务端全通**。
  问题只可能出在 `appQuery` 这一个名字上（未注册/被覆盖）或前端根本没发。
- `404`（Network 里能看到）或 `Failed to fetch` → 是**资源级**路由问题（host 名错、页面不是本资源的、资源未注册），
  直接跳 §3.2 / §3.4 / §3.1。
- 请求挂住直到你手动打断 → Lua 侧接了但不回（罕见；说明 `clientError` 也被覆盖了）。

### 探针 3：只打 `/appQuery`

```js
(async () => {
  const t0 = performance.now();
  try {
    const r = await fetch(`https://${GetParentResourceName()}/appQuery`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify({ app_id: 'police_mdt', query: 'units', params: {} }),
    });
    const txt = await r.text();
    console.log('appQuery ->', r.status, Math.round(performance.now() - t0) + 'ms', 'body:', txt.slice(0, 300));
  } catch (e) {
    console.log('appQuery THREW', e.name, e.message, Math.round(performance.now() - t0) + 'ms');
  }
})()
```

**同时**盯服务端：出现 `phase=appQuery-hit` 即证明回调进入。

### 探针 4：bundle 指纹（排除旧缓存）

DevTools Console：

```js
(async () => {
  const src = document.querySelector('script[type=module]').src;
  const txt = await fetch(src, { cache: 'no-store' }).then(r => r.text());
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(txt));
  const hex = [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('');
  console.log({ src, bytes: txt.length, sha256: hex, hasAppQuery: (txt.match(/appQuery/g) || []).length });
})()
```

本机对照（磁盘上的构建产物）：

```bash
cd "/home/swk/Documents/deepseek-harness/default-workspace/T-City/T-CityLite.base/resources/[custom]/custom-phone"
sha256sum html/assets/index.js; wc -c < html/assets/index.js
grep -o "appQuery" html/assets/index.js | wc -l
```

`bytes`/`sha256` 不一致 → **页面跑的是旧 bundle**（§3.1），后面所有 Lua 侧推断都不作数。

### 判定矩阵（探针 2 × 探针 3）

| `/clientError` 探针 | `/appQuery` | 结论 | 去 |
|---|---|---|---|
| 200 + 服务端 nui-error 行 | 404（Network 可见） | 资源路由正常，只有 `appQuery` 这个名字没注册/被覆盖 | §3.3 |
| 200 | 挂 9s（AbortError） | 注册在，但 `cb` 从未被调用（抛错被吞/漏调用/资源重启打断） | §3.5 / §3.6 |
| 200 | 200 + `{success:true}` | NUI 链路没问题，是业务/服务端问题（`PhoneApps.Query`） | 查 server 日志，非本手册 |
| 404 / Failed to fetch | 同左 | 资源级全坏：host 名、页面来源、ui_page、资源没起来 | §3.2 / §3.4 / §3.1 |
| TypeError | TypeError | 传输层：CORS / 证书 / CSP / 协议 | §3.7 / §3.8 |

---

## 2. 时间/状态签名速查

| 现象 | 最可能的层 |
|---|---|
| 错误在 **< 200ms** 内出现 | 请求被拒（404 未注册 / CORS / CSP / 证书）；不是 Lua 挂住 |
| 错误在 **~9000ms** 出现（`AbortError`） | 回调被接受但永不回答，或请求发到了一个死掉的运行时 |
| 首次刷新失败、**再点一次成功** | 时序（§3.6）或一次性的热点路径抖动 |
| 只有 MDT 失败，短信/联系人正常 | 只与 `appQuery`/`appAction` 两个名字有关（§3.3），公共链路是好的 |
| 所有 NUI 回调都失败，但 `SendNUIMessage` 正常 | 页面在跑，但 host/注册错（§3.2/§3.4）——单向通道不代表双向通 |
| 重启资源后一段时间内失败，之后自愈 | 旧 bundle（§3.1）或重启窗口（§3.6） |

> “页面能收到 `phone:open`、能回 `phoneOpenAck`”只证明 **Lua→CEF 与 CEF→Lua 的
> `phoneOpenAck` 这一条**通；它不能证明 `appQuery` 已注册，也不能证明页面跑的是当前构建。

---

## 3. 原因清单（按本项目的先验概率排序）

每条格式：**签名 → 60 秒证实/排除 → 修复**。

### 3.0 NUI 应答通道是可调用表，被 `type(cb) ~= 'function'` 丢掉（2026-10-25 实测命中）

**已证实的事实**（本 build）：`RegisterNUICallback(name, function(data, cb) ... end)` 的
`cb` **不一定是 `function`**。经探针打印，此 FXServer build 交下来的是
`type(cb) == 'table'`，内容为 `{ __cfx_functionReference = '<ref>' }` 且 **有 `__call` 元方法**。

**签名**（三条同时成立，几乎可以直接定案）
- NUI 侧 fetch **挂到超时**才失败：`AbortError: The user aborted a request`，`status=-`，
  不是 404 空 body、不是 `TypeError: Failed to fetch`。
- 服务端**能收到**请求（`[arrived]`/`appQuery-hit` 有日志），甚至已经回包，但前端永远拿不到。
- 同一资源的**普通回调**（如 `getPhoneData`）却工作正常——因为它们直接 `cb(...)`，
  没有经过任何 `type(cb)` 守卫。

**根因**：任何形如 `if type(cb) ~= 'function' then return end` 的守卫，在拿到函数引用表时
会**静默 return**，`cb` 永不调用 ⇒ CEF 的 fetch 永久 pending ⇒ 前端只能报
`query_failed` / `action_failed`（`resources/[custom]/custom-phone/web/src/core/request.ts` 的传输层兜底码）。

**修复**：用统一的适配层（`PhoneBridge.AnswerFn`），顺序为
1. `type == 'function'` → 直接用；
2. 表且有 `__call` → `return function(r) return cb(r) end`（官方语义，实测可用）；
3. 表且只有 `__cfx_functionReference` → `Citizen.InvokeFunctionReference(ref, r)`；
4. 都不成立 → **返回 nil 并拒绝执行 handler**（宁可让前端拿到确定的超时码，也不要
   跑一半留副作用）。

**顺带教训**：`rawget(_G, 'X')` 在 FiveM 里拿不到**其他脚本**定义的全局（每个脚本有独立
env，只有普通读取才走 `__index` 回退到共享表）。跨文件取模块请用 `local d = X; if type(d)…`
而不是 `rawget(_G, 'X')`。

### 3.0a `IsNuiFocused()` 恒 false，拿它判断"焦点还在不在"会把关闭变成重开（2026-10-27 实测命中）

**已证实的事实**（本 build，FXServer 37872）：`IsNuiFocused()` 与
`IsNuiFocusKeepingInput()` **在游戏内恒返回 false**。取证：`[custom-phone][focus]` 的 61 条
事件（open-nui-sent / reassert / close 等，全是 `SetNuiFocus` 之后打的）里
`focused=true` **0 条**；而同一时刻通过 NUI 导出读到的 `PhoneFocus.State().focus` 是 true，
手机也确实在屏幕上、可点。

**签名**
- 手机"打开了"但按 M 关不掉，或者按一次闪一下又回来。
- 服务端 focus 遥测里 `focused=false` 是常量，`keepInput=false` 也是常量。
- 同一个手机在无头 harness 里断言 `env.nui.focused == true` 通过——因为桩如实反映了
  `SetNuiFocus` 的入参，而真机原生不反映。

**根因**：把引擎原生当真相来源去驱动状态机。曾经的 toggle 是
`if Surface.IsOpen() then if IsNuiFocused() then ClosePhone() else 复位重开 end`；
原生恒 false ⇒ 每次"关闭"都走进"复位重开"，玩家看到的是关不掉的手机。

**修复**（两条一起）
1. 状态机只看自己的账：`Surface.IsOpen()` 决定开关，`PhoneFocus.State()` 决定谁持有焦点；
   原生只作为**诊断字段**上报（`nui_focus_native`），不参与任何判定。
2. 半开（NUI 没应答）交给 `OpenPhone` 的 `AwaitAck` 超时兜底，不要在 toggle 里再猜一次。

**顺带教训**：`RegisterCommand` 同名后注册者覆盖先注册者。本项目曾同时注册两个 `phone`
（toggle 与 `/phone` 强制形态），后者把前者覆盖成"只开不关"，M 键因此永远关不掉手机。

### 3.0d 真机上鼠标点不进 NUI：OS 光标被游戏锁在屏幕角（2026-10-27 实测）

**已证实的事实**：窗口模式，手机开着（NUI 有焦点、键盘可用），调用
`SetCursorPos(2382, 816)` 之后用 `GetCursorPos` 读回来是 **(2559, 1439)** ——
就是 2560×1440 屏幕的右下角。`mouse_move` 报 "mouse -> (2382,816)" 是**请求**，不是结果。

FiveM 侧的证据：`code/components/nui-core/src/CefInput.cpp` 用
`GetCursorPos() + ScreenToClient()` 决定 CEF 的鼠标坐标，所以合成点击永远落在
(2559,1439) —— 那是手机框外面 → 点击等于"点了背景"。

**签名**
- 键盘有效（`Escape` 能关手机），鼠标无效——说明焦点链是通的，坏的只是坐标。
- 任何"点击"都表现为点同一个位置：点击图标、点图标间隙，结果完全一样。
- 用 PowerShell `[System.Windows.Forms.Cursor]::Position` 读到的坐标恒定在屏幕角落。

**为什么会被锁**：GTA 在窗口模式下用 ClipCursor + 每帧回写光标（raw input），
`SetCursorPos` 的写入被游戏立刻覆盖。这是游戏侧行为，不是 NUI 的问题。

**结论：自动化不要点像素。** 走消息导航（本项目已提供）：
`/phoneui <app>`（需要 `setr phone_ui_nav "1"`，生产默认关）→
`SendNUIMessage({action='phone:navigate', app='quests'})` → NUI 切页。
动态 App（任务/MDT）在 `activeApp` 里是 `dyn:<id>`，消息里只报 id 即可。

**仍然没解决的**：怎么在真机上"点任意坐标"（例如测一个 pure-click 的交互）。
可能的路线：`SetCursorLocation(x, y)`（GTA 原生，0..1 归一化，给暂停菜单/NUI 用）
或让资源自己加"可编程点击"的调试入口。在被证实之前，别把像素点击写进验收脚本。

### 3.0c keepInput 让按键同时到达游戏和 CEF，两边各关一次就是"按 M 没反应"（2026-10-27 实测命中）

**已证实的事实**：手机开着时 `SetNuiFocusKeepInput(true)`，一次 M 按键会**同时**被
① 游戏的 `RegisterKeyMapping('phone')` 和 ② CEF 页面的 `window.keydown` 收到。
Lua 那边 toggle 打开手机，同一帧 CEF 的旧处理器又 `closePhone()` ——
服务端遥测里能看到成对的 `open-start` 紧跟 `close-start`，画面上就是闪一下没了。

**签名**
- `/live/clients` 的 `open` 在按下后 1s 还是 false，但 `[custom-phone][focus]` 日志里
  `open-nui-sent → open-start → open-ack → close-start` 连着出现。
- 同样的按键"有时开、有时不开"：取决于按键落下时 CEF 是否已经挂上（重启资源后最先几下常失败）。
- 无头 NUI 测试全绿——因为测试里只有一个键盘监听者。

**修复**：按键归属只能有一个主人。`m/M` 归 Lua（它管 Surface/PhoneFocus/DeviceLock），
NUI 只保留自己也独占的键（`Escape`）与鼠标动作（右键 = contextmenu）。

**教训**：凡是 `keepInput=true` 的 NUI，都要问一句"这个键谁来处理"，否则就是双重处理。

### 3.0b 新增脚本文件"明明在、就是不执行"（`restart` 不重读 fxmanifest）

**签名**
- 文件存在、`luac -p` 通过、`fxmanifest.lua` 里也确实写了，但运行时完全看不到它的
  任何痕迹（连加载时第一行 `print`/事件都没有）。
- 同一个资源的**已有**脚本改动却生效正常。
- 之前有人只用过 `restart <resource>`。

**根因**：服务端缓存解析后的资源元数据（含脚本清单）。`restart` 用缓存清单重跑脚本，
所以**新加进清单的文件不会被加载**；只有 `refresh`（或重启服务器）才会重新解析
fxmanifest。客户端同理：客户端缓存整份资源，`refresh` + 资源重启后才能拿到新清单。

**60 秒证实/排除**
1. `refresh` → `restart <resource>`；
2. 在该文件**第一行**（`PhoneDiag = ...` 之前）放一行 `print('[x] file loaded')`；
3. 仍然没有 ⇒ 才是真的没加载；有 ⇒ 说明之前是清单缓存，不是代码问题。

**修复/预防**：模块文件自己带一行启动自证
（`print('[custom-phone][diag] server trace core loaded (level=N)')`），
以后任何"模块没生效"的怀疑都能用一行日志排除。

### 3.1 CEF 缓存了旧 bundle（本项目概率最高）

**为什么这里高发**：`vite.config.ts` 曾把产物固定成 `index.js`、`index.css`（无 hash；本仓库 2026-10-25 起已改为带内容哈希）
（旧配置的 `entryFileNames`/`assetFileNames` 无 hash，故旧包名恒定），`resources/[custom]/custom-phone/html/index.html` 里也是
`<script type="module" crossorigin src="./assets/index.js">`。URL 恒定 + CEF 有 HTTP 缓存
⇒ `restart custom-phone` 重建了页面，但**不保证重新拉取 JS**。旧 bundle 照样会 ack `phone:open`
（这个回调一直存在），也照样会显示“查询失败”，但发的事件名/host/超时逻辑可能是旧的。

**签名**
- 探针 4 的 `sha256`/`bytes` 与磁盘不一致。
- `restart` 后立刻失败、隔几分钟或强刷后自己好了。
- Network 里 `index.js` 显示 `(from disk cache)` / 200 without request。
- Console 里的报错文案/堆栈在源码里搜不到（说明是上上个版本）。

**60 秒证实/排除**
1. 跑探针 4，和 `sha256sum html/assets/index.js` 对比。
2. DevTools → Network 勾 **Disable cache** → `Ctrl+Shift+R` 硬刷新后重跑探针 3。
   失败消失 = 已证实。

**修复**
- 现场：DevTools（Application → Storage → Clear site data 或右键刷新按钮选
  “Empty cache and hard reload”）→ 关手机 → F8 `restart custom-phone` → 再按 M 打开。
- 根治（建议，需改构建，不在本手册范围）：产物加内容指纹（`entryFileNames: 'assets/[name]-[hash].js'`）
  或注入构建戳（`__BUILD__ = '<git-sha>-<timestamp>'`）并在 `main.ts` 打印，
  以后用一行 console 就能判断新旧。

---

### 3.2 宿主资源名不符 / `GetParentResourceName()` 不是 `custom-phone`

`fetchNui` 打的是 `https://${GetParentResourceName()}/${event}`；NUI 按**host = 资源名**
路由到该资源的回调表。页面本身在 `https://cfx-nui-custom-phone/…`，两者是**不同 host**，
所以“用 `window.location.hostname` 拼 URL”是经典 404 来源（社区实录见参考 6）。

**签名**
- `GetParentResourceName()` 返回 `undefined`（页面跑在外部 `ui_page https://…` 或纯浏览器预览），
  或返回别的名字（`qb-phone`、`custom-ui`）。
- 探针 2/3 的 URL 里 host 不是 `custom-phone`。
- 探针 2 直接 404。

**60 秒证实/排除**
```js
console.log('parent =', GetParentResourceName(), '| host =', location.host, '| href =', location.href);
```
- `parent === 'custom-phone'` 且 `location.host === 'cfx-nui-custom-phone'` → 正常，排除本项。
- `location.host` 是 `cfx-nui-其它资源` → 你看到的是**别的资源的页面**（转到 §3.4）。
- `parent` 为 `undefined` → 当前页面不是 FiveM 托管的 NUI（浏览器预览 / 外部 url），
  `isBrowser()` 会走 mock 分支，真实请求根本不会发生。

**修复**
- 只用 `GetParentResourceName()`，禁止 `location.hostname`/硬编码。
- 若支持浏览器预览，`isBrowser()` 分支必须完全绕过 fetch（`nui.ts` 已如此），
  不要在预览里“顺手”测真实回调。
- 资源目录改名（例如 `custom-phone` → `tcity-phone`）必须同步 `ensure`、
  `exports['custom-phone']`、`GetCurrentResourceName()` 比较处；
  NUI host 用的是**运行中的资源名**，不是 manifest 里的文件名。
- 社区经验：资源名保持**全小写**，历史上大小写不一致会导致回调 404（参考 7，社区而非官方结论，
  但成本为零，直接遵守）。

---

### 3.3 回调未注册，或被同名注册覆盖

**机制（要说准）**
- 一个资源内，`RegisterNUICallback` 的回调表按**名字单槽**：同名再注册会**静默覆盖**前一个，
  不会报错（官方 issue #1848 标题即是 “NUI Callbacks can only be registered once per type”，
  参考 5）。`RegisterRawNuiCallback` / 老的 `__cfx_nui:<name>` 事件桥混用时同样互相顶掉。
- **跨资源不会互相覆盖**：回调表属于各自资源运行时，A 资源的 `appQuery` 不会顶掉 B 资源的。
  所谓“第三方资源冲突”的真实形态只有三种：
  1. 页面 POST 到了第三方资源的 host（§3.2）；
  2. 第三方把代码 `load()` 进你的运行时（少见）；
  3. 第三方抢了同名 **key mapping / 打开逻辑**，导致你以为在测 A 实际在测 B。
- 本项目目前 `appQuery` **只有一处**注册（`PhoneBridge.RegisterNui`）。所以只要这里被覆盖/未执行，
  就必然 404 或挂起。

**签名**
- 探针 3 得到 404（Network 可见，JS 侧多为 `TypeError`/`SyntaxError`），探针 2 正常。
- F8 里**没有** `[custom-phone][bridge] NUI appQuery failed:`（说明 handler 没进），
  也**没有** `phase=appQuery-hit`。
- 资源启动时若 `resources/[custom]/custom-phone/client/core/bridge.lua` 没先加载，`PhoneBridge` 为 nil，`main.lua` 会在
  第 937 行直接报错并**中断该文件后续注册**（包括 `clientError`）——这时探针 2 也会失败。

**60 秒证实/排除**
```bash
cd "/home/swk/Documents/deepseek-harness/default-workspace/T-City/T-CityLite.base/resources/[custom]/custom-phone"
grep -rn "RegisterNUICallback\|RegisterRawNuiCallback\|RegisterNuiCallback" client/ | sort
grep -n "phone-app-readers" -A4 client/main.lua     # 确认这段还在（测试会抽取这两个注册）
```
- 输出里 `'appQuery'` 出现 **且只出现一次**，且位于 `PhoneBridge.RegisterNui` 内 → 注册源没问题。
- 出现两次（含第三方 shim / 旧代码残留）→ 后者覆盖前者，已证实。
- F8 启动段有 `attempt to index a nil value (global 'PhoneBridge')` → 加载顺序坏了
  （`fxmanifest.lua` 的 `client_scripts` 顺序：`bridge.lua` → `focus.lua` → `events.lua` → `main.lua`）。

**修复**
- 单一注册入口（本仓库已经是 `PhoneBridge.RegisterNui`）；禁止在别处再注册同名。
- 给注册加**显式断言**（推荐，非本次改动）：在 `RegisterNui` 内维护 `registeredNames`，
  重复时 `print('[custom-phone][bridge] duplicate NUI callback: '..name)` ——静默覆盖是最贵的 bug。
- 启动时打印已注册名字清单（一行），以后 404 时先对数。

---

### 3.4 `ui_page` 与实际加载页面不一致

官方 manifest 文档明确：`ui_page` 指定的文件**以及它的依赖**都必须出现在 `files{}` 里
（参考 4）。缺项时页面/资源 404，但 CEF 可能仍显示上一个成功加载的页面（观感上“手机是好的”）。

**签名**
- `location.href` 不是 `https://cfx-nui-custom-phone/html/index.html`。
- Network 里 document 请求 404，或 `index.js` 404 但页面有内容（旧帧残留）。
- 改完 `index.html` 没生效，但改 `index.js` 生效（或反之）。

**60 秒证实/排除**
```bash
cd "/home/swk/Documents/deepseek-harness/default-workspace/T-City/T-CityLite.base/resources/[custom]/custom-phone"
grep -n "ui_page\|files" -A6 fxmanifest.lua
ls -l html/index.html html/assets/index.js html/assets/index.css
```
```js
// DevTools
console.log(location.href, document.title);
```
- `ui_page` = `resources/[custom]/custom-phone/html/index.html`，`files{}` 覆盖 `resources/[custom]/custom-phone/html/index.html` + `html/assets/*`，文件都在
  → 排除。本仓库当前满足。
- `location.href` 指向别的资源 → 打开逻辑/焦点栈里另一个 UI 抢先（`custom-ui` 只管焦点、无 ui_page，
  但第三方 UI 可能自带 `ui_page`）。

**修复**
- `ui_page` 指向真实存在的入口；`files{}` 用 `html/**` 或显式列全（含 `html/assets/audio/*` 这类子目录）。
- 改 manifest 后必须 `restart custom-phone`（manifest 不热重载）。
- 加静态测试（本仓库已有 `tests/architecture/test_nui_client_contracts.py` 这类契约测试，
  可扩展一条“ui_page 与 files 对齐”）。

---

### 3.5 回调抛错被吞 / `cb` 没调用 / 返回值不可 JSON 编码

官方文档写明：**必须始终调用 `cb`**，否则请求会超时并在 fetch 侧抛错（参考 1）。

本仓库有两层保护，正好可以用来定位：

| 现象 | 结论 |
|---|---|
| F8 有 `[custom-phone][bridge] NUI appQuery failed: <err>` | **进过** handler 且抛错；`pcall` 已兜底回 `handler_error`（UI 会显示 handler_error，不是 query_failed） |
| 什么都没有，请求挂 9s | 连 `pcall(handler, …)` 都没执行：名字没注册 / 没路由到这里（回 §3.3） |

**其余可以吞掉 `cb` 的写法（写代码时要防）**
```lua
RegisterNUICallback('x', function(data, cb)
    if not ok then return end          -- 提前 return，cb 永不调用 → fetch 挂到超时
    cb({ success = true })
    cb({ success = true })             -- 二次调用，CEF 侧行为未定义
end)
```
- `cb` 传了不可 JSON 编码的值（userdata、function、NaN 混进表里）→ 序列化失败，前端拿不到 body。
- handler 里 `Wait()`/`Citizen.Wait` 长时间阻塞（同步 SQL 直连、死循环）→ 超过 9s 一样表现为超时。
- `cb` 本身是 nil（`if type(cb) ~= 'function' then return end` 直接吞掉）——本项目 `RegisterNui`
  第 199 行就是这样，虽然五方不会传 nil，但自定义 wrapper 里出现过。

**60 秒证实/排除**
```lua
-- 【临时，测完删】在 client/main.lua 的 appQuery 注册外层加一行
print('[probe] appQuery registered', type(PhoneBridge), type(PhoneBridge and PhoneBridge.Request))
```
重启资源，F8 看有没有 `[probe]`：没有 = 文件没加载 / 前面报错中断；有 = 注册执行了。
再用探针 3 打一发，看是否出现 `[custom-phone][bridge] … failed`。

**修复**
- handler 内**所有分支**都要 `cb(...)`；用 `answerOnce` 包装（`bridge.lua` 已实现）。
- 任何业务异常走 `cb({success=false, error='…'})`，不要靠抛错。
- 禁止在 NUI 回调里做同步阻塞 I/O；服务端交互一律走 `PhoneBridge.Request`（带 request_id，1 次答复）。

---

### 3.6 时序：页面在 Lua 注册之前就发请求

两个方向都存在：

1. **资源刚 start/restart**：CEF 里的旧页面还活着（或立即重载），第一帧就把 `appQuery` 打出去，
   而新的 client Lua 运行时还没跑完注册 → 404。窗口通常 100–500ms。
2. **页面重启后没有 `phone:open` 门控**：直接从 `localStorage`/默认 app 恢复 MDT 并发起查询。

**签名**：`restart custom-phone` 后立即点刷新必失败，等 1 秒再点成功；Network 里失败请求发生在
页面 document 加载完成后的极短时间内。

**60 秒证实/排除**
```bash
# 客户端 F8 里连续执行，观察失败请求是否都落在 start 之后 1s 内
restart custom-phone
# 打开手机，立刻点 MDT 刷新 → 记时间；等 2s 再刷新一次
```
配合 Network 的 Waterfall 时间轴：失败请求若都集中在资源启动后 ~1s 内 → 证实。

**修复**
- UI 端所有初始化请求挂在 `phone:open` 之后（本仓库 `App.svelte` 已经是这个结构，
  `loadPhoneData()` 在 `phone:open` 事件里调用），**不要**在模块顶层或 `onMount` 里直接查业务数据。
- `OpenPhone` 用 `PhoneBridge.AwaitAck` 确认帧就绪（已实现，2.5s 超时会打
  `[custom-phone][bridge] phone:open unacked after 2500ms`）。
- 对 404 做一次 250–500ms 的自动重试（仅限幂等的 query），比让玩家手动重试体验好。

---

### 3.7 fetch 因 CSP / 证书 / 混合内容失败

**签名**（DevTools Console 全文是关键，别只看 `TypeError`）：
- `net::ERR_CERT_AUTHORITY_INVALID` / `ERR_CERT_COMMON_NAME_INVALID`
- `Refused to connect … because it violates the following Content Security Policy directive: "connect-src …"`
- `Mixed Content: The page at 'https://…' was loaded over HTTPS, but requested an insecure resource 'http://…'`
- `net::ERR_NAME_NOT_RESOLVED`（host 拼错、把资源名写成了域名）

**60 秒证实/排除**
- DevTools → Network → 该请求 → Status 列显示 `(failed)` / `(blocked:csp)`；点开看 `Provisional headers`。
- Console 过滤器：`CSP`、`Mixed Content`、`ERR_`。
- 检查 `resources/[custom]/custom-phone/html/index.html` 是否被加了 `<meta http-equiv="Content-Security-Policy">`（当前没有）。
- 检查 `ui_page` 是否被改成了外部 `https://…`（外部页面既没有 `GetParentResourceName`，
  也过不了 CORS/CSP）。

**修复**
- 只用相对路径 `./assets/…`（`vite base: './'` 已正确），不要引入 `http://` 资源。
- 不要在 NUI 页面加 CSP meta；确需加时 `connect-src 'self' https://cfx-nui-*` 之类必须放行 NUI host，
  但更简单的做法是别加。
- 外部 `ui_page` 域名必须有效证书；本地自签证书 CEF 不接受。

---

### 3.8 https origin 与 CORS

**先把事实说清**：页面 origin 是 `https://cfx-nui-custom-phone`，请求目标是
`https://custom-phone/…` —— 这**本来就是跨源请求**，靠 FiveM NUI 层返回的 CORS 头放行
（这也是官方示例用 `GetParentResourceName()` 的原因）。因此：

- 正常路径不存在“需要你自己配 CORS”的问题；
- 一旦你绕开 NUI 路由（`http://`、`localhost:13172`、错误 host、外部页面、`file://`），
  就会退化成真正的 CORS 失败，且**浏览器会隐藏真实状态码**（JS 只看到 `TypeError: Failed to fetch`，
  Network 里才能看到 404/403）。
- `resources/[custom]/custom-phone/html/index.html` 上 `<script crossorigin>` 是**同源**加载，安全，不是嫌疑对象（省得白查）。

**60 秒证实/排除**
```js
// 这三个 host 的正常/异常，一眼区分“路由错”还是“网络错”
fetch(`https://${GetParentResourceName()}/clientError`, {method:'POST', headers:{'Content-Type':'application/json'}, body:'{}'})
  .then(r => console.log('resource host ok', r.status))
  .catch(e => console.log('resource host FAIL', e.message));
```
再对照 `location.host`（应为 `cfx-nui-custom-phone`）。若 `location.host === 'localhost:13172'`
说明你在**远程调试器页面**里执行代码，而不是在 NUI 页面上下文里——这是常见误判：
DevTools 顶部 target 选错了。

**修复**
- 永远用 `GetParentResourceName()`；不要手写 host，不要 `location.hostname`。
- 在 `http://localhost:13172/` 选 target 时确认选的是 `https://cfx-nui-custom-phone/…` 那个页面。

---

### 3.9 “没有 `appQuery-hit`”本身可能是证据侧漏（不是原因，但必须先排除）

- **按 phase 5 秒限流**（`FOCUS_COOLDOWN = 5`）：MDT 一次刷新打两条 `appQuery`
  （`Promise.all([units, incidents])`），**只会打印第一条**；如果你在 5 秒内又点了刷新，
  第二次也静默。**测试姿势**：点一次刷新，等 ≥6 秒，再点一次；或只看“窗口内是否出现过”。
- **被丢弃的事件不会立刻说明**：限流期间累计的丢弃会在下一次允许打印时补一行
  `dropped N event(s) in the last window` —— 看到这行也说明链路是通的。
- **日志前缀有对齐空格**，`grep -F "[script:custom-phone]"` 匹配不到（见探针 0）。
- **客户端 `print` 不进服务端日志**：`[custom-phone][bridge]` 在 F8 / `CitizenFX_log` 里，
  不在 `fxserver.log` 里。
- **看错实例**：txAdmin 面板里粘的日志、`txData/default/logs/fxserver.log`、
  另一个 server data 目录，三者可能不是同一个进程。

---

## 3.9 用截图当证据：窗口模式 + 先聚焦

真机上"界面到底画出来没有"只有像素能回答。经验值（2026-10-27 实测）：

| 条件 | 结果 |
|---|---|
| 独占全屏 | `PrintWindow` 全黑（亮度 0–2%） |
| 窗口模式 + 窗口在前台 | 亮度 96–99%，手机/平板/列表文字都清晰 |
| 窗口模式但窗口不在前台 | 2%（黑帧），`focus_window` 之后恢复 |

所以固定顺序：`focus_window` → 等 1.5s →（可选）`mouse_move` 制造一次输入让 DWM 重绘 →
`screenshot`。截完先看亮度：低于 50% 就是没抓到，重来，别拿它当"界面没渲染"的证据。

## 4. FiveM 客户端日志与 NUI 日志怎么拿

### 4.1 三条互不相通的通道

| 通道 | 看什么 | 怎么看 |
|---|---|---|
| F8 客户端控制台 | 客户端 Lua 的 `print`/错误、资源加载错误、`RegisterNUICallback` 相关报错 | 游戏内按 <kbd>F8</kbd>；也可用 VConsole2 在游戏外看（参考 3） |
| NUI DevTools（CEF） | `console.log/error`、Network、Sources、Application | F8 执行 `nui_devtools`；或浏览器打开 `http://localhost:13172/`（参考 2） |
| 服务端控制台 | `[custom-phone][focus] …`、`[custom-phone][nui-error] …` | txAdmin Live Console，或落盘日志（§4.3） |

**最容易犯的错**：在 F8 里找 `console.error('Phone request failed: appQuery')` —— 它只出现在
NUI DevTools 的 Console；反过来，在 DevTools 里找 `print('[custom-phone][bridge] …')` 也永远找不到。

### 4.2 打开 NUI DevTools

1. `nui_devtools` 是**开发者命令**，需要开发者模式，否则报
   `Access denied for command …`。开启方式（官方）：启动参数加 `+set moo 31337`
   （例如改快捷方式目标），或使用 Beta/Latest 更新通道（参考 3）。
2. 命令名大小写两个版本都出现在官方文档里：Console Commands 页写 `nui_devtools`，
   Fullscreen NUI 页写 `nui_devTools`。两种都试一遍，报 `Access denied` 才是开发者模式没开。
3. 更稳的路径：游戏运行中，用 Chrome/Edge 打开 `http://localhost:13172/`，
   在 target 列表里选 `https://cfx-nui-custom-phone/html/index.html`（**别选错 target**，
   选错就会出现 §3.8 里那种“host 变成 localhost”的假象）。
4. DevTools 里建议一次性设置：Console 勾 **Preserve log**；Network 勾 **Disable cache** +
   **Preserve log**；过滤词 `appQuery`、`clientError`、`index.js`。

**常用过滤词对照**

| 目的 | Console 过滤 | Network 过滤 |
|---|---|---|
| 前端 fetch 失败 | `Phone request failed` / `Failed to fetch NUI event` | `appQuery` |
| 是否 404 | —（状态码看不到） | `appQuery`，看 Status 列 |
| 旧 bundle | `Uncaught` 堆栈里出现源码中不存在的函数名 | `index.js`，看 `(from disk cache)` |
| 页面来源 | `location.href` | document 请求 |

### 4.3 日志文件路径

**客户端（Windows）**

```
%localappdata%\FiveM\FiveM.app\logs\CitizenFX_log_<YYYY-MM-DD>_<HHMMSS>.log
```

- 打开方式：<kbd>Win+R</kbd> 输入 `%localappdata%\FiveM\FiveM.app\logs`。
- `FiveM.app` 是应用数据目录（`CitizenFX.ini` 也在这里，参考 8）。
- 同目录还有 `cef.log` 一类 CEF 日志（视版本而定），NUI 崩溃时值得一起看。
- 客户端 Lua 的 `print` 与运行时错误会进这个文件；**NUI 的 `console.*` 不进**。

**客户端（Linux，Steam/Proton 或 Wine 前缀）**

```bash
# 直接找，别猜 AppID
find ~/.local/share/Steam/steamapps/compatdata ~/Games ~/.wine \
     -path '*FiveM.app/logs*' -name 'CitizenFX_log*' 2>/dev/null | tail
```

典型位置：`<prefix>/drive_c/users/<user>/AppData/Local/FiveM/FiveM.app/logs/`，
其中 `<prefix>` 形如 `~/.local/share/Steam/steamapps/compatdata/<APPID>/pfx`。
Windows 里的 `%localappdata%` 对应 `drive_c/users/<user>/AppData/Local`。

**服务端（本仓库）**

```bash
cd /home/swk/Documents/deepseek-harness/default-workspace/T-City
ls txData/default/logs/            # fxserver.log / server.log / admin.log
grep -nE "script:custom-phone|\[custom-phone\]\[(focus|nui-error|bridge)\]" \
     txData/default/logs/fxserver.log | tail -50
```

实时跟：

```bash
tail -f txData/default/logs/fxserver.log | grep --line-buffered -E "custom-phone|appQuery"
```

### 4.4 把 CEF 错误回传服务端（推荐做法）

现状：`resources/[custom]/custom-phone/web/src/App.svelte` 已挂 `window.addEventListener('error'|'unhandledrejection')` →
`fetchNui('clientError', { message, stack })`；服务端 `phone:server:clientError`
已按 source 10 秒限流、剥控制字符、截断字段，并会打印 `status`/`source`/`event`——
**但前端目前没传这三个字段**，所以服务端日志里它们常年是 `-`。

推荐的目标形态（以后改，不在本手册内动手）：

```ts
// web/src/utils/nui.ts（示意）
const seen = new Map<string, number>();
export function reportClientError(payload: {
  source: string; event?: string; status?: number; message: string; stack?: string;
}) {
  const key = `${payload.source}|${payload.event}|${payload.message}`.slice(0, 200);
  const now = Date.now();
  const last = seen.get(key) ?? 0;
  if (now - last < 10_000) return;   // 客户端去重：服务端 10s 窗口的第一条最重要
  seen.set(key, now);
  void fetchNui('clientError', {
    source: payload.source,          // 'window.onerror' | 'appQuery' | 'fetch'
    event: payload.event,            // 事件名，如 'appQuery'
    status: payload.status,          // fetch 的 HTTP status（若能拿到）
    message: String(payload.message).slice(0, 300),
    stack: String(payload.stack ?? '').slice(0, 500),
  }).catch(() => {});
}
```

要点：

1. **一定带 `status` 与 `event`**：`fetchNui` 现在 `return await resp.json()` 不看 `resp.ok`，
   导致 404 变成 `SyntaxError`；至少要在 catch 里把 `resp.status` 带上（改成先 `resp.text()`
   再 `JSON.parse`，或 `if (!resp.ok) throw Object.assign(new Error('http_'+resp.status), {status: resp.status})`）。
2. **客户端也要限流**：服务端 10s/source 的窗口里第一条最有价值，刷屏只会把第一条挤掉。
3. **不要回传业务数据**（手机号、citizenid、金额）——只回传错误类型与堆栈。
4. 只用 `source`/`event`/`status`/`message`/`stack` 这五个白名单字段；服务端已经只读这几个。
5. 加开关（convar 或 `Config.Debug`），正式服默认关，避免把诊断通道变成攻击面。

---

## 5. 一次性取证脚本（贴给下一个排查的人）

在 NUI DevTools Console 跑，把输出整段贴进 issue：

```js
(async () => {
  const out = { at: new Date().toISOString(), href: location.href, host: location.host,
                parent: (typeof GetParentResourceName === 'function') ? GetParentResourceName() : null,
                ua: navigator.userAgent };
  const src = document.querySelector('script[type=module]')?.src;
  if (src) {
    const t = await fetch(src, { cache: 'no-store' }).then(r => r.text());
    const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t));
    out.bundle = { src, bytes: t.length,
      sha256: [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, '0')).join(''),
      appQueryRefs: (t.match(/appQuery/g) || []).length };
  }
  const probe = async (name, body) => {
    const t0 = performance.now();
    try {
      const r = await fetch(`https://${GetParentResourceName()}/${name}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(body) });
      const txt = await r.text();
      return { name, status: r.status, ms: Math.round(performance.now() - t0), body: txt.slice(0, 200) };
    } catch (e) {
      return { name, error: `${e.name}: ${e.message}`, ms: Math.round(performance.now() - t0) };
    }
  };
  out.probes = [
    await probe('clientError', { source: 'probe', event: 'manual', status: 0, message: 'nui probe', stack: '' }),
    await probe('appQuery', { app_id: 'police_mdt', query: 'units', params: {} }),
  ];
  console.log(JSON.stringify(out, null, 2));
})()
```

配套服务端（同一时间窗内）：

```bash
grep -nE "\[custom-phone\]\[(focus|nui-error)\]" txData/default/logs/fxserver.log | tail -20
```

三条信息凑齐就能定性：**探针 status + 是否有 `appQuery-hit` + bundle 指纹**。

---

## 6. 修复后的验收清单

- [ ] `GetParentResourceName() === 'custom-phone'`，`location.host === 'cfx-nui-custom-phone'`
- [ ] bundle `sha256` 与磁盘一致（探针 4）
- [ ] `clientError` 探针 200，服务端出现 `[custom-phone][nui-error] … source=probe`
- [ ] `appQuery` 探针 200 且返回 `{success:true,data:…}`
- [ ] 服务端出现 `[custom-phone][focus] src=… phase=appQuery-hit`
- [ ] MDT 刷新两次（间隔 ≥6s），两次都在 1s 内出数据，页面不再出现“查询失败”
- [ ] `restart custom-phone` 后立刻打开手机 + 刷新，仍成功（时序回归）
- [ ] 关闭 DevTools 的 Disable cache 与 Preserve log，重跑一遍（避免“只有开调试才正常”）

防回归建议（按性价比排序）：

1. 构建产物加内容指纹或构建戳，并在启动时 `console.log` 一次。
2. `PhoneBridge.RegisterNui` 检测重复注册并打印警告。
3. `fetchNui` 检查 `resp.ok`，把 `status` 带进错误对象（顺带让 `clientError` 有 `status` 可报）。
4. 契约测试里加一条：`ui_page` 路径存在于 `files{}`；`appQuery`/`appAction` 只注册一次。

---

## 7. 参考来源

| # | 来源 | 用来支撑什么 |
|---|---|---|
| 1 | [NUI Callbacks — Cfx Docs](https://docs.fivem.net/docs/scripting-manual/nui-development/nui-callbacks/) | 必须始终调用 `cb`，否则请求超时并在 fetch 侧抛错；`fetch(https://${GetParentResourceName()}/name)` 官方用法；数据必须 JSON 可编码 |
| 2 | [Fullscreen NUI — Cfx Docs](https://docs.fivem.net/docs/scripting-manual/nui-development/full-screen-nui/) | `ui_page`/`files` 关系；`https://cfx-nui-<resource>/` 协议作用域；DevTools `http://localhost:13172/`；焦点栈与 full-screen iframe（无点击穿透） |
| 3 | [Client Console Commands — Cfx Docs](https://docs.fivem.net/docs/client-manual/console-commands/) | F8 客户端控制台；`nui_devtools` = “Opens the NUI dev tools window”；开发者命令需开发者模式（`+set moo 31337` 或 Beta/Latest 通道） |
| 4 | [Resource Manifest — Cfx Docs](https://docs.fivem.net/docs/scripting-reference/resource-manifest/resource-manifest/) | `ui_page` 的文件及其依赖必须用 `files` 引用；支持绝对 URL 作为入口 |
| 5 | [citizenfx/fivem#1848 — NUI Callbacks can only be registered once per type](https://github.com/citizenfx/fivem/issues/1848) | 同一资源内同名回调单槽、后注册覆盖前注册的行为 |
| 6 | [Cfx Forum — NUI callback issues (404 + empty body)](https://forum.cfx.re/t/nui-callback-issues/5414273) | 用 `location.hostname` 而不是 `GetParentResourceName()` 会稳定 404 空 body；未注册回调的签名 |
| 7 | [Cfx Forum — Nui Callbacks (resource name must be lowercase)](https://forum.cfx.re/t/nui-callbacks/336500) | 资源名大小写导致 NUI 回调失灵的社区经验 |
| 8 | [CitizenFX.ini — Cfx Docs](https://docs.fivem.net/docs/client-manual/citizenfx/) | `%localappdata%\FiveM\FiveM.app\` 应用数据目录（日志同源） |
| 9 | [RegisterNUICallback — Cfx Docs](https://docs.fivem.net/docs/scripting-reference/runtimes/lua/functions/RegisterNUICallback/) | Lua 侧 API 语法（已标记为 legacy，新代码用 REGISTER_NUI_CALLBACK 原生） |

日志文件名的 `CitizenFX_log_<date>_<time>.log` 形态与 Linux/Proton 下的
`compatdata/<APPID>/pfx/drive_c/users/<user>/AppData/Local/FiveM/FiveM.app/logs`
属于社区与运维共识（Cfx 官方支持文档只给出 `FiveM.app` 应用数据目录，未逐个列出日志文件名），
排查时以上面的 `find` 命令为准，不要凭记忆拼路径。
