---
id: base-agent-reviews-08-phase2
type: audit
status: final
system: agent
owner: hermes
updated: 2026-10-25
---

# 08 — Phase 2 快速安全评审（A 手机系统短信 / B agent_effects 审计 / C live money）

- 仓库/分支：`T-City-agent` @ `feat/agent-takeover-v2`
- 范围：`git diff b738a80..HEAD`（3 个提交，24 个文件，+944/−57）
- 基线：`lua5.4 tests/agent/lua/runner.lua` = 8 suites / 228 checks / 0 failed；`pytest tests/agent` = 203 passed, 3 skipped
- 性质：只评审、不改仓库；3 个变异均在 `/tmp/tcity-mut` 副本上做，仓库工作区未改动
- 时间盒：12 分钟，覆盖 3 个指定点，未展开全仓审计

## 结论

**可合并**。未发现客户端可利用的 P0/P1：`SendSystemMessage` 确实只走服务端导出、无新网络入口；`agent_effects` 不落 payload；live 列表 money 的移除被测试锁住。存在 3 条 P2（1 条潜伏功能缺陷、1 条单测空缺、1 条审计字段可被客户端写自由文本）和 4 条 P3 加固项，均不阻塞合并，建议随分支或紧随其后修掉 P2-1/P2-2。

## 发现表

