-- ==============================================================
-- v2.2 Schema Reconcile — story-engine 索引/唯一约束补齐
-- ==============================================================
-- 背景：线上库的 player_choices / story_completions 曾手工调整过，
--       与 v0.7_story_engine.sql 产生漂移。本迁移幂等补齐：
--         player_choices     uq_choice(citizenid, decision_id) / idx_arc(arc_id)
--         story_completions  uq_completion(citizenid, arc_id)
--
-- 执行前先检查重复数据（有结果则先清理，否则唯一索引会创建失败）：
--   SELECT citizenid, arc_id, COUNT(*) c FROM story_completions
--     GROUP BY citizenid, arc_id HAVING c > 1;
--
-- Run: mysql -u root -p <数据库名> < v2.2_schema_reconcile.sql

DROP PROCEDURE IF EXISTS tcity_add_index_if_missing;

DELIMITER //
CREATE PROCEDURE tcity_add_index_if_missing(
    IN p_table VARCHAR(64),
    IN p_index VARCHAR(64),
    IN p_cols  VARCHAR(255),
    IN p_unique TINYINT
)
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = p_table
          AND INDEX_NAME = p_index
    ) THEN
        SET @ddl = CONCAT(
            'ALTER TABLE `', p_table, '` ADD ',
            IF(p_unique = 1, 'UNIQUE ', ''),
            'KEY `', p_index, '` (', p_cols, ')'
        );
        PREPARE stmt FROM @ddl;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
    END IF;
END//
DELIMITER ;

CALL tcity_add_index_if_missing('player_choices', 'uq_choice', 'citizenid, decision_id', 1);
CALL tcity_add_index_if_missing('player_choices', 'idx_arc', 'arc_id', 0);
CALL tcity_add_index_if_missing('story_completions', 'uq_completion', 'citizenid, arc_id', 1);

DROP PROCEDURE IF EXISTS tcity_add_index_if_missing;
