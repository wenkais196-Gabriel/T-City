---
id: jobs-content-02-design
type: spec
status: draft
system: jobs
owner: hermes
updated: 2026-11-13
review_by: 2027-02-28
stage: D
---

# 设计：职业内容填充（阶段 D）

> 两份独立设计（Hermes 主写 + Claude Code 只读）合并后的结果。调研见 [01-research.md](./01-research.md)。
> 设计只回答**目标状态长什么样**；任务拆分与验收步骤在阶段 P / V。

---

## 0. 两轮设计的分歧与采信

| 分歧点 | Hermes | Claude Code | 采信 + 依据 |
|---|---|---|---|
| 数值锚点 | 以**本服车价**为主：median $48,000，目标「一辆中位车 ≈ 10–20 小时合法劳动」 | 以**外部基线**为主：低技能 $700/h（外部 $500–1,000） | **Hermes**。理由是仓库内的既成事实：现有 7 条民职壳任务每次结算 $150–800、单次 2–6 分钟 ⇒ **$2k–8k/h**。若新循环只给 $700/h，玩家会继续刷旧壳——新内容反而比旧壳差。外部基线是"从零建服"的建议，不适用于已有 $4k/h 存量内容的服 |
| 计价方式 | 站数 × 单站价 + 里程系数 | 站数 × 单站价（不带里程） | **CC**。调研已确认引擎不支持里程计价（`quest_rewards` 只吃固定区间 × 倍率），加 `per_km` 是新增能力，而站数计价已经能表达全部三个职业；里程系数留到有职业真的需要时再加 |
| 服务端如何证明"真跑完了" | 新增 `fail_conditions` + 服务端计时器 | 在 `AdvanceStep` 入口执行 step 的 `validator_id`（复用现有 validator 表），0 新事件 | **CC**。`RegisterStepValidator` 是官方扩展点，validator 表已存在，比新增一套 fail_conditions 便宜且有现成先例 |
| NPC 顾客预算 | 新建独立预算（共享常量表） | 放 custom-quest 内存，1 槽/玩家，不复用 police 的 | **两者合并**：实现放 custom-quest 内存（CC），但常量与语义抽成可测的纯函数文件（Hermes），并**明确不复用** police 的 `NPCBudget`（`MAX_GLOBAL=6` 太小、kind 不含乘客、且被 FIT-13 文档锁定） |
| 时薪怎么压 | 直接调 qb-core 的 shared/jobs.lua 里的 grades | 不改 jobs.lua，在 `PaycheckInterval` 读值处加覆盖钩子 | **CC**。roadmap §8 明令不许改职级结构（上游 diff 会被吞）；钩子 + pcall 回退是唯一不碰上游的路 |

---

## 1. 机制与数据

三种机制全部落在 `custom-quest` 的既有 step 类型上，**固定顺序**（线性状态机不可改，调研 §2.1-3）。

| 机制 | step 组合 | 关键字段 | 结算由谁算 |
|---|---|---|---|
| **route** 多站路线 | 每站一个 `validator`（`validate_route_stop`）+ 装卸用 `interact` | `session={deposit, stops, time_limit}`；`economy={per_stop, tier_mult, damage_cap}`；`validator_data={index, index_total, job, require_vehicle}` | 服务端：末站 validator 通过后按站数算 |
| **station** 站点服务 | `interact`（服务）+ `validator`（计价/冷却） | `station={npc_kind, patience, minigame, price}` | 服务端：`validate_station_service` 复核在场 + 扣料 + 冷却 |
| **produce** 产出加工 | `interact`（投料）+ `validator`（配方）+ `deliver`（出售） | `recipe={inputs, outputs, fail_rate}` | 服务端：`HasItem/RemoveItem/AddItem` 原子校验（先例：custom-mining 的冶炼） |

配置示例（route，trucker 低阶，可直接落地）：

```lua
{ id = 'trucker_city', title = '城区配送', category = 'civilian', level = 1,
  required_tags = { role = 'civilian' },
  conditions = { cooldown_hours = 0, min_police = 0, daily_limit = 6 },
  session = { deposit = 125, stops = 6, time_limit = 900 },          -- 15 分钟
  economy = { per_stop = 70, tier_mult = 0.9, damage_cap = 0.5 },
  rewards = { rep = { delivery = 10 } },
  steps = {
    { id = 's1', type = 'validator', data = { coords = { x = 26.45, y = -1315.51, z = 29.62 },
        radius = 10.0, validator_id = 'validate_route_stop',
        validator_data = { index = 1, index_total = 6, job = 'trucker', require_vehicle = true } } },
    -- s2..s6 同形，index 递增；s6 追加 finish = true
  } }
```

