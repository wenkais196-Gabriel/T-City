-- v3.6_police_justice_case.sql — keep the justice case id on the report.
SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'justice_case_id');
SET @sql := IF(@has = 0,
    'ALTER TABLE police_reports ADD COLUMN justice_case_id VARCHAR(32) DEFAULT NULL AFTER case_id',
    'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @idx := (SELECT COUNT(*) FROM information_schema.STATISTICS
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND INDEX_NAME = 'idx_justice_case');
SET @sql2 := IF(@idx = 0,
    'ALTER TABLE police_reports ADD KEY idx_justice_case (justice_case_id)',
    'SELECT 1');
PREPARE stmt2 FROM @sql2; EXECUTE stmt2; DEALLOCATE PREPARE stmt2;
