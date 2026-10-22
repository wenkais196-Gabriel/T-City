# 04 · Live perception（`/agent/v1/live/*`）对抗性评审

- **评审对象**：`fe76857 feat(agent): add in-memory live perception endpoints (M1)`
- **基线**：`7008611`（父提交）→ `fe76857`；分支 `feat/agent-takeover-v2`
- **范围**：`server/live_rules.lua`、`live_store.lua`、`live_events.lua`、`live_api.lua`、`http_api.lua` 的 live 拦截（+19 行）、`main.lua` 的 `live = _G.LiveApi`（+1 行）、`tests/agent/lua/cases/live_*.lua`、`tests/agent/lua/{bootstrap,runner}.lua`、`fxmanifest.lua` 加载顺序
- **环境**：Lua 5.4（`lua5.4`）、Python 3、Linux；`TCITY_ROOT` 指向仓库或 `/tmp` 变异根
- **约束遵守**：未修改任何被 git 跟踪的文件；未执行 `git add/commit/checkout`；本文件是唯一新增文件。复现脚本在 `/tmp/review04/`（不入库），关键代码已内联。
- **方法**：逐行代码审计 + 恶意 `PlayerData`/恶意 convar/恶意 cursor 构造 + 18 个变异体（`/tmp` 副本）+ 48 人基准 + 真实调用链（`custom-phone` → `EconomyService` → `OnMoneyChange`）追踪

---

## 0. 结论

**需修（不建议按当前状态合并）—— 0 个 P0 / 3 个 P1 / 12 个 P2；另有 9 条测试缺口（T-01…T-09）。**

投影白名单、plate 掩码、路由前缀、鉴权主路径、环形边界本身没有发现可利用的绕过；问题集中在**事件文本的 PII 透传、UTF-8 字节级截断、cursor 未来值回显**三条主线上，另有若干设计契约漂移与测试盲区。

1. **P1 / L-01**：`money.change` 事件的 `reason` 原样保留，`custom-phone` 的转账 reason 就是 `"Transfer to " .. 手机号`（收款侧是 `"Transfer from " .. 手机号`），手机号因此进入 `/live/events`——直接违反设计 §2.1“绝不出现 `charinfo.phone`”。
2. **P1 / L-02**：`sanitize_text` 按**字节** `sub(1, maxLength)`，中文/emoji 展示名 >64 字节时会在码点中间截断，产生非法 UTF-8；要么 FXServer `json.encode` 失败使**整个 48 人响应**退化为 `200 + internal_error`，要么 Python `requests.json()` 解码失败使 MCP 工具整体报错。
3. **P1 / L-03**：`since` 的 `seq` 大于 `newest` 时服务端不夹紧，直接回显未来 `next_cursor`；客户端此后每次轮询都是 0 事件，直到 seq 真正追上——事件流被静默搁置。9 位 seq 在 MCP 的 cursor 正则 `^\d{1,10}:\d{1,9}$` 内，可达。

基线本身是绿的：`http_contract 19/19`、`http_adapter 10/10`、`live_rules 10/10`、`live_api 20/20`，pytest `3 passed`；`luac5.4 -p` 全部通过。**测试绿不等于契约对**——§3 的变异矩阵显示 7 个安全/正确性变异体存活。

---

## 1. 证据总览

| 检查 | 结果 |
|:---|:---|
| `lua5.4 T-CityLite.base/tests/agent/lua/runner.lua` | rc=0；4 cases，`live_rules 10/10`、`live_api 20/20` |
| `cd T-CityLite.base && python3 -m pytest -q tests/agent` | `3 passed` |
| `luac5.4 -p`（live_*、http_api、main、两个 live case、bootstrap、runner） | 全部通过 |
| 18 个变异体（§3） | **7 个 GREEN/survived**：M4、M7、M13、M14、M15、M17、M18 |
| 48 人基准（harness） | build+project+sort **0.368 ms**；pure-Lua json **1.918 ms**；**22,305 B**；**480 次 native 调用**；Handle 内 `json.encode` **0 次** |
| `/live/events`（2048 满环取 200） | **0.022 ms/req** |
| 真实 PII 链 | `custom-phone/server/banking.lua:46,49` → `economy_service.lua:240` → `live_events.lua:207` → `/live/events`，手机号可见 |

---

## 2. 发现表（代码）

> 行号均指 `fe76857`。复现脚本 `/tmp/review04/poc.lua`（§A–§I）与 `poc3.lua`；命令：`lua5.4 /tmp/review04/poc.lua`。表中只摘关键断言。

