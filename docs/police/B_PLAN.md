---
id: police-b-plan
type: plan
status: active
system: justice
owner: hermes
updated: 2026-10-24
review_by: 2027-04-30
---

# 方案 B 落地计划（已拍板）

决策：B 平衡；接受一次逮捕提交；证据/BOLO 降级为报告附件/标签；法庭保留但降级；
罚单金额由罪名目录自动 + ±20% 滑轨；MDT 压到 5 页。

目标步数：逮捕 **6** / 罚单 **3** + 滑轨 / 报告 **3** + 一段正文。
目标表：9 张；目标 MDT：5 页。

---

## 1. 目标流程

### 1.1 一次逮捕（6 步）

1. `/cuff`（或交互菜单）上铐；
2. `/escort` 押运（可跳过，步行押解）；
3. 打开 MDT → **Report 页**自动带入：目标 citizenid、最近警情、当前警员、时间、坐标；
4. 选罪名（目录来自 justice charges，自动求和刑期与罚款）；
5. 提交 → 同一事务写 `police_reports(kind='arrest')` + `police_citations`（可选）+ `police_evidence`（可选）+ `police_audit`，并送监；
6. 可选：点「开庭」创建 justice 案件；法官不在线时走认罪协议自动判决。

合并后下线：`/jail` 手输、MDT 逮捕 tab、`/arrest` 命令（保留导出兼容）。

### 1.2 罚单（3 步 + 滑轨）

1. Report 页选人（自动带入）；
2. 选罪名 → 金额自动 = `base × [0.8,1.2]` 滑轨；
3. 提交 → 写 `police_citations`，通知带 **罚单号 + app_id**；平民在手机「我的罚单」页付款。

服务端校验：金额必须在 `base×0.8 ~ base×1.2`；`reason` 必填；罚单只能付自己的。

### 1.3 报告（3 步 + 打字）

1. 自动带入警情/人/时间/警员/坐标；
2. 写正文（强扮演，唯一长输入）；
3. 提交 → 可选勾选：生成罚单 / 登记证据 / 标记 BOLO / 关联案件。

---

## 2. 数据模型（9 张）

| 表 | 变化 |
|---|---|
| `police_units` | 不变 |
| `police_incidents` | 不变 |
| `police_incident_units` | 不变 |
| `police_reports` | **+kind('report','arrest')、+case_id、+charges JSON、+is_bolo、+bolo_kind、+bolo_target、+location、+officer_citizenid、+status('draft','submitted','approved')** |
| `police_citations` | **+charge_id、+base_amount、+amount、+report_id** |
| `police_evidence` | **+report_id、+chain 自动首条**（保留 case_id/incident_id） |
| `police_audit` | 不变 |
| `police_cases` | 不变 |
| `police_warrants` | 不变 |

`police_arrests`：停止新写入；历史数据在案件详情里 union；一个版本后归档/删除。
`police_bolos`：停止新写入；BOLO 改为 report 的 `is_bolo` 标签；查询走 reports。
`metadata.wanted`：不再写；通缉单源 = `police_warrants`（approved）。

---

## 3. MDT 五页

| 页 | 内容 | 合并自 |
|---|---|---|
| **Dispatch** | 单位状态、接警队列、派单/前往/到场/清场、建单 | 首页+单位+接警 |
| **Person** | 人员/车辆查询、前科、通缉、罚单 | 人员+车辆+部分逮捕 |
| **Report** | 报告/逮捕/罚单/证据 一屏三段；罪名目录 + 滑轨 | 报告+罚单+证据+逮捕 |
| **Case** | 案件、搜查令、BOLO | 案件+BOLO+搜查令 |
| **Me** | 10-8/10-6/10-7、我的记录、审计（Lieutenant+） | 首页状态+审计 |

---

## 4. 改造顺序与验收

### P1 合并逮捕入口（最高优先）

- 迁移：reports 加 kind/case/charges/bolo/location/officer；citations 加 charge/report/base；evidence 加 report。
- 新增 `police_arrest_submit`（服务端单事务）：校验罪名白名单、自动刑期（上限 120）、写 report+citation(可选)+evidence(可选)+audit，送监，通知律师（可选）、开庭标记。
- `/jail` 改为内部实现并加刑期 clamp；下线手输入口。
- 验收：一次逮捕 ≤6 步；`police_reports` 有 kind='arrest'；同一事务的 citation/evidence 都有 report_id；`/jail` 无法超 120。

### P2 罚单闭环

- 罪名目录：justice 导出 `GetChargeCatalog`，custom-police 缓存 + 本地 fallback。
- 金额滑轨 ±20%，服务端双向校验；通知带罚单号 + `app_id='police_mdt'`。
- 手机新增「我的罚单」页（或 Banking 内），付款走 `PayCitation`。
- 验收：罚单 3 步；通知可点进付款；付款后 `status='paid'`；越界金额被拒。

### P3 报告/证据/BOLO 合并

- Report 页三段：正文、罪名/罚单、证据（label+description，自动首条链）、BOLO 勾选。
- 案件上下文：打开 Report 时自动带当前 incident/case。
- 下线独立 BOLO/证据/逮捕 tab 与 `police_bolos` 写入。
- 验收：报告 3 步+正文；记录覆盖率 ≥70%；证据链 100% 有首条。

### P4 法庭降级 + 出狱恢复 + 安全修复

- 法官 `/trial <case>` 命令；无人在线时认罪协议：`final = max(5, base×0.6)`，需 Sergeant+ 确认。
- 出狱恢复职业：入狱时存 prev job/grade（`police_units.prev_job/prev_grade` 或独立表），释放时经 Bus.JobService 恢复。
- 安全：`autoAlert` 加警察鉴权+限流；双入口去重（重连只认 qb-prison）；通缉单源。
- 验收：无官员工时也能判；出狱 job 恢复；伪造 autoAlert 被拒。

### P5 MDT 五页收敛

- 现有 13 tab 合并为 5 页；页面内用分段控件，不新增路由。
- 审计页仅 Lieutenant+ 渲染。
- 验收：5 页可完成所有日常流程；UI 切换 ≤1 次/次执法。

---

## 5. 指标（用 police_audit 即可算）

| 指标 | 算法 | 目标 |
|---|---|---|
| 记录覆盖率 | reports / closed incidents | ≥70% |
| 罚单有据率 | reason 非空 / 全部罚单 | ≥95% |
| 逮捕耗时 | on_scene→arrest.register | ≤90s |
| 开庭/认罪协议 | 每周案件数 | ≥2 |
| 滑轨使用 | amount≠base 的比例 | 10–30%（说明有人在用裁量） |

## 6. 改动文件（预估 18）

- custom-police：`server/{p0,p1,p2_evidence,p3_cases,p2_system}.lua`、`shared/{policy,charges}.lua`、`client/p0.lua`、`fxmanifest`
- custom-justice：`server/{arrest,trial,prison,main}.lua`（GetChargeCatalog、trial 命令、恢复职业）
- qb-prison：`server/main.lua`、`client/main.lua`（去重、恢复职业）
- custom-phone：`server/apps/police_mdt.lua`、`web/src/apps/PoliceMDT.svelte`、`App.svelte`、`server/main.lua`（罚单通知/付款）
- 迁移 2 个、测试 3–4 个

## 7. 不做

- 独立证据板、独立 BOLO 页、FTO/IA/PPR、法庭日历、保释金、律师考试、法官选举、多部门共享矩阵。
