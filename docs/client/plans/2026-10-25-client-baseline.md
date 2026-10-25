# 客户端基线与手机查询故障 —— 计划（2026-10-25）

> 状态：**进行中**（P0-1 待真机复验；P0-2 已落地；P1-1 阶段 0 已落地）
> 指导原则：模块化 / 高性能 / 可拓展 / 安全
> 流程门禁：任何代码任务必须走 **调研 → 计划 → 开发 → 审查**，四关齐全才算交付

---

## 0. 一句话目标

把客户端（NUI/CEF + 客户端 Lua）从"黑盒波动"变成"有证据、可复现、可断言"的一端：任何一次双端联调，都能在 1 分钟内定位断在四段往返（NUI → 客户端 Lua → 服务端 → 回到 NUI）的哪一段。

---

## 1. 已知事实（不是推测）

| # | 事实 | 证据 |
|---|---|---|
| F1 | 手机能打开，NUI 页面与 JS 正常运行 | `phase=open-ack` 到达服务端（`phoneOpenAck` 回执） |
| F2 | `focused=false` / `keepInput=false` 但这不影响界面可见 | `focus` 诊断 4 连（open-nui-sent → open-start → open-ack → reassert），真机上界面可见 |
| F3 | MDT 显示"查询失败" | `PoliceMDT.svelte` 的 `query_failed` 文案；该文案只由 `core/request.ts` 的 catch 分支产生 = **fetch 层失败**，不是服务端错误码 |
| F4 | 服务端日志里没有 `phase=appQuery-hit` | 该 phase 由客户端 `appQuery` NUI 回调的第一行触发；缺失有两种可能：回调没跑，或诊断被限流/日志没捕获（假阴性） |
| F5 | NUI 产物此前是 `assets/index.js`（无内容哈希） | `vite.config.ts` 旧配置 + `html/index.html` 实测引用 |

---

## 2. 调研输入（已完成，3 份文档）

| 文档 | 内容 | 对本计划的直接产出 |
|---|---|---|
| `docs/client/research/fivem-nui-2026.md` | NUI/CEF 机制、`ui_page`/`files`、缓存与 restart 语义、`RegisterNUICallback` 三态失败、焦点真实语义、DevTools/日志通道、性能与安全；34 条可检查规则 | 客户端基线规则清单（P1-2） |
| `docs/client/research/nui-debug-playbook.md` | 5 个 60 秒探针 + 判定矩阵 + 9 类原因按先验概率排序 + 日志获取三条通道 + 一次性取证脚本 | 故障定位 SOP（P0-1 的验证手段） |
| `docs/client/research/client-observability-design.md` | `phone:server:diag` 协议设计：8 个 `req.*` phase 四对配对、批次上报、限流分通道、服务端 128 槽内存环、PII 白名单投影、测试接法 | P1-1 双端诊断协议 |

三条被采纳的关键结论：

1. **`query_failed` 是纯传输层信号**（fetch 拒绝 / 非 JSON / 404），业务错误一定带结构化错误码 —— 所以排查必须从路由和注册抓起，不要先怀疑 SQL。
2. **CEF 会按 iframe 缓存 NUI 页面，固定文件名 `assets/index.js` 是最常见的"改了没生效"元凶**，且它不会破坏 `phone:open` 之类的握手（旧 bundle 一样会 ack），症状表现为"界面能开、某个功能悄悄用旧代码"。
3. **诊断通道本身会撒谎**：`focusState` 按 phase 5 秒冷却 + 日志前缀右对齐，足以让"没有日志"变成假阴性。诊断必须先自证（探针成对出现、以及显式的 dropped 汇总）。

---

## 3. 任务清单

### P0-1 手机 MDT 查询失败（阻塞真机验收）

- **现象**：见 F3/F4。
- **候选假设（按先验概率）**
  1. CEF 缓存旧 bundle → 旧 JS 调用了当前客户端没注册的回调名（404）。
  2. `appQuery` 回调未注册/被同名覆盖 → 404 空 body → `resp.json()` 抛错 → `query_failed`。
  3. 回调在，但 `cb` 从未调用（抛错被吞/资源重启打断）→ 9s AbortError → `query_failed`。
  4. 时序：资源 restart 后页面先于 Lua 注册完成就发首帧查询（100–500ms 窗口）。
- **已落地的取证改进**（本轮）
  - `web/src/utils/nui.ts`：`fetchNui` 失败（非 2xx 且 body 非 JSON / fetch 抛错）上报 `clientError`，带 `source/event/status/message`，同 event+reason 10s 去重；结构化 JSON 响应即使非 2xx 仍按成功路径返回（不破坏既有语义）。
  - `server/main.lua`：`phone:server:clientError` 只打印白名单字段并截断（`src/source/event/status/message/stack`），保证反查得到、又不会被客户端刷屏或注入。
  - `web/vite.config.ts`：产物改内容哈希 `assets/[name]-[hash].js`，从根上排除假设 1。
