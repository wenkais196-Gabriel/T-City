-- v3.0_police_evidence.sql — evidence register + custody chain (P1). Idempotent.
CREATE TABLE IF NOT EXISTS `police_evidence` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `exhibit_no`  VARCHAR(32) DEFAULT NULL,
    `incident_id` BIGINT UNSIGNED DEFAULT NULL,
    `report_id`   BIGINT UNSIGNED DEFAULT NULL,
    `label`       VARCHAR(120) NOT NULL,
    `description` VARCHAR(1000) NOT NULL DEFAULT '',
    `location`    VARCHAR(120) DEFAULT NULL,
    `collected_by` VARCHAR(50) NOT NULL,
    `status`      ENUM('collected','stored','released','destroyed') NOT NULL DEFAULT 'collected',
    `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_exhibit` (`exhibit_no`),
    KEY `idx_incident` (`incident_id`),
    KEY `idx_report` (`report_id`),
    KEY `idx_status_created` (`status`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `police_evidence_chain` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `evidence_id` BIGINT UNSIGNED NOT NULL,
    `action`      VARCHAR(32) NOT NULL,
    `actor_citizenid` VARCHAR(50) NOT NULL,
    `note`        VARCHAR(500) DEFAULT NULL,
    `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_evidence_created` (`evidence_id`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
