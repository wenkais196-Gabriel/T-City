# 警察 P0 真实服务端 E2E（`police_e2e`）

> 套件：`custom-testing/suites/10_police_e2e.lua`
> 运行：服务器控制台 `/test run police_e2e`
> 定位：**开发/测试服**用真实 FXServer export + MySQL 断言覆盖警察 P0 主链路，
> 不替代进服人工验收（`LIVE_ACCEPTANCE.md`）。

## 1. 为什么需要新套件

现有的 `02_police_test.lua` 是布尔模拟：它把 `onduty = not onduty`、
`priority >= 3` 这类条件直接写死，既不调用 `custom-police` export，也不读数据库。
因此它无法发现下面这些真实故障：

- export 参数顺序/返回值变化；
- `police_incidents` / `police_units` / `police_outbox` 写入失败；
- 状态机（`open → assigned → closed`）被绕过或无法推进；
- 审计 `police_audit` 缺失；
- `custom-justice` 的 `justice_sentences` 与 export 返回值不一致；
- outbox worker 没有把通知落库。

`police_e2e` 用测试命名空间在真实服务端跑完整链路，每一步都同时断言
**系统 export 的返回值**、**数据库落库结果**和（可用的）**审计行**。

## 2. 运行方式

### 2.1 前置条件

```cfg
# T-CityLite.base/configs/modules/dev.cfg（当前仓库已包含）
ensure custom-testing
```

同时保证以下资源已启动：

- `custom-police`（P0 dispatch / outbox / NPC budget）
- `custom-justice`（sentence）
- `custom-phone`（`Notify`，outbox worker 的投递目标）
- `oxmysql` / `qb-core`

数据库需已执行 `migrations/v2.8_police_p0.sql`、`v3.8_justice_sentences.sql`、
`v3.10_police_incident_disposition.sql`、`v3.12_police_outbox.sql`。

### 2.2 命令

```text
/test list                 # 确认存在 police_e2e
/test run police_e2e       # 只跑本套件
```

`/test run` 现在会把 runner 放进 `CreateThread`，因此套件内部可以安全使用
`Wait()` / `MySQL.*.await()`。套件是**单个异步用例**，内部按固定顺序执行
多个 step；即使某一步失败，也会继续执行后续可执行步骤并最终清理。

### 2.3 正常输出

```text
═══════════════════════════════════════════════
  测试套件: police_e2e (1 个用例)
═══════════════════════════════════════════════
[E2E] ✅ cleanup.prepare                 3ms
[E2E] ✅ npc_budget.baseline             2ms
[E2E] ✅ incident.create                 18ms
[E2E] ✅ incident.assign                 12ms
[E2E] ⏭️ SKIP incident.close — 无在线且上班的警察；...
[E2E] ✅ npc_budget.unchanged            1ms
[E2E] ✅ outbox.delivery                420ms
[E2E] ✅ sentence.apply                  8ms
[E2E] ✅ sentence.adjust                 7ms
[E2E] ✅ sentence.release                9ms
[E2E] ⏭️ SKIP duty.probe — 无在线且上班的警察；...
[E2E] ✅ cleanup.final                   9ms
[E2E] ─── 结果: ✅ 9 PASS | ❌ 0 FAIL | ⏭️ 2 SKIP ───
E2E_RESULT {"suite":"police_e2e","ok":true,"exit_code":0,...}
E2E_EXIT 0
```

最后两行给 agent / CI 解析：`E2E_RESULT` 是单行 JSON，`E2E_EXIT` 是 0/1。
FXServer 控制台没有“进程退出码”这个概念；`E2E_EXIT 1` 是可读的失败标记，
不是 `os.exit()`，不会杀掉服务器。

## 3. 覆盖范围

