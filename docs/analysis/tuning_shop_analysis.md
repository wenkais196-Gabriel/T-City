# T-City2 改装店玩法分析报告

> **日期**: 2026-06-05 | **版本**: v1.0 | **目标读者**: 开发团队 / AI 辅助规划

---

## 1. 现状速览

### 1.1 架构拓扑

```
qb-mechanicjob v3.1 (UI层)
  ├─ cosmetic.lua       — 外观/内饰改装 (31+11类)
  ├─ performance.lua    — 性能改装 6级
  ├─ tunerchip.lua      — ECU调校 NUI 40+参数
  ├─ repair.lua         — 修理/轮胎/清洁
  ├─ nitrous.lua        — 氮气安装+使用 (v3.1→custom-vehicles)
  └─ main.lua           — blip/target/喷漆/车间管理
        │
custom-vehicles v0.9 (数据层)
  ├─ vehicle_state.lua  — 统一车辆状态 (plate→state 内存缓存)
  ├─ key_manager.lua    — O(1) 钥匙查表
  ├─ vehicle_degradation.lua — 里程/磨损/引擎损耗
  └─ compat.lua         — qb-vehiclekeys 兼容桥
        │
qb-core (基座)
  ├─ shared/items.lua   — 17个车辆物品定义
  └─ client/functions.lua — GetVehicleProperties / SetVehicleProperties
```

### 1.2 5个车间

| ID | 名称 | 坐标 | 所属组织 |
|:---|:---|:---|:---|
| mechanic | LS Customs 市区总店 | -346, -131, 39 | lscustoms |
| mechanic2 | LS Customs Harmony | 1175, 2639, 38 | lscustoms |
| mechanic3 | LS Customs 机场 | -1155, -2006, 13 | lscustoms |
| bennys | Benny's Motorworks | -212, -1325, 31 | bennys |
| beeker | Beeker's Garage | 110, 6627, 32 | beekers |

### 1.3 17个车辆物品

```
性能: veh_armor / veh_brakes / veh_engine / veh_suspension / veh_transmission / veh_turbo
外观: veh_interior / veh_exterior / veh_wheels / veh_neons / veh_xenons / veh_tint / veh_plates
工具: nitrous / repairkit / advancedrepairkit / cleaningkit / tunerlaptop / tirerepairkit / veh_toolbox
```

---

## 2. 关键发现 — 缺失清单

### 🔴 致命缺失

| # | 问题 | 证据 | 影响 |
|:---|:---|:---|:---|
| 1 | **改装完全免费** | `cosmetic.lua` / `performance.lua` / `server/main.lua` 中搜索 `AddMoney\|RemoveMoney\|payment\|charge\|price\|bill` — **0 matches** | 经济循环断裂，改装店无收入 |
| 2 | **无机修工佣金** | 同上，无 commission 逻辑 | 机修工只有固定工资，无绩效激励 |
| 3 | **无发票系统** | `qb-mechanicjob/server/` 仅 `main.lua`，无 billing 模块 | 无交易记录，无审计追踪 |

### 🟠 中等缺失

| # | 问题 | 说明 |
|:---|:---|:---|
| 4 | 外观改装无材料消耗 | 仅性能零件走物品消耗，外观改装免费装 |
| 5 | 无技师等级/技能树 | 有 job.grade 但改装能力不随等级变化 |
| 6 | 无车辆检测流程 | 缺 OBD诊断/胎纹检测/压缩测试等 RP 深度 |

### 🟡 轻度缺失

| # | 问题 | 说明 |
|:---|:---|:---|
| 7 | 无非法改装/Chop Shop | 缺地下改装+黑市零件+盗车拆解 |
| 8 | 无玩家自有改装店 | 仅限职业机修工，非 sandbox 经济 |
| 9 | 无改装前后性能对比 | 安装零件后无数据变化展示 |
| 10 | 无引擎更换 | 缺 engine swap 跨车型移植 |
| 11 | 无悬挂姿态独立调节 | tunerchip 有全局参数但无 camber/offset |
| 12 | 无营收仪表盘 | 老板看不到各车间收入 |

---

## 3. 社区生态调研

### 3.1 主流脚本对比

| 脚本 | 类型 | 价格 | 亮点 |
|:---|:---|:---|:---|
| popcornrp-customs | 免费开源 | $0 | ox_lib驱动、拖拽摄像头、框架无关、社区活跃(83★) |
| qbx_customs | 免费开源 | $0 | Qbox官方fork、持续维护 |
| JG Mechanic | 免费 | $0 | 平板操作、保养、stance、自有店 |
| PC Mechanic | 付费 | $30-50 | Vue.js UI、商业管理、OBD诊断、5级权限 |
| VMS Tuning 2.0 | 付费 | $20-40 | 零件安装可视化、多语言 |
| Argus Customs | 付费 | $15-25 | 完整改装+喷漆、双框架 |

### 3.2 行业趋势 (2024-2025)

