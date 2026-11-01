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
> **恢复命令**：`cd T-CityLite.base && python tests/architecture/net_event_baseline.py --write`

## 1. 之前的状况

`test_net_event_auth.py` 只扫三个目录（custom-police / custom-phone / core-framework），
qb-core 的引擎层事件**一个都没在闸门里**；而全仓有 1102 次 `RegisterNetEvent` 注册，
没有人知道哪些被管、哪些没有。

## 2. 现在测量的是什么

唯一扫描器：`tests/architecture/net_event_scan.py`（闸门与基线生成器共用，避免两套判定）。

| 口径 | 说明 |
|---|---|
| 范围 | `resources/**` 的**服务端**脚本。客户端判定顺序：`server/` 目录 → fxmanifest（`client_scripts { }` 块与 `client_script 'x.lua'` 单条都认）→ `cl_*` / `client*` 文件名。同一文件既声明 client 又声明 server 时按服务端算（漏扫比多算危险）。qb-target 的 init.lua 这类"名字看不出来"的由 manifest 兜住 |
| 事件 | `RegisterNetEvent` / `RegisterServerEvent`，名字必须是字面量（变量名注册另计债） |
| 两种写法 | 内联 handler；以及 `RegisterNetEvent('x')` + `AddEventHandler('x', fn)`（PolyZone / monitor 这类老资源）。后者去同文件找 fn 定义体，找不到就记空 body —— **空 body 永远算未鉴权**，只会多报债 |
| 鉴权判定 | 先**剥掉注释与字符串**再匹配（`strip_lua_noise`）：注释里写的检查不算检查，日志里印一句 token 也不算 |
| 已鉴权的证据 | `PolicePolicy.Can/Check`、`hasCapability`、`IsPlayerAceAllowed`、`HasPermission(src...)`、**只允许服务端触发的 `src ~= 0 then return`**、回调归属校验（`pending.source ~= src`），以及项目 helper（`onDutyOfficer` / `NPC.SubmitResult` / `PoliceDispatch.*` / `AdoptDraft` / `ListDrafts` —— 每个都追查定义处是否真的调用 `PolicePolicy.Can`） |
| 已登记 | 在 `net_events_allowlist.json` 里，且有 category / reason / owner / expires |

`src == 0` **不算鉴权**：它只把控制台排除在外。2026-11-01 之前这条误判让 12 个事件
"看起来已鉴权"，其中 10 个其实任何玩家都能触发（见 §4）。

## 3. 实测（2026-11-01）

| 批次 | 事件 | 已鉴权 | 已登记 | 未登记 | 在启动集内 |
|---|---|---|---|---|---|
| **engine（qb-core）** | 15 | 5 | 10 | **0** | ✅ 100%，闸门硬性强制 |
| custom `[custom]` | 134 | 41 | 45 | 48 | 覆盖率 **86/134 ≈ 64%**（P1-3 第 2 批：custom-vehicles 26→17 已鉴权、custom-police 证据链 5 个） |
| qb `[qb]` | 216 | 16 | 0 | 200 | 债务 |
| other（system / standalone / voice / cfx-default） | 76 | 1 | 6 | 69 | 债务 |
| **合计** | **441** | 63 | 61 | **317** | — |

另有 **11 处变量名注册**（`RegisterNetEvent(Config.X.Events.Y, ...)`：custom-quest 5、
custom-vehicles 6 —— 另有 PolyZone 1 处运行时拼接），单独记债，只许减少。

**债的分布不是均匀的**：58 个还有欠账的资源里，15 个**不在启动集**（`ensure` 列表里没有），
它们贡献 **93/317（29%）** 的未登记事件（`monitor` 33、`qb-houses` 19、`qb-lapraces` 10、
`qb-crypto` 6、`qb-shops` 5、`qb-weed` 5、`qb-streetraces` 3…）。基线里每个资源都带 `started`
标记，排期时先看 `started: true` 的。客户端 handler（qb-target 的 init.lua、`[cfx-default]` 的 playernames_cl.lua / rconlog_client.lua 等）已按 manifest 排除。

## 3.1 资源内部 helper 登记表（2026-11-01 第 2 批）

