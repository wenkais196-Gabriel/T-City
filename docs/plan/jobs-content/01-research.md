---
id: jobs-content-01-research
type: research
status: draft
system: jobs
owner: hermes
updated: 2026-11-13
review_by: 2027-02-28
stage: R
---

# 调研：职业内容填充（阶段 R）

> 阶段 R 的产物。退出条件：影响面清楚 + 有证据 + 至少排除过一条假设。
> 配套：总规划见 [../jobs-content-roadmap.md](../jobs-content-roadmap.md)（R0–R6 分批与五项拍板）。
> 本文件只回答「现在到底是什么样、能不能按想的做」，不写做法。

- 日期 / 负责人 / 级别：2026-11-13 / Hermes / **L3**（跨资源 + 新增机制类型）
- 关联：`docs/plan/jobs-content-roadmap.md` §5 R0–R6
- 协作：内部实测 = Hermes（脚本扫 + 逐行读）；表达力盘点 = Claude Code 只读（30 轮工具，`file:line` 逐条已复核）

---

## 1. 问题陈述

一句话：**22 个职业里只有 4 个有真实循环，市政厅可申请的 7 个民职有 6 个只有名字**——
上一轮把它们做成了 quest 的「走到点 + 按住 E」的壳，玩家 3 分钟就能发现里面没有机制。
本轮要把这些壳变成能重复玩的循环，所以在动手前必须先确认两件事：**现有引擎能表达哪些机制**、
**外部同类实现是怎么定数值与留人的**。

---

## 2. 证据（内部实测，可复现）

| # | 证据 | 来源 / 命令 |
|---|---|---|
| 1 | 22 个 job 定义，全部只有 `label` / `defaultDuty` / `offDutyPay` / `grades.payment`，无玩法字段 | `resources/[qb]/qb-core/shared/jobs.lua`（`rg "'payment'"` 命中 105 行，全部在 grades 内） |
| 2 | 有真实循环的只有 police / ambulance / mechanic×3 / miner 四条；qb-shops 的送货循环无 job 校验（本轮已修，见 CHANGELOG） | 各资源 config + server；`test_shops_guards.py` 5 passed |
| 3 | 市政厅可申请 7 个民职（trucker/taxi/tow/reporter/garbage/bus/hotdog），其中 6 个全仓只有 career/storage 配置引用 | `resources/[qb]/qb-cityhall/config.lua` 的 `AvailableJobs`；全仓 grep 命中清单 |
| 4 | 7 条民职壳任务，step 只有 `reach` 与 `interact`（到点、按住），无乘客/计价/顾客/货损 | `quest_public_services.lua`、`quest_civilian_misc.lua`（逐个 step 读过） |
| 5 | 声望写入口 5 处、读出口 1 处（qb-drugs 的 dealer minrep），无等级/解锁/面板 | `rg "AddRep\("` → 5；`rg "GetRep\("` → 5 处命中但只有 dealer 一处用于判定 |
| 6 | **NPC 预算只属于 police**：`NPCBudget.MAX_GLOBAL = 6`、`MAX_PLAYER = 2`、TTL 10 分钟，kind 只有 `backup` / `callout` / `coroner` / `tow` | `resources/[custom]/custom-police/shared/npc_budget.lua` 第 13–24 行 |
| 7 | 预算被闸门锁定：`number_budget.json` 的 `npc-budget-per-player = 2` 必须与文档同步（FIT-13），改数值要同时改文档 | `tests/architecture/number_budget.json` 第 7–13 行 |
| 8 | 交互层三件套已就绪：`custom-prompt`（E）、`custom-notify`（feed/toast/error/phone）、`custom-ui`（焦点栈） | CHANGELOG `[Unreleased]` 的 N-1a 与焦点栈条目 |

### 2.1 引擎表达力（Claude Code 只读盘点，逐条已复核）

