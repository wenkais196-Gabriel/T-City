-- v3.8_justice_sentences.sql — server-authoritative custody sentences.
--
-- Before this migration the remaining jail time only lived in the qb-prison
-- client (`jailTime`) and in `players.metadata.injail`. `justice_sentences` is
-- the durable source of truth: `ends_at` is computed by the database clock, so
-- offline time is served and a client can no longer clear the sentence.
--
-- Idempotent: both the table and its indexes are guarded through
-- information_schema, so the migration can be re-run safely.

SET @has_table := (
    SELECT COUNT(*) FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'justice_sentences'
);
SET @sql_table := IF(@has_table = 0,
    'CREATE TABLE IF NOT EXISTS justice_sentences (
        id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        citizenid VARCHAR(50) NOT NULL,
        case_id VARCHAR(32) NULL,
        minutes INT UNSIGNED NOT NULL,
        reason VARCHAR(255) NULL,
        status ENUM(''active'',''released'',''expired'') NOT NULL DEFAULT ''active'',
        started_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        ends_at DATETIME NOT NULL,
        released_at DATETIME NULL,
        created_by VARCHAR(50) NULL,
        PRIMARY KEY (id),
        KEY idx_citizen_status (citizenid, status),
        KEY idx_status_ends (status, ends_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci',
    'SELECT 1');
PREPARE stmt_table FROM @sql_table; EXECUTE stmt_table; DEALLOCATE PREPARE stmt_table;

-- Older/partial installs may already have the table but not the indexes.
SET @has_idx_citizen := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'justice_sentences'
      AND INDEX_NAME = 'idx_citizen_status'
);
SET @sql_idx_citizen := IF(@has_idx_citizen = 0,
    'ALTER TABLE justice_sentences ADD KEY idx_citizen_status (citizenid, status)',
    'SELECT 1');
PREPARE stmt_idx_citizen FROM @sql_idx_citizen;
EXECUTE stmt_idx_citizen;
DEALLOCATE PREPARE stmt_idx_citizen;

SET @has_idx_status := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'justice_sentences'
      AND INDEX_NAME = 'idx_status_ends'
);
SET @sql_idx_status := IF(@has_idx_status = 0,
    'ALTER TABLE justice_sentences ADD KEY idx_status_ends (status, ends_at)',
    'SELECT 1');
PREPARE stmt_idx_status FROM @sql_idx_status;
EXECUTE stmt_idx_status;
DEALLOCATE PREPARE stmt_idx_status;
