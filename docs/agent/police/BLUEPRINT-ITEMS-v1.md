# 警察道具层蓝图（Items & Props）

> **状态**：设计稿 v1，未实现。日期 2026-10-30。
> **范围**：警察**手上拿的、地上摆的、身上戴的**东西 —— 道具定义、配发链路、使用与回收、与案卷/调度的接线。
> **不含**：MDT 页面、调度状态机、AI 支援单位（分别见 [`BLUEPRINT.md`](BLUEPRINT.md) 的 P2/P3/P5）。
> **配套**：[`ACCEPTANCE.md`](ACCEPTANCE.md)（验收标准）、[`RESEARCH-2026-10.md`](RESEARCH-2026-10.md)（调研依据）。

---

## 0. 结论摘要

1. **真正的问题不是"缺道具"，是"没有配发链路"**：`qb-policejob` 里 `inArmoury` 只声明从未使用，`Config.Departments[*].weapons` 全仓 0 引用——**军械库和部门武器配发都是死配置**。警察现在能拿到的道具只有车尾箱那三样。
2. 道具系统已经有一套**成熟范式**可抄：`QBShared.Items` 定义 + `CreateUseableItem` 注册 + `qb-inventory` 的 `AddItem/RemoveItem(..., reason)` 审计 + `info` 实例元数据（`filled_evidence_bag` 就是这么带血样数据的）。
3. **钉刺带是反例**：`/spikestrip` 是命令、不消耗任何道具、只有 `Config.MaxSpikes = 5` 的全局上限、重启即失。做成道具比新增任何酷炫工具都值。
4. 道具分三类产出，必须事先定死：**只读数**（测速枪）、**读数 + 证据行**（酒测/毒品快检/指纹）、**读数 + 调度事件**（panic）。三类混在一起就会变成"查了但没人看得见"。
5. 部署物（锥桶/护栏/警戒带/钉刺带/证据牌）必须有主：**服务端登记 + 可回收 + 重启清理**。这是现在 `Config.Objects` 最大的漏洞（只有 netid 列表，没有 owner / 没有落库 / 没有清理）。
6. 外部生态里真正值得抄的是**"item-based system"**（Pickle Police Tools 明确所有工具都是实体道具，要采买、要管理），不是某一件工具本身。

---

## 1. 现状审计（仓库实测）

### 1.1 道具的定义与通道

| 环节 | 现状 | 证据 |
|---|---|---|
| 定义 | `QBShared.Items` 单表，字段 `name / label / weight / type / image / unique / useable / shouldClose / description`；**没有数据库表** | `qb-core/shared/items.lua` 首 20 行 |
| 注册可用 | `QBCore.Functions.CreateUseableItem(name, fn(source, item))`（服务端），再 `TriggerClientEvent` 通知客户端 | `qb-core/server/functions.lua`；`qb-smallresources/server/consumables.lua:4-11` |
| 增删物品 | `exports['qb-inventory']:RemoveItem(src, name, amount, slotOrFalse, reason)` / `AddItem(src, name, amount, slot, info, reason)` | `qb-policejob/server/evidence.lua:97-151` |
| 实例元数据 | `info` 表随物品走；`unique = true` 表示唯一实例 | `filled_evidence_bag`（items.lua） |
| 图片 | `qb-inventory/html/images/` 共 292 张 PNG；每个新道具都要一张 | 目录统计 |

### 1.2 警察手上已经有什么

