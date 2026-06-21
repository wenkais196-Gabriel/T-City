# core_economy + economy-dashboard — 经济网关与仪表盘

> **路径**: `resources/[system]/core_economy/` `economy-dashboard/`
> **状态**: ✅ BOTH ENABLED | **CFG 模块**: economy.cfg

---

## core_economy — 统一经济奖励网关

### 核心 API

| Export | 描述 |
|:---|:---|
| `TriggerReward(source, activityId, baseReward, options?)` | **全服唯一奖励入口** |
| `PreviewReward(source, activityId, baseReward)` | 不发放，仅预览 |
| `GetGlobalMultiplier()` | 当前全局倍率 |
| `GetActivityHeat(activityId)` | 活动热度 (0.5-1.5) |
| `ResetAllHeat()` | 重置所有热度（管理员） |

### 奖励计算公式

```
final = floor(baseReward × global_mult × heat_coeff × player_bonus)
```

| 系数 | 来源 | 范围 |
|:---|:---|:---:|
| `global_mult` | Convar `economy_reward_scale` | 0.8–1.4 |
| `heat_coeff` | 活动频率追踪：高频→降 0.5，冷门→升 1.5 | 0.5–1.5 |
| `player_bonus` | 玩家 metadata `player_bonus` (VIP/buff) | 0.5–3.0 |

### 分发路径
- **金钱** → `qb-core` EconomyService.AddMoney → DirtyFlush
- **物品** → `exports['qb-inventory']:AddItem`
- **声望** → `Player.Functions.AddRep`

### 安全 ✅
- 无 `RegisterNetEvent` — 纯导出 + Bus API
- `source` 参数校验玩家存在
- `options.moneytype` 缺少白名单校验 — 轻微风险

---

## economy-dashboard — 实时经济遥测仪表盘

### 功能
- 被动监听 `QBCore:Server:OnMoneyChange` 采集全服资金流
- 追踪 KPI：总流入/流出/虹吸/活动热度/资产分布
- 管理员命令：`/econ`, `/hotrank`, `/assets`, `/econreport`

### 数据库 (只读)
| 查询 | 用途 |
|:---|:---|
| `SELECT COUNT(*) FROM player_vehicles` | 车辆统计 |
| `SELECT COUNT(*) FROM player_houses WHERE citizenid IS NOT NULL` | 房屋统计 |
| `SaveResourceFile` → `data/telemetry_weekly.json` | 周报导出 |

### 安全 ✅
纯监控 — 不处理金钱，无 RegisterNetEvent。

---

## custom-economy — 已废弃的壳

**路径**: `resources/[custom]/custom-economy/`

`fxmanifest.lua` 明确声明：`server/economy.lua removed — replaced by core_economy`。该资源仅作为配置占位符 (`config.lua` + `economy_state.json`)，无 Lua 代码执行。

配置通过 Convars (`economy_reward_scale`, `economy_price_scale` 等) 生效。

---

## custom-taxes — 经济虹吸系统

**路径**: `resources/[custom]/custom-taxes/` | **依赖**: qb-core, oxmysql

| 虹吸类型 | 文件 | 机制 |
|:---|:---|:---|
| 房产税 | `server/property_tax.lua` | 定时从房主银行扣除 |
| 车辆生命周期税 | — | 注册/年检费用 |
| NPC 定价 | — | 商店价格调整 |
| 物品耐久度 | — | 修理/消耗成本 |
| 交易监控 | — | 大额交易审计 |
