# 03 — 跨资源契约（Contracts）

> 架构基线 agent C ｜ 只读 + 文档 ｜ **基线快照 `568acd2` + post-baseline 注记，当前 HEAD `3bbcab3`**（2026-10-24）｜ 未改代码、未 commit、未触碰 FXServer。
> 未标“现在”的表格是基线事实；§2.8、§3.4、§10.1 是 post-baseline 增量（`bb64d87`…`3bbcab3`）。
>
> **证据路径口径**：
> - `custom-*/*`、`qb-prison/*` 相对 `T-CityLite.base/resources/`（`custom-*` 在 `[custom]/`，`qb-prison` 在 `[qb]/`）
> - `migrations/*`、`tests/*` 相对 `T-CityLite.base/`
> - `tools/*`、`docs/*` 相对仓库根
>
> 关联：[STATUS.md](../STATUS.md)、[TECH_DEBT.md](../TECH_DEBT.md)、[FLOW_INTERNAL.md](../FLOW_INTERNAL.md)、[B_PLAN.md](../B_PLAN.md)、[02-state-machines.md](02-state-machines.md)（状态机）、[04-data-ownership.md](04-data-ownership.md)（数据归属）、[07-fitness-tests.md](07-fitness-tests.md)（可自动化的约束）。
> 本文只描述现状与目标边界，**不设计新表、不改代码**。

---

## 0. 一页结论

| # | 结论 | 证据 |
|---|---|---|
| 1 | 契约面共 **56 个 export（42 police 服务端 + 7 justice + 6 director + 1 client；若把 `custom-director/server/director.lua` 另 3 个 export 也算上则 59）、27 个跨资源事件（15 入站 + 12 出站）、6 个 callback、17 个 PhoneApps query、17 个 MDT action、21 个 director action、35 个 agent tool**；其中重点展开：警察 5 个 export（§2.3）、justice 2 个 export（§2.5）、3 个 police agent tool（§7）。基线时为 46 export / 22 事件 | `custom-police/server/{p0,p1,p2_evidence,p3_cases,p2_system,p4_npc}.lua`、`custom-justice/server/{main,sentence}.lua:221-227,249-267`、`custom-phone/server/main.lua:1372-1414`、`custom-director/server/policy.lua:29-160`、`tools/agent_tools.json:3-4` |
| 2 | 在 export 层只有 **4 个契约**返回结构化 `{ok,error}`（`ArrestSubmit`/`ReportSubmit`/`RequestBackup`/`GetCaseDetail`）；新增的 NPC 警情/服刑契约仍是 `table｜false,'code'` 元组。在 MDT action 层只有 2 个透传（`report_submit`/`request_backup`），14 个被压平（13 个 `ok and res ~= false` + `arrest_submit`），`alert` 为特例（成功 `{sent}`、失败压平） | `custom-phone/server/apps/police_mdt.lua:168-284`、`custom-phone/server/phone_apps.lua:138-142` |
| 3 | export 仍**没有版本号**；幂等只到参数层：`ArrestSubmit`/`ReportSubmit` 接受 `params.idempotency_key`（v3.9 账本），其余写契约无幂等键；director HTTP 仍是最完整的 `agent_actions.idempotency_key` UNIQUE | `custom-police/server/p2_system.lua:146-267`、`migrations/v3.9_police_write_intents.sql`、`migrations/v2.3_agent_actions.sql:38`、`custom-director/server/main.lua:1367-1389` |
| 4 | 契约方向是**环形的**：`custom-justice` 声明依赖 `custom-police`，同时 `custom-police` 运行时调 `custom-justice` 的 export，但自己的 fxmanifest 没有声明该依赖 | `custom-justice/fxmanifest.lua:21`、`custom-police/server/p2_system.lua:109,566,605` |
| 5 | 事件命名有 5 套前缀、3 种大小写风格；`police:server:autoAlert`（camel）、`police:server:UpdateCurrentCops`（Pascal）、`custom-police:server:setStatus`（lower）同时存在 | `custom-police/server/main.lua:198`、`custom-police/server/main.lua:239`、`custom-police/server/p0.lua:294` |
| 6 | 有 3 个 callback 是**死契约**（零消费者），1 个旧事件在 `source=0` 分支上不可用 | `custom-police/server/main.lua:75,90,106`、`custom-police/server/interactions.lua:139-149` |

---

## 1. 契约分层与信任边界

| 层 | 契约形态 | 调用方 → 被调方 | 鉴权位置 | 审计位置 | 证据 |
|---|---|---|---|---|---|
| L0 玩家 | 命令 / NUI | 客户端 → `custom-police` 命令 | `PolicePolicy.Can` | `police_audit` | `custom-police/shared/policy.lua:40-47` |
| L1 App | `PhoneApps` query/action | `custom-phone` → `custom-police` export | `audience`（job+onduty）→ 再 `PolicePolicy` | `police_audit` | `custom-phone/server/phone_apps.lua:39-52,113-143` |
| L2 资源 | export | `custom-phone` / `custom-director` → `custom-police` / `custom-justice` | 被调方自行校验 source | `police_audit`（`actor_kind='player'`） | `custom-police/server/p0.lua:305-309` |
| L3 Agent | HTTP `/agent/v1/act` | MCP/脚本 → `custom-director` | token + 动作分级 + 审批 | `agent_actions` + `police_audit`（`actor_kind='agent'`） | `custom-director/server/policy.lua:29-160`、`custom-police/server/p2_system.lua:31-38` |
| L4 感知 | HTTP `/agent/v1/live/*` | agent → `custom-director` | 独立 live token + 限流 | 无（只读、无 PII） | `custom-director/server/live_api.lua:26,107-141,483-502` |

**总原则（现状与目标一致的部分）**：所有写路径的服务端权威在资源内，`NUI 隐藏 ≠ 权限`（`custom-phone/server/phone_apps.lua:1-6`）。**现状缺口**：`GetUnits`/`GetIncidents` 在 export 层没有任何 capability 检查（`custom-police/server/p0.lua:56-75,118-137`），安全性完全依赖调用方的 `audience` 与 director token。

---

## 2. Export 契约

> **行号口径**：本节未标“现在”的表格/行号是基线 `568acd2`；HEAD 的签名与行为变化见 §2.1.1（P0 导出）与 §2.8（新增契约）。§2.3 的五个重点契约已把幂等/审计/错误码更新到 HEAD。

### 2.1 `custom-police` — 出勤 / 警情 / 查询 / 审计（P0）

| Export | 消费者 | 输入 | 返回 / 错误 | 权限 | 幂等 | 审计 |
|---|---|---|---|---|---|---|
| `SetUnitStatus(citizenid, callsign, status)` | 内部 / MDT 间接 | `citizenid:string`, `callsign:string≤16`, `status:enum` | `true` / `false,'invalid_status'` | **无**（export 层零鉴权） | 是（UPSERT `p0.lua:47-51`） | `unit.status`（target=status, detail=nil），结果被忽略（`p0.lua:52`） |
| `SetUnitStatusForSource(source, status)` | `police_mdt.lua:169` | `source:number`, `status:enum` | `true` / `false,'not_police'` / `false,'invalid_status'` | 仅 `IsPolice`（**不查 onduty、不查 grade**，`p0.lua:307`） | 是 | 同左 |
| `GetUnits()` | `police_mdt.lua:49,66`；director `live_api.lua:484` 走 SQL | 无 | `{units[],count}`；`SELECT *`（`p0.lua:57`） | **无** | 读 | 无 |
| `CreateIncident(source, data)` | `police_mdt` 未接；内部 `/911`（`p0.lua:300-303`） | `{title,code,priority,x,y,z,description}` | `{id,status='open'}` / `false,'invalid_title'\|'db_error'\|'player_not_found'` | 仅 `player_not_found`（`p0.lua:78-79`） | **否** | `incident.create`，非 fail-closed（`p0.lua:94`） |
| `GetIncidents(status?)` | `police_mdt.lua:72` | `status?:enum` | `{incidents[],count}` | **无** | 读 | 无 |
| `AssignUnit(source, incidentId, citizenid)` | `police_mdt.lua:175` | `incidentId:number`, `citizenid:string` | `{id,unit,status}` / `false, reason` | `incident.assign`（grade≥2） | **否**（重复分配幂等，`p0.lua:149-152`） | `incident.assign` |
| `SetIncidentStatus(source, incidentId, status)` | `police_mdt.lua:232,238,244` | `{incidentId,status}` | `{id,status}` / `false,'invalid_status'\|'not_assigned'\|'invalid_incident'` | `incident.update`；grade<2 需已加入（`p0.lua:166-169`） | 是（写同值） | `incident.status` |
| `LookupCitizen(source, citizenid)` | `police_mdt.lua:79` | `citizenid:string≤50` | `{citizenid,name,birthdate,job,warrants[],bolo[],active_wanted,last_seen}` / `false,'not_found'` | `lookup.citizen` + **审计 fail-closed**（`p0.lua:187-189`） | 读 | `lookup.citizen` + `.result`（`p0.lua:227`） |
| `LookupVehicle(source, plate)` | `police_mdt.lua:88` | `plate:string≤12` | `{plate,citizenid,model,state}` / `false,'invalid_plate'\|'not_found'` | `lookup.vehicle` + fail-closed | 读 | `lookup.vehicle(.result)` |
| `GetAudit(source)` | `police_mdt.lua:150` | 无 | `{rows[],count}`（`LIMIT 100`） | `audit.view`（grade≥3） | 读 | 不审自身 |

