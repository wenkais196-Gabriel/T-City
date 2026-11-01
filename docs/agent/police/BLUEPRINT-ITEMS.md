---
id: agent-police-blueprint-items
type: spec
status: active
system: justice
owner: hermes
updated: 2026-11-01
review_by: 2027-04-30
supersedes: [agent-police-blueprint-items-v1]
---

# 警察道具层蓝图（Items & Props）v2

> **状态**：设计稿 v2（已合并两份独立调研），未实现。日期 2026-10-30。
> **范围**：警察**手上拿的、地上摆的、身上戴的**东西 —— 道具定义、配发链路、使用与回收、与案卷/调度的接线。
> **不含**：MDT 页面、调度状态机、AI 支援单位（见 [`BLUEPRINT.md`](BLUEPRINT.md) 的 P2/P3/P5）。
> **配套**：[`ACCEPTANCE.md`](ACCEPTANCE.md) §3.8（验收标准 AC-IT-*）、[`BLUEPRINT-ITEMS-CC.md`](BLUEPRINT-ITEMS-CC.md)（Claude Code 独立版，原样保留）。
> **两份稿子的分歧与裁决**：见本文 §11。

---

## 0. 结论摘要

1. **真正的问题不是"缺道具"，是"没有配发链路"**：`qb-policejob` 里 `inArmoury` 只声明从未使用，`Config.Departments[*].weapons` 全仓 0 引用——**军械库和部门武器配发都是死配置**。警察现在能拿到的道具只有车尾箱那三样。
2. 道具系统已有**成熟范式**可抄：`QBShared.Items` 定义 + `CreateUseableItem` 注册 + `qb-inventory` 的 `AddItem/RemoveItem(..., reason)` 审计 + `info` 实例元数据（`filled_evidence_bag` 就是这么带血样数据的）。
3. **顺手查出两个真缺陷**：证据袋的 `info` 由客户端传入、服务端不复验（可伪造 DNA/序列号）；`Config.MaxSpikes` 的判定在客户端且差一（配 5 实际只能放 4，改客户端可无限放）。做道具层必须先修这两处。
4. **钉刺带是反例**：`/spikestrip` 是命令、不消耗道具、只有客户端列表上限、重启即失。把它做成道具，比新增任何酷炫工具都值。
5. 外部生态最值得抄的是**"每个工具一个 item、按 job/grade 限制"**（Pickle 现售包价 30 美元、只有 6 件，且**不含**雷达/钉刺带/取证——所以不该买包，该自建）。
6. 道具分三类产出，必须事先定死：**只读数**（测速枪）、**读数 + 证据行**（酒测/毒品快检/指纹）、**读数 + 调度事件**（panic）。混在一起就会变成"查了但没人看得见"。
7. 部署物（锥桶/护栏/警戒带/钉刺带/证据牌）必须有主：**服务端登记 + 可回收 + 重启清 prop 但保留背包道具**。这是现在 `Config.Objects` 最大的漏洞。

---

## 1. 现状审计（仓库实测）

### 1.1 道具的定义与通道

| 环节 | 现状 | 证据 |
|---|---|---|
| 定义 | `QBShared.Items` 单表，字段 `name / label / weight / type / image / unique / useable / shouldClose / description`；**没有数据库表** | `T-CityLite.base/resources/[qb]/qb-core/shared/items.lua` |
| 注册可用 | `QBCore.Functions.CreateUseableItem(name, fn(source, item))`（服务端），再 `TriggerClientEvent` 通知客户端 | `T-CityLite.base/resources/[qb]/qb-core/server/functions.lua`；`qb-smallresources/server/consumables.lua:4-11` |
| 增删物品 | `exports['qb-inventory']:RemoveItem(src, name, amount, slotOrFalse, reason)` / `AddItem(src, name, amount, slot, info, reason)` | `qb-policejob/server/evidence.lua:97-151` |
| 实例元数据 | `info` 表随物品走；`unique = true` 表示唯一实例 | `filled_evidence_bag` |
| 图片 | `qb-inventory/html/images/` 共 292 张 PNG；每个新道具要一张 | 目录统计 |

