---
id: base-agent-reviews-02-lua-refactor
type: audit
status: final
system: agent
owner: hermes
updated: 2026-10-25
---

# 02 · Lua HTTP 抽取重构对抗性评审（`ccdd61e`）

- **评审对象**：`ccdd61e refactor(director): extract testable HTTP API and add Lua harness`
- **基线**：`9bd57d7`（旧 `resources/[custom]/custom-director/server/main.lua`）→ `ccdd61e`（新 `resources/[custom]/custom-director/server/http_api.lua` + 适配器 + harness）
- **范围**：`T-CityLite.base/resources/[custom]/custom-director/`、`T-CityLite.base/tests/agent/lua/`
- **方法**：逐函数文本对比 + 旧实现重建差分（定向矩阵 + 360 条随机请求）+ 变异测试 + 现有 pytest/Lua 套件
- **环境**：Lua 5.4.8、pytest 9.0.2、Linux；`TCITY_ROOT=<repo>`
- **约束遵守**：未修改任何被 git 跟踪的文件；本文件是唯一新增文件，未 `git add/commit/checkout`。
  复现脚本放在 `/tmp/review02/`（不入库），关键代码已内联在 §7。

## 0. 结论

**需修（不建议按当前状态合并）—— 0 个 P0 / 3 个 P1 / 7 个 P2。**

`AgentHttp.Handle` 本体与旧 `dispatchHttp` 的逐函数语义基本等价：在对 360 条随机请求关闭适配器“早 413”后，状态码/响应体/Allow/WWW-Authenticate/动作调用次数 **0 drift**。
问题几乎全部集中在 `main.lua` 的 30 行适配器，以及“golden 只锁新行为、不锁旧顺序/副作用”的测试有效性上：

1. 旧 `readJsonBody` 的 `done` 单次执行守卫被删除 → 同一 `setDataHandler` 回调被调用两次时会执行两次 `Propose`（潜在重复建单/重复通知/重复审批链）。
2. `finish` 未处理 `need_body` 哨兵 → 回调传入 `nil` 时会 `res.writeHead(nil, ...)`，旧实现是 400 `missing_body`。
3. 适配器在探测前用 `Content-Length > 16384` 直接回 413，把旧顺序（503/401/404/405/200 在 413 之前）整体压过，违反“外部行为零变化”。

## 1. 证据总览

| 检查 | 结果 |
|:---|:---|
| `lua5.4 T-CityLite.base/tests/agent/lua/runner.lua` | rc=0；`http_contract` 19/19、`http_adapter` 8/8 |
| `cd T-CityLite.base && python3 -m pytest -q tests/agent tests/unit/test_director_http_contract.py` | `4 passed` |
| `luac5.4 -p`（http_api、main、harness 全部 .lua） | 全部通过 |
| 旧/新定向差分（16 个请求） | 4 处 drift：3 处早 413 + 1 处重复回调 |
| 旧/新随机差分（360 请求 × 3 种配置） | 98 处 drift，**全部是 `old=X → new=413`** |
| 同一随机集，关闭适配器早 413（`AgentHttp.MAX_BODY=1e9`） | **0 drift** |
| 变异测试（18 个变异） | **9 个存活（GREEN）**，见 §5.2 |

## 2. 发现表

> 行号均指 `ccdd61e` 中的文件；旧实现指 `git show 9bd57d7:.../server/main.lua`。
> 复现脚本在 `/tmp/review02/`，命令见 §7；表内不复述全部代码。

