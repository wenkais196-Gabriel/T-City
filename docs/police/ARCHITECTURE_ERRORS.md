# 警察 MDT 错误码契约（FIT-04）

> 状态：`police_mdt` 的 17 个 action 已全部返回结构化结果；`PhoneApps.Action` 负责把
> 结果压平成 `success/error`，MDT 用一张中文表本地化。
> 适用：`custom-phone/server/apps/police_mdt.lua`、`custom-phone/server/phone_apps.lua`、
> `custom-phone/web/src/apps/PoliceMDT.svelte`。

## 1. 返回契约

成功的 action 返回：

```lua
{ ok = true, data = <可选>, ... }   -- 或 true
```

失败的 action 返回：

```lua
{ ok = false, error = '<snake_case>', detail = <可选> }
```

`police_mdt` 不再返回裸 `false`，也不再把 export 的元组压成布尔：

| export 返回 | `police_mdt` action 返回 |
|---|---|
| `true` | `{ ok = true }` |
| `false, '<code>'` | `{ ok = false, error = '<code>' }`（`nil, code` 同样处理） |
| `{ ok = true, ... }` | 原样透传 |
| `{ ok = false, error, detail }` | 原样透传，只规范化 `error` |
| `{ id = ..., ... }`（无 `ok`） | 补 `ok = true` 后透传 |
| pcall 异常 | `{ ok = false, error = 'export_error' }` |

`PhoneApps.Action` 再将上表映射为：

| action 结果 | `PhoneApps.Action` |
|---|---|
| `true` / `{ ok = true, ... }` / 无 `ok` 的表 | `true, result` |
| `{ ok = false, error, detail }` | `false, error, detail` |
| 裸 `false` / `nil`（仅兼容旧 action） | `false, 'action_rejected'` |
| handler 抛异常 | `false, 'action_failed'` |
| 未注册 action | `false, 'action_not_found'` |

规则：

1. 错误码统一 `snake_case`，由 export/action 产生，UI 不拼接英文句子。
2. `detail` 只用于服务端日志/诊断，当前不进入 NUI；UI 只依赖 `error`。
3. **action 层不做权限判断**：`PolicePolicy.Can` 全部在 `custom-police` export 内；
   action 层只负责调用、结构化与错误码归一化。
4. 内部码 `unknown_capability` 不外露，统一映射为 `forbidden`。
5. 未知码在 UI 回退显示原码，绝不吞成“失败”。

## 2. 通用错误码

| 错误码 | 产生层 | 含义 | UI 文案 |
|---|---|---|---|
| `not_police` | `PolicePolicy.Can` | 不是警察 | 仅限警察使用 |
| `not_on_duty` | `PolicePolicy.Can` / export | 未上班（10-7） | 请先上班（10-8 在勤） |
| `rank_too_low` | `PolicePolicy.Can` | 职级不足 | 职级不足 |
| `forbidden` | action 层 | 权限判定失败（含 `unknown_capability` 归一化） | 无权限执行该操作 |
| `unknown_capability` | policy 表内部 | 能力名拼错；action 层映射为 `forbidden` | 无权限执行该操作 |
| `cooldown` | `RequestBackup` | 支援 60 秒冷却 | 支援请求冷却中（60 秒），请稍后再试 |
| `limit` | `RequestBackup` | 同时最多 2 个 NPC 支援单位 | 同时最多 2 个 NPC 支援单位，请等待现有单位结束 |
| `global_limit` | 预留 | 全服支援上限（当前未产生，UI 已预留） | 全服支援单位已达上限，请稍后重试 |
| `in_progress` | `withIntent` | 同一幂等键正在提交 | 该提交正在处理中，请勿重复点击 |
| `invalid_idempotency_key` | `withIntent` | 幂等键格式非法 | 提交标识无效，请刷新后重试 |
| `invalid_transition` | `AssignUnit` / `SetIncidentStatus` | 状态机不允许该转换 | 警情状态已变化，请刷新后重试 |
| `incident_not_found` | `AssignUnit` / `SetIncidentStatus` / 报告 | 警情不存在 | 警情不存在或已归档 |
| `not_assigned` | `SetIncidentStatus` | Grade<2 且未加入该警情 | 你尚未被分配到该警情（需先派单/到场） |
| `already_jailed` | `ArrestSubmit` | 目标已在服刑 | 目标已在服刑 |
| `too_far` | `ArrestSubmit` | 目标超过 5 米 | 目标距离超过 5 米 |
| `not_handcuffed` | UI 契约名 | 目标未上铐/未倒地；export 实际码为 `target_not_cuffed`，两者同文案 | 目标没有上铐/倒地，先 /cuff |
| `target_not_cuffed` | `ArrestSubmit` | 同上 | 目标没有上铐/倒地，先 /cuff |
| `case_forbidden` | `ArrestSubmit` | 建案/开案需要 Sergeant+ | 创建案件需要 Sergeant+ |
| `audit_unavailable` | 敏感 export | 审计写入失败，fail-closed | 审计不可用，请稍后重试 |
| `db_error` | 所有写 export | 数据库写入/读取失败 | 数据库错误，请重试 |
| `export_error` | action 层 | pcall 捕获的 export 异常 | 服务端处理异常，请稍后重试 |
| `rejected` | action 层 | export 返回失败但没有错误码 | 服务端拒绝：请检查权限与参数 |
| `action_rejected` | `PhoneApps.Action` | 旧 action 返回裸 `false`（兼容路径） | 服务端拒绝：请检查权限与状态 |
| `action_failed` | `PhoneApps.Action` | action handler 自身抛异常 | 服务端处理失败，请稍后重试 |
| `action_not_found` | `PhoneApps.Action` | App 未注册该 action | MDT 未注册该动作 |
| `app_forbidden` | `PhoneApps.Action` | audience（job/onduty）不允许 | 无权限使用 MDT（需在勤警察） |
| `player_not_found` | `PhoneApps.Action` | 玩家数据未加载 | 角色尚未加载 |