### 1.2 警察手上已经有什么

| 道具 | 状态 | 证据 |
|---|---|---|
| `handcuffs` | 可用物品，走 `HasItem(Config.HandCuffItem)` 校验（**只查道具，不查 grade**） | `qb-policejob/server/main.lua:285`、`client/interactions.lua:265` |
| `police_stormram` | 可用物品（破门） | items.lua；`Config.CarItems[3]` |
| `empty_evidence_bag` / `filled_evidence_bag` | 采集血液/指纹/弹壳时消耗前者、产出后者（带 `info`） | `server/commands.lua:339-345`、`server/evidence.lua:97-151` |
| `heavyarmor` / `empty_evidence_bag` / `police_stormram` | **车尾箱三件套**（`Config.CarItems`，实现于 `SetCarItemsInfo`） | `config.lua:135-139`、`client/job.lua:49-69` |
| `radio` / `radioscanner` / `moneybag` / `armor` / `heavyarmor` | 定义齐全；`armor`、`heavyarmor` 可用（qb-smallresources） | items.lua:355-356；`qb-smallresources/server/consumables.lua:70` |
| 武器 | `weapon_handcuffs` / `weapon_nightstick` / `weapon_flashlight` | items.lua |

### 1.3 三类"有代码但没接上道具"的能力

| 能力 | 现状 | 缺什么 |
|---|---|---|
| **军械库** | `inArmoury` 变量声明后从未使用；`Config.ArmoryWhitelist = {}` 也没人读 | 整个配发界面与 grade 门禁 |
| **部门武器配发** | `Config.Departments[PATROL/TRAFFIC/CID/SWAT].weapons` 全仓 0 引用 | 一个读它的地方（现在就等于注释） |
| **钉刺带** | `/spikestrip` 命令 + `Config.MaxSpikes = 5`；不消耗道具；只有 netid 同步 | 道具化、次数/耐久、回收、清理 |
| **部署物件** | 锥桶/护栏/路牌/帐篷/照明灯，`CreateObject` + `NetworkGetNetworkIdFromEntity` + 删除事件 | owner、落库、上限、重启清理 |

### 1.4 顺手查出来的两个真缺陷（做道具层时必须先修）

| 缺陷 | 证据 | 后果 | 修法 |
|---|---|---|---|
| **证据袋的 `info` 由客户端传入，服务端不复验** | `evidence:server:AddBlooddropToInventory(bloodId, bloodInfo)`（`server/evidence.lua:96`）；`fingerInfo` / `casingInfo` 同理 | 改过的客户端可以伪造 DNA、弹壳序列号——**证据本身可造假，保管链再完整也没意义** | 服务端按 `bloodId/fingerId/casingId` 从自己的世界登记表取 payload，只信 id |
| **`MaxSpikes` 判定在客户端且差一** | `if #SpawnedSpikes + 1 < Config.MaxSpikes`（`client/objects.lua:214`），配 5 实际最多 4；列表在客户端 | 上限形同虚设；两名警员各算一份 | 服务端计数 + 每玩家/全局双层上限 |

### 1.5 qb-smallresources 给了什么（可复用 / 会影响道具层）

| 能力 | 对道具层的意义 |
|---|---|
| **可用双筒望远镜**（相机 FOV 缩放，`Config.Binoculars`） | 观察类道具已有现成实现，不要再写一个 |
| **可用护甲 `armor` / `heavyarmor` / 跳伞 `parachute`** | 就是"可用道具"的标准范式（`CreateUseableItem` + `RemoveItem(..., reason)` + 客户端演出） |
| **Tackle（扑倒，`LMENU`）** | 已有警察动作，但**无道具、无职业校验**（任何玩家都能扑）→ 应收进道具层 |
| **移除了 GTA 默认通缉系统、默认警察/救护 NPC、全部分支调度服务**（`Config.AIResponse` 15 项全 false） | 街上没有原版警察 → 道具层是玩家唯一执法手段；**这也是"自动罚单"不成立的根本原因**（没有 NPC 兜底，罚单必须由玩家开） |

---

## 2. 外部调研

