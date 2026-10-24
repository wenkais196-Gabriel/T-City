# 警察系统技术债

> 记录已知架构债，不立即修；后续按优先级处理。

## TD-01 值班/勤务双状态（高）

**现状**
- `job.onduty`（qb-core）与 `police_units.status`（custom-police）都可写。
- 值班点 → `OnJobUpdate` → 单向同步到 `police_units`。
- MDT 10-8/10-6/10-7 只写 `police_units`，不改 `onduty`；`OnJobUpdate` 又可能把它覆盖。
- 结果：`onduty=true` + `unit=off_duty` 这类组合合法存在，UI/权限/派单各读一套。

**目标模型（后续）**
- 唯一状态机：`OffDuty / Available / Busy` + 任务派生 `Assigned / Enroute / OnScene`。
- `on_duty = state != OffDuty`；qb-core `onduty` 只作为兼容投影。
- 所有入口收敛到 `PoliceDuty.SetState / Assign / Arrive / Clear`，禁止直接写两套状态。
- 历史迁移写入 `police_audit`，不在两张表存两份最后值。

**待拍板**
1. MDT 10-8/10-7 是否真正切 `onduty`；
2. 10-6 是否保留为手动；
3. 前往/到场自动还是手动兜底；
4. duty 服务先放 custom-police 还是 core-framework。

## TD-02 justice 案件/判决只在内存（中）

- `activeCases` 在 `custom-justice` 内存，重启即丢；判决只回写 `police_reports.justice_verdict`。
- 长期需要 `justice_cases` / `justice_verdicts` 持久表。

## TD-03 案件号类型不统一（中）

- `police_reports.case_id` 是 BIGINT（police_cases），justice 案件号是 `CASE-0001` 字符串。
- 已加 `justice_case_id VARCHAR`；`case_id` 与 `justice_case_id` 语义需在 UI/查询中明确区分。

## TD-04 open_case 严格回滚（低）

- `OpenCase` 失败会回滚警察侧 report/citation/evidence；可评估改 best-effort。

## TD-05 测试 fixture 缺 police 表（低）

- `tests/fixtures/tcity_schema.sql` 没有 `police_*` 表；DB 集成用例目前 skip，后续补 fixture。

## TD-06 legacy 兼容入口（低）

- `/unjail`、`police:server:JailPlayer`（仅 source=0）等保留；确认无调用后可删除。
- `RegisterArrest` / agent `Sys.Jail` 仍写 `police_arrests`，与新 report=arrest 并存。

## TD-07 MDT 状态显示依赖列表（已缓解）

- 已让 `me` query 返回 status 并本地乐观更新；长期随 TD-01 一起收敛。