| ID | 严重度 | 文件:行 | 问题 | 复现 | 建议 |
|:---|:---|:---|:---|:---|:---|
| R1 | **P1** | `server/main.lua:1000-1009`、`:1029-1031`（旧 `main.lua:1059-1063`） | 旧 `readJsonBody` 用 `local done` + `if done then return end` 保证 body 回调只执行一次；新 `finish` 没有该守卫。回调被调两次时第二次仍会 `run(raw)`，`AgentActions.Propose/Approve/Reject` 副作用执行两次，只是第二次 HTTP 响应被 `makeResponder` 的 `sent` 吞掉。 | `lua5.4 /tmp/review02/repro.lua`：同一 handler 调两次 `dh('{"type":"notify","args":{}}')` → `Propose calls=2 sends=1 status=202`；`diff_driver.lua` 的 `duplicate_body_call` 用例旧实现同输入 `p=1`。现有 `tests/agent/lua/cases/http_adapter.lua:154-162` 正好调用了两次 handler，却只断言“只发一次响应”，把这层掩盖了。 | `finish` 恢复 `done` 守卫（或在入口检查 `sent` 短路，但动作层也需要幂等）；adapter golden 增加“回调两次 → Propose 只一次”。触发频率需实机确认；但删除守卫本身是确定回归。 |
| R2 | **P1** | `server/main.lua:1000-1009` + `server/http_api.lua:243-245`、`:299-301`、`:327-329`（旧 `1066-1068`） | `finish` 无条件 `respond(result.status, result.body, result.headers)`。若 `setDataHandler` 回调收到 `nil`，`run(nil)` 走 `request.body == nil` 分支返回 `{need_body=true}`，`finish` 于是执行 `res.writeHead(nil, headers)` + `res.send('{}')`。旧实现对非 string body 明确回 400 `missing_body`（“request body must be text”）。 | `lua5.4 /tmp/review02/repro4.lua`：`dh(nil)` → `writeHead(nil)`、`send('{}')`；`repro6.lua`：旧实现同输入 → 400 `missing_body`。 | `finish` 中判断 `result.need_body`，按旧语义回 400；或不要用 `nil` 作为“尚未读 body”的哨兵（另设 flag）。回调是否可能收到 `nil` 需实机确认，但旧代码明确覆盖了该输入。 |
| R3 | **P1** | `server/main.lua:1011-1016`（旧 `main.lua:1189-1250`、`1044-1057`） | 适配器在 probe **之前**用 `Content-Length > 16384` 回 413，把旧 `readJsonBody` 的 body 检查从“开关→token→路由→方法→admin 鉴权→agent 鉴权→/policy→X-Agent-Id 之后”提前到“一切之前”。任何 CL>16384 的请求都变成 413：disabled 503、token 缺失 503、404、405、401、甚至合法 `GET /policy` 的 200 都被覆盖。 | `lua5.4 /tmp/review02/fuzz_driver.lua`：360 条随机请求 98 条 drift，全部 `old=X new=413`（503×63、405×26、404×5、401×3、500×1）。定向差分里另有合法 token 的 `GET /agent/v1/policy` + `Content-Length: 17000` → 旧 200 / 新 413；`POST /agent/v1/act` + 错 token + 17000 → 旧 401 / 新 413。 | **删掉适配器这段早拒**：`http_api.lua:240-242` 的 `decodeRequest` 已经在 probe 内、在旧位置做同一检查，body 路由仍会在注册 handler 前 413；非 body 路由则恢复旧顺序。若坚持保留，必须写进版本化契约并 bump `actions_api_version`，同时补“旧顺序”golden。安全影响低（信息泄露方向相反），但违反“外部行为零变化”。 |
| R4 | P2 | `server/main.lua:987-998`、`:1018`、`:1029` | probe 与 finish 各调一次 `run`，于是每个带 body 的请求 `Config()` 被读两次：7 个 convar → 14 次 `GetConvar`；`bearerToken`/`secureEquals`/`NormalizeAgentId` 也各做两次。两次快照之间 convar 变化会改变同一请求的最终结果。旧实现每请求只读一次 Config（旧 `1189`）。 | `lua5.4 /tmp/review02/repro2.lua`：probe 后 7 次 `GetConvar`，finish 后 14 次。`repro3.lua`：probe 后把 `agent_actions_token` 改成 `rotated-token` → 同一请求 finish 回 401（旧单快照会继续 202）。 | finish 复用 probe 的 cfg/auth 结果；或把 `Handle` 拆成 preflight（路由/鉴权/header/CL 检查，返回 need_body 或最终响应）+ 只做 decode+dispatch 的第二段，避免二次读配置/二次鉴权。至少加注释说明这个 TOCTOU。 |
| R5 | P2 | `server/main.lua:1013-1014`、`:1024-1026`（旧 `1294-1301`） | 同步路径的 `respond(...)` 在 pcall 之外。旧实现整段 `dispatchHttp` 在 `SetHttpHandler` 的 pcall 内，`res.writeHead`/`res.send` 抛错会被捕获（或因 `sent` 已置位而静默）；新路径异常会直接冒泡出 HTTP handler。 | `lua5.4 /tmp/review02/repro5.lua`（带 `sent` 语义的 responder）：旧 outer pcall `ok=true`；新 outer pcall `ok=false`、`err=writeHead exploded`。 | 同步 respond 也放进 `pcall(function() respond(...) end)`，或统一 `safeRespond(respond, ...)`。 |
| R6 | P2 | `server/http_api.lua:224-252`、`:296-304`、`:326-332`（头注释 `1-16`） | `Handle` 在“body 尚未读取”时返回 `{need_body=true}`。这不是文件头宣称的 `{status,body,headers}` 契约的一部分，也未在注释中定义；任何非适配器调用方（未来 MCP/tool registry、`live_http.lua`）拿到无 status 的表会误用。另：设计文档 `01-live-perception.md:238-244` 期望 `_G.AgentHttp.{MakeResponder,SplitPath,ParseQuery,BearerToken,SecureEquals}` 且 `GetHeader(req, ...)`；本实现只导出 `GetHeader(headers,...)`/`MatchRoute`/`DecodeBody`/`Handle` + 常量，`BearerToken`/`SecureEquals` 等未导出，`GetHeader` 语义也已改为 headers 表。 | `lua5.4 /tmp/review02/repro2.lua`：直接调用 `Handle`（有合法 CL、无 body）返回 `status=nil need_body=true`。`grep -n 'AgentHttp\.' server/http_api.lua` 与设计 `01-live-perception.md:238-244,444` 对照。 | 在文件头与 design 里显式定义 `need_body` 哨兵；或让 `Handle` 始终返回 `{status,...}`，另提供 `HandlePreflight`。同步修正设计 01 的导出面/`GetHeader` 签名，避免后续 `live_http.lua` 按旧文档实现后静默拿不到 header。 |
| R7 | P2 | `tests/agent/lua/cases/http_contract.lua:289-312`；`tests/agent/lua/cases/http_adapter.lua:140-176` | golden 覆盖不足：18 个变异里 9 个存活（§5.2）。特别是**主成功路径 202（pending_approval）**、`httpStatusForResult` 的 404/410/500/409 分支、空 body、`%XX`/`+` query 解码、重复 query 参数、默认 `limit=20`、Bearer `Trim` 都没有锁。adapter 的 `oversized_content_length_early_413` 反而把 R3 的漂移固化为预期；`act_defers_until_body` 只断言单响应、不断言单次执行（R1）。 | `lua5.4 /tmp/review02/mutate.lua`：M8 `202→201`、M9 `404→400`、M10 `410→400`、M11 `500→400`、M3/M4 去 URL 解码、M6 重复参数 first-wins、M7 默认 limit `20→21`、M16 空 body、M18 `Trim→raw` 全部 GREEN；M1/M2/M5/M12/M13/M14/M15/M17 RED。 | 补：非 dry-run 202、actions 结果映射矩阵（404/409/410/500）、空 body、`?status=%70ending&limit=2`、`a+b`、重复 status、默认 limit、`Bearer  token  `；adapter 补“同一 handler 调两次 → Propose 一次”、旧顺序（401/404/503 + 大 CL）golden，并把 202/映射写进 Python `EXPECTED`。 |
| R8 | P2 | `tests/agent/lua/stubs/fivem.lua:115-118`；`bootstrap.lua:85-91`；`json.lua:136-187` | harness 不模拟 FXServer 的 HTTP 流：`SetHttpHandler` 只是保存 handler，adapter 测试手工构造 `req`/`res`，所以“FXServer 只在有 body 时调用 `setDataHandler`”这一核心前提**没有被 harness 验证**，只是被假定。`json.lua` 是自写 codec，`json.encode({})→'{}'`、浮点/转义/UTF-8 与 FiveM 实际 `json` 不保证一致；golden 没有旧实现作 oracle，作者与实现同源，“stub 错 → golden 一起错”是可能的。 | 读 `stubs/fivem.lua:115-118`（只 push handler）；`json.encode({})` 输出 `{}`；mutation 9/18 存活说明断言面窄。 | 扩展 stub 为最小 HTTP 流模型（按 CL/chunked 决定是否回调、header 大小写来源），并加一条由旧实现生成/对比的差分测试；在 `json.lua` 标注“非 FiveM 等价”，关键响应字段用 Python 侧独立期望而不是只复用 Lua codec。真实流/json 语义列入 T5 实机。 |
| R9 | P2 | `server/main.lua:22-23` vs `server/http_api.lua:22-23` | list 的默认/最大 limit 现在有两份：exports 的 `AgentActions.List` 用 main 的 20/100，HTTP list 用 http_api 的 20/100。当前一致，但改一处会造成“exports 列表”和“HTTP 列表”行为分叉；旧实现只有一份。 | `grep -n 'DEFAULT_LIST_LIMIT' ...` 与 `grep -n 'MAX_LIST_LIMIT' ...`；把 http_api 常量单独改 21 后两条 list 路径会分叉（未改仓库，仅说明）。 | main 的 `AgentActions.List` 也引用 `AgentHttp.DEFAULT_LIST_LIMIT/MAX_LIST_LIMIT`，或把常量放共享文件；golden 锁默认 limit。 |
| R10 | P2 | `server/main.lua:941-945` | `http_api.lua` 缺失/加载失败时，main 在注册完 exports 之后 `return`：exports 仍在，但 `/agentapprove`、`SetHttpHandler` 和最终 loaded 日志都不会注册，资源处于半可用状态（旧实现无此依赖）。 | `lua5.4 /tmp/review02/repro7.lua`：置空 `_G.AgentHttp` 后 `dofile main.lua` → `exports Policy=true`、`command agentapprove=false`、`http_handler=false`。 | 把 http_api 的加载失败处理成启动期显式错误（或在注册 exports 之前校验），避免半注册。 |

