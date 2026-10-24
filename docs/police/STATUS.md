# 警察系统实现状态（2026-10-23）

## 已交付

| 阶段 | 内容 | 代码 | 数据表 |
|---|---|---|---|
| P0 | 出勤 10-8/10-6/10-7、911、警情队列、派单/前往/到场/清场、单位/人员/车辆查询、审计 | `custom-police/server/p0.lua`、`client/p0.lua` | `police_units`、`police_incidents`、`police_incident_units`、`police_audit` |
| P1 | 罚单（开具/查询/支付）、报告、证据登记+保管链 | `server/p1.lua`、`server/p2_evidence.lua` | `police_citations`、`police_reports`、`police_evidence`、`police_evidence_chain` |
| P2 | 案件、BOLO、搜查令（申请/审批）、逮捕登记 | `server/p3_cases.lua` | `police_cases`、`police_bolos`、`police_warrants`、`police_arrests` |
| 电话 | MDT 10 个 Tab、通知深链 `app_id`、罚单支付命令 | `custom-phone/server/apps/police_mdt.lua`、`web/src/apps/PoliceMDT.svelte` | `phone_notifications.app_id` |
| 司法 | 判决→入狱改为服务端执行，修复 `JusticeService.Inmates` | `custom-justice/server/{main,prison,trial}.lua` | — |

## 权限模型

`custom-police/shared/policy.lua` 的 capability 表是唯一入口：

- `units.view` / `incident.create` / `incident.update` / `lookup.*` / `citation.*` / `report.*` / `evidence.*` / `case.*` / `bolo.*` / `warrant.*` / `arrest.*`
- 要求 `job.name == 'police'` + `onduty` + 最低 grade；`warrant.approve` / `audit.view` 需 Lieutenant+（grade ≥ 3）。
- 敏感读失败时 `audit_unavailable` 直接拒绝（fail-closed）。

## 未完成

1. **P4 L2/L3 实机执行**：只读看板、L1、L2、L3 均已实现（35 工具 / 21 动作）。L1 已实机 `executed`；L2/L3 的审批端点在无加载玩家时按 `player_not_found` 拒绝（409），system 执行路径由 Lua 测试覆盖，**尚缺一次在线玩家下 approve→executed 的实机记录**。
2. **产品化收尾**：罚单收据/邮件、BOLO 清除按钮、搜查令执行/过期流转、案件详情导出。
3. `qb-policejob` 事件名保留 `qb-policejob:*` 兼容，未重命名（刻意）。

## 验证命令

```bash
cd T-CityLite.base && python3 -m pytest -q tests/unit      # 327 passed
cd .. && python3 -m pytest -q tests/tools                  # 203 passed
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua
python3 tools/agent_tools.py --check
```

> 改 `fxmanifest` 或新增 server 文件后必须整服重启（或删 `cache/files/custom-police`），只 `restart` 不会加载新文件。


## 方案 B 落地状态（2026-10-24）

- P1 一次逮捕：`ArrestSubmit`（手铐/5m/未服刑校验，report=arrest，可选案件/罚单/证据，失败回滚）
- P2 罚单闭环：罪名目录 + ±20% 滑轨、通知带罚单号 + `app_id='banking'`、Banking「我的罚单」支付
- P3 报告合并：`ReportSubmit`（证据附件 + 首条保管链、BOLO 报告标签），`GetBolos` 双源合并
- P4 法庭/安全：`/trial`（法官）、`/plea`（Sergeant+，无法官时 0.6 系数）、`OpenCase`、服刑去重、`autoAlert` 鉴权/限流（系统 source=0 放行）
- P5 MDT 五页：调度 / 人车 / 文书 / 案件 / 我的；审计仅 Lieutenant+ 渲染

按用户决定：**不做“出狱恢复职业”**。
已知限制：justice 案件号是字符串，`police_reports.case_id` 仍是 BIGINT，`justice_case_id` 仅返回+审计；`open_case` 失败会回滚警察侧记录。
