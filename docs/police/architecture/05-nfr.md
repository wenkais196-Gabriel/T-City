# 05 — 非功能需求（NFR）与数字预算

> 架构基线 agent D ｜ 只读 + 文档 ｜ 未改代码、未 commit、未触碰 FXServer。
> 基线：`master`（2026-10-24，与 [STATUS.md](../STATUS.md)、[TECH_DEBT.md](../TECH_DEBT.md)、[FLOW_INTERNAL.md](../FLOW_INTERNAL.md)、[GTA_MOD_RESEARCH.md](../GTA_MOD_RESEARCH.md) 同一快照）。
> 口径：证据写 `路径:行号`，未带资源前缀的路径相对 `T-CityLite.base/resources/`；`server/*.lua`、`client/*.lua`、`shared/*.lua` 默认指 `custom-police/`。
> 标注：**【现状】** = 2026-10-24 代码可验证的事实；**【建议】** = 本文给出的目标值，需在 P7 拍板后进入 CI/监控。凡未标【现状】的数字都是建议值。

**与兄弟文档的关系**：本文只定义"数字 + 验证方式"，不重复功能设计（见 [DESIGN.md](../DESIGN.md)）与流程断点（见 [FLOW_INTERNAL.md](../FLOW_INTERNAL.md)）；可落地的约束检查与评分卡在 [07-fitness-tests.md](07-fitness-tests.md)。

**为什么需要这份文档**：警察系统的所有 NFR 目前都是**未测量的**。仓库已有的性能预算只覆盖 agent 侧（`T-CityLite.base/docs/agent/design/01-live-perception.md` §5.1：tick P95 ≤3ms、`/live/players` ≤15ms；`.../design/05-test-and-eval.md` §7 明确"真 P95 由实机 T5 采集"），警察侧从未定义过预算，因此"慢不慢、撑不撑得住"只能靠猜。本文把可以猜的部分变成可验证的数字。

---

## 0. 一页 SLO 卡

| 域 | 指标 | 目标（建议） | 现状 |
|---|---|---|---|
| 规模 | 在线玩家 / 在勤警察 | 48 / ≤12 | `sv_maxclients 48`（`server.cfg.template:14`）/ 无上限 |
| 规模 | 并发 open 警情 | ≤20（15 告警） | 无上限，查询截断 50 |
| 规模 | NPC 支援单位（全局 / 每人） | ≤6 / ≤2 | 无全局上限 / 2（`server/p2_system.lua:173`） |
| 性能 | 911 → 警情落库 + 广播 P95 | ≤120 ms | 未测；结构上是 `N+2` 次串行 DB 往返 |
| 性能 | MDT 单次查询 P95 | ≤150 ms | 未测 |
| 性能 | 逮捕提交（含送监）P95 | ≤500 ms（硬超时 2 s） | 未测；~15 次 DB 往返 + 2 次资源导出 |
| 性能 | DB 稳态 / 峰值 qps | ≤30 / ≤120（5 s） | 未测 |
| 可靠性 | 掉线 → 单位离勤 | ≤5 s | 即时（`server/p0.lua:282-289`） |
| 可靠性 | 资源重启后 stale 单位 | 60 s 内归零 | 未知；无启动清扫 |
| 可靠性 | 重复提交导致的双写 | 0 | 存在（支付 / 逮捕 / 报告，见 §3.5） |
| 可靠性 | RPO / RTO | ≤15 min / ≤30 min | 手工 `mysqldump`，无计划、无演练 |
| 安全 | net event 鉴权覆盖 | 100% | 2/43 走 capability 表（§4.2） |
| 安全 | 敏感读审计 fail-closed | 100% | 3 个导出 fail-closed（`lookup.citizen` / `lookup.vehicle` / `GetCaseDetail`）；9 个读导出写审计（3 个即上述 fail-closed、6 个忽略返回值），5 个完全不写 |
| 可观测 | 审计写入失败可告警 | 有指标 + 阈值 | 无（多处忽略返回值） |
| 兼容 | `job.onduty` 写入点 | 1（duty 服务） | 4（§6.1） |

---

## 1. 规模与容量

### NFR-SCALE-01 · 玩家规模与在勤警察上限

- **指标**：同时在线上限；同职业 `police` 且在勤人数峰值。
- **目标【建议】**：48 人在线（对齐 `sv_maxclients`）；在勤警察 ≤12（25%），>16 时告警。
- **当前实现【现状】**：`sv_maxclients 48`；警察人数无上限。MDT 的 `units` 查询硬截断 100 行（`server/p0.lua:57`），`officers` 查询每次全量遍历在线玩家（`custom-phone/server/apps/police_mdt.lua:154-164`）。无任何 convar 控制警察编制。
- **验证方法**：`tcity-e2e` 假人池支持 100 个 source（`tcity-e2e/README.md` §Scenario DSL），可造 48 假人 + 12 名 `police` + `onduty=true`，跑 `GetUnits` / `officers` / 一次广播，断言 P95 与查询次数；静态侧检查 convar 白名单存在。
- **缺口**：无编制上限、无告警、无"超编时降级"策略（例如只广播给 nearest 8 人）。24 人以上时 `CreateIncident` 的广播是 N 次串行 insert（`server/p0.lua:100-114`）。

### NFR-SCALE-02 · 并发警情

- **指标**：`police_incidents` 中 `status NOT IN ('closed')` 的行数；最老 open 警情的年龄。
- **目标【建议】**：并发 open ≤20（15 时告警）；单警员同时挂 ≤3 个未清警情；无状态变更 >30 min 标 `stale`（只降权，不自动关闭）；>7 天未变更由维护任务置 `closed`。
- **当前实现【现状】**：无上限、无 TTL、无 stale 概念。`GetIncidents` 只取 50 行并按 `priority ASC, id DESC` 排序（`server/p0.lua:118-126`），索引 `idx_status_created` / `idx_priority` 存在（`migrations/v2.8_police_p0.sql`），但 `status NOT IN ('closed')` 走不到复合索引前缀。
- **验证方法**：静态检查 `police_incidents` 的写路径只有 `SetIncidentStatus` / `AssignUnit`（见 07 FIT-11）；`tcity-e2e` 场景灌 25 条 incident 后断言 `count` 与告警条件；实机上 `EXPLAIN` 两条查询记录到 `docs/police/architecture/perf-baseline.md`（待建）。
- **缺口**：派单后无接受超时（DESIGN 里的 90 s 回退未实现），警情会永久停在 `assigned`；这是容量问题的放大器——卡住的单占满 20 的配额。

### NFR-SCALE-03 · NPC 支援单位与实体预算

