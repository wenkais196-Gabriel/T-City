-- v3.7_police_justice_verdict.sql — persist the justice verdict on the report.
-- justice keeps cases in memory; the police report is the durable row linked by
-- justice_case_id (v3.6). Idempotent: each column is added only when
-- information_schema does not have it, so this migration can be re-run safely.

-- Verdict JSON (case id, judge, charges, minutes, fine, reductions, mode).
SET @h1 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'justice_verdict');
SET @s1 := IF(@h1 = 0,
    'ALTER TABLE police_reports ADD COLUMN justice_verdict TEXT NULL AFTER justice_case_id',
    'SELECT 1');
PREPARE st1 FROM @s1; EXECUTE st1; DEALLOCATE PREPARE st1;

-- Justice case state at write time: 'sentenced' or 'closed'.
SET @h2 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'justice_status');
SET @s2 := IF(@h2 = 0,
    'ALTER TABLE police_reports ADD COLUMN justice_status VARCHAR(16) NULL AFTER justice_verdict',
    'SELECT 1');
PREPARE st2 FROM @s2; EXECUTE st2; DEALLOCATE PREPARE st2;
