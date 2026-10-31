# P2 调度总线 · 现状核对（2026-10-31）

> 动手前的第一步：**先查清已有什么**。蓝图 §0 那句「排队/优先级/谁接了/到没到 在系统里无解」
> 与 §7 的 Phase 2 计划，都是在**还没读这两张表**的时候写的。

## 1. 结论

**P2 的服务器侧已经基本实现了**，只是它叫 `police_incidents` 而不是蓝图里的 `police_calls`。
`police_calls` / `police_call_units` 这两张表**不存在，也不该新建**——否则就是第二套案卷。

## 2. 已有的能力（全部带位置）

| 能力 | 实现 | 位置 |
|---|---|---|
| 表 | `police_incidents`（code/title/priority/status/x,y,z/disposition…）+ `police_incident_units`（incident_id + citizenid + role） | `T-CityLite.base/tests/fixtures/tcity_schema.sql:811` |
| 建单 | `CreateIncident` / `CreateIncidentFromSystem` / `P.ProjectIncident` | `T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua:352` |
| 状态机 | `open → assigned → enroute → on_scene → cleared → closed` + `SetIncidentStatus` | 同上 |
| 单位附着 | `ClaimIncident` / `ArriveIncident` / `RequestArriveNonce` / `ActionState` | `T-CityLite.base/resources/[custom]/custom-police/server/p0_lifecycle.lua:220` |
| 同案合并 | `findMergeableIncident(code, coords)` + `merge_count` | `T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua:128` |
| legacy shim | `police:server:policeAlert` → 服务端取坐标 → `createIncidentForAlert` | `T-CityLite.base/resources/[custom]/custom-police/server/main.lua:224` |
| 系统警报 | `police:server:autoAlert`（`source 0` 视为可信系统来源） | `T-CityLite.base/resources/[custom]/custom-police/server/main.lua:250` |
| 手机 911 | `phone:server:report911` → `CreateIncident` | `T-CityLite.base/resources/[custom]/custom-phone/server/emergency.lua:47` |
| 投影（通知 + 标记） | `notifyOnDutyIncident` 只发在勤警员；`broadcastIncidentAlert` 发标记，**每单一次** | `T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua:57,99` |
| 滞留清理 | `SweepStaleIncidents`（定时） | `T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua:358` |
| 手机面 | `PoliceMDT.svelte` 的警情页（`GetIncidents` 导出） | `T-CityLite.base/resources/[custom]/custom-phone/server/apps/police_mdt.lua:112` |

## 3. 真正的缺口（这才是 P2 剩余工作）

| # | 缺口 | 证据 | 影响 |
|---|---|---|---|
| 1 | **车机终端不存在** | `custom-vehicles` 下没有 dispatch/terminal 的 dashboard app | 开车时看不到当前 call，等于蓝图 P2 只做了一半 |
| 2 | **`custom-crime` 一条警情都不发** | `grep policeAlert\|autoAlert` 命中 0 | 自研犯罪内容对警方完全隐形 |
| 3 | **通知没有预算层** | `notifyOnDutyIncident` 对每个在勤警员逐条发，没有「同屏 ≤3 / 90 秒同 zone 合并 ×N」 | 连续事件会刷屏 |
| 4 | **7 个发案来源从未逐个验过** | shim 有了，但没有一次真机「抢劫 → 板上出现一张单」的证据 | 出问题只会在玩的时候才发现 |
| 5 | **AC 与实现不一致** | AC-P2-05 写 `ref` 幂等键 + `merge_count`；实现按 `code + coords` 合并 | 照原 AC 验收必然 FAIL |

## 4. 建议顺序

| 步 | 内容 | 工时 | 依赖 |
|---|---|---|---|
| **P2-1** | 核对 `broadcastIncidentAlert` 实际下发的字段（是否含 x/y/z），并把 7 个来源逐个真机触发一次 | 半天 | 无 |
| **P2-2** | 通知预算层：同屏 ≤3、单条 5 s、同 `code+zone` 90 s 合并显示 `×N`、priority 0 穿透静音 | 1 天 | P2-1 |
| **P2-3** | `custom-crime` 接入（走 `CreateIncidentFromSystem`，带上真实现场坐标） | 半天 | 无 |
| **P2-4** | 车机终端：`custom-vehicles` dashboard app「当前 call + 一键导航 + 单位列表」 | 2–3 天 | P2-1 |

**先做 P2-1**：它是唯一能证明"这套东西真的会产单"的一步，成本半天，而且会顺带产出
AC 需要的字段真相（P2-2 的预算和 P2-4 的终端都要靠它）。

## 5. 与蓝图 AC 的对照（需要改的地方）

| 原 AC | 现状 | 建议改法 |
|---|---|---|
| AC-P2-01 手机与车机收到同一 `call.id` | 手机有，车机没有 | 等 P2-4 做完再验 |
| AC-P2-02 payload 不含 x/y/z | 待核（P2-1） | 先看 `broadcastIncidentAlert` 的字段列表 |
| AC-P2-05 同 `ref` 5 分钟 3 次合并成 1 张、`merge_count=3` | 实现是 `code+coords` 合并 | AC 改成「同 code 且同 200 m 内合并」，或给表加 `ref` 列（L4） |
| AC-P2-06/07 7 个来源 + custom-crime 产卡 | 未验 / custom-crime 0 | P2-1 + P2-3 |


---

## 6. 施工方案（2026-10-31 修订）

### 6.1 车机终端早已存在（纠正）

`[system]/tcity-dashboard` 就是车机：有 `client/police.lua` 的警用模块（ANPR + 测速雷达）与
Vite 前端（`nui/`）。所以 P2-4 **不是从零做一个终端**，而是给它的 police 模块**加一页警情视图**：

| 原计划 | 修订后 |
|---|---|
| 新建车机终端（2–3 天） | 在 `tcity-dashboard` 的 police 模块加 dispatch 页：当前 call 列表 + 一键导航 + 单位列表（1–1.5 天，含 `npm run build`） |

### 6.2 P2-1 已完成的部分（本轮）

| 项 | 结果 |
|---|---|
| `broadcastIncidentAlert` 字段核对 | 原来**直接广播精确 x/y/z** → 违反 D5（精确坐标永不下发） |
| 修复 | 按单号稳定偏移到半径 60–95% 的点（黄金角，相邻单号不扎堆）；运维侧仍能在库里查到精确坐标 |
| 闸门 | `test_dispatch_coords.py`：payload 里不得出现原始 `x`,`y` |
| 真机 | `/911 测试警情 请求支援` → `police_incidents` **#30**（code=911、priority=1、open）落库 |

### 6.3 还没验的（P2-1 剩余）

| 项 | 状态 |
|---|---|
| 7 个发案来源逐个触发 | 未做（qb-storerobbery / qb-houserobbery / qb-drugs ×2 / custom-vehicles / custom-police 自身） |
| legacy `policeAlert` shim 真机触发 | 未做（代码路径与 911 共用同一建单函数） |
| NPC callout → 警情 | **已顺带证实**：#28 `10-37 [NPC] 可疑车辆`、#29 `10-32 [NPC] 持械人员` 都是 NPC 路径产的单 |
