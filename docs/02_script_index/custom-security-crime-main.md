# custom-security + custom-crime + custom-main — 安全与犯罪三件套

> **路径**: `resources/[custom]/custom-security/` `custom-crime/` `custom-main/`
> **状态**: ✅ ALL ENABLED | **CFG 模块**: custom.cfg (+ security.cfg for Convars)

---

## custom-security — 安全防火墙

**文件**: `server/security.lua`

### 速率限制器 (L1 层)
- `CheckRateLimit(source, action, cooldownMs)` — 按 source 的每操作冷却
- `playerDropped` 清理

### 回调劫持 (L2 层)
- **attemptPurchase**: 速率限制 `security_rate_limit_ms` (默认 1000ms)
- **SpawnVehicle / CreateVehicle**: 职业白名单 (police/ambulance/taxi/mechanic/tow/garbage) + 执勤检查 + 5s 冷却 + Discord 警报

### 事件审计 (L3 层)
- `QBCore:Server:OnMoneyChange` — 标记 > MaxAddMoneyLimit (默认 $50k)
- `QBCore:Server:OnGangUpdate` — 帮派变更审计
- `QBCore:Server:OnJobUpdate` — 职业变更审计

### 无 RegisterNetEvent
custom-security 的服务器逻辑全部通过 `AddEventHandler` 钩入框架事件 — 不暴露新网络端点。

---

## custom-crime — 犯罪校验库

**文件**: `server/crime.lua`

纯 exports 库，无 RegisterNetEvent。风险转移到调用方。

| Export | 校验内容 |
|:---|:---|
| `CheckStoreRobbery(source, storeId)` | 商店抢劫：警察在线数 + 全局冷却 + 玩家冷却 (10s) |
| `CheckHouseRobbery(source, houseId)` | 房屋抢劫：警察在线数 + 全局冷却 + 家具唯一键锁 |
| `CheckDrugs(source, drugType)` | 毒品交付：冷却检查 |
| `LaunderMoney(source, amount)` | 洗钱：折旧率 (25%) + 最低金额 ($1000) + 冷却 (60s) |
| `MultiLaunderMoney(source, level, amount)` | 多层洗钱：L1-L4 不同折旧率 |

---

## custom-main — 中央逻辑入口

### 服务端文件

| 文件 | 功能 |
|:---|:---|
| `server/main.lua` | 登录/登出日志、死亡元数据清理、遗留兼容 exports |
| `server/dispatch.lua` | 警察通缉分发：GPS 三角定位、通缉雷达 blip、通缉状态锁定执勤 |
| `server/security.lua` | **custom-security 的副本** — 速率限制器、回调劫持、事件审计 |
| `server/crime.lua` | **custom-crime 的副本** — 抢劫/毒品/洗钱校验 |
| `server/logs.lua` | 日志引擎：本地文件 + Discord Webhook 分发 |

### 客户端文件

| 文件 | 功能 |
|:---|:---|
| `client/main.lua` | 登录无敌 (12s)、死亡自动复活、预登录 godmode |
| `client/dispatch.lua` | 通缉星移交 (3★+)、GPS 三角定位脉冲 (8s)、帮派 NPC 关系组、市民恐慌 AI |
| `client/security.lua` | `CheckClientRateLimit` export |

### ⚠️ 代码重复
`custom-main` 中的 `server/security.lua` 和 `server/crime.lua` 是 `custom-security` 和 `custom-crime` 的**完全副本**。这是技术债 — 应合并为单一来源。

---

## 安全 Convars (security.cfg)

| Convar | 默认值 | 说明 |
|:---|:---|:---|
| `security_rate_limit_ms` | 1000 | 关键事件速率限制 |
| `security_max_add_money_limit` | 50000 | 单次最大加钱 |
| `security_max_add_item_limit` | 20 | 单次最大物品数量 |
| `security_max_interaction_distance` | 10.0 | 最大交互距离 (⚠️ 未在代码中实际执行) |
| `security_check_vehicle_spawn` | true | 车辆生成校验 |
| `security_check_weapon_give` | true | 武器赐予校验 |
