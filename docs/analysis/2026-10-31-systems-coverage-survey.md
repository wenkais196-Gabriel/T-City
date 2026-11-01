---
id: systems-coverage-2026-10
type: research
status: final
system: meta
owner: hermes
updated: 2026-10-31
review_by: 2027-04-30
source_of_truth: true
---

# T-City 服务器系统覆盖与规划缺口调研

> **日期**：2026-10-31 ｜ **基线**：`chore/windows-workspace-baseline`（HEAD `ac2cbde`）
> **目的**：回答一个问题——**哪些系统/模块还没有"基本规划"**。
> **方法**：先按「系统 → 模块」两级把本服现状摸清（本文件 §1–§2，全部来自仓库实测），再对照行业主流 RP 服的功能矩阵（§3，外部调研带来源），最后产出缺口清单与优先级（§4–§5）。
> **配套**：警察模块已有施工图 [`../agent/police/BLUEPRINT.md`](../agent/police/BLUEPRINT.md)（本文 §2 的 S3 直接引用它，不重复设计）。

---

## 0. 结论摘要

1. **最小可玩闭环有一处硬断裂（本轮最实的发现）**：饥饿/口渴由 `qb-core` 每秒级衰减（`server/events.lua:153`，`HungerRate 4.2` / `StatusInterval 5000ms`），归零后 `client/loops.lua:45` 直接扣血；但——
   - **买不到**：唯一购买通道是自动售货机，`Config.VendingItems` 只有 `kurkakola` 与 `water_bottle` 两件（`qb-inventory/config/config.lua:39`）；
   - **吃不了**：18 个食品/饮品的用途注册在 qb-smallresources 的 server/consumables.lua（该资源已不在仓库里），而该资源**未启用**。

   即：**生存循环（饿→掉血→死）是完整闭合的，但"补充"这一侧完全断开。** 这是全服优先级最高的一个洞。
2. **规划水位极不均衡**：17 个系统里只有 **4 个到「施工图级」**（S3 警察、S7 载具、S11 手机、S16 Agent 栈），**10 个停在「手册级」**（描述现状但不指导新增），**2 个「代码即规范」**（S13 运营安全、S15 世界环境），**1 个「真空/库存」**（S9 房产与所有权）。
3. **第二大整块真空是「房产/所有权」**：`qb-houses`（5140 行 + 989 行配置）躺在仓库不启用，`custom-taxes` 却在收 `property_tax`——税基不存在；而 `server-design/00–05` 整卷设计都在讲"所有权感"。
4. **有职业、没工作**：`T-CityLite.base/resources/[qb]/qb-core/shared/jobs.lua` 定义 20 个职业，其中 8 个（出租车、公交、拖车、记者、垃圾、葡萄园、热狗、房产中介）没有任何支撑资源在跑；v0.6a 规划里的渔民/农民至今未落地。
5. **33 个资源未被任何 CFG 引用，合计 56,457 行 Lua，其中纯玩法约 35,000 行**——它们缺的不是代码，是一份"启用 or 删除"的取舍决策。
6. **文档已明显落后于代码**：`PROJECT_PROGRESS.md` 写「78 资源 / 17 CFG」，实测 **82 个 ensure / 18 个模块 CFG / 108 个磁盘资源**；`docs/01_resource_inventory.md` 自标「历史快照」。**以文档为准做规划会踩空。**
7. **`custom-director`（7113 行，Agent 动作栈）没有出现在任何启动配置里**：`server.cfg.template` 只 exec 17 个模块，`dev.cfg`（`custom-testing`）同样不在其中 → 部署态与开发态不一致。

---

## 1. 系统级现状（第一层）

**统计口径（实测）**：磁盘 108 个资源（含 `fxmanifest.lua`）；模块 CFG 18 个，`ensure` 去重 82 个；`server.cfg.template` exec 17 个 CFG（缺 `dev.cfg`）。

**规划等级（本文统一口径）**：

| 等级 | 含义 | 判定证据 |
|---|---|---|
| **A 施工图** | 有设计稿 + 决策日志 + 验收标准（AC） | `docs/agent/police/BLUEPRINT.md`、`docs/agent/phone/DESIGN.md`、`T-CityLite.base/docs/agent/design/01..07` |
| **B 手册** | 有模块手册或脚本索引（描述现状，不指导新增） | `docs/01_module_manuals/*`、`docs/02_script_index/*` |
| **C 代码即规范** | 能跑、有测试，但无任何设计文档 | 只有 `fxmanifest.lua` + Lua 源码 |
| **D 库存** | 资源在仓库、未启用、**无启用/不启用的决策记录** | 实测 33 个资源未被任何 CFG 引用（26 个 `qb-*` + 7 个 standalone/custom） |
| **E 真空** | 无资源、无文档、无表 | 见 §2 各系统缺项列 |

