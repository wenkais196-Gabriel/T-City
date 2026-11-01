---
id: engineering-net-events-baseline
type: audit
status: active
system: meta
owner: hermes
updated: 2026-11-01
review_by: 2027-02-01
topic: foundation-hardening
tracks: [docs/engineering/2026-11-foundation-plan.md, docs/engineering/STANDARDS.md]
---

# net event 治理基线（P1-3 第 1 步）

> **类型**：audit（现状 + 判据 + 反向证据） ｜ 对应计划：P1-3「net event 闸门扩到 qb-core 与全仓」
> **一句话**：把"1102 次注册、16% 覆盖"的模糊事实，变成**可 diff、会变红、带到期日**的基线。

## 1. 之前的状况

`test_net_event_auth.py` 只扫三个目录（custom-police / custom-phone / core-framework），
qb-core 的引擎层事件**一个都没在闸门里**；而全仓有 1102 次 `RegisterNetEvent` 注册，
没有人知道哪些被管、哪些没有。

## 2. 现在测量的是什么

唯一扫描器：`tests/architecture/net_event_scan.py`（闸门与基线生成器共用，避免两套判定）。

| 口径 | 说明 |
|---|---|
| 范围 | `resources/**` 的**服务端**脚本；排除 `client/` 目录与 `cl_*.lua` / `client*.lua`（客户端 handler 的调用方是服务端，不是玩家可触发的入站面） |
| 事件 | `RegisterNetEvent` / `RegisterServerEvent`，名字必须是字面量 |
| 两种写法 | 内联 handler；以及 `RegisterNetEvent('x')` + `AddEventHandler('x', fn)`（PolyZone / monitor 这类老资源）。后者去同文件找 fn 定义体，找不到就记空 body —— **空 body 永远算未鉴权**，只会多报债 |
| 已鉴权 | handler 里出现 `PolicePolicy.Can/Check`、`hasCapability`、`IsPlayerAceAllowed`、`HasPermission(src...)`、系统来源守卫、或回调归属校验（`pending.source ~= src`） |
| 已登记 | 在 `net_events_allowlist.json` 里，且有 category / reason / owner / expires |

## 3. 实测（2026-11-01）

| 批次 | 事件 | 已鉴权 | 已登记 | 未登记 | 状态 |
|---|---|---|---|---|---|
| **engine（qb-core）** | 15 | 5 | 10 | **0** | ✅ 100%，闸门硬性强制 |
| custom `[custom]` | 134 | 23 | 45 | 66 | 债务（基线棘轮） |
| qb `[qb]` | 221 | 22 | 0 | 199 | 债务（基线棘轮） |
| other（system / standalone / voice / cfx-default） | 82 | 1 | 4 | 77 | 债务（基线棘轮） |
| **合计** | **452** | 51 | 59 | **342** | — |

另有 **23 处变量名注册**（`RegisterNetEvent(EVENT_NAME, ...)`）—— 扫描器看不见它们，
单独作为债记在基线里，只许减少；`custom-quest`、`custom-vehicles`、`qb-storerobbery`、
`core-framework/events`、`PolyZone` 是主要来源。解析失败的 handler：**0**。

## 4. 这一轮真正修掉的东西

| 位置 | 问题 | 改法 |
|---|---|---|
| `QBCore:Server:TriggerClientCallback` | **任意客户端都能 resolve 任意待决的客户端回调**（回调只按名字索引，没有归属校验）。返回值是伪造的，会直接进服务端逻辑（库存/钱校验都可能走这条） | 建回调时记 `source`；handler 校验 `pending.source ~= src` 直接返回。同时修掉"回答后条目被清空、`Citizen.Await` 恢复时索引 nil"的潜伏错误（改成持有 `pending`） |
| qb-core 的 10 个事件 | 之前完全没有闸门可见性 | 4 个有真守卫的纳入强鉴权 token（`HasPermission(src, ...)`、`IsPlayerAceAllowed`）；其余按真实语义登记：`self_scoped`（只碰 caller 自己）、`callback_relay`（公用回调分发）、`deprecated_blocked`（废弃事件已硬阻断） |

三个新 category 都带"承诺可检查"的断言：`self_scoped` 必须在 handler 里出现
`local src = source`，`callback_relay` 必须走 `QBCore.ServerCallbacks[name]`，
`deprecated_blocked` 必须还带 `BLOCKED` 守卫 —— 类别不是一张免检通行证。

## 5. 闸门怎么工作

`tests/architecture/test_net_event_inventory.py`：

1. **棘轮**：实测的未登记集合必须与 `net_events_baseline.json` **逐条相等**。
   新冒出一个未鉴权的 net event → 红；修掉一个却没更新基线 → 也红（否则数字会停在旧值）。
2. **批次①为 0**：qb-core 不允许有任何未登记事件（与 `test_net_event_auth.py` 双保险）。
3. **债要有主**：每个还有未登记事件的资源必须有 `owner` + 未来的 `expires`，且数字与清单一致。
4. **变量名注册 / 解析失败不许增长**。

重新生成基线（有意改变现状时才跑）：

```bash
python tests/architecture/net_event_baseline.py --write
```

## 6. 反向证据

| 形状 | 结果 |
|---|---|
| 在 `[custom]` 下塞一个未鉴权事件 | `test_baseline_matches_live_inventory` 红（`gate_mutation_smoke --only net_event`：注入红 / 对照绿） |
| 在 qb-core 里塞一个未鉴权事件 | `test_enforced_batch_has_zero_unguarded_events` 红 |
| 变量名注册 | `test_non_literal_registrations_do_not_grow` 红 |
| handler 缺行首 `end)` | `test_unparsed_handlers_do_not_grow` 红 |
| 把债的 `expires` 改成过去 | `test_every_resource_with_debt_has_an_owner_and_a_future_expiry` 红 |
| 手改批次数字 | `test_batch_totals_add_up` 红 |
| 临时给 `custom-market` 追加一个未鉴权事件 | 红，并点名 `custom-market: spike:server:drift`（人工演练，已还原） |

7 条变异用例全部"注入红 / 对照绿"（`tools/dev/gate_mutation_smoke.py --only net_event`）。

## 7. 还没做到的（诚实记账）

| 计划里的判据 | 现状 | 差距 |
|---|---|---|
| ① 引擎层（qb-core）100% | ✅ 15/15 | — |
| ② `[custom]` ≥ 80% | 51%（68/134 已鉴权或登记） | 还差 39 个事件。需要逐个看业务语义，不是机械登记能解决的 |
| ③ `[qb]` 登记为带 expires 的债务 | ✅ 59 个资源各有 owner + expires（2027-03-31） | 到期前要么修，要么续期并说明 |

下一步优先级：`[custom]` 里**会写钱/物品/职业**的事件先修（`custom-vehicles`、`custom-quest`、
`custom-market`、`custom-storage`），这些的越权后果远大于诊断类事件。
