-- v3.9_police_write_intents.sql — idempotency ledger for police write paths.
--
-- `ArrestSubmit` and `ReportSubmit` are multi-table writes (report + optional
-- case/citation/evidence) on an oxmysql build that has no transaction export,
-- so a network retry or a double tap can create a second report/citation. The
-- client now sends an `idempotency_key`; this table is the claim ledger:
--
--   pending → the write is in flight (`in_progress` for a duplicate caller)
--   done    → the write committed; `result_json` replays the original result
--   failed  → reserved for sweeps; the submit currently deletes the row on a
--             business failure so a corrected retry may reuse the key
--
-- Idempotent: the table and both indexes are guarded through information_schema,
-- so the migration can be re-run safely.

SET @has_table := (
    SELECT COUNT(*) FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_write_intents'
);
SET @sql_table := IF(@has_table = 0,
    'CREATE TABLE IF NOT EXISTS police_write_intents (
        idem_key VARCHAR(128) NOT NULL,
        action VARCHAR(32) NOT NULL,
        actor_citizenid VARCHAR(50) NOT NULL,
        status ENUM(''pending'',''done'',''failed'') NOT NULL DEFAULT ''pending'',
        result_json TEXT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (idem_key),
        KEY idx_actor_created (actor_citizenid, created_at),
        KEY idx_created (created_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci',
    'SELECT 1');
PREPARE stmt_table FROM @sql_table; EXECUTE stmt_table; DEALLOCATE PREPARE stmt_table;

-- Older/partial installs may already have the table but not its indexes.
SET @has_idx_actor := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_write_intents'
      AND INDEX_NAME = 'idx_actor_created'
);
SET @sql_idx_actor := IF(@has_idx_actor = 0,
    'ALTER TABLE police_write_intents ADD KEY idx_actor_created (actor_citizenid, created_at)',
    'SELECT 1');
PREPARE stmt_idx_actor FROM @sql_idx_actor;
EXECUTE stmt_idx_actor;
DEALLOCATE PREPARE stmt_idx_actor;

SET @has_idx_created := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_write_intents'
      AND INDEX_NAME = 'idx_created'
);
SET @sql_idx_created := IF(@has_idx_created = 0,
    'ALTER TABLE police_write_intents ADD KEY idx_created (created_at)',
    'SELECT 1');
PREPARE stmt_idx_created FROM @sql_idx_created;
EXECUTE stmt_idx_created;
DEALLOCATE PREPARE stmt_idx_created;
