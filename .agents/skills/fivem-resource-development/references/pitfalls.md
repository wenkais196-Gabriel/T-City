# 坑位清单

每条都是真实踩过、且**看代码看不出来**的东西。正文只保留常驻规则，这里放完整清单——
不确定的时候先扫一遍标题。

## 完整清单

- **An ack proves the page exists, not that focus took.** Read the diagnostic stages separately:
  `open-ack` present means CEF loaded and rendered; `focused=false` / `keepInput=false` in the
  stages emitted after `Acquire` mean the focus natives did not stick — that is a different bug,
  and "no UI on screen" must never be inferred from it. Ask the player which of the two they see
  (nothing at all vs. a visible page with the mouse still driving the camera) before touching
  either path.
- **Diagnose focus with a probe that opens no UI.** A client command that does
  `SetNuiFocus(false,false)` → `Wait(100)` → `SetNuiFocus(true,true)`, samples
  `IsNuiFocused()`/`IsNuiFocusKeepingInput()` every ~100 ms for ~2 s, then always `Reset()`s
  (so input is never left locked), separates "the natives do nothing on this client" from "a
  resource steals focus right after us". Recipe in `references/nui-delivery-and-focus.md`.
- **A retrying test helper proves "eventually works", not the single-shot path the player takes.**
  Read the helper before citing its pass as verification of the user-visible flow.
- **Cross-resource exports fail inside `pcall` when the target is only loaded by a dev cfg.** On a
  production start chain such an action returns `execution_failed` and looks like a bug in the
  caller. Register the resource in the repo's export-consumer allowlist as a deferred/dev-only
  dependency instead of adding it to the production chain.
- **A config URI printed as `user:***@host` is tool-side secret masking, not a broken config.**
  Extract it into a shell variable and test the connection before declaring the DB unreachable.
- **A green NUI suite does not prove the open path.** Headless scenarios drive callbacks directly;
  only the ack/resend loop catches a dropped open message after `restart <resource>`.
- **A user-facing error string is usually produced by the transport wrapper, not the server.** Grep
  the frontend for the literal text the player reports (`查询失败`, `Request failed`) and read the
  branch that emits it before touching either end: a generic fallback code means the fetch
  rejected/aborted, so the server never sent that string and has nothing to log.
- **The repo's architecture gates will stop a new net event or export, and that is the gate doing
  its job.** A client→server telemetry event has no capability token by design: register it in the
  repo's net-event allowlist under the `diagnostic` category with the whitelist/limit evidence, and
  if the gate matches on a guard token in the handler body, extend the guard **and** add a test that
  the claim holds where the delegation lands — widening the pattern alone lets any function name
  satisfy it. Same shape for a new cross-resource export: start the resource or register it as a
  deferred/dev-only dependency, never silently.
- **Absence of a diagnostic line is not evidence.** A per-phase cooldown drops the second event of
  a burst, and FXServer prefixes are right-aligned so a naive `grep '^\[script:x\]'` misses every
  line from a short resource name. Before concluding "the client never sent it", confirm the log you
  are reading is the live one, and read a page of the console right after the action rather than
  trusting a stale file.
- **`rawget(_G, 'X')` cannot see a global another script defined.** Each FXServer script gets its
  own environment table and reaches the shared globals through `__index`, which `rawget` bypasses —
  so a module defined in one file reads back `nil` in the next, and the optional-dependency guard
  silently disables the feature (a trace that never starts, a limiter that never limits). Read the
  name directly (`local mod = PhoneDiag; if type(mod) == 'table' then …`) and use the same shape for
  engine globals (`Citizen`, `GetConvar`, `GetGameTimer`). The `rawget` form survives review
  precisely because it looks defensive, so grep for it when a cross-file module reads as nil.
- **Gate an on-load self-probe to the real CEF host.** A page that fires a synthetic request at
  load eats whatever the headless scenario scripted for the next request (the scripted 500 lands on
  the probe, the scenario then sees a healthy reply and fails on the wrong assertion). Require
  `location.protocol === 'https:' && location.host === 'cfx-nui-' + GetParentResourceName()`.
- **Keep the legacy callback names.** Replacing a callback rather than adding one breaks callers in
  other resources that were never in your diff.
