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
