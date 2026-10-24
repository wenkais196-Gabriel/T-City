# 07 — 架构适应度测试（Fitness Tests）

> 架构基线 agent D ｜ 只读 + 文档 ｜ **基线快照 `568acd2` + post-baseline 复评，当前 HEAD `3bbcab3`**（2026-10-24）｜ 未改代码、未 commit、未触碰 FXServer。
> 与 [05-nfr.md](05-nfr.md) 配套：05 定义"数字是多少"，本文定义"怎么用自动化证明架构没退化"。复评只改“现状/得分”，规则本身与基线一致。
> 姊妹文档：[00-overview.md](00-overview.md)（边界与信任模型）、[01-domain-model.md](01-domain-model.md)（不变量）、[03-contracts.md](03-contracts.md)（契约面清单）。
> 约束：检查器只用 **Python 3.12 标准库**、离线、确定性（无 FXServer、无 DB、无网络），单次运行 <15 s；不写产品代码，只写检查规则。
> 证据口径同 05：`路径:行号` 相对 `T-CityLite.base/resources/`；`server/*.lua` 等默认指 `custom-police/`。

**为什么是"静态 + 契约"而不是"运行时"**：仓库已有的事实是——真 P95 只能实机采（`T-CityLite.base/docs/agent/design/05-test-and-eval.md` §7："真 P95 由 T5 采集"），客户端 NPC 无法离线跑（`tcity-e2e` 假人没有 ped）。所以能进 CI 的只有两类断言：**源码形状**（谁写了哪张表、哪个事件有没有鉴权）和**契约一致性**（注册表 ↔ 生成物、迁移 ↔ fixture、常量 ↔ 文档）。这两类恰好覆盖了本项目最贵的失败模式（越权、丢审计、跨资源耦合、文档漂移）。

---

## 0. 一页：13 条规则

| # | 规则 | 域 | 现状 | 门禁 |
|---|---|---|---|---|
| FIT-01 | `job.onduty` 只有一个写者（duty 服务） | 状态一致性 | ✅ PASS（`test_duty_writer.py`；4 个登记写者，0 未登记） | blocking |
| FIT-02 | 禁止跨资源写别人拥有的表 | 边界 | ✅ PASS（`test_cross_resource_writes.py`；0 处未登记跨写） | blocking |
| FIT-03 | 每个 net event 必须有来源/权限校验 | 安全 | ✅ PASS（3e720bf；13 强鉴权 + 35 登记例外，0 未登记） | blocking |
| FIT-04 | 每个 export / app action 必须有稳定错误码 + 审计 | 契约 | ✅ PASS（46/46 export 扫描通过；11 条登记例外，0 未登记） | blocking |
| FIT-05 | 审计不可写时敏感路径必须 fail-closed | 取证 | ✅ PASS（3e720bf；11 个敏感读，0 丢弃） | blocking |
| FIT-06 | 迁移幂等 + fixture 覆盖 + 可重复执行 | 数据 | ⚠️ PARTIAL | blocking |
| FIT-07 | NPC 生成必须走预算接口（唯一入口 + 冷却 + 上限 + 审计） | 资源预算 | ⚠️ PARTIAL | blocking |
| FIT-08 | 生成物/注册表一致（`agent_tools --check` + 禁止手改） | 工具链 | ✅ PASS | blocking（已存在） |
| FIT-09 | 查询纪律：禁 `SELECT *`、必须 `LIMIT`、字段白名单 | 性能/PII | ✅ PASS（dec840f；23 处通配投影清零，2 条 allowlist） | blocking |
| FIT-10 | 资源接线：cfg ↔ manifest ↔ 文件 ↔ 导出消费者 | 可启动性 | ⚠️ PARTIAL | blocking |
| FIT-11 | 状态机列只允许登记过的写者 | 一致性 | ⚠️ PARTIAL | advisory |
| FIT-12 | 弃用登记：deprecated 写路径为 0 或未过期豁免 | 演进 | ✅ PASS（`test_deprecations.py`；6 条已知债务，2026-12-31 到期） | blocking |
| FIT-13 | 文档数字与代码常量一致（05 的预算不得漂移） | 文档 | ❓ UNKNOWN | advisory |

加权得分 **27 / 100**（上一轮快照，见 §5；基线 21/100）。**本轮把 FIT-02/FIT-12 从 FAIL 转 PASS**：跨资源写收敛到 owner 导出 + 扫描器，弃用路径登记 + 到期强制；§5 的合计仍是旧快照，权重分待下一轮统一重算。

> **本轮（FIT-02/FIT-12）**：新增 `tests/architecture/test_cross_resource_writes.py`、`tests/architecture/table_owners.json`、`tests/architecture/test_deprecations.py`、`tests/architecture/deprecations.json`；`phone_notifications` 只剩 `custom-phone` 写，`police_reports` 只剩 `custom-police` 写。outbox/TTL 语义见 [09-outbox.md](09-outbox.md)。
>
> **post-baseline `3e720bf`**：FIT-03/FIT-05 扫描器、evidence 鉴权、敏感读 fail-closed 已提交；`tests/architecture/` 已加入 CI。上表状态已更新，评分数字待重算。
>
> **本轮（FIT-01）**：`custom-police` 新增唯一警察 duty 服务 `P.SetDutyForSource`（导出 `SetDutyForSource`），10-8/10-7、`custom-main` 的 `/duty` 与通缉锁、`custom-director` 的 `set_job_duty` 全部改走该服务；新增 `tests/architecture/test_duty_writer.py` + `duty_writers_allowlist.json`（4 条登记，0 处未登记）。
>
> **本轮（FIT-04）**：新增 `tests/architecture/test_export_contracts.py` + `export_allowlist.json`，扫描 46 个 police export 的权限门、失败错误码、敏感读审计与 fail-closed；`GetUnits`/`GetIncidents` 补 `units.view` / `incident.update` + 先审计后查询，`GetCaseDetail` 审计移到首条 SELECT 之前；11 条登记例外（含 `GetCharges` 静态目录、`GetNpcBudget` 内部读取），0 条未登记。证据见 §FIT-04。

---

## 1. 落地形态

### 1.1 文件布局（建议）

```
T-CityLite.base/tests/architecture/          # 已落地文件（其余规则按需新增）
├── test_net_event_auth.py       # FIT-03
├── test_query_discipline.py     # FIT-09
├── test_cross_resource_writes.py + table_owners.json   # FIT-02（owner 表 + 跨写 allowlist）
├── test_deprecations.py + deprecations.json            # FIT-12（弃用登记 + 到期强制）
├── test_duty_writer.py + duty_writers_allowlist.json   # FIT-01（onduty 写者登记 + 反向验证）
├── test_export_contracts.py + export_allowlist.json    # FIT-04（export 门禁/错误码/敏感读审计）
└── test_audit_fail_closed.py    # FIT-05
docs/police/architecture/
├── error-codes.md                  # 人读词表（与 json 双向同步）
└── deprecations.md                 # 人读弃用登记（与 json 双向同步）
```

**为什么单独目录而不是塞进 `tests/check_*.py`**：现有 5 个脚本（`check_cfgs.py`、`check_dependencies.py`、`check_bus_wiring.py`、`check_db_schema.py`、`light_lint.py`）各自是被 `tests/run_all.py` 顺序执行的独立进程，退出码即结论；架构规则需要共享**一套可信的 Lua 解析层**（事件体、函数体、SQL 字面量），复制 5 份必然漂移。一个入口 + 规则模块，CI 里只多一个 step。

### 1.2 共享解析层（所有规则的共同前提）

不引第三方 Lua parser。用三条足够稳的启发式，都基于本仓库既有代码风格（`RegisterNetEvent` 顶格、`function` 顶格、`end` 顶格、SQL 用 `[[ ]]` 或单引号多行）：

```
① lines(path) -> [(no, text)]
② block_at(lines, i) -> 从第 i 行起到"顶格 end / end) / ]] / ')"为止的切片
     用于：事件体、函数体、SQL 字面量
③ sql_strings(text) -> 所有含 INSERT/UPDATE/DELETE/SELECT 的字符串字面量（跨行拼接后再匹配）
```

**假阴性优先**：宁可漏报（把可疑当通过），也不要因格式变化误报（会让整条规则被关掉）。规则遇到无法解析的构造时输出 `SKIP <file>:<line> <reason>`，`--strict` 下 SKIP 计为失败。

