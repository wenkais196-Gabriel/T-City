# 计划：剧情抉择 UI 重构（decision surface）

> 阶段：L3（跨资源、改契约）。产物：本文 + 后续切片 PR。
> 起因：`story-engine` 独立 `ui_page` 的面板**能显示、不能输入**，玩家只能等 120s 超时。

## 0. 结论（已修正，2026-11-01 真机）

> **最初判断"CEF 回程通道死了"是错的**（CC 的评审推翻了它，真机证实）。
> 真正原因只有两个，都修好后键鼠同时可用：
>
> 1. **NUI 回调地址写错**：`decision_nui.html` 里 `fetch('https://cfx-nui-story-engine/…')`
>    —— `cfx-nui-<res>` 只是页面自身的 host，回调必须 POST 到 `https://<GetParentResourceName()>/…`。
>    于是 `nuiReady` / `nuiOpened` / `makeChoice` 全部 404，且被 `.catch` 吞掉。
> 2. **焦点顺序反了**：`SetNuiFocus` 之后再 `SetNuiFocusKeepInput` 会丢光标；
>    正确顺序是**先 keepInput，再 SetNuiFocus**（与 `custom-phone` / `tcity-dashboard` 一致）。
>
> 真机验证：`nui.ready` 到达 → 键盘 `1` → `nui.makeChoice` → `makeDecision choice=honest_cop`
> → `quest_event_log #89 complete`；随后鼠标点击同样产生 `nui.makeChoice` + `makeDecision`。

## 0.1 历史证据（修复前）

| 观测 | 结果 | 说明 |
|---|---|---|
| 面板渲染 | ✅ | `SendNUIMessage` 生效，中文、按钮、倒计时都正常（截图） |
| 页面 → Lua 回调 | ❌ 0 次 | `nuiReady` / `nuiOpened` / `nui.makeChoice` 遥测全为空 |
| 合成鼠标点击 | ❌ | 点击落到**游戏**（视角被带动），不进 CEF |
| `keepInput=false` 时按键 | ❌ | 游戏收不到键（按 M 打不开手机），CEF 也不处理 → 输入全被吞 |
| `keepInput=true` + Lua 轮询 | ✅ | `IsRawKeyDown` 提交成功（两次实测：honest_cop / silent_watcher） |
| 同一个 CEF 里的 `custom-phone` | ✅ | 玩家日常用手机，鼠标点击正常 |

**机制解释**：`SetNuiFocus` 作用于**调用方资源的页面**。我们页面能显示只说明 CEF 实例存在；
输入没进来说明焦点没落在本页面（或被别的页面持有），且 `keepInput` 在这个 build 上是**全局粘滞**的
（citizenfx#3593），一旦被别的 UI 设过 true，后面的 UI 就再也拿不到可用的光标。

## 1. 项目既有 UI 基建（重构应当复用，而不是再造）

| 基建 | 能力 | 关键约束 |
|---|---|---|
| `custom-ui` 输入栈 | `Push/Pop/Top/Path/Owns/Refresh`；帧字段 `{id, owner, cursor, keepInput, allow, close}` | **`SetNuiFocus` 按资源**：栈只做仲裁，真正按焦点要回调 `exports[owner]:ApplyFocus()` |
| `custom-ui:apply()` 的正确顺序 | ①`SetNuiFocusKeepInput(keepInput)`（**每次**都调，规避粘滞）②`ApplyFocus(true,cursor,keepInput)` ③两帧重按（Wait 0 / 100ms）④capture 线程按 `BLOCKED_CONTROLS` 屏蔽视角/攻击/移动 | keepInput 必须在 SetNuiFocus **之前**设；反过来会丢光标 |
| `custom-phone` | Svelte NUI + `PhoneFocus` 所有权栈 + `server/apps/*.lua` 处理器 + `fetchNui / requestAppQuery / requestAppAction` | **鼠标输入在这套页面里实测可用**；业务代码禁止直接 `fetch`、禁止自己拼 `cfx-nui-*` |
| `tcity-dashboard` | 独立 `ui_page` + 走 `custom-ui:Push`（同我们现在的写法） | 同结构 ⇒ 存在同样的输入风险，需要一并回归 |

## 2. 方案对比

> 结论更新：**C 已经修好并真机验证**，因此不需要把抉择搬进手机。A 保留为"如果将来要做手机端剧情入口"的备用方向；B（原生 Lua 面板）作为无 CEF 的兜底保留代码。

