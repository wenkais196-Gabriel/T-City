-- ==============================================================
-- v0.7 StoryEngine — 剧情决策系统数据库迁移
-- ==============================================================
-- Run: mysql -u root -p < v0.7_story_engine.sql
--
-- 注意：本文件已与线上实际 schema 对齐（2026-10-21）：
--   player_choices  使用 uq_choice(citizenid, decision_id) + idx_arc
--   story_completions 使用 id 主键 + uq_completion(citizenid, arc_id)
-- 已有库请执行 v2.2_schema_reconcile.sql 补齐差异。

-- 玩家抉择记录表
CREATE TABLE IF NOT EXISTS player_choices (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    citizenid       VARCHAR(50) NOT NULL,
    decision_id     VARCHAR(100) NOT NULL,       -- 决策点ID，如 'cartel_ch1_betray_or_loyal'
    chosen_option   VARCHAR(100) NOT NULL,       -- 玩家选择的选项ID
    arc_id          VARCHAR(50) NOT NULL,        -- 所属剧情线: cartel | police | civilian
    chapter         INT DEFAULT 1,
    chosen_at       DATETIME DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_choice (citizenid, decision_id),
    KEY idx_citizenid (citizenid),
    KEY idx_arc (arc_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 剧情线完成追踪表（一次性门控）
CREATE TABLE IF NOT EXISTS story_completions (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    citizenid       VARCHAR(50) NOT NULL,
    arc_id          VARCHAR(50) NOT NULL,        -- cartel | police | civilian
    completed_at    TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_completion (citizenid, arc_id),
    KEY idx_citizenid (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
