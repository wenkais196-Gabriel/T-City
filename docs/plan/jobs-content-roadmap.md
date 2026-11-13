---
id: jobs-content-roadmap
type: plan
status: draft
system: jobs
owner: hermes
updated: 2026-11-13
review_by: 2027-02-28
topic: content-fill
source_of_truth: false
---

# 内容填充总规划（职业优先，R0–R6）

> **一句话**：机制层（交互 / 通知 / HUD / 焦点 / 经济回执）已经收口，本轮起只做**内容**——
> 把 22 个只有名字的职业，变成「每个职业要么有一条能重复玩的循环，要么有一套只有它能做的事」。
> 硬约束：**0 个新资源、0 张新表、0 个新 net event**（新增任何一项都要按 `tests/architecture` 的闸门重新计价）。

---

## 0. 两轮独立判断（本文 + Claude Code 只读复盘）

| 争议点 | 我的初稿 | CC 复盘 + 我的核实 | 采信 |
|---|---|---|---|
| 要不要新建引擎资源 | 新建 `custom-works` 装引擎 + 三机制 | **不要**。`custom-quest` 已经是引擎：12 个 export（`TriggerQuest` / `OnCustomEvent` / `CompleteStep` / `RegisterStepValidator` / `FailQuest` / `GetActiveQuests` …），step 类型已有 `reach` / `interact` / `deliver` / `custom_event` / `validator` / `script_trigger` / `goto` / `reward`，`RegisterStepValidator` 就是官方给的扩展点 | **CC** |
| 新资源的闸门成本 | 随资源数线性增长 | **不成立**。FIT-03 只扫 4 个资源、跨资源写只扫 10 个资源簇 —— 新资源反而**逃出扫描**，风险是覆盖归零，不是成本上升 | **CC** |
| 首批做谁 | taxi（竖切最完整） | **trucker 先做**。它的循环已经在跑（qb-shops 的送货），但服务端没有 job 校验，且结算是全仓最宽的钱口 | **CC** |
| 声望第一个消费者 | 执照（certificates 的 vehicleClasses） | **mining 的金/银矿准入**更便宜：mining rep 已经在写（50/单、500/链）却没人读；改动只是把 `mineral.minGrade` 的比较对象从 job grade 换成 `max(jobGrade, repLevel)`；执照留作第二个消费者 | **CC** |

> 下面标 ✅ 的数字都是我自己 `rg` / `sed` / `python` 跑出来的，不是转述。

---

## 1. 实测基线（2026-11-13）

| 项 | 实测值 | 怎么测的 |
|---|---|---|
| 职业定义 | **22 个**（unemployed + 21），全是「五级职级 + 时薪」模板，无玩法字段 | ✅ `resources/[qb]/qb-core/shared/jobs.lua` |
| 有真实循环的职业 | **4 个**：police、ambulance、mechanic×3、miner；另加 qb-shops 的送货（无 job 校验，见 §7） | ✅ 各资源 config + server |
| 市政厅可申请 | **7 个**：trucker / taxi / tow / reporter / garbage / bus / hotdog | ✅ `resources/[qb]/qb-cityhall/config.lua` |
| 其中「只有名字」 | **6 个**（只有 hotdog 在 quest 里有一个壳） | ✅ 全仓 grep 只命中 career/storage 配置 |
| 民职 quest 壳 | **7 条**：taxi_fare / bus_route / tow_service / garbage_collection / hotdog_vendor / news_report / recycle_run | ✅ `T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_public_services.lua` 与同目录的 quest_civilian_misc.lua |
| 这些壳的 step | 只有 `reach` 与 `interact`（到点 + 按住）——**没有乘客、没有计价、没有 NPC 顾客、没有货损** | ✅ 同上 |
| 声望写入口 | **5 处**：quest 奖励、core_economy、qb-drugs×2、qb-shops | ✅ `rg "AddRep\("` |
| 声望读出口 | **1 处**：qb-drugs 的 dealer minrep | ✅ `rg "GetRep\("` |
| 等级 / 晋升门槛字段 | **0**（custom-career 只有组织 + 职级 + certs） | ✅ `docs/client/ux/modules/jobs.md` §5 缺口 3 |
| 可复用件 | quest 状态机 15.6k 行 / 28 份任务配置、mining 762 行配置驱动采集、market 22 个商品、storage 19 个组织仓、certificates 5 类执照、qb-minigames 8 个小游戏（已 ensure）、progressbar（已在 player.cfg） | ✅ 逐个读过 config |
| 闸门 | net event 364 条、**unguarded 0**；db_call_sites 预算 463（只许下调）；表必须有唯一 owner | ✅ `tests/architecture/*.json` |

