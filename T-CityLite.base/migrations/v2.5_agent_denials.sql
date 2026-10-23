-- ============================================================================
-- Migration: v2.5_agent_denials.sql
-- Issue:     #30/#32 follow-up — audit policy rejections of agent actions
-- Depends:   v2.3_agent_actions.sql (agent_actions)
-- Target:    MariaDB 11.8 (TCityLite)
-- Run:       set -a; . ./.env; set +a
--            MYSQL_PWD="$TCITY_DB_PASS" mysql -h "$TCITY_DB_HOST" \
--              -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
--              < T-CityLite.base/migrations/v2.5_agent_denials.sql
--
-- Idempotency:
--   * CREATE TABLE IF NOT EXISTS, so re-running the migration is safe.
--
-- Security:
--   * Policy-rejected proposals are still NOT written to agent_actions (their
--     idempotency key must stay reusable), so this table is the only record of
--     an over-privileged request.
--   * Parameter VALUES are never stored as a params blob: only the sorted
--     parameter NAMES plus a 64-bit hash of the normalized JSON. The policy's
--     own message is kept (it explains the denial) and must stay short.
--   * No credentials or tokens are stored here; custom-director is the only
--     writer.
-- ============================================================================

SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS `agent_denials` (
    `id`          BIGINT       NOT NULL AUTO_INCREMENT,
    `agent_id`    VARCHAR(64)  NOT NULL COMMENT 'Caller identity from X-Agent-Id / export argument',
    `action_type` VARCHAR(32)  NOT NULL COMMENT 'Action that was denied',
    `code`        VARCHAR(64)  NOT NULL COMMENT 'Policy error code, e.g. daily_budget_exceeded',
    `message`     VARCHAR(255) NULL COMMENT 'Short human-facing rejection reason',
    `param_keys`  VARCHAR(255) NULL COMMENT 'Sorted, comma-separated parameter NAMES only',
    `params_hash` CHAR(16)     NULL COMMENT 'djb2 (64 bit) hex digest of the normalized params JSON',
    `dry_run`     TINYINT(1)   NOT NULL DEFAULT 0 COMMENT '1 when the denied proposal was a dry run',
    `created_at`  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`id`),
    KEY `idx_agent_created` (`agent_id`, `created_at`),
    KEY `idx_code_created` (`code`, `created_at`),
    KEY `idx_action_created` (`action_type`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Policy denials of agent action proposals (no parameter values).';

-- ============================================================================
-- Verification (run manually after applying):
--   SHOW CREATE TABLE agent_denials\G
--   SELECT code, COUNT(*) FROM agent_denials GROUP BY code ORDER BY 2 DESC;
--   SELECT * FROM agent_denials ORDER BY id DESC LIMIT 10;
-- ============================================================================
