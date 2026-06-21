# 🏙️ T-City 宏观经济模拟层 — 施工蓝图

> **版本**: v1.0  
> **日期**: 2026-06-18  
> **状态**: 设计完成，待 Phase 3 施工  
> **前置依赖**: `economy-dashboard` (已运行), `core_economy` (已运行), `core-framework/bus.lua` (已运行)

---

## 总览

四个子系统按依赖顺序排列。每个子系统都是**独立的 `[system]/` 资源**，通过 Bus 暴露接口，通过监听现有事件采集数据，**零侵入现有代码**。

```
施工顺序:
  1️⃣ SupplyChain Tracker    (产业链追踪器)     — 无依赖
  2️⃣ PriceEngine            (价格弹性引擎)     — 依赖 1️⃣
  3️⃣ StrataAnalyzer         (阶层流动分析器)   — 依赖 1️⃣ 2️⃣
  4️⃣ PredictionEngine       (预测引擎)         — 依赖 1️⃣ 2️⃣ 3️⃣
```

每个子系统满足 **T-City Lite 四大铁律**。以下逐项展开。

---

# 1️⃣ SupplyChain Tracker — 产业链追踪器

## 1.1 概述

追踪全服 320 种物品的生产与消费流，构建投入产出矩阵，检测供应链瓶颈。

## 1.2 文件清单

```
resources/[system]/supplychain-tracker/
├── fxmanifest.lua              # 资源声明
├── config/
│   ├── items_to_track.lua      # 物品分层 (Tier 1/2/3/4)
│   ├── recipes.lua             # 配方矩阵 (从现有 config 提取)
│   └── sectors.lua             # 活动→部门映射
├── server/
│   ├── main.lua                # 启动入口 + Bus 注册
│   ├── tracker.lua             # 核心追踪器 (环形缓冲区)
│   ├── event_listeners.lua     # 事件监听 (零侵入)
│   ├── bottleneck_detector.lua # 瓶颈检测算法
│   ├── value_added.lua         # 价值链增值分析
│   ├── sector_flow.lua         # 部门间资金流矩阵
│   └── commands.lua            # /supplychain, /bottleneck
└── data/
    └── state.json              # 持久化状态 (重启不丢失)
```

**总计**: 10 文件, ~400 行 Lua

## 1.3 模块注册

```cfg
# configs/modules/economy.cfg (追加)
ensure supplychain-tracker
```

加载顺序: `oxmysql → qb-core → core_economy → economy-dashboard → supplychain-tracker`

## 1.4 fxmanifest.lua

```lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'T-City Lite'
description 'Supply Chain Tracker — 全服物品生产/消费流追踪与瓶颈检测'
version '1.0.0'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config/items_to_track.lua',
    'config/recipes.lua',
    'config/sectors.lua',
    'server/tracker.lua',
    'server/event_listeners.lua',
    'server/bottleneck_detector.lua',
    'server/value_added.lua',
    'server/sector_flow.lua',
    'server/commands.lua',
    'server/main.lua',
}

dependencies {
    'qb-core',
    'oxmysql',
    'core-framework',
}
```

## 1.5 Bus 注册接口

```lua
-- server/main.lua
local SupplyChainTracker = require 'server.tracker'  -- or dofile pattern

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    Bus.RegisterService('supplychain', {
        -- 查询
        GetItemFlow        = SupplyChainTracker.GetItemFlow,
        GetProductionChain = SupplyChainTracker.GetProductionChain,
        GetSectorFlow      = SupplyChainTracker.GetSectorFlow,

        -- 分析
        GetBottlenecks     = BottleneckDetector.Detect,
        GetValueAddedRank  = ValueAdded.GetTop,
        GetSectorMatrix    = SectorFlow.GetMatrix,

        -- 快照
        TakeSnapshot       = SupplyChainTracker.TakeSnapshot,
    })

    print('[supplychain-tracker] ✅ 注册到 Bus.supplychain')
end)
```

## 1.6 四大原则合规清单

| 原则 | 合规措施 |
|:---|:---|
| **模块化** | 独立 `[system]/` 资源, 通过 Bus 暴露, `configs/modules/economy.cfg` 注册 |
| **高性能** | 环形缓冲区 O(1) 写入; 瓶颈检测每小时运行一次 (CreateThread + Wait); 无 Tick 循环; 零 DB 写入 (仅内存) |
| **安全** | 纯事件监听, 不处理客户端数据; 不修改玩家余额; 内部数据不外泄 |
| **可拓展** | Bus 接口标准化 (GetItemFlow/GetBottlenecks); 新生产系统只需触发同名事件即可自动纳入追踪 |

