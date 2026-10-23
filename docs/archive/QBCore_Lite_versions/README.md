# 📋 T-City Lite 版本规划索引

> **本项目的一站式版本规划总览。每个版本对应一个独立的规格文档。**  
> 项目根目录的 `PROJECT_PROGRESS.md` 是实时进度看板（含任务清单和资源状态），本文件是静态规划索引。

---

## 🗺️ 版本全景图

| 版本 | 名称 | 类型 | 状态 | 前置依赖 | 规格文档 |
|:---:|------|:----:|:----:|:---------|:--------:|
| **v0.1** | 精简启动链 | 🏗️ 基础设施 | ✅ 完成 | — | [📄](./v0.1-lite-startup.md) |
| **v0.2** | 基础 RP 闭环 | 🏗️ 基础设施 | ✅ 完成 | v0.1 | [📄](./v0.2-basic-rp.md) |
| **v0.3** | 基础设施层 | 🏗️ 基础设施 | ✅ 完成 | v0.1~v0.2 | [📄](./v0.3-economy.md) |
| **v0.4** | 自研手机系统 | 📱 特色系统 | ✅ 完成 | v0.1~v0.3 | [📄](./v0.4-custom-phone.md) |
| **v0.5** | 犯罪玩法系统 | 🎮 玩法 | 🚧 进行中 | v0.3 + v0.4 | [📄](./v0.5-crime-gameplay.md) |
| **v0.6-quest** | 通用任务系统 | 🏗️ 基础设施 | ⏳ 待开始 | v0.3~v0.5 | [📄](./v0.6-quest-system.md) ← **新建** |
| **v0.6a** | 民间经济职业 | 🎮 玩法 | ⏳ 待开始 | v0.6-quest | [📄](./v0.6a-civilian-economy.md) |
| **v0.6b** | 沙盒社会生态 | 🎮 玩法 | ⏳ 待开始 | v0.6-quest | [📄](./v0.6-sandbox-sociology.md) |
| **v1.0** | Beta 开放公测 | 🚀 发布 | ⏳ 待开始 | v0.6a + v0.6b | [📄](./v1.0-beta-launch.md) |
| **v1.3** | 硬核原位登录 | 🛠️ 迭代 | 📅 规划中 | v1.0 | [📄](./v0.7-hardcore-spawn-system.md) |
| **v1.4** | 多语言本土化 | 🛠️ 迭代 | 📅 规划中 | v1.0 | [📄](./v0.8-localization-adaptation.md) |

### 版本类型说明

| 类型 | 含义 | 特点 |
|------|------|------|
| 🏗️ **基础设施** | 底层框架/系统 | 后续版本的依赖，变更影响面大，需充分测试 |
| 📱 **特色系统** | 面向玩家的独立系统 | 可并行开发，通过标准接口与基础设施对接 |
| 🎮 **玩法** | 具体游戏内容 | 依赖基础设施，通过配置/API 快速迭代 |
| 🚀 **发布** | 上线准备 | 全系统联调、压力测试、运营准备 |
| 🛠️ **迭代** | 上线后功能追加 | 不急，正式运营后按需推进 |

---

## 🔗 版本依赖关系图

```
v0.1 ─→ v0.2 ─→ v0.3 ──→ v0.5 ──→ v0.6-quest ──┬──→ v0.6a ─┐
                        │                         │            │
                        └─→ v0.4 ────────────────┘──→ v0.6b ─┤
                                                              │
                                                         ┌── v1.0
                                                   上线后 │
                                                         ├── v1.3 (原位登录)
                                                         └── v1.4 (多语言)
```

### 关键依赖说明

| 版本 | 为什么依赖它 |
|------|-------------|
| **v0.3** | 统一经济出口（AddScaledMoney）、多标签职业校验（PlayerMatchesTags）、安全边界（CheckRateLimit）、审计日志（custom-logs）——**所有后续版本的基础** |
| **v0.4** | 手机 Job Board 和 NUI 交互框架是所有 Phone-First 设计的前置 |
| **v0.6-quest** | 任务系统是 v0.6a（民间经济）和 v0.6b（领袖+卡牌）的前置基础设施——省去各自实现步骤状态机/冷却/奖励管理 |

---

## 🏛️ 核心架构决策

| 决策 | 结论 |
|------|------|
| 交互入口 | **Phone-First**：所有系统交互通过手机完成；NPC 只用于商店等必须线下存在的场景 |
| 手机系统 | **自研** `custom-phone`（Svelte + Vite），不使用 qb-phone |
| 职业身份 | **多标签体系**（职业标签 + 层级标签 + 部门标签），扩展 QBCore 原生 job+grade |
| 领袖终端 | **手机内专属 App**（`rank_tier=leader` 时动态解锁），无物理终端实体 |
| 开发模式 | **四轨并行**（基础设施 + 特色系统 + 民间经济 + 通用任务系统） |
| Beta 定位 | **开放公测** → 积累社群 → 视情况转白名单私服 |
| 任务系统 | **数据驱动**：任务模板是配置文件（非 DB），外部脚本通过标准 API 联动 |

---

## 🧩 版本推进管线

```
        ┌── v0.6a 民间经济 (A轨) ──┐
已验收  │                          │
v0.1~v0.4 ──→ v0.5 犯罪 (A轨) ──→ v0.6-quest 任务系统 (D轨) ──┤
                                    │                          │
                                    └── v0.6b 领袖+卡牌 (B轨) ──┘
                                                                  ↓
                                                           v1.0 Beta
                                    ┌── v0.6c Wiki (C轨) ────┘
```

### 并行轨道说明