### 2.1.1 post-baseline 变化（P0 导出，只列变更行）

| Export | 基线时 | 现在（`3bbcab3`） | 证据 |
|---|---|---|---|
| `SetUnitStatus` / `SetUnitStatusForSource` | 只写 `police_units`；不要求 onduty | `off_duty`/`available` 经 `SetJobDuty` 投影，失败 `duty_failed`；busy/任务态要求 `onduty=true`；`SetUnitStatus` 拒绝离线非 off_duty | `p0.lua:102-121,567-599` |
| `CreateIncident` | 只校验 title；无坐标校验 | 行为未变（仍接受客户端 x/y/z、无频率/去重）；`_source` 仍要求玩家存在 | `p0.lua:144-183` |
| `GetIncidents(status?)` | 只排除 `closed`；`cleared` 永远在队列 | 允许的过滤值收窄为 `open/assigned/enroute/on_scene`；默认仍排除 `closed`；返回行新增 `disposition`、`npc_template` | `p0.lua:30-34,185-210` |
| `AssignUnit` | incident 存在即可；不校验目标单位；重复分配写第二行 | incident 必须 `open/assigned`；grade1 可自派；同 incident+同活动 unit 返回 `idempotent=true`；非法返回 `invalid_transition` | `p0.lua:212-257` |
| `SetIncidentStatus` | 任意 enum 可跳转；`cleared` 不是 `closed` | 新增可选参数 `(disposition, reason)`；transition 表守卫；`cleared/cancelled/closed` 统一归档 `closed` + disposition；只释放任务态单位 | `p0.lua:259-325` |
| `SweepStaleIncidents()` | 不存在 | 新导出：45min 无活动 → `closed` + `disposition='stale'`，返回处理行数；定时器每 60s 调用 | `p0.lua:506-541,608` |

> **兼容性**：`SetIncidentStatus(source, incidentId, status)` 的原三参调用仍可用（disposition 缺省为 `cleared`/`cancelled`）；`GetIncidents` 的 `cleared` 过滤值现在返回 `invalid_status`（基线可传但无意义）。

### 2.2 `custom-police` — 罚单 / 报告 / 证据 / 案件

| Export | 消费者 | 输入 | 返回 / 错误 | 权限 | 幂等 | 审计 |
|---|---|---|---|---|---|---|
| `IssueCitation(source, params)` | `police_mdt.lua:223` | `{citizenid,amount 1..50000,reason 3..240,plate?,incident_id?}` | `{id,amount,status='unpaid'}` / `false,'invalid_amount'\|'citizen_not_found'\|'db_error'` | `citation.issue` | **否** | `citation.issue` + 通知（`p1.lua:58-62`） |
| `PayCitation(source, citationId)` | `custom-phone/server/main.lua:1402` | `citationId:number` | `{id,amount,status='paid'}` / `false,'not_owner'\|'already_paid'\|'insufficient_funds'` | 归属校验（`p1.lua:146`），无警察 cap | **否**（状态前置，二次调用返回 `already_paid`） | `citation.pay` |
| `GetMyCitations(source)` | `custom-phone/server/main.lua:1392` | 无 | `{rows[],count}` | 归属即权限（`p1.lua:69-77`） | 读 | 无 |
| `GetCitations(source, params)` | `police_mdt.lua:96` | `{citizenid?}` | `{rows[],count}` | `citation.view` | 读 | **无审计**（`p1.lua:79-92`） |
| `CreateReport(source, params)` | `police_mdt.lua:227`（旧路径） | `{title,body,incident_id?,case_id?}` | `{id,status='submitted'}` / `false,'invalid_title'\|'invalid_body'\|'case_not_found'` | `report.create` | 否 | `report.create` |
| `GetReports(source, params)` | `police_mdt.lua:101` | `{case_id?\|incident_id?}` | `{rows[],count}` | `report.view` | 读 | **无审计** |
| `RegisterEvidence(source, params)` | `police_mdt.lua:219` | `{label,description?,incident_id?\|report_id?\|case_id?}` | `{id,exhibit_no,status}` / `false,'missing_case'\|'case_not_found'\|'incident_not_found'` | `evidence.register` | 否 | `evidence.register` + 首条链 |
| `GetEvidence(source, params)` | `police_mdt.lua:106` | `{incident_id?}` | `{rows[],count}` | `evidence.view` | 读 | `evidence.view` |
| `GetEvidenceChain(source, evidenceId)` | `police_mdt.lua:144` | `evidenceId:number` | `{rows[],count}` | `evidence.view` | 读 | `evidence.chain` |
| `CreateCase(source, params)` | `police_mdt.lua:180` | `{title,summary,lead_citizenid?}` | `{id,case_no,status='open'}` | `case.create`（grade≥2） | 否 | `case.create` |
| `GetCases(source, params)` | `police_mdt.lua:116` | `params.status` **被忽略**（`p3_cases.lua:62-70`） | `{rows[],count}` | `case.view` | 读 | `case.view` |
| `GetCaseDetail(source, caseId)` | `police_mdt.lua:111` | `caseId:number` | `{case{},reports[],evidence[],arrests[]}` / `false,'not_found'\|'audit_unavailable'` | `case.view` + **审计 fail-closed**（`p3_cases.lua:242-244`） | 读 | `case.detail` |
| `CreateBolo` / `ClearBolo` | `police_mdt.lua:184` | `{kind,target,reason}` / `boloId` | `{id,...,status}` | `bolo.create` | 否 | `bolo.create` / `bolo.clear` |
| `GetBolos(source)` | `police_mdt.lua:121` | 无 | `{rows[]}`：reports(is_bolo) **UNION** `police_bolos`（`p3_cases.lua:95-122`） | `bolo.view` | 读 | `bolo.view` |
| `RequestWarrant` / `DecideWarrant` / `GetWarrants` | `police_mdt.lua:188,192,126` | `{citizenid,reason}` / `{warrant_id,approve}` | `{id,status}` / `false,'not_pending'` | `warrant.request`(2) / `warrant.approve`(3) / `warrant.view` | `DecideWarrant` 幂等（`status='requested'` 守卫，`p3_cases.lua:165-168`） | 三条均审计 |
| `RegisterArrest(source, params)` | `police_mdt.lua:196`（旧路径） | `{citizenid,charges,incident_id?,case_id?}` | `{id,citizenid,status='registered'}` | `arrest.create` | 否 | `arrest.register` |
| `GetArrests(source, params)` | `police_mdt.lua:131` | `{citizenid?}` | `{rows[]}`（读 `police_reports kind='arrest'`，`p3_cases.lua:212-227`） | `arrest.create` | 读 | `arrest.view` |

### 2.3 五个重点契约（逐条）

#### C-EXP-01 `ArrestSubmit(source, params)` — 一次逮捕的唯一写入口

| 项 | 内容 | 证据 |
|---|---|---|
| 名称 / 方向 | `custom-police:ArrestSubmit` ｜ `custom-phone`(server) → `custom-police`(server)，同一 tick 内同步返回 | `custom-police/server/p2_system.lua:336,802`；`custom-phone/server/apps/police_mdt.lua:199-203` |
| 输入 schema | `citizenid:string`（必须在线）；`charge_ids:string[1..8]`（白名单，禁重复）；`details?:string≤1000`；`incident_id?:int`；`case_id?:int`；`create_case?:bool`；`open_case?:bool`；`bolo?:bool` + `bolo_kind?:'person'\|'vehicle'` + `bolo_target?:string≤50`；`location?:≤120`；`create_citation?:bool`（缺省 **true**）；`citation_amount?:int`（夹取 `base×0.8~1.2`）；`create_evidence?:bool` + `evidence_label?:≤120` | `custom-police/server/p2_system.lua:343-446`、`custom-police/shared/charges.lua:9,64-92` |
| 输出 | `{ok=true, report_id, minutes, fine, jailed=true, subject_citizenid, citation_id?, evidence_id?, case_id?, justice_case_id?}`；失败 `{ok=false, error, report_id?, jailed?}` | `custom-police/server/p2_system.lua:653-661,650` |
| 错误码 | 权限：`not_police`/`not_on_duty`/`rank_too_low`；校验：`invalid_params`/`invalid_citizen`/`invalid_charges`/`invalid_charge`/`duplicate_charge`/`invalid_amount`/`invalid_bolo_kind`/`invalid_bolo_target`/`invalid_case_combination`/`invalid_idempotency_key`；状态：`citizen_offline`/`target_unavailable`/`already_jailed`/`target_not_cuffed`/`too_far`/`incident_not_found`/`case_not_found`/`in_progress`；权限细分：`case_forbidden`/`bolo_forbidden`；依赖：`db_error`/`case_create_failed`/`open_case_failed`/`jail_failed`/`audit_unavailable` | `p2_system.lua:459-808`（`fail` 定义 `:142-144`） |
| 权限 | `arrest.create`（police + onduty + grade≥1）；`create_case`/`open_case` 另需 `case.create`(2)；`bolo` 另需 `bolo.create`(2)；物理前置：目标 ped 存在、已上铐/倒地/失能、≤5m、未在服刑 | `custom-police/shared/policy.lua:19-26`、`p2_system.lua:475-537` |
| 幂等 | **现在**：可选 `params.idempotency_key`（`^[A-Za-z0-9_-]{8,128}$`）；`pending` 拒绝并发、`done` 重放 `result_json`；无键调用仍不幂等（基线行为） | `p2_system.lua:146-267,466-469`、v3.9 |
| 审计 | 成功：`arrest.register` + 可选 `bolo.create`/`case.create`/`citation.issue`/`evidence.register`（现在 citation/evidence 也单独审计）；审计失败**不回滚已送监**，返回 `ok=false, jailed=true` | `p2_system.lua:766-797` |
| 超时 / 失败语义 | 无超时、无事务；补偿删除：evidence_chain→evidence→citation→case→report；`open_case` 之后失败**无法回滚**（justice 内存案件成孤儿）；幂等键失败即删，允许修正后重试 | `p2_system.lua:127-136,591-614,694-712` |
| 版本 / 兼容 | export 无版本号；参数只增不改；旧 `register_arrest`/`issue_citation` 仍然并存（同一 MDT 有两组入口） | `p2_system.lua:802`、`police_mdt.lua:195-198,222-229` |