## 3. 已核对等价的函数清单

文本逐行比对 + 差分驱动结论（`/tmp/review02/diff_driver.lua`、`fuzz_handle_only.lua`）：

| 旧函数（旧行） | 新位置（新行） | 结论 / 证据 |
|:---|:---|:---|
| `splitPath`（942-946） | `http_api.lua:33-37` | 逐字节相同 |
| `urlDecode`（948-953） | `http_api.lua:39-44` | 逐字节相同（`+`→空格、`%XX` 解码均保留） |
| `parseQuery`（955-971） | `http_api.lua:46-62` | 逐字节相同（空 key 丢弃、重复 key 后者覆盖） |
| `getHeader`（973-983） | `AgentHttp.GetHeader`（65-75） | 语义等价；签名从 `req` 改为 `headers`，新增 `name:lower()`；所有调用点传小写名，大小写混合 header 仍可命中。**注意 R6 的导出面变化** |
| `bearerToken`（985-991） | `http_api.lua:77-83` | 等价；仅把 `AgentPolicy.Trim` 改为 `policy.Trim` 参数注入 |
| `secureEquals`（993-1004） | `http_api.lua:85-96` | 逐字节相同（空串拒绝、长度差异、按位 OR 累积） |
| `makeResponder`（1006-1032） | `main.lua:947-973` | 逐字节相同（默认头、`sent` 单次、编码失败兜底 JSON） |
| `decodeJsonBody`（1034-1042） | `AgentHttp.DecodeBody`（148-168） | 分支等价：非 string→missing_body/400、空串→bad_request、非法 JSON/非 table→bad_request、数字 key→bad_request；错误文案相同。**唯一新差异在适配器 nil 哨兵，见 R2** |
| `readJsonBody`（1044-1091） | `decodeRequest`（230-252）+ 适配器 | `Handle` 内的 CL/0/chunked/413 判断顺序与旧 `readJsonBody` 相同；适配器多了早 413（R3）且丢了 `done` 守卫（R1）、缺 need_body 处理（R2） |
| `matchRoute`（1093-1114） | `AgentHttp.MatchRoute`（102-123） | 逐字节相同（含 `%d+`、尾斜杠不匹配） |
| `httpStatusForResult`（1116-1131） | `http_api.lua:125-140` | 逐字节相同（202/200/503/404/410/409/500/400） |
| `handleAct`（1133-1156） | `http_api.lua:174-194` | 等价：`respond(...)` 改为 `return status, body`，参数/默认值/错误文案一致 |
| `handleAdminAction`（1158-1186） | `http_api.lua:196-222` | 等价：`NormalizeApprover`/`NormalizeReason`/`rejected→409` 逻辑一致 |
| `dispatchHttp`（1188-1292） | `AgentHttp.Handle`（254-364） | 检查顺序一致（disabled→token→route→method→admin token→admin auth→agent auth→policy→X-Agent-Id→body→dispatch）。360 条随机请求（关闭适配器早 413）**0 drift**；定向 16 条除早 413/重复回调外 0 drift |

