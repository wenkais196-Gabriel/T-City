-- v3.1_police_p2.sql — cases / BOLOs / warrants / arrests (P2). Idempotent.
CREATE TABLE IF NOT EXISTS `police_cases` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `case_no`     VARCHAR(32) DEFAULT NULL,
    `title`       VARCHAR(160) NOT NULL,
    `summary`     VARCHAR(2000) NOT NULL DEFAULT '',
    `status`      ENUM('open','closed','archived') NOT NULL DEFAULT 'open',
    `lead_citizenid` VARCHAR(50) DEFAULT NULL,
    `created_by`  VARCHAR(50) NOT NULL,
    `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uniq_case_no` (`case_no`),
    KEY `idx_status_created` (`status`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `police_bolos` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `kind`        ENUM('person','vehicle') NOT NULL,
    `target`      VARCHAR(50) NOT NULL,
    `reason`      VARCHAR(500) NOT NULL,
    `status`      ENUM('active','cleared') NOT NULL DEFAULT 'active',
    `created_by`  VARCHAR(50) NOT NULL,
    `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `cleared_at`  DATETIME DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_kind_status` (`kind`, `status`),
    KEY `idx_target` (`target`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `police_warrants` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50) NOT NULL,
    `reason`      VARCHAR(500) NOT NULL,
    `status`      ENUM('requested','approved','denied','executed','expired') NOT NULL DEFAULT 'requested',
    `requested_by` VARCHAR(50) NOT NULL,
    `approved_by` VARCHAR(50) DEFAULT NULL,
    `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `decided_at`  DATETIME DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_citizen_status` (`citizenid`, `status`),
    KEY `idx_status_created` (`status`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `police_arrests` (
    `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50) NOT NULL,
    `officer_citizenid` VARCHAR(50) NOT NULL,
    `charges`     VARCHAR(1000) NOT NULL,
    `incident_id` BIGINT UNSIGNED DEFAULT NULL,
    `case_id`     BIGINT UNSIGNED DEFAULT NULL,
    `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_citizen_created` (`citizenid`, `created_at`),
    KEY `idx_case` (`case_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