### 1.3 allowlist 的 schema（统一）

```json
{
  "version": 1,
  "entries": [
    { "id": "…", "why": "…", "owner": "…", "added": "2026-10-24",
      "expires": "2026-12-31", "ticket": "TD-0x" }
  ]
}
```

- `expires` 是**硬性**字段：过期条目在 `--strict` 下直接 FAIL（不是警告），强制每季度重看。
- 每次新增条目必须带 `why`（一句话说明"为什么现在不能修"）与 `ticket`（TD 编号或 issue）。
- 条目只允许"存量豁免"，**不允许"新代码豁免"**：`added` 日期晚于规则上线日的条目一律 FAIL（新代码必须直接合规）。

### 1.4 输出契约

```
FIT-03 net-event-auth  FAIL  37/43 unguarded
  server/evidence.lua:64  evidence:server:CreateBloodDrop  no_auth
  …
  summary: {"rule":"FIT-03","status":"fail","violations":37,"skipped":0,"allowlisted":6}
```

退出码：`0` 通过 / `1` 失败 / `2` 规则自身错误（解析异常、allowlist 损坏）。`--json` 供 CI 归档，`--rule` 供本地单跑。

---

## 2. 规则

### FIT-01 · `job.onduty` 只有一个写者

- **规则**：`PlayerData.job.onduty` 只有两类合法写者：
  1. qb-core 的底层 primitive `Player.Functions.SetJobDuty`（`qb-core/server/player.lua`；不改 qb-core，`QBCore:ToggleDuty` 仍由框架内部调用它）；
  2. `custom-police` 的唯一警察 duty 服务 `P.SetDutyForSource(source, onDuty, reason)`（导出 `SetDutyForSource`）：校验 source 是 police → `pcall(SetJobDuty)` → 回读 `PlayerData.job.onduty` 实际值 → `syncDuty` 投影 `police_units` → 审计 `duty.set`（`target=citizenid`、`detail=on/off:<reason>`），返回 `true` 或 `false, 'not_police'|'duty_failed'`。
  所有**警察**写路径（10-8/10-7、`custom-main` 的 `/duty` 快速指令与通缉锁、`custom-director` 的 `set_job_duty`）必须先调该导出，不得直接调 `SetJobDuty`。非警察（ambulance/mechanic/taxi）保留 qb-core 原生 `SetJobDuty`，语义不变。
- **为什么**：TD-01 的根因。4 个写者（qb-core 定义、`custom-main/server/dispatch.lua`、`custom-director/server/main.lua`、qb-core `QBCore:ToggleDuty`）曾让 `onduty=true` + `police_units=off_duty` 这类组合合法存在；权限、MDT、派单各读一套（`TECH_DEBT.md` TD-01）。没有这条规则之前，"单一状态机"永远只是文档里的一句话。
- **检查方式**（`tests/architecture/test_duty_writer.py` + `duty_writers_allowlist.json`）：
  - 扫描范围：`resources/*/*/server/**/*.lua`（排除 `custom-testing/`；qb-core 的 `server/events.lua` 是框架 vendor 代码，按约束不改 qb-core，其 `QBCore:ToggleDuty` 投影由 `p0.lua` 的 `OnJobUpdate → syncDuty` 兜底）；先 mask 注释/长字符串，注释掉的调用不算。
  - 正则（写入）：`SetJobDuty\s*\(`。除 allowlist 外任何文件出现即 FAIL，输出 `file:line`。
  - allowlist 只登记 4 条：`qb-core/server/player.lua`（primitive）、`custom-police/server/p0.lua`（服务实现）、`custom-main/server/dispatch.lua` 与 `custom-director/server/main.lua` 的**非警察分支**（reason 写明“非 leo / ambulance/mechanic/taxi”）。
  - `custom-main`/`custom-director` 的每条调用还必须静态验证：同一函数体内、调用之前出现 `jobName == 'police'` 或 `type == 'leo'`、函数内出现 `SetDutyForSource`、且 guard 与调用之间有 `else`/`elseif`。否则报 `not_in_non_police_branch` / `no_police_guard_before_call` / `no_duty_service_in_function`。
  - `p0.lua` 内只允许一处 `SetJobDuty`，且必须位于 `P.SetDutyForSource` 函数体内。
  - 反向验证：把 `Player.Functions.SetJobDuty(true)` 注入临时副本的 `custom-main` 模块级或警察分支，扫描器必须报红。
- **失败信息**：`FIT-01 FAIL 1 unregistered SetJobDuty writer(s)` / `custom-main/server/dispatch.lua:289 Player.Functions.SetJobDuty(false)  not_in_non_police_branch`。
- **CI**：`pytest -q tests/architecture`（blocking）；`test_duty_writer.py` 离线、确定性，单次 <1 s。
- **现状（本轮）**：✅ **PASS**。`P.SetDutyForSource` 落地并导出；10-8/10-7 与 `SetUnitStatus` 的 off_duty 路径改调服务（离线 citizen 只写 unit 行）；`/duty` 警察分支、通缉锁、director 警察目标均先调 export。allowlist 4 条、0 处未登记；`p0.lua` 仅服务内 1 处 primitive 调用。
- **例外**：`custom-main`/`custom-director` 的非警察分支是 allowlist 的“非 leo / ambulance/mechanic/taxi”条目；警察分支**不得**回退直写。qb-core 的 `server/events.lua`（`QBCore:ToggleDuty`）是框架 vendor 代码，按约束不改 qb-core，因此作为 `FRAMEWORK_INTERNAL_FILES` 排除在 allowlist 之外，其投影由 `p0.lua` 的 `OnJobUpdate → syncDuty` 兜底。

### FIT-02 · 禁止跨资源写别人拥有的表

- **规则**：每张表有唯一 owner；非 owner **只能读，且只读白名单列**；写必须通过 owner 的导出。允许的跨资源写只能是 owner 明确提供的导出路径。
- **为什么**：这是"30+ 资源共用一库"的唯一边界。曾经的现实是：`custom-police` 直接 `INSERT phone_notifications`（5 处），`custom-justice` 直接 `UPDATE police_reports`（1 处）。它们今天能跑，但任何一方改列/加约束/换存储，另一方静默坏掉，且坏在运行时而不是 CI。
- **检查方式**（`tests/architecture/test_cross_resource_writes.py`）：
  - `table_owners.json` 定义扫描资源、owner（精确名 / `prefix_*`）与跨写 allowlist（语义以 `04-data-ownership.md` 为准，json 只是它的机器可读镜像，避免两份 owner 表打架）：
    ```
    police_*            -> custom-police      (read: none)
    phone_*             -> custom-phone       (read: none)
    players, player_vehicles, bans -> qb-core (write: 仅 API / 登记例外)
    agent_*             -> custom-director
    justice_*           -> custom-justice
    inventories         -> qb-inventory
    ```
  - 扫描 `scan` 列表里的 `server/**/*.lua`，抽取 SQL 写语句（`INSERT [IGNORE] INTO` / `REPLACE INTO` / `UPDATE <table> SET` / `DELETE FROM`，注释先 mask）：表有 owner 且资源 ≠ owner → 违规，必须命中 allowlist 条目（`writer`/`table`/`owner`/`reason`/`expires`）；过期条目与“没有命中任何违规”的 stale 条目都 FAIL。
  - 反向检查：`test_reverse_check_detects_a_justice_write_to_police_reports` 把被本任务删除的 justice 直写形状注入扫描器，必须报红；`test_phone_notifications_and_police_reports_have_a_single_writer` 断言两张表只剩 owner 写。
- **失败信息**：`FIT-02: custom-police/server/p0.lua:105 INSERT phone_notifications — owned by custom-phone; use exports['custom-phone']:Notify(...)`。
- **CI**：`Config & dependency checks`，blocking。
- **现状（本轮）**：✅ **PASS**。owner 导出落地：`custom-phone:Notify(citizenid, title, content, appId, meta)`（字段截断 + `app_id` 白名单 + 单次推送，在线/离线都落库）；`custom-police:RecordVerdict(justiceCaseId, verdictJson, status)`（参数校验 + 只 UPDATE `justice_verdict/justice_status`）。5 处警察通知改走 `police_outbox`（见 [09-outbox.md](09-outbox.md)），justice 改调派生导出。当前 18 处跨资源写全部在 allowlist（career/main/phone-banking → `players`，police → `phone_invoices`/`inventories`/`player_vehicles`，agent-client/story-engine → `agent_*`），到期 `2026-12-31`。
- **例外**：allowlist 只豁免“存量 + 明确理由 + 到期日”；**新增**跨资源写必须在同一 PR 里加 owner 导出，否则 `test_cross_resource_writes.py` 直接红。`phone_notifications` 的 `content` 长度与 `app_id` 枚举由 owner 导出 + `test_police_outbox.py` 覆盖。