来源：Pickle Police Tools 现售包（rpscripts）、Pickle's Police Job 与已停更的 Pickle's Police Tools、Advanced Police Job、wasabi-police v2、oxide-police、Codesign Radar/ALPR、RS9000、crime-scene tape 系列。

### 2.1 功能矩阵（只列"道具型"工具）

| 道具 | Pickle 现售 | Advanced Police Job | wasabi v2 | oxide-police | 备注 |
|---|---|---|---|---|---|
| 钉刺带 | — | ✓ | ✓ | ✓ | 三家有，刚需 |
| 锥桶/护栏/照明 | — | ✓（item 放置、全玩家同步） | ✓ | ✓ | 部署物 |
| 测速雷达 | — | ✓（车载内置） | ✓（雷达枪 + 雷达柱） | ✓（`WEAPON_RADAR` + 车载） | 形态三种，见 §2.2 |
| ALPR 车牌识别 | — | — | 未记载 | ✓（常设相机） | 本服已有静态 `Config.Radars` |
| 酒测 breathalyzer | — | ✓ | ✓ | ✓ | 产证据 |
| 指纹 / 血 / GSR | — | ✓（指纹） | ✓（血/弹壳/指纹/GSR） | ✓（GSR/弹道/车辆指纹） | 产证据 |
| 毒品快检 | — | — | 未记载 | — | 外部少见 |
| 证据牌 / 警戒带 | — | — | 未记载 | — | 独立品类（有 MIT 开源实现） |
| bodycam | ✓ item | ✓ item | ✓ | ✓ | 见 P4 |
| 行车记录仪 | — | ✓ item | — | — | 多数并入 bodycam |
| 盾牌 | ✓（2 种） | ✓（金属/玻璃） | — | — | 对峙用 |
| 蛇眼 / 抓钩 / 刺棍 | ✓ / — / — | — | — | — | 高成本玩具 |
| NVG / 热成像 | ✓（头盔集成） | ✓ item + 开关 | — | — | 装备附属 |
| panic 按钮 | ✓ `/panic` + item | — | 有 panic 警报 | — | 小服最实用 |
| 扎带 / 断线钳 / 轮锁 / 口塞头套 | — | — | ✓ 扎带/断线钳/钥匙 | ✓ 扎带/口塞/头套/轮锁 | 低技术高 RP |

### 2.2 两个反直觉的外部结论（决定了本蓝图的重心）

1. **没有一家把 ALPR 做成实体道具**：Codesign 是纯车机 UI（4 路相机、自动锁、BOLO、日志），RS9000 是车内面板（前后天线、50 m 量程），APJ 是内置车载雷达，wasabi 是雷达枪（未给 item ID），oxide 是 `WEAPON_RADAR` 武器码。**"雷达道具"这件事，业内主流是 UI 而不是物品。**
2. **现售的"道具包"其实很小**：Pickle 现售包 30 美元、只有 6 件（含 `police_panic` / `police_shield` / `police_bodycam` / `police_snakecam`），**不含雷达、钉刺带、取证**。所以本服不该买包，而应把已有的 prop 系统、证据袋、dispatch 总线接起来。

### 2.3 可直接抄的产品判断

- **"item-based system" 是卖点而不是限制**：Pickle 把「所有工具都是实体道具、需要采买与管理」写成第一条卖点。道具的价值来自**稀缺与配发**，不是功能本身。
- **警戒带/证据牌已是独立品类**：有开源（`bebecito_policetape`，MIT、OneSync、NPC 对现场有反应、自动清理）与多个付费实现 → **不必自研渲染，必须自研数据绑案卷**。
- **测速枪的差异在读数可信度**：RS9000 的用户抱怨旧雷达"明明 50 报 60"→ 读数算法（单帧 `GetEntitySpeed` vs 多帧中位数）直接决定道具能不能用于定罪。
- **命名前缀有先例**：Pickle 用 `police_*`（`police_panic` 等）→ 本蓝图沿用（DI-8）。

---

## 3. 设计决策（DI）