| # | 要表达的机制 | 判定 | 现在的实现路径 | 最小新增 |
|---|---|---|---|---|
| 1 | NPC 乘客：上车 / 跟随 / 下车 / 等待计时 | **部分能** | 引擎无 NPC 原语；`interact` 只是 E 键进度条；全资源唯一 `CreatePed` 是战斗敌人（client/main.lua 第 582 行，`GiveWeaponToPed`） | 新 step 类型（如 `npc_ride`），或把外部 export 走 `script_trigger` 白名单 |
| 2 | 按里程 / 时长计价（服务端算） | **部分能** | 奖励 = 固定区间 × 损伤倍率 × 时效倍率（quest_rewards.lua 第 55–80 行），**里程不参与**；时长由服务端起算 | 奖励字段加 `per_km`，用已解析的起终点 + 耗时算 |
| 3 | 多站顺序推进，且**允许玩家自己排顺序** | **不能** | 状态机严格线性：`AdvanceStep` 取 `currentIndex + 1`（quest_manager.lua 第 789 行）；顺序校验只认当前步（quest_security.lua 第 198–247 行） | 改 DAG（步骤加 `next`/`require_steps`）≈ 重做引擎 → **本轮不做** |
| 4 | 失败与货损（超时 / 撞车 / 载具损毁） | **部分能** | 三者都是**客户端上报**，服务端照单 `FailQuest`（client/main.lua 第 848–874 行）；碰撞扣钱有服务端夹取 | 给模板加 `fail_conditions` + 服务端计时器裁决 |
| 5 | 同一单只结算一次 + 挡住「没完成却 CompleteStep」 | **部分能** | 幂等有：内存锁 + DB `status='in_progress'` 条件更新（quest_manager.lua 第 806–836 行）；但 `CompleteStep` 直接转 `AdvanceStep`（第 1070–1077 行），**只查 stepId 是否存在，不校验当前步、不跑 validator** | `AdvanceStep` 入口加顺序校验，`CompleteStep` 必跑 `validator_id` |

**最贵的是第 3 条**：线性 FSM 写死在 `AdvanceStep` 与 `ValidateStepOrder` 两处，改乱序要同时动状态机、安全层、
客户端节点下发与手机进度。**结论：本轮所有多站循环一律固定顺序**，不做「玩家自排路线」。

---

## 3. 外部调研（联网，2026-11-13）

