# Module 3: 经济系统 (economy.cfg / banking.cfg / security.cfg)

> **CFG 文件**: `configs/modules/economy.cfg` `banking.cfg` `security.cfg`
> **资源数**: 4 个 (3 + 1 + 0★)
> ★ security.cfg 仅设置 Convars，不 ensure 资源

---

## 3.1 经济架构全景

```
                     ┌──────────────────────┐
                     │   core_economy        │
                     │   统一奖励网关        │
                     │   TriggerReward()     │
                     └──────┬───────────────┘
                            │ final = base × global × heat × bonus
          ┌─────────────────┼─────────────────┐
          ↓                 ↓                   ↓
    ┌──────────┐    ┌──────────────┐    ┌──────────┐
    │ AddMoney │    │  AddItem     │    │  AddRep  │
    │ (Economy │    │  (qb-inv)    │    │ (Player) │
    │ Service) │    └──────────────┘    └──────────┘
    └────┬─────┘
         │ DirtyFlush
         ↓
    ┌──────────┐
    │ players  │  ← 15min 定时刷盘
    │  (MySQL) │
    └──────────┘
```

---

## 3.2 core_economy — 统一经济奖励网关

**路径**: `resources/[system]/core_economy/`

全服只有一个奖励入口：`TriggerReward(source, activityId, baseReward, options?)`

### 三层系数

| 系数 | 来源 | 范围 | 自适应? |
|:---|:---|:---:|:---:|
| `global_mult` | Convar `economy_reward_scale` | 0.8–1.4 | ✅ 自适应微调 |
| `heat_coeff` | 活动频率追踪 | 0.5–1.5 | ✅ 自动衰减/提升 |
| `player_bonus` | 玩家 metadata `player_bonus` | 0.5–3.0 | ❌ 手动 VIP |

### 自适应宏观经济稳定器

```
每小时净流入 > $150K  →  通胀 → 自动降奖励倍率 0.05
每小时净流入 < $30K   →  冷清 → 自动升奖励倍率 0.05
```

Convars: `economy_high_inflation_net_per_hour` / `economy_low_activity_net_per_hour` / `economy_scale_step`

---

## 3.3 economy-dashboard — 实时经济遥测

**路径**: `resources/[system]/economy-dashboard/`

- 被动监听 `QBCore:Server:OnMoneyChange`
- 管理员命令：`/econ` `/hotrank` `/assets` `/econreport`
- 周报导出：`data/telemetry_weekly.json`
- 只读 — 不处理金钱，零安全风险

---

## 3.4 qb-banking — 银行系统

**路径**: `resources/[qb]/qb-banking/`

- 银行存款/取款
- 共享账户 (job/gang)
- ATM 卡支持
- **独立于 Bus** — 直接通过 `QBCore.Functions` 操作金钱

---

## 3.5 custom-economy (壳) + custom-taxes (虹吸)

- **custom-economy**: 已废弃 — `server/economy.lua` 已移除，被 core_economy 替代。配置通过 Convars 生效。
- **custom-taxes**: 经济虹吸管道 — 房产税、车辆周期费、NPC 定价、物品耐久度消耗、交易监控。

---

## 3.6 经济 Convars 全集

| Convar | 默认值 | 说明 |
|:---|:---|:---|
| `economy_reward_scale` | 1.0 | 全局奖励倍率 |
| `economy_price_scale` | 1.0 | 全局物价倍率 |
| `economy_sample_window_minutes` | 60 | 自适应统计窗口 |
| `economy_high_inflation_net_per_hour` | 150000 | 通胀阈值 |
| `economy_low_activity_net_per_hour` | 30000 | 冷清阈值 |
| `economy_scale_step` | 0.05 | 微调步长 |
| `economy_min_reward_scale` | 0.8 | 奖励下限 |
| `economy_max_reward_scale` | 1.4 | 奖励上限 |
| `economy_discord_webhook` | "" | 经济日志 Discord Webhook |

---

## 3.7 安全边界

| Convar | 默认值 | 说明 |
|:---|:---|:---|
| `security_rate_limit_ms` | 1000 | 敏感事件速率限制 |
| `security_max_add_money_limit` | 50000 | 单次最大加钱（熔断） |
| `security_max_add_item_limit` | 20 | 单次最大物品数 |
| `security_max_interaction_distance` | 10.0 | ⚠️ Convar 定义了但未在代码中执行 |
| `security_check_vehicle_spawn` | true | 车辆生成校验 |
| `security_check_weapon_give` | true | 武器赐予校验 |
| `security_discord_webhook` | "" | 安全警报 Discord Webhook |

---

## 3.8 已知问题

1. **两套 EconomyService**: `qb-core/server/services/economy_service.lua` (citizenid 凭证) 与 `core-framework/services/economy_service.lua` (source 凭证) — 需要合并为一套
2. **AddScaledMoney 实现**: 项目备忘录 `economy-refactor-memo` 标记为 P0 — `exports['custom-main']:AddScaledMoney()` 函数不存在，需实现全局统一出口
3. **经济倍率未生效**: 部分调用方直接调用 `Player.Functions.AddMoney` 绕过了 `economy_wage_multiplier` 缩放
4. **custom-phone 独立路径**: 不走 Bus 也不走 core_economy — 直接 `oxmysql` + `qb-core` exports