- **指标**：全局并发 NPC 支援单位数；每玩家单位数；每个单位的网络实体数；服务端网络实体总数。
- **目标【建议】**：
  - 每玩家 ≤2 单位（现状已是 2）、全局 ≤6 单位（**新增**，跨玩家共享）；
  - 1 单位 = 1 车 + 2 ped = **3 个网络实体**（现状一致，`client/backup.lua:204-221`）；
  - 全局 NPC 实体 ≤18；连同 48 玩家与 ~20 台玩家载具，服务器网络实体总数 ≤250；
  - 冷却 60 s/人（现状），单位寿命 5 min、离场 150 m/30 s 回收（现状 `client/backup.lua:21-27`）。
- **当前实现【现状】**：`BACKUP_MAX_UNITS = 2`、`BACKUP_COOLDOWN = 60`（`server/p2_system.lua:172-173`）只按 `citizenid` 计数（`backupUnits[cid]`，行 175），**没有全局计数器**。48 人满编时理论上限 96 单位 / 288 实体，是建议值的 16 倍。资源级上限靠客户端自清理 + `playerDropped`（行 266-272）。
- **验证方法**：Lua harness（`tests/agent/lua/cases/police_system.lua` 的 `env.exports` + MySQL stub）可直接驱动 `RequestBackup`：连续 3 次断言第 3 次 `limit`、60 s 内第 2 次 `cooldown`、audit 失败时返回 `audit_unavailable` 且不占槽。全局上限需要新增 `BACKUP_MAX_UNITS_GLOBAL` 常量后同样在 harness 覆盖。
- **缺口**：全局上限、全局计数器、耗尽时的降级（排队/拒绝码 `global_limit`）、泄漏检测（见 NFR-OBS-03）。

### NFR-SCALE-04 · 每单位实体与清理成本

- **指标**：`CreateVehicle` + `CreatePedInsideVehicle` 次数；`DeleteEntity`/`DeleteVehicle` 次数；残留实体数。
- **目标【建议】**：生成 ≤1 车 + 2 ped；清理 100% 覆盖（5 条路径：超时 / 距离 / 玩家死亡 / 资源停止 / 车毁）；清理耗时 ≤300 ms（客户端线程内）；残留 0。
- **当前实现【现状】**：生成点 `client/backup.lua:183-260`（`SPAWN_FORWARD 50m`，模型 `police`/`police2`、`s_m_y_cop_01`/`s_m_y_hwaycop_01`）；清理函数 `client/backup.lua:112-130`（blip + peds + 车，`SetEntityAsMissionEntity` 后删除），调用点覆盖行 428-483 与 `onResourceStop`（行 506-519）。模型加载失败只 `print` 不重试（`loadFirstModel`，行 95-101）。
- **验证方法**：客户端侧无自动化，只能实机回归 + 服务端计数对比（NFR-OBS-03 的 spawn/cleanup 计数差应为 0）；静态检查 `CreatePed*`/`CreateVehicle*` 只出现在 `client/backup.lua`（07 FIT-07）。
- **缺口**：模型加载无超时（`loadModel` 自带 5 s 等待但不设整体预算），失败时服务端槽位要等 5 min 寿命才回收。

### NFR-SCALE-05 · 数据增长与保留

- **指标**：各表行数与磁盘增量；无界增长表。
- **目标【建议】**（按 48 人 / 日 30 警情 / 日 10 逮捕估算）：

| 表 | 估算日增 | 年增 | 保留策略【建议】 |
|---|---|---|---|
| `police_audit` | ~800 行（每次查询 2 行 + 写 1 行） | ~29 万 | 180 天，之后归档 |
| `police_incidents` | 30 | 1.1 万 | 永久（7 天未变更置 closed） |
| `police_reports` | 20（body ≤4000 字节） | 7 千 / ~30 MB | 永久 |
| `police_citations` | 15 | 5.5 千 | 永久 |
| `phone_notifications` | ~500（广播扇出） | ~18 万 | **90 天**（当前无清理） |

- **当前实现【现状】**：`police_audit` 有 `idx_actor_created` / `idx_action_created`（`migrations/v2.8_police_p0.sql`）；**没有任何清理/归档任务**——全仓库无 `DELETE FROM police_*` 的维护路径（只有回滚删除，`server/p2_system.lua:458-481,743-754`）。`phone_notifications` 只在用户手动清空时按 citizenid 删除（`custom-phone/server/main.lua:711,722`）。
- **验证方法**：静态检查是否存在 retention 维护任务（当前 fail）；上线后按周采样 `information_schema.TABLES` 的 `DATA_LENGTH`，写入运维周报。
- **缺口**：无保留策略、无归档表、无容量告警；`police_audit` 与业务表混在同一库，备份窗口会随之变长（影响 RTO）。

---

## 2. 性能

> 所有警察侧数字目前**都是未测的**。下面给的是"先定预算、再补测量"的目标值；测量方法分离线（CI 可跑）与实机（需 FXServer + 客户端）两档，见 §2.5。

### NFR-PERF-01 · 911 / 建单事件处理

- **指标**：`custom-police:server:911` 或 `CreateIncidentSystem` 从事件进入到达成"落库 + 广播完成"的 P95；事件处理线程占用。
- **目标【建议】**：P95 ≤120 ms（在勤 8 人）、P99 ≤250 ms；不得阻塞主线程 >1 tick（~16 ms 的连续占用）。
- **当前实现【现状】**：`P.CreateIncident` 串行执行 1 次 insert + 1 次 audit + **每个在勤警察 1 次 insert + 1 次 client event**（`server/p0.lua:88-114`），即 `N+2` 次串行 DB 往返；agent 路径同构（`server/p2_system.lua:40-54,57-73`）。无批处理、无去重。
- **验证方法**：Lua harness 统计 `env.mysql` 调用次数（已有 `env.mysql.reset/push` 机制，`tests/agent/lua/cases/police_system.lua:36-42`），断言"1 条 incident 在 8 名在勤警察下 = 10 次 DB 往返"；实机用 `/tmp/fxserver.log` 时间戳 + `os.clock()` 包裹计时采样 200 次取 P95。
- **缺口**：无计时埋点；广播串行化是 NFR-PERF-06（DB 峰值）的主要贡献者；也意味着一次警情 = 10 次跨网络往返（若 DB 在远端，1 次往返 5 ms 就是 50 ms）。

### NFR-PERF-02 · MDT 查询（phone app query）

- **指标**：`phone:server:appQuery` 服务端处理时间 P95；单次响应字节数；单警官查询频率。
- **目标【建议】**：
  - 单次查询 P95 ≤150 ms、P99 ≤400 ms；
  - 单次响应 ≤64 KB，行数 ≤50（现状 LIMIT 50）；
  - 单警官 ≤20 次/分钟、≤600 次/小时（含翻页与刷新）；超限返回 `rate_limited`；
  - MDT 首屏（dispatch）≤6 次查询、≤400 ms 总计。
