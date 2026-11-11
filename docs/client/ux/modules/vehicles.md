---
id: ux-vehicles
type: manual
status: active
system: vehicle
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

# 载具与车库 · UX 设计

> 状态 **draft**：目前只完成 §1 调研（数字均为实测扫描）。§2/§3/§4 待设计。
> 工作流见 [00-workflow.md](../00-workflow.md)。

## 1. 调研（现状）

### 1.1 触点规模（实测）

| 资源 | 通知类调用 | 交互热区 | 命令 |
|---|---|---|---|
| `qb-garages` | 17 | 0 | 0 |
| `qb-vehicleshop` | 73 | 1 | 1 |
| `qb-fuel` | 13 | 1 | 0 |

### 1.2 状态语义（数据事实）

| 字段 | 取值 | 含义 |
|---|---|---|
| `player_vehicles.state` | 0 | 已取出，在世界里 |
| | 1 | 停在车库 |
| | 2 | 被扣押 |
| `player_vehicles.depotprice` | > 0 | 取回要交的钱（>0 时按扣押处理，与 state=2 等价） |

### 1.3 玩家会卡住的场景

| # | 场景 | 现在 |
|---|---|---|
| 1 | 车库取车 | Garage App 能看到车，但不知道车库在哪 → 已加「📍 地图」（2026-11-11） |
| 2 | 车被扣押 | 只显示 `Impounded`，没写为什么、要交多少、去哪取 |
| 3 | 加油 / 修车 | 提示是 `DrawText` 左中一条，与其它交互不同源 |

### 1.4 外部实践（我的调研，2026-11-11）

| 来源 | 关键做法 | 对我们的意义 |
|---|---|---|
| Agency Scripts《FiveM Garage System》 | 车库分三层：**数据库持久化**（`player_vehicles` 存完整属性，含 mods/fuel/engine/body）、**服务端权威的生成/回收**（含校验）、**客户端 UI**（只管选车）；强调"取回时要和离开时一模一样"，否则玩家认为车被清空 | 我们的表结构完全一致（`state` 0=在外 / 1=在车库 / 2=被扣，`depotprice`=取回费用）；要检查的是**取回后属性是否真的一致**（mods/fuel/body） |
| 同上（扣押部分） | 扣押不是另一种东西，而是**带额外状态的 garage**：两条进入路径（警察扣押 / 弃车被拖），并需要"时长 + 费用 + 去哪交"三件信息 | 我们只显示一个 `Impounded` 字符串，三件信息一件都没有 |
| 同类的 PD Impound 讨论（Cfx 论坛 / Reddit） | 玩家最常见的抱怨是"车不见了，不知道被扣了还是没了" | 需要一条**明确的状态迁移通知**：车被扣时立刻给车主 `phone` 留档 |

**外部结论两条**：

1. **扣押要把三件事说全**：为什么被扣 / 要交多少钱 / 去哪交。只显示状态词等于没说；
2. **状态迁移要主动通知车主**：车从「在车库」→「被扣押」时推一条 `phone`（可回查），
   而不是等玩家下次打开 Garage 才发现。

### 1.5 CC 调研补充（2026-11-11）

**外部做法**（0Ticks / Zerio / Helix / Agency-Garage）：

| 环节 | 主流做法 |
|---|---|
| 被扣时告知 | 扣押时填原因与费用，**主动通知车主**（"Your vehicle has been impounded by the police"） |
| 在哪交、交多少 | 扣押场有独立地图图标；面板显示 `Impounded` + `Impound Fee: $X`，到场 `RETRIEVE` 付款 |
| 我的车在哪 | `Locate` 直接把在外车辆标到地图；列表用 `STORED / OUT / IMPOUNDED` 三态 |
| 取车失败 | 具名原因：`Not enough money` / `Area too crowded` / `No parking spots` / `ALREADY OUT` |

**仓库现状（关键缺口）**：