### FIT-03 · 每个 net event 必须有来源/权限校验

- **规则**：每个 `RegisterNetEvent(name, handler)` 的 handler 体内必须至少出现一个鉴权 token：`PolicePolicy.Can(`、`IsPlayerAceAllowed(`、系统来源守卫（`src == 0` / `source == 0`）、或显式的**会话/所有权**校验（只能操作自己创建的 request_id 等，需 allowlist 说明）。没有 token 且不在 allowlist → FAIL。
- **为什么**：44 个 net event 里只有 2 个走 capability 表，9 个 `evidence:server:*` 完全不校验，任意客户端可伪造 DNA、清空全服血迹与弹壳（`server/evidence.lua:64-155`）。这不是"可能被利用"，是"现在就能被利用"。
- **检查方式**：
  - 提取事件体：从 `RegisterNetEvent('<name>'` 行起，到其后第一个顶格 `end)`（本仓库风格）为止；若 60 行内没有顶格 `end)` 则 SKIP 并记入 `--strict` 失败。
  - 正则 token 集：`PolicePolicy\.Can\(`、`IsPlayerAceAllowed\(`、`src\s*==\s*0`、`source\s*==\s*0`；**弱 token**（只校验职业）：`job\.type\s*==\s*'leo'`、`PolicePolicy\.IsPolice\(` → 记为 `weak_auth`（不通过，但在 allowlist 里标注降级优先级）。
  - 伪代码：
    ```
    for each event in events(path):
        tokens = AUTH_RE.findall(event.body)
        if any(strong): pass
        elif any(weak): findings.append(weak_auth, priority="p2")
        else: findings.append(no_auth, priority="p1")
        if event.name not in allowlist[weak_auth|no_auth]: violations += 1
    ```
  - 额外子规则（**平民入口**）：不要求 capability，但必须（a）在 allowlist 标注 `civilian`，（b）handler 内有长度/类型校验，（c）所在资源有频率限制常量。当前 `custom-police:server:911` 三项里只有 (b)。
- **失败信息**：`FIT-03: <file>:<line> <event-name> no_auth — add PolicePolicy.Can(...) or a system-source guard, or register it in allowlists/net_events.json with an expiry`。
- **CI**：`Config & dependency checks`，blocking（allowlist 让存量通过，新增违规立刻红）。
- **现状（post-baseline）**：❌ **FAIL（HEAD）/ 进行中**（2/44 强校验）。**HEAD 上扫描器尚未落地**：`tests/architecture/` 与 CI step 都不在 `3bbcab3`。**工作区（未提交）**已新增 `T-CityLite.base/tests/architecture/test_net_event_auth.py` + `net_events_allowlist.json`，并给 `evidence.lua` 加了 capability 校验；提交后需重跑并在 allowlist 里登记 evidence 的到期日。在此之前本条只有“人工复核”的结论。强：`police:server:autoAlert`、`police:server:JailPlayer`（仅 `source==0`）。弱（27，未变）：`interactions.lua` 10、`main.lua` ~10、`objects.lua` 3、`vehicle.lua` 4。无（9，HEAD 未修）：`server/evidence.lua:64,69,78,86,95,108,121,139,148`——**HEAD 上这 9 个 evidence 事件仍可被平民客户端调用**；工作区版本已加校验（未提交）。合规新增：`police:server:NpcCalloutResult`（`p4_npc.lua:406-413`，`incident.update` + membership）。注意 `custom-police:server:setStatus` 现在走 `SetUnitStatusForSource`，会校验 onduty（`p0.lua:567-599`），**这条基线缺口已修**。
- **例外**：evidence 9 条 allowlist 到期日必须 ≤ `2026-11-30`（优先下线或加 `PolicePolicy.Can`+onduty）；`911` 标 `civilian` 并补限流；`NpcCalloutResult` 属合规会话校验，无需豁免。

### FIT-04 · export / app action 必须有稳定错误码 + 审计

- **规则**：
  1. 写路径（函数体内含 `INSERT|UPDATE|DELETE`）必须调用 `audit(`（或 `auditPlayer(`），且审计动作名属于受控词表；
  2. 每个 `return` 必须是"表"或 `false, '<code>'` / `nil, '<code>'` / `false, reason`（`reason` 来自 `PolicePolicy.Can`）；裸 `return` / `return false` / `return nil` → FAIL；
  3. 返回的字面量必须是稳定的 `snake_case` 码，并同步登记到 [ARCHITECTURE_ERRORS.md](../ARCHITECTURE_ERRORS.md)（`error_codes.json` 机器词表尚未落地，当前扫描器先强制字符串形态；新增码 = 显式 diff + 文档同步）；
  4. **action 层不得把错误码压成布尔**：`PhoneApps` action handler 必须返回 `{ok=false,error=...}` 或原样透传，不得 `return ok and res ~= false`。
- **为什么**：MDT 是唯一接警 UI，错误文案取决于 action 层有没有把码透传；`aea205c` 已把 17/17 action 收敛到 `structured()`。本轮补更底层：46 个 export 里仍有读导出没有 capability/审计（`GetUnits`/`GetIncidents` 会返回公民姓名/警情描述）、部分失败路径是裸 `false`、跨资源 owner 写没有稳定码。没有扫描器，新增一个 `exports(...)` 很容易再次绕过门禁/审计；allowlist 让存量例外必须带 owner + 到期日，而不是永久沉默。
- **检查方式**（`tests/architecture/test_export_contracts.py` + `export_allowlist.json`，只扫 `custom-police/server/**/*.lua`）：
  - 解析 `exports('<Name>', <sym>)`：`<sym>` 是 `P.GetUnits` / `C.CreateCase` / `GetNpcBudget` 时找顶格 `function <sym>(` 切到 `^end$`；是 `function(...)` 时切到 `^end)$`。每条 finding 带 `file:line export`。
  - **门禁**：函数体（去注释后）必须含 `PolicePolicy.Can/Check/IsPolice`、`isPolice`、`hasCapability`、`IsPlayerAceAllowed`、已验证的 `lookupAllowed`，或显式 ownership 比较（`row.citizenid ~= actor.citizenid`）。
  - **错误码**：逐个 `return false|nil` 检查第二个返回值；裸 `return false` / `return nil`（含 `then return false end`）→ `error_code`。`fail('<code>')` / `{ ok=false, error }` 视为合规。
  - **敏感读**：capability 以 `.view/.detail/.chain` 结尾，或 `Get*/Lookup*` 返回 PII（citizenid/姓名/description/summary/body；`GetNpcBudget -> NPCBudget.Get` 这类一层委托也解析）→ 必须 `if not audit(...) then return false, 'audit_unavailable' end`（或 `lookupAllowed` + `return false, err`），且审计位置必须早于首条 SELECT。审计写晚于查询同样 FAIL。
  - **allowlist**：每条必须有 `export`/`file`/`kind`/`exceptions`（`auth` / `error_code` / `sensitive_read_audit` 的精确集合）/`reason`/`owner`/`added`/`expires`。过期、未知 export、重复条目、以及"登记的 exception 已不再命中"（修好了没删条目）全部 FAIL；未登记的新违规立即 FAIL。
