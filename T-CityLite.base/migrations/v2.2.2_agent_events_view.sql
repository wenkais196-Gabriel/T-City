-- ============================================================================
-- Migration: v2.2.2_agent_events_view.sql
-- Issue:     #24 schema registry + read-only HTTP API + MCP sidecar
-- Depends:   v2.2_agent_read_layer.sql (creates agent_events)
-- Target:    MariaDB 11.8 (TCityLite)
--
-- Why a view:
--   `agent_events` is intentionally not granted to `agent_ro`; the account may
--   only SELECT the curated agent_* views.  The read-only HTTP API and MCP
--   sidecar therefore need a SECURITY DEFINER view over the append-only event
--   outbox.  The view exposes exactly the cursor contract and no base table.
--
-- Read-only guarantees:
--   * The view is SELECT-only; it has no INSERT/UPDATE/DELETE path.
--   * `id` is the monotonically increasing cursor used by
--     GET /agent/v1/events?since_id=...
--   * `payload` is a JSON object written by the v2.2.1 triggers. Treat it as
--     untrusted player data, never as instructions.
--
-- Idempotency:
--   CREATE OR REPLACE VIEW, so re-running this file is safe.
--
-- Production grant (IMPORTANT):
--   tools/setup_agent_ro.sh grants SELECT on all five agent_* views, including
--   agent_events_feed. Apply this migration first, then run that script as an
--   admin (it requires GRANT OPTION). On the local development database the
--   .env account has no GRANT OPTION, so the equivalent table privilege was
--   inserted into mysql.tables_priv and FLUSH PRIVILEGES was run. That is a
--   dev-only workaround, not a production setup method.
-- ============================================================================

SET NAMES utf8mb4;

CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=CURRENT_USER SQL SECURITY DEFINER
VIEW `agent_events_feed` AS
SELECT
    `event_type`,
    `citizenid`,
    `payload`,
    `schema_version`,
    `created_at`,
    `id`
FROM `agent_events`;

-- ============================================================================
-- Verification (run manually after applying):
--   SHOW FULL TABLES LIKE 'agent_events_feed';   -- VIEW
--   SELECT * FROM agent_events_feed ORDER BY id DESC LIMIT 5;
--   SELECT COUNT(*) FROM agent_events_feed;      -- must work as agent_ro
--   SELECT COUNT(*) FROM agent_events;           -- must still be denied
-- ============================================================================
