---
id: engineering-2026-11-abstraction-convergence-plan
type: plan
status: active
system: meta
owner: hermes
updated: 2026-11-15
review_by: 2027-03-31
---

# 抽象收敛施工计划（2026-11）

> 唯一来源：`abstraction-audit-report.md`（2026-11-15，已定稿）。本文件只把报告 §4/§5/§6
> 变成**可逐片验收**的施工计划；不新增报告之外的主题。
>
> 基线：`origin/master` @ `8e2d96c0`，worktree 为 `E:/T-City-abs`（干净）。
> 所有 `path:line` 已回到本 worktree 的源码逐条核对；报告与本 worktree 不一致的地方见 §0.2。
>
> 阅读约定：`代码字体` 是**仓库中已存在**的路径（`test_docs_links.py` 会校验）；
> **加粗** 是本计划要新建、当前还不存在的路径。命令中的解释器统一用
> `C:/Users/swkgb/AppData/Local/Programs/Python/Python312/python.exe`（本机没有 `python3`）。

---

## 0. 结论与事实校准

### 0.1 一句话

按报告 §6 的顺序做 **8 片**：S1 是其余所有片的前置闸门；原 S2「退役 Bus」拆成
**S2a（场景/作业/车辆 + Bus 闸门）** 与 **S2b（税/热度/通知 + owner 导出）**，
因为原样执行会是一个 20+ 文件、2–3 天的 PR，违反本计划「一片一个 PR、≤1 天」的尺度。
其余 S3–S7 保持报告的原始主题。总片数 8，不新增报告范围外的主题。

### 0.2 报告数字 vs 本仓核实

| 报告条目 | 报告写法 | 本 worktree 核实（`8e2d96c0`） | 本计划处置 |
|---|---|---|---|
| §5.1 E 自研死调用 | 13 处 | **11 个真实调用表达式 + 2 个非调用引用**（注释 1、测试断言/桩 1） | 修 11 个真实调用；另修 1 个 pcall 兜底（`custom-career:GetLocalIdentity`）；2 个引用不改代码，闸门按「剥注释/字符串」判定；见 §4.1.2 |
| §5.1 E `custom-main:CheckStoreRobbery` | ×1 | 只有 `T-CityLite.base/resources/[custom]/custom-testing/suites/04_security_test.lua:65` 的注释；无真实调用 | 不修代码；测试注释保留 |
| §5.1 E `custom-economy:AddScaledMoney` | ×2 | 1 个真实调用（`T-CityLite.base/resources/[qb]/qb-drugs/server/cornerselling.lua:79`）+ 1 个测试断言字符串（`T-CityLite.base/resources/[custom]/custom-testing/suites/07_economy_admin_test.lua:12`） | 修 1 个真实调用；断言字符串由闸门忽略 |
| §2.1 `service_*` 调用点 | 33 | 33（custom-crime 1、justice 4、notify-test 11、cartel 10、mining 5、market 1、police 1） | S1 逐条登记；不改名 |
| §4.3 `reuse_scan` 的 `LoadModel` 计数 | 7+，建议加预算 | `DEF_RE` 按大小写精确统计：`LoadModel` 2 份（`entity_util`、`CFShared`），`loadModel` 2 份（progressbar、qb-multicharacter），都 < `MIN_COUNT=4` | **不新增 `reuse_budget.json` 条目**（加了会被 `test_reuse_budget.py` 的「条目已不再重复」判红）；验收改用语义闸门 |
| §4.4 `reuse_scan` 的 `Money` 计数 | 6→1，建议加预算 | `Money` 5 个字符 < `MIN_NAME_LEN=6`，扫描器根本不统计；`PhoneMoney`/`QuestMoney`/`TCMoney` 各 1 份 | **不新增 `reuse_budget.json` 条目**；验收改用语义闸门 |
| §4.3 热狗客户端文件 | 工作区已修改、本次不动 | 本 worktree 里它们已入库；循环有 `deadline`/`generation` 退出条件，不是无超时形状 | 不动；S5 闸门只抓无退出条件的本地循环 |
| §5.1 C `[custom]` 的 `-1` 广播 | 28 处 / 9 文件 | 28 处 / 9 文件（`evidence.lua` 9、`custom-vehicles` 9、`custom-police` 6、`custom-phone` 3、`custom-cartel` 1） | S7 只改 `evidence.lua` 9 处；其余 19 处登记为 `all` |
| §4.6 `T-CityLite.base/resources/[custom]/custom-police/server/main.lua` 广播 | 2 处 | 3 处（`:96`、`:327`、`:422`） | S7 按实测 3 处登记 |
| 报告未列的 `T-CityLite.base/resources/[custom]/custom-police/server/objects.lua` | — | 2 处 `-1`（`:34`、`:44`） | S7 登记为 `all`，不改行为 |
| `gate_coverage_budget.json` | `max_unproven=278` | 278（`tools/dev/gate_coverage.py --json` 实测：`total=558`、`proven_by_smoke=69`、`proven_by_reverse_tests=211`、`proven_by_history=3`） | 6 条新前向规则全部配变异用例 → 增量 **+0**；见 §4 各片记账 |

### 0.3 本计划**不**当作既成事实的 ⛔ 条目

报告 §8.3 标了 ⛔ 的条目，本计划只把它们当**待验证假设**，不当成施工依据：

1. **`exports[owner][dynamicName]` 字符串下标访问**：不提供运行时 helper；S1 只做静态闸门。
   若以后要加 `CoreService.Call`，先做一次真机探针
   `print(type(exports['custom-storage']['service_storage_CanAccess']))`，再单独排片。
2. **`rawget(_G,'Config')` 是否真取不到**：信号 B 不在本计划（见 §1.3）；先做报告 §8.3 #2 的
   真机打印，再决定是 bug 还是风格统一。
3. **外部资源是否存在/导出**（`LegacyFuel`、`qb-vehiclekeys`、`safecracker` 等）：S1 的
   `external_exports` 只是**允许清单**，不是「这些导出一定存在」的证明；本计划不依赖它们的行为。
4. **commit 历史**：本计划没有读 `git log`；所有「为什么当初这么写」的判断都不作为施工前提。
5. **测试/闸门实跑**：本文件写的是预期红绿；每个实施 PR 必须贴**真实输出**。
6. **真机行为**：BGM、税收、证据广播、模型缺失等只在 §4 各片的真机清单里验收，不写成「应该没问题」。

---

## 1. 范围

### 1.1 要做（8 片）

| 片 | 主题 | 报告来源 | 文件数 | 一句话验收 |
|---|---|---|---|---|
| S1 | 方法级导出契约闸门 + 修 11 个真实死调用 | §4.1、§6 第 1 件 | 14 | 新闸门在真实仓库绿、反向注入红；11 个死调用 + 1 个 pcall 兜底全部换成真实 owner |
| S2a | 退役跨资源 Bus（场景/作业/车辆）+ Bus 闸门 | §5.1 A、§6 第 2 件 | 12 | 4 个扫描根内 0 个 `Bus.<service>` 读取；`qb-vehicleshop` 的 8 个 `service_dealership_*` 真实存在 |
| S2b | 退役跨资源 Bus（税/热度/通知）+ owner 导出 | §5.1 A、§6 第 2 件 | 13 | 5 类 `_G.Bus` 读取消失；税走 `SinkWithdraw`、热度走 `HeatReset`、通知走原生事件 |
| S3 | 限流收口到 `RateLimit` | §4.5、§6 第 3 件 | 12 | 8 文件/9 张本地表消失；`IMPL_MARKERS` 扩展后先红后绿 |
| S4 | `Db` 结果适配器 | §4.2 | 19 | `[custom]`/core-framework 范围内，`insertId/affectedRows` 归一化只在 **core-framework/server/db.lua**；4 种返回形状单测全绿 |
| S5 | `CFShared.LoadModel` 采纳 | §4.3 | 12 | 8 个迁移文件不再有无退出条件的本地模型循环 |
| S6 | `FormatMoney` 合并 + `$%d` 基线下降 | §4.4 | 17 | 8 份实现变 1 个 `money_aliases.lua`（4 个别名）+ 8 个 manifest include；`$%d` 基线 66→59 |
| S7 | 受众感知广播收口 | §4.6 | 11 | `evidence.lua` 9 处 `-1` 改 `Broadcast.Scope`；其余 19 处全部登记 |

> 文件数含新增测试、登记表、`CHANGELOG.md`、文档；不含 `git revert` 之类的回滚操作。
> 超过 12 文件的片在 §3 写明为什么不能再切。

### 1.2 明确不做（照抄报告 §6 的 14 条）

| 不做项 | 理由 |
|---|---|
| 合并 `DebugPrint` | REUSE.md 已定案：同名不同语义，各带调试开关/前缀（`reuse_budget.json` 的 `DebugPrint` 条目） |
| 合并 `[qb]`/`[standalone]` 的重复 | REUSE.md 已定案：不迁上游/第三方，避免分叉 |
| 再合并 `DrawText3D` | 已合并到 `CFShared.DrawText3D`（`reuse_budget.json` 条目、`T-CityLite.base/resources/[standalone]/core-framework/client/shared.lua:33-48`） |
| 把业务冷却并进 `RateLimit` | `quest_cooldowns` 是持久化状态（`T-CityLite.base/resources/[custom]/custom-quest/server/quest_db.lua:157-206`），进程内限流重启即丢；语义不同 |
| 合并通知封装 | `QBCore:Notify` 原生、`custom-notify` 资源、phone NUI 三种通道语义不同；合并会改观感/延迟 |
| 合并权限检查 | `QBCore.Functions.HasPermission` 已是 owner；`PolicePolicy.Can`/`OrgStorage.CanAccess` 是域内策略，不是通用权限 |
| 全仓抽 `GetCoreObject` 重试样板 | 19 个资源里 18 个是 `[qb]` 上游（报告 §3.2 #7）；`[custom]` 只有 custom-security 1 处，抽出来是「为 2 个调用点造一个抽象」 |
| 抽通用 `Cache` | 各资源的 TTL/失效键/一致性要求不同（quest/phone/vehicles），没有证据存在统一契约；强行合并会把「缓存脏读」变成全局问题 |
| 合并进度条 option 表 | 那是调用参数，不是实现；改参数会改 UX |
| 复活 `custom-economy` 的 server | 它被 `core_economy` 取代是正确方向（`T-CityLite.base/resources/[custom]/custom-economy/fxmanifest.lua:15-17` 明写 removed）；正确做法是迁调用点，不是把死网关救活 |
| 把 `players.money` 的写路径迁到 core-framework | 宪法②/`test_economy_single_owner.py` 已定 owner 是 qb-core；core-framework 只能做便利层，不能做第二写者 |
| 为跨资源服务调用新增 net event | 会绕开 exports 契约与 `test_net_event_auth` 的登记；服务调用是同步导出，不是事件 |
| 把 `Bus` 做成真正的 `_G` 全局总线 | 跨资源 `_G` 不共享；唯一可行的是 exports/events，做「全局总线」只会再造一个 0 采纳层 |
| 合并 qb-drugs 的 `Money()` | `[qb]` 上游，REUSE.md 不迁 |

### 1.3 本计划未纳入的报告条目（不是遗漏，是明确留到下一轮）

| 条目 | 报告位置 | 为什么不在本计划 | 什么时候再做 |
|---|---|---|---|
| 信号 B：`rawget(_G,'Config')` | §5.1 B | 先要真机打印确认本 build 是否真取不到（报告 §8.3 #2）；在确认前改就是猜 | 探针完成后的独立 0.5 天 PR |
| `metadata` 服务降级/删除 | §2.3 R5 | 需要产品决定「只读还是删除」；报告 §6 的 3+4 件事没排它 | 服务面裁剪轮 |
| 13 个 0 外部调用服务的 `service_*` 面裁剪 | §2.3、§2.7 | 同上；S1 只登记、S2 只删 5 个占位，不裁剪有消费者的面 | 服务面裁剪轮 |
| `custom-vehicles` 重复静态导出 `GiveKeys`/`HasKeys` 的覆盖关系 | §5.1 D | 不是 Bus 问题；需要「同名导出 + 覆盖顺序 + 签名」的新登记表 | 单独的导出覆盖登记 PR |
| `Db` 批 4（`custom-quest`/`story-engine` 回调风格） | §4.2 | 它们没有 `insertId/affectedRows` 归一化形状；把 `MySQL.Async.*` 迁到 `await` 会改异步语义 | S4 之后的独立重构 |
| `Broadcast` 批 2–4 的行为收口（vehicles/main/objects/phone） | §4.6 | S7 只改证据；其余 19 处先登记 `all`，行为变更需要产品/玩法判断 | 证据收口后的下一轮 |
| 热狗两个客户端文件 | §4.3 | 是另一条任务的工作集；且它们的循环已有 deadline/generation 退出条件 | 热狗任务自己收 |
| `qb-drugs` 的 `Money()` | §4.4 | `[qb]` 上游不迁 | 永不（REUSE.md 定案） |
| `Cache` / `Notify` / `Permission` 门面 | §4 末尾 | 报告已判定「不统一/不合并」 | 不排 |

---

## 2. 验收标准（可执行）

### 2.1 命令模板

本机 shell 是 PowerShell；以下命令可直接复制。`&&` 在 PowerShell 里不可用，所以用两行。

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit tests/architecture tests/agent -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/integration -q
```

> **`tests/integration` 必须跑**（2026-11-15 补）：CI 只跑 `tests/unit / tests/architecture /
> tests/agent`，`tests/integration` 不在 CI 里，所以它红着也能合并。S2a 删掉 5 个占位服务后，
> `TestContractsIntegration` 的 5 条旧断言红了一整片而 CI 全绿——测试说谎比红灯更糟。
> 凡是删除/改签名/改注册行为的片（S2a、S2b、S3、S5、S6），`tests/integration` 与 `tests/agent`
> 都要进本片的验收命令。

单文件/单闸门：

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/architecture/test_service_contracts.py -q
```

