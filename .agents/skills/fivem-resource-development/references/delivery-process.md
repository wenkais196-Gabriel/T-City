# 交付流程与闸门设计

用户要求每个代码任务过四道门，并把"能编译"视作未完成。这份文件是那四道门的判据，
以及"把 bug 变成闸门"的三条设计规则。

## 四道门

The user requires every code task to pass four gates, and treats "it compiles" as not done:

1. **调研 (research)** — read the existing code path and the official docs before editing; when the
   question is "why is the client side flaky", run the research as parallel subagents that each
   write a cited document, so the conclusion outlives the session.
2. **计划 (plan)** — a written task list with the acceptance criteria (which tests, which live
   check) before touching files.
3. **开发 (dev)** — thin slices; each slice ends with the verification commands above actually run.
4. **审查 (review)** — score the diff against the four project principles:
   **模块化** (one module owns each concern, no duplicated wire logic), **高性能** (no per-frame or
   per-request chatter, cached where it matters), **可拓展** (new app/channel = register, not edit a
   switch), **安全** (NUI input untrusted, whitelisted log fields, rate limits, unicast responses).

   **审查 also means encoding the bug as a gate.** After a root-cause fix, add the failing shape to
   `tests/architecture/` so the next occurrence is caught by CI instead of by a player. Three rules
   decide whether the gate is worth having: (a) scope the pattern to the construct that makes it
   wrong — `type(cb) ~= 'function'` is fatal inside a NUI handler but legitimate in a
   `Request(event, payload, cb, …)` completion callback, and a whole-repo grep produces the false
   positive that gets the whole rule allowlisted away; (b) skip the file that *defines* the API (a
   `Commands.Add` implementation is not a call site, and a brace-depth splitter will happily insert
   a guard into it); (c) give every rule a reverse assertion that feeds the banned shape and
   requires the scanner to go red — a rule that cannot fail is decoration, not a gate.

Report only what execution returned: test counts, live console lines, file paths. "已完成" without
those is not a delivery.
