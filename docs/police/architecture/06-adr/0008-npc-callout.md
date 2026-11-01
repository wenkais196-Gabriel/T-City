---
id: police-architecture-06-adr-0008-npc-callout
type: adr
status: final
system: justice
owner: hermes
updated: 2026-10-24
---

# ADR-0008 NPC 警情：服务端调度 + 客户端场景

- 状态：Accepted（MVP，`a52d2ca` / `3bbcab3`）
- 日期：2026-10-24
- 相关：SM-09、SM-02、SM-06、FIT-07、05 NFR-SCALE-03

## 背景

SM-06 的 NPC 支援是“警员主动请求”，无法产生“没有玩家报警的警情”。GTA 单机 mod 的 callout 通常在客户端随机生成现场、直接给奖励；FiveM 里如果照搬，会出现：

- 客户端可凭空造警情（污染调度、统计与审计）；
- 客户端可自选奖励/地点（经济与公平问题）；
- 每个客户端各自生成，实体数量不可预算（与 SM-06 同类风险）。

## 选项

A. **纯客户端**：简单，但重演“客户端权威”，且无法被 MDT/看板/审计统一管理。
B. **服务端建单 + 客户端建场景**：服务端决定何时/何地/是否允许，客户端只负责实体表现与结果上报。
C. **纯服务端生成实体**：服务端 `CreatePed`/`CreateVehicle` 需要 OneSync 实体所有权与流式加载，跨客户端可见性与清理成本高，MVP 不划算。

## 决定

采用 **B**，并复用 SM-02 的 `police_incidents` 作为唯一事实源：

1. **服务端调度**：启动 30s 后首次评估，之后每 8 分钟一次；条件为在勤警员 ≥1、活动 NPC 警情 <1、30% 概率（`shared/npc_callouts.lua:22-29`、`server/p4_npc.lua:368-390`）。
2. **模板与坐标在共享常量**：4 个模板、每个 3 个固定地点；服务端选模板与地点，客户端不得自选（`shared/npc_callouts.lua:31-160`）。
3. **建单落 `police_incidents`**：`npc_template` 非空即 NPC 警情；`NULL` 保持普通警情语义（`migrations/v3.11_police_npc_callout.sql`、`p4_npc.lua:124-146`）。
4. **场景推送**：只有被派单位 `on_scene` 或任一在勤警员距坐标 ≤80m 时，服务端才推 `police:client:NpcCallout`；客户端建场景（`p4_npc.lua:252-358`）。
5. **结算复用 P0**：客户端上报 `resolved/arrest/failed/false_alarm`，服务端调 `SetIncidentStatus('cleared', disposition)`，复用 transition 守卫、单位释放与 `incident.close` 审计；奖励 $500 只发给真正执行关闭的人，且幂等关闭不二次发奖（`p4_npc.lua:171-243`）。
6. **超时**：不单独建 TTL，直接复用 SM-02 的 45 分钟 stale sweep；`MAX_ACTIVE=1` 保证不会无限堆积。
7. **客户端清理**：玩家离场景中心 300m 持续 60s、收到 `NpcCalloutEnd`、资源 stop、或场景被替换时清理（`client/npc_callouts.lua:23-24,493-503,562-575`）。

## 后果

**收益**：NPC 警情进入与普通警情同一张表、同一状态机、同一审计面；MDT/看板/统计无需新增数据源；客户端不能建单、不能选奖励。

**代价 / 风险**：

- 服务端没有场景生命周期表（`spawned` 是内存 map），无法回答“场景是否真的建起来了”；无 ack/超时重发（`p4_npc.lua:345-350`）。
- AI 可能跑出场景（客户端按玩家位置而不是 NPC 位置计时）。
- 奖励只给关闭者，缺少“参与人”记录。
- 新增了 `client/npc_callouts.lua` 的 `CreateVehicle`/`CreatePed` 路径，绕过 `RequestBackup` 的预算接口；FIT-07 因此从 PASS 降为 PARTIAL（见 07）。
- 依赖 SM-02 的 stale：卡住的 NPC 警情会占用 `MAX_ACTIVE=1` 最多 45 分钟。

## 证据

- `custom-police/server/p4_npc.lua`
- `custom-police/client/npc_callouts.lua`
- `custom-police/shared/npc_callouts.lua`
- `migrations/v3.11_police_npc_callout.sql`
- `docs/police/architecture/02-state-machines.md` §8
- `docs/police/architecture/08-scenarios.md` §6

## 后续

1. 加 `police:server:NpcCalloutAck(incidentId, phase)` + 服务端超时重发/改派；
2. 加 AI leash（按 NPC 距场景中心拉回/重定位）；
3. 把 NPC 警情实体纳入 05 的全局 NPC 预算；
4. 记录参与人（close 时写 `police_incident_units` 的参与状态），再决定奖励分配。
