-- v3.11_police_npc_callout.sql — NPC callout marker on police_incidents.
--
-- NPC callouts reuse the existing dispatch board: an incident is a normal
-- police_incidents row, with `npc_template` set to the shared template id
-- (traffic_accident / suspicious_vehicle / store_robbery / armed_person).
-- `NULL` means an ordinary player/agent/911 incident, so every existing query
-- and the MDT keep working unchanged.
--
-- The composite index supports the two server-side hot reads:
--   * the active-callout cap:  WHERE npc_template IS NOT NULL AND status <> 'closed'
--   * the MDT/badge marker:    npc_template IS NOT NULL
--
-- Idempotent: the column and the index are both guarded through
-- information_schema, so re-running this migration is a no-op.

SET @has_npc_template := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_incidents'
      AND COLUMN_NAME = 'npc_template'
);
SET @sql_npc_template := IF(@has_npc_template = 0,
    'ALTER TABLE police_incidents ADD COLUMN npc_template VARCHAR(32) NULL AFTER disposition',
    'SELECT 1');
PREPARE stmt_npc_template FROM @sql_npc_template;
EXECUTE stmt_npc_template;
DEALLOCATE PREPARE stmt_npc_template;

SET @has_idx_npc_template := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'police_incidents'
      AND INDEX_NAME = 'idx_npc_template_status'
);
SET @sql_idx_npc_template := IF(@has_idx_npc_template = 0,
    'ALTER TABLE police_incidents ADD KEY idx_npc_template_status (npc_template, status)',
    'SELECT 1');
PREPARE stmt_idx_npc_template FROM @sql_idx_npc_template;
EXECUTE stmt_idx_npc_template;
DEALLOCATE PREPARE stmt_idx_npc_template;