补充核对：

- **`%` 解码**：完全相同的 `gsub('%%(%x%x)'...)`，无漂移。
- **`+` 是否变空格**：相同（`gsub('+', ' ')` 在 percent 解码之前）。
- **空 query / 只有 `?`**：`parseQuery('')` 返回空表，同旧。
- **重复参数**：`result[key] = ...` 后者覆盖，同旧。
- **header 大小写**：`GetHeader` 双边 `:lower()`；FXServer 若返回 `Content-Length`/`X-Agent-Id` 也能命中。**FXServer 实际 header 表形态需实机验证**（见 §6）。
- **`makeResponder` 只发一次**：已由 `sent` 保证；重复 body 回调时 `sends=1`（R1 复现），但动作执行了两次。

## 4. 适配器专项结论（对应任务 2/3/4）

### 4.1 `need_body` 探测是否可能漏响应？

| 输入 | 旧行为 | 新行为 | 结论 |
|:---|:---|:---|:---|
| POST 无 body、无 CL | 400 `missing_body`（同步） | probe 同步 400 `missing_body`；不注册 handler | 等价 |
| `content-length: 0`（无 body） | 400 `missing_body`（同步） | 同上 | 等价 |
| `content-length: 0` + `transfer-encoding: chunked` | 注册 handler（chunked 优先） | probe `need_body=true`，注册 handler | 等价（FXServer 对 CL=0+chunked 的处理需实机） |
| chunked、无 CL | 注册 handler | probe `need_body=true`，注册 handler | 等价 |
| CL>0、body 实际为空/未到达 | 注册 handler，可能一直不回调 | 同旧（也不回调） | 无回归；但 `finish` 收到 nil 时有 R2 |

