-- v3.12_police_outbox.sql — TTL for the idempotency ledger + a delivery outbox.
--
-- SM-03 leftovers:
--   * a `done` police_write_intents row replayed forever was fine, but the row
--     itself never expired (only a blind `created_at < 1 DAY` sweep existed),
--     so a key could be replayed days later or a process crash could leave a
--     `pending` row that blocked retries forever;
--   * notifications left custom-police for the phone owner, so a phone restart
--     could silently drop a dispatch/fine notification. The outbox is the
--     compensating log: enqueue first, deliver from a worker, retry with
--     exponential backoff, give up after 5 attempts.
--
-- `police_outbox` is deliberately NOT a transaction: the bundled oxmysql has no
-- `transaction` export, so the compensation is "intent ledger + outbox worker"
-- (see docs/police/architecture/09-outbox.md).
--
-- Idempotent: the table, both indexes and both ALTERs are guarded through
-- information_schema, so the migration can be re-run safely.

-- ---------------------------------------------------------------------------
-- police_write_intents: done-result TTL + completion timestamp
-- ---------------------------------------------------------------------------

-- `expires_at` is set to NOW() + INTERVAL 7 DAY when a row becomes done. A done
-- row older than that is swept on the next claim instead of replaying stale
-- results forever. NULL on legacy rows; readers fall back to created_at + 7d.
SET @has_expires := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_write_intents'
      AND COLUMN_NAME = 'expires_at'
);
SET @sql_expires := IF(@has_expires = 0,
    'ALTER TABLE police_write_intents ADD COLUMN expires_at DATETIME NULL AFTER result_json',
    'SELECT 1');
PREPARE stmt_expires FROM @sql_expires;
EXECUTE stmt_expires;
DEALLOCATE PREPARE stmt_expires;

-- `completed_at` records when the row reached done (observability + the sweep
-- can also use it instead of created_at for long-running submits).
SET @has_completed := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_write_intents'
      AND COLUMN_NAME = 'completed_at'
);
SET @sql_completed := IF(@has_completed = 0,
    'ALTER TABLE police_write_intents ADD COLUMN completed_at DATETIME NULL AFTER expires_at',
    'SELECT 1');
PREPARE stmt_completed FROM @sql_completed;
EXECUTE stmt_completed;
DEALLOCATE PREPARE stmt_completed;

-- ---------------------------------------------------------------------------
-- police_outbox: pending -> done/failed delivery log
-- ---------------------------------------------------------------------------

SET @has_table := (
    SELECT COUNT(*) FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_outbox'
);
SET @sql_table := IF(@has_table = 0,
    'CREATE TABLE IF NOT EXISTS police_outbox (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        topic VARCHAR(32) NOT NULL,
        payload TEXT NOT NULL,
        status ENUM(''pending'',''done'',''failed'') NOT NULL DEFAULT ''pending'',
        attempts INT UNSIGNED NOT NULL DEFAULT 0,
        next_attempt_at DATETIME NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (id),
        KEY idx_status_next (status, next_attempt_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci',
    'SELECT 1');
PREPARE stmt_table FROM @sql_table; EXECUTE stmt_table; DEALLOCATE PREPARE stmt_table;

-- Older/partial installs may already have the table but not its worker index.
SET @has_idx_status_next := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_outbox'
      AND INDEX_NAME = 'idx_status_next'
);
SET @sql_idx_status_next := IF(@has_idx_status_next = 0,
    'ALTER TABLE police_outbox ADD KEY idx_status_next (status, next_attempt_at)',
    'SELECT 1');
PREPARE stmt_idx_status_next FROM @sql_idx_status_next;
EXECUTE stmt_idx_status_next;
DEALLOCATE PREPARE stmt_idx_status_next;