| 来源 | 关键做法 | 对我们的意义 |
|---|---|---|
| [qb-garbagejob 官方文档](https://qbcore.org/docs/qbcore-resources/qb-garbagejob) | 租车 $250（还车退回）→ 5 站起、每站 2–5 袋、每袋 $50–100 | 这就是被玩家吐槽「重复脚本」的标准形状：**只有钱、没有进度**。我们的循环必须多一层（声望/解锁/难度档） |
| [qb-taxijob 官方文档](https://qbcore.org/docs/qbcore-resources/qb-taxijob) | 16 个上车点、23 个下车点、PolyZone 判定、`Config.Meter.defaultPrice = 1.60`（按里程计价） | 出租车的**数据结构可以直接照抄**：点位池 + 计价系数。我们的点位数应 ≥16/23，否则同一晚上会重复遇到同一单 |
| [Agency G：Taxi System 架构](https://agencyg.de/blog/fivem-taxi-system) | 计价 = 起步价 + 里程 + 等待费；表在角落常驻、司机与乘客都看得见；开单前给**预估车费**；混合派单（全服看板 + 高亮最近的） | 三条可直接采纳：①常驻表不是通知 ②预估车费降决策成本 ③派单板让"人少时也能接单"。与 jobs.md「进度不是通知」的结论一致 |
| [Quasar Taxi Job 文档](https://www.quasar-store.com/docs/taxi-job/usage) | 班次（shift）+ NPC 车费 + 准点奖金 + 计价表 | **班次**是比"随到随干"更好的骨架：一趟有开始/结束，天然给结算与限流一个边界 |
| [Cfx 论坛：服务端 CreatePed 的同步](https://forum.cfx.re/t/will-spawning-peds-on-the-server-side-automatically-sync-them-on-onesync/5243154) | 服务端 `CreatePed` 在 OneSync 下自动同步；客户端造 ped 必须 `isNetwork=true` | NPC 乘客/顾客可以**服务端生成**，不必走客户端广播；反过来说，服务端因此要管预算（见 §2 第 6 条） |
| [CyberNex：FiveM 经济平衡](https://cybernex.lk/knowledge-base/fivem-roleplay-server-economy) | 低技能（trucker/送货/钓鱼）**$500–1,000/h**；中技能（mechanic/taxi/tow）**$1,000–2,000/h**；高技能（警察/EMS/法官）$2,000–4,000/h；非法 $3,000–6,000/h 带风险 | 我上一版拍板里写的「民职统一 $500–900/h」**过窄**：它只对应低技能档。应改成分档（见 §5 假设 B） |
| [Tebex 经济设计指南](https://cfxmods-tebex.io/blog/fivem-economy-design-guide) | 货币符号是假的，真正的单位是**玩家时间**：先定「合法工作一小时产出多少」，再给所有东西定价 | 数值卡的正确顺序：先定每小时产能，再回推单价，而不是反过来 |

**外部结论三条**：

1. **标准形状 = 租车/接单 → 多点循环 → 结算**，所有同类都这样，差异只在「有没有进度层」；
2. **进度层（声望/等级/解锁）+ 班次边界 + 常驻计价表**，是这三家里唯一拉开差距的部分，也是我们要做的；
3. **数值必须分档**（低/中/高技能），并且以「每小时」为单位反推单价。

---

## 4. 假设与被排除的假设

| 假设 | 支持证据 | 结论 |
|---|---|---|
| A：7 条民职壳任务改改配置就能变成真玩法 | 配置里确实有 7 个任务 id | ❌ **已排除**：step 只有 `reach`/`interact`，NPC/计价/失败判定都要新增能力（§2.1 第 1/2/4 条） |
| B：民职统一目标带 $500–900/h 就够 | 我按「比时薪高、比犯罪低」推的 | ❌ **已排除（部分）**：外部基线把 trucker/送货归低技能（$500–1,000/h）、taxi/tow 归中技能（$1,000–2,000/h）；统一一条带会让 taxi 偏低、trucker 偏高 |
| C：可以复用 custom-police 的 NPCBudget 给乘客/顾客 | 仓库已有成熟的槽位预算实现 | ❌ **已排除**：kind 表只有 4 种、预算住在 custom-police，跨资源复用要改 owner 与 FIT-13 文档 |
| D：多站循环允许玩家自己排顺序 | 现实里快递员确实可以自排 | ❌ **已排除**：线性 FSM，改 DAG 接近重做引擎（§2.1 第 3 条） |
| E：可以完全靠现有 quest 引擎，不新增 step 类型 | `script_trigger` + `custom_event` 能外挂资源 | ✅ **成立但要付代价**：外挂 = 每个机制一个 export 白名单条目；NPC/计价这两条无论哪条路都要动引擎，只是改哪一层 |
| F：服务端生成 NPC 乘客会引发同步问题 | — | ❌ **已排除**：OneSync 下服务端 `CreatePed` 自动同步（§3 第 5 条）；真正的约束是预算与清理，不是同步 |

---

## 5. 影响面（按平面）

| 平面 | 会不会动 | 具体 |
|---|---|---|
| NUI（`custom-phone/web/src`） | 会（R5） | 手机「我的职业」页；本轮不动 web 构建 |
| Client Lua | 会 | 新 step 的客户端处理（乘客/顾客/计价表）——落在 `custom-quest` 的 client 侧，不新开资源 |
| Server Lua | 会 | 计价（奖励字段扩展）、失败判定（服务端计时器）、`CompleteStep` 顺序校验 |
| Shared / 配置 | 会 | 每职业一份配置；`qb-cityhall` 的岗位入口可能要指向新岗点 |
| DB / 迁移 / 登记表 | **不动**（本轮 0 新表） | 声望继续用 `players.metadata.rep`；若将来要存「已解锁」才走 L3 + `table_owners` |
| 闸门 | 会 | 新增 step 类型若带 net event，需登记 allowlist；`gate_coverage_budget` 的未证明数会增加，需按规则补反向用例 |

---

## 6. 结论

- [x] **继续**（进设计阶段）
- [ ] 不改

**三条判断在调研后被修正**：

1. 「民职统一 $500–900/h」→ 改为**按技能分三档**（低 $500–1,000 / 中 $1,000–2,000 / 高 $2,000–4,000）；
2. 「多站循环可以让玩家自排顺序」→ **放弃**，一律固定顺序；
3. 「NPC 顾客可以复用警察的 NPC 预算」→ **放弃**，需要独立的顾客预算（新决策，见下）。

**进入设计阶段前需要拍板的两个新问题**（调研阶段新发现的，不在原五项之内）：

| # | 问题 | 选项（推荐在前） | 为什么必须现在定 |
|---|---|---|---|
| 6 | 顾客/乘客的 NPC 预算放哪 | ①新建**独立**的顾客预算（与 police 的 6 槽分开，上限按在线人数算） ②给现有 NPCBudget 加 kind 并改成共享 ③不做全局预算，只限「每玩家 1 个乘客」 | 决定 R2 是「一个新文件」还是「改警察的共享层 + FIT-13 文档」 |
| 7 | 计价能力加在哪 | ①奖励字段扩 `per_km`（改 `quest_rewards`，所有任务可复用） ②新 step 类型自带计价（只服务职业） ③外部 handler 资源算完再调 `AddRep`/`TriggerReward` | 决定后面 8 个职业的计价是「一处配置」还是「每职业一份代码」 |