| ID | 严重度 | 文件:行 | 问题 | 复现 | 建议 |
|:---|:---|:---|:---|:---|:---|
| **L-01** | **P1** | `live_events.lua:207`（`onMoneyChange` 189-210）；来源 `custom-phone/server/banking.lua:46,49`、`qb-core/server/services/economy_service.lua:240` | `money.change` 的 `reason = LiveRules.sanitize_text(reason,64)` 只去控制字符，不去 PII。`banking.lua:46` 传入 `"Transfer to " .. toPhoneNumber`，`:49` 传入 `"Transfer from " .. Player.PlayerData.charinfo.phone`；`EconomyService.TransferMoney` 把同一 reason 透传给 `RemoveMoney/AddMoney` → `fireMoneyEvents` → `QBCore:Server:OnMoneyChange`。任何持有 live token 的 agent 在 `/live/events` 都能读到玩家手机号。设计 §2.1 明确把 `charinfo.phone` 列为“绝不出现”。 | `poc.lua §A`：`TriggerEvent('QBCore:Server:OnMoneyChange', 1,'bank',-250,'remove','Transfer to 555-0100')` → `events[1].payload.reason == 'Transfer to 555-0100'`，整包 JSON 命中 `555-0100`；`add` 方向同样命中。现有用例只用 `reason='repair'`（`live_api.lua:362`）和 `'vehicle repair'`（`:306`），扫不到。 | 事件文本要么改为**枚举白名单**（reason 归一化为 `transfer/purchase/repair/...`，原始文本只进日志），要么对 reason 做 PII 清洗（手机号/`license:`/`discord:`/`steam:`/8 位 citizenid（3 字母+5 数字，`player.lua:752-757`）正则脱敏）。至少补一条“reason 含手机号”的负例。 |
| **L-02** | **P1** | `live_rules.lua:78`（`sanitize_text` 75-80）；调用 `:243,159-160,179` | 截断发生在字节层：`text:sub(1, maxLength)`。一个 40 个“张”的名字（120 B）截到 64 B 时落在第 22 个码点中间，输出最后一个字节是 `E5`（三字节序列的首字节），`utf8.len(cut) == nil`。该值进入 `name` 后整包 JSON 非法：真实 `json.encode` 若校验 UTF-8 则整包失败（`main.lua:962-968` 回 `200 + internal_error`），若不校验则 Python 侧 `decode('utf-8')` 失败。一个玩家即可让 48 人列表整体不可用。`job.label`（64 B）/`gang.name`（32 B）同理。 | `poc.lua §D`：`#cut==64`、`utf8.len(cut)==nil`、末 4 字节 `E5 BC A0 E5`；`python3 json.loads(open(...).read().decode('utf-8'))` → `UnicodeDecodeError: invalid continuation byte`。 | 按码点截断：`local n = utf8.offset(text, maxLength + 1); if n then text = text:sub(1, n - 1) end`（`maxLength` 改为字符数），并在返回前校验/替换非法序列；或统一走 Python 侧同款 `sanitize_untrusted` 规则。补“中文名 >64 B”的用例，断言 `utf8.len` 非 nil 且整包可被 Python 解码。 |
| **L-03** | **P1** | `live_store.lua:127-139`、`:153-160`（`List`） | `since.seq > self.seq` 时既不夹紧也不报错：`startSeq = requested+1` 使循环不执行，`lastSeq = requested`，`next_cursor = Encode(requested)`——服务端把**未来 seq** 原样还给客户端。之后即使有新事件（seq 更小），用该 cursor 轮询仍是 0 事件；`dropped` 也不提示。同一 bug 还让超长 seq 变成 `epoch:1e+24`（`ParseCursor` 再解析失败 → 400），以及 `os.time()` 秒级 epoch 在“同一秒内 restart”时与新环 seq=0 组合出跨代未来 cursor。 | `poc.lua §B`：seq=3 时 `since=epoch:999999999` → `200 / 0 events / next_cursor=epoch:999999999`；push seq=4 后再用该 cursor → `0 events`；24 位 seq → `next_cursor=epoch:1e+24`，再提交 → `400`。`poc3.lua`：`since=300`（== newest）正常 0 事件；`since=301` → `next_cursor=epoch:301`（越界回显）。 | `requested` 先夹紧：`if requested > self.seq then requested = self.seq end`；或对 `requested > newest` 回 `409 cursor_ahead`/`400 invalid_cursor`。`next_cursor` 永远用 `Encode(math.min(lastSeq, self.seq))`。`ParseCursor` 限制 `seq < 2^53` 且只接受规范十进制。epoch 加入随机/启动毫秒分量，避免同秒 restart 复用。 |
| L-04 | P2 | `live_rules.lua:35-39`（`tonumberOr`）、`:132-136`、`:224-231`、`:183-190`；`main.lua:962-968` | `tonumberOr`/`sanitize_metadata`/`sanitize_player` 只排 `NaN`，不排 `±inf`；`tonumber('1e999')` 返回 `inf` 且为 truthy。`money.cash='1e999'`（或 ped 不存在时的 `metadata.health=0/0`、`opts.heading=inf`）进入投影；真实 `json.encode` 对非有限数抛错，`main.lua` 的 `pcall` 兜底返回 **status 200 + `{"error":"internal server error"}`**，整包 48 人数据消失且状态码误导。 | `poc.lua §E`：`money.cash == inf`，harness `json.encode` 返回 `nil, 'json encode error: non-finite number'`；`poc2.lua`：ped=0 时 `metadata.health == -nan`，整包 encode 失败。 | 抽一个 `finite_number(v)`：`v==v and v~=math.huge and v~=-math.huge`，在 `tonumberOr`、metadata、health/armor override、heading/bucket/ping 全部使用；`money` 非法值降级为 `nil` 而不是 `inf`；`makeResponder` 的 encode 失败应回 500（不要 200）。补“`1e999`/`0/0`”用例。 |
| L-05 | P2 | `live_api.lua:82-89`（`liveConfig` precision）；`live_rules.lua:109-117` | `math.floor(value)` 把 `(0,1)` 的正小数压成 `0`，而 `quantize_position` 把 `0` 解释为 **fine（原样坐标）**：`agent_live_precision=0.5` 得到 `precision_m=0`、`x=123.4`，与“默认 25m”相反。`agent_live_precision=1e999` 得到 `inf`，`quantize` 产生 `x=-nan`（再触发 L-04）。设计 §2.2 要求 fine 走独立开关 `agent_live_allow_fine_position=1`，本实现只有一个 convar，且没有 5m/1m/heading 15° 的 fine 定义。 | `poc.lua §C`：`0.5 → precision_m=0 / x=123.4`；`fine → 0 / 123.4`；直接调 `quantize_position(..., inf)` → `-nan`。 | 显式解析：`fine` → 0（且必须过 allow 开关）；数值只接受 `>=1` 的整数米，`(0,1)` 回退 25 或报错；拒绝非有限值；`precision_m` 与坐标实际精度保持一致。补 `0.5`/`1e999` 用例。 |
| L-06 | P2 | `live_rules.lua:75-80`（`%c`）；文本入口 `:220,243,159-160,179` | `%c` 只匹配 ASCII C0 + DEL；C1（U+0085、U+009B）、零宽（U+200B/200C/FEFF）、bidi（U+202E）、行分隔（U+2028）全部原样保留。玩家展示名可携带 RLO/零宽字符，在 LLM 上下文、日志、终端里做视觉欺骗/隐藏。`poc.lua §F` 的 `name` 保留了 U+202E。 | `poc.lua §D/F`：`sanitize_text('A\u{202E}B')` 长度不变；`contains U+202E == true`；NUL/BEL/ESC/DEL 被删除（这部分正确）。 | 在 Lua 侧同步 Python `sanitize_untrusted` 的字符集：去掉 C0/C1、零宽、bidi（U+202A–202E、U+2066–2069、U+200B–200F、U+FEFF）与 U+2028/2029；或明确“Lua 只做 C0，Hub 负责 Unicode”，并在契约里写清（当前 commit 没写）。 |
| L-07 | P2 | `live_api.lua:142-146`（`sampleVehicle`） | `seat` 只在 `driver == ped` 时保持 `-1`（driver，正确）；其余情况一律 `0`：**后排乘客被报成 0 号座**，`GetPedInVehicleSeat` 报错也被报成 `0`。注释/契约 `{model,plate,seat}` 会误导 agent 判断“谁在开车/谁在副驾”。 | `poc.lua §G`：`GetPedInVehicleSeat() -> 7`（别人开车）→ `seat=0`；native 抛错 → `seat=0`。 | 扫 `seat = 0..GetVehicleMaxNumberOfPassengers(vehicle)-1` 找到 ped 的真实座位；找不到或 native 缺失时 `seat=nil` + `seat_source='unavailable'`，不要默认 0。补“后排乘客/错误”用例。 |
| L-08 | P2 | `live_rules.lua:239-255`、`live_api.lua:241-310`；对照 `docs/agent/design/01-live-perception.md:74-91,98,104` | 契约漂移（列表过度暴露/字段/分页缺失）：① 设计规定 `money`、`metadata` **只出现在 detail**，实现列表对 48 人全量返回 `money`（cash/bank/crypto）和 `metadata`；② 设计 `pos` 含 `grid`、z 5m、heading 15°，实现 z 25m、无 `grid`、heading 原样；③ 设计 `display_name`，实现 `name`；④ 设计 `metadata` 白名单含 `injail`，实现没有；⑤ 可选字段（无 ped、步行、native 缺失）是 **省略键** 而不是 `null`；⑥ `limit < 48` 时没有 `after`/`has_more`/`next_cursor`（设计 §2.3 104 行），`count` 只是返回条数，agent 无法知道还有多少被截掉。 | `poc.lua §F`：投影 keys 含 `money,job,gang,metadata,position`；48 人响应 22,305 B，列表内每人都有 money。`live_rules.lua:22-31` 无 `injail`；`live_api.lua:197-203` 的 `limit=1` 只断言 `count==1`，没有分页断言；手工 `?bogus=1&limit=1` → 200（设计要求 400）。 | 明确 M1 的“summary vs detail”字段表并写进文件头；列表去掉 money/metadata（或更新设计并同步 Python schema）；heading 量化或写清；可选字段统一 `null`；补 `injail` 或从设计删除；要么加 `after`/`has_more`，要么把 `limit` 的语义写成“只取前 N 个、不保证可枚举”，并让 agent 默认取 48。 |
| L-09 | P2 | `live_events.lua:34`、`:140-148` | `leftAt[citizenid]` 只增不删（`Reset()` 之外），长期运行服务器上每个出现过的玩家都留一条（含 citizenid 字符串），是**无界内存增长**；`now - leftAt[...]` 用 wall clock，NTP 回拨会误判/延长去重窗口。 | 代码直读；`leftAt` 无 prune 调用；`Reset()` 只被测试调用。 | 用固定容量 LRU（如 256）或在每次 leave 时清掉 > `LEAVE_DEDUPE_MS` 的条目；用单调时钟或只比较“最近一条”。 |
| L-10 | P2 | `live_api.lua:380-394`；`liveConfig` 76-80；`http_api.lua:267-277` | 鉴权面：① `agent_live_enabled=0` 时**在鉴权之前**返回 503 `live_disabled`；token 未配置返回 503 `live_token_not_configured`；两者让未认证请求区分“live 关闭/未配 token/已开启”，是配置 oracle（无数据泄漏，但与 actions 一样可枚举）；② live token 为空时静默回退 `cfg.token`（actions token），读能力与写 token 合一，且无启动日志，运维容易误以为已隔离——设计 §5.2（198 行）明确要求“**独立** `agent_live_token`，不复用 `agent_actions_token`：只读凭证泄漏不应导致可加钱”，当前 fallback 使这条安全目标只在显式配置两个 token 时成立；③ 回退分支没有 warning，`agent_live_token` 轮换也不会自动失效 actions token。 | `poc.lua §H`：未认证 `agent_live_enabled=0` → `503 live_disabled`；token 空 → `503 live_token_not_configured`；正常错 token → `401`；fallback 用例见 `live_api.lua:258-264`。 | 错误码顺序可以保留（与 actions 一致），但至少不要让 503 泄漏“功能存在”；fallback 在启动时打一条 warning（“live reads share the actions token”）；文档明确独立 token 才是推荐部署。 |
| L-11 | P2 | `live_store.lua:32-37,100,153-160`；`live_api.lua:342-353`；设计 §4.3（161-169 行） | cursor 契约与设计不符：⓪ 形状：设计要求 `v1:<8hex 启动 id>:<seq>`，实现是 `<os.time() 十进制>:<seq>`；Python registry 已按十进制 `^\d{1,10}:\d{1,9}$` 写死——设计、Lua、Python 三方不一致，必须有一方改；① `dropped` 是**进程生命周期累计值**（`poc3.lua` 中 300 条/256 环后每个响应都是 44），客户端会把它当成“自上次 cursor 以来丢了多少”；② `410 cursor_expired` 只回 `{error,code}`，没有设计 §4.3 的 `oldest_cursor`/`dropped_before`，也没有 epoch 头，客户端无法直接重建 cursor；③ `409` 只在 header 放 epoch，body 不带 `epoch/oldest_seq/newest_seq`；④ 纯数字 `since` 被接受但没有 `epoch_assumed` 标记。 | `poc3.lua`：`since=42/43` → `410`；`since=44` → `200`；`dropped=44` 恒定；`poc.lua §B`：`409` 仅 header。 | 明确 `dropped` 语义（建议改名 `dropped_total`，另给 `dropped_since_cursor`）；410 回 `oldest_cursor`+`epoch`；409 body 带 epoch/oldest/newest；纯数字 cursor 回 `epoch_assumed:true`。 |
| L-12 | P2 | `live_rules.lua:220`、`live_api.lua:272-288` | `citizenid` 在**列表**里经过 `sanitize_text`（去控制字符/截断），但 detail 的 `findPlayer` 用**原始** `data.citizenid` 比较。构造 `citizenid='AB\0CD'`：列表返回 `ABCD`，用 `ABCD` 查 detail → 404；连原始值也无法从 URL 请求（路径不做 URL 解码），agent 拿到的 id 不可回查。 | `poc.lua §F` + 手工：`sanitize_player({PlayerData={citizenid='AB\0CD'}})` → `"ABCD"`；`/agent/v1/live/players/ABCD` 与 `/players/AB%00CD` 均 `404 player_not_found`。 | 不应对身份键做 lossy 清洗：citizenid 只做类型/长度/字符集校验（`^[%w_-]+$`），非法则拒绝该玩家并记日志；列表与 detail 共用同一规范化函数（或都不规范化）。 |
| L-13 | P2 | `live_store.lua:141-151`（`List` 返回 `self.items[...]` 原表引用） | `List` 把环内的 `row`/`payload` 表**按引用**返回给 live_api，后者直接塞进 HTTP body。当前 `json.encode` 不修改，但任何未来调用方（MCP 归一化、测试、director）改动 `events[i]` 都会永久污染环形缓冲；也没有“只读”契约。 | 代码直读：`events[#events+1] = row`，无 copy。 | 返回浅拷贝（`{seq,type,citizenid,at,payload=copy}`），或在函数头注明“callers must not mutate”；测试可加“改返回值不影响下一次 List”。 |
| L-14 | P2 | `http_api.lua:65-75`（`GetHeader`）、`:85-96`（`secureEquals`）；`live_api.lua:94-109` | 鉴权细节：① `GetHeader` 对重复 header 用 `pairs` 遍历、返回 `value[1]`；`req.headers` 若同时存在 `Authorization`/`authorization` 两个键，命中顺序由哈希决定，代理注入的正确 token 可能被客户端伪造的第一个值覆盖（只会 401，不会绕过，但行为不确定）；② `secureEquals` 内容无关（我们测到错首字节/错末字节同为 ~3.59 µs，无短路），但循环次数 = `max(#a,#b)`，1 KB 约 55 µs、按长度线性，**token 长度可被计时推断**（内容不可）。 | `poc.lua §H`：`{'Bearer wrong','Bearer live-token'}`（数组）→ 401（只取第一个）；`timing.lua`：64 B 3.59 µs vs 1 KB 55.5 µs，错首/错末字节差异 <1%。 | 对重复 `Authorization` 明确策略（拒绝 400，或要求唯一）；`secureEquals` 先做定长哈希再比较，或在文档中接受“长度非机密”；不要在 fallback 分支用 `presented == token`（`live_api.lua:108`）。 |
| L-15 | P2 | `live_api.lua:290-310,324-353`；`live_rules.lua:75-80`；设计 §4.4（173 行）、§5.2（200-202 行） | 缺少设计承诺的背压/输入约束：live 读没有速率限制（设计 `agent_live_rate_limit`=20/s burst 40、detail 5/s、全局 100/s）、没有响应字节预算（设计 32768 B）、单事件没有 512 B 上限、没有 `live.overflow` 聚合、没有 `money.change` 500ms 合并；未知 query 参数未按设计回 400（当前静默忽略）。另有**无界字符串 CPU**：`sanitize_text` 先对完整字符串做三次 `gsub` 再截断，1 MB 的 `name` 单玩家耗时 **16.19 ms**，48 人即可 >700 ms，直接击穿 5 ms 预算。48 人列表 ~22 KB 尚可，但 `events?limit=200` 实测 **35,766 B**（单事件 176 B）已超 32 KB。 | `bench.lua`：480 native/请求；手工：200 条 `money.change`（reason='vehicle repair'）→ `#json.encode(body)==35766`；`?bogus=1&limit=1` → 200（设计要求 400）；1 MB `name` → `sanitize_player` 16.19 ms；代码无 `rate`/`max_bytes`/`truncated` 分支。 | 至少加每 token 的读速率限制（或说明由 Hub/网关负责），并对 events 总字节做预算（超限降 `limit` 并置 `truncated:true`）；单事件 payload 上限 512 B；按设计对未知 query 参数回 400；`sanitize_text` 在 `gsub` 前先按字节上限截断（如 `value:sub(1, maxLength * 4)`）。 |

