-- v4.5_industry_quarter.sql — P1 两时钟：周 = 四季，13 周 = 1 季度。
--
-- 三张表各加一个维度，**不删旧列**：
--
--   industry_state
--     quarter_no / season / season_no：当前季度号、季名、季内序号。
--     season_started_at / season_ends_at：当前季节的绝对边界。
--     quarter_started_at / quarter_ends_at：当前季度的绝对边界。
--     时间戳默认 NULL 是**迁移哨兵**：NULL = 还是旧单时钟，Lua 的 Initialize
--     会把现有 phase 边界原样接上 season（不重算），之后才走两时钟 Tick。
--     season 默认 'spring' 只是新库的占位；是否已接线只看 season_started_at。
--
--   industry_demand
--     PK 从 (cycle_no, phase, item_name) 扩到 (cycle_no, phase, season, item_name)。
--     `quota_used` 因此严格按季独立；历史行 season 默认 0，仍满足新唯一键。
--     ⚠️ 必须 DROP 再 ADD：MySQL 8 没有 ADD COLUMN IF NOT EXISTS 以外的幂等 DDL，
--     沿用 v4.3 的 information_schema + PREPARE 形状，连跑两次是 no-op。
--
--   industry_cycle_results
--     加 quarter_no（历史行 NULL —— MySQL 唯一索引允许多个 NULL，不会互相冲突）。
--     幂等键从 UNIQUE(org_id, cycle_no) 换成 UNIQUE(org_id, quarter_no)；
--     旧列 cycle_no 保留（历史行与旧工具仍能读），只删旧唯一键 —— 否则新季度
--     结果会被「同 org 的旧 cycle_no」撞键。
--
-- 不改 industry_sales：v4.3 已经有 phase/season 列，写入侧由 IndustryCycle.Current()
-- 返回真实 season 序号（1..4）后自动生效。
--
-- Idempotent: CREATE TABLE 不在本文件；所有变更走 information_schema + PREPARE。
--
-- 上游设计：docs/plan/industry-ops/10-plan.md §1/§2、11-plan.md §2；施工单元 #409。

-- ── industry_state ───────────────────────────────────────────────────────

SET @has_quarter_no := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_state'
      AND COLUMN_NAME = 'quarter_no'
);
SET @sql_quarter_no := IF(@has_quarter_no = 0,
    'ALTER TABLE `industry_state` ADD COLUMN `quarter_no` INT(11) NOT NULL DEFAULT 1 AFTER `phase`',
    'DO 0');
PREPARE stmt_quarter_no FROM @sql_quarter_no;
EXECUTE stmt_quarter_no;
DEALLOCATE PREPARE stmt_quarter_no;

SET @has_season := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_state'
      AND COLUMN_NAME = 'season'
);
SET @sql_season := IF(@has_season = 0,
    'ALTER TABLE `industry_state` ADD COLUMN `season` VARCHAR(16) NOT NULL DEFAULT ''spring'' AFTER `quarter_no`',
    'DO 0');
PREPARE stmt_season FROM @sql_season;
EXECUTE stmt_season;
DEALLOCATE PREPARE stmt_season;

SET @has_season_no := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_state'
      AND COLUMN_NAME = 'season_no'
);
SET @sql_season_no := IF(@has_season_no = 0,
    'ALTER TABLE `industry_state` ADD COLUMN `season_no` INT(11) NOT NULL DEFAULT 1 AFTER `season`',
    'DO 0');
PREPARE stmt_season_no FROM @sql_season_no;
EXECUTE stmt_season_no;
DEALLOCATE PREPARE stmt_season_no;

SET @has_season_started := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_state'
      AND COLUMN_NAME = 'season_started_at'
);
SET @sql_season_started := IF(@has_season_started = 0,
    'ALTER TABLE `industry_state` ADD COLUMN `season_started_at` DATETIME DEFAULT NULL AFTER `season_no`',
    'DO 0');
PREPARE stmt_season_started FROM @sql_season_started;
EXECUTE stmt_season_started;
DEALLOCATE PREPARE stmt_season_started;

SET @has_season_ends := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_state'
      AND COLUMN_NAME = 'season_ends_at'
);
SET @sql_season_ends := IF(@has_season_ends = 0,
    'ALTER TABLE `industry_state` ADD COLUMN `season_ends_at` DATETIME DEFAULT NULL AFTER `season_started_at`',
    'DO 0');
