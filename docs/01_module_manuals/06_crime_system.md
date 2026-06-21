# Module 6: 犯罪系统 (crime.cfg)

> **CFG 文件**: `configs/modules/crime.cfg`
> **资源数**: 5 个

---

## 6.1 资源清单

| 资源 | 功能 |
|:---|:---|
| qb-doorlock | 门锁管理系统 |
| qb-storerobbery | 商店抢劫 |
| qb-houserobbery | 房屋入室抢劫 |
| qb-drugs | 毒品包裹配送 + NPC 销售 |
| qb-pawnshop | 物品出售换钱（当铺） |

---

## 6.2 犯罪 Convars 控制面板

| Convar | 默认值 | 说明 |
|:---|:---|:---|
| `crime_enable` | true | 犯罪系统总开关 |
| `crime_enable_storerobbery` | true | 商店抢劫开关 |
| `crime_enable_houserobbery` | true | 房屋抢劫开关 |
| `crime_enable_drugs` | true | 毒品开关 |
| `crime_cooldown_storerobbery` | 1800 | 商店抢劫 CD (30min) |
| `crime_cooldown_houserobbery` | 1800 | 房屋抢劫 CD (30min) |
| `crime_cooldown_drugs` | 300 | 毒品 CD (5min) |
| `crime_min_police_storerobbery` | 2 | 最少在线警察数 (纵深防御) |
| `crime_min_police_houserobbery` | 2 | 最少在线警察数 |
| `crime_min_police_drugs` | 0 | 毒品最少警察 |
| `crime_min_police_launder` | 0 | 洗钱最少警察 |
| `crime_launder_rate` | 0.75 | 洗钱折旧率 (25% 手续费) |
| `crime_launder_min` | 1000 | 最低洗钱金额 |
| `crime_cooldown_launder` | 60 | 洗钱冷却 (60s) |

---

## 6.3 安全校验链

每个犯罪活动经过 `custom-crime` 的四层验证：

1. **警察人数检查** → 对应 `crime_min_police_*` Convar
2. **全局冷却** → 目标 (商店/房屋) 共享受害冷却
3. **玩家冷却** → 10s 最小间隔防刷
4. **家具唯一键锁** (房屋) → 防止并行利用

---

## 6.4 洗钱管道 (v0.5+)

| 参数 | 默认值 |
|:---|:---|
| 折旧率 | 25% (`crime_launder_rate = 0.75`) |
| 最低金额 | $1,000 |
| 冷却时间 | 60s |
| 多层洗钱 | L1-L4 不同折旧率 (MultiLaunderMoney) |

洗钱通过 `Bus.EconomyService.AddScaled` 发放，享受经济倍率缩放。

---

## 6.5 与 v0.7 组织系统的关系

| 旧系统 (qb-*) | 新系统 (v0.7) | 状态 |
|:---|:---|:---|
| qb-drugs (配送+NPC) | custom-cartel (完整毒品产业链) | **并行运行** — qb-drugs 仍启用 |
| qb-pawnshop (销赃) | custom-market (动态市场) | **并行运行** |
| — | custom-mining (矿业) | 新增 |
| — | custom-justice (司法) | 新增 |

⚠️ **并行风险**: qb-drugs 和 custom-cartel 同时运行可能导致双倍毒品产出。需协调禁用或统一定价。

---

## 6.6 维护要点

1. 所有犯罪 Convars 可通过 `set` 命令运行时调整（无需重启）
2. `crime_enable` 为总开关 — 设置为 false 禁用所有犯罪活动
3. `custom-crime` 的校验函数被 `custom-main` 完全复制 — 修改时需同步两处
4. 警察人数检查依赖 `QBCore.Functions.GetDutyCount('police')` — police.cfg 必须先加载
