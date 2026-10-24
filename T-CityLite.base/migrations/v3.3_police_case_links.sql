-- v3.3_police_case_links.sql — link reports/evidence to cases. Idempotent.
SET @h1 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'case_id');
SET @s1 := IF(@h1 = 0, 'ALTER TABLE police_reports ADD COLUMN case_id BIGINT UNSIGNED DEFAULT NULL AFTER incident_id', 'SELECT 1');
PREPARE st1 FROM @s1; EXECUTE st1; DEALLOCATE PREPARE st1;

SET @h2 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_evidence' AND COLUMN_NAME = 'case_id');
SET @s2 := IF(@h2 = 0, 'ALTER TABLE police_evidence ADD COLUMN case_id BIGINT UNSIGNED DEFAULT NULL AFTER report_id', 'SELECT 1');
PREPARE st2 FROM @s2; EXECUTE st2; DEALLOCATE PREPARE st2;

SET @i1 := (SELECT COUNT(*) FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND INDEX_NAME = 'idx_case');
SET @s3 := IF(@i1 = 0, 'ALTER TABLE police_reports ADD KEY idx_case (case_id)', 'SELECT 1');
PREPARE st3 FROM @s3; EXECUTE st3; DEALLOCATE PREPARE st3;

SET @i2 := (SELECT COUNT(*) FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_evidence' AND INDEX_NAME = 'idx_case');
SET @s4 := IF(@i2 = 0, 'ALTER TABLE police_evidence ADD KEY idx_case (case_id)', 'SELECT 1');
PREPARE st4 FROM @s4; EXECUTE st4; DEALLOCATE PREPARE st4;
