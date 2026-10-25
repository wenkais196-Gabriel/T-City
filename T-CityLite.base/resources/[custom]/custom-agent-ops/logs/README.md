# custom-agent-ops runtime logs

`server/main.lua` appends critical events to `agent-events.jsonl` here.

The directory is tracked so a fresh checkout already has a writable target; the
`*.jsonl` files are ignored by the repository-level `**/logs/` rule and must
never be committed (they can contain operational event data). If the resource
directory is read-only, the logger falls back to
`<server-root>/logs/custom-agent-ops-events.jsonl`, then to
`SaveResourceFile`.
