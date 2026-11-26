-- v4.2_industry_production.sql — S3 惰性生产的累计埋点。
--
-- produced_units 是设施自建成以来的**累计产出**（不是当前库存：S4 卖出会扣 stock，
-- 但不回退这一列）。S7 结算用它算分，所以只增不减。
--
-- 库存上限与结算逻辑都在 Lua 的纯函数里；本迁移只补一列，不建新表。
--
-- Idempotent: ADD COLUMN IF NOT EXISTS，可重复执行。
--
-- 上游设计：docs/server-design/12-industry-operations.md §8/§10；
-- 施工单元：#335。

ALTER TABLE `industry_facility`
  ADD COLUMN IF NOT EXISTS `produced_units` bigint(20) NOT NULL DEFAULT 0;