| step | 调用的真实 export | 数据库/行为断言 | 审计断言 |
|---|---|---|---|
| `cleanup.prepare` | — | 删除上一次异常运行残留的 E2E 数据 | 保留 |
| `npc_budget.baseline` | `custom-police:GetNpcBudget` | `used/max` 为数字、`used == sum(entries.slots)`、`max >= used` | — |
| `incident.create` | `CreateIncidentSystem` | `police_incidents.status='open'`、标题、`created_by='agent:e2e'` | `incident.create`，`actor_kind='agent'` |
| `incident.assign` | `AssignUnitSystemForAgent` | 预置 `police_units.available`；`police_incidents.assigned`、`police_incident_units` 成员、unit 绑定 incident | `incident.assign`，target=incident id，detail=测试 unit |
| `incident.close` | `SetIncidentStatus` | `status='closed'`、`disposition='cleared'`、`closed_by`/`closed_at`、测试 unit 释放回 `available` | `incident.close`，detail=`cleared` |
| `npc_budget.unchanged` | `GetNpcBudget` | 前后 `used/max` 一致，无 E2E 单位占用 | — |
| `outbox.delivery` | `EnqueueOutbox` + 真实 worker | 10s 内 `police_outbox.status='done'`，`phone_notifications` 有对应行且 `app_id='police_mdt'` | outbox 无 police_audit |
| `sentence.apply` | `custom-justice:ApplySentence` | `justice_sentences` active、`case_id='E2E'`、`minutes=1`、`created_by` | justice 不写 police_audit |
| `sentence.adjust` | `AdjustSentence(-1)` | 剩余 0 秒，status=`expired`，`released_at` 非空；再次 `ReleaseSentence` 返回幂等 `false` | — |
| `sentence.release` | `ApplySentence` + `ReleaseSentence` | 第二次 1 分钟后成功 `released`，`released_at` 非空 | — |
| `duty.probe` | `SetDutyForSource` | 在线警察同值设置返回 true | `duty.set`，detail 前缀 `on:` / `off:` |
| `cleanup.final` | — | E2E_* 残留为 0 | 清理后 `incident.create` 审计仍存在 |

### 3.1 条件步骤与跳过原因

| step | 条件 | 为什么 |
|---|---|---|
| `incident.close` | 必须有在线且 `onduty` 的 `police` 玩家，grade ≥ 1；grade < 2 时其 `police_units.status` 不能是 `busy/assigned/enroute/on_scene/unavailable` | `SetIncidentStatus(source, ...)` 只接受玩家 source；不存在系统/agent 的 close export。**不用直接 SQL 伪造 `enroute/on_scene/closed`**。若在线警察 grade < 2，先通过真实 `AssignUnit` 补齐成员关系（grade 1 单人接警的最小合法路径），再关单；为避免抢占正在处理其他警情的真实 unit，忙时直接 SKIP。 |
| `duty.probe` | 必须有在线且 `onduty` 的 `police` 玩家 | `SetDutyForSource` 与 `job.onduty` 绑定在在线 PlayerData 上。只做同值探测，不改变玩家真实上下班状态。 |
| `npc_budget` 写路径 | 无 | `NPCBudget.Acquire/Release` 是资源内全局函数，**没有 export**；只有 `GetNpcBudget` 导出。因此只做只读快照 + 前后无泄漏对比，用 `EnqueueOutbox` 覆盖异步/worker 路径。 |
| `sentence` 审计 | — | `custom-justice` 的 sentence 路径不写 `police_audit`，DB 行就是唯一服务端证据。 |

跳过（SKIP）不记为失败；`E2E_RESULT.steps[].status` 会明确标为 `SKIP` 并带
`reason`，方便区分“通过”和“因环境缺人未覆盖”。

## 4. 测试命名空间与清理

| 数据 | 标识 |
|---|---|
| 警员 citizenid | `E2E_TEST_OFFICER` |
| 嫌疑人 citizenid | `E2E_TEST_SUSPECT` |
| incident 标题 | `[E2E] ...` |
| incident `created_by` | `agent:e2e` |
| outbox payload | 含 `E2E_TEST_` |
| police_units callsign | `E2E-1` |

### 4.1 清理策略

开始前 `cleanup.prepare` 与结束后 `cleanup.final` 都会：

1. 找到 `title LIKE '[E2E]%' AND created_by='agent:e2e'` 的 incident，
   先删 `police_incident_units`，再删 `police_incidents`；
2. 删除 `police_units` 中两个 E2E_* citizenid；
3. 删除 `justice_sentences` 中两个 E2E_* citizenid；
4. 删除 `police_outbox` 中本次 id / payload 含 `E2E_TEST_` 的行；
5. 删除 `phone_notifications` 中两个 E2E_* citizenid（outbox 投递产物）；
6. 统计上述表残留，必须为 0。

**`police_audit` 永远不删**。因此清理后仍能按 incident id / `actor_citizenid`
追溯本次测试的建单、派单、关单、duty 记录；审计里的 target 可能指向已删除的
测试 incident，这是刻意的“审计优先”策略。

