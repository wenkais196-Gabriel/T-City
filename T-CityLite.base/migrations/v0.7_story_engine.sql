-- ==============================================================
-- v0.7 StoryEngine — 剧情决策系统数据库迁移
-- ==============================================================
-- Run: mysql -u root -p < v0.7_story_engine.sql

-- 玩家抉择记录表
CREATE TABLE IF NOT EXISTS player_choices (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    citizenid       VARCHAR(50) NOT NULL,
    decision_id     VARCHAR(64) NOT NULL,       -- 决策点ID，如 'cartel_ch1_betray_or_loyal'
    chosen_option   VARCHAR(32) NOT NULL,        -- 玩家选择的选项ID
    arc_id          VARCHAR(32) NOT NULL,        -- 所属剧情线: cartel | police | civilian
    chapter         INT NOT NULL DEFAULT 1,
    chosen_at       DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_citizenid (citizenid),
    INDEX idx_arc_chapter (arc_id, chapter),
    INDEX idx_decision (decision_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 剧情线完成追踪表（一次性门控）
CREATE TABLE IF NOT EXISTS story_completions (
    citizenid       VARCHAR(50) NOT NULL,
    arc_id          VARCHAR(32) NOT NULL,        -- cartel | police | civilian
    completed_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (citizenid, arc_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
