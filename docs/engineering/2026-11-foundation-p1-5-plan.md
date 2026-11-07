---
id: p1-5-plan
type: plan
status: active
system: infra
owner: hermes
updated: 2026-11-07
review_by: 2026-12-31
---

# P1-5 施工计划：真机缺陷（跨资源引用 / 金额格式化 / 审计与运维）

> 来源：2026-11-01 首次真机（有人类客户端进服）暴露的问题。两份**独立**调研：
> 实施方做全仓静态扫描，验收方（CC）做语义判定与调用链追踪，本文件是合并结论，
> 冲突处标注取舍并给出裁决依据。

## 1. 结论摘要

1. **跨资源函数引用**是真风险，且上一轮只修好了一个点：`qb-garages` 取抵押车
   （`qb-garages/server/main.lua:276,279`）在 `MySQL.scalar` 回调里调
   `Player.Functions.RemoveMoney` —— 与 PR #193 修掉的是同一形态。**P0**。
2. **金额格式化的规模双方判断冲突**：验收方看完样本后认为"只有 economy_service 两处"；
   实施方词法扫描实测 **129 处** `$` 与 `%d` 同串的字面量（21 个资源）。
   **以实施方为准**（可复现：抽字符串字面量后同时匹配 `$` 与 `%d`）。所以策略是
   **基线 + 棘轮 + 高危逐个修**，不是"两处已修完"。
3. **审计链路是真问题但不是崩溃**：`qb-log:server:CreateLog` 全仓 47 处活跃发送点，
   唯一监听者在不启动的 `archive/` 里 → 活跃服 0 消费者。`custom-logs` 有现成
   `LogEconomy/LogSecurity/LogGeneric` export 却没桥接。
4. **重启级联是流程问题**：`qb-core` 被 44 个资源声明依赖、`core-framework` 29、`oxmysql` 19；
   `restart qb-core` 会停掉它们且不自动拉回（真机实测：85 → 42）。`resync_modules.sh`
   依赖 Linux 的 `tcity-cmd`，本机不会自动执行。

## 2. 范围

| 编号 | 内容 | 级别 |
|---|---|---|
| A | DB 回调里的跨资源函数引用：修 `qb-garages`、盘点 `SaveInventory` 调用方、加闸门 | P0 |
| B | 金额/余额格式化：`$%d` 棘轮闸门 + 修高危点（税、转账、任务奖励） | P1 |
| C | 审计桥接：`qb-log:server:CreateLog` → `custom-logs`，含 PII 脱敏 | P1 |
| D | 重启级联：Windows 侧 resync 包装 + SOP + 资源数基线断言 | P1 |

## 3. 缺陷清单与证据

### A. 跨资源函数引用（真机已证实）

判定依据（来自 PR #193 的真机栈）：在 oxmysql/JS 异步回调（或其 `await` 续体）里，
调用**另一个资源经 `GetCoreObject()` 拿到的 Lua 函数引用**会抛
`Execution of function reference in script host failed`；oxmysql 侧报
`the reference wasn't valid`。`CreateThread + Wait(0)` 挪线程**实测无效**。

| 编号 | 位置 | 触发时机 | 形态 | 状态 |
|---|---|---|---|---|
| A1 | `qb-garages/server/main.lua:276,279` | 取抵押车 | `MySQL.scalar` 回调里 `Player.Functions.RemoveMoney` | **未修 · P0** |
| A2 | `qb-core/server/player.lua:Saved`（PR #193） | 进角色 | `SaveInventory(source)` → callee 里 `GetPlayer(source)` | 已修 |
| A3 | `qb-inventory/server/functions.lua:106` | 取决于调用方 | offline=false 分支会调 `GetPlayer` | 调用方待盘点 · P0 |
| A4 | `qb-core/server/player.lua:149-151` | 进角色 | `LoadInventory(source, cid)`，callee 只用 `QBCore.Shared` 数据 | 安全 · 观察 |

**噪音（不用改）**：回调体里只有 `TriggerEvent` / `TriggerClientEvent` / `GetPlayerName`
这类原生函数，任何 script host 都能调。实施方粗扫的 97 处候选里，绝大多数属于这一类
（`economy_service.lua:295-311`、`custom-vehicles/server/compat.lua:251-277`、
`qb-clothing/server/main.lua:100-129`、`qb-drugs/server/deliveries.lua:192-268`）。

