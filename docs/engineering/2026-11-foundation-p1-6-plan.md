---
id: p1-6-plan
type: plan
status: active
system: infra
owner: hermes
updated: 2026-11-07
review_by: 2026-12-31
---

# P1-6 施工计划：重启后的「失效函数引用」与审计留存

> 来源：2026-11-07 真机 `qb-clothing` 报 `Execution of function reference in script host failed`。
> 验收方（CC）独立调研 + 实施方裁决，本文件记录结论与取舍。

## 1. 结论摘要

1. 这是**第三类**跨资源引用问题，与前面两类都不同：
   | # | 形态 | 何时炸 | 已处理 |
   |---|---|---|---|
   | 1 | MySQL **回调闭包**里调跨资源函数引用 | 运行时（进角色/取车） | PR #193/#194 + 闸门 G-A1 |
   | 2 | `MySQL.x.await` **续体** | 不炸（续体回到调用方协程） | 调研订正，无代码改动 |
   | 3 | **顶层缓存** `local QBCore = exports['qb-core']:GetCoreObject()` | `restart qb-core` 之后 | **本文件** |
2. 顶层缓存拿到的是 **qb-core 当次 script host 的快照**；qb-core 重启后表里的函数引用失效。
   没有声明 qb-core 依赖的资源不会被重启级联带走 → 旧表一直用下去。
3. 规模（CC 可执行口径）：172 个文件顶层缓存，156 个用到函数引用，其中 119 个随级联自愈。
   本仓扫描器（口径见 §3 阶段 A）判定 **server 侧 23 个文件**是真风险，另有 **13 个 client 文件**
   单独记账（跨客户端语义未验证）。CC 初稿报 35/36，其中 12 条其实是 client 文件被旧的路径启发式
   算进了 server —— 收口时按目录段重新划归，数字从 35 变成 23 + 13。
4. `exec configs/modules/*.cfg`（ensure）**修不了**这类问题：`ensure` 对运行中的资源是 no-op，
   而风险集恰好是"从没被停过"的那批。

## 2. 修法选型（已拍板）

| 方案 | 结论 |
|---|---|
| ① 每次调用都惰性解析 `GetCoreObject()` | **否** —— `GetPlayer` 在热路径，跨资源 export + 表物化成本不可接受 |
| ② `onResourceStart('qb-core')` 里重解析 | **采用** —— 停机面不变，一处几行 |
| ③ qb-core 广播自定义事件 | 否 —— 原生 `onResourceStart` 就是资源就绪信号，自造事件只多一层时序风险 |
| ④ 给 21 个资源加 `dependency 'qb-core'` | 否 —— 重启影响面变大（这 21 个会被一起停），留作最后手段 |

## 3. 分阶段

### 阶段 A（P0，本轮完成）

1. **qb-clothing 的服务端主文件**：顶层缓存后加 `onResourceStart` 重解析（真机故障点）。
2. **custom-security 的服务端主文件**：原来的重挂只复位了 `callbackGuardsInstalled`，
   **没有重解析 `QBCore`** —— 守卫会重新挂到旧表上（装上但无效）。现在两者都做。
3. **闸门 `test_no_stale_core_cache.py`** + `stale_core_cache_scan.py`：
   四条件判定（顶层缓存 ∧ 用函数引用 ∧ 无重解析 ∧ 不在级联内），基线 **server 23 条**棘轮，
   client 13 条记 `client_unverified`（不进棘轮，但新增同样判红）。
   判重挂是**结构化**的：只认 `AddEventHandler('onResourceStart'|'onClientResourceStart')`，
   且窗口内必须给**同一变量**重新赋值 `GetCoreObject()` —— `RegisterNetEvent` 冒充、
   注释里写事件名、给别的变量赋值，都不算自愈（CC 首轮验收的三条假阴性，已各有反向用例）。

### 阶段 B（P1，本轮完成）

4. **审计留存**（`custom-logs`）：
   - 按天分片 `<type>_audit-YYYY-MM-DD.log`，单文件超 10MB 滚动到 `-2`/`-3`（单日 20 片封顶）；
   - 保留 `custom_logs_retention_days`（默认 30）天，启动时宽扫 10 年清积压，之后每小时窄扫；
   - **删除只看 retention**：探测范围宽 ≠ 删得狠（第一版就写错了，把 5 天前的文件删了，测试抓住）；
   - 当天文件永不删；`AuditSweepNow` 导出可手动触发。

### 阶段 C（P2，未做）

5. 剩余 23 条 server 风险逐资源偿还（每个资源 1–2 行，但要逐个真机验证）。
6. 13 个 **client** 侧风险文件：`onClientResourceStart('qb-core')` 的跨客户端语义**未在真机验证**，
   验证前不动。
7. 审计轮转参数进 SOP（convar 名、默认值、怎么改）。

## 4. 交付标准（DoD）

| 编号 | 断言 | 验证方式 | 反向形状 |
|---|---|---|---|
| G1 | 顶层缓存 + 用函数引用 + 无重解析 + 不在级联内 → 判红 | `stale_core_cache_scan.py` | fixture 新增一个这样的文件 → 红 |
| G1b | 四种伪装形态不许判安全（RegisterNetEvent / 注释 / 别的变量 / 多缓存只判第一个） | 扫描器自证 | 把 `_has_rehook` 改成恒真 → 自证用例红 |
| G2 | 三种安全形态（有重解析 / 声明依赖 / 只用 Shared 数据）不误报 | 扫描器自证 | 让 `_has_rehook` 恒真 → 自证用例红 |
| G3 | 基线 server 23 / client 13 只许减 | 双向相等 + 元数据（owner/expires/count） | 改 count → 红 |
| G4 | `custom-security` 重挂时**同时**重解析 QBCore | 静态断言 handler 体内有赋值 | 删那行 → 红（阶段 A 已实机验证方向） |
| G5 | 审计分片：过期删除、窗口内保留、当天保留、幂等 | Lua 沙箱跑真实 `SweepOldLogs` | 去掉 retention 判断（能探到就删）→ 红 |
| G6 | 已有回归全绿 | `pytest tests/unit tests/architecture tests/integration` | — |
| G7 | 真机 | `restart qb-core` + resync + 客户端加载 → 0 SCRIPT ERROR；审计按天分片、过期被清 | — |

## 5. 真机证据（2026-11-07）

- 修复前：`restart qb-core` 后客户端加载 → `[script:qb-clothing] SCRIPT ERROR: Execution of function reference…`
- 修复后：同样的 `restart qb-core` + `resync_modules.ps1` + 客户端加载 → **0 SCRIPT ERROR**
- 审计：`[custom-logs] 🧹 启动清理：删除 1 个过期审计分片（保留 30 天）`，当天分片保留。

## 6. 不做的事

1. 不给 172 个缓存文件全部加 `dependency`（119 个本来就自愈，扩大停机面无收益）。
2. 不用 `pcall` 吞掉函数引用错误 —— 会把"静默失效"变成"带病运行"。
3. 不把 `ensure` 当重启用（SOP 已写明）。
4. 不做通配删除：清理只按文件名里的日期精确探测。
