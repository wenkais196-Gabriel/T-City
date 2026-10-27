# NUI delivery, ack protocol and focus — depth notes

## The failure this encodes

`SendNUIMessage` into a CEF page that is still loading returns nothing and logs nothing. After
`restart <resource>` the client Lua is fresh while the frame is not, so the open message lands in
the void: `isOpen = true`, no UI, and every later keypress short-circuits on the guard. Retrying
until the page answers is the only reliable signal.

## Ack waiter (client Lua)

```lua
local ackWaiters = {} -- [channel] = entry

function Bridge.AwaitAck(channel, resend, opts)
    if type(channel) ~= 'string' or channel == '' or type(resend) ~= 'function' then return nil end
    opts = opts or {}
    local interval = tonumber(opts.intervalMs) or 250
    if interval <= 0 then interval = 250 end
    local deadline = tonumber(opts.timeoutMs) or 2500

    local entry = { channel = channel }
    ackWaiters[channel] = entry          -- supersedes a previous attempt
    resend()
    local elapsed = 0
    local function tick()
        if ackWaiters[channel] ~= entry then return end  -- acked / replaced / expired
        elapsed = elapsed + interval
        if elapsed >= deadline then
            ackWaiters[channel] = nil
            if opts.onTimeout then pcall(opts.onTimeout) end
            return
        end
        resend()
        SetTimeout(interval, tick)
    end
    SetTimeout(interval, tick)
    return entry
end

function Bridge.Ack(channel)
    if type(channel) ~= 'string' or not ackWaiters[channel] then return false end
    ackWaiters[channel] = nil
    return true   -- false means late/forged ack: nothing was waiting
end
```

Wiring: `RegisterNUICallback('<name>Ack', function(_, cb) if Bridge.Ack('<channel>') then
<emit diag stage> end cb({ ok = true }) end)`. The close branch calls `Bridge.Ack` before
releasing focus so a close during a resend loop stops it.

## Focus owner stack

- `Acquire(owner, keepInput)`, `Release(owner)`, `Reassert(owner)`; keep an ordered owner list so
  a re-acquire moves to top without duplicates.
- Release must drop NUI focus even when a delegated close helper is missing or throws — wrap the
  call, do not depend on it succeeding.
- `onResourceStop` releases every owner and resets engine flags; a stop with focus held leaves
  the player unable to move.
- Restoring `keepInput` per owner (not globally) is what stops the next UI from inheriting the
  previous one's input mode.

## Diagnostic phases worth emitting

| phase | emitted by | answers |
|---|---|---|
| `open-nui-sent` | client, after first send | did the client reach the open path at all |
| `open-start` (focus applied) | client | did the focus native run |
| `open-ack` | client, on ack callback | did CEF actually answer |
| `open-ack-timeout` | client, timeout branch | UI never materialised |
| `<app>Query-hit` | client NUI callback | did the page call the app layer |

Server side: whitelist the phase strings, rate-limit with the phase in the key
(`diagRateLimited('focus:' .. phase, src, 5)`), log `src`, phase, attempt and current focus
state. A per-source key makes the second and third stage of one open disappear.

## Reading the stages of one open

The stage order for a healthy open: `open-nui-sent` → `open-start` (focus applied) → `open-ack`
(CEF answered) → `reassert attempt=1..5` (watchdog) → on close `close-start` → `loop-exit` →
`close`. What each deviation means:

| observed | conclusion | next move |
|---|---|---|
| no `open-nui-sent` | the open path never ran (key bind, guard, or resource not started) | check the key handler and `isOpen` guard |
| stages stop after `open-nui-sent` | no ack, no timeout line | resend loop or ack callback not wired |
| `open-ack-timeout` | CEF never answered: page not loaded / bundle stale | rebuild the bundle, check the NUI `fetchNui('<name>Ack')` |
| `open-ack` present but `focused=false` | page exists and rendered; focus natives did not stick | run the probe below — do not "fix" delivery |
| `focused=true`, `keepInput` wrong | cursor or movement mode is wrong | focus stack's `keepInput` bookkeeping |

Ack + `focused=false` + `keepInput=false` after `Acquire(keepInput = true)` means neither native
reported success in that frame. Before rewriting the open path, confirm with the probe whether
`IsNuiFocused()` / `IsNuiFocusKeepingInput()` ever flip on that client at all.