| 道具 | 状态 | 证据 |
|---|---|---|
| `handcuffs` | 可用物品，走 `HasItem(Config.HandCuffItem)` 校验 | `qb-policejob/server/main.lua:285`、`client/interactions.lua:265` |
| `police_stormram` | 可用物品（破门） | items.lua；`Config.CarItems[3]` |
| `empty_evidence_bag` / `filled_evidence_bag` | 采集血液/指纹/弹壳时消耗前者、产出后者（带 `info`） | `server/commands.lua:339-345`、`server/evidence.lua:97-151` |
| `heavyarmor` / `empty_evidence_bag` / `police_stormram` | **车尾箱三件套**（`Config.CarItems`，实现于 `SetCarItemsInfo`） | `config.lua:135-139`、`client/job.lua:49-69` |
| `radio` / `radioscanner` / `moneybag` | 定义存在；radio 可用（pma-voice），moneybag 有服务端使用 | items.lua、`server/main.lua:292` |
| 武器 | `weapon_handcuffs` / `weapon_nightstick` / `weapon_flashlight` | items.lua:5-25 |

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
| **证据袋的 `info` 由客户端传入，服务端不复验** | `evidence:server:AddBlooddropToInventory(bloodId, bloodInfo)`（`server/evidence.lua:96`）；`fingerInfo` / `casingInfo` 同理 | 改过的客户端可以伪造 DNA、弹壳序列号——**证据本身可造假，保管链再完整也没意义** | 服务端按 `bloodId/fingerId/casingId` 从自己的世界登记表里取 payload，只信 id |
| **`MaxSpikes` 判定是客户端列表且差一** | `if #SpawnedSpikes + 1 < Config.MaxSpikes`（`client/objects.lua:214`），配 5 实际最多放 4；列表在客户端 | 上限形同虚设（改客户端即可无限放）；两名警员各算一份 | 服务端计数 + 每玩家/全局双层上限 |

### 1.5 qb-smallresources 给了什么（可复用 / 会影响道具层）

官方 README 的能力清单里，与本层直接相关的四条：

| 能力 | 对道具层的意义 |
|---|---|
| **可用双筒望远镜**（相机 FOV 缩放，`Config.Binoculars`） | 观察类道具已有现成实现，不要再写一个 |
| **可用护甲 / 可用跳伞** | 这就是"可用道具"的标准范式（`CreateUseableItem` + 消耗 + 客户端演出） |
| **Tackle（扑倒）** | 已有警察动作，但现在**无道具、无职业校验**（任何玩家 `LMENU` 都能扑）→ 应该收进警察道具层 |
| **移除了 GTA 默认通缉系统、默认警察/救护 NPC、全部分支调度服务**（`Config.AIResponse` 15 项全 false） | 街上没有原版警察 → 道具层是玩家唯一执法手段；也说明 P5 的 AI 支援是"补空白"，不会与原生 AI 打架 |

---

## 2. 外部调研：三类道具体系

来源：Pickle Police Tools（商店页 + cfx 帖子）、Advanced Police Job（cfx）、Pickle's Police Tools（已停更，cfx）、wasabi-police v2 文档、oxide-police 文档、Codesign Radar/ALPR、RS9000 测速雷达、crime-scene tape 系列资源。

### 2.1 功能矩阵（只列"道具型"工具）

| 道具 | Pickle Tools | Advanced Police Job | wasabi v2 | oxide-police | 备注 |
|---|---|---|---|---|---|
| 钉刺带 | ✓ | ✓ | ✓ | ✓ | 全都有，说明是刚需 |
| 锥桶 / 护栏 / 照明 | ✓ | ✓（道具放置、全玩家同步） | ✓（road-control equipment） | ✓ | 部署物 |
| 路障烟幕 / 照明弹 flare | ✓ | — | 未记载 | — | 一次性 |
| 测速枪 / 雷达 | ✓ | ✓（可锁速、自动锁） | ✓（radar gun + 常设雷达桩） | ✓（手持 + 车载） | 读数类 |
| ALPR 车牌识别 | ✓（hoto list 联动） | — | 未记载 | ✓（常设测速相机） | 本服已有静态 `Config.Radars` |
| 酒测 breathalyzer | ✓（BAC 读数） | ✓（真实 UI） | ✓ | ✓ | 产证据 |
| 毒品快检 | ✓ | — | 未记载 | — | 产证据 |
| 指纹扫描 / 血液检测 | ✓ | ✓ | ✓ | ✓ | 产证据 |
| GSR 火药残留 | — | — | ✓ | ✓ | 动手能力的客观依据 |
| 证据牌（编号） | ✓ | — | 未记载 | — | 现场拍照用 |
| 警戒带 police tape | ✓ | — | 未记载 | — | 有多个独立资源（含 MIT 开源实现） |
| 随身摄像头 bodycam | ✓ | ✓（需道具） | ✓（Medal） | ✓ | 本蓝图外，见 P4 |
| 夜视 / 热成像 | ✓（停更版） | — | 未记载 | — | 视觉增强 |
| 盾牌 / 蛇眼摄像头 / 抓钩 | ✓（停更版） | — | 未记载 | — | 高成本 |
| 扎带 / 断线钳 / 口塞 / 头套 / 轮锁 | — | — | ✓（zipties、bolt cutters、keys） | ✓（zip ties、mouth tape、headbags、wheel clamps） | 低技术但很 RP |

