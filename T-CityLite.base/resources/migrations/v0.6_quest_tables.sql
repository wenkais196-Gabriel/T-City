-- ==============================================================
-- v0.6 Quest System — Database Migration
-- ==============================================================
-- Run: mysql -u root -p < v0.6_quest_tables.sql
-- 或在 oxmysql 控制台中逐条执行
-- ==============================================================

-- 1. 玩家任务进度表
CREATE TABLE IF NOT EXISTS player_quests (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    citizenid       VARCHAR(50) NOT NULL,
    quest_id        VARCHAR(64) NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'in_progress',
    --  'not_started' | 'in_progress' | 'completed' | 'failed' | 'abandoned'
    current_step    VARCHAR(64) DEFAULT NULL,
    progress_data   LONGTEXT DEFAULT NULL,     -- JSON 灵活存储步骤级进度
    started_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    completed_at    DATETIME DEFAULT NULL,
    failed_at       DATETIME DEFAULT NULL,
    completion_count INT DEFAULT 0,
    UNIQUE KEY uq_player_active_quest (citizenid, quest_id, status),
    INDEX idx_citizenid (citizenid),
    INDEX idx_status (status),
    INDEX idx_quest_id (quest_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 2. 任务冷却表
CREATE TABLE IF NOT EXISTS quest_cooldowns (
    citizenid       VARCHAR(50) NOT NULL,
    quest_id        VARCHAR(64) NOT NULL,
    expires_at      DATETIME NOT NULL,
    completion_count INT DEFAULT 0,
    PRIMARY KEY (citizenid, quest_id),
    INDEX idx_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 3. 任务事件审计日志
CREATE TABLE IF NOT EXISTS quest_event_log (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    citizenid       VARCHAR(50) NOT NULL,
    quest_id        VARCHAR(64) NOT NULL,
    step_id         VARCHAR(64) DEFAULT NULL,
    event_type      VARCHAR(32) NOT NULL,  -- trigger | advance | complete | fail | abandon
    metadata        LONGTEXT DEFAULT NULL, -- JSON 上下文
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_citizenid (citizenid),
    INDEX idx_created (created_at),
    INDEX idx_quest_event (quest_id, event_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 4. Cleanup 事件: 定期清理过期的冷却记录
-- (可在 oxmysql 中创建定时事件)
-- CREATE EVENT IF NOT EXISTS evt_clean_quest_cooldowns
-- ON SCHEDULE EVERY 1 HOUR
-- DO DELETE FROM quest_cooldowns WHERE expires_at < NOW();