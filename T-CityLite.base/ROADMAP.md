# T-City Lite — 模块化架构开发路线图

> 最后更新: Phase 1 完成
> 开发原则: 一次开发，多次调用，额外调试
> 核心总线: `core-framework` Bus (economy / job / security / storage / market / persistence)

---

## 📊 全局架构总览

```
                          ┌──────────────────────┐
                          │    Bus 统一导出总线     │
                          │  (core-framework)     │
                          └──────┬───────────────┘
           ┌─────────┬──────────┼──────────┬──────────┬──────────┐
           ▼         ▼          ▼          ▼          ▼          ▼
       Economy    Job       Security   Storage    Market   Persistence
       Service   Service    Service    Service    Service   Manager
       (已有)     (已有)      (已有)     🆕Phase1   🆕Phase1   (已有)
           │         │          │          │          │          │
           └─────────┴──────────┴──────────┴──────────┴──────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    ▼              ▼              ▼
              合法组织层       非法组织层       灰色组织层
           (警察/医院/矿业)  (Cartel/Ballas/..) (律师/记者/..)
                    │              │              │
                    └──────────────┼──────────────┘
                                   ▼
                          custom-quest 任务系统
                          custom-career 身份系统
                          custom-economy 经济系统
                          custom-crime 犯罪校验
```

---

## ✅ Phase 1 — 基础设施层 (已完成)

### 交付内容

| 资源 | 文件 | 功能 |
|------|------|------|
| `custom-storage` | config.lua / server/main.lua / fxmanifest.lua | 通用组织仓库：Job/Gang 双轨、差异化容量、权限校验、Bus.StorageService |
| `custom-market` | config.lua / server/main.lua / fxmanifest.lua | 动态交易市场：22商品 OrderBook、供需驱动价格、均值回归、Bus.MarketService |
| `qb-core/shared/items.lua` | 修改 | +22 种新物品（矿业12 + 毒品5 + 化学品2 + 工具3） |
| `qb-core/shared/jobs.lua` | 修改 | +miner 职业（5级） |
| `configs/modules/custom.cfg` | 修改 | 启用 storage + market |
| `configs/modules/crime.cfg` | 修改 | 启用 drugs + qb-drugs |

### Bus 服务清单

```
Bus.EconomyService     → GetBalance / AddScaled / Transfer
Bus.JobService         → GetJob / SetJob / GetGang / SetGang / GetOnDutyCount
Bus.SecurityService    → ValidateMoneyEvent / ValidateJobEvent / SanitizeNumber / CheckThreshold
Bus.StorageService 🆕  → OpenOrgStorage / GetOrgStorage / CanAccess / AddItem / RemoveItem
Bus.MarketService   🆕 → GetPrice / Buy / Sell / GetMarketStats / GetCategory
Bus.PersistenceService → StartFlushTick / FlushAll / ForceFlushPlayer / Stats
Bus.MetadataService    → GetJob / SetJob / GetGang / GetMetadata / SetMetadata
```

### 差异化仓库配置

| 组织 | 类型 | 格子 | 重量上限 | 备注 |
|------|------|------|----------|------|
| 矿业公司 (miner) | job | 150 | 1,000kg | 矿石100个/格 |
| Cartel | gang | 80 | 500kg | 毒品50个/格 |
| 警察局 (police) | job | 80 | 500kg | 证物室 |
| Ballas / Vagos / Families | gang | 60 | 300kg | 街头帮派 |
| Lost MC / Triads | gang | 70 | 400kg | 中型帮派 |
| 其他组织 | job/gang | 50 | 200kg | 默认配置 |

---

## 🔜 Phase 2 — Cartel 核心玩法 (下一步)

### 2.1 custom-cartel 资源

```
custom-cartel/
├── config.lua            — 毒品配方、加工时间、NPC坐标
├── server/
│   ├── main.lua          — Bus.CartelService 注册入口
│   ├── drug_lab.lua      — 毒品生产配方引擎
│   │   coca_leaf(3) + sulfuric_acid(1) → coca_paste(1)    [30s + minigame]
│   │   coca_paste(2) + acetone(1) → cocaine(1)             [45s + minigame]
│   │   cannabis_bud(5) → weed_pack(1)                      [20s]
│   ├── npc_manager.lua   — 农场NPC ped生成 + 交互
│   └── gang_sync.lua     — 帮派成员状态同步
├── client/
│   └── main.lua          — 加工台交互 / NPC target
├── shared/
│   └── recipes.lua       — 共享配方定义
└── fxmanifest.lua
```

### 2.2 Cartel NPC 盟友

- **位置**: Madrazo Ranch (La Fuente Blanca) 农场内部
- **NPC**: 2-3 个毒贩 ped，qb-target 交互
- **功能**:
  - 购买化学原料（硫酸/丙酮）
  - 出售古柯叶（原料采购）
  - 接取运输任务
  - 非 cartel 成员靠近 → 警告/敌对