### 2.2 三条可直接抄的产品判断

1. **"item-based system" 是卖点而不是限制**：Pickle Police Tools 把「所有工具都是实体道具，需要采买与管理」写成第一条卖点。道具层的价值来自**稀缺与配发**，不是来自功能本身。
2. **警戒带/证据牌已经是独立品类**：有开源（`bebecito_policetape`，MIT、OneSync、NPC 会对现场有反应、自动清理）和多个付费实现，说明这块**没有必要自研渲染**，但**必须自研数据**（绑案卷）。
3. **测速枪的差异在读数可信度**：RS9000 的用户抱怨旧雷达"明明 50 报 60"，说明读数算法（用 `GetEntitySpeed` 还是逐帧积分）直接决定这个道具能不能用于 RP 定罪。

---

## 3. 设计决策（DI）

| ID | 决策 | 理由 | 反方案 |
|---|---|---|---|
| **DI-1** | **三级校验**：grade（资格）→ item（手上有没有）→ 世界条件（距离/目标/场景）；三关全在服务端判 | 客户端按钮不是权限；`handcuffs` 现在只查 item 不查 grade | 只在客户端查 → 等于没有门禁 |
| **DI-2** | 道具定义不进 DB，用 `QBShared.Items`；实例数据走 `info` | 与全仓一致，证据袋已验证可行 | 建 `police_items` 表 → 双写漂移 |
| **DI-3** | 消耗策略三档：**一次性**（flare / tape / zip tie / 试剂）、**持久**（radar / breathalyzer / cuffs / camera）、**次数型**（spike strip、`info.uses`） | 全做成一次性太贵，全做成持久没有稀缺感 | 全部一次性 → 每次出勤先跑商店 |
| **DI-4** | 部署物必须有主：服务端登记 `{id, netid, owner, kind, at}`，支持回收，重启清理 | 现在只有 netid 列表，谁放的/放多久/怎么清都不知道 | 继续用客户端表 → 重启后幽灵锥桶 |
| **DI-5** | **军械库先做**，否则一切道具无处配发 | `inArmoury` 是死代码，部门武器配置是死配置 | 先做道具 → 玩家拿不到，无法验收 |
| **DI-6** | 工具产出必须分级声明：只读数 / 读数 + 证据行 / 读数 + 调度事件 | 否则"查了但没人看得见"（这正是现在 911 的毛病） | 统一弹通知 → 全部噪音 |
| **DI-7** | 枪型工具（测速枪/酒测仪）用 **prop + 动画**，不占武器槽 | 占武器槽会与武器轮、`weapon_*` 系统打架，还会被当武器收缴 | 做成 `weapon_*` → 与 qb-weapons 冲突 |
| **DI-8** | 命名与素材规范：`police_` 前缀 + snake_case + 中文 label + 一句话描述 + 必须附 PNG | 道具靠图片辨认；缺图就是一格白块 | 随手起名 → 图标混乱 |
| **DI-9** | 车尾箱（`Config.CarItems`）与军械库**读同一份道具目录** | 现在两处各写各的，必然漂 | 分开配置 |
| **DI-10** | 本层不新增轮盘、不新增第二套交互：一律「库存里使用」+「qb-target 对准目标」 | 轮盘已有 qb-radialmenu，再叠一层会乱 | 自建 F 键菜单 |

---

## 4. 道具清单（分优先级）

图例：**需图** = 需要新 PNG；**产出** = 只读数 / 证据 / 调度。