测试只删除 E2E 命名空间，不按玩家 source、不按时间窗、不按通配符删真实数据。
准备 `police_units` 测试行与清理是测试代码的职责，生产运行路径仍只走
`custom-police` / `custom-justice` 的 export。

### 4.2 可重复跑

- 固定 citizenid，运行前先清残；
- incident 标题带时间戳，避免唯一性假设；
- outbox 以本次返回 id 为主键清理；
- sentence 先删后建，避免 active 行叠加；
- 审计只增不减，不参与唯一性检查。

## 5. 异步框架扩展

`custom-testing/lib/test_runner.lua` 原来只支持同步 `pcall`。本套件新增：

- `Test.it(name, fn, { async = true, timeout = 秒 })`
- `Test.it_async(name, fn, timeout)`
- `Test._runAsync`：把用例函数放进 `CreateThread`，runner 用 `Wait(25)` 等待，
  超时（默认 `Config.TestTimeout`，本套件 180s）标记 `[TIMEOUT]`。

用法：

```lua
Test.it_async("异步用例", function(source)
    local row = MySQL.single.await('SELECT ... WHERE id = ? LIMIT 1', { id })
    Wait(250) -- 等 worker
    Test.assert_equal('done', row.status, 'worker 应完成')
end, 30)
```

注意：

- 同步 `Test.it` 行为完全不变，现有套件无需改动；
- `Test.run()` 本身需要在可 yield 的线程里执行；`/test` 命令已用 `CreateThread`
  包裹 `Test.run` / `Test.runAll`；
- 异步用例内部仍使用原有 `Test.assert_*` / `Test.skip`；`Test.skip` 会中止当前
  **整个**用例。本套件的条件 step 使用内部 SKIP 记录，不会中止后续步骤。

## 6. 失败输出与 `E2E_RESULT`

每个 step 的第一个失败断言立即中止该 step，并打印：

```text
[E2E] ❌ incident.assign              12ms incident.assign 返回 table — expected=table actual=false
```

`E2E_RESULT` 结构：

```json
{
  "suite": "police_e2e",
  "ok": false,
  "exit_code": 1,
  "pass": 9,
  "fail": 1,
  "skip": 1,
  "total": 11,
  "steps": [
    {
      "name": "incident.assign",
      "status": "FAIL",
      "ms": 12,
      "checks": 3,
      "expected": "table",
      "actual": "false",
      "failures": ["incident.assign 返回 table — expected=table actual=false"]
    }
  ]
}
```

解析约定：

```bash
# 控制台/日志里截取最后一行 E2E_RESULT 后交给 jq
... | grep '^E2E_RESULT ' | sed 's/^E2E_RESULT //' | jq '.ok, .steps[] | select(.status=="FAIL")'
```

## 7. 已知限制

1. **无真实客户端**：不覆盖 NUI、MDT 页面、地图 blip、语音、NPC 实体生成。
   `incident.close` 即使拿到在线警察 source，也只验证服务端状态机与 DB。
2. **close/duty 依赖在线警察**：无人时 SKIP。CI/无人服上不能强制覆盖。
3. **NPC budget 只读**：`Acquire/Release` 未导出，无法在不生成 NPC 的情况下
   精确测试“预占/释放”；本套件用 outbox 覆盖异步 worker，另用前后快照保证无泄漏。
4. **budget 前后对比可能受真实玩家影响**：若测试期间有警察请求 backup/NPC
   callout，`used` 会变化并被判失败。应在安静测试服运行，或接受该 step 偶发失败。
5. **incident 广播副作用**：`CreateIncidentSystem` 会给所有在勤警察 enqueue
   `[E2E]` 通知（有在线警察时）。该通知不属于 E2E_* citizenid，套件不删除它；
   生产服不要运行本套件。
6. **审计 actor_kind 现状**：`AssignUnitSystemForAgent` 走 p0 的 audit helper，
   当前写入 `actor_kind='player'`、`actor_citizenid='e2e'`。套件断言 action 和
   actor id，不对这个既有语义做额外要求。
7. **sentence 无 police_audit**：不要用 `police_audit` 判断刑期是否生效，查
   `justice_sentences`。
8. **不要并发跑**：套件按固定 E2E citizenid + `[E2E]` 标题清理，同一服务器
   同时跑两个 `police_e2e` 会互相删除对方的数据。控制台一次只跑一个。
9. **grade < 2 且 unit 忙时跳过关单**：套件不会为了测试把正在处理真实警情的
   警察 unit 改派到测试 incident；这是有意的安全边界。
