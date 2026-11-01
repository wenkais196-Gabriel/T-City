---
id: police-p4-agent
type: plan
status: active
system: justice
owner: hermes
updated: 2026-10-24
review_by: 2027-04-30
---

# P4 — 警察调度 Agent 工具（实现清单）

已上线：`get_police_board`（L0，live token，只读，无 PII）。

## 目标动作

| 工具 | director_action | 风险 | 审批 | 参数 | 审计 |
|---|---|---|---|---|---|
| `police_incident_create` | `police_incident_create` | L1 | 否 | `title`(3..120), `code`(<=16), `priority`(1..3), `description`(<=1000) | `police_audit.actor_kind='agent'`, action=`incident.create` |
| `police_assign_unit` | `police_assign_unit` | L2 | 是 | `incident_id`, `citizenid` | action=`incident.assign` |
| `police_jail_player` | `police_jail_player` | L3 | 是 | `citizenid`, `minutes`(1..120), `reason`(3..240) | action=`arrest.register` + justice 判决记录 |

## 实现要点

1. `custom-police` 增加 **system 入口**（无 player source）：
   - `CreateIncidentSystem(data, actorKind)`：校验字段，写 `police_incidents`，广播在勤手机；`created_by='agent'`。
   - `AssignUnitSystem(...)` / `JailSystem(...)`：复用现有 P0/P3 逻辑，但 actor 为 `agent:<id>`。
2. `police_audit` 增加 `actor_kind='agent'` 与 `actor_citizenid='agent:<id>'`（列已支持 ENUM）。
3. `custom-director`：
   - `policy.lua`：`ACTIONS` 增加三项；L1 `requires_approval=false, auto_execute=true`；L2/L3 `true/false`；`WORLD_ACTIONS` 加 L1（无 citizenid）。
   - `main.lua`：`buildContext` 白名单、`executeXxx`、`_Execute`、validate/preview 三处。
4. 注册表：三工具 `channel='write'`, `director_action=...`, `requires_approval` 与风险一致；`--write` 生成文档/Lua 镜像；契约测试计数 32→35。
5. 评测：`agent_eval.py` 覆盖 L1 成功率、L2/L3 审批拒绝率；拒绝写 `agent_denials`。
6. 实机：`agent_smoke.py` L1 建警情 → 看板可见；L2 派单需 admin token；L3 入狱需 admin token 且 qb-prison 生效。

## 顺序

1. custom-police system 入口 + 单测（Lua 纯函数 / Python 静态）
2. director L1 动作 + 工具 + 实机
3. L2 审批流
4. L3 审批 + 判决/监狱联动