| ID | 严重度 | 位置 | 问题 | 复现 | 建议 |
|---|---|---|---|---|---|
| A-P2-1 | P2 | `T-CityLite.base/resources/[custom]/custom-phone/server/main.lua:380-388`、`:406-415`；列定义 `:19` | 导出把 label 上限写成 **32 字节**，但 `phone_messages.sender_number` 是 `VARCHAR(20)`。任何 21–32 字节的 label 会通过导出校验、却在 INSERT 时触发 MariaDB 严格模式 `1406 Data too long`，被 pcall 捕获后返回 `false,'db_error'` —— 即导出接受了一个它永远存不下的入参；>32 字节时 `sub(1,32)` 按字节切还可能切断 UTF-8 码点。默认 label `City Services`（13 字节）不受影响，当前唯一调用方也写死该值，所以暂未触发。文档只写“默认 label 放得下”，没写“其他 label 会失败”。 | 临时脚本：`exports['custom-phone']:SendSystemMessage('555-0100','hi','A'):rep(21)` → `false,'db_error'`（严格模式）；`'中文标签…'` 截断后可能插入失败或乱码。 | 截断上限改为与列一致的 **20 字节且 UTF-8 安全**（复用同文件 `TruncateUtf8`），或把列 `ALTER` 到 `VARCHAR(32)`；同步 ACTIONS.md 的“caps at 32 chars”描述。 |
| A-P2-2 | P2 | `T-CityLite.base/tests/agent/lua/cases/director_actions.lua:1914-1980`；`STATUS.md:82` | 新导出 **没有仓内单测**：director 侧 4 个用例全部用 `export_overrides['custom-phone'].SendSystemMessage` 打桩，`resources/[custom]/custom-phone/server/main.lua` 在测试里从未被加载。因此导出的校验/截断/事件推送全部无回归保护。STATUS.md §6.2 已自认“只有临时冒烟脚本”，但 CI 不覆盖。 | 变异 1（见下）：删掉 `SystemSenderLabel` 全部校验，8 suites 仍全绿。 | 增加一个纯 Lua 用例（stub `MySQL`、`GetPlayerByPhone`、`TriggerClientEvent`），覆盖：超长/非字符串 label、21 字节边界、控制字符、空号码、DB 失败返回 `db_error`、在线/离线两条推送路径。 |
| B-P2-3 | P2 | `T-CityLite.base/resources/[custom]/custom-agent-client/server/main.lua:306-313`、`:120`；迁移 `v2.6_agent_effects.sql:31` | `error_code` 名义上是“机器码”，实际是**客户端可控的自由文本**：ack 的 `error_code` 只做 `gsub('%c',' ')` + `sub(1,64)`，随后原样写入 `agent_effects.error_code`。目标玩家（持有合法 session + request_id）可让审计表出现任意 ≤64 字节文本，与“machine code only / no free text”的迁移注释不符，属审计可信度问题；不是 payload 泄露（正文另有测试锁定）。 | 目标客户端回 `tcity:agent:ack`：`{status='failed', error_code='<任意64B文本>'}`；`SELECT error_code FROM agent_effects` 可见该文本。 | 把客户端 ack 的 code 收敛到白名单（`client_rejected`/`client_failed`/已知错误码），自由文本只放服务端日志；或单独列 `client_code` 并注明 untrusted。 |
| B-P3-1 | P3（需实机） | `custom-agent-client/server/main.lua:105-127`、`:149-164`、`:361-380` | 审计 INSERT 放在 `settle()` 里、`promise:resolve` 之后，且 `playerDropped` / `onResourceStop` 都会走 `settle()`。资源停止时 `MySQL.insert.await` 可能不再返回，`executor_stopped` 行可能丢失（结算本身不受影响）；`await` 位于 `pcall` 内且从 `SetTimeout` 回调触发，纯 Lua 桩无法证明 FiveM 调度器里可 yield。 | 实机：触发一个 pending effect 后 `stop custom-agent-client`，查 `agent_effects` 是否有该 request 的 `executor_stopped` 行；或在 timeout 回调路径观察 insert 是否报 “cannot yield”。仓库内已有 `pcall + *.await` 先例（`tcity-e2e/server/main.lua:96`），风险不高。 | 标“需实机”验证；若要保证停止时审计完整，可在 `onResourceStop` 改用同步/非 await 的 `MySQL.insert` 回调或只写 console。 |
| C-P3-2 | P3 | `custom-director/server/live_rules.lua:287`；`live_api.lua:211`、`:316`、`:377` | 默认是“包含 money”（`opts.include_money ~= false`），列表安全完全依赖唯一调用点显式传 `{include_money=false}`；详情则依赖 `nil` 走默认。当前有测试锁住（变异 2 会红），但以后新增任何 `samplePlayer` 调用者忘记传 flag 就会默认泄露余额。 | 变异 2：把列表调用改回 `samplePlayer(player, precision)` → `players_list_envelope_and_fields` 红。 | 改为默认**不含** money，详情显式 `{include_money=true}`（默认关闭、按需开启），语义与“list 最小集”一致。 |
| A-P3-3 | P3 | `custom-phone/server/main.lua:407-414` | `receiver_number` 只校验 `string` + 1..15 字节，不校验数字/控制字符，也不校验号码存在；`message` 只校验长度，不拒绝控制字符（director 的 policy 拒绝了，但导出自身没有防御）。仅服务端可信资源可调，故不构成客户端攻击面；是纵深防御缺口。 | 服务端临时脚本传 `receiver='\1\2'` 或 15 字节非数字 → 行照写。 | 号码加 `^[%d%-%+]+$` 类白名单并去控制字符；`message` 复用 policy 的 C0/DEL 拒绝逻辑（保留 LF）。 |
| B-P3-4 | P3 | `custom-agent-client/server/main.lua:61-65`、`:115-121` | `truncate()` 按字节切，`agent_id`/`error_code` 为多字节 UTF-8 时可能截出非法序列，utf8mb4 列在严格模式下会拒绝该行 → 审计行丢失（有 pcall，只告警）。 | 单测：`agentId = ('汉'):rep(30)`（90B）→ truncate 到 64B 切断码点；实机 INSERT 可能 1366。 | 截断改为 UTF-8 边界安全（同仓库 `TruncateUtf8`/`sanitize_text` 思路）。 |

## 变异结果（/tmp 副本，3 条）