### 4.1 PI-0 配发链路（与 P0 同期，**先做这个**）

| 道具 | item name | 重量 | 消耗 | 获取 | 产出 | 需图 |
|---|---|---|---|---|---|---|
| 军械库（不是道具，是界面+服务） | — | — | — | 站点 | — | — |
| 部门配发包（复用死配置） | — | — | — | 军械库按 grade | — | — |
| 钉刺带（改造） | `police_spikestrip` | 1500 | 次数型（`info.uses = 3`） | 军械库 | 部署物 | ✓ |
| 锥桶 / 护栏 / 照明灯（改造） | 复用 `Config.Objects` 键 | — | 复用（无限次） | 军械库（道具化开关） | 部署物 | 已有 prop |

### 4.2 PI-1 盘查与取证（与 P3/P4 同期）

| 道具 | item name | 消耗 | 产出 | 优先级 |
|---|---|---|---|---|
| 指纹套件 | `police_fingerprint_kit` | 持久 | 证据（`kind=fingerprint`） | P0 |
| 酒测仪 | `police_breathalyzer` | 持久 | 读数 + 证据（BAC） | P0 |
| 毒品快检试剂 | `police_drugtest_kit` | 一次性 | 证据（延迟结果：疑似→确认） | P1 |
| GSR 套件 | `police_gsr_kit` | 一次性 | 证据（开枪残留） | P1 |
| 血检套件 | `police_blood_kit` | 一次性 | 证据（复用 `filled_evidence_bag` 的 info 结构） | P1 |
| 扎带 | `police_zipties` | 一次性 ×10 | 约束动作（低阶替代手铐） | P1 |
| 证据牌（编号 1–20） | `police_evidence_marker` | 持久 | 部署物 | P2 |
| 警戒带 | `police_tape` | 一次性（每次一段） | 部署物 | P2 |

### 4.3 PI-2 交通执法（与 P3 同期）

| 道具 | item name | 消耗 | 产出 | 优先级 |
|---|---|---|---|---|
| 测速枪（手持） | `police_radar` | 持久（`info.battery` 可选） | 读数 + 罚单联动 | P0 |
| 车牌识别（车载，已有静态 `Config.Radars`） | — | — | 读数 + 通缉比对 | 已有，只补 UI |
| 测速相机（可放置） | `police_speedcamera` | 持久 | 部署物 + 自动罚单 | P2 |
| 停车棒（引导牌） | `police_stopbaton` | 持久 | 纯演出（拦停流程） | P2 |

### 4.4 PI-3 现场与后勤（与 P4/P5 同期）

| 道具 | item name | 消耗 | 产出 | 优先级 |
|---|---|---|---|---|
| 照明弹 flare | `police_flare` | 一次性 | 部署物（照明 90 s） | P1 |
| 拖车 / 验尸调度 | 手机 App（不是道具） | — | 调度事件 | P2 |
| 断线钳 | `police_boltcutters` | 持久（耐久） | 开锁/切铐（对 `qb-doorlock`） | P2 |
| 轮锁 | `police_wheelclamp` | 一次性 | 部署物（锁车） | P2 |

### 4.5 明确不建议（不管别人怎么做）

| 不做 | 理由 |
|---|---|
| 口塞 / 头套（mouth tape、headbag） | 在成人向 RP 服之外基本是道具垃圾；没有系统功能，只有贴图 |
| 盾牌 / 抓钩 / 蛇眼摄像头 | 高成本（模型+动画+物理），10–30 人服一年用不了几次 |
| 夜视 / 热成像 | 视觉增强会让"搜捕"变成"开挂"，破坏 RP 张力 |
| 独立 "police tools" 资源包 | 与本仓库既有的 prop 系统、证据袋、案卷全部重叠，双写风险大于收益 |

---

## 5. 四个关键道具的规格（写清才能实现）

### 5.1 钉刺带（把 `/spikestrip` 改成道具）