其他参数类错误码（`invalid_title` / `invalid_body` / `invalid_citizen` /
`invalid_amount` / `invalid_reason` / `invalid_label` / `invalid_kind` /
`invalid_target` / `invalid_case` / `invalid_incident` / `invalid_warrant` /
`invalid_charges` / `invalid_charge` / `invalid_params` / `invalid_status` /
`invalid_disposition` / `invalid_case_combination` / `missing_case` /
`citizen_not_found` / `not_pending` / `duty_failed` / `jail_failed` /
`case_create_failed` / `open_case_failed` / `not_found` / `not_owner` /
`insufficient_funds` / `unavailable`）同理：export 产生稳定码，UI 表逐条翻译；
未登记的新码按第 4 节回退显示原码。

## 3. 17 个 action 的错误码

| action | 后端 export | 可能错误码（除第 2 节通用码外） | 成功结果 |
|---|---|---|---|
| `set_status` | `SetUnitStatusForSource` | `invalid_status`、`duty_failed`、`not_police`、`not_on_duty` | `{ ok = true }` |
| `assign` | `AssignUnit` | `rank_too_low`、`invalid_incident`、`invalid_unit`、`incident_not_found`、`invalid_transition` | `{ id, unit, status }` |
| `enroute` | `SetIncidentStatus(..., 'enroute')` | `not_on_duty`、`rank_too_low`、`invalid_incident`、`incident_not_found`、`not_assigned`、`invalid_transition` | `{ id, status }` |
| `on_scene` | `SetIncidentStatus(..., 'on_scene')` | 同 `enroute` | `{ id, status }` |
| `clear` | `SetIncidentStatus(..., 'cleared')` | 同 `enroute`，另 `invalid_disposition` | `{ id, status, disposition }` |
| `alert` | 无（`custom-phone:Notify` 扇出） | `invalid_message` | `{ ok = true, sent }` |
| `issue_citation` | `IssueCitation` | `not_on_duty`、`rank_too_low`、`invalid_citizen`、`invalid_amount`、`invalid_reason`、`citizen_not_found`、`db_error` | `{ id, amount, status }` |
| `create_report` | `CreateReport` | `not_on_duty`、`rank_too_low`、`invalid_title`、`invalid_body`、`case_not_found`、`db_error` | `{ id, status }` |
| `register_evidence` | `RegisterEvidence` | `not_on_duty`、`rank_too_low`、`invalid_label`、`missing_case`、`case_not_found`、`incident_not_found`、`db_error` | `{ id, exhibit_no, status }` |
| `create_case` | `CreateCase` | `rank_too_low`、`invalid_title`、`db_error` | `{ id, case_no, status }` |
| `create_bolo` | `CreateBolo` | `rank_too_low`、`invalid_kind`、`invalid_target`、`invalid_reason`、`db_error` | `{ id, kind, target, status }` |
| `request_warrant` | `RequestWarrant` | `rank_too_low`、`invalid_citizen`、`invalid_reason`、`citizen_not_found`、`db_error` | `{ id, citizenid, status }` |
| `decide_warrant` | `DecideWarrant` | `rank_too_low`、`invalid_warrant`、`not_pending` | `{ id, status }` |
| `register_arrest` | `RegisterArrest` | `not_on_duty`、`rank_too_low`、`invalid_citizen`、`invalid_charges`、`db_error` | `{ id, citizenid, status }` |
| `arrest_submit` | `ArrestSubmit` | `invalid_params`、`invalid_idempotency_key`、`in_progress`、`invalid_citizen`、`citizen_offline`、`target_unavailable`、`already_jailed`、`target_not_cuffed`、`too_far`、`invalid_charges`、`invalid_charge`、`invalid_amount`、`invalid_incident`、`incident_not_found`、`invalid_case`、`case_not_found`、`invalid_case_combination`、`case_forbidden`、`bolo_forbidden`、`invalid_bolo_kind`、`invalid_bolo_target`、`case_create_failed`、`open_case_failed`、`jail_failed`、`audit_unavailable`、`db_error` | `{ report_id, minutes, fine, citation_id?, evidence_id?, case_id?, justice_case_id?, jailed }` |
| `report_submit` | `ReportSubmit` | `invalid_params`、`invalid_idempotency_key`、`in_progress`、`invalid_title`、`invalid_body`、`invalid_incident`、`incident_not_found`、`invalid_case`、`case_not_found`、`invalid_evidence_label`、`bolo_forbidden`、`invalid_bolo_kind`、`invalid_bolo_target`、`audit_unavailable`、`db_error` | `{ report_id, evidence_id?, bolo }` |
| `request_backup` | `RequestBackup` | `not_police`、`cooldown`、`limit`、`audit_unavailable` | `{ request_id }` |

