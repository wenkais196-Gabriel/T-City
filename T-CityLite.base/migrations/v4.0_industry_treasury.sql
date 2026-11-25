-- v4.0_industry_treasury.sql — S1 组织金库（industry treasury）。
--
-- 三张表的分工：
--   org_treasury   每个组织一行：余额 / 声望 / 周期号。余额的**唯一**写入口是
--                  custom-industry 的 Treasury.*；扣减守卫写在 UPDATE 的 WHERE 里
--                  （`balance + ? >= 0`），不在 Lua 里先读后写。
--   org_ledger     只追加的流水。UNIQUE(org_id, ref) 是幂等键：同一个 ref 第二次
--                  入账必须被数据库拒绝，而不是靠调用方自觉。
--   industry_audit 操作审计（成功与拒绝都记）。payload 只放金额 / 结果码 / ref，
--                  不放玩家姓名、车牌、坐标等 PII。
--
-- Idempotent: CREATE TABLE IF NOT EXISTS，可重复执行。
--
-- 上游设计：docs/server-design/12-industry-operations.md §8；
-- 施工计划：docs/plan/industry-ops/01-plan.md（P1）。

CREATE TABLE IF NOT EXISTS `org_treasury` (
  `org_id` varchar(64) NOT NULL,
  `balance` bigint(20) NOT NULL DEFAULT 0,
  `prestige` int(11) NOT NULL DEFAULT 0,
  `cycle_no` int(11) NOT NULL DEFAULT 0,
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`org_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `org_ledger` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `org_id` varchar(64) NOT NULL,
  `delta` bigint(20) NOT NULL,
  `balance_after` bigint(20) NOT NULL,
  `reason` varchar(64) NOT NULL,
  `actor_cid` varchar(64) DEFAULT NULL,
  `ref` varchar(96) NOT NULL,
  `cycle_no` int(11) NOT NULL DEFAULT 0,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_org_ref` (`org_id`,`ref`),
  KEY `idx_org_created` (`org_id`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `industry_audit` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `org_id` varchar(64) NOT NULL,
  `actor_cid` varchar(64) DEFAULT NULL,
  `action` varchar(48) NOT NULL,
  `payload` longtext DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_org_created` (`org_id`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