---

## 3. 测试有效性（变异矩阵）

在 `/tmp/review04/mutroot` 复制整份 `custom-director`，用 `TCITY_ROOT` 指向副本，对每个变异跑 `runner.lua --case live_rules` 与 `--case live_api`。**仓库文件未改**。

```bash
python3 /tmp/review04/mutate.py
# 每个变异：cp -r custom-director /tmp/review04/mutroot/...; 替换源码; TCITY_ROOT=... lua5.4 .../runner.lua --case live_rules|live_api
```

| 变异 | 内容 | live_rules | live_api | 判定 |
|:---|:---|:---|:---|:---|
| M1 | `sanitize_player` 透传 `license` | RED（field_allowlist, pii_scan） | RED（list, detail） | 有效 |
| M2 | `project_vehicle` 不做 plate 掩码 | RED（field_allowlist） | RED（list, detail） | 有效 |
| M3 | `mask_plate` 恒等 | RED（mask_plate, field_allowlist） | RED（list, detail） | 有效 |
| **M4** | `DEFAULT_PRECISION_M = 0` | **GREEN** | **GREEN** | **缺口 T-03** |
| M5 | `quantize_position` 恒等 | RED（coarse_grid, field_allowlist） | RED（list） | 有效 |
| M6 | `sanitize_metadata` 全量复制 | RED（metadata, field_allowlist, pii_scan） | RED（list, detail） | 有效 |
| **M7** | `sanitize_text` 不去 `%c` | **GREEN** | **GREEN** | **缺口 T-02** |
| M8 | `authorized` 恒 true | GREEN（rules 不涉及） | RED（wrong_token） | 有效 |
| M9 | `LIVE_PREFIX = '/agent/'`（抢占 actions） | GREEN | RED（existing_routes） | 有效 |
| M10 | `clamp_limit` 不夹 max | RED（clamp） | GREEN | 有效（rules 兜住） |
| M11 | 短 plate 不掩码 | RED（mask_plate） | GREEN | 有效（rules 兜住） |
| M12 | `List` 忽略 epoch | GREEN | RED（epoch_mismatch） | 有效 |
| **M13** | `onMoneyChange` 的 `reason` 不做 `sanitize_text` | **GREEN** | **GREEN** | **缺口 T-01** |
| **M14** | 删除 `dropped` 自增 | **GREEN** | **GREEN** | **缺口 T-07** |
| **M15** | `jsonArray` 去掉 `__jsontype` | **GREEN** | **GREEN** | **缺口 T-04** |
| M16 | live 拦截移到 actions kill switch 之后 | GREEN | RED（18 条） | 有效 |
| **M17** | 去掉 leave 2s 去重 | **GREEN** | **GREEN** | **缺口 T-07** |
| **M18** | 409 去掉 `X-Agent-Live-Epoch` | **GREEN** | **GREEN** | **缺口 T-05** |

