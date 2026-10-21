-- ==============================================================
-- v0.7 Quest System — 任务系统数据库迁移
-- ==============================================================
-- 背景: custom-quest/server/quest_db.lua 引用了 4 张表，但仓库中
--       没有任何可执行的建表脚本（只存在于设计文档）。
--       新库部署时任务系统会在第一次 DB 调用时报 "table not found"。
--
-- Run: mysql -u root -p < v0.7_quest_system.sql
--
-- 说明:
--   * 不建 (citizenid, quest_id, status) 唯一键：代码每次接取都 INSERT
--     新行，重复完成时 UPDATE 到 completed 会与历史 completed 行冲突。
--     重复控制由 quest_cooldowns / max_active 负责。
-- ==============================================================

-- 玩家任务进度
CREATE TABLE IF NOT EXISTS player_quests (
    id               INT AUTO_INCREMENT PRIMARY KEY,
    citizenid        VARCHAR(50) NOT NULL,
    quest_id         VARCHAR(64) NOT NULL,
    status           VARCHAR(20) NOT NULL DEFAULT 'in_progress',
    -- not_started | in_progress | completed | failed | abandoned
    current_step     VARCHAR(64) DEFAULT NULL,
    progress_data    LONGTEXT DEFAULT NULL,
    started_at       DATETIME DEFAULT CURRENT_TIMESTAMP,
    completed_at     DATETIME DEFAULT NULL,
    failed_at        DATETIME DEFAULT NULL,
    completion_count INT DEFAULT 0,
    INDEX idx_citizenid (citizenid),
    INDEX idx_quest (quest_id),
    INDEX idx_status (status),
    INDEX idx_citizen_status (citizenid, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 任务冷却
CREATE TABLE IF NOT EXISTS quest_cooldowns (
    citizenid        VARCHAR(50) NOT NULL,
    quest_id         VARCHAR(64) NOT NULL,
    expires_at       DATETIME NOT NULL,
    completion_count INT DEFAULT 0,
    PRIMARY KEY (citizenid, quest_id),
    INDEX idx_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 任务事件审计日志
CREATE TABLE IF NOT EXISTS quest_event_log (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    citizenid   VARCHAR(50) NOT NULL,
    quest_id    VARCHAR(64) NOT NULL,
    step_id     VARCHAR(64) DEFAULT NULL,
    event_type  VARCHAR(32) NOT NULL,  -- trigger | advance | complete | fail | abandon
    metadata    LONGTEXT DEFAULT NULL,
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_citizenid (citizenid),
    INDEX idx_quest (quest_id),
    INDEX idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 每日/每周任务次数限制
CREATE TABLE IF NOT EXISTS quest_daily_limits (
    citizenid   VARCHAR(50) NOT NULL,
    quest_id    VARCHAR(64) NOT NULL,
    limit_type  VARCHAR(16) NOT NULL,      -- daily | weekly | lifetime
    period_start DATE NOT NULL,
    count       INT DEFAULT 0,
    PRIMARY KEY (citizenid, quest_id, limit_type, period_start)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
