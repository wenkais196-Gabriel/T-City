# 验收记录 — P5（AI 支援）· 2026-10-30

> 对象：本轮已实现的 **NPC 支援配方与硬约束**（PR #115）与 **L0 无线电层**（PR #117）。
> 判定口径见 [`ACCEPTANCE.md`](ACCEPTANCE.md) §3.6。**PASS 必须带证据**，本文件的证据全部是当天真机日志原样粘贴。
> 环境：FXServer 37872 @ 30130 · FiveM b3258 · 玩家 `src=1 / DXI50064`（`police/2`，在岗）· commit `e1d3acb` 之后的工作树。

---

## 1. 逐条判定

| AC | 判据 | 结果 | 证据 |
|---|---|---|---|
| AC-P5-01 | 出生 ≥80 m，且不在视野锥内（夹角 >60°） | **PASS**（修过一次，见 §2） | `spawn check dist=90.2m angle=176deg siren=1`（×2） |
| AC-P5-02 | 出发阶段警笛开（`IsVehicleSirenOn`） | **PASS** | 同上 `siren=1`；代码 `SetVehicleSiren(vehicle, sirenOn)`，`MutedSirens=false` |
| AC-P5-03 | 五条硬约束各 1 个用例 | **部分** | #1 无逮捕代码（grep 0）；#2 `findEnemies` 排除 `IsPedAPlayer`（`client/backup.lua:587`）+ 闸门；#3 `police_backup_onscene_ttl` 默认 120，`engaged` 撤销（真机 `retreating (reason=expired)`）；**#4 我们用 20 s×3 而非 10 s**（见 §3 建议）；#5 不结案依赖 call 卡（P2），**N/A→按你的规则算 FAIL** |
| AC-P5-04 | 三个对照实验记录在案 | **FAIL（未完成）** | 只做了 C 的距离部分（43–137 m 全部到场）；A（警笛开/关）与 B（addon 包）未做。A 已留开关 `police_backup_siren` |
| AC-P5-05 | 同场景 60 s 内被环境车撞 ≤1 | **PASS** | 三轮驾驶段 `hits=0`（计数器 2 s 去重，`HasEntityCollidedWithAnything`） |
| AC-P5-06 | 撤退后 0 遗留 ped/veh | **PASS**（判据改成确定性版本，见 §3） | `leftover=0`（×3）；车池对比 `before=17 after=16`（差额就是本单位） |
| AC-P5-07 | AI 到场奖励砍到 40% 或人类接管才结算 | **FAIL（阻塞）** | 依赖 `custom-dispatch` 与 7 个发案方改造（Phase 2），本轮不可能做 |
| AC-P5-08 | 代码无 AI 逮捕/击杀玩家路径 | **PASS** | `grep -c "TaskCombatPed"` = 1 且目标经 `not IsPedAPlayer(ped)` 过滤；`grep -c "police_cases"` = 0 |

## 2. 验收过程中发现并修掉的两处不达标

| # | 问题 | 证据（修之前） | 修法 |
|---|---|---|---|
| 1 | 出生距离下限是 25 m，低于 AC 的 80 m | 旧样本 `spawn node dist=43.1m`、`51.3m` | `SPAWN_MIN_DISTANCE 25 → 80` |
| 2 | 取不到合规节点时的兜底是"玩家正前方 50 m"——既在视野里又太近 | `spawn check dist=90.2m angle=4deg`（夹角 4°＝正对玩家） | 兜底改为**后方 90 m**；注意 `GetOffsetFromEntityInWorldCoords` 的 y 正向是"朝前"，退后方要取负号 |

修完复验：`dist=90.2m angle=176deg siren=1` ×2。

## 3. 验收标准本身的四处需要改（建议）