**7/18 存活**，且存活项正好覆盖本次的 P1/P2：事件 reason 的 PII 清洗（M13）、控制字符/UTF-8（M7）、默认精度（M4）、`dropped`/去重（M14/M17）、空数组 tag（M15）、cursor 错误头（M18）。现有用例对“**值**是否泄漏”有 PII 扫描（`cases/live_rules.lua:199-204`、`cases/live_api.lua:137-151`），但对“**文本清洗规则本身**”没有任何直接断言；PII 扫描只扫固定 fixture。

| ID | 严重度 | 文件:行 | 缺口 | 复现 | 建议 |
|:---|:---|:---|:---|:---|:---|
| T-01 | P2 | `cases/live_api.lua:305-306,362,371`；`live_events.lua:207` | 事件 reason 只用 `'repair'/'vehicle repair'`，没有“reason 含手机号/license/控制字符”的负例；M13 存活，L-01 不会被发现。 | 变异 M13；`poc.lua §A` | 加 `reason='Transfer to 555-0100'`、`reason='license:DEADBEEF'`、`reason='a\0b'` 三条，断言响应中不出现手机号/license，且控制字符被去。 |
| T-02 | P2 | `live_rules.lua:75-80`；`cases/live_rules.lua:199-204` | 没有 `sanitize_text` 的直接单测：C0/C1/零宽/bidi/UTF-8 截断全未覆盖；M7 存活，L-02/L-06 不会被发现。 | 变异 M7；`poc.lua §D` | 加参数化用例：`'A\0B'→'AB'`、`'A\u{202E}B'` 去 bidi、`rep('张',40)` 截 64 后 `utf8.len~=nil`、`'é'` 边界。 |
| T-03 | P2 | `live_rules.lua:233-237`；`cases/live_api.lua:205-212` | 没有任何用例断言 `sanitize_player` 在**不传 `precision`** 时使用 25m；`live_api` 总是显式传 convar。M4 存活，L-05 的默认回退未被锁。 | 变异 M4 | 加 `sanitize_player(player, {position=...})` 断言 `x==125`；加 `agent_live_precision=''/'abc'` 时 `precision_m==25`。 |
| T-04 | P2 | `tests/agent/lua/json.lua:163-164`；`cases/live_api.lua:161-190,310-335` | harness 的 `json.encode` **忽略 `__jsontype`**（空表恒 `{}`），因此空 `players`/`events` 的数组契约在测试里根本不可见；M15 存活。`poc.lua §I`：`json.encode(setmetatable({}, {__jsontype='array'})) == '{}'`，空响应是 `"players":{}`。 | 变异 M15；`poc.lua §I` | harness 的 json 实现 `__jsontype`（与 FXServer 同语义）；加空列表/空事件用例；真实 FXServer 行为列入 §5 实机。 |
| T-05 | P2 | `cases/live_api.lua:337-351`；`live_store.lua:127-160` | 只测了 `invalid_cursor`、`epoch_mismatch`、`limit=0`；没有 `cursor_expired(410)`、`since>newest`、超大 seq、`X-Agent-Live-Epoch` 头、`dropped` 溢出。M18 存活，L-03/L-11 不会被发现。 | `poc3.lua`；变异 M18 | 加：ring=256 压 300 条 → `since=oldest-2` 410；`since=newest+1` 断言 0 事件且 `next_cursor` 不超过 newest；`since='epoch:1e999'`；409/410 的 header/body。 |
| T-06 | P2 | `cases/live_api.lua:160-223`；`cases/live_rules.lua:157-197` | 没有非有限数（`'1e999'`、`0/0`）用例，也没有乘客/座位 native 错误用例；L-04/L-07 不会被发现。 | `poc.lua §E/G` | 加 `money.cash='1e999'`、`metadata.health=0/0`、ped=0、`GetPedInVehicleSeat` 错误/后排三条。 |
| T-07 | P2 | `live_events.lua:135-153`；`cases/live_api.lua:354-373` | 没有环形溢出 `dropped` 断言，也没有两条 drop 路径（`QBCore:Server:PlayerDropped` + `playerDropped`）在 2s 内各触发一次的用例；M14/M17 存活。 | 变异 M14/M17 | 加“capacity=256 压 300 条后 `dropped>=44`”“同一玩家两条 drop 只出 1 个 leave”。 |
| T-08 | P2 | `cases/live_api.lua:205-212,238-243,245-250,258-264` | convar 的恢复写在断言之后，没有 `finally`/pcall 保护；任一中途断言失败会把 `agent_live_precision='fine'` 或 `agent_live_token=''` 泄漏给后续 case，造成级联假失败（或假通过）。 | 代码直读：`env.convars.agent_live_precision='fine'` → `handle` → `='25'`，中间失败则不恢复。 | 用 `local ok, err = pcall(...)` + 恢复再 `error(err)`，或在每个 check 的 setup/teardown 里快照/恢复 `env.convars`。 |
| T-09 | P2 | `http_api.lua:85-96`；`live_api.lua:94-109` | `secureEquals` 的“内容无关”性质没有测试（把实现换成 `a==b` 所有用例仍绿）；它只能靠计时/代码审查保证。 | 变异 `secureEquals` → `==`：预期全绿。 | 在测试里加一个“长 token 与短 token 的循环次数相同”的可观测钩子（或导出 `SecureEquals` 的迭代计数仅测试用）；至少把这条性质写进 review checklist。 |

