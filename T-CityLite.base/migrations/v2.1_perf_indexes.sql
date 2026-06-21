-- ============================================================================
-- Migration: v2.1_perf_indexes.sql
-- Step 2 P1 Performance Optimization
-- ============================================================================
-- Adds phone_number virtual column + index to eliminate charinfo LIKE full scans
-- Run: mysql -u root -p QBCore_CDB34E < v2.1_perf_indexes.sql
-- ============================================================================

-- 1. phone_number virtual column (extracted from JSON charinfo)
-- This replaces all `charinfo LIKE '%phone%'` queries with exact index lookups
ALTER TABLE players
ADD COLUMN phone_number VARCHAR(20)
  GENERATED ALWAYS AS (JSON_UNQUOTE(JSON_EXTRACT(charinfo, '$.phone')))
  VIRTUAL;

-- 2. Index on phone_number for fast exact-match lookups
CREATE INDEX idx_players_phone ON players(phone_number);

-- 3. bank_statements date index (for time-sorted billing queries)
CREATE INDEX idx_bank_statements_date ON bank_statements(`date`);

-- 4. phone_tweets date index (for time-filtered tweet feed)
CREATE INDEX idx_phone_tweets_date ON phone_tweets(`date`);

-- ============================================================================
-- Verification queries (run after migration to confirm)
-- ============================================================================
-- SHOW INDEX FROM players WHERE Key_name = 'idx_players_phone';
-- EXPLAIN SELECT citizenid, money, charinfo FROM players WHERE phone_number = '1234567890';
-- (should show 'ref' type, not 'ALL' full scan)
-- ============================================================================
