# 04 — 数据所有权（Data Ownership）

> 架构基线 agent C ｜ 只读 + 文档 ｜ 基线 `master`（2026-10-24）｜ 未改代码、未 commit、未触碰 FXServer。
>
> **证据路径口径**（同 [03-contracts.md](03-contracts.md)）：
> - `custom-*/*`、`qb-prison/*` 相对 `T-CityLite.base/resources/`
> - `migrations/*`、`tests/*` 相对 `T-CityLite.base/`
> - `tools/*` 相对仓库根
>
> 关联：[STATUS.md](../STATUS.md)、[TECH_DEBT.md](../TECH_DEBT.md)、[FLOW_INTERNAL.md](../FLOW_INTERNAL.md)、[B_PLAN.md](../B_PLAN.md)、[01-domain-model.md](01-domain-model.md)（聚合与不变量）、[02-state-machines.md](02-state-machines.md)（状态迁移）、[03-contracts.md](03-contracts.md)（契约面）、[07-fitness-tests.md](07-fitness-tests.md)（所有权检查）。
> 本文**不设计新表**，只描述"现状 + 目标边界"。所有"建议"都是所有权规则，不是 schema 变更。

---

## 0. 一页结论

| # | 结论 | 证据 |
|---|---|---|
| 1 | 12 张 `police_*` 表的唯一写者**在资源层是单一的**（全部由 `custom-police` 写），只有一处跨资源写：`custom-justice` 回写 `police_reports.justice_verdict` | `custom-police/server/{p0,p1,p2_evidence,p3_cases,p2_system}.lua`、`custom-justice/server/trial.lua:30-49` |
| 2 | 但有 **5 个概念没有单一事实源**：duty、custody、arrest 记录、wanted、罪名目录 | `TECH_DEBT.md:5-24`、`custom-police/server/p0.lua:210-232`、`custom-police/shared/charges.lua:1-6` |
| 3 | `phone_notifications` 有 **6 个写者文件**（`p0`/`p1`/`p2_system`/`police_mdt`/`main`/`qb_phone_compat`），其中 **5 个绕过 owner 的 `StoreNotification`**（缓存失效 + `app_id` 白名单） | `custom-phone/server/main.lua:223-262` vs `custom-police/server/{p0,p1,p2_system}.lua`、`custom-phone/server/apps/police_mdt.lua:259-264` |
| 4 | `players.job/metadata/money` 是 TEXT JSON（无列约束、无 FK），有 **7 个资源**直接写（qb-core 加 6 个非 owner，其中 `custom-career` 用裸 SQL）；宽度还和 `citizenid` 不一致（`varchar(11)` vs 业务表 `varchar(50)`） | `tests/fixtures/tcity_schema.sql:624-646`、`migrations/v2.8_police_p0.sql:7-8`、`tools/agent_tools.json:121-125` |
| 5 | 一致性策略**不统一**：同一个资源里既有 fail-closed 审计（读失败即拒绝），也有写完就忘（`audit` 结果被忽略） | `custom-police/server/p3_cases.lua:242-244` vs `custom-police/server/p2_system.lua:121`、`p0.lua:52` |
| 6 | 迁移链 `v2.8 → v3.7` 全部幂等，但 **fixture 里 0 张 `police_*` / `agent_actions` 表**，DB 集成测试不可能覆盖，CI 的 schema 检查也只认 7 张表 | `tests/fixtures/tcity_schema.sql`（grep 0 命中）、`tests/check_db_schema.py:15-49`、`TECH_DEBT.md:39-41` |

---

## 1. 所有权规则（目标边界，非新设计）

| 规则 | 内容 | 现状符合度 |
|---|---|---|
| R1 单写者 | 一张表只有一个写入资源；其他资源只能通过 export/事件请求写 | `police_*` ✅；`phone_notifications` ❌；`players.*` ❌（设计上多写者，但必须经 qb-core API） |
| R2 读也走接口 | 跨资源读默认走 export / live API / callback；**唯一允许的直读是 director live board 的列白名单**（登记为例外） | `custom-phone` ✅（全部走 export）；`custom-director` live board ⚠️ 登记例外（只读 `police_units`/`police_incidents` 的列白名单，`live_api.lua:484-492`） |
| R3 白名单例外 | 跨资源直写只允许登记在案的例外，且必须写明理由 | 仅 1 条：justice → `police_reports` verdict 投影（`trial.lua:39-48`） |
| R4 玩家数据唯一入口 | `players.job/metadata/money/inventory` 只能经 `Player.Functions.*`（或 `Bus.JobService`），禁止 SQL 直改 | ⚠️ 多数走 `Player.Functions`；`custom-career` 直接 `UPDATE players SET rank_tier/department/certs`（见 §4） |
| R5 内存态标注可丢 | 内存事实（justice cases/inmates、backup 槽位、冷却表）必须声明"允许丢失"，不得作为判决/服刑唯一依据 | ❌ justice 判决与服刑状态只在内存（`TECH_DEBT.md:25-28`） |
| R6 审计只追加 | 审计表 append-only；敏感读必须审计；禁止业务代码 UPDATE/DELETE 审计行 | ⚠️ append-only ✅；敏感读覆盖不全（§6） |

