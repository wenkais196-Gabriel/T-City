-- config.lua — custom-agent-ops runtime knobs.
--
-- Defaults are dev friendly: the ring is always on (it costs no I/O), the file
-- log is on so an agent can inspect what happened after a resource restart, and
-- both pollers run at a low frequency. Set `file_log = false` for a read-only
-- deployment, or raise the intervals on a busy server.
--
-- This resource is read-only over the police/justice tables. Nothing in this
-- file can turn it into a writer.

AgentOpsConfig = {
    -- police_audit poll (id > cursor, LIMIT audit_batch). 500..60000 ms.
    poll_audit_ms = 2000,
    -- police_units / incidents / sentences / outbox counters. 1000..60000 ms.
    poll_snapshot_ms = 5000,
    -- Never larger than the ring: a poll may not flood the buffer in one tick.
    audit_batch = 100,

    -- Append critical events to logs/agent-events.jsonl inside the resource.
    -- Falls back to <server>/logs/custom-agent-ops-events.jsonl, then to
    -- SaveResourceFile when the checkout is read-only.
    file_log = true,
    file_log_path = 'logs/agent-events.jsonl',
    file_log_max_bytes = 2 * 1024 * 1024,
    file_log_keep = 1,

    -- Outbox health thresholds.
    outbox_pending_warn = 20,
    outbox_stale_minutes = 10,

    -- Field truncation (UTF-8 characters, not bytes) and sanitisation limits.
    event_text_limit = 160,
    event_target_limit = 64,
    event_max_keys = 20,
    event_max_depth = 3,

    -- PushAgentEvent rate limit per second (0 disables the limit).
    external_push_per_second = 20,
}
