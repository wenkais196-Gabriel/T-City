-- v3.14 — police_evidence 增加 subject_citizenid（P4 证据收口）
--
-- 盘查（酒测/药检）发生在立案之前：那时还没有 case 可挂，但读数是证据。
-- 有了 subject，就能先把读数落成"待挂载证据"（case_id 为空），立案后再绑定，
-- 证据链仍然只追加（绑定写一条 bound_to_case，不 UPDATE 链表）。
--
-- 纯增量：列可空，旧行 NULL；幂等：判列是否存在。

SET @needs_col := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = DATABASE()
       AND TABLE_NAME = 'police_evidence'
       AND COLUMN_NAME = 'subject_citizenid'
);

SET @ddl := IF(@needs_col = 0,
    'ALTER TABLE police_evidence ADD COLUMN subject_citizenid varchar(50) DEFAULT NULL AFTER location, ADD KEY idx_subject (subject_citizenid, case_id)',
    'DO 0');

PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