- **当前实现【现状】**：`PhoneApps.Query` 直接调用 handler，**无频率限制、无响应大小检查**（`custom-phone/server/phone_apps.lua:113-125`）；MDT 前端"每个数据集只加载一次除非手动刷新"（`PoliceMDT.svelte:227`），已有基本节流。最贵的两个查询：`me` 会顺带 `GetUnits()` 拉 100 行（`apps/police_mdt.lua:38-64`），`units` 也拉 100 行且 `SELECT *`（`server/p0.lua:57`）。
- **验证方法**：离线静态检查每个 query handler 是否显式 `LIMIT`/`limit` 参数（FIT-09）；实机对 17 个 query 各打 50 次，记录 P50/P95 与 `#json.encode(result)` 字节数，写入 perf baseline。
- **缺口**：无 per-officer 限额、无 payload 上限、无慢查询日志。`SELECT *` 让 `reports` 单行最多 4 KB body（`migrations/v2.9_police_p1.sql`），50 行理论峰值 ~200 KB。

### NFR-PERF-03 · 敏感查询（lookup）

- **指标**：`LookupCitizen` / `LookupVehicle` P95；每次调用的 DB 往返数。
- **目标【建议】**：citizen ≤60 ms（3 次查询 + 2 次 audit）、vehicle ≤30 ms（1 + 1）；P99 ≤150 ms。
- **当前实现【现状】**：`LookupCitizen` = 1 次 `players` + 2 次 `police_warrants`/`police_reports`（各 LIMIT 5）+ 2 次 audit 写（`server/p0.lua:192-235`），共 **5 次往返**，且 audit 是 `await` 串在查询之间；`LookupVehicle` = 1 读 + 1 audit（行 237-247）。
- **验证方法**：Lua harness 断言往返次数（回归保护）；实机采样 200 次。
- **缺口**：warrant/BOLO 两次查询可合并为一次 `UNION`；`lookup.citizen.result` 的第二次 audit 写与首条 audit（`lookupAllowed`）重复，可合并为 1 行（含 target），省 1 次往返。**注意**：删 audit 行会削弱取证，需在 07 FIT-05 里把"合并"写成显式豁免，而不是静默优化。

### NFR-PERF-04 · 逮捕提交（ArrestSubmit）

- **指标**：从 `arrest_submit` action 进入到达成"已送监并回包"的 P95；失败回滚耗时；单次 DB 往返数。
- **目标【建议】**：P95 ≤500 ms（含 justice 导出 + qb-prison handoff）、P99 ≤1.2 s；硬超时 2 s（超时返回 `timeout` 并保留已提交的报告，不得半写）；单次 ≤20 次 DB 往返（现状估算 ~15）。
- **当前实现【现状】**：`server/p2_system.lua:336-662`，最坏路径 = 2 次前置读（incident/case）+ report insert + case insert + case update + report 链接 + citation insert + evidence insert + evidence update + chain insert + justice 导出 + 2~3 次 audit + 通知 insert ≈ **15 次往返**；无事务（注释已说明 oxmysql 无 `transaction` 导出，行 125-136），失败靠补偿 `DELETE`（行 458-481）。
- **验证方法**：`tests/unit/layer3_business/test_arrest_submit.py`（58 个静态契约）保护"不信任客户端"的部分；性能只能实机。回滚正确性可在 Lua harness 用 stub 让第 N 次 insert 失败，断言 0 残留。
- **缺口**：无超时控制；补偿删除自身可能失败（`pcall` 吞掉，行 458-481），失败后无告警——属于"数据一致性静默降级"。

### NFR-PERF-05 · NPC 生成与清理开销

- **指标**：请求 → NPC 出现在画面 P95；请求 → 服务端回包 P95；清理耗时；生成失败率。
- **目标【建议】**：回包 P95 ≤80 ms（服务端只有 1 次 audit 写）；画面出现 P95 ≤1.5 s（含模型流式加载）；清理 ≤300 ms；生成失败率 ≤2%（模型缺失/无生成点）。
- **当前实现【现状】**：服务端 `RequestBackup` 只做权限 + 冷却 + 计数 + 1 次 audit（`server/p2_system.lua:191-243`），回包应为个位数毫秒；客户端 `spawnBackup` 需加载 2 个模型 + 寻路到 50 m 外（`client/backup.lua:183-260`），无超时、无失败上报（只在行 198 `print`），服务端槽位不会因生成失败而提前释放。
- **验证方法**：服务端可直接测；客户端需实机（`/backup` 后看 F8 日志时间戳）。失败率靠新增计数（NFR-OBS-03）。
- **缺口**：模型加载失败无快速回收；生成点无校验（可能在墙里/水里）；`SPAWN_FORWARD 50m` 在高速/桥上容易出问题（GTA_MOD_RESEARCH §3.1 已列为风险）。

### NFR-PERF-06 · DB 负载

- **指标**：DB 查询数/秒（稳态、峰值）、慢查询（>200 ms）比例、连接池占用。
- **目标【建议】**：稳态 ≤30 qps、5 s 峰值 ≤120 qps；慢查询比例 <0.1%；单查询 P95 ≤15 ms（与 DB 同机）；连接池 ≥16（当前由 oxmysql 默认值决定，未记录）。
- **当前实现【现状】**：无任何测量。可静态推导的写放大：每次敏感查询 2 次 audit 写（`server/p0.lua:187,227`）、每条警情 `N+2` 次写、每次广播 N 次 `phone_notifications` 写。48 人 + 12 在勤 + 每分钟 1 条警情时稳态估算 ≈ 12~20 qps（可接受），但**峰值（多人同时逮捕、MDT 刷新）无上限保护**。
- **验证方法**：实机开 `general_log` 或 `performance_schema` 采 10 分钟；离线用 Lua harness 统计每次导出的往返数并乘以目标调用率，作为预算表（见 §8 附录 A）。
- **缺口**：无连接池配置记录、无慢查询日志、无 qps 指标。**这是所有性能 NFR 里最容易补、收益最大的一项**。

---

## 3. 可靠性

### NFR-REL-01 · 掉线 / 断线重连

- **指标**：`playerDropped` → `police_units.status='off_duty'` 延迟；占用的 NPC 槽位释放数；incident 上的单位关联是否清理。
- **目标【建议】**：≤5 s 内落库；100% 释放该玩家全部 NPC 单位；`police_incident_units` 保留历史但单位状态归零。
- **当前实现【现状】**：`server/p0.lua:282-289` 立即 `UPDATE police_units SET status='off_duty', incident_id=NULL`（`pcall` 包裹）；`server/p2_system.lua:266-272` 清 `backupUnits[cid]`。**不写审计**（掉线属系统事件，`police_audit.actor_kind` 有 `system` 但无人使用）。重连后新的 source，`police_units` 按 `citizenid` 复用（表主键是 citizenid，正确）。
- **验证方法**：Lua harness 触发 `playerDropped` 后断言 `backupUnits` 为空、`police_units` 更新语句形状；实机杀进程后看日志与 DB。
- **缺口**：掉线无审计（`actor_kind='system'` 未使用）→ 无法回答"XX 时间谁在勤"；如果 DB 在掉线瞬间不可用，`pcall` 吞掉失败，留下 stale 行且无重试。