---

## 2. 单一事实源（Single Source of Truth）

| 概念 | 当前事实源 | 并存副本 | 判定 | 证据 |
|---|---|---|---|---|
| **duty（是否在勤）** | `players.job.onduty`（qb-core） | `police_units.status != 'off_duty'`；`police_units.status` 又被 MDT 单独写 | **无单源**：`OnJobUpdate` 单向同步到 `police_units`，MDT 只写后者不回写 `onduty` → `onduty=true + unit=off_duty` 合法存在 | `custom-police/server/p0.lua:262-280,294-309`、`TECH_DEBT.md:5-24` |
| **unit status / 派单** | `police_units.status` + `police_units.incident_id` | `police_incidents.status` 与 `police_units.status` 共享 `assigned/enroute/on_scene` 三个值 | 近强一致但非原子：一个动作两条 UPDATE | `custom-police/server/p0.lua:171-178`、`migrations/v2.8_police_p0.sql:11-12,27-28` |
| **incident status** | `police_incidents.status` | 无（`cleared`/`closed` 都落 `closed_at`） | ✅ 单源；但 3 个写点（create/assign/setStatus） | `p0.lua:88-94,154,171-178`、`p2_system.lua:66-69,93` |
| **arrest 记录** | 目标单源 = `police_reports(kind='arrest')` | `police_arrests` 仍被 `RegisterArrest` 与 agent `JailSystem` 写 | **冲突**：新读路径只读 reports，agent 判的刑在逮捕历史里不可见 | `p3_cases.lua:212-227`、`p2_system.lua:118-121`、`B_PLAN.md:54` |
| **justice verdict** | `custom-justice` 内存 `activeCases[caseId].verdict` | `police_reports.justice_verdict` + `justice_status`（投影） | **最终一致**：DB 是投影、写失败只 warn；重启后内存案件消失、只剩投影 | `custom-justice/server/main.lua:7,25-37,53-59`、`trial.lua:30-49,170-199` |
| **wanted** | 三源并列：`police_warrants`(approved) / `police_reports.is_bolo` / `players.metadata.wanted` | 全部并行读取、明确"Never merge" | **无单源**：B_PLAN 要求 warrants 单源，未实现；`custom-main` 还在写 `metadata.wanted` | `custom-police/server/p0.lua:210-232`、`custom-main/server/dispatch.lua:71,135`、`B_PLAN.md:56` |
| **custody（在押）** | `players.metadata.injail` | `justice.Inmates[citizenid]`（内存）；qb-prison 客户端 `jailTime` | **无单源**：5 个写者；离线判刑只写内存，重连靠两套恢复逻辑 | `custom-justice/server/prison.lua:12-66,80-98`、`qb-prison/server/main.lua:5-18`、`custom-police/server/p2_system.lua:611,826` |
| **citation 收款** | `police_citations.status`（`unpaid→paid`） | `/fine` 直接扣钱、不入表 | **单源成立但被旁路**：`/fine` 收的钱没有任何记录 | `custom-police/server/p1.lua:137-156` vs `commands.lua:259-301` |
| **罪名目录** | 两份：`PoliceCharges`（police）与 `Config.Justice.Crimes`（justice） | 无 export、无测试强制一致 | **冲突**：改一处即漂移；`GetChargeCatalog` 计划未实现 | `custom-police/shared/charges.lua:1-6,19-33`、`custom-justice/config.lua:9-26` |

---

## 3. 表清单

### 3.1 警察域（12 张）

> 现存 12 张；`B_PLAN.md:40-56` 的目标模型是 **9 张**（未列 `police_evidence_chain`，并计划让 `police_bolos`/`police_arrests` 停止新写入）。差异是计划性退役，不是遗漏。