**结论**：`need_body` 探测不会“漏响应”普通请求；真正的问题是 `finish` 对 `nil` body 的哨兵处理（R2），以及探测/执行之间的二次鉴权（R4）。

### 4.2 探测阶段副作用

- `Config()`：每个带 body 的请求从 1 次变 2 次（7→14 次 convar 读，R4）。
- `Policy()`/`AgentActions.*`：探测在 `decodeRequest` 的 `request.body == nil` 处返回，**不会**调用 `Propose/Approve/Reject`；GET `/policy` 的 `Policy()` 也只在 probe 同步路径调用一次（不二次）。这点是干净的。
- `NormalizeAgentId`：act 路由 probe + finish 各一次（纯函数，无副作用，但属于 R4 的重复工作）。
- 两次快照之间 convar 变化会改变结果（R4 的 token 轮换复现）。

### 4.3 `respond` 是否只发一次？

**HTTP 响应层：是。** `makeResponder` 的 `sent` 在 `res.writeHead` 前置位；重复 `finish` 也不会二次发送（复现 `sends=1`）。
**副作用层：否。** 重复回调时 `Propose` 执行两次（R1）；这是本次重构最需要修的适配器回归。

### 4.4 `setDataHandler` 抛错路径

新实现 `pcall(function() req.setDataHandler(finish) end)` 失败 → `fail(respond)` → 500 `internal_error`；旧实现同样 500（日志文案从“registration failed”变为无专属文案）。**状态码/响应体等价**，日志文本有变化（非 HTTP 契约）。