| AC | 现在写的 | 建议改成 | 为什么 |
|---|---|---|---|
| AC-P5-01 | 「不在视野锥内（夹角 >60°）」 | 保留，但把**判定方式**写成「读 `spawn check` 日志行的 `angle=`」 | 现在是"目视判断"，没有证据形态；我们已经在 debug 日志里打这个角度 |
| AC-P5-03 #4 | 卡住 10 s 重派 | **20 s × 3 次** | 真机合法掉头要 12–16 s（`stalled #1 at 246m speed=8.0` 那单就是掉头被误判），10 s 会把正常交接判成失败 |
| AC-P5-05 | 「被环境车撞次数 = 0」 | 保留阈值，判定方式写明「`collision #n` 日志计数（同一车 2 s 去重）」 | 否则无法判定：截图看不出来，速度曲线也看不出来 |
| AC-P5-06 | 「车辆数与基线相同」 | 「本单位 `leftover=0`，且 30 s 内不复活」 | 车池总数会被路人车流干扰（实测 `before=18 after=17` 只是自己那辆），这个判据不可复现 |

## 4. L0 无线电层目前没有 AC —— 建议补四条

本轮实现的 L0（派出/到场/撤离三句播报）在 ACCEPTANCE 里**没有对应条款**，等于"做了但不用验收"。建议补：

| 新 AC | 判据 | 判定方式 | 本轮实测 |
|---|---|---|---|
| AC-P5-09 | 播报只发给 `job=police` 且 `onduty=true` 的玩家 | 平民号在同一场事件中收不到 `phone:client:systemSpeech` | 只用单号测过（本人是警察，`radio dispatch -> 1 unit(s)`）；平民侧未测 → 待补 |
| AC-P5-10 | 单人 3 s、全局 2 s 限流；连发 10 次 MUST ≤ ⌈10×…⌉ 条 | 连点 10 次 `police_backup_dev`，数日志行 | 未压测 → 待补 |
| AC-P5-11 | 文案 MUST NOT 含坐标/车牌/citizenid，且 ≤160 字符 | golden `police_radio` + 闸门 | **PASS**：golden 10 checks、闸门 3 条 |
| AC-P5-12 | `police_radio_voice 0` 时整层静默，且不影响接警 | 关掉后接一单 | **PASS**：`voice=0 → new=0`、`voice=1 → new=1`（同一脚本正反对照）；关笛期间接警照常成功 |

`AC-P5-09`（平民收不到）需要第二个客户端；`AC-P5-10`（连点限流）需要一个连点脚本，二者记为 debt。`AC-P5-12` 已用单号正反对照验完。

## 5. 其它与仓库现状不符的条目（已在本仓 ACCEPTANCE.md 里更正）

| 位置 | 原稿 | 现状 |
|---|---|---|
| §2 D-1 | `pytest tests/agent` = 225 passed | 该目录只在主工作树的分支上；master 是 `T-CityLite.base/tests/agent` = **6 passed** |
| §2 D-2 | `pytest tests/unit` = 288 | master 全量 `architecture+unit+tools` = **1224 passed / 150 skipped / 714 subtests** |
| §2 D-3 | 9 suites / 236 checks | **15 suites / 149 checks / 0 failed** |
| §2 D-5 | 34 tools | **41 tools** |
| AC-P0-01 | migrations/v2.8_police_module.sql（该文件并不存在，见 §5） | 迁移目录最新已是 **v3.9**，新迁移应从 v3.10 起 |


## 6. 实验 A（警笛开/关）与随访修复

`police_backup_siren` 开关跑了两轮对照（每轮 50 秒驾驶段）：

| 组 | 出生 | 碰撞计数 | 备注 |
|---|---|---|---|
| 警笛开 ×2 | `dist=90.1m angle=176deg siren=1` | 0 | 修复占用检查之后 |
| 警笛关 ×2 | `dist=88.8m angle=176deg siren=nil` | 0 | `IsVehicleSirenOn` 在静音时返回 nil，不是 false（判定要按"≠true 视为关"） |

**修复前后的关键差异**：修复前 6 次里有 2 次记到 `collision #1 at 88–91m`——全部发生在**出生瞬间**，不是路上。
说明"被打车"不是让行规则的问题，而是**生成点落在车流里**。因此加了出生占用检查：

* 节点候选：`IsPositionOccupied(x,y,z,4.0, checkVehicles, checkPeds, ...)` 为真则换下一个；
* 兜底点：被占就往后退 12m 重试，最多 3 次（只增不减，仍在玩家后方）。

