# v0.7 组织系统五件套

> **状态**: ✅ ALL ENABLED | **CFG 模块**: custom.cfg

---

## custom-cartel — 帮派组织核心

**路径**: `resources/[standalone]/custom-cartel/` | **依赖**: oxmysql※, qb-core, qb-inventory, qb-target, qb-menu, progressbar, core-framework, custom-storage, custom-market, custom-security, production-freeze

> ※ oxmysql 已声明但从未调用 — 纯内存状态

### 玩法循环
1. **化学供应商** NPC → 购买原料（可卡叶/大麻花/硫酸/丙酮）
2. **实验室工作台** (`/cartellab`) → 选择配方 → 进度条/保险箱小游戏 (20-45s) → 产出毒品
3. **毒品分销商** NPC → 以市场价 85% 出售成品
4. **突袭检查**: ≥3 警察在线 + 15% 每小时概率 → 全警察 blip 警报
5. **Cartel Boss** NPC → 链接 custom-quest

### 核心 API (CartelService, Bus 注册)

| 方法 | 描述 |
|:---|:---|
| `GetOnlineMembers()` | Cartel 在线成员表 |
| `GetOnlineCount()` | 在线人数 |
| `IsMember(source)` | (bool, grade) |
| `CheckProductionCooldown(cid)` | (canProduce, remainingSec) |
| `SetProductionCooldown(cid)` | 设置冷却 |
| `OpenStorage(source)` | → Bus.StorageService.OpenOrgStorage(source, 'cartel') |
| `CheckRaidConditions()` | (shouldRaid, policeCount) |

### 安全 ✅
所有四个 `RegisterNetEvent`（startProduction/finishProduction/buyFromSupplier/sellToDealer）均验证 source → Player → 成员资格 → 等级 → 冷却 → has-item → SecurityService — 五层完整。

### Bus 集成
- `Bus.StorageService` — 毒品存入组织仓库
- `Bus.MarketService` — NPC 价格按市场价 80%/85% 计算
- `Bus.EconomyService.AddScaled` — 销售现金应用倍率 + DirtyFlush
- `Bus.JobService.GetOnDutyCount('police')` — 突袭检测
- `Bus.SecurityService.ValidateItemEvent` — 物品校验

---

## custom-mining — 矿业系统

**路径**: `resources/[standalone]/custom-mining/` | **依赖**: oxmysql※, qb-core, qb-inventory, qb-target, qb-menu, progressbar, core-framework, custom-storage, custom-market, production-freeze

> ※ oxmysql 未调用

### 玩法循环
1. 4 个矿场（采石场/山区/沙漠/海岸）→ qb-target 圈 + 镐子动画
2. 5s 进度条循环 → 随机矿石（按等级加权）
3. **冶炼厂** → 菜单 → 配方（铁/铜/金/银锭）→ 进度条 (15-25s)
4. 所有矿石和锭进入 dynamic market

### 安全 ⚠️
`mining:server:mineOre` 和 `mining:server:smeltOre` — 缺少 `SecurityService.ValidateItemEvent` 调用。cartel 有，mining 没有。

### Bus 集成
- `Bus.StorageService` — 矿石/锭存入 mining_co 组织仓库
- `Bus.RegisterService('mining', { GetSites, GetSmeltRecipes, GetToolStats })`

---

## custom-justice — 司法系统

**路径**: `resources/[standalone]/custom-justice/` | **依赖**: oxmysql☆, qb-core, qb-menu, qb-target, core-framework, qb-policejob, qb-prison, custom-career, production-freeze

> ☆ oxmysql 已声明 — 用于监狱记录持久化

### 流程
逮捕 → 律师指派 → 审判 → 监狱服刑

### 文件
| 文件 | 功能 |
|:---|:---|
| `server/main.lua` | 入口：事件注册、律师系统、审判逻辑 |
| `server/prison.lua` | 监狱管理：刑期、减刑、越狱 |
| `client/main.lua` | 客户端 UI/交互 |

---

## custom-storage — 通用组织仓库

**路径**: `resources/[standalone]/custom-storage/` | **依赖**: oxmysql☆, qb-core, qb-inventory, core-framework

> ☆ oxmysql 用于组织仓库持久化

### 功能
- 按组织 (job/gang) 的共享仓库
- 区分容量：`job` vs `gang`
- 通过 `Bus.StorageService` 暴露 API
- 被 custom-cartel, custom-mining 等复用

---

## custom-market — 动态商品市场

**路径**: `resources/[standalone]/custom-market/` | **依赖**: oxmysql☆, qb-core, qb-inventory, core-framework

> ☆ oxmysql 用于价格数据持久化

### 功能
- 供需定价引擎 — 均值回归模型
- `Bus.MarketService.GetPrice(itemName)` → 当前市场价
- `Bus.MarketService.RecordTransaction(itemName, qty, price)` → 更新供需
- 被 custom-cartel (NPC 分销商定价) 和 custom-mining (矿石/锭定价) 使用
