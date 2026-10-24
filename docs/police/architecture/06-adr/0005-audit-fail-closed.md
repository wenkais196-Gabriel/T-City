# ADR-0005 敏感读审计 fail-closed

- 状态：Accepted（部分实现）
- 相关：FIT-05

## 背景
`police_audit` 是事后追责唯一依据；部分代码忽略审计写入结果。

## 决定
- 敏感读（人员/车辆/案件/证据/审计）在审计写入失败时**拒绝返回**；
- 非敏感写可以 best-effort，但必须记录告警；
- 审计 append-only，不 UPDATE/DELETE。

## 后果
- DB 不可用时敏感查询直接失败（预期）；
- 需要统一 `audit()` 返回值检查与指标。