| 表 | 唯一写者（当前） | 读者 | 主键 / 唯一键 | 逻辑外键 | 生命周期 | 迁移文件 | 允许跨资源写 |
|---|---|---|---|---|---|---|---|
| `police_units` | custom-police（`p0.lua:45-54,153,175,177,262-270,286`；`p2_system.lua:92`） | `p0.lua:56-75`、`police_mdt.lua:49,66`、`live_api.lua:484-488` | PK `citizenid`(50) | `incident_id → police_incidents.id` | 玩家以 `police` 加载时插入（即使 `off_duty`）；掉线只置 `off_duty`，**永不删除**；无 stale 清理 | `v2.8_police_p0.sql:7-19` | 否 |
| `police_incidents` | custom-police（`p0.lua:88-91,154,171-173`；`p2_system.lua:66-69,93`） | `p0.lua:118-137`、`live_api.lua:489-492`、`p2_system.lua:386,690`（存在性） | PK `id` | `created_by` 为多态字符串（citizenid 或 `agent:<id>`），无 FK | `open→assigned→enroute→on_scene→cleared/closed`；`closed_at` 只在 setStatus 写；无归档 | `v2.8:21-39` | 否 |
| `police_incident_units` | custom-police（`p0.lua:149-152`、`p2_system.lua:88-91`） | `p0.lua:166-168`（权限判定） | PK(`incident_id`,`citizenid`) | 无 | **只增不删**：清场只清 `police_units.incident_id`，join 行永久保留 | `v2.8:41-48` | 否 |
| `police_audit` | custom-police（`p0.lua:31-39`、`p1.lua:14-20`、`p2_evidence.lua:14-21`、`p3_cases.lua:32-38`、`p2_system.lua:31-38,146-152`） | `p0.lua:249-257`（`LIMIT 100`） | PK `id` | `actor_citizenid` 多态（citizenid 或 `agent:<id>`） | append-only；**无 DELETE / 无 TTL / 无分区**（全库 grep 0 命中） | `v2.8:50-61` | 否（agent 也走同一 helper） |
| `police_reports` | custom-police（`p2_system.lua:448,509,573,589,733`、`p1.lua:107`）+ **custom-justice**（`trial.lua:42`） | `p1.lua:116-133`、`p3_cases.lua:97-103,214-227,245-246`、`p0.lua:220-225` | PK `id` | `incident_id→incidents`、`case_id→police_cases`(**BIGINT**)、`justice_case_id`(string，无 FK)、`subject/author/officer_citizenid`(无 FK) | 只增 + 字段回填；`status` 的 `approved` **无写者**；rollback 会 DELETE | `v2.9:18-30`、`v3.3`、`v3.4`、`v3.5`、`v3.6`、`v3.7` | **是（白名单例外 #1）** |
| `police_citations` | custom-police（`p1.lua:51-56,153`、`p2_system.lua:520-526`） | `p1.lua:69-92` | PK `id` | `report_id→police_reports`、`incident_id→police_incidents`；`citizenid/officer` 无 FK | `unpaid→paid`（`void` 无写者）；`paid_at` | `v2.9:2-16`、`v3.4`（charge/base/report） | 否 |
| `police_evidence` | custom-police（`p2_evidence.lua:69,79`、`p2_system.lua:536,547,757`） | `p2_evidence.lua:67-77`、`p3_cases.lua:247-248` | PK `id`；UNIQUE `exhibit_no` | `incident_id`/`report_id`/`case_id`（均无约束） | `collected→stored→released→destroyed`（只有 collected 有写者）；rollback 物理删除 | `v3.0:2-19`、`v3.3`、`v3.4` | 否 |
| `police_evidence_chain` | custom-police（`p2_evidence.lua:23-27`、`p2_system.lua:550-553,771-773`） | `p2_evidence.lua:79-94` | PK `id` | `evidence_id`（无约束） | append-only；**无 UNIQUE(evidence_id,action)** → 重试会写第二条 `collected`；rollback 按 evidence_id 删除 | `v3.0:21-30` | 否 |
| `police_cases` | custom-police（`p3_cases.lua:51-57`、`p2_system.lua:489-498`） | `p3_cases.lua:62-70,240-241`、`p1.lua:104`（存在性） | PK `id`；UNIQUE `case_no` | `lead_citizenid`/`created_by`（无 FK） | `status ENUM open/closed/archived` **无任何写者** → 永远 `open` | `v3.1:2-15` | 否 |
| `police_bolos` | custom-police（`p3_cases.lua:82-85,133`） | `p3_cases.lua:104-105`（legacy 分支） | PK `id` | 无 | `active→cleared`（软删）；规划为下线但入口仍开（`police_mdt.lua:183`） | `v3.1:17-29` | 否 |
| `police_warrants` | custom-police（`p3_cases.lua:148-151,165-167`） | `p3_cases.lua:179-183`、`p0.lua:214-219` | PK `id` | `citizenid/requested_by/approved_by`（无 FK） | `requested→approved\|denied`；`executed`/`expired` **无写者** | `v3.1:31-43` | 否 |
| `police_arrests` | custom-police（`p3_cases.lua:197-201`、`p2_system.lua:118-120`） | `p3_cases.lua:249-258`（UNION 历史） | PK `id` | `incident_id`/`case_id`（无 FK） | 只增；"停止新写入"未落实（TD-06） | `v3.1:45-57` | 否（但 agent 路径仍写） |

