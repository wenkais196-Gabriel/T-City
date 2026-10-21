-- ============================================================================
-- Migration: v2.3_agent_actions.sql
-- Issues:    #30 / #32 — server-side agent action broker (custom-director)
-- Target:    MariaDB 11.8 (TCityLite)
-- Run:       set -a; . ./.env; set +a
--            MYSQL_PWD="$TCITY_DB_PASS" mysql -h "$TCITY_DB_HOST" \
--              -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
--              < T-CityLite.base/migrations/v2.3_agent_actions.sql
--
-- Idempotency:
--   * CREATE TABLE IF NOT EXISTS, so re-running the migration is safe.
--
-- Security:
--   * No credentials or tokens are stored in this file or in the table.
--   * params / preview / result are JSON written by custom-director only.
--   * idempotency_key is globally UNIQUE: one row per proposed action.
-- ============================================================================

SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS `agent_actions` (
    `id`              BIGINT       NOT NULL AUTO_INCREMENT,
    `agent_id`        VARCHAR(64)  NOT NULL COMMENT 'Caller identity from X-Agent-Id / export argument',
    `action_type`     VARCHAR(32)  NOT NULL COMMENT 'notify | add_money | start_quest',
    `params`          LONGTEXT     NOT NULL COMMENT 'Normalized JSON action arguments',
    `status`          ENUM('proposed','pending_approval','approved','executed','rejected','failed')
                                   NOT NULL DEFAULT 'proposed',
    `idempotency_key` VARCHAR(128) NOT NULL COMMENT 'Caller-supplied key; globally unique',
    `preview`         LONGTEXT     NULL COMMENT 'JSON preview computed before execution',
    `result`          LONGTEXT     NULL COMMENT 'JSON execution result or rejection reason',
    `error`           VARCHAR(255) NULL COMMENT 'Short machine-facing failure/rejection reason',
    `requested_at`    DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `approved_by`     VARCHAR(64)  NULL COMMENT 'Approver label, or auto for L1 actions',
    `approved_at`     DATETIME(3)  NULL,
    `executed_at`     DATETIME(3)  NULL,
    `expires_at`      DATETIME     NULL COMMENT 'Approval deadline (NULL = no deadline)',
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_idem` (`idempotency_key`),
    KEY `idx_status_requested` (`status`, `requested_at`),
    KEY `idx_agent_requested` (`agent_id`, `requested_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Agent action proposals, approvals and audit trail.';

-- ============================================================================
-- Verification (run manually after applying):
--   SHOW CREATE TABLE agent_actions\G
--   SELECT COUNT(*) FROM agent_actions;
--   SHOW INDEX FROM agent_actions;
-- ============================================================================
