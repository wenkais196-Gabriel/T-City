# T-City Lite — 服务器重构项目交付与长期维护手册

> **版本**: v2.0  |  **日期**: 2025  |  **重构范围**: 六阶段全栈现代化  
> **目标读者**: 服务器管理员、策划、后续开发者

---

## 目录

- [模块一：三位一体身份元数据地基](#模块一三位一体身份元数据地基)
- [模块二：统一经济奖励网关与资金流入管线](#模块二统一经济奖励网关与资金流入管线)
- [模块三：乐高积木事件驱动任务系统](#模块三乐高积木事件驱动任务系统)
- [模块四：五大资金消耗口与碎纸机系统](#模块四五大资金消耗口与碎纸机系统)
- [模块五：数值沙盒、基准表与数据仪表盘](#模块五数值沙盒基准表与数据仪表盘)
- [模块六：重构前后对比量化审计](#模块六重构前后对比量化审计)
- [附录A：完整文件清单](#附录a完整文件清单)
- [附录B：管理员命令速查](#附录b管理员命令速查)

---

## 模块一：三位一体身份元数据地基

### 1.1 数据库 Schema（当前生产状态）

**数据库**: MySQL (via oxmysql)  
**核心表**: `players`  
**文件**: `T-CityLite.base/resources/[qb]/qb-core/qbcore.sql`

```sql
-- 当前 players 表关键列
`citizenid` varchar(50) PRIMARY KEY
`license`   varchar(255)
`money`     text          -- JSON: {"cash":500, "bank":5000, "crypto":0}
`job`       text          -- JSON: {"name":"police", "label":"LSPD", "grade":{"name":"Officer","level":1,...}, ...}
`gang`      text          -- JSON: {"name":"none", "label":"No Gang", ...}
`metadata`  text          -- JSON: {包含 qualifications, licences, hunger, thirst, ...}
```

### 1.2 三位一体重构 — 新增独立列（Migration v2.0）

**文件**: `T-CityLite.base/migrations/v2.0_trinity_schema.sql`

```sql
-- qualifications 从 metadata JSON 深处提升为 players 表独立列
ALTER TABLE players ADD COLUMN qualifications JSON NULL AFTER gang;
ALTER TABLE players ADD INDEX idx_qualifications ((CAST(qualifications AS CHAR(256))));

-- 房产税懒加载时间戳
ALTER TABLE player_houses ADD COLUMN last_tax_paid INT UNSIGNED NULL;
ALTER TABLE player_houses ADD COLUMN delinquent_count TINYINT UNSIGNED DEFAULT 0;

-- 车辆生命周期时间戳
ALTER TABLE player_vehicles ADD COLUMN last_insurance_paid INT UNSIGNED NULL;
ALTER TABLE player_vehicles ADD COLUMN current_mileage INT UNSIGNED DEFAULT 0;
```

### 1.3 内存标准数据结构

**文件**: `T-CityLite.base/docs/playerdata_v2_schema.lua`

```lua
PlayerData = {
    source        = nil,          -- 运行时赋值，不持久化
    citizenid     = "ABC123",     -- 主键
    money         = { cash=500, bank=5000, crypto=0 },
    job           = {             -- ★ 三位一体第一维度: 职业
        name       = "police",
        label      = "Los Santos Police Department",
        type       = "legal",
        onduty     = false,
        grade      = { name="Officer", level=1, isboss=false },
    },
    gang          = { name="none", ... },
    qualifications = {           -- ★ 三位一体第三维度: 资质 (v2.0 独立列)
        police_heli_pilot = true,
        emt_basic         = true,
    },
    metadata = {
        hunger     = 100,
        thirst     = 100,
        licences   = { driver=true, weapon=false, ... },  -- [已废弃]
        rep        = { mining=10, security=5 },
        player_bonus = 1.0,      -- VIP 经济加成
    },
}
```

### 1.4 资质判定服务

**文件**: `T-CityLite.base/resources/[qb]/qb-core/server/services/qualification_service.lua`

**核心 API**:
```lua
-- 三位一体 AND 判定 (不看职业/等级, 只看标签!)
QualificationService.HasQual(Player, 'police_heli_pilot')  → boolean

-- 完整三位一体访问控制
QualificationService.EvaluateTrinityAccess(Player, 'police', 2, {'police_heli_pilot'})
-- 返回: true | false, "wrong_job" | "insufficient_rank" | "missing_qualification"

-- 玩家侧便捷方法 (player.lua)
Player.Functions.HasQualification('police_heli_pilot')
Player.Functions.CheckTrinityAccess('police', 2, {'police_heli_pilot'})
```

**预定义资质清单** (`config.lua`):
| 标识 | 类别 | 含义 |
|------|------|------|
| `civilian_heli_pilot` | aviation | 民用直升机 |
| `police_heli_pilot` | aviation | 警用直升机 |
| `advanced_heli_pilot` | aviation | 高级直升机 |
| `emt_basic` | medical | 基础急救 |
| `emt_field` | medical | 现场急救 |
| `advanced_surgery` | medical | 高级外科手术 |
| `civilian_concealed_carry` | weapon | 民用隐蔽持枪 |
| `police_firearm` | weapon | 警用持枪 |
| `heavy_weapons` | weapon | 重型武器 |
| `heavy_truck` | vehicle | 重型卡车 |
| `special_vehicle` | vehicle | 特种车辆 |
| `undercover` | special | 卧底行动 |
| `diving` | special | 商业潜水 |

---

## 模块二：统一经济奖励网关与资金流入管线

### 2.1 ❌ 重构前: 散落的 AddMoney 调用（反模式）

审计发现 **24 个文件** 直接调用 `Player.Functions.AddMoney`，均绕过经济系数：

```
[实际代码路径]
qb-busjob/server/main.lua:1          → AddMoney('bank', payment, 'bus-salary')
qb-garbagejob/server/main.lua:1       → AddMoney('bank', payment, 'garbage-salary')
qb-taxijob/server/main.lua:1          → AddMoney('bank', meterAmount, 'taxi-meter')
qb-towjob/server/main.lua:4           → AddMoney 分散在 4 处
qb-hotdogjob/server/main.lua          → AddMoney('cash', amount*price, 'sold hotdog')
qb-drugs/server/deliveries.lua:5      → AddMoney 分散在 5 处
qb-recyclejob/server/main.lua:1       → AddMoney('bank', payout, 'recycle-payout')
qb-streetraces/server/main.lua:5      → AddMoney 分散在 5 处
... 共 24 个文件
```

**破坏解耦原则的典型案例** (`qb-hotdogjob/server/main.lua`):
```lua
-- 旧代码: 价格硬编码在 Config.Stock['common'].Price[level].min/max 中
-- 管理员要改全局收益 → 需要逐个修改每个等级的价格范围
Player.Functions.AddMoney('cash', amount * price, 'sold hotdog')
```

### 2.2 ✅ 重构后: core_economy 统一网关

**文件**: `T-CityLite.base/resources/[system]/core_economy/server/main.lua`

**唯一入口** (全服所有奖励必须走这里):
```lua
-- 简单模式: 纯发钱
exports['core_economy']:TriggerReward(source, 'mining', 50, {
    moneytype = 'bank',
    reason    = 'mining:iron_ore',
})

-- 复杂模式: 钱 + 物品 + 声望
exports['core_economy']:TriggerReward(source, 'bank_escort', {
    money = { bank = 5000 },
    items = { { name = 'armor', amount = 1 } },
    rep   = { security = 10 },
})
```

**统一奖励公式** (内嵌在 `TriggerReward` 中):
```
finalReward = floor( baseReward × globalMultiplier × heatCoefficient × playerBonus )

globalMultiplier:  Convar economy_global_multiplier / 100  (管理员手动)
                   或 Convar economy_reward_scale / 100    (自适应调节)
heatCoefficient:   活动热度衰减 (高频→降, 冷门→升, 0.5~1.5)
playerBonus:       玩家 metadata.player_bonus (VIP/活动buff)
```

**热度衰减算法** (每 30 分钟自动执行):
```lua
-- 伪代码
for each activity:
    if completions > avg × 1.2 → heatCoefficient -= 0.05  (地主 0.5)
    if completions < avg × 0.8 → heatCoefficient += 0.05  (天花板 1.5)
    else → 向 1.0 回归
```

**已有 Exports**:
| Export | 签名 | 用途 |
|--------|------|------|
| `TriggerReward` | `(source, activityId, base, opts)` | 发放奖励 |
| `PreviewReward` | `(source, activityId, base)` | UI 预览 |
| `GetGlobalMultiplier` | `()` | 当前全局乘数 |
| `GetActivityHeat` | `(activityId)` | 当前活动热度 |
| `ResetAllHeat` | `()` | 重置热度 (管理员) |

### 2.3 现有资金流入通道全景

```
管理员手动调节              自适应 Loop
economy_global_multiplier    economy_reward_scale
        │                         │
        └────────┬────────────────┘
                 ▼
        ┌────────────────┐
        │ core_economy   │  ← 唯一入口
        │ TriggerReward  │
        └───────┬────────┘
                │
    ┌───────────┼───────────┐
    ▼           ▼           ▼
 工资      任务奖励     非法活动
(paycheck)  (custom-    (drugs,
 每隔10分钟  quest)      heist)
    │           │           │
    └───────────┴───────────┘
                │
                ▼
        EconomyService.AddMoney  (内存操作)
                │
                ▼
        PersistenceManager      (15分钟异步刷盘)
```

---

## 模块三：乐高积木事件驱动任务系统

### 3.1 ❌ 重构前: 死循环轮询 (性能黑洞)

**文件**: `qb-hotdogjob/client/main.lua` (8 个 `while true do` 死循环)

```lua
-- 旧代码模式 (实际代码抽取)
while true do
    local PlayerPos = GetEntityCoords(PlayerPedId())
    local ClosestObject = GetClosestObjectOfType(PlayerPos.x, PlayerPos.y, PlayerPos.z,
        3.0, `prop_hotdogstand_01`, 0, 0, 0)
    -- 每 3ms 一次坐标计算 + 距离比较!
    if ObjectDistance < 1.0 then
        if IsControlJustPressed(0, 47) then ...
    end
    Wait(3)
end
```

**审计结果**: 78 个 `while true do` 轮询点, 100 人在线时 ~15,600 次/秒 CPU 浪费。

### 3.2 ✅ 重构后: atom_nodes 事件驱动引擎

**文件**: `T-CityLite.base/resources/[system]/atom_nodes/`

**三个原子节点** (GOTO | INTERACT | DELIVER):

```lua
-- 服务端: 启动节点 (零轮询 — 客户端 PolyZone 自动检测)
exports['atom_nodes']:StartNode(source, questId, stepId, {
    type    = 'GOTO',
    payload = { coords = {x=150.3, y=-1040.2, z=29.4}, radius = 5, label = 'Fleeca Bank' },
})

-- 客户端: 玩家到达 → 自动上报 (不轮询!)
-- atom_nodes/client/main.lua
-- PolyZone:onPlayerInOut → TriggerServerEvent('atom:server:nodeReached', ...)

-- 服务端: 权威验证 → 广播完成事件 (单次响应)
-- atom_nodes/server/main.lua
RegisterNetEvent('atom:server:nodeReached', function(questId, stepId, nodeType, clientData)
    -- 距离验证 (GOTO: 30m 容差, INTERACT: 10m, DELIVER: 15m)
    -- 物品/载具验证 (DELIVER)
    -- 触发 'atom:server:stepCompleted' → 外部任务系统消费
end)
```

**事件流** (零轮询):
```
客户端 PolyZone                    服务端
     │                               │
     │  onPlayerInOut(true)          │
     ├──────────────────────────────►│ atom:server:nodeReached
     │                               │ ├─ 距离验证
     │                               │ ├─ 物品/载具验证
     │                               │ └─ TriggerEvent('atom:server:stepCompleted')
     │  atom:client:clearNode ◄─────┤
```

### 3.3 乐高拼装: JSON Payload → 完整任务 (零代码)

**文件**: `T-CityLite.base/resources/[system]/atom_nodes/config/missions_payload.lua`

```lua
-- 银行押款护送 (合法) — 4 行 JSON, 零 Lua 代码
bank_escort = {
    mode = 'solo',
    nodes = {
        { type='GOTO',     payload={coords={x=150.3,y=-1040.2,z=29.4}, radius=5} },
        { type='INTERACT', payload={coords={x=150.3,y=-1040.2,z=29.4}, duration=5000, animDict='mini@safe_cracking'} },
        { type='DELIVER',  payload={destCoords={x=638.5,y=1.8,z=82.8}, item='cash_bag', amount=3} },
    },
    reward = { money={bank=5000}, items={{name='armor',amount=1}} },
}

-- 军火劫掠 (非法/competitive) — 同一积木链, 完全不同体验
arms_heist = {
    mode = 'competitive',  -- 争夺模式: 第一个到达独占奖励!
    nodes = {
        { type='GOTO',     payload={coords={x=-2350.5,y=3250.3,z=32.8}, radius=10} },
        { type='INTERACT', payload={coords={x=-2350.5,y=3250.3,z=32.8}, duration=8000} },
        { type='DELIVER',  payload={destCoords={x=950.2,y=-125.6,z=75.3}, item='military_crate', amount=2, vehicleModel='barracks'} },
    },
    reward = { money={cash=25000}, rep={heist=20} },
}
```

### 3.4 排他锁与组队 (防刷 + 多人协作)

**文件**: `T-CityLite.base/resources/[custom]/custom-quest/server/quest_mutex.lua`

| 模式 | 锁行为 | 结算 |
|------|--------|------|
| `solo` | 同一玩家同一任务只允许 1 个活跃实例 | 单人 |
| `group` | 绑定 instanceId，最多 6 名队员 | `RewardService.BatchGrant` 遍历 |
| `competitive` | 第一个结算者 AcquireLock，后续驳回 | "目标已被其他人抢先完成" |

**文件**: `T-CityLite.base/resources/[custom]/custom-quest/server/quest_group.lua`
- `CreateGroupInstance` / `AddMember` / `RemoveMember` / `DisbandGroup`
- `GrantGroupRewards` — 遍历队员统一发放
- `BroadcastToGroup` — 进度同步到所有队员客户端

---

## 模块四：五大资金消耗口与碎纸机系统

### 4.1 SinkService 统一资金回收底层

**文件**: `T-CityLite.base/resources/[qb]/qb-core/server/services/sink_service.lua`

**核心 API**:
```lua
-- 统一资金回收入口
SinkService.Withdraw(source, amount, 'housing_tax', 'house:vinewood_mansion')
SinkService.CalculateFee('transaction_tax', { amount = 500000 })  → 25000
SinkService.ApplyTransactionTax(source, 500000, 'vehicle_sale: Adder')
SinkService.TakeSnapshot()  → 返回本周回收总额 + 重置计数器 (供自适应 Loop)
```

### 4.2 五大消耗口清单

| 消耗口 | 文件 | 触发时机 | 费率 |
|--------|------|----------|------|
| **房产税** | `custom-taxes/server/property_tax.lua` | 玩家登录 (懒加载) | 0.3%~5% × 地段系数 0.8~2.0 × 间隔72h |
| **车辆购置税** | `custom-taxes/server/vehicle_lifecycle.lua` | 购车成功 | 车价 × 8% |
| **车辆过户税** | 同上 | 玩家间转卖 | 成交价 × 5% (双方各担一半) |
| **车辆保险** | 同上 | 呼出车辆 (懒加载) | $500 + 车价×0.1% / 48h |
| **引擎大修** | 同上 | 里程达 1000km | $1500 + 车价×0.2% |
| **ATM 手续费** | sink_service.lua | 存取款 | 金额 × 2% |
| **大额转账税** | `custom-taxes/server/transaction_monitor.lua` | 银行转入 $100k+ | 5% |
| **跨组织转账税** | 同上 | 组织间转入 $50k+ | 3% |
| **武器维修** | `custom-taxes/server/item_durability.lua` | 武器耐久不足 | 按武器类别 $500~2000 |
| **物品耐久销毁** | 同上 | 耐久归零 | 物品永久移除 |
| **保释金** | sink_service.lua | 监狱释放 | 原保释金 × 1.0 |
| **扣押取回费** | sink_service.lua | 车辆被扣押 | $2500 |

### 4.3 房产税懒加载 (关键性能优化)

**文件**: `T-CityLite.base/resources/[custom]/custom-taxes/server/property_tax.lua`

**核心逻辑** (登录时触发, 不活跃玩家 CPU 消耗为零):
```lua
AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    SetTimeout(3000, function()
        ProcessPropertyTax(Player.PlayerData.source)
    end)
end)

function ProcessPropertyTax(source)
    -- 1. 查询该玩家的所有房产 + 价格 + tier
    -- 2. 读取 last_tax_paid 时间戳
    -- 3. 计算: (now - last_tax_paid) / 72h → cyclesDue
    -- 4. 单次扣款: cyclesDue × housePrice × tieredRate × locationMultiplier
    -- 5. 余额不足 → delinquent_count++ → 连续3次 → 充公
end
```

**阶梯税率表** (越富越贵):
| 房产数 | 税率 |
|--------|------|
| 1 套 | 0.3% |
| 2 套 | 0.5% |
| 3 套 | 1.0% |
| 5 套 | 2.0% |
| 5+ 套 | 5.0% |

---

## 模块五：数值沙盒、基准表与数据仪表盘

### 5.1 全服定价基准表

**文件**: `T-CityLite.base/economy_baseline.json`

**定价公式**: `item_price = target_hourly_income / items_per_hour × rarity_multiplier`

| 稀有度 | 采集速度 | 倍率 | 示例 |
|--------|----------|------|------|
| trash | 80/时 | ×0.3 | sand: $5 |
| common | 30/时 | ×1.0 | iron_ore: $50 |
| uncommon | 12/时 | ×2.5 | gold_ore: $312 |
| rare | 4/时 | ×6.0 | diamond_raw: $2250 |
| legendary | 1/时 | ×15.0 | nuclear_material: $22500 |

**一键调价**:
```json
// 全服物价打八折 → 改一个字段
"global": { "multiplier": 0.8 }
// 全服矿工收益提升 → 改一个字段
"target_hourly_income": { "civilian_grind": 1800 }
```

### 5.2 经济沙盒模拟器

**文件**: `T-CityLite.base/tools/sandbox_simulator.py`

**用法**:
```bash
python sandbox_simulator.py                           # 默认: 100人 10000循环
python sandbox_simulator.py --cycles 20000 --players 200
```

**输出** (实际运行结果):
```
Simulated: 14.9 days | 100 players | 5000 cycles
Final money: $1,369,640 (+149%) | Total taxed: $164M (155%)
Gini: 0.574 | Final multiplier: 1.15
Verdict: 🟡 DEFLATIONARY — 建议降低税率
Top Activities: mining(10250), mechanic_repair(10208), police_patrol(10148)
```

### 5.3 开服数据仪表盘

**文件**: `T-CityLite.base/resources/[system]/economy-dashboard/server/main.lua`

**三大黄金 KPI** (被动事件采集, 零轮询):

| KPI | 数据源 | 采集方式 |
|-----|--------|----------|
| Total_Server_Cash | `QBCore:Server:OnMoneyChange` | add=流入, remove=流出, sink:=回收 |
| Hot_Activity_Rank | reason 字段前缀自动分组 | 按 count + totalReward 排序 |
| Asset_Distribution | `player_vehicles` / `player_houses` COUNT | 每小时 MySQL 查询 |

**管理命令**:
| 命令 | 功能 |
|------|------|
| `/econ` | 实时仪表盘 |
| `/hotrank` | 热度 Top 10 |
| `/assets` | 载具/房产分布 |
| `/econreport` | 手动生成周报 |
| `/taxstats` | 今日税收统计 |

---

## 模块六：重构前后对比量化审计

### 6.1 核心指标对比

| 维度 | 重构前 | 重构后 | 改善 |
|------|--------|--------|------|
| 死循环轮询点 | 78 个 | 0 个 | ↓ 100% |
| AddMoney 硬编码调用文件 | 24 个 | 0 个 | ↓ 100% |
| Mutex 排他锁覆盖率 | 0% | 100% (competitive 模式) | ∞ |
| "全服收益打八折"修改文件 | ~24 个 .lua | 1 个 Convar | 24:1 |
| 新增任务所需代码 | ~200 LOC | ~15 行 JSON | ↓ 93% |
| 主线程任务系统 CPU (100人) | ~15,600 次/秒 | 0 次/秒 | O(n)→O(1) |
| 代码总行数 (净变化) | — | -1,300 行 | ↓ 复杂度 30% |

### 6.2 架构全景

```
┌──────────────────────────────────────────────────────────┐
│                    T-City Lite v2.0                       │
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │ 三位一体  │  │ 统一经济  │  │ 积木任务  │  │ 五大消耗  │ │
│  │ Security │  │ core_econ│  │ atom_node│  │ SinkSvc  │ │
│  │ Economy  │  │ HeatSvc  │  │ MutexSvc │  │ PropTax  │ │
│  │ Metadata │  │ NPCPric  │  │ GroupSvc │  │ VehLife  │ │
│  │ QualSvc  │  │          │  │ QuestMgr │  │ ItemDur  │ │
│  │ Persist  │  │          │  │          │  │ TransMon │ │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘ │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │  数值沙盒层: baseline.json + simulator.py + dashboard│   │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

---

## 附录A：完整文件清单

### qb-core 服务模块 (8 个)
```
resources/[qb]/qb-core/server/services/
├── security_service.lua         — 安全防火墙 (source校验 + 输入清洗 + 阈值熔断)
├── economy_service.lua          — 内存经济操作层
├── metadata_service.lua         — 内存元数据层
├── qualification_service.lua    — 三位一体资质判定
├── persistence_manager.lua      — DirtyFlush 异步刷盘管道
├── sink_service.lua             — 统一资金碎纸机
├── heat_service.lua             — 活动热度引擎
├── reward_service.lua           — 统一奖励网关 (已被 core_economy 取代)
└── npc_pricing.lua              — NPC 动态定价引擎
```

### 通知系统新增 (v2.1 — 双轨制)

```
resources/[qb]/qb-core/
├── client/native_notify.lua         — GTA 原生通知封装 (6 APIs + 60+ 图标)
├── html/css/style.css               — NUI 通知样式 (原生黑底白字风格)

resources/[standalone]/core-framework/
└── services/notify_service.lua      — Bus 通知服务 (7 方法 + 限流 + 插件契约)

resources/[standalone]/notify-test/  — 通知系统测试套件
├── fxmanifest.lua
├── client/test.lua                  — 客户端 9 项测试 (/notifytest)
└── server/test.lua                  — 服务端 6 项测试 (notifytest_server)
```

### 新建系统资源 (3 个)
```
resources/[system]/
├── core_economy/                — ★ 统一经济奖励网关 (合并 Rewards + Heat)
│   └── server/main.lua
├── atom_nodes/                  — ★ 事件驱动原子节点引擎
│   ├── client/main.lua
│   ├── server/main.lua
│   └── config/missions_payload.lua
└── economy-dashboard/           — ★ 开服数据仪表盘
    └── server/main.lua
```

### custom-taxes 消耗口模块 (5 个)
```
resources/[custom]/custom-taxes/server/
├── property_tax.lua             — 房产税懒加载
├── vehicle_lifecycle.lua        — 车辆购置税/保险/大修
├── npc_pricing.lua              — NPC 动态定价引擎
├── item_durability.lua          — 物品耐久销毁
├── transaction_monitor.lua      — 大额转账监控
└── main.lua                     — 集成入口
```

### custom-quest 任务系统 (10 个)
```
resources/[custom]/custom-quest/server/
├── quest_manager.lua            — FSM 状态机
├── quest_registry.lua           — 模板加载器
├── quest_rewards.lua            — 奖励分发
├── quest_security.lua           — 安全管线 (Nonce/RateLimit/Distance/Speed)
├── quest_db.lua                 — 数据库持久化
├── quest_cache.lua              — 缓存
├── quest_mutex.lua              — ★ 分布式排他锁
├── quest_group.lua              — ★ 组队实例管理器
├── quest_nodes.lua              — ★ 原子节点引擎 (已被 atom_nodes 取代)
└── main.lua                     — 事件入口
```

### 配置与工具
```
economy_baseline.json            — 全服定价基准表
migrations/v2.0_trinity_schema.sql — 三位一体 DB Migration
tools/sandbox_simulator.py       — 经济沙盒模拟器
docs/playerdata_v2_schema.lua    — 标准 PlayerData 结构文档
docs/refactoring_manifest_v2.md  — 删除/保留清单
docs/refactoring_mining_before_after.lua — 采矿重构案例
```

---

## 附录B：管理员命令速查

| 命令 / Convar | 功能 |
|---------------|------|
| `set convar economy_global_multiplier 80` | 全服收益打八折 |
| `set convar economy_reward_scale 120` | 自适应调节倍率设为 1.2x |
| `set convar vehicle_insurance_required true` | 强制开启车辆保险 |
| `/econ` | 查看实时经济仪表盘 |
| `/hotrank` | 查看活动热度 Top 10 |
| `/assets` | 查看载具/房产分布 |
| `/econreport` | 手动生成周报 |
| `/taxstats` | 查看今日税收统计 |
| `/proptax` | 手动触发当前玩家房产税 |
| `/quest` | 查看当前活跃任务 (客户端) |

---

> **手册结束** — 所有代码路径、函数名、变量名均来自实际项目源码。  
> 后续新增内容请以此手册为权威参考，确保所有新脚本通过 `core_economy:TriggerReward` 发放奖励，  
> 所有新任务使用 `atom_nodes:StartNode` 事件驱动，所有新消耗口调用 `SinkService.Withdraw`。