---

## 4. 已验证无问题

以下为**实际执行**过的正向验证（不是“读代码觉得没问题”）：

1. **投影白名单**：构造含 `license='license:DEADBEEF'`、`identifiers={discord,steam}`、`charinfo.phone='555-0100'`、`items[].info.serial`、`inventory`、`metadata.fingerprint/walletid/phone`、`secret_account`、嵌套 table、1 MB 级字符串、`__index` 元表的 `PlayerData`，`sanitize_player` 只输出 `citizenid,name,source,job,gang,money,metadata,position,heading,bucket,ping,vehicle,last_seen_ms`；对序列化结果扫 `SECRET/license/IDENT/phone/inventory/DEADBEEF` 全部 false（`poc.lua §F`）。元表只影响“读哪个字段”，不会把 `license` 带进输出（除非运维自己写 `__index` 把 license 映射到白名单键）。
2. **plate 掩码**：`'TC123AB'→'TC***AB'`、`'AB12CD'→'AB**CD'`、短牌 `'AB'→'**'`、`nil/''→nil`；M2/M3/M11 均 RED（`poc.lua §F`，`live_rules 10/10`）。
3. **控制字符（C0/DEL）**：NUL/BEL/ESC/DEL 被 `%c` 删除；首尾空白被 trim；长度上限生效（`poc.lua §D`）。
4. **鉴权主路径**：无 token → `401 unauthorized` + `WWW-Authenticate: Bearer`；错 token → 401；`agent_live_token=''` 且 `cfg.token=''` → `503 live_token_not_configured`；`agent_live_enabled=0` → `503 live_disabled`；POST + 正确 token → `405` + `Allow: GET`；大小写 `bearer` + 多空格/尾空格 → 200（`poc.lua §H`）。
5. **live 与 actions 开关独立**：`cfg.enabled=false`（`agent_actions_enabled=0`）时 live 仍 200；把拦截移到 kill switch 之后（M16）→ 18 条 RED，说明测试确实锁住了这个顺序。
6. **路由隔离**：`/agent/v1/live/players/../act`、`/agent/v1/live/../act`、`/agent/v1/live/players/..`、`/agent/v1/live/players/%2e%2e`、`/agent/v1/live//players` 均不能到达 `/agent/v1/act`（未认证时由 live 返回 401，认证后 404）；`LIVE_PREFIX='/agent/'`（M9）会抢 actions 路由，测试 RED。前缀不带尾斜杠的 `/agent/v1/live` 不归 live 管（落到 actions 503/404），符合设计。
7. **cursor 正常边界**：`invalid_cursor` 400；epoch 不匹配 409；`since == oldest-1` 被接受、`since < oldest-1` 410（`poc3.lua`，256 环、300 条：oldest=45，`since=43→410`，`since=44→200`）；`since == newest` → 0 事件、`next_cursor` 不回退；`next_cursor` 在正常区间单调推进（`cases/live_api.lua:301-335` 20/20）。
8. **limit clamp / job filter**：`nil/'abc'→48`、`0→1`、`-10→1`、`999→48`、`'10'→10`、`10.9→10`；`?job=police` 只回 1 人；`?limit=999` 夹到 2（fixture 只有 2 人）；`live_rules` 直接单测了 9 组边界（`live_rules 10/10`）。
9. **性能（harness）**：48 人一次 `Handle` = 0.368 ms（build+project+sort）；pure-Lua `json.encode` 1.918 ms / 22,305 B；合计 2.285 ms，与 commit 的 2.2 ms/21 KB 同量级。**480 次 native 调用/请求**（48×`GetPlayerPed/DoesEntityExist/GetEntityCoords/Heading/Health/Armour/VehiclePedIsIn` + 16×vehicle 三件套 + 48×bucket/ping）。`Handle` 内 `json.encode` **0 次**，生产 `main.lua` 只 encode 1 次——没有每玩家 encode，没有 O(n²)（`bench.lua`）。`events?limit=200`（2048 满环）0.022 ms。
10. **零 SQL/零 Wait/零出站**：live 四个文件无 `MySQL`/`Wait`/`PerformHttpRequest`/`CreateThread`；`live_events` 只做 O(1) 入环（`grep` 直读）。
11. **环形容量与边界**：capacity clamp 256–8192；`OldestSeq = max(1, seq-cap+1)`；`dropped` 在溢出后 >0；`since=oldest-1` 不误报过期（`poc3.lua`）。
12. **qb-core 事件签名**：`QBCore:Server:PlayerLoaded(Player)`、`PlayerDropped(Player)`、`OnJobUpdate(src,job)`、`OnGangUpdate(src,gang)`、`OnMoneyChange(src,type,amount,op,reason)` 与本 checkout 的 `player.lua:228,271,293,498`、`economy_service.lua:50`、`events.lua:10-18` 一致；`QBCore:Server:PlayerDropped` 在 `QBCore.Players[src]=nil` **之前**触发（`events.lua:15`），主路径拿得到 Player。
13. **`secureEquals` 内容无关**：错误字节在首/末的耗时 3591.9 ns vs 3583.4 ns（<1%），无短路；只有长度线性（见 L-14）。
14. **默认关闭**：`agent_live_enabled` 缺省 `'0'`；`agent_live_token` trim；`agent_live_event_buffer` 有 256–8192 clamp。
15. **停读不停采**：`agent_live_enabled=0` 只影响 HTTP（`TryHandle` 381-383），`live_events.lua:233-285` 的事件注册没有 convar 判断，事件继续入环，与设计 §4.4（174 行）一致。

