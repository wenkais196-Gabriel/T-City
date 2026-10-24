-- v3.5_police_arrest_subject.sql — name the person arrested in the report (P1).
-- Since v3.4 an arrest is a police_reports row with kind='arrest'; readers used
-- to recover the suspect from the retired police_arrests table. Store it on the
-- report itself so GetArrests / case detail need no legacy table.
--
-- Idempotent: every change is guarded by information_schema and can be re-run.

SET @h1 := (SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND COLUMN_NAME = 'subject_citizenid');
SET @s1 := IF(@h1 = 0, 'ALTER TABLE police_reports ADD COLUMN subject_citizenid VARCHAR(50) DEFAULT NULL AFTER officer_citizenid', 'SELECT 1');
PREPARE st1 FROM @s1; EXECUTE st1; DEALLOCATE PREPARE st1;

-- Arrest history is read by subject, newest first; kind keeps the index usable
-- for the other report kinds too.
SET @i1 := (SELECT COUNT(*) FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_reports' AND INDEX_NAME = 'idx_subject_kind_created');
SET @s2 := IF(@i1 = 0, 'ALTER TABLE police_reports ADD KEY idx_subject_kind_created (subject_citizenid, kind, created_at)', 'SELECT 1');
PREPARE st2 FROM @s2; EXECUTE st2; DEALLOCATE PREPARE st2;