### 4.5 413 顺序

**确定漂移（R3）**：早拒在 probe/路由/鉴权之前。旧顺序在 body 检查前已经完成了 disabled/token/route/method/admin/agent/policy/agent-id 判断。
可利用性：攻击者只能得到一个统一的 413，**不新增信息泄露**（反而掩盖了 401/404/405 的差异）；但这是对既有契约（设计 05 §4.1 明确把顺序列为契约）的破坏，且现有 adapter golden 把它固化成预期。
注意设计 05 自身矛盾：§4.1 把“body 检查”列为第 10 步，§4.4 却写“CL>16384 适配器早拒”；本评审按 commit message 的“外部行为零变化”判定为漂移，若产品决定接受早拒，必须改 §4.1、bump 契约版本并补旧顺序测试。

### 4.6 header 大小写

- 代码层：`GetHeader` 对 `key:lower() == name`（name 也 lower），`Content-Length`/`X-Agent-Id`/`Authorization` 均可命中；`Transfer-Encoding` 也 lower 后 `find('chunked')`。
- 多值 header：value 为 table 时取 `[1]`，同旧。
- **需实机验证**：FXServer 的 `req.headers` 是否确实为“字符串键 → 字符串/数组值”的普通表，以及是否会把 header 名统一小写。代码对两种大小写都兼容，风险低，但不应在未验证时声称已证。

## 5. 测试有效性 / harness 保真度

### 5.1 19 条 golden 是否可能“因 stub 错而一起错”？

**可能，且现有设计无法自证。** 理由：

1. golden 的期望是作者在同一 commit 里手写的，没有从旧实现生成的 oracle；`Handle` 与 golden 同源，逻辑写错时两边可以一起错。
2. `stubs/fivem.lua:115-118` 的 `SetHttpHandler` 只保存 handler；adapter 测试手工构造 `req/res`，**没有模拟** FXServer 的 body 流/header 表/路径前缀。因此“FXServer 只在有 body 时调用 setDataHandler”这一本次重构的核心前提，在 harness 里只是注释和假定（`http_adapter.lua:3-6`），没有可执行验证。
3. `json.lua` 是自写 codec，不是 FiveM 的 `json`：
   - `json.encode({})` → `'{}'`（`json.lua:163-167`）；空表/空数组在 FiveM 实际 encoder 中可能是 `[]`，golden 不比较原始字节，发现不了。
   - 浮点用 `%.17g`（`json.lua:148`），FiveM 精度/格式未必相同。
   - 只转义控制字符/引号/反斜杠（`json.lua:136-140`），`/`、`<`、`>` 与 Unicode 的处理未与 FiveM 对齐。
   - 这些差异不会让“错误实现”变绿（golden 只比较解码后的字段），但会让 **生产响应与 harness 响应** 在序列化层不一致；当前所有响应字段都是整数/字符串，风险有限，仍应标注。
4. golden 没有覆盖 `main.lua` 适配器与真实 `AgentActions`/`Config` 的组合（adapter 测试跑的是 stub 下的真实 `AgentActions`，`get_list_is_synchronous` 只断言 `count==0`，mysql stub 错了也绿）。

### 5.2 变异测试（`/tmp/review02/mutate.lua`，仓库文件未改）

