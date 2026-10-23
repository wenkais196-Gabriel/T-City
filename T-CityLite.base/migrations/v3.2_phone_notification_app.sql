-- v3.2_phone_notification_app.sql — deep-link target for notifications.
SET @has := (SELECT COUNT(*) FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'phone_notifications' AND COLUMN_NAME = 'app_id');
SET @sql := IF(@has = 0,
    'ALTER TABLE phone_notifications ADD COLUMN app_id VARCHAR(32) DEFAULT NULL AFTER content',
    'SELECT 1');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