```
1. UI 现代化       → Vue.js/React NUI 替代原生 qb-menu
2. 商业化管理      → 零件成本 + 工时费 + 佣金 三级定价
3. RP 深度化       → OBD诊断 → 检测 → 维修 → 保养 完整闭环
4. 去中心化        → 玩家可购买/经营自有改装店
5. 物理精细化      → stance / camber / track width / drivetrain swap
6. 数据驱动        → 营收仪表盘、客户评价、改装热力图
7. 生态集成        → 采矿→冶炼→零件→改装→竞技 产业链
```

---

## 4. 融入 T-City2 锐评架构方案

### 4.1 定位

```
        采矿/回收                    竞技/非法
        (原材料)                    (性能验证)
           │                            ▲
           ▼                            │
       冶炼/零件制造 ──────→ 改装店 ──────┘
        (加工增值)          (核心枢纽)
           │                    │
           ▼                    ▼
       合法经营              非法改装
      (执照/税收)          (黑市零件)
```

**改装店 = 车辆经济中枢**，连接上游供应链和下游验证场景。

### 4.2 四层架构

```
Layer 4: 玩法层
  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐
  │ 合法改装  │ │ 性能调校  │ │ 非法改装  │ │ 赛车竞技   │
  │ LS Customs│ │ ECU Tune │ │Chop Shop │ │ Street Race│
  └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ └─────┬──────┘
        │              │              │              │
Layer 3: 服务层 (新增 services/mechanic_service.lua)
  ┌──────────────────────────────────────────────────┐
  │ InstallPart() / CalculatePrice() / CreateInvoice()│
  │ GetShopRevenue() / ValidateCompatibility()        │
  └──────────────────────────────────────────────────┘
        │
Layer 2: 经济层 (economy_service.lua + tax/sink)
  ┌──────────────────────────────────────────────────┐
  │ ProcessMechanicPayment() / DistributeCommission() │
  │ LogTransaction() / 大额审计 Webhook               │
  └──────────────────────────────────────────────────┘
        │
Layer 1: 数据层 (DirtyFlush Pipeline + 内存缓存)
  ┌──────────────────────────────────────────────────┐
  │ player_vehicles / mechanic_shops / transactions   │
  └──────────────────────────────────────────────────┘
```

### 4.3 核心模块: mechanic_service.lua

```lua
-- services/mechanic_service.lua 设计契约

---@class MechanicService
local MechanicService = {
    --- 安装改装零件
    ---@param plate string 车牌号
    ---@param modType integer 改装类型 (11=engine, 12=brakes, ...)
    ---@param modIndex integer 改装等级 (-1=stock, 0-N)
    ---@param mechanicSrc integer 机修工 source
    ---@param paymentMethod string "cash"|"bank"|"dirty"
    ---@return {success:boolean, invoice:table, newStats:table}
    InstallPart = function(plate, modType, modIndex, mechanicSrc, paymentMethod) end,

    --- 计价引擎
    ---@param partType string "engine"|"brakes"|"spoiler"|...
    ---@param mechanicLevel integer 技师等级 1-5
    ---@param shopType string "legal"|"illegal"
    ---@return {partCost:number, laborCost:number, tax:number, total:number}
    CalculatePrice = function(partType, mechanicLevel, shopType) end,

    --- 生成发票
    ---@param customerSrc integer
    ---@param mechanicSrc integer
    ---@param items table[] 改装项目列表
    ---@param totalAmount number
    ---@return invoiceId string
    CreateInvoice = function(customerSrc, mechanicSrc, items, totalAmount) end,
}
```

### 4.4 定价模型

```
外观件 = 零件成本(物品消耗) + 工时费(技师等级×$50/级) + 车间运营费(15%)
性能件 = 零件成本 + 工时费(技师等级×$100/级) + 车间运营费(15%)
ECU调校 = 基础费$500 + 参数调整数量×$200
喷漆    = 普通$200 / 金属$500 / 变色龙$2000 / HEX自定义$1000
维修    = 损坏程度% × 车辆原价×0.1%

佣金分配 = 工时费×70%归机修工, 车间运营费归店铺账户, 税收归政府sink
```

### 4.5 安全设计

```lua
-- 事件防火墙: mechanic:charge
RegisterNetEvent('mechanic:charge', function(plate, amount, items)
    local src = source
    -- ① source 存在性校验
    -- ② 机修工 job 校验 (type=='mechanic')
    -- ③ 金额熔断 (单次≤$500k, 日累计≤$2M)
    -- ④ 车牌有效性校验 (plate→车辆状态必须存在)
    -- ⑤ 距离校验 (机修工距车辆≤10m)
    -- ⑥ 审计日志 (大额>$100k → Discord Webhook)
    -- ⑦ economy_service 统一扣款
    -- ⑧ DirtyFlush.MarkDirty(citizenid, 'vehicle')
end)
```

### 4.6 插件契约

```lua
-- 第三方改装模组接入标准接口
exports['tcity-mechanic']:RegisterShop({
    id = 'custom_underground',
    label = '地下改装厂',
    type = 'illegal',
    location = vector3(...),
    allowedMods = { 'performance', 'cosmetic', 'nos' },
    priceMultiplier = 1.5,
    heatGeneration = 0.3,
})

local result = exports['tcity-mechanic']:InstallPart(plate, {
    modType = 11, modIndex = 3,
    mechanic = source,
    paymentMethod = 'dirty',
})
-- → { success, invoice: { id, amount, tax }, newStats: {...} }
```