| # | 变异 | 命中测试 | 结果 |
|---|---|---|---|
| 1 | 删除 `custom-phone` 的 `SystemSenderLabel` 校验（直接 `return label`） | 无 | **绿**：8 suites / 228 checks，0 failed → 导出零覆盖（A-P2-2 的直接证据） |
| 2 | 列表恢复 money：`samplePlayer(player, precision, {include_money=false})` → `samplePlayer(player, precision)` | `live_api::players_list_envelope_and_fields` | **红**：`player has unexpected field "money"` → 列表无 money 已被锁住 |
| 3 | 审计错误上抛：`if not ok then auditInsertFailed(err) end` → `error(err)` | `effect_server::audit_insert_failure_does_not_change_exec_result` | **红**：`...main.lua:124: Table tcity.agent_effects does not exist` → “insert 失败不影响 settle”已被锁住 |

补充：详情有 money 由 `live_api.lua:222`（`response.body.player.money ~= nil`）锁定；基线 pytest 与 Lua 全绿。

## 已验证不可利用清单

- **A：无客户端入口。** `grep -n 'RegisterNetEvent\|CreateCallback' custom-phone/server/main.lua` 的新增行只有导出本身（`:406`），diff 未新增 net event/callback；`SendSystemMessage` 仅被 `resources/[custom]/custom-director/server/main.lua` 的 `executeSendPhoneMessage` 在服务端调用，`senderLabel` 写死 `'City Services'`。客户端既不能伪造 sender，也不能触发系统短信。
- **A：SQL 参数化。** `phone_messages` 与 `agent_effects` 的 INSERT 全部 `?` 占位；`receiver_number` 15 字节上限小于列宽 20，`message` 500 字节进 `TEXT`，不存在注入或溢出。
- **A：sender 伪造。** 玩家短信回调 `phone:server:sendMessage` 的 `sender_number` 取自 `PlayerData.charinfo.phone`，客户端不可指定；新导出也不接受客户端参数。
- **B：不落 payload/正文。** `auditToDb` 的 7 个参数只来自 request_id/agent_id/src/action/status/error_code/elapsed；`settle_ok_writes_one_agent_effects_row_without_payload` 会逐列扫描 notify 正文，`open_text_ui_audit_does_not_contain_body` 覆盖 UI body。
- **B：status 白名单。** `AUDIT_STATUS` 含 7 个终态，未知值落 `failed`；所有 `settle()` 调用点（ok/rejected/failed/cancelled/timeout/player_offline/executor_stopped）均在白名单内。
- **B：伪造 ack。** 需要匹配 `pending[src][request_id]` + `entry.session`，且 `ack.status` 必须在 `ACK_STATUS`；伪造 ack 被丢弃并计入 `dropped_acks`（有测试）。
- **B：insert 失败不影响 settle。** `promise:resolve` 在 `audit()` 之前，`auditToDb` 整体 pcall，失败只打印（变异 3 证明测试有效）。
- **C：列表/详情/工具描述一致。** 列表走 `listPlayers` 且显式 `include_money=false`；详情走 `samplePlayer` 默认含 money 并被测试锁住；`tools/agent_tools.json:436` 的 `get_live_players` 描述只承诺 positions/vitals/job/vehicle，无 balances；`get_live_player` 描述新增 balances 与实际返回一致。`money.change` live 事件仍带 `after` 余额，但这是 design 01 §7（`:508`）的明确设计，不算本次回归。

P0：0；P1：0；P2：3；P3：4
最严重一条：A-P2-1 `SendSystemMessage` label 上限 32 字节 vs `sender_number VARCHAR(20)`，21–32 字节 label 必得 `db_error`（潜伏功能缺陷，当前调用方写死 13 字节故未触发）
建议：**可合并**；合并前顺手修 A-P2-1 并补 A-P2-2 的导出单测，B-P2-3 随下个审计迭代收敛
基线：`b738a80..HEAD` @ `0218e68`，2026-10-23
