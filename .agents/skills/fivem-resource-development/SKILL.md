---
name: fivem-resource-development
description: Use when building or debugging FiveM resources.
version: 1.1.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags:
      - fivem
      - fxserver
      - nui
      - cef
      - gta5
      - game-server
    related_skills:
      - debugging-and-error-recovery
      - agent-handoff-recon
---

# FiveM / FXServer resource development

For NUI (CEF) UI work, client Lua, focus/frame handling and resource wiring on a FiveM server:
"the UI didn't appear", "it only breaks after `restart <resource>`", "the page opens but every
button shows an error", "the mouse stays locked after closing".

## When to Use

- A NUI page did not appear, appeared empty, or only breaks after `restart <resource>`.
- Input is locked, the mouse is missing, or two UIs fight over focus after open/close.
- A resource's callbacks/queries work once but never on a concurrent second call.
- A change must be proven without a connected game client (unit gates, headless NUI, server boot).
- Wiring a new client/server file, export or dev-only resource into an FXServer start chain.
- Merging duplicated helpers across resources into a shared core.

Not for the visual design of the page itself; this is the runtime contract — delivery, focus,
request pairs, load order.

## Always-on rules

**Delivery**
- **Never trust `SendNUIMessage`.** Fire-and-forget: a frame sent while CEF reloads is dropped with
  no error, leaving Lua's `isOpen = true` with nothing on screen. Resend until the NUI acks, set
  state only when the ack lands, and on timeout clear state + release focus + tell the player.
- **One waiter per channel, superseded not duplicated.** Key waiters by channel; a second open
  replaces the old one. Without the key, a reload mid-loop leaves two loops racing and the UI flickers.
- **Register a toggle keybind once, and debounce inside the command.** `RegisterKeyMapping` in
  `onClientResourceStart` re-registers on every client reload, so one key press dispatches twice:
  first opens, second sees `isOpen` and closes — "the key does nothing". Guard with a
  `keyMappingRegistered` flag *and* a ~300 ms window; the signature is open stages followed
  immediately by close stages, no ack between.
- **A NUI fetch failure is invisible until you forward it.** When the POST never lands, Lua never
  runs and the server log stays empty. Send `{source, event, reason, status, message}` to the
  resource's own `clientError` via raw `fetch` (never `fetchNui` — it recurses), cooldown per
  `event+reason`, whitelist + truncate server-side.
- **A NUI callback's answer channel is not always a `function`.** Assert `type(cb) == 'function'`
  and every reply is silently dropped while the server log shows a delivered reply. Normalise in one
  place: plain function → callable table via `__call` → `Citizen.InvokeFunctionReference`; skip the
  handler when no channel can be built. Depth: `references/nui-delivery-and-focus.md`.

**Focus & input**
- **One focus owner stack.** `SetNuiFocus`/`keepInput` are global; register owners, release on every
  exit path including `onResourceStop`, restore `keepInput` deliberately.
- **An ack proves the page exists, not that focus took.** `open-ack` + `focused=false` is a focus
  bug, not a missing UI — ask the player which of the two they actually see.

**Data & concurrency**
- **Anything concurrent needs a `request_id`.** qb-core keeps one pending callback per name, so two
  in-flight queries overwrite each other and the first fetch never resolves. Use a
  client-generated id + a dedicated request/response event pair, keeping the legacy callback for
  other callers.
- **Parse the body before classifying a non-2xx as transport failure.** A structured JSON error can
  arrive with a 5xx; checking status first turns every failure into one generic message. A missing
  callback answers 404 with an empty body and `resp.json()` throws a `SyntaxError` that mimics a
  network error.
- **Rate limits are explicit at the call site** — pass `(ratePerMinute, burst)` literally; tests
  hardcode the burst and go red later. A token bucket must also spend a token on its *first* call:
  seeding it full and returning early lets `burst=N` pass `N+1` requests, an off-by-one only a real
  burst-boundary test (injected clock, not sleeps) catches.