| ID | 决策 | 理由 | 反方案 |
|---|---|---|---|
| **DI-1** | **三级校验**：grade（资格）→ item（手上有没有）→ 世界条件（距离/目标/场景）；三关全在服务端判 | 客户端按钮不是权限；`handcuffs` 现在只查 item 不查 grade | 只在客户端查 → 等于没有门禁 |
| **DI-2** | 道具定义不进 DB，用 `QBShared.Items`；实例数据走 `info`（`serial/owner/uses/deployed`） | 与全仓一致，证据袋已验证 | 建 `police_items` 表 → 双写漂移 |
| **DI-3** | 消耗三档：**一次性**（flare/tape/扎带/试纸）、**持久**（radar/breathalyzer/cuffs/camera/盾）、**次数型**（钉刺带、破门锤，`info.uses`） | 全一次性太贵，全持久没有稀缺感 | 全部一次性 → 出勤前先逛商店 |
| **DI-4** | 部署物必须有主：服务端登记 `{id, netid, owner, kind, at}`，可回收，**上限超限拒绝而不是静默删旧** | 现在只有 netid 列表，谁放的/放多久/怎么清都不知道 | 继续用客户端表 → 重启后幽灵锥桶 |
| **DI-5** | **军械库先做**，否则一切道具无处配发 | `inArmoury` 是死代码，部门武器配置是死配置 | 先做道具 → 玩家拿不到，无法验收 |
| **DI-6** | 工具产出必须分级声明：只读数 / 读数 + 证据行 / 读数 + 调度事件 | 否则"查了但没人看得见"（这正是现在 911 的毛病） | 统一弹通知 → 全是噪音 |
| **DI-7** | 枪型工具（测速枪/酒测仪）用 **prop + 动画**，不占武器槽 | 占武器槽与武器轮、`weapon_*`、收缴逻辑打架 | 做成 `weapon_*` → 与 qb-weapons 冲突 |
| **DI-8** | 命名规范：`police_` 前缀 + snake_case + 中文 label + 一句描述 + **必须附 PNG** | 道具靠图片辨认，缺图就是一格白块 | 随手起名 → 图标混乱 |
| **DI-9** | 车尾箱（`Config.CarItems`）与军械库**读同一份道具目录** | 现在两处各写各的，必然漂 | 分开配置 |
| **DI-10** | 不新增轮盘、不新增第二套交互：一律「库存使用」+「qb-target 对准目标」+「车机」 | 轮盘已有 qb-radialmenu，再叠一层会乱 | 自建 F 键菜单 |
| **DI-11** | **重启策略**：prop 全清（不复原）、背包道具保留（含 uses），并在日志记录清理数量 | 复原 prop 需要落库；丢道具会引发"我的钉刺带呢" | 全落库复原 → 表膨胀、坐标失效 |

---

## 4. 道具清单

图例：**需图** = 需要新 PNG；**产出** = 读数 / 证据 / 调度。

### 4.1 PI-0 配发底座（与主蓝图 P0 同期，**先做这个**）

| 项 | item name | 重量 | 消耗 | 获取 | 产出 | 需图 |
|---|---|---|---|---|---|---|
| 军械库（界面+服务，不是道具） | — | — | — | 站点 | — | — |
| 部门配发（复活死配置） | — | — | — | 军械库按 grade/部门 | — | — |
| 钉刺带（改造） | `police_spikestrip` | 1500 | 次数型（`info.uses = 3`） | 军械库 | 部署物 | ✓ |
| 锥桶 / 护栏 / 照明灯（改造） | 复用 `Config.Objects` 键 | — | 持久（部署/回收） | 军械库 | 部署物 | 已有 prop |
| panic 按钮（轻量） | `police_panic` | 200 | 持久 | 军械库 | 调度事件（最高优） | ✓ |

### 4.2 PI-1 盘查与取证（与 P3/P4 同期）