#### C-EXP-02 `ReportSubmit(source, params)` — 报告 + 证据 + BOLO

| 项 | 内容 | 证据 |
|---|---|---|
| 方向 | `custom-phone`(server) → `custom-police`(server) | `police_mdt.lua:204-208`、`p2_system.lua:672,803` |
| 输入 | `title:3..160`；`body:10..4000`；`citizenid?`；`incident_id?`；`case_id?`；`location?`；`evidence?:bool`+`evidence_label?`/`evidence_description?`；`bolo?:bool`+`bolo_kind?`/`bolo_target?`/`bolo_reason?` | `p2_system.lua:679-731` |
| 输出 | `{ok=true, report_id, evidence_id?, bolo:boolean}` / `{ok=false, error}` | `p2_system.lua:796` |
| 错误码 | `not_police`/`not_on_duty`/`rank_too_low`、`invalid_title`/`invalid_body`/`invalid_case`/`invalid_incident`/`invalid_evidence_label`/`invalid_bolo_kind`/`invalid_bolo_target`、`incident_not_found`/`case_not_found`、`bolo_forbidden`、`db_error`/`audit_unavailable` | `p2_system.lua:676-794` |
| 权限 | `report.create`(1)；BOLO 另需 `bolo.create`(2) | `p2_system.lua:675,721-722` |
| 幂等 | **现在**：`params.idempotency_key` 同上；`done` 重放、`pending` → `in_progress` | `p2_system.lua:819-828` |
| 审计 | `report.create` + `evidence.register` + `bolo.create`；任一失败 → 回滚 report/evidence 并返回 `audit_unavailable` | `p2_system.lua:930-940` |
| 超时 / 失败 | 无事务；补偿删除 report+evidence(+chain)；幂等账本失败即删 | `p2_system.lua:828-946` |
| 版本 | 与旧 `CreateReport`（`p1.lua:94`）并存，同表两个写者 | `p1.lua:107-114` |

#### C-EXP-03 `RequestBackup(source)` — NPC 支援（服务端裁决）

| 项 | 内容 | 证据 |
|---|---|---|
| 方向 | `custom-phone`(server) → `custom-police`(server)；随后 `custom-police`(server) → 请求者 client `police:client:SpawnBackup` | `police_mdt.lua:213-217`、`p2_system.lua:241` |
| 输入 | 仅 `source:number`（`_params` 被忽略） | `p2_system.lua:191`、`police_mdt.lua:213-214` |
| 输出 | `{ok=true, request_id='BU-<src>-<epoch>-<seq>'}` / `{ok=false, error}` | `p2_system.lua:207,242` |
| 错误码 | `not_police`（非警察**或**审计期间玩家已离开，两义合并）、`cooldown`（60s）、`limit`（2 队）、`audit_unavailable` | `p2_system.lua:197,203,204,228,238` |
| 权限 | `incident.update`（police + onduty + grade≥1） | `p2_system.lua:197` |
| 幂等 | 非幂等（每次新 `request_id`）；冷却/上限是节流，不是幂等 | `p2_system.lua:172-177,201-207` |
| 审计 | `backup.request`（`actor_kind='player'`），fail-closed | `p2_system.lua:225-229` |
| 超时 / 失败 | **无 TTL**：仅 `police:server:backupEnded` 或 `playerDropped` 释放槽位；client 卡死但未掉线 → 槽位直到掉线才回收 | `p2_system.lua:248-272`、`custom-police/client/backup.lua:497-504` |
| 版本 | `request_id` 是隐式契约：client 只校验 `string, 1..64`，不得改格式 | `client/backup.lua:498` |

#### C-EXP-04 `GetCaseDetail(source, caseId)` — 案件聚合读

| 项 | 内容 | 证据 |
|---|---|---|
| 方向 | `custom-phone`(server) → `custom-police`(server) | `police_mdt.lua:110-114`、`p3_cases.lua:234,268` |
| 输入 | `caseId:number` | `p3_cases.lua:238-239` |
| 输出 | `{case:{id,case_no,title,summary,status,lead_citizenid,created_at}, reports[], evidence[], arrests[]}`；**裸表无 envelope** | `p3_cases.lua:259-265` |
| 错误码 | `not_police`/`not_on_duty`/`rank_too_low`、`invalid_case`、`not_found`、`audit_unavailable` | `p3_cases.lua:236-243` |
| 权限 | `case.view`；**审计失败即拒绝**（全库唯一 read fail-closed 之一，另一处是 lookups） | `p3_cases.lua:242-244` |
| 幂等 | 读，幂等 | — |
| 审计 | `case.detail` | `p3_cases.lua:242` |
| 超时 | 无；4 次串行 await（case/reports/evidence/arrests） | `p3_cases.lua:240-258` |
| 版本 | 双层 envelope：export 裸表 → PhoneApps `{rows:[res],count:1}` → UI `res.data.rows[0]`（`p3_cases.lua:265`、`police_mdt.lua:110-114`）；字段增删需同时改三处 | 同上 |

#### C-EXP-05 `SetUnitStatusForSource(source, status)` — 出勤状态

| 项 | 内容 | 证据 |
|---|---|---|
| 方向 | `custom-phone`(server) → `custom-police`(server) | `police_mdt.lua:167-172`、`p0.lua:305-309` |
| 输入 | `status ∈ {off_duty,available,busy,unavailable,assigned,enroute,on_scene}` | `p0.lua:8-11` |
| 输出 | `true` / `false,'not_police'` / `false,'invalid_status'` | `p0.lua:306-308`、`p0.lua:46` |
| 权限 | 仅 `job.name=='police'`；**不校验 onduty、不校验 grade**（与 `PolicePolicy.Can` 不一致） | `p0.lua:307` vs `custom-police/shared/policy.lua:40-47` |
| 幂等 | 幂等（`INSERT ... ON DUPLICATE KEY UPDATE`） | `p0.lua:47-51` |
| 审计 | `unit.status`，`actor_citizenid=本人`、`target=status`、`detail=nil`；写失败返回值被 `pcall` 包装但调用点忽略 | `p0.lua:31-39,52` |
| 超时 / 失败 | 无；DB 失败时 `MySQL.insert.await` 抛错 → export 抛给调用方 pcall → MDT 收到 `action_rejected` | `police_mdt.lua:167-172` |
| 版本 | `status` ENUM 变更需同时迁移 `migrations/v2.8_police_p0.sql:11-12` + UI + `live_api` 过滤 | 同左 |

### 2.4 `custom-police` — agent/system 入口（无 player source）

| Export | 消费者 | 输入 | 返回 / 错误 | 审计 | 幂等 |
|---|---|---|---|---|---|
| `CreateIncidentSystem(actorId, data)` | director `police_incident_create` | `{title 3..120,code≤16,priority 1..3,details≤1000}` | `{id,status}` / `false,'invalid_params'\|'invalid_title'\|'audit_unavailable'\|'db_error'` | `actor_kind='agent'`，**fail-closed** | 否（director 层保证） |
| `AssignUnitSystem(actorId, incidentId, citizenid)` | director `police_assign_unit` | `{incident_id,citizenid≤50}` | `{id,unit,status}` / `false,'invalid_incident'\|'invalid_unit'\|'incident_not_found'\|'unit_not_found'\|'unit_off_duty'\|'audit_unavailable'` | fail-closed | 否（`p2_system.lua:88-91` 有 UPSERT） |
| `JailSystem(actorId, citizenid, minutes, reason)` | director `police_jail_player` | `{citizenid,minutes 1..120,reason 3..240}` | `{citizenid,minutes,status}` / `false,'invalid_citizen'\|'invalid_minutes'\|'invalid_reason'\|'citizen_offline'` | 审计失败**被忽略**（`p2_system.lua:121`） | 否 |
| `ArrestSubmit` / `ReportSubmit` / `RequestBackup` | 见 §2.3 | — | — | — | — |
| `GetCharges()` | `police_mdt.lua:136` | 无 | `{charges[{id,label,minutes,fine}]}` | 无（静态目录） | 读 |

证据：`custom-police/server/p2_system.lua:56-123,799-814`；director 调用方 `custom-director/server/main.lua:1189-1222`。

### 2.5 `custom-justice` — 判决 / 送监