PREPARE stmt_season_ends FROM @sql_season_ends;
EXECUTE stmt_season_ends;
DEALLOCATE PREPARE stmt_season_ends;

SET @has_quarter_started := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_state'
      AND COLUMN_NAME = 'quarter_started_at'
);
SET @sql_quarter_started := IF(@has_quarter_started = 0,
    'ALTER TABLE `industry_state` ADD COLUMN `quarter_started_at` DATETIME DEFAULT NULL AFTER `season_ends_at`',
    'DO 0');
PREPARE stmt_quarter_started FROM @sql_quarter_started;
EXECUTE stmt_quarter_started;
DEALLOCATE PREPARE stmt_quarter_started;

SET @has_quarter_ends := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_state'
      AND COLUMN_NAME = 'quarter_ends_at'
);
SET @sql_quarter_ends := IF(@has_quarter_ends = 0,
    'ALTER TABLE `industry_state` ADD COLUMN `quarter_ends_at` DATETIME DEFAULT NULL AFTER `quarter_started_at`',
    'DO 0');
PREPARE stmt_quarter_ends FROM @sql_quarter_ends;
EXECUTE stmt_quarter_ends;
DEALLOCATE PREPARE stmt_quarter_ends;

-- ── industry_demand：season 维度 + 新主键 ───────────────────────────────

SET @has_demand_season := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_demand'
      AND COLUMN_NAME = 'season'
);
SET @sql_demand_season := IF(@has_demand_season = 0,
    'ALTER TABLE `industry_demand` ADD COLUMN `season` INT(11) NOT NULL DEFAULT 0 AFTER `phase`',
    'DO 0');
PREPARE stmt_demand_season FROM @sql_demand_season;
EXECUTE stmt_demand_season;
DEALLOCATE PREPARE stmt_demand_season;

SET @demand_pk_has_season := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_demand'
      AND INDEX_NAME = 'PRIMARY' AND COLUMN_NAME = 'season'
);
SET @demand_pk_columns := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_demand'
      AND INDEX_NAME = 'PRIMARY'
);
SET @sql_demand_pk := IF(@demand_pk_has_season = 0,
    IF(@demand_pk_columns = 0,
        'ALTER TABLE `industry_demand` ADD PRIMARY KEY (`cycle_no`,`phase`,`season`,`item_name`)',
        'ALTER TABLE `industry_demand` DROP PRIMARY KEY, ADD PRIMARY KEY (`cycle_no`,`phase`,`season`,`item_name`)'),
    'DO 0');
PREPARE stmt_demand_pk FROM @sql_demand_pk;
EXECUTE stmt_demand_pk;
DEALLOCATE PREPARE stmt_demand_pk;

-- ── industry_cycle_results：季度幂等键（保留旧列）────────────────────────

SET @has_result_quarter := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_cycle_results'
      AND COLUMN_NAME = 'quarter_no'
);
SET @sql_result_quarter := IF(@has_result_quarter = 0,
    'ALTER TABLE `industry_cycle_results` ADD COLUMN `quarter_no` INT(11) DEFAULT NULL AFTER `org_id`',
    'DO 0');
PREPARE stmt_result_quarter FROM @sql_result_quarter;
EXECUTE stmt_result_quarter;
DEALLOCATE PREPARE stmt_result_quarter;

SET @has_uniq_quarter := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_cycle_results'
      AND INDEX_NAME = 'uniq_org_quarter'
);
SET @sql_uniq_quarter := IF(@has_uniq_quarter = 0,
    'ALTER TABLE `industry_cycle_results` ADD UNIQUE KEY `uniq_org_quarter` (`org_id`,`quarter_no`)',
    'DO 0');
PREPARE stmt_uniq_quarter FROM @sql_uniq_quarter;
EXECUTE stmt_uniq_quarter;
DEALLOCATE PREPARE stmt_uniq_quarter;

SET @has_uniq_cycle := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_cycle_results'
      AND INDEX_NAME = 'uniq_org_cycle'
);
SET @sql_drop_uniq_cycle := IF(@has_uniq_cycle > 0,
    'ALTER TABLE `industry_cycle_results` DROP INDEX `uniq_org_cycle`',
    'DO 0');
PREPARE stmt_drop_uniq_cycle FROM @sql_drop_uniq_cycle;
EXECUTE stmt_drop_uniq_cycle;
DEALLOCATE PREPARE stmt_drop_uniq_cycle;