| 道具 | item name | 消耗 | 产出 | 优先级 |
|---|---|---|---|---|
| 指纹套件 | `police_fingerprint_kit` | 持久 | 证据（`kind=fingerprint`） | P0 |
| 酒测仪 | `police_breathalyzer` | 持久（吹嘴一次性） | 读数 + 证据（BAC） | P0 |
| 毒品快检试剂 | `police_drugtest_kit` | 一次性 | 证据（延迟：疑似→确认） | P1 |
| GSR 套件 | `police_gsr_kit` | 一次性 | 证据（开枪残留） | P1 |
| 血检套件 | `police_blood_kit` | 一次性 | 证据（复用证据袋 `info` 结构） | P1 |
| 扎带 | `police_zipties` | 一次性 ×10 | 约束动作（低阶替代手铐） | P1 |
| 证据牌（1–20） | `police_evidence_marker` | 持久 | 部署物 | P1 |
| 警戒带 | `police_tape` | 一次性（一段一次） | 部署物 | P1 |

### 4.3 PI-2 交通执法（与 P3 同期）

| 道具 | item name | 消耗 | 产出 | 优先级 |
|---|---|---|---|---|
| 测速枪（手持） | `police_radar` | 持久 | 读数（可选存为证据） | P0 |
| 车牌识别（车载） | 复用现有 `Config.Radars`（9 个静态点） | — | 读数 + 通缉比对 | 已有，只补 UI |
| 照明弹 flare | `police_flare` | 一次性 | 部署物（照明 90 s） | P1 |
| 轮锁 | `police_wheelclamp` | 持久 | 部署物 + 证据（车牌+照片） | P2 |
| 停车棒 | `police_stopbaton` | 持久 | 纯演出（拦停流程） | P2 |

### 4.4 PI-3 现场与后勤

| 道具 | item name | 消耗 | 产出 | 优先级 |
|---|---|---|---|---|
| 拖车 / 验尸调度 | 手机 App（不是道具） | — | 调度事件 | P2 |
| 断线钳 | `police_boltcutters` | 次数型（耐久 5） | 开锁/切铐（对 `qb-doorlock`） | P2 |
| 防暴盾 | `police_shield` | 持久 | 掩体（SWAT grade 2 起） | P3 |
| 夜视 / 热成像 | 装备附属（**不单列 item**） | 持久 | 视觉 toggle | P3 |

### 4.5 明确不建议

| 不做 | 理由 |
|---|---|
| 口塞 / 头套（mouth tape、headbag） | 没有系统功能，只有贴图；滥用风险高 |
| 蛇眼摄像头 / 抓钩 / 刺棍 | 第二摄像头/物理同步，成本高、一年用不了几次 |
| K9 / 无人机 | 寻路+动画+图传+权限，10–30 人服养不起专职操作员 |
| 全量 ALPR 摄像头网 | 热榜维护、误报、隐私争议；本服已有 9 个静态点够用 |
| **自动测速罚单** | 本服已移除默认警察 NPC，**罚单必须由玩家开**；自动罚单绕过 RP |
| 独立 bodycam/行车记录仪两套存储 | 合并为 bodycam 一套（见主蓝图 P4） |
| 独立防弹衣道具 | qb-smallresources 已有 `armor`/`heavyarmor`，重复 |
| 第二套手铐系统 | 现有 `handcuffs` 可用；扎带只作"大规模拘捕"补充 |

### 4.6 生命周期（一表定死：拿 → 用 → 耗 → 收 → 留痕）