---

## 5. 需实机验证（不要在合并前把“未验证”写成“已保证”）

1. **`__jsontype='array'` 在真实 FXServer `json.encode` 下是否输出 `[]`**。仓库内没有先例，harness 的 `json.lua:163-164` 明确忽略该 metatable（空表恒 `{}`）。若真实实现不支持，空 `players`/`events` 会变成 `{}`，破坏“始终可迭代”的文件头契约——按 **P1** 处理（当前未计入 §2 的 12 个 P2）。实机一行：`print(json.encode(setmetatable({}, {__jsontype='array'})))`，期望 `[]`；再在 0 人在线时调一次 `/agent/v1/live/players`。
2. **真实 `json.encode` 对非法 UTF-8 / `inf` / `nan` 的行为**：是抛错（→ `main.lua:962-968` 的 200+internal_error）还是原样输出（→ Python 解码失败）。两种都说明 L-02/L-04 成立，但错误形态不同。
3. **48 人 <5 ms 的实测**：harness 的 native 是 Lua 函数，不是 FXServer C native invoker；480 次调用在真机上的成本需在 `sv_maxclients 48` 满载、`GetEntityCoords` 等热路径上测 p50/p95。commit 的 2.2 ms 目前只是 harness 数字。
4. **`GetPlayerPed`/`DoesEntityExist` 的返回类型**：代码用 `value == true`（`live_api.lua:181`）；若该 build 返回 `1` 而不是 boolean，所有玩家会被当作 `exists=false`，position/vehicle/health 全缺。实机 `print(type(DoesEntityExist(GetPlayerPed(1))), DoesEntityExist(GetPlayerPed(1)))`。
5. **`req.headers` 的重复/大小写形态**：FXServer 是否把重复 `Authorization` 合并成数组/逗号串、是否保留大小写两个键；决定 L-14 的风险是“确定 401”还是“随机 401”。
6. **死亡/未加载玩家的字段**：`GetEntityHealth` 在死亡时是 0 还是 100、`metadata.isdead` 与 health 的同步延迟；当前实现不按 `health<=0` 兜底 `isdead`（设计 §2.1 要求），实机确认 agent 是否会看到 “health=0 / isdead=false”。
7. **`QBCore.Players` 的 key 类型**（number vs string）与 `GetPlayerByCitizenId` 的 O(n) 在 48 人下的 detail 延迟。
8. **两条 drop 路径的实际触发顺序**：`qb-core/server/events.lua:10-18` 先 `TriggerEvent('QBCore:Server:PlayerDropped')` 再清表；custom-director 的 `playerDropped` 处理器在 qb-core 之后注册（依赖启动顺序），通常拿不到 Player。实机确认不会双发/漏发。
9. **convar 热更新**：`LiveStore.Default()` 的 capacity 只读一次；`agent_live_event_buffer` 改动是否要求 restart；`agent_live_precision` 每请求读（这个是对的）。
10. **反向代理/网关路径规范化**：若网关在转发前把 `..`/`%2e%2e` 规范化，live 的“前缀即拥有”行为与 director 的 `/act` 是否仍隔离；本次仅在 Lua 层验证。