| 变异 | 结果 | 说明 |
|:---|:---|:---|
| M1 `405→400` | RED | `wrong_method_returns_405` 抓住 |
| M2 删除 `Allow` 头 | RED | 同上 |
| M3 删除 `+`→空格 | **GREEN** | 没有 query 解码 golden |
| M4 删除 `%XX` 解码 | **GREEN** | 没有 query 解码 golden |
| M5 `GetHeader` 改为大小写敏感 | RED | 10 条 golden 依赖 `Content-Length`/`Authorization` 的大小写兼容 |
| M6 重复 query 参数改 first-wins | **GREEN** | 没有重复参数 golden |
| M7 默认 `DEFAULT_LIST_LIMIT 20→21` | **GREEN** | golden 只测显式 `limit=999` |
| M8 `pending_approval → 201` | **GREEN** | **主成功路径 202 无 golden**（只有 dry_run 200） |
| M9 `not_found → 400` | **GREEN** | `httpStatusForResult` 的 404 分支无 golden |
| M10 `expired → 400` | **GREEN** | 410 分支无 golden |
| M11 `db_error → 400` | **GREEN** | 500 分支无 golden |
| M12 接受数字 key 的 JSON | RED | `non_object_body_returns_400` 抓住 |
| M13 `413→400` | RED | `content_length_over_limit_returns_413` 抓住 |
| M14 `Allow` 改为 `GET` | RED | 405 golden 抓住 |
| M15 删除 `WWW-Authenticate` | RED | admin 401 golden 抓住 |
| M16 删除空 body 检查 | **GREEN** | 无 golden 走 `DecodeBody('')` 的 400 分支 |
| M17 `missing_body 400→422` | RED | 抓住 |
| M18 `Bearer Trim` 改为原样返回 | **GREEN** | 无“token 两侧空格”golden |

**9/18 存活**。存活项不是“实现错”，而是“测试没锁”；其中 M8/M9/M10/M11 是最重要的契约分支。

### 5.3 测试用例本身的两个问题

- `http_adapter.lua:154-162`：`dataHandler('{}')` 调两次，只断言 `#captures == 2`（一次响应），**没有断言 `Propose/Approve` 调用次数**。按 R1，若 body 是 `{"type":"notify",...}`，这里会 `Propose` 两次而测试仍绿。
- `http_adapter.lua:165-176`：`oversized_content_length_early_413` 用**无鉴权**的请求断言 413，把 R3 的“413 早于 401/404”固化为预期；修复 R3（删早拒）后这条测试会失败，需要改成“合法鉴权 + CL>MAX → 413”或改为断言旧顺序。

## 6. harness 无法覆盖 / 需实机验证的点

以下均不应在当前证据下声称“已验证”，建议在 T5 实机或 FXServer 集成测试中覆盖：

1. `setDataHandler` 回调语义：是否保证恰好一次；chunked 请求是否按 chunk 多次回调；空 body 时回调参数是 `""`、`nil` 还是不回调；请求中断时是否回调。
2. `req.headers` 的真实形态：键是否小写、是否多值数组、特殊 header（`Content-Length`、`Transfer-Encoding`、`Authorization`）是否被保留/规范化。
3. `req.path` 是否已去掉 `/<resource>/` 前缀（旧实现与 golden 都假定是 `/agent/v1/...`），以及 query 是否包含在 `path` 里。
4. FXServer 自己的 HTTP 层对 `Content-Length`/`Transfer-Encoding` 冲突、非法 CL、HTTP/2、半关闭连接的处理。
5. 真实 FiveM `json` 的 encode/decode：空表 vs 空数组、浮点格式、Unicode 转义、对非法 JSON/重复 key 的宽容度。
6. 真实 MySQL/QBCore 下 `Propose/Approve/Reject` 的副作用与幂等性（harness 只有 stub）。
7. `res.writeHead`/`res.send` 在连接已关闭、响应过大等情况下是否抛错（R5 的触发条件）。
8. convar 热切换与请求并发下的 TOCTOU（R4）。
9. 真实 FXServer 日志格式（本次日志文案有变化，但非 HTTP 契约）。
10. `http_api.lua` 与 `main.lua` 的资源加载/重启顺序（manifest 已把 http_api 放在前面，但热重载/部分加载未验证）。

## 7. 复现方式

### 7.1 基础命令（均在仓库根执行）