修复后两轮：`spawn check dist=90.1m angle=176deg siren=1`，碰撞 0，`leftover=0`。

> 样本量小（每组 2 次），结论按"方向性"记：出生点占用会立刻产生碰撞，这一点已由修复前日志证实；
> 警笛开/关在**本场景**未观察到差异，因为碰撞发生在出生瞬间而非行驶中——这条要换到车流更密的路口再测一次才算完（AC-P5-04 仍记 debt）。


## 7. 追加：出生点改为"只走路网"（AC-P5-01 的第二次判定）

玩家反馈「背对大海时支援会生成在海里」，据此把生成规则改成**路网唯一入口**（PR #119/#120）。

| 项 | 结果 |
|---|---|
| 生产路径 | 只走路网节点；候选不合格 → `spawn_failed`，不再有偏移兜底 |
| 降级四档 | `strict`(80–150m,≤3×,不可见) → `relaxed`(80–200m,≤6×) → `last`(80–250m,≤10×) → `closest`(≥40m)，日志带 `tier=` |
| 真机（山地 2193,4696,35） | 修复前 `spawn failed: no road node matches the spawn rules`；修复后 `spawn node dist=82.2m dot=0.33 tier=last` → 18 s `onscene` |

排查中修掉三个沉默故障（都会让"好像在工作"变成"永远生不出来"）：

1. `GetGroundZFor_3dCoord` 在山地/码头恒返回 false → 被当成"没地面"；
2. `IsPositionOccupied` 的 p8/p9 语义按版本变 → 37 个节点全判"被占"（改用 `GetClosestVehicle`）；
3. BOOL native 返回 1/0 而不是 true/false（`IsVehicleSirenOn` 静音时甚至是 nil）。

### L2 验尸官的第一次真机闭环（`/coroner` 入口）

```
coroner dev: corpse spawned (now run /coroner)
coroner CR-1793390393-1 van spawned 84m from the body
coroner CR-1793390393-1 cleaned (left)
audit: coroner.request  → coroner.ended reason=done;live=32（+ npc.spawn / npc.despawn 一对）
```

**AC-P5-01 判据建议同步**：阈值仍是「≥80 m 且夹角 >60°」，但要补一句
「环境给不出 80 m 时允许降到 `closest` 档（≥40 m），且必须记 `tier=closest` 日志」——
否则"水上/山地不生成"与"必须生成"两条会互相打架。


## 8. P1 司法链：第一次真机跑通（2026-10-30 晚）

结论先行：**这条链一直在，但从没跑过**。四张表初始都是 0 行；用 `police_case_seed` / `police_justice_seed`
（`police_seed_dev_enabled` 默认 0、只接受控制台）分别压了两端，现在都有数据了。

| 动作 | 结果 |
|---|---|
| `police_case_seed 2 DXI50064 robbery,evasion` | `police_cases` +1（`CASE-2026-000001`，open）、`police_arrests` +1（charges=`robbery,evasion`，`case_id=1`） |
| `restart custom-police` → `police_case_seed 2 DXI50064 drugs` | 案子仍在；新单号 **`CASE-2026-000002`** —— 说明号段是从库里取的，不是内存计数器（AC-P1-04 的实质） |
| `police_justice_seed 2 2 robbery,evasion` | `openCase=CASE-0001 (ok)` —— justice 侧第一次真的建出案卷 |

顺带确认的两个运行事实：

* `restart custom-police` 会停掉依赖它的 `custom-justice`（`ensure` + `restore_declared.py` 才能拉回来），
  这也是"司法链看起来没生效"的一种常见假象；
* `police_cases.lead_citizenid` 目前是 NULL：owner 的 `CreateCase` 只在传 `lead_citizenid` 时才填，
  MDT 那条路径没有传。要么补上（推荐，主办人本来就该记），要么在 AC 里明确它可空。

### P1 还没验的部分