10. **`/test run all` 也会执行本套件**：它会在真实 DB 中创建/删除 E2E 数据。
    生产服或共享测试服请只跑 `/test run police_e2e`，并确认当前没有需要保留的
    在勤警察通知；不要在生产环境执行 `custom-testing`。

## 8. 扩展方式

新增一个 step：

```lua
runStep('my.domain', function()
    local cursor = auditCursor()
    local ok, result = callExport('custom-police', 'SomeExport', arg1, arg2)
    expect(ok, 'SomeExport 可调用', 'true, result', ok and 'ok' or result)
    expect(result.status == 'expected', '返回值状态', 'expected', result.status)

    local row = MySQL.single.await(
        'SELECT status FROM some_table WHERE id = ? LIMIT 1', { id })
    expect(row and row.status == 'expected', 'DB 落库', 'expected',
        row and row.status or 'nil')

    local audit = auditRow(cursor, 'some.action', id)
    expect(audit ~= nil, '审计记录', 'row', audit and 'row' or 'nil')
end)
```

约定：

- 任何写操作都先登记 `auditCursor()`，用 `id > cursor` 避免命中历史行；
- 所有测试数据必须落在一个可识别命名空间（E2E_* / `[E2E]`），并在
  `prepareCleanup` / `finalCleanup` 中删除；
- 需要在线玩家的能力先 `findOnDutyOfficer()`，没有就 `skip(reason)`，不要用
  SQL 伪造状态；
- 数据库 SQL 只用于测试准备/断言/清理，不复制业务写路径；
- 新增 step 后同步更新本文档第 3 节表格。

## 9. 排障

| 现象 | 排查 |
|---|---|
| `E2E_EXIT 1` + `incident.create` FAIL | `CreateIncidentSystem` 是否已加载；`police_incidents` 表/列（`disposition`、`closed_by`）是否迁移 |
| `incident.assign` FAIL `unit_not_found` | 预置 `police_units` 是否被 cleanup 抢跑；确认 `E2E_TEST_OFFICER` 行 status 为 `available` |
| `incident.assign` FAIL `unit_off_duty` | 测试行被写成 off_duty；重跑会重新 upsert |
| `incident.close` SKIP | 无在线 `police` 且 `onduty` 玩家，或 grade < 1；这是环境限制，不是代码失败 |
| `incident.close` FAIL `not_assigned` | grade 1 的 `AssignUnit` 自派单失败；检查在线警察是否真的 onduty |
| `outbox.delivery` FAIL status=`pending/failed` | 看 `custom-phone:Notify` 是否可用、`phone_notifications` 表是否存在、worker 日志 `[custom-police] outbox` |
| `sentence.apply` FAIL | `custom-justice` 是否启动；`justice_sentences` 是否迁移 |
| 清理后仍有残留 | 看 `cleanup.final` 的 `actual` 残留数，按第 4 节表逐表查；只允许 E2E_* 行被删 |
| `export_missing:custom-police:...` | 资源未启动或 manifest 新增文件后未整服重启；`restart` 不加载新的 server 文件 |

## 10. 手工核对 SQL

```sql
-- 本次 E2E 审计（清理后仍在）
SELECT id, actor_citizenid, actor_kind, action, target, detail, created_at
FROM police_audit
WHERE actor_citizenid IN ('agent:e2e', 'e2e', 'E2E_TEST_OFFICER')
ORDER BY id DESC LIMIT 50;

-- 测试数据应全部为 0（清理后）
SELECT COUNT(*) FROM police_incidents
 WHERE title LIKE '[E2E]%' AND created_by = 'agent:e2e';
SELECT COUNT(*) FROM police_units WHERE citizenid LIKE 'E2E\_%';
SELECT COUNT(*) FROM justice_sentences WHERE citizenid LIKE 'E2E\_%';
SELECT COUNT(*) FROM police_outbox WHERE payload LIKE '%E2E_TEST_%';

-- outbox 健康度
SELECT status, COUNT(*) FROM police_outbox GROUP BY status;
```

## 11. 相关文档

- `STATUS.md` — 警察系统实现状态
- `LIVE_ACCEPTANCE.md` — 进服人工验收清单
- `architecture/08-scenarios.md` — P0 场景与审计口径
- `T-CityLite.base/resources/[custom]/custom-testing/suites/02_police_test.lua`
  — 旧的布尔模拟套件（保留，不替代）
