# ADR-0001 值班/勤务状态收敛为单一状态机

- 状态：Accepted（已实施 `bb64d87`；`police_units.status` 为状态、`job.onduty` 为投影）
- 日期：2026-10-24
- 相关：TD-01、SM-01、FIT-01

## 背景
`job.onduty`（qb-core）与 `police_units.status`（custom-police）都可写；值班点单向同步到 unit，MDT 只写 unit。结果是 `onduty=true + unit=off_duty` 等 **4 类典型异常**可存在（02 §1.3：在勤但 `off_duty`、未上勤却 `available`、失业/入狱后仍挂任务、`available` 仍带 `incident_id`），UI/权限/派单各读一套。

## 选项
A. 只保留 `job.onduty`：无法表达 busy/assigned/enroute/on_scene。
B. 只保留 `police_units.status`：要改 qb-core 及所有读 onduty 的资源。
C. 单一状态机 + qb-core 投影（推荐）。

## 决定
- 状态机：`OffDuty / Available / Busy / Unavailable` + 任务派生 `Assigned / Enroute / OnScene`。
- `on_duty = state != OffDuty`；`job.onduty` 只作为兼容投影。
- 所有入口走 02 §1.4 的 6 个 API：`PoliceDuty.SetDuty(citizenid, on)` / `SetManual(citizenid, state, meta)` / `Assign(citizenid, incidentId)` / `Mark(citizenid, incidentId, state)` / `Release(citizenid, reason)` / `Sweep()`；禁止直接写两套状态。
- `unavailable` **保留**在 enum：只能经 `SetManual` 写入，且必须带 `reason`/`until`；若一个版本内仍无调用方，则从 enum 删除，不得留死值。
- 状态迁移写 `police_audit`。

## 后果
- 需要一次迁移与一次 qb-core 适配层；
- MDT/值班点/命令/agent 必须改走同一 API；
- 在完成前，FIT-01 作为 advisory 检查，禁止新增 `job.onduty` 写入点。