---

## 2. 判断一：职业是两种东西，不能用同一套做法

| 类型 | 定义 | 职业 | 该做什么 | 不该做什么 |
|---|---|---|---|---|
| **循环型**（10） | 玩家投入时间换钱，可 solo | taxi、bus、trucker、tow、garbage、hotdog、reporter、vineyard、miner、mechanic | 一条能重复玩的循环 + 难度档 + 声望 | 不要发「挂名工资」 |
| **职权型**（8） | 为**其他玩家**提供服务，收入来自制度 | police、ambulance、judge、lawyer、mayor、realestate、cardealer（+ mechanic 改装线） | 工具（案件 / 合同 / 判决 / 过户）+ 抽佣 + 权限 | 不要编「刷钱循环」——一刷就通胀 |

> 上一轮把 6 个空壳 cityhall 职业做成了 quest 的 `reach` 链，本质是「走过去 + 按住」，玩家 3 分钟就能发现里面什么都没有。
> 这是本轮要还的债，不是要继续扩的模式。

---

## 3. 判断二：内容是「三个机制 × N 份数据」，引擎已经在仓库里

| 机制 | 骨架 | 覆盖职业 | 复用件 | 新增量 |
|---|---|---|---|---|
| **route 多站路线** | 接单 → 按序到点 → 条件满足 → 结算 | trucker、garbage、bus、taxi、tow、recycle | quest 的 `reach` + 物流校验器（车辆/到达/货损）+ 现有 `quest_logistics` 1401 行配置 | 会话/计价 + 1 个 validator |
| **station 站点服务** | 定点交互链 + NPC 顾客 + 小游戏 + 计价 | hotdog、reporter、vineyard（榨汁段） | qb-minigames 的 skillbar / keyminigame / wordguess、progressbar、quest 客户端已有的 `CreatePed` | 顾客生成（走 NPCBudget）+ 定价 |
| **produce 产出加工** | 投入 → 配方 → 产出 → 市场/店铺 | vineyard（酿造）、mechanic（改装件）、miner 二期 | mining 的 `SmeltRecipes` + market 的 OrderBook | 配方与商品条目 |

**落在哪**：新机制写成 `custom-quest` 的 step handler（`client/quest_<mechanic>.lua` + 服务端 validator），
接单 / 状态 / 冷却 / 日限 / 结算 / 声望继续由 `custom-quest` 单一持有。**只有**当某个机制需要独立 NUI 页面
或独立事件命名空间时，才为它单开资源（目前只有「出租车计价器」有这点嫌疑，用 HUD 常驻即可避免）。

理由：`player_quests` 的 owner 是 `custom-quest`（`table_owners` 已登记），手机任务 App 只读它；
另写一套引擎 = 第二份实现 + 跨表写（宪法第 6 条），且新任务在手机里根本看不见。

---

## 4. 判断三：声望的入口已经够用，缺的是「消费者」

- 写：`Player.Functions.AddRep` 有 5 个调用点，quest 的 `rewards.rep` 早已在给 `mining = 50` 这种职业声望；
- 读：全仓只有 qb-drugs 的 dealer minrep。**没有等级、没有解锁、没有 UI**；
- 结论：**本轮不新建表**。R5 做三件事（成本从小到大）：
  1. **mining 金/银矿准入**：把 `custom-mining` 里 `grade >= ore.minGrade` 改成 `max(jobGrade, repLevel)` 的等价判断，让「干活 → 声望 → 能挖更好的矿」第一次成立；
  2. **rep→等级只读面板**：补 `docs/client/ux/modules/jobs.md` 的 J-6 缺口，显示「还差 X 点 / 还差 Y 次」；
  3. **执照 gating**：`custom-certificates` 已有 `vehicleClasses`，让 trucker / bus 的高阶单要 heavy 执照（第二个消费者，验证「执照 → 岗位」链）。
- 新表留到出现第二个需要「已领取状态」的消费者再谈（L3，需过 `table_owners` 闸门）。

---

## 5. 分批（R0–R6）

工时按「代码 + 测试 + 真机验收 + 文档」全包计。