- **Money has exactly one writer, and the offline branch belongs to it.** Online balances live in
  memory (`QBCore.Players[src].PlayerData.money`) and flush via the dirty-flag manager; when the
  counterparty is offline there is no player object, so the credit has to touch the row. Put that
  single SQL statement inside the economy service (`AddMoneyOffline(citizenid, moneytype, amount,
  reason, cb)` at the owner, exported for other resources) instead of letting each feature write
  `players.money` itself — and never `SET money = ?` from an earlier read, which reverts every other
  balance the row holds. Every caller must  roll back its own debit when the credit comes back false. The amount binds as a DOUBLE, so
  `DECIMAL(20,2) + ?` drifts — `100 + 0.55` stores `100.5499999999999545`. Wrap the whole arithmetic
  in `ROUND(..., 2)` and assert in the gate that `ROUND` encloses it, or every balance the player
  ever sees carries float garbage.
- **Two layers registered under different Bus keys is a coin flip for callers.** `GetEconomy()
  returning `Bus.economy or Bus.EconomyService` hands out whichever registered first, and the two
  have different method sets (one lacks `RemoveMoney`/`SetMoney`). Return the primitive layer from
  the accessor and expose the convenience layer (`AddScaled`, `Transfer`) under its own name.

**Observability**
- **Never a per-request `print`.** Use the whitelisted diag channel with per-phase rate limits: a
  single per-source cooldown eats the tail of one transition and makes "NUI never answered"
  indistinguishable from "focus never applied".
- **Trace the whole round trip in one record.** Sample once at the end of the chain (slow, failed,
  warm-up, or level=2) and let the server render the path of **observable** slots. Only slots a Lua
  client can prove belong in the verdict; the NUI's own send/resolve marks are unobservable and
  report healthy requests as broken. Depth: `references/request-trace-diag.md`.
- **Give the client a channel, or the server will never see client state.** A client `print` lives in
  the player's F8 and never reaches the server log, so "did the new client file load", "is the
  include live", "did the export resolve" are unanswerable after the fact. Ship two events in the
  core resource: a **ready beacon** the shared client include sends once after load
  (`<resource> + version` from `GetResourceMetadata`, logged as `[client-ready] res v1.2.3 player(#id)`)
  and a **report** entry point (`CFShared.Report(kind, msg)`) for branch-level failures. Treat it as
  a diagnostic channel, because its *input is fully client-controlled and its output is the server
  log*: strip every control character (a newline lets a client forge whole log lines), truncate each
  field, whitelist `kind`, rate-limit per source **through the limiter owner**, and ignore
  `source == 0`. Register the event names as **string literals** — scanner-based gates read the
  literal, so `RegisterNetEvent(EVENT_NAME, …)` makes the event invisible to every architecture
  check. Say plainly which half is proven: both halves are unit-testable with natives stubbed, but
  "a real player sees the beacon" needs a real login.

**Code sharing**
- **Pick the sharing mechanism by call frequency, not by habit.** Anything with state or a
  cross-resource return value goes **behind an export**, and callers wrap it lazily:
  `local f = exports['core']:Foo` resolves at **load** time, so a start-order change turns it into
  `No such export`; write `local foo = function(...) return exports['core']:Foo(...) end`.
  **Per-frame drawing/math helpers must not use exports at all** — every call crosses the runtime
  boundary, which at marker-per-frame density becomes frame time. Ship them as an *include*:
  `client_scripts { '@core/…/shared.lua', … }` in the caller's manifest (the same mechanism as
  `'@oxmysql/lib/MySQL.lua'`), which splices the file in at load — zero call overhead and no
  start-order race. Reference it as `CFShared.DrawText3D`, guard the load with a one-line warning +
  no-op fallback so a missing include is loud in F8 instead of killing the client script, and keep
  a startup self-print in the shared file so "did the include land" costs one glance.
