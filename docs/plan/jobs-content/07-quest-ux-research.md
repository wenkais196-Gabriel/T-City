---
id: jobs-content-07-quest-ux-research
type: research
status: active
system: quest
owner: hermes
updated: 2026-11-14
review_by: 2027-02-28
---

# 任务节点与 UX 调研：以「热狗摊」为样本

> 结论先行：**我们的模板把「一次性触达」当成了任务**。上游 qb-hotdogjob 是一条
> 「租借 → 生产 → 持续售卖 → 归还结算」的经营循环，节点形状完全不同。
> 缺的不是数值，是 **4 类节点**（租借 / 小游戏生产 / 持续售卖 / 归还结算）与一套 UX 规格。
> 数值按用户决定**暂停调整**，等所有任务线补齐后再统一算。

---

## 1. 上游是怎么做的（证据）

`qbcore-framework/qb-hotdogjob`（官方资源，929 行 client）。

| 环节 | 上游实现 | 证据 |
|---|---|---|
| 租借 | 固定点交互 → 回调 `qb-hotdogjob:server:HasMoney`，从**银行**扣 `Config.StandDeposit = 250`，记 `Bail[citizenid] = true` | server.lua `CreateCallback('qb-hotdogjob:server:HasMoney')`；config.lua `Config.StandDeposit = 250` |
| 摊位 | `CreateObject('prop_hotdogstand_01')` 在 `Config.Locations.spawn` 生成、`FreezeEntityPosition` 冻结、`qb-target` 挂交互 | client.lua 403–414 |
| 推车 | 按 47 键 → `AttachEntityToEntity(StandObject, ped, GetPedBoneIndex(ped, 28422), …)` + 动画 `missfinale_c2ig_11 / pushcar_offcliff_f` | client.lua 261–273；`AnimationData` |
| 制作 | 站在摊位 1 m 内按 38 键 → `exports['qb-minigames']:KeyMinigame(10)` → 返回 `faults` | client.lua 305–310 |
| 三档品质 | `faults == 0 → exotic`、`1 → rare`、`≥2 → common`；品质决定**售价区间**与**库存上限** | client.lua 275–282；config.lua `Config.Stock` |
| 库存 | 每档 `Max = {15, 30, 45, 60}` 随等级成长；制作时 `Current + 1`（高等级有随机暴击 +1~level） | client.lua 282–298 |
| NPC 顾客 | 逛到摊位附近生成 ped，`TaskGoStraightToCoord` 走向摊位，`qb-target` 弹出「卖 N 个，共 $X」/「拒绝」 | client.lua 518–660 |
| 结算 | 服务端 `Sell` 校验 **距离 ≤ 4 m**（超出直接封号级 `ExploitBan`）、校验持有 `hotdog` 物品、扣物品、`AddMoney('cash', N × price)` | server.lua `RegisterNetEvent('qb-hotdogjob:server:Sell')` |
| 声望 | exotic +3 / rare +2 / common +1，上限 200，等级门槛驱动库存与售价 | server.lua `UpdateReputation` |
| 归还 | `StopWorking` → 回调 `BringBack` → 银行**原额退还** 250，清空库存、删摊位 | client.lua 486–516；server.lua `BringBack` |

### 上游自己也有两处矛盾（我们不要照抄）

1. **`Sell` 要求持有 `hotdog` 物品，但制作分支只加库存、没有 `AddItem`** —— 按代码读，
   卖出去的瞬间会因物品不足失败。上游靠「qb-core 的 hotdog 物品」与某些分支补上，属于历史债。
   → 我们的实现必须**制作 = 服务端产出物品**，售卖 = 服务端扣物品，两边同一个 owner。
2. **押金原额退还，没有按时的租赁费**。要「按时长扣租」是用户加的规则，上游没有，
   需要我们自己在结算节点里做（见 §5 `settle`）。

---

## 2. 我们仓库已有的零件