### NFR-REL-02 · 客户端崩溃

- **指标**：崩溃后单位状态回落时间；卡在 `assigned` 的警情数；NUI 残留（手机打不开 / WASD 冻结）恢复成功率。
- **目标【建议】**：单位 ≤5 s 回落（崩溃等同掉线）；`assigned` 警情 ≤90 s 回 `open`；NUI 残留可一键恢复（`/phonefix`）且恢复率 100%。
- **当前实现【现状】**：崩溃会触发 `playerDropped`，所以单位/备份单位能释放；但**警情没有接受超时**，派给崩溃玩家的单会永久 `assigned`（`server/p0.lua:139-157` 只写不读状态）。NUI 侧有焦点看门狗 + 手动恢复（`custom-phone/client/main.lua:14-96,239-246`），服务端只记日志（`custom-phone/server/main.lua:1351-1359`）。
- **验证方法**：实机 kill 客户端进程，观察 `police_incidents.status` 与 `police_units`；NUI 恢复按 `docs/agent/phone/` 的焦点语义回归清单手工走。
- **缺口**：无 90 s 接受超时（DESIGN 有设计，代码未实现）；无 stale-assigned 看板指标。

### NFR-REL-03 · DB 超时 / 不可用

- **指标**：DB 不可用期间的错误码分布；fail-closed 行为是否一致；恢复后是否自愈。
- **目标【建议】**：所有 DB 调用有 5 s 超时；**敏感读**在审计不可写时拒绝（现状已是）；**敏感写**在审计不可写时拒绝或回滚（现状不一致）；DB 恢复后 ≤60 s 自愈，无需重启资源。
- **当前实现【现状】**：
  - 无显式查询超时（沿用 oxmysql 连接参数，`server.cfg` 未记录）；
  - fail-closed 覆盖 **3 个敏感读**：`server/p0.lua:183-190`（`LookupCitizen`/`LookupVehicle`）与 `server/p3_cases.lua:242-244`（`GetCaseDetail`）；写路径覆盖 `server/p2_system.lua`（CreateIncident/AssignUnit、ArrestSubmit 尾部、ReportSubmit、RequestBackup）；
  - 其余敏感读 **fail-open**：9 个写审计的读中，除上述 3 个外其余 6 个忽略 `audit()` 返回值（`case.view`/`evidence.view`/`evidence.chain`/`bolo.view`/`warrant.view`/`arrest.view`）；另有 5 个完全不写（`GetUnits`/`GetIncidents`/`GetAudit`/`GetCitations`/`GetReports`）；
  - 写路径 **fail-open**：`server/p1.lua:18-25` 的 `audit()` 返回值被所有调用点忽略（IssueCitation/CreateReport/PayCitation），`server/p3_cases.lua:37-44` 同理，`server/p2_system.lua:121`（Sys.Jail）也未检查。审计表不可写时，这些写路径照常成功且**静默丢审计**。
- **验证方法**：静态检查"每个 `audit(` 调用点是否消费返回值"（07 FIT-05）；Lua harness 让 `env.mysql` 的 insert 抛错，断言 `lookup` 返回 `audit_unavailable`、`IssueCitation` 返回 `false, 'audit_unavailable'`（当前会失败，正是要修的）。
- **缺口**：超时配置未文档化；**23 个 audit 调用点丢弃返回值**（`p0` 6、`p1` 3、`p2_evidence` 3、`p2_system` 1、`p3_cases` 10，`grep -E "^\s*audit\("` 计数），其中 p1/p2_evidence/p3 的 16 处在敏感写/读路径上；无"DB 降级"模式（例如只读缓存）。

### NFR-REL-04 · 资源重启

- **指标**：重启后 stale `police_units` 行数；内存态（冷却、NPC 计数、justice 案件）丢失量；重启后首个错误。
- **目标【建议】**：重启 ≤60 s 内把"不在线但在勤"的单位行扫成 `off_duty`（启动清扫）；内存态丢失可接受但必须**可见**（启动日志打印重置项）；重启事件本身写 `police_audit(actor_kind='system')`。
- **当前实现【现状】**：`server/p0.lua:262-270` 的 `syncDuty` 只在 `PlayerLoaded` / `OnJobUpdate` 触发；`custom-police` 单独 `restart` 时**既不会触发 PlayerLoaded，也不会清表**，于是所有在勤单位保持旧状态（含 `incident_id`）直到该玩家上下班或掉线。`backupUnits` / `backupCooldown` 归零（可被用来重置冷却刷 NPC）；`custom-justice` 的 `Inmates` 直接丢失（TD-02）；`police_units` 与 `players.job.onduty` 可能出现"表里 available、内存里 offduty"。
- **验证方法**：实机 `restart custom-police` 后立刻 `SELECT status FROM police_units`；Lua harness 可加载后调用不存在（无启动处理器）→ 静态检查 `AddEventHandler('onResourceStart'` 是否存在（当前无）。
- **缺口**：无启动清扫、无重启审计、无"重启后单位状态以 players.job.onduty 为准"的对账逻辑。

### NFR-REL-05 · 重复提交 / 幂等

- **指标**：同一逻辑操作产生 >1 条业务行的比例；双扣款次数；重复审计行。
- **目标【建议】**：支付 0 双扣；逮捕 1 次提交 = 1 report + ≤1 citation；报告 0 重复；所有写动作接受 `idempotency_key` 幂等键（建议 24 h 去重窗）。
- **当前实现【现状】**：
  - `PayCitation`：先 `RemoveMoney`，再 `UPDATE ... WHERE status='unpaid'`（`server/p1.lua:140-157`）。两个并发请求可同时通过状态检查 → **双扣款，只入账一次**（UPDATE 影响 0 行但未检查）。
  - `ArrestSubmit`：靠 `metadata.injail > 0` 拦第二次（`server/p2_system.lua:360`），同一 tick 内的两次提交都能通过；justice `Imprison` 对已在服刑者返回 `true` 而不重置（`custom-justice/server/prison.lua:36-39`），于是会产生 **2 report + 2 citation + 1 次生效刑期**。
  - `ReportSubmit`：无任何去重（`server/p2_system.lua:672-797`），双击 = 2 份报告。
  - 全仓库无 `idempotency_key` / nonce 字段（`request_id` 是 NPC 支援的一次性请求号，不是幂等键）。
