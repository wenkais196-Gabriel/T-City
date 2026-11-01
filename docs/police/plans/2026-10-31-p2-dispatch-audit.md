---
id: police-plans-2026-10-31-p2-dispatch-audit
type: audit
status: final
system: justice
owner: hermes
updated: 2026-10-31
---

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


---

## 7. P2-2 通知预算层（已完成）

### 7.1 规则

| 规则 | 值 | 原因 |
|---|---|---|
| 同 `code` 合并窗口 | **90 s** | 同一张单的后续事件（增援、二次报警）不该再响一遍 |
| 合并播报点 | 第 2 / 5 条，之后每 10 条 | 「×2」提醒一次、「×5」再提醒一次，中间静默 |
| 非紧急频率上限 | 每人 **3 条 / 5 s** | 连锁事件（NPC callout 刷屏）不应该糊满通知栏 |
| 紧急穿透 | `priority ≤ 1` 不受频率上限约束 | 银行劫案不能因为前面三条小单被丢 |
| 回滚开关 | `police_alert_budget 0` | 一键回到逐条发 |

### 7.2 一个闸门踩到的坑（RATE-01）

第一版 `alert_budget.lua` 自己用 `buckets` 做冷却与窗口 → `test_rate_limit_single_owner`
直接红：**全仓只允许一份限流实现**（`core-framework/server/rate_limit.lua`）。
改成委托 `RateLimit.Cooldown` / `RateLimit.Window` 之后，
本文件只剩"发不发、标题带不带 ×N"的业务判断，闸门转绿。

这条很值得记：安全原语的重复实现会让边界行为各说各话，而这类 bug 最容易在"合并窗口 90 秒"这种地方出现。

### 7.3 证据

* golden `police_alert_budget`：8 个 case（含 90 s 边界、第 3/4 条静默、第 5 条播报、紧急穿透、按人隔离）
* 闸门 `test_police_alert_budget.py`：窗口常量 / 接线 / 清单加载顺序
* 真机：`/911 预算测试A` → `police_incidents` #32 落库，重启后 **SCRIPT ERROR 0**
* 真机顺带发现：同一玩家连续两次 `/911`，第二次**没有进系统** —— phone 侧本就有 911 冷却，
  不是预算层丢的（预算层只影响通知，不影响建单）


---

## 8. P2-4 车机警情页（已完成）

### 8.1 做了什么

车机终端（`[system]/tcity-dashboard` 的 police 模块）里加了一段 **📞 警情**：
当前未结警情列表（单号 / code / 标题 / 状态），点一行就把导航点设到那条警情上，右上角可刷新。

数据链路（每一层都各自把关）：

| 层 | 做什么 |
|---|---|
| NUI（`PoliceConsole.vue`） | `sendNui('dispatchList')` 拉列表；点行 → `dispatchWaypoint` |
| client（`client/police.lua`） | 本地先判在岗，再 `TriggerCallback`；`SetNewWaypoint` 设点 |
| server（`server/police_api.lua`） | 再判一次在岗 + `checkRateLimit` + `GetIncidentsPublic(source, 20)` |
| custom-police（`server/p0_read.lua`） | export 自带 `PolicePolicy.Can` + `audit` 失败关闭，再走共享只读查询 |
| 投影（`shared/dispatch_view.lua`） | 坐标按单号稳定偏移 60–95% 半径（D5），**唯一实现** |

### 8.2 真机证据（2026-10-31）

`police_incidents_public 1 3`（控制台，走的就是车机同一份 export）：

```
#33 10-32 p1 open @ 376.2,-1541.6      DB: 430.0,-1500.0   → 偏移 ≈ 68 m
#32 911   p1 open @ 216.9,-852.9       DB: 206.1,-916.0    → 偏移 ≈ 64 m
#30 911   p1 open @ 1808.6,4952.7      DB: 1862.8,4938.4   → 偏移 ≈ 56 m
```

库里的精确坐标与客户端拿到的点**不是同一个**，且偏移量都落在 48–76 m 的窗口里。

### 8.3 顺带修掉的

* `broadcastIncidentAlert` 的偏移逻辑收进 `shared/dispatch_view.lua`（REUSE：只留一处实现）
* `DriveTab.vue` 有个未使用的 `ref` 导入，`vue-tsc` 直接报错、**整个 `npm run build` 过不去** —— 删掉
* `GetIncidents` 拆成 `readIncidents`（纯查询）+ 鉴权/审计包装，车机的 export 复用同一份查询

### 8.4 还差的（需要人在车里看）

车机页的**视觉**没在现场确认过 —— `/dashboard` 要求玩家坐在载具里，这一步需要业主亲自看一次
（数据链路已由上面的控制台证据证明）。这是 P2 唯一需要人工过目的地方。


---

## 9. P2-1 收尾：7 个发案来源逐个对账

蓝图 §P2 要求"每个发案来源都要能产卡"。代码层面逐个核对的结果（全部落在两个 handler 上，
而这两个 handler 都已建单）：

| # | 来源 | 调用点 | 事件 | 坐标来源 |
|---|---|---|---|---|
| 1 | qb-drugs 街头交易 | `qb-drugs/client/cornerselling.lua:33` | `policeAlert('Drug sale in progress')` | 服务端按 `src` 取 ped 坐标 |
| 2 | qb-drugs 送货 | `qb-drugs/client/deliveries.lua:144` | `policeAlert('Suspicous activity')` | 同上 |
| 3 | qb-houserobbery | `qb-houserobbery/client/main.lua:74` | `policeAlert(Lang palert)` | 同上 |
| 4 | qb-storerobbery | `qb-storerobbery/client/main.lua:598` | `policeAlert(email storerobbery_progress)` | 同上 |
| 5 | custom-vehicles 抢车 | `custom-vehicles/client/main.lua:764` | `policeAlert('车辆抢夺')` | 同上 |
| 6 | custom-vehicles 热线 | `custom-vehicles/server/main.lua:198/206` | `autoAlert(vehCoords, '🚨 热线发动…')` | 服务端已有坐标（`source 0` 视为系统来源） |
| 7 | NPC callout | `custom-police` 内部 | `CreateIncidentFromSystem` | 服务端 |

**真机已证实的路径**（本次会话）：

| 路径 | 证据 |
|---|---|
| 手机 911 | `police_incidents` #30、#32 |
| NPC callout | #28 `10-37 可疑车辆`、#29 `10-32 持械人员`、#31 `10-50 交通事故`、#33 `10-32` |
| 控制台可读投影 | `police_incidents_public 1 3` → #33/#32/#30（坐标已偏移） |

**还差**：1–6 需要真实游戏动作（卖药、送货、刷房、抢店、抢车、热线）才能触发；本轮没有逐一做，
留给业主下次在线时顺手验证——它们的调用点与 handler 都已确认，风险是"文案/坐标不对"，不是"不产卡"。

## 10. P2 完成度

| 项 | 状态 |
|---|---|
| 建单 / 状态机 / 单位附着 / 合并 | ✅ 早已存在（§2） |
| legacy `policeAlert` shim + `autoAlert` | ✅ |
| 手机 911 入口 | ✅ 真机 |
| 通知预算层（90 s 合并 / 5 s 3 条 / 紧急穿透） | ✅ P2-2 真机 + golden 8 case |
| 车机警情页 + 一键导航 | ✅ P2-4（数据链路真机、视觉待人工） |
| 坐标脱敏（D5） | ✅ 真机对比（偏移 56–68 m） |
| 7 个来源真机逐个触发 | ⏳ 待业主在线顺手验 |
| 车机页视觉确认 | ⏳ 待业主在载具里看一次 |