| 零件 | 能力 | 证据 |
|---|---|---|
| `qb-minigames` | 8 个小游戏，全是**客户端 export**：`Hacking`、`KeyMinigame(amount)`、`Lockpick`、`StartPinpad`、`Quiz`、`Skillbar(difficulty, validKeys)`、`WordGuess`、`WordScramble` | `T-CityLite.base/resources/[qb]/qb-minigames/client/keyminigame.lua:28` |
| `KeyMinigame` 返回值 | `{ quit = bool, faults = number }` —— 和上游热狗用的一模一样 | 同上 `RegisterNuiCallback('keyminigameFinish')` |
| `Skillbar` 返回值 | `data.success`（布尔），可做「三档品质」的另一种判定 | qb-minigames 的 skillbar 客户端脚本 |
| `qb-target` | 实体/区域交互（上游热狗用的就是它） | `T-CityLite.base/resources/[qb]/qb-target` |
| `PolyZone` | 区域判定（我们的 interact 步骤已用） | `T-CityLite.base/resources/[standalone]/PolyZone` |
| `custom-market` | **玩家间订单簿**：供需驱动价格 + 均值回归 → 「玩家能不能买」有现成通道 | `T-CityLite.base/resources/[custom]/custom-market/config.lua` |
| `qb-inventory` | `Player.Functions.AddItem / RemoveItem / GetItemByName` | 上游 `Sell` 就是这么用的 |
| `custom-vehicles` | 载具 spawn / 钥匙 / 回收 | `T-CityLite.base/resources/[custom]/custom-vehicles` |
| `custom-storage` | 容器与物品流转 | `T-CityLite.base/resources/[custom]/custom-storage` |

**注意**：`hotdog` 物品在我们库里**不存在**（qb-core 的 shared 目录下的 items.lua 424 行里没有 hotdog）。
要做热狗线，必须先有物品（三档品质 = 三个 item 或一个 item + metadata）。

---

## 3. custom-quest 的节点能力：13 种声明，8 种真的能跑

`Config.Quest.StepTypes` 声明了 13 种。逐个查客户端与服务端的处理分支：

| 类型 | 状态 | 说明 |
|---|---|---|
| `reach` / `goto` | ✅ 可用 | 到达坐标半径内 → `nodeComplete` |
| `interact` / `validator` | ✅ 可用 | 支持 `duration`、`animDict`/`animName`、服务端校验器 |
| `deliver` | ✅ 可用 | 有 `destCoords` 分支 |
| `custom_event` | ✅ 可用 | 监听外部脚本事件（采矿、物流在用） |
| `script_trigger` | ✅ 可用 | 服务端白名单调外部 export，**不自动推进**，等外部 `CompleteStep` |
| `decision` | ✅ 可用 | 剧情抉择（story-engine） |
| `reward` | ✅ 可用 | 结算步，自动完成 |
| **`collect`** | ❌ **死类型** | 全仓库没有任何处理分支 |
| **`wait`** | ❌ **死类型** | 同上 |
| **`combat`** | ❌ **死类型** | 同上 |
| **`placement`** | ❌ **死类型** | 同上（注释说 v0.10 支持，代码里没有） |

> 这就是「任务节点缺模板」的实证：**声明了不等于能用**。写配置时选到死类型，
> 注册器会放过（它只校验名字在白名单里），客户端没有任何反应 —— 任务静默卡死。

---

## 4. 差距表：6 个环节 × 现有能力

| 环节 | 需要什么 | 现有节点能不能表达 | 结论 |
|---|---|---|---|
| ① 租借（押金 + 起租计时） | 扣钱、记押金、起计时、生成实体、失败可回滚 | `script_trigger` 能扣钱，但**押金状态不在引擎里**：任务放弃/超时/服务器重启后没人退押金 | **要新模板 `rental`** |
| ② 推车 / 载具 | 生成实体、挂接、动画、归还时删除 | `script_trigger` 可 spawn；但「推着走」是客户端持续态，引擎没有对应表达 | 由 `rental` 的实体生命周期管理，客户端脚本负责推 |
| ③ 小游戏生产 | 弹小游戏、按成绩定品质、产出物品 | 引擎里**没有小游戏节点**；只能 `interact` 走进度条假装 | **要新模板 `minigame`** |
| ④ 持续售卖（NPC/玩家） | 一段时间内反复成交，每次成交服务端校验 | `custom_event` 只能计数推进，不能承载"每次交易结算" | **要新模板 `vendor_session`**（限时 + 每笔成交走独立校验） |
| ⑤ 归还 + 结算 | 还车、退押金、扣租金、按库存/品质结算 | `script_trigger` 能做，但同样缺「押金退还」这个不变量 | **要新模板 `settle`**（与 `rental` 配对） |
| ⑥ 动画 / 道具 | 做热狗动画、产出三档物品 | `interact` 支持 `animDict`/`animation`；物品需要 `qb-core` 侧定义 | 补齐物品定义即可 |

