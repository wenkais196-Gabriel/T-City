# ADR-0006 跨资源契约统一错误码与版本

- 状态：Proposed
- 相关：03-contracts、FIT-04

## 背景
14 个 MDT action 把下游错误压平（13 个 `ok and res ~= false` + `arrest_submit`；`alert` 为特例），只有 `report_submit`/`request_backup` 透传；export 无版本号、无幂等键。

## 决定
- 统一返回 `{ok=true,data}` / `{ok=false,error=<code>,detail?}`；
- 错误码按 03 §8.2 分层：`perm.*` / `input.*` / `state.*` / `deps.*`（`internal.*` 仅兜底），不再使用扁平 snake_case；
- 禁止裸 boolean 作为唯一结果；
- 写操作接受可选 `idempotency_key`（全仓统一命名，不用 `request_id`）；
- export 增加 `contract_version`，破坏性变更 bump；
- 错误码登记在 03-contracts。

## 后果
- 需要改 PhoneApps.Action 与所有 handler；
- UI 可以显示具体原因；
- 旧调用方需要兼容期。