- **验证方法**：静态检查"支付路径是否先占位再扣款"（FIT-05 的幂等子规则）；`tests/tools` 侧已有离线 eval 幂等用例可参照；并发用两个协程对 stub 交替调度可复现（Lua harness 的 `MySQL` stub 是同步的，需要新增延迟钩子）。
- **缺口**：无幂等键、无乐观锁（`WHERE status='unpaid'` 的 affectedRows 未检查）、无并发测试。

### NFR-REL-06 · 恢复目标（RPO / RTO）

- **指标**：可接受的数据丢失窗口（RPO）；从故障到恢复服务的时间（RTO）；备份覆盖率。
- **目标【建议】**：
  - **RPO ≤15 min**（`players`、`police_*` 至少每 15 min 增量；binlog 保留 7 天）；
  - **RTO ≤30 min**（恢复到可登录、可接警）；
  - 每日 03:00 全量 + 每次迁移前快照；季度恢复演练一次，记录实际 RTO。
- **当前实现【现状】**：只有文档里的手工命令（`docs/03_maintenance_manuals/maintenance_guide.md` §7，`mysqldump ... > backup_$(date +%Y%m%d).sql`，注意示例库名是旧的 `QBCore_CDB34E`），**无计划任务、无 binlog 策略、无演练记录**。`police_*` 未被列入"关键表"清单（清单只写 `players` / `player_vehicles`）。
- **验证方法**：检查 crontab / systemd timer 是否存在备份任务（当前无）；每季度做一次"删库→恢复→起服→接警"演练并记录耗时。
- **缺口**：RPO 实际等于"上次手动备份"，不可承诺；`police_audit` 属于不可重建数据，必须与 `players` 同等级备份——这点目前没写进任何清单。

---

## 4. 安全

### NFR-SEC-01 · NUI 不可信

- **指标**：NUI → 服务端入口数量；每个入口的鉴权方式；单连接每秒可触发的无鉴权事件数。
- **目标【建议】**：100% 的 NUI 入口经服务端重鉴权；无鉴权事件 0 个；单玩家 `focusState`/`clientError` 类诊断事件 ≤10 条/分钟（采样）。
- **当前实现【现状】**：
  - **好的部分**：`PhoneApps.Query/Action` 每次 `resolve()` 都重查 `PlayerData` 并校验 `audience`（`custom-phone/server/phone_apps.lua:39-52,103-143`），NUI 隐藏不是权限；`custom-police` 的所有写导出都在服务端再过一遍 `PolicePolicy.Can`。
  - **问题**：`phone:server:focusState` 与 `phone:server:clientError` 完全无鉴权、无频率限制，直接 `print`（`custom-phone/server/main.lua:1351-1366`）——任意客户端可刷爆服务端 stdout（日志洪泛 → 磁盘 + 观测噪声）。
  - NUI 传入的 `params` 只按需取字段，未做统一 schema 校验（例如 `apps/police_mdt.lua:167-172` 直接读 `params.status`）。
- **验证方法**：静态枚举 `RegisterNUICallback` 与 `phone:server:*` 事件，逐个标注鉴权方式（07 FIT-04）；实机/压测发 1000 条 `focusState` 观察日志行数。
- **缺口**：诊断事件无采样、无上限；参数 schema 无统一校验层。

### NFR-SEC-02 · net event 鉴权

- **指标**：需要鉴权的 net event 占比；鉴权强度分布（capability / job.type / 无）。
- **目标【建议】**：100% 的 net event 满足下列之一：① `PolicePolicy.Can(data, cap)`；② `source == 0` 且调用方是可信服务端导出；③ 会话/所有权校验（例如 `backupEnded` 只释放自己的 request_id）；④ 明确标注为"平民入口"并有限流 + 输入校验（`911`）。新增未鉴权事件必须进 allowlist 并在 30 天内整改。
- **当前实现【现状】**（`custom-police/server/*.lua` 共 **43** 个 `RegisterNetEvent`）：
  - 走 capability 表：**2 个**（`police:server:autoAlert`，`server/main.lua:198-236`；`police:server:JailPlayer`，`server/interactions.lua:139-186`，且只接受 `source==0`）；
  - 只校验 `job.type == 'leo'` 或 `PolicePolicy.IsPolice`（不校验 onduty/grade）：约 **27 个**（`interactions.lua` 10、`main.lua` ~10、`objects.lua` 3、`vehicle.lua` 4）；
  - **完全不校验：9 个** `evidence:server:*`（`server/evidence.lua:64-155`）——任意客户端可伪造 DNA/指纹、清空全服血迹与弹壳；
  - 其余为 self/会话校验（`custom-police:server:setStatus` 只查 `isPolice`，**不查 onduty**；`backupEnded` 校验 request_id 归属，正确）。
- **验证方法**：07 FIT-04 的 allowlist 扫描；对 9 个 evidence 事件做一次"平民客户端触发"的实机验证（预期应被拒，当前能成功——即证明缺口）。
- **缺口**：这是当前**最大的安全缺口**，也是本文最推荐先补的一条（见 07 §6）。`evidence.lua` 的 9 个事件应当直接下线或加 `PolicePolicy.Can` + `onduty`。

### NFR-SEC-03 · agent L1–L4 风险分级

- **指标**：L1 自动执行比例；L2–L4 人审覆盖率；拒绝留痕率；agent token 越权次数。
- **目标【建议】**：L1 可自动执行但必须审计；L2/L3/L4 100% 需人审；拒绝 100% 写 `agent_denials`；agent token 不能审批（admin token 独占）；越权接受次数 = 0。
- **当前实现【现状】**：35 工具 / 21 动作，风险表在 `custom-director/server/policy.lua`（L1 `notify`/`police_incident_create` 自动执行；L2 `police_assign_unit`；L3 `police_jail_player` 均需审批）。警察三个 system 入口带 `actor_kind='agent'` 审计（`server/p2_system.lua:31-38`）；拒绝写 `agent_denials`（不含参数值）。**实机只验证过 L1**；L2/L3 的 approve→executed 尚无在线玩家记录（`docs/police/STATUS.md`"未完成"第 1 条）。
- **验证方法**：`python3 tools/agent_eval.py`（离线成功率/审批/拒绝/P95）；`tools/agent_smoke.py --allow-write --allow-approve`（实机三段式）；契约测试 `tests/tools/test_agent_contract*.py`。
- **缺口**：L2/L3 缺一次端到端实机记录；`Sys.Jail` 的 audit 失败未拦截（`server/p2_system.lua:121`），agent 入狱可能无审计。

### NFR-SEC-04 · 审计 fail-closed

