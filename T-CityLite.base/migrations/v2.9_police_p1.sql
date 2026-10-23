-- v2.9_police_p1.sql — citations + reports (P1). Idempotent.
CREATE TABLE IF NOT EXISTS `police_citations` (
    `id`               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `citizenid`        VARCHAR(50) NOT NULL,
    `officer_citizenid` VARCHAR(50) NOT NULL,
    `plate`            VARCHAR(12) DEFAULT NULL,
    `amount`           INT UNSIGNED NOT NULL,
    `reason`           VARCHAR(240) NOT NULL,
    `status`           ENUM('unpaid','paid','void') NOT NULL DEFAULT 'unpaid',
    `incident_id`      BIGINT UNSIGNED DEFAULT NULL,
    `created_at`       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `paid_at`          DATETIME DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_citizen_status` (`citizenid`, `status`),
    KEY `idx_officer_created` (`officer_citizenid`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `police_reports` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `incident_id` BIGINT UNSIGNED DEFAULT NULL,
    `author_citizenid` VARCHAR(50) NOT NULL,
    `title`       VARCHAR(160) NOT NULL,
    `body`        VARCHAR(4000) NOT NULL,
    `status`      ENUM('draft','submitted','approved') NOT NULL DEFAULT 'submitted',
    `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_incident` (`incident_id`),
    KEY `idx_author_created` (`author_citizenid`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
