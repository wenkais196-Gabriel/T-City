-- v3.15_cityfeed_author_kind.sql — CityFeed 需要一个「城市」作者。
--
-- 世界痕迹第一条链要把「某区域刚结案」变成玩家看得见的城市动态
-- （docs/engineering/2026-11-01-world-traces-blueprint.md）。而 phone_cityfeed 只有
-- citizenid（NOT NULL、被 LEFT JOIN 取名字），系统公告落进去会显示成 @Anonymous。
--
--   author_kind   citizen（玩家帖子，默认）| city（系统公告）
--
-- 玩家发帖路径显式写 'citizen'，不接受客户端传值；系统公告只走 custom-phone 自己的
-- 导出 PostCityBulletin。既有行由 DEFAULT 自动补齐。
--
-- Idempotent: 列与索引各自过 information_schema 守卫，可重复执行。

SET @has_author_kind := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'phone_cityfeed'
      AND COLUMN_NAME = 'author_kind'
);
SET @sql_author_kind := IF(@has_author_kind = 0,
    "ALTER TABLE phone_cityfeed ADD COLUMN author_kind ENUM('citizen','city') NOT NULL DEFAULT 'citizen' AFTER citizenid",
    'SELECT 1');
PREPARE stmt_author_kind FROM @sql_author_kind;
EXECUTE stmt_author_kind;
DEALLOCATE PREPARE stmt_author_kind;

SET @has_author_kind_idx := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'phone_cityfeed'
      AND INDEX_NAME = 'idx_author_kind'
);
SET @sql_author_kind_idx := IF(@has_author_kind_idx = 0,
    'ALTER TABLE phone_cityfeed ADD INDEX idx_author_kind (author_kind)',
    'SELECT 1');
PREPARE stmt_author_kind_idx FROM @sql_author_kind_idx;
EXECUTE stmt_author_kind_idx;
DEALLOCATE PREPARE stmt_author_kind_idx;