| Export | 消费者 | 输入 | 返回 / 错误 | 权限 | 幂等 | 审计 |
|---|---|---|---|---|---|---|
| `Imprison(citizenid, minutes, crimes, opts?)` | `custom-police`（`p2_system.lua:108,738-740`）、自身 `trial.lua:190` | `citizenid≤50`；`minutes 1..MaxSentence(120)`；`crimes:string[]`；`opts={replace?,caseId?,reason?,createdBy?}`（**现在**：`replace=true` → `ApplySentence('set')`，否则 `'add'`） | `true` / `false,'invalid_citizen'\|'invalid_sentence'\|'sentence_failed'` | **export 无鉴权**（调用方负责） | 现在幂等：active sentence 用 `UPDATE` 调整，不重复插行；`replace` 可改判 | **无 `police_audit`**，只 `custom-logs`（`prison.lua:87-90`） |
| `OpenCase(citizenid, officerSrc, crimes)` | `custom-police`（`p2_system.lua:566`） | 同上；`officerSrc` 必须在线且 `job∈{police,judge}` | `'CASE-0001'`（**string**）/ `false`（**无错误码**） | 要求 officer 在线 + 职业 | **非幂等**（`caseCounter+1`，`main.lua:18-20`） | 无 |
| `ResolveCase(caseId, opts)`（非 export） | `/trial`、`/plea`、`justice:server:startTrial` | `{mode='trial'\|'plea', actorSrc, judgeName}` | `verdict{}` / `nil,'invalid_mode'\|'case_not_found'\|'case_closed'` | 调用层校验（judge / police grade≥2 + 无在线法官） | 非幂等（第二次 `case_closed`） | 无 `police_audit`；判决镜像回写 `police_reports`（best-effort） |
| `Bus: justice` 服务 | 任何 `Bus.GetService('justice')` | `CreateCase/GetCase/GetActiveCases/AssignLawyer/SetVerdict/OpenCase/GetInmates/GetInmate/ReleaseInmate/GetOnlineJobCount` | 直接透出内部函数（无 envelope） | **无** | 视函数 | 无 |

证据：`custom-justice/server/prison.lua:12-66,68-78`、`custom-justice/server/main.lua:67-93,140-153,221-227`、`custom-justice/server/trial.lua:124-200`。

> **post-baseline（`2ae3da4`）**：`Imprison` 不再把 `metadata.injail` 当权威，而是先 `ApplySentence` 落 `justice_sentences` 再投影；trial/plea 用 `replace=true`，判决可改变正在服的刑期。新增的 5 个 sentence export（`GetSentence`/`RemainingSeconds`/`ApplySentence`/`AdjustSentence`/`ReleaseSentence`）见 §2.8。

### 2.6 `custom-director` — agent 动作代理

| Export | 方向 | 输入 | 输出 / 错误 | 鉴权 | 幂等 | 审计 |
|---|---|---|---|---|---|---|
| `Propose(agentId, actionType, params, idempotencyKey?, dryRun?)` | 外部脚本/MCP → director | `agentId`(pattern `^[A-Za-z0-9_-]{1,64}$`)、`actionType ∈ ACTIONS`、`params`（每动作白名单）、`idempotencyKey?≤128`、`dryRun:boolean` | `{ok=true,id,status,preview,result?,idempotent?}` / `{ok=false,code,message}` | agent token（HTTP 层）+ 动作分级；L2/L3 不自动执行 | **是**：同 key 同参数返回首行，`idempotent=true`；不同参数 `idempotency_conflict` | `agent_actions` 行；拒绝写 `agent_denials` |
| `Approve(id, approver)` | admin | `id:int`, `approver` 标注 | `{ok,status='executed'\|'failed'}` / `invalid_status`/`expired` | admin token（与 agent token 不同） | 否（状态机守卫 `approved`） | `approved_by/at`、`executed_at` |
| `Reject(id, approver, reason?)` | admin | `id`, `approver`, `reason≤255` | `{ok,status='rejected'}` | 同上 | 否 | 同上 |
| `Get(id)` / `List(status?, limit?)` | 读 | `limit≤100` | 动作行 | admin/agent | 读 | — |
| `Policy()` | 读 | 无 | 动作分级表 | agent | 读 | — |

证据：`custom-director/server/main.lua:1345-1480,1822-1842`、`custom-director/server/policy.lua:1290-1330`、`migrations/v2.3_agent_actions.sql:21-45`。

### 2.7 `custom-police` 客户端 export

| Export | 消费者 | 输入 | 输出 | 证据 |
|---|---|---|---|---|
| `IsHandcuffed()` | `qb-ambulancejob/client/main.lua:699` | 无 | `boolean`（本机玩家） | `custom-police/client/interactions.lua:5` |

> 客户端 export 只在**同客户端**可调用；它不构成服务端契约，不能用于鉴权（`qb-ambulancejob` 用它做 UI 分支是安全的，用它做权限就不是）。

### 2.8 post-baseline 新增契约（HEAD `3bbcab3`）

| 契约 | 形态 / 方向 | 输入 | 输出 / 错误 | 权限 / 审计 | 证据 |
|---|---|---|---|---|---|
| `CreateNpcCallout(templateId, officerSrc?)` | police export；调度器/控制台/MDT 可调 | `templateId ∈ {traffic_accident, suspicious_vehicle, store_robbery, armed_person}`；`officerSrc` 可为 nil/0（系统） | `{id,template,code,title,coords,location,status='open'}` / `false,'invalid_template'｜'player_not_found'｜'not_police'｜'not_on_duty'｜'limit_reached'｜'no_location'｜'db_error'` | 玩家 source 必须 police+onduty；`npc_callout` 命令另需 ACE `police.release`；审计 `npc.callout.create` | `custom-police/server/p4_npc.lua:100-146,415-435,450-453` |
| `SubmitNpcCalloutResult(source, incidentId, outcome, notes?)` | police export + net 事件 `police:server:NpcCalloutResult` | `outcome ∈ {resolved,arrest,failed,false_alarm}`；`notes ≤200` | `{id,status='closed',disposition,outcome}` / `false,'not_police'｜'invalid_incident'｜'invalid_outcome'｜'incident_not_found'｜'not_npc_callout'｜'not_assigned'｜'close_failed'` | `incident.update`；grade<2 必须是该 incident 成员；审计 `incident.close` + `npc.callout.resolve`；成功关闭发 $500（best-effort） | `p4_npc.lua:171-243,406-413,451` |
| `GetActiveNpcCallouts()` / `GetNpcCalloutTemplates()` | police 只读 export | 无 | 行集（id/template/code/title/priority/status/x/y/z，无 PII）/ `{id,...}` 字符串数组 | 无额外鉴权（供测试/诊断；MDT 走 `GetIncidents`） | `p4_npc.lua:392-401,452-453` |
| `police:client:NpcCallout` / `NpcCalloutEnd` | 服务端 → 客户端事件 | `(incidentId, templateId, {x,y,z,heading})` / `(incidentId)` | 客户端建/清场景，无回包 | 服务端只推给在勤且到场（`on_scene` 或 ≤80m）的警员；无审计 | `p4_npc.lua:345-350,153-167`、`client/npc_callouts.lua:528-575` |
| `prison:server:WorkReduction(minutes)` | qb-prison client → server 事件 | `minutes 1..5`（客户端只表达“完成一次劳动”） | 无直接回包；成功后 `prison:client:WorkReductionAck(remainingMinutes)` | 服务端校验 `injail>0`、55s/人冷却；调 `AdjustSentence(cid,-n)`；**不信任客户端剩余时间** | `qb-prison/server/main.lua:187-213` |
| `AdjustSentence(citizenid, deltaMinutes, reason)` | justice export | `deltaMinutes` 可负；`reason ≤255` | 剩余秒数（number）；无 active sentence 返回 0 | 幂等靠 `UPDATE ... WHERE status='active'`；减到 0 自动 `Release`；无 audit 行 | `custom-justice/server/sentence.lua:160-178,261-263` |
| `ReleaseSentence(citizenid, reason?, status?)` | justice export | `status ∈ {released,expired}`（其他值归 `released`） | `true`（真的迁移了一行）/ `false` | 只在 `status='active'` 时 UPDATE，可重试；`/unjail`、`police_release` 调用 | `sentence.lua:139-154,265-267`、`custom-police/server/commands.lua:235-246`、`p2_system.lua:969-978` |
| `ApplySentence` / `GetSentence` / `RemainingSeconds` | justice export（qb-prison/登录投影消费） | `citizenid`；`minutes`；`mode 'set'｜'add'` | 剩余分钟 / sentence 行（含 `remaining_seconds`）/ 剩余秒数 | `ends_at` 由 MySQL 时钟算；无 audit | `sentence.lua:42-67,91-135,249-259` |
| `idempotency_key` 参数 | `ArrestSubmit` / `ReportSubmit` 的 `params` 字段 | 8..128，`[A-Za-z0-9_-]` | 无效 `invalid_idempotency_key`；并发 `in_progress`；完成重放首次结果 | 账本 `police_write_intents`；无 TTL 的 `done` 行是已知风险 | `p2_system.lua:154-267`、v3.9 |
| `GetIncidents` 的 `npc_template` | `GetIncidents` 返回行字段 | 只读 | `npc_template`（`NULL`=普通警情，否则模板 id） | 由 `police_incidents.npc_template` 投影；MDT 用它标记 NPC 警情 | `p0.lua:204`、`migrations/v3.11_police_npc_callout.sql` |

