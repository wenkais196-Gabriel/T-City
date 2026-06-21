-- ============================================================================
-- DB Migration v2.0: 三位一体架构 Schema 重构
-- ============================================================================
-- 执行方式: 在 MySQL 中按顺序执行以下语句 (可重复执行, 使用 IF NOT EXISTS)
-- 向后兼容: 不删除任何旧列, 仅新增独立列 + 索引
-- ============================================================================

-- ── 第一阶段: players 表新增三位一体独立字段 ──────────────────────────

-- 1. qualifications 独立 JSON 列 (从 metadata 中提升为一级公民)
--    结构: {"police_heli_pilot": true, "advanced_surgery": true, ...}
ALTER TABLE `players`
  ADD COLUMN IF NOT EXISTS `qualifications` JSON NULL
  COMMENT '三位一体第三维度: 专业技术通行证, 跨阵营独立于职业和等级'
  AFTER `gang`;

-- 2. 资质索引 (支持 GetPlayersByQualification 查询)
ALTER TABLE `players`
  ADD INDEX IF NOT EXISTS `idx_qualifications` ((CAST(`qualifications` AS CHAR(256))));

-- ── 第二阶段: 房产税懒加载时间戳 ──────────────────────────────────────

-- 3. player_houses 表新增 tax 字段
ALTER TABLE `player_houses`
  ADD COLUMN IF NOT EXISTS `last_tax_paid` INT UNSIGNED NULL
  COMMENT '上次房产税缴纳时间 (Unix timestamp), 用于懒加载扣费'
  AFTER `citizenid`;

ALTER TABLE `player_houses`
  ADD COLUMN IF NOT EXISTS `delinquent_count` TINYINT UNSIGNED NOT NULL DEFAULT 0
  COMMENT '连续欠费次数, 达到阈值触发充公'
  AFTER `last_tax_paid`;

ALTER TABLE `player_houses`
  ADD INDEX IF NOT EXISTS `idx_tax` (`citizenid`, `last_tax_paid`);

-- ── 第三阶段: 车辆保险/大修时间戳 ─────────────────────────────────────

-- 4. player_vehicles 表新增 lifecycle 字段
ALTER TABLE `player_vehicles`
  ADD COLUMN IF NOT EXISTS `last_insurance_paid` INT UNSIGNED NULL
  COMMENT '上次保险缴纳时间 (Unix timestamp)'
  AFTER `depotprice`;

ALTER TABLE `player_vehicles`
  ADD COLUMN IF NOT EXISTS `current_mileage` INT UNSIGNED NOT NULL DEFAULT 0
  COMMENT '当前累计里程 (km), 用于触发引擎大修'
  AFTER `last_insurance_paid`;

ALTER TABLE `player_vehicles`
  ADD INDEX IF NOT EXISTS `idx_insurance` (`citizenid`, `last_insurance_paid`);

-- ── 第四阶段: 经济数据持久化表 ────────────────────────────────────────

-- 5. 经济仪表盘快照表 (每周自动写入)
CREATE TABLE IF NOT EXISTS `economy_snapshots` (
  `id` INT AUTO_INCREMENT PRIMARY KEY,
  `week_start` DATE NOT NULL,
  `total_inflow` BIGINT NOT NULL DEFAULT 0,
  `total_outflow` BIGINT NOT NULL DEFAULT 0,
  `total_sink` BIGINT NOT NULL DEFAULT 0,
  `vehicle_count` INT NOT NULL DEFAULT 0,
  `house_count` INT NOT NULL DEFAULT 0,
  `global_multiplier` DECIMAL(4,2) NOT NULL DEFAULT 1.00,
  `hot_activities` JSON NULL,
  `generated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX `idx_week` (`week_start`)
) ENGINE=InnoDB;

-- 6. NPC 动态价格持久化表
CREATE TABLE IF NOT EXISTS `npc_prices` (
  `item_name` VARCHAR(64) PRIMARY KEY,
  `demand` INT NOT NULL DEFAULT 0,
  `supply` INT NOT NULL DEFAULT 1,
  `base_price` INT NOT NULL DEFAULT 0,
  `last_updated` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ── 第五阶段: 数据迁移 (将旧数据填充到新列) ───────────────────────────

-- 7. 从 metadata JSON 中提取 qualifications 到独立列 (如果存在)
UPDATE `players`
SET `qualifications` = JSON_EXTRACT(`metadata`, '$.qualifications')
WHERE `qualifications` IS NULL
  AND JSON_EXTRACT(`metadata`, '$.qualifications') IS NOT NULL;

-- 8. 为所有现有房产初始化 last_tax_paid (设为当前时间, 避免登录即扣税)
UPDATE `player_houses`
SET `last_tax_paid` = UNIX_TIMESTAMP()
WHERE `last_tax_paid` IS NULL
  AND `citizenid` IS NOT NULL;

-- 9. 为所有现有车辆初始化 last_insurance_paid
UPDATE `player_vehicles`
SET `last_insurance_paid` = UNIX_TIMESTAMP()
WHERE `last_insurance_paid` IS NULL;
