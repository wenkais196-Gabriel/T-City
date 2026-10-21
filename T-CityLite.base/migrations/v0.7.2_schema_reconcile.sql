-- ==============================================================
-- v0.7.2 — 既有数据库结构对齐（可重复执行）
-- ==============================================================
-- 适用场景:
--   已经在跑的老 TCityLite 库，缺少后续迁移里的列/索引/表。
--   新库请先执行 v0.7_quest_system.sql、v0.7_story_engine.sql、
--   v0.8_ownership_engine.sql，再执行本文件兜底。
--
-- Run: mysql -u <user> -p <database> < v0.7.2_schema_reconcile.sql
-- ==============================================================

-- player_quests: 失败时间（QuestDB.FailQuest 会写 failed_at）
ALTER TABLE player_quests
    ADD COLUMN IF NOT EXISTS failed_at DATETIME NULL;

-- quest_event_log: 任务审计日志（此前只在设计文档里，没有建表）
CREATE TABLE IF NOT EXISTS quest_event_log (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    citizenid   VARCHAR(50) NOT NULL,
    quest_id    VARCHAR(100) NOT NULL,
    step_id     VARCHAR(100) DEFAULT NULL,
    event_type  VARCHAR(32) NOT NULL,
    metadata    LONGTEXT DEFAULT NULL,
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_citizenid (citizenid),
    INDEX idx_quest (quest_id),
    INDEX idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- player_choices: 剧情查询索引（v0.7_story_engine 里有定义，老库可能缺）
CREATE INDEX IF NOT EXISTS idx_arc_chapter ON player_choices (arc_id, chapter);
CREATE INDEX IF NOT EXISTS idx_decision ON player_choices (decision_id);
