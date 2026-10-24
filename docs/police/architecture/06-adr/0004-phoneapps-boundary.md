# ADR-0004 职业 App 走 PhoneApps 注册表

- 状态：Accepted（已实现）
- 相关：01-domain-model

## 背景
MDT 是手机里的职业 App；如果直接写 NUI/回调，会绕过服务端权限与审计。

## 决定
- 所有职业 App 通过 `PhoneApps.Register` 注册元数据 + query/action；
- `ForPlayer` 只返回 job+onduty 允许的 App；执行前再次校验；
- 敏感读由 App handler 走 `PolicePolicy` 并审计；
- UI 只负责展示，不承担权限。

## 后果
- 新 App 必须提供 query/action 契约与错误码；
- PhoneApps 的 audience 不是 rank 系统，rank 仍由 custom-police 判定。