- **失败信息**：`FIT-04: custom-police/server/p0.lua:729 SweepStaleIncidents auth (no permission/source gate)` / `custom-police/server/p1.lua:229 GetMyCitations sensitive_read_audit (sensitive read does not fail closed on audit_unavailable)`。
- **CI**：`pytest -q tests/architecture`（blocking）；扫描器离线、确定性，单次 <0.2 s；行为层由 `tests/unit/layer3_business/test_police_read_exports.py` 的 Lua harness 补证。
- **现状（本轮）**：✅ **PASS**。46 个 export 全部解析，0 条未登记；11 条登记例外（见下）。**已修**：`GetUnits` 改为 `P.GetUnits(source)` → `units.view` + 先写 `units.view` 审计再 SELECT，审计失败 `false, 'audit_unavailable'`；`GetIncidents` 改为 `P.GetIncidents(source, status)` → `incident.update`（policy 无 `incident.view`）+ 先写 `incident.view` 审计，同样 fail-closed；MDT 的 `me`/`units`/`incidents` 三个 query 已把 `source` 传进来。`C.GetCaseDetail` 的 `case.detail` 审计从 case 查询之后移到首条 SELECT 之前。`C.RecordVerdict` 补 `invalid_justice_case`/`invalid_verdict`/`invalid_status`/`db_error`；`Outbox.Enqueue` 补 `invalid_topic`/`invalid_payload`/`encode_failed`/`db_error`（`EnqueueOutbox` 原样透传）。action 层 17/17 已结构化（`aea205c` 的 `structured()`），不再压平错误码。
- **剩余非 export 例外**：`PayCitation` 的 `already_<status>` 仍是动态码（公民侧 banking，不在 17 个 action 内）；`Sys.Jail` 的 `arrest.register` 审计失败只打印（arrest 行已提交，不能回滚），属 FIT-05 的"写路径 best-effort 必须留日志"，不计入本规则。
- **例外（`export_allowlist.json`，11 条）**：
  - system-only（6）：`SweepStaleIncidents`（定时器）、`CreateIncidentSystem` / `AssignUnitSystem` / `JailSystem`（custom-director agent 桥，actorId 不是玩家 source）、`EnqueueOutbox`（内部队列）、`RecordVerdict`（custom-justice owner 写）；均已有审计与稳定错误码。
  - 静态目录（2）：`GetCharges`（罪名表，无 DB/PII/审计）、`GetNpcCalloutTemplates`（模板 id）。
  - 诊断读（1）：`GetActiveNpcCallouts`（无 PII）。
  - 公民自有读（1）：`GetMyCitations`（SQL 绑定 `actor.citizenid`，非警察审计面）。
  - 内部读（1）：`GetNpcBudget`（`RequestBackup`/`CreateNpcCallout` 热路径共用；在 accessor 内加审计会读放大；快照含 citizenid，2026-12-31 前补带 source 的审计包装）。

### FIT-05 · 审计不可写时敏感路径必须 fail-closed

- **规则**：任何**敏感读**（lookup / 案件 / 证据 / 报告 / 罚单 / 审计查看）与**所有写**，在 `audit()` 返回 false 时必须拒绝或回滚，并返回 `audit_unavailable`。检测两种形状：
  - R1（fail-open 形状）：`^\s*audit\(` / `^\s*auditPlayer\(` 独占一行的调用 → 返回值被丢弃；
  - R2（缺审计形状）：函数内出现 `PolicePolicy.Can(actor, '<x>.view')` 但没有 `audit(` → 敏感读零审计。
- **为什么**：`police_audit` 是本系统唯一的取证面（05 NFR-OBS-01）。`server/p1.lua:18-25`、`server/p3_cases.lua:37-44` 的 `audit()` 返回值被所有调用点忽略——审计表写不进去时，罚单、报告、案件照常成功，**事后无法证明谁做了什么**。而 DB 抖动是最常见故障（05 NFR-REL-03）。
- **检查方式**：
  ```
  for path in server_lua_files:
      for no, line in lines(path):
          if RE_FAILOPEN.match(line) and rel not in allowlist:
              report(path, no, "unconsumed audit result")
  for fn in exports_and_state_functions():
      if re.search(r"PolicePolicy\.Can\([^)]*'[a-z.]*\.view'", fn.body) and 'audit(' not in fn.body:
          report(fn.path, fn.line, "sensitive read without audit")
  ```
  - 合法形状白名单：`if not audit(...) then return ... end`、`local ok = audit(...)`、`auditsOk = false`（`server/p2_system.lua:636-651` 是样板）。
- **失败信息**：`FIT-05: custom-police/server/p1.lua:29 audit() result ignored — a DB write failure would silently lose the forensic row; wrap it as "if not audit(...) then return false, 'audit_unavailable' end"`。
- **CI**：与 FIT-04 同一个 step；blocking（存量进 allowlist）。
- **现状（post-baseline）**：❌ **FAIL（HEAD）**。HEAD 上 fail-open 仍是 **23 处**（`p0` 6、`p1` 3、`p2_evidence` 3、`p2_system` 1、`p3_cases` 10），新增的 `p4_npc` 2 处 `audit()` 也不消费返回值。零审计的敏感读：`GetUnits`、`GetIncidents`、`GetAudit`、`GetCitations`、`GetReports`。已合规集合：`p0.lua:331-333`（lookup fail-closed）、`p3_cases.lua:242-244`（case.detail）、`p2_system.lua:348-352,766-797,930-940`。
- **工作区（未提交）**：`p0/p1/p2_evidence/p3_cases` 等已把 `audit()` 改为 `if not audit(...) then`（写路径失败打印、敏感读 fail-closed），`GetAudit`/`GetCitations`/`GetReports` 改为审计失败即 `audit_unavailable`；但 `GetUnits`/`GetIncidents` 仍零审计。提交后本条应转 **PARTIAL**。
- **例外**：`GetCitations`/`GetReports` 加审计会新增写放大（05 PERF-06），allowlist 里必须写清"加审计前先评估 qps"，到期日 `2026-12-31`。

### FIT-06 · 迁移幂等 + fixture 覆盖 + 可重复执行

- **规则**：
  1. 每个 `migrations/v*.sql` 可重复执行：每个 `CREATE TABLE` 带 `IF NOT EXISTS`，或整段被 `information_schema` 存在性判断保护（含存储过程形态）；`ALTER TABLE` 的 `ADD COLUMN/KEY` 带 `IF NOT EXISTS` 或同文件内有 `information_schema.COLUMNS/STATISTICS` 守卫；
  2. 迁移里出现 `DROP TABLE` / `TRUNCATE` / 无 `WHERE` 的 `DELETE` → FAIL（除非该文件在 `destructive` allowlist，且必须人工审批）；
  3. **fixture 覆盖**：迁移创建的每张表都必须出现在 `tests/fixtures/tcity_schema.sql`；
  4. **可重复执行**：CI 连续 import 两次，第二次不得报错、表/行数不变。
- **为什么**：TD-05 直接说"fixture 缺 police 表，DB 集成用例目前 skip"。这意味着 12 张警察表的真实 SQL（索引、ENUM、字符集）**从未在 CI 里跑过**；`v2.8`–`v3.7` 的守卫写错只会在生产迁移时炸。
- **检查方式**：
  ```
  for f in migrations/*.sql:
      text = strip_comments(read(f))
      for m in CREATE_TABLE_RE.finditer(text):
          if 'IF NOT EXISTS' not in m.group(0) and 'information_schema' not in text: report(...)
      for m in ADD_COLUMN_OR_KEY_RE.finditer(text):
          if 'IF NOT EXISTS' not in m.group(0) and 'information_schema' not in text: report(...)
      if DESTRUCTIVE_RE.search(text) and f not in allowlist: report(...)
  tables = set(all CREATE TABLE names across migrations)
  fixture = set(CREATE TABLE names in tests/fixtures/tcity_schema.sql)
  for t in sorted(tables - fixture): report("fixture missing " + t)
  ```
  - 第 4 条靠 CI 命令实现，不靠静态分析：`mariadb ... < fixture; mariadb ... < fixture`（或在 db-schema job 里 `for i in 1 2`）。
- **失败信息**：`FIT-06: tests/fixtures/tcity_schema.sql missing 14 tables from migrations: police_audit, police_bolos, police_cases, police_citations, police_evidence, police_evidence_chain, police_incidents, police_incident_units, police_reports, police_units, police_warrants, police_arrests, police_write_intents, justice_sentences`。
- **CI**：静态部分进 `Config & dependency checks`；重复导入进 `DB schema tests`（现有 job，MariaDB service 已就绪）。
- **现状（post-baseline）**：⚠️ **PARTIAL**。迁移幂等：**通过**（`v2.8`–`v3.11` 全部 `CREATE TABLE IF NOT EXISTS`/`information_schema` 守卫；`v3.8`/`v3.9` 还补了索引守卫；无 `DROP TABLE`/`TRUNCATE`）。fixture：**仍失败**——`tests/fixtures/tcity_schema.sql` 里 `police_*`/`justice_sentences`/`police_write_intents` 全部 0 命中。重复导入：**仍未验证**（CI 只 import 一次）。
- **例外**：无。这是最便宜的一条，见 §6。