```
Given 警员手持 police_spikestrip 且 grade ≥ 0 且 on duty
When  在道路上使用道具
Then  生成部署物（服务端登记 owner/netid/coords/at，记入 police_deployables）
      info.uses 减 1；uses 归零时物品移除
      其他警员可回收（拾回 → 恢复 uses）
      车辆碾过按现有 spikemodel 逻辑爆胎
And   重启后清理所有部署物（不做持久化），日志记录清理数量
```

验收要点：`Config.MaxSpikes` 从"全局 5 个"改成"每玩家 2 + 全局 20"，两个上限都在服务端判。

### 5.2 测速枪（prop + 读数，不占武器槽）

- 持有 `police_radar` → 使用道具进入"举枪"状态（`prop_...` + 双手瞄准动画），**不禁用移动但禁用开火**。
- 读数：对被瞄准车辆取 `GetEntitySpeed(veh) * 3.6`，**连续 3 帧取中位数**（RS9000 的教训：单帧读数不可信）。
- 显示：世界 3D 文本显示 `车牌 + km/h`，持续 3 s；超过阈值时手机/车机弹一条提示。
- 产出：读数**默认不落库**；只有在开罚单时把读数写进 `police_case_charges.fine` 的依据字段。
- 明确不做：自动锁速、四方向雷达、常设雷达桩（P2 再说）。

### 5.3 酒测仪（读数 + 证据）

- 对被约束/站定的目标使用（距离 ≤ 2 m，目标 MUST 非车辆内）。
- 读数 = `math.random` + 目标 metadata 中的 `alcohol` 水平（**建议给醉酒状态建一个 metadata 字段**，否则就是随机数糊弄）。
- 结果写 `police_evidence`（`kind='bac'`，`payload={bac, at, officer}`），并同步到手机「我的报告」。
- 阈值：`0.08` 以上自动建议罪名（复用 justice 的 `public` 类罪名）。

### 5.4 警戒带 + 证据牌（部署物 + 场景）

- 警戒带：瞄准两个碰撞点 → 生成两端之间的带子（照开源实现的交互）；一次性道具，一段一次。
- 证据牌：放在脚下，编号自增（1–20 循环）；与 `police_evidence` 的 `evidence_id` **弱关联**（可选填），不强制。
- 两者都进 `police_deployables`，支持"全部清理"（结案时一键收队）。
- 性能：闲置 0.00 ms 是同类资源的公开承诺，实现时按"只在放置时创建实体、无逐帧循环"来写。

---

## 6. 与已有系统的接线

| 目标 | 接法 | 注意 |
|---|---|---|
| `qb-inventory` | `AddItem/RemoveItem(..., reason)`，`reason` 用 `police:<道具>:<动作>` | reason 就是审计线索，别写 `nil` |
| 军械库 | 新建 `custom-police` 的 `server/armoury.lua`：读 grade 矩阵 + `QBShared.Items` 白名单 | 复用 §8 权限矩阵，不另建等级 |
| 部门配发 | 把 `Config.Departments[*].weapons` 接进军械库的"按部门过滤" | 现在是死配置，正好复活 |
| `qb-target` | 盘查动词（搜身/酒测/戴铐）挂 target，道具只是"许可票" | 道具用完即走，不留菜单 |
| 案卷 | 取证类道具 → `police_evidence`；`kind` 取值表见 P4 | 一条证据一行，payload 存结果 |
| 调度 | panic / 测速超阈值 → `dispatch:server:create` | 不要绕过 bus 直接 `TriggerClientEvent` |
| 车载屏 | 雷达/钉刺带状态显示在 `custom-vehicles` dashboard app | 已有 `RegisterDashboardApp` |
| 手机 | 「我的装备」页：当前携带道具 + 剩余次数 | 只读，不做购买 |
| 审计 | 每次丢弃/回收/使用写 `custom-logs:LogGeneric` | 部署物尤其要有 |

---

## 7. 分期与工时

