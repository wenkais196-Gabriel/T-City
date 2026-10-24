-- v3.4_police_arrest.sql — arrest-as-report consolidation (P1). Idempotent:
-- every column/index is added only when information_schema does not have it,
-- so this migration can be re-run safely on existing databases.

-- police_reports.case_id (normally from v3.3; repeated so v3.4 stands alone).
SET @h1 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'case_id');
SET @s1 := IF(@h1 = 0, 'ALTER TABLE police_reports ADD COLUMN case_id BIGINT UNSIGNED DEFAULT NULL AFTER incident_id', 'SELECT 1');
PREPARE st1 FROM @s1; EXECUTE st1; DEALLOCATE PREPARE st1;

-- police_reports.kind — distinguishes an arrest report from a written report.
SET @h2 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'kind');
SET @s2 := IF(@h2 = 0, "ALTER TABLE police_reports ADD COLUMN kind ENUM('report','arrest') NOT NULL DEFAULT 'report' AFTER status", 'SELECT 1');
PREPARE st2 FROM @s2; EXECUTE st2; DEALLOCATE PREPARE st2;

-- police_reports.charges — JSON array of {id,label,minutes,fine}.
SET @h3 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'charges');
SET @s3 := IF(@h3 = 0, 'ALTER TABLE police_reports ADD COLUMN charges JSON DEFAULT NULL AFTER case_id', 'SELECT 1');
PREPARE st3 FROM @s3; EXECUTE st3; DEALLOCATE PREPARE st3;

-- police_reports BOLO tag: BOLOs stop writing police_bolos and ride on reports.
SET @h4 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'is_bolo');
SET @s4 := IF(@h4 = 0, 'ALTER TABLE police_reports ADD COLUMN is_bolo TINYINT NOT NULL DEFAULT 0 AFTER charges', 'SELECT 1');
PREPARE st4 FROM @s4; EXECUTE st4; DEALLOCATE PREPARE st4;

SET @h5 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'bolo_kind');
SET @s5 := IF(@h5 = 0, 'ALTER TABLE police_reports ADD COLUMN bolo_kind VARCHAR(8) DEFAULT NULL AFTER is_bolo', 'SELECT 1');
PREPARE st5 FROM @s5; EXECUTE st5; DEALLOCATE PREPARE st5;

SET @h6 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'bolo_target');
SET @s6 := IF(@h6 = 0, 'ALTER TABLE police_reports ADD COLUMN bolo_target VARCHAR(50) DEFAULT NULL AFTER bolo_kind', 'SELECT 1');
PREPARE st6 FROM @s6; EXECUTE st6; DEALLOCATE PREPARE st6;

-- Context auto-filled by the MDT when the report page opens.
SET @h7 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'location');
SET @s7 := IF(@h7 = 0, 'ALTER TABLE police_reports ADD COLUMN location VARCHAR(120) DEFAULT NULL AFTER bolo_target', 'SELECT 1');
PREPARE st7 FROM @s7; EXECUTE st7; DEALLOCATE PREPARE st7;

SET @h8 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'officer_citizenid');
SET @s8 := IF(@h8 = 0, 'ALTER TABLE police_reports ADD COLUMN officer_citizenid VARCHAR(50) DEFAULT NULL AFTER location', 'SELECT 1');
PREPARE st8 FROM @s8; EXECUTE st8; DEALLOCATE PREPARE st8;

-- police_citations — the charge catalogue and the report that produced it.
SET @h9 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_citations' AND COLUMN_NAME = 'charge_id');
SET @s9 := IF(@h9 = 0, 'ALTER TABLE police_citations ADD COLUMN charge_id VARCHAR(32) DEFAULT NULL AFTER amount', 'SELECT 1');
PREPARE st9 FROM @s9; EXECUTE st9; DEALLOCATE PREPARE st9;

SET @h10 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_citations' AND COLUMN_NAME = 'base_amount');
SET @s10 := IF(@h10 = 0, 'ALTER TABLE police_citations ADD COLUMN base_amount INT DEFAULT NULL AFTER charge_id', 'SELECT 1');
PREPARE st10 FROM @s10; EXECUTE st10; DEALLOCATE PREPARE st10;

SET @h11 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_citations' AND COLUMN_NAME = 'report_id');
SET @s11 := IF(@h11 = 0, 'ALTER TABLE police_citations ADD COLUMN report_id BIGINT UNSIGNED DEFAULT NULL AFTER incident_id', 'SELECT 1');
PREPARE st11 FROM @s11; EXECUTE st11; DEALLOCATE PREPARE st11;

-- police_evidence.report_id (already in v3.0; repeated for standalone safety).
SET @h12 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_evidence' AND COLUMN_NAME = 'report_id');
SET @s12 := IF(@h12 = 0, 'ALTER TABLE police_evidence ADD COLUMN report_id BIGINT UNSIGNED DEFAULT NULL AFTER incident_id', 'SELECT 1');
PREPARE st12 FROM @s12; EXECUTE st12; DEALLOCATE PREPARE st12;

-- Indexes used by the arrest/report queries.
SET @i1 := (SELECT COUNT(*) FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND INDEX_NAME = 'idx_kind_created');
SET @s13 := IF(@i1 = 0, 'ALTER TABLE police_reports ADD KEY idx_kind_created (kind, created_at)', 'SELECT 1');
PREPARE st13 FROM @s13; EXECUTE st13; DEALLOCATE PREPARE st13;

SET @i2 := (SELECT COUNT(*) FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_citations' AND INDEX_NAME = 'idx_report');
SET @s14 := IF(@i2 = 0, 'ALTER TABLE police_citations ADD KEY idx_report (report_id)', 'SELECT 1');
PREPARE st14 FROM @s14; EXECUTE st14; DEALLOCATE PREPARE st14;

SET @i3 := (SELECT COUNT(*) FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_evidence' AND INDEX_NAME = 'idx_report');
SET @s15 := IF(@i3 = 0, 'ALTER TABLE police_evidence ADD KEY idx_report (report_id)', 'SELECT 1');
PREPARE st15 FROM @s15; EXECUTE st15; DEALLOCATE PREPARE st15;
