---
id: engineering-foundation-p1-evidence
type: audit
status: active
system: meta
owner: hermes
updated: 2026-11-01
review_by: 2027-05-01
topic: foundation-hardening
tracks: [docs/engineering/2026-11-foundation-plan.md, docs/engineering/STANDARDS.md]
---

# P1-2 / P1-1 验收证据（存档单写者 + 拆环）

> **类型**：audit（判据 + 可复现输出） ｜ 判据来源：docs/engineering/2026-11-foundation-plan.md §3
> **对应条目**：P1-2（拆 `ForceFlush → Save(true)` 的环）、P1-1（存档收敛为单一 owner，失败保留 + 退避 + ack）
> **验收人**：Claude Code 只读复核，结论与逐条处置见 §8

## 1. 判据与结论

| 判据（计划原文） | 结果 | 证据 |
|---|---|---|
| P1-2：等价复现脚本从 stack overflow 变单次写 | **通过** | §2 红 → §3 绿；`test_flush_never_calls_player_save_and_writes_exactly_once` |
| P1-1：失败 fake DB 后 dirty 仍在且 `failed_flushes` 增长 | **通过** | `test_failed_flush_keeps_dirty_and_counts_it_then_retries` |
| P1-1：停服刷盘有 ack | **通过** | `Store.FlushAll` 返回 `{reason, attempted, ok, failed, duration_ms}`；`test_flush_all_reports_an_ack_with_counts_and_duration` |
| P1-1：一个池、一个定时器 | **通过** | delegate 无 `_dirty`、无 `CreateThread`、无 `INSERT`（结构断言）；真机日志只有一个 tick |
| DoD-2：改动前的红输出留档 | **通过** | §2 |
| DoD-2：新增闸门有反向用例 | **通过** | 失败注入、`IsDirty` 漏池、非玩家 key、心跳重标脏，以及**变异测试**（打穿"成功才清脏"守卫必须变红） |

## 2. 改动前（红）

把 HEAD 上的三份源码放进临时树，配上**当前**的闸门（临时目录 redcheck，不动工作区）：

```text
$ pytest tests/unit/layer1_core/test_persistence_single_owner.py -q
12 failed in 1.88s
```

其中环本身是栈溢出，不是断言失败：

```text
E       AssertionError: 刷盘直接炸了（栈溢出就是这条环）:
E         lua5.4: ...: stack overflow
E         stack traceback:
E                 ...: in field 'MarkDirty'
E                 ...: in field 'Save'
E                 ...: in field 'ForceFlush'
E                 ...: in field 'Save'
E                 ...: in field 'ForceFlush'
E                 ...     (skipping 399964 levels)
E                 ...: in field 'FlushAll'
```

环的形状（同一个 Lua state 里两份实现互相指向）：

```text
core-framework  DirtyFlush.ForceFlush(cid)
   → Player.Functions.Save(true)
      → qb-core  QBCore.Player.Save(src, true)
         → DirtyFlush.MarkDirty(cid) / DirtyFlush.ForceFlush(cid)
            → 回到第一行
```

生产环境没炸，只因为 FiveM 每个资源是独立 Lua state，`_G.DirtyFlush` 在两侧分别是
两份不同实现 —— 代价是**两套脏池、两个 900s 定时器、互相看不见**，外加"刷盘失败也清脏"。

## 3. 改动后（绿）

```text
$ pytest tests/unit/layer1_core/test_persistence_single_owner.py tests/unit/layer1_core/test_persistence.py -q
19 passed

$ pytest tests/unit tests/architecture -q
1120 passed, 147 skipped, 51 subtests passed

$ pytest tests/tools -q
239 passed, 3 skipped, 716 subtests passed

$ python tools/dev/release_check.py
[release_check] 扫描 6237 个跟踪文件 … 结论: 通过

$ python tools/docs_lifecycle.py --check
[check] total=281 registered=281 unregistered=0 errors=0 warnings=0
```

## 4. 结构证据（改了哪里、为什么这样改）

| 位置 | 变化 | 说明 |
|---|---|---|
| `persistence_manager.lua:214` | `Store.SaveNow(target, reason)` | 唯一写库入口；**不回调 Save**，直接 `MySQL.insert.await` + `pcall` |
| 同文件 `:142` / `:166` | `noteSuccess` / `noteFailure` | 成功才清脏；带 `rev` 版本号，写库期间又被标脏则条目保留；失败保留 + 退避 + `failed_flushes` |
| 同文件 `:264` | `Store.FlushAll(reason, ignoreBackoff)` | 返回 ack；停服/资源停止传 `ignoreBackoff = true` |
| 同文件 `:183` / `:214` | 非玩家 key 不入池 | `region:key` 这类没有 `PlayerData`、也不对应在线玩家的 key 直接拒绝——否则会变成永远退避的僵尸条目 |
| 同文件 `:284-294` | `isdirty_scan` 兜底 | `IsDirty = true` 但没进池子的玩家（economy/metadata 只标 IsDirty）也会被刷到 |
| 同文件 `:34` | `wallMs()` | ack 的 `duration_ms` 用 `GetGameTimer` 墙钟（TS-8），不再用 `os.clock` 冒充阻塞时长 |
| 同文件 `:344` | `dirty_count` 别名 | custom-testing 的 stress_test.lua 与 architecture_stress_test.lua 仍读旧字段 |
| core-framework 的 persistence_manager.lua:117 | `_G.DirtyFlush = Delegate` | 委托层：无池、无 SQL、无定时器、无 `Save` 调用 |
| 同文件 :67-78 | `FlushAll` 只接受 ack 表 | owner 返回非表（旧版本/异常）时降级成 `attempted=0` 的**同形状** ack，调用方不会拿到 boolean |
| `player.lua:606` | `store.SaveNow(Player, 'save_force')` | 强制存档一次写；失败保留脏标记并 `ShowError` |
| `player.lua:594-598` | 非强制存档清 `IsDirty` | 债务已进池；不清会让 5 分钟心跳每次重跑 `SaveInventory` |