## Focus probe (client command, opens no UI)

```lua
RegisterCommand('focusprobe', function()
    SetNuiFocus(false, false)
    Wait(100)
    SetNuiFocus(true, true)
    emitDiag('probe-start', IsNuiFocused(), IsNuiFocusKeepingInput())
    CreateThread(function()
        for i = 1, 20 do
            Wait(100)
            emitDiag('probe', IsNuiFocused(), IsNuiFocusKeepingInput())
        end
        PhoneFocus.Reset()          -- always: never leave the player without input
        emitDiag('probe-end', IsNuiFocused())
    end)
end, false)
```

- 20 samples over 2 s show whether focus holds, flips once, or never applies.
- Reset in the `CreateThread` epilogue, not after the loop's `return`: a probe that exits early
  still owns engine focus.
- Read the samples from the server console (`diag` phases are whitelisted + phase-rate-limited);
  ask the player to run it in F8 while the console is being read.

## Transport failure triage: the POST never reached Lua

A page that renders and answers the open ack can still fail every data request. The four legs are
NUI → client Lua → server → client Lua → NUI; each one has a different signature.

| evidence | leg that broke | first move |
|---|---|---|
| no `<query>-hit` diag at all, fast failure | NUI → Lua: callback missing / stale bundle / wrong resource name (404, empty body) | rebuild bundle, check the callback is registered at load, read the reported HTTP status |
| `<query>-hit` present, no reply, UI says timed out | Lua → server or return leg | server handler/whitelist, response event name |
| `<query>-hit` absent, failure after the full timeout | callback ran but never answered | the handler's `cb` path / `request_id` slot |
| server log shows the request arrived **and** a reply was sent, page still times out, other callbacks in the resource are fine | answer channel dropped by a `type(cb)` guard | see "Answer channel" below |
| server reply sent, UI shows a generic code | return leg: response event or request_id mismatch | compare the response event name on both ends |

The generic fallback (`query_failed` / `action_failed`) is produced by the transport wrapper's
`catch`, so it proves the fetch rejected — not that the server answered with that code.

### Frontend reporting sketch (raw fetch, cooldown, whitelisted server print)

```ts
const recent = new Map<string, number>();
function reportNuiFailure(event: string, detail: Record<string, unknown>) {
  if (isBrowser()) return;                       // browser preview has nowhere to report
  const key = `${event}:${String(detail.reason ?? '')}`;
  const now = Date.now();
  if (now - (recent.get(key) ?? 0) < 10000) return;
  recent.set(key, now);
  void fetch(`https://${window.GetParentResourceName()}/clientError`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify({ source: 'nui', event, ...detail }),
  }).catch(() => {});
}

const text = await resp.text();
let parsed: unknown; let failed = false;
try { parsed = JSON.parse(text); } catch { failed = true; }
if (!failed && parsed && typeof parsed === 'object') return parsed as T;   // structured error wins
reportNuiFailure(event, { reason: 'http_status', status: resp.status, body: text.slice(0, 200) });
throw new Error(`NUI ${event} replied HTTP ${resp.status}`);
```

Server side, print whitelisted fields only, each truncated (`event` 48, `message` 300, `stack` 500,
`status` numeric) and keep the existing per-source cooldown: a client must not be able to flood or
forge the log, and citizenid/payload contents must never be written.

## Test harness shape (Lua, no FiveM)

- Stub `SetTimeout`, `RegisterNUICallback`, `SendNUIMessage`, `SetNuiFocus`,
  `SetNuiFocusKeepInput`, `IsNuiFocused`, `TriggerServerEvent`, `RegisterNetEvent` into tables;
  run pending timers manually (`runTimers()`), then assert counts and order.
- Cases worth writing: resend count within the deadline; ack stops the loop; timeout fires once;
  supersede (second `AwaitAck` for the same channel leaves exactly one loop); late ack after
  timeout returns `false`; a handler calling `cb` twice still answers CEF once; a throwing handler
  still answers with a structured error.
- Keep the wiring assertions (`"RegisterNUICallback('X'" in main`) in the same file — cheap
  protection against a refactor dropping half of the pair.

## Answer channel: `cb` is not always a `function`

The most misleading member of the family: the page times out, the server log shows the request
arrived **and** the reply was sent, and other callbacks in the same resource work. FXServer can
hand `RegisterNUICallback`'s second argument over as a CFX function reference — a **table** with
`__call` (and/or `__cfx_functionReference`), never a `function`.

```lua
local function answerFn(cb)
    local kind = type(cb)
    if kind == 'function' then return cb end
    if kind == 'table' then
        local mt = getmetatable(cb)
        if mt and type(rawget(mt, '__call')) == 'function' then
            return function(response) return cb(response) end
        end
        local ref = rawget(cb, '__cfx_functionReference')
        if type(ref) == 'string' and ref ~= ''
            and Citizen and Citizen.InvokeFunctionReference then
            return function(response) Citizen.InvokeFunctionReference(ref, response) end
        end
    end
    return nil