Lua 语法检查（每个改过的 `.lua` 都要过）：

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
luac5.4 -p "resources/[custom]/custom-police/server/evidence.lua"
```

工具类：

```powershell
Set-Location E:/T-City-abs
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' tools/dev/release_check.py
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' tools/dev/budget_probe.py --check
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' tools/dev/gate_coverage.py --json
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' tools/dev/gate_mutation_smoke.py
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' tools/dev/reuse_scan.py --min 3
```

本计划**不碰前端**：S6 改的是 `T-CityLite.base/resources/[custom]/custom-phone/client/main.lua`（Lua），不是 `web/src/**`；
因此不需要 `node tests/nui/run.mjs` / `npm run build`。若实施时误改了 NUI，按
`docs/engineering/LIVE_VERIFICATION.md` 补前端构建。

### 2.2 全局验收表

| # | 标准 | 怎么验证 |
|---|---|---|
| 1 | 全量离线测试绿 | §2.1 第一条命令 exit 0 |
| 2 | 6 条新前向闸门绿 | `pytest tests/architecture/test_service_contracts.py tests/architecture/test_bus_scope.py tests/architecture/test_db_result_adapter.py tests/architecture/test_load_model_single_owner.py tests/architecture/test_money_format_single_owner.py tests/architecture/test_broadcast_scope.py -q` exit 0 |
| 3 | 新闸门真的会红 | `tools/dev/gate_mutation_smoke.py` 的 7 条新用例都显示「会红 ✓」 |
| 4 | 覆盖率预算不涨 | `gate_coverage.py --json` 的 `unproven ≤ 278`；`pytest tests/architecture/test_gate_coverage.py -q` exit 0 |
| 5 | 交付三件套 | `release_check.py` exit 0（无凭据、无过期条目） |
| 6 | IO 预算不涨 | `budget_probe.py --check` exit 0；`broadcast_sites ≤ 144`、`db_call_sites ≤ 465` |
| 7 | 净事件不变 | `pytest tests/architecture/test_net_event_inventory.py -q` exit 0；本计划 0 个新 net event |
| 8 | 文档零断链 | `pytest tests/architecture/test_docs_links.py -q` exit 0（本文件里的反引号路径必须都存在） |
| 9 | 真机清单完成 | §4 各片「真机验证清单」的 ⛔ 行都有日志/DB/截图证据；未完成的登记 owner + expires |

---

## 3. 分片总表与拆分理由

| 片 | 主题 | 文件数 | 前置 | 可并行 | 为什么是这个粒度 |
|---|---|---|---|---|---|
| S1 | 导出契约闸门 + 11 个死调用 | 14 | — | 其余所有片的前置 | 3 个新增（登记表/测试/生成器）+ 8 个调用资源 + 3 个交付件。11 个死调用 + 1 个 pcall 兜底分属 6 个 owner，按 owner 拆会得到多个红着闸门的 PR |
| S2a | Bus：场景/作业/车辆 + 闸门 | 12 | S1 | 与 S2b 开发可并行 | 6 个调用文件 + 2 个 qb-vehicleshop 文件 + 闸门/登记/交付 |
| S2b | Bus：税/热度/通知 + owner 导出 | 13 | S1、S2a 的闸门（合并顺序 S2a→S2b） | 与 S3–S7 开发可并行 | 2 个 qb-core owner 导出 + 8 个调用文件 + 闸门扫描根扩展；5 类读取各是一个失败面，拆开每次都要临时 allowlist |
| S3 | 限流收口 | 12 | S2a（同一文件 `p2_system.lua`） | 与 S4–S7 开发可并行 | 7 个 custom-police 文件 + 1 个 director + owner 自清理 + 测试/交付 |
| S4 | `Db` 结果适配器 | 19 | S3（同一文件 `p0_incidents.lua`） | 与 S5/S6 开发可并行 | 适配器 + 6 个归一化点必须同 PR：新闸门要求归一化只在 `db.lua`，拆开中间态必红；2 个 Lua harness 必须同 PR 才能保持绿 |
| S5 | `LoadModel` 采纳 | 12 | S2b（同一个 `REUSE.md`） | 与 S3/S4/S6 开发可并行 | 8 个客户端文件 + 新闸门 + 交付 |
| S6 | `FormatMoney` 合并 | 17 | S1 | 与 S2–S5/S7 开发可并行 | 8 份逐行相同的门面会被 Sonar 算成新代码重复（9.9%）；改为一个 `money_aliases.lua` + 8 个 manifest include；`test_money_renderers.py` 必须同 PR 改加载方式 |
| S7 | 证据广播收口 | 11 | S4（同一个 `T-CityLite.base/resources/[standalone]/core-framework/fxmanifest.lua`） | 与 S5/S6 开发可并行 | 1 个业务文件 9 处 + helper + allowlist + 预算/交付 + 1 个静态测试断言更新 |

> **S2 为什么拆成两片**：原样执行是 20+ 文件、2–3 天（报告 §5.3 自己的估算），违反
> 「一片一个 PR、≤1 天」。S2a 与 S2b 的失败面不同（场景/作业/车辆 vs 钱/税/通知），
> 回滚粒度也不同；拆开后 S2a/S2b 各 ≤13 文件、可独立合并。总片数从 7 变 8，
> 这是满足「≤12 文件、≤1 天」的最小拆法，没有新增主题。

---

## 4. 逐片执行卡

> 每张卡固定七件事：影响文件 / 先红后绿 / 验收命令 / 登记表与预算 / 闸门覆盖率记账 /
> CHANGELOG + 文档 / 回滚；另加真机清单。

### 4.1 S1 — 方法级导出契约闸门 + 修 11 个真实死调用 + 1 个兜底

**验收口径**：新闸门在真实仓库上绿、反向注入红；11 个真实死调用 + 1 个 pcall 兜底
全部换成真实 owner；
`luac5.4 -p` 全过；四组导出（`custom-main:AddScaledMoney`、`custom-main:CheckRateLimit`、
`custom-economy:GetEconomyRewardScale`、`custom-economy:AddScaledMoney`、`qb-inventory:SetItemInfo`）
在**代码**里为 0（注释/测试字符串不算）。

#### 4.1.1 影响文件

| 动作 | 路径 |
|---|---|
| 新增 | **T-CityLite.base/tests/architecture/service_contracts.json** |
| 新增 | **T-CityLite.base/tests/architecture/test_service_contracts.py** |
| 新增 | **tools/dev/service_contracts_scan.py** |
| 修改 | `tools/dev/gate_mutation_smoke.py` |
| 修改 | `T-CityLite.base/resources/[qb]/qb-pawnshop/server/main.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-crime/server/crime.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-testing/stress_test.lua` |
| 修改 | `T-CityLite.base/resources/[qb]/qb-storerobbery/server/main.lua` |
| 修改 | `T-CityLite.base/resources/[system]/economy-dashboard/server/main.lua` |
| 修改 | `T-CityLite.base/resources/[qb]/qb-drugs/server/cornerselling.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-taxes/server/item_durability.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-phone/client/main.lua` |
| 修改 | `CHANGELOG.md` |
| 修改 | `docs/engineering/ARCHITECTURE.md` |

删除：无。
14 文件。**为什么不能再切**：3 个新增是「登记表 + 闸门 + 生成器」，缺一不可；
8 个代码文件覆盖 11 个真实调用点 + 1 个 pcall 兜底、分属 6 个 owner，按 owner 拆会得到
多个闸门红的 PR；`CHANGELOG`/`ARCHITECTURE` 是宪法⑩要求的交付件。

#### 4.1.2 先红后绿

**红（第一步：只加闸门，不修调用）**：`test_every_export_call_resolves` 必须列出这 12 行：

| # | 位置 | 现状 | 红的原因 |
|---|---|---|---|
| 1 | `T-CityLite.base/resources/[qb]/qb-pawnshop/server/main.lua:74` | `exports['custom-main']:CheckRateLimit(...)` | `custom-main` 只导出 `LogEconomy/LogSecurity/LogGeneric`，没有 `CheckRateLimit` |
| 2 | `T-CityLite.base/resources/[qb]/qb-pawnshop/server/main.lua:98` | `exports['custom-main']:AddScaledMoney(...)` | 同上；且发生在 `RemoveItem` 成功之后 → 物品已扣、钱没到 |
| 3 | `T-CityLite.base/resources/[custom]/custom-crime/server/crime.lua:287` | `exports['custom-main']:AddScaledMoney(...)` | 同上；`exports['custom-main']` 是资源代理（truthy），所以 `if ... and exports[...]` 守卫**挡不住** |
| 4 | `T-CityLite.base/resources/[custom]/custom-crime/server/crime.lua:419` | 同上 | 同上 |
| 5 | `T-CityLite.base/resources/[custom]/custom-testing/stress_test.lua:76` | `exports['custom-main']:AddScaledMoney(...)` | 同上；`pcall` 吞掉错误，压力测试静默不发钱 |
| 6 | `T-CityLite.base/resources/[qb]/qb-storerobbery/server/main.lua:446` | `exports['custom-economy']:GetEconomyRewardScale()` | `custom-economy` 只剩 config，没有 server 脚本 |
| 7 | `T-CityLite.base/resources/[qb]/qb-storerobbery/server/main.lua:674` | 同上 | 同上 |
| 8 | `T-CityLite.base/resources/[system]/economy-dashboard/server/main.lua:271` | 同上 | `if exports['custom-economy'] then` 是 truthy，必进 → `/econ` 崩 |
| 9 | `T-CityLite.base/resources/[qb]/qb-drugs/server/cornerselling.lua:79` | `exports['custom-economy']:AddScaledMoney(...)` | 同上；守卫用 `.AddScaledMoney` 但资源代理永远 truthy |
| 10 | `T-CityLite.base/resources/[custom]/custom-taxes/server/item_durability.lua:120` | `exports['qb-inventory']:SetItemInfo(...)` | qb-inventory 只导出 `SetItemData`（`T-CityLite.base/resources/[qb]/qb-inventory/server/functions.lua:217`） |
| 11 | `T-CityLite.base/resources/[custom]/custom-taxes/server/item_durability.lua:160` | 同上 | 同上 |
| 12 | `T-CityLite.base/resources/[custom]/custom-phone/client/main.lua:1016` | `exports['custom-career']:GetLocalIdentity()` | custom-career 只导出 `GetPlayerIdentity`（`T-CityLite.base/resources/[custom]/custom-career/client/main.lua:6`）；`pcall` 吞掉错误，Leader app 永远不注册 |

**非调用引用（不改代码）**：
- `T-CityLite.base/resources/[custom]/custom-testing/suites/04_security_test.lua:65` 是注释里的 `exports['custom-main']:CheckStoreRobbery`；
- `T-CityLite.base/resources/[custom]/custom-testing/suites/07_economy_admin_test.lua:12` 是断言字符串 `exports['custom-economy']:AddScaledMoney()`。
两者都不在「真实调用」里；闸门剥注释/字符串后不报。报告把它们算进 13，本计划按 11 个真实调用 + 1 个兜底施工。
- 报告说「另有 2 处兜底/上游」：`custom-career:GetLocalIdentity` 是真实死调用（上表第 12 行，本片修）；
  `qb-fuel:GetFuel` 由 `T-CityLite.base/resources/[qb]/qb-fuel/client/exports.lua:1-6` 的
  `newExports('GetFuel', ...)` 注册，是**误报**，不修。

**首次跑闸门会输出不止 12 条**：报告 §5.1 E 的 43 条里，约 28 条是
qb-core 动态导出、注释、外部资源（`LegacyFuel`/`money`/`qb-vehiclekeys`/`safecracker` 等）。
它们不是 bug，按 `dynamic_exports`/`external_exports` 登记；PR 必须贴一张
「12 个真实修复 + 其余误报」的完整分类表，**不能只修 12 条就宣布绿**。
如果某个资源在树内、又不在 dynamic/external 表里，闸门会让它红——这正是我们要的。

**绿（第二步：修调用）**：

| 位置 | 改成 | 语义说明 |
|---|---|---|
| qb-pawnshop:74 | `exports['custom-security']:CheckRateLimit(src, "sell_pawn_item", 1500)` | `custom-security` 的 `CheckRateLimit` 是真实导出（`T-CityLite.base/resources/[custom]/custom-security/server/security.lua:33`），内部已走 `core-framework:RateLimitCooldown`；S3 不会破坏它 |
| qb-pawnshop:98 | `Player.Functions.AddMoney(account, totalPrice, reason)`；返回 false 时把物品加回去并通知 | 卖物品不是「活动奖励」，不走倍率/热度；失败要回滚物品，避免「物品已扣、钱没到」 |
| custom-crime:287/419 | 删掉 `exports['custom-main']` 分支，保留 `Player.Functions.AddMoney('bank', cleanAmount, reason)` | 洗钱入账是原语写路径，不需要倍率；现有 fallback 就是正确写法 |
| stress_test:76 | `Player.Functions.AddMoney`（真实玩家）；拿不到玩家就跳过 | 压力测试只测吞吐；不引入倍率/热度 |
| qb-storerobbery:446/674 | `pcall` 调 `exports['core_economy']:GetGlobalMultiplier()`，失败回落 `1.0` | `core_economy` 的 `GetGlobalMultiplier` 是真实导出（`T-CityLite.base/resources/[system]/core_economy/server/main.lua:263`）；回落保证奖励路径不再崩 |
| economy-dashboard:271 | `if GetResourceState('core_economy') == 'started' then globalMult = exports['core_economy']:GetGlobalMultiplier() end` | 用资源状态而不是代理 truthiness |
| qb-drugs:79 | 删掉 `custom-economy` 分支；`Player.Functions.AddMoney('cash', amount, reason)` | 同上 |
| custom-taxes:120/160 | `exports['qb-inventory']:SetItemData(source, itemName, 'info', newInfo, slot)` | `SetItemData` 的签名是 `(source, itemName, key, val, slot)`（`T-CityLite.base/resources/[qb]/qb-inventory/server/functions.lua:199-217`）；`key='info'` 等价于旧的整块 `info` 写入 |
| custom-phone:1016 | `exports['custom-career']:GetPlayerIdentity()` | client/main.lua:6 已导出；返回 `LocalPlayer.state.career_identity`（含 `rank_tier`/`primary_role`），与 `CheckLeaderApp` 的读取字段一致 |

**闸门设计**（写在 `test_service_contracts.py`，只写两个 `test_` 函数）：
1. `test_every_export_call_resolves`（前向）：
   - 从代码推导「已声明导出」：所有字面量 `exports('Name', ...)` + 所有
     `Bus.RegisterService('<service>', { Method = ... })` 块 + `dynamic_exports` + `external_exports`；
   - 扫所有 `*.lua` 里的字面量 `exports['<res>']:<Method>(` 调用（剥注释/字符串）；
   - 未解析的 `(res, method)` → 红；每个 `service_*` 声明必须在 `service_contracts.json` 有且仅有一条；
   - `qb-core`/`qb-fuel` 等动态导出登记在 `dynamic_exports`，不按方法名逐个列。
   - **已知盲区**：`qb-core` 是整体放行（`QBCore.Functions` 循环导出），所以本闸门
     不能证明 qb-core 静态导出的方法名；S2b 新增的 `SinkWithdraw`/`HeatReset`
     另用控制台探针验证一次（见 §4.3.3）。
2. `test_reverse_unresolved_export_is_rejected`（反向）：
   - 合成 `exports['custom-main']:AddScaledMoney(...)` → 必须报；
   - 合成注释/字符串里的同名调用 → 必须**不**报；
   - 合成 `exports['custom-storage']:service_storage_NoSuchMethod(...)` → 必须报。

**登记表内容**：`service_contracts.json` 分四段：
- `services`：有真实外部调用点的服务（storage/economy/job/security/market/cartel/atmosphere/world_trace/notify），
  每个方法写 `args/returns/failure`；`service_contracts_scan.py --update` 从代码生成 174 条初始记录，
  人工复核 33 个外部调用点对应的 9 个服务；
- `planned_services`：5 个占位（reputation/chronicle/governance/cosmetics/funnel），S1 只登记，S2a 删除；
- `dynamic_exports`：`qb-core`（`server/functions.lua:812-816` 的 `QBCore.Functions` 循环）、
  `qb-fuel`（`client/exports.lua:1-6` 的 `newExports`）、`custom-vehicles`
  （`vehicle_state.lua:414-428` 的 `pairs({...})` 表；生成器解析表里的 9 个方法名，
  **不按整个资源放行**）；
- `external_exports`：`LegacyFuel`、`money`、`qb-vehiclekeys`、`safecracker`、`qb-jobs`、
  `qb-interior`、`oxmysql` 等不在树内/上游的资源。
- `plugin_contract`：`{ status: 'planned', reason: '全仓 0 个 Bus.Plugin.Register 调用' }`；
  S2a 保留 `Bus.Plugin` 实现，但不再出现在对外文档。

#### 4.1.3 验收命令

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/architecture/test_service_contracts.py -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit tests/architecture -q
luac5.4 -p "resources/[qb]/qb-pawnshop/server/main.lua"
luac5.4 -p "resources/[custom]/custom-crime/server/crime.lua"
luac5.4 -p "resources/[custom]/custom-testing/stress_test.lua"
luac5.4 -p "resources/[qb]/qb-storerobbery/server/main.lua"
luac5.4 -p "resources/[system]/economy-dashboard/server/main.lua"
luac5.4 -p "resources/[qb]/qb-drugs/server/cornerselling.lua"
luac5.4 -p "resources/[custom]/custom-taxes/server/item_durability.lua"
luac5.4 -p "resources/[custom]/custom-phone/client/main.lua"
```

> 登记表需要重生成时，手动跑一次 `service_contracts_scan.py --update` 并 review diff 后提交；
> **验收命令不跑 `--update`**，否则闸门会变成「自动改写自己」的假绿。

真实调用清零（`rg` 未安装时用 `Select-String`；CI 以新闸门为准）：

```powershell
Set-Location E:/T-City-abs
rg -n "exports\['(custom-main|custom-economy)'\]:(AddScaledMoney|CheckRateLimit|GetEconomyRewardScale)|exports\['qb-inventory'\]:SetItemInfo|exports\['custom-career'\]:GetLocalIdentity" T-CityLite.base/resources --glob '*.lua' --glob '!**/tests/**' --glob '!**/custom-testing/**'
# 期望：无输出（注释/字符串/压力测试资源不在口径内）
```

#### 4.1.4 登记表/预算同步

| 文件 | 改动方向 | 说明 |
|---|---|---|
| **service_contracts.json** | 新增 | 初始 174 条 `service_*` + 33 个外部调用契约；S1 之后由生成器保持 |
| `reuse_budget.json` | 不改 | 本片没有同名实现数量变化 |
| `io_budget.json` | 不改 | 没有新增轮询/广播/DB 调用点 |
| `money_format_baseline.json` | 不改 | S6 才动 |
| `gate_coverage_budget.json` | 不改 | 本片 +0（选了 §4.1.5 的方案 a） |
| `net_events_allowlist.json` | 不改 | 0 个新 net event |

#### 4.1.5 闸门覆盖率记账

- 新增 **1 条前向规则**（`test_every_export_call_resolves`）+ 1 条自带反向校验。
- 选 **(a)**：在 `tools/dev/gate_mutation_smoke.py` 加 1 条变异用例：
  - gate：`tests/architecture/test_service_contracts.py::test_every_export_call_resolves`
  - 注入：**resources/[custom]/custom-vehicles/server/__mutant_export_call.lua**
  - 内容：`exports['custom-main']:AddScaledMoney(1, 'cash', 1, 'probe')`
  - 期望：注入后红、撤回后绿。
- 因此 `max_unproven` 增量 **+0**；`gate_coverage_budget.json` 不动。
- 若实施时决定不加变异用例，则本片 **+1（279）**，必须在 `history` 写
  `date=2026-11-15 / previous=278 / why="新增方法级导出契约前向规则" / 到期条件="补变异用例或反向校验后降回 278"`。
  **不允许**只加反向用例就宣称不增——`gate_coverage.py` 的 proven 是逐条 nodeid 算的。

#### 4.1.6 CHANGELOG + 文档

- `CHANGELOG.md` → `### Fixed` 一条：
  「方法级导出契约闸门 + 修 11 处死调用 + 1 处兜底：卖物品不再丢物品、抢劫奖励不再报
  `No such export`、武器耐久恢复更新。」
- `docs/engineering/ARCHITECTURE.md` §3「唯一通道速查」加一行：
  | 跨资源服务调用 | `exports['<owner>']:service_<name>_<method>`，方法必须登记在 `service_contracts.json` | `Bus.<service>.<method>`（跨资源恒 nil） |
- `docs/engineering/REUSE.md`：本片不动（S2b 统一加 Bus 规则）。
- `T-CityLite.base/resources/[custom]/AGENTS.md`：本片不动（S4 改 DB helper 行）。

#### 4.1.7 回滚

- `git revert <sha>` 足够；本片无数据/迁移。
- 建议拆两个 commit：① 闸门 + 登记表（可独立 revert，不影响运行时）；② 12 个调用修复。
  若只 revert ②，闸门会红在第 1–12 行——这是预期，不是回滚失败。
- 需要重启/`refresh` 的资源：`qb-pawnshop`、`qb-storerobbery`、`custom-crime`、
  `custom-taxes`、`qb-drugs`、`economy-dashboard`、`custom-testing`（如启用）。
  无新增文件，不需要 `refresh`；`restart` 即可。

#### 4.1.8 真机验证清单

| 触发步骤 | 期望现象 | 判定方式 | 标记 |
|---|---|---|---|
| 在当铺卖一件物品 | 物品扣除、现金/银行增加 `totalPrice`、通知显示金额；服务端无 `No such export` | 服务端日志 + `tools/dev/db_query.py` 前后 money 对比 + 截图 | ⛔ 钱到账只能真机 |
| 抢一次商店并拿钱 | 奖励按 `GetGlobalMultiplier` 倍率发放；无 `No such export 'GetEconomyRewardScale'` | 服务端日志 + 背包 `markedbills` 的 `worth` | ⛔ |
| 用武器直到耐久下降 | 物品 `info.durability` 更新；无 `No such export 'SetItemInfo'` | 服务端日志 + 背包物品信息 | ⛔ |
| qb-drugs 街角卖货 | 现金增加 `serverPrice`；无 `No such export` | 服务端日志 + 钱变化 | ⛔ |
| 执行 `/econ` | 仪表盘显示全局倍率；无报错 | 服务端日志/命令回显 | ✅ 日志可判 |
| 执行 `/stress`（仅在测试资源启用时） | 不再出现 `custom-main:AddScaledMoney` 错误 | 服务端日志 | ✅ 日志可判 |
| 打开手机 Leader app（`CheckLeaderApp`） | `GetPlayerIdentity` 返回 `career_identity`；leader 显示/隐藏正确；无 pcall 静默失败 | 手机 UI 截图 + F8 | ⛔ 客户端导出只能真机 |

---

### 4.2 S2a — 退役跨资源 Bus（场景/作业/车辆）+ Bus 闸门

**验收口径**：`custom-police`、`qb-ambulancejob`、`qb-storerobbery`、`qb-vehicleshop`
的服务端不再出现 `Bus.<service>` / `_G.Bus.<service>` 读取；所有 `Bus.RegisterService`
的资源都在 manifest 里加载了 Bus；`qb-vehicleshop` 的 8 个 `service_dealership_*` 真实可调用。

#### 4.2.1 影响文件

| 动作 | 路径 |
|---|---|
| 新增 | **T-CityLite.base/tests/architecture/test_bus_scope.py** |
| 修改 | `tools/dev/gate_mutation_smoke.py` |
| 修改 | `T-CityLite.base/resources/[standalone]/core-framework/contracts.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/vehicle.lua` |
| 修改 | `T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua` |
| 修改 | `T-CityLite.base/resources/[qb]/qb-storerobbery/server/main.lua` |
| 修改 | `T-CityLite.base/resources/[qb]/qb-vehicleshop/server/bus.lua` |
| 修改 | `T-CityLite.base/resources/[qb]/qb-vehicleshop/server/integration.lua` |
| 修改 | **T-CityLite.base/tests/architecture/service_contracts.json** |
| 修改 | `CHANGELOG.md` |
| 修改 | `docs/engineering/ARCHITECTURE.md` |

删除：无。
12 文件。

#### 4.2.2 先红后绿

**红**：`test_no_cross_resource_bus_reads` 在 4 个扫描根上必须列出：

| 位置 | 现状 | 红的原因 |
|---|---|---|
| `T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua:1904-1905` | `Bus.JobService.SetJob(...)` | `Bus.JobService` 在 custom-police 的 Lua state 里恒 nil |
| `T-CityLite.base/resources/[custom]/custom-police/server/vehicle.lua:95` | `Bus.SafeCall('atmosphere','PlayScene',...)` | 同上；追车 BGM 不放 |
| `T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:120,284` | `Bus.SafeCall('atmosphere','PlayScene',...)` | 同上；重生/死亡场景不放 |
| `T-CityLite.base/resources/[qb]/qb-storerobbery/server/main.lua:552` | 同上 | 同上；抢劫追逐场景不放 |
| `T-CityLite.base/resources/[qb]/qb-vehicleshop/server/integration.lua:65-66` | `Bus.vehicles.GetState(plate)` | qb-vehicleshop 的服务端没有加载 Bus |
| `T-CityLite.base/resources/[qb]/qb-vehicleshop/server/bus.lua:330-338` | `Bus.RegisterService('dealership', ...)` | 资源 manifest 没有 **@core-framework/bus.lua**，注册永远不执行；fxmanifest 第 50-58 行列的 8 个导出是文档，不是实现 |

**绿**：

| 位置 | 改成 |
|---|---|
| `p2_system.lua:1904-1908` | 删掉 `Bus.JobService` 分支，直接用 `player.Functions.SetJob(job, grade)`（现有 fallback，qb-core 是 job 的 owner） |
| `T-CityLite.base/resources/[custom]/custom-police/server/vehicle.lua:95` | `pcall(function() exports['tcity-atmosphere']:service_atmosphere_PlayScene(source, 'chase') end)` |
| `T-CityLite.base/resources/[qb]/qb-ambulancejob/server/main.lua:120,284` | 同上，scene 分别为 `'default'`、`'respawn'` |
| `T-CityLite.base/resources/[qb]/qb-storerobbery/server/main.lua:552` | 同上，scene `'chase'` |
| `T-CityLite.base/resources/[qb]/qb-vehicleshop/server/integration.lua:61-75` | 删掉 `Bus.vehicles` 分支；`GetResourceState('custom-vehicles') == 'started'` 时直接 `exports['custom-vehicles']:GetVehicleState(plate)` |
| `T-CityLite.base/resources/[qb]/qb-vehicleshop/server/bus.lua:330-338` | 把 `Bus.RegisterService('dealership', {...})` 改成 6 条 `exports('service_dealership_<Method>', ...)` |
| `T-CityLite.base/resources/[qb]/qb-vehicleshop/server/integration.lua:81-101` | 删掉 `if Bus and Bus._services...` 外壳，直接 `exports('service_dealership_EstimateUsedPrice', ...)` / `exports('service_dealership_GetVehicleState', ...)`；8 个导出全部真实注册 |
| `T-CityLite.base/resources/[standalone]/core-framework/contracts.lua:36-216` | 删除 `reputation`/`chronicle`/`governance`/`cosmetics`/`funnel` 五个 `Bus.RegisterService` 块；文件头注释改成「planned 服务不注册」；`Bus.Plugin` 保持现状但在 `service_contracts.json` 标 `planned` |

**闸门设计**（`test_bus_scope.py`，只写两个 `test_` 函数）：
1. `test_no_cross_resource_bus_reads`（前向）：
   - `SCAN_ROOTS` 先包含：`T-CityLite.base/resources/[custom]/custom-police/server`、`T-CityLite.base/resources/[qb]/qb-ambulancejob/server`、
     `T-CityLite.base/resources/[qb]/qb-storerobbery/server`、`T-CityLite.base/resources/[qb]/qb-vehicleshop/server`；
   - 命中 `Bus.<service>.<method>` / `_G.Bus.<service>` 即红；
   - 允许：`Bus.RegisterService(...)`、`Bus.Plugin.*`、owner 自己进程内的 `Bus.<own service>`
     （owner 文件不在扫描根内，例如 `T-CityLite.base/resources/[custom]/custom-vehicles/server/**`）；
   - 额外检查：每个 `Bus.RegisterService` 调用所在资源的 `fxmanifest.lua` 必须有
     **@core-framework/bus.lua** 或 `'bus.lua'`；`qb-vehicleshop` 转换后不再有注册，天然通过。
2. `test_reverse_cross_resource_bus_read_is_rejected`（反向）：
   - 合成 `Bus.storage.CanAccess(src, 'org')` → 必须报；
   - 合成 `Bus.RegisterService('probe', {...})` 但 manifest 没有 Bus → 必须报；
   - 合成 owner 进程内的 `Bus.vehicles.GetState`（在自定义 owner 根）→ 必须不报。

**登记表更新**：`service_contracts.json` 删除 5 个 `planned_services`；`dealership` 条目
保留（来源从 Bus 注册变成 8 条静态 `service_dealership_*`）。生成器重跑后 diff 应只显示这两处。

#### 4.2.3 验收命令

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/architecture/test_bus_scope.py -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit tests/architecture -q
luac5.4 -p "resources/[standalone]/core-framework/contracts.lua"
luac5.4 -p "resources/[custom]/custom-police/server/p2_system.lua"
luac5.4 -p "resources/[custom]/custom-police/server/vehicle.lua"
luac5.4 -p "resources/[qb]/qb-ambulancejob/server/main.lua"
luac5.4 -p "resources/[qb]/qb-storerobbery/server/main.lua"
luac5.4 -p "resources/[qb]/qb-vehicleshop/server/bus.lua"
luac5.4 -p "resources/[qb]/qb-vehicleshop/server/integration.lua"
```

#### 4.2.4 登记表/预算同步

| 文件 | 改动方向 | 说明 |
|---|---|---|
| **service_contracts.json** | 收紧 | 删 5 个 planned；`dealership` 改为静态导出来源 |
| `gate_coverage_budget.json` | 不改 | +0（见 §4.2.5） |
| `io_budget.json` | 不改 | 本片不动广播/轮询/DB |
| `net_events_allowlist.json` | 不改 | 0 个新 net event |
| `reuse_budget.json` / `money_format_baseline.json` | 不改 | 与本片无关 |

#### 4.2.5 闸门覆盖率记账

- 新增 **1 条前向规则**（`test_no_cross_resource_bus_reads`）+ 1 条反向。
- 选 **(a)**：变异用例注入 **resources/[custom]/custom-vehicles/server/__mutant_bus.lua**，
  内容 `Bus.storage.CanAccess(1, 'org')`；gate 指向 `test_no_cross_resource_bus_reads`。
- 增量 **+0**。若不加变异，则 +1（279），`history` 写
  `date=2026-11-15 / previous=278 / why="新增跨资源 Bus 读取前向规则" / 到期条件="补变异用例后降回 278"`。

#### 4.2.6 CHANGELOG + 文档

- `CHANGELOG.md` → `### Changed`：
  「退役跨资源 Bus（场景/作业/车辆）：3 处 BGM 死调用改为
  `exports['tcity-atmosphere']:service_atmosphere_PlayScene`；`qb-vehicleshop` 的
  8 个 `service_dealership_*` 真正注册。」
- `docs/engineering/ARCHITECTURE.md` §3 加一行：
  | 跨资源服务调用 | `exports['<owner>']:service_<name>_<method>` | `Bus.<service>`（跨资源恒 nil） |
  并在 §4 加一句：「`Bus` 只是 owner 侧注册辅助；`Bus.Plugin` 标 planned，不再出现在对外文档。」
- `docs/engineering/REUSE.md`：本片不动（S2b 统一加）。
- `T-CityLite.base/resources/[custom]/AGENTS.md`：本片不动。

#### 4.2.7 回滚

- `git revert <sha>` 足够；无数据/迁移。
- 按文件回滚也安全：BGM 调用与车辆导出互不依赖；回滚 `qb-vehicleshop` 两个文件会恢复
  「文档有 8 个导出、实际一个都没有」的状态，但不会影响其它资源。
- 需要 `restart` 的：`core-framework`（contracts 改动）、`custom-police`、
  `qb-ambulancejob`、`qb-storerobbery`、`qb-vehicleshop`。无新增文件。

#### 4.2.8 真机验证清单

| 触发步骤 | 期望现象 | 判定方式 | 标记 |
|---|---|---|---|
| 警察端触发 `police:server:FlaggedPlateTriggered` | 追车 BGM 播放（`PlayScene(..., 'chase')`） | 客户端 F8/音频 + 服务端 atmosphere 日志 | ⛔ BGM 只能真机听 |
| 玩家死亡后在医院重生 | `default`/`respawn` 场景播放 | 客户端音频 + 日志 | ⛔ |
| 开始一次商店抢劫 | `chase` 场景播放 | 客户端音频 + 日志 | ⛔ |
| 二手车估值界面打开 | `GetVehicleStateSafe` 返回车辆状态，估值不报错 | 服务端日志 + UI 截图 | ⛔ |
| 控制台探针 `exports['qb-vehicleshop']:service_dealership_GetShopConfig('...')` | 返回配置表，不是 `No such export` | 控制台输出 | ✅ 控制台可判 |
| 控制台 `exports['core-framework']:BusStatus()` | 服务列表不再含 reputation/chronicle/governance/cosmetics/funnel | 控制台输出 | ✅ 控制台可判 |

---

### 4.3 S2b — 退役跨资源 Bus（税/热度/通知）+ owner 导出

**验收口径**：`custom-taxes`、`qb-shops`、`production-freeze`、`custom-phone`、
`T-CityLite.base/resources/[qb]/qb-core/server/functions.lua` 的 5 类 `_G.Bus` 读取全部消失；税走
`exports['qb-core']:SinkWithdraw`，热度走 `exports['qb-core']:HeatReset`，通知走原生事件；
真机大额转账税进 sink。

#### 4.3.1 影响文件

| 动作 | 路径 |
|---|---|
| 修改 | `T-CityLite.base/resources/[qb]/qb-core/server/services/sink_service.lua` |
| 修改 | `T-CityLite.base/resources/[qb]/qb-core/server/services/heat_service.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-taxes/server/transaction_monitor.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-taxes/server/property_tax.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-taxes/server/main.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-taxes/server/item_durability.lua` |
| 修改 | `T-CityLite.base/resources/[qb]/qb-shops/server/main.lua` |
| 修改 | `T-CityLite.base/resources/[system]/production-freeze/server/main.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-phone/server/banking.lua` |
| 修改 | `T-CityLite.base/resources/[qb]/qb-core/server/functions.lua` |
| 修改 | **T-CityLite.base/tests/architecture/test_bus_scope.py**（只加 `SCAN_ROOTS`/`OWNER_FILES` 条目） |
| 修改 | `CHANGELOG.md` |
| 修改 | `docs/engineering/REUSE.md` |

删除：无。
13 文件。**为什么不能再切**：5 类读取（Sink/Heat/NPCPricing/notify/EconomyService）各是一个
失败面，但它们共享同一个闸门扫描根；拆开会让 S2a 的闸门在中间态红，或需要临时 allowlist。
`test_bus_scope.py` 只加 5 行扫描根，不是新逻辑。

#### 4.3.2 先红后绿

**红**：在 S2a 的闸门基础上把 `SCAN_ROOTS` 扩到本片文件，`test_no_cross_resource_bus_reads` 必须列出：

| 位置 | 现状 | 失败面 |
|---|---|---|
| `T-CityLite.base/resources/[custom]/custom-taxes/server/transaction_monitor.lua:58-59,106-108` | `_G.Bus.SinkService.Withdraw` | 大额转账税/跨组织转账税不进 sink 记账 |
| `T-CityLite.base/resources/[custom]/custom-taxes/server/property_tax.lua:258-259` | 同上 | 房产税不进 sink |
| `T-CityLite.base/resources/[custom]/custom-taxes/server/main.lua:93-94` | 同上 | 购房印花税不进 sink |
| `T-CityLite.base/resources/[custom]/custom-taxes/server/item_durability.lua:149-150` | 同上 | 维修费不进 sink |
| `T-CityLite.base/resources/[qb]/qb-shops/server/main.lua:52-53` | `_G.Bus.NPCPricing.GetBuyPrice` | NPCPricing 是 custom-taxes 的 stub，从未挂到 Bus；永远走 fallback |
| `T-CityLite.base/resources/[system]/production-freeze/server/main.lua:113-114` | `_G.Bus.HeatService.ResetHeat` | 热力重置永远不执行 |
| `T-CityLite.base/resources/[system]/production-freeze/server/main.lua:116-119` | `_G.Bus.NPCPricing` | 同上；只删一个数据文件，分支永远不进 |
| `T-CityLite.base/resources/[custom]/custom-phone/server/banking.lua:35-40` | `_G.Bus.EconomyService.TransferMoney` | 永远走手动 fallback（非原子） |
| `T-CityLite.base/resources/[qb]/qb-core/server/functions.lua:784-787` | `_G.Bus.notify.Send` | qb-core 自己的 Bus 没有 notify；永远走 `QBCore:Notify` |

**绿**：

| 位置 | 改成 |
|---|---|
| `T-CityLite.base/resources/[qb]/qb-core/server/services/sink_service.lua` 末尾 | 加 `exports('SinkWithdraw', SinkService.Withdraw)`；owner 仍在 qb-core，扣款仍走 `EconomyService.RemoveMoney` |
| `T-CityLite.base/resources/[qb]/qb-core/server/services/heat_service.lua` 末尾 | 加 `exports('HeatReset', HeatService.ResetHeat)`；同时把 `:283` 的 `_G.Bus.CoreEconomy` 改成 `GetResourceState('core_economy') == 'started'` |
| custom-taxes 4 个文件 | `exports['qb-core']:SinkWithdraw(src, amount, sinkType, reason)`；失败时保留现有 `Player.Functions.RemoveMoney` fallback（如果原来有） |
| `T-CityLite.base/resources/[qb]/qb-shops/server/main.lua:52-53` | 删掉 `_G.Bus.NPCPricing` 分支；直接用 `exports['core_economy']:GetGlobalMultiplier()`（用 `GetResourceState` 判） |
| `T-CityLite.base/resources/[system]/production-freeze/server/main.lua:113-119` | `_G.Bus.HeatService` → `pcall(function() exports['qb-core']:HeatReset(nil) end)`；删掉 `_G.Bus.NPCPricing` 分支，保留删除 `npc_prices.json` 的代码 |
| `T-CityLite.base/resources/[custom]/custom-phone/server/banking.lua:35-40` | 删掉 `_G.Bus.EconomyService` 分支；保留现有手动 `RemoveMoney` + `AddMoney` fallback（本片不新增 `EconomyTransferMoney` 导出，避免扩大 money 导出面） |
| `T-CityLite.base/resources/[qb]/qb-core/server/functions.lua:784-787` | 删掉 `_G.Bus.notify` 分支，直接 `TriggerClientEvent('QBCore:Notify', ...)` |

**闸门扩展**：`SCAN_ROOTS` 加：
```
resources/[custom]/custom-taxes/server
resources/[qb]/qb-shops/server
resources/[system]/production-freeze/server
resources/[custom]/custom-phone/server
resources/[qb]/qb-core/server/functions.lua
resources/[qb]/qb-core/server/services/heat_service.lua
```
`OWNER_FILES` 允许 qb-core 的 `_G.Bus.EconomyService` 读写（`player.lua`/`sink_service.lua`/
`economy_service.lua`），本片不扫这三份 owner 文件。

#### 4.3.3 验收命令

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/architecture/test_bus_scope.py -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit tests/architecture -q
luac5.4 -p "resources/[qb]/qb-core/server/services/sink_service.lua"
luac5.4 -p "resources/[qb]/qb-core/server/services/heat_service.lua"
luac5.4 -p "resources/[custom]/custom-taxes/server/transaction_monitor.lua"
luac5.4 -p "resources/[custom]/custom-taxes/server/property_tax.lua"
luac5.4 -p "resources/[custom]/custom-taxes/server/main.lua"
luac5.4 -p "resources/[custom]/custom-taxes/server/item_durability.lua"
luac5.4 -p "resources/[qb]/qb-shops/server/main.lua"
luac5.4 -p "resources/[system]/production-freeze/server/main.lua"
luac5.4 -p "resources/[custom]/custom-phone/server/banking.lua"
luac5.4 -p "resources/[qb]/qb-core/server/functions.lua"
```

#### 4.3.4 登记表/预算同步

| 文件 | 改动方向 | 说明 |
|---|---|---|
| `service_contracts.json` | 不改 | 新导出 `SinkWithdraw`/`HeatReset` 是静态导出，S1 闸门从代码推导，不需要 JSON 条目 |
| `gate_coverage_budget.json` | 不改 | 本片只扩扫描根，不新增 test 函数 → +0 |
| `io_budget.json` | 不改 | 本片不动广播/轮询/DB |
| `net_events_allowlist.json` | 不改 | 0 个新 net event |
| `reuse_budget.json` / `money_format_baseline.json` | 不改 | 与本片无关 |

#### 4.3.5 闸门覆盖率记账

- 本片不新增前向规则，只扩展 S2a 已证明规则的扫描根；`max_unproven` 增量 **+0**。
- 红/绿证据：PR 里先贴扩展 `SCAN_ROOTS` 后的 red 输出（上述 9 个位置），再贴修复后的 green 输出。
- 如果实施时把 S2b 拆成独立 PR 且先于 S2a 合并，则 S2a 的闸门必须一次扫全部根；
  本计划不建议这个顺序（见 §5）。

#### 4.3.6 CHANGELOG + 文档

- `CHANGELOG.md` → `### Changed`：
  「税/热度/通知的跨资源 Bus 读取改为 owner 导出：`qb-core:SinkWithdraw`、
  `qb-core:HeatReset`；大额转账/房产/维修税重新计入 sink，`QBCore.Functions.Notify`
  不再走永远不存在的 `_G.Bus.notify`。」
- `docs/engineering/REUSE.md` §2 加一句：
  「跨资源服务调用只认 `exports['<owner>']:service_<name>_<method>`；`Bus` 只是 owner 侧
  注册实现，不得跨资源读取。」并在 §5 状态表加一行「跨资源 Bus 读取：0（本次收敛）」。
- `docs/engineering/ARCHITECTURE.md`：S2a 已加同一行；本片不重复。
- `T-CityLite.base/resources/[custom]/AGENTS.md`：本片不动。

#### 4.3.7 回滚

- `git revert <sha>` 足够；无数据/迁移。
- qb-core 的两个导出是 append-only，可单独保留；回滚调用点即可恢复旧行为。
- 行为变化：修好后税**会真的扣**（之前部分路径只走不存在的 Bus 分支）；回滚
  `SinkWithdraw` 调用会恢复「税可能不扣或只走 fallback」的旧状态。上线前要在测试服
  通知玩家税率生效，不接受「怎么突然扣钱」的工单。
- 需要 `restart`：`qb-core`（导出）、`custom-taxes`、`qb-shops`、`production-freeze`、
  `custom-phone`。`qb-core` 重启会级联停掉依赖资源，按 `tools/dev/resync_modules.sh` 拉起。

#### 4.3.8 真机验证清单

| 触发步骤 | 期望现象 | 判定方式 | 标记 |
|---|---|---|---|
| 银行转账一笔 > `LARGE_TRANSACTION_THRESHOLD` | 扣 5% 税；`QBCore:Server:OnMoneySink` 触发；sink 统计 +1 | 服务端日志 + `economy-dashboard` + DB | ⛔ 钱/税只能真机 |
| 等一次房产税/手动触发 | 银行扣税；sink 统计 +1 | 日志 + DB | ⛔ |
| 维修武器 | 银行扣维修费；耐久恢复；sink 统计 +1 | 背包 + 钱 + 日志 | ⛔ |
| 购买房产（印花税） | 银行扣 2%；sink 统计 +1 | 日志 + DB | ⛔ |
| 手机银行转账给在线玩家 | 双方余额变化；无 `_G.Bus.EconomyService` 报错 | 手机 UI + DB | ⛔ |
| `QBCore.Functions.Notify` 发一条通知 | 玩家屏幕收到通知；无 `_G.Bus.notify` 分支 | 客户端截图 | ⛔ |
| 执行 `ResetEconomyToDayOne`（如有入口） | `[HeatService] Reset ALL activity heat` 日志；NPC 价格文件被清 | 服务端日志 | ✅ 日志可判 |

---

### 4.4 S3 — 限流收口到 `RateLimit`

**验收口径**：`IMPL_MARKERS` 扩展后，迁移前 `test_no_new_rate_limiter_grows` 红在
8 个文件；迁移后绿；`CALLERS` 含 8 个文件；`RateLimit.Size()` 在玩家下线后不随在线时长
单调增长；真机连续触发超阈值被拒。

#### 4.4.1 影响文件

| 动作 | 路径 |
|---|---|
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/forensics.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/tow.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/coroner.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/evidence.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/main.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-director/server/live_api.lua` |
| 修改 | `T-CityLite.base/resources/[standalone]/core-framework/server/rate_limit.lua` |
| 修改 | `T-CityLite.base/tests/architecture/test_rate_limit_single_owner.py` |
| 修改 | `tools/dev/gate_mutation_smoke.py` |
| 修改 | `CHANGELOG.md` |

删除：无。
12 文件。

#### 4.4.2 先红后绿

**红（commit 1：只扩闸门）**：
- `IMPL_MARKERS` 加 `liveBuckets|policeAlertCooldown|autoAlertCooldown|call911Cooldown|towCooldown|coronerCooldown|backupCooldown`；
- `CALLERS` 加 8 个文件（7 个 custom-police + `T-CityLite.base/resources/[custom]/custom-director/server/live_api.lua`）；
- `test_rules_fire_on_bad_shapes` 加 `liveBuckets`、`backupCooldown` 的 rogue/clean 断言；
- 此时 `test_no_new_rate_limiter_grows` 必须红在：
  `forensics.lua:46`、`tow.lua:14`、`coroner.lua:16`、`evidence.lua:171-184`、
  `p2_system.lua:556`、`p0_incidents.lua:469`、`main.lua:6,11`、`live_api.lua:113`；
- `test_migrated_callers_use_the_owner` 对 8 个文件红（找不到 `RateLimit*`）。

**绿（commit 2：迁移）**：

| 文件 | 本地表/桶 | 改成 |
|---|---|---|
| `forensics.lua` | `cooldown[cid]` + `COOLDOWN_SECONDS` | `exports['core-framework']:RateLimitCooldown(('police:%s:forensic'):format(cid), COOLDOWN_SECONDS * 1000)` |
| `tow.lua` | `towCooldown[cid]` | `RateLimitCooldown(('police:%s:tow'):format(cid), TOW_COOLDOWN_SECONDS * 1000)` |
| `coroner.lua` | `coronerCooldown[cid]` | `RateLimitCooldown(('police:%s:coroner'):format(cid), CORONER_COOLDOWN_SECONDS * 1000)` |
| `evidence.lua` | `pickupAt[src]` + `pickupWrites` + 每 64 次 prune | `RateLimitCooldown(('police:%s:evidence:pickup'):format(src), 1000)`；删掉 prune 循环 |
| `p2_system.lua` | `backupCooldown[cid]` | `RateLimitCooldown(('police:%s:backup'):format(cid), BACKUP_COOLDOWN * 1000)` |
| `p0_incidents.lua` | `call911Cooldown[src]` + 60s prune | `RateLimitCooldown(('police:%s:911'):format(src), CALL_911_COOLDOWN * 1000)`；删掉 prune 循环 |
| `main.lua` | `autoAlertCooldown[src/'system']`、`policeAlertCooldown[src]` + prune | `RateLimitCooldown(('police:%s:autoalert'):format(cooldownKey), AUTO_ALERT_COOLDOWN * 1000)`、`('police:%s:alert'):format(src)`；删掉两个 prune 循环；`main.lua` 加一个 `playerDropped` 清 `police:<src>:` 前缀 |
| `live_api.lua` | `liveBuckets` + 完整令牌桶 | `RateLimitTokenBucket(('director:live:%s'):format(liveKey(live.token)), live.rate_per_min, live.burst)`；用返回的 `retryAfterMs` 组装现有 429 |
| `rate_limit.lua` | — | 加一个 owner 自清理线程：`if type(CreateThread) == 'function' then CreateThread(function() while true do Wait(60 * 1000); RateLimit.Sweep(15 * 60 * 1000) end end) end`；`Wait` 是常量 60000，不落入 fast/warm/unknown 三档 |

**键与清理**：
- 所有 src 键统一 `police:<src>:<action>`；`playerDropped` 一次 `RateLimitReset('police:<src>:')`。
- cid 键（forensic/tow/coroner/backup）由 owner 的 60s 自清理（15 分钟 maxAge）回收；
  15 分钟大于所有 cooldown（最长 60s），不会误删活跃键。
- `custom-director` 的 token 键数量由 live credential 数量决定，不需要玩家下线清理。

#### 4.4.3 验收命令

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/architecture/test_rate_limit_single_owner.py -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit tests/architecture -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit/layer1_core/test_rate_limit.py -q
luac5.4 -p "resources/[custom]/custom-police/server/forensics.lua"
luac5.4 -p "resources/[custom]/custom-police/server/tow.lua"
luac5.4 -p "resources/[custom]/custom-police/server/coroner.lua"
luac5.4 -p "resources/[custom]/custom-police/server/evidence.lua"
luac5.4 -p "resources/[custom]/custom-police/server/p2_system.lua"
luac5.4 -p "resources/[custom]/custom-police/server/p0_incidents.lua"
luac5.4 -p "resources/[custom]/custom-police/server/main.lua"
luac5.4 -p "resources/[custom]/custom-director/server/live_api.lua"
luac5.4 -p "resources/[standalone]/core-framework/server/rate_limit.lua"
```

#### 4.4.4 登记表/预算同步

| 文件 | 改动方向 | 说明 |
|---|---|---|
| `test_rate_limit_single_owner.py` | 收紧 | `IMPL_MARKERS` 扩 7 个别名；`CALLERS` 加 8 文件；反向用例加 2 个形状 |
| `gate_coverage_budget.json` | 不改 | 没有新增 `test_` 函数；现有规则已由 smoke 证明 → +0 |
| `io_budget.json` | 不改 | 新线程 Wait(60000) 是常量，不落入 fast/warm/unknown 档；实测后 `budget_probe --check` 确认 |
| `net_events_allowlist.json` | 不改 | 0 个新 net event |
| `reuse_budget.json` / `money_format_baseline.json` | 不改 | 与本片无关 |

#### 4.4.5 闸门覆盖率记账

- 本片**不新增前向规则**，只扩现有规则的 marker/调用方列表 → `max_unproven` 增量 **+0**。
- 现有 `test_no_new_rate_limiter_grows` 已在 `gate_mutation_smoke.py` 有 `UserCooldowns` 用例；
  本片再加一条 `liveBuckets` 用例，证明新 marker 也会红：
  - 注入：**resources/[custom]/custom-vehicles/server/__mutant_ratelimit2.lua**
  - 内容：`local liveBuckets = {}`
  - gate：`tests/architecture/test_rate_limit_single_owner.py::test_no_new_rate_limiter_grows`
- 若不加这条变异用例，新 marker 本身没有独立证明；但前向规则没有新增，`max_unproven` 仍不变。
  计划要求加，避免「marker 写了但抓不住」的假绿。

#### 4.4.6 CHANGELOG + 文档

- `CHANGELOG.md` → `### Security`：
  「限流收口到 `RateLimit`：custom-police 7 文件/8 表 + custom-director 1 桶全部迁移；
  `IMPL_MARKERS` 扩展后闸门先红后绿；owner 每 60s 自清理 15 分钟未更新的键。」
- `docs/engineering/REUSE.md`：本片不动。S5 会把「下一批候选」里的 `checkRateLimit` 标成已收口。
- `docs/engineering/ARCHITECTURE.md`：本片不动。
- `T-CityLite.base/resources/[custom]/AGENTS.md`：本片不动。

#### 4.4.7 回滚

- `git revert <sha>` 足够；无数据/迁移。
- 按文件回滚安全：每个 net event 入口的限流是独立的；回滚一个文件只恢复该入口的本地表。
- owner 自清理线程可单独保留（不影响旧表）；若回滚 `rate_limit.lua`，旧表恢复后不需要清理线程。
- 需要 `restart`：`core-framework`（owner）、`custom-police`、`custom-director`。
- 行为变化：旧表用 `os.time()` 秒，新 owner 用 `GetGameTimer()` 毫秒；阈值含义不变，
  但边界精度从秒变毫秒。真机连续触发时可能比旧实现早/晚 1 次，属预期。

#### 4.4.8 真机验证清单

| 触发步骤 | 期望现象 | 判定方式 | 标记 |
|---|---|---|---|
| 连续触发 `police:server:forensicSample` 超过 20s 1 次 | 超阈值请求被拒；无 `RateLimit` 报错 | 服务端日志 + 审计行数 | ⛔ 时序只能真机 |
| 连续触发 tow/coroner/backup/911/policeAlert/autoAlert | 各自阈值生效；不同入口互不串键 | 服务端日志 + 审计行数 | ⛔ |
| 玩家下线后重连，立刻再触发 | 旧冷却不残留（`police:<src>:` 被清）；cid 键最多 15 分钟后清 | 控制台 `RateLimitStats`/`RateLimit.Size()` 探针 | ⛔ 需要下线/重连 |
| custom-director 用同一 live token 连发超过 `burst` | 返回 429 `rate_limited` + `Retry-After`；行为与 owner 一致 | HTTP 响应 + 服务端日志 | ⛔ HTTP 层 |

---

### 4.5 S4 — `Db` 结果适配器

**验收口径**：在 `[custom]` + core-framework 范围内，`insertId/affectedRows` 的归一化
只允许出现在 **core-framework/server/db.lua**；`Db.Insert` 对 number/table/string/nil
四种返回形状的单测全绿；`insertId` 缺失时不再把 `affectedRows` 当 id；director 的
`agent_actions` 使用正确 id。`[qb]` 上游（如 qb-core 的 `EconomyAddMoneyOffline`）不在扫描范围，
保持原样。

#### 4.5.1 影响文件

| 动作 | 路径 |
|---|---|
| 新增 | **T-CityLite.base/resources/[standalone]/core-framework/server/db.lua** |
| 新增 | **T-CityLite.base/tests/architecture/test_db_result_adapter.py** |
| 修改 | `T-CityLite.base/resources/[standalone]/core-framework/fxmanifest.lua` |
| 修改 | `tools/dev/gate_mutation_smoke.py` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-director/fxmanifest.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-director/server/main.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-director/server/director.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-phone/fxmanifest.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-phone/server/sms.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/fxmanifest.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/shared/insert_id.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/records.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/citations.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/p2_evidence.lua` |
| 修改 | `T-CityLite.base/tests/unit/layer3_business/test_phone_db_contract.py` |
| 修改 | `T-CityLite.base/tests/agent/lua/cases/police_outbox.lua` |
| 修改 | `CHANGELOG.md` |
| 修改 | `T-CityLite.base/resources/[custom]/AGENTS.md` |

删除：无。
19 文件（含 2 个必须改加载顺序的 Lua harness；§9.4 里其余只补 stub 的 harness 不计入）。
**为什么不能再切**：新闸门要求「归一化只在 `db.lua`」，适配器和 6 个归一化点
必须同 PR；拆开中间态必红，只能靠临时 allowlist，而 allowlist 正是这次要消灭的债。
3 个 fxmanifest 只是加一行 **@core-framework/server/db.lua**；`insert_id.lua`/`PhoneDb` 保留
门面是为了不牵动 `p2_system.lua`/`p3_cases.lua`/`T-CityLite.base/resources/[custom]/custom-phone/server/main.lua`/`jobboard.lua`/
`T-CityLite.base/resources/[custom]/custom-phone/server/core/notify.lua` 这 5 个调用文件。
2 个 Lua harness 必须同 PR：`test_phone_db_contract.py` 直接 `loadfile(sms.lua)`，
`T-CityLite.base/tests/agent/lua/cases/police_outbox.lua` 直接 `dofile(insert_id.lua)`；门面改成
`Db.*` 后它们必须先加载 `db.lua`。报告 §4.2 自己也把 Db 标为「风险最高、迁移最大」。

#### 4.5.2 先红后绿

**红（commit 1：只加闸门/单测）**：
- `test_result_normalisation_only_in_db_adapter` 必须列出：
  `T-CityLite.base/resources/[custom]/custom-director/server/main.lua:140-142`（把 `affectedRows` 当 id）、
  `T-CityLite.base/resources/[custom]/custom-phone/server/sms.lua:21-31`（只认 `insertId`）、
  `T-CityLite.base/resources/[custom]/custom-police/shared/insert_id.lua:4-9`（表/数字归一化）、
  `T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua:372,549`、
  `T-CityLite.base/resources/[custom]/custom-police/server/p2_evidence.lua:224`、
  `T-CityLite.base/resources/[custom]/custom-police/server/citations.lua:135`、
  `T-CityLite.base/resources/[custom]/custom-police/server/records.lua:195,216`。
- `test_db_result_adapter.py` 因 `db.lua` 不存在而红（或 4 个形状全失败）。

**绿（commit 2：加 `db.lua` 并迁移）**：

`db.lua` 的契约（写在文件头注释，逐条可测）：
- `Db.Insert(sql, params) -> number|nil, string|nil`：`MySQL.insert.await`；
  表取 `insertId`/`[1]`/`id`；**表里只有 `affectedRows` 时返回 `nil, 'no_insert_id'`**；
  字符串视为 `nil, 'db_error'`；0 视为 `nil, 'no_insert_id'`。
- `Db.Update(sql, params) -> number|nil, string|nil`：`MySQL.update.await`；
  `affectedRows`/`affected_rows`/`[1]`/number；字符串 → `nil, 'db_error'`；0 是成功。
- `Db.Query/Single/Scalar(sql, params) -> result|nil, string|nil`：`pcall` + 错误截断 160 字。
- `Db.InsertId(result) -> number` / `Db.AffectedRows(result) -> number`：纯归一化，不碰 SQL。
- 不拼 SQL、不改列名、不重试、不超时、不使用 `Citizen.Await`。

迁移表：

| 位置 | 现状 | 改成 |
|---|---|---|
| `T-CityLite.base/resources/[custom]/custom-director/server/main.lua:128-158` | `dbInsert`/`dbUpdate` 各自归一化 | `Db.Insert`/`Db.Update` 的薄包装；删除 `affectedRows` 兜底 |
| `T-CityLite.base/resources/[custom]/custom-director/server/director.lua:98-121` | 同上（第二份） | 同上 |
| `T-CityLite.base/resources/[custom]/custom-phone/server/sms.lua:21-31` | `PhoneDb.InsertId/AffectedRows` 各自归一化 | 保留门面，函数体 `return Db.InsertId(result)` / `return Db.AffectedRows(result)` |
| `T-CityLite.base/resources/[custom]/custom-police/shared/insert_id.lua:4-9` | `InsertId` 自己归一化 | 保留门面，函数体 `return Db.InsertId(result)`；文件从 `shared_scripts` 移到 `server_scripts`（当前无客户端调用） |
| `T-CityLite.base/resources/[custom]/custom-police/server/records.lua:193-197,214-216` | 内联 `type(result)=='table'` | `local affected, err = Db.Update(...)`；`err` 时按现有语义返回 |
| `T-CityLite.base/resources/[custom]/custom-police/server/citations.lua:132-139` | 内联 | 同上 |
| `T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua:372-373,549` | 内联 | 同上；`affected` 为 nil 时仍按 0 处理，但打一行 `[db]` 日志 |
| `T-CityLite.base/resources/[custom]/custom-police/server/p2_evidence.lua:222-225` | 内联 | 同上 |

**不迁移**：`T-CityLite.base/resources/[custom]/custom-quest/server/quest_db.lua:24-47`、`T-CityLite.base/resources/[custom]/story-engine/server/story_db.lua:28`。
它们没有 `type(x)=='table'` 归一化形状，迁到 `await` 会改异步语义；见 §1.3。

**闸门扫描范围**：`resources/[custom]/**/server/**/*.lua` +
`resources/[standalone]/core-framework/server/**/*.lua` + `T-CityLite.base/resources/[custom]/custom-police/shared/insert_id.lua`；
`[qb]` 上游全部排除（qb-core 的 `EconomyAddMoneyOffline` 有自己的归一化，不动）。
`test_db_result_adapter.py` 的 4 个返回形状用 `lua5.4` 加载真实 `db.lua` + stub `MySQL`，
不读业务文件。

**两个直接 `loadfile` 的 Lua harness 必须一起改**：
- `T-CityLite.base/tests/unit/layer3_business/test_phone_db_contract.py` 现在直接
  `loadfile(sms.lua)`；改为先 `loadfile(db.lua)` 再 `loadfile(sms.lua)`（`Db.InsertId` 是纯函数，
  不需要 MySQL stub）。
- `T-CityLite.base/tests/agent/lua/cases/police_outbox.lua:31` 现在直接
  `dofile(insert_id.lua)`；改为先 `dofile(core-framework/server/db.lua)` 再
  `dofile(insert_id.lua)`。
- `T-CityLite.base/tests/unit/layer3_business/test_phone_apps.py:271` 的静态断言
  `"function InsertId" and "insertId" in shared`：`insert_id.lua` 保留一行注释
  `-- insertId / affectedRows 的归一化在 core-framework/server/db.lua`，断言继续通过；
  不把这个测试改成「只认字符串」（真正的规则在 S4 闸门里）。
- **同文件的 `test_insert_ids_are_normalized` 还有两条位置断言，S4 必须一起保证绿**：
  `any("InsertId(" in src for src in p0_files().values())` 与
  `for f in ("p2_evidence.lua","p3_cases.lua"): "InsertId(" in src`。这两条断言的是
  「归一化入口仍是 `InsertId(`」，不是实现细节。因此 S4 **只允许把 `InsertId` 的函数体改成
  `return Db.InsertId(result)`（门面），不得把调用点的 `InsertId(` 改名为 `Db.InsertId(...)`**；
  否则这两条会红。若确实要改名，必须在同一 PR 里把断言改成对 `Db.InsertId(` 的检查，
  并在 PR 描述里写明「断言随符号改名」，不能直接删断言。
  `pytest tests/unit/layer3_business/test_phone_apps.py -q` 必须出现在 S4 的验收命令里。

#### 4.5.3 验收命令

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/architecture/test_db_result_adapter.py -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit/layer3_business/test_phone_db_contract.py -q
& 'C:\\Users\\swkgb\\AppData\\Local\\Programs\\Python\\Python312\\python.exe' -m pytest tests/unit/layer3_business/test_phone_apps.py -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit tests/architecture -q
luac5.4 -p "resources/[standalone]/core-framework/server/db.lua"
luac5.4 -p "resources/[custom]/custom-director/server/main.lua"
luac5.4 -p "resources/[custom]/custom-director/server/director.lua"
luac5.4 -p "resources/[custom]/custom-phone/server/sms.lua"
luac5.4 -p "resources/[custom]/custom-police/shared/insert_id.lua"
luac5.4 -p "resources/[custom]/custom-police/server/records.lua"
luac5.4 -p "resources/[custom]/custom-police/server/citations.lua"
luac5.4 -p "resources/[custom]/custom-police/server/p0_incidents.lua"
luac5.4 -p "resources/[custom]/custom-police/server/p2_evidence.lua"
```

`tests/agent` 的 harness 不在 §2.1 的默认命令里；S4 额外跑一次：

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/agent -q
```

4 种返回形状的单测（由 `test_db_result_adapter.py` 用 `lua5.4` 加载真实 `db.lua` + stub `MySQL`）：
- `MySQL.insert.await` 返回 `42` → `Db.Insert` = `42`；
- 返回 `{ insertId = 7, affectedRows = 1 }` → `7`；
- 返回 `{ affectedRows = 1 }` → `nil, 'no_insert_id'`（**不得返回 1**）；
- 返回 `'Duplicate entry'` → `nil, 'db_error'`；
- `Db.Update` 的 `affectedRows` 同上，0 是成功。

#### 4.5.4 登记表/预算同步

| 文件 | 改动方向 | 说明 |
|---|---|---|
| `T-CityLite.base/resources/[standalone]/core-framework/fxmanifest.lua` | 新增条目 | `server_scripts` 加 server/db.lua（在 @oxmysql/lib/MySQL.lua 之后） |
| custom-director/custom-phone/custom-police `fxmanifest.lua` | 新增条目 | 各加 **@core-framework/server/db.lua**（在 @oxmysql/lib/MySQL.lua 之后）；custom-police 把 shared/insert_id.lua 从 `shared_scripts` 移到 `server_scripts`，位置在 **@core-framework/server/db.lua** 之后、server/citations.lua 之前 |
| `gate_coverage_budget.json` | 不改 | +0（见 §4.5.5） |
| `io_budget.json` | 不改预算数字 | 迁移是把 `MySQL.*` 调用点搬进 `db.lua`，净变化应 ≤0；实测后 `budget_probe --check` 必须 ≤465。若 +N，先删对应调用点的旧 `MySQL.*`，**不允许**调高预算 |
| `net_events_allowlist.json` | 不改 | 0 个新 net event |
| `reuse_budget.json` / `money_format_baseline.json` | 不改 | 与本片无关 |

#### 4.5.5 闸门覆盖率记账

- 新增 **1 条前向规则**（`test_result_normalisation_only_in_db_adapter`）+ 1 条反向。
- 选 **(a)**：变异用例注入 **resources/[custom]/custom-vehicles/server/__mutant_db.lua**，
  内容 `local id = type(res) == 'table' and (res.affectedRows or res[1]) or res`；
  gate 指向 `test_result_normalisation_only_in_db_adapter`。
- 增量 **+0**。若不加变异，则 +1（279），`history` 写
  `date=2026-11-15 / previous=278 / why="新增 DB 结果归一化前向规则" / 到期条件="补变异用例后降回 278"`。

#### 4.5.6 CHANGELOG + 文档

- `CHANGELOG.md` → `### Fixed`：
  「`Db` 结果适配器：`insertId/affectedRows` 归一化收口到
  **core-framework/server/db.lua**；director 不再把 `affectedRows=1` 当记录 id；
  phone/police 的 5 个调用方保留门面、行为不变。」
- `T-CityLite.base/resources/[custom]/AGENTS.md`「唯一入口」表「服务端 → DB」行改为：
  | 服务端 → DB | `Db.Insert/Update/Query/Single/Scalar`（**@core-framework/server/db.lua**），不直接 `MySQL.*` |
  并把「已知坑」里「oxmysql 定制版 insert 可能返回 `{insertId, affectedRows}`」改成
  「统一走 `Db.Insert`，不要自己解形状」。
- `docs/engineering/ARCHITECTURE.md`：本片不动（P3 仍是唯一 DB 平面，`Db` 是 P3 内部 helper）。
- `docs/engineering/REUSE.md`：本片不动（`Db` 不是同名函数碎片，是结果形状适配）。

#### 4.5.7 回滚

- 适配器可独立保留：`db.lua` 不迁调用方时是惰性的；回滚调用方即可恢复本地 helper。
- 建议按批 revert：director（2 文件）→ phone（1 文件）→ police（5 文件）；每批都可单独回滚。
- `insert_id.lua` 从 `shared_scripts` 移到 `server_scripts` 是可逆的；回滚要同时恢复
  `T-CityLite.base/resources/[custom]/custom-police/fxmanifest.lua` 的两个条目。
- 无数据/迁移；`agent_actions` 的历史行不受影响。
- 需要 `refresh` + `restart`：`core-framework`（新增 `db.lua` 必须 `refresh`，否则已连接客户端/
  服务器不会拿到新文件）、`custom-director`、`custom-phone`、`custom-police`。

#### 4.5.8 真机验证清单

| 触发步骤 | 期望现象 | 判定方式 | 标记 |
|---|---|---|---|
| director 执行一个 approved action | `agent_actions` 行 id 正确；后续 `completeApproved` 更新同一行，不更新错行 | DB 查询 `agent_actions` | ⛔ DB id 只能真机 |
| 手机发短信/加联系人 | 新行 id 正确；无 `insertId` 字符串错误 | DB 查询 `phone_messages`/contacts | ⛔ |
| 警察建案卷/罚单/关警情/自动绑证据 | 行更新成功；无 `db_error`；`affected` 语义与旧一致 | DB + 服务端日志 | ⛔ |
| 停掉 MariaDB 后触发一次写 | `[db]` 日志截断 160 字；调用方返回错误而不是崩 | 服务端日志 | ⛔ 破坏性，只在测试服 |

---

### 4.6 S5 — `CFShared.LoadModel` 采纳

**验收口径**：8 个迁移文件不再有本地 `RequestModel` + `while not HasModelLoaded`
无退出条件循环；模型缺失时客户端不卡死；`CFShared.Report` 每次进程最多报一条同类失败。

#### 4.6.1 影响文件

| 动作 | 路径 |
|---|---|
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/client/entity_util.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/client/coroner.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/client/tow.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/client/lockdown.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/client/scenery.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-cartel/client/main.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-quest/client/main.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-quest/client/quest_logistics_client.lua` |
| 新增 | **T-CityLite.base/tests/architecture/test_load_model_single_owner.py** |
| 修改 | `tools/dev/gate_mutation_smoke.py` |
| 修改 | `CHANGELOG.md` |
| 修改 | `docs/engineering/REUSE.md` |

删除：无。
12 文件。

#### 4.6.2 先红后绿

**红**：`test_no_local_loadmodel_loops` 必须列出：
- `T-CityLite.base/resources/[custom]/custom-police/client/entity_util.lua:11-20`（本地 `EntityUtil.LoadModel`，5s 超时，无上报）；
- `T-CityLite.base/resources/[custom]/custom-cartel/client/main.lua:42-50`（`RequestModel` + `while not HasModelLoaded`，300 次 ×10ms）；
- `T-CityLite.base/resources/[custom]/custom-quest/client/main.lua:593-594`（**无超时** `while not HasModelLoaded(...) do Citizen.Wait(10) end`）；
- `T-CityLite.base/resources/[custom]/custom-quest/client/quest_logistics_client.lua:415-422`（50×100ms，失败只 notify）；
- 以及 4 个 `EntityUtil.LoadModel` 调用方（coroner/tow/lockdown/scenery）仍引用本地实现。

**绿**：

| 位置 | 改成 |
|---|---|
| `entity_util.lua` | 删除 `EntityUtil.LoadModel`（保留 `EntityUtil.Delete`）；文件头注释改为「模型加载走 `CFShared.LoadModel`」 |
| `coroner.lua:16`、`tow.lua:16`、`lockdown.lua:14` | `local loadModel = CFShared.LoadModel` |
| `scenery.lua:45` | `CFShared.LoadModel(guardHash, 5000)` / `CFShared.LoadModel(patrolHash, 5000)` |
| `T-CityLite.base/resources/[custom]/custom-cartel/client/main.lua:42-50` | `if not CFShared.LoadModel(hash, 5000) then print(...); return end`；需要时 `CFShared.ReleaseModel(hash)` |
| `T-CityLite.base/resources/[custom]/custom-quest/client/main.lua:593-594` | `if not CFShared.LoadModel(GetHashKey(data.npcModel), 10000) then return end` |
| `quest_logistics_client.lua:415-422` | `if not CFShared.LoadModel(modelHash, 5000) then QBCore.Functions.Notify(...); return end` |

**不迁移**：热狗两个客户端文件。它们的循环有 `deadline` + `generation` 退出条件，
不是「无超时」形状；且属于另一条任务的工作集。闸门只抓无退出条件的本地循环。

**闸门设计**（`test_load_model_single_owner.py`，只写两个 `test_` 函数）：
1. `test_no_local_loadmodel_loops`（前向）：
   - 扫 `resources/[custom]/**/client/**/*.lua`；
   - 命中 `while not HasModelLoaded` / `while not NativeBool(HasModelLoaded(...))` 且循环体内
     **没有** `GetGameTimer() < deadline`、`timeout < N`、`generation ~= ...` 之类的退出条件 → 红；
   - 7 个调用文件（coroner/tow/lockdown/scenery/cartel/quest main/quest logistics）必须出现
     `CFShared.LoadModel`；`entity_util.lua` 不得再定义 `EntityUtil.LoadModel` 或本地循环；
   - 允许 `T-CityLite.base/resources/[custom]/custom-quest/client/quest_hotdog_*` 的有界循环（按上面的退出条件判定，不按文件名）。
2. `test_reverse_unbounded_model_loop_is_rejected`（反向）：
   - 合成 `RequestModel(hash); while not HasModelLoaded(hash) do Wait(10) end` → 必须报；
   - 合成带 `deadline` 的循环 → 必须不报；
   - 合成 `CFShared.LoadModel(hash)` 调用 → 必须不报。

#### 4.6.3 验收命令

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/architecture/test_load_model_single_owner.py -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit tests/architecture -q
luac5.4 -p "resources/[custom]/custom-police/client/entity_util.lua"
luac5.4 -p "resources/[custom]/custom-police/client/coroner.lua"
luac5.4 -p "resources/[custom]/custom-police/client/tow.lua"
luac5.4 -p "resources/[custom]/custom-police/client/lockdown.lua"
luac5.4 -p "resources/[custom]/custom-police/client/scenery.lua"
luac5.4 -p "resources/[custom]/custom-cartel/client/main.lua"
luac5.4 -p "resources/[custom]/custom-quest/client/main.lua"
luac5.4 -p "resources/[custom]/custom-quest/client/quest_logistics_client.lua"
```

#### 4.6.4 登记表/预算同步

| 文件 | 改动方向 | 说明 |
|---|---|---|
| `reuse_budget.json` | **不改** | `LoadModel`/`loadModel` 都 < `MIN_COUNT=4`；新增条目会被 `test_reuse_budget.py` 判为「已不再重复，请删掉」 |
| `gate_coverage_budget.json` | 不改 | +0（见 §4.6.5） |
| `io_budget.json` | 不改 | 客户端 `Wait(10)` 循环不在 `io_budget` 的服务端扫描范围内；模型加载的 `Wait(10)` 仍是 10ms，但只在加载期短暂运行 |
| `net_events_allowlist.json` | 不改 | `CFShared.Report` 复用既有 `core-framework:server:clientReport`，不新增事件 |
| `service_contracts.json` | 不改 | `CFShared.LoadModel` 是客户端 include，不是 export |

#### 4.6.5 闸门覆盖率记账

- 新增 **1 条前向规则**（`test_no_local_loadmodel_loops`）+ 1 条反向。
- 选 **(a)**：变异用例注入 **resources/[custom]/custom-vehicles/client/__mutant_model.lua**，
  内容 `RequestModel(hash); while not HasModelLoaded(hash) do Wait(10) end`；
  gate 指向 `test_no_local_loadmodel_loops`。
- 增量 **+0**。若不加变异，则 +1（279），`history` 写
  `date=2026-11-15 / previous=278 / why="新增无超时模型加载前向规则" / 到期条件="补变异用例后降回 278"`。

#### 4.6.6 CHANGELOG + 文档

- `CHANGELOG.md` → `### Fixed`：
  「`LoadModel` 收口到 `CFShared.LoadModel`：删除 custom-police/custom-cartel/custom-quest
  的 4 份本地实现；模型缺失时客户端不再无超时卡死，失败经 `CFShared.Report` 上报一次。」
- `docs/engineering/REUSE.md` §5「当前状态」加一行：
  | `LoadModel` | 4 个 `[custom]` 本地实现（含 2 个无超时） | 0（统一走 `CFShared.LoadModel`） | `T-CityLite.base/resources/[standalone]/core-framework/client/shared.lua:69-104` |
  并把「下一批候选」里的 `loadModel` 标成「已完成」。
- `docs/engineering/ARCHITECTURE.md`：本片不动（客户端 include 的规则已在 §2/REUSE）。
- `T-CityLite.base/resources/[custom]/AGENTS.md`：本片不动。

#### 4.6.7 回滚

- `git revert <sha>` 足够；无数据/迁移。
- 按资源回滚：custom-police 5 文件、custom-cartel 1 文件、custom-quest 2 文件互相独立；
  回滚 `entity_util.lua` 会恢复本地 `LoadModel`，其它资源的 `CFShared` 调用仍可用。
- 客户端资源改动需要 `restart <res>`；`CFShared` 已在 manifest 里，不需要 `refresh`
  （如果改了 `T-CityLite.base/resources/[standalone]/core-framework/client/shared.lua` 才需要 `refresh`，本片不改它）。
- 行为变化：custom-police 的旧超时是 5s，新调用显式传 5000ms，保持一致；
  custom-quest main 旧实现无超时，新实现 10s，属修复。

#### 4.6.8 真机验证清单

| 触发步骤 | 期望现象 | 判定方式 | 标记 |
|---|---|---|---|
| 警察叫验尸官/拖车/封锁/布景 | NPC/载具模型正常加载；F8 有 `[core-framework] client shared ready` | 客户端 F8 + 服务端 `clientReport` 日志 | ⛔ 模型加载只能真机 |
| 把 `npcCfg.model` 改成一个不存在的模型，触发 cartel NPC 生成 | 客户端不卡死；服务端 `clientReport` 出现一条 `模型不在 cdimage` 或超时；不再刷屏 | 客户端 F8 + 服务端日志 | ⛔ |
| 把 quest combat 的 `npcModel` 改成不存在的模型 | 任务不卡死；客户端有失败提示或安全返回 | 客户端 F8 + 任务状态 | ⛔ |
| 正常完成一次拖车/验尸官任务 | 行为与旧实现一致（模型加载成功、实体生成） | 任务流程 + 截图 | ⛔ |

---

### 4.7 S6 — `FormatMoney` 合并 + `$%d` 基线下降（已按 Sonar 重复返工）

**验收口径**：金额格式化实现只剩 `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua` 一份；
四个历史别名（`Money`/`PhoneMoney`/`QuestMoney`/`TCMoney`）只在
`T-CityLite.base/resources/[standalone]/core-framework/shared/money_aliases.lua` 定义一次，
8 个 `[custom]` 资源删除各自的 shared/money_format.lua 并在 fxmanifest 里 include 别名文件；
`$%d` 基线从 66 降到 59，`test_money_format.py` 双向相等。

#### 4.7.1 影响文件

| 动作 | 路径 |
|---|---|
| 修改 | `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua` |
| 新增 | **T-CityLite.base/resources/[standalone]/core-framework/shared/money_aliases.lua** |
| 修改 | 8 个 `[custom]` 资源的 `fxmanifest.lua`：custom-market / custom-main / custom-cartel / custom-security / custom-crime / custom-phone / custom-quest / custom-taxes（shared/money_format.lua → '@core-framework/shared/money_aliases.lua'） |
| 修改 | `T-CityLite.base/resources/[custom]/custom-market/server/main.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-phone/client/main.lua` |
| 修改 | `T-CityLite.base/tests/architecture/money_format_baseline.json` |
| 修改 | `T-CityLite.base/tests/unit/layer3_business/test_money_renderers.py` |
| 修改 | `T-CityLite.base/tests/unit/layer3_business/test_quest_rewards.py` |
| 新增 | **T-CityLite.base/tests/architecture/test_money_format_single_owner.py** |
| 修改 | `tools/dev/gate_mutation_smoke.py` |
| 修改 | `CHANGELOG.md` |

删除：8 个 `[custom]` 资源的 shared/money_format.lua（同上 8 个资源；名称不带完整路径，
避免把已删除文件写成文档链接）。
17 文件。**为什么不能再切**：8 份门面逐行相同，保留它们就是 Sonar 新代码重复（实测 9.9%）；
`test_money_renderers.py` / `test_quest_rewards.py` 直接 dofile 门面，必须同 PR 改成
加载唯一别名文件；2 个调用点（market 6 条、phone 1 条）是 `$%d` 基线下降的最小证明；
基线/闸门/smoke/CHANGELOG 是交付要求。

**方案选择（与报告 §4.4 的差异）**：报告建议删除 8 个 shared/money_format.lua 并把所有
调用点改成 `FormatMoney`。实际调用点有 76 处 / 29 文件，一个 PR 做不完（>12 文件、>1 天）。
本计划先保留 8 个 ≤10 行门面，但 Sonar 把 8 份逐行相同的门面算成新代码重复（9.9%，阈值 3%），
所以返工为**一个共享别名文件** core-framework/shared/money_aliases.lua：
资源 fxmanifest 用 '@core-framework/shared/money_aliases.lua' include，
四个历史名字与全部调用点不变；`FormatMoney` 仍是唯一实现。

```lua
local function alias(value)
    if GetResourceState('core-framework') ~= 'started' then return '0' end
    return exports['core-framework']:FormatMoney(value)
end

function Money(value) return alias(value) end
function PhoneMoney(value) return alias(value) end
function QuestMoney(value) return alias(value) end
function TCMoney(value) return alias(value) end
```

#### 4.7.2 先红后绿

**红（commit 1：只加闸门）**：`test_money_format_has_a_single_implementation` 必须列出
8 个 shared/money_format.lua 的实现体（`tonumber` + `num % 1 == 0` + `%.2f`）：
custom-market、custom-main、custom-cartel、custom-security、custom-crime、custom-phone
（`PhoneMoney`）、custom-quest（`QuestMoney`）、custom-taxes（`TCMoney`）。

**绿（commit 2：加 `FormatMoney` + 别名文件 + 基线）**：
- `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua` 加：
```lua
--- 金额渲染：nil/非数字 → '0'；整数无小数点；小数两位；负数保留符号。
function FormatMoney(value)
    local num = tonumber(value)
    if not num or num ~= num then return '0' end
    if num % 1 == 0 then return ('%d'):format(num) end
    return ('%.2f'):format(num)
end
exports('FormatMoney', FormatMoney)   -- 两端都注册：shared/util.lua 在客户端和服务端都加载
```
- 8 个资源各自的 shared/money_format.lua 删除；四个历史名字（`Money`/`PhoneMoney`/
  `QuestMoney`/`TCMoney`）只在 `T-CityLite.base/resources/[standalone]/core-framework/shared/money_aliases.lua`
  定义一次，资源 fxmanifest 用 '@core-framework/shared/money_aliases.lua' include；调用点不改名。
- `T-CityLite.base/resources/[custom]/custom-market/server/main.lua` 的 6 条 `$%d` 改成 `$%s` + `Money(...)`；
- `T-CityLite.base/resources/[custom]/custom-phone/client/main.lua` 的 1 条 `$%d` 改成 `$%s` + `PhoneMoney(...)`；
- `money_format_baseline.json` 删掉这 7 条，`total` 66→59（双向相等，必须同 commit）。

**`test_money_renderers.py` / `test_quest_rewards.py` 的加载方式必须同 PR 改**：它们现在
直接 `dofile` 每个资源的门面。别名转调 `exports['core-framework']:FormatMoney` 后，
测试要先定义**可调用且可索引**的 `exports` 表（`__call` 注册、`__index` 返回
`core-framework` 的方法表），定义 `IsDuplicityVersion() return false`，
`dofile(core-framework/shared/util.lua)` 拿到真实 `FormatMoney`，再 `dofile` 唯一别名文件；
渲染测试对**四个别名**各跑同一组输入。

**闸门设计**（`test_money_format_single_owner.py`，三个 `test_` 函数）：
1. `test_money_format_has_a_single_implementation`（前向）：
   - 扫 `resources/[custom]/**/*.lua`，找 `tonumber(...)` + `% 1 == 0` + `%.2f` 的组合；
   - 8 个旧门面文件不许再出现；`[custom]` 里非 `local` 的全局别名定义也不许出现；
   - 允许 `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua`（唯一实现）；
   - 别名文件必须存在、定义四个名字、只出现 `exports['core-framework']:FormatMoney`；
   - 允许 `T-CityLite.base/resources/[custom]/custom-quest/client/quest_hotdog_vendor_client.lua:122-131` 的委托 fallback
     （它先 `if type(QuestMoney) == 'function' then return QuestMoney(value) end`，不是第二份实现）；
   - qb-drugs 不在 `[custom]` 扫描范围。
2. `test_reverse_money_format_alias_is_rejected`（反向）：
   - 合成 `local function PhoneMoney(value) ... end` 的实现体 → 必须报；
   - 合成全局 `function Money(value) ... end` 的复制门面 → 必须报；
   - 合成 `local function Money(value) return alias(value) end` → 必须不报；
   - 合成只有 `$%s` 的安全文案 → 必须不报。
3. `test_money_alias_users_load_the_alias_file`（接线）：
   - 凡是 `[custom]` 资源里调用了四个别名之一，其 `fxmanifest.lua` 必须包含
     @core-framework/shared/money_aliases.lua，或同资源内定义了同名等价函数；
   - 反向：合成一个调 `Money()` 但 manifest 没 include 的资源 → 必须红；补上 include → 必须绿。
     这是运行时才会炸的 `attempt to call a nil value (global 'Money')`，静态闸门正是该拦它的地方。

#### 4.7.3 验收命令

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/architecture/test_money_format_single_owner.py -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/architecture/test_money_format.py -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit/layer3_business/test_money_renderers.py -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit tests/architecture -q
luac5.4 -p "resources/[standalone]/core-framework/shared/util.lua"
luac5.4 -p "resources/[standalone]/core-framework/shared/money_aliases.lua"
luac5.4 -p "resources/[custom]/custom-market/fxmanifest.lua"
luac5.4 -p "resources/[custom]/custom-main/fxmanifest.lua"
luac5.4 -p "resources/[custom]/custom-cartel/fxmanifest.lua"
luac5.4 -p "resources/[custom]/custom-security/fxmanifest.lua"
luac5.4 -p "resources/[custom]/custom-crime/fxmanifest.lua"
luac5.4 -p "resources/[custom]/custom-phone/fxmanifest.lua"
luac5.4 -p "resources/[custom]/custom-quest/fxmanifest.lua"
luac5.4 -p "resources/[custom]/custom-taxes/fxmanifest.lua"
luac5.4 -p "resources/[custom]/custom-market/server/main.lua"
luac5.4 -p "resources/[custom]/custom-phone/client/main.lua"
```

`$%d` 基线检查：

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/architecture/test_money_format.py -q
# 期望：绿；money_format_baseline.json 的 total=59
```

#### 4.7.4 登记表/预算同步

| 文件 | 改动方向 | 说明 |
|---|---|---|
| `money_format_baseline.json` | 收紧 | 删 7 条（market main 6 + phone client 1）；`total` 66→59；`owner/expires` 不变 |
| `reuse_budget.json` | **不改** | `Money` 5 字符 < `MIN_NAME_LEN=6`；`PhoneMoney`/`QuestMoney`/`TCMoney` 各 1 份 < 4；加条目会被判「已不再重复」 |
| `gate_coverage_budget.json` | 不改 | +0（见 §4.7.5） |
| `io_budget.json` | 不改 | 没有新增广播/轮询/DB；`FormatMoney` 是纯函数 |
| `net_events_allowlist.json` | 不改 | 0 个新 net event |
| `service_contracts.json` | 不改 | `FormatMoney` 是静态导出，S1 闸门从代码推导 |

#### 4.7.5 闸门覆盖率记账

- 新增 **2 条前向规则**（`test_money_format_has_a_single_implementation`、
  `test_money_alias_users_load_the_alias_file`）+ 1 条反向。
- 选 **(a)**，两条变异用例：
  - 注入 **resources/[custom]/custom-vehicles/server/__mutant_money_format.lua**，
    内容 `local function PhoneMoney(v) local n=tonumber(v); if n%1==0 then return ('%d'):format(n) end; return ('%.2f'):format(n) end`；
    gate 指向 `test_money_format_has_a_single_implementation`；
  - 注入 **resources/[custom]/custom-vehicles/server/__mutant_money_alias.lua**，
    内容 `CreateThread(function() print(Money(1)) end)`（该资源 manifest 不含别名文件）；
    gate 指向 `test_money_alias_users_load_the_alias_file`。
- 增量 **+0**。若不加变异，则 +2（280），`history` 写
  `date=2026-11-15 / previous=278 / why="新增金额格式化单一实现与别名接线前向规则" / 到期条件="补变异用例后降回 278"`。

#### 4.7.6 CHANGELOG + 文档

- `CHANGELOG.md` → `### Changed`：
  「`FormatMoney` 合并 8 份 `[custom]` 金额格式化实现；8 个 shared/money_format.lua
  删除，四个别名只在 core-framework/shared/money_aliases.lua 定义一次并由各资源 include；
  `$%d` 基线 66→59（market main 6、phone client 1）。」
- `docs/engineering/REUSE.md`：本片不动。理由：§2 已写明「与业务无关的纯工具放
  `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua`，用 `exports` 暴露」；`FormatMoney` 是这条规则的直接应用，
  没有新规则要写。若评审要求登记当前状态，可在 §5 表加一行（不改变本片验收）。
- `docs/engineering/ARCHITECTURE.md`：本片不动（「改钱/物品」行已指向 `Player.Functions`/
  `TriggerReward`；金额显示不是写路径）。
- `T-CityLite.base/resources/[custom]/AGENTS.md`：本片不动。

#### 4.7.7 回滚

- `git revert <sha>` 足够；必须**同一 commit** 回滚 `money_format_baseline.json` 与代码，
  否则 `test_money_format.py` 会因「债已不在但基线还留着」红。
- 别名文件与 2 个调用点可分开回滚；回滚别名文件会让 8 个资源的调用点变成 nil 全局，
  必须连同各自的 fxmanifest include 一起回；基线不用动（`$%s` 仍是安全写法）。
- 无数据/迁移；金额显示变化只影响文案。
- 需要 `restart`：`core-framework`（shared/util.lua 改动，客户端需要 `refresh` 才能拿到新文件）、
  `custom-market`、`custom-phone`、`custom-main`、`custom-cartel`、`custom-security`、
  `custom-crime`、`custom-quest`、`custom-taxes`。
- **注意**：`T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua` 是 shared script；新增 `exports('FormatMoney')`
  后，已连接的客户端必须 `refresh` + 重连才会拿到新 util。按 REUSE.md §6 的真机步骤做。

#### 4.7.8 真机验证清单

| 触发步骤 | 期望现象 | 判定方式 | 标记 |
|---|---|---|---|
| 市场买卖一件带小数价格的物品 | 金额显示整数无小数点、小数两位；无 `number has no integer representation` | 客户端 UI 截图 + 服务端日志 | ⛔ 显示只能真机看 |
| 手机罚单/任务板显示金额 | 同上；`PhoneMoney`/`QuestMoney` 别名生效 | 手机截图 | ⛔ |
| 服务端控制台探针 `exports['core-framework']:FormatMoney(61.75)` / `(500)` / `('x')` | `'61.75'` / `'500'` / `'0'` | 控制台输出 | ✅ 服务端可判 |
| 客户端 F8 探针同上 | 客户端也能拿到 `FormatMoney` 导出 | F8 输出 | ⛔ 客户端导出只能真机 |
| 修一条 `$%d` 后跑 `test_money_format.py` | 基线双向相等；total=59 | pytest 输出 | ✅ 离线可判 |

---

### 4.8 S7 — 受众感知广播收口

**验收口径**：`T-CityLite.base/resources/[custom]/custom-police/server/evidence.lua` 的 9 处 `-1` 改为 `Broadcast.Scope`；
`[custom]` 内剩余 19 处 `-1` 全部在 `broadcast_allowlist.json` 有 `file/event/audience/reason/expires`；
平民客户端收不到证据事件，在岗警察能收到；`broadcast_sites` 预算下调。

#### 4.8.1 影响文件

| 动作 | 路径 |
|---|---|
| 新增 | **T-CityLite.base/resources/[standalone]/core-framework/server/broadcast.lua** |
| 修改 | `T-CityLite.base/resources/[standalone]/core-framework/fxmanifest.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/fxmanifest.lua` |
| 修改 | `T-CityLite.base/resources/[custom]/custom-police/server/evidence.lua` |
| 修改 | `T-CityLite.base/tests/architecture/test_evidence_authority.py` |
| 新增 | **T-CityLite.base/tests/architecture/test_broadcast_scope.py** |
| 新增 | **T-CityLite.base/tests/architecture/broadcast_allowlist.json** |
| 修改 | `tools/dev/gate_mutation_smoke.py` |
| 修改 | `T-CityLite.base/tests/architecture/io_budget.json` |
| 修改 | `CHANGELOG.md` |
| 修改 | `docs/engineering/ARCHITECTURE.md` |

删除：无。
11 文件。

#### 4.8.2 先红后绿

**红（commit 1：先建 allowlist 28 条，闸门绿；commit 2：删掉 evidence 9 条）**：
- 删除 `broadcast_allowlist.json` 里 `evidence.lua` 的 9 条后，
  `test_every_custom_broadcast_is_registered` 必须红在这 9 行：
  `evidence.lua:142,307,322,334,364,394,447,456,489`。
- 反向用例证明：合成 `TriggerClientEvent('probe:client:all', -1)` → 红。

**绿（commit 3：改 evidence + helper）**：
- 新增 **core-framework/server/broadcast.lua**：
```lua
Broadcast = Broadcast or {}

--- 按受众发客户端事件；未知/空受众返回 0，不抛错。
--- audience: { all = true } | { job = 'police', onduty = true } |
---           { source = src } | { coords = vec3, radius = 50 }
---@return number recipients
function Broadcast.Scope(eventName, audience, ...)
    if type(eventName) ~= 'string' or eventName == '' then return 0 end
    if type(audience) ~= 'table' then return 0 end

    if audience.all == true then
        TriggerClientEvent(eventName, -1, ...)
        return GetNumPlayerIndices and GetNumPlayerIndices() or 0
    end

    local targets = {}
    if audience.job then
        local QBCore = exports['qb-core']:GetCoreObject()
        targets = QBCore.Functions.GetPlayersByJob(audience.job, audience.onduty == true) or {}
    elseif audience.source then
        targets = { tonumber(audience.source) }
    elseif audience.coords and audience.radius then
        local origin = audience.coords
        local radius = tonumber(audience.radius) or 0
        for _, src in ipairs(GetPlayers()) do
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 and #(GetEntityCoords(ped) - origin) <= radius then
                targets[#targets + 1] = tonumber(src)
            end
        end
    end

    local sent = 0
    for _, src in ipairs(targets) do
        if src and src > 0 then
            TriggerClientEvent(eventName, src, ...)
            sent = sent + 1
        end
    end
    return sent
end
```
- `T-CityLite.base/resources/[custom]/custom-police/fxmanifest.lua` 的 `server_scripts` 顶部加
  `'@core-framework/server/broadcast.lua'`（在 @oxmysql/lib/MySQL.lua 之后）。
- `T-CityLite.base/resources/[standalone]/core-framework/fxmanifest.lua` 的 `server_scripts` 加 `'server/broadcast.lua'`。
- `evidence.lua` 的 9 处改为：
  - `142`：`Broadcast.Scope(removeEvent, { job = 'police', onduty = true }, id)`
  - `307`：`Broadcast.Scope('evidence:client:AddBlooddrop', { job = 'police', onduty = true }, bloodId, dna, blood, where)`
  - `322`：`Broadcast.Scope('evidence:client:AddFingerPrint', { job = 'police', onduty = true }, fingerId, fingerprint, where)`
  - `334/364`：`Broadcast.Scope('evidence:client:RemoveBlooddrop', { job = 'police', onduty = true }, id)`
  - `394`：`Broadcast.Scope('evidence:client:RemoveFingerprint', { job = 'police', onduty = true }, id)`
  - `447`：`Broadcast.Scope('evidence:client:AddCasing', { job = 'police', onduty = true }, casingId, weapon, where, serieNumber)`
  - `456/489`：`Broadcast.Scope('evidence:client:RemoveCasing', { job = 'police', onduty = true }, id)`
- `broadcast_allowlist.json` 保留其余 **19 处**（按 `file+event` 合并为 **13 条**），
  全部 `audience='all'` + `reason` + `expires='2027-03-31'`：
  - `T-CityLite.base/resources/[custom]/custom-vehicles/server/vehicle_state.lua` 2（氮气火焰）
  - `T-CityLite.base/resources/[custom]/custom-vehicles/server/main.lua` 3（被盗/驾驶模式）
  - `T-CityLite.base/resources/[custom]/custom-vehicles/server/dashboard_api.lua` 4（警笛/麦克风/锚定）
  - `T-CityLite.base/resources/[custom]/custom-police/server/main.lua` 3（`UpdateBlips`/`SetCopCount`）
  - `T-CityLite.base/resources/[custom]/custom-police/server/objects.lua` 2（`removeObject`/`SyncSpikes`）
  - `T-CityLite.base/resources/[custom]/custom-police/server/vehicle.lua` 1（直升机探照灯）
  - `T-CityLite.base/resources/[custom]/custom-phone/server/jobboard.lua` 3（新工作）
  - `T-CityLite.base/resources/[custom]/custom-cartel/server/drug_lab.lua` 1（突袭警报；建议下一轮改为 `{coords, radius}`）
- `io_budget.json`：`broadcast_sites` 从 152 调到实测值。预期 **144**
  （152 − 9 个 evidence + 1 个 `Broadcast.Scope({all=true})` 内部的 `-1`）；
  若 helper 用逐玩家发送实现 `{all=true}`，则 143。**只许下调**，以 `budget_probe.py --check` 实测为准。
- `T-CityLite.base/tests/architecture/test_evidence_authority.py:118` 现在断言
  `"TriggerClientEvent(removeEvent, -1, id)" in body`；同 PR 改成
  `"Broadcast.Scope(removeEvent, { job = 'police', onduty = true }, id)" in body`。
  这是行为断言更新，不是新闸门；不改会让 S7 的 pytest 红。

**闸门设计**（`test_broadcast_scope.py`，只写两个 `test_` 函数）：
1. `test_every_custom_broadcast_is_registered`（前向）：
   - 扫 `resources/[custom]/**/*.lua` 的 `TriggerClientEvent(<event>, -1, ...)`；
   - 每条必须在 `broadcast_allowlist.json` 有匹配 `file+event` 条目，且
     `audience/reason/owner/expires` 齐全；
   - 新未登记 → 红；登记项没有对应代码（死条目）→ 红；过期 → 红。
2. `test_reverse_unregistered_broadcast_is_rejected`（反向）：
   - 合成 `TriggerClientEvent('probe:client:all', -1)` → 必须报；
   - 合成注释里的 `-1` → 必须不报；
   - 合成 `Broadcast.Scope(...)` → 必须不报（helper 自身不是业务广播点）。

#### 4.8.3 验收命令

```powershell
Set-Location E:/T-City-abs/T-CityLite.base
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/architecture/test_broadcast_scope.py -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' -m pytest tests/unit tests/architecture -q
& 'C:\Users\swkgb\AppData\Local\Programs\Python\Python312\python.exe' tools/dev/budget_probe.py --check
luac5.4 -p "resources/[standalone]/core-framework/server/broadcast.lua"
luac5.4 -p "resources/[custom]/custom-police/server/evidence.lua"
```

#### 4.8.4 登记表/预算同步

| 文件 | 改动方向 | 说明 |
|---|---|---|
| **broadcast_allowlist.json** | 新增 | 13 条（覆盖 19 处）`[custom]` 全服广播；每条 `file/event/audience/reason/owner/expires` |
| `io_budget.json` | 收紧 | `broadcast_sites` 152→144（实测；只许下调） |
| `gate_coverage_budget.json` | 不改 | +0（见 §4.8.5） |
| `net_events_allowlist.json` | 不改 | 0 个新 net event；`Broadcast.Scope` 只发不收 |
| `reuse_budget.json` / `money_format_baseline.json` | 不改 | 与本片无关 |
| `service_contracts.json` | 不改 | `Broadcast` 是 server include，不是 export |

#### 4.8.5 闸门覆盖率记账

- 新增 **1 条前向规则**（`test_every_custom_broadcast_is_registered`）+ 1 条反向。
- 选 **(a)**：变异用例注入 **resources/[custom]/custom-vehicles/server/__mutant_broadcast.lua**，
  内容 `TriggerClientEvent('probe:client:all', -1)`；
  gate 指向 `test_every_custom_broadcast_is_registered`。
- 增量 **+0**。若不加变异，则 +1（279），`history` 写
  `date=2026-11-15 / previous=278 / why="新增受众广播登记前向规则" / 到期条件="补变异用例后降回 278"`。

#### 4.8.6 CHANGELOG + 文档

- `CHANGELOG.md` → `### Security`：
  「证据广播按受众收口：`evidence.lua` 的 9 处 `-1` 改为 `Broadcast.Scope`，
  DNA/血型/指纹/弹壳只在岗警察可见；`[custom]` 剩余 19 处全服广播登记
  `broadcast_allowlist.json`（含 owner/expires）。」
- `docs/engineering/ARCHITECTURE.md` §3 加一行：
  | 跨资源/全服广播 | `Broadcast.Scope(event, audience, ...)`（server include） | `TriggerClientEvent(event, -1, ...)`（未登记会被闸门拦） |
  并在 §4 加一句：「`broadcast_allowlist.json` 是债务清单，不是白名单；新增 `-1` 必须登记。”
- `docs/engineering/REUSE.md`：本片不动（Broadcast 是广播收口，不是同名实现合并）。
- `T-CityLite.base/resources/[custom]/AGENTS.md`：本片不动。

#### 4.8.7 回滚

- `git revert <sha>` 足够；无数据/迁移。
- 按事件回滚：`evidence.lua` 的 9 处可以一次性回滚；`broadcast_allowlist.json` 必须同 commit
  恢复 evidence 9 条 + `io_budget.json` 恢复 152，否则闸门/预算红。
- 行为变化：证据（血滴/指纹/弹壳）从「全服可见」变为「在岗警察可见」。这是安全修复；
  如果玩法要求平民看到自己的弹壳，需要产品决策后改为 `{source=src}` + 警察双受众，
  不在本片默认范围。
- 需要 `refresh` + `restart`：`core-framework`（新增 server/broadcast.lua）、`custom-police`。
- `io_budget.json` 的 `broadcast_sites` 回滚会调高，`budget_probe --update` 本身拒绝调高；
  `git revert` 直接恢复文件，不算 `--update`。回滚后重跑 `test_budget.py` 确认。

#### 4.8.8 真机验证清单

| 触发步骤 | 期望现象 | 判定方式 | 标记 |
|---|---|---|---|
| 1 名在岗警察 + 1 名平民；平民制造血滴/指纹/弹壳 | 警察客户端收到 `evidence:client:AddBlooddrop`/`AddFingerPrint`/`AddCasing`；平民**收不到** | 两个客户端 F8 事件日志 / 临时 debug print / 截图 | ⛔ 平民收不到只能双客户端验 |
| 警察拾取证据 / TTL 到期 / 清场 | 警察客户端移除对应标记；平民没有残留 | 两个客户端截图 | ⛔ |
| 触发 `police:SetCopCount` / `UpdateBlips` | 所有客户端仍收到（登记为 `all`，行为不变） | 两个客户端 F8 | ⛔ |
| 触发车辆氮气/被盗/驾驶模式 | 所有客户端仍收到（登记为 `all`） | 两个客户端 F8 | ⛔ |
| 跑 `test_broadcast_scope.py` + `budget_probe --check` | 闸门绿；`broadcast_sites ≤144` | pytest/工具输出 | ✅ 离线可判 |

---

## 5. 执行顺序与依赖图

```
S1  (导出契约闸门 + 11 个死调用 + 1 个兜底)
├─> S2a (Bus: 场景/作业/车辆 + 闸门) ──> S2b (Bus: 税/热度/通知 + owner 导出)
├─> S3  (限流收口) ──> S4 (Db 适配器) ──> S7 (证据广播)
├─> S5  (LoadModel)
└─> S6  (FormatMoney)
```

**必须串行的原因**（都是同一文件的 hunk 冲突，不是逻辑依赖）：

| 顺序 | 同一文件 | 冲突点 |
|---|---|---|
| S1 → S2a | `T-CityLite.base/resources/[qb]/qb-storerobbery/server/main.lua` | S1 改 446/674，S2a 改 552 |
| S1 → S2b | `T-CityLite.base/resources/[custom]/custom-taxes/server/item_durability.lua` | S1 改 120/160，S2b 改 149-155 |
| S1 → S2b | `service_contracts.json` | S1 生成，S2a/S2b 收紧 |
| S2a → S2b | **T-CityLite.base/tests/architecture/test_bus_scope.py** | S2b 加扫描根；S2a 的闸门必须先绿 |
| S2a → S3 | `T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua` | S2a 改 1904-1908，S3 改 556/763 |
| S3 → S4 | `T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua` | S3 改 469-483，S4 改 372/549 |
| S4 → S7 | `T-CityLite.base/resources/[standalone]/core-framework/fxmanifest.lua` | 两边都在 `server_scripts` 加一行；S4 先 |
| 所有片 | `tools/dev/gate_mutation_smoke.py` | 每片在文件尾部追加一条 `Mutation`；按合并顺序解决冲突，不要并行改同一段 |
| S2b → S5 | `docs/engineering/REUSE.md` | S2b 加 Bus 规则，S5 加 LoadModel 行 |
| S1 → S6 | `T-CityLite.base/resources/[custom]/custom-phone/client/main.lua` | S1 改 `:1016` 的 `GetLocalIdentity`，S6 改 1 处 `$%d`；S1 先 |
| S1 → S6 | `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua` 的导出契约 | S1 的闸门要能解析 `FormatMoney`（静态导出，无 JSON 改动） |

**可以并行开发**：S2a、S3、S5、S6、S7 的代码互不依赖（除上表同文件），可以开分支并行；
合并顺序按上面的箭头。**不要**同时开两个改同一文件的 PR。

**合并前每个 PR 的自检**：
1. `pytest tests/unit tests/architecture -q` 绿；
2. 本片的新闸门 + 反向用例绿；
3. 本片的 `gate_mutation_smoke.py --only <gate>` 注入红、对照绿；
4. `release_check.py` exit 0；
5. `luac5.4 -p` 所有改过的 Lua；
6. PR 描述贴「红→绿」两段真实输出。

---

## 6. 全局退出条件（8 片全做完后的数字）

> 以下命令都在 `E:/T-City-abs` 下运行；解释器用 §2.1 的绝对路径。

| # | 判据 | 期望 |
|---|---|---|
| G1 | `pytest tests/unit tests/architecture -q` | exit 0，0 failed |
| G1b | `pytest tests/agent -q` | exit 0（S3/S4/S7 改了 agent case，必须单独跑） |
| G2 | `pytest tests/architecture/test_gate_coverage.py -q` | exit 0；`gate_coverage.py --json` 的 `unproven ≤ 278` |
| G3 | `gate_mutation_smoke.py` | exit 0；S1/S2a/S3/S4/S5/S6/S7 的 7 条新用例都「会红 ✓」 |
| G4 | `release_check.py` | exit 0；无过期 `expires`、无凭据 |
| G5 | `budget_probe.py --check` | exit 0；`broadcast_sites ≤ 144`、`db_call_sites ≤ 465`、`fast_polling_loops ≤ 2` |
| G6 | `test_money_format.py` | 绿；`money_format_baseline.json` 的 `total=59` |
| G7 | `test_net_event_inventory.py` | 绿；net event 总数/未登记数与基线一致（0 新事件） |
| G8 | `test_resource_wiring.py` | 绿；**core-framework/server/db.lua**、server/broadcast.lua、3 个 **@core-framework/server/db.lua** 条目都在 |
| G9 | `test_plane_boundaries.py` | 绿；`db.lua`/`broadcast.lua` 只在 server；shared/money_format.lua 门面不含 API |
| G10 | `test_docs_links.py` | 绿；本文件所有反引号路径都存在 |
| G11 | 死调用 grep | `rg "exports\['(custom-main|custom-economy)'\]:(AddScaledMoney|CheckRateLimit|GetEconomyRewardScale)|exports\['qb-inventory'\]:SetItemInfo|exports\['custom-career'\]:GetLocalIdentity" T-CityLite.base/resources --glob '*.lua' --glob '!**/tests/**' --glob '!**/custom-testing/**'` → 0 |
| G12 | Bus 跨资源读取 | `test_bus_scope.py` 绿；扫描根内 0；owner 侧 `Bus.RegisterService` 仍保留 |
| G13 | 限流 | `test_rate_limit_single_owner.py` 绿；8 个文件在 `CALLERS`；`IMPL_MARKERS` 无命中 |
| G14 | DB 归一化 | `test_db_result_adapter.py` 绿；`[custom]`/core-framework 内 `type(x)=='table'` + `insertId/affectedRows` 只出现在 `db.lua`（`[qb]` 上游除外） |
| G15 | LoadModel | `test_load_model_single_owner.py` 绿；7 个调用文件有 `CFShared.LoadModel`；`entity_util.lua` 无本地实现 |
| G16 | FormatMoney | `test_money_format_single_owner.py` 绿；别名只在 `money_aliases.lua` 一份；每个调用点的 manifest 有 include；`$%d` 59 |
| G17 | 广播 | `test_broadcast_scope.py` 绿；`[custom]` 的 19 处 `-1`（13 条）全部登记 |
| G18 | 真机 | §4 各片 ⛔ 行有证据；未完成的在 `CHANGELOG.md`/Issue 里写 owner + expires |

**收敛数字对照**：

| 指标 | 收敛前 | 收敛后 | 证据 |
|---|---|---|---|
| 真实死调用 | 11 | 0 | `test_service_contracts.py` + G11 |
| `service_*` 外部调用点 | 33 | 33（不改名，但全部有契约） | `service_contracts.json` |
| 跨资源 Bus 读取 | 15 点 / 11 文件（报告口径） | 0（扫描根内） | `test_bus_scope.py` |
| 本地限流表/桶 | 9 表 / 8 文件 | 0（全部走 `RateLimit`） | `test_rate_limit_single_owner.py` |
| DB 归一化实现 | 6 | 1（`db.lua`） | `test_db_result_adapter.py` |
| 本地 `LoadModel` 循环 | 4（2 个无超时） | 0 | `test_load_model_single_owner.py` |
| 金额格式化实现 | 8 `[custom]` | 1（`FormatMoney`）+ 1 个别名文件（4 个名字） | `test_money_format_single_owner.py` |
| `$%d` 基线 | 66 | 59 | `money_format_baseline.json` |
| `[custom]` 的 `-1` | 28 | 19（全部登记） | `broadcast_allowlist.json` |
| `broadcast_sites` | 152 | ≤144（实测） | `io_budget.json` + `budget_probe --check` |
| `max_unproven` | 278 | ≤278 | `gate_coverage.py --json` |
| net events | 基线 | 不变（0 新） | `test_net_event_inventory.py` |

> 注意：`reuse_scan --min 3` **不能**用来证明 `Money`/`LoadModel` 收敛（见 §0.2）。
> 它的输出只作为旁证；真正的判据是 G16/G15。

---

## 7. 架构对照（template §4）

### 7.1 涉及平面

| 片 | 平面 | 说明 |
|---|---|---|
| S1 | P2 + P3 + 测试 | 11 个服务端调用点 + 1 个客户端兜底（`T-CityLite.base/resources/[custom]/custom-phone/client/main.lua`）；无 P1 |
| S2a | P3 + P0（Bus 注释） | `contracts.lua` 是服务端注册；`Bus` 仍是 shared script（P0 副作用），但本片不加新副作用 |
| S2b | P3 | qb-core owner 导出 + 调用点 |
| S3 | P3 | 限流 owner + 服务端入口 |
| S4 | P3 + P0（`insert_id.lua` 是 shared 文件但只在 server 加载） | `db.lua` 必须放 `server/`；`insert_id.lua` 从 shared 移到 server 加载 |
| S5 | P2 | 客户端模型加载；不改服务端 |
| S6 | P0 + P2 | `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua` 是 P0 纯函数；8 个 manifest include 是 P0；`T-CityLite.base/resources/[custom]/custom-phone/client/main.lua` 是 P2 |
| S7 | P3 + P0（`broadcast.lua` 是 server include） | 只改服务端收件人；无 P1 |

### 7.2 跨平面契约变化

| 类型 | 旧 | 新 | 影响方 |
|---|---|---|---|
| 导出 | 5 个占位 `service_*`（reputation/chronicle/governance/cosmetics/funnel） | 删除 | 0 个外部调用点 |
| 导出 | `service_dealership_*` 只在文档里 | 8 个真实静态导出 | qb-vehicleshop 内部/未来调用方 |
| 导出 | 无 `SinkWithdraw`/`HeatReset` | `qb-core:SinkWithdraw`、`qb-core:HeatReset` | custom-taxes、production-freeze |
| 导出 | 无 `FormatMoney` | `core-framework:FormatMoney`（两端） | 8 个 `[custom]` 资源（include 别名文件） |
| 错误码 | Db 调用方各自 `tonumber(...) or 0` | `nil, 'db_error'` / `nil, 'no_insert_id'` | director/phone/police 调用方 |
| 事件 | 无新 net event | 无 | 无 |
| 广播 | `TriggerClientEvent(..., -1)` | `Broadcast.Scope(event, audience, ...)` | custom-police evidence |

### 7.3 宪法对照

| 条款 | 本计划怎么满足 |
|---|---|
| ① 服务端权威 | S7 把证据广播从「所有客户端」收到「在岗警察」；S1 修掉卖物品/奖励的静默失败 |
| ② 钱/物品唯一出口 | S1 把钱调用迁回 `Player.Functions.AddMoney`/`core_economy:GetGlobalMultiplier`；S2b 税走 qb-core `SinkWithdraw`（内部仍走 `RemoveMoney`）；没有新增第二写路径 |
| ③ SQL 参数化 | S4 不拼 SQL；`Db` 只做结果适配；`test_query_discipline.py` 保持绿 |
| ④ net event 鉴权/登记 | 本计划 0 个新 net event；`Broadcast.Scope` 只发不收 |
| ⑤ 幂等 | S4 修掉「`affectedRows` 当 id」的错误 id/幂等风险；无迁移 |
| ⑥ 表唯一 owner | S2b 的 Sink/Heat 仍在 qb-core；S4 不新增写路径 |
| ⑦ 诊断不落 PII | S7 反而减少 PII 广播；S5 的失败上报只带模型名，不带玩家数据 |
| ⑧ 一次一个平面 | 每片只动一个平面为主；跨平面（S1 的 P2 兜底、S6 的 P0+P2）在 PR 里显式声明 |
| ⑨ 没有测试不算完成 | 每片先红后绿 + 反向/变异用例；G1–G18 |
| ⑩ 交付三件套 | 每片 `CHANGELOG.md` + 文档判断；`release_check.py` |

---

## 8. 风险

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| S1 闸门对动态导出误报（qb-core/qb-fuel/custom-vehicles） | 中 | 闸门红，阻塞合并 | `dynamic_exports` 登记 + 反向用例证明「动态资源不按方法名逐个列」；33 个真实调用点人工复核 |
| S1 把卖物品改成 `Player.Functions.AddMoney` 后金额语义变化 | 低 | 玩家少拿/多拿 | 卖物品不走倍率；`totalPrice` 原样；真机对 DB 前后 |
| S2a BGM 从「不播」变「播」 | 高（预期） | 观感变化/音量 | 真机听至少 1 条路径；scene ID 用现有 `service_atmosphere_PlayScene` 的参数 |
| S2b 税从「部分不扣」变「扣」 | 高（预期） | 玩家钱变少 | 测试服先公告；按文件回滚；`SinkWithdraw` 失败时保留 fallback |
| S3 冷却从秒变毫秒/从 cid 变 src | 中 | 限流边界变化/重连绕过 | cid 键保留 cid；src 键用 `playerDropped` 清；真机连续触发验证 |
| S4 `Db` 错误语义变化 | 中 | 调用方把 `nil` 当 0 | 单测 4 形状；调用方保留 `affected or 0`；真机 DB 写 |
| S4 3 个 fxmanifest 加 include 顺序错 | 低 | `Db` 未定义 | include 放在 `@oxmysql` 之后、所有业务 server 脚本之前；`test_resource_wiring` 校验文件存在 |
| S5 超时从 5s/无超时变 10s | 低 | 模型加载慢时行为变化 | 显式传 5000/10000；真机缺失模型 |
| S6 别名在 core-framework 未启动时返回 `'0'` | 低 | 金额显示 0 | core-framework 在启动集；别名 `GetResourceState` 判断；真机客户端/服务端探针 |
| S6 `T-CityLite.base/resources/[standalone]/core-framework/shared/util.lua` 新增导出需要 `refresh` | 中 | 已连接客户端拿不到 `FormatMoney` | 按 REUSE.md §6：`refresh` + `restart` + 重连；F8 自证 |
| S7 证据对平民不可见改变玩法 | 中 | 平民看不到弹壳/血滴 | 先在测试服双客户端验证；如果产品要求平民可见，改为 `{source=src}` + 警察双受众，单独 PR |
| S7 `broadcast_sites` 预算回滚失败 | 低 | `test_budget.py` 红 | 回滚用 `git revert` 恢复 152；不要用 `budget_probe --update` 调高 |
| 跨片同文件合并冲突 | 中 | PR 冲突 | 按 §5 的串行顺序合并；不要同时开两个改同一文件的 PR |
| 实施时误改热狗文件 | 低 | 与另一条任务冲突 | S5 明确不碰 `quest_hotdog_*`；闸门只抓无退出条件的循环 |

---

## 9. 测试计划

### 9.1 新增/修改的测试文件

| 片 | 文件 | 类型 | 关键断言 |
|---|---|---|---|
| S1 | **T-CityLite.base/tests/architecture/test_service_contracts.py** | 架构闸门 | 12 个调用（11 死调用 + 1 兜底）红→绿；反向 3 形状；动态/外部 allowlist |
| S2a | **T-CityLite.base/tests/architecture/test_bus_scope.py** | 架构闸门 | 4 个扫描根 0 个跨资源 Bus 读取；注册资源必须加载 Bus；反向 2 形状 |
| S2b | 同上（扩扫描根） | 架构闸门 | 5 类 `_G.Bus` 读取红→绿 |
| S3 | `T-CityLite.base/tests/architecture/test_rate_limit_single_owner.py` | 扩现有闸门 | `IMPL_MARKERS` 7 别名；`CALLERS` 8 文件；反向 `liveBuckets`/`backupCooldown` |
| S4 | **T-CityLite.base/tests/architecture/test_db_result_adapter.py** | 架构闸门 + Lua 单测 | 归一化只在 `db.lua`；4 种返回形状；`affectedRows` 不当 id |
| S4 | `T-CityLite.base/tests/unit/layer3_business/test_phone_db_contract.py` | 修改现有 Lua harness | 先加载 `db.lua`；`PhoneDb` 契约仍绿 |
| S4 | `T-CityLite.base/tests/agent/lua/cases/police_outbox.lua` | 修改现有 Lua case | 先加载 `db.lua`；outbox case 仍绿 |
| S5 | **T-CityLite.base/tests/architecture/test_load_model_single_owner.py** | 架构闸门 | 8 文件走 `CFShared.LoadModel`；无无超时循环；反向 2 形状 |
| S6 | **T-CityLite.base/tests/architecture/test_money_format_single_owner.py** | 架构闸门 | 8 个旧门面不许回来；别名只在 `money_aliases.lua`；调用点 manifest 必须 include；反向 3 形状 |
| S6 | `T-CityLite.base/tests/architecture/test_money_format.py` | 现有闸门 | `$%d` 基线 66→59，双向相等 |
| S6 | `T-CityLite.base/tests/unit/layer3_business/test_money_renderers.py` | 修改现有 Lua harness | 先加载真实 `FormatMoney` + 可调用/可索引 `exports`，再 dofile `money_aliases.lua`；4 个别名 × 9 组输入 |
| S7 | **T-CityLite.base/tests/architecture/test_broadcast_scope.py** | 架构闸门 | 9 处 evidence 红→绿；13 条（19 处）登记；死条目/过期红 |
| S7 | `T-CityLite.base/tests/architecture/test_evidence_authority.py` | 修改现有静态断言 | `:118` 的 `TriggerClientEvent(removeEvent, -1, id)` 改为 `Broadcast.Scope(...)` |
| 全部 | `tools/dev/gate_mutation_smoke.py` | 变异用例 | 7 条新用例注入红、对照绿 |

### 9.2 反向校验（错误形状 → 必须红）

| 片 | 注入的错误形状 | 期望 |
|---|---|---|
| S1 | `exports['custom-main']:AddScaledMoney(1,'cash',1,'probe')` | `test_every_export_call_resolves` 红 |
| S1 | 注释/字符串里的同名调用 | 不红（剥注释/字符串） |
| S2a | `Bus.storage.CanAccess(1, 'org')` | `test_no_cross_resource_bus_reads` 红 |
| S2a | `Bus.RegisterService('probe', {...})` 但 manifest 无 Bus | 红 |
| S3 | `local liveBuckets = {}` | `test_no_new_rate_limiter_grows` 红 |
| S3 | `local backupCooldown = {}` | 同上 |
| S4 | `local id = type(res)=='table' and (res.affectedRows or res[1]) or res` | `test_result_normalisation_only_in_db_adapter` 红 |
| S5 | `RequestModel(hash); while not HasModelLoaded(hash) do Wait(10) end` | `test_no_local_loadmodel_loops` 红 |
| S5 | 带 `deadline` 的循环 | 不红 |
| S6 | `local function PhoneMoney(v) ... % 1 ... %.2f ... end` | `test_money_format_has_a_single_implementation` 红 |
| S6 | 只转调 `FormatMoney` 的别名文件 / 文件内 `local` 委托 | 不红 |
| S7 | `TriggerClientEvent('probe:client:all', -1)` | `test_every_custom_broadcast_is_registered` 红 |
| S7 | 注释里的 `-1` | 不红 |

### 9.3 真机验证

见 §4 各片「真机验证清单」。汇总的 ⛔ 项（只能用真机验）：

1. **S1**：当铺卖物品钱是否到账、抢劫奖励是否发放、武器耐久是否更新、qb-drugs 卖货钱是否到账。
2. **S2a**：追车/重生/抢劫的 BGM 是否真的播放；二手车估值是否返回状态。
3. **S2b**：大额转账/房产/维修税是否真的扣、是否进 sink；手机银行转账是否双方到账；
   `QBCore:Notify` 是否仍然显示。
4. **S3**：连续触发限流入口是否在阈值处拒绝；玩家下线重连后冷却是否清掉；
   director live API 是否返回 429。
5. **S4**：director `agent_actions` 的 id 是否正确；phone/police 写库是否用对 id。
6. **S5**：模型缺失时客户端是否不卡死；`CFShared.Report` 是否只报一条。
7. **S6**：market/phone/quest/taxes 的金额显示是否正确；客户端 `FormatMoney` 导出是否可用。
8. **S7**：**平民客户端能否收到证据事件**（必须用 2 个客户端）；警察是否收到；
   全服广播（SetCopCount/车辆同步）是否仍然所有客户端可见。

### 9.4 测试 harness 兼容清单（实施时以 pytest 红名单补齐）

仓库里很多业务单测用 `lua5.4` **真加载**资源源码，只 stub 掉 `MySQL`/`QBCore`/原生。
本计划把调用改成 `exports[...]`/`Db`/`Broadcast` 后，这些 harness 需要 1–3 行 stub，
否则全量 pytest 会红。**只补 stub 的 harness 不计入 §3 的运行时文件数，但必须在同一 PR 里改**；
S4 的 2 个「必须先加载 db.lua」的 harness 已经计入 S4 的 19 文件。
下表是已知清单，最终以 `pytest tests/unit tests/architecture tests/agent` 的红名单为准。

| 片 | 已知 harness / fixture | 需要的 stub |
|---|---|---|
| S1 | `T-CityLite.base/tests/unit/layer3_business/fixtures/pawnshop_probe.lua`、`storerobbery_probe.lua`、`weed_probe.lua`、`weapons_probe.lua` 及对应测试 | `exports['custom-security']`/`exports['core_economy']`/`exports['qb-inventory']` 的方法桩（返回 true 或固定值） |
| S1 | `T-CityLite.base/tests/unit/layer3_business/test_pawnshop_multicharacter_guards.py`、`test_storerobbery_crypto_guards.py`、`test_weed_guards.py`、`test_weapon_repair_authority.py` | 如果测试本身拼 Lua，补 `exports` 表；如果走 fixture，改 fixture。`T-CityLite.base/tests/architecture/test_crime_feedback_contract.py` 是静态读文本，不需要 stub |
| S1 | `T-CityLite.base/tests/unit/layer3_business/test_phone_client_core.py` | `exports['custom-career']:GetPlayerIdentity` 桩（返回 `{ rank_tier = 'leader', primary_role = 'x' }`）；以 pytest 红名单为准 |
| S2b | `T-CityLite.base/tests/unit/layer3_business/fixtures/weapons_probe.lua`/`test_weapon_repair_authority.py`、`shops_probe.lua`/`test_shops_guards.py` | `exports['qb-core']:SinkWithdraw`、`exports['core_economy']:GetGlobalMultiplier` 的方法桩；`Player.Functions.RemoveMoney` fallback 保留 |
| S3 | `T-CityLite.base/tests/unit/layer3_business/test_police_alert_dispatch.py`、`test_police_claim_and_arrival.py`、`T-CityLite.base/tests/unit/layer1_core/test_police_evidence_create.py` | `exports = { ['core-framework'] = { RateLimitCooldown = function() return true end, RateLimitReset = function() end } }`；架构测试 `test_police_forensics.py`、`test_police_tow.py`、`test_police_coroner.py` 只查常量名，常量保留即可 |
| S3 | `T-CityLite.base/tests/agent/lua/cases/police_system.lua`、`police_backup.lua`、`live_api.lua`、`live_roster_refresh.lua` | agent bootstrap 的 `env.exports` 加 `core-framework` 的 `RateLimitCooldown/TokenBucket` 桩 |
| S4 | `T-CityLite.base/tests/unit/layer3_business/test_police_records.py`、`test_police_citations.py`、`test_police_evidence_writer.py`、`test_police_claim_and_arrival.py`、`test_police_alert_dispatch.py`、`test_police_read_exports.py`、`T-CityLite.base/tests/unit/layer1_core/test_world_traces.py` | `dofile(db.lua)` 或 `Db = { Update = function(sql, params) return 1 end, InsertId = function(v) return tonumber(type(v)=='table' and v.insertId or v) or 0 end }` |
| S4 | `T-CityLite.base/tests/unit/layer3_business/test_director_rules.py`、`test_agent_actions.py`、`T-CityLite.base/tests/unit/test_director_http_contract.py` | `Db.Insert/Db.Update` stub 或 `dofile(db.lua)`；这些 harness 已有 MySQL 桩 |
| S4 | `T-CityLite.base/tests/unit/layer3_business/test_phone_db_contract.py` | 先 `loadfile(db.lua)` 再 `loadfile(sms.lua)`（本片必改） |
| S4 | `T-CityLite.base/tests/agent/lua/cases/police_outbox.lua`、`police_system.lua`、`police_backup.lua` | 先 `dofile(db.lua)`；或给 `Db.InsertId/Db.Update` 桩 |
| S4 | `T-CityLite.base/tests/unit/layer3_business/test_phone_apps.py`（静态断言） | `insert_id.lua` 保留含 `insertId` 的注释即可，不改测试 |
| S7 | `T-CityLite.base/tests/unit/layer1_core/test_police_evidence_create.py`、`T-CityLite.base/tests/architecture/test_evidence_authority.py`、`T-CityLite.base/tests/unit/layer2_engine/test_evidence_casing_hint.py` | `Broadcast = { Scope = function() return 0 end }`；`test_evidence_authority.py:118` 的静态断言改成 `Broadcast.Scope`；`test_evidence_casing_hint.py` 只读文本，不需要执行 |
| S5 | 客户端文件没有同类的「真加载服务端源码」harness；只需 `CFShared` stub（已有 `CFShared` 的资源不需要） | 以 `pytest tests/unit tests/architecture` 红名单为准 |
| S6 | `T-CityLite.base/tests/unit/layer3_business/test_money_renderers.py` | 先定义可调用/可索引的 `exports` 表 + `dofile(core-framework/shared/util.lua)`，再 dofile `money_aliases.lua`（4 个别名）；见 §4.7.2 |

> 规则：**先跑全量，再补 stub**。不要把 stub 写成第二份实现——只返回固定值/成功，
> 不复制限流/DB 归一化逻辑；否则新闸门会把它当成第二份实现。

### 9.5 不需要真机的部分

- S1/S3/S4/S6 的静态闸门、Lua 单测、预算检查、`release_check.py`；
- S2 的 `BusStatus`/`service_dealership_*` 控制台探针；
- S7 的 allowlist/io_budget 静态检查。

---

## 10. 回滚总则（template §5）

| 片 | 代码回滚 | 数据/迁移 | 运行时 |
|---|---|---|---|
| S1 | `git revert <sha>`；可拆两个 commit（闸门/修复） | 无 | `restart` 7 个资源 |
| S2a | `git revert <sha>`；按文件回滚也安全 | 无 | `restart` core-framework/custom-police/ambulance/storerobbery/vehicleshop |
| S2b | `git revert <sha>`；qb-core 导出可保留 | 无 | `restart` qb-core + 5 个调用资源；qb-core 重启会级联，按 resync 脚本拉起 |
| S3 | `git revert <sha>`；按文件回滚 | 无 | `restart` core-framework/custom-police/custom-director |
| S4 | 按批 revert（director/phone/police）；`db.lua` 可保留；测试 harness 与调用方同 commit 回滚 | 无 | `refresh` + `restart` core-framework/custom-director/custom-phone/custom-police |
| S5 | 按资源 revert | 无 | `restart` custom-police/custom-cartel/custom-quest（客户端） |
| S6 | **同一 commit** 回滚代码 + 基线 | 无 | `refresh` + `restart` core-framework + 8 个资源；已连接客户端需重连 |
| S7 | 按事件 revert；allowlist/io_budget 同 commit 恢复 | 无 | `refresh` + `restart` core-framework/custom-police |

**共同点**：本计划没有 DB 迁移、没有表结构变更、没有不可逆数据写入。唯一的行为不可逆是
「税开始真的扣」「证据不再全服可见」——这两项上线前要在测试服公告；真回滚只需 revert 代码。

---

## 11. 交付检查单（template delivery）

每个 PR 合并前：

- [ ] 代码/测试/文档/`CHANGELOG.md` 四件套齐全；
- [ ] 引用路径真实存在（`pytest tests/architecture/test_docs_links.py -q`）；
- [ ] `release_check.py` exit 0（无凭据、无过期条目）；
- [ ] 本片登记表/预算按 §4.x.4 更新，方向正确（只许收紧）；
- [ ] `gate_coverage_budget.json` 的 `max_unproven` 与 §4.x.5 的记账一致；
- [ ] 新增/修改的 Lua 全部 `luac5.4 -p`；
- [ ] 新增文件已进 fxmanifest（`test_no_orphan_scripts.py`/`test_resource_wiring.py`）；
- [ ] 新闸门的反向/变异用例在 PR 里贴了「注入红、撤回绿」输出；
- [ ] 真机清单的 ⛔ 行有证据，或写了 owner + expires；
- [ ] PR 描述写了 `gate-change:`（如改了预算/allowlist）。

---

## 附录 A：报告 §6「明确不做」14 条摘要（完整表述与理由见 §1.2）

1. 合并 `DebugPrint` —— REUSE.md 已定案：同名不同语义，各带调试开关/前缀。
2. 合并 `[qb]`/`[standalone]` 的重复 —— REUSE.md 已定案：不迁上游/第三方。
3. 再合并 `DrawText3D` —— 已合并到 `CFShared.DrawText3D`。
4. 把业务冷却并进 `RateLimit` —— `quest_cooldowns` 是持久化状态，语义不同。
5. 合并通知封装 —— 三种通道语义不同，合并会改观感/延迟。
6. 合并权限检查 —— `QBCore.Functions.HasPermission` 是 owner；域内策略不同。
7. 全仓抽 `GetCoreObject` 重试样板 —— 18/19 是 `[qb]` 上游；为 2 个调用点造抽象不值得。
8. 抽通用 `Cache` —— 各资源 TTL/失效键不同，没有统一契约。
9. 合并进度条 option 表 —— 那是调用参数，不是实现。
10. 复活 `custom-economy` 的 server —— 被 `core_economy` 取代是正确方向。
11. 把 `players.money` 的写路径迁到 core-framework —— 宪法② owner 是 qb-core。
12. 为跨资源服务调用新增 net event —— 会绕开 exports 契约与 net event 登记。
13. 把 `Bus` 做成真正的 `_G` 全局总线 —— 跨资源 `_G` 不共享。
14. 合并 qb-drugs 的 `Money()` —— `[qb]` 上游，REUSE.md 不迁。

## 附录 B：报告 §6 的 3+4 件事 → 本计划分片

| 报告 | 本计划 | 说明 |
|---|---|---|
| 第 1 件：契约闸门 + 死调用 | S1 | 11 个真实调用 + 1 个兜底（报告 13 的口径修正见 §0.2） |
| 第 2 件：退役跨资源 Bus | S2a + S2b | 场景/作业/车辆 vs 税/热度/通知；每片 ≤13 文件 |
| 第 3 件：限流收口 | S3 | 8 文件/9 表 + marker 扩展 |
| 下一批 4：Db 适配器 | S4 | adapter + 6 个归一化点；quest/story 回调风格见 §1.3 |
| 下一批 5：LoadModel | S5 | 8 个 `[custom]` 文件；热狗不动 |
| 下一批 6：FormatMoney | S6 | 别名文件方案（8 个 manifest include）；`$%d` 66→59 |
| 下一批 7：证据广播 | S7 | evidence 9 处 + 19 处（13 条）allowlist |
