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
   实施方词法扫描实测 **120 处** `$%d` 相邻的金额字面量（21 个资源；首版报 129，
   经验收方指出 `%.d` 与 regex pattern 误报后收紧为「`$` 紧跟 `%d`」）。
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

判定依据（来自 PR #193 的真机栈）：在 oxmysql/JS **异步回调闭包**里调用
**另一个资源经 `GetCoreObject()` 拿到的 Lua 函数引用**会抛
`Execution of function reference in script host failed`；oxmysql 侧报
`the reference wasn't valid`。`CreateThread + Wait(0)` 挪线程**实测无效**。

**订正（2026-11-07，验收方指出）**：`MySQL.x.await` 的**续体是安全的** ——
oxmysql 的 Lua 包装里 `.await` = `promise.new()` + `Citizen.Await(p)`，恢复的是**调用方自己的协程**；
只有传给 JS 的**回调闭包**才在 oxmysql 宿主里执行。实证：全仓 337 处 `.await`，
`qb-management/server/sv_gang.lua:24-26` 在 `MySQL.query.await` 之后直接调
`QBCore.Functions.GetPlayerByCitizenId`，长期运行无报错。所以 `qb-garages` 的修法（改 await）成立。

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
| 其余 14 个资源 | 33 → 6 | 已偿还 taxes/phone/quest 的高危点 |

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

### 阶段 B（P1）  ✅ 闸门 + 首批偿还完成（2026-11-07）

4. **闸门 G-B1（棘轮）**：`$` 与 `%d` 同串的字面量集合必须**逐条等于**基线（129 条，含
   文件+行文本指纹），新增要登记、删除要同步 → 双向相等。配反向 fixture。
5. **修高危点**：`custom-taxes`（比例税）、`custom-phone`（转账）、`custom-quest`（乘算奖励）
   —— 已修，三个资源各自加资源内的 money_format 共享脚本（`TCMoney` / `PhoneMoney` / `QuestMoney`，
   语义一致：整数不带小数点、小数两位），基线 120 → **93**。
   `qb-drugs`（押金/奖励）、`custom-cartel`（分红）**未修**，留在基线里作为债（到期 2027-03-31）。
6. **闸门 G-B2**：`math.floor(<money 名>)` → 红，除非行尾 `-- money-int-ok`。

### 阶段 C（P1）  ✅ 2026-11-07 完成

7. **桥接 qb-log → custom-logs**：已落地 —— `AddEventHandler`（不是 `RegisterNetEvent`，
   防客户端伪造），`playermoney`/`economy` → `LogEconomy`，`anticheat`/`bans`/`security` → `LogSecurity`，
   其余 → `LogGeneric`。
8. **PII 脱敏**：已落地 custom-logs 的 shared 目录里 sanitize 脚本提供的 `SanitizeLogText` ——
   `citizenid` 掩码（8 位以下整体 `***`）、`license`/`ip`/`discord`/`steam` 值打码、
   控制字符清掉、正文截断 500。玩家名保留（排查需要，且不是可登录凭据）。
9. **闸门 G-C1**：活跃 `TriggerEvent('qb-log:...')` 必须能找到被 `ensure` 的 handler；
   桥接存在且调用 `sanitize()`。配反向 fixture（payload 含 `playerIp` → 红）。

### 阶段 D（P1）  ✅ 2026-11-07 完成

10. **`tools/dev/resync_modules.ps1`**：已落地 —— RCON 包装，`-DryRun` 打印 17 条 `exec`
    （顺序同 `server.cfg`），实跑后查 `info.json` 核对资源数 85，不足则退出码 1。不动原 `.sh`。
11. **SOP 文档**：活服禁止 `restart qb-core/core-framework/oxmysql`；必须热重启时按顺序
    `exec configs/modules/*.cfg`；验证三件事（资源数 85、无 `No such export`、关键命令已注册）。

### 阶段 E（P1）  ✅ 2026-11-07 完成（金额 A 档偿还）

12. **A 档 26 处偿清**（基线 93 → 68）：qb-drugs 8、custom-cartel 9、custom-crime 3、
    custom-security 2、custom-main 2、custom-market 2。每个资源自带 shared 下的 money_format 模块
    （函数 `Money`），不跨资源引用。