end
```

- Never write `if type(cb) ~= 'function' then return end`. It compiles, it runs, and it drops
  **every** answer: the fetch stays pending until its abort (`AbortError: The user aborted a
  request`, `status=-`, not a 404), the page reports `query_failed`/`action_failed`, and the server
  believes the request was answered.
- Normalise inside the shared `RegisterNui` helper so every callback registered through it inherits
  the fix, and hand only the normalised function to the handler.
- No channel ⇒ **do not run the handler**; log `unanswerable callback (<type>)`. A half-run handler
  with side effects is worse than a deterministic timeout on the client.
- Inspect the shape from inside the wrapper through the diagnostic channel (`type(cb)` plus
  `type(getmetatable(cb).__call)`); a client `print` only reaches F8, which the agent cannot read.

## Timeout layering

Three deadlines touch one request. Keep *client Lua fallback < NUI abort*, or the structured code
you wrote is unreachable and every slow call looks like a transport failure.

| layer | typical | on expiry |
|---|---|---|
| client Lua fallback (`SetTimeout` in the callback) | 4 s | answers `{ success = false, error = 'timeout' }` |
| NUI abort (`AbortController` in `fetchNui`) | 6 s (9 s for `request_id` calls) | `AbortError` → transport fallback code |
| server `request_id` deadline | 8 s | answers `timeout` through the response event |

Pin the ordering in a test (read the frontend constant, assert the client fallback is smaller),
not just the numbers.

## Self-verifying page load

Make the page prove itself on load instead of asking the player to reproduce:

1. `fetchNui('nuiReady', { build, host, href, parent })` — `build` is injected at bundle time and
   proves which JS is running (the stale-bundle question); `host` must be `cfx-nui-<resource>` and
   `parent` the resource name.
2. One **real** request through the normal transport, timed, reported to a second callback as
   `{ code, dur, build }`.

After that, `restart <resource>` answers what used to need a person: `code=ok` at ~200 ms = whole
chain healthy; `code=query_failed` with `dur≈9000` = the answer never came back; `nuiReady` without
a probe = the request never reached Lua at all. Gate both on the CEF host, and treat `href`/`build`
as attacker-controlled strings server-side (per-source cooldown, charset + length caps).

## 「打开 UI」路径的标准实现

1. Client open handler: set state, then `AwaitAck(channel, resendFn, { intervalMs = 250,
   timeoutMs = 2500, onTimeout })` — the resend closure is the single place that emits the open
   message.
2. NUI on the open message: render first, then immediately answer the ack callback
   (`void fetchNui('phoneOpenAck').catch(() => {})`) — the answer is the only proof the frame
   exists.
3. Client: `RegisterNUICallback('phoneOpenAck', …)` consumes the waiter and emits the ack
   diagnostic stage.
4. Timeout branch: `isOpen = false`, release focus, chat/notification hint to the player.
5. Close branch: ack the channel (stops the loop) → release focus → tell the NUI to close.
6. Tests, both halves in one file: the waiter (resend count, supersede, timeout, late ack not
   consumed) in a Lua stub harness **and** the wiring (callback registered, NUI answers it) as
   string assertions, so a refactor cannot silently drop one half.

Depth (Lua/TS sketches, diag phase table, harness shape):
本文件（references 下的 nui-delivery-and-focus）.
