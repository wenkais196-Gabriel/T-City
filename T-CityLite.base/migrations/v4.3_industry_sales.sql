-- v4.3_industry_sales.sql — S4 销售 / 配额（industry demand & sales）。
--
-- 两张表的分工：
--   industry_demand  全服共享的城市需求（S4 用占位周期 cycle_no=0 / phase='static'；
--                    S6 接周期状态机时只改这两列的值，不动 schema）。
--                    quota_used 与 quota_total 的守卫写在 Lua 的 CAS UPDATE 里。
--   industry_sales   卖单流水。UNIQUE(org_id, ref) 是幂等键：同一个 ref 第二次
--                    卖出必须被数据库拒绝。组织累计销量（50% 上限）从这张表 SUM。
--
-- **配额是每阶段的**（#408）：单组织上限 = 当阶段 quota_total × 50%，不是「全周期累计」。
-- 因此 `industry_sales` 必须带 `(cycle_no, phase, season)` 维度 —— 组织累计、全服对账、
-- 配额 CAS 子查询都按当前阶段求和；否则扩张期卖满会把后三阶段锁死，且对账会把
-- 上一阶段流水回填进当前阶段的 quota_used。`season` 为 P1 两时钟预留，当前恒 0。
--
-- S4 是全仓第一个「无对应玩家扣款」的净增货币点，所以两张表缺一不可：
-- 需求行限制总量，卖单行提供幂等与对账。收入本身进 org_treasury（Treasury.Deposit，
-- ref = 'sale:' .. sale_id），不在这两张表里存余额。
--
-- 种子行：migration 固定插一条 cycle 0 / static / iron_ore / 10 的默认行；
-- 资源启动时 IndustrySales.EnsureSeed() 会用 convar industry_demand_seed 校准
-- quota_total（仅当 quota_used = 0 时覆盖）。这不新增调度，只是启动时一次 UPSERT。
--
-- 历史行：v4.3 初版建的库没有 phase/season，补列时默认 `phase='legacy'` / `season=0`。
-- 不回填历史数据 —— MVP 只有两个组织，legacy 行不参与任何真实阶段的 50% 累计；
-- 新写入一律显式带当前 (phase, season)。
--
-- Idempotent: CREATE TABLE IF NOT EXISTS + INSERT IGNORE + information_schema 补列，
-- 可重复执行（老库连跑两次是 no-op）。
--
-- 上游设计：docs/server-design/12-industry-operations.md §8/§9；
-- 施工单元：#336；配额维度修正：#408。

CREATE TABLE IF NOT EXISTS `industry_demand` (
  `cycle_no` int(11) NOT NULL DEFAULT 0,
  `phase` varchar(24) NOT NULL DEFAULT 'static',
  `item_name` varchar(64) NOT NULL,
  `quota_total` int(11) NOT NULL DEFAULT 0,
  `quota_used` int(11) NOT NULL DEFAULT 0,
  PRIMARY KEY (`cycle_no`,`phase`,`item_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `industry_sales` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `org_id` varchar(64) NOT NULL,
  `cycle_no` int(11) NOT NULL DEFAULT 0,
  -- 卖单归属的阶段/季节。老库由下面的 information_schema 补列（默认 legacy/0）；
  -- 新建库直接带这两列。任何真实卖单都必须显式写入当前值。
  `phase` varchar(24) NOT NULL DEFAULT 'legacy',
  `season` int(11) NOT NULL DEFAULT 0,
  `item_name` varchar(64) NOT NULL,
  `qty` int(11) NOT NULL,
  `unit_price` bigint(20) NOT NULL,
  `revenue` bigint(20) NOT NULL,
  `ref` varchar(96) NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_org_ref` (`org_id`,`ref`),
  KEY `idx_org_cycle_item` (`org_id`,`cycle_no`,`item_name`),
  KEY `idx_cycle_item` (`cycle_no`,`item_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT IGNORE INTO `industry_demand` (`cycle_no`, `phase`, `item_name`, `quota_total`, `quota_used`)
VALUES (0, 'static', 'iron_ore', 10, 0);

-- ── 老库补列（v4.3 初版的 industry_sales 没有 phase/season）──────────────
-- MySQL 8 没有 `ADD COLUMN IF NOT EXISTS`，沿用 v3.10 / v2.1 的
-- information_schema + PREPARE/EXECUTE 幂等形状：连跑两次是 no-op。
-- ADD COLUMN 带 DEFAULT，已有的历史行因此自动填 'legacy' / 0。
SET @has_phase := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_sales'
      AND COLUMN_NAME = 'phase'
);
SET @sql_phase := IF(@has_phase = 0,
    'ALTER TABLE industry_sales ADD COLUMN phase VARCHAR(24) NOT NULL DEFAULT ''legacy'' AFTER cycle_no',
    'DO 0');
PREPARE stmt_phase FROM @sql_phase;
EXECUTE stmt_phase;
DEALLOCATE PREPARE stmt_phase;

SET @has_season := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'industry_sales'
      AND COLUMN_NAME = 'season'
);
SET @sql_season := IF(@has_season = 0,
    'ALTER TABLE industry_sales ADD COLUMN season INT(11) NOT NULL DEFAULT 0 AFTER phase',
    'DO 0');
PREPARE stmt_season FROM @sql_season;
EXECUTE stmt_season;
DEALLOCATE PREPARE stmt_season;