**计数说明**：`police` 服务端 export 从 37 → 42（+`SweepStaleIncidents`、`CreateNpcCallout`、`SubmitNpcCalloutResult`、`GetActiveNpcCallouts`、`GetNpcCalloutTemplates`）；justice 从 2 → 7（+`GetSentence`、`RemainingSeconds`、`ApplySentence`、`AdjustSentence`、`ReleaseSentence`）。MDT action / query 数量不变（17/17），见 §5。

---

## 3. Net event 契约（跨资源部分）

### 3.1 入站（其他资源 → `custom-police` / `custom-justice` / `qb-prison`）

| 事件 | 生产者 → 消费者 | 输入 | 权限 / 校验 | 幂等 | 审计 | 超时 / 失败 | 证据 |
|---|---|---|---|---|---|---|---|
| `police:server:policeAlert` | qb-drugs / qb-storerobbery / qb-houserobbery / custom-vehicles client → police | `(text:string)` | `job.type=='leo'` 或 `job.name=='ambulance'` | 否 | 无 | 无回执；广播给所有 on-duty leo | `custom-police/server/main.lua:179-196` |
| `police:server:autoAlert` | custom-vehicles（server `TriggerEvent`，`source=0`）→ police | `(coords:{x,y,z}, text:string)` | `source==0` 放行；否则需 `PolicePolicy.Can(...,'incident.create')`；10s/来源冷却；坐标与文本清洗 | 否（冷却近似） | 仅 `print`，**无 `police_audit`** | 无；被冷却静默丢弃 | `custom-police/server/main.lua:198-237` |
| `police:server:UpdateBlips` | qb-ambulancejob client → police | 无 | 无（只重算） | 是 | 无 | 无 | `custom-police/server/main.lua:239-251` |
| `police:server:SetTracker` | tcity-dashboard server → police | `(playerId)` | dashboard 侧限流 + on-duty leo | 否 | custom-logs | 无 | `[system]/tcity-dashboard/server/police_api.lua:230-263`、`custom-police/server/main.lua:283-306` |
| `police:server:plateFlagged` | tcity-dashboard / 客户端 → dashboard | `(plate, reason)` | 2s/玩家冷却 + leo | 是（覆写） | custom-logs | 无 | `[system]/tcity-dashboard/server/police_api.lua:291-300` |
| `police:server:JailPlayer` | 无调用方（**死路径**） | `(playerId, time)` | `src~=0` 直接 return；随后仍做 2.5m 距离校验与 `DropPlayer(src)` | 否 | `arrest.register`（legacy） | `source=0` 时距离校验几乎必然失败，路径不可用 | `custom-police/server/interactions.lua:139-186` |
| `justice:server:registerArrest` | `/arrest`（`TriggerEvent`）→ justice | `(suspectSrc, crimes[], officerSrc?)` | `src = officerSrc or source`，仅校验 `job.name=='police'`（**不查 onduty**）；客户端可伪造 `officerSrc` | 否 | custom-logs | 无 | `custom-justice/server/arrest.lua:11-13,147-162` |
| `justice:server:imprison` | 兼容入口 | `(citizenid, minutes, crimes)` | 调用者必须 `police`/`judge`，否则打印 SECURITY 并丢弃 | 交给 `Imprison` | 无 | 无 | `custom-justice/server/prison.lua:68-78` |
| `justice:server:startTrial` | 旧客户端 | `(caseId)` | `job.name=='judge'` | 非幂等 | custom-logs | 无 | `custom-justice/server/trial.lua:206-225` |
| `prison:server:SetJailStatus` | qb-prison client | `(jailTime:number)` | **现在**：忽略客户端值，改查 `custom-justice:RemainingSeconds`；justice 不可用时才用客户端值并 clamp 0..120 | 是（同一剩余分钟的重复调用等价） | 无 | 无 | `qb-prison/server/main.lua:14-50` |
| `prison:server:WorkReduction` | qb-prison client | `(minutes:1..5)` | 校验 `injail>0` + 55s/人冷却 + 数值范围；调 `AdjustSentence`；回报 `WorkReductionAck` | 服务端权威计时；客户端只能请求 | 无 | 冷却无审计 | `qb-prison/server/main.lua:187-213` |
| `police:server:NpcCalloutResult` | custom-police client | `(incidentId, outcome, notes?)` | `incident.update` + `npc_template` 非空 + outcome 枚举 + grade<2 需成员 | 关闭走幂等 P0 close（重复上报返回 `idempotent`，不二次发奖） | `incident.close` + `npc.callout.resolve` | `close_failed` 时客户端收到 Notify | `custom-police/server/p4_npc.lua:171-243,406-413` |
| `prison:server:GiveJailItems` / `SaveJailItems` / `ResetJailItems` | qb-prison client | 无 | **现在**：只在 `injail>0` 收物，`$80` 每刑期一次，`Give` 仅在 `injail=0` 时归还一次 | 是一句一次 | 无 | 无 | `qb-prison/server/main.lua:52-110` |

### 3.2 出站（`custom-police` / `custom-justice` → 其他资源 client）

| 事件 | 消费者 | 载荷 schema | 备注 | 证据 |
|---|---|---|---|---|
| `phone:client:newNotification` | `custom-phone/client/main.lua:499` → NUI | `{id:number, title≤200, content≤500, timestamp:'YYYY-MM-DD HH:MM:SS', is_read:false, app_id?:string≤32, origin?='server'}` | `app_id` 必须是内置 app id（如 `banking`）或 `PhoneApps` 注册 id（`Notifications.svelte:21-23` 走 `dyn:<id>`）；`id=0` = **客户端不要回存，但行已落库**（p0/p2_system 先 INSERT 再推 0，`p0.lua:104-109`、`p2_system.lua:45-51`；p1 与罚单通知推真实 insert id） | `custom-police/server/p0.lua:108-112`、`p1.lua:30-33`、`p2_system.lua:48-51,288-291` |
| `prison:client:Enter` | qb-prison client | `(time:number)` 分钟 | **调用者白名单**：`qb-policejob`/`custom-police`/`custom-justice`/`qb-ambulancejob`/自身 | `qb-prison/client/main.lua:225-234`、`custom-police/server/p2_system.lua:115,612`、`custom-justice/server/prison.lua:47` |
| `prison:client:UnjailPerson` | qb-prison client | 无 | 触发 `SetJailStatus 0` + 归还物品；**不恢复职业** | `qb-prison/client/main.lua:311-330`、`custom-police/server/p2_system.lua:827` |
| `police:client:SpawnBackup` | custom-police client | `(requestId:string, 1..64)`（camelCase，历史命名） | 只 spawn/动画；服务端已裁决权限/冷却/上限 | `custom-police/server/p2_system.lua:364`、`client/backup.lua:497-504` |
| `police:client:NpcCallout` | custom-police client | `(incidentId:number, templateId:string, coords:{x,y,z,heading})` | 客户端只建场景、不建单、不选奖励；服务端只推给到场/≤80m 的在勤警员 | `custom-police/server/p4_npc.lua:345-350`、`client/npc_callouts.lua:528-560` |
| `police:client:NpcCalloutEnd` | custom-police client | `(incidentId:number)` | 外部关闭/掉线/服务端结算时清理实体；客户端 300m/60s 也会自清 | `p4_npc.lua:153-167,236-239,266-273`、`client/npc_callouts.lua:562-575` |
| `prison:client:WorkReductionAck` | qb-prison client | `(remainingMinutes:number)` | 工作减刑成功后刷新 UI；权威值来自 `justice_sentences` | `qb-prison/server/main.lua:210-212`、`client/main.lua:225` |
| `police:client:policeAlert` | custom-police client；qb-prison prisonbreak | `(coords:vector3, text:string)` | 与 `qb-phone:client:addPoliceAlert(table)` 同义不同形（双形状） | `custom-police/server/main.lua:191-192`、`qb-prison/client/prisonbreak.lua:110` |
| `justice:client:lawyerNotify` | justice client | `{caseId:string, suspectName, crimes[], baseMinutes}`（**camelCase**） | 命名与其余 payload 不一致 | `custom-justice/server/arrest.lua:66-73`、`client/main.lua:23-40` |
| `justice:client:enterPrison` / `released` / `verdictReceived` | justice client | `{sentenceMinutes,startTime,crimes,reductions}` / 无 / `verdict{}` | 仅当 qb-prison 未启用的回退路径 | `custom-justice/server/prison.lua:49-52,90-96`、`client/main.lua:42-100` |

### 3.3 命名现状（不做重命名，仅记录）

| 前缀 | 现有风格 | 例 | 问题 |
|---|---|---|---|
| `police:*` | `server:`/`client:` + 大小写混用 | `police:server:autoAlert`、`police:server:UpdateCurrentCops`、`police:server:spawnObject` | camel/Pascal/lower 三种并存 |
| `custom-police:*` | 新代码 `server:<verb>` | `custom-police:server:setStatus`、`custom-police:server:911` | 与 `police:*` 语义重复（同一个资源两套前缀） |
| `qb-policejob:*` | 保留兼容 | `qb-policejob:server:stash`、`qb-policejob:ToggleDuty` | 刻意保留（`STATUS.md:25`），无迁移计划 |
| `phone:*` | 方向前缀清晰 | `phone:server:appQuery`、`phone:client:newNotification` | 命名规范最好的一组 |
| `justice:*` / `prison:*` | 方向前缀清晰 | `justice:server:imprison`、`prison:client:Enter` | `Enter` 为 Pascal，其余 lower |
| `evidence:*` | 老 qb 风格 | `evidence:server:CreateBloodDrop` | 与 `police:*` 无边界（都在 custom-police 内） |

