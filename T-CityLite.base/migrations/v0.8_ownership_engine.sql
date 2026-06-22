-- ============================================================================
-- DB Migration v0.8: Phase 0 所有权引擎骨架表
-- ============================================================================
-- 设计依据: docs/server-design/ 全系列 (00-ownership-philosophy 至 07-architecture-integration)
-- 执行方式: mysql -u swk -p1543368168 TCityLite < v0.8_ownership_engine.sql
-- 兼容性:  全部使用 CREATE TABLE IF NOT EXISTS，可重复执行
-- 影响范围: 零 —— 不修改任何现有表，纯新增
-- 四原则落地:
--   模块化 — 每张表独立锚点系统，无外键耦合
--   高性能 — 高频读字段建索引 (region+key, citizenid, severity+time)
--   安全   — JSON 写操作不走客户端路径; changed_by / proposed_by 仅服务端填充
--   可拓展 — JSON 列允许未来增加字段不破坏 Schema
-- ============================================================================

-- ── 1. world_state — 世界状态 ─────────────────────────────────────────────
-- 锚点: 世界痕迹系统 (02-world-traces.md)
-- 高频读 (每次进区域) · 低频写 (帮派战/经济事件) · DirtyFlush 异步刷盘
CREATE TABLE IF NOT EXISTS `world_state` (
    `id`            INT AUTO_INCREMENT PRIMARY KEY,
    `region_id`     VARCHAR(64)  NOT NULL  COMMENT '区域标识: dock_zone, plaza_market, cartel_base_01',
    `state_key`     VARCHAR(64)  NOT NULL  COMMENT '状态键: controller, price_modifier, market_exists',
    `state_value`   JSON         NOT NULL  COMMENT '状态值 (灵活 JSON 结构)',
    `changed_by`    VARCHAR(64)  NULL      COMMENT '造成此状态的玩家 citizenid (可追溯)',
    `changed_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    `previous_value` JSON        NULL      COMMENT '上一个状态值 (回滚 + 审计)',
    UNIQUE KEY `idx_region_key`  (`region_id`, `state_key`),
    INDEX  `idx_changed_by`      (`changed_by`),
    INDEX  `idx_changed_at`      (`changed_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='世界状态 — 高频读低频写，DirtyFlush 异步刷盘';

-- ── 2. world_events — 世界事件 ────────────────────────────────────────────
-- 锚点: 叙事所有权 (05-narrative-ownership.md) + 世界痕迹 (02)
-- 帮派战结算 / 经济异常 / 首位成就 → 记录 → 编年史 + Discord推送
CREATE TABLE IF NOT EXISTS `world_events` (
    `id`            INT AUTO_INCREMENT PRIMARY KEY,
    `event_type`    VARCHAR(32)  NOT NULL  COMMENT '事件类型: territory_changed, economic_anomaly, achievement_first',
    `severity`      ENUM('minor','notable','major','legendary') NOT NULL DEFAULT 'minor',
    `title`         VARCHAR(255) NOT NULL  COMMENT '事件标题',
    `description`   TEXT         NULL      COMMENT '详细描述',
    `participants`  JSON         NULL      COMMENT '参与者 [{citizenid, role}, ...]',
    `location`      VARCHAR(128) NULL      COMMENT '发生地点',
    `outcome`       JSON         NULL      COMMENT '事件结果',
    `duration_sec`  INT          NULL      COMMENT '持续时间 (秒)',
    `triggered_by`  VARCHAR(64)  NULL      COMMENT '触发者 citizenid',
    `timestamp`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_type_time`    (`event_type`, `timestamp`),
    INDEX `idx_severity`     (`severity`, `timestamp`),
    INDEX `idx_triggered_by` (`triggered_by`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='世界事件 — 全服可见的叙事节点，驱动编年史和上线通知';

-- ── 3. trust_graph — 信任图 ──────────────────────────────────────────────
-- 锚点: 不可替代性与声誉 (03-irreplaceability-reputation.md)
-- 玩家间互评 → 7天交互门槛 → 同IP检测 → 每人每天最多3条
CREATE TABLE IF NOT EXISTS `trust_graph` (
    `id`            INT AUTO_INCREMENT PRIMARY KEY,
    `from_citizen`  VARCHAR(64)  NOT NULL  COMMENT '评价者 citizenid',
    `to_citizen`    VARCHAR(64)  NOT NULL  COMMENT '被评价者 citizenid',
    `category`      VARCHAR(32)  NOT NULL  COMMENT '信任类别: reliability, combat, trade, teaching',
    `weight`        FLOAT        NOT NULL  COMMENT '信任权重 [-1.0, 1.0]',
    `reason_event`  VARCHAR(255) NULL      COMMENT '关联事件 (帮派战ID / 交易记录ID)',
    `created_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY `idx_trust_edge` (`from_citizen`, `to_citizen`, `category`),
    INDEX  `idx_to_citizen`     (`to_citizen`),
    INDEX  `idx_category`       (`category`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='信任图 — 玩家间互评，声誉系统的数据基础';

-- ── 4. patron_records — Patron 月供记录 ───────────────────────────────────
-- 锚点: 付费模型 (06-payment-model.md)
-- 支付回调写入 · 服务端只读 · 客户端不可触达
CREATE TABLE IF NOT EXISTS `patron_records` (
    `id`            INT AUTO_INCREMENT PRIMARY KEY,
    `citizenid`     VARCHAR(64)  NOT NULL UNIQUE COMMENT '养服人 citizenid',
    `tier`          INT          NOT NULL DEFAULT 0  COMMENT '月供等级: 0/1/2/3',
    `started_at`    TIMESTAMP    NULL      COMMENT '当前周期开始',
    `expires_at`    TIMESTAMP    NULL      COMMENT '当前周期到期',
    `external_id`   VARCHAR(128) NULL      COMMENT '支付平台外部ID (对账)',
    `created_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX `idx_tier`     (`tier`),
    INDEX `idx_expires`  (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Patron 月供 — 支付回调写入，服务端只读，客户端不可触达';

-- ── 5. governance_proposals — 共治提案 ────────────────────────────────────
-- 锚点: 共治系统 (04-co-governance.md)
-- 完整生命周期: draft → cosigning → voting → passed/rejected/executed/vetoed
CREATE TABLE IF NOT EXISTS `governance_proposals` (
    `id`              INT AUTO_INCREMENT PRIMARY KEY,
    `scope`           ENUM('organization','server') NOT NULL COMMENT '作用域',
    `scope_id`        VARCHAR(64)  NULL      COMMENT '组织ID (scope=organization时)',
    `proposal_type`   VARCHAR(32)  NOT NULL  COMMENT '提案类型: rule_change, leadership, budget, alliance',
    `title`           VARCHAR(255) NOT NULL  COMMENT '提案标题',
    `description`     TEXT         NOT NULL  COMMENT '提案描述',
    `proposed_by`     VARCHAR(64)  NOT NULL  COMMENT '提案人 citizenid',
    `proposed_at`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `required_cosign` INT          NOT NULL DEFAULT 0  COMMENT '所需联署人数',
    `cosigners`       JSON         NULL      COMMENT '联署人 [{citizenid, at}, ...]',
    `status`          ENUM('draft','cosigning','voting','passed','rejected','executed','vetoed') NOT NULL DEFAULT 'draft',
    `voting_start`    TIMESTAMP    NULL      COMMENT '投票开始时间',
    `voting_end`      TIMESTAMP    NULL      COMMENT '投票截止时间',
    `votes_for`       INT          NOT NULL DEFAULT 0,
    `votes_against`   INT          NOT NULL DEFAULT 0,
    `vote_details`    JSON         NULL      COMMENT '{citizenid: vote, ...}',
    `execution_fn`    VARCHAR(64)  NULL      COMMENT '执行函数名 (白名单校验)',
    `execution_args`  JSON         NULL      COMMENT '执行参数',
    `executed_at`     TIMESTAMP    NULL      COMMENT '执行时间',
    INDEX `idx_scope`       (`scope`, `scope_id`),
    INDEX `idx_status`      (`status`),
    INDEX `idx_proposed_by` (`proposed_by`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='共治提案 — 完整生命周期管理，提案-投票-自动执行';

-- ── 6. skill_ranks — 技能位阶 ─────────────────────────────────────────────
-- 锚点: 不可替代性与声誉 (03-irreplaceability-reputation.md)
-- 容量限制 + 挑战/晋升机制
CREATE TABLE IF NOT EXISTS `skill_ranks` (
    `id`            INT AUTO_INCREMENT PRIMARY KEY,
    `skill_name`    VARCHAR(32)  NOT NULL  COMMENT '技能名: mechanic_engine, surgeon, weapon_craft',
    `citizenid`     VARCHAR(64)  NOT NULL  COMMENT '持有者',
    `rank`          ENUM('apprentice','journeyman','expert','master') NOT NULL,
    `achieved_at`   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `rank_score`    FLOAT        NOT NULL DEFAULT 0  COMMENT '位阶分数 (升级依据)',
    `is_active`     BOOLEAN      NOT NULL DEFAULT TRUE COMMENT '是否当前持有 (降级时旧记录 deactivate)',
    INDEX `idx_skill_rank`   (`skill_name`, `rank`),
    INDEX `idx_citizenid`    (`citizenid`),
    INDEX `idx_active_skill` (`citizenid`, `skill_name`, `is_active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='技能位阶 — 容量限制 + 挑战晋升，驱动不可替代性';

-- ── 7. cosmetic_items — 外观物品目录 ──────────────────────────────────────
-- 锚点: 付费模型 (06-payment-model.md)
-- 仅管理员写入 · 绑成就 · 卖美观不卖数值
CREATE TABLE IF NOT EXISTS `cosmetic_items` (
    `id`                  INT AUTO_INCREMENT PRIMARY KEY,
    `item_id`             VARCHAR(64)  NOT NULL UNIQUE COMMENT '外观物品ID',
    `item_name`           VARCHAR(128) NOT NULL  COMMENT '显示名称',
    `item_type`           VARCHAR(32)  NOT NULL  COMMENT '类型: badge, name_color, outfit, vehicle_skin',
    `required_achievement` VARCHAR(64) NULL      COMMENT '前置成就 — 必须真实达成才可购买',
    `price_cny`           INT          NOT NULL  COMMENT '人民币价格 (分)',
    `is_permanent`        BOOLEAN      NOT NULL DEFAULT TRUE,
    `created_at`          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_type`      (`item_type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='外观物品目录 — 只卖美观，绑定成就，不卖数值优势';

-- ── 8. player_cosmetics — 玩家已购外观 ────────────────────────────────────
CREATE TABLE IF NOT EXISTS `player_cosmetics` (
    `id`            INT AUTO_INCREMENT PRIMARY KEY,
    `citizenid`     VARCHAR(64)  NOT NULL,
    `item_id`       VARCHAR(64)  NOT NULL,
    `purchased_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `equipped`      BOOLEAN      NOT NULL DEFAULT FALSE COMMENT '当前是否装备',
    `frozen`        BOOLEAN      NOT NULL DEFAULT FALSE COMMENT '冻结 (违规惩罚)',
    UNIQUE KEY `idx_player_item` (`citizenid`, `item_id`),
    INDEX  `idx_equipped`       (`citizenid`, `equipped`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='玩家已购外观 — 成就验证后购买，冻结机制用于违规惩罚';

-- ── 9. organization_rules — 组织自定规则 ──────────────────────────────────
-- 锚点: 共治系统 (04-co-governance.md)
-- 帮派/企业可自定义内部规则，通过提案系统修改
CREATE TABLE IF NOT EXISTS `organization_rules` (
    `id`                INT AUTO_INCREMENT PRIMARY KEY,
    `org_id`            VARCHAR(64)  NOT NULL  COMMENT '组织ID (gang_id 或 job_id)',
    `rule_key`          VARCHAR(64)  NOT NULL  COMMENT '规则键: tax_rate, entry_requirement, ally_list',
    `rule_value`        JSON         NOT NULL  COMMENT '规则值 (灵活JSON)',
    `changed_by_proposal` INT         NULL      COMMENT '修改来源提案ID (可追溯)',
    `changed_at`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY `idx_org_rule` (`org_id`, `rule_key`),
    INDEX  `idx_org_id`       (`org_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='组织自定规则 — 通过共治提案系统修改，玩家从消费者变主人';

-- ============================================================================
-- 迁移验证查询 (执行后使用)
-- ============================================================================
-- SHOW TABLES LIKE 'world_%';
-- SHOW TABLES LIKE 'trust_%';
-- SHOW TABLES LIKE 'patron_%';
-- SHOW TABLES LIKE 'governance_%';
-- SHOW TABLES LIKE 'skill_%';
-- SHOW TABLES LIKE 'cosmetic_%';
-- SHOW TABLES LIKE 'organization_%';
-- SELECT COUNT(*) AS tables_added FROM information_schema.TABLES
--   WHERE TABLE_SCHEMA = 'TCityLite'
--     AND TABLE_NAME IN ('world_state','world_events','trust_graph','patron_records','governance_proposals','skill_ranks','cosmetic_items','player_cosmetics','organization_rules');
-- ============================================================================
