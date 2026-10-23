-- ============================================================================
-- v2.8_police_p0.sql — police dispatch P0 (units / incidents / audit)
-- Idempotent: CREATE TABLE IF NOT EXISTS only.
-- ============================================================================
SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS `police_units` (
    `citizenid`   VARCHAR(50) NOT NULL,
    `callsign`    VARCHAR(16) DEFAULT NULL,
    `dept`        VARCHAR(16) NOT NULL DEFAULT 'PATROL',
    `status`      ENUM('off_duty','available','busy','unavailable','assigned','enroute','on_scene')
                  NOT NULL DEFAULT 'off_duty',
    `incident_id` BIGINT UNSIGNED DEFAULT NULL,
    `updated_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`),
    KEY `idx_status` (`status`),
    KEY `idx_incident` (`incident_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `police_incidents` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `code`        VARCHAR(16) NOT NULL DEFAULT '911',
    `title`       VARCHAR(120) NOT NULL,
    `description` VARCHAR(1000) NOT NULL DEFAULT '',
    `priority`    TINYINT UNSIGNED NOT NULL DEFAULT 2,
    `status`      ENUM('open','assigned','enroute','on_scene','cleared','closed')
                  NOT NULL DEFAULT 'open',
    `x`           DOUBLE DEFAULT NULL,
    `y`           DOUBLE DEFAULT NULL,
    `z`           DOUBLE DEFAULT NULL,
    `created_by`  VARCHAR(50) DEFAULT NULL,
    `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    `closed_at`   DATETIME DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_status_created` (`status`, `created_at`),
    KEY `idx_priority` (`priority`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `police_incident_units` (
    `incident_id` BIGINT UNSIGNED NOT NULL,
    `citizenid`   VARCHAR(50) NOT NULL,
    `role`        VARCHAR(16) NOT NULL DEFAULT 'primary',
    `joined_at`   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`incident_id`, `citizenid`),
    KEY `idx_citizenid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `police_audit` (
    `id`              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `actor_citizenid` VARCHAR(50) DEFAULT NULL,
    `actor_kind`      ENUM('player','agent','system') NOT NULL DEFAULT 'player',
    `action`          VARCHAR(48) NOT NULL,
    `target`          VARCHAR(64) DEFAULT NULL,
    `detail`          VARCHAR(500) DEFAULT NULL,
    `created_at`      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_actor_created` (`actor_citizenid`, `created_at`),
    KEY `idx_action_created` (`action`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Existing DBs that already have police_units without the newer columns.
ALTER TABLE `police_units`
    ADD COLUMN IF NOT EXISTS `dept` VARCHAR(16) NOT NULL DEFAULT 'PATROL' AFTER `callsign`,
    ADD COLUMN IF NOT EXISTS `incident_id` BIGINT UNSIGNED DEFAULT NULL AFTER `status`;