### FIT-07 · NPC 生成必须走预算接口

- **规则**：客户端实体创建（`CreateVehicle`、`CreatePed`、`CreatePedInsideVehicle`、`CreateVehicleServerSetter`）只允许出现在 `custom-police/client/backup.lua`，且必须由服务端下发的 `requestId` 驱动；服务端只有 `RequestBackup` 可以发 `police:client:SpawnBackup`，且必须在**冷却检查 → 上限检查 → 预留槽位 → 审计成功**之后才发（顺序不可换）。
- **为什么**：NPC 支援是唯一一处"客户端创建实体 + 服务端计数"的耦合。GTA_MOD_RESEARCH §6 的结论是"关键不是生成 NPC，而是回收、上限、失败兜底"；一旦绕过预算接口（例如直接从 command 触发 `SpawnBackup`，或客户端自行 `RequestBackup` 之外的路径生成），48 人服可以在 10 秒内出现数百个实体（05 SCALE-03 的 96 单位上限）。
- **检查方式**：
  ```
  允许文件 = {'custom-police/client/backup.lua'}
  for path in all_lua_files:
      for no, line in lines(path):
          if SPAWN_RE.search(line) and rel not in 允许文件: report(...)
  for path in custom-police/server/*.lua:
      for emit in re.finditer(r"TriggerClientEvent\(\s*'police:client:SpawnBackup'", text):
          enclosing = function_of(emit)
          if enclosing.name != 'RequestBackup': report(...)
          order = [pos(check) for check in ('backupUnitCount', 'BACKUP_COOLDOWN', 'auditPlayer')]
          if not (order[0] < pos(emit) and order[1] < pos(emit) and order[2] < pos(emit)): report(...)
  子规则（预算完整性，advisory）：RequestBackup 必须引用一个全局上限常量（如 BACKUP_MAX_UNITS_GLOBAL）
  ```
- **失败信息**：`FIT-07: custom-police/server/p2_system.lua:241 emits police:client:SpawnBackup outside RequestBackup — NPC spawns must go through the budget interface (cooldown + per-player cap + audit)`。
- **CI**：`Config & dependency checks`，blocking；预算完整性用 Lua harness（`tests/agent/lua/cases/police_system.lua` 已能加载 `p2_system.lua` + MySQL stub）。
- **现状（post-baseline）**：⚠️ **PARTIAL**。backup 路径仍合规：唯一发送点 `server/p2_system.lua:364`，顺序为冷却（325-327）→ 上限（327）→ 预留（336-341）→ audit（348-352）→ 发（364），audit 让出后复验玩家仍在（356-362）。**但 NPC 警情在 `client/npc_callouts.lua:192,210` 新增了独立的 `CreateVehicle`/`CreatePed` 生成路径**，不受 `RequestBackup` 的冷却/上限/审计约束（只受服务端 `MAX_ACTIVE=1` 的警情数约束）。按规则字面（生成只允许在 `client/backup.lua`）本条 **不再是 PASS**。全局 cap 仍缺。
- **例外**：无。新增 NPC 类型（K9/SWAT）时必须扩展同一接口，不允许新建生成路径。

### FIT-08 · 生成物/注册表一致

- **规则**：`tools/agent_tools.json` 是唯一事实源；`T-CityLite.base/docs/agent/TOOLS.md` 与 `custom-director/shared/agent_tools.lua` 只能由 `python3 tools/agent_tools.py --write` 生成（文件头有 `@generated` 标记），手改即 FAIL。
- **为什么**：35 工具 / 21 动作的文档、Lua 镜像、MCP 路由三者必须同源；任何手改都会让 agent 侧与警察侧的策略不一致（例如工具写了 `requires_approval=false`，director 里却是 L3）。
- **检查方式**：直接复用现有能力——`python3 tools/agent_tools.py --check`（`tools/agent_tools.py:1499-1504`）已实现漂移检测；本规则只额外加两条：① 生成物首行含 `GENERATED_MARKER`（`tools/agent_tools.py:1115`）；② 契约测试的计数断言（32→35 之类的硬编码数字）与 registry 的 `len()` 一致。
- **失败信息**：`FIT-08: generated file drift — run python3 tools/agent_tools.py --write`（沿用现有输出）。
- **CI**：`Config & dependency checks` 的 `Agent tool registry drift` step（**已存在**，`ci.yml:32-33`）。
- **现状**：✅ **PASS**（CI 已绿）。
- **例外**：无。

### FIT-09 · 查询纪律（禁 `SELECT *`、必须 `LIMIT`、字段白名单）

- **规则**：
  1. `custom-police/**` 与警察相关读路径禁止 `SELECT *`；
  2. 每个返回行集的查询必须有 `LIMIT`（或 `LIMIT ?` 且调用方 clamp）；
  3. 单次响应的 JSON 字节数有上限常量（建议 64 KB），超限截断并计数；
  4. 返回给 NUI 的字段必须显式列出（不得透传整行）。
- **为什么**：16 处 `SELECT *`（05 NFR-SEC-05/PERF-02）。`police_reports.body` 是 `VARCHAR(4000)`，50 行最坏 ~200 KB 一次性塞进 net event；同时把 `author_citizenid`/`officer_citizenid` 等 PII 无审计地推到前端。这是"性能问题"和"PII 问题"的同一个根因。
- **检查方式**：
  ```
  for path in custom_police_server_files + phone_app_files:
      for sql in sql_strings(path):
          if re.match(r"\s*SELECT\s+\*", sql): report(path, "select_star")
          if sql.startswith("SELECT") and "LIMIT" not in sql: report(path, "no_limit")
  额外：对每个 app query handler，检查返回值是否经过 FIELD_WHITELIST 映射（人工 review 项，机器只查 'SELECT *' 与字节上限常量是否存在）
  ```
- **失败信息**：`FIT-09: custom-police/server/p1.lua:130 SELECT * FROM police_reports — list columns explicitly and cap the payload (body is 4000 bytes × 50 rows)`。
- **CI**：`Config & dependency checks`，blocking（存量 16 处进 allowlist，按文件批次收敛）。
- **现状（post-baseline）**：❌ **FAIL，未变**。16 处：`server/p0.lua:124,194,197`、`server/p1.lua:86,89,123,127,130`、`server/p2_evidence.lua:74,77`、`server/p3_cases.lua:67,105,180,183,240`、`server/vehicle.lua:12`。全部都有 `LIMIT`（除 `vehicle.lua:12` 无 LIMIT）。`p4_npc.lua` 没有 `SELECT *`，但 `GetActiveNpcCallouts` 仍返回行集、无显式字段白名单（只选了列，算合规）。
- **例外**：`vehicle.lua:12` 是老 qb-policejob 代码（`state=2` 的车牌列表），allowlist 到期 `2026-12-31`。

### FIT-10 · 资源接线（cfg ↔ manifest ↔ 文件 ↔ 导出消费者）

- **规则**：
  1. 启动链里 `ensure`/`start` 的资源都有 `fxmanifest.lua`（复用 `check_cfgs.py` 的内置资源集合与判定口径）；
  2. 每个已启动 manifest 的 `shared_scripts` / `client_scripts` / `server_scripts` / `files` 列出的**字面文件**必须存在（`@resource/file.lua` 与 glob 不由本规则判定）；
  3. 已启动资源里的每个 `exports['<res>']` / `exports["<res>"]` 消费者，`<res>` 要么是已启动资源，要么是 `resource_wiring_allowlist.json` 登记的外部/延期依赖；
  4. 声明依赖存在且顺序正确（复用 `check_dependencies.py` 的 `parse_manifest` / `build_resource_index` / `get_startup_sequence` / `check_startup_order`，同进程 import，不 subprocess）。