- **指标**：写操作中"审计失败即拒绝/回滚"的比例；静默丢审计的写路径数。
- **目标【建议】**：所有**敏感读**（lookup、案件/证据/报告/罚单查询）与**所有写**在审计不可写时要么拒绝、要么回滚并返回 `audit_unavailable`；静默容忍只允许"事后补写"场景，且必须有补偿日志。
- **当前实现【现状】**：敏感读只有 **3 个 fail-closed**（`LookupCitizen`/`LookupVehicle`/`GetCaseDetail`，`server/p0.lua:183-190`、`server/p3_cases.lua:242-244`）；9 个读导出写审计，其中上述 3 个 fail-closed、其余 6 个忽略返回值；5 个完全不写（`GetUnits`/`GetIncidents`/`GetAudit`/`GetCitations`/`GetReports`，`server/p1.lua:84-95,117-132`、`server/p0.lua:56-75,118-137,249-257`）；写路径里 `p1`/`p3` 全部忽略审计返回值（见 NFR-REL-03）。`ArrestSubmit` 的"已送监但审计失败"返回 `{ok=false, error='audit_unavailable', jailed=true}`（`server/p2_system.lua:649-651`）——语义正确，但调用方（phone action）把它转成 `false`，丢掉了"已送监"这一关键事实。
- **验证方法**：07 FIT-05 的静态规则；Lua harness 注入 audit 失败断言行为。
- **缺口**：fail-closed 口径不统一；`GetUnits`/`GetIncidents`/`GetAudit`/`GetCitations`/`GetReports` 零审计；`audit_unavailable + jailed=true` 的复合状态未进契约测试。

### NFR-SEC-05 · PII

- **指标**：进入审计表的自由文本字段；NUI 返回的 PII 字段；保留期。
- **目标【建议】**：`police_audit.detail` ≤500 字符且不含电话/license/完整坐标（现状 500 截断已做）；`LookupCitizen` 只返回姓名/生日/职业/令状/通缉星级（现状一致，**不含电话**）；罚单通知只含掩码后的必要字段；PII 保留 180 天；读取 PII 的操作必须可审计（现状 lookup 可，案件/报告不可）。
- **当前实现【现状】**：`LookupCitizen` 返回 `name/birthdate/job/warrants/bolo/active_wanted/last_seen`（`server/p0.lua:228-234`），无电话/无 license——设计上是对的。但 `GetReports`/`GetCitations` 返回 `SELECT *`，把 `author_citizenid`、`officer_citizenid`、`plate`、自由文本 `body` 一次性推给 NUI 且不留审计（`server/p1.lua:123-131`）。
- **验证方法**：07 FIT-09（禁止 `SELECT *` + 字段白名单）；对 NUI payload 做一次字段 diff（人工）。
- **缺口**：查询侧 PII 扩散（`SELECT *` 16 处）；无保留期；无"PII 字段清单"文档。

---

## 5. 可观测性

### NFR-OBS-01 · `police_audit` 作为唯一取证面

- **指标**：审计覆盖率（写操作 / 敏感读）；`action` 词表稳定性；写入失败率；查询性能。
- **目标【建议】**：100% 写 + 100% 敏感读；`action` 词表受控（当前 26 个，新增需评审）；写入失败率 0，非 0 立即告警；`GetAudit` P95 ≤120 ms（`LIMIT 100`，`idx_action_created` 支撑）。
- **当前实现【现状】**：26 个 action 字面量（含 `lookup.citizen` / `lookup.vehicle` 与它们的 `.result` 两条）；`actor_kind` ENUM 有 `system` 但**无人使用**；`GetAudit` 只给 grade≥3，且不审计"谁看了审计"。查询 `ORDER BY id DESC LIMIT 100`（`server/p0.lua:249-257`）走主键倒序，性能没问题。写入失败率无指标（返回值被 `pcall` 包装后多数被忽略）。
- **验证方法**：静态统计 `audit(` 调用点与 action 字面量；实机 `SELECT action, COUNT(*) ... GROUP BY action` 与代码词表对比，缺失即为漏审计。
- **缺口**：无 `system` 事件（重启/掉线/清扫）；无审计读取审计；无失败率指标。

### NFR-OBS-02 · focus / NUI 诊断日志

- **指标**：`[custom-phone][focus]` 行数/分钟；每次开合的日志条数；是否含敏感字段。
- **目标【建议】**：每次开合 ≤8 行；采样（正常路径 1/10）；单玩家 ≤10 行/分钟，超限丢弃并计数；只记 `phase/attempt/focused/keepInput`（现状字段 OK，无 PII）。
- **当前实现【现状】**：`custom-phone/server/main.lua:1351-1359` 对**每条** `phone:server:focusState` 无条件 `print`，客户端在开/关/看门狗/超时各打一次（`custom-phone/client/main.lua:16,33,59,75,83,94,217,246`），一次开合约 4~8 行；无采样、无限流、无计数。字段已脱敏（只有 source 与布尔值）。
- **验证方法**：实机开合手机 10 次，数 `/tmp/fxserver.log` 行数；压测伪造 1000 条事件看是否洪泛。
- **缺口**：无限流/采样；日志只进 stdout，不入库、无指标；不能回答"上周焦点问题有多少次"。

### NFR-OBS-03 · NPC 生命周期指标

- **指标**：`spawned / cleaned / rejected_cooldown / rejected_limit / rejected_not_police / spawn_failed / leaked` 计数；活跃单位数；单位存活时长分布。
- **目标【建议】**：每次 `RequestBackup` 必产出 1 个结果计数；`cleaned` 与 `spawned` 在 10 min 窗口内差值 ≤1；活跃单位 ≤全局上限；存活时长 P95 ≤5.5 min（>6 min 视为泄漏疑点）。
- **当前实现【现状】**：**零指标**。唯一的可观测信号是客户端 `print`（模型缺失，`client/backup.lua:198`）与服务端 audit 行 `backup.request`（只在成功受理时写，拒绝原因不入库）。全局计数不存在，因此也无法检测泄漏。
- **验证方法**：Lua harness 断言每个分支都 `++` 对应计数器（需先加计数表）；实机 30 分钟后对比 counter 与 `active` 表。
- **缺口**：计数器、日志、告警全缺；拒绝原因不可观测（`fail('cooldown'|'limit'|'not_police')` 未落任何存储）。

### NFR-OBS-04 · 告警阈值

- **指标**：下述 A1–A11 的可观测信号（错误率 / 速率 / 队列深度 / 存活时长）。
- **目标【建议】**：全部信号有采集点，且阈值触发后 5 min 内有人知道。