### 顺带发现的第二类问题：**任务线是"层"而不是"线"**

现有模板基本是「3 站到达」的平铺结构。热狗这条线是**嵌套**的：
外层（租→卖→还）里套内层（每做一次热狗 = 一次小游戏 + 一次产出），
再套第三层（每次 NPC 来买 = 一次询价 + 一次成交）。
引擎的线性 FSM 只能表达外层，内层必须由新节点自己带循环。

---

## 5. 新节点模板提案（字段草案）

### 5.1 `rental` —— 租借与押金

```lua
{ id = 'step_rent_cart', type = 'rental',
  data = {
    coords = { x = 39.3, y = -1005.5, z = 29.5 }, radius = 2.0,
    rent_point = 'hotdog_take',              -- 结算点（还车点）
    deposit = 250, currency = 'bank',
    rate_per_min = 6,                        -- 每满 1 分钟扣租金
    grace_sec = 60,                          -- 起租保护期，防"接了就还"
    max_minutes = 60,                        -- 上限，超时强制召回
    spawn = { model = 'prop_hotdogstand_01', coords = ..., heading = 342.5 },
  } }
```

- 服务端：扣 `deposit` → 写会话（`citizenid:questId`）→ 记 `startedAt` → 生成实体 → 推进。
- 退押金只能由 **`settle`** 完成；`AbandonQuest` / 失败 / 断线超时都要走 `settle` 的退款分支，
  否则玩家会丢押金 —— 这是**服务端不变量**，必须有测试钉住。
- 引擎已有同类先例：`quest_route_validators` 的会话表（`citizenid:questId`），可复用同一形状。

### 5.2 `minigame` —— 小游戏生产

```lua
{ id = 'step_cook', type = 'minigame',
  data = {
    coords = { ... }, radius = 1.5,
    anim = { dict = 'amb@prop_human_bbq@male@base', name = 'base' },
    export = 'qb-minigames:KeyMinigame', args = { 10 },
    quality_rules = { { faults = 0, item = 'hotdog_exotic' },
                      { faults = 1, item = 'hotdog_rare' },
                      { faults = 2, item = 'hotdog_common' } },   -- >=2 兜底
    repeatable = true,        -- 可反复做，不推进主线
    produce = { count = 1, cap = 30 },
  } }
```

- 客户端：调 export → 把 `{ faults }` 上报；**服务端**按 `quality_rules` 决定产出物品（不能信客户端上报的品质名）。
- 引擎的 `interact` 已有 `animDict`/`duration` 的现成写法，`minigame` 是它的超集。

### 5.3 `vendor_session` —— 持续售卖

```lua
{ id = 'step_sell', type = 'vendor_session',
  data = {
    coords = { ... }, radius = 4.0,
    duration_sec = 300,               -- 卖多久
    customer_interval = { 15, 40 },   -- NPC 到访间隔
    source = 'inventory',             -- 卖的是背包里的物品
    items = { hotdog_common = 5, hotdog_rare = 9, hotdog_exotic = 12 },  -- 底价，实际由品质与声望浮动
    allow_player_buy = true,          -- 玩家也能买（走 qb-target 的实体交互）
  } }
```

- **NPC 顾客**：客户端生成/驱动 ped（上游就是这么做的），成交**必须**走服务端校验：
  距离、库存、金额上限、频率（防连点）。
- **玩家顾客**：比 NPC 简单得多（不需要生成实体、不需要 AI），但需要一条「玩家 A 卖给玩家 B」的通道。
  两条现成路子：`qb-target` 直接交互（简单、无库存缓存）或 `custom-market` 订单簿（可复用现成的供需价格）。
  → **建议：第一版只做 NPC 顾客 + 允许玩家点摊位购买（固定价），订单簿留到 R5。**