| 环节 | 现在 | 依据 |
|---|---|---|
| 取车成功 | **无任何回执**，直接 WARP 上车 | `qb-garages/client/main.lua:359-392` |
| 扣押取车 | 客户端零反馈，点完只发 `PayDepotPrice` | `qb-garages/client/main.lua:327-335` |
| 扣押解释 | 只有静态 blip 与按键提示，无原因/金额 | `qb-garages/config.lua:247-260` |
| 列表数据 | 只带 `depotPrice`/`balance`，**没有扣押原因** | `qb-garages/client/main.lua:68-69` |
| 手机 | `state=2` → `Impounded`，不查 `depotprice` | `custom-phone/server/main.lua:837,842-847,867` |
| 手机异常 | 拉取失败只 `console.error`，界面退化成"无车辆" | `Garage.svelte:17-19,37-43` |
| 静默 return | depot 车内按 E 直接 return（无提示） | `qb-garages/client/main.lua:204` |

**通道现状**：`qb-garages` 全部走老 `QBCore.Functions.Notify`，**未接入三层通知**。


## 2. 设计（目标）

> 综合我的 §1.4 与 CC 的 §1.5。规则可落成 if/else。

### 2.1 取车（公共车库）

```
走近车库 → prompt: [E] 取车
   → 成功：feed「已取车 TESTCAR1 · pillboxgarage」+ 车辆属性与离开时一致
   → 失败：error 具名原因（见 2.3）
```

- **成功必须有回执**（现在完全静默）；
- 取车后 HUD 的油量/车损要与库里 `fuel/engine/body` 一致（同一数据源）。

### 2.2 扣押（三件套 + 主动通知）

| 位置 | 内容 |
|---|---|
| 手机 Garage 卡片 | 状态 `扣押中` + **原因** + **取回 $X** + 所在地（带「📍 地图」） |
| 到场取回 | `prompt`：[E] 取回（$X）→ 成功 feed「已支付 $X · TESTCAR1 已放行 · 余额 $Y」 |
| 被扣瞬间 | 车主收到 `phone`：「TESTCAR1 因 <原因> 被扣至 <扣押场>，取回需 $X」 |
| 缴费收据 | `phone` 留档：金额 / 时间 / 现金或银行 / 放行状态 |

**铁律**：只显示 `Impounded` 一个词等于没说 —— 原因、金额、地点三件缺一不可。

### 2.3 失败原因（具名，不笼统）

| 原因 | 文案 |
|---|---|
| 钱不够 | `需 $X，你有 $Y，还差 $Z` |
| 取车点被占 | `取车点被占用，先把车开走` |
| 车已不在扣押场 | `该车已被取回或转移，请刷新` |
| 无证件/无权限 | `需要 <驾照> 才能使用该车库` |
| depot 内按 E | `扣押场不能存车，请去公共车库`（现在完全静默） |

### 2.4 空态（区分"没有车"与"没拉到"）

| 情形 | 表现 |
|---|---|
| 名下确实没有车 | 「名下没有登记车辆」+ 指路"去车行看看" |
| 拉取失败/超时 | 「网络忙，点此重试」（**不许**退化成"没有车"） |
| 车在外（state=0） | 「已取出 · 位置未知」+「📍 标注最后位置」 |


## 3. 计划（任务）

> 分工：我开发（P），CC 定验收（V）。

| # | 任务 | 文件 | 风险 | 验收方式 |
|---|---|---|---|---|
| V-1 ✅(`c55b628e`) | 接入三层通道：`qb-garages` 的 `QBCore.Functions.Notify` 收口到本地 `feedback()`（success→feed、error→error） | `T-CityLite.base/resources/[qb]/qb-garages/client/main.lua` | 低（机械 + 逐条看） | 取车/存车提示落在左下，右侧不再弹 |
| V-2 ✅(`c55b628e`) | 取车成功回执 | 同上（取车回调末尾） | 低 | 取车后左下出现「已取车 …」 |
| V-3 | 扣押取车结果回执（成功/失败都要） | 同上 `327-335` 段 + 服务端 `PayDepotPrice` 返回 | 中（要看服务端返回形状） | 缴费成功有余额；失败具名 |
| V-4 ✅(`c55b628e`) | depot 内按 E → error（现在静默） | 同上 `:204` | 低 | 扣押场里按 E 得到红条 |
| V-5 | 手机 Garage 显示扣押三件套（原因/金额/地点） | `T-CityLite.base/resources/[custom]/custom-phone/server/main.lua`（`getOwnedVehicles`）+ `Garage.svelte` | 中（要加字段并兼容旧行） | 被扣车的卡片能看到原因与金额 |
| V-6 | 手机拉取失败与"没有车"分开 | `Garage.svelte` | 低 | 断网时显示重试，不显示"名下没有车辆" |
| V-7 | 扣押瞬间主动推 `phone` | `qb-garages` 的扣押入口（`/impound` 与拖车） | 中（要拿车主 cid） | 车被扣后手机会话里有凭证 |