- **为什么**：这是"改完 manifest 忘了重启 / 忘了加文件 / 调了未启动资源的导出"的机器化版本（`STATUS.md` 已警告改 manifest 或新增 server 文件后必须整服重启）。第 3 条尤其重要：`custom-police` 依赖 `custom-phone` 的 app 注册、`custom-justice` 的判决导出，而依赖方向过去只写在文档里；一个拼错的资源名在运行时才会炸。
- **检查方式**（`tests/architecture/test_resource_wiring.py` + `resource_wiring_allowlist.json`，离线、单文件 <1 s）：
  - **配置来源**：优先读本地 `T-CityLite.base/server.cfg`（gitignored）；不存在时读 tracked 的 `server.cfg.template`。两者都通过 `exec configs/modules/*.cfg` 启动，测试沿 exec 链收集 `ensure`/`start`，因此 CI 与开发机得到同一资源集（当前 82 个；`chat` 等 FiveM 内置资源豁免）。
  - **manifest 文件**：先 mask Lua 注释，再解析四个 block（含单数 `server_script` 等旧写法）；跳过 `@` 前缀与 `*`/`?`/`[]` glob。当前检查 **598** 个字面条目、0 缺失。反向测试用临时 manifest 引用 `server/ghost.lua`，必须报红。
  - **导出消费者**：扫描 82 个已启动资源下 **951** 个 Lua 文件，共 **424** 处 `exports[...]`、**46** 个目标资源；未启动且未登记的目标 → FAIL。反向测试注入 `exports['ghost-resource']`，必须报红。
  - **依赖/顺序**：对每个已启动 manifest 的 `dependencies{}` 断言依赖已启动或属于 system/built-in；并用 `check_dependencies.check_startup_order` 断言硬依赖早于消费者。当前 0 条。
  - **allowlist**（`resource_wiring_allowlist.json`，4 条）：`LegacyFuel` / `qb-jobs` / `qb-vehiclekeys` 是仓库外的既有兼容依赖；`qb-houses` 是存在于 `resources/` 但不在精简启动链的 known deferred 资源，仅 `qb-garages` 的 house 分支调用。每条必须有 `reason` / `added` / `expires`；过期与 stale（不再被任何消费者引用）都 FAIL。
- **失败信息**：`FIT-10: custom-police/fxmanifest.lua server_scripts:12 server/ghost.lua — file does not exist` / `FIT-10: qb-houses: referenced by [qb]/qb-garages/server/main.lua`。
- **CI**：`pytest -q tests/architecture`，blocking。
- **现状（本轮）**：✅ **PASS**。82 个启动资源全部有 manifest；598 个字面条目 0 缺失；424 导出引用只指向已启动资源或 4 条登记依赖；依赖声明与启动顺序 0 违规。**未改业务代码**。
- **例外**：`qb-houses` 是"存在但未启动"的延期资源（不是外部依赖），登记为 `kind: deferred_repo_resource`，到期 `2027-03-31`；真正启用房屋系统时必须先从 allowlist 删除本例外。其余 3 条是仓库外兼容依赖，到期同上。

### FIT-11 · 状态机列只允许登记过的写者

- **规则**：`police_units.status`、`police_units.incident_id`、`police_incidents.status`、`police_reports`、`police_cases`、`police_citations`、`police_warrants.status`、`police_bolos.status` 的 `UPDATE` 只允许出现在登记过的服务文件/函数内；其他资源（`custom-justice` / `custom-phone` / `qb-prison`）只能经 `custom-police` 导出，不能直接写。新增写者必须改 `state_writers_allowlist.json` 或走服务导出。
- **为什么**：状态列是最容易被"顺手写一行"破坏的地方。`police_incidents.status` 曾同时由 p0 与 p2_system 写，`police_units.status` 也有 5 个 helper；没有登记表就没有"谁是新来的"这一判断，05 COMPAT-01 的"单一状态机"永远收不回来。FIT-01 已把 duty 收敛到 `SetDutyForSource`，本规则把剩下的 SM-01/02/03/05 写点固定下来。
- **检查方式**（`tests/architecture/test_state_writers.py` + `state_writers_allowlist.json`，离线、单文件 ~1 s）：
  - **SQL 提取**：mask Lua 注释后匹配 `UPDATE police_* SET`，从 `SET` 到 `WHERE` 解析赋值列，再按"表 + 列"匹配规则：
    - `police_units.status` / `police_units.incident_id` → 仅 `server/p0.lua`；
    - `police_incidents.status` → 仅 `server/p0.lua`；
    - `police_reports` → `p1.lua` / `p2_system.lua` / `p3_cases.lua`；
    - `police_cases` → `p2_system.lua` / `p3_cases.lua`；`police_citations` → `p1.lua`；`police_warrants.status` / `police_bolos.status` → `p3_cases.lua`。
  - **当前扫描**：22 个状态写点、7 条规则、4 个文件（p0/p1/p2_system/p3_cases）；`custom-justice` / `custom-phone` / `qb-prison` 对 `police_*` 的直接状态写 **0 处**（justice 判决已改走 `RecordVerdict` 导出）。
  - **例外**：`p2_system.lua` 的 `Sys.AssignUnit` 仍直接写 `police_units` + `police_incidents`（旧 director L2 路径，绕过 `P.AssignUnit` 的 transition/在勤守卫）。两条 entry 按 `(writer, table, file, function)` 精确登记，因此同一文件里的新写点不会被这条例外放过；到期 `2027-03-31`。
  - **反向测试**：向临时 `custom-justice/server/trial.lua` 注入 `UPDATE police_incidents SET status='closed'`、向 `custom-phone/server/pay.lua` 注入 `UPDATE police_citations`，扫描器都必须报红；向 `p2_system.lua` 的 **非** `Sys.AssignUnit` 函数注入 units 写，也必须红。
- **失败信息**：`FIT-11: custom-justice/server/trial.lua:3 UPDATE police_incidents SET ['status'] in (top-level) — register the writer or route it through the service`。
- **CI**：`pytest -q tests/architecture`，blocking（登记表已收敛，0 未登记；例外按函数钉死）。
- **现状（本轮）**：✅ **PASS**。22 个写点全部命中 7 条规则或 2 条精确例外，0 未登记、0 非警察资源直写。**需代码修复**：`Sys.AssignUnit` 应改为调用 `P.AssignUnit`（或 `exports['custom-police']:AssignUnit`），修好后删除两条例外；目前它不影响运行，但状态机多了一个旁路。
- **例外**：2 条 `Sys.AssignUnit`（units + incidents），到期 `2027-03-31`；allowlist 只减不增。

### FIT-12 · 弃用登记（deprecated 写路径为 0 或未过期豁免）

- **规则**：任何被宣布"停止新写入"的表/命令/事件，其写路径必须为 0；未清完的必须在 `tests/architecture/deprecations.json` 登记（`kind`、`target`、`owner`、`reason`、`replacement`、`expected_writes`、`expires`），到期 FAIL。
- **为什么**：[B_PLAN.md](../B_PLAN.md) §2 明确"`police_arrests` 停止新写入；`police_bolos` 停止新写入"，但代码里 `police_arrests` 仍有 2 个写者，`police_bolos` 仍有 `CreateBolo`。**文档已经宣布弃用、代码还在写**，这是最坏的状态：读的人以为旧表是死的，实际上新旧两份都在长。同时 `GetBolos` 已经双源合并（`server/p3_cases.lua:96-135`），说明迁移方向是确定的，只是没执行完。
- **检查方式**（`tests/architecture/test_deprecations.py`）：对每条 entry 统计真实命中：`table` 数 `INSERT/UPDATE ... SET/DELETE` 写语句；`command` 数 `QBCore.Commands.Add`/`RegisterCommand` 注册；`event` 数 `RegisterNetEvent` 注册。命中数 > `expected_writes` → “新增债务” FAIL；`expires` 已过且仍命中 → FAIL；命中 0 → stale FAIL。带 `guard` 的 entry 还会校验 handler 体仍保留该守卫。人读镜像见 [deprecations.md](deprecations.md)。
- **失败信息**：`FIT-12: custom-police/server/p2_system.lua:118 still INSERTs police_arrests, deprecated since v3.4 (replacement: police_reports kind='arrest')`。
- **CI**：`Config & dependency checks`，blocking。
- **现状（本轮）**：✅ **PASS（已知债务 + 到期强制）**。登记 6 条：`police_arrests`（2 写）、`police_bolos`（2 写）、`/fine`（1）、`/911p`（1）、`police:server:JailPlayer`（1，`src ~= 0` 守卫）、`police:server:policeAlert`（1）。全部 `expires = 2026-12-31`；到期未清 → 红。`/jail` 已删除，因此不登记（登记会因 stale 而红）。
- **例外**：`police_arrests` 历史数据要保留（`GetArrests`/`GetCaseDetail` 继续读），登记只约束“写”；表级 allowlist 只豁免存量写并带到期日。

