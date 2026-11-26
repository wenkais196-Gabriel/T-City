-- v4.4_industry_cycle.sql — S6 周期状态机 + S7 结算转生。
--
-- 两张表的分工：
--   industry_state          周期权威状态，**单行表**（CHECK id = 1）。为什么不住
--                           `world_state`：后者唯一键是 (region_id, state_key)，全局周期
--                           不属于任何 region，且 GetRegionState 冷缓存返回 nil —— 权威
--                           状态不能靠可能为空的读（设计 §2 第 4 行）。
--                           phase_* 用 datetime 存**绝对时间**；Lua 侧统一用
--                           UNIX_TIMESTAMP() / FROM_UNIXTIME(?) 进出，避免时区解释分叉。
--                           种子行是 'uninitialized'：Lua 首次启动时按 convar 压缩后的
--                           时长写入真正的时间边界；重启不会重新校准（从 DB 续跑）。
--   industry_cycle_results  每组织每周期的结算结果。**UNIQUE(org_id, cycle_no)** 是
--                           结算幂等键。`applied` 标记「清分 + prestige 已落地」，
--                           崩溃后重试靠它续跑；prestige_after 是**绝对值**，重试只可能
--                           写同一个值，不会重复累加。
--
-- Idempotent: CREATE TABLE IF NOT EXISTS + INSERT IGNORE，可重复执行。
--
-- 上游设计：docs/server-design/12-industry-operations.md §5/§8/§12；
-- 施工单元：#338。

CREATE TABLE IF NOT EXISTS `industry_state` (
  `id` tinyint(4) NOT NULL,
  `cycle_no` int(11) NOT NULL DEFAULT 0,
  `phase` varchar(24) NOT NULL DEFAULT 'uninitialized',
  `phase_started_at` datetime NOT NULL DEFAULT '1970-01-02 00:00:00',
  `phase_ends_at` datetime NOT NULL DEFAULT '1970-01-02 00:00:00',
  -- 结算前公告只发一次：成功发布后才写时间；NULL = 本周期还没发过。
  `warning_announced_at` datetime DEFAULT NULL,
  -- 已完成的结算周期 / 已发布的结算结果。两者都只增不减，Tick 用它们判断
  -- 「结算有没有跑完」「结果公告要不要补发」。
  `settled_cycle_no` int(11) NOT NULL DEFAULT 0,
  `result_announced_cycle` int(11) NOT NULL DEFAULT 0,
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  CONSTRAINT `chk_industry_state_single` CHECK (`id` = 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `industry_cycle_results` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `org_id` varchar(64) NOT NULL,
  `cycle_no` int(11) NOT NULL,
  -- 累计销售额（industry_sales.revenue 之和）与设施生命周期累计产出；
  -- stock 是设施表的一列，结算时随设施行一起删除，结果表保留快照。
  `revenue` bigint(20) NOT NULL DEFAULT 0,
  `produced_units` bigint(20) NOT NULL DEFAULT 0,
  `score` bigint(20) NOT NULL DEFAULT 0,
  `prestige_awarded` int(11) NOT NULL DEFAULT 0,
  `prestige_before` int(11) NOT NULL DEFAULT 0,
  `prestige_after` int(11) NOT NULL DEFAULT 0,
  -- 清分前的金库余额：清分要写一条 `settlement-clear` 流水，崩溃重试
  -- 靠这个快照补写（余额已经是 0 时不能再从表里读出来）。
  `balance_cleared` bigint(20) NOT NULL DEFAULT 0,
  -- 0 = 结果已算、清分尚未确认完成；1 = 该组织本周期结算完成。
  `applied` tinyint(1) NOT NULL DEFAULT 0,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `applied_at` timestamp NULL DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_org_cycle` (`org_id`,`cycle_no`),
  KEY `idx_cycle` (`cycle_no`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 首次启动由 Lua 写真实相位边界；这里只保证单行存在且形状合法。
INSERT IGNORE INTO `industry_state`
  (`id`, `cycle_no`, `phase`, `phase_started_at`, `phase_ends_at`)
VALUES (1, 0, 'uninitialized', '1970-01-02 00:00:00', '1970-01-02 00:00:00');
