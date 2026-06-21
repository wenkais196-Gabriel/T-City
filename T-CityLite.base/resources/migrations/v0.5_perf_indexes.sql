-- =============================================================
-- T-City Lite v0.5 数据库迁移脚本
-- 优化性能：添加缺失索引 + 虚拟列
-- =============================================================

-- 1. phone_tweets.date 索引 — 加速推文按时间加载
ALTER TABLE `phone_tweets` 
    ADD INDEX `idx_date` (`date`) 
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.statistics 
        WHERE table_name = 'phone_tweets' AND index_name = 'idx_date'
    );

-- 2. bank_statements.date 索引 — 加速账单流水查询
ALTER TABLE `bank_statements` 
    ADD INDEX `idx_date` (`date`)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.statistics 
        WHERE table_name = 'bank_statements' AND index_name = 'idx_date'
    );

-- 3. bank_statements.statement_type 索引 — 加速按类型过滤
ALTER TABLE `bank_statements` 
    ADD INDEX `idx_type` (`statement_type`)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.statistics 
        WHERE table_name = 'bank_statements' AND index_name = 'idx_type'
    );

-- 4. players 表 phone_number 虚拟列 + 索引
-- 替换所有 charinfo LIKE '%phone%' 全表扫描
ALTER TABLE `players`
    ADD COLUMN `phone_number` VARCHAR(20) GENERATED ALWAYS AS 
        (JSON_UNQUOTE(JSON_EXTRACT(`charinfo`, '$.phone'))) VIRTUAL
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'players' AND column_name = 'phone_number'
    );

ALTER TABLE `players`
    ADD INDEX `idx_phone` (`phone_number`)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.statistics 
        WHERE table_name = 'players' AND index_name = 'idx_phone'
    );

-- 5. houselocations.name 索引 — 加速街道门牌号查询
ALTER TABLE `houselocations`
    ADD INDEX `idx_name` (`name`)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.statistics 
        WHERE table_name = 'houselocations' AND index_name = 'idx_name'
    );

-- 6. phone_messages 补充索引 — 加速按接收者查询
ALTER TABLE `phone_messages`
    ADD INDEX `idx_receiver_sender` (`receiver_number`, `sender_number`)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.statistics 
        WHERE table_name = 'phone_messages' AND index_name = 'idx_receiver_sender'
    );

-- 7. player_vehicles.citizenid 索引确认
ALTER TABLE `player_vehicles`
    ADD INDEX `idx_citizenid` (`citizenid`)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.statistics 
        WHERE table_name = 'player_vehicles' AND index_name = 'idx_citizenid'
    );
