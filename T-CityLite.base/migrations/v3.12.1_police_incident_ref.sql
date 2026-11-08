-- v3.12_police_incident_ref.sql — 警情的幂等键与合并计数（AC-P2-05）
--
-- 现有合并是"同 code + 200 m 内 + 5 分钟"，对同一个物理事件够用；
-- 但同一个报警源（例如同一次商店抢劫的多个阶段）坐标会漂，靠坐标合并不住。
-- 蓝图要求按 `ref` 合并并把次数记在单上（merge_count=3），所以补两列。
--
-- 幂等：沿用 v3.11 的 information_schema 判断 + PREPARE/EXECUTE，可重复执行。

SET @has_ref := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_incidents'
                   AND COLUMN_NAME = 'ref');
SET @sql := IF(@has_ref = 0,
    'ALTER TABLE police_incidents ADD COLUMN ref VARCHAR(64) DEFAULT NULL AFTER description',
    'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @has_merge_count := (SELECT COUNT(*) FROM information_schema.COLUMNS
                         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_incidents'
                           AND COLUMN_NAME = 'merge_count');
SET @sql2 := IF(@has_merge_count = 0,
    'ALTER TABLE police_incidents ADD COLUMN merge_count INT NOT NULL DEFAULT 1 AFTER ref',
    'SELECT 1');
PREPARE stmt2 FROM @sql2; EXECUTE stmt2; DEALLOCATE PREPARE stmt2;

SET @has_ref_idx := (SELECT COUNT(*) FROM information_schema.STATISTICS
                     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_incidents'
                       AND INDEX_NAME = 'idx_ref_activity');
SET @sql3 := IF(@has_ref_idx = 0,
    'ALTER TABLE police_incidents ADD KEY idx_ref_activity (ref, last_activity_at)',
    'SELECT 1');
PREPARE stmt3 FROM @sql3; EXECUTE stmt3; DEALLOCATE PREPARE stmt3;