### B. 金额格式化（基线 129 处 / 21 资源）

| 资源 | `$`+`%d` 同串 | 备注 |
|---|---|---|
| production-freeze | 42 | 多为 locale 文案（税率、保险、房产税） |
| custom-taxes | 12 | **税 = 比例计算，必然产生小数** |
| custom-phone | 10 | 银行转账 |
| custom-cartel | 9 | 交易/分红 |
| qb-drugs | 8 | 押金、送货奖励 |
| custom-quest | 8 | 奖励乘算（0.85 倍等） |
| custom-market | 7 | 价格 |
| 其余 14 个资源 | 33 | 零散 |

危险等级取决于**入参是否可能带小数**：`%d` 对 `500.0` 不抛（Lua 5.4 里它是整数表示），
对 `0.5` / `0.85*100` 抛。税率、佣金、乘算奖励这三类必然带小数。

### C. 审计（0 消费者）

- 发送点：47 处（18 个活跃资源；含 `archive/` 共 53 处）。
- 监听点：仅 `archive/qb/qb-smallresources/server/logs.lua:59`，该资源不在 `ensure` 列表。
- custom-logs 的 server/logs.lua 只有 `exports('LogEconomy'/'LogSecurity'/'LogGeneric')`，
  写本地文件 + Discord webhook，**没有**监听该事件。
- 后果：`playermoney` / `anticheat` / `joinleave` 审计全部丢失；PR #193 那个 `%d` bug
  唯一可见症状是报错，正是因为消息没人接。

### D. 重启级联（真机实测）

| 资源 | 依赖它的资源数 |
|---|---|
| qb-core | 44 |
| core-framework | 29 |
| oxmysql | 19 |
| production-freeze | 10 |
| qb-inventory | 10 |

真机：`restart qb-core` → 资源 85 → **42**，客户端刷 `No such export GetCoreObject`。
基线口径：`configs/modules/*.cfg` 共 86 条 `ensure`，`custom-director` 重复一次 → **85 个唯一资源**。

## 4. 分阶段施工

### 阶段 A（P0，本轮必做）

1. **A1 修 qb-garages**：把 `depotprice` 在进入异步上下文之前取到（或改成
   `MySQL.scalar.await` 后立刻回到同步段），扣款只在同步段执行。
   验收：`luac5.4 -p`；真机取抵押车 0 SCRIPT ERROR、余额只扣一次。
2. **A3 盘点 `SaveInventory(` 全部调用点**：非 offline 形态必须在同步段，否则改传
   `PlayerData, true`。产出登记表（文件 + 形态 + 是否安全）。
3. **闸门 G-A1**：静态扫描「MySQL 回调体内出现 `Player.Functions.` / `QBCore.Functions.` /
   `exports[`（非数据形态）」→ 红。配反向 fixture。允许白名单（带 owner + 到期）。

### 阶段 B（P1）

4. **闸门 G-B1（棘轮）**：`$` 与 `%d` 同串的字面量集合必须**逐条等于**基线（129 条，含
   文件+行文本指纹），新增要登记、删除要同步 → 双向相等。配反向 fixture。
5. **修高危点**：`custom-taxes`（比例税）、`custom-phone`（转账）、`custom-quest`（乘算奖励）、
   `qb-drugs`（押金/奖励）、`custom-cartel`（分红）。统一用「整数不带小数点、小数两位」的
   渲染函数；每修一处从基线里删一条。
6. **闸门 G-B2**：`math.floor(<money 名>)` → 红，除非行尾 `-- money-int-ok`。

### 阶段 C（P1）

7. **桥接 qb-log → custom-logs**：`AddEventHandler`（不是 `RegisterNetEvent`，防客户端伪造），
   `playermoney` → `LogEconomy`，`anticheat`/`bans`/`security` → `LogSecurity`，其余 → `LogGeneric`。
8. **PII 脱敏**：现有 `message` 是自由文本且多处含 `license`/`playerIp`/完整 `citizenid`。
   桥接层必须先 `sanitize()`（掩码 cid 前4…后4、抹掉 license/ip/discord），再落盘。
9. **闸门 G-C1**：活跃 `TriggerEvent('qb-log:...')` 必须能找到被 `ensure` 的 handler；
   桥接存在且调用 `sanitize()`。配反向 fixture（payload 含 `playerIp` → 红）。

### 阶段 D（P1）

