---
id: jobs-content-08-mature-scripts-survey
type: research
status: active
system: quest
owner: hermes
updated: 2026-11-14
review_by: 2027-02-28
---

# 成熟职业脚本调研：官方 9 个 job 的玩法循环拆解

> 目的：在做「任务节点模板」之前，先把生态里**已经在跑**的职业脚本摸清。
> 上一轮只看了 qb-hotdogjob 一个，这次把 qbcore-framework 官方在售的 9 个 job 全过一遍，
> 提炼可复用的循环模式，反哺我们的 `custom-quest` 节点设计。
> 社区脚本（Quasar / Renewed / jim / wasabi 等）由 CC 并行调研，见 §6。

---

## 1. 结论先行

1. **官方 job 全部是「押金 → 干活 → 回到固定点结算→ 退押金」**。9 个里有 5 个设押金
   （hotdog 250、garbage 250、tow 250、trucker 125），退还都在**物理结算点**发生，不是凭空转账。
2. **任务参数一律服务端生成**：站数、每站袋数、每袋价值、拖车距离价、乘客上车点 ——
   客户端只负责运，服务端负责发牌。这是它们没有被刷爆的根本原因。
3. **计价不是「一个价」，而是「基础值 × 条件倍率 − 税」**：tow 是 `(150–170 × 件数 + 车况 bonus) − 税`；
   trucker 是 `500/单 + 每 5 单一档 20% 奖金 − 15% 税`；taxi 是 `65–105 + 小费 + 完好 10%`。
4. **反作弊 = 位置校验 + 职业校验 + 直接断线**（DropPlayer）。没有一个是「只信客户端上报」的。
5. **没有一个是「一次性触碰」**：最短的 hotdog 也要「租 → 做 → 卖 → 还」四段。
   我们现在的模板（到点 + 交互）在结构上就少了两段：**产出**与**售卖**。

---

## 2. 官方 job 一览

| job | 押金 | NPC | 计价 | 特色机制 |
|---|---|---|---|---|
| hotdog | **250**（银行） | 顾客 ped | 按品质单价（common/rare/exotic） | `KeyMinigame(10)` 定品质；可推车 |
| taxijob | 无 | 乘客 ped | `random(65,105)` + 小费 + 完好 10% | 仪表 125/英里；碰撞 5 次或车况 <750 终止 |
| garbagejob | **250**（银行） | 无 | 每袋 `random(50,100)` | 服务端生成路线（站数与袋数） |
| towjob | **250**（现金优先，退到银行） | 无 | `150–170 × 件数 + 车况 bonus − 税` | `DropPlayer` 反作弊；`/npc` 切换 |
| busjob | 无 | 上下车 ped（随机皮肤） | 见客户端 | 5 个 NPC 站点 + 皮肤池 |
| truckerjob | **125** | 无 | `500/单 + 每 5 单 20% 奖金 − 15% 税` | 满 20 单必须回站补给 |
| recyclejob | 无 | 收购 ped | 按材料种类 | 箱子道具 + 4–6 s 搬运动作；限量收购 |
| vineyard | 无 | 无 | 成品价（酒 15 / 果汁 10） | 葡萄→汁→酒，加工 180 s |
| mechanicjob | 未查 | 未查 | 未查 | 本轮未展开 |

---

## 3. 逐脚本细节（带证据）

### 3.1 hotdogjob（上一轮已详查，此处只列结论）

押金 250 银行 → 生成 `prop_hotdogstand_01` → 推车 → `KeyMinigame(10)` 定品质
（`faults==0 exotic / 1 rare / ≥2 common`）→ NPC 顾客成交 → 归还退押金。
**坑**：制作只加库存不发物品，而成交时校验物品 → 上游自身不自洽。

### 3.2 taxijob —— 「里程表 + 车况」的范式

| 机制 | 实现 |
|---|---|
| 计价表 | `Config.Meter = { defaultPrice = 125.0 }`（每英里）；`startingPrice = 0` |
| 乘客 | `Config.NPCLocations.TakeLocations` 池 + `DeliverLocations`；随机取点 |
| 结算 | 服务端事件 `qb-taxi:server:NpcPay`：`payment = random(65,105)`；`random(1,5)` 命中则 +10~20；完好再 +10% |
| 车况约束 | `MinCabHealth = 750`、`MaxCrashesAllowed = 5` → 触发任务终止 |
| NPC 反应 | `Speech` 四态（Angry / Scared / Grateful / Happy） |
| 反作弊 | `NearTaxi(src)`：玩家必须在某个下车点 20 m 内，否则 `DropPlayer('Attempting To Exploit')`；职业不符也断线 |
| 附加奖励 | 26% 概率掉 `cryptostick` |

**不该抄的坑**：客户端把 `hasReceivedBonus` 当参数传上来，服务端直接信了这个布尔值 ——
「是否完好」本应由服务端自己算（车损可由服务端读实体血量）。这是官方脚本里少见的漏点。

### 3.3 garbagejob —— 「服务端发牌」的范式

| 机制 | 实现 |
|---|---|
| 押金 | `Config.TruckPrice = 250`；`payDeposit` 事件 `RemoveMoney('bank', 250)` |
| 发牌 | `MaxStops = random(MinStops, #trashcan)`、`stop = random(#trashcan)`、`newBagAmount = random(2,5)` —— **全在服务端** |
| 计价 | `totalNewPay += random(BagLowerWorth, BagUpperWorth)`（50–100/袋），累加到 `PayShift` |
| 结算点 | `paycheck` 坐标，玩家走过去领 |
| 附加 | 75% 概率掉 cryptostick |