### FIT-13 · 文档数字与代码常量一致

- **规则**：05 / 02 / 09 里承诺的可执行数字（NPC 预算、冷却、NPC 警情调度、stale 窗口、intent TTL、outbox 重试）必须与代码常量或 SQL interval 一致；不一致 → FAIL 并打印两侧数值。允许 `【建议】` 值与代码不同，但必须在 `number_budget.json` 显式标 `kind: proposed`；`kind: implemented` 则必须有代码 pattern。
- **为什么**：文档里的"2 人 / 60 s / 8 min / 30% / 45 min / 7 天 / 10 分钟 / 30 秒 / 5 次"是**唯一**的性能与安全承诺来源。代码改常量、文档不改，下一个 agent 就会按错的预算做设计；本仓库已经出现过 `MAX_MINUTES` 与 justice `MaxSentence` 两处上限（05 COMPAT-03）。
- **检查方式**（`tests/architecture/number_budget.json` + `test_number_budget.py`，离线、<0.1 s）：
  - **登记 11 个数字**：`implemented` 10 条 — backup per-player 2（`NPCBudget.MAX_PLAYER`）、cooldown 60（`BACKUP_COOLDOWN`）、NPC global 6（`NPCBudget.MAX_GLOBAL`）、callout interval 8 min（`NPCCallouts.INTERVAL_MS = 8 * 60 * 1000`）、chance 0.30（`NPCCallouts.SPAWN_CHANCE`）、stale 45 min（p0 的 `INTERVAL 45 MINUTE`）、intent done 7 天 / pending 10 分钟（p2_system 的 `INTERVAL 7 DAY` / `INTERVAL 10 MINUTE`）、outbox interval 30 s（`OUTBOX_INTERVAL_MS = 30000`，scale 0.001）、max attempts 5（`OUTBOX_MAX_ATTEMPTS`）；`proposed` 1 条 — audit retention 180 天（05 SCALE-05 / SEC-05 目标值，代码尚无 retention 任务）。
  - **比对**：每条代码 pattern 捕获值 × `scale` 必须等于 `value`；每条文档 pattern 的所有命中都必须等于 `value`。当前 31 条文档引用覆盖 05/02/09 三篇、4 个代码文件；任何一侧改数字都会打印 `file:line says X, expected Y`。
  - **反向测试**：把 05 的"每玩家 ≤2 单位"改成 ≤3、把 `NPCBudget.MAX_PLAYER` 改成 3、把 `OUTBOX_INTERVAL_MS` 改成 60000，评估器都必须报红；删掉文档短语也会报 `did not match`。
- **失败信息**：`FIT-13: docs/police/architecture/05-nfr.md:60 says 3 for npc-budget-per-player, expected 2`。
- **CI**：`pytest -q tests/architecture`，blocking（映射显式登记，不靠正则猜措辞）。
- **现状（本轮）**：✅ **PASS**。10 个实现值全一致，1 个建议值（audit retention 180 天）显式标 `proposed`；三篇文档 31 处引用全部命中且相等。**未改代码**；代码若改预算，FIT-13 会先红，强制同一 PR 更新 05/02/09。
- **例外**：`police-audit-retention` 是唯一的 `proposed` 值；实现保留/归档任务后必须把 `kind` 改为 `implemented` 并补 code pattern，否则本规则会一直提醒它只是目标。

---

## 3. 检查器实现约定

1. **只读**：检查器不修改任何文件，不写缓存（CI 可复现）。
2. **确定性**：不依赖文件系统遍历顺序；所有输出按 `(rule, path, line)` 排序。
3. **假阴性优先**（重复强调）：解析失败的构造输出 SKIP 而非 FAIL，`--strict` 才把 SKIP 当失败。理由：一条天天红的规则会在两周内被 `--advisory` 掉，等于没有。
4. **单文件可定位**：每条 finding 必须包含 `path:line`，不允许只报"有 3 个问题"。
5. **不与现有脚本重复**：`check_cfgs.py`、`check_dependencies.py`、`check_bus_wiring.py`、`check_db_schema.py`、`light_lint.py` 保持原样并由 `tests/run_all.py` 继续调度；新检查器只补它们不覆盖的部分，FIT-10 以"调用现有脚本的解析函数"方式复用（Python 同进程 import，不 subprocess）。
6. **本地一键**：`python3 T-CityLite.base/tests/architecture/check_architecture.py --all --strict`，与 CI 完全同参。

---

## 4. CI 接线

| Job（现有） | 新增 step | 覆盖规则 | 门禁 | 预算 |
|---|---|---|---|---|
| `Config & dependency checks` | `Architecture fitness (static)` | FIT-01 02 03 04 05 06(静态) 07 10 11(adv) 12 | blocking（11 advisory） | <10 s |
| `Config & dependency checks` | `Agent tool registry drift`（**已有**） | FIT-08 | blocking | <2 s |
| `Python unit tests` | `pytest -q tests/architecture` | FIT-04 契约词表、FIT-05 形状、`error_codes.json` ↔ md 同步 | blocking | <5 s |
| `DB schema tests` | `Import schema fixture twice` + police 表存在性断言 | FIT-06（③④） | blocking | +20 s（MariaDB 已在） |
| `DB schema tests` | `pytest -q tests/unit` （已有，fixture 补齐后不再 skip police 用例） | FIT-06 的收益 | blocking | 现状 |
| `Docs links (advisory)` | `Number budget drift` | FIT-13 | advisory | <2 s |
| `Lua syntax (changed files)` | 无改动 | — | — | — |

**post-baseline 落地状态（`3bbcab3`）**：上表在 `3bbcab3` 时仍是**建议接线**，仓库里没有 `T-CityLite.base/tests/architecture/`。**本轮已落地** `test_duty_writer.py`（FIT-01）与既有 FIT-02/03/05/09/12 扫描器；`pytest -q tests/architecture` 即可运行。CI 里若尚未加 step，仍以本地 pytest 输出为准。

**为什么不新建 job**：6 个 job 的并行度已经足够，单条规则 <10 s 放进 `static-checks` 不拖慢反馈；新建 job 会让"必过检查"列表变长，反而降低执行力。

**上线顺序**（避免一次全红）：
1. 先合入检查器骨架 + FIT-08（已绿）+ FIT-06 静态（只报 fixture 缺失）；
2. 再补 allowlist（把当前 51 条违规**全部**登记，`expires` 分档），此时全绿——**绿是基线，不是修复**；
3. 然后按 §6 的顺序逐条收紧：先修代码、再删 allowlist 条目、最后去掉 `--advisory`。

---

## 5. 架构适应度评分卡（当前）

评分：PASS=1、PARTIAL=0.5、FAIL=0、UNKNOWN=0；权重 1–3（按"失败后的爆炸半径"）。

| # | 规则 | 权重 | 状态 | 状态分 | 加权分 | 关键证据 |
|---|---|---|---|---|---|---|
| FIT-01 | onduty 单一写者 | 3 | ✅ PASS | 1 | 3 | `test_duty_writer.py` 4 条 allowlist、0 未登记；警察写路径全部走 `SetDutyForSource`（p0 仅服务内 1 处 primitive） |
| FIT-02 | 跨资源表所有权 | 2 | ✅ PASS | 1 | 2 | 0 处未登记跨写；`phone_notifications`/`police_reports` 单写者；8 条存量 allowlist（2026-12-31） |
| FIT-03 | net event 鉴权 | 3 | ❌ FAIL | 0 | 0 | 2/44 强校验；9 条 evidence 仍零校验；**扫描器未落地（进行中）** |
| FIT-04 | export/action 错误码 + 审计 | 2 | ✅ PASS | 1 | 2.0 | `test_export_contracts.py` 46/46 export、0 未登记、11 条登记例外；GetUnits/GetIncidents 补 capability + 先审计后查询 + fail-closed；action 17/17 结构化 |
| FIT-05 | 审计 fail-closed | 3 | ❌ FAIL | 0 | 0 | 23 处 fail-open 未变；5 个读导出零审计 |
| FIT-06 | 迁移幂等 + fixture | 1 | ⚠️ PARTIAL | 0.5 | 0.5 | 迁移幂等 ✅（含 v3.8–v3.11）/ fixture 仍缺 14 张表 ❌ |
| FIT-07 | NPC 预算接口 | 2 | ⚠️ PARTIAL | 0.5 | 1.0 | backup 路径仍合规；NPC 警情新增独立 `CreatePed/CreateVehicle` 路径；全局 cap 缺 |
| FIT-08 | 注册表/生成物一致 | 1 | ✅ PASS | 1 | 1 | `agent_tools.py --check` 已进 CI（35 工具/21 动作未变） |
| FIT-09 | 查询纪律 | 2 | ❌ FAIL | 0 | 0 | 16 处 `SELECT *`，1 处无 LIMIT（未变） |
| FIT-10 | 资源接线 | 1 | ⚠️ PARTIAL | 0.5 | 0.5 | cfg/manifest/顺序 ✅；`p4_npc` 已接线，但导出依赖仍靠人 |
| FIT-11 | 状态机写者登记 | 2 | ⚠️ PARTIAL | 0.5 | 1.0 | 写者收敛到 p0/p2_system，但仍无登记表；p0 内 5 个 helper 是事实上的状态写入口 |
| FIT-12 | 弃用登记 | 1 | ✅ PASS | 1 | 1 | 6 条已知债务登记（2 表 + 2 命令 + 2 事件），全部 2026-12-31 到期 |
| FIT-13 | 数字漂移 | 1 | ❓ UNKNOWN | 0 | 0 | 当前代码常量（`MAX_ACTIVE=1`、8min、30%、45min）未进 05，无机制 |
| **合计** | | **24** | 快照未重算（FIT-01 本轮 +1.5、FIT-02/12 前轮 +3） | — | **待重算** | 上一轮 27 / 100；FIT-01 转 PASS 后待与 FIT-09 等历史行统一重算 |

