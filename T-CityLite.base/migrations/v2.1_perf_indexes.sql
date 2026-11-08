-- ============================================================================
-- Migration: v2.1_perf_indexes.sql
-- Step 2 P1 Performance Optimization
-- ============================================================================
-- Adds phone_number virtual column + index to eliminate charinfo LIKE full scans
-- 幂等：每一步都先查 information_schema（沿用 v3.11/v3.12 的 PREPARE/EXECUTE 形状），
--       可重复执行。原来裸 ALTER / CREATE INDEX，第二次跑必报
--       `ERROR 1060 Duplicate column name 'phone_number'`。
-- Run: mysql -u root -p QBCore_CDB34E < v2.1_perf_indexes.sql
-- ============================================================================

-- 1. phone_number virtual column (extracted from JSON charinfo)
-- This replaces all `charinfo LIKE '%phone%'` queries with exact index lookups
SET @has_phone_column := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'players' AND COLUMN_NAME = 'phone_number'
);
SET @stmt_phone_column := IF(@has_phone_column = 0,
    'ALTER TABLE players ADD COLUMN phone_number VARCHAR(20) GENERATED ALWAYS AS (JSON_UNQUOTE(JSON_EXTRACT(charinfo, ''$.phone'')) ) VIRTUAL',
    'DO 0');
PREPARE stmt_phone_column FROM @stmt_phone_column;
EXECUTE stmt_phone_column;
DEALLOCATE PREPARE stmt_phone_column;

-- 2. Index on phone_number for fast exact-match lookups
SET @has_phone_index := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'players' AND INDEX_NAME = 'idx_players_phone'
);
SET @stmt_phone_index := IF(@has_phone_index = 0,
    'CREATE INDEX idx_players_phone ON players(phone_number)', 'DO 0');
PREPARE stmt_phone_index FROM @stmt_phone_index;
EXECUTE stmt_phone_index;
DEALLOCATE PREPARE stmt_phone_index;

-- 3. bank_statements date index (for time-sorted billing queries)
SET @has_bank_index := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'bank_statements' AND INDEX_NAME = 'idx_bank_statements_date'
);
SET @stmt_bank_index := IF(@has_bank_index = 0,
    'CREATE INDEX idx_bank_statements_date ON bank_statements(`date`)', 'DO 0');
PREPARE stmt_bank_index FROM @stmt_bank_index;
EXECUTE stmt_bank_index;
DEALLOCATE PREPARE stmt_bank_index;

-- 4. phone_tweets date index (for time-filtered tweet feed)
SET @has_tweets_index := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'phone_tweets' AND INDEX_NAME = 'idx_phone_tweets_date'
);
SET @stmt_tweets_index := IF(@has_tweets_index = 0,
    'CREATE INDEX idx_phone_tweets_date ON phone_tweets(`date`)', 'DO 0');
PREPARE stmt_tweets_index FROM @stmt_tweets_index;
EXECUTE stmt_tweets_index;
DEALLOCATE PREPARE stmt_tweets_index;

-- ============================================================================
-- Verification queries (run after migration to confirm)
-- ============================================================================
-- SHOW INDEX FROM players WHERE Key_name = 'idx_players_phone';
-- EXPLAIN SELECT citizenid, money, charinfo FROM players WHERE phone_number = '1234567890';
-- (should show 'ref' type, not 'ALL' full scan)
-- ============================================================================
