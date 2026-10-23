-- ============================================================================
-- Migration: v2.6_agent_effects.sql
-- Issue:     effect channel audit — one terminal row per dispatched client effect
-- Depends:   none (custom-agent-client writes; no FK)
-- Target:    MariaDB 11.8 (TCityLite)
-- Run:       set -a; . ./.env; set +a
--            MYSQL_PWD="$TCITY_DB_PASS" mysql -h "$TCITY_DB_HOST" \
--              -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
--              < T-CityLite.base/migrations/v2.6_agent_effects.sql
--
-- Idempotency:
--   * CREATE TABLE IF NOT EXISTS, so re-running the migration is safe.
--
-- Security / privacy:
--   * This table deliberately stores NO payload and NO free text. Notify body
--     text, open_text_ui title/body, phone numbers and every other parameter
--     VALUE stay out of agent_effects; only routing metadata (request id,
--     agent, target source, action), the terminal status, the bounded error
--     code and the server-measured latency are kept.
--   * The writer is custom-agent-client only, and it is best-effort: a failed
--     insert never changes the result returned to the caller.
--   * `agent_effect_audit` (default 1) disables the insert at runtime.
-- ============================================================================

SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS `agent_effects` (
    `id`            BIGINT        NOT NULL AUTO_INCREMENT,
    `request_id`    VARCHAR(80)   NOT NULL COMMENT 'Effect channel request id (tcity:agent:exec)',
    `agent_id`      VARCHAR(64)   NOT NULL COMMENT 'Caller identity, unknown when not supplied',
    `target_source` INT           NOT NULL COMMENT 'Server-resolved player source, never from a payload',
    `action`        VARCHAR(32)   NOT NULL COMMENT 'Effect action, e.g. send_notify',
    `status`        ENUM('ok','rejected','failed','cancelled','timeout','player_offline','executor_stopped')
                                  NOT NULL COMMENT 'Terminal settle status',
    `error_code`    VARCHAR(64)   NULL COMMENT 'Machine code only; no message or payload text',
    `latency_ms`    INT UNSIGNED  NULL COMMENT 'GetGameTimer() dispatch-to-settle delta, clamped >= 0',
    `created_at`    DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`id`),
    KEY `idx_created` (`created_at`),
    KEY `idx_agent_created` (`agent_id`, `created_at`),
    KEY `idx_action_created` (`action`, `created_at`),
    KEY `idx_status_created` (`status`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Terminal status of client effect dispatches (no payload/text).';

-- ============================================================================
-- Verification (run manually after applying):
--   SHOW CREATE TABLE agent_effects\G
--   SELECT status, COUNT(*) FROM agent_effects GROUP BY status ORDER BY 2 DESC;
--   SELECT action, status, COUNT(*), AVG(latency_ms)
--     FROM agent_effects
--    WHERE created_at >= CURDATE() - INTERVAL 1 DAY
--    GROUP BY action, status;
--   SELECT * FROM agent_effects ORDER BY id DESC LIMIT 10;
-- ============================================================================