- **Calling another resource's export: wrap lazily, never alias at load.**
  `local f = exports['core']:Foo` resolves at file load, so any start-order change breaks it with
  `No such export`; write `local foo = function(...) return exports['core']:Foo(...) end` and the
  lookup happens per call. Register on the correct side only
  (`if not IsDuplicityVersion() then exports('Foo', fn) end` for anything touching client natives like
  `RequestAnimDict`), and add the file to `shared_scripts`/`client_scripts` or it never runs.
- **oxmysql returns SQL errors as a value, so `pcall` reports success.**
  `MySQL.insert.await(...)` hands back the error **string** instead of throwing, so
  `local ok = pcall(function() return MySQL.insert.await(sql, p) end)` is `true` on a broken
  statement and the caller's `if not ok then` never fails closed — in this repo six of eight audit
  implementations lost rows this way, with nothing in the server log. Always test the payload:
  `local ok, res = pcall(...); if not ok or type(res) == 'string' then return false end`.
- **A test stub that answers `true` (or an empty body) to everything hides the bug it is meant to
  catch.** An export stub returning `true` for every unregistered method made a convar gate read
  `enabled = false` and every HTTP adapter case answer 503 for weeks; an empty `fetch` body made the
  phone UI throw on `JSON.parse` while the test still passed its visual assertions. Stubs must return
  the shape the real thing returns, and must call what was actually registered.

- **A green local suite is not evidence the pipeline is green — run the CI commands in a fresh
  clone.** Tests that read `server.cfg` (gitignored), or write into a repo whose path happens to
  contain `cache/`, pass locally and fail on the runner. Reproduce with
  `git clone . ~/ci-verify` then run exactly the workflow steps; the diff between the two
  environments is the bug.

- **A parameter array with a nil hole gets truncated, and the SQL then reports a syntax error.**
  A hole is not only a trailing nil: `{ nil, incidentId, reportId, ... }` (leading nil, the natural
  shape for an auto-increment id you fill in after the insert) truncates to zero parameters and every
  call fails with `syntax error near '?)'`. Two independent features in this repo were dead this way
  for weeks, and both looked like a business-layer rejection in the log. Build the column list and the
  values together and put `NULL` into the SQL text for absent fields; then add a gate that a table
  has exactly one writer, because a second copy re-learns the same bug from scratch.
- **Consolidating N copies of a write reveals that some of them were broken.** Treat "merge the
  duplicates" as a bug hunt, not a cleanup: diff the SQL shapes and the failure handling before
  picking the survivor, and prove the survivor's behaviour against the real database with a startup
  probe. A "single writer" gate is worth more than the merge itself, because it stops the next copy.
- **Do not migrate upstream (`[qb]`, vendored `[standalone]`) helpers onto your own core exports.**
  It reads like deduplication but it forks upstream: their next sync conflicts, and a broken core
  resource now takes vendored features down too. Consolidate your own code; record upstream copies as
  intentional duplication with a written reason and a ratchet budget.
- **A duplicated helper is often a hidden hang.** `while not HasAnimDictLoaded(dict) do Wait(5) end`
  copied 17 times blocks the client thread forever on a wrong dict; the shared version needs a
  deadline (`GetGameTimer() + timeout`) and a boolean return so callers can log instead of freezing.

## 无差别字符串替换会污染同一文件里的其它函数

`str.replace(old, new)` 不带计数时，只要那段代码在文件里出现多次，就会**全部**被替换。
qb-inventory 里 `local invName = player and GetPlayerName(identifier) .. ' (' .. identifier .. ')' or identifier`
这一行在 SetInventory / AddItem / RemoveItem 三个函数里各有一份。改 SetInventory 时顺手
把它换成用局部变量 `idText` 的版本，另外两个函数并没有 `idText` —— Lua 把它当**全局**读成
nil，于是 `giveitem` 直接报 `attempt to concatenate a nil value (global 'idText')`。

两个教训：

- 改共享行模板前先 `grep -c` 数出现次数；出现多次就要么带 `count=1` 加唯一上下文，要么一次改干净并给每个函数补上依赖；
- **测试要覆盖所有调用同一模板的函数**。SetInventory 的测试当时是绿的，坏的是 AddItem/RemoveItem，
  而 giveitem 走的正是 AddItem。现在 INV-01 会分别用数字和 citizenid 各调一次这三个入口。