| # | 信号 | 阈值【建议】 | 级别 | 触发后动作 |
|---|---|---|---|---|
| A1 | `police_audit` 写入失败 | >0 / 5 min | P1 | 页面；相关写路径开始拒绝 |
| A2 | `lookup.*` 拒绝率（`rank_too_low`/`not_police`） | >20 / min / source | P1 | 可疑提权探测，记录并在必要时踢出 |
| A3 | 单警官 MDT 查询 | >20 / min | P2 | 返回 `rate_limited` + 记录 |
| A4 | DB 查询 P95 | >50 ms 持续 5 min | P2 | 记录；检查慢查询 |
| A5 | DB 查询 P95 | >200 ms 持续 1 min | P1 | 页面；广播类路径降级 |
| A6 | 并发 open 警情 | >15 | P2 | 容量告警 |
| A7 | 最老 open 警情 | >60 min 无单位 | P2 | 调度 SLA 告警 |
| A8 | 活跃 NPC 单位 | >全局上限 或 存活 >6 min | P1 | 强制回收入口 |
| A9 | `focus` 日志速率 | >50 行/min/source | P3 | 采样模式 |
| A10 | 重复提交（同一 subject 5 min 内 >1 次逮捕） | >0 | P2 | 一致性排查 |
| A11 | 未鉴权 net event 命中（新事件） | >0 | P1 | CI 已拦截；运行时告警 |

- **当前实现【现状】**：A1–A11 全部无实现；无指标后端（无 Prometheus/Influx），只能靠 stdout 与人工 grep。
- **验证方法**：逐条标注"是否有采集点"（当前 11/11 无）；A1/A6/A8 可先用控制台命令 + 人工巡检代替，其余等指标层。
- **缺口**：没有指标导出层。最小可行方案：在 `custom-police` 起一个 `Metrics.Inc(name)` 纯内存计数 + 控制台 `police_metrics` 命令打印 JSON（不引依赖，符合"Python/工具只用标准库"的同类约束），先满足 A8/A10 两条。

---

## 6. 兼容性契约

### NFR-COMPAT-01 · qb-core `job.onduty`

