-- v4.6_industry_stock_level.sql — P3 库存上限可升级（#411）。
--
-- `industry_facility` 增加 `stock_level`（0–6）。上限与价格由 Lua 从配置计算：
--   上限 = 540 + 900 × stock_level（0 级 540，满级 5,940）
--   价格 = floor(40,000 × 1.6^stock_level)（0→1 $40,000，1→2 $64,000 …）
-- 等级只在 upgrade 入口里推进（facility.lua 的 CAS UPDATE），本迁移只补列。
--
-- 旧库的 facility 行默认 0 级 = 原有 540 上限，不需要回填；季节滚动不碰这一列，
-- 只有季度结算删除设施行时才会随行消失。
--
-- Idempotent: MySQL 8 / MariaDB 没有 `ADD COLUMN IF NOT EXISTS`，沿用 v4.3 的
-- information_schema + PREPARE/EXECUTE 形状；连跑两次是 no-op。
--
-- 上游设计：docs/plan/industry-ops/10-plan.md §1/§2（季节保留库存升级）、
-- 11-plan.md §4；施工单元 #411。

SET @has_stock_level := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_facility'
      AND COLUMN_NAME = 'stock_level'
);
SET @sql_stock_level := IF(@has_stock_level = 0,
    'ALTER TABLE `industry_facility` ADD COLUMN `stock_level` TINYINT NOT NULL DEFAULT 0 AFTER `workstations`',
    'DO 0');
PREPARE stmt_stock_level FROM @sql_stock_level;
EXECUTE stmt_stock_level;
DEALLOCATE PREPARE stmt_stock_level;
