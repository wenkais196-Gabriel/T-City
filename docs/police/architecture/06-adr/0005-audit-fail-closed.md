---
id: police-architecture-06-adr-0005-audit-fail-closed
type: adr
status: final
system: justice
owner: hermes
updated: 2026-10-24
---

# ADR-0005 敏感读审计 fail-closed

- 状态：Proposed
- 相关：FIT-05（tracking=FIT-05）

## 背景
`police_audit` 是事后追责唯一依据；部分代码忽略审计写入结果。当前读导出中：3 个 fail-closed；9 个写审计（其中 3 个即上述 fail-closed、6 个忽略返回值）；5 个完全不写（`GetUnits`/`GetIncidents`/`GetAudit`/`GetCitations`/`GetReports`）。

## 决定
- 范围先限定为 **3 个导出**：`LookupCitizen`、`LookupVehicle`、`GetCaseDetail`；审计写入失败时**拒绝返回** `audit_unavailable`（`server/p0.lua:183-190`、`server/p3_cases.lua:242-244`）。
- 未纳入 fail-closed 的读：9 个写审计中其余 6 个忽略返回值，另有 5 个完全不写；纳入 FIT-05 跟踪，到期未清则规则转 red。
- 非敏感写可以 best-effort，但必须记录告警——**当前未实现**，tracking=FIT-05。
- 审计 append-only，不 UPDATE/DELETE。

## 后果
- DB 不可用时这 3 个查询直接失败（预期）；
- 需要统一 `audit()` 返回值检查与指标；在 FIT-05 清账前，不得把其他读导出写成“已 fail-closed”；
- 补审计会增加写放大，先评估 qps（05 NFR-PERF-06）。