| 道具 | 获取 | 使用入口 | 消耗 | 回收/上限 | 留痕 |
|---|---|---|---|---|---|
| 扎带 | PATROL 0 | 对已控制玩家（qb-target） | 一次性 | 无 | 审计 |
| 锥/护栏/照明 | PATROL 0 | 库存使用（放置） | 持久 | qb-target 回收；每类 5/人、30 全局 | deployment |
| 钉刺带 | TRAFFIC 1 / PATROL 1 | 库存使用（放置） | 次数 3 | 回收复位 uses；2/人、20 全局 | deployment + 审计 |
| 证据牌 / 警戒带 | PATROL 1 | 库存使用（放置） | 牌持久 / 带一次性 | 牌可回收；带不回收 | evidence |
| 酒测 | TRAFFIC 1 / PATROL 1 | 对准目标（qb-target） | 主机持久 + 吹嘴一次性 | 无 | evidence + 审计 |
| 指纹 / 血 / GSR | CID 1 | 对准物/人/车 | 试剂一次性 | 无 | evidence |
| 毒品快检 | CID 1 | 对准物品 | 一次性 | 无 | evidence（延迟） |
| 测速枪 | TRAFFIC 1 | 库存使用（举枪） | 持久 | 无 | 读数；罚单时入案 |
| panic 按钮 | 全员 0+ | 库存使用 / 快捷键 | 持久 | 无 | 调度 + 审计 |
| bodycam | PATROL 1 | 库存使用（开关） | 持久 | 无 | 审计 + 案卷引用 |
| GPS 追踪器（P2） | CID 2 | 对准车辆 | 持久（电池 30 min） | 回收 | 案卷 + 调度 |
| 防暴盾 | SWAT 2 | 库存使用（装备） | 持久 | 回军械库 | 审计 |
| 断线钳 | CID 2 | 对准门/铐 | 次数 5 | 无 | 审计 |
| 轮锁 | TRAFFIC 1 | 对准车轮 | 持久 | 解锁回收 | evidence + 审计 |

---

## 5. 关键道具规格

### 5.1 钉刺带（把 `/spikestrip` 改成道具）

```
Given 警员手持 police_spikestrip、grade ≥ 1、on duty
When  在道路上使用道具
Then  生成部署物（服务端登记 owner/netid/coords/at）
      info.uses 减 1；归零时移除物品
      其他警员可回收（拾回 → uses 复原，上限 3）
      车辆碾过按现有 spikemodel 逻辑爆胎
And   重启后清 prop（DI-11），背包里的钉刺带与 uses 保留
```

上限：`2/玩家 + 20/全局`，两层都在服务端判（修掉 §1.4 的差一与客户端计数）。

### 5.2 测速枪（prop + 读数，不占武器槽）

- 持有 `police_radar` → 使用道具进入"举枪"状态（prop + 双手瞄准动画），禁用开火、不禁移动。
- 读数：对被瞄准车辆取 `GetEntitySpeed(veh) * 3.6`，**连续 3 帧取中位数**（RS9000 的教训）。
- 显示：世界 3D 文本 `车牌 + km/h`，持续 3 s；超阈值时手机/车机弹一条提示。
- 产出：读数**默认不落库**；开罚单时把读数作为依据写入 `police_case_charges`。
- 不做：自动锁速、四方向、常设雷达桩。

### 5.3 酒测仪（读数 + 证据）

- 距离 ≤ 2 m、目标非在车内、目标已约束或站定。
- 读数 = 目标 metadata 的 `alcohol` 基线 + 小抖动（**建议先给醉酒状态建一个 metadata 字段**，否则就是随机数糊弄）。
- 结果写 `police_evidence`（`kind='bac'`，`payload={bac, at, officer}`），同步到手机「我的报告」。
- ≥ `0.08` 自动建议罪名（复用 justice 的 `public` 类罪名）。

### 5.4 警戒带 + 证据牌（部署物 + 场景）

- 警戒带：瞄准两个碰撞点 → 生成两端之间的带子；一次性道具，一段一次。
- 证据牌：放在脚下，编号 1–20 自增；可与 `police_evidence.evidence_id` 弱关联（可选），不强制。
- 两者都进部署登记表，支持"结案一键收队"。
- 性能：按"只在放置时创建实体、无逐帧循环"实现（同类资源的公开承诺是闲置 0.00 ms）。

### 5.5 统一证据入口（**采纳 CC 的建议**）

所有取证类道具只调一个服务端函数，不各自写表：

```
AddPoliceEvidence(src, kind, payload, item, coords, caseId?)
  → 写 police_evidence（服务端构建 payload，不信客户端）
  → 回填 filled_evidence_bag.info.evidence_id
  → 推送平板/MDT
```

好处：一张表查全链路；`kind` 取值集中在一处（`fingerprint | blood | casing | gsr | bac | drug | photo | weapon`）。
**注意**：payload 必须由服务端按世界登记数据生成，这是修 §1.4 第一个缺陷的唯一正确位置。

---

## 6. 与已有系统的接线