- **契约**：`PlayerData.job` = `{ name, type, grade = { level = number, name }, onduty = boolean }`；`onduty` 的**唯一写者**应是 duty 服务；qb-core 的 `SetJobDuty` 是兼容投影。
- **指标**：`job.onduty` 写入点数量（目标 1、现状 4）；读 `onduty` 而与 `police_units` 不一致的路径数。
- **当前实现【现状】**：4 个写者——`qb-core/server/player.lua:291-297`（定义）、`core-framework/services/job_service.lua:125-152`（`SetOnDuty`，直接改字段）、`custom-main/server/dispatch.lua:236,261`（通缉自动下班）、`custom-director/server/main.lua:619-645`（agent `set_job_duty`）；`qb-core/server/events.lua:168-182` 的 `QBCore:ToggleDuty` 又调用定义。读侧更散：`job.type == 'leo'`（~27 处）、`job.name == 'police'`（`shared/policy.lua:36`）、`PolicePolicy.Grade` 只接受 `grade` 为 table（**若某处把 `grade` 存成 number，等级直接变 0，所有 rank 门失败**）。
- **目标【建议】**：单一状态机（`OffDuty/Available/Busy` + 派生 `Assigned/Enroute/OnScene`）；`on_duty = state ~= OffDuty`；`job.onduty` 只读投影；写入点 = 1。
- **验证方法**：07 FIT-01 静态扫描；契约测试断言 `PolicePolicy.Can` 在 `onduty=false` 时拒绝所有 cap（应已有，需补一条 `grade` 为 number 的负例）。
- **缺口**：TD-01 未拍板（4 个待定项见 [TECH_DEBT.md](../TECH_DEBT.md#td-01-值班勤务双状态高)）；`grade` 类型契约未文档化、未测试。

### NFR-COMPAT-02 · phone（custom-phone）

- **契约**：① 通知 = `phone_notifications(citizenid,title,content,app_id)` + `phone:client:newNotification{ id,title,content,timestamp,is_read,app_id }`（**`app_id` 决定深链**）；② app = `PhoneApps.Register({ id,label,icon,audience,queries,actions })`，返回 `{success,data|error}`；③ 平民侧 `phone:server:getMyCitations` / `phone:server:payCitation` 是既有出口。
- **指标**：跨资源直写 `phone_notifications` 的处数（目标 0、现状 4）；`app_id` 取值集合（目标 2 个：`police_mdt` / `banking`）。
- **当前实现【现状】**：`custom-police` **直接 INSERT `phone_notifications`**（`server/p0.lua:104-107`、`server/p1.lua:29-34`、`server/p2_system.lua:45-47,282-284`）——这是跨资源写别人的表（07 FIT-02 会拦）。phone 侧其实有 owner 函数 `StoreNotification`（`custom-phone/server/main.lua:223-262`，含 `phoneDataCache` 失效与 `app_id` 格式/长度校验），但**没有导出**，所以警察侧只能直写并绕过缓存失效（详见 [04-data-ownership.md](04-data-ownership.md) §4 与 G-12）。`app_id` 取值**尚未统一**：警情/派单广播与 `police_mdt` 的 `alert` 走 `police_mdt`（但 `alert` 的 INSERT 仍不带 `app_id`，`apps/police_mdt.lua:261` → NULL），罚单走 `banking`。
- **目标【建议】**：phone 把 `StoreNotification` 包成 `exports['custom-phone']:Notify(citizenid, { title, content, app_id })`，police 只调用导出；在导出落地前，FIT-02 对该表给**限时豁免**（写入点白名单 + 截止日期），避免"规则刚加就一片红"。
- **验证方法**：FIT-02 的 owner 表；契约测试断言 `app_id ∈ {police_mdt, banking}` 且 `content ≤500`。
- **缺口**：缺导出；跨资源写表；无 `app_id` 枚举校验。

### NFR-COMPAT-03 · justice（custom-justice）

- **契约**：`exports['custom-justice']:Imprison(citizenid, minutes, crimes)` → `true | false, code`；`OpenCase(citizenid, officerSrc, crimes)` → 案件号字符串（`CASE-0001`）；判决回写 `police_reports.justice_verdict` / `justice_status`（v3.7）；`justice_case_id` 是 **VARCHAR**，`police_reports.case_id` 是 **BIGINT**（TD-03）。
- **指标**：返回结构化（`{ok,code}`）的契约数（目标 2、现状 0）；`case_id` 类型冲突写入次数（目标 0）。
- **当前实现【现状】**：调用点 `server/p2_system.lua:108-117`（Sys.Jail）、`604-614`（ArrestSubmit）、`564-578`（open_case）；每次都用 `pcall` + 字符串比较 `result == true`，失败落到 metadata + `prison:client:Enter` 兜底。`activeCases` 在内存，重启即丢（TD-02）。
- **目标【建议】**：导出返回结构化 `{ ok, code, case_id }`（字符串码），police 侧不再猜 `== true`；`justice_case_id` 永不写入 `case_id`（现状已用 `tonumber` 守卫，`server/p2_system.lua:586-595`）。
- **验证方法**：`tests/unit/layer3_business/test_arrest_submit.py` 已锁住 charge 目录与 justice 配置的一致性（13 条）；补一条"导出返回值类型"契约。
- **缺口**：内存态 + 双案件号；`Imprison` 对在押者返回 `true` 造成幂等假象（NFR-REL-05）。

### NFR-COMPAT-04 · qb-prison

- **契约**：写 `metadata.injail` / `metadata.criminalrecord` / `metadata.jailitems`；事件 `prison:client:Enter` / `prison:client:UnjailPerson`；**入狱会把 `job` 强制改为 `unemployed`**（`qb-prison/server/main.lua:11-14`）。
- **指标**：police 侧模块级缓存 `job`/`onduty` 的变量数（目标 0）；出狱后 MDT 访问被拒率（应 100%）。
- **当前实现【现状】**：`custom-police` 通过 `TriggerClientEvent('prison:client:Enter'|'UnjailPerson')` 与 `SetMetaData('injail')` 交互（`server/p2_system.lua:114-116,611-613,826-827`），无导出封装。
- **决策（已定）**：**不做"出狱恢复职业"**（`docs/police/STATUS.md`"方案 B 落地状态"末条）。因此警察系统**不得**缓存 `job.name`/`onduty` 跨会话或跨事件；每次判定必须重读 `PlayerData`。
- **目标【建议】**：把"每次重读"写成显式约束（07 FIT-01 的读侧子规则 + 代码评审项）；文档标注 `qb-prison` 是 job 重置的合法 owner。
- **验证方法**：静态检查 police 侧是否有模块级缓存 `PlayerData` / `job` 的变量（当前无模块级缓存，都是按 source 现查）。
- **缺口**：`police_units` 在出狱后仍是 `off_duty`（正确），但玩家职业已非 police，MDT 立即不可用——属产品预期，需在玩家指引里说明。

### NFR-COMPAT-05 · 弃用策略

- **规则【建议】**：任何"停止新写入"的表/事件，必须在 `docs/police/architecture/deprecations.md` 登记（owner、替代物、停止写入日期、删除日期、CI 检查名），并由 07 FIT-12 强制：**deprecated 写路径必须为 0 或在 allowlist 内且未过期**。
- **指标**：deprecated 表的写路径数（目标 0）；已登记弃用项比例。
- **目标【建议】**：`police_arrests` / `police_bolos` 写路径 = 0；legacy 命令/事件 100% 登记并有删除日期。
- **当前实现【现状】**：[B_PLAN.md](../B_PLAN.md) §2 已宣布 `police_arrests` 停止新写入、`police_bolos` 停止新写入（BOLO 改 report 标签），但代码里 `police_arrests` 仍有 **2 个写者**：`server/p2_system.lua:118-120`（Sys.Jail）、`server/p3_cases.lua:197-201`（`RegisterArrest`）。`police_bolos` 同样仍被 `CreateBolo` 写入（`server/p3_cases.lua:73-95`），而 `GetBolos` 已经双源合并（行 96-135）。legacy 命令 `/911p`、`/fine`、`/jail` 的去留也未登记。
- **验证方法**：FIT-12；每季度 review 一次 allowlist 的 `expires`。
- **缺口**：弃用只有文字、没有机器可读清单，也没有 CI 拦截；`police_arrests` 的"停止写入"事实上没有执行。

---

## 7. 缺口汇总（按"风险 × 成本"排序）

| 序 | 缺口 | 关联 NFR | 成本 | 建议动作 |
|---|---|---|---|---|
| 1 | 9 个 `evidence:server:*` 无鉴权 | SEC-02 | 低 | 下线或加 `PolicePolicy.Can`+onduty；07 FIT-04 先行 |
| 2 | 审计 fail-open（p1/p3 忽略返回值） | SEC-04 / REL-03 | 低 | 统一 `if not audit(...) then return false,'audit_unavailable'`；FIT-05 |
| 3 | 无 DB 指标 / 慢查询 / qps | PERF-06 | 低 | 开 slow log + 记录连接池参数；perf baseline 文档 |
| 4 | `police_units` 重启后 stale | REL-04 | 低 | `onResourceStart` 清扫 + 审计 |
| 5 | 重复提交（支付/逮捕/报告） | REL-05 | 中 | 条件更新 + 幂等键列 |
| 6 | NPC 无全局上限 / 无指标 | SCALE-03 / OBS-03 | 中 | 计数器 + 全局 cap + 拒绝码 |
| 7 | `SELECT *` 16 处 / 单次响应无上限 | PERF-02 / SEC-05 | 中 | 字段白名单 + 字节上限 |
| 8 | 无保留策略（audit/notification） | SCALE-05 | 中 | 维护任务 + 归档表 |
| 9 | 无备份计划 / 无演练 | REL-06 | 中 | cron + 季度演练 |
| 10 | `job.onduty` 4 写者、无单一状态机 | COMPAT-01 | 高 | TD-01 拍板后收敛；FIT-01 advisory 先行 |

---

## 8. 附录

### A. 测算口径（本文数字怎么来的）

- **每警情 DB 往返** = 1（incident insert）+ N（在勤警察通知 insert）+ 1（audit）= `N+2`；N=8 → 10。
- **每 lookup 往返** = 1（players）+ 2（warrants/bolo）+ 2（audit）= 5。
- **每次逮捕往返** ≈ 2 读 + 6 写（report/case/caseNo/link/citation/evidence/chain 中按分支）+ 2~3 audit + 1 通知 ≈ 15（最坏）。
- **audit 日增** = 查询数 × 2 + 写操作数 × 1；按 10 名警官 × 30 次查询/日 → 600 + 200 ≈ 800。
- **NPC 实体** = 单位数 × (1 车 + 2 ped)；全局 6 单位 → 18。
- **qps 估算** = (每分钟警情 × 10 + 每分钟查询 × 5 + 每分钟写 × 15) / 60；按峰值 2 警情/min、60 查询/min、5 写/min → (20+300+75)/60 ≈ 6.6 qps；本文给的 30 qps 稳态留了 4 倍余量，覆盖未建模路径（手机、车辆、其他资源）。

### B. 未验证 / 不可离线验证

- 所有 P95 数字（无实机采样，仓库也没有 perf baseline）。
- 客户端 NPC 生成/清理（需真客户端；`tcity-e2e` 假人没有 ped，`GetPlayerPed` 返回 0，`ArrestSubmit` 的物理前置条件无法在假人上通过）。
- DB 实际 qps 与慢查询（未接 `performance_schema`）。
- `police_units` 重启后 stale 的实际分布（需在跑服采样；本文只从代码推断"无清扫"）。
- 备份/恢复的实际 RTO（未演练）。
- L2/L3 agent 的实机 approve→executed（`docs/police/STATUS.md` 已列为未完成）。

### C. 待建文件

- `docs/police/architecture/perf-baseline.md`：实机采样结果（P50/P95/往返数/响应字节）。
- `docs/police/architecture/deprecations.md`：弃用登记表（NFR-COMPAT-05）。
- `docs/police/architecture/error-codes.md`：错误码词表（07 FIT-05 依赖）。