### 3.2 平台域（2 张平台表 + `players` + justice 内存）

| 表 | 唯一写者（目标 / 现状） | 读者 | 主键 | 生命周期 | 迁移 | 允许跨资源写 |
|---|---|---|---|---|---|---|
| `agent_actions` | **custom-director 唯一** ✅（`main.lua:1435-1440` insert、`completeApproved` update、`Approve/Reject`） | `Get/List`、MCP `get_action`、verify 断言 | PK `id`；UNIQUE `idempotency_key` | `proposed→pending_approval→approved→executed/failed/rejected`；`expires_at` 仅审批期限，无清理任务 | `v2.3_agent_actions.sql:21-45` | 否 |
| `phone_notifications` | 目标 = **custom-phone 唯一**；现状 6 个写者文件 / 5 个非 owner（见 §4） | `custom-phone/server/main.lua:418,697-725` | PK `id` | 长期保留；`is_read` 单条/全量更新；可单删/清空 | 表见 `v2.7`（未重建），`v3.2` 加 `app_id` | **是（违规）** |
| `players`（`job`/`metadata`/`money`/`inventory`） | owner = qb-core（`Player.Functions.*`）；**共 7 个资源直写**：qb-core + 6 个非 owner（career/prison/justice/police/custom-main/director）。其中 qb-prison 写 `job`（入狱强制 `unemployed`），custom-main 写 `metadata.criminalrecord` | 全服 | PK `citizenid` `varchar(11)`；`job/metadata/money` 为 **TEXT JSON** | 角色删除时 qb-core 级联清理（`qb-core/server/player.lua:658-672` 的 `playertables` 含 `phone_invoices`，**不含 `police_*`**，见 G-13） | `v0.7.2_schema_reconcile.sql` 等；无警察专用迁移 | **是（设计使然，必须经 API）** |
| `justice` 内存（`activeCases`/`inmates`） | custom-justice 唯一 ✅ | `/cases`、`/trial`、`/inmates`、`ResolveCase` | key 为 `caseId:string` / `citizenid` | 进程生命周期；closed 案件 2h 后清（每小时扫一次）；**重启全丢** | 无（TD-02） | 否（但可通过 export 间接改） |

---

## 4. 跨资源写矩阵（谁在写别人的表）

| 写者 | 被写的非自有数据 | 目的 | 判定 | 证据 |
|---|---|---|---|---|
| `custom-police` | `phone_notifications` | 911/派单/罚单/支援通知 | ❌ 违规：绕过 `StoreNotification`（不清 `phoneDataCache`、不校验 `app_id`） | `p0.lua:104-107`、`p1.lua:23-25`、`p2_system.lua:45-47,282-284` |
| `custom-police` | `phone_invoices` | `/fine` 现金不足时兜底开票 | ❌ 违规且**无读者**：自研手机不读该表 | `commands.lua:293-299`（全库仅此 1 处写、0 处读） |
| `custom-police` | `players.metadata`（`callsign`/`injail`/`criminalrecord`） | 警号、legacy 服刑、前科 | ✅ 经 `Player.Functions`（允许；但 `injail` 属于 custody 冲突，见 D-02） | `commands.lua:224`、`interactions.lua:181-185`、`p2_system.lua:611,826` |
| `custom-police` | 经济（`RemoveMoney`/`qb-banking:AddMoney`） | 罚单支付、`/fine`、`/paylawyer` | ⚠️ 非原子：扣款与入账两条语句 | `p1.lua:149-153`、`commands.lua:289-291,513` |
| `custom-justice` | `police_reports.justice_verdict/justice_status` | 判决投影（重启后唯一痕迹） | ✅ **白名单例外 #1**：只 UPDATE 两个字段，`WHERE justice_case_id=?`，best-effort | `trial.lua:30-49` |
| `custom-justice` | `players.metadata.injail` | 送监 | ✅ 经 `Player.Functions`（custody 冲突见 D-02） | `prison.lua:46` |
| `custom-justice` | `custom-career` 部门 | `/setjusticedept` | ✅ 经 export `SetPlayerDepartment` | `main.lua:210` |
| `custom-career` | `players.rank_tier` / `department` / `district` / `certs` | 职业等级/部门/辖区/证照 | ❌ 裸 SQL，绕过 `Player.Functions`，无任何审计 | `custom-career/server/main.lua:54,322-333,352` |
| `custom-phone` | `phone_notifications`（自有） | 通知持久化 + 推送 | ✅ owner | `main.lua:235`、`qb_phone_compat.lua:156` |
| `custom-phone` app `police_mdt` | `phone_notifications`（宿主自有表） | MDT `alert` 动作 | ⚠️ 表属 phone，但绕过 `PhoneNotify` 直接用 `MySQL.Async.insert` | `apps/police_mdt.lua:259-264` |
| `qb-prison` | `players.job` | 入狱强制改 `unemployed` | ❌ 无恢复路径（B3）；写入方不是 owner（qb-core/career） | `qb-prison/server/main.lua:11-14` |
| `qb-prison` | `players.metadata`（`injail`/`jailitems`） | 服刑、物品托管 | ✅ 经 `Player.Functions`（custody 冲突见 D-02） | `qb-prison/server/main.lua:8,30,42` |
| `custom-main` | `players.metadata`（`wanted`/`criminalrecord`） | 星级通缉持久化 | ❌ wanted 三源之一，与 warrants 竞争 | `custom-main/server/dispatch.lua:71-75,135` |
| `custom-director` | `players.job/metadata` | `set_job`/`set_job_duty`/`set_metadata`（L2/L3） | ✅ 经 `Player.Functions` + 审批 | `custom-director/server/main.lua:583,619,652` |
| `tcity-dashboard` | 仅内存 `FlaggedPlates` | 车牌标记 | ✅ 不落库 | `[system]/tcity-dashboard/server/police_api.lua:277-288` |