### 2.3 Cartel 任务链

基于 `custom-quest` 模板:

| 任务ID | 名称 | 类型 | 说明 |
|--------|------|------|------|
| `cartel_initiation` | 入会考验 | 入门 | 运输一批货到指定地点，避开警察 |
| `cartel_drug_produce` | 毒品加工 | 生产 | 在农场实验室加工 5 份可卡因 |
| `cartel_delivery` | 街头交货 | 运输 | 将毒品送到 3 个街头 dealer |
| `cartel_turf_defend` | 守卫地盘 | 战斗 | 在农场抵御敌对帮派进攻 |
| `cartel_boss` | 集团运营 | 管理 | 管理生产链，分配任务给成员 |

### 2.4 警察缉毒联动

- 在 `custom-crime` 中添加 `CheckCartelActivity()`
- cartel 成员在农场生产毒品时，按警察在线数概率触发突袭
- 突袭 = 警察收到 GPS 警报 → 可前往搜查 → 发现毒品 → 逮捕

---

## 🔜 Phase 3 — 多组织生态

### 3.1 矿业公司 (custom-mining)

```
custom-mining/
├── config.lua            — 矿点坐标、矿石类型、采集参数
├── server/
│   ├── main.lua          — 矿石生成 + 采集逻辑
│   └── smelter.lua       — 冶炼配方 (矿石→金属锭)
├── client/
│   └── main.lua          — 矿镐使用 + 进度条
└── fxmanifest.lua
```

- 矿点: 郊区砂石场 (quest_miner.lua 已有坐标)
- 矿石100个/格 → 矿石量充足、单价低、有收获感
- 冶炼: 3 iron_ore + 1 coal → 1 iron_ingot

### 3.2 组织外交系统

- 帮派间关系: 盟友/中立/敌对
- 地盘冲突: 占领敌对帮派地盘可夺取
- 收益: 地盘越多 → 仓库容量加成 / 生产效率加成

### 3.3 洗钱管道升级

扩展现有 `custom-crime.LaunderMoney`:
- 多层洗钱: 现金 → 当铺 → 壳公司 → 投资 → 干净银行
- 每层折旧率不同，层级越深越干净
- cartel 专属低折旧率（组织内部消化）

---

## 🔜 Phase 4 — 司法生态

### 4.1 逮捕→审判→监狱 闭环

```
警察逮捕 → 警局登记 → 律师介入 → 法院审判 → 
  ├─ 无罪释放
  └─ 有罪 → 监狱服刑（prison_map已有）
           ├─ 探视（律师/家属）
           ├─ 减刑（社区服务/举报）
           └─ 出狱（社会复归）
```

### 4.2 社区立法

- 市长/议会可制定地方法规
- 警察执法依据
- 法官量刑参考
- 引入"三权"微缩: 行政(市长) / 立法(议会) / 司法(法院)

---

## 📋 开发进度追踪

| Phase | 系统 | 状态 | 完成日期 |
|-------|------|------|----------|
| 1 | custom-storage | ✅ 完成 | 2025-06-04 |
| 1 | custom-market | ✅ 完成 | 2025-06-04 |
| 1 | items.lua (+22) | ✅ 完成 | 2025-06-04 |
| 1 | jobs.lua (+miner) | ✅ 完成 | 2025-06-04 |
| 1 | server.cfg 集成 | ✅ 完成 | 2025-06-04 |
| 2 | custom-cartel | ✅ 完成 | 2025-06-04 |
| 2 | Cartel NPC 盟友 | ✅ 完成 | 2025-06-04 |
| 2 | Cartel 任务链 | ✅ 完成 | 2025-06-04 |
| 2 | 警察缉毒联动 | ✅ 完成 | 2025-06-04 |
| 3 | custom-mining | ✅ 完成 | 2025-06-04 |
| 3 | 组织外交系统 | ⏳ 待开发 | - |
| 3 | 洗钱管道升级 | ✅ 完成 | 2025-06-04 |
| 4 | 司法-监狱联动 | ✅ 完成 | 2025-06-04 |
| 4 | 社区立法系统 | ⏳ 待开发 | - |

---

## 🛠️ 关键技术决策记录

1. **Bus 总线 > 直接 exports**: 所有服务通过 `Bus.RegisterService()` 注册，第三方插件通过 Bus 调用，避免 exports 跨资源可见性问题
2. **内存优先 > 同步 SQL**: 所有写操作只标记 DirtyFlush，由 PersistenceManager 定时批量刷盘
3. **SecurityService 前置**: 所有敏感操作（金钱/职业/帮派变更）必须经过 SecurityService 校验
4. **Convar 驱动配置**: 所有阈值/倍率/开关通过 `set` 命令运行时调整，无需重启
5. **组织仓库 = qb-inventory stash**: 复用现有 stash 机制，只加权限层和差异化容量