全仓 317 个未登记事件里，有一部分**本来就写了校验**，只是校验住在资源自己的 helper 里
（`CanModifyPlate` / `IsEmergencyService` / `onDutyOfficer` …），按固定 token 名单扫不出来。
直接把这些名字塞进 token 名单等于"名字像校验就算校验"，所以另开了
`tests/architecture/net_event_guard_helpers.json`：

| 门槛 | 怎么保证 |
|---|---|
| 定义唯一 | 登记的 `defined_at` 里 `function <名字>(` 必须恰好出现一次 |
| 证据齐全 | `requires_code` 在**剥掉注释/字符串**后必须全部命中；含字符串字面量的判据放 `requires_raw` |
| 调用必须看返回值 | 资源内每一处调用都必须是 `if not <名字>(…) then … return` 形状（`H(x)` 单调用不算） |
| 不许死豁免 | 登记了却没有任何调用点 → 红 |
| 闸门自己会咬 | `gate_mutation_smoke.py` 里加了"调用但忽略返回值"的变异 |
| 形状单一实现 | 计数器与闸门共用 `net_event_scan.helper_call_problems`（否定分支必须真的 `return`，`if false` 死代码不算，单行写法的 `return` 必须在 `end` 之前） |

**已知局限**（静态形状分析的天花板，写在这里而不是假装没有）：只校验"守卫存在且真的返回"，
**不校验守卫在特权动作之前**（`DoThing(); if not H(x) then return end` 仍然算已鉴权）。
这类形态靠 review 与单测覆盖，闸门抓不到。

当前登记 5 个：`CanModifyPlate`（车牌写权限 = 车主或执勤机修）、`IsEmergencyService`
（PA/警笛/雷达/锚定限紧急服务）、`IsSeatedIn` / `IsSeatedInPlate`（广播类只允许车内的人）、
`onDutyOfficer`（执勤 + `PolicePolicy.Can`）。

## 4. 这一轮真正修掉的东西

| 位置 | 问题 | 改法 |
|---|---|---|
| `QBCore:Server:TriggerClientCallback` | **任意客户端都能 resolve 任意待决的客户端回调**（回调只按名字索引，没有归属校验）。返回值是伪造的，会直接进服务端逻辑（库存/钱校验都可能走这条） | 建回调时记 `source`；handler 校验 `pending.source ~= src` 直接返回。同时修掉"回答后条目被清空、`Citizen.Await` 恢复时索引 nil"的潜伏错误（改成持有 `pending`） |
| `QBCore:Server:TriggerCallback` 的分发目标 | 分发器本身不鉴权，而它分发的 `QBCore:Server:SpawnVehicle` / `CreateVehicle` 在 qb-core 里**没有任何权限判断**——任何客户端都能让服务端 `CreateVehicle` | 不改 qb-core 的业务语义，而是给"守卫存在"加闸门：`custom-security` 必须仍然劫持这两个回调，且守卫里必须有 `HasPermission(admin/god)`、`CheckRateLimit("vehicle_spawn")`，`security_check_vehicle_spawn` 必须是 `true`。劫持被删/被改名/开关被关 → 红 |
| 12 个"凭 `src == 0` 算已鉴权"的事件 | `src == 0` 只排除控制台 | token 收紧为 `src ~= 0 then return`；custom-police 的 4 个事件改为经 `PoliceDispatch.*` helper 追踪到 `PolicePolicy.Can`（真守卫在 `p0_lifecycle.lua` / `p0_incidents.lua` 里），其余进入债 |
| qb-core 的 10 个事件 | 之前完全没有闸门可见性 | 4 个有真守卫的纳入强鉴权 token；其余按真实语义登记：`self_scoped`、`callback_relay`、`deprecated_blocked` |

三个新 category 都带"承诺可检查"的断言，而且都在**剥掉注释/字符串之后**检查：

* `self_scoped`：必须有 `local src = source`，且 `GetPlayer(...)` 的参数只能是 `src`/`source`，
  并且不许出现 `Players[<别的变量>]` / `GetPlayer(tonumber(...))` / `GetPlayerByCitizenId(<别的变量>)`；