---

## 6. 修复优先级建议

1. **P1（合并前必须）**：L-01 事件 reason 去 PII（枚举或正则脱敏）；L-02 按码点截断 + UTF-8 校验；L-03 clamp `since > newest` 并禁止未来 cursor 回显。
2. **P1 配套测试**：T-01（手机号 reason）、T-02（中文名/控制字符）、T-05（410/未来 cursor/epoch 头）。
3. **P2（可与 P1 同 PR）**：L-04（finite 数值）、L-05（precision 解析 + fine 开关）、L-07（seat）、L-08（summary/detail 字段表）、L-09（leftAt 容量）、L-10（fallback 日志/错误码）、L-11（cursor 元数据）、L-12（身份键不高损）、L-13（List 拷贝）、L-14（重复 header/定长比较）、L-15（读限速/字节预算）。
4. **实机**：§5 的 1（`__jsontype`）、2（非法 UTF-8/inf）、3（48 人 5 ms）、4（boolean native）优先；这四项会改变严重度判断。
5. **不建议**把 `agent_live_token` 的 fallback 删掉——MCP 侧（`e8df70a`）已按同一规则回退；但必须在启动日志里显式提示“live 与 actions 共享 token”，否则“独立 token”只是文档承诺。

---

## 7. 复现资产