10. **`tools/dev/resync_modules.ps1`**：RCON 包装，`-DryRun` 打印 17 条 `exec`，
    实跑后断言资源数回到 85。不动原 `.sh`。
11. **SOP 文档**：活服禁止 `restart qb-core/core-framework/oxmysql`；必须热重启时按顺序
    `exec configs/modules/*.cfg`；验证三件事（资源数 85、无 `No such export`、关键命令已注册）。

## 5. 交付标准（DoD）

| 编号 | 断言 | 验证方式 | 反向形状 |
|---|---|---|---|
| G1 | A1 修好：`qb-garages` 的扣款不在 MySQL 回调体内 | G-A1 闸门对该文件 0 命中 | 注入同样一行 → 红 |
| G2 | A3 盘点完成：`SaveInventory(` 调用点集合 == 登记表 | pytest 集合相等 | 新增未登记调用点 → 红 |
| G3 | G-A1 闸门本身有效 | 全仓 0 命中（除白名单） | fixture 注入回调内 `Player.Functions.` → 红 |
| G4 | G-B1 棘轮：`$%d` 集合 == 基线 129 条 | 双向集合相等 | 新增 `('$%d'):format(0.5)` → 红；删一条不同步 → 红 |
| G5 | 高危点修完：taxes / phone / quest / drugs / cartel 不再用 `%d` 渲染金额 | 基线中这 5 个资源计数为 0 | 改回 `%d` → G4 红 |
| G6 | G-B2：`math.floor(<money 名>)` 0 命中 | 全仓扫描 | fixture `math.floor(amount)` → 红 |
| G7 | C：桥接存在且脱敏 | 单测：桥接注册 + `sanitize` 被调用 | payload 含 `playerIp`/`license` → 红 |
| G8 | C：`qb-log` 有消费者 | G-C1 断言任一处发送点能找到 handler | 删 handler → 红 |
| G9 | D：resync 脚本可跑 | `-DryRun` 输出 17 条 `exec`；实跑后资源数 == 85 | 跳过 `core.cfg` → 断言失败 |
| G10 | 既有回归全绿 | `pytest tests/unit tests/architecture tests/integration` | — |
| G11 | 闸门预算不抬高 | `gate_coverage` 未证明数 ≤ 276 | 改 budget → 评审打回 |
| G12 | 真机 | 干净重启 85 资源 0 SCRIPT ERROR；取抵押车 / 转账 / 交税 / 拿任务奖励四条路径无错 | — |

## 6. 施工纪律

1. **不批量替换 `%d`**：计数、ID、时间戳、测试断言本来就是整数；只盯金额/余额/时长。
   闸门只拦 `$`+`%d` 与 money 名的 `math.floor` 两种确定形态。
2. **不用 `CreateThread + Wait(0)` 修跨资源引用**：PR #193 已实测无效。
3. **不把 `qb-log:server:CreateLog` 注册成 `NetEvent`**：客户端可伪造。
4. **不在本轮新建审计表**：先文件 + webhook 过渡（`custom-logs` 现成实现），结构化字段预留。
5. **不改 `resync_modules.sh`**：它是 Linux 布局用的；Windows 另加 `.ps1`。
6. **每条闸门必须带反向形状**，否则不算完成。

## 7. 双方差异与取舍

| 议题 | 验收方（CC） | 实施方 | 裁决 |
|---|---|---|---|
| 金额 `%d` 规模 | 「已证实的金额 `%d` 只有两处，其余是计数/ID」 | 词法扫描 129 处 `$`+`%d` | **按实施方**：CC 只看了样本；129 处可复现，且税/佣金/乘算必然带小数 |
| A 类修正范围 | 主张修 `qb-garages` + 盘 `SaveInventory` | 同 | 一致 |
| 是否新建审计表 | 建议先文件/webhook | 同 | 一致（P2 再评） |
| 重启级联 | 给 SOP + 脚本 | 同 | 一致；基线取 85 |

## 8. 已知遗留

- `custom-testing` 两个压测脚本仍读旧的 persistence 字段（`dirty_count` 已移除）。
- P1-3 最后 13 个 net event（含需服务端验高的 `aviationHeightMonitorComplete`）挂着 2027-03-31 的到期日。
- 真机 G13（选人界面停 5 分钟 / 换角色 / 连续加钱）当时未做完，本阶段 G12 一并补。