- 这一环节的性能风险最高（实体数量 × 同屏玩家），所以间隔与上限要配置化，且**同屏 NPC 上限 ≤ 3**。

### 5.4 `settle` —— 归还与结算

```lua
{ id = 'step_return', type = 'settle',
  data = {
    coords = { ... }, radius = 2.0,
    rental_session = true,            -- 与 rental 配对
    refund_deposit = true,
    charge = 'per_minute',            -- 由 rental 的 rate_per_min 计算
    stock_settle = 'per_item',        -- 未卖完的货按成本回收 or 丢弃
  } }
```

- 输出一份**账单**（押金 - 租金 + 卖出所得 + 库存回收），一次性结算，并写审计日志。
- 中途放弃：退押金但**扣已用时长**；如果摊位/车没还，按 `max_minutes` 计费。

### 5.5 需要同步补的两件事

| 事项 | 说明 |
|---|---|
| 物品定义 | qb-core 的 shared 目录下的 items.lua 加三档热狗（或一档 + metadata 品质）。属于**配置平面**，不动逻辑 |
| 死类型清理 | `collect` / `wait` / `combat` / `placement` 要么实现，要么从 `StepTypes` 里删掉。**留着就是坑**：配置选到它，注册器放过、客户端无反应 |

---

## 6. UX 规格（玩家视角）

一条完整的热狗循环，玩家应当看到/听到这些：

| 阶段 | 玩家动作 | 应有反馈 | 失败态 |
|---|---|---|---|
| 接单 | 在租赁点按 E | 提示「押金 $250 从银行扣除，按分钟 $6 计租」+ 摊位出现 | 银行不足 → 明确提示差额，不扣钱 |
| 推车 | 抓车（47 键） | 进入推车动画，屏幕提示「走到位置后按 47 放下」 | 撞到人/车 → 车散架动画或自动放下 |
| 摆摊 | 放下 | 摊位落地、出现「按 E 制作 / 按 G 开卖」 | 放在车道中间 → 提示「阻挡交通」 |
| 制作 | 按 E → 小游戏 | 进度条/小游戏 UI，完成 toast「做到一份 稀有 热狗」+ 库存计数 | 小游戏退出 → 不消耗材料、不产出 |
| 开卖 | 按 G | 头顶浮标「营业中」，NPC 陆续走近 | 库存为 0 → 提示「先做几份再开卖」 |
| 成交 | NPC 走近弹「卖 2 份 $18？Y/N」 | 手递手动画 + 收钱 toast + 库存 -2 | 拒绝 → NPC 离开，不扣库存 |
| 收摊 | 回租赁点按 E | **账单面板**：押金 +250 / 租金 -36 / 售出 +174 / 库存回收 +0 → 实收 | 逾时未还 → 每小时提醒一次，超时扣押金 |

**关键 UX 原则**：这条线的快乐来自「经营」，不是「跑点」。所以每一笔成交都要有即时反馈，
账单必须是**明细**而不是一个总数 —— 否则玩家不知道自己赚在哪、亏在哪。

---

## 6.5 闸门与预算约束（新节点落地前必须知道）

这些不是建议，是仓库里**已经在跑的红线**。设计新节点前先按这张表对一遍，否则 PR 会被闸门打回。

