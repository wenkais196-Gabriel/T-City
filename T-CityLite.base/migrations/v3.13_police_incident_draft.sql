-- v3.13 — police_incidents 增加 draft 状态（P6-4 AI 调度员）
--
-- 语义：agent 把一段人话解析成 call 卡，先落成 draft —— 上板、可见，但**不响铃、不派单**。
-- 由警员采纳后才变成 open（既有广播路径）。
--
-- 纯增量：旧值全部保留，不重写任何行。幂等：先查 COLUMN_TYPE，已含 draft 就跳过。
-- 回滚：确认无 draft 行后，把 enum 改回旧集合即可。

SET @needs_draft := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'police_incidents'
       AND COLUMN_NAME = 'status'
       AND COLUMN_TYPE NOT LIKE '%draft%'
);

SET @ddl := IF(@needs_draft > 0,
    'ALTER TABLE police_incidents MODIFY COLUMN status ENUM(''draft'',''open'',''assigned'',''enroute'',''on_scene'',''cleared'',''closed'') NOT NULL DEFAULT ''open''',
    'DO 0');

PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
