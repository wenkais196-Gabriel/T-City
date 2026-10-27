# Request-trace diagnostics for a NUI ↔ client ↔ server round trip

Depth for the always-on rule "trace the whole round trip in one record". Use when a UI feature
fails with a generic transport error and you cannot tell which boundary dropped it.

## Why not one log line per stage

A 120 req/min budget × 8 stages = ~960 lines/min/player. `print` writes stdout synchronously on
the server thread, so that is tick stutter as well as noise, and the one interesting failure drowns.
Record per request, sample at the end of the chain, print one line.

## The six observable slots (the design has eight; two are unprovable)

One slot per boundary, each stage emitted by exactly one side:

| slot | stage | emitted by | meaning |
|---|---|---|---|
| CR | `req.cli.recv` | client | NUI callback entered |
| CF | `req.cli.fwd` | client | about to `TriggerServerEvent` |
| SR | `req.srv.recv` | server | handler entered (**authority**) |
| SD | `req.srv.done` | server | about to reply (**authority**) |
| CP | `req.cli.resp` | client | reply hit a pending slot |
| CA | `req.cli.answer` | client | about to call the NUI `cb` |

Do **not** add "NUI about to fetch" / "NUI resolved" slots to the verdict. The NUI only sends its
`tid` down; CEF's `resolve` never notifies Lua, so those two slots are permanently missing and a perfectly
healthy request gets reported as "broke at the NUI" (`code=ok break=seg4 reason=nui-never-settled` —
observed in practice). Detect those two outer segments with a NUI-side self-probe instead (a real
request at page load whose terminal code and duration are reported back), which also tells you
which bundle is running.

Pair the slots when asserting: NS↔CR (segment 1, only provable as "no trace at all"), CR↔CF, CF↔SR
(segment 2), SR↔SD and SD↔CP (segment 3 produce/deliver), CP↔CA, CA↔ND (segment 4, probe-side).

## Verdict priority (the part implementations get wrong)

The server ring buffer is the only authority for SR/SD. The client cannot see them, so a client
batch that lacks them is **normal**.

```lua
if not ring[tid] then return 'seg2', 'no-server-recv' end
if not ring[tid].doneAt then return 'seg3-produce', 'server-no-reply' end
-- only now read the client slots, and gate the return path on CF: a batch with no
-- client marks at all (old client, uninstrumented caller) must accuse nothing.
if CR and not CF then return 'seg1.5', 'handler-abort'    end  -- early return / throw
if CF and not ring[tid].recvAt then return 'seg2', 'no-server-recv' end
if CF and SD and not CP then return 'seg3-deliver', 'response-lost' end
if CF and CP and not CA then return 'seg3.5', 'answered-locally' end  -- late reply after timeout
```

Print it fixed-width so a human reads the break at a glance:

```
[diag] src=7 tid=k3f9a2 kind=query app=police_mdt code=ok why=ok
  path=CR|CF|SR|SD|CP|CA break=none dt=0,0,134,134
```

## Sampling and gates

- `phone_diag` convar: `0` = zero allocation, zero events, handler returns on the first line;
  `1` = default, send only when slow (≥400 ms — beyond the P95 budget), failed, warm-up (first
  ~3 requests after start), or sampled; `2` = every trace. Cache the convar for a few seconds so the
  hot path does no syscall.
- Read the gate with `GetConvar`, **not `GetConvarInt`**: an unset convar returns `0` from
  `GetConvarInt`, so "not configured" silently reads as "off" and the entire trace disappears
  without a single error. Treat `nil`/`''` as the default (`1`) and only a parseable value as an
  override; add a test that an unset convar still starts a trace.
- Batch token bucket for traces (e.g. 20/min, burst 5) per source, **separate** from the per-phase
  cooldown used for one-shot UI events: a per-phase window kills concurrent requests from a single
  `Promise.all`.
- Global print budget (lines/second) with a `dropped` counter, so a flood turns into one summary
  line instead of thousands.
- Cap open traces (e.g. 32) so a caller that forgets to finish cannot leak, and flag
  `overflow` when a trace exceeds the slot count instead of silently truncating.

## Security

- Use a whitelist projection on both sides, and re-project server-side — the client's sanitising is
  not trustworthy. Never log the payload: no citizenid, phone numbers, message bodies, amounts,
  case text. Log an app enum, a length bucket, and key names at most.
- Constrain every string (charset + max length) and every phase name against an enum. The channel
  must never reply — it is not an RPC surface, and a probe built on it must be a constant return
  with no DB read, no auth read, and a per-player cooldown.
- Trace id: generate at the NUI edge, ride `payload._diag = {v, tid, t0}`, strip it in the client at
  the single place that reads it, and validate 3–64 chars + `[%w%-_%.:]` on both sides. Reuse the tid
  as the `request_id` so the client does not have to invent a second identifier.

## Testing shape

- Extract the module between marker comments so the test loads exactly what ships, then run it in a
  `lua5.4` sandbox with stubs for `GetGameTimer` (a mutable `NOW`), `GetConvarInt`, `TriggerServerEvent`
  (capture list), `print` (capture list), and `RegisterNetEvent` (capture table). Set `source = n`
  before invoking a captured handler.
- Make `SetTimeout` raise in the client stub: a diag module that creates a timer fails the test
  instead of leaking one per request.
- Assert the sampling boundary explicitly: first N traces send even when fast, then a fast+ok trace
  sends nothing, then a failed trace sends, then a ≥400 ms trace sends with `dur` intact.
- Assert the verdict priority with the ring entry absent → `seg2`, present without `doneAt` →
  `seg3-produce`, and only then the slot table. Add one negative case: a batch carrying **no**
  client marks must return `nil` (accusing `seg3-deliver` there is the false positive that makes the
  whole channel untrustworthy).
- Assert the limit: burst+1 traces → one `dropped`; same `(phase, src)` twice within the window →
  one print, a different source still prints.