---

## 5. 实施路线图

### P0 — 经济闭环 (本周, ~200 LOC)

| 文件 | 动作 | 内容 |
|:---|:---|:---|
| `services/mechanic_service.lua` | **新建** | 计价引擎 + 发票生成 + InstallPart |
| `server/billing.lua` | **新建** | 佣金分配 + 营收记录 |
| `server/main.lua` | 修改 | 注册 `mechanic:charge` 事件 + 安全校验 |
| `client/cosmetic.lua` | 修改 | 外观改装后 `TriggerServerEvent('mechanic:charge', ...)` |
| `client/performance.lua` | 修改 | 性能安装后扣款 |
| `config/config.lua` | 修改 | 新增 `Config.Pricing` 定价表 |

### P1 — RP 深度 (两周, ~500 LOC)

| 文件 | 动作 | 内容 |
|:---|:---|:---|
| `client/inspection.lua` | **新建** | OBD诊断 → 部件健康 → 检测报告 |
| `config/skills.lua` | **新建** | 技师等级表 (学徒→大师, 5级) |
| `client/performance.lua` | 修改 | 改装前后性能对比面板 |
| `services/mechanic_service.lua` | 修改 | 技能等级检查 + 解锁逻辑 |
| `client/engine_swap.lua` | **新建** | 引擎更换 (大师级解锁) |
| `client/stance.lua` | **新建** | camber/track width/height 独立调节 |

### P2 — 非法玩法 (一月, ~800 LOC)

| 文件 | 动作 | 内容 |
|:---|:---|:---|
| `server/chopshop.lua` | **新建** | 盗车拆解 → 黑市零件入库 |
| `config/illegal.lua` | **新建** | 黑市零件定义 (性能+15%, 警察识别率30%) |
| `server/heat.lua` | **新建** | 热度系统 (改装店+个人) |
| 对接 `custom-crime` | 修改 | 非法改装收入 → 洗钱管道 |
| 对接街头赛车 | 修改 | 改装后赛车 → 验证性能 → 声望 |

### P3 — 玩家经营 (远期, ~1500 LOC)

| 功能 | 说明 |
|:---|:---|
| 玩家自有改装店 | 购买/租赁店铺, 自定义名称+定价 |
| 营收仪表盘 | Web Dashboard 集成 |
| 技师招聘 | 雇佣其他玩家为机修工 |
| 供应链管理 | 零件采购/库存/定价 三级管理 |

---

## 6. 评分卡

| 维度 | 当前 | 目标 | 差距 |
|:---|:---:|:---:|:---|
| 改装功能完整度 | 9/10 | 10/10 | +引擎更换、悬挂姿态 |
| 经济系统集成 | 1/10 | 9/10 | +收费/佣金/税收/审计 |
| 安全防护 | 3/10 | 9/10 | +source校验/金额熔断/日限 |
| RP 深度 | 5/10 | 9/10 | +检测流程/技师成长/非法线 |
| 代码架构 | 7/10 | 9/10 | +mechanic_service/Bus注册/Plugin Contract |
| 扩展性 | 3/10 | 9/10 | +第三方接入标准接口 |

---

## 7. 关键代码路径索引

```
T-CityLite.base/resources/
├── [qb]/qb-mechanicjob/           ← 改装店 UI + 逻辑 (v3.1)
│   ├── config/config.lua          ← 5车间 + 定价(缺失)
│   ├── config/const.lua           ← 改装常量 (色板/轮毂/类别)
│   ├── client/cosmetic.lua        ← 外观/内饰改装 (725行, 0处收费)
│   ├── client/performance.lua     ← 性能改装 (197行, 0处收费)
│   ├── client/tunerchip.lua       ← ECU调校 NUI (162行)
│   ├── client/repair.lua          ← 修理/保养
│   ├── client/nitrous.lua         ← 氮气 (v3.1→custom-vehicles)
│   ├── client/main.lua            ← 入口/blip/target
│   └── server/main.lua            ← 服务端 (物品注册/喷漆/指令)
├── [custom]/custom-vehicles/      ← 车辆底层系统 (v0.9)
│   ├── server/vehicle_state.lua   ← 统一车辆状态管理
│   ├── server/key_manager.lua     ← O(1) 钥匙管理
│   ├── server/compat.lua          ← qb-vehiclekeys 兼容
│   ├── client/vehicle_degradation.lua ← 里程/磨损
│   └── client/vehicle_nitrous.lua ← 氮气逻辑
├── [qb]/qb-core/
│   ├── shared/items.lua:301-326   ← 17个车辆物品定义
│   └── client/functions.lua:405-560 ← 车辆属性序列化
└── configs/modules/vehicles.cfg   ← 启动顺序
```

---

*本报告由 Reasonix Code 对 T-CityLite.base 项目进行全局扫描 + Google 社区调研后生成。所有代码引用均已通过 search_content 验证。*