---

## 4. QBCore callback 契约

| Callback | 提供者 | 消费者 | 输入 | 输出 | 权限 | 证据 |
|---|---|---|---|---|---|---|
| `phone:server:appQuery` | custom-phone | client NUI 桥（`client/main.lua:849-855`） | `(appId, queryName, params)` | `{success:true,data}` / `{success:false,error}` | `audience` + 下游 cap | `custom-phone/server/main.lua:1376-1380` |
| `phone:server:appAction` | custom-phone | 同上（`:857-863`） | `(appId, actionName, params)` | 同上 | 同上 | `custom-phone/server/main.lua:1382-1386` |
| `phone:server:getPhoneApps` | custom-phone | 同上（`:843-847`） | 无 | `{success:true, apps:[{id,label,icon,queries[],actions[]}]}` | `audience` 过滤 | `custom-phone/server/main.lua:1372-1374`、`phone_apps.lua:82-101` |
| `phone:server:getMyCitations` | custom-phone → police | Banking「我的罚单」 | 无 | `{success,rows[],count}` / `{success:false,error:'unavailable'}` | 归属校验在 police 侧 | `custom-phone/server/main.lua:1391-1399` |
| `phone:server:payCitation` | custom-phone → police | Banking 付款 / `/paycitation` | `(citationId)` | `{success,id,amount}` / `{success:false,error}` | `not_owner` 等（`p1.lua:146-152`） | `custom-phone/server/main.lua:1401-1414` |
| `police:server:IsPoliceForcePresent` | custom-police | **qb-houses** | 无 | `boolean`（grade≥2 在线即 true） | 无 | `custom-police/server/main.lua:125-136`、`qb-houses/client/main.lua:1377` |

**失败语义**：回调不返回时，客户端 `QBCore.Functions.TriggerCallback` 永不回调，NUI `fetch` 也**没有超时**（`web/src/utils/nui.ts:111-130`）→ UI 会一直等。现状只能靠 `res or {success:false,error:'no_response'}` 兜底，而这只在 cb 被调用时生效（`client/main.lua:852-855`）。

---

## 5. PhoneApps query / action 契约

框架契约：`PhoneApps.Register` → `audience`（`jobs[]` + `onduty`）→ `Query`/`Action` 用 `pcall` 包装，异常转 `query_failed`/`action_failed`（`custom-phone/server/phone_apps.lua:54-143`）。

| 类型 | 名称 | 下游调用 | 错误码是否透传 | 证据 |
|---|---|---|---|---|
| query | `me` | `exports['custom-police']:GetUnits()` | 吞异常 → `{rows:[],count:0}` | `police_mdt.lua:38-64` |
| query | `units` | `GetUnits` | 吞 | `police_mdt.lua:65-69` |
| query | `incidents` | `GetIncidents(status)` | 吞 | `:70-76` |
| query | `citizen` | `LookupCitizen` | 吞（`not_found` 也变空列表） | `:77-85` |
| query | `vehicle` | `LookupVehicle` | 吞 | `:86-94` |
| query | `citations` | `GetCitations` | 吞 | `:95-99` |
| query | `reports` | `GetReports` | 吞 | `:100-104` |
| query | `evidence` | `GetEvidence` | 吞 | `:105-109` |
| query | `case_detail` | `GetCaseDetail` | 吞（`audit_unavailable` 也变空） | `:110-114` |
| query | `cases` / `bolos` / `warrants` / `arrests` | 对应 export | 吞 | `:115-134` |
| query | `charges` | `GetCharges` | 吞 | `:135-141` |
| query | `evidence_chain` | `GetEvidenceChain` | 吞 | `:142-148` |
| query | `audit` | `GetAudit` | 吞（`rank_too_low` 变空 → 前端只能看出"没数据"） | `:149-153` |
| query | `officers` | 本地 `onDutyPolice()`（不调 export） | — | `:154-164` |
| action | `set_status` | `SetUnitStatusForSource` | **吞**（`ok and res==true` → 裸 boolean） | `:167-172` |
| action | `assign` | `AssignUnit` | **吞** | `:173-178` |
| action | `create_case` / `create_bolo` / `request_warrant` / `decide_warrant` / `register_arrest` / `register_evidence` / `issue_citation` / `create_report` / `enroute` / `on_scene` / `clear` | 对应 export | **吞**（`ok and res ~= false`） | `:179-247` |
| action | `alert` | 直接写 `phone_notifications` + 广播 | 只返回 `{sent}` | `:248-275` |
| action | `arrest_submit` | `ArrestSubmit` | **不透传**（失败一律 `return false` → `action_rejected`，`police_mdt.lua:201`） | `:199-203` |
| action | `report_submit` | `ReportSubmit` | **透传** | `:204-208` |
| action | `request_backup` | `RequestBackup` | **透传** | `:213-217` |

**结论**：17 个 action 中 **2 个**透传结构化错误（`report_submit` / `request_backup`），**14 个**被压平（13 个 `ok and res ~= false` + `arrest_submit`），`alert` 为特例（成功 `{sent}`、失败压平，`phone_apps.lua:141`）。MDT 因此为 `action_rejected` 写了一整张兜底文案表（`web/src/apps/PoliceMDT.svelte:400-421`），仍无法区分"职级不足"与"数据库错误"。

**post-baseline 重数（`3bbcab3`）**：query 17 / action 17 **数量未变**；`arrest_submit` 与 `report_submit` 都改为“把 params（含 `idempotency_key`）原样转发”，但 `arrest_submit` 仍把 `ok=false` 压成 `false`（`police_mdt.lua:203-207`），所以透传数仍是 **2**、压平仍是 **14**、`alert` 特例仍是 1。**没有新增 MDT action**：NPC 警情/服刑由服务端调度器、客户端场景事件与管理命令驱动，不经过 PhoneApps action。

---

## 6. Director action 契约

### 6.1 HTTP 信封

| 项 | 内容 | 证据 |
|---|---|---|
| 路由 | `POST /agent/v1/act`、`GET /agent/v1/policy`、`GET /agent/v1/actions`、`/actions/{id}`、`/actions/{id}/approve`、`/actions/{id}/reject` | `custom-director/server/http_api.lua:110-131` |
| 请求体 | `{type:string, args:object, idempotency_key?:string, dry_run?:boolean}`，`≤16KB` | `http_api.lua:178-207,26` |
| 鉴权 | `Authorization: Bearer <agent token>`；审批端点另需 admin token，两者不可相同 | `http_api.lua:12-19`、`custom-director/server/live_api.lua:77` |
| 返回 | 成功 `{ok:true,id,status,preview,result?}`；`pending_approval` → **202** | `http_api.lua:134-149` |
| 错误码 → HTTP | `disabled`→503、`not_found`→404、`expired`→410、`idempotency_conflict`/`invalid_status`/`execution_failed`→409、`db_error`/`quest_catalog_unavailable`→500、其余→400、`body_too_large`→413 | `http_api.lua:134-149,203-205` |
| 检查顺序（契约的一部分） | disabled→token→route→method→admin token→admin auth→agent auth→policy→agent id→body→dispatch | `http_api.lua:12-19` |

### 6.2 警察相关动作

| 动作 | 风险 | 审批 | 自动执行 | 输入 schema（normalize 后） | 执行器 → 下游 | 预检 | 证据 |
|---|---|---|---|---|---|---|---|
| `police_incident_create` | L1 | 否 | 是 | `title 3..120`、`code ^[A-Z0-9_-]{1,16}$`（默认 911）、`priority 1..3`、`details≤1000` | `custom-police:CreateIncidentSystem('action:<id>', params)` | `WORLD_ACTIONS` 成员：不需要目标玩家 | `policy.lua:62-67,159-161,452-500`、`main.lua:1209-1222,1287` |
| `police_assign_unit` | L2 | 是 | 否 | `incident_id:positive int`、`citizenid ^[%w_%-]{1,11}$` | `custom-police:AssignUnitSystem(actionId, incident_id, citizenid)` | 目标玩家不必在线；preview 带 `incident_id/unit` | `policy.lua:50-55,418-429,1090-1094`、`main.lua:1189-1197,1288` |
| `police_jail_player` | L3 | 是 | 否 | `citizenid ^[%w_%-]{1,11}$`、`minutes 1..120`、`reason 3..240`（禁控制符） | `custom-police:JailSystem(actionId, citizenid, minutes, reason)` | 需在线目标 | `policy.lua:56-61,431-450,1096-1100`、`main.lua:1199-1207,1289` |

**失败语义**：执行器把下游 `false` 统一映射为 `police_rejected`，pcall 异常映射为 `police_unavailable: <150 chars>`（`main.lua:1194-1195,1204-1205,1214-1218`）。**下游错误码全部丢失**（`incident_not_found`/`unit_off_duty` 都成 `police_rejected`），与 `FLOW_INTERNAL.md:249` 的日志旁证一致。

