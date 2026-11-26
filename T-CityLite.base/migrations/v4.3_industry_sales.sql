-- v4.3_industry_sales.sql — S4 销售 / 配额（industry demand & sales）。
--
-- 两张表的分工：
--   industry_demand  全服共享的城市需求（S4 用占位周期 cycle_no=0 / phase='static'；
--                    S6 接周期状态机时只改这两列的值，不动 schema）。
--                    quota_used 与 quota_total 的守卫写在 Lua 的 CAS UPDATE 里。
--   industry_sales   卖单流水。UNIQUE(org_id, ref) 是幂等键：同一个 ref 第二次
--                    卖出必须被数据库拒绝。组织累计销量（50% 上限）从这张表 SUM。
--
-- S4 是全仓第一个「无对应玩家扣款」的净增货币点，所以两张表缺一不可：
-- 需求行限制总量，卖单行提供幂等与对账。收入本身进 org_treasury（Treasury.Deposit，
-- ref = 'sale:' .. sale_id），不在这两张表里存余额。
--
-- 种子行：migration 固定插一条 cycle 0 / static / iron_ore / 10 的默认行；
-- 资源启动时 IndustrySales.EnsureSeed() 会用 convar industry_demand_seed 校准
-- quota_total（仅当 quota_used = 0 时覆盖）。这不新增调度，只是启动时一次 UPSERT。
--
-- Idempotent: CREATE TABLE IF NOT EXISTS + INSERT IGNORE，可重复执行。
--
-- 上游设计：docs/server-design/12-industry-operations.md §8/§9；
-- 施工单元：#336。

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