```bash
cd /home/swk/Documents/deepseek-harness/default-workspace/T-City-agent

lua5.4 'T-CityLite.base/tests/agent/lua/runner.lua'          # rc=0，19+8
for f in 'T-CityLite.base/resources/[custom]/custom-director/server/http_api.lua' \
         'T-CityLite.base/resources/[custom]/custom-director/server/main.lua' \
         T-CityLite.base/tests/agent/lua/*.lua \
         T-CityLite.base/tests/agent/lua/cases/*.lua \
         T-CityLite.base/tests/agent/lua/stubs/*.lua; do luac5.4 -p "$f" || echo "FAIL $f"; done

cd T-CityLite.base && python3 -m pytest -q tests/agent tests/unit/test_director_http_contract.py
```

### 7.2 旧实现重建

```bash
git show '9bd57d7:T-CityLite.base/resources/[custom]/custom-director/server/main.lua' > /tmp/review02/main_old.lua
# 取旧 938-1292 行（HTTP helpers + dispatchHttp），补上 MAX_HTTP_BODY/Config/truncate
# 等全局后 `return dispatchHttp`，即 /tmp/review02/old_http.lua（393 行，luac5.4 -p 通过）。
```

### 7.3 关键复现（节选）

R1（重复回调执行两次）：

```lua
-- 真实适配器，env.actions.Propose 换成本地计数器
local dh
env.http_handler({ method='POST', path='/agent/v1/act',
  headers={Authorization='Bearer agent-token', ['X-Agent-Id']='agent-1', ['content-length']='27'},
  setDataHandler=function(fn) dh=fn end }, res)
dh('{"type":"notify","args":{}}')
dh('{"type":"notify","args":{}}')
-- 输出：Propose calls=2 sends=1 status=202   （旧实现 calls=1）
```

R2（nil body → writeHead(nil)）：

```lua
env.http_handler({ method='POST', path='/agent/v1/act',
  headers={Authorization='Bearer agent-token', ['X-Agent-Id']='agent-1', ['Content-Length']='10'},
  setDataHandler=function(fn) dh=fn end }, res)
dh(nil)
-- 新：writeHead 收到 nil
-- 旧：400 missing_body（"request body must be text"）
```

R3（早 413）：

```lua
-- 合法 token 的 GET /policy + Content-Length: 17000
-- 旧：200 {schema_version=1}
-- 新：413 {code="body_too_large"}
```

完整脚本：`/tmp/review02/{diff_driver,fuzz_driver,fuzz_handle_only,mutate,repro,repro2,repro3,repro4,repro5,repro6,repro7}.lua`。
它们只 `dofile` 仓库文件，不写入仓库。

## 8. 修复优先级建议

1. **P1**：`finish` 恢复 `done` 守卫；`finish` 处理 `need_body`（nil body → 400）；补对应 adapter golden（单次执行、nil body）。
2. **P1**：删除 `main.lua:1011-1016` 早 413（`decodeRequest` 已覆盖），同步改 `oversized_content_length_early_413`；补旧顺序 golden（503/401/404/405 + 大 CL）。
3. **P2**：finish 复用 probe 的 cfg/auth；同步 respond 纳入 pcall；明确 `need_body` 契约/导出面；补 202/映射/query/空 body/默认 limit 的 golden；把 stub 的 HTTP 流模型和 json 差异列入 T5。

## 9. 五行总结

1. **0 P0 / 3 P1 / 7 P2**；`Handle` 本体与旧 `dispatchHttp` 在 360 条随机请求上（关闭适配器早 413）行为等价（状态码/响应体/头/动作调用一致）。
2. **最严重**：适配器删除了旧 `done` 守卫，`setDataHandler` 回调两次会执行两次 `Propose`（`sends=1` 但 `Propose=2`，重复建单/通知/审批链）。
3. 另外两个 P1：`finish` 未处理 `need_body` → nil body 时 `writeHead(nil)`；适配器早 413 把 503/401/404/405/200 全部压成 413。
4. harness 能跑但锁不住关键分支：18 个变异 9 个存活（含 202 主路径、404/410/500 映射、空 body、query 解码）；stub 未真正模拟 FXServer，核心 `setDataHandler` 前提需实机验证。
5. **建议：需修后合并**；先修 2 个适配器 P1 + 413 顺序并补对应 golden，再处理 P2。