| 目标 | 接法 | 注意 |
|---|---|---|
| `qb-inventory` | `AddItem/RemoveItem(..., reason)`，`reason` 用 `police:<道具>:<动作>` | reason 就是审计线索，别写 `nil` |
| 军械库 | 新建 custom-police 的 server/armoury.lua（规划中，尚未创建）：读 grade 矩阵 + `QBShared.Items` 白名单 + 部门过滤 | 复用主蓝图 §8 权限矩阵，不另建等级 |
| 部门配发 | 把 `Config.Departments[*].weapons` 接进军械库的"按部门过滤" | 死配置正好复活 |
| `qb-target` | 盘查/使用动词挂 target，道具只是"许可票" | 用完即走，不留菜单 |
| 案卷 | 取证类 → `AddPoliceEvidence`（§5.5） | 一条证据一行 |
| 调度 | panic / 测速超阈值 → `dispatch:server:create` | 不要绕过 bus 直接 `TriggerClientEvent` |
| 车载屏 | 雷达/钉刺带状态显示在 `custom-vehicles` dashboard app | 已有 `RegisterDashboardApp` |
| 手机 | 「我的装备」页：当前携带道具 + 剩余次数 + 一键 panic | 只读，不做购买 |
| 审计 | 部署/回收/丢弃/取用写 `custom-logs:LogGeneric` | 设备序列号、发放/归还都要有 |

---

## 7. 分期与工时

| 期 | 内容 | 依赖 | 工时 |
|---|---|---|---|
| **PI-0** | 道具目录（14 项 + PNG）+ 军械库（grade/部门门禁）+ 三级校验框架 + 部署登记表与清理 + 钉刺带/锥桶改造 + panic | 主蓝图 P0 | 4–5 天 |
| **PI-1** | 指纹 / 酒测 / 血检 / GSR / 毒品快检 + 扎带 + 证据牌/警戒带 | PI-0、P3 | 5–6 天 |
| **PI-2** | 测速枪 + flare + 轮锁 + 车载 ALPR UI | PI-0、P2 | 4–5 天 |
| **PI-3** | 断线钳 + 防暴盾 + NVG（装备附属）+ 停车棒 | PI-1 | 3–4 天 |

合计 **16–20 个工作日**，可与主蓝图 P2/P3/P4 并行；**PI-0 必须最先**（否则道具拿不到，无法验收）。
若只做三件：**军械库 + 钉刺带 + 警戒带/证据牌**；panic 几乎免费（手机已有 911 与 SheriffApp），一并做掉。

---

## 8. 风险与回滚

| 风险 | 触发信号 | 缓解 | 回滚 |
|---|---|---|---|
| 道具化后老玩家不会用 | "钉刺带怎么没了" | 保留 `/spikestrip` 兼容期，命令内部转道具校验 | `Config.Items.Enforce = false` 退回命令 |
| 部署物泄露（越放越多） | resmon 上升、实体数暴涨 | 每玩家上限 + 超限**拒绝** + 定时清理 + 结案一键收队 | `MaxDeployedPerPlayer = 0` |
| 军械库被刷物品 | 日志同一人高频取用 | 速率限制 + `reason` 审计 + 单次上限 | 关军械库，改回车尾箱配发 |
| 读数不准导致误罚 | 玩家投诉"我没超速" | 3 帧中位数 + 读数入证据 | 关测速枪，只留静态 `Config.Radars` |
| 新图片缺失 | 库存里白块 | CI 加"items.lua 每个 name 都有 PNG"检查（AC-IT-01） | — |
| 证据被伪造（历史缺陷） | 案件 DNA 与现场不符 | §5.5 服务端构建 payload | 回退到"只认 id"的旧路径并禁用采集 |

---

## 9. 不做清单

见 §4.5，另补三条工程向的：

| 不做 | 理由 |
|---|---|
| 自研警戒带/证据牌渲染 | 已有开源与成熟实现，自研等于重造美术管线 |
| 第二套库存/商店系统 | `qb-inventory` + 军械库足够 |
| 每个道具一张审计表 | 统一 `custom-logs` + `police_deployables` 足够 |

---