按域看：

| 域 | 规则 | 得分 |
|---|---|---|
| 安全 / 取证（01 02 03 05） | 1 部分 / 3 红（03 工作区进行中） | **1.5 / 11 ≈ 14%** |
| 契约 / 边界（04 09 10 12） | 1 部分 / 3 红 | **1.0 / 6 ≈ 17%** |
| 数据 / 迁移（06） | 部分 | **0.5 / 1 = 50%** |
| 资源预算（07） | 部分（新增 NPC 警情生成路径） | **1.0 / 2 = 50%** |
| 工具链（08） | 通过 | **1 / 1 = 100%** |
| 状态机（11） | 部分 | **1.0 / 2 = 50%** |
| 文档（13） | 未知 | **0 / 1 = 0%** |

**读法（post-baseline）**：27 分（基线 21）的增量来自 4 条真实修复（duty 投影、incident 关闭/幂等、custody 服务端计时、迁移覆盖），不是评分口径变化。本轮 FIT-02/FIT-12 转 PASS，加权分至少 +3（6.5 → 9.5 / 24），上表的 PASS/PARTIAL/FAIL 计数与总分留待下一轮统一重算。分数仍不代表"系统坏了"——功能测试是绿的；它代表"架构约束是否被自动化保护"。目标不变：P7 末 ≥70，v1.0 前 ≥85。

---

## 6. 最该先加的 3 条（+1 个快速胜利）

按"失败后的爆炸半径 ÷ 落地成本"排序：

1. **FIT-03 net event 鉴权（进行中，未提交）**（3 天含 allowlist）
   - 唯一一条能立刻量化"我们现在能被怎么打"的规则：**44 个事件、2 个强校验、9 个完全不设防**。allowlist 允许存量，所以**合入当天就能 blocking**，不会阻塞任何在飞的功能分支。
   - **状态**：HEAD `3bbcab3` 上扫描器尚未落地；**工作区（未提交）**已有 `tests/architecture/test_net_event_auth.py` + allowlist，`evidence.lua` 也加了 capability 校验。提交前不要把 HEAD 当成“已加扫描器”。
   - 落地同时产出 allowlist（工作区实际文件：`tests/architecture/net_events_allowlist.json`），这份文件本身就是安全待办清单（按 `weak_auth` / `no_auth` 排序）。
   - 先修的不是 27 个弱校验，而是 9 个 evidence 事件——它们能被平民客户端直接调用。

2. **FIT-05 审计 fail-closed**（2~3 天含修 16 处：`p1` 3 + `p2_evidence` 3 + `p3` 10；post-baseline 又 +`p4_npc` 2，仍未修）
   - 取证面是本系统唯一的"事后真相"。现在 DB 抖一下，罚单/报告/案件就静默无审计，而**没有任何地方会知道**。这条规则的修复量很小（16 个 `if not audit(...) then return ... end`，其余 7 处低风险调用随后收敛），但把 05 NFR-SEC-04 从"部分"变成"可承诺"。
   - 顺带解决 FIT-04 的一半（审计消费是同一批代码）。

3. **FIT-01 onduty 单一写者**（✅ 本轮完成）
   - `custom-police:SetDutyForSource` 成为唯一警察写入口；`custom-main`/`custom-director` 只保留非警察直写，扫描器 + 4 条 allowlist 已 blocking。
   - 后续只剩收尾：把非警察分支也抽象成统一 duty 服务时删 allowlist，并评估 qb-core `QBCore:ToggleDuty` 是否改调服务（需要改 qb-core，当前约束下不做）。

**快速胜利（1 小时，建议顺手做）**：**FIT-06 的 fixture 补齐**。`tests/fixtures/tcity_schema.sql` 缺 14 张表（12 张 `police_*` + `police_write_intents` + `justice_sentences`，TD-05），补上即可让 DB 集成用例从 skip 变 run——这是全仓库性价比最高的一小时，且它让 FIT-06 从 PARTIAL 直接转 PASS（+0.5 分），也为 05 NFR-REL-06 的"恢复演练"提供了可重放的 schema。

**已先做的一步**：FIT-02（跨资源写）已在本轮落地——`custom-phone:Notify` 与 `custom-police:RecordVerdict` 两个 owner 导出 + 扫描器，剩余只在 allowlist 里的历史债务。教训是：先加导出、再改调用方、最后开扫描器，三步可以在一个变更里完成，不必等 FIT-03/05。

---

## 7. 维护约定

- **allowlist 只减不增**：每个 PR 必须让条目数 `≤` 基线；新增条目需在 PR 描述里写明 `why` 与 `ticket`。
- **每季度 review**：过期条目 = CI 红，强制处理（这是"技术债有利息"的机器化版本）。
- **规则本身可改**：如果某条规则连续 4 周误报 >5%，先改规则（提高精确率），不要加 allowlist——allowlist 膨胀比误报更危险。
- **新增警察写路径时**：FIT-01/02/03/05/11 会自动拦；如果拦错了（例如合法的系统入口），正确做法是加**规则内的例外类型**，不是给文件开白名单。

## 8. 附录：现状数据来源

| 数字 | 来源 |
|---|---|
| 44 net events / 42 police 服务端 exports | `grep -c RegisterNetEvent( server/*.lua` / `grep -c '^exports(' server/*.lua`（含 `p4_npc.lua`） |
| 2 强校验事件 | `server/main.lua:198`、`server/interactions.lua:139`（人工核对 44 个 handler） |
| 9 个 evidence 事件 | `server/evidence.lua:64,69,78,86,95,108,121,139,148` |
| 16 处 `SELECT *` | `grep -n "SELECT \*" server/*.lua` |
| 14 张 fixture 缺表 | 迁移 `v2.8`–`v3.11` 的 `CREATE TABLE` 集合（12 police + `police_write_intents` + `justice_sentences`） − `tests/fixtures/tcity_schema.sql` 的 47 张表 |
| 4 个 onduty 写者 | `custom-main/server/dispatch.lua:236,261`、`custom-director/server/main.lua:619-645` + 定义/服务两处 |
| 6 处跨资源写 | `server/p0.lua:171-179`、`server/p1.lua:23-33`、`server/p2_system.lua:45-52`、`server/p4_npc.lua:78-90`、`custom-justice/server/trial.lua:30-49`（另 `apps/police_mdt.lua:268-270`） |
| 14/17 action 压平 | `custom-phone/server/apps/police_mdt.lua:168-284`（仅 `report_submit`/`request_backup` 透传表；13 个 `ok and res ~= false` + `arrest_submit`；`alert` 特例；post-baseline 数量不变） |
| 迁移幂等 | `migrations/v2.8`–`v3.7` 逐个人工核对（`IF NOT EXISTS` / `information_schema` 守卫），无 `DROP TABLE`/`TRUNCATE` |
