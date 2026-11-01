---
id: police-plans-2026-10-31-p4-evidence-binding
type: plan
status: active
system: justice
owner: hermes
updated: 2026-10-31
review_by: 2027-04-30
---

# P4 证据收口：盘查读数延迟绑定（研究与施工图）

> 目标：酒测/药检的读数**不再读完就散**，能随后续立案挂到案卷上，并且保持证据链只增不改。

## 1. 现状（代码查证）

| 事实 | 位置 |
|---|---|
| `insertEvidence` **强制要求** `incident_id` / `report_id` / `case_id` 三者至少一个 | `custom-police/server/p2_evidence.lua:56` → `missing_case` |
| `police_evidence` 表里 `case_id` 本来就允许 NULL，且**没有** `subject_citizenid` 列 | fixture `police_evidence` |
| 盘查读数目前只写 `police_audit`，返回 `evidence=false` | `custom-police/server/interactions.lua` 的 `police:server:fieldTest` |
| 证据链 `police_evidence_chain` 只追加，无 UPDATE 路径（AC-P4-02） | `p2_evidence.lua` |

矛盾点：盘查发生在**立案之前**，那时没有 case/incident 可挂；但读数本身是证据，应该留。

## 2. 方案对比

| 方案 | 做法 | 代价 | 结论 |
|---|---|---|---|
| A. 放宽 `missing_case`，允许裸行 | 无父证据先落库，`case_id=NULL` | 但表里没有"这是谁的读数"的字段，`description` 里塞 cid 不好查、也不好校验 | ✗ 不可靠 |
| **B. 加一列 `subject_citizenid` + `BindEvidence`**（本方案） | 读数落成"待挂载证据"（有 subject、无 case）；立案后按 subject 匹配、绑定到 case，链上追加一行 | 动表（**L4**，但纯增量：加一列 + 一个索引，旧行 NULL 不受影响） | ✓ |
| C. 新建 `police_pending_evidence` 表 | 完全隔离 | 多一张表、多一个写者、绑定后还要删/迁 | ✗ 重 |

选 **B**。

## 3. 变更清单

### 3.1 迁移（幂等）

`T-CityLite.base/migrations/v3.14_police_evidence_subject.sql`

```sql
-- 待挂载证据需要知道"是谁的读数"
ALTER TABLE police_evidence
  ADD COLUMN subject_citizenid varchar(50) DEFAULT NULL AFTER location,
  ADD KEY idx_subject (subject_citizenid, case_id);
```

用 `information_schema.COLUMNS` 判列是否已存在，再 `PREPARE/EXECUTE`；fixture 同步。

### 3.2 服务端

`custom-police/server/p2_evidence.lua`

| 改动 | 说明 |
|---|---|
| `insertEvidence` 接受 `subject_citizenid` | 写库时带上 |
| **放宽父级要求**：有 `subject_citizenid` 时允许 `case_id/incident_id/report_id` 全空 | 这类行是"待挂载"（`status='collected'`），只由系统路径写 |
| 新增 `M.BindEvidence(actor, evidenceId, caseId)` | 校验：警察 + `PolicePolicy.Can(actor,'evidence.bind')`、证据存在、**尚未绑定**、案卷存在、`subject` 与案卷 `lead_citizenid`/裁定主体一致（不一致需 `force=true` 且写审计）；成功后 `UPDATE case_id` + 链上追加 `bound_to_case` |

### 3.3 盘查读数

`police:server:fieldTest` 改为：

1. 计算分档；
2. 调 `Evidence.FieldTest(...)` 写一条待挂载证据（`label='fieldtest:alcohol'`，`description` 带读数/档位/时间）；
3. 返回 `evidence_id`（此前是 `false`）。

### 3.4 立案后绑定

- 逮捕表单提交时（`RegisterArrest` / `InsertReport` 之后），若该 citizen 有未绑定读数 → 自动挂到新建的 case 上，链上记 `auto_bound`；
- MDT 证据页加一个"挂载"入口（手动兜底，带 subject 不匹配提示）。

### 3.5 验收判据

| 编号 | 判据 |
|---|---|
| AC-P4-07 | 盘查后 `police_evidence` 出现一行 `subject_citizenid` 非空、`case_id` 为空、`label='fieldtest:*'` |
| AC-P4-08 | 立案后同一行 `case_id` 被填上，链上多一条 `bound_to_case/auto_bound` |
| AC-P4-09 | 已绑定的证据再次绑定 MUST 被拒（`already_bound`） |
| AC-P4-10 | subject 与案卷不匹配时 MUST 需要 `force=true` 并写审计 |
| AC-P4-11 | 没有 subject 的普通证据仍按旧规则要求父级（不许绕过） |

## 4. 风险与回滚

| 风险 | 处置 |
|---|---|
| 加列影响旧查询 | 列可空、无默认值，所有 `SELECT` 都显式列名，不受影响 |
| 自动绑定绑错人 | 只按**精确 citizenid** 匹配；案卷主体不一致则不绑，留给人工 |
| 回滚 | 先删 `fieldtest:*` 待挂载行，再 `ALTER TABLE police_evidence DROP COLUMN subject_citizenid` |

## 5. 施工顺序

1. 迁移 v3.14 + fixture 同步（**L4：需人审**，本条已在计划里写明）
2. `insertEvidence` 支持 subject / 待挂载；`BindEvidence`
3. `fieldTest` 写证据并返回 id
4. 立案自动绑定
5. 闸门 AC-P4-07…11
6. 真机：盘查 → 立案 → 证据页/DB 可见绑定

## 6. 实施记录（2026-10-31）

| 项 | 结果 |
|---|---|
| 迁移 v3.14 | 已应用到 `tcity-mariadb`，`subject_citizenid` 列存在；**重复执行 rc=0**（幂等） |
| fixture | `police_evidence` 增列 + `idx_subject` 同步 |
| `insertEvidence` | 有 subject 时允许无父级（`missing_case` 只在没有 subject 时触发）—— 普通采集仍不能绕过 |
| `EV.BindEvidence` | 只改 `case_id`；`WHERE case_id IS NULL` 保证不重复绑；链由 `chain()` 追加，全程无 `UPDATE police_evidence_chain` |
| `EV.BindPendingFor` | 立案后按精确 citizenid 匹配，命中行绑到新案卷并写 `auto_bound` |
| `police:server:fieldTest` | 无在办警情时写待挂载证据，返回 `pending=true` 与 `exhibit_no` |
| `C.CreateCase` | 建案成功后 `pcall` 调 `BindPendingFor`，失败不阻断立案 |
| 闸门 | 6 条（AC-P4-07..11 + 迁移幂等），全绿 |
| 真机 | `restart custom-police` → SCRIPT ERROR 新增 **0**；迁移幂等已验证 |

### 6.1 还没验的（需要两个玩家）

盘查 → 立案的**完整动线**需要：目标先喝酒 → 警员近距离酒测 → 警员立案。
单客户端无法一次性演完，已列入 STATUS §4 的多机验收清单。
