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
| FIT-01 | `job.onduty` 只有一个写者（duty 服务） | 状态一致性 | ⚠️ PARTIAL | advisory → blocking |
| FIT-02 | 禁止跨资源写别人拥有的表 | 边界 | ✅ PASS（`test_cross_resource_writes.py`；0 处未登记跨写） | blocking |
| FIT-03 | 每个 net event 必须有来源/权限校验 | 安全 | ✅ PASS（3e720bf；13 强鉴权 + 35 登记例外，0 未登记） | blocking |
| FIT-04 | 每个 export / app action 必须有稳定错误码 + 审计 | 契约 | ⚠️ PARTIAL | blocking |
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

---

## 1. 落地形态

### 1.1 文件布局（建议）

```
T-CityLite.base/tests/architecture/          # 已落地文件（其余规则按需新增）
├── test_net_event_auth.py       # FIT-03
├── test_query_discipline.py     # FIT-09
├── test_cross_resource_writes.py + table_owners.json   # FIT-02（owner 表 + 跨写 allowlist）
├── test_deprecations.py + deprecations.json            # FIT-12（弃用登记 + 到期强制）
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

- **规则**：`PlayerData.job.onduty` 的写入只允许出现在 duty 服务（`core-framework/services/job_service.lua` 的 `SetOnDuty`）与 qb-core 的定义处（`qb-core/server/player.lua` 的 `SetJobDuty`，作为兼容投影）。其他资源必须调用 `Bus.JobService.SetOnDuty` 或触发 `QBCore:ToggleDuty`。
- **为什么**：TD-01 的根因。当前 4 个写者（`custom-main/server/dispatch.lua:236,261`、`custom-director/server/main.lua:619-645`、plus 定义与 JobService），导致 `onduty=true` + `police_units=off_duty` 这类组合合法存在；权限、MDT、派单各读一套（`TECH_DEBT.md` TD-01）。在没有这条规则之前，"单一状态机"永远只是文档里的一句话。
- **检查方式**：
  - 扫描范围：`resources/**/server/**.lua`（排除 `client/`、`web/`、`custom-testing/`、`tests/`）。
  - 正则（写入）：`\.job\.onduty\s*=(?!=)`、`SetJobDuty\s*\(`、`SetOnDuty\s*\(`、`^[^-\n]*\.onduty\s*=\s*(true|false|not)`。
  - 伪代码：
    ```
    for path in server_lua_files:
        for no, line in lines(path):
            if WRITE_RE.search(strip_comment(line)):
                rel = relpath(path)
                if rel not in ONDUTY_WRITERS and rel not in allowlist:
                    report(rel, no, "onduty_write")
    ```
  - 读侧子规则（advisory）：`data.job.onduty` 的读取必须紧跟 `GetPlayer(source)` 取得的最新 `PlayerData`，不得缓存到模块级变量。检查方式：模块级 `local .* = .*PlayerData` 赋值 → 警告。
- **失败信息**：`FIT-01: <file>:<line> writes job.onduty directly; call Bus.JobService.SetOnDuty (owner: core-framework/services/job_service.lua) — see TD-01`。
- **CI**：`Config & dependency checks` job 新增 step `Architecture fitness (FIT-01..)`；初期 `--rule FIT-01 --advisory`（只打印、不失败），duty 服务落地后同一 step 去掉 `--advisory` 即变 blocking。
- **现状（post-baseline）**：⚠️ **PARTIAL**。`custom-police` 已把 10-8/10-7/自动 park 全部改为调用 qb-core 的 `SetJobDuty` 投影（`server/p0.lua:109,578,587`），`syncDuty` 不再在每次 JobUpdate 重置任务态（`406-425`）；但**违规写者仍在**：`custom-main/server/dispatch.lua:236,261`、`custom-director/server/main.lua:619-645`（agent `set_job_duty`，L2 人审）。许可写者/服务未变。扫描器**未实现**，`--advisory` 也没有接线，所以这条仍是“靠人看”。
- **例外**：`custom-director` 的 `set_job_duty` 在 duty 服务提供 `SetOnDuty` 之前保留，allowlist 至 `2026-12-31`，到期必须改为调用服务或下线该动作。

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
  3. 返回的字面量必须存在于 `error_codes.json`（新增错误码 = 显式 diff + 更新 `docs/police/architecture/error-codes.md`）；
  4. **action 层不得把错误码压成布尔**：`PhoneApps` action handler 必须返回 `{ok=false,error=...}` 或原样透传，不得 `return ok and res ~= false`。
- **为什么**：MDT 是唯一接警 UI，用户看到的错误文案完全取决于 action 层有没有把码透传。17 个 action 里只有 2 个（`report_submit` / `request_backup`）透传结构化结果，14 个把 `cooldown`/`limit`/`rank_too_low`/`not_on_duty` 全压平（13 个 `ok and res ~= false` + `arrest_submit`），`alert` 为特例（成功 `{sent}`、失败压平）（`custom-phone/server/apps/police_mdt.lua:167-275` + `custom-phone/server/phone_apps.lua:138-142`），玩家只能看到"失败"。
- **检查方式**：
  - 函数体提取：`exports('<Name>', <sym>)` → 找 `function <sym>(` 或 `<sym> = function`，切到顶格 `end`；
  - 伪代码：
    ```
    for name, body in exports(path):
        if WRITE_RE.search(body) and not AUDIT_RE.search(body):
            report(path, "export %s mutates without audit" % name)
        for ret in RETURN_RE.finditer(body):
            expr = ret.group(1).strip()
            if expr in ('', 'nil', 'false'): report(..., "bare return")
            if STRING_LITERAL_RE.search(expr) and literal not in CODES: report(..., "unknown_code")
    for action in phone_app_actions():
        if not RETURNS_TABLE_OR_PASSTHROUGH: report(..., "code_collapsed")
    ```
- **失败信息**：`FIT-04: custom-phone/server/apps/police_mdt.lua:222 action issue_citation collapses error code to boolean; return the {ok=false,error} table so the MDT can localise it`。
- **CI**：`Python unit tests` job（`tests/architecture` 走 pytest）或独立 step；blocking。
- **现状（post-baseline）**：⚠️ **PARTIAL**。`ArrestSubmit`/`ReportSubmit` 现在返回完整 `{ok=true,...}` / `{ok=false,error}`，并补齐 citation/evidence 独立审计（`p2_system.lua:766-797`）；错误码新增 `invalid_idempotency_key`/`in_progress`；`SetIncidentStatus` 新增 `invalid_disposition`/`invalid_transition`。**仍红**：action 层压缩 14/17（`police_mdt.lua:168-284`，新增 NPC 契约不经过 action，所以数量不变）；`Sys.Jail` 仍不消费 audit（`p2_system.lua:121`）；`already_<status>` 仍是动态码（`p1.lua:156`）。
- **例外**：`GetUnits` / `GetIncidents` / `GetCharges` 这类纯读返回表，不需要错误码；但 `GetUnits`/`GetIncidents` **仍没有 capability 检查**（`server/p0.lua:123-142,185-210`，等同 FLOW B10），应在 FIT-03 的"读导出"扩展里补，或明确登记为"靠 phone audience 兜底"。

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
  1. `configs/modules/*.cfg` 里 `ensure` 的资源都有 `fxmanifest.lua`（已有 `check_cfgs.py`）；
  2. `fxmanifest` 里列出的每个 `server_scripts`/`client_scripts` 文件都存在，且仓库里没有"存在但未接线"的警察脚本（反向检查）；
  3. 每个 `exports('<Name>')` 的生产者与消费者在同一资源或通过 `dependencies` 声明；
  4. 启动顺序满足依赖（已有 `check_dependencies.py`）。
- **为什么**：TD 里没有这一条，但它是"改完 manifest 忘了重启/忘了加文件"的机器化版本（`STATUS.md` 已警告"改 fxmanifest 或新增 server 文件后必须整服重启"）。第 3 条尤其重要：`custom-police` 依赖 `custom-phone` 的 app 注册、`custom-justice` 的导出，但依赖方向只写在文档里。
- **检查方式**：复用 `check_cfgs.py` / `check_dependencies.py` / `check_bus_wiring.py` 的解析逻辑；新增 ② 反向检查（对比 `custom-police/{server,client}/*.lua` 与 `fxmanifest.lua` 的 `server_scripts`/`client_scripts` 列表）与 ③ 导出消费者扫描（`exports['<res>']:<Name>` 的 `<res>` 必须在 `fxmanifest` 的 `dependencies` 里）。
- **失败信息**：`FIT-10: custom-police/fxmanifest.lua does not list server/p2_system.lua — a new file needs a manifest entry and a full restart`。
- **CI**：`Config & dependency checks`（三个 step 已存在，新增反向检查）；blocking。
- **现状**：⚠️ **PARTIAL**。①②④ 大体由现有脚本覆盖（`ci.yml:35-45`）；③ **未覆盖**——`custom-police` 调 `exports['custom-justice']`、`exports['qb-core']`、`exports['qb-inventory']`、`exports['custom-phone']`（经 phone app 反向调用），依赖声明靠人。
- **例外**：无。

### FIT-11 · 状态机列只允许登记过的写者

- **规则**：`police_incidents.status`、`police_units.status`、`police_units.incident_id`、`police_citations.status`、`police_warrants.status`、`police_evidence.status` 的 `UPDATE` 只允许出现在登记的状态函数内；新增写者必须改登记表。
- **为什么**：状态列是最容易被"顺手写一行"破坏的地方。当前 `police_incidents.status` 有 3 个写者（`server/p0.lua:154,172`、`server/p2_system.lua:93`），`police_units.status` 有 5 个（`server/p0.lua:47,175,177,266`、`server/p2_system.lua:92`）。它们都在同一资源内、语义也说得通，但没有任何东西阻止第 6 个出现——而状态机一旦多点写，05 COMPAT-01 的"单一状态机"就永远收不回来。
- **检查方式**：
  ```
  for path in custom_police_server_files:
      for sql in sql_strings(path):
          if re.search(r"UPDATE\s+police_\w+\s+SET\s+.*\b(status|incident_id)\s*=", sql, re.I|re.S):
              fn = enclosing_function(path, sql.position)
              if (path, fn.name) not in STATE_WRITERS: report(path, fn.line, "unregistered status writer")
  ```
- **失败信息**：`FIT-11: custom-police/server/p0.lua:175 updates police_units.status outside the registered state functions — register it in allowlists/state_writers.json or route it through SetUnitStatus`。
- **CI**：`Config & dependency checks`，**advisory**（等 FIT-01/duty 状态机落地后再转 blocking，否则会在重构期持续红）。
- **现状**：⚠️ **PARTIAL**。8 个写者全在同一资源内、逻辑自洽；但没有登记表，也就没有"谁是新来的"这一判断。**注意**：`syncDuty`（`server/p0.lua:262-270`）是"从 onduty 投影到 units"的唯一合法入口，FIT-01 收敛后它应当是唯一写者。
- **例外**：登记现有 8 个（路径 + 函数名），到期 `2027-03-31`。

### FIT-12 · 弃用登记（deprecated 写路径为 0 或未过期豁免）

- **规则**：任何被宣布"停止新写入"的表/命令/事件，其写路径必须为 0；未清完的必须在 `tests/architecture/deprecations.json` 登记（`kind`、`target`、`owner`、`reason`、`replacement`、`expected_writes`、`expires`），到期 FAIL。
- **为什么**：[B_PLAN.md](../B_PLAN.md) §2 明确"`police_arrests` 停止新写入；`police_bolos` 停止新写入"，但代码里 `police_arrests` 仍有 2 个写者，`police_bolos` 仍有 `CreateBolo`。**文档已经宣布弃用、代码还在写**，这是最坏的状态：读的人以为旧表是死的，实际上新旧两份都在长。同时 `GetBolos` 已经双源合并（`server/p3_cases.lua:96-135`），说明迁移方向是确定的，只是没执行完。
- **检查方式**（`tests/architecture/test_deprecations.py`）：对每条 entry 统计真实命中：`table` 数 `INSERT/UPDATE ... SET/DELETE` 写语句；`command` 数 `QBCore.Commands.Add`/`RegisterCommand` 注册；`event` 数 `RegisterNetEvent` 注册。命中数 > `expected_writes` → “新增债务” FAIL；`expires` 已过且仍命中 → FAIL；命中 0 → stale FAIL。带 `guard` 的 entry 还会校验 handler 体仍保留该守卫。人读镜像见 [deprecations.md](deprecations.md)。
- **失败信息**：`FIT-12: custom-police/server/p2_system.lua:118 still INSERTs police_arrests, deprecated since v3.4 (replacement: police_reports kind='arrest')`。
- **CI**：`Config & dependency checks`，blocking。
- **现状（本轮）**：✅ **PASS（已知债务 + 到期强制）**。登记 6 条：`police_arrests`（2 写）、`police_bolos`（2 写）、`/fine`（1）、`/911p`（1）、`police:server:JailPlayer`（1，`src ~= 0` 守卫）、`police:server:policeAlert`（1）。全部 `expires = 2026-12-31`；到期未清 → 红。`/jail` 已删除，因此不登记（登记会因 stale 而红）。
- **例外**：`police_arrests` 历史数据要保留（`GetArrests`/`GetCaseDetail` 继续读），登记只约束“写”；表级 allowlist 只豁免存量写并带到期日。

### FIT-13 · 文档数字与代码常量一致

- **规则**：05 与 07 里出现的可执行数字（NPC 上限、冷却、刑期上下限、罚单滑轨、查询 LIMIT、48 人）必须与代码常量一致；不一致 → FAIL 并打印两侧数值。
- **为什么**：文档里的"2 人 / 60 s / 120 分钟 / ±20% / LIMIT 50"是**唯一**的性能与安全承诺来源。代码改常量、文档不改，下一个 agent 就会按错的预算做设计（本仓库已经出现过 `MAX_MINUTES` 与 justice `MaxSentence` 两处上限，05 COMPAT-03）。
- **检查方式**：
  ```
  pairs = [
    ("BACKUP_MAX_UNITS",        r"BACKUP_MAX_UNITS\s*=\s*(\d+)",        05, "每玩家 ≤2"),
    ("BACKUP_COOLDOWN",         r"BACKUP_COOLDOWN\s*=\s*(\d+)",         05, "冷却 60 s"),
    ("MAX_MINUTES",             r"local MAX_MINUTES\s*=\s*(\d+)",       05, "刑期上限 120"),
    ("CITATION_HIGH",           r"local CITATION_HIGH\s*=\s*([\d.]+)",   05, "±20%"),
    ("MAX_CHARGES",             r"local MAX_CHARGES\s*=\s*(\d+)",       07, "≤8 罪名"),
    ("mdt row limit",           r"LIMIT (\d+)",                         05, "行数 ≤50"),
  ]
  对每组：从文档表格里解析目标值，与代码常量比对
  ```
- **失败信息**：`FIT-13: 05-nfr.md says NPC cap = 2 per player, code BACKUP_MAX_UNITS = 3 — update the doc and the budget together`。
- **CI**：`Docs links (advisory)` 旁边新增 step；**advisory**（文档措辞多变，先观察误报率）。
- **现状**：❓ **UNKNOWN**。当前实际一致（`BACKUP_MAX_UNITS=2`、`BACKUP_COOLDOWN=60`、`MAX_MINUTES=120`、`CITATION 0.8/1.2`、`MAX_CHARGES=8`、`LIMIT 50`），但没有任何机制防止漂移，且 05 里大部分数字是**建议值**（还没有对应常量），所以这条规则要等 §6 之后才有意义。
- **例外**：文档表格里标注为"建议值"的列不参与比对，只比对与代码常量对应的目标值列；新增映射需在 `number_budget.json` 显式登记，不允许靠正则猜。

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
| `Config & dependency checks` | `Architecture fitness (static)` | FIT-01(adv) 02 03 04 05 06(静态) 07 10 11(adv) 12 | blocking（01/11 advisory） | <10 s |
| `Config & dependency checks` | `Agent tool registry drift`（**已有**） | FIT-08 | blocking | <2 s |
| `Python unit tests` | `pytest -q tests/architecture` | FIT-04 契约词表、FIT-05 形状、`error_codes.json` ↔ md 同步 | blocking | <5 s |
| `DB schema tests` | `Import schema fixture twice` + police 表存在性断言 | FIT-06（③④） | blocking | +20 s（MariaDB 已在） |
| `DB schema tests` | `pytest -q tests/unit` （已有，fixture 补齐后不再 skip police 用例） | FIT-06 的收益 | blocking | 现状 |
| `Docs links (advisory)` | `Number budget drift` | FIT-13 | advisory | <2 s |
| `Lua syntax (changed files)` | 无改动 | — | — | — |

**post-baseline 落地状态（`3bbcab3`）**：上表仍是**建议接线**，没有实现。仓库里没有 `T-CityLite.base/tests/architecture/`，`ci.yml` 也没有 `Architecture fitness` / `pytest -q tests/architecture` / `Number budget drift` 这几个 step；FIT-08 的 `agent_tools.py --check` 仍存在。所以本轮 07 的所有状态都是**人工复评**，不是 CI 输出——这也是 FIT-03/05 仍标 FAIL 的原因。

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
| FIT-01 | onduty 单一写者 | 3 | ⚠️ PARTIAL | 0.5 | 1.5 | police 侧已全部走 `SetJobDuty` 投影（`p0.lua:109,578,587`）；`custom-main`/`custom-director` 仍有写者 |
| FIT-02 | 跨资源表所有权 | 2 | ✅ PASS | 1 | 2 | 0 处未登记跨写；`phone_notifications`/`police_reports` 单写者；8 条存量 allowlist（2026-12-31） |
| FIT-03 | net event 鉴权 | 3 | ❌ FAIL | 0 | 0 | 2/44 强校验；9 条 evidence 仍零校验；**扫描器未落地（进行中）** |
| FIT-04 | export/action 错误码 + 审计 | 2 | ⚠️ PARTIAL | 0.5 | 1.0 | arrest/report 已结构化 + citation/evidence 审计；action 层仍压平 14/17 |
| FIT-05 | 审计 fail-closed | 3 | ❌ FAIL | 0 | 0 | 23 处 fail-open 未变；5 个读导出零审计 |
| FIT-06 | 迁移幂等 + fixture | 1 | ⚠️ PARTIAL | 0.5 | 0.5 | 迁移幂等 ✅（含 v3.8–v3.11）/ fixture 仍缺 14 张表 ❌ |
| FIT-07 | NPC 预算接口 | 2 | ⚠️ PARTIAL | 0.5 | 1.0 | backup 路径仍合规；NPC 警情新增独立 `CreatePed/CreateVehicle` 路径；全局 cap 缺 |
| FIT-08 | 注册表/生成物一致 | 1 | ✅ PASS | 1 | 1 | `agent_tools.py --check` 已进 CI（35 工具/21 动作未变） |
| FIT-09 | 查询纪律 | 2 | ❌ FAIL | 0 | 0 | 16 处 `SELECT *`，1 处无 LIMIT（未变） |
| FIT-10 | 资源接线 | 1 | ⚠️ PARTIAL | 0.5 | 0.5 | cfg/manifest/顺序 ✅；`p4_npc` 已接线，但导出依赖仍靠人 |
| FIT-11 | 状态机写者登记 | 2 | ⚠️ PARTIAL | 0.5 | 1.0 | 写者收敛到 p0/p2_system，但仍无登记表；p0 内 5 个 helper 是事实上的状态写入口 |
| FIT-12 | 弃用登记 | 1 | ✅ PASS | 1 | 1 | 6 条已知债务登记（2 表 + 2 命令 + 2 事件），全部 2026-12-31 到期 |
| FIT-13 | 数字漂移 | 1 | ❓ UNKNOWN | 0 | 0 | 当前代码常量（`MAX_ACTIVE=1`、8min、30%、45min）未进 05，无机制 |
| **合计** | | **24** | 快照未重算（FIT-02/12 本轮 +3 加权分） | — | **9.5（待重算）** | 上一轮 6.5 / 24 = 27 / 100；本轮 FIT-02/12 转 PASS 后待统一重算 |

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

3. **FIT-01 onduty 单一写者**（police 侧已收敛 `bb64d87`，还剩 `custom-main`/`custom-director` 两个写者 + 扫描器）
   - 它是 TD-01 的机器化表达。即使现在不修代码，这条规则也会在**每次新增写者时**提醒"你在加深 TD-01"。等 §05 COMPAT-01 的 4 个待定项拍板、`Bus.JobService.SetOnDuty` 成为唯一入口后，删 allowlist + 去 `--advisory` 即可。
   - 之所以放在第 3 而不是第 1：它的修复依赖产品决策，而 FIT-03/05 不依赖。

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