## 10. 来源

**外部**：`rpscripts.net/shop/pickle-police-tools-package`（6 件、30 美元、`police_*` 命名）；`fivemx.com/shop/pickle-police-tools-package`（迁移公告）；`forum.cfx.re` 上 Pickle's Police Job（grappler/stab sticks/NVG/snakecam/object placer/evidence camera）、Advanced Police Job（item 放置锥桶护栏照明、bodycam/dashcam/NVG item、spike strips、speed camera、shields、breathalyzer、fingerprint scanner、vehicle radar、trackers）、Pickle's Police Tools（停更：盾/蛇眼/热成像/panic）、Codesign Radar-ALPR（纯 UI、四机位、自动锁、hotlist）、RS9000（车内面板、读数争议）、crime-scene tape 系列（`bebecito_policetape` MIT、Prop Spawner + 20 证据牌、Advanced Tape）；`docs.wasabiscripts.com/advanced-series/wasabi-police-v2/`（扎带/断线钳/GSR/雷达枪+雷达柱/呼气/props/grade-aware armory）；`oxidestudios.dev/docs/oxide-police`（`WEAPON_RADAR`、轮锁、口塞头套、扎带、测速相机、追踪带、扩音器）；`github.com/qbcore-fivem/qb-smallresources`（可用双筒/护甲/跳伞、tackle、移除默认通缉与警察 NPC）。

**仓库**：`T-CityLite.base/resources/[qb]/qb-core/shared/items.lua`、`T-CityLite.base/resources/[qb]/qb-core/server/functions.lua`、`T-CityLite.base/resources/[qb]/qb-inventory/server/functions.lua`、`qb-smallresources/{config.lua,server/consumables.lua,client/binoculars.lua,client/tackle.lua}`、`qb-policejob/{config.lua,client/job.lua,client/objects.lua,client/interactions.lua,server/main.lua,server/evidence.lua,server/commands.lua}`。

---

## 11. 两份稿子的分歧与裁决

Claude Code 的独立版见 [`BLUEPRINT-ITEMS-CC.md`](BLUEPRINT-ITEMS-CC.md)。它没有仓库访问权限，所以在"现状审计"上不如本文（它没有发现军械库是死配置、`MaxSpikes` 差一、证据 info 可伪造），但在**外部生态判断**上比本文更准，以下几处已采纳它的结论：

| 议题 | 本文原稿 | CC 稿 | 裁决 |
|---|---|---|---|
| ALPR 形态 | 计划 P2 做"常设测速相机" | 没有一家把 ALPR 做成道具；只做"查询 + 热榜命中" | **采纳 CC**：本服已有 9 个静态 `Config.Radars`，先复用，不铺网 |
| 自动测速罚单 | P2 列为"自动罚单" | 本服无 NPC 警察兜底，罚单必须玩家开 | **采纳 CC**：删掉自动罚单 |
| 证据写入 | 各道具分别写表 | 统一 `AddPoliceEvidence` 入口 | **采纳 CC**：见 §5.5 |
| 重启策略 | 只说"清理部署物" | prop 清、**背包道具保留** | **采纳 CC**：见 DI-11 |
| 部署上限 | 只提"每玩家 + 全局" | 超限**拒绝**而不是静默删旧 | **采纳 CC**：见 DI-4 |
| 防暴盾 | 不建议（成本高） | 值得 P2（10h，先做 1 种） | **折中**：降级 P3，SWAT grade 2 起；模型/动画不可得则砍 |
| 夜视/热成像 | 不建议（破坏搜捕张力） | 降级为"装备附属，不单列 item" | **采纳 CC 的形态**，但排最后（P3）：它不该成为一件背包道具 |
| 最该先做的三件 | 军械库 + 钉刺带 + 测速枪 | 钉刺带 + 警戒带 + panic | **合并**：军械库是底座（必做），其后钉刺带 → 警戒带/证据牌 → panic（几乎免费） |
| 工时 | 17–23 天 | P0 4 天 / P1 7 天 / P2 8–9 天 | 合并为 **16–20 天**（区间取交集，按 PI-0…PI-3 分段） |