### 3.4 towjob —— 「押金 + 税 + 条件倍率」的范式

| 机制 | 实现 |
|---|---|
| 押金 | `Config.BailPrice = 250`；`DoBail` 先扣**现金**、现金不足扣**银行**；退还一律到**银行** |
| 计价 | `DropPrice = random(150,170)`；车况分档 bonus（5% / 7% / 10% / 12%）；`price = DropPrice × drops + bonus` |
| 税 | `taxAmount = ceil(price / 100 × PaymentTax)`；实发 `price − taxAmount` |
| 反作弊 | 结算前校验：职业名 + 玩家必须在总部 X 米内，否则 `DropPlayer`；`vehNetID`/`drops` 都做上限校验 |
| 控制 | `/npc` 切换 NPC 模式 |

### 3.5 truckerjob —— 「连击奖金」的范式

`TruckerJobTruckDeposit = 125`、`DropPrice = 500`/单、`Bonus = 20%`（每 5 单结算一次）、
`PaymentTax = 15%`、`MaxDrops = 20`（满了必须回站）。
→ 这是唯一一个把「**连续完成**带来的边际收益」写进配置的脚本。

### 3.6 recyclejob / vineyard —— 「生产链」的两种写法

| 脚本 | 链 | 证据 |
|---|---|---|
| recyclejob | 取箱子（`prop_cs_cardbox_01`，动作 4–6 s）→ 送 → **卖给收购 ped**（限量） | config 的 `PickupActionDuration` / `SellPed` / `LimitedMaterials` |
| vineyard | 摘葡萄（8–12）→ 榨汁（6–10，180 s 计时）→ 卖成品（酒 15 / 果汁 10） | config 的 `wineTimer` / `Sell.prices` |

→ 「生产」在成熟脚本里的两种形态：**动作时长模拟**（recycle）与**定时器加工**（vineyard）。
都没有用「小游戏」，只有 hotdog 用了（因为它是即时手艺）。

### 3.7 busjob —— 「NPC 站点」的范式

`Config.NPCLocations.Locations` 5 个上车点 + `NpcSkins` 随机外观池。
没有押金、没有顾客成交逻辑 —— 它是最接近我们现有模板（到点）的一个，也因此最"薄"。

---

## 4. 模式提炼（反复出现的 7 个做法）

| # | 模式 | 出现在 | 对我们的意义 |
|---|---|---|---|
| P1 | **押金即会话**：取车/取货时扣、还回时退，金额固定 | hotdog / garbage / tow / trucker | 我们的 `rental` 节点就该是「服务端会话 + 押金」 |
| P2 | **服务端发牌**：站数、每站量、单价随机都在服务端 | garbage / tow / trucker / taxi | 客户端只能上报「我做完了」，不能上报「值多少」 |
| P3 | **结算走物理点**：回到 HQ / 工资单点才结算 | 全部 9 个 | 我们的 `settle` 节点必须绑坐标，不是任务完成就转账 |
| P4 | **基础值 × 条件倍率 − 税** | tow / trucker / taxi | 单一固定价是反模式；要给「车况/连击/完好」留乘数位 |
| P5 | **反作弊三件套**：职业校验 + 位置校验 + 断线 | tow / taxi / garbage | 新节点的服务端校验必须是这三件，不能只查库存 |
| P6 | **附加掉落**：小概率给稀有物品 | hotdog 无 / garbage 75% / taxi 26% | 我们已在 qb-shops 里踩过 cryptostick 印钞，这里要「低概率 + 低价值」 |
| P7 | **生产用时长或计时器，不用小游戏** | recycle（动作时长）/ vineyard（180 s） | 小游戏只给「即时手艺」用；批量生产用计时器更省 |

---

## 5. 反哺到我们缺的 4 个节点

| 我们的节点 | 该吸取 | 不该抄 |
|---|---|---|
| `rental` | P1 押金即会话：扣款记 `citizenid`，退还走 `settle`；garbage 的「银行扣、银行退」最简单 | tow 的「现金优先」会让退款路径分叉，先不做 |
| `minigame` | hotdog 的 `faults → 品质映射`；但要改成**客户端只报 faults、服务端映射品质与产出** | hotdog 只加库存不发物品的半截实现 |
| `vendor_session` | busjob 的 NPC 站点池 + 随机皮肤；hotdog 的「顾客走近 → 报价 → 确认」 | taxi 把「是否完好」布尔交给客户端 |
| `settle` | P3 物理结算点 + P4 税与倍率（tow 的 `payment − tax` 写法最干净） | 只在任务完成回调里转账（没回点也能结算 = 可刷） |

---

## 6. 社区脚本（CC 并行调研）

> 占位：CC 正在跑 `Quasar` / `Renewed` / `jim-*` / `wasabi_*` 等源码可读的职业包，
> 回来后补进本节（循环形状、押金、顾客类型、结算方式、值得抄的点）。

---

## 7. 未验证 / 本轮没覆盖

| 项 | 状态 |
|---|---|
| `qb-mechanicjob` | 未展开（有 NPC 维修呼叫，结构可能更有参考价值） |
| `qb-busjob` 的结算公式 | 只看了 config，未读客户端计价 |
| `qb-taxijob` 的 `Meter` 是否真的在用 | config 里有 125/英里，但服务端用的是 `random(65,105)`，两者关系未查清 |
| 社区脚本 | CC 进行中 |
| 各脚本的性能表现（NPC 数量、同步开销） | 无公开数据，只能靠我们真机量 |