* `callback_relay`：必须走 `QBCore.ServerCallbacks[name]`，且分发目标里的高危项要有可验证的守卫（见上）；
* `deprecated_blocked`：必须有 `LogSecurity(` 调用，并且**不许**出现列出的写 API（`AddItem/RemoveItem/AddMoney/RemoveMoney/SetMetaData/SetJob/SetJobDuty/SetGang/SetMoney`、任何 `MySQL.*`、`exports[...]:Set*`）。

## 5. 闸门怎么工作

`tests/architecture/test_net_event_inventory.py`：

1. **棘轮**：实测的未登记集合必须与 `net_events_baseline.json` **逐条相等**（新增要拦、还清也要反映）。
2. **数字可信**：`batches` 与每资源的 `events/guarded/allowlisted/unguarded` 必须等于实测 —— 只校验"批次内部相加相等"挡不住手改。
3. **批次①为 0**：qb-core 不允许有任何未登记事件（与 `test_net_event_auth.py` 双保险）。
4. **债要有主**：每个还有未登记事件的资源必须有 `owner` + 未来的 `expires`，且数字与清单一致。
5. **变量名注册 / 解析失败的 handler**：与基线双向相等（只拦"新增"可以被"先塞基线再引代码"绕过）。

重新生成基线（有意改变现状时才跑）：

```bash
cd T-CityLite.base && python tests/architecture/net_event_baseline.py --write
```

## 6. 反向证据

| 形状 | 结果 |
|---|---|
| 在 `[custom]` 下塞一个未鉴权事件 | `test_baseline_matches_live_inventory` 红 |
| 在 qb-core 里塞一个未鉴权事件 | `test_enforced_batch_has_zero_unguarded_events` 红 |
| 变量名注册 / handler 缺行首 `end)` | 各自的闸门红 |
| 把债的 `expires` 改成过去 | 过期即红 |
| 手改批次数字 / 每资源数字 | `test_batch_totals_add_up` / `test_recorded_counts_match_the_live_scan` 红 |
| 删掉 custom-security 对刷车回调的劫持 | `test_relay_callbacks_that_spawn_vehicles_are_guarded_somewhere` 红 |
| 把 `src == 0` 又当成鉴权 token | `test_system_source_token_only_counts_the_server_only_shape` 红 |
| `RegisterNetEvent (`（多一个空格） | 扫描器仍然收得到（反向用例钉住） |
| 注释里写 `-- PolicePolicy.Can(` / 字符串里印 token | 不算鉴权（两条反向用例） |

**11 条变异用例全部"注入红 / 对照绿"**（`tools/dev/gate_mutation_smoke.py --only net_event`）。

## 7. 还没做到的（诚实记账）

| 计划里的判据 | 现状 | 差距 |
|---|---|---|
| ① 引擎层（qb-core）100% | ✅ 15/15 | — |
| ② `[custom]` ≥ 80% | **64%**（86/134） | 80% 需要 108 个，还差 **22** 个。剩下的大头：`custom-quest` 10、`custom-justice` 7、`custom-police` 派发 5、`custom-cartel` 4、`custom-agent-client` 4、`custom-vehicles` 9 |
| ③ `[qb]` 登记为带 expires 的债务 | ✅ 58 个仍有欠账的资源各有 owner + expires（2027-03-31）：`[qb]` 28 个、`[custom]` 12 个、other 18 个 | 到期前要么修，要么续期并说明 |

其它已知残余（不阻塞本步，但要在下一轮处理）：

* `QBCore.ClientCallbacks` 只按 `name` 作键（`functions.lua:468`）：两个玩家同时触发同名回调时，
  后一个会覆盖前一个的条目，前一个的 `pending` 永远等不到 resolve（归属校验挡住了"别人替你答"，
  但挡不住"同名互相踩"）。修法是按 `(name, source)` 存。
* `qb-inventory` 的 `vehicleCheck`（`commands.lua:121`）仍信任客户端返回的 `inventory` / `class`：
  归属校验只挡住"别的玩家"，被问的玩家仍可伪造自己打开哪个 trunk。
* 基线 `measured_at` 用 `date.today()`：每天重生成都会变，别把"重生成"当成无脑操作。