> 命名说明：FIT-04 描述中的 `create_evidence` 对应已注册的 `register_evidence`
> （UI 也叫“证据登记”）。为避免改变既有 action 契约，未新增别名。

## 4. UI 映射与未知码

`PoliceMDT.svelte` 只有一张 `ERROR_TEXT` 表和一个 `errorText(code)`：

```ts
function errorText(code: unknown): string {
  const key = String(code ?? '');
  return ERROR_TEXT[key] ?? (key || '提交失败');
}
```

- 表覆盖第 2、3 节的全部 action 错误码，以及现有 query 错误码。
- 未登记的新码**回退显示原码**（例如 `some_new_code`），不会静默变成“失败”。
- 原 `backupErrorFor` / `reportErrorFor` / 逮捕内联 map 已收敛到同一张表，
  旧函数名保留为别名，未新增第二份映射。
- 本地校验文案（如“请填写标题”“请至少选择一条罪名”）不是服务端错误码，
  仍留在表单层。

## 5. 审计（FIT-04 第二半）

错误码只是契约的一半；写路径的审计在 `custom-police` export 内完成，action 层不重复：

| action | 审计动作 |
|---|---|
| `set_status` | `unit.status` |
| `assign` | `incident.assign` |
| `enroute` / `on_scene` / `clear` | `incident.update` / `incident.close` |
| `issue_citation` | `citation.issue` |
| `create_report` | `report.create` |
| `register_evidence` | `evidence.register` + 首条 `police_evidence_chain` |
| `create_case` | `case.create` |
| `create_bolo` | `bolo.create` |
| `request_warrant` | `warrant.request` |
| `decide_warrant` | `warrant.decide` |
| `register_arrest` | `arrest.register` |
| `arrest_submit` | `report.create`、可选 `citation.issue` / `evidence.register` / `bolo.create` / `case.create`、送监 |
| `report_submit` | `report.create`、可选 `evidence.register` / `bolo.create` |
| `request_backup` | `backup.request` |
| `alert` | 不写 `police_audit`（只走手机通知，无警察表写入） |

敏感读（`GetCitations`/`GetReports`/`GetEvidence`/`GetCases`/`GetAudit` 等）
在审计失败时返回 `audit_unavailable` 并拒绝返回数据（FIT-05）。

## 6. 已知动态码 / 边界

- `p1.lua` 的 `PayCitation` 仍有 `already_<status>` 动态码；它不在本 MDT 17 个
  action 内（走 Banking「我的罚单」），本轮不处理，登记为后续 FIT-04 债务。
- `global_limit` 为预留码：`RequestBackup` 当前只有每警员 `limit`，没有全服上限；
  UI 先翻译，服务端加限制时不需要改前端。
- `detail` 暂不显示；若将来要显示，只允许展示经过白名单的字段，避免把内部
  SQL/异常文本带给客户端。
