-- ============================================================================
-- Migration: v2.7_phone_messages.sql
-- Issue:     custom-phone reads/writes the new SMS columns, but the live
--            phone_messages table still has the qb-phone columns
--            (citizenid, number, messages, gps, msg_status). Every SELECT and
--            INSERT on sender_number/receiver_number/message/timestamp/is_read
--            fails with ERROR 1054, and sendMessage returns db_error.
-- Depends:   none (no foreign keys on phone_messages)
-- Target:    MariaDB 11.8 (TCityLite)
-- Run:       set -a; . ./.env; set +a
--            MYSQL_PWD="$TCITY_DB_PASS" mysql -h "$TCITY_DB_HOST" \
--              -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
--              < T-CityLite.base/migrations/v2.7_phone_messages.sql
--
-- Idempotency / states handled (all three are safe to run twice):
--   1. table missing          -> create the new structure
--   2. old qb-phone structure -> RENAME TABLE phone_messages TO
--                                phone_messages_legacy, then create the new
--                                structure and its (receiver_number, id) /
--                                (sender_number, id) indexes
--   3. new structure          -> no-op
--   An unrecognised schema raises an error instead of dropping data.
--
-- LEGACY DATA: 旧数据保留在 `phone_messages_legacy`，不自动 explode JSON。
-- Old rows stay in `phone_messages_legacy`. This migration does NOT explode the
-- legacy JSON `messages` column into rows; the old data is kept only for
-- manual inspection/recovery. If it is needed later, migrate it explicitly
-- with a separate, reviewed script.
-- ============================================================================

SET NAMES utf8mb4;

DROP PROCEDURE IF EXISTS tcity_migrate_phone_messages_v27;

DELIMITER //
CREATE PROCEDURE tcity_migrate_phone_messages_v27()
BEGIN
    DECLARE v_table_exists  INT DEFAULT 0;
    DECLARE v_old_cols      INT DEFAULT 0;
    DECLARE v_new_cols      INT DEFAULT 0;
    DECLARE v_legacy_exists INT DEFAULT 0;
    DECLARE v_archive_exists INT DEFAULT 0;

    SELECT COUNT(*) INTO v_table_exists
      FROM information_schema.TABLES
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'phone_messages';

    IF v_table_exists = 0 THEN
        -- State 1: brand-new database.
        CREATE TABLE `phone_messages` (
            `id`              INT(11)      NOT NULL AUTO_INCREMENT,
            `sender_number`   VARCHAR(20)  NOT NULL,
            `receiver_number` VARCHAR(20)  NOT NULL,
            `message`         TEXT         NOT NULL,
            `timestamp`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `is_read`         TINYINT(1)   NOT NULL DEFAULT 0,
            `gps`             TEXT         DEFAULT NULL,
            `msg_status`      VARCHAR(20)  DEFAULT NULL,
            PRIMARY KEY (`id`),
            KEY `idx_receiver` (`receiver_number`, `id`),
            KEY `idx_sender`   (`sender_number`, `id`),
            KEY `idx_time`     (`timestamp`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
    ELSE
        SELECT COUNT(*) INTO v_new_cols
          FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE()
           AND TABLE_NAME = 'phone_messages'
           AND COLUMN_NAME IN ('sender_number', 'receiver_number', 'message',
                               'timestamp', 'is_read');

        IF v_new_cols = 5 THEN
            -- State 3: already migrated. Nothing to do.
            SET @tcity_phone_messages_noop = 1;
        ELSE
            SELECT COUNT(*) INTO v_old_cols
              FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = DATABASE()
               AND TABLE_NAME = 'phone_messages'
               AND COLUMN_NAME IN ('citizenid', 'number', 'messages',
                                   'gps', 'msg_status');

            IF v_old_cols >= 5 THEN
                -- State 2: qb-phone table. Keep the original rows under a
                -- different name so nothing is destroyed.
                SELECT COUNT(*) INTO v_legacy_exists
                  FROM information_schema.TABLES
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'phone_messages_legacy';

                IF v_legacy_exists = 0 THEN
                    RENAME TABLE `phone_messages` TO `phone_messages_legacy`;
                ELSE
                    -- A previous partial run already produced a legacy table.
                    -- Keep this copy too instead of overwriting either one.
                    SELECT COUNT(*) INTO v_archive_exists
                      FROM information_schema.TABLES
                     WHERE TABLE_SCHEMA = DATABASE()
                       AND TABLE_NAME = 'phone_messages_legacy_archive';

                    IF v_archive_exists = 0 THEN
                        RENAME TABLE `phone_messages`
                            TO `phone_messages_legacy_archive`;
                    ELSE
                        SIGNAL SQLSTATE '45000'
                            SET MESSAGE_TEXT = 'v2.7: legacy phone tables already exist; refusing to overwrite';
                    END IF;
                END IF;

                CREATE TABLE `phone_messages` (
                    `id`              INT(11)      NOT NULL AUTO_INCREMENT,
                    `sender_number`   VARCHAR(20)  NOT NULL,
                    `receiver_number` VARCHAR(20)  NOT NULL,
                    `message`         TEXT         NOT NULL,
                    `timestamp`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    `is_read`         TINYINT(1)   NOT NULL DEFAULT 0,
                    `gps`             TEXT         DEFAULT NULL,
                    `msg_status`      VARCHAR(20)  DEFAULT NULL,
                    PRIMARY KEY (`id`),
                    KEY `idx_receiver` (`receiver_number`, `id`),
                    KEY `idx_sender`   (`sender_number`, `id`),
                    KEY `idx_time`     (`timestamp`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
            ELSE
                SIGNAL SQLSTATE '45000'
                    SET MESSAGE_TEXT = 'v2.7: phone_messages has an unrecognised schema; refusing to overwrite';
            END IF;
        END IF;
    END IF;
END//
DELIMITER ;

CALL tcity_migrate_phone_messages_v27();

DROP PROCEDURE IF EXISTS tcity_migrate_phone_messages_v27;

-- ============================================================================
-- Verification (run manually after applying):
--   SHOW COLUMNS FROM phone_messages;
--   SHOW INDEX FROM phone_messages;   -- expect idx_receiver, idx_sender
--   SHOW TABLES LIKE 'phone_messages_legacy';
-- ============================================================================