## 5. 真机证据（2026-11-01，FXServer :30130，0 玩家在线）

热更新路径：`restart qb-core`（连带停掉依赖者）→ 逐个 `ensure` 拉回。

```text
[scripts:qb-core] [persistence] ✅ single owner store loaded (dirty pool / timer / SQL writer)
[scripts:qb-core] [persistence] ⏰ Flush tick started: every 900 seconds (owner=qb-core)
[scripts:core-framework] [persistence] ✅ delegate loaded (owner=qb-core: resolved)
```

拉回后实测：`info.json` **85 个资源**在跑（与本次重启前一致），自 `single owner store loaded` 之后
**0 条 SCRIPT ERROR / No such export**，且只出现一次 `Flush tick started`（qb-core 侧）。
拉回过程中被 `ensure` 顺带起过的两个 dev 资源（custom-agent-ops / custom-testing）已停掉，恢复原启动集合。

（重启过程中暴露并修掉了一个真问题：写者文件在 qb-core 的 `main.lua` 之前加载，
顶层调 `exports['qb-core']:GetCoreObject()` 会直接 `No such export` 并中断整份脚本。
现在改为调用时惰性解析 —— 这条正是"只读测试永远发现不了、只有热重载能暴露"的类别。）

## 6. 没做的（不在本条目范围）

| 项 | 为什么不在这次 | 去处 |
|---|---|---|
| 字段级 dirty 位图 | 本次是"整行 upsert + 类型标签"，只解决所有权与失败语义 | TS-6 剩余项 |
| 幂等键防重放 | 需要表结构与迁移 | P2-3 邻域 |
| 带脏玩家时停服刷盘的真机演练 | 本次真机是 0 玩家；`onResourceStop` 内 `await` 的路径只有离线证据 | P1 收尾时补一次 |
| qb-core 的 `SaveOffline` / `SaveInventory` 路径 | 未改动，仍由原调用方驱动 | — |

## 7. 回滚

```bash
git revert <this commit>          # 三个 Lua 文件 + 两个测试文件，无数据迁移
restart qb-core && tools/dev/resync_modules.sh
```

无表结构变更，回滚不需要动库。

## 8. Claude Code 独立验收（只读，2026-11-01）

总结论：**有条件通过** —— 环已拆、单写者 / 失败保留 / ack 主干成立。它给出 5 条「应修」+ 5 条「建议」，
逐条处置：

| # | 发现 | 来源 | 处置 |
|---|---|---|---|
| 1 | 文档断链（services/persistence_manager.lua 与 server/main.lua 这类资源内相对路径被写成反引号，闸门解析不到），全量测试 1 红 | CC 阻断项 | **已修**：改成裸文件名/叙述，`test_docs_links` 转绿 |
| 2 | 非玩家 key（`region:key`）永久驻留脏池、`failed_flushes` 单调增长 | CC 探针 | **已修**：无快照且不在线的 key 直接拒绝；新增闸门 |
| 3 | 写库 `await` 期间的新脏标记被 `noteSuccess` 吞掉（丢更新） | CC 探针 | **已修**：脏条目带 `rev`，版本变了就不清；新增闸门 |
| 4 | "剥守卫形状"反向用例不存在，证据虚报 | CC | **已修**：补变异测试（打穿"成功才清脏"守卫必须变红），§1 按实际列出 |
| 5 | 证据数字不实（1116 / 7 failed / 256-124） | CC | **已修**：按当前闸门重测（12 failed，栈溢出仍可复现；1120 passed；行数 432/135） |
| 6 | `duration_ms` 用 `os.clock` 违反 TS-8 | CC 建议 | **已修**：改 `GetGameTimer` |
| 7 | 非强制 Save 不再清 `IsDirty` → 心跳重复 `SaveInventory` | CC 建议 | **已修**：非强制分支把债务交给池子后清 `IsDirty` |
| 8 | 停服刷盘（有脏玩家）未真机验证 | CC 建议 | **未做**，已记入 §6 |
| 9 | `DirtyFlushStats` 的 `dirty_count` 字段消失，压测脚本静默读到 0 | CC 建议 | **已修**：`Stats()` 同时返回 `dirty_count` |
| 10 | `STANDARDS.md` 仍用现在时说"两套池" | CC 建议 | **已修**：改成过去时并标注收敛日期 |

CC 另确认：闸门文件（`net_events_allowlist.json` / `query_allowlist.json` /
`gate_coverage_budget.json` / `gate_history.jsonl`）**零改动**；`test_persistence.py` 的重写删掉的是
"刷盘必须回调 `Player.Functions.Save(true)`"这种把 bug 写进验收标准的旧断言，其余约束未被放宽。