---

## 5. 数据一致性等级

| 数据 / 路径 | 等级 | 依据 | 失败表现 | 补偿 |
|---|---|---|---|---|
| `police_units` / `police_incidents` 多语句写 | **强一致（非原子）** | 同资源内逐条 `await`，但无事务（后端无 `transaction` export） | 中间失败 → `incident` 已 assigned、`unit` 未更新 | 无（依赖下一次动作覆盖） |
| `ArrestSubmit`（report+citation+evidence+case+audit） | **补偿事务（saga）** | 顺序写 + 反向删除 | 任一失败 → 删除已写入的行，返回错误码 | ✅ `p2_system.lua:458-481`；**例外**：`open_case` 之后不可回滚（内存案件成孤儿，`:560-578,615-622`） |
| `ReportSubmit`（report+evidence+chain+audit） | **补偿事务** | 同上 | 失败回滚 report/evidence/chain | ✅ `p2_system.lua:743-754`；审计失败也回滚（`:791-794`） |
| `justice verdict → police_reports` | **最终一致** | `CreateThread` + 只 `print` 警告 | DB 写失败 → 内存判决照常、MDT 看不到判决 | ⚠️ 无重试、无队列（`trial.lua:39-48`） |
| `custody`（`metadata.injail` ↔ Inmates ↔ qb-prison `jailTime`） | **最终一致（且可能分叉）** | 三条独立写路径 + 两套重连恢复 | 双计时（`FLOW_INTERNAL.md:148` B6）或"坐牢无记录" | ⚠️ 仅"已在服刑则早退"去重（`prison.lua:33-35`） |
| 罚单通知 / 案件通知 | **允许丢失** | `pcall` + 失败只 print | 玩家收到罚单但没通知（或反之） | 仅日志（`p2_system.lua:281-296`） |
| `backupUnits` / `backupCooldown` / `autoAlertCooldown` | **允许丢失** | 纯内存 | 重启后冷却清零、槽位归零 | ✅ 有 `playerDropped` 兜底释放（`p2_system.lua:264-272`） |
| `justice.activeCases` / `Inmates` | **允许丢失（但用于判决/服刑）** | 纯内存 | 重启后案件消失、在押者只剩 `metadata.injail` 计时 | ❌ 无持久化（TD-02） |
| `police_audit` | **要求强一致（fail-closed）** | 敏感读/写前先写审计 | 审计失败应拒绝操作 | ⚠️ 策略不一：`GetCaseDetail`/`Lookup*`/`RequestBackup`/`ReportSubmit` 严格；`SetUnitStatus`/`JailSystem`/`CreateIncident` 忽略结果 |
| `PayCitation`（扣款 → 改状态） | **非原子** | 两次独立操作 | 已扣钱但 `status` 仍 `unpaid` | ❌ 无补偿（`p1.lua:149-153`） |
| `/fine`（扣款 + 部门入账） | **非原子** | 两条语句 | 扣了钱但部门没入账（或反之） | ❌ 无补偿（`commands.lua:289-291`） |

### 5.1 失败补偿明细