## 1.7 数据结构

```lua
-- tracker.lua 核心状态
local State = {
    items = {},  -- { [itemName] = { produced24h=0, consumed24h=0, hourlySlots={...} } }
    recipes = {}, -- 从 config/recipes.lua 加载
    bottlenecks = {},
    lastBottleneckCheck = 0,
}
```

## 1.8 事件监听清单

| 事件 | 来源资源 | 采集内容 |
|:---|:---|:---|
| `custom-mining:server:OreMined` | custom-mining | 矿石产出 |
| `custom-mining:server:SmeltComplete` | custom-mining | 冶炼产出 + 原材料消耗 |
| `qb-crafting:server:CraftItem` | qb-crafting | 工作台产出 + 材料消耗 |
| `custom-cartel:server:DrugLabComplete` | custom-cartel | 毒品产出 + 化学品消耗 |
| `qb-weed:server:HarvestPlant` | qb-weed | 大麻收获 |
| `qb-pawnshop:server:MeltComplete` | qb-pawnshop | 熔炼产出 |
| `qb-shops:server:SellToPlayer` | qb-shops | 商店售出 = 消费 |
| `qb-shops:server:BuyFromPlayer` | qb-shops | 商店回收 = 供给回流 |
| `QBCore:Server:UseItem` | qb-core | 消耗品使用 |
| `QBCore:Server:OnMoneyChange` | qb-core | 部门间资金流 |

---

# 2️⃣ PriceEngine — 价格弹性引擎

## 2.1 概述

基于 24h 供需窗口，使用幂律弹性公式动态调整物品价格。商店通过 Bus 拉取实时价格。

## 2.2 文件清单

```
resources/[system]/price-engine/
├── fxmanifest.lua
├── config/
│   └── parameters.lua          # ε, α, floor, ceiling, 死区, 周期
├── server/
│   ├── main.lua                # 启动 + Bus 注册
│   ├── engine.lua              # 核心计算引擎
│   ├── price_store.lua         # 价格存储 + 窗口管理
│   ├── recalculate_loop.lua    # 定时重算 (每 6h)
│   ├── m2_link.lua             # M2 联动 (贵金属)
│   ├── anomaly_detector.lua    # 异常检测 (跳变/极端比)
│   └── commands.lua            # /price, /pricetrend, /pricealert
└── data/
    └── price_history.json      # 30 天价格历史
```

**总计**: 8 文件, ~350 行 Lua

## 2.3 模块注册

```cfg
# configs/modules/economy.cfg (追加)
ensure price-engine
```

依赖: `supplychain-tracker`

## 2.4 Bus 注册接口

```lua
Bus.RegisterService('price', {
    GetPrice         = PriceStore.Get,        -- 单物品价格
    GetMultiplier    = PriceStore.GetMultiplier,
    GetAllPrices     = PriceStore.GetAll,     -- 全量价格表
    GetPriceHistory  = PriceStore.GetHistory, -- 历史曲线
    GetHotItems      = AnomalyDetector.GetHotItems,
    RecalculateNow   = Engine.RecalculateAll, -- 手动触发
})
```

## 2.5 四大原则合规

| 原则 | 合规措施 |
|:---|:---|
| **模块化** | 独立资源; Bus 暴露; 商店通过 `Bus.price.GetPrice(itemName)` 拉取 |
| **高性能** | 6h 间隔重算 (非 Tick); EMA 平滑避免计算尖峰; 价格缓存在 `_G.Bus.price._cache` O(1) 查询 |
| **安全** | 纯内存计算; 不修改 DB; 不开放客户端写入接口; 管理命令 source 校验 |
| **可拓展** | 物品分层可配置 (config/parameters.lua); `itemOverrides` 支持单物品自定义弹性 |

## 2.6 商店集成 (对 qb-shops 的 3 行改动)

```lua
-- qb-shops 价格查询处 (唯一侵入点)
local function getItemPrice(itemName)
    local basePrice = Config.Products[itemName].price
    local dynamicPrice = nil
    if _G.Bus and _G.Bus.price then
        dynamicPrice = _G.Bus.price.GetPrice(itemName)
    end
    return dynamicPrice or basePrice  -- fallback: 引擎挂了也不影响商店
end
```

---

# 3️⃣ StrataAnalyzer — 阶层流动分析器

## 3.1 概述