- **判定方式**：真机按 M 进 MDT，看服务端日志落点——
  | 日志 | 结论 | 下一步 |
  |---|---|---|
  | `[nui-error] ... event=appQuery status=404` | 假设 2/4 | 查 `client_scripts` 加载顺序与注册时机，必要时在回调注册后补一次 `nuiReady` 握手 |
  | `[nui-error] ... event=appQuery reason=fetch_error` | origin/资源名/传输层 | 按 playbook §3.2/§3.7 走 |
  | 有 `appQuery-hit`、无回包 | 回程丢包/`PhoneBridge.Resolve` 未命中 | 查 request_id 生命周期与 response 事件名 |
  | 无任何日志且 MDT 正常 | 假设 1 成立（旧缓存） | 记录并关闭 |
- **交付标准**：MDT 打开后 `units` + `incidents` 两个查询成功渲染；`pytest tests/unit tests/architecture` 全绿；`node web/tests/nui/run.mjs` 4 通过；真机截图/日志留档。

### P0-2 NUI 传输层可见性（已落地，随 P0-1 一起复验）

- 交付标准：人为制造一次 404（例如临时删掉某回调）时，服务端必须出现一行带 `event/status` 的 `[nui-error]`，且 10 秒内不重复刷屏。

### P1-1 双端诊断协议 `phone:server:diag`（待开发）

- **依据**：`client-observability-design.md`。
- **范围**：新增 `PhoneDiag`（客户端）+ 服务端聚合器；`req.*` 8 个 phase；trace 批次上报；`focusState` 保留为兼容 shim（`ui.*` 域），双写开关 `phone_diag_dual`。
- **不做**：不引入新依赖、不改 `PhoneBridge` 的对外契约、不动 `appQuery/appAction` 语义。
- **交付标准**
  - 新增 `tests/unit/layer3_business/test_phone_diag_protocol.py`（lua5.4 沙箱断言 8 phase 配对、零计时器泄漏、限流生效）。
  - 新增 `web/tests/nui/diag.spec.mjs`（断言请求体 `_diag` 字段存在且不含 PII）。
  - 真机：一次正常查询 0 条诊断日志；一次注入故障（drop.cli_fwd）必须打印 `break=seg2`。
  - 审查：PII 白名单投影 + 全局打印预算 + 可一键关闭的 convar。

### P1-2 客户端基线规则入 CI（待开发）

- 把 `fivem-nui-2026.md` 的 34 条规则里**可静态检查**的部分做成 `tests/architecture/test_nui_baseline.py`：
  - `ui_page` 唯一且文件存在；`files{}` 覆盖 `html/` 下被引用资源。
  - 构建产物必须带内容哈希（防回退）。
  - 每个 `SendNUIMessage` 状态型消息必须伴随 ack 或幂等重发（白名单枚举现有例外）。
  - `onClientResourceStop` 必须清理焦点/计时器/pending。
- 交付标准：新测试全绿；规则文档与测试一一对应（每条规则注明测试名）；CI 里跑得动（离线、无 FXServer）。

### P2 待评估

- `ui_page_preload`：先测手机冷启动耗时与内存，再决定是否常驻预加载。
- 客户端 Lua 侧全局错误回传（FiveM 没有 uncaught 钩子，只能靠关键路径显式上报 + 前端 `window.onerror` 已接）。

---

## 4. 执行顺序与门禁

```
P0-1 取证 → 定位 → 修复 → 审查 → 真机复验     ← 现在
P0-2 与 P0-1 同时复验
P1-1 协议开发 → 审查（安全/性能两项专项）→ 真机故障注入验收
P1-2 规则测试化 → 审查 → 并入 CI
```

每项任务在提交信息里必须写明：调研依据（文档/链接）、计划要点、开发范围、审查结论。审查不通过不得合并。

**审查清单（每项任务都要过）**

- 模块化：新增逻辑是否落在正确层（NUI / client Lua / server / 测试），有没有把业务塞进 wiring。
- 高性能：是否引入每帧/每请求无条件日志或 `SendNUIMessage`；网络事件数量级是否可接受。
- 可拓展：新增诊断能否被下一个 app 直接复用；enum/白名单是否集中定义。
- 安全：客户端输入不可信、日志 PII 白名单、限流、不可由客户端伪造审计结论。

---

## 5. 验收与回滚

- 自动化：`pytest tests/unit tests/architecture`（700+）+ `node web/tests/nui/run.mjs`（4）+ `npx svelte-check`（0 error）。
- 真机：M 开手机 / MDT 两查询 / 通话 / 通知 / 指纹焦点 / `restart custom-phone` 后再开。
- 回滚：P0 改动都在 `custom-phone` 单资源内，`git revert` 对应 commit 即可；P1-1 有 `phone_diag_dual` 与 convar 两级开关。

---

## 6. 风险

| 风险 | 影响 | 应对 |
|---|---|---|
| 真机复验依赖用户在场 | P0-1 可能停在"等一次点击" | 诊断先落地，一次点击即可定案；文档化 SOP 让任何人可复现 |
| 诊断日志污染生产日志 | 性能与信噪比 | 采样 + 打印预算 + convar 关闭 |
| 内容哈希改变产物名 | 部署脚本/文档引用旧名失效 | `files{}` 用通配、文档只引用 `html/index.html` |