| 约束 | 现值 | 对新节点意味着什么 |
|---|---|---|
| **NPC 预算闸**（FIT-07，custom-police 资源的 `npc_budget` 共享模块）| 全局 6 槽 / 每人 2 槽 / TTL 10 分钟 / 60 s sweep；槽价 backup=1、callout=2 | 热狗顾客**不能**无脑 spawn。若复用同一预算：6 槽全服意味着同时最多 6 个顾客，且模块属于 police 域（跨平面，要声明契约）。**建议：顾客用「1 个临时 ped、成交即删」的轻量形态，不占预算**，同屏上限 1–3 |
| **循环预算**（`io_budget.json`）| warm_polling_loops ≤ 5、fast_polling_loops ≤ 2、wait_zero_loops ≤ 1 | `vendor_session` 必须事件/定时器驱动（`SetTimeout` 链），**不能**新增 `while true … Wait(1000)` |
| **广播预算** | broadcast_sites 152 | 顾客到访用实体 target 或单点事件，不用 `-1` 全服广播 |
| **DB 调用预算** | db_call_sites 465（趋势）| 租借会话、账单**不落库**（内存即可，退出即作废）；只有 daily_limit 这类跨会话计数走 DB owner |
| **复用预算**（`reuse_budget.json`）| `loadAnimDict` ≤ 12、`DrawText3D` ≤ 4 | 新客户端代码必须用 core-framework 的共享函数，不得再抄一份动画加载/3D 文字 |
| **数字预算**（FIT-13）| 每个「已实现」的数字要同时出现在代码与文档 | 新节点的常量（顾客上限、租借上限分钟、小游戏难度）要登记进 `number_budget.json` 并写进文档，否则文档漂移会红 |
| **文档** | 315 篇已登记 | 新增文档要 frontmatter + `--index` 重生成；`system` 只能取白名单值（本系列取 `quest`） |

### 由此得出的实现形态建议

| 节点 | 不要这样做 | 应该这样做 |
|---|---|---|
| `vendor_session` | 每人 spawn 3 个常驻 ped、每 1 s 轮询一次 | 单个临时 ped，`SetTimeout` 排下一次到访；成交即删；同屏 ≤ 1 |
| `minigame` | 客户端判定品质后直接发奖励 | 客户端只上报 `faults`，服务端映射品质与产出 |
| `rental` | 押金写成客户端状态 | 服务端会话 + 不变量（只有 `settle` 能退），放弃/超时也走同一条退款路径 |
## 7. 交付标准

### 7.1 代码 / 配置交付标准

| 项 | 标准 |
|---|---|
| 节点实现 | 每个新 step 都有：客户端处理分支 + 服务端校验器 + `StepTypes` 注册 + 注册器白名单 |
| 服务端权威 | 客户端只上报数字（`faults`、`amount`），品质/金额/库存一律服务端判定 |
| 不变量 | 押金只有 `settle` 能退；放弃/失败/断线都要退（或有明确扣费规则）；同一玩家只能有一个租借会话 |
| 幂等 | 重复 `nodeComplete`、重复 `Settle` 不重复扣钱/退钱 |
| 测试 | 每个新节点 ≥ 3 条：正常、坏形状（越距/超额/重复）、不变量（放弃后押金状态） |
| 架构闸 | 新 net event 必须登记 + 鉴权；`db_call_sites` 只在 DB owner 涨；gate 预算靠自证规则而不是抬预算 |
| 死类型 | 未实现的类型不得留在 `StepTypes` 里 |

### 7.2 UX 交付标准

| 项 | 标准 |
|---|---|
| 每个交互点 | 有可见提示（3D 文本或 target 选项），不允许「走过去什么都没发生」 |
| 每一笔钱的变化 | 有 toast 或账单行，不允许静默加减 |
| 失败态 | 每个失败分支都有玩家可读的原因（不足/太远/库存空/逾时），不允许只打日志 |
| 动画 | 关键动作（推车、制作、递货）都有动画，不允许瞬移式交互 |
| 账单 | 结算明细至少四行（押金、租金、售出、回收），可回看 |
| 可测 | UX 的每一条都能在真机按清单走完（不做"看起来应该行"的判断） |

---

## 8. 需要你拍板

1. **热狗这条线先做「NPC 顾客 + 玩家点摊购买」还是直接上订单簿？** 我建议前者（成本低、可测）。
2. **租车 vs 推车**：上游是可推的摊位道具。我们是否保留「推」这个动作（乐趣高、但要处理碰撞与卡位）？
3. **押金与租金的数值**：这轮按你的决定**先不定**，等全部任务线补齐再统一算 —— 确认这个顺序。
4. **三档品质对应物品**：三个 item（`hotdog_common/rare/exotic`）还是一档 + metadata？
5. **新节点的工作量**：`rental` / `minigame` / `vendor_session` / `settle` 四个模板，
   我建议按这个顺序做（前两个能复用到所有「生产-售卖」型职业：热狗、矿工、洗衣、渔夫）。