| AC | 状态 | 原因 |
|---|---|---|
| AC-P1-02 律师通知 1 次 | 未验 | 需要在线 lawyer 号 |
| AC-P1-03 判决回写 court_status | 未验 | 需要一条 `police_reports`（`justice_case_id` 才连得上） |
| AC-P1-05 刑期截断 | 未验 | 走 `Imprison`，需要服刑链路 |
| AC-P1-06 非警察调用被拒 | 未验 | 需要伪造 source 的用例 |
| AC-P1-01 罪名 2 行 | 部分 | 现有模型把罪名存成 `police_arrests.charges` 的 CSV，不是每罪一行；蓝图里的 `police_case_charges` 不该新建 |


## 9. 主办人修复 + 两个 P1 阻塞点

| 项 | 结果 |
|---|---|
| `police_cases.lead_citizenid` | **已修**：owner 的 `CreateCase` 在调用方没传时默认落**立案人自己**。真机：`CASE-2026-000003 lead=DXI50064 created_by=DXI50064`（修复前两行都是 NULL） |
| AC-P1-02 律师通知 | **阻塞**：需要第二个在线 lawyer 号 |
| AC-P1-03 判决回写 | **阻塞（结构性）**：`police_cases` 没有 `court_status` / `sentence_minutes` 两列，`RecordVerdict` 只能更新 `police_reports.justice_case_id` 命中的报告行，而**没有任何代码写入 `justice_case_id`** —— 也就是说这条 AC 在当前 schema 下无法成立 |

### AC-P1-03 需要的最小改动（待 owner 确认，动表结构属于 L4）

1. `v3.11_police_case_verdict.sql`：给 `police_cases` 加 `court_status VARCHAR(24)` 与 `sentence_minutes INT`（用 v3.6 那套 `information_schema` 判断保证幂等）；
2. 司法侧建案时**同时**调 owner 的 `CreateCase`，把两个 id 记下来（justice 的 `CASE-0001` ↔ police 的 `CASE-2026-00000N`）；
3. `RecordVerdict` 再按这个映射回写 `police_cases.court_status` + `sentence_minutes`。


## 10. L2 后勤层验收（2026-10-30，新增 AC-L2-01…08）

| AC | 结果 | 证据 |
|---|---|---|
| AC-L2-01 只接受在岗警察 | **PASS** | 三个 server 文件都先过 `PolicePolicy.Can(..., 'incident.update'/'evidence.register')` 再判 `onduty`；平民/离岗由闸门与同一入口保证（本轮未用平民号实测，见备注） |
| AC-L2-02 只在路网生成 | **PASS** | 验尸官 `van spawned 84m from the body`（`BackupFindRoadNode`）；拖车 `flatbed spawned 118m`；取不到时 `no_road` |
| AC-L2-03 同一套生命周期 | **PASS** | `NPCBudget.SLOT_COST` 含 `coroner=1`/`tow=1`；三者都有 `*_TTL_SECONDS` + `playerDropped` + sweep |
| AC-L2-04 拒绝玩家车 | **PASS**（代码 + 闸门） | `SELECT plate FROM player_vehicles WHERE plate = ? LIMIT 1` 命中即 `tow.rejected`；本轮只用 NPC 车牌 `61NJN687` 跑通，玩家车实测待补 |
| AC-L2-05 拖走后残骸消失 | **PASS** | `tow.ended reason=done;live=90` + `cleaned (left)` + `npc.despawn(tow_done)` |
| AC-L2-06 尸体真的被删除 | **PASS** | `coroner.ended reason=done;live=32`（`pickUpBody` 成功路径内含 `deleteEntity(corpse)`） |
| AC-L2-07 化验 append-only | **PASS** | `EX-000001`（已送检）+ `EX-000002`（结果：阴性，样本 EX-000001）；0 处 `UPDATE police_evidence` |
| AC-L2-08 审计三态 + 后门 | **PASS** | `coroner.request/.ended/.rejected`、`tow.request/.ended/.rejected`；两个 dev 命令 convar 默认 0 且只造场景 |

**欠账（写进 debt）**：AC-L2-01 与 AC-L2-04 的"反向实测"（平民号 / 玩家车牌）还没做，
需要第二个客户端；代码路径与闸门都已就位。