**重试/幂等**：`idempotency_key` 全局 UNIQUE；同 key 同参数返回首次结果、`idempotent=true`；同 key 不同参数 → 409（`main.lua:1370-1389,1458-1467`、`migrations/v2.3_agent_actions.sql:38`）。L1 动作 3 次重试只产生 1 个 incident（前提是调用方复用 key）。

---

## 7. Agent tool 契约

| 工具 | 通道 / 路由 | 对应 director action / 端点 | 风险 | 审批 | 幂等 | `since` | 验证 |
|---|---|---|---|---|---|---|---|
| `get_police_board` | read / live | `GET /agent/v1/live/police/board` | L0 | 否 | none | 1.1.0 | 无 |
| `apply_police_incident` | write / director | `police_incident_create` | L1 | 否 | required | 1.2.0 | `get_action.status=='executed'`（10s） |
| `apply_police_assignment` | write / director | `police_assign_unit` | L2 | **是** | required | 1.3.0 | 同上 |
| `apply_police_jail` | write / director | `police_jail_player` | L3 | **是** | required | 1.3.0 | 同上 |

| 项 | 现状 | 证据 |
|---|---|---|
| 注册表版本 | `registry_version 1.5.0`、`schema_version 1`（35 工具） | `tools/agent_tools.json:3-4` |
| Lua 镜像 | 由 `tools/agent_tools.py --write` 生成，`DO NOT EDIT`，含 params/required/schema | `custom-director/shared/agent_tools.lua:1-2,9-36` |
| 输入上限 | `citizenid ≤11`（与 `players.citizenid varchar(11)` 一致）、`minutes 1..120`、`title ≤120` | `tools/agent_tools.json:100-163`、`tests/fixtures/tcity_schema.sql:624-627` |
| live 契约 | 无 `{ok,data}` 信封（刻意），空数组用 `__jsontype='array'` 保证 JSON `[]` | `custom-director/server/live_api.lua:12,61-66,493-502` |
| 限流 | **注册表声明 60/min burst 10，服务端默认 120/min burst 40**（convar 可覆盖） | `tools/agent_tools.json:605-640` vs `live_api.lua:107-108` |
| PII | 板子不返回 citizenid/姓名/坐标 | `live_api.lua:480-492` |

---

## 8. 命名与错误码规范（现状 → 建议）

### 8.1 字段命名

| 规则 | 现状 | 违反点 | 建议 |
|---|---|---|---|
| 字段 `snake_case` | 大多数 table 契约符合 | `justice:client:lawyerNotify {caseId,suspectName,baseMinutes}`（`arrest.lua:68-73`）、`police:client:SpawnBackup(requestId)`（`client/backup.lua:497`） | 新 payload 一律 snake_case；旧 payload 客户端兼容读取，不改发送端 |
| id 命名 `<entity>_id` | `incident_id`/`case_id`/`report_id`/`evidence_id` 一致 | `request_id` 带前缀字符串（`BU-...`），`case_no` vs `case_id` 语义并行 | 保留；文档明确"`request_id` 是不透明字符串" |
| 时间 | `os.date('%Y-%m-%d %H:%M:%S')` 字符串（通知）、`os.time()` 整数（live/verdict） | 两种格式并存（`p0.lua:110` vs `live_api.lua:499`） | 单条契约内只用一种；跨契约不转换 |
| 金额 | 整数美元 | `police_citations.amount INT UNSIGNED` | 保持整数，禁止浮点 |
| 坐标 | `{x,y,z}` 显式对象（通知/autoAlert） vs `vector3`（client 事件） | 同一概念两种编码（`main.lua:190` vs `p2_system.lua:364`） | 跨资源边界只用 `{x,y,z}` |

### 8.2 统一 fail 表（建议，作为目标契约）

> 现状是 5 套错误码来源（`PolicePolicy`、各 export、PhoneApps、director、justice），前缀不一致、语义重叠。目标：**一张扁平表 + 5 个类别前缀**，所有契约只返回 `{ok=false, error=<code>}`（禁止裸 boolean）。

| 类别 | 语义 | 可重试 | 现有 code（示例） | 目标 code |
|---|---|---|---|---|
| `perm.*` | 身份/职级/审批 | 否 | `not_police`,`not_on_duty`,`rank_too_low`,`app_forbidden`,`bolo_forbidden`,`case_forbidden`,`unknown_capability` | `perm.not_police` / `perm.not_on_duty` / `perm.rank_too_low` / `perm.forbidden` |
| `input.*` | 参数非法 | 否（改参数） | `invalid_*`,`duplicate_charge`,`missing_case` | `input.invalid` + `field` | 
| `state.*` | 状态冲突 | 是（状态变化后） | `incident_not_found`,`unit_not_found`,`unit_off_duty`,`case_closed`,`already_jailed`,`target_not_cuffed`,`too_far`,`citizen_offline`,`not_pending`,`cooldown`,`limit`,`already_paid` | `state.conflict` + `reason` |
| `deps.*` | 依赖不可用 | 是（退避） | `db_error`,`audit_unavailable`,`police_unavailable`,`unavailable`,`query_failed`,`action_failed`,`open_case_failed`,`jail_failed` | `deps.db` / `deps.audit` / `deps.downstream` |
| `internal.*` | 不可归类 | 否（需日志） | `action_rejected`（14 处兜底）、`invalid_status`（director 409） | **应被消灭**；仅保留 `internal.unknown` |

**三条硬规则**：
1. **禁止裸 boolean**：`set_status`/`assign`/`create_case`/`create_bolo`/`request_warrant`/`decide_warrant`/`register_arrest`/`register_evidence`/`issue_citation`/`create_report`/`enroute`/`on_scene`/`clear` 共 13 个 action 必须改为返回 `{ok,error}`；`arrest_submit` 也把失败压成 `false`（不透传，`police_mdt.lua:201`），合计 **14 个**（`police_mdt.lua:167-247`）。
2. **禁止一码两义**：`not_police` 现在同时表示"不是警察"与"审计期间玩家已离开"（`p2_system.lua:197` vs `:238`）；以 `assign` 为例，`police_rejected` 覆盖 4 种下游原因（`incident_not_found`/`unit_not_found`/`unit_off_duty`/`audit_unavailable`，`p2_system.lua:83-87`；`main.lua:1194-1195`）。
3. **禁止动态拼接 code**：`'already_'..row.status`（`p1.lua:147`）会产生 `already_unpaid`/`already_void` 等未登记 code，前端无法静态映射。

### 8.3 现状错误码分布（供迁移对照）

| 来源 | 数量级 | 代表 | 证据 |
|---|---|---|---|
| `PolicePolicy` | 5 | `not_police`,`not_on_duty`,`rank_too_low`,`unknown_capability` | `shared/policy.lua:41-46` |
| `custom-police` export | ~30 | 见 §2 | `p0/p1/p2_*/p3_cases` |
| `PhoneApps` 框架 | 9 | `app_not_found`,`app_forbidden`,`query_failed`,`action_rejected` | `phone_apps.lua:105-142` |
| `custom-justice` | 5 | `invalid_citizen`,`invalid_sentence`,`case_not_found`,`case_closed`,`invalid_mode` | `prison.lua:14-16`、`trial.lua:127-133` |
| `custom-director` | ~20 | `unsupported_action`,`idempotency_conflict`,`police_rejected`,`expired` | `policy.lua:406-409`、`main.lua:1378-1389` |

---

## 9. 事件命名建议（不改存量，新增才遵守）

| 目标规则 | 说明 | 反例（现状） |
|---|---|---|
| `<resource>:<c2s\|s2c>:<domain>_<verb>` | 方向显式、snake_case、资源名不重复出现在 payload | `police:server:autoAlert`、`police:server:UpdateCurrentCops` |
| 一个资源只用一个前缀 | `custom-police` 应只保留 `police:*`（`custom-police:*` 仅 2 条且语义重复） | `custom-police:server:setStatus`、`custom-police:server:911` |
| 同概念只保留一种形状 | 警用广播二选一：`(coords,text)` 或 `{title,coords,description}` | `police:client:policeAlert` vs `qb-phone:client:addPoliceAlert` |
| 破坏性变更需双写 ≥1 个版本 | 旧名继续注册为别名（`qb-policejob:*` 已按此保留，`STATUS.md:25`） | `custom-police:server:setStatus` 无别名 |
| 不新增 `qb-` 前缀 | 新事件不得用历史前缀，避免与 qb-* 生态混淆 | 新增代码目前遵守 |

---

## 10. 契约冲突清单

