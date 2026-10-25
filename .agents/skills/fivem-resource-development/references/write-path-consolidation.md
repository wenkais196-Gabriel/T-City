# Write-path consolidation (one owner per table)

For "this table is written from N places, make it one". Name-level dedupe is tidiness; this is
correctness, because every extra writer re-learns the same bugs.

## 0. Inventory with comments stripped

```bash
grep -rn "INSERT INTO <table>\|UPDATE <table>\|DELETE FROM <table>" resources/ --include=*.lua \
  | grep -v node_modules
```

Then in Python, strip `--…` before matching (a doc comment naming the table must not count), and
report `table -> {files}`. Anything with more than one file is a candidate; also list the **column
set per call site**, because differing column sets are what makes the merge look risky later
(three-column jail insert vs five-column arrest insert on the same table).

## 1. Prove which copies are already broken (before touching anything)

Write a temporary startup probe that executes the **existing shapes verbatim** against the real DB
and prints, for each: `ok` (pcall), `type(result)` and `result` truncated. `pcall` returning true
with a *string* result means the write failed silently — the usual cause is one nil hole in the
parameter array (`{ nil, a, b }` or `{ a, nil, c }`): oxmysql truncates the array, MariaDB answers
`syntax error near '?)'`, `InsertId()` hands back that string, and the caller returns `db_error`.
Include a control shape with `NULL` in the SQL text so the probe also proves the fix.

Do this first. Twice in one module the "refactor" turned out to be a rescue: audit rows and the
whole evidence-registration path were dead on every call, and only the real DB showed it.

## 2. Pick the owner and give it an API, not a copy

The owner is the file already on the critical path (or the one with the fullest column set). Expose
narrow verbs — `InsertCase`, `InsertArrest`, `InsertReport`, `LinkReport`, `RecordVerdict` — each
validating its own inputs and returning `result, reason` (never a bare `false`). Return the
**derived** values the caller would otherwise recompute (settled amount, case number, `chain_ok`).
When a caller must control auditing, take `opts.audit = false` and document why.

## 3. Build columns conditionally

```lua
local function insertInto(head, fields)   -- head is a LITERAL: 'INSERT INTO police_arrests'
    local columns, placeholders, values = {}, {}, {}
    for _, pair in ipairs(fields) do
        if pair[2] ~= nil then
            columns[#columns + 1] = pair[1]
            placeholders[#placeholders + 1] = '?'
            values[#values + 1] = pair[2]
        end
    end
    ...
end
```

Absent optional columns must not appear at all (or be written as `NULL` in the SQL text) — never as
a nil in the array. Keep the table name literal at each call site so literal-scanning gates can see
the writer.

## 4. Delegate at every other call site, keeping local behaviour

Notifications, rollback paths, policy checks and audit actions stay where they were; only the row
write moves. Two things bite here:

- A caller that pre-audits must pass `opts.audit = false` (in the owner) or every row gets two audit
  entries; a caller that inherits the owner's audit result must surface it (`audit_unavailable`).
- Rollback semantics must survive: if the old code treated a child-write failure as fatal, the owner
  has to hand back enough to keep that (`result.chain_ok`).

## 5. Tighten the gate, then prove it can fail

Table-name → owner map; former exceptions move into the owner map (the exception list should trend
to **empty**). Keep two directions: an unlisted writer fails, and an exception whose trace vanished
fails too. Add one injection case (create a second writer file → suite red → delete → green).

## 6. Unit-test the owner in Lua with a recording stub

Stub `MySQL.insert/update` to record `{sql, values}` and assert: the exact column set per case, that
no value in `values` is nil, the derived id/number format, and that a string result is treated as
failure. Keep INSERT and UPDATE records in **separate** lists — mixing them makes `__sql[2]` point at
the follow-up `UPDATE … SET exhibit_no` and the assertions report nonsense.

## 7. Verify end-to-end, then clean up

Startup probe through the new entry points: one row per table, `NULL` where optional, read back with
the mysql client, then `DELETE` the probe rows by their marker citizenid. Delete the probe file and
its manifest line — a leftover `_probe_*.lua` fails the single-writer gate on the next run.

## 8. Expect the contract tests to go red, and fix them honestly

Tests that grepped the caller for `INSERT INTO <table>`, for the audit SQL, or for an ordering
anchor now pin a shape that no longer exists. Rewrite each so the **promise** is still checked, but
at the owner: `PoliceRecords.InsertReport(` in the caller, the column list / audit call / ordering
in the owner file. Deleting the assertion is widening the gate; moving it is not.

Registries that counted writes (deprecation budgets, owner allowlists) must be updated in the same
commit — a drop from 2 to 1 is the ratchet working, not a stale entry.

## Amount/quantity policies live in the owner too

If two call sites derive a money amount differently, move the formula into the owner and have
callers pass only the raw inputs. Compute band edges with integer percentages
(`math.ceil(base * 80 / 100)`, `math.floor(base * 120 / 100)`); in double precision
`base * 0.8` and `base * 1.2` are off by an ULP, so `500` yields edges `401`/`599` instead of
`400`/`600` — an off-by-one nobody notices until a unit test enumerates several bases.