| 方案 | 键鼠 | 复用既有基建 | 改动面 | 风险 | 工作量 |
|---|---|---|---|---|---|
| **A. 决策搬进手机**（app 页 + 自动打开） | 鼠 ✅ 键 ✅（手机导航） | `PhoneFocus` + app 框架 + MDT 的 query/action 模式 | `custom-phone` web 新页面 + server app + `story-engine` 桥接 | 手机被 MDT 占用、玩家无手机、自动打开的时机 | 1–2 天 |
| B. 原生 Lua 面板（已写好 `client/decision_native.lua`） | 键 ✅ 鼠 ❌ | 无（自绘 DrawRect/DrawText） | 已存在，改 manifest 一行 | 没有鼠标；中文需字体包 | 0.5 天（已完成） |
| C. 继续修独立 `ui_page` 的输入 | 鼠 ？ 键 ？ | `custom-ui` 栈（按上面的正确顺序重接） | 只改 `story-engine/client/main.lua` | 机制不透明，可能再白做一轮；已有 6 次失败 | 0.5–1 天（不确定） |

**推荐 A，B 作为降级路径**。理由：
1. A 是**唯一**键鼠都被实测证明可用的 surface（手机页面）；
2. 焦点、光标、控制屏蔽全部由 `PhoneFocus` / `custom-ui` 承担，不再自造焦点逻辑；
3. 抉择本身就是"一条消息"，放进手机语义自然（短信/通知的同一条链路）；
4. B 已实现，可作为"没手机 / 手机被占用"时的兜底，保证任务永不软锁。

## 3. 验收标准（可执行）

| # | 标准 | 怎么验证 |
|---|---|---|
| 1 | 手机端出现抉择页 | 服务端下发后 2s 内 `[custom-phone][probe] code=ok`，页面显示题干 + 两个选项 |
| 2 | 鼠标选择生效 | 点击后服务端 `📩 makeDecision … choice=honest_cop`，`quest_event_log` 新增 `advance` |
| 3 | 键盘选择生效 | 手机导航键 1/2 提交，日志同上 |
| 4 | 关闭即释放 | 选择后 `nuiOpen=false`、`PhoneFocus.State().focus=false`、可正常走动/转视角 |
| 5 | 手机未开时自动打开 | 日志 `[phone] auto-open story_decision`，且不抢正在使用的 MDT（改为通知 + 稍后） |
| 6 | 超时兜底 | 120s 无操作 → 服务端 `timeout` 结算，页面自动关闭 |
| 7 | 无手机玩家 | 自动降级到原生面板（B），键盘 1/2 仍可完成 |
| 8 | 回归 | `pytest tests/architecture` 全绿；`node tests/nui/run.mjs`；`npm run build` 且产物提交 |

## 4. 切片（每片独立可运行）

| # | 切片 | 影响文件 | 验证 |
|---|---|---|---|
| 1 | `story-engine` 把 offer 转发到手机侧事件，保留 Lua 按键兜底 | `story-engine/client/main.lua`、`server/main.lua` | 日志出现 `[story-decision] offer→phone` |
| 2 | 手机 server app `story_decision`（query 取题干/选项，action 提交选择，复用 `DecisionEngine`） | `custom-phone/server/apps/story_decision.lua` | 手写 curl 等价调用 → `code=ok` |
| 3 | 手机 web 页面 `StoryDecision.svelte`（复用 `components/*` 与 token） | `custom-phone/web/src/apps/`、路由表 | `svelte-check` 0 error；浏览器预览可点 |
| 4 | 自动打开 + 焦点（走 `PhoneFocus`，禁止直接 `SetNuiFocus`） | `custom-phone/client/*` | 面板出现即锁输入、有游标 |
| 5 | 闸门与测试 | `tests/architecture/test_story_decision_ui.py`、`web/tests/nui` | 新测试红→绿 |
| 6 | 文档 + CHANGELOG | `docs/agent/police/*`、`CHANGELOG.md` | `release_check.py` 通过 |

## 5. 架构对照

- 平面：P1（客户端 UI）/ P3（任务服务端）；跨平面契约变化：新增 `phone:server:storyDecision` 与 app 通道 `story_decision`。
- 宪法：**服务端权威**（选择必须在服务端对 `_pending` 校验，客户端只提交 optionId）；**幂等**（重复提交只结算一次，`clearPending` 先行）；**无 PII**（题干只含剧情文本）。

## 6. 回滚

- 运行时开关：`setr story_decision_surface "phone" | "native"`（默认 phone；native 即当前已实现的 Lua 面板）。
- 代码：`git revert <sha>`；手机 app 即使留着也不可见，不影响任务推进。
- 数据：无表结构变更。

## 7. 风险

| 风险 | 处置 |
|---|---|
| 手机正被 MDT/其它 app 占用 | 不抢占：发通知 + 手机角标，玩家打开手机时优先显示抉择页 |
| 玩家没有手机（无 item） | 立即降级到原生面板（B） |
| 抉择期间断线 | 服务端 `_pending` 超时兜底，重连时 `QUEST_STATE_RESTORE` 重新下发 |
| `PhoneFocus` 与 `custom-ui` 栈双写冲突 | 只调 `PhoneFocus.Acquire/Release`，不直接 `SetNuiFocus` |