| ID | 冲突 | 影响 | 证据 |
|---|---|---|---|
| X-01 | **环形依赖**：justice 依赖 police；police 运行时调 justice export 但未声明依赖 | 冷启动顺序不定；justice 未起时 `Imprison` 走 fallback（`metadata.injail` + `prison:client:Enter`），下次启动双计时风险 | `custom-justice/fxmanifest.lua:21`、`custom-police/server/p2_system.lua:108-117,604-614` |
| X-02 | **税率/罪名目录双份**：`PoliceCharges`（13 条）自称镜像 justice `Config.Justice.Crimes`（13 条），但无 export、无测试强制一致；B_PLAN 计划的 `GetChargeCatalog` **未实现** | 改一处罪名 → 逮捕刑期与法庭量刑不一致 | `custom-police/shared/charges.lua:2-4`、`custom-justice/config.lua:9-26`、`custom-justice/server/main.lua:221-227` |
| X-03 | **案件号类型冲突**：`police_reports.case_id BIGINT` ↔ justice `CASE-0001` 字符串；代码只写数字、把字符串静默丢弃 | `CASE-0001` 的判决/回写找不到对应 report（`justice_case_id` 兜底，但 `case_id` 被污染） | `p2_system.lua:580-595`、`migrations/v3.6_police_justice_case.sql` |
| X-04 | **错误码被 clamp**：14 个 action 把失败压平（13 个 `ok and res ~= false` + `arrest_submit`）→ `action_rejected` | MDT 无法区分权限/参数/依赖错误；director 日志只有 `police_rejected` | `police_mdt.lua:167-247`、`phone_apps.lua:138-142`、`main.lua:1194-1195` |
| X-05 | **出勤状态双写**：`job.onduty` 与 `police_units.status` 都可写且入口不同；`SetUnitStatusForSource` 不校验 onduty/grade | `onduty=true + unit=off_duty` 合法存在；派单/权限/UI 各读一套 | `p0.lua:262-270,294-309`、`TECH_DEBT.md:5-24` |
| X-06 | **通知绕过 owner**：`custom-police` 直接 `INSERT INTO phone_notifications`，绕过 `custom-phone` 的 `StoreNotification/PhoneNotify`（后者负责清 `phoneDataCache` 并校验 `app_id`） | 列表缓存最多滞后 30s（`custom-phone/server/main.lua:351`）；`app_id` 由 police 硬编码，phone 侧正则/长度校验被绕过 | `custom-police/server/p0.lua:104-107`、`p1.lua:23-25`、`p2_system.lua:45-47,282-284` vs `custom-phone/server/main.lua:223-262` |
| X-07 | **agent 逮捕不可见**：`JailSystem` 仍写 `police_arrests`，但 `GetArrests`/案件详情只读 `police_reports(kind='arrest')` | agent 判的刑在 MDT 逮捕历史里查不到（只有 union 的 `case_id` 路径能看到） | `p2_system.lua:118-121`、`p3_cases.lua:212-227`、`B_PLAN.md:54` |
| X-08 | **限流契约不一致**：注册表 60/min + burst 10 vs 服务端 120/min + burst 40 | 客户端按注册表退避会过度保守；按 120 调会打满注册表假设 | `tools/agent_tools.json:605-640`、`custom-director/server/live_api.lua:107-108` |
| X-09 | **legacy jail 不可达**：`police:server:JailPlayer` 只接受 `source=0`，但仍做 2.5m 距离校验并 `DropPlayer(src)` | 该兼容入口实际无法工作，且 `DropPlayer(0)` 是无效调用 | `custom-police/server/interactions.lua:139-149` |
| X-10 | **`officerSrc` 可伪造**：`justice:server:registerArrest` 用网络参数决定操作者身份 | 客户端可冒用他警身份登记案件 | `custom-justice/server/arrest.lua:11-13,161` |
| X-11 | **死契约**：`police:GetDutyPlayers`、`police:GetCops`、`police:IsSilencedWeapon` 无任何消费者 | 误改会静默破坏"以为有人用"的兼容面 | `custom-police/server/main.lua:75,90,106` |
| X-12 | **双层信封**：`GetCaseDetail` 裸表 → PhoneApps `{rows:[res]}` → UI `rows[0]` | 字段改名需同步 3 处；错误场景返回空 rows 而非 error | `p3_cases.lua:259-265`、`police_mdt.lua:110-114` |
| X-13 | **`CreateReport` / `ReportSubmit` 双写者同表**，`police_reports.status` 的 `approved` 值**无人写入** | 状态机是摆设；两个写者字段集不同（旧路径无 kind/bolo/location） | `p1.lua:107-113`、`p2_system.lua:733-739`、`migrations/v2.9_police_p1.sql:20-21` |

### 10.1 冲突现状（post-baseline，`3bbcab3`）

| ID | 现在 | 说明 / 证据 |
|---|---|---|
| X-01 | ⚠️ 部分缓解 | 环形依赖仍在（`custom-justice/fxmanifest.lua:20-22` 依赖 police；police 未声明 justice）；但送监已由 `justice_sentences` 落库，fallback 失败不会再造成“双计时”。 |
| X-02 | ❌ 未变 | 罪名目录仍两份硬编码（`custom-police/shared/charges.lua` vs `custom-justice/config.lua`），无 export/测试强制一致。 |
| X-03 | ⚠️ 部分缓解 | `justice_case_id` 仍写 `VARCHAR`；`case_id` 只写数字（`p2_system.lua:714-729` 用 `tonumber` 守卫），不会再污染 BIGINT。双案件号仍并存。 |
| X-04 | ❌ 未变 | 14/17 action 仍压平（见 §5 post-baseline 重数）。 |
| X-05 | ✅ police 侧已解决 | 10-8/10-7 走 `SetJobDuty` 投影，`syncDuty` 只做投影/清理（`p0.lua:406-425,567-599`）；`job.onduty` 在 police 之外仍有写者（见 07 FIT-01）。 |
| X-06 | ❌ 未变（+1） | `custom-police` 仍直写 `phone_notifications`；新增 NPC 警情通知在 `p4_npc.lua:79-82`，写者变 5 处（p0/p1/p2_system×2/p4_npc）。 |
| X-07 | ❌ 未变 | `JailSystem` 仍写 `police_arrests`（`p2_system.lua:118-121`），`GetArrests` 仍只读 report。 |
| X-08 | ❌ 未变 | 注册表限流与服务端默认仍不一致。 |
| X-09 | ❌ 未变 | legacy `police:server:JailPlayer` 仍在，`source=0` 路径仍不可用。 |
| X-10 | ❌ 未变 | `justice:server:registerArrest` 仍用客户端 `officerSrc`。 |
| X-11 | ❌ 未变 | 3 个死 callback/事件仍无消费者。 |
| X-12 | ❌ 未变 | `GetCaseDetail` 双层 envelope 仍在。 |
| X-13 | ❌ 未变 | `CreateReport`（`p1.lua:94-121`）与 `ReportSubmit`（`p2_system.lua:819+`）仍双写；`approved` 仍无写者。 |

---

## 11. 建议先统一的 3 个契约

> 选择标准：跨资源调用频次最高、错误语义最贵、修改面最小（都只改"返回形状"与"一个字段"，不新增表）。

| 顺序 | 契约 | 统一内容 | 为什么先做 | 影响面 |
|---|---|---|---|---|
| **1** | `ArrestSubmit` + `custom-justice:Imprison` 配对 | ① 统一 `{ok,error,detail}` 与 §8.2 fail 表；② 增加可选 `idempotency_key`（服务端按 key 去重，重复提交返回首次 `report_id`）；③ justice 侧 `Imprison` 改返回 `{ok,error}`，与 `OpenCase` 的裸 `false` 对齐；④ `open_case` 失败时明确"记录已保留/已回滚" | 唯一同时写 5 张表 + 跨 2 个资源的写路径；当前重复提交会产生双报告、孤儿 justice 案件、`jailed=true` 却 `ok=false` 的歧义返回 | `p2_system.lua:336-662`、`prison.lua:12-66`、`police_mdt.lua:199-203,563-600` |
| **2** | PhoneApps `appAction` 的 fail 透传 | 14 个压平的 action 统一返回 `{ok=false,error=<code>}`；`PhoneApps.Action` 不做二次归类；MDT 删掉 `action_rejected` 兜底表 | 一次改动消灭 14 个契约的错误盲区；不需要改任何 export 签名（export 已返回 `false,reason`，只是 handler 丢掉了） | `police_mdt.lua:167-247`、`phone_apps.lua:128-143`、`PoliceMDT.svelte:400-421` |
| **3** | 通知契约 `phone_notifications`（唯一写者 = `custom-phone`） | police 改为调用 `custom-phone` 的 `PhoneNotify`（或触发 `phone:server:notify`），不再直接 INSERT；`app_id` 白名单在 phone 侧校验；`id=0` 的"未落库推送"退役 | 现在 `custom-police` 3 个文件 4 处 + `police_mdt` app 1 处直接写同一张表，绕过缓存失效与 `app_id` 校验；通知是玩家可感知的最后一步，坏了最难查 | `custom-police/server/{p0,p1,p2_system}.lua` vs `custom-phone/server/main.lua:223-262` |

**不建议现在动的**：事件重命名（收益低、回归面大，且 `qb-policejob:*` 兼容是刻意保留）、`police_arrests` 下线（需先补 agent 路径的可见性，X-07）、`ResolveCase` 落库（属 04 的数据所有权议题，见 [04-data-ownership.md](04-data-ownership.md) §5）。

---

## 12. 未验证 / 边界

- 未实机调用任何契约为"通过"证据；所有结论来自源码静态阅读（FLOW_INTERNAL 同样口径）。
- 未查询数据库，`police_reports`/`agent_actions` 实际行数与错误分布未采样。
- `custom-director` 的 `AgentPolicy.ACTIONS` 共 21 条，本文只展开 3 条警察动作；其余见 `T-CityLite.base/docs/agent/ACTIONS.md`。
- `Bus` 服务面（`Bus.RegisterService('justice', ...)`）是注册表而非强类型契约，未逐条测试。