### 1.1 本轮必须新增的最小能力（4 项，全部在 custom-quest 内，0 新 net event）

| # | 能力 | 改哪 | 为什么必须 |
|---|---|---|---|
| C1 | `AdvanceStep` 入口执行 step 的 `validator_id` | quest_manager 的推进函数 | 现在 `CompleteStep` 只查 stepId 存在，客户端一句"我完成了"就能推进（调研 §2.1-5） |
| C2 | **顺序校验**：stepId 必须等于当前步 | 同上 | 堵住"跳过中间站"，也是 C1 的前置（乱序时不该跑 validator） |
| C3 | 服务端会话：`citizenid:questId → {stops, started_at, paid}` | custom-quest 内存 + 快照进 `progress_data` | 计价与幂等都依赖它；不建表 |
| C4 | 顾客/乘客预算（纯函数 + 内存表） | 新文件，1 槽/玩家、TTL 5 分钟 | NPC 只能服务端生成，没有预算就会泄漏与刷屏 |

> C2 是 C1 的前置；C1+C2 一起做才有意义，所以它们是第一个开发切片。

---

## 2. 数值

### 2.1 两个锚点（都是仓库内实测）

| 锚点 | 实测 | 含义 |
|---|---|---|
| A 存量内容收益率 | 7 条民职壳 $150–800/次，单次 2–6 分钟 ⇒ **$2k–8k/h** | 新循环必须**不低于**这个区间下缘，否则玩家继续刷旧壳 |
| B 资产价格 | `T-CityLite.base/resources/[qb]/qb-core/shared/vehicles.lua` 730 台车：p25 $25,000、**median $48,000**、p75 $100,000 | 「一辆中位车 ≈ 多少小时」是玩家真正感受到的刻度 |

### 2.2 分档（取代上一版"统一 $500–900/h"）

| 档 | 职业 | 目标 $/h | 中位车所需工时 | 依据 |
|---|---|---|---|---|
| 低技能 | trucker、garbage、bus、recycle、reporter | 1,400–2,800（含 tier 倍率） | 17–34 h | 略低于存量壳的上缘，靠"可重复 + 有声望"补足 |
| 中技能 | taxi、tow、hotdog、vineyard | 3,000–4,500 | 11–16 h | 需要技能判定或承担货损风险 |
| 高风险 | 犯罪（drugs/heists） | 8,000–15,000（**未取证**，本轮不动） | 3–6 h | 保持 3–5 倍合法溢价 |
| 底薪 | 全部在岗职业 | 150–300（时薪） | — | 只做"活着"的地板，不超过干活的 15% |

### 2.3 三个职业的结算公式（R0/R1）

| 职业 | 公式 | 低/中/高阶（站·分钟·趟收益） | 折算 $/h |
|---|---|---|---|
| trucker | `站数 × per_stop × tier × time × damage`，per_stop = 70 | 6·15·$378 / 12·25·$840 / 20·35·$1,400 | 1,510 / 2,016 / 2,400 |
| garbage | `站数 × 30 + 袋数 × 25`，再乘 `time × damage` | 4·16·$370 / 6·24·$705 / 8·32·$1,140 | 1,388 / 1,763 / 2,138 |
| bus | `站数 × 90 × punctuality`，punctuality ∈ [0.8, 1.1] | 6·18·$486 / 8·24·$648 / 10·30·$810 | 1,620 / 1,620 / 1,620 |

`time` 复用现有倍率（早到 +10%、晚到 -10%/档、封顶 -50%）；`damage` = `1 - min(损伤, cap)`。

> **附带的既有奖励要一起算**：`deliveryPay` 过去每站还有 10% 概率掉 `cryptostick`，而 qb-crypto 里
> 一根按 `Worth = 1000` 兑换 ⇒ 20 站/趟期望 2 根 = $2,000，比现金结算（$1,400）还多，实际收益约 $6k/h。
> 这是 Claude Code 验收时抓出来的，处理方式：改成配置 `DeliveryCryptostickChance = 0`（保留彩蛋但默认关）。

### 2.4 时薪（paycheck）

- 不改 qb-core 的 shared/jobs.lua；在 `PaycheckInterval` 读 payment 的地方加一个覆盖钩子（pcall + 失败回退原值）。
- 覆盖表放 `custom-career`；民职 25/30/35/40/45（每 10 分钟 = $150–270/h），职权型保持 50–100。
- **门控**：过去 10 分钟内有过一次干活结算则照发；一次都没有则不发（堵住"挂名领工资"）。

---

## 3. 机制卡（R0/R1 三个职业）

