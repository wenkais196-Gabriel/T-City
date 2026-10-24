-- v3.10_police_incident_disposition.sql — SM-02 incident close provenance.
--
-- `police_incidents.status` used to have no transition guard and `closed` was
-- unreachable, so cleared calls stayed in the dispatch queue forever and a
-- close overwrote every linked unit's busy state. The server now owns the
-- transition table and closes with an explicit disposition. These columns keep
-- the why/who/how of a close and give the stale-call sweep a heartbeat:
--
--   disposition      cleared | cancelled | false_alarm | stale | arrest
--   closed_by        officer citizenid, or 'system' for the sweep
--   closed_reason    free-form reason, e.g. 'stale_timeout'
--   last_activity_at bumped on assign/status changes; COALESCE(created_at)
--                    is used for calls that have never been touched
--
-- Idempotent: each column is guarded through information_schema.COLUMNS, so
-- the migration can be re-run safely.

SET @has_disposition := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_incidents'
      AND COLUMN_NAME = 'disposition'
);
SET @sql_disposition := IF(@has_disposition = 0,
    'ALTER TABLE police_incidents ADD COLUMN disposition VARCHAR(32) NULL AFTER closed_at',
    'SELECT 1');
PREPARE stmt_disposition FROM @sql_disposition;
EXECUTE stmt_disposition;
DEALLOCATE PREPARE stmt_disposition;

SET @has_closed_by := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_incidents'
      AND COLUMN_NAME = 'closed_by'
);
SET @sql_closed_by := IF(@has_closed_by = 0,
    'ALTER TABLE police_incidents ADD COLUMN closed_by VARCHAR(50) NULL AFTER disposition',
    'SELECT 1');
PREPARE stmt_closed_by FROM @sql_closed_by;
EXECUTE stmt_closed_by;
DEALLOCATE PREPARE stmt_closed_by;

SET @has_closed_reason := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_incidents'
      AND COLUMN_NAME = 'closed_reason'
);
SET @sql_closed_reason := IF(@has_closed_reason = 0,
    'ALTER TABLE police_incidents ADD COLUMN closed_reason VARCHAR(255) NULL AFTER closed_by',
    'SELECT 1');
PREPARE stmt_closed_reason FROM @sql_closed_reason;
EXECUTE stmt_closed_reason;
DEALLOCATE PREPARE stmt_closed_reason;

SET @has_last_activity := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_incidents'
      AND COLUMN_NAME = 'last_activity_at'
);
SET @sql_last_activity := IF(@has_last_activity = 0,
    'ALTER TABLE police_incidents ADD COLUMN last_activity_at DATETIME NULL AFTER closed_reason',
    'SELECT 1');
PREPARE stmt_last_activity FROM @sql_last_activity;
EXECUTE stmt_last_activity;
DEALLOCATE PREPARE stmt_last_activity;
