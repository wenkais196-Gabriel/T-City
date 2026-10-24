# ADR-0007 custody 服务端计时

- 状态：Accepted（已实施 `2ae3da4` + `f690230` work/release）
- 日期：2026-10-24
- 相关：SM-05、SM-04、TD-02、ADR-0002

## 背景
刑期当前由 qb-prison **客户端** `jailTime` 递减并回写：`qb-prison/client/main.lua:344-369` 每分钟 `TriggerServerEvent('prison:server:SetJailStatus', jailTime)`，服务端只查玩家存在（`qb-prison/server/main.lua:5-18`）。后果：

- 任意客户端可把 `jailTime` 改成任意值（含 0）后回写，绕过剩余刑期；
- 离线时间不计刑，重连按 `metadata.injail` 最后值恢复；
- `metadata.injail`、justice `Inmates`（内存）、客户端 `jailTime` 三份状态可互相分叉；`/trial`/`/plea` 的 `Imprison` 又因 `metadata.injail > 0` early-return，判决改不了正在服的刑期。

## 决定
- **唯一权威是 `justice_sentences`**（schema 见 02 §5.4）：`ends_at = started_at + minutes - reductions`，由服务端时钟计算；`status` 至少 `active/released/escaped/void`。
- **服务端计时**：`Sweep` 每 30–60s 扫 `status='active' AND ends_at<=NOW()` → 幂等 `ReleaseSentence(id,'expired')`；登录按 `remaining = max(0, ends_at-now)` 重建 `metadata.injail` 并触发 qb-prison Enter，离线时间自然计入。
- **qb-prison 降为表现层**：客户端不再拥有 `jailTime` 的权威；自由门/自动释放改为请求服务端 `RequestRelease`，由服务端校验 `ends_at<=NOW()`。
- **`SetJailStatus` 加来源与数值校验**：不再接受客户端任意 `TriggerServerEvent`；只保留为服务端内部 `SyncRemaining`（白名单资源/内部调用），且只接受 `0 ≤ value ≤ 上次服务端结算值`，其余丢弃并记安全日志。校验失败不得改 `metadata.injail`。
- **判决改判**：`/trial`/`/plea` 通过 `AdjustSentence(id, new_minutes)` 更新 `ends_at` 并写 `custody.adjust`，不得再次 `Imprison`（当前正是二次 `Imprison` 被 early-return，导致判决无效）。
- 所有 `custody.imprison/release/adjust` 写 `police_audit`（含 `reason='expired'|'admin'|'escape'`）。

## 后果
- 需要一次迁移（`justice_sentences`）、qb-prison 客户端/服务端改造与登录结算；
- `metadata.injail` 保留为 qb-prison 的投影，不再作为事实源；qb-prison 的 `SetJailStatus` 从“客户端回写”变成“服务端下发”；
- 需补测试：客户端伪造 0 分钟、离线 8 小时后重连、`/trial` 改判后 `ends_at` 变化、服务端重启后剩余刑期不变；
- 与 ADR-0002 的分工：0002 管案件/判决落库，0007 管判决如何变成可执行的 sentence。
