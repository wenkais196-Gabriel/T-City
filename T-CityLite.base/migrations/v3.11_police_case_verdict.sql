-- v3.11_police_case_verdict.sql — 案卷需要能记住判决（AC-P1-03）
--
-- 现状：`police_cases` 只有 status（open/closed/archived），判决结果只能落在
-- `police_reports.justice_verdict` 上；而报告不一定存在，于是"这案子判了几年"
-- 在案卷维度查不到。加两列，判决回写就能落在案卷自己身上。
--
-- 幂等：沿用 v3.6 的 information_schema 判断 + PREPARE/EXECUTE，可重复执行。

SET @has_court := (SELECT COUNT(*) FROM information_schema.COLUMNS
                   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_cases'
                     AND COLUMN_NAME = 'court_status');
SET @sql := IF(@has_court = 0,
    'ALTER TABLE police_cases ADD COLUMN court_status VARCHAR(24) DEFAULT NULL AFTER status',
    'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @has_minutes := (SELECT COUNT(*) FROM information_schema.COLUMNS
                     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_cases'
                       AND COLUMN_NAME = 'sentence_minutes');
SET @sql2 := IF(@has_minutes = 0,
    'ALTER TABLE police_cases ADD COLUMN sentence_minutes INT DEFAULT NULL AFTER court_status',
    'SELECT 1');
PREPARE stmt2 FROM @sql2; EXECUTE stmt2; DEALLOCATE PREPARE stmt2;