- **When many call sites already depend on a local name, keep the name and replace the body.**
  Four call sites plus a diag module were reading `PhoneRateLimit.Allow`; renaming it to the owner's
  export would have touched every one of them for no behavioural gain. Leave the façade holding the
  caller-facing signature and its own domain knowledge (which convars/Config keys supply the
  defaults), delegate the algorithm, and **fail closed** when the owner is unavailable — a rate
  limiter that silently allows everything because a dependency is missing is worse than one that
  rejects and says so once.
- **A helper called at load time needs a declared dependency.** Reading convars at the top of a
  `config.lua` happens the instant the resource loads, so the consumer's `fxmanifest` must list
  `dependencies { 'core' }`; without it a start-order change fails the whole resource instead of one
  animation. Gate this: assert every load-time caller declares the dependency.
- **A duplicated helper is often a hidden hang.** `while not HasAnimDictLoaded(d) do Wait(5) end`
  blocks the client thread forever on a bad dict — the shared version needs a deadline and a boolean
  return.
- **A "duplicate" may be a file nothing loads — check manifest membership before merging.**
  The scan finds N copies; only the manifest decides which of them run. A resource split leaves the
  old file behind (security → its own resource, logs → the log resource, a panel → its own system
  resource) with handlers and exports intact: it reads as authoritative, inflates every duplicate
  metric, and makes `exports['<old>']:LogSecurity` look callable when it throws on first use. For
  each copy confirm it is in its `fxmanifest.lua` (a literal path or a `dir/*.lua` glob); the
  unlisted ones are residue — delete them rather than "merging" them, and gate it (every `[custom]`
  script must be listed, `_`-prefixed temp files and `tests/` exempt) so the next split cannot leave
  another.
- **Consolidate only code you own.** Upstream/vendored copies (`qb-*`, third-party `standalone/`)
  stay duplicated: pointing them at your core forks upstream and breaks their next sync. Record
  retained copies with a written reason and a ratchet budget instead of a cleanup sprint.
- **Content-hash the NUI build artifacts.** CEF caches per iframe, so a fixed `assets/index.js` keeps
  running yesterday's JS after `restart` while Lua runs new code — a *specific* feature fails while
  the handshake still works. Emit `assets/[name]-[hash].js|css`.
- **A shared audit/log helper written for the online path throws for an offline actor.** It formats
  `GetPlayerName(source)` and a numeric balance with `%d`; an offline player has neither, so the
  helper raises `bad argument` or formats `nil` mid-transaction. Write the offline branch's audit
  line explicitly rather than teaching the helper to accept a fake player object.
- **Scripted bulk edits need a bounded block and a before/after symbol diff.** When replacing N copies
  of a helper across files, bound the replacement by the function's own closing `end` at the same
  indentation — never by "the next marker line": a two-marker slice silently deleted an entire
  service definition, and `luac5.4 -p` still passed because the file stayed syntactically valid.
  After the run, diff the set of `function` names per file against `git show HEAD:<path>` and require
  zero losses.

## Verify without a game client

```bash
luac5.4 -p client/main.lua server/main.lua                     # syntax
/usr/bin/python3 -m pytest tests/unit tests/architecture -q    # unit + architecture gates
npx svelte-check --tsconfig ./tsconfig.app.json                # types, before any build
node tests/nui/run.mjs                                         # headless NUI (playwright-core)
```

Then `restart <resource>` on the live server and read the boot lines: `Started resource X` with no
`stack traceback` is the layer the unit gates cannot prove. Detail, ordering and what each check does
*not* prove: `references/verification.md`.

- **For server-side logic, prefer a start-time probe that writes a report file.** A temporary
  `CreateThread` in a resource that already declares its dependencies, calling the real exports
  against the real DB, then `SaveResourceFile`-ing its findings, and a full restart to read them — no
  console typing (which mangles commands) and no echo to interpret. Money arithmetic, limiter
  boundaries and lost updates only fail here, never in a mocked unit test. Recipe:
  `references/verification.md`.

Traps worth memorising here:

- `luac5.4 -p` is a syntax gate only for **pure Lua**; CfxLua files use `+=`, `//` and backtick hash
  literals and never pass — verify the failure predates you (`git show HEAD:path`) before reading
  your diff, and never rewrite `+=` to make a checker green.