| 轨道 | 覆盖版本 | 说明 |
|:----:|:---------|:------|
| **A 轨 — 基础设施** | v0.3 → v0.5 → v0.6a | 底层系统 → 犯罪玩法 → 民间经济 |
| **B 轨 — 特色系统** | v0.4 → v0.6b | 手机 → 领袖体系 + 催化剂卡牌 |
| **C 轨 — 内容填充** | v0.6c | 游戏内百科（可随时并行） |
| **D 轨 — 任务系统** | v0.6-quest | 通用任务基础设施（v0.6a/v0.6b 的前置依赖） |

### 推进规则

1. **完成度优先**：每个版本以验收标准为准，不设硬性截止日期
2. **前序通过后才能启动后序**：一个版本通过验收后，才能启动依赖它的下个版本
3. **v0.6-quest 须优先完成**：它是 v0.6a 和 v0.6b 的共同前置依赖
4. **v0.6a 与 v0.6b 可并行开发**：共享同一套任务系统基础设施
5. **自愈机制**：开发中发现设计缺陷时，允许回退修正前置版本

---

## 📦 自定义资源清单（v1.0 目标）

按版本分组，显示每个资源在架构中的位置：

### v0.3 基础设施层

| 资源 | 说明 | 模块 cfg |
|------|------|:--------:|
| `custom-main` | 核心工具函数（AddScaledMoney、Spawn Death Fallback、Duty） | `custom.cfg` |
| `custom-economy` | 统一经济出口、倍率配置、经济日志 | `economy.cfg` |
| `custom-security` | Rate Limit、事件校验、伪造拦截 | `security.cfg` |
| `custom-career` | 多标签职业体系 API（GetPlayerIdentity / PlayerMatchesTags） | `career.cfg` |
| `custom-admin` | 管理员指令（setleader / demote / settier） | `admin.cfg` |
| `custom-logs` | Discord Webhook 5 频道审计 | `custom.cfg` |
| `core-framework` | 统一导出总线（Bus）+ 三层 TTL 缓存 + 脏数据刷盘 | `custom.cfg` |

### v0.4 特色系统

| 资源 | 说明 | 模块 cfg |
|------|------|:--------:|
| `custom-phone` | 自研手机（Svelte + Vite）→ Job Board / 职业频道 / 领袖 App | `custom.cfg` |

### v0.5 犯罪玩法

| 资源 | 说明 | 模块 cfg |
|------|------|:--------:|
| `custom-crime` | 犯罪校验逻辑（CheckStoreRobbery / LaunderMoney / CheckDrugs） | `custom.cfg` |
| `qb-storerobbery` | 便利店抢劫（配置型） | `crime.cfg` |
| `qb-drugs` | 毒品系统（配置型） | `crime.cfg` |

### v0.6-quest 通用任务系统

| 资源 | 说明 | 模块 cfg |
|------|------|:--------:|
| `custom-quest` | 通用任务系统（数据驱动状态机 + 外部脚本联动 API + 手机任务追踪） | `quest.cfg` |

### v0.6a 民间经济

| 资源 | 说明 | 模块 cfg |
|------|------|:--------:|
| `custom-mining` | 矿工系统（交互薄层，步骤/奖励由 quest 管理） | `civilian-economy.cfg` |
| `custom-trucking` | 货运系统（薄层，路线由 quest 配置 + Job Board 联动） | `civilian-economy.cfg` |
| `qb-fishing` | 渔民（配置型） | `civilian-economy.cfg` |
| `qb-farming` | 农民（配置型，化肥 → 毒品配方） | `civilian-economy.cfg` |
| `qb-mechanicjob` | 机修师（配置型） | `jobs.cfg` |

### v0.6b 沙盒社会生态

| 资源 | 说明 | 模块 cfg |
|------|------|:--------:|
| `custom-leaders` | 三线领袖业务逻辑（基于 quest 发布动态任务） | `leaders.cfg` |
| `custom-catalysts` | 催化剂卡牌系统（作为 quest 任务链奖励） | `catalysts.cfg` |
| `custom-wiki` | 游戏内百科（Anti-Meta-Gaming 盲盒设计） | `wiki.cfg` |

---

## ⚙️ 基础原则

1. **不直接大改 `qb-core` 本体。** 所有自定义逻辑放在 `[custom]` 下，通过 exports / events / Bus 对接。
2. **不再使用 `ensure [qb]`。** 所有资源通过模块化 CFG 白名单加载。
3. **每个版本必须可启动、可回滚。** 新增资源记录依赖、启动顺序和禁用原因。
4. **所有资金变更经过 `AddScaledMoney` 统一出口**（v0.3 之后）。
5. **奉行"网络信任零边界"。** 所有关键逻辑在服务端校验，不信任客户端传入的任何数据。
6. **Phone-First。** 手机是所有系统的主要交互界面，NPC 只用于必须线下存在的场景。
7. **任务数据驱动。** 任务模板是配置文件（`config/quests/*.lua`），运行时注册到内存，不改动 DB 结构即可新增任务。

---

## 🔗 外部参考

| 文档 | 位置 |
|------|------|
| 项目实时进度看板 | [`/PROJECT_PROGRESS.md`](../PROJECT_PROGRESS.md) |
| 技术讨论记录 | [`/QBCore_Lite_技术讨论.md`](../QBCore_Lite_技术讨论.md) |
| 项目 README | [`/T-CityLite.base/README.md`](../T-CityLite.base/README.md) |
| 变更日志 | [`/T-CityLite.base/LITE_CHANGELOG.md`](../T-CityLite.base/LITE_CHANGELOG.md) |
| 通用任务系统设计方案 | [`/quest-system-design.md`](../quest-system-design.md) |
| 架构重构交付报告 | [`/T-CityLite.base/docs/v0.5-architecture-migration.md`](../T-CityLite.base/docs/v0.5-architecture-migration.md) |