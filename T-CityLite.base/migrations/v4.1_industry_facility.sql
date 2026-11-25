-- v4.1_industry_facility.sql — S2 设施 / 工位 / 库存（industry facility）。
--
-- 一组织一设施：org_id 是主键。level / workstations / stock 都在这一行上；
-- 本片只允许「建设施 / 雇工位」，不跑生产（stock 恒为 0）。
--
-- workstations 的并发推进形状与 S1 余额守卫一致：
--   UPDATE industry_facility
--      SET workstations = workstations + 1
--    WHERE org_id = ? AND workstations = ? AND workstations < ?
-- 上限与乐观锁都在同一条 UPDATE 里，affectedRows 是唯一裁决依据。
--
-- Idempotent: CREATE TABLE IF NOT EXISTS，可重复执行。
--
-- 上游设计：docs/server-design/12-industry-operations.md §8/§11；
-- 施工计划：docs/plan/industry-ops/02-plan.md（Q1）。

CREATE TABLE IF NOT EXISTS `industry_facility` (
  `org_id` varchar(64) NOT NULL,
  `facility_type` varchar(48) NOT NULL,
  `level` int(11) NOT NULL DEFAULT 1,
  `workstations` int(11) NOT NULL DEFAULT 0,
  `recipe_id` varchar(48) DEFAULT NULL,
  `stock` bigint(20) NOT NULL DEFAULT 0,
  `last_tick_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`org_id`),
  KEY `idx_facility_type` (`facility_type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