| 路径 | 补偿动作 | 漏洞 |
|---|---|---|
| `ArrestSubmit` | 反向 DELETE：chain→evidence→citation→case→report | `open_case` 成功后无法回滚；审计失败时不回滚但返回 `ok=false, jailed=true`（调用方必须自己判断 `jailed`） |
| `ReportSubmit` | 反向 DELETE：chain→evidence→report | 无（审计失败也回滚，语义干净） |
| `JailSystem` | `Imprison` 失败 → `metadata.injail` + `prison:client:Enter` 兜底 | 兜底成功仍可能没有 `justice.Inmates` 记录（后续减刑/探视查不到） |
| `OpenCase` | 无 | 调用方（ArrestSubmit）只能整体回滚自己，justice 内存案件留下 |
| `ResolveCase` | 无 | 判决已入内存并送监，`persistVerdict` 失败只 warn |
| `PayCitation` | 无 | 扣款成功 + UPDATE 失败 = 玩家白付 |
| `police_release`（控制台） | `metadata.injail=0` + `UnjailPerson` + 可选 `SetJob` | 不写 `police_audit`（`p2_system.lua:820-839`） |

---

## 6. 审计保留

| 项 | 现状 | 证据 |
|---|---|---|
| `police_audit` 结构 | `actor_citizenid`(50)、`actor_kind ENUM(player,agent,system)`、`action`(48)、`target`(64)、`detail`(500) | `migrations/v2.8_police_p0.sql:50-61` |
| 保留策略 | **无**：无 TTL、无归档、无分区、无清理任务；读侧 `ORDER BY id DESC LIMIT 100` | `p0.lua:253-255` |
| 覆盖度 | 写路径基本覆盖；**读路径缺口**：`GetUnits`、`GetIncidents`、`GetAudit`、`GetCitations`、`GetReports` 完全不写审计；其余 9 个读导出写审计（3 个 fail-closed、6 个忽略返回值） | `p1.lua:79-92,116-133`、`p0.lua:56-75,118-137,249-257` |
| 司法侧 | 判决/送监**不写 `police_audit`**，只有 `custom-logs` 文本日志 | `prison.lua:56-64`、`trial.lua:86-91,107-112` |
| Agent 侧 | `agent_actions`（含 preview/result）+ `agent_denials`（不含参数值）+ `custom-agent-client` 的 `agent_effects`（不存正文） | `migrations/v2.3_agent_actions.sql:21-45`、`AGENTS.md` §4 |
| 截断 | `detail` 500 字符、`action` 48 字符，超长静默截断（UTF-8 安全截断只在部分文件实现） | `p2_system.lua:15-29,31-37` vs `p0.lua:35`（`tostring(detail):sub(1,500)` 按字节） |
| 目标边界 | ① 审计表 append-only、单写者；② 敏感读必须审计且 fail-closed 策略统一；③ 保留期由运维策略决定（本文不新增表）；④ 禁止业务代码 `UPDATE/DELETE` 审计行 | — |

---

## 7. 迁移与 fixture 缺口

### 7.1 迁移链现状

| 版本 | 内容 | 幂等手段 | 证据 |
|---|---|---|---|
| `v2.8_police_p0` | units/incidents/incident_units/audit | `CREATE TABLE IF NOT EXISTS` + `ADD COLUMN IF NOT EXISTS` | `v2.8_police_p0.sql:3,64-68` |
| `v2.9_police_p1` | citations/reports | `CREATE TABLE IF NOT EXISTS` | `v2.9_police_p1.sql:1` |
| `v3.0_police_evidence` | evidence/evidence_chain | 同上 | `v3.0_police_evidence.sql:1` |
| `v3.1_police_p2` | cases/bolos/warrants/arrests | 同上 | `v3.1_police_p2.sql:1` |
| `v3.2_phone_notification_app` | `phone_notifications.app_id` | `information_schema` 守卫 + PREPARE | `v3.2_phone_notification_app.sql:2-7` |
| `v3.3`–`v3.7` | reports/evidence 关联、arrest-as-report、subject、justice case、verdict | `information_schema` 守卫 | `v3.3`…`v3.7` 各自头部 |

### 7.2 缺口清单

