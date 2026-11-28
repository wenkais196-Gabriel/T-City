---
id: research-kittens-game-loop
type: research
status: draft
system: economy
owner: hermes
updated: 2026-11-28
review_by: 2027-02-28
---

# Kittens Game 循环拆解 → T-City 产业周期映射（调研 + demo 规格）

> **范围**：只做调研、映射与 demo 规格，**不写实现**。本轮没有改任何 `.lua` / `.py` / 测试 / 迁移。
>
> **证据等级**：
> - Kittens Game 的数字来自官方 wiki（2026-11-28 抓取）与官方源码核对；每节都给链接。第三方设计分析文章本轮没有引用。
> - T-City 的数字来自当前 worktree 的 `custom-industry` 配置与代码；**回本、季度收入等是手算推导值，未跑代码**。
> - 标「分析」的是设计推断；标「未取证」的是没有找到可引用来源、或没有真机数据。
>
> **一句话结论**：Kittens 的黏性不是“数值一直涨”，而是**可预期的损失 + 可见的下一步 + 离线有上限 + 重置有永久收益**。T-City 已经有成本曲线、库存上限、配额和结算；真正缺的是**让四个季节改变决策类型**，以及**把“季度重置”的资本会计算清楚**。后者比四季倍率重要得多：把 28 天的资本周期直接拉成 90 天，4 工位回本会从 6.1 周掉到约 1 周。

---

## 0. 结论先讲

| # | 结论 | 依据 |
|---|---|---|
| 1 | **最值得搬的是“四季改变决策”，不是“四季改倍率”**。Kittens 的春/夏/秋/冬分别对应“扩张/争夺/收割/收缩”，每季玩家要做的决定不同；只改数值的阶段等于换皮。 | §1.3、§4.2 |
| 2 | **库存上限 + 离线物化是 T-City 已有、且最不该丢的刹车**。离线只产“库存”，不产“钱”；仓满即停。这条比任何季节倍率都更能防通胀。 | `docs/server-design/12-industry-operations.md` §0、§11；`config/facility.lua:24` |
| 3 | **季度结算 + 设施跨季保留会把资本摊销拉长 3 倍**。当前 8 周回本的口径是“28 天重建一次设施”；如果设施跨 3 个周期只建一次，4 工位回本约 1.0 周，而不是 6.1 周。要么每季重建/收维护费，要么把资本价格 ×3，要么接受更高的货币投放并另找回收口。 | §4.4 的算式与表 |
| 4 | **最大的设计风险不是数值，而是“提现”**：结算只清产业层，Boss 可以在结算前把金库提现到个人银行（`server/commands.lua:167-210`）。如果提现没有摩擦，季度重置只重置生产工具，不重置财富，马太效应会从“组织资产”转移到“个人现金”。 | `server/settlement.lua:1-27`、`server/treasury.lua:212-217` |
| 5 | **demo 只能验证算术与配置形状，不能验证玩家行为、留存或全服通胀**。它的价值是让你在改 `.lua` 之前先看到“回本、配额、库存、声望”四条曲线怎么互相打架。 | §5.8 |

---

## 1. Kittens Game 的循环由几层组成

### 1.1 时间底座：一个“季节”只有 3 分 20 秒

Kittens Game 的网页版把时间压得很短，所以它敢用很猛的季节倍率：