- **A shared export can be broken while every static check is green.** A missing export only throws
  at the first call, and a client `print` lives in the player's F8 console, not the server log. Prove
  it with a throwaway probe that reports through a server-visible diagnostic event, then delete it:
  recipe in `references/verification.md`.
- **`dependencies` is enforced at start, so a broken core takes the whole chain down.** Editing a
  manifest into invalid Lua (a missing comma after the last entry is the classic) is **invisible to
  `restart <resource>`** — the server reuses its parsed metadata — and only shows up at the next
  `refresh` or full boot, as "N resources failed to load" with the rest of the server still running.
  That reads like "the server died" rather than "one manifest is broken". Therefore: parse every
  `fxmanifest.lua` with `luac5.4 -p` in a gate (`scripts/check_manifests.sh` does the sweep), treat
  `dependencies` as a hard start barrier (a core
  script error keeps every dependent down), and after touching a core manifest or core script do a
  full restart and **count `Started resource` lines** instead of trusting per-resource restarts.
- **`luac5.4 -p` passing does not mean FXServer can load the file.** The two parsers disagree in
  both directions: CfxLua extensions (`+=`, backtick hashes) fail luac, and CfxLua rejects shapes
  luac accepts — `type(exports['core']:Method)` is valid Lua grammar but the runtime answers
  `function arguments expected near ')'` and `Failed to load script`. A file that luac-approved and
  the server refused will not announce itself anywhere else. So after adding a file, read the boot
  log for `Failed to load script` / `Error parsing script`; absence of those two lines, next to
  `Started resource`, is the only proof of loadability.
- **Run the test selection CI runs, not the two directories you always run.** `tests/unit` plus
  `tests/architecture` can be fully green while `tests/agent` (pure-Lua harnesses) and
  `tests/integration` (concatenated-resource scripts) have been red for a dozen commits. Read the
  workflow file and run every `pytest` invocation in it before claiming a change is verified — a
  red pipeline is often just "nobody ran that directory locally".
- **A Lua harness's `exports` proxy must call what the env actually registered.** A stub that answers
  every unknown `exports['res']:Method(...)` with `true` hides the real dependency: a resource that
  reads `exports['core-framework']:ConvarString('flag','0') == '1'` gets `true`, so the feature is
  "disabled" and every HTTP route answers 503 while the harness reports no error at all. Make the
  proxy look up `env.exports[name]` first and only fall back to the log-and-return-`true` behaviour
  for genuinely unregistered names.
- **Load the `shared_scripts` files in the harness, in manifest order.** Globals defined by a shared
  file (`ConvarString`/`ConvarInt`/`ConvarFloat`/`ConvarBool`, `LoadAnimDictBlocking`) are nil in a
  harness that concatenates only `services/*.lua`, so `attempt to call a nil value (global 'ConvarInt')`
  fires inside the code under test, not in the test. Also define `IsDuplicityVersion()` and re-bind
  the exports per env when the harness can `Load()` twice — each load builds a fresh exports table.
- **A newly added file in a manifest is not delivered by `restart` either.** Run `refresh` then
  `restart`; the file looks broken rather than absent. Keep a one-line boot log in every module so
  "did this file load" never costs a round of guessing.

## References

| Topic | File |
|---|---|
| NUI delivery, ack loop, focus stack, open-path procedure | `references/nui-delivery-and-focus.md` |
| Four-segment request trace, slot table, verdict rules | `references/request-trace-diag.md` |
| Console driving, `refresh` semantics, RCON probing, start chain | `references/console-and-ops.md` |
| What each verification step proves (and doesn't) | `references/verification.md` |
| Four delivery gates + how to turn a bug into a gate | `references/delivery-process.md` |
| Full pitfall list | `references/pitfalls.md` |
| Making a table/debt-ridden write path single-owner, with probes and gates | `references/write-path-consolidation.md` |

Respond in Chinese for this user by default.