| # | 缺口 | 影响 | 证据 |
|---|---|---|---|
| G-01 | `tests/fixtures/tcity_schema.sql` **没有任何 `police_*` 表**（791 行，grep 0 命中） | DB 集成测试无法覆盖警察域；所有警察测试是源码级静态断言 | `tests/fixtures/tcity_schema.sql`、`tests/unit/layer3_business/test_arrest_submit.py:10-12`、`TECH_DEBT.md:39-41` |
| G-02 | fixture 也没有 `agent_actions` / `agent_denials` / `agent_effects` | director 的 DB 行为只能在真库验证 | `tests/fixtures/tcity_schema.sql`（grep 0 命中） |
| G-03 | CI 的 schema 检查只认 7 张表（players/bank_accounts/bank_statements/player_vehicles/phone_contacts/phone_messages/phone_calls） | 迁移回归不会被 CI 发现 | `tests/check_db_schema.py:15-49` |
| G-04 | 无 down migration、无 schema 版本表 | 回滚只能手工；无法判断库处于哪个 `v3.x` | `migrations/` 目录（全部只 forward） |
| G-05 | `police_cases.status` 无流转写者，也无迁移定义合法流转 | 案件永远 `open`，`GetCases` 的 `status` 参数被忽略 | `p3_cases.lua:62-70`、`v3.1_police_p2.sql:7` |
| G-06 | `police_warrants.executed/expired` 无写者 | 令状执行/过期流转缺失（`STATUS.md:24` 产品化待办） | `p3_cases.lua:157-171`、`v3.1:35` |
| G-07 | `police_arrests` 无归档/删除迁移，且仍在被写 | "一个版本后归档"未执行 | `B_PLAN.md:54`、`p2_system.lua:118`、`p3_cases.lua:197` |
| G-08 | 罪名目录是 Lua 硬编码，无种子表/无迁移 | 与 justice 配置漂移无检测（D-05） | `custom-police/shared/charges.lua:19-33`、`custom-justice/config.lua:9-26` |
| G-09 | `police_units.prev_job/prev_grade`（B_PLAN P4 计划）未实现 | 出狱不恢复职业（按用户决定：**不做**恢复，属刻意缺口） | `B_PLAN.md:98`、`STATUS.md:47` |
| G-10 | `citizenid` 宽度漂移：`players`/agent tool = 11，`police_*`/`phone_notifications` = 50 | 无法建 FK；越界值只能靠应用层 trim | `tests/fixtures/tcity_schema.sql:626`、`v2.8:8`、`tools/agent_tools.json:121-125` |
| G-11 | `police_evidence_chain` 无 `UNIQUE(evidence_id, action)` | 重试写重复首条链，"100% 有首条链"验收无法机器校验 | `v3.0_police_evidence.sql:21-30` |
| G-12 | `phone_notifications` 的迁移只补了 `app_id`；表本体来自旧库 | 新库初始化依赖 `v2.7` 前状态，fixture 与迁移不完全同源 | `v3.2_phone_notification_app.sql`、`tests/fixtures/tcity_schema.sql:401-411` |
| G-13 | **删号不清理**：`DeleteCharacter` 的级联表清单不含任何 `police_*`，也不含 `phone_notifications` | 删角后案卷/罚单/审计成为孤儿行（无 FK 兜底，只能靠人工按 citizenid 清） | `qb-core/server/player.lua:658-672` |

---

## 8. 数据所有权冲突清单