`/tmp/review04/`（不入库，可按下述重建）：

- `poc.lua`：§A PII phone、§B cursor、§C precision、§D UTF-8/Unicode、§E 非有限数、§F 恶意 PlayerData、§G seat、§H 路由/鉴权、§I 空数组。
- `poc2.lua`：无 ped 时 NaN metadata；`poc3.lua`：256 环的 410/边界/dropped。
- `bench.lua`：48 人基准 + native 调用计数；`timing.lua`：`SecureEquals` 计时。
- `mutate.py`：18 个变异体（`/tmp/review04/mutroot` 副本，`TCITY_ROOT` 指向它）。

最小复现（PII + cursor + UTF-8）：

```bash
lua5.4 /tmp/review04/poc.lua
lua5.4 /tmp/review04/poc3.lua
lua5.4 /tmp/review04/bench.lua
python3 /tmp/review04/mutate.py
```

内联关键片段（无需 /tmp 也能手工跑）：

```lua
-- L-01: 事件 reason 带手机号
TriggerEvent('QBCore:Server:OnMoneyChange', 1, 'bank', -250, 'remove', 'Transfer to 555-0100')
-- GET /agent/v1/live/events  -> events[1].payload.reason == 'Transfer to 555-0100'

-- L-02: 字节截断切断 UTF-8
local cut = LiveRules.sanitize_text(string.rep('张', 40), 64)
assert(#cut == 64 and utf8.len(cut) == nil) -- 末尾 E5

-- L-03: 未来 seq 被回显
local s = LiveStore.New({ capacity = 256 })
for i = 1, 3 do s:Push({ type = 'player.join', citizenid = 'C', at = i }) end
local events, meta = s:List({ epoch = s.epoch, seq = 999999999 }, 10)
assert(#events == 0 and meta.next_cursor == s.epoch .. ':999999999')
```

---

## 8. 最后 5 行（TL;DR）

P0 0 / P1 3 / P2 12；另有 9 条测试缺口（T-01…T-09，均为 P2，未重复计数）。
最严重：`live_events.lua:207` 把 `OnMoneyChange` 的 reason 原文带入事件，`custom-phone` 的 “Transfer to/from <手机号>” 使玩家手机号进入 `/live/events`（设计明文禁止 `charinfo.phone`，P1 / L-01）。
其余 P1：`live_rules.lua:78` 按字节截断 UTF-8，中文名 >64 B 可产生非法 JSON，整包 48 人列表失败；`live_store.lua:138,158` 回显未来 seq，事件流可被静默搁置（P1 / L-02、L-03）。
结论：**需修后合并**——先修 3 个 P1 并补 T-01/T-02/T-05，再处理 P2 与 §5 实机项。
不阻断：无 P0；路由隔离、鉴权主路径、投影白名单、plate 掩码、环形正常边界未发现可利用绕过，48 人基准在 harness 下可复现（0.368 ms build + 1.918 ms pure-Lua encode / 22.3 KB）。
