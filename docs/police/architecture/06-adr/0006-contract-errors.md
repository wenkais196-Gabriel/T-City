# ADR-0006 跨资源契约统一错误码与版本

- 状态：Proposed
- 相关：03-contracts、FIT-04

## 背景
13 个 MDT action 把下游错误压成 `action_rejected`；export 无版本号、无幂等键。

## 决定
- 统一返回 `{ok=true,data}` / `{ok=false,error=<snake_case>}`；
- 禁止裸 boolean 作为唯一结果；
- 写操作接受可选 `idempotency_key`；
- export 增加 `contract_version`，破坏性变更 bump；
- 错误码登记在 03-contracts。

## 后果
- 需要改 PhoneApps.Action 与所有 handler；
- UI 可以显示具体原因；
- 旧调用方需要兼容期。