| 单位 | 游戏内长度 | tick 数 | 真实时间（网页版） | 玩家在这层做什么 | 来源 |
|---|---|---|---:|---|---|
| Tick | — | 1 | 200 ms | 无决策；所有事件按 tick 排队 | [Game Mechanics](https://wiki.kittensgame.com/en/general-information/game-mechanics) |
| 天（Day） | — | 10 | 2 秒 | 生产/消耗自动结算 | 同上 |
| 季（Season） | 100 天 | 1,000 | 3 分 20 秒 | 补猫粮、调农民、看天气 | 同上 |
| 年（Year） | 400 天 = 4 季 | 4,000 | 13 分 20 秒 | 节庆、贸易、科技、建筑 | 同上 |
| 周期（Cycle） | 5 年 | 20,000 | 1 小时 6 分 40 秒 | 空间生产/节庆加成；更长线的规划 | 同上 |
| 一轮（Run） | 玩家决定 | — | 数小时到数天（量级估计） | 什么时候重置、要不要打挑战 | [Reset](https://wiki.kittensgame.com/en/general-information/game-mechanics#reset)、[Challenges](https://wiki.kittensgame.com/en/game-tabs/challenges) |
| 元层（Meta） | 跨轮 | — | — | paragon / metaphysics / 挑战奖励 | [Paragon](https://wiki.kittensgame.com/en/general-information/resources/paragon)、[Metaphysics](https://wiki.kittensgame.com/en/game-tabs/science/metaphysics) |

**对 T-City 的直接含义（分析）**：Kittens 的一个季节只有 3 分 20 秒，玩家一年能看到 4 次季节切换；T-City 的一个季节如果是 3 周，玩家一个季度只看到 4 次。**同样 25% 的冬季减产，在 3 分 20 秒里是节奏，在 3 周里是灾难**。所以 T-City 不能照抄 Kittens 的倍率幅度，除非把“季节”缩到 1 周左右，或者给玩家一个管理动作来对冲。

### 1.2 资源生产链：每一步都掉一层效率

Kittens 的通用产出公式是：

```
perTick = (building output × season modifier + job output × upgrades × happiness)
          × building % effects + automatic effects
          − consumption × consumption % effects
```

来源：[Resources](https://wiki.kittensgame.com/en/general-information/resources)。

关键点不是公式本身，而是**建筑产出吃季节倍率，岗位产出不吃**。猫田（Catnip Field）在冬天会掉到 25%，但农民（Farmer）的 1 catnip/tick 不受季节影响；所以冬天玩家会把猫口从猫田转向农民、或者囤猫粮。来源：[Game Mechanics](https://wiki.kittensgame.com/en/general-information/game-mechanics)、[Catnip](https://wiki.kittensgame.com/en/general-information/resources/catnip)。

主要转换链的“损耗率”如下（配方成本，craft ratio 可以放大产出）：

| 转换 | 比率 | 来源 |
|---|---|---|
| catnip → wood | 100 : 1（研究 Catnip Enrichment 后 50 : 1） | [Catnip](https://wiki.kittensgame.com/en/general-information/resources/catnip) |
| wood + minerals → iron（Smelter） | 0.05 wood + 0.1 minerals → 0.02 iron / tick，即 **2.5 wood + 5 minerals → 1 iron** | [Bonfire](https://wiki.kittensgame.com/en/game-tabs/bonfire) |
| iron + coal → steel | 100 iron + 100 coal → 1 steel | [Workshop](https://wiki.kittensgame.com/en/game-tabs/workshop) |
| steel → gear | 15 steel → 1 gear | 同上 |
| steel + titanium → alloy | 75 steel + 10 titanium → 1 alloy | 同上 |
| beam → scaffold | 50 beam → 1 scaffold | 同上 |
| furs → parchment | 175 furs → 1 parchment | 同上 |
| parchment + culture → manuscript | 25 parchment + 400 culture → 1 manuscript | 同上 |
| manuscript + science → compendium | 50 manuscript + 10k science → 1 compendium | 同上 |
| compendium + science → blueprint | 25 compendium + 25k science → 1 blueprint | 同上 |

**瓶颈设计**：猫粮被“猫口吃饭”吃掉，木材/矿物被建筑和铁吃掉，科学被科技吃掉，文化/信仰被节庆和宗教吃掉。每个上层资源都需要下层资源 + 时间 + 建筑，**没有一条链能只靠一种资源无限自举**。来源：[Resources](https://wiki.kittensgame.com/en/general-information/resources)、[Catnip](https://wiki.kittensgame.com/en/general-information/resources/catnip)。

### 1.3 季节：倍率是明牌，天气才是暗牌

四个季节对**猫田**的猫粮产出倍率如下（warm / average / cold）：

| 季节 | Warm | Average | Cold |
|---|---:|---:|---:|
| 春 Spring | +65% | **+50%** | +35% |
| 夏 Summer | +15% | **0%** | −15% |
| 秋 Autumn | +15% | **0%** | −15% |
| 冬 Winter | −60% | **−75%** | −90% |

来源：[Game Mechanics § Seasons](https://wiki.kittensgame.com/en/general-information/game-mechanics)。

天气规则：从第 4 年（年份从 0 开始计）起，每个季节有 **35% 概率异常**，其中 17.5% 偏暖、17.5% 偏冷、65% 正常。来源：同上。官方源码也把基础倍率写成 `1.5 / 1.0 / 1.0 / 0.25`，与 wiki 的 average 列一致：[calendar.js](https://github.com/nuclear-unicorn/kittensgame/blob/master/js/calendar.js)。

**玩家怎么应对**：
- 冬天前囤猫粮、建谷仓（Barn 每个 +5000 猫粮上限）；来源：[Catnip § Storage](https://wiki.kittensgame.com/en/general-information/resources/catnip)、[Bonfire](https://wiki.kittensgame.com/en/game-tabs/bonfire)。
- 把猫口从猫田转到农民，因为农民不受季节影响；来源：[Game Mechanics](https://wiki.kittensgame.com/en/general-information/game-mechanics)。
- 冬天和 Sharks 换猫粮：Sharks 的猫粮在冬季有 +45% 的季节加成；来源：[Trade](https://wiki.kittensgame.com/en/game-tabs/trade)。
- 开节庆（Festival）拉幸福度、拉猫口增长速度；来源：[Festival](https://wiki.kittensgame.com/en/general-information/events/festival)。

**失败了会怎样**：猫粮不足，猫会饿死；猫口死亡是硬损失，不是“少赚一点”。来源：[Kittens](https://wiki.kittensgame.com/en/general-information/resources/kittens)、[Catnip](https://wiki.kittensgame.com/en/general-information/resources/catnip)。

**设计要点（分析）**：Kittens 的季节是**可预期的**（冬天一定差，只是冷暖幅度随机），所以玩家能提前规划；随机性只改变“差多少”，不改变“会不会差”。这比“每季随机一个灾难”更适合持续世界。

### 1.4 节庆 / 随机事件 / 商队：把“挂机”打断成“回来看一眼”

| 机制 | 触发 / 成本 | 效果 | 在循环里的功能 | 来源 |
|---|---|---|---|---|
| **Festival（节庆）** | 玩家主动；1500 catpower + 5000 culture + 2500 parchment | 持续 400 天（一年）；幸福度 +30%；猫口到达速度 ×2；可刷新/叠加（Carnivals） | 资源消耗口 + 爆发 + 让玩家主动上线 | [Festival](https://wiki.kittensgame.com/en/general-information/events/festival) |
| **Astronomical event（天文事件）** | 第一座 Library 后每天 0.25%，每座 Observatory +0.2% | 持续 30 天；点击得 science + starchart；不点有 1%/Observatory 自动成功；SETI 后全自动 | 注意力检查 + 科学爆发 | [Game Mechanics § Astronomical events](https://wiki.kittensgame.com/en/general-information/game-mechanics) |
| **Meteor（流星）** | 每天 0.1%（Iron Will +0.4%） | minerals 50 + 25×ratio；science 15×(1+ratio)（Celestial Mechanics）；iron 5（Prospecting） | 随机资源小爆发 | [Events](https://wiki.kittensgame.com/en/general-information/events) |
| **Trade / 商队** | 探索者 1000 catpower；不同种族/季节换率不同 | 用一种资源换另一种；季节改变换率；有概率得 blueprint/spice | 把过剩资源转成短缺资源；套利 | [Trade](https://wiki.kittensgame.com/en/game-tabs/trade) |

季节对贸易的影响是明牌，例如（Amount Modifier）：

| 种族 / 资源 | 春 | 夏 | 秋 | 冬 |
|---|---:|---:|---:|---:|
| Lizards / Wood | −5% | **+35%** | +15% | +5% |
| Sharks / Catnip | +20% | −5% | +15% | **+45%** |
| Griffins / Iron | −25% | −5% | **+35%** | −20% |
| Nagas / Minerals | **+25%** | +5% | −35% | −5% |
| Zebras / Iron | 0% | +15% | −10% | −20% |

来源：[Trade § Seasonal Adjustments](https://wiki.kittensgame.com/en/game-tabs/trade)。

**功能（分析）**：这些机制不是“更多产出”，而是**改变玩家的上线理由**：
- 节庆是“我存够了资源，主动开一波”；
- 天文事件是“它只开 30 天，我现在不点就没了”；
- 商队是“这个季节换率最好，我把过剩的木头换成铁”。

对 T-City 的映射：这些不能照抄成“每组织随机刷事件”，否则在多人经济里会变成不公平的运气；应该做成**全服共享的限时订单/城市事件**，或者**组织花金库主动开促销**（见 §4.2）。

### 1.5 重置层：自愿重置，保留的是“下一轮更快”

Kittens 的重置不是定时器，是玩家自己按的按钮。Time 标签在研究 Calendar 后解锁，Reset 是 Time 标签里的一项；来源：[Time](https://wiki.kittensgame.com/en/game-tabs/time)。重置的保留/丢失规则：

| 类别 | 内容 |
|---|---|
| **一定保留** | Karma、Paragon（含 burned paragon）、Metaphysics 升级、Temporal flux、Zebra 计数、成就、统计、BLS、Blackcoin 价格、Epiphany、Transcendence 层级、Cryptotheology 建筑、礼物盒/包装纸、配色方案 |
| **有条件保留** | Apocrypha 下 worship 折成 epiphany；Anachronomancy 下 time crystal + Chronophysics；每个 Chronosphere 保留 1.5% 的非制作/非奢侈品资源；Flux Condensator 下部分制作资源按 `1.5% × 100 × sqrt(X)` 保留；Cryochambers 保留对应数量的猫 |
| **一定丢失** | Gigaflops、Hashrate、Worship、奢侈品（furs/ivory/spice/unicorns/alicorns/necrocorns/tears） |
| **重置获得** | 猫口 >35 得 Karma；>70 得 Paragon（每多 1 只 1 点）；Iron Will 下 Zebra 上限提升 |

来源：[Game Mechanics § Reset](https://wiki.kittensgame.com/en/general-information/game-mechanics#reset)。

Paragon 的效果：每点 **+1% 全局产出、+0.1% 存储、+0.05% 自动生产**；产出加成有 **200% 上限**并递减，存储加成没有上限。来源：[Paragon](https://wiki.kittensgame.com/en/general-information/resources/paragon)。Karma：每点 **+1% 幸福度**，另有“拥有任意 Karma +10%”的稀有资源加成；Karma 本身用 `karmaKittens` 做递减。来源：[Karma](https://wiki.kittensgame.com/en/general-information/resources/karma)。

**重置的“理由”（分析）**：不是“资源太多了”，而是**下一轮会更快**。Paragon/Karma/Metaphysics 让新一轮的早期阶段加速，所以玩家会在“继续当前轮的边际收益”低于“重开一轮的元收益”时重置。这一点和 T-City 的“季度到了就强制清”完全不同：Kittens 的重置是玩家的优化决策，T-City 的结算是日历事件。**强制结算必须额外给一个“下一季值得期待”的理由，否则会被感知为没收。**

### 1.6 挑战层：用规则变化延长生命周期

挑战由 Metaphysics 的 Adjustment Bureau 解锁；它们重置游戏、施加特殊限制，完成给永久奖励；多次完成会叠加“Increasing Challenge / Increasing Reward”。来源：[Challenges](https://wiki.kittensgame.com/en/game-tabs/challenges)。

| 挑战 | 限制（Base Challenge） | 目标 | 永久奖励（Base） |
|---|---|---|---|
| Iron Will | 不建住房、不养猫（隐藏挑战） | 无固定目标 | Zebra 上限 +1，按科技花费最多 +100/轮 |
| Winter Has Come | 只有冬天 | 到 Helios | 冷冬不再发生 |
| Anarchy | 猫懒惰、吃更多、只能一半上班、不能领导 | 建 AI Core | 重置时猫口对 Karma 双倍 |
| Energy | 能耗 ×2 | 建齐所有能源建筑 | 负能耗惩罚减半 |
| Atheism | 无信仰加成 | 带 cryochamber 重置 | Solar Revolution 上限提高 |
| 1000 Years | 年份卡在 500 | 到第 1000 年 | 时间水晶燃烧热量减半；解锁 Temporal Press |
| Black Sky | 没有天文事件 | 建 Space Beacon | 提前遇到 Elders；免费 Black Pyramid |
| Pacifism | 不能打猎 | 研究 Outer Space Treaty 并重置 | Base 无；后续完成提升贸易比率 |
| Unicorn Tears | 独角兽资源成为建筑成本，存储受限 | 获得 Necrocorn | Unicorn Tombs 提高信仰上限 |
| Post Apocalypse | 污染 10M ppm 起步 | 清完污染 | 可运作的 cryochamber 上限提高 |

来源：同上。

**它怎么延长生命周期（分析）**：挑战不是“更多数值”，而是**同一套内容、换一套约束**。老玩家已经知道最优建造顺序，挑战把顺序打乱，让他们重新做决策；奖励又是永久的小加成，不会把数值撕碎。

### 1.7 层与层怎么咬合

| 层 | 主要货币 | 玩家决策 | 失败后果 | 对下一层的影响 |
|---|---|---|---|---|
| 天/季 | 猫粮、木材、矿物 | 补食物、调岗位、囤粮 | 猫饿死 | 决定能不能活到明年 |
| 年 | 科学、文化、信仰 | 研究、节庆、贸易 | 进度慢、错过事件 | 决定建筑/科技上限 |
| 周期（5 年） | 空间资源、starchart | 空间任务、Numerology 规划 | 空间产出慢 | 决定后期资源 |
| 一轮 | Paragon、Karma | 什么时候重置 | 重置晚了，边际收益低 | 决定下一轮起点 |
| 元层 | Metaphysics、挑战奖励 | 买什么永久升级、打什么挑战 | 挑战失败，白跑一轮 | 决定长期策略 |

来源：综合 [Game Mechanics](https://wiki.kittensgame.com/en/general-information/game-mechanics)、[Time](https://wiki.kittensgame.com/en/game-tabs/time)、[Paragon](https://wiki.kittensgame.com/en/general-information/resources/paragon)、[Challenges](https://wiki.kittensgame.com/en/game-tabs/challenges)。

**关键观察（分析）**：Kittens 每一层用**不同的货币**，所以一层的最优解不能直接买通下一层。T-City 目前只有两种货币：组织金库（产业层）和 prestige（永久层）；个人现金是第三条、但不受结算约束。层数少意味着**更容易被一种最优策略打穿**，所以更需要配额和监控。

---

## 2. 它靠什么制造“黏性”，而不只是拖时间

| 机制 | 证据 | 来源 | 它治的是哪种流失 | 对 T-City 的启示 |
|---|---|---|---|---|
| **离线进度（Redshift）** | 暂停 ≥3 秒后按“每 2 秒补 1 天”补产出；初始上限 10 kitten years，有 1000 年日历或 paragon 后 40 年；离线每分钟 5 temporal flux | [Time](https://wiki.kittensgame.com/en/game-tabs/time) | “我不能一直开着游戏” → 离开也不亏 | T-City 的惰性生产 + 库存上限是同一功能；**不要因为季度变长就取消离线补算** |
| **可见的下一步** | 建筑在资源达到 30% 前隐藏；科技树有明确前置；存储上限不断逼你建谷仓/仓库 | [Bonfire](https://wiki.kittensgame.com/en/game-tabs/bonfire) | “上线不知道干什么” | 手机快照/Boss 菜单应该显示“下一座建筑/下一个工位/离上限还有多久”；现在只有当前状态，没有下一步 |
| **损失厌恶（可预期）** | 冬天猫田 −75%（冷冬 −90%）；猫饿死；仓库满了溢出即丢；天文事件 30 天不点就消失 | [Game Mechanics](https://wiki.kittensgame.com/en/general-information/game-mechanics)、[Events](https://wiki.kittensgame.com/en/general-information/events)、[Catnip](https://wiki.kittensgame.com/en/general-information/resources/catnip) | “没有理由回来” → 有东西会失去 | 季节要有“会失去的东西”（库存上限、冬季配额、限时订单），但不能是随机天灾 |
| **收藏与解锁** | 成就标签（第一个成就解锁）；Metaphysics 用 paragon 买永久升级；挑战有永久奖励 | [Achievements](https://wiki.kittensgame.com/en/game-tabs/achievements)、[Metaphysics](https://wiki.kittensgame.com/en/game-tabs/science/metaphysics)、[Challenges](https://wiki.kittensgame.com/en/game-tabs/challenges) | “后期没事做” | 组织称号、城市编年史、季度荣誉可以承担这一层；**不要给永久经济加成**，否则变成 power creep |
| **数值里程碑** | 35 猫 → Karma；70 猫 → Paragon；每 1000 年 1 paragon；存储上限逐级抬升 | [Karma](https://wiki.kittensgame.com/en/general-information/resources/karma)、[Paragon](https://wiki.kittensgame.com/en/general-information/resources/paragon) | “看不到进度” | 季度目标要可量化（收入、配额利用率、回本、排名），不能只有“再来一季” |
| **主动检查（check-in）** | 节庆、天文事件、商队、季节贸易加成都要求玩家在正确的时间做选择 | [Festival](https://wiki.kittensgame.com/en/general-information/events/festival)、[Events](https://wiki.kittensgame.com/en/general-information/events)、[Trade](https://wiki.kittensgame.com/en/game-tabs/trade) | “放置游戏太被动” | 每季给 1 个“现在做还是等下季”的选择（卖/囤、建/等、提现/留） |
| **精通/优化** | 成本曲线、转化损耗、季节贸易、幸福度/消费的取舍 | [Bonfire](https://wiki.kittensgame.com/en/game-tabs/bonfire)、[Workshop](https://wiki.kittensgame.com/en/game-tabs/workshop)、[Happiness](https://wiki.kittensgame.com/en/general-information/happiness) | “没有技巧表达” | 让“什么时候建、什么时候卖、卖多少”有可学习的答案；demo 应该能看出不同策略的差异 |
| **社交/对比** | **Kittens 本体是单机**；wiki 首页只链接 Reddit/Discord 等外部社区，没有游戏内排行榜/公会 | [wiki 首页](https://wiki.kittensgame.com/) | —（单机没有社交流失） | T-City 的多组织是新增层；可以做季度排行榜/CityFeed，但要用“荣誉”而不是永久资源，避免把竞争变成军备竞赛 |

> 注：最后一行“没有游戏内排行榜/公会”是基于 wiki 首页导航的**未取证**判断；不能证明游戏里绝对不存在任何隐藏排行榜。

**“不只是拖时间”的关键（分析）**：Kittens 的每个阶段都在换**问题**，不是换数字：
- 春天问“先建猫田还是先造猫口”；
- 夏天问“要不要囤到秋天卖/换”；
- 秋天问“收割还是继续投资”；
- 冬天问“保命还是赌明年”；
- 重置问“现在重开是不是更快”；
- 挑战问“换一套规则我还能不能赢”。

T-City 如果只做“四季倍率”，玩家第二轮就会把它当成“每 7 天变一次的税率表”。**每个季节必须有一个不同的决策类型**，否则不如不做。

---

## 3. 它的平衡是怎么不崩的

### 3.1 约束清单

| 约束 | Kittens 的参数 / 量级 | 来源 | 防什么 | 如果没有这条会怎样 |
|---|---|---|---|---|
| **指数成本曲线** | 建筑 price ratio 从 **1.12**（Catnip Field）到 **2.5**（Hut）；多数建筑 1.15；Barn 1.75；Chronosphere/Ziggurat 1.25 | [Bonfire](https://wiki.kittensgame.com/en/game-tabs/bonfire) | 单一种建筑无限堆叠；资本线性换产出 | 有钱就能无限买同一栋建筑，产出随资本线性增长，没有边际递减 |
| **库存上限** | 基础：catnip 5000、wood 200、minerals 250、coal 60、iron 50、titanium 2、gold 10、oil 1500、uranium 250、unobtainium 150、catpower 100、science 250、faith 100、culture 100、antimatter 100 | [Resources § Storage](https://wiki.kittensgame.com/en/general-information/resources) | 离线无限积累；挂机变最优 | 玩家关掉游戏一周，回来资源爆仓，所有“上线决策”消失 |
| **时间门槛** | 每季 100 天（3m20s）；科技有前置；建筑在资源 30% 前隐藏 | [Game Mechanics](https://wiki.kittensgame.com/en/general-information/game-mechanics)、[Bonfire](https://wiki.kittensgame.com/en/game-tabs/bonfire) | 跳过内容；一步到位 | 玩家第一天就能看到全部建筑/科技，失去“下一步”的钩子 |
| **转化损耗** | catnip→wood 100:1；2.5 wood + 5 minerals→1 iron；100 iron + 100 coal→1 steel；50 manuscript + 10k science→1 compendium | [Catnip](https://wiki.kittensgame.com/en/general-information/resources/catnip)、[Workshop](https://wiki.kittensgame.com/en/game-tabs/workshop) | 一种资源万能；没有专业化 | 木头可以 1:1 变任何东西，贸易和配方都失去意义 |
| **消费** | 每只猫 0.85 catnip/tick（4.25/s）；幸福度 >100% 时消费也按同比例增加 | [Catnip](https://wiki.kittensgame.com/en/general-information/resources/catnip)、[Happiness](https://wiki.kittensgame.com/en/general-information/happiness) | 猫口无限增长；只堆人口 | 猫口是纯收益，没有粮食约束，人口爆炸 |
| **幸福度惩罚** | 幸福度每低于 100 1 点，产出 −1%；每超过 5 只猫 −2%；最低 25%；节庆 +30% | [Happiness](https://wiki.kittensgame.com/en/general-information/happiness) | 只堆人口/不建娱乐 | 人口越多越好，Amphitheatre/Broadcast Tower 没有存在意义 |
| **重置折价** | 重置只保留少数资源（Chronosphere 每个 1.5%）；paragon 产出加成 200% 上限；存储加成无上限 | [Game Mechanics § Reset](https://wiki.kittensgame.com/en/general-information/game-mechanics#reset) | 跨轮资产复利；越滚越大 | 每轮把上一轮全部资产带过去，指数爆炸，新玩家永远追不上 |
| **声望递减** | Paragon 每点 +1% 产出，但 200% 封顶并递减；Karma 用 `karmaKittens` 递减 | [Paragon](https://wiki.kittensgame.com/en/general-information/resources/paragon)、[Karma](https://wiki.kittensgame.com/en/general-information/resources/karma) | 声望线性叠乘 | 老玩家产出无限高，新内容失去意义 |
| **随机性有上限** | 天气 35% 异常，但冬天一定差；天文事件 30 天窗口；流星是增益 | [Game Mechanics](https://wiki.kittensgame.com/en/general-information/game-mechanics)、[Events](https://wiki.kittensgame.com/en/general-information/events) | 纯随机惩罚；玩家无法规划 | 随机天灾会让玩家觉得“努力没用”；纯确定性又会让玩家觉得“只是打卡” |
| **挑战自限** | 挑战主动加限制，奖励永久但小 | [Challenges](https://wiki.kittensgame.com/en/game-tabs/challenges) | 后期无决策 | 后期只剩“堆更多建筑”，没有新问题 |

### 3.2 为什么这套组合不崩（分析）

1. **每个资源有不同瓶颈**：猫粮瓶颈是猫口消费，木材瓶颈是猫粮转化，矿物瓶颈是猫口/矿工，科学瓶颈是图书馆/学者，信仰瓶颈是神庙/祭司。玩家不能只优化一个资源，必须同时管食物、住房、存储、生产、科研。
2. **每个扩张动作都有边际成本**：建筑价格指数增长，越往后越贵；仓库/谷仓也占资源，不是免费上限。
3. **每个离线收益都有上限**：库存满了就停；redshift 有 10/40 年上限；temporal flux 有速率但没上限（用于时间操作，不是直接资源）。
4. **每个重置都有折价**：大部分资源丢失，paragon 有 200% 上限，Karma 递减；所以“重开”不是“复制资产”，而是“用资产换下一轮的加速度”。
5. **随机性不改变大方向**：冬天一定差，天气只改变差多少；天文事件是增益，不是惩罚；流星是增益。玩家能规划，但需要回来确认。

**一句话**：Kittens 不是靠一个“平衡公式”不崩，而是靠**六个互相独立的刹车**（成本、上限、时间、损耗、消费、重置）同时存在。任何一个刹车失灵，其他五个还能兜住。

### 3.3 T-City 的刹车更少，所以更需要监控

T-City 当前实际生效的刹车：

| 刹车 | T-City 现状 | 相当于 Kittens 的哪条 |
|---|---|---|
| 指数成本 | 工位 `floor(50,000 × 1.35^(n−1))`（`server/facility.lua:75-81`） | 成本曲线 ✅ |
| 库存上限 | `stockCap = 540`（`config/facility.lua:24`），满仓冻结 | 库存上限 ✅ |
| 时间门槛 | 四阶段时长 + 衰退期不可购置（`config/cycle.lua:44-61`） | 季节/科技门槛 ⚠️ 只有时间，没有科技树 |
| 转化损耗 | 只有一条 `iron_ore` 销售链；`iron_smelt` 配方当前不被 S3 读取 | 转化损耗 ❌ |
| 消费 | 无；工位不吃饭 | 猫口消费 ❌ |
| 幸福度 | 无 | 幸福度 ❌ |
| 重置折价 | 季度/周期结算清产业层 + prestige（`server/settlement.lua:1-27`） | 重置折价 ✅ |
| 声望递减 | +2%/级，10 级封顶 +20%（`config/cycle.lua:86-87`） | paragon 上限 ✅ |
| 配额 | 全服 11,000/阶段 + 单组织 50%（`config/sales.lua:31,39`） | Kittens 没有的额外刹车 ✅ |

**结论（分析）**：T-City 的刹车数量只有 Kittens 的一半左右。它没有“吃饭/幸福/转化损耗”这些软约束，所以**配额和结算必须承担更大的防通胀责任**；一旦配额失效（比如 `industry_sales` 没有 `phase` 的 bug），或者结算周期拉长导致资本摊销变便宜，就没有第二条软刹车兜底。这就是为什么“监控数值和配置”不是附属功能，而是主功能。

---

## 4. 映射到 T-City：哪些能搬、哪些搬不了

### 4.1 T-City 的现状数值（照抄配置）

| 项 | 值 | 位置 |
|---|---|---|
| 组织白名单 | `mining_co`（job `miner`）、`cartel`（gang `cartel`） | `T-CityLite.base/resources/[custom]/custom-industry/config.lua:15-18` |
| Boss 权限 | Grade 4 | 同上 `:22` |
| 设施 `baseCost` | **$50,000** | `config/facility.lua:16` |
| 工位上限 | **10** | `config/facility.lua:17` |
| 设施 `maxLevel` | 5（MVP 未使用） | `config/facility.lua:18` |
| 库存上限 `stockCap` | **540** | `config/facility.lua:24` |
| 配方 | `3 iron_ore → 1 iron_ingot`，60 秒（S3 生产当前不读取） | `config/facility.lua:26-36` |
| 单工位产能 | **4.5 单位/小时** | `config/production.lua:27` |
| 生产倍率 | **1.0** | `config/production.lua:30` |
| 生产心跳 | **30 秒** | `config/production.lua:33` |
| 单次追赶上限 | **3,600 秒（1 小时）** | `config/production.lua:36` |
| 每阶段全服配额 | **11,000** | `config/sales.lua:31` |
| `iron_ore` 单价 | **$50** | `config/sales.lua:35` |
| 单组织配额比例 | **0.5** | `config/sales.lua:39` |
| 单次卖单上限 | 1,000,000 | `config/sales.lua:42` |
| 阶段时长 | **10 / 10 / 5 / 3 天**（28 天） | `config/cycle.lua:44-61` |
| 阶段产能 / 售价 / 配额倍率 | 扩张 1.25/1.00/1.00；竞争 1.00/0.95/0.85；成熟 1.00/1.10/0.70；衰退 0.70/0.80/0.40 | `config/cycle.lua:44-61` |
| 可购置 | 扩张/竞争/成熟 = 是；衰退 = 否 | 同上 |
| `PrestigeK` | **50,000** | `config/cycle.lua:78` |
| 永久加成 | **+2%/级，10 级封顶 = +20%**；只乘产能，不乘售价 | `config/cycle.lua:86-87` |
| 单次结算组织上限 | 500 | `config/cycle.lua:90` |
| `core_economy` 全局倍率 | convar `economy_global_multiplier` 或 `economy_reward_scale`，默认 **1.0** | `core_economy/server/main.lua:111-123`；`configs/modules/economy.cfg:9` |
| 活动热度 | **0.5–1.5**，30 分钟窗口，0.05 步长 | `core_economy/server/main.lua:31-35` |
| 玩家加成 | **0.5–3.0**；产业销售**不读取** | `core_economy/server/main.lua:126-133`；`server/sale.lua:338-373` |

### 4.2 映射表

| Kittens 的做法 | T-City 里的对应物 | 能不能搬 | 为什么 |
|---|---|---|---|
| 四季影响**建筑产出**，不影响岗位产出（§1.3） | 现有四阶段倍率，乘到所有工位（`server/production.lua:205-215`） | **改造后能** | T-City 没有“岗位”层，产能 100% 来自工位，所以季节倍率会**全额**打到产出，比 Kittens 更猛。建议把倍率幅度收窄，或用“维护/减产”动作对冲 |
| 季节等长（100 天），天气 35% 异常（§1.3） | 现有阶段**不等长**（10/10/5/3），且完全确定 | **改造后能** | 等长季节更容易读；服务器级天气（全服同一种）可以做叙事，但**不要每组织独立随机**，否则多人经济里是运气税 |
| 建筑价格指数增长，ratio 1.12–2.5（§3.1） | 工位 `floor(50,000 × 1.35^(n−1))`（`server/facility.lua:75-81`） | **能** | 1.35 比 Kittens 多数建筑更陡，防垄断更强；但满建 $2.78M 也意味着“10 工位不是利润最优” |
| 库存上限由建筑提供，可升级（§3.1） | `stockCap = 540`，固定不可升级（`config/facility.lua:24`） | **改造后能** | Kittens 可以用谷仓/仓库扩容；T-City 固定上限会让高工位组织的离线缓冲变短（10 工位只有 12 小时）。如果要季度节奏，建议加“库存升级”或按工位缩放 |
| 猫口吃饭、幸福度影响产出/消费（§3.1） | 无对应物；工位不吃饭、没有幸福度 | **不能** | T-City 玩家是管理者，不是工人；NPC 工位没有“生存”层。强行加饥饿/幸福会惩罚离线玩家，并且会把个人层拉进产业结算 |
| 节庆：主动花三种资源，换 400 天 +30% 幸福/双倍猫口（§1.4） | 无；可做“城市展销会/组织促销” | **改造后能** | 全服节庆需要协调与防薅；组织级促销必须花金库、限时、限配额，否则就是印钞。MVP 不做 |
| 天文事件：0.25%/天，30 天窗口，点击得 science/starchart（§1.4） | 无；可做“限时订单/商机” | **改造后能** | 是很好的上线理由，但必须服务端权威、限时限量、通知可达；否则会变成 FOMO 惩罚 |
| 商队贸易：季节改变换率（§1.4） | 只有一条 `iron_ore` 销售链，没有跨资源交换 | **不能** | 要做需要卖家身份、多物品、订单/库存；超出 MVP。未来可做组织间订单或“外部买家” |
| 重置：清资源，留 paragon/karma/成就（§1.5） | 季度/周期结算清产业层 + prestige（`server/settlement.lua:1-27`） | **改造后能** | 方向一致；但 T-City 金库可以提现到个人层（`server/commands.lua:167-210`），所以“清产业层”挡不住个人财富累积。`PrestigeK` 也要按季度收入重标 |
| 挑战：自限规则，永久小奖励（§1.6） | 无；可做可选组织挑战/服务器剧本季度 | **改造后能** | 强制全服挑战会破坏 RP 经济；建议 opt-in、奖励 cosmetic/title，不给永久产能 |
| 离线进度（redshift，§2） | 惰性生产 + `max_catchup = 3600s` + `stockCap`（`server/production.lua:49-55`） | **能** | T-City 的闸是库存而不是时间，更适合持续世界；但追赶上限是 1 小时/次，停机很久要多个 tick 才追平 |
| 可见的下一步：建筑 30% 才显示、科技树（§2） | 手机快照 / Boss 菜单；没有“下一解锁”提示 | **改造后能** | 需要 UI 工作，但对管理者很有价值；至少应显示“离库存上限还有多久”“下一工位多少钱” |
| 成就/收藏（§2） | 无；可做组织称号/城市编年史 | **改造后能** | 与 RP 服契合；不要给经济奖励，否则变成第二套声望 |
| 社交/对比（§2） | 多组织竞争 + CityFeed/排行榜 | **改造后能** | Kittens 是单机；T-City 的多组织是优势，但排行榜会放大马太/敌对。用“季度荣誉”而不是永久资源 |
| 多资源链：catnip→wood→…（§1.2） | 单物品 `iron_ore`；`iron_smelt` 配方未生效 | **不能** | 多链会牵动库存/配方/销售/UI；MVP 只有一条链。若只加一个，建议加“2 步配方 + 转化损耗” |
| 玩家作为工人（猫口分配） | 玩家是管理者，产能靠 NPC 工位 | **不能** | 这是 RP 服的核心约束；不要把在线时长当产出 |
| 个人层不可动（重置清资源） | 宪法/结算边界：个人层字节不动（`server/settlement.lua:1-15`） | **不能** | Kittens 重置是单机自愿；T-City 不能把大家的家底抹掉 |
| 持续世界/离线玩家 | 服务器一直开，玩家离线也在 | **不能** | 季度只能软重置产业层；公告、缓冲、离线补偿必须设计 |
| 单组织独立最优解 | 多组织共享配额 + 单组织 50% 上限 | **改造后能** | 50% 上限是为 2 个组织校准的；3 个以上组织会出现“先到先得”（静态推导），后面的组织可能卖不出去 |

### 4.3 RP 服的四条特殊约束

1. **玩家是管理者，不是工人。** 产出靠 NPC 工位，在线时长 ≠ 产出。Kittens 的“调岗位/喂猫”不能照搬；T-City 的决策是“建不建、卖不卖、提不提现”。来源：`docs/server-design/12-industry-operations.md` §0 第 3 行、§4 Workstation 定义。
2. **有 RBAC 和多组织。** 只有 Grade 4 能建/卖/取（`config.lua:22`、`T-CityLite.base/resources/[custom]/custom-industry/server/access.lua`）；大多数成员是旁观者。Kittens 是所有玩家都做决策；T-City 的留存不能只靠 Boss 的动作，成员需要分红/称号/可见贡献。
3. **有宏观调节，但行业不能自己写第二套系数。** `core_economy` 的全局倍率影响所有职业（`core_economy/server/main.lua:111-123`），不能为了产业好看去抬它；产业的阶段售价倍率是更合适的本地旋钮（`config/cycle.lua:44-61`）。来源：`docs/server-design/12-industry-operations.md` §9/§10。
4. **服务器是持续世界。** 结算只能清产业层，个人层（现金/物品/车/房/职级）一个字节都不能动（`server/settlement.lua:1-15`、`docs/engineering/CONSTITUTION.md` 第 2/6 条）。所以不能做 Kittens 式硬重置；季度只能是“产业层软重置 + 公告”。

### 4.4 季度化的三种路径：先把资本会计算清楚

这是本文最重要的一节。当前 `PrestigeK=50,000`、回本 6–8 周、三档建造的数字，全部是按 **28 天一个周期、设施每周期重建** 校准的（`docs/server-design/12-industry-operations.md` §10）。把结算改成季度，资本的摊销期从 4 周变成 12 周，**同样的 C 和 R 会让回本大幅缩短（4 工位从 6.1 周降到约 1 周，不是简单除以 3）**。

设：

- `C` = 设施 + 工位的资本；
- `R` = 一个 28 天周期的收入；
- `N` = 一个结算周期包含几个 28 天周期（季度 N=3）；
- 若设施在结算时重建一次：季度回本 `= 4C / (N×R − C)` 周；
- 若设施每个 28 天周期都重建：季度回本 `= 4C / (R − C)` 周（和现在一样）。

三档建造的对比（推导值，按配置手算，未跑代码）：

| 档位 | C | R/28 天 | 现状回本（N=1） | 季度回本（N=3，设施只建一次） | 结论 |
|---|---:|---:|---:|---:|---|
| 1 工位 | $100,000 | $157,540 | **6.95 周** | **1.07 周** | 摊销期 ×3；回本缩到约 1/6（净现金效应） |
| 4 工位 | $381,643 | $630,280 | **6.14 周** | **1.01 周** | 同上；4 工位变成印钞机（约 1 周回本） |
| 10 工位 | $2,779,505 | $796,812 | 不回本 | 不回本 | 资本仍太重；季度化救不了满建 |

**这不是“四季倍率没调好”，是会计恒等式。** 若走 C（每周期维护 `2C/3`，季度总资本成本 `3C`），季度回本回到 `4×3C / (3R − 3C) = 4C / (R − C)`，即与现状相同；这也是为什么维护费不能只收 `C/3`。要让季度化后仍保持 6–8 周回本，只有三条路：

| 路径 | 做法 | 代价 | 适合 |
|---|---|---|---|
| **A. 经济周期仍是 28 天，季度只结算声望** | 设施每 28 天照旧清空/重建；3 个周期的结果累计，第 84 天发一次 prestige/排行榜 | “大周期”不改变生产工具；玩家仍每 4 周重建 | 想保住现有 6–8 周回本和防马太效果；改动最小 |
| **B. 季度经济周期，资本价格 ×3** | 设施跨 3 个周期保留，但 `baseCost`/工位成本 ×3；`PrestigeK` ×3 | 满建资本从 $2.78M 变成 $8.34M，超出 §20 的“头部 $2–5M”；新组织更难起步 | 想要真正的季度大周期，且愿意重标资本门槛 |
| **C. 季度经济周期，接受更高利润 + 加回收口** | 设施跨 3 个周期保留，价格/配额不变；用税收/维护费/分红/组织税把多出来的钱收回去 | 需要新的回收机制；如果回收不够，通胀 | 想要“季度大周期”的体感，且愿意做第二套货币回收 |

**推荐（按“季度大周期”这个目标）**：
- **首选 C：设施跨季保留，但加一笔“季度资本费/维护费”**。最小的实现是每个 28 天周期从 `treasury` 扣 `2C/3`（或结算时一次性扣 `2C`），把多出来的 3 倍利润收回去；这样季度总资本成本 ≈ `3C`，回本回到 6–8 周，资本门槛仍在 $2–5M。代价是要新增一条扣费/审计/欠费规则（不能扣成负数）。
- **次选 B：资本价格 ×3**。实现最简单，但满建 $8.34M 超出 §20 的“头部 $2–5M”，新组织更难起步。
- **A 是保守回退**：保留 28 天经济周期，只把 prestige 改成季度发放。它不提供“大周期”体感，但改动最小、数值最稳；如果你发现 C/B 的维护费/资本重标在真机上不可行，就退回 A。
- **不要直接用“季度 + 现行资本价格”**：4 工位回本约 1 周，产业会变成全服最赚钱的职业，通胀会从产业溢出到整个服务器。
- **无论走哪条，`PrestigeK` 都要按 `N` 缩放**：`K_quarter = K_cycle × N`。当前 `K=50,000`，N=3 → **150,000**。如果不缩放，满建一个季度会拿 `floor(sqrt(3×796,812/50,000)) = 6` 点，两个季度就顶满 +20%，power creep 比现在快一倍。

**四季等长化的影响**（如果你把 10/10/5/3 改成 7/7/7/7）：

| 档位 | 产量/周期 | 收入/周期 | 回本（N=1） | 对比现状 |
|---|---:|---:|---:|---|
| 1 工位 | 2,986 | $145,900 | 8.71 周 | 收入 −7.4%，仍在 6–10 周目标内 |
| 4 工位 | 11,944 | $583,600 | 7.56 周 | 收入 −7.4%，仍在目标内 |
| 10 工位 | 16,225 | $796,812 | 不回本 | 配额全吃满，不变 |

（推导值；按小时结算、向下取整，未跑代码。等长化会拉长冬季、缩短春季，所以小组织收入略降；满建因为每季配额都吃满，收入不变。）

### 4.5 已知缺陷：`industry_sales` 没有 `phase`

> **本轮不修**。这里只记录，因为 demo 必须知道“设计意图”和“当前代码”不是一回事。

- `industry_demand` 的主键是 `(cycle_no, phase, item_name)`，所以配额是**按阶段**的（`migrations/v4.3_industry_sales.sql:23-30`）。
- `industry_sales` 只有 `cycle_no`，**没有 `phase`**（`migrations/v4.3_industry_sales.sql:32-46`）。
- `readOrgUsed` 按 `(org_id, cycle_no, item_name)` 求和，把四个阶段的销量加在一起（`server/sale.lua:199-209`）。
- 配额 CAS 里的子查询同样只按 `cycle_no`，没有 `phase`（`server/sale.lua:386-396`）。

**后果**：扩张期卖满 5,500 后，竞争期的单组织上限是 4,675，但 `orgUsed` 已经是 5,500 → 第一件就返回 `org_cap_reached`。用户已在仓库 harness 复现；本轮只做了静态确认，**没有跑 harness**。

**demo 的处理**：
- 默认按**设计意图**建模：每个阶段独立累计 `orgUsed`；
- 提供“现状 bug”开关：按 `cycle_no` 累计，复现 `org_cap_reached`；
- 这个开关不是修复，只是让监控面板能区分“数值问题”和“schema 问题”。

### 4.6 最不该搬的两个（详见文末结论）

1. **猫口饥饿/幸福度**：T-City 的工位是 NPC/资本，不是需要喂的猫；加入饥饿会惩罚离线玩家，并把个人层拉进产业结算。
2. **全量硬重置**：T-City 是持续世界，个人层不可动；Kittens 的硬重置只在单机自愿语境下成立。

另外两个“不建议照搬但可以改造”的：**每组织独立随机天气**（多人经济里是运气税）、**强制全服挑战**（会破坏 RP 经济）。

---

## 5. demo 规格

### 5.1 目标与非目标

**目标**：做一个单页 HTML，离线可开，用 T-City 的真实配置值，模拟两种时钟（四季 / 季度结算）下的库存、配额、金库、回本四条曲线，让策划在改 `.lua` 前先看到数值后果。**默认场景 = 季度 + 维护费（§4.4 的 C）；A（28 天经济周期）和 B（资本 ×3）作为对照开关。**

**非目标**：
- 不是玩家可玩的游戏，不需要美术/音效/移动端适配；
- 不是服务器模拟器，不连数据库、不模拟并发/权限/审计；
- 不是平衡验收，不能替代真机试玩（见 §5.8）。

### 5.2 技术形态与布局

- **单文件 HTML**，内联 CSS/JS，无外部 CDN、无构建步骤；双击可开。
- 数据与渲染分离：`state` → `step()` → `render()`；所有随机用可复现的种子（默认固定种子）。
- 布局：
  ```
  ┌─────────────────────────────────────────────────────────────┐
  │ 顶栏：季度 / 天 / 季节 / 速度 / 播放暂停 / 重置 / 预设       │
  ├───────────────┬─────────────────────────────┬───────────────┤
  │ 组织卡片 A/B   │ 4 张图（2×2）                │ 配置滑杆/开关  │
  │ 金库/工位/库存 │ 库存 配额 金库 回本          │ + 事件日志     │
  ├───────────────┴─────────────────────────────┴───────────────┤
  │ 底部：汇总 tile（回本/声望/库存满仓/提现率）+ 导出 JSON/CSV │
  └─────────────────────────────────────────────────────────────┘
  ```
- 颜色：不要只靠红/绿区分，线条加形状/标签；深色/浅色都能读（参考 dataviz 的可访问性要求，但 demo 不追求品牌色）。

### 5.3 状态与数值表

**全局状态**：

| 字段 | 含义 |
|---|---|
| `day` | 0–90（默认演示 90 天；推荐模型第 84 天结算） |
| `seasonIndex` | 0=春/扩张，1=夏/竞争，2=秋/成熟，3=冬/衰退 |
| `quarter` | 季度序号 |
| `config` | 见下表；可在 UI 改 |
| `preset` | 现状 28 天 / 等长四季 / 季度经济周期 / 季度+维护费 / 成本×3 |
| `bugMode` | `per-phase`（设计意图）或 `cross-phase`（现状 bug） |
| `checkIn` | 连续 / 每天 / 每 3 天（模拟离线玩家） |

**组织状态**（A=`mining_co`，B=`cartel`）：

| 字段 | 含义 |
|---|---|
| `treasury` | 组织金库余额 |
| `withdrawn` | 已提现到个人银行（永久层，不随结算清零） |
| `prestige` | 永久声望点数 |
| `workstations` | 工位数 0–10 |
| `stock` | 当前库存 0–540 |
| `producedUnits` | 累计产出（只增不减） |
| `revenueBySeason[4]` | 每季销售额 |
| `salesBySeason[4]` | 每季销量 |
| `rejected` | `org_cap_reached` / `demand_exhausted` / `stock_empty` 次数 |

**配置表（默认值 = 当前 `custom-industry/config/*.lua`）**：

| 参数 | 默认值 | 可调范围 | 来源 |
|---|---:|---|---|
| 设施 `baseCost` | 50,000 | 10k–200k | `config/facility.lua:16` |
| 工位成本曲线 | `floor(50,000 × 1.35^(n−1))` | ratio 1.10–1.60 | `server/facility.lua:75-81` |
| 工位上限 | 10 | 1–20 | `config/facility.lua:17` |
| 库存上限 | 540 | 100–5,000 | `config/facility.lua:24` |
| 单工位产能 | 4.5/h | 1–30 | `config/production.lua:27` |
| 每阶段全服配额 | 11,000 | 1,000–50,000 | `config/sales.lua:31` |
| 单价 | 50 | 10–200 | `config/sales.lua:35` |
| 单组织比例 | 0.5 | 0.1–1.0 | `config/sales.lua:39` |
| 阶段时长 | 10/10/5/3 天 | 7/7/7/7 或自定义 | `config/cycle.lua:44-61` |
| 阶段产能/售价/配额 | 见 §4.1 | 可单独调 | `config/cycle.lua:44-61` |
| `PrestigeK` | 50,000 | 10k–500k | `config/cycle.lua:78` |
| 每级加成 | +2% | 0–10% | `config/cycle.lua:86` |
| 加成上限 | +20%（10 级） | 0–100% | `config/cycle.lua:87` |
| 全局经济倍率 | 1.0 | 0.5–2.0 | `core_economy/server/main.lua:111-123` |
| 热度 | 1.0 | 0.5–1.5 | `core_economy/server/main.lua:31-35` |

**派生数值表（默认配置，手算，未跑代码）**：

| 项 | 1 工位 | 4 工位 | 10 工位 |
|---|---:|---:|---:|
| 资本 C | $100,000 | $381,643 | $2,779,505 |
| 单周期产量（10/10/5/3） | 3,196 | 12,787 | 16,225 |
| 单周期收入 | $157,540 | $630,280 | $796,812 |
| 回本（28 天周期） | 6.95 周 | 6.14 周 | 不回本 |
| prestige/周期（K=50k） | 1 | 3 | 3 |
| 库存撑多久（倍率 1.0） | 120 h | 30 h | 12 h |
| 库存撑多久（春季 1.25） | 96 h | 24 h | 9.6 h |
| 库存撑多久（冬季 0.70） | 171 h | 43 h | 17 h |
| 单组织每阶段上限 | 5,500 / 4,675 / 3,850 / 2,200 | 同左 | 同左 |

**工位成本表**（`floor(50,000 × 1.35^(n−1))`）：

| n | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 成本 | 50,000 | 67,500 | 91,125 | 123,018 | 166,075 | 224,201 | 302,672 | 408,607 | 551,620 | 744,687 |

### 5.4 两个时钟与推进规则

**时钟 1：季节（内层）**

- 默认推荐：4 季 × 7 天 = 28 天/年；季节切换时立即应用新倍率。
- 也允许“现状”10/10/5/3 天，或“自然季度”4 × 22.5 天。
- 每季的产能/售价/配额倍率见 §4.1；冬季 `purchasable = false`。
- 玩家在每个季节可以做 §5.5 的 3–5 个动作；不做就按当前策略自动结算。

**时钟 2：结算（外层）**

- 推荐：3 个 28 天年 = **84 天 ≈ 12 周**，在第 3 个冬季结束触发结算；第 85–90 天展示新季度春季。
- 结算顺序（照 `T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua` 的语义）：
  1. 汇总本季度 `revenue = Σ salesBySeason`；
  2. `prestigeAward = floor(sqrt(revenue / K))`，`K = 50,000 × N`（N=3 → 150,000）；
  3. `prestige += award`（绝对值，重试不重复）；
  4. `treasury = 0`；`facility` 清空（工位/库存/产出）；`sales`/`demand` 清空；
  5. **`withdrawn` 不清**（个人层）；
  6. 记录 `quarterResults`（收入、产量、声望、清分余额），写事件日志；
  7. 新季度从春季开始，`day = 0`（或继续 85–90 天作为下一季春）。
- 结算前 7 天（默认）显示警告横幅 + 手机推送模拟；对应 `WarningSeconds = 7 天`（`config/cycle.lua:69-72`）。
- **若选 C（季度 + 维护费）**：每个 28 天周期结束时从 `treasury` 扣 `maintenance = 2C/3`（`C` = 当前设施 + 工位的重置成本）；余额不足记“欠费/停机”，不扣成负数。三个周期合计 ≈ `2C`；加上初始 `C`，季度总资本成本 ≈ `3C`，回本恢复到 6–8 周。

**公式（demo 必须和配置同口径）**：

```
productionPerHour = workstations × unitsPerHour × season.production × (1 + prestigeBonus)
stock            = min(stock + productionPerHour × dtHours, stockCap)
// 满仓期间的时间直接前进，不补算（对应 production.lua 的 stock_full 分支）

unitBase         = 50
orgCap           = floor(quotaTotal × OrgCapRatio + 1e-9)
orgRemaining     = orgCap − orgUsedThisPhase
globalRemaining  = quotaTotal − quotaUsed
sellable         = min(requested, stock, orgRemaining, globalRemaining)
// 请求量 > orgRemaining 时直接拒绝（不截断），对应 sale.lua:363-366
revenue          = floor(unitBase × sellable × globalMultiplier × heat × season.price + 1e-9)
// 展示价可以 floor(unitBase × global × heat × price) 给 UI，但入账按整单乘完再 floor（sale.lua:372-374）
```

**库存满仓**：库存到 540 后，继续经过的时间不产出、也不在卖出后补算；对应 `server/production.lua:128-133`。demo 要把“满仓小时数”统计出来。

**离线/检查间隔**：`checkIn = 连续 / 每天 / 每 3 天`。离线期间生产继续、库存封顶；但**不会自动卖**，所以玩家回来时可能看到满仓。这个开关是 demo 的核心之一：它把“在线时长 ≠ 产出，但上线频率影响变现”直接画出来。

### 5.5 玩家在一个季节里能做的 3–5 个动作

| # | 动作 | 可用季节 | 效果 | 约束 | 对应现状 |
|---|---|---|---|---|---|
| 1 | **建厂 / 雇工位** | 春/夏/秋 | 扣 `treasury`，工位 +1，产能上升 | 冬季关闭；工位 ≤10；金库够钱 | `server/facility.lua:101-180`、`:183-285` |
| 2 | **卖库存** | 全季 | 按当前季节价/配额卖出；钱进 `treasury` | 受 `orgCap`、全服配额、库存限制；超单组织上限直接拒 | `server/sale.lua:556-590` |
| 3 | **囤货/惜售** | 全季 | 不卖，赌下季价格；库存占上限 | 库存 ≤540；满仓后停产 | `server/production.lua:109-133` |
| 4 | **提现到个人银行** | 全季 | `treasury → withdrawn`（个人层，结算不清） | Boss 权限；金额 ≤ 余额 | `server/commands.lua:167-210` |
| 5 | **开促销 / 减产**（提案，不在当前代码） | 春/夏/秋 | 花金库换本季配额/价格；或临时降工位避免满仓 | 需要新表/新字段，MVP 不做 | — |

**每个季节的“正确问题”**（demo 应该让玩家感觉到）：

| 季节 | 该问的问题 | 典型策略 |
|---|---|---|
| 春 | 现在建，还是等夏天？ | 春季产能 1.25，早建早产；但金库要留卖单周转 |
| 夏 | 现在卖，还是囤到秋天？ | 夏季价 0.95、配额 0.85；秋天价 1.10、配额 0.70；赌错会满仓 |
| 秋 | 收割还是继续囤？ | 秋季价最高，但配额最低；优先卖高价、清库存 |
| 冬 | 清库存、提现、还是硬撑？ | 冬季不能买、产能 0.70、价 0.80、配额 0.40；结算前把该提的提走 |

### 5.6 四张监控曲线/仪表

#### 图 A：库存—产能—销售（Stock / Production / Sales）

- **x**：day 0–90；**y**：单位数。
- **系列**：`stock`（面积）、`produced` 累计（线）、`sold` 累计（线）、`stockCap`（虚线）。
- **标注**：季节边界竖线；满仓区间用红色底纹；事件日志标 `stock_full`。
- **指标 tile**：`stock_full_hours / total_hours`、`overflow_units`（本可产但被上限吃掉的量）。
- **监控问题**：库存上限是不是太低？玩家是不是每 3 天才上线一次？工位是不是建多了？
- **可疑信号**：满仓率 > 30% → 产能/上限/上线频率不匹配；满仓率 ~0 且库存长期接近 0 → 产能不足或卖得太快。

#### 图 B：配额消耗（Quota per Season）

- **x**：季节/天；**y**：单位数。
- **系列**：全服配额柱、组织 A 销量、组织 B 销量；单组织上限线（5,500/4,675/3,850/2,200）。
- **开关**：`per-phase`（设计意图） vs `cross-phase`（当前 bug）。
- **指标 tile**：`quota_utilization = sold / quotaTotal`、`org_share`、`rejected` 次数。
- **监控问题**：配额是不是先于产能触顶？第二家组织是不是永远卖不出去？50% 上限在 3 个组织时还成立吗？
- **可疑信号**：某组织连续 3 季份额 > 45%；`org_cap_reached` 集中在季初（可能是 bug 或上限太低）；全服配额利用率 < 50%（需求太高/产得太少）。

#### 图 C：金库—提现—结算—声望（Treasury / Withdrawal / Prestige）

- **x**：day；**y**：$（左轴）、prestige 点（右轴）。
- **系列**：`treasury`（线）、`withdrawn` 累计（线）、`prestige`（阶梯）。
- **标注**：结算日竖线；结算前 7 天警告带；`treasury` 归零；`withdrawn` 不归零。
- **指标 tile**：`withdrawal_ratio = withdrawn / revenue`、`prestige_per_quarter`、`treasury_at_settlement`。
- **监控问题**：玩家是不是在结算前把金库抽干？季度重置到底重置了什么？prestige 的增速是否和 K 匹配？
- **可疑信号**：提现率 > 80% → 产业层只是过路财神，anti-马太失效；`treasury_at_settlement` 长期接近 0 → 玩家已经把“结算清余额”内化成“提前提现”。

#### 图 D：收入—成本—净现金—回本（Revenue / Capex / Payback）

- **x**：季度/天；**y**：$ / 周。
- **系列**：每季收入柱、累计资本柱、累计净现金线；右侧仪表：`payback_weeks = 4C / (R_quarter − C)`（若 `R_quarter ≤ C` 显示“不回本”）。
- **开关**：结算节奏 N=1 / N=3；资本是否跨季保留；成本 ×1 / ×3；维护费 0 / 2C/3 每周期。
- **指标 tile**：`R_quarter`、`C`、`net_cash`、`payback_weeks`、`ROI`。
- **监控问题**：季度化后回本是不是从 6 周掉到 1 周？满建是不是永远不回本？资本价格要不要 ×3？
- **可疑信号**：回本 < 4 周 → 资本太便宜/配额太高/价格太高；回本 > 12 周 → 没人愿意建，产业空转；满建 ROI 为负但玩家仍建 → 说明声望/竞争动机压过利润，需要单独监控。

### 5.7 “自动试玩 90 天”加速开关

**控制**：

| 控件 | 选项 | 说明 |
|---|---|---|
| 速度 | 1× / 10× / 100× / 瞬间 | 1× ≈ 每 100ms 推进 1 小时，90 天约 3.6 分钟；100× 约 2 秒 |
| 播放/暂停 | — | 暂停时可改配置并重算 |
| 预设 | 入门 1 工位 / 推荐 4 工位 / 满建 10 工位 / 双组织 / 三组织 | 双组织默认 A=4、B=1；三组织用来测 50% 上限的“先到先得” |
| 检查间隔 | 连续 / 每天 / 每 3 天 | 模拟离线；离线不自动卖 |
| 策略 | 每天卖光 / 囤到秋 / 只卖到配额 80% / 结算前提现 | 自动播放时的确定性策略 |
| 结算 | 28 天 / 84 天 / 84 天 + 维护费 / 84 天 + 成本×3 | 对应 §4.4 的 A/C/B 路径 |
| 季节 | 10/10/5/3 / 7/7/7/7 / 4×22.5 | 对应现状/等长/自然季度 |
| Bug 开关 | per-phase / cross-phase | 对应 §4.5 |

**自动播放流程**：

1. 初始化：季度 1、day 0、春季；组织按预设建厂/雇工位（扣钱）。
2. 每 1 小时：按当前季节倍率生产；若 `stock` 到 540，记录 `stock_full` 并停止产出。
3. 到达检查间隔：按策略卖库存（受配额/上限限制），钱进 `treasury`。
4. 季节边界：应用新倍率；冬季关闭购买；记录季节收入。
5. 第 84 天（或 28 天，按结算设置）：结算；累计 prestige；清产业层；记录 `quarterResults`；第 85 天开新季度。
6. 第 90 天：停止，输出汇总；可导出 JSON/CSV。

**汇总 tile（至少 8 个）**：

`quarterRevenue`、`prestigeAward`、`paybackWeeks`、`stockFullRatio`、`quotaUtilization`、`orgShareA/B`、`withdrawalRatio`、`treasuryAtSettlement`。

### 5.8 这个 demo 不证明什么

**必须写在 demo 的“关于”面板里，避免被当成验收：**

- ❌ **不证明玩家行为**：检查间隔、策略、是否提现，都是假设；真实玩家可能更懒、更激进、更不理性。
- ❌ **不证明留存**：demo 没有社交、没有 RP、没有组织政治；它只能证明“数值上有没有理由回来”，不能证明玩家会回来。
- ❌ **不证明全服通胀**：demo 只有 1 个物品、2–3 个组织、没有其他职业/商店/任务/犯罪的钱出口；全服货币供应不在模型里。
- ❌ **不证明服务器正确性**：没有数据库、并发、事务、RBAC、审计、崩溃恢复；`org_cap_reached` 的 bug 只是算术复现，不是修复验证。
- ❌ **不证明配置就是对的**：所有“推荐值”都是手算/设计推断；正式值必须真机试玩（至少一个 compressed cycle + 一个真人季度）。
- ❌ **不证明 anti-马太有效**：如果玩家在结算前提现，demo 会显示提现率，但不会自动判断“这算不算马太”；需要结合个人银行数据看。
- ❌ **不证明四季倍率适合 RP 服**：3 周冬天 vs 3 分 20 秒冬天，玩家体感完全不同；demo 只能给你看数字，不给体感。

### 5.9 demo 自身的验收（不是产业验收）

| 检查 | 判据 |
|---|---|
| 数值一致性 | 默认配置下，1/4/10 工位的单周期产量/收入与 §5.3 表一致（按代码的 `floor(x + 1e-9)` 口径；若 demo 不加 epsilon，允许 ±1 单位/±$100 的取整差） |
| 结算幂等 | 同一天重复点“结算”不重复加 prestige；`prestigeAfter` 是绝对值 |
| 满仓语义 | 库存到 540 后不再增长；卖出后不会补算满仓期间的时间 |
| 配额语义 | per-phase 模式下，每季独立累计；cross-phase 模式能复现“扩张卖满 5,500 后竞争第一件 `org_cap_reached`” |
| 提现语义 | 提现后 `treasury` 减少、`withdrawn` 增加；结算后 `withdrawn` 不变 |
| 确定性 | 同一配置/策略/种子，两次 90 天跑出的汇总一致 |
| 导出 | JSON 至少包含 config、quarterResults、dailySeries、summary |

---

## 附录 A：监控指标与季度复盘

把 demo 的 tile 变成运营指标；**初始阈值是设计建议，不是取证值**。

| 指标 | 公式 | 健康范围（建议） | 异常时先看什么 |
|---|---|---|---|
| 满仓率 `stock_full_ratio` | 满仓小时 / 总小时 | < 20% | 库存上限太低、工位太多、玩家上线太稀 |
| 配额利用率 `quota_utilization` | 销量 / 全服配额 | 50–90% | 太低 → 需求太高/产能不足；100% → 配额是瓶颈，竞争真实 |
| 单组织份额 `org_share` | 组织销量 / 全服销量 | ≤ 50%，且不是长期 45%+ | 50% 上限是否被吃满；3 组织时是否先到先得 |
| 提现率 `withdrawal_ratio` | 已提现 / 累计收入 | < 60% | 结算前抽干 → 产业层是过路财神；anti-马太失效 |
| 季度声望 `prestige_per_quarter` | `floor(sqrt(quarterRevenue/K))` | 与 §10 目标一致（1 工位约 1，满建约 3） | K 没按 N 缩放；收入异常 |
| 回本周数 `payback_weeks` | `4C / (R_quarter − C)`；`C` 含季度维护费/资本费 | 6–10 周 | < 4 周 → 资本太便宜/配额太高；> 12 周 → 没人建 |
| 集中度 `HHI` | `Σ org_share²` | < 0.5 | > 0.8 → 一家独大；配额/成本/声望需要重标 |
| 季节方差 `season_variance` | 各季收入的标准差 / 均值 | < 0.4 | > 0.5 → 某一季决定生死；季节倍率太猛 |
| 新组织存活率 | 新组织 1 季内建到 ≥1 工位的比例 | > 50% | 资本门槛/配额先到先得/声望差距太大 |
| 配置哈希 | 每次改配置记录 `hash(config)` | 每季一条 | 没有它就无法把“数值变化”归因到配置变化 |

**季度复盘清单（按顺序问）**：

1. 有没有组织在季初就 `org_cap_reached`？→ 先查 `industry_sales.phase` bug，再查上限。
2. 满仓率是不是 > 30%？→ 库存/工位/上线频率不匹配。
3. 提现率是不是 > 80%？→ 结算清余额被内化成“提前提现”；anti-马太失效。
4. 声望/季度是不是偏离目标 > 20%？→ K 没按结算周期缩放。
5. 有没有新组织一季内建不起来？→ 资本门槛太高/配额被先到先得吃光。
6. 全服配额利用率是不是 < 50%？→ 需求太高或产能太低；也可能是玩家都囤着不卖。
7. 有没有一家组织连续 3 季份额 > 45%？→ 50% 上限不够，或声望/资本复利。
8. 这次改配置前后，哪条曲线先动？→ 用配置哈希 + 季度结果做 A/B，不要凭感觉。

---

## 附录 B：来源

### Kittens Game（官方 wiki，2026-11-28 抓取）

- [Game Mechanics](https://wiki.kittensgame.com/en/general-information/game-mechanics)（tick/天/季/年/周期、天气、季节表、天文事件、Reset 的保留/丢失）
- [Resources](https://wiki.kittensgame.com/en/general-information/resources)（产出公式、常见资源、基础库存）
- [Catnip](https://wiki.kittensgame.com/en/general-information/resources/catnip)（猫粮产出/消费/100:1 木材/库存）
- [Bonfire / Buildings](https://wiki.kittensgame.com/en/game-tabs/bonfire)（建筑成本、price ratio、库存建筑、Smelter 比率）
- [Workshop](https://wiki.kittensgame.com/en/game-tabs/workshop)（制作配方/损耗）
- [Trade](https://wiki.kittensgame.com/en/game-tabs/trade)（种族、季节换率、商队）
- [Events](https://wiki.kittensgame.com/en/general-information/events)（流星、天文、季节事件）
- [Festival](https://wiki.kittensgame.com/en/general-information/events/festival)（成本/400 天/+30% 幸福/双倍猫口）
- [Religion](https://wiki.kittensgame.com/en/game-tabs/religion)（Solar Revolution、Transcendence、宗教升级）
- [Challenges](https://wiki.kittensgame.com/en/game-tabs/challenges)（挑战列表/奖励/叠加）
- [Happiness](https://wiki.kittensgame.com/en/general-information/happiness)（幸福度公式/消费/惩罚）
- [Paragon](https://wiki.kittensgame.com/en/general-information/resources/paragon)（+1% 产出/+0.1% 存储/200% 上限）
- [Karma](https://wiki.kittensgame.com/en/general-information/resources/karma)（+1% 幸福/递减）
- [Time](https://wiki.kittensgame.com/en/game-tabs/time)（Time 标签、redshift、temporal flux、Chronoforge）
- [Kittens](https://wiki.kittensgame.com/en/general-information/resources/kittens)（猫口/岗位/技能）
- [Science](https://wiki.kittensgame.com/en/general-information/resources/science)（科学产出/库存）
- [Achievements](https://wiki.kittensgame.com/en/game-tabs/achievements)（成就标签/示例）
- [Metaphysics](https://wiki.kittensgame.com/en/game-tabs/science/metaphysics)（paragon 购买/永久保留）
- [Kittens Game Wiki 首页](https://wiki.kittensgame.com/)（外部社区链接；单机判断）

### Kittens Game 官方源码（用于核对数值，不替代 wiki）

- [calendar.js](https://github.com/nuclear-unicorn/kittensgame/blob/master/js/calendar.js)（季节基础倍率 1.5/1.0/1.0/0.25；100 天/季）
- [prestige.js](https://github.com/nuclear-unicorn/kittensgame/blob/master/js/prestige.js)（paragon 产出/存储公式）
- [time.js](https://github.com/nuclear-unicorn/kittensgame/blob/master/js/time.js)（Reset UI、redshift 上限）

### T-City（当前 worktree）

- `T-CityLite.base/resources/[custom]/custom-industry/config.lua`
- `T-CityLite.base/resources/[custom]/custom-industry/config/facility.lua`
- `T-CityLite.base/resources/[custom]/custom-industry/config/production.lua`
- `T-CityLite.base/resources/[custom]/custom-industry/config/sales.lua`
- `T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua`
- `T-CityLite.base/resources/[custom]/custom-industry/server/{settlement,cycle,sale,treasury,facility,production,commands}.lua`
- `T-CityLite.base/resources/[system]/core_economy/server/main.lua`
- `T-CityLite.base/migrations/v4.3_industry_sales.sql`、`v4.4_industry_cycle.sql`
- `docs/server-design/12-industry-operations.md`
- `docs/engineering/CONSTITUTION.md`

---

## 附录 C：未取证 / 待验证

| # | 事项 | 状态 |
|---|---|---|
| 1 | Kittens 是否有游戏内排行榜/公会 | **未取证**：wiki 首页只列外部社区；没有找到“排行榜”页面，但不能证明不存在 |
| 2 | Kittens Reset 的精确解锁条件 | **部分取证**：Time 标签由 Calendar 解锁，Reset 在 Time 标签；没有单独的“Reset 解锁”页面。源码 UI 显示 Reset 面板在 Time 标签内 |
| 3 | Kittens 移动版与网页版的差异 | **未取证**：本文只对网页版；移动版贸易退款等有差异（wiki 提到），但不影响主循环结论 |
| 4 | T-City 的“季度”应取 84 天还是 91 天 | **设计取值**：84 天 = 12 周，便于 3×28 天周期；91 天 = 13 周，更接近自然季度。demo 默认 84 天 + 6 天新季度展示 |
| 5 | 四季等长化后的精确收入 | **推导值**：按小时结算、向下取整手算；未跑代码；demo 应以模拟结果为准 |
| 6 | 季度化后的真实回本/通胀 | **未取证**：本文只给会计恒等式与手算；需要真机至少一个季度（或压缩周期）验证 |
| 7 | `industry_sales` 缺 `phase` 的真机复现 | **用户报告 + 静态确认**：用户已在 harness 复现；本轮未跑 harness、未改代码 |
| 8 | 玩家在结算前提现的真实比例 | **未取证**：没有真机数据；demo 只能模拟策略 |
| 9 | 3 个以上组织时 50% 上限的行为 | **静态推导**：配额先到先得；没有真机多组织数据 |
| 10 | 季节倍率对 RP 玩家体感的影响 | **未取证**：3 周冬天 vs 3 分 20 秒冬天；需要真人试玩 |

---

## 附录 D：一句话回答（给决策者）

- **最值得搬的 3 个**：① 四季改变决策类型（不是只改倍率）；② 库存上限 + 离线物化（离线只产库存、不产钱）；③ 重置折价 + 永久声望（季度软重置 + 封顶 prestige）。
- **最不该搬的 2 个**：① 猫口饥饿/幸福度（T-City 玩家是管理者，NPC 不吃饭；会惩罚离线）；② 全量硬重置（持续世界，个人层不可动）。
- **最大风险**：季度结算清得掉设施，清不掉已经提现到个人银行的钱；如果提现没有摩擦，重置只会重置生产工具，不会重置财富，马太效应会从组织资产转移到个人现金并更快复利。
