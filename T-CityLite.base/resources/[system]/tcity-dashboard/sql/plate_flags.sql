-- sql/plate_flags.sql — v2.2 BOLO 标记持久化
--
-- 创建 plate_flags 表，存储警用车牌标记数据
-- 服务端启动时预加载到内存 FlaggedPlates

CREATE TABLE IF NOT EXISTS `plate_flags` (
    `plate`       VARCHAR(16)  NOT NULL PRIMARY KEY,
    `isflagged`   TINYINT(1)   NOT NULL DEFAULT 1,
    `reason`      VARCHAR(255)  DEFAULT NULL,
    `flagged_by`  VARCHAR(64)   DEFAULT NULL,
    `flagged_at`  INT(11)       NOT NULL DEFAULT 0,
    INDEX `idx_isflagged` (`isflagged`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
