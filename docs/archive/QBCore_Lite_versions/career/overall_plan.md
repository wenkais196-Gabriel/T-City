# 🎭 T-City Lite 职业身份与扮演体验（Career）总规划

> **单一数据源 (Single Source of Truth)**  
> **适用版本**: v0.6 - v1.0+  
> **设计思想**: 职业是 RP（角色扮演）互动的载具，绝非单纯的挂机刷钱工具。通过将底层身份、许可证、文档投射与通用任务系统打通，实现高沉浸感、社会化协作的职业生态。

---

## 🏛️ 1. 核心理念与设计原则

本服的职业系统遵循以下四大核心原则进行重构与扩展：

1. **统一晋升与层级（Unified Tier & Grades）**：
   所有职业严格执行 **0➔4 五级晋升制度**（见 [ORGANIZATION_GUIDE.md](file:///e:/T-City/docs/ORGANIZATION_GUIDE.md)）。职级不仅决定薪资，还直接与 `custom-career` 的全局 Tier (`entry`, `mid`, `leader`, `boss`) 挂钩，解锁对应的管理权限与社会化能力。
2. **凭证授权与限制（Certificates-Gated Authority）**：
   特殊职业工具或高级载具的解锁，不再仅看“职业名”，而是看其是否在 `custom-career` 中持有特定的 **许可证/证书（Certs）**。例如，空中救援队需要 `pilot_license`，重型运输需要 `heavy_license`。所有驾驶限制由 [custom-certificates](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-certificates/server/main.lua) 强制约束。
3. **轻量化与任务化（Quest-Driven Transformation）**：
   废除传统平民职业（如公交、环卫、拖车）臃肿且耗能的客户端轮询，统一使用 [custom-quest](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua) 数据驱动状态机重写为“轻量级任务流”。玩家可以通过手机 Job Board 接单，以 GPS Waypoint 打卡和物理物品收集的形式完成执勤。
4. **社会化协作与供应链（Economic & Social Synergy）**：
   打通职业之间的供需壁垒。矿工生产的铁矿石，由货车司机运往港口，成为市长城市工程（KPI）的耗材，或成为机修工制作高级改装配件的原料。农民种植的作物加工成食物，成为警员与平民维持生命体征的补给。

---

## 🔍 2. 当前基础设施与职业现状

### 已有基建
* 📂 **基础职业配置**：[jobs.lua](file:///e:/T-City/T-CityLite.base/resources/[qb]/qb-core/shared/jobs.lua) 定义了 20 个标准职业及其 5 级职级名字。
* 📂 **身份与组织缓存**：[configs.lua](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-career/configs.lua) 实现了高并发的内存缓存与动态组织查找，提供 `PlayerMatchesTags` 比对。
* 📂 **证件与状态机**：[custom-certificates/server/main.lua](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-certificates/server/main.lua) 掌控物理驾照/船照/飞行照等实体，支持局方吊销、暂停、恢复逻辑。
* 📂 **3D 文本投射**：[custom-documents/config.lua](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-documents/config.lua) 支持警察直接查验玩家的实时证书状态。
* 📂 **安全结算与倍率**：[custom-phone/server/jobboard.lua](file:///e:/T-City/T-CityLite.base/resources/[custom]/custom-phone/server/jobboard.lua) 支持市长端发布工程，对接 `AddScaledMoney` 统一经济出口。

### 资源运行状态 (Active vs Inactive)
* 🟢 **已启用职业资源**：`qb-policejob` (警局), `qb-ambulancejob` (医护), `qb-mechanicjob` (机修)。目前以独立 QBCore 模式运行，尚未集成多标签职业系统。
* 🔴 **未启用职业资源**：`qb-busjob` (公交), `qb-garbagejob` (环卫), `qb-taxijob` (出租车), `qb-towjob` (拖车), `qb-newsjob` (新闻)。
* ⏳ **待自研资源 (Roadmap)**：`custom-mining` (矿工), `custom-trucking` (货运司机)。

---

## 🗺️ 3. T-City Lite 职业社会学供应链图谱

```
   ┌────────────────────────────────────────────────────────┐
   │                     市长 (City Hall)                   │
   │           通过手机发布城市工程 & 划拨公共财政预算      │
   └───────────┬────────────────────────────────────────┬───┘
               │                                        │
               ▼ (发布物流/基建工程任务)                ▼ (调配治安/巡逻专款)
   ┌────────────────────────┐              ┌────────────────────────┐
   │   货车司机 (Trucker)   │              │     警察局 (LSPD)      │
   │  从郊区仓库运输建材到城区   │              │   警员出勤/治安巡逻     │
   └───────────▲────────────┘              └────────────────────────┘
               │ (承运矿石)                             ▲
   ┌───────────┴────────────┐                           │ (保障安全)
   │     矿工 (Miner)       ├───────────────────────────┤
   │     在郊区开采铁矿/建材 │                           │ (供应原料/黑市)
   └────────────────────────┘                           ▼
   ┌────────────────────────┐              ┌────────────────────────┐
   │     农民 (Farmer)      ├─────────────►│    非法帮派 (Gangs)    │
   │   种植农产品/产出化肥   │  (供应化肥)  │    毒品加工与黑市交易   │
   └───────────┬────────────┘              └────────────────────────┘
               │ (供应农副产品)
               ▼
   ┌────────────────────────┐              ┌────────────────────────┐
   │ 餐饮/服务 (Food/Taxi)   ├─────────────►│ 汽车机修 (Mechanic)    │
   │   热狗摊/葡萄酒/出租车   │  (日常出行)  │ 警车/民用车/帮派车改装与维护│
   └────────────────────────┘              └────────────────────────┘
```

---

## 📅 4. 分步讨论与具体职业规划蓝图 (Discussion Backlog)

为了实现上述构想，我们将采用 **“全局扫描 ➔ 深度讨论 ➔ 方案输出 ➔ 代码施工”** 的循环，逐步讨论各个职业的细化规划。以下是讨论目录和预设排期：

### 📌 第一阶段：公共安全与生命救援（紧急服务篇）
* **涉及职业**: 警察 (`police`) / 医护 (`ambulance`)
* **核心议题**:
  * 如何将 `qb-policejob` 和 `qb-ambulancejob` 接入 `custom-career` 的 `department`（部门）与 `district`（辖区）。
  * 警衔与医护等级如何动态映射 `rank_tier`，并利用证书（Certs）锁定高级警车/直升机。
  * 引入警员/医护出勤 KPI 统计与薪资分发。

### 📌 第二阶段：社会治理与司法秩序（市政与司法篇）
* **涉及职业**: 市长 (`mayor`) / 法官 (`judge`) / 律师 (`lawyer`)
* **核心议题**:
  * 市长终端的财政预算与 Job Board 发布联动规则。
  * 法官与律师的诉讼流程、3D 执业证书展示及法庭专属权限。
  * 执照暂停/吊销（Suspended/Revoked）的司法强制执行链路（如：法院指令吊销驾照 ➔ 证书系统失效 ➔ 玩家无法开动对应载具）。

### 📌 第三阶段：工业制造与民间物流（工业供应链篇）
* **涉及职业**: 矿工 (`miner`) / 货车司机 (`trucker`) / 机修工 (`mechanic` / `beeker` / `bennys`)
* **核心议题**:
  * 自研资源 `custom-mining` 的采矿点分布、采矿工具与产出设计。
  * 自研资源 `custom-trucking` 的物流路线、重载证书限制与手机端交单。
  * 机修工高级改装材料与矿石冶炼链路的合并方案。

### 📌 第四阶段：基础保障与公共服务（轻量化平民篇）
* **涉及职业**: 出租车 (`taxi`) / 公交 (`bus`) / 拖车 (`tow`) / 环卫 (`garbage`)
* **核心议题**:
  * 原生臃肿脚本的下架与“通用任务化”包装。
  * 利用 `custom-quest` 实现公交线打卡、垃圾收运、违章拖车等全流程追踪。
  * 公共服务组织（如环卫局、公交公司）的财政反哺机制。

### 📌 第五阶段：市井商业与特色副业（休闲商业篇）
* **涉及职业**: 新闻记者 (`reporter`) / 葡萄酒庄 (`vineyard`) / 热狗摊贩 (`hotdog`) / 汽车销售 (`cardealer`) / 房产中介 (`realestate`)
* **核心议题**:
  * 记者专用相机、新闻发布与 NUI 报纸阅读。
  * 葡萄酒与热狗的生产、物流及市民基础属性补充。
  * 房产/汽车交易的职业抽成与 Boss 账目联动。

---

## 🚦 5. 后续操作指南

1. 您现在可以随时发起针对上述**任何一个职业或阶段**的讨论。
2. 在我们开始某一个具体职业的规划前，我会自动对相关的原生脚本及涉及的数据库、文件等进行**全局扫描**，并在讨论时为您输出详细的代码层规划。
3. 您可以通过直接输入“**我们开始讨论[职业名称]的具体规划**”来向我下达指令。