**顺序**：V-4（最小、真静默）→ V-1（统一通道）→ V-2（取车回执）→ V-3（扣押取车）→ V-5/V-6（手机侧）→ V-7（主动通知）。


## 4. 验收（步骤）

> CC 定标准（2026-11-11）。前置：测试账号名下有 **TESTCAR1 / TESTCAR2**；
> DB 判定统一用 `SELECT state, depotprice FROM player_vehicles WHERE plate=?`。

### V-2 取车成功回执

| 步骤 | 操作 | 期望现象 | 判定 |
|---|---|---|---|
| 1 | DB 置 TESTCAR1 `state=1`；站入公共车库圆圈中心按 **E**，菜单点取车 | WARP 上车同时出现 feed「已取车 TESTCAR1 · <车库>」，**不得**走 error | 截图 |
| 2 | 取车后查 DB | `state` 由 1 变 0 | DB |

### V-3 扣押取车（缴费）

| 步骤 | 操作 | 期望现象 | 判定 |
|---|---|---|---|
| 1 | DB 置 TESTCAR2 `state=2, depotprice=500`，现金 ≥500；depot 圈内按 E 取车 | feed「已缴 $500 取出 TESTCAR2」；现金 −500 | 截图 |
| 2 | 查 DB | `state` 2→0，`depotprice`→0 | DB 两列 |
| 3 | 现金 <500 重复步骤 1 | error「现金不足」；不扣款、不 WARP | 截图 + DB 未变 |

### V-4 depot 内按 E

| 步骤 | 操作 | 期望现象 | 判定 |
|---|---|---|---|
| 1 | 坐进 TESTCAR1 驶入 depot 圆圈按 **E** | error「扣押场不能存车，请去公共车库」，非静默 | 截图 |
| 2 | 查 DB | `state` 仍为 0 | DB |

### V-5 手机扣押三件套

| 步骤 | 操作 | 期望现象 | 判定 |
|---|---|---|---|
| 1 | DB 置 TESTCAR2 `state=2, depotprice=750`；打开手机 Garage | 卡片**同屏**四项：扣押中 / 原因 / $750 / 地点 | 截图 |
| 2 | 对照金额 | 显示 $750 | DB depotprice=750 |

### V-6 拉取失败与「没有车」分开

| 步骤 | 操作 | 期望现象 | 判定 |
|---|---|---|---|
| 1 | 用 0 车账号打开 Garage | 空态「名下没有车辆」（非错误样式） | 截图 |
| 2 | 令 `getOwnedVehicles` 超时/抛错后重开 | 「拉取失败，请重试」，与步骤 1 文案不同 | 两态对比截图 |

**反例（必须不成立）**

1. 取车成功仅 WARP、无任何回执；
2. 扣押缴费失败仍扣钱，或 `state` 被改成 0；
3. depot 内按 E 完全无通知；
4. 拉取失败复用「名下没有车辆」空态；
5. 扣押卡片只显示 Impounded，缺金额/原因/地点。

## 5. 已知未决

- 扣押（`state=2` / `depotprice>0`）的解释与缴费入口未设计；
- 车损/油量在 HUD 与手机 Garage 两处数值口径不同（手机显示 100%，HUD 未必）；
- 车行 73 处通知，购买流程的成功/失败通道未区分。