| 期 | 内容 | 依赖 | 工时 | 备注 |
|---|---|---|---|---|
| **PI-0** | 道具目录（`QBShared.Items` 新增 12 项 + 12 张 PNG）+ 军械库（grade 门禁 + 部门过滤）+ 三级校验框架 + `police_deployables` 表与清理 | P0 | 4–5 天 | 先做，否则后面全是空中楼阁 |
| **PI-1** | 指纹 / 酒测 / 血检 / GSR / 毒品快检 + 扎带 | PI-0、P3 | 4–5 天 | 产出接 `police_evidence` |
| **PI-2** | 钉刺带道具化 + 锥桶/护栏/照明改造 + 测速枪 + flare | PI-0、P2 | 4–6 天 | 交通组的主力 |
| **PI-3** | 警戒带 + 证据牌 + 断线钳 + 轮锁 | PI-1、P4 | 3–4 天 | 现场收尾 |
| **PI-4** | 测速相机、停车棒、其余降级项 | PI-2 | 2–3 天 | 可不做 |

合计 17–23 个工作日，可与主蓝图的 P2/P3/P4 并行推进（PI-0 必须最先）。

---

## 8. 风险与回滚

| 风险 | 触发信号 | 缓解 | 回滚 |
|---|---|---|---|
| 道具改成命令→道具后老玩家不会用 | "钉刺带怎么没了" | 保留 `/spikestrip` 兼容期，命令内部转道具校验 | 开关 `Config.Items.Enforce = false` 退回命令 |
| 部署物泄露（越放越多） | resmon 上升、实体数暴涨 | 每玩家上限 + 定时清理 + 结案一键收队 | 关 `MaxDeployedPerPlayer` 为 0 |
| 军械库被刷物品 | 日志里同一人高频取用 | 速率限制 + `reason` 审计 + 单次上限 | 关闭军械库资源，改回车尾箱配发 |
| 读写数不准导致误罚 | 玩家投诉"我没超速" | 3 帧中位数 + 车门级 diff，读数写证据 | 关闭测速枪，只留静态 `Config.Radars` |
| 新图片缺失 | 库存里白块 | CI 加一条"items.lua 里每个 name 都有对应图片"的检查 | — |

---

## 9. 不做清单

| 不做 | 理由 |
|---|---|
| 自研警戒带/证据牌渲染 | 已有开源与成熟实现，自研等于重造美术管线 |
| 第二套库存/商店系统 | `qb-inventory` + 军械库足够；再叠一层必然双写 |
| 把道具做成武器 | 与武器轮、收缴、`weapon_*` 系统冲突（DI-7） |
| 新增轮盘/自定义按键菜单 | 与 qb-radialmenu 重叠（DI-10） |
| 全道具一次性 | 出勤前要跑商店，RP 变成购物（DI-3） |
| 口塞、头套、盾牌、抓钩、夜视 | 见 §4.5 |

---

## 10. 来源

**外部**：`fivemx.com/shop/pickle-police-tools-package`（item-based system 卖点与工具清单）；`forum.cfx.re` 上 Pickle's Police Job（grappler/stab sticks/NVG/snakecam/object placer）、Advanced Police Job（breathalyzer、房卡道具化、speed camera、radar、bodycam/dashcam 道具）、Pickle's Police Tools（停更版：盾牌/蛇眼/热成像/panic）、Codesign Radar-ALPR（四机位/自动锁/hotlist）、RS9000（读数可信度争议）、crime-scene tape 系列（`bebecito_policetape` MIT、Prop Spawner + 20 证据牌、Advanced Tape）；`docs.wasabiscripts.com/advanced-series/wasabi-police-v2/`（zipties/bolt cutters/GSR/radar posts/breathalyzer/props）；`oxidestudios.dev/docs/oxide-police`（手持雷达 `WEAPON_RADAR`、轮锁、口塞、头套、扎带、测速相机）；`github.com/qbcore-fivem/qb-smallresources`（官方能力清单与"移除默认警察/通缉"）。

**仓库**：`qb-core/shared/items.lua`、`qb-core/server/functions.lua`、`qb-inventory/server/functions.lua`、`qb-smallresources/{config.lua,server/consumables.lua,client/binoculars.lua,client/tackle.lua}`、`qb-policejob/{config.lua,client/job.lua,client/objects.lua,client/interactions.lua,server/main.lua,server/evidence.lua,server/commands.lua}`。