| 批次 | 内容 | 交付物 | 验收门（可判定） | 工时 |
|---|---|---|---|---|
| **R0 堵漏 + trucker 收编** | ①给 qb-shops 的 `RestockShopItems` 加 job 校验（现在任何职业站在交货点，每 30 秒就能拿 $500）；②把送货循环接进 trucker 职业（job 变更、结算审计、rep）；③~~`quest_logistics` 去重~~ **已撤回**：2026-11-13 实测 31 份配置 / 183 个 step、12 个运输任务 id 全部唯一，没有重复（只有跨任务的同名 step id，属正常命名空间） | 1 处鉴权 + 1 份 validator + 结算统一 | 非 trucker 触发 → 拒绝且记审计；trucker 触发 → 只有 1 条结算回执；同一单重复提交 → 第二次拒绝 | 14h |
| **R1 多站驾驶（无 NPC）** | garbage（袋数/站点谱）、bus（站点谱 + 准点率） | 2 份 config + route validator | 各跑通一次；每职业 ≥3 点位 ≥2 难度档；中途放弃只扣押金不吞钱 | 22h |
| **R2 第一个 NPC** | taxi（乘客 NPC、计价、小费、取消惩罚）→ tow（玩家车归属，最贵放末位） | 1 份 config + NPC 生成 + 车程 HUD | taxi 三条反例全过（无乘客提交 / 远距提交 / 重复结算）；tow 拖走别人车必须拒绝 | 30h |
| **R3 站点服务** | reporter（拍照取证 → 交稿）、hotdog（NPC 顾客 + 定价 + 库存）、recycle（要补 plastic 商品进 market） | 3 份 config + station 机制 | 每个 ≥3 点位；hotdog 的顾客走 NPCBudget 且不超每玩家 2 个槽 | 26h |
| **R4 produce** | vineyard（种 → 收 → 酿 → 卖）、mechanic 二期（改装件订单，与 qb-mechanicjob 的喷漆/轮毂分工） | 配方 + 商品入库 + 分工说明 | 一条配方链跑通；产出进 market 后价格随供需波动，不是固定卖价 | 24h |
| **R5 声望与执照** | §4 的三件事 | 1 处比较 + 1 个面板 + 1 处 gating | 面板显示「差 X 点」；无 heavy 执照接不了 trucker 高阶单（错误码可判） | 16h |
| **R6 收口** | 数值卡复核、全量回归、CHANGELOG、交付三件套 | 数值表 + 验收报告 | `pytest tests/unit tests/architecture` 全绿；真机清单逐条打勾 | 10h |

**顺序理由**（每条都可验证，不是偏好）：

1. **R0 必须最先**：qb-shops 的补货结算是全仓唯一「无 job 校验 + 无次数上限 + 单次 $500」的钱口
   （`RestockShopItems`：30 秒冷却按「玩家×店」计，配置里 45 处 delivery，理论 $60k/h/店）。
   这既是安全修复，又正好是 trucker 的循环本体 —— 一次改动两件事。
2. **R1 在 R2 之前**：garbage / bus 与 taxi 同属多站驾驶，但**不需要乘客**。quest 目前只有客户端 `CreatePed`，
   NPC 乘客是新东西，先让引擎在没有 NPC 的情况下跑稳。
3. **tow 放 R2 末位**：`custom-police` 的 `/tow` 只拖 NPC 残骸、明确拒绝玩家车；民职拖车必须处理
   `player_vehicles` 归属，是这一批里唯一有「动别人资产」风险的动作。
4. **hotdog 后移**：`items.lua` 里没有 hotdog 物品（只有 sandwich），要先动 shared items + custom-consumables。
5. **realestate 移出本轮**：`qb-houses` 不在启动链里（`resource_wiring_allowlist.json` 登记为 `deferred_repo_resource`），
   做房产中介等于先做房产。这一项单列成决策（§11 问题 5）。
6. **职权型其余 4 个（lawyer / judge / mayor / cardealer）不进本轮**：各自的底座已交付
   （justice / vehicleshop / management），缺的是「案件量与合同」，属于各自模块的内容，不该塞进职业批次。

---

## 6. 「内容规格卡」——这是「填充」的验收单位

每个职业交一张卡，八项缺一项不算完成。