按净资产将玩家分为 Poor/Working/Middle/Elite 四层，每周追踪流动矩阵，计算 SMI 指数，检测贫困陷阱。

## 3.2 文件清单

```
resources/[system]/strata-analyzer/
├── fxmanifest.lua
├── config/
│   └── strata_config.lua       # 阶层门槛, 资产估值参数
├── server/
│   ├── main.lua                # 启动 + Bus 注册
│   ├── strata_calculator.lua   # 净资产计算 + 阶层判定
│   ├── weekly_snapshot.lua     # 每周快照 + 流动矩阵
│   ├── smi_calculator.lua      # SMI 指数计算
│   ├── poverty_trap.lua        # 贫困陷阱检测
│   ├── consumption_profile.lua # 阶层消费结构 (供 Prediction)
│   ├── commands.lua            # /strata, /strata detail, /poverty
│   └── trend_writer.lua        # 趋势持久化
└── data/
    ├── snapshots/               # week_023.json ...
    └── trends/
        └── strata_trend.json    # 聚合趋势
```

**总计**: 11 文件, ~450 行 Lua

## 3.3 模块注册

```cfg
# configs/modules/economy.cfg (追加)
ensure strata-analyzer
```

依赖: `supplychain-tracker`, `price-engine`

## 3.4 Bus 注册接口

```lua
Bus.RegisterService('strata', {
    GetDistribution   = StrataCalculator.GetDistribution,
    GetPlayerStrata   = StrataCalculator.GetPlayerStrata,
    GetTransitionMatrix = WeeklySnapshot.GetMatrix,
    GetSMI            = SMICalculator.Get,
    GetPovertyTraps   = PovertyTrap.Detect,
    GetConsumptionProfile = ConsumptionProfile.Get,  -- 供 Prediction 使用
    TakeSnapshot      = WeeklySnapshot.Take,
})
```

## 3.5 四大原则合规

| 原则 | 合规措施 |
|:---|:---|
| **模块化** | 独立资源; Bus 暴露; 数据独立存储 |
| **高性能** | 每周一次快照 + 计算 (CreateThread + 周日 03:00); 净资产计算走内存 `Player.PlayerData.money`, 房产/载具估值走异步 DB (不阻塞) |
| **安全** | 个人资产数据仅管理员可查 (`/strata detail` 需要 source 校验); 公开发布的只有聚合数据 |
| **可拓展** | 阶层门槛跟随 M2 自动调整; 消费结构可配置; 支持手动调整阶层定义 |

## 3.6 数据库查询 (异步)

```lua
-- 房产估值 (异步, 每周一次)
MySQL.Async.fetchAll([[
    SELECT ph.citizenid, ph.house, hl.price, hl.tier
    FROM player_houses ph
    LEFT JOIN houselocations hl ON ph.house = hl.name
    WHERE ph.citizenid IS NOT NULL
]], {}, function(results) ... end)

-- 载具估值 (异步)
MySQL.Async.fetchAll([[
    SELECT pv.citizenid, pv.vehicle, pv.drivingdistance, pv.status
    FROM player_vehicles pv
    WHERE pv.citizenid IS NOT NULL
]], {}, function(results) ... end)
```

---

# 4️⃣ PredictionEngine — 预测引擎

## 4.1 概述

拍摄服务器经济快照 → 注入干预 → 在沙盒中模拟 N 周期 → 生成预测报告对比基线。

## 4.2 文件清单

```
resources/[system]/prediction-engine/
├── fxmanifest.lua
├── config/
│   └── prediction_config.lua   # 蒙特卡洛参数, 行为反馈因子
├── server/
│   ├── main.lua                # 启动 + Bus 注册
│   ├── snapshot.lua            # 快照拍摄 (聚合 Price + SupplyChain + Strata)
│   ├── sandbox.lua             # 沙盒状态机
│   ├── tick_loop.lua           # tick() 核心循环
│   ├── intervention.lua        # 干预 DSL 解析器
│   ├── production_sim.lua      # 生产模拟
│   ├── consumption_sim.lua     # 消费模拟 (复用 Strata 的消费结构)
│   ├── behavioral_feedback.lua # 行为反馈模型
│   ├── monte_carlo.lua         # 蒙特卡洛采样
│   ├── report_generator.lua    # 报告生成
│   ├── comparator.lua          # 多场景并排对比
│   └── commands.lua            # /predict, /predict compare
└── data/
    └── scenarios/              # 预定义场景 JSON
```

**总计**: 14 文件, ~500 行 Lua

## 4.3 模块注册