| 项 | trucker | garbage | bus |
|---|---|---|---|
| 入口 | GO Postal 岗点 `[E]`；cityhall 可申请 | cityhall + 垃圾场岗点 `[E]` | cityhall + 车场岗点 `[E]` |
| 站点/难度 | 交付点池（现有 45 处）抽 6/12/20 站；15/25/35 分钟；tier 0.9/1.0/1.15 | 10 个垃圾点抽 4/6/8；袋 10/21/36；16/24/32 分钟 | 站点池 6/8/10 站；18/24/30 分钟 |
| 结算 | 见 §2.3；押金 $125 | 见 §2.3；押金 $250 | 见 §2.3；押金 $100 |
| 声望 | 每站 +1、完成 +10 `delivery` | 每袋 +1、完成 +5 `garbage` | 每趟 +25 `bus` |
| 失败/货损 | 超时 → 押金没收、无结算；损伤 > 50% 按比例扣 | 毁车时未卸袋不计；损伤 > 30% 扣 | 准点率 < 50% 只发一半、无 rep |
| 限流/审计 | 20 站/趟；30 秒/店（已有）；日 6 趟；结算走审计 | 日 8 趟；每站 ≥30 秒 | 日 8 趟；每站 ≥30 秒 |
| UI | `[E]` 接单；HUD 常驻「站 3/6 · 剩余 12:40」；完成 toast；失败 error；回执进手机 | HUD「袋 7/21」；其余同上 | HUD「下一站：商业区 · 准点 +2」；其余同上 |
| 验收剧本 | 正：在岗 + 押金 + 6 站按序 → $378 + rep。反：①非 trucker 触发结算 → 拒 + 审计 ②末站 20m 外提交 → 拒 ③重复末站/超 20 站 → 拒 | 正：在岗 + 4 站 10 袋 → $370 + rep。反：①非 garbage → 拒 ②跳站/乱序 → 拒 ③重复倾倒 → 拒 | 正：在岗 + 6 站准点 → $486 + rep。反：①非 bus → 拒 ②跳站 → 拒 ③重复末站 → 拒 |

---

## 4. 决策记录（阶段 R 遗留的问题 6/7 + 新发现）

| # | 问题 | 决定 | 理由 |
|---|---|---|---|
| 6 | NPC 顾客预算放哪 | **custom-quest 内独立预算**：1 槽/玩家、TTL 5 分钟、全局上限 = 在线人数（上限 8）；常量与判断写成纯函数文件 | 不改 police 的 `NPCBudget`（FIT-13 锁定 + kind 不含乘客），也不新建资源 |
| 7 | 计价能力加在哪 | **不加 `per_km`**，只加「站数/袋数计价」，落在 quest 的结算层 | 三个职业都不需要里程；加能力要有消费者，否则又是一次无验收的抽象 |
| 8 | 时薪怎么压 | **覆盖钩子**（pcall + 回退），不改 jobs.lua | 上游 diff 会被吞 |
| 9 | 乱序多站 | **永久不做** | 线性 FSM，改 DAG ≈ 重做引擎 |

---

## 5. 风险与回滚

| 风险 | 概率 | 影响 | 缓解 / 回滚 |
|---|---|---|---|
| 在 `AdvanceStep` 强制跑 validator，把现有物流任务卡死 | 中 | 高（玩家卡任务） | 只对**声明了** `validator_id` 的 step 生效；灰度一个任务；出问题删一行判断即回滚 |
| paycheck 钩子 nil/导出失败把全服工资打成 0 | 中 | 高 | pcall + 失败回退原 payment；先单职业灰度（trucker），观察一个发薪周期 |
| 数值定得太高，一晚上车随便买 | 中 | 中 | §2.3 的公式全部走配置；改 `per_stop` 一行即可回滚，不需改码 |
| NPC 预算泄漏（下线不释放） | 中 | 中 | TTL 5 分钟 + 玩家离线清账；预算占用有可查的 `/work budget` 诊断命令 |
| 与 qb-shops 的送货循环重复结算 | 低 | 高 | trucker 的路线走 quest，qb-shops 的 `RestockShopItems` 已在 R0.1 加了会话上限；两者互斥（同一趟只能有一个来源） |

---

## 6. 阶段 V 的输入（验收要证明什么）

1. **服务端是真权威**：伪造"我完成了"（跳过站、远距提交、重复末站）三种形状全部被拒，且拒绝留审计；
2. **单次结算只发一条**：qbt 结算回执不重复、不叠加；
3. **人看得到进度**：HUD 常驻（不是逐次通知），完成才 toast；
4. **收益落在带内**：跑完一趟实测 $/h 与 §2.3 的预期差 ≤ 15%；
5. **回滚可行**：把 `per_stop` 改回旧值、把 validator 判断去掉，功能退化但不崩。