| # | 项 | 判据 |
|---|---|---|
| 1 | **入口** | 在哪申请（cityhall / 手机 / 现场岗点），谁可见 |
| 2 | **机制参数** | 站点数、单站时长、难度档、失败条件 |
| 3 | **结算公式** | 基础价 + 距离/难度系数 + 小费/罚金，**服务端算**，客户端只上报「我完成了」 |
| 4 | **声望产出** | 每次结算 +N rep，走 `AddRep`（不新开通道） |
| 5 | **失败与货损** | 超时 / 死亡 / 车辆损毁 / 中途放弃，各扣多少、是否退押金 |
| 6 | **限流与审计** | 冷却、每日上限、单会话上限；结算写审计（走 core_economy） |
| 7 | **UI 触点** | `[E]` 入口、常驻进度（不刷通知）、完成 toast、失败 error（四通道规则） |
| 8 | **验收剧本** | 一条正例 + 三条反例（刷单 / 远距提交 / 重复结算） |

**样例（taxi，R2 交付时填满）**：

| 项 | 值 |
|---|---|
| 入口 | 出租车公司岗点 `[E]` 接单；同时进手机 JobBoard 列表 |
| 机制 | 1 单 1 乘客；上车点 3 选 1，目的地在地址池里抽；乘客有耐心（上车 30s） |
| 结算 | `$60 基础 + $4/100m 里程 + 小费(0–20%，按是否超时/碰撞数)`，服务端按起终点算，不信客户端 |
| 声望 | 每单 +3 `taxi` rep（与 mining 的 50/单口径在 R6 数值卡里统一） |
| 失败 | 乘客等待超时 -$30 违约金；车辆损毁 / 玩家死亡无结算 |
| 限流 | 单会话 ≤5 单；每日 ≤40 单；同一乘客 id 不复用 |
| UI | 上车 `[E]`；车程中 HUD 常驻显示里程与预估小费；送达 toast 一条 |
| 反例 | ① 无乘客提交 → 拒绝 ② 距离校验 5m 外提交 → 拒绝 ③ 同一单结算两次 → 第二次拒绝并记审计 |

---

## 7. 数值与通胀（含一条已发现的漏洞）

| 现有收入源 | 速率 | 问题 |
|---|---|---|
| 时薪（paycheck） | 每 10 分钟按职级 $20–200 | `PayCheckSociety = false`：**钱是无中生有的**，不从公司账出 |
| quest 结算 | 单次 $150–600 | 与时长无关，可被刷（靠 `daily_limit` 兜） |
| 挖矿 | 单次 1–2 块、5s 冷却、矿石 $3–45 | 理论上限 ~$7k/h，实际被背包重量与会话上限压住；**没有基线数字** |
| **qb-shops 送货** | **每店每 30 秒 $500，无 job 校验** | **R0 修**：全仓最宽的钱口 |

**提议（待你确认）**：
1. 每批附一张**数值卡**（每职业：单次收益、每小时上限、每日上限、与现有源的比例），进 `docs/`；
2. 循环型目标带**按技能分档**（低 1,400–2,800 / 中 3,000–4,500 $/h），时薪只做地板（$150–300/h）——
   分档依据与逐职业公式见阶段 D 的 [02-design.md](./jobs-content/02-design.md) §2；
3. 职权型**不新增刷钱口**，收入来自抽佣（固定比例，走审计）。

---

## 8. 边界：每批不许碰什么

| 不许 | 原因 |
|---|---|
| 改 qb-core 的职级结构 | 上游 diff 会吞掉，后续无法合并 |
| 新增 net event（超出的必须登记 allowlist 并给投影/限流） | unguarded 已是 0，新增就要重新过闸门 |
| 新增表 | 先复用 `metadata.rep`；真需要时走 L3 + `table_owners` |
| 直接 SQL 结算 | 宪法第 2 条：钱只走 `Player.Functions.*` / `core_economy:TriggerReward` |
| 在客户端算钱 | 宪法第 1 条：客户端只上报「我完成了」 |
| 用 DrawText / 各自弹窗 | 交互层已统一到 custom-prompt / custom-notify |

---

## 9. 验收三态（交付时用这张表，不用勾）

| 态 | 意思 | 必须带 |
|---|---|---|
| ✅ 已证明 | 有可执行证据 | 节点（文件::测试）+ 命令 |
| ⚪ 结构上已成立 | 被测对象已删 / 不变量由更粗断言兜住 | 删了什么 + 旧红绿从哪个 commit 复现 |
| ⛔ 未验证 | 只能真机 / 真人观察 | 做到哪一步 + 缺什么 |

**注意**：「0 SCRIPT ERROR」不是验收，只是没崩。

---

## 10. 分工

