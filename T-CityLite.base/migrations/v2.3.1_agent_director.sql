-- ============================================================================
-- Migration: v2.3.1_agent_director.sql
-- Issue:     #31 — rule-based director bridge (observe -> propose)
-- Depends:   v2.2_agent_read_layer.sql (agent_events)
--            v2.3_agent_actions.sql (agent_actions)
-- Target:    MariaDB 11.8 (TCityLite)
-- Run:       set -a; . ./.env; set +a
--            MYSQL_PWD="$TCITY_DB_PASS" mysql -h "$TCITY_DB_HOST" \
--              -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
--              < T-CityLite.base/migrations/v2.3.1_agent_director.sql
--
-- Idempotency:
--   * CREATE TABLE IF NOT EXISTS, so re-running the migration is safe.
--   * INSERT IGNORE seeds the single 'agent_events' cursor row once.
--
-- Security:
--   * No credentials, tokens or player PII are stored here.
--   * This table is written only by custom-director (server-side).
--   * There is deliberately no FK to agent_events: the cursor must survive
--     event pruning and is a plain monotonic watermark, not a row reference.
-- ============================================================================

SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS `agent_director_state` (
    `name`          VARCHAR(64) NOT NULL COMMENT 'Event stream name; currently always agent_events',
    `cursor`        BIGINT      NOT NULL DEFAULT 0 COMMENT 'Highest agent_events.id fully handled',
    `updated_at`    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                                ON UPDATE CURRENT_TIMESTAMP(3),
    `last_event_at` DATETIME(3) NULL COMMENT 'created_at of the last event consumed',
    PRIMARY KEY (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Rule-based director cursor state. One row per event stream.';

-- Seed the only stream this bridge consumes. A fresh install starts at 0, so
-- pre-existing agent_events are intentionally replayed on first enable.
INSERT IGNORE INTO `agent_director_state` (`name`, `cursor`)
VALUES ('agent_events', 0);

-- ============================================================================
-- Verification (run manually after applying):
--   SHOW CREATE TABLE agent_director_state\G
--   SELECT `name`, `cursor`, `updated_at`, `last_event_at`
--     FROM agent_director_state WHERE name = 'agent_events';
-- ============================================================================