13. **B 档 21 处留基线**（整数常量 / `math.floor` / DB 整数列），`$comment` 已注明是假阳性；
    **C 档 46 处**多为 production-freeze 的 locale 模板串（当前无调用点，但 `string.format`
    通路是真的，记为潜在陷阱）。
14. 新增 `test_money_renderers.py`：8 个渲染器 × 8 组输入 —— 静态闸门只看"还有没有 `$%d`"，
    看不见"渲染成 500 还是 500.00"。

### 阶段 F（P0 安全）  ✅ 2026-11-07 完成（qb-drugs 配送服务端权威）

15. **押金/报酬/时间窗口改服务端算**：接单时按 Config 反算并存档（`activeDeliveries[src]`，
    绑定 citizenid），数量固定 1，结算只认存档，`elapsed` 用服务端计时，背包无货不发钱。
16. **单活跃配送约束 + 掉线清理**：防"连开两单覆盖记录"（净赚 500/轮）与"source 复用结算旧单"。
17. 新增 test_drugs_delivery_authority.py 与同目录 fixtures 下的 drugs_delivery_probe 探针：mock 掉 FiveM
    运行时（含**真的**定时器队列），真的触发 net event 断言钱与货的走向。

### 阶段 G（P1）  ✅ 2026-11-08 完成（掉线配送结算）

18. **掉线不再白扣押金**：`playerDropped` 把未结算配送记到 citizenid；重新上线时结算 ——
    货在就回收 + 全额退押金，货没了就不退。不在离线阶段动背包（会和存档打架）。
19. 新增用例 `test_drop_settlement_refunds_only_when_goods_are_recovered`（退 500 / 货清零、货没了退 0），
    反向验证：退回上一版实现 → 红。

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
| G13 | 金额 A 档 26 处偿清：基线 == 扫描 68 条，且与分档口径对得上 | `money_format_scan.py` 双向相等 | 改回 `$%d` → 红 |
| G14 | 配送押金/报酬不采信客户端 | `test_drugs_delivery_authority.py`（押金 500 / 发货 1 / 结算 1500） | 退回旧实现 → 押金 0 / 发货 999 / 结算 2.2e9 |
| G15 | 单活跃配送 + 断线不复用 | 同上（连开两单只扣 1 次；source 复用 0 收入） | 去掉 citizenid 核对 → 红 |
| G16 | 两个配送事件被闸门识别为已鉴权 | net event 基线 qb 未登记 197 → 195 | 改回无校验 → 红 |

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
| 金额 `%d` 规模 | 「已证实的金额 `%d` 只有两处，其余是计数/ID」 | 词法扫描 120 处 `$%d`（首版 129 含 9 条 regex/`%.d` 误报，已收紧） | **两边都对了一半**：CC 的"两处"是已实锤的线上炸点，不是缺陷类总量；实施方扫的是全部候选 → 采用 120 条基线 + 逐个 triage |
| A 类修正范围 | 主张修 `qb-garages` + 盘 `SaveInventory` | 同 | 一致 |
| 是否新建审计表 | 建议先文件/webhook | 同 | 一致（P2 再评） |
| 重启级联 | 给 SOP + 脚本 | 同 | 一致；基线取 85 |

## 8. 已知遗留

- `custom-testing` 两个压测脚本仍读旧的 persistence 字段（`dirty_count` 已移除）。
- P1-3 最后 13 个 net event（含需服务端验高的 `aviationHeightMonitorComplete`）挂着 2027-03-31 的到期日。
- 真机 G13（选人界面停 5 分钟 / 换角色 / 连续加钱）当时未做完，本阶段 G12 一并补。

- **掉线配送已解决**（阶段 G）：不在离线阶段动背包（会和存档打架），改为把未结算配送记到
  citizenid，等玩家**重新上线**（在线、背包可安全操作）时结算 —— 货在就回收 + 全退押金，
  货没了就不退。代价是"掉线当下"押金仍处于冻结状态，最长冻结到玩家下次上线。
- **client 侧 19 个顶层缓存文件未修**：`onClientResourceStart('qb-core')` 的跨客户端语义需要
  真人客户端在场才能验（本次实机时客户端未连上），修法与服务端一致（线程重试），但没验证前不动。