| 角色 | 负责 |
|---|---|
| Hermes（主） | Lua 侧、鉴权与闸门、真机验证、数值卡、文档与 CHANGELOG、PR |
| Claude Code | 单点可离线判定的子任务：step handler 单测、反例用例、配置 schema 校验、只读复盘（固定文件清单 + 行数预算） |
| 你 | 玩法取向拍板（§11）、真机试玩、数值手感 |

---

## 11. 待你拍板的 5 个问题

| # | 问题 | 选项（推荐在前） | 影响 |
|---|---|---|---|
| 1 | 首批范围 | ①R0+R1（堵漏 + trucker + garbage + bus 一条线打通） ②R0 只堵漏 + trucker ③每类各一个（trucker + reporter + vineyard） | 6–8 周内能否看到「一整个模块像样」 |
| 2 | 收入模型 | ①干活为主、时薪下沉 ②双轨保留 ③取消时薪只靠干活 | 是否通胀 |
| 3 | 顾客 / NPC 从哪来 | ①NPC 顾客（solo 可玩，占 NPCBudget） ②玩家下单（真实需求，人少时没人下单） ③先 NPC，人多了再开玩家下单 | R2/R3 的全部设计 |
| 4 | 职权型这轮做不做 | ①不做（只做循环型） ②只做 cardealer ③全做 5 个 | 是否多花 30h |
| 5 | realestate / qb-houses | ①本轮不碰（qb-houses 仍 deferred） ②先启 qb-houses 再做中介 ③改用 apartment 做中介标的 | 是否引入一个 deferred 资源 |

### 11.1 已拍板（2026-11-13）

| # | 决定 | 对计划的影响 |
|---|---|---|
| 1 | **首批 = R0 + R1**（堵漏 + trucker + garbage + bus，一条线打通） | R0/R1 合并为一个交付单元；R1 的两份 config 必须复用 R0 定下的 validator 形状，不许各写一套 |
| 2 | **干活为主、时薪下沉**（目标：按技能分档，见 02-design §2；时薪 $150–300/h 只做地板） | R0 就要给出 trucker 的数值卡；§7 的三条提议转为强制执行；R6 复核全部 10 个循环型 |
| 3 | **先 NPC 顾客，人多了再开玩家下单** | R2/R3 只做 NPC 一侧，但会话数据要留 `customer_type` 字段，后面加玩家下单不改表 |
| 4 | **职权型不做**（本轮只做循环型 10 个） | R4 只保留 vineyard + mechanic 二期这两个循环型项；5 个职权型职业退回各自模块的 backlog |
| 5 | **realestate 不碰，qb-houses 保持 deferred** | 从 §12 的依赖表里划掉「房产」，不占用本轮工时 |

> 由 4 与 5 推出的范围收敛：本轮 = **循环型 10 个里的 8 个**（trucker、garbage、bus、taxi、tow、reporter、hotdog、recycle）
> + **2 个产出链路**（vineyard、mechanic 二期）+ 声望/执照。miner 已有循环，只接声望消费者（R5）。

---

## 12. 全局：其余 10 个模块的内容缺口（只给轮廓，职业收口后再展开）

| 模块 | 内容缺口（一句话） | 依赖职业批次 |
|---|---|---|
| 经济与交易 | 22 个市场商品之外没有「本地产业」；商店库存是固定表，不随生产波动 | 是（R4） |
| 犯罪与组织 | 三条线（店铺/毒品/军火）只有前两条；洗钱链路是死配置 | 否 |
| 警务 | 案件/取证/验尸已交付，缺「常态化案件量」 | 否 |
| 医疗 | 死亡→复活闭环有了，缺「慢性病/伤病」长期线 | 否 |
| 载具 | 车店/车库/中控已交付，缺「改装件经济」 | 是（R4） |
| 手机 | 16 个 App，缺「职业」页与「我的生意」页 | 是（R5） |
| 剧情 | 三条主线已写，缺平民支线的「日常」层 | 是 |
| 身份与出生 | 已交付，缺多角色共享资产 | 否 |
| HUD 与状态 | 已交付，缺职业专属 HUD（taxi 计价、trucker 货损） | 是（R2） |
| 管理与审计 | 已交付，缺「职业数据面板」（哪个职业没人玩） | 是（R6） |

---

## 13. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-11-13 | 初版：实测基线 + 两轮判断对照 + R0–R6 分批 + 内容规格卡 + 5 个待拍板问题 |
| 2026-11-13 | §11.1：五个问题全部拍板（首批 R0+R1 / 干活为主 / 先 NPC / 职权型不做 / realestate 不碰），范围收敛为循环型 8 个 + 2 条产出链 |