| # | 系统 | 在用资源（主要） | 规模（Lua 行） | 规划等级 | 一句话判断 |
|---|---|---|---|---|---|
| S1 | 身份与角色 | qb-multicharacter, qb-clothing, qb-spawn, qb-apartments, qb-cityhall, custom-certificates, custom-documents, custom-career | ~9.7k | **B** | 骨架齐；**外观（理发/纹身/衣柜持久化）与新手引导是真空** |
| S2 | 经济与金融 | core_economy, custom-economy, custom-taxes, economy-dashboard, atom_nodes, custom-market, qb-banking | ~3.4k | **B**（另有经济模拟蓝图） | 发钱链路很硬；**贷款/信用/保险/股票无规划**，税基（房产）不存在 |
| S3 | 执法与司法 | qb-policejob, qb-prison, custom-justice, custom-documents, tcity-dashboard | ~10.8k | **A（仅设计）** | 规划水位全服最高；**Phase 0 未开工**，司法链全是内存态 |
| S4 | 医疗急救 | qb-ambulancejob, hospital_map | ~5.5k | **B**（一页索引） | 死亡/复活够用；**医院分级、病历、毒理、与司法交接无规划** |
| S5 | 犯罪与地下经济 | qb-storerobbery, qb-houserobbery, qb-drugs, qb-pawnshop, qb-doorlock, custom-crime, custom-cartel, custom-mining, safecracker | ~10.4k | **B** | 主线完整；**银行/珠宝/运钞/赛车抢劫与地下赌场 D 级或真空** |
| S6 | 正当职业 | custom-career, qb-management, qb-mechanicjob, custom-quest(logistics), custom-mining | ~5.4k | **B** | 20 个职业里 8 个**无人干活**；v0.6a 的渔民/农民未落地 |
| S7 | 载具全生命周期 | custom-vehicles, qb-garages, qb-vehicleshop, qb-fuel, tcity-dashboard | ~9.5k | **A**（v0.7a/0.7b spec） | 本服最强的一块；**保险理赔、改装经济、二手车、扣押拍卖无规划** |
| S8 | 物品与获取 | qb-inventory, qb-weapons, custom-storage, custom-market | ~4.9k | **B** | **没有商店、没有制作台**：唯一购买入口是自动售货机（可乐/水），且吃喝的用途未加载 |
| S9 | 房产与所有权 | qb-apartments, qb-interior, custom-taxes(property_tax) | ~3.6k | **E/D** | `qb-houses` 5140 行躺着不启用；**购房/按揭/家具/储物整块无设计** |
| S10 | 组织与社交 | custom-cartel, cartel-gates, custom-storage, custom-phone(faction) | ~2.0k | **B**（索引）+ 设计稿（§server-design 03/04） | 帮派有产业链；**玩家企业（所有权/雇员/薪资/许可）完全真空** |
| S11 | 通讯 | custom-phone, pma-voice | ~4.6k | **A** | 11 个 App + 3 个领袖 App；**无 App 注册表**（硬编码 import），相机/相册/邮件/地图全缺 |
| S12 | 任务与叙事 | custom-quest(31 个 quest), story-engine, atom_nodes | ~14.9k | **B** | 内容量惊人；**涌现式/多人社交任务（design 01 漏斗）未实现** |
| S13 | 运营与安全 | custom-security, custom-logs, custom-admin, custom-testing, custom-debug, production-freeze, aaa_silence, qb-adminmenu | ~3.2k（不含 adminmenu 库） | **C** | 五层安全链有手册；**反作弊、白名单/申诉、举报工单、监控告警真空** |
| S14 | 表现层/交互 | qb-hud, qb-scoreboard, custom-ui, qb-loading, tcity-atmosphere, hud-position-tool, qb-target/menu/input | ~4.0k | **B**（NUI 规范 + 菜单规范） | 交互范式统一；**本地化只有 zh-CN，通知中心不统一** |
| S15 | 世界与环境 | qb-weathersync, bob74_ipl, cartel-gates, hospital_map, dealer_map | ~13.6k | **C** | 天气/时间很硬；**灾害/天气事件、地图内容（MLO）无规划** |
| S16 | AI Agent 层 | custom-director, custom-agent-client, tools/* | ~8.0k | **A** | 34 工具 / 18 动作 / 双层评测；**不在任何启动配置里** |
| S17 | 交付与运维 | CI（6 job）、migrations、tests、`tools/*` | — | **B** | 静态质量门禁齐；**部署（docker/txAdmin recipe）、监控、备份自动化未入库** |

> 说明：S17 不是玩法系统，单列是因为它决定了前面 16 个系统能不能上线。

---

## 2. 模块级现状（第二层）

> 每格格式：**模块 → 实现资源（行数）/ 状态**。状态标记：✅ 可用 · 🟡 半成品 · ⛔ 未启用 · ❌ 真空。

### S1 身份与角色（B）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 账号/多角色 | ✅ `qb-multicharacter` 1993 行 + `qb-spawn` 852 | 角色槽位上限、角色删除后果（资产/组织归属）无定义 |
| 外貌与服装 | 🟡 `qb-clothing` 4425 行（含 barber 字样）；`player_skins`/`player_outfits` 表在 fixture | **理发店/纹身店/衣柜跨机持久化**无规划；无一键换装/职业制服系统 |
| 证件与执照 | ✅ `custom-certificates` 623 + `custom-documents` 504（驾照/武器证/医疗执照，走 metadata 非表） | 证件伪造/吊销公示、国际驾照等扩展无定义 |
| 职业身份 | ✅ `custom-career` 685（多标签）+ `jobs.lua` 20 个职业阶梯 | 职业与技能/执照的绑定规则无文档 |
| 新手引导 | ❌ | **无 onboarding 设计**（首个 30 分钟体验没有 spec） |

### S2 经济与金融（B）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 发钱网关 | ✅ `core_economy`（293）+ `custom-economy`（62，近乎空壳）+ `atom_nodes`（428） | 两套 EconomyService 未合并（手册 §8 技术债 #1） |
| 宏观调节 | ✅ `custom-taxes` 843（房产税/车辆生命周期/NPC 定价/耐久）+ `economy-dashboard` 356 | **税基缺失**：property_tax 收的房产没有购买系统 |
| 银行 | ✅ `qb-banking` 1120 + 手机 Banking App | **贷款/信用分/分期付款（车行 finance 之外）/ATM 网络**无规划 |
| 市场 | ✅ `custom-market` 738（供需定价） | 玩家间交易/拍卖行、价格操纵防护无定义 |
| 保险/理财 | ❌ | 车险、医保、寿险、股票/基金全真空（`qb-crypto` 821 行 ⛔） |

### S3 执法与司法（A，设计定稿未实现）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 巡逻/工具 | ✅ `qb-policejob` 8174（MDT 只是 3 块 HUD 浮层） | 对照 §3.5B 的成熟 MDT：**档案/通缉/BOLO/案件/报告/证据链/执法记录仪/罚金分级 八块全缺** |
| 调度 | 🟡 `custom-main` 里 wantedlevel 接管；`police:server:policeAlert` 有 5 个玩法发件方各自直发（`qb-drugs`×2、`qb-houserobbery`、`qb-storerobbery`、`custom-vehicles`），另有 2 个已禁用的抢劫资源也在发 | **统一报警入口**（BLUEPRINT Phase 2 的核心）：没有优先级、没有队列、没有派单状态 |
| 逮捕/案卷 | 🟡 `qb-policejob` + `custom-justice` 1006；`justice:server:registerArrest` 的唯一入口是 `/arrest` 命令，**警察的逮捕流程不调用它** | 案卷落库、刑期、保释、缓刑全在内存 |
| 法庭/律师 | ❌（jobs.lua 有 judge/lawyer 阶梯，无资源） | 庭审流程、社区服务、罚单争议 |
| 监狱 | ✅ `qb-prison` 1486（被 `custom-justice` 声明依赖） | 越狱事件、囚犯劳动、探视 |

### S4 医疗急救（B）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 死亡/复活/伤害 | ✅ `qb-ambulancejob` 5542 + `hospital_map` | 伤病分级（骨折/内出血/中毒）、致残后果无规划 |
| EMS 职业流程 | 🟡 职业阶梯在 `jobs.lua`，无担架/急救包/自动体外除颤流程 | 出勤计时/KPI、救护车优先级调度 |
| 病历与药房 | ❌ | 医疗记录（EMR）、处方/药物、毒理检测 |
| 与司法交接 | ❌ | 尸体证据链、伤情鉴定书（警察 BLUEPRINT 依赖它但未定义） |

### S5 犯罪与地下经济（B）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 便利店抢劫 | ✅ `qb-storerobbery` 1649（v0.5 已加服务端 25 秒计时/距离校验） | — |
| 入室盗窃 | ✅ `qb-houserobbery` 1961（依赖 `qb-minigames` 304） | 与房产系统联动（住户在线/报警）未定义 |
| 毒品链 | ✅ `qb-drugs` 2526 + `custom-cartel` 1434（产业链/领地/NPC 盟友）+ `custom-mining` 680 | 成瘾/耐受/毒理；原料点与配方仍未配置（v0.5 遗留 2 项） |
| 销赃/洗钱 | ✅ `qb-pawnshop` 1117 + `custom-crime` LaunderMoney（折旧 75%） | 洗钱链与当铺/洗车行折旧联动未配 |
| 银行/珠宝/运钞抢劫 | ⛔ `qb-bankrobbery` 2771、`qb-jewelery` 762、`qb-truckrobbery` 581 | **全部未启用、无取舍记录** |
| 地下赌场/黑市 | ❌ | 赌场（`bob74_ipl` 有 IPL 但无玩法）、军火黑市、赃车拆解（`qb-scrapyard` 634 ⛔） |

### S6 正当职业（B）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 职业框架 | ✅ `custom-career`（标签/晋升）+ `qb-management` 3355（雇佣/解雇） | 面试流程、试用期、绩效 |
| 修车 | ✅ `qb-mechanicjob` 3193（含 bennys 与另一工坊） | 改装经济（配件定价/工单/发票） |
| 物流/卡车 | 🟡 `custom-quest` quest_logistics（取货→运输→交付），无独立职业资源 | 多点在途、货损、油价联动 |
| 矿业/加工 | ✅ `custom-mining` 680 → `custom-storage` → `custom-market` | 职业健康/事故 |
| 空壳职业 | ❌ 出租车/公交/拖车/记者/垃圾/葡萄园/热狗/房产中介 8 个阶梯**无资源** | 其中 `qb-taxijob` 1896、`qb-busjob` 998、`qb-towjob` 1098、`qb-garbagejob` 1499、`qb-vineyard` 902、`qb-hotdogjob` 1758、`qb-newsjob` 1027 ⛔ |
| 渔民/农民 | ❌（v0.6a spec 未落地） | 无资源、无表、无设计 |

### S7 载具全生命周期（A）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 钥匙/状态/驾驶辅助 | ✅ `custom-vehicles` 4719（O(1) 缓存、事件驱动、安全带/巡航/氮气/损耗） | `vehicle_state` 同步写库待迁 DirtyFlush（技术债 #4） |
| 车行/购买/分期 | ✅ `qb-vehicleshop` 3740（Phase 1–5，含试驾/独立车牌） | 二手市场（`qb-vehiclesales` 1459 ⛔）、拍卖 |
| 车库/扣押 | ✅ `qb-garages` 2199（含 impound 逻辑） | 扣押拍卖、拖车服务闭环（`qb-towjob` ⛔） |
| 油量 | ✅ `qb-fuel` 754 | 加油站经营/油价随市场浮动 |
| 中控屏 | ✅ `tcity-dashboard` 2811（Vue 3，6 类模板） | 更多职业模板（EMS/消防/出租） |
| 保险/理赔 | ❌ | 保费、事故勘察、全损与折旧 |

### S8 物品与获取（B）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 背包 | ✅ `qb-inventory` 2733（27 exports，槽位制） | 重量/耐久/赃物标记 |
| 武器 | ✅ `qb-weapons` 2361 | 弹道/序列号追溯、军火商 |
| 组织仓库 | ✅ `custom-storage` 554（job/gang 分容量） | 个人保险箱/仓储租赁（依赖 S9） |
| 商店 | ⛔ `qb-shops` 2578 **未启用** | **全服没有普通商店、24/7、自动售货机之外的任何购买入口** |
| 消耗品 | ⛔ `qb-smallresources` 里 18 个食品/饮品用途未加载 | **饥饿/口渴在衰减，但吃喝用不了**（`qb-hud` 照常扣，`consumables.lua` 不跑） |
| 制作 | ⛔ `qb-crafting` 600 **未启用** | 工作台/配方/熟练度 |
| 玩家交易 | ❌ | P2P 交易、拍卖行、邮件包裹 |

### S9 房产与所有权（E/D）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 公寓 | ✅ `qb-apartments` 1646（进服分房）+ `qb-interior` 1913（壳模型） | 公寓租金、水电、室友 |
| 购房/持有 | ⛔ `qb-houses` 5140（含 `houselocations`/`player_houses`/`house_plants` 表） | **无购房流程、无产权表设计** |
| 家具/装修 | ❌（`qb-houses` 内有 furniture 逻辑但未启用） | 家具目录、摆放持久化、装修权限 |
| 仓储/保险箱 | ❌ | 与 `custom-storage` 联动缺失 |
| 房产中介 | 🟡 `jobs.lua` 有 realestate 阶梯 | 无资源、无委托/佣金模型 |

> 这块是**最讽刺的一处自相矛盾**：`custom-taxes` 有 `property_tax` 在收房产税，`server-design/00` 整篇在讲"所有权感"，但玩家买不到房。

### S10 组织与社交（B）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 帮派 | ✅ `custom-cartel` 1434 + `cartel-gates` 606 + `organization_rules` 表 | 领地争夺规则、外交/停战/宣战、成员贡献 |
| 保险/共治 | 🟡 `governance_proposals` 表（design 04 共治） | 提案/投票系统未实现 |
| 企业 | ❌ | 玩家企业（执照/雇员/薪资/税务/供应链）全真空 |
| 声誉 | 🟡 `trust_graph` 表 + design 03 | 声誉如何产生/消费无实现 |
| 社交 | 🟡 手机派系频道 `faction.lua` | 好友、公会、组队系统 |

### S11 通讯（A）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 手机基础 | ✅ 通话/短信分页/联系人/通知/设置/铃声/调度 TTS | 换号、丢机、套餐/电量 |
| App 矩阵 | ✅ 11 个：Contacts, Messages, Banking, Notifications, JobBoard, FactionChannel, CityFeed, Settings, PhoneCall, Garage, Hotlines；领袖 3 个：Mayor/Sheriff/GangBoss | **硬编码 `import`（`App.svelte:2-20`），无 `PhoneApps` 注册表** → 每加一个 App 改核心文件 |
| 相机/相册 | ❌（`phone_gallery` 表存在但无 App） | 拍照/分享/CityFeed 配图 |
| 其他常用 App | ❌ | 邮件、地图/导航、Marketplace、音乐、社交媒体、天气、时钟、笔记 |
| 语音 | ✅ `pma-voice` 1781（含无线电） | 频道权限、语音质量分级 |

### S12 任务与叙事（B）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 任务引擎 | ✅ `custom-quest` 14901 行 / 61 文件（状态机、12 种步类型、外部 API、DB 持久化） | 任务编辑器/内容流水线 |
| 内容量 | ✅ 31 个 quest 配置（cartel 4 章、civilian 4 章、police 4 章、miner/driver/pilot/logistics…） | 内容之间无全局进度视图 |
| 剧情 | ✅ `story-engine` 1322（决策树） | 与 world_state 联动的长期后果 |
| 涌现/多人 | ❌（design 01「预设→涌现漏斗」） | 动态事件、多人协作任务、季节赛 |

### S13 运营与安全（C）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 层 0–4 安全链 | ✅ `custom-security` 380 + `custom-crime` 500 + `core-framework` SecurityService | 客户端注入检测、事件伪造的全量覆盖 |
| 审计/日志 | ✅ `custom-logs` 194（Discord webhook） | 日志检索、玩家行为画像 |
| 管理工具 | ✅ `qb-adminmenu` + `custom-admin` 514 | 封禁申诉、举报工单、影子管理 |
| 反作弊 | ❌ | **无专门反作弊**（`monitor` 6135 行 ⛔） |
| 白名单/准入 | ❌ | 申请表单、Discord 角色同步、连接队列（`connectqueue` 1013 ⛔） |
| 自测框架 | ✅ `custom-testing` 2430（`/test` 298 用例） | 实机回归无法自动化 |

### S14 表现层/交互（B）

| 模块 | 现状 | 缺口 |
|---|---|---|
| HUD/计分板 | ✅ `qb-hud` 2153 + `qb-scoreboard` 219 + `hud-position-tool` | 情景 HUD（驾驶/受伤/通话）差异化 |
| 交互范式 | ✅ `qb-target` 1897 + `qb-menu`/`qb-input` + 规范文档 | 菜单/通知/进度条的统一组件层 |
| 主题/BGM | ✅ `tcity-atmosphere` 600 + `custom-ui` 113 | — |
| 本地化 | 🟡 `sets locale "zh-CN"`；`production-freeze` 有 i18n | **只有中文**；v1.4 多语言 spec 未开工 |

### S15 世界与环境（C）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 时间/天气 | ✅ `qb-weathersync` 1462（事件溯源+漂移修正） | 灾害天气、极端天气玩法 |
| 地图/IPL | ✅ `bob74_ipl` 12124 + `hospital_map` + `dealer_map` | MLO 内容管线、新区域（岛屿/沙漠营地） |
| 场景道具 | 🟡 `cartel-gates` 606 | 动态事件布景（事故/封锁/演唱会） |

### S16 AI Agent 层（A）

| 模块 | 现状 | 缺口 |
|---|---|---|
| 动作代理 | 🟡 `custom-director` 7113（18 动作，L1–L4） | **未在任何 CFG / template 中 ensure** |
| 客户端效果 | ✅ `custom-agent-client` 856（6 个动作 + `agent_effects` 审计） | 新效果类型 |
| 工具契约 | ✅ `tools/agent_tools.json` 34 工具 → MCP/文档/Lua 镜像 | 工具覆盖玩法系统偏少（多为只读） |
| 评测/冒烟 | ✅ `agent_eval.py` / `agent_smoke.py` / 双层 harness | 真机长期运行数据 |

### S17 交付与运维（B）

| 模块 | 现状 | 缺口 |
|---|---|---|
| CI | ✅ 6 个 job（CFG/依赖、Python、Lua、Docs、Sonar、NUI） | 无性能基线与回归阈值 |
| 数据库 | 🟡 `migrations/` 16 个（v0.7–v2.7）+ `tests/fixtures/tcity_schema.sql` 47 表 | **核心业务表（银行/组织/矿业/市场/仓储/司法）没有迁移脚本**，只在 fixture 里 |
| 部署 | ❌ | 无 docker-compose / txAdmin recipe / 一键起服 |
| 监控/备份 | ❌ | 无 Prometheus/Sentry、无自动备份 |

---

## 3. 外部调研：主流 RP 服的系统/模块矩阵

> 调研对象：QBCore 官方资源库（71 仓库）、CommunityOx/Overextended（ox_* 生态）、Qbox 文档、Project Sloth、lb-phone、Cfx 发布区。
> 每条结论后附来源。抓不到的内容标 **UNVERIFIED**。

### 3.1 框架生态的系统分层（三方对照）

| 层 | QBCore 官方 | ox / Overextended | Qbox |
|---|---|---|---|
| 核心 | qb-core（Player/Shared/服务） | ox_core（玩家/载具/分组/账户/持久化） | qbx_core + modules/ |
| 数据 | oxmysql | oxmysql（事实标准） | oxmysql |
| 交互 | qb-target / qb-menu / qb-input | ox_target / ox_lib（UI、回调、工具） | ox_target + ox_lib |
| 物品 | qb-inventory（槽位） | ox_inventory（槽位 + metadata、商店/储物/制作/耐久） | ox_inventory |
| 载具 | qb-garages / qb-vehicleshop / qb-vehiclekeys / qb-fuel | ox_core 载具持久化 | qbx_vehicles |

来源：
- QBCore 组织 71 仓库、仓库描述（qb-core / qb-inventory / qb-vehiclekeys / qb-ambulancejob / qb-busjob / qb-crafting / qb-truckerjob / qb-prison / qb-smallresources …）— https://github.com/qbcore-fivem?tab=repositories
- ox 生态资源清单（ox_inventory「slot-based inventory with metadata」、ox_core「player and vehicle management and persistence」、ox_target「standalone third-eye targeting」、ox_lib、oxmysql）— https://github.com/CommunityOx
- Overextended 自述：oxmysql 成为 FiveM 事实标准、ox_lib 为框架无关的公共库 — https://overextended.dev/
- Qbox：基于 QBCore 的现代化重写，模块化 `modules/`，QBCore 生态向后兼容 — https://docs.qbox.re/、https://github.com/Qbox-project/qbx_core

> **对本服的启示**：T-City 已经自建了 ox 生态里「本该由 ox_inventory 提供」的东西（`custom-market`、`custom-storage`），却把 `ox_inventory` 最核心的两块——**商店（shops）与制作（crafting）**——留空了。ox_inventory 把 shop/stash/crafting 作为同层能力，本服只做了 stash 一侧。

### 3.2 手机：模块级对照（lb-phone 的 App 矩阵）

| 类别 | lb-phone 自带 App（实测文件清单） | T-City `custom-phone` |
|---|---|---|
| 系统 | Phone, Messages, Mail, Notes, Clock, Weather, Maps, Camera, Services, Settings | ✅ 通话/短信/设置 ❌ 邮件/笔记/时钟/天气/地图/相机/服务 |
| 框架 | Garage, Home, Wallet | 🟡 Garage ✅ / ❌ Home / 🟡 Banking 近似 Wallet |
| 社交 | Instagram, Twitter(Birdy), Tinder, DarkChat | 🟡 CityFeed（近似动态流）+ FactionChannel |
| 生活 | Marketplace, Music, YellowPages | 🟡 JobBoard 近似 YellowPages；❌ 市场/音乐 |
| 扩展机制 | `AddCustomApp`/`RemoveCustomApp` 导出 + App Store（可付费下载、独立 UI） | ❌ **无注册表、无 App Store、硬编码 import** |

来源：lb-phone 文档（App 配置 `apps` 对象、`Config.CustomApps`、`AddCustomApp` 导出、`GetSocialMediaUsername`）— https://docs.lbscripts.com/phone/configuration/apps/ 、 https://docs.lbscripts.com/phone/custom-apps/ 、 https://docs.lbscripts.com/phone/exports/client-exports/ ；App 文件清单（default/ framework/ other/ social/ 四类）— 反编译清单 https://tria.ge/240804-1whfws1gpd/static1

> **结论**：`custom-phone` 的功能密度大约相当于 lb-phone 的 40%，但它缺的不是 App 数量，而是**扩展机制**——这也是 `docs/agent/police/BLUEPRINT.md` 把 `PhoneApps.Register/CanUse` 放在 Phase 0 的原因。

### 3.3 社区在做什么（发布区热度）

Cfx 发布区当月的热门条目集中在：**职业玩法包**（如「Multiplayer Builder Job — 12 Regions & 3 Machine Systems」）、**地图/MLO**、**季节活动**（Halloween / Ghost Hunting）、**库存 UI 皮肤**。全部同时标注 `qbcore`/`qbox`/`ox` 标签。

来源：https://forum.cfx.re/c/releases/7/l/top

> **启示**：社区供给的重心是「一条新职业玩法 + 配套地图」，而不是新框架。这正好对应本服最薄的一层——**S6 正当职业**（8 个空壳阶梯）。

### 3.4 参考实现抽查（GitHub API 实测，2026-10-31）

抽查 12 个系统在社区里的"标准实现"，用星标数当作社区投入的代理指标：

| 系统 | 参考实现 | 实测描述 / 星标 | 对本服的意义 |
|---|---|---|---|
| 房产 | [`qbcore-fivem/qb-houses`](https://github.com/qbcore-fivem/qb-houses) | "Housing and Furniture Script Used With QB-Core" ・ 48★ | 官方把"房 + 家具"做成**一个系统**；本服已躺在仓库 |
| 房产（进阶） | [`Project-Sloth/ps-housing`](https://github.com/Project-Sloth/ps-housing) | "Advanced housing system for QBCore" ・ **378★** | 全样本最高星 → 房产是**重资产系统**，不可能一次写完，必须分阶段 |
| 外观 | [`iLLeniumStudios/illenium-appearance`](https://github.com/iLLeniumStudios/illenium-appearance) | "fivem-appearance for qb-core and ESX framework, packed with a lot of features" ・ **332★** | 本服 G6（理发/纹身/衣柜）的现成参考，不是"加个菜单" |
| MDT | [`Project-Sloth/ps-mdt`](https://github.com/Project-Sloth/ps-mdt) ・ [`CommunityOx/ox_mdt`](https://github.com/CommunityOx/ox_mdt) | "MDT for QBCore" ・ **331★** ／ "Police MDT for ox_core" ・ 3★ | 两套生态都把 MDT 当独立系统；本服只有 3 块 HUD 浮层 |
| 调度 | [`Project-Sloth/ps-dispatch`](https://github.com/Project-Sloth/ps-dispatch) | "QBCore Dispatch" ・ **223★** | 本服是 5 个发件方各自 `policeAlert`，缺统一入口 |
| 商店 | [`qbcore-fivem/qb-shops`](https://github.com/qbcore-fivem/qb-shops) | "Shops For QB-Core" ・ 35★ | 官方实现就在本仓库目录里（未启用） |
| 管理 | [`Project-Sloth/ps-adminmenu`](https://github.com/Project-Sloth/ps-adminmenu) | "An admin menu for QBCore." ・ 129★ | 本服 `qb-adminmenu` + `custom-admin` 已覆盖 |
| 毒品加工 | [`Project-Sloth/ps-drugprocessing`](https://github.com/Project-Sloth/ps-drugprocessing) | "An advanced drug script" ・ 114★ | 本服 `qb-drugs` + `custom-cartel` 已覆盖 |
| 背包 | [`Project-Sloth/ps-inventory`](https://github.com/Project-Sloth/ps-inventory) | "Formally lj-inventory with updated UI" ・ 75★ | 本服 `qb-inventory` 够用 |
| 银行 | [`Project-Sloth/ps-banking`](https://github.com/Project-Sloth/ps-banking) | 53★ | 本服 `qb-banking` 够用 |
| 载具持久化 | [`Qbox-project/qbx_vehicles`](https://github.com/Qbox-project/qbx_vehicles) | "provides API to manage player owned vehicles" ・ 5★ | 本服 `custom-vehicles` 已超出该范围 |
| 油 / 门锁 | [`CommunityOx/ox_fuel`](https://github.com/CommunityOx/ox_fuel) ・ [`CommunityOx/ox_doorlock`](https://github.com/CommunityOx/ox_doorlock) | "Simplistic fuel resource meant for use with ox_inventory" ・ 7★ ／ 10★（TS） | 本服 `qb-fuel`/`qb-doorlock` 够用 |

> **可操作的结论**：在我抽查的 12 个系统里，星标前四（housing 378 / appearance 332 / MDT 331 / dispatch 223）中有**三个正是本服的缺口**（G2 房产、G6 外观、S3 的 MDT+调度）。社区投入最大的系统，恰好是本服规划最薄的系统——这不是巧合，而是"重资产 + 强体验"的系统最容易被"没时间"挤掉。
> ⚠️ 样本是**定向抽查**（11 个系统 + 若干备选），不是全量排名；星标只反映社区关注度，不等同于质量。

### 3.5 CC（Claude Code）独立调研

> 用 Claude Code CLI（`--allowedTools WebFetch`，固定 3 个 URL、每题一问、上限 12 轮，实际 5 轮收敛）独立抓取后汇总；与 §3.1–3.4 交叉核对，冲突处已标注。

**A. ox_inventory 的"物品获取"能力（来源：https://github.com/CommunityOx/ox_inventory ・ https://coxdocs.dev/ox_inventory）**

| 能力 | README 是否说明 | 一句话 |
|---|---|---|
| shops 商店 | ✅ | 按 groups / licenses 限制购买权限 |
| stashes 储物 | ✅ | 个人储物，按 identifier 绑定，每玩家独立实例 |
| metadata 元数据 | ✅ | 逐槽存储，支持唯一性 |
| durability 耐久 | ✅ | 物品随时间消耗/被移除 |
| crafting 制作 | **UNVERIFIED** | 首页 README 无制作章节（CC 未能证实；ox 文档站另有页面，未采信） |

> **对 S8 的印证**：T-City 只实现了"储物"这一侧（`custom-storage`），shops 与 crafting **两侧都空**——正好是 ox_inventory 明确列为独立能力的另外两项。

**B. 成熟 MDT 的最小功能集（来源：https://github.com/Project-Sloth/ps-mdt）**

| 模块 | 说人话 |
|---|---|
| 档案 Citizens | 可检索公民记录：身份、联系方式、就业、指纹、资产、逮捕与文书 |
| 通缉 Warrants | 法院令状，含到期、罪名等级计数、送达结案 |
| BOLO | 人/车通报，带状态与跨部门共享 |
| 案件 Cases | 卷宗，聚合报告，含承办人/优先级/状态/附件 |
| 报告 Reports | 协作式事件叙述，关联当事人、罪名、物证与访问限制 |
| 证据 Evidence | 物证登记、照片、保管链转移、挂接案件 |
| 车辆 Vehicles | 车牌查询、车主/注册、DMV 扣分、可选外部校验 |
| 罪名/罚金 Charges | 罪名分级 + 罚金/拘押/扣分（无独立"罚单"模块） |
| 其余 | Impound、Weapons、摄像头/执法记录仪/行车记录仪、地图巡逻、调度、排班、法庭/DOJ、IA、PPR、审计日志、**62 项权限** |

> **对 S3 的直接对标**：T-City 目前 `qb-policejob` 只提供了其中"车辆查询 + 部分罪名/罚单"的一小部分，`custom-documents` 提供证件展示；**档案、通缉、BOLO、案件、报告、证据链、摄像头/执法记录仪八块全缺**——这正是 `docs/agent/police/BLUEPRINT.md` 要补的范围，本文确认其分期是对的（不可能一次做完）。

**C. Qbox 的系统清单（来源：https://docs.qbox.re/）**

CC 只抓首页：可确认 "Qbox 是 QBCore 的现代化分支，保留对 QBCore 脚本的向后兼容，并声明使用 overextended 资源"；**具体资源清单在首页不可见 → UNVERIFIED**（不追加深，避免重复 §3.1 已有的 `qbx_core/modules` 事实）。

**D. CC 的局限（如实记录）**

- 第一轮（开放 prompt + 自由追链）跑到 **111 个 assistant turn 仍未收敛**，被迫终止；第二轮改为"3 个 URL、每题一问、12 轮上限"后 5 轮完成。**结论：给 CC 的自由度必须与输出预算一起限定，否则它会把预算全花在抓取上。**
- CC 自报的 `tool_use` 记录已用于交叉核对；凡它未能从页面证实的（ox crafting、Qbox 资源清单）一律标 UNVERIFIED，未替换为推测。

## 4. 缺口清单（按可行动性分类）

### 4.1 E 级：规划真空 —— 必须从零写设计

| # | 系统/模块 | 为什么算真空 | 最小闭环必须包含 |
|---|---|---|---|
| G1 | **物品获取**（商店/制作/消耗品） | 饥饿/口渴在 `qb-core` 里衰减并扣血，但**补不回去**：购买只有自动售货机（可乐/水，`qb-inventory/config/config.lua:39`），吃喝的用法注册在未启用的 `qb-smallresources`（`consumables.lua` 18 项），`qb-shops`(2578) 与 `qb-crafting`(600) 均未启用 | 店类型与点位、库存与补货、服务端定价与防刷、走 `core_economy` 扣款、**先把 consumables 单独拆出来启用**、制作台与配方经济 |
| G2 | **房产与所有权** | `qb-houses` 5140 行 + 989 行配置躺着不启用；`custom-taxes` 在收 `property_tax` 但**没有购房系统**；`server-design/00-05` 整卷讲"所有权"却无落地设计 | 产权与产权转移、按揭/租金、家具与摆放持久化、门锁/储物联动、水电费、房产中介职业、法拍与欠税回收 |
| G3 | **玩家企业** | `jobs.lua` 有 20 个职业，全是政府/既定雇主；**没有任何"玩家拥有企业"的表、资源或文档**（`company` 仅出现在 qb-core 的 boss 菜单语境内） | 企业注册与许可、雇员与薪资发放、营收与税务、供应链（进什么货、卖什么价）、所有权转让 |
| G4 | **保险** | `insurance` 全仓仅 3 处提及（qb-core/production-freeze/custom-taxes 各 1，均非玩法） | 车险（保费/免赔/理赔勘察/全损折旧）、医保（急救费用与报销）、寿险（死亡赔偿） |
| G5 | **医疗记录与毒理** | `qb-ambulancejob` 只管生命值；无 EMR、无药物、无检测 | 病历（诊断/用药/过敏）、处方与药房、毒品/酒精检测、伤情鉴定书（警察 BLUEPRINT 依赖） |
| G6 | **外观系统** | `qb-clothing` 只是换装菜单；理发/纹身各 1 处字符串，无资源、无表 | 理发店/纹身店/化妆、衣柜持久化与快速换装、职业制服与装备预设、跨机外观同步 |
| G7 | **反作弊/准入/申诉** | `monitor` 6135 行 ⛔、`connectqueue` 1013 行 ⛔；无白名单、无举报工单、无封禁申诉 | 事件签名与客户端注入检测、白名单申请（Discord 角色）、举报工单、封禁申诉与公示 |
| G8 | **娱乐内容层** | 钓鱼/打猎/赌场/竞速全真空（`racing` 只在 `qb-lapraces` 与 `qb-phone` 里出现，两者都 ⛔） | 至少一条"非经济"的放松玩法（钓点/猎区/赌场桌面/计时赛）与其奖励边界 |
| G9 | **新手引导** | 无 onboarding 资源、无首小时脚本 | 出生后的 30 分钟动线、教学任务、首次收入、防走失（新手保护） |

> G1+G2 是本轮调研发现的两处**结构性断裂**：生存循环（饿）与所有权循环（买房）都没有闭合，而它们恰好是 `server-design/00` 与 `server-design/02` 的立论基础。

### 4.2 D 级：库存未决 —— 缺的不是代码，是取舍决策

**实测：33 个资源未被任何 CFG 引用，合计 56,457 行 Lua**（另有 7 个 `[...]` 是 CFG 分组目录，不计）。其中纯玩法（排除框架重复体 `qb-phone`/`qb-smallresources`/`qb-radialmenu`/`monitor` 与工具）约 **35,000 行**：

| 类别 | 资源（行数） | 文档里给的说法 | 建议 |
|---|---|---|---|
| 房产 | `qb-houses` 5140（989 行配置） | 「被 custom-* 替代规划中」——从未有替代设计 | **改判：直接接管 qb-houses 的 schema（`houselocations`/`player_houses`/`house_plants` 已在 fixture），只重写 UI 与权限** |
| 商店 | `qb-shops` 2578（844 行配置：normal/liquor/hardware/weapons/blackmarket/prison/police/ambulance/mechanic/ltdgasoline 等 13 类） | 「未列入当前版本」 | **P0 启用 + 接 `core_economy` 扣款；这是最快补上 G1 的路径** |
| 制作 | `qb-crafting` 600（176 行配置） | 「未列入当前版本」 | P1，需先定"制作 vs 采购"的经济分工 |
| 正当职业 | `qb-taxijob` 1896、`qb-hotdogjob` 1758、`qb-garbagejob` 1499、`qb-towjob` 1098、`qb-recyclejob` 1047、`qb-newsjob` 1027、`qb-busjob` 998、`qb-vineyard` 902、`qb-diving` 1370 | 全部「未列入当前版本」 | **做一个"职业取舍矩阵"：留 3–4 个接入 `custom-quest` 作为日常循环，其余删阶梯**（`jobs.lua` 里已定义却无人干活的 8 个职业一并处理） |
| 抢劫扩展 | `qb-bankrobbery` 2771、`qb-jewelery` 762、`qb-truckrobbery` 581 | 「v0.5+ 犯罪扩展」 | P2，与警察 MDT/调度一起上（否则警力接不住） |
| 竞速 | `qb-lapraces` 1489、`qb-streetraces` 458 | 「v0.5+ 竞速扩展」 | P2（G8 的现成底料） |
| 车辆二手 | `qb-vehiclesales` 1459 | 「未列入当前版本」 | P1（`occasion_vehicles` 表已在 fixture） |
| 其他 | `qb-weed` 741、`qb-scrapyard` 634、`qb-crypto` 821、`qb-radialmenu` 3829、`qb-smallresources` 2947、`qb-phone` 3651 | 各有延期理由 | crypto 建议**明确不做**（见 §5）；radialmenu/smallresources 需逐项挑选而非整包启用 |

### 4.3 C/🟡 级：半成品 —— 有代码没闭环

| 位置 | 症状 | 影响 |
|---|---|---|
| `custom-justice` 1006 | 案卷/刑期全在内存（`activeCases`/`inmates`）；`justice:server:registerArrest` 的**唯一入口是自带命令 `/arrest`**（`arrest.lua:161`），`qb-policejob` 的逮捕流程完全不调用它 | 重启即清空；司法链只能靠手动命令驱动 |
| `custom-economy` 62 行 | 近乎空壳，真正的网关在 `core_economy`（293） | 两套 EconomyService 并存（手册技术债 #1） |
| `custom-director` 7113 | **不在任何 CFG / `server.cfg.template` 里** | 部署态起不来 Agent 栈 |
| `custom-phone` App 层 | 硬编码 `import`（`App.svelte:2-20`），无 `PhoneApps` 注册表 | 每加一个 App 改核心文件；警察平板 App 无法独立注册 |
| `custom-taxes` `property_tax` | 收税对象（房产）不存在 | 税基空转 |
| `custom-cartel` | fxmanifest 声明 oxmysql 但**零 SQL**，状态纯内存 | 重启丢领地/产业链状态 |
| `atom_nodes` / `trust_graph` / `governance_proposals` | 有表（fixture 47 表里）但无系统消费 | 设计稿（design 01/03/04）未落地 |
| `dev.cfg` | 18 个 CFG 里唯一未被 template exec 的 | `custom-testing` 实际靠手动启动 |

### 4.4 优先级建议（相对工作量：S < 1 周 / M = 1–2 周 / L > 2 周）

| 优先 | 事项 | 对应缺口 | 工作量 | 理由 |
|---|---|---|---|---|
| **P0-1** | 启用 `qb-shops` + 接 `core_economy` 扣款 + 定 13 类店的定价策略 | G1 | S–M | 生存循环现在是断的；现成 844 行配置不用重写 |
| **P0-2** | 房产系统接管 `qb-houses` schema，重写 UI/权限，接 `custom-taxes` 与 `custom-storage` | G2 | L | 与 `server-design/00` 的"所有权"叙事直接对齐；税基同步复活 |
| **P0-3** | 职业取舍矩阵：8 个空壳职业 → 启用 or 删阶梯；v0.6a 渔民/农民出取舍结论 | §4.2 | S | 低成本清账，避免"有职业没工作"持续误导玩家 |
| **P0-4** | 部署一致性修复：`custom-director` 入 CFG、`dev.cfg` 入 template、文档数字对齐（78/17 → 82/18） | §4.3 | S | 现在"开发态 ≠ 部署态"，任何验收都不可信 |
| **P1-1** | 警察 BLUEPRINT Phase 0–1（PhoneApps 注册表 + MDT 平板 + 案卷落库） | G5 依赖 + §4.3 | L | 已有施工图，是全服最成熟的设计资产，早开工早收益 |
| **P1-2** | 医疗深化：病历 + 毒理 + 伤情鉴定（供警察/司法消费） | G5 | M | 警察/司法两条链都卡在这里 |
| **P1-3** | 载具保险 + 扣押拍卖 + 二手车（`qb-vehiclesales`） | G4 | M | 载具系统本身已是 A 级，补最后一段 |
| **P1-4** | 企业经济（G3）：先做"企业注册 + 雇员薪资 + 税"，供应链后置 | G3 | L | 与 `custom-market`/`custom-storage` 已有底座接得上 |
| **P2-1** | 外观系统（理发/纹身/衣柜持久化） | G6 | M | 体验层，不影响经济 |
| **P2-2** | 娱乐层：竞速（`qb-lapraces`）或钓鱼二选一 | G8 | M | 内容供给，可在 beta 前补 |
| **P2-3** | 反作弊 + 白名单 + 举报工单 | G7 | L | 公测（v1.0）前置，但需先定准入策略 |
| **P2-4** | 新手引导 + 监控/备份/部署自动化 + i18n（v1.4） | G9 | M | 上线工程化 |

---

## 5. 明确不建议做（省下来的时间给 P0）

| 不做 | 理由 | 证据 |
|---|---|---|
| `qb-crypto` / 股票交易所 | 与「不卖数值、经济受控」的付费铁律冲突；投机玩法会放大经济波动 | `server-design/06-payment-model.md` 的付费铁律；`qb-crypto` 821 行 ⛔ 且无任何设计引用 |
| 迁到 ox_inventory / Qbox | 自研 `custom-market`+`custom-storage`+`core_economy` 已成型；ox_inventory 的 metadata 能力可由现有槽位制补齐 | §3.1；迁移成本远高于补 `qb-shops` |
| 自建反作弊引擎 | 客户端注入检测维护成本极高，收益递减；优先做**事件签名 + 服务端复验**（已有五层安全链） | `00_SERVER_MASTER_MANUAL` §6 五层安全链 |
| 全套 MLO 内容生产 | 地图是美术资产不是系统；社区可买/可换 | §3.3 发布区现状 |
| 一次性启用 `qb-smallresources`/`qb-radialmenu` | 整包启用会引入与现有交互范式（qb-target + 手机）冲突的入口 | `menu-interaction-design.md` 已定范式 |

---

## 6. 证据索引

### 6.1 本地实测命令（可复现）

```bash
# 启用矩阵
grep -rhoE '^\s*ensure\s+[A-Za-z0-9_:-]+' T-CityLite.base/configs/modules/*.cfg | awk '{print $2}' | sort -u | wc -l   # 82
ls T-CityLite.base/configs/modules/*.cfg | wc -l                                                                        # 18
find T-CityLite.base/resources -mindepth 2 -maxdepth 3 -name fxmanifest.lua | wc -l                                     # 108
grep -E '^exec configs' T-CityLite.base/server.cfg.template | wc -l                                                     # 17

# 库存未启用资源及其规模
# （见 §4.2：40 个资源 / 60,093 行；纯玩法约 35k 行）

# 职业与承载资源
awk '/^\t[a-z]+ = \{/' T-CityLite.base/resources/\[qb\]/qb-core/shared/jobs.lua | wc -l                                  # 20
grep -rn "CreateShop" --include=*.lua T-CityLite.base/resources | wc -l                                                 # 4 个调用点

# 数据库
grep -ci 'create table' T-CityLite.base/tests/fixtures/tcity_schema.sql                                                  # 47
ls T-CityLite.base/migrations/*.sql | wc -l                                                                              # 16
```

### 6.2 外部来源

| 结论 | 来源 |
|---|---|
| QBCore 官方 71 仓库与各自职责 | https://github.com/qbcore-fivem?tab=repositories |
| ox 生态职责划分（ox_inventory 含 metadata；ox_core 负责玩家/载具持久化） | https://github.com/CommunityOx |
| oxmysql 成为事实标准、ox_lib 框架无关 | https://overextended.dev/ |
| Qbox 模块化结构与 QBCore 兼容性 | https://docs.qbox.re/ ・ https://github.com/Qbox-project/qbx_core |
| lb-phone App 矩阵与 `AddCustomApp` 扩展机制 | https://docs.lbscripts.com/phone/configuration/apps/ ・ https://docs.lbscripts.com/phone/exports/client-exports/ |
| lb-phone 自带 App 文件清单（default/framework/other/social） | https://tria.ge/240804-1whfws1gpd/static1 |
| 社区发布区供给重心（职业包/地图/季节活动/库存 UI） | https://forum.cfx.re/c/releases/7/l/top |
| qbx_properties / qbx_medical / ox_mdt 作为对应系统的参考实现 | 见 §3.5（CC 抓取记录） |

---

> **维护**：本文件是"规划缺口"的单一入口。补完一项就在 §4.1/§4.2 里划掉并链到新的设计文档（格式参照 `docs/agent/police/BLUEPRINT.md`）。