| ID | 冲突 | 后果 | 证据 |
|---|---|---|---|
| D-01 | **duty 双源**：`players.job.onduty` vs `police_units.status` | 派单/权限/UI 各读一套；下班后仍可被派单 | `p0.lua:262-280,294-309`、`TECH_DEBT.md:5-24` |
| D-02 | **custody 三源**：`metadata.injail` / `justice.Inmates` / qb-prison 客户端 `jailTime`；5 个写者 | 双计时、"坐牢无记录"、离线判刑只在内存 | `prison.lua:12-66,80-98`、`qb-prison/server/main.lua:5-18`、`p2_system.lua:611,826` |
| D-03 | **arrest 双源**：`police_reports(kind='arrest')` vs `police_arrests` | agent 判刑在 MDT 逮捕历史不可见；案件详情靠 UNION 兜底 | `p3_cases.lua:212-227,249-258`、`p2_system.lua:118-121` |
| D-04 | **wanted 三源**：warrants / BOLO tag / `metadata.wanted` | HUD 两星、MDT 查不到令状（F10/B8） | `p0.lua:210-232`、`custom-main/server/dispatch.lua:71` |
| D-05 | **罪名目录两份**：police `PoliceCharges` vs justice `Config.Justice.Crimes` | 逮捕刑期与法庭基准不一致 | `shared/charges.lua:1-6`、`custom-justice/config.lua:9-26` |
| D-06 | **`phone_notifications` 6 个写者文件 / 5 个非 owner** | 列表缓存最长滞后 30s（`custom-phone/server/main.lua:351`）、`app_id` 校验被绕过、无法统一限流/去重 | `p0.lua:105`、`p1.lua:24`、`p2_system.lua:46,283`、`police_mdt.lua:261`、`custom-phone/server/main.lua:235`、`custom-phone/server/qb_phone_compat.lua:156` |
| D-07 | **justice 判决只在内存**，DB 只有投影；且投影键 `justice_case_id` 会**跨重启复用**（`CASE-0001` 重新从 1 计数），`UPDATE ... WHERE justice_case_id=?` 会批量改写上一轮所有同号报告 | 重启后案件不可查/不可再判；更严重的是历史判决被新判决覆盖 | `custom-justice/server/main.lua:7-8,18-20,158-168`、`trial.lua:39-44,198`、`02-state-machines.md` §justice |
| D-08 | **`/fine` 旁路 citations**：收钱不写 `police_citations`，兜底还写无人读的 `phone_invoices` | 同一执法两种记录；对账不可能 | `commands.lua:259-301` |
| D-09 | **`police_cases.status` 无写者** | 案件永不关闭；`GetCases` 的 `status` 过滤是死参数 | `p3_cases.lua:62-70`、`v3.1:7` |
| D-10 | **`police_incident_units` 只增不删** | 长期膨胀；无法区分"当前参与"与"历史参与" | `p0.lua:149-152,177` |
| D-11 | **`police_evidence_chain` 无唯一约束** | 重试产生重复链；保管链完整性不可断言 | `v3.0:21-30`、`p2_system.lua:550-553` |
| D-12 | **`citizenid` 宽度不一致**（11 vs 50） | 无 FK、跨表 join 依赖应用层约定 | `tests/fixtures/tcity_schema.sql:626`、`v2.8:8` |
| D-13 | **审计策略不一致** | 同一"敏感操作"在不同入口有/无审计 | `p3_cases.lua:242-244` vs `p2_system.lua:121`、`p0.lua:52` |
| D-14 | **BOLO 计划下线但入口仍开** | 新数据继续进 legacy 表，双源长期存在 | `B_PLAN.md:55`、`police_mdt.lua:183`、`p3_cases.lua:82` |
| D-15 | **删号无级联**：`playertables` 清单不含 `police_*` / `phone_notifications` | 数据保留与隐私删除都无法闭环 | `qb-core/server/player.lua:658-672` |

---

## 9. 建议的所有权收敛顺序

> 只列"先动哪个"，不改 schema。每条都能在不新增表的前提下推进。

| 顺序 | 动作 | 解决 | 成本 |
|---|---|---|---|
| 1 | `phone_notifications` 收敛为 `custom-phone` 唯一写者（police 走 `PhoneNotify`/事件） | D-06、03 的 X-06 | 低（4 处调用替换 + 1 处 app 内直写） |
| 2 | 出勤状态收敛到单一状态机（`OffDuty/Available/Busy` + 任务派生），`onduty` 降为投影 | D-01 | 中（TD-01 有 4 个待拍板项） |
| 3 | arrest 单源：新写入只进 `police_reports`，`police_arrests` 转只读历史 | D-03（并消除 03 的 X-07） | 低（删 2 处 INSERT，读路径已兼容 UNION） |
| 4 | custody 单源：`metadata.injail` 为唯一权威，Inmates 降为缓存并可从 `metadata` 重建 | D-02、D-07 | 中（需先决定 justice 是否落库） |
| 5 | wanted 单源：`police_warrants(approved)` 为准，BOLO/metadata 降为只读展示 | D-04 | 中（`custom-main` 需改读） |
| 6 | 罪名目录单源：任选一侧为源、另一侧运行时读取（`GetChargeCatalog` 仍未实现） | D-05、G-08 | 低 |
| 7 | 补 fixture（`police_*` + `agent_actions`）并把 `check_db_schema` 扩到警察域 | G-01/G-02/G-03 | 低（纯测试资产） |
| 8 | 案件/令状状态机补齐（`closed`/`executed`/`expired` 写者） | D-09、G-05、G-06 | 中（涉及 UI） |

**不建议现在做的**：给 `police_reports.case_id` 改类型（需双字段并存过渡，见 03 的 X-03）、给 `police_audit` 加分区（数据量未到）、把 justice 内存整体落库（属产品决策，见 TD-02）。

---

## 10. 未验证 / 边界

- 未连库：所有行数、paid 比例、`police_arrests` 实际存量均未采样。
- 未实机触发出狱/重连路径；custody 双计时的结论来自代码路径与 `FLOW_INTERNAL.md:148` 的既有记录。
- `Bus` 服务（`Bus.RegisterService('justice', ...)`、`Bus.JobService.SetJob`）的实际注册时序未验证。
- 本文不覆盖 `phone_*` 其余表（messages/contacts/calls/gallery/...）与经济表的完整所有权，只覆盖与警察域有交集的 3 张。