```cfg
# configs/modules/economy.cfg (追加)
ensure prediction-engine
```

依赖: `supplychain-tracker`, `price-engine`, `strata-analyzer`

## 4.4 Bus 注册接口

```lua
Bus.RegisterService('prediction', {
    RunScenario       = Sandbox.Run,        -- 运行单个场景
    CompareScenarios  = Comparator.Run,     -- 并排对比多个场景
    GetSavedScenarios = ScenarioStore.List,
    SaveScenario      = ScenarioStore.Save,
    DeleteScenario    = ScenarioStore.Delete,
})
```

## 4.5 四大原则合规

| 原则 | 合规措施 |
|:---|:---|
| **模块化** | 独立资源; Bus 暴露; 场景可 JSON 文件预定义 |
| **高性能** | 沙盒模拟在内存中运行, 不触碰真实 DB; 每次预测限时 5 秒 (超时熔断); 无 Tick 循环, 仅在管理员调用时运行 |
| **安全** | 仅管理员可用; source 校验; 干预参数做范围校验 (倍率 ±50% 上限); 不修改任何真实数据 |
| **可拓展** | 干预 DSL 可扩展新类型; 行为反馈模型可配置; 场景可 JSON 导入导出 |

## 4.6 熔断保护

```lua
-- sandbox.lua
local MAX_TICKS = 28
local MAX_WALL_TIME_MS = 5000  -- 5 秒熔断

function Sandbox.Run(intervention, ticks)
    ticks = math.min(ticks, MAX_TICKS)
    local startTime = os.mtime()  -- 毫秒

    for t = 1, ticks do
        if os.mtime() - startTime > MAX_WALL_TIME_MS then
            return nil, ('熔断: 预测超过 %dms, 在第 %d/%d tick 中止'):format(
                MAX_WALL_TIME_MS, t, ticks)
        end
        Tick(sandbox, intervention)
    end

    return GenerateReport(sandbox)
end
```

---

# 📋 施工顺序与检查点

```
Phase 3-经济模拟 (4 个子系统, 总计 43 文件, ~1700 行 Lua)

Step 1: supplychain-tracker          [2-3 天]  ← 先做这个
  ├── 验证: /supplychain 命令可显示物品流
  ├── 验证: /bottleneck 可检测 metalscrap 缺口
  └── 交付: tracker.lua + event_listeners.lua

Step 2: price-engine                 [2-3 天]  ← 依赖 Step 1
  ├── 验证: /price iron_ore 显示动态价
  ├── 验证: 商店集成后物价随供需变化
  └── 交付: engine.lua + qb-shops 3行改动

Step 3: strata-analyzer              [2-3 天]  ← 依赖 Step 1+2
  ├── 验证: /strata 显示阶层分布
  ├── 验证: 周日自动生成快照
  └── 交付: strata_calculator.lua + weekly_snapshot.lua

Step 4: prediction-engine            [3-4 天]  ← 依赖 Step 1+2+3
  ├── 验证: /predict mining_buff 产出预测报告
  ├── 验证: /predict compare 并排对比
  └── 交付: sandbox.lua + report_generator.lua

总计: 9-13 天 (单人全职)
```

---

# 🔒 向后兼容保证

所有四个子系统:

- **不修改任何现有文件的业务逻辑** (唯一例外: qb-shops 的 3 行 fallback 价格查询)
- **通过监听已有事件工作**, 不发送新事件
- **Bus 注册失败不回滚** — 所有 `Bus.RegisterService` 包裹在 `if Bus and Bus.RegisterService then` 中
- **子系统挂了不影响核心游戏** — 商店 fallback 到静态价, Sink/奖励照常运行
- **兼容现有 economy-dashboard** — 不重复采集, 复用其事件监听逻辑

---

# 📊 预期效果

| 指标 | 当前 | 模拟层上线后 |
|:---|:---|:---|
| 管理员经济决策方式 | 看 `/econ` 数字, 凭经验手动调倍率 | 看瓶颈预警 + 运行 `/predict` 模拟 → 数据驱动决策 |
| 物价 | 静态 (items.lua) | 动态 (供需驱动, 24h 窗口, 防震荡) |
| 社会结构可见性 | 无 | 阶层金字塔 + 流动矩阵 + SMI 指数 |
| 新人留存问题 | 感知到但无法量化 | 贫困陷阱自动检测 + 新手阶层分布 |
| 经济平衡周期 | 数周 (发现问题 → 手动调整 → 观察) | 数分钟 (运行 `/predict compare` 立即看到 N 天后的效果) |
