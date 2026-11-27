---
id: plan-next-wave-candidates
type: plan
status: active
system: meta
owner: hermes
updated: 2026-11-27
review_by: 2027-03-31
---

# 候选清单（2026-11-27 盘点）

> **路径口径**：反引号里带完整路径的条目全部在本工作树核对过存在；新增文件写成裸文件名并标“新增”，
> 不把计划当成现状。行号写作“路径`:行号`”，因为行号会随改动漂移，以函数名与代码形状为准。
>
> **结论取值**：本轮做 / 在途 / 不做（条件触发）。条件触发的条目写清“看到什么才做”，不写“以后再说”。

## 0. 摘要

| ID | 候选 | 结论 | 服务谁 | 成本（人日） | 主要风险 |
|---|---|---|---|---|---|
| I0 | 产业数值平衡与真实周期长度 | **本轮做（P0）** | 玩家留存 / 经济运维 | 3–5 | 碰钱：售价、配额、prestige |
| I1 | 手机端产业动作入口 | **本轮做（P0）** | 管理者体验 / 留存 | 3–4 | P1 构建产物 + P3 权限复验 |
| I2 | 周期公告推送 | **本轮做（P0）** | 玩家信任 / 运维公告 | 2–3 | 通知重复、跨资源调用 |
| I3 | 循环型职业并入产业岗位 | 不做（条件触发） | 循环职业玩家 / 组织 | 8–12 | 工资出口 + 跨资源任务 |
| I4 | 多设施 / 多地块 / 跨区物流 | 不做（条件触发） | 长期留存 / 组织 | 10–15 | 迁移 + 结算边界 |
| I5 | 组织治理两条提案 | 不做（条件触发） | 组织成员 / 管理者 | 8–12 | 分红碰钱 + 表归属 |
| I6 | NPC 对手 / 抢单 | 不做（条件触发） | 竞争期玩家 / 留存 | 10–15 | 配额公平 + 经济 |
| M6 | adminmenu 迁出 menuv | **在途（#348）** | 管理员 / 玩家（可见 bug） | 4–6 | 输入面 + 权限 |
| M7 | 手机双 `Wait(0)` + 棘轮基线 | **本轮做（M6 后）** | 运维 / 性能 / 架构 | 2–3 | 焦点与输入回归 |
| M8 | qb-menu 全量迁移 | 不做（条件触发） | 运维 / 架构 | 8–12 | 159 处调用点 |
| D1 | #369 命令清单去行号 | **本轮做（合入）** | 开发 / CI | 0.5–1 | 文档与扫描器 |
| D2 | #379 Sonar 三项 | **本轮做（到期 2027-01-15）** | CI / 安全 / 维护 | 1–5 | 盲改只为过 Sonar |

---

## I0. 产业数值平衡与真实周期长度

**一句话价值**：把产业从“机制 demo”变成能开放的经济。服务玩家留存（有理由每天上线经营），
也服务运维（收入、成本、周期可解释）。

**触及的文件与资源**

- `T-CityLite.base/resources/[custom]/custom-industry/config/cycle.lua`:37、`:41`、`:45`、`:49` —
  四阶段天数 10/10/5/3，合计 **28 天**；同文件 `:5` 的注释却写“默认 30 天 = 10/10/5/3”，
  设计稿 `docs/server-design/12-industry-operations.md`:103 写的是五阶段 10/10/5/3/2 = **30 天**
  （结算阶段没有落成状态）。
- `T-CityLite.base/resources/[custom]/custom-industry/config/facility.lua`:12 — `baseCost = 50000`；`:13` 工位上限 10；`:18` `stockCap = 144`。
- `T-CityLite.base/resources/[custom]/custom-industry/config/sales.lua`:28 — `SeedQuota = 10`；`:32` `iron_ore = 50`；`:36` `OrgCapRatio = 0.5`。
- `T-CityLite.base/resources/[custom]/custom-industry/config/production.lua`:24 — `UnitsPerHour = 12`。
- `T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua`:51 — prestige 公式的分母 `PrestigeK`。
- `T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua`:33 — 权威阶段顺序只有四项。
- `T-CityLite.base/tests/unit/layer3_business/test_industry_cycle.py`、`test_industry_sales.py`、`test_industry_facility.py` — 现有数值与状态机用例。
- `docs/plan/industry-ops/06-plan.md` §12.5 — 真机探针的验收方式与“数值仍待真人试玩标定”。
- `docs/plan/jobs-content/04-numbers.md` — 同服其它收入源的实测带（1,388–2,400 $/h）。

**现状标定（按默认 convar 计算，不是估计）**

| 项 | 默认值 | 结果 |
|---|---|---|
| 单组织每阶段可卖 | `floor(10 × 0.5) = 5` 件 | 四阶段 20 件/周期 |
| 单周期收入 | 5×50×(1.00+0.95+1.10+0.80) | 约 **$962** |
| 设施 + 1 工位成本 | 50,000 + 50,000 | **$100,000** |
| 回本约 104 个周期（默认值）** |

这组数字说明：默认配置下配额先耗尽，库存上限（144）永远碰不到——库存上限这道通胀闸在默认配置下
不起作用；指数成本仍在（它拦的是工位数，不是收入），周期清零也仍在。它不是“平衡得不好”，
是“还没有进入平衡阶段”。

**依赖**

- 无代码前置；需要一次产品决策：周期取 28 天（代码现状）还是 30 天（设计稿含结算阶段），以及单周期目标资本量级。
- 数值卡必须先于 I2 的推送文案与 I3 的岗位收益，否则后面两个会基于占位数字写死。

**成本**：3–5 人日。配置与断言 1.5；数值卡/纯函数 1；压缩周期真机跑 0.5；14 天试玩与报告 2。
**不需要迁移，不需要重建前端**；只改配置、测试与文档。

**风险**

- **碰钱**：售价、配额、prestige 都会改变净增货币量。缓解：不改 schema；继续用库存上限、指数成本、周期清零三道闸；
  新增断言锁住“单组织单周期收入上限”和“两家组织时 50% 上限必须生效”。
- **默认 convar 与正式值混淆**：`industry_demand_seed` 是验收旋钮，不能当正式值。缓解：把正式值写进配置，
  验收用 convar 覆盖；测试里同时断言正式值与旋钮的差异。

**验收判据**

离线：

- `cd T-CityLite.base && pytest tests/unit/layer3_business/test_industry_cycle.py tests/unit/layer3_business/test_industry_sales.py tests/unit/layer3_business/test_industry_facility.py -q` 全绿。
- 新增的数值用例（文件在施工时新增，建议名 `test_industry_balance.py`）至少断言：
  1. `sum(Phases[*].days) == CycleDays`，且 `industry_state` 算出的周期末端与它一致；
  2. 设施 + 1 个工位的回本时间在 **3–14 天**（按正式配置、满库存与满配额销售折算），
     低于 3 天说明太便宜，高于 14 天说明扩张期看不到回报；
  3. 单设施日毛利在 **$15k–$30k**（spec §10 的起点值是 $23k）；单组织单周期收入上限 **≤ $5M**（spec §20 的头部组织量级）；
  4. 一个阶段的可产库存 ≥ 该阶段配额，否则“库存上限”是装饰；
  5. 两家组织同时卖时，第二家超过 50% 份额必须被拒（`org_cap_reached`）。
  这些阈值在数值卡定稿时写进测试常量；如果决定改阈值，先改 spec §10/§20 再改测试。
- 反向注入：把任一阶段天数 +1、把 `SeedQuota` 调回 10、把 `OrgCapRatio` 改成 1.0，对应断言必须变红。

真机：

- `python tools/dev/industry_cycle_probe.py --scale 60 --cycles 2` 通过（现有脚本，见 `docs/engineering/LIVE_VERIFICATION.md`:51）。
- 14 天试玩：每天记录 `industry_sales` 的 `SUM(qty)/SUM(revenue)`、`industry_facility.stock`、
  参与组织数、在线人数；报告给出保留/修改周期与数值的结论。只有这一步能回答“真实周期长度”。

**为什么现在做**

- 默认值下 ROI 约 104 个周期；不修就不能对玩家开放。
- 改的是配置与测试，不动表结构；等玩家投入后再改数值，会变成“信任问题”而不是“平衡问题”。
- 设计稿与代码的 28/30 天不一致，必须在“真实周期”被公告给玩家之前定死。

**为什么不做（如果有人想拖）**

- 拖到 I4 多设施之后：多设施会把数值问题放大（每个设施一份配额），而且 schema 变更会掩盖数值问题。
- 拖到 I6 NPC 之后：NPC 会先吃配额，玩家看到的是“抢不到”，不是“值不值得建”。

---

## I1. 手机端产业动作入口

**一句话价值**：管理者不必回到 Boss 菜单坐标才能卖货/雇工位。服务管理者体验与留存；
手机是这个服的第一入口（`custom-phone` 是自研 Svelte 手机）。

**触及的文件与资源**

- `T-CityLite.base/resources/[custom]/custom-phone/server/apps/industry.lua`:107 — 已注册 `industry` App；
  `queries.snapshot` 与 `actions.sell` 已存在（`:118`、`:140`），只缺 `hire`。
- `T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua`:385 — 已导出 `CanAccessIndustry` /
  `GetIndustrySnapshot` / `EstimateIndustrySale` / `SellIndustryStock`；`HireWorkstation` 在 `:365`，但**没有导出**。
- `T-CityLite.base/resources/[custom]/custom-phone/server/phone_apps.lua`:83 — App 注册表；`:111` 只下发 id/label/icon/queries/actions。
- `T-CityLite.base/resources/[custom]/custom-phone/web/src/core/appRegistry.ts`:54 — 已有“服务端注册 + 前端专用页面”的先例（任务 App）。
- `T-CityLite.base/resources/[custom]/custom-phone/web/src/App.svelte`:628 — `dyn:` 前缀会先查 `getApp`，命中就用专用 Svelte 页面；否则回退 `DynamicApp`。
- `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/DynamicApp.svelte`:28 — 只特判 `alert` 动作，不能承载卖出/雇工位。
- `T-CityLite.base/tests/unit/layer3_business/test_phone_apps.py` — App 注册、动作扁平化与错误码用例。
- `T-CityLite.base/tests/unit/layer3_business/test_industry_ui.py` — 玩家侧写入口的权限与参数用例。
- 新增页面 `Industry.svelte`（放在 `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/` 下）；
  新增 `hire` 动作与对应导出。

**依赖**

- 现有 `PhoneApps` 查询/动作协议与 `requestAppQuery` / `requestAppAction`；不需要新 net event。
- 服务端 `IndustryUi.Sell` / `HireWorkstation` 已经做了成员 + Boss 复验；本片只增加一个导出，不复制权限判定。
- 建议在 I0 之后联调，但代码可以并行：页面只消费 `maxQty`、`hireBlocked`、`nextWorkstationCost`，不硬编码数值。

**成本**：3–4 人日。Svelte 页面 1.5；服务端 hire 导出/动作 0.5；测试 1；构建与真机 1。
**需要重建手机 NUI**（`npm run build` 并提交 `html/` 产物）；**不需要 DB 迁移**。

**风险**

- **P1 构建产物**：改 `web/src` 必须 `npm run build` 并把 `html/` 产物一起提交；否则游戏里加载的是旧页面。
- **权限**：前端隐藏按钮不算权限。卖出/雇工位必须继续由 `IndustryAccess.IsOrgBoss` 在服务端复验；
  新增的 `hire` 动作要复用 `IndustryUi.HireWorkstation`，不能在前端算钱。
- **UI 回退**：专用页面注册后，`dyn:industry` 不再走 `DynamicApp`；要保留 `DynamicApp` 的只读回退路径，
  避免页面构建失败时整个 App 打不开。
- **不碰钱、不碰个人层**：金额仍由 `EstimateIndustrySale` / `HireWorkstation` 在服务端算；
  本片不加 SQL、不改表。

**验收判据**

离线：

- `cd T-CityLite.base/resources/[custom]/custom-phone/web && npm run check` 退出码 0。
- `npm run build` 退出码 0；`node tests/nui/run.mjs` 退出码 0。
- `cd T-CityLite.base && pytest tests/unit/layer3_business/test_phone_apps.py tests/unit/layer3_business/test_industry_ui.py -q` 全绿。
- 新增用例断言：非组织成员看不到 `industry` App；Boss 的 `sell` 动作先 estimate 再 sell；
  非 Boss 伪造 `sell`/`hire` 返回 `not_boss`；`hire` 不经过前端计算金额。
- 构建产物静态检查：`T-CityLite.base/resources/[custom]/custom-phone/html/` 中 `https://` 与 `backdrop-filter` 为 0
  （复用 `test_nui_baseline.py` / 现有构建闸门）。

真机：

- 组织成员打开手机 → 产业 App → 看到快照；Boss 卖 5 件，`org_ledger` 增一行、`industry_sales` 增一行；
  非 Boss 的页面没有卖出/雇工位按钮，用构造的 NUI 动作仍被服务端拒绝。
- 手机开着按 `M` 能关、按 `Esc` 能关；不出现“菜单没了但人动不了”。

**为什么现在做**

- S5 明确把手机端定成只读；现在服务端动作已经备好，补齐前端是成本最低的一段。
- 卖出入口只有 Boss 菜单的世界坐标；管理者离开总部就无法经营，手机端是这个服的主要交互面。
- 与 I2 共用 `industry` App id 与通知深链；先有动作页，推送点进去才有意义。

**为什么不做（如果有人想拖）**

- 等 M8 qb-menu 全量迁移：手机 App 与 qb-menu 无关，等下去不会减少本片工作。
- 等 I4 多设施：多设施会让页面从“一个设施”变成“设施列表”，本片会返工；但 I4 本轮不做，不能拿它当前置。

---

## I2. 周期公告推送

**一句话价值**：结算前把“资产要清零”送到玩家手机上，而不是只躺在 CityFeed 里。服务玩家信任与留存，
也服务运维（公告失败可观测、只发一次）。

**触及的文件与资源**

- `T-CityLite.base/resources/[custom]/custom-industry/server/announce.lua`:3 — 文件头写明“没接手机推送，
  因为 custom-phone 没有全服推送导出”；`:59` 只调 `PostCityBulletin`。
- `T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua`:335 — `maybeWarn` 每周期只发一次；
  `:354` `maybeResultAnnounce` 补发结果公告。
- `T-CityLite.base/resources/[custom]/custom-phone/server/core/notify.lua`:38 — `NOTIFY_APP_IDS` 只允许
  `banking` / `police_mdt`；不把 `industry` 加进去，通知会落库但 `app_id` 变 NULL，无法深链。
- `T-CityLite.base/resources/[custom]/custom-phone/server/core/notify.lua`:156 — 已导出 `Notify(citizenid, title, content, appId, meta)`，
  可给在线玩家落库并推送一次。
- `T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/Notifications.svelte`:21 — 非 banking 的 `app_id`
  会走 `dyn:<id>`；注册了 `industry` 专用页面后即可深链。
- `T-CityLite.base/tests/unit/layer3_business/test_industry_cycle.py` — 公告幂等与阶段推进用例。
- `T-CityLite.base/tests/unit/layer3_business/test_phone_apps.py` — 通知白名单与深链用例。

**依赖**

- 现有 `PhoneNotify` 导出与 `Notifications.svelte` 深链；不需要新 net event。
- 需要遍历在线组织成员：`QBCore.Functions.GetQBPlayers()`（`T-CityLite.base/resources/[qb]/qb-core/server/functions.lua`:131）
  与 `IndustryAccess.OrgMembership` 已在 `T-CityLite.base/resources/[custom]/custom-industry/server/access.lua`:16。
  `OrgMembership` 按 `orgId` 判断，调用方要遍历 `Config.Industry.OrgWhitelist`，或复用
  `IndustryUi.PlayerOrgId`（`T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua`:64）。
- 与 I1 共用 `industry` App id；I2 不依赖 I1 的页面，但最终联调排在 I1 之后。

**成本**：2–3 人日。announce/notify 1；测试 1；压缩周期真机 0.5。
**不需要 DB 迁移，不需要重建前端**；只改服务端与通知白名单。

**风险**

- **通知重复**：`maybeWarn` / `maybeResultAnnounce` 已有每周期一次的水位；推送必须挂在同一个水位之后，
  不能在 `Publish` 里无条件重试。失败重试仍由 `RetryLogSeconds` 节流。
- **跨资源调用**：`custom-industry` 调 `custom-phone` 导出必须 `pcall` + `GetResourceState`，失败只记日志，
  不阻断结算（现有 CityFeed 已是这个方向）。
- **隐私**：通知标题/正文只放周期号、组织名、金额；不放 citizenid、坐标、玩家名。
- **离线成员**：`PhoneNotify` 需要 citizenid；本轮只推在线成员，离线成员靠 CityFeed（打开手机可见）。
  这条要写进验收，避免“以为所有人都收到了”。
- **不碰钱、不碰个人层**：公告与推送都不写 `org_treasury` / `players`；唯一新增写入是
  `phone_notifications`（由 custom-phone 的 owner 写）。

**验收判据**

离线：

- `cd T-CityLite.base && pytest tests/unit/layer3_business/test_industry_cycle.py tests/unit/layer3_business/test_phone_apps.py -q` 全绿。
- 新增用例（建议 `test_industry_push.py`）断言：
  1. 两个在线组织成员 + 一个非成员 → 恰好 2 次 `Notify` 调用，0 次给非成员；
  2. 同一周期第二次 tick → 0 次新增通知；`industry_enable=false` → 0 次；
  3. 通知 `app_id` 是 `industry`，且 `PhoneNotify` 的白名单接受它；
  4. CityFeed 仍恰好 1 条（不因推送而重复）。
- 反向注入：删掉每周期水位判断 → “第二次 tick 不新增”用例必须红。

真机：

- `industry_phase_seconds=60` 跑一个压缩周期：结算前手机通知托盘出现 1 条警告；点击进入产业 App；
  CityFeed 同时有 1 条公告；结算结果只再推 1 条。
- 离线成员重新上线：通知托盘没有旧的推送，但 CityFeed 能看到历史公告。

**为什么现在做**

- S7 的 issue #338 验收写了“CityFeed + 手机推送”，实现只做了 CityFeed；这是明确的欠账。
- 结算会清空设施、库存、配额与金库余额；没有提前通知，玩家会认为资产被偷。
- `PhoneNotify` 已有现成导出，缺的只是白名单与一个循环；成本远低于补一条新推送通道。

**为什么不做（如果有人想拖）**

- 等 I1 页面：通知可以先推，深链暂时落到只读 `DynamicApp`；等 I1 合入后自动落到专用页，不需要重写推送。
- 等 I4 多设施：周期公告与设施数量无关，拖下去只会让玩家在结算时才发现。

---

## I3. 循环型职业并入产业岗位

**一句话价值**：让 trucker / garbage / bus 等循环职业与产业发生关系（运库存、清维护），
给循环职业玩家一个新的目标，也给组织管理者“雇人”的理由。

**触及的文件与资源（本轮只调研，不改）**

- `T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_public_services.lua` — taxi / bus / garbage 的任务壳。
- `T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_garbage.lua` — garbage 多站路线。
- `T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_logistics.lua` — 物流任务配置。
- `T-CityLite.base/resources/[custom]/custom-quest/server/quest_logistics_validators.lua` — 到站/车辆/货损校验。
- `T-CityLite.base/resources/[custom]/custom-career/configs.lua`:50、`:60`、`:90` — `taxi_co` / `trucking_co` /
  `garbage_co` 等组织映射。
- `T-CityLite.base/resources/[qb]/qb-core/shared/jobs.lua` — 22 个职业定义与职级。
- `T-CityLite.base/resources/[custom]/custom-industry/config/facility.lua` — 单设施、单库存；没有“运输”字段。
- `T-CityLite.base/resources/[custom]/custom-industry/server/production.lua` — 只读 `last_tick_at` / `workstations`，没有外部输入。

**依赖**

- 至少需要“设施地点 + 输入/输出缓冲”或 I4 多设施；否则“运库存”没有起点与终点。
- 工资/分成如果从组织金库出，需要 `Treasury.Withdraw` + `Player.Functions.AddMoney` 的第二条出口，
  并带幂等 ref；这会碰宪法第 2 条，必须单独设计。
- 任务侧要走 `custom-quest` 的 validator，不新增第二套任务引擎。

**成本**：8–12 人日（不含数值卡与真机试玩）。**很可能需要新列/新表或任务会话字段**；
如果引入持久化字段，需要迁移与 `table_owners.json` 同步；不需要重建手机 NUI（如果走任务提示）。

**风险**

- **碰钱**：组织金库 → 玩家工资是新的净流出路径；重复结算/重试会双发。
- **跨资源**：industry ↔ quest ↔ qb-core 三方；任何一方失败都要有可重试的中间态。
- **内容空转**：单设施、无地点模型时，任务只是“跑到设施点按 E”，玩家会看穿。

**验收判据（如果触发后做）**

离线：任务完成 → 组织库存/维护值变化 + 玩家收入一行流水，ref 唯一；重复提交第二次拒绝；
非该职业/非组织成员拒绝；`players` 与 `org_treasury` 对账一致。真机：一条完整运输/清理循环。

**为什么现在不做**

- 单设施、无地点模型；先做会得到“换皮任务”。
- 当前默认数值下产业收入约 $962/周期，没有利润可以分给岗位。
- 会新增工资出口，风险高于 I0–I2；先把账本与数值证明，再谈岗位。

**触发条件（看到什么才做）**

- I0 合入并完成一个真实周期，且至少 2 个组织有正收入；
- 或 I4 多设施合入，设施有地点与输入/输出缓冲；
- 两者至少满足一个，再进入设计阶段。

---

## I4. 多设施 / 多地块 / 跨区物流

**一句话价值**：从“一个组织一个设施”扩展到多点经营与跨区物流，给长期留存提供深度。

**触及的文件与资源**

- `T-CityLite.base/migrations/v4.1_industry_facility.sql`:26 — `PRIMARY KEY (org_id)`，一组织一设施。
- `T-CityLite.base/resources/[custom]/custom-industry/server/facility.lua`:85 — `Facility.Get` 按 `org_id` 取一行；
  `:101` `Build` 用 `already_built` 拒绝第二座。
- `T-CityLite.base/resources/[custom]/custom-industry/server/production.lua`:148 — `readFacility` 按 `org_id` 取一行；
  `:256` `SettleAll` 只选 `org_id`。
- `T-CityLite.base/resources/[custom]/custom-industry/server/sale.lua`:186 — `readStock` 按 `org_id` 取一行。
- `T-CityLite.base/resources/[custom]/custom-industry/server/settlement.lua`:203 — `DELETE FROM industry_facility WHERE org_id = ?`。
- `T-CityLite.base/resources/[custom]/custom-industry/server/ui.lua`:195 — 快照只渲染一个 `facility`。
- `T-CityLite.base/tests/unit/layer3_business/test_industry_facility.py`、`test_industry_production.py`、`test_industry_sales.py`、`test_industry_settlement.py`。
- `T-CityLite.base/tests/architecture/table_owners.json` — 新表/新列需要 owner 与扫描范围。

**依赖**

- I0 的数值与周期先定；否则多设施只是把错误数值乘以 N。
- 需要新迁移与数据回填（现有行变成“设施 1”），以及设施地点/归属/冲突规则。
- 结算、销售、生产、UI、公告全部要按设施维度改写；跨区物流还要定义“区”和运输时间。

**成本**：10–15 人日（含迁移、测试、真机）。**需要 DB 迁移与数据回填**；手机/Boss 菜单的快照要
从“一个设施”改成“设施列表”，需要重建手机 NUI（如果手机也要展示多设施）。

**风险**

- **schema 迁移**：`org_id` 主键改成 `id` 主键 + `org_id` 索引，所有 SQL 都要重写；迁移必须幂等并可回滚数据。
- **结算边界**：结算从“删一行”变成“删多行”，个人层 checksum 证明要重跑。
- **经济**：多设施会放大配额与库存；50% 上限必须按组织聚合，否则一个组织用多设施绕过。
- **位置冲突**：多地块需要位置、归属、抢占规则；这是玩法设计，不是 schema 能解决的。

**验收判据（如果触发后做）**

离线：迁移连跑两次幂等；老数据回填为设施 1；两座设施独立生产/销售；结算清空全部设施且个人层 checksum 不变；
50% 配额按组织聚合仍然生效。真机：建两座设施、分别生产与卖出、结算。

**为什么现在不做**

- MVP 的一设施已经足够证明通路；没有真实周期数据，不知道“多设施”是不是玩家真正想要的深度。
- schema 迁移会锁死后续数值调整；先定数值与周期，再动结构。
- 本轮已经有 I0–I2 三个碰产业的文件面，再开迁移会让回归范围失控。

**触发条件**

- I0 完成一个真实周期后，出现以下任一现象：
  1. 至少 2 个组织的库存连续 7 天打满 `stockCap`；
  2. 管理者在试玩反馈里明确要求“第二座设施/分店”；
  3. 单设施收入已经稳定落在设计目标带内，且没有通胀异常。
- 先写迁移设计（含回滚），再估算工期；不在触发当天直接开工。

---

## I5. 组织治理两条提案

**一句话价值**：让 `governance_proposals` / `organization_rules` 第一次有写者，把“组织”从 Boss 独裁
变成有规则的经营主体。服务组织成员与管理者。

**触及的文件与资源**

- `T-CityLite.base/migrations/v0.8_ownership_engine.sql`:91 — `governance_proposals` 表；`:166` `organization_rules` 表。
- `T-CityLite.base/tests/fixtures/tcity_schema.sql` — 两张表的 fixture 快照。
- `T-CityLite.base/tests/architecture/table_owners.json` — 两张表目前**没有 owner**；新增写者前必须登记，
  并把新资源加入 `scan` 清单。
- `T-CityLite.base/resources/[qb]/qb-management/server/sv_org.lua`:323 — `HireMember`；`:210` 晋级检查。
- `T-CityLite.base/resources/[custom]/custom-industry/server/treasury.lua` — 分红如果走金库，必须复用唯一写入口。
- `docs/server-design/04-co-governance.md` — 提案生命周期与两条提案的语义。

**依赖**

- 一个提案内核（创建 / 联署 / 投票 / 执行 / 审计）；目前不存在，需要新资源或新模块。
- 分红提案依赖 I0 的真实余额与至少一个完整周期；否则分的是占位数字。
- 招募门槛提案依赖 `qb-management` 的招募路径与组织规则读取；不碰钱，适合作为第一条。

**成本**：8–12 人日。提案内核 5；两条提案 2；UI/审计 2；测试与真机 1–3。
**不需要新建表**（两张表已存在），但**需要 DB owner 登记与扫描范围**；提案 UI 如果是手机页面，
需要重建 NUI；如果只做 Boss 菜单，则不需要。

**风险**

- **碰钱**：分红是 `org_treasury` → 玩家的净流出；必须带幂等 ref、审计、总额上限，且不能绕过 `Treasury.Withdraw`。
- **表归属**：两张表没有 owner；新增写者必须先定 owner 与扫描范围，否则跨资源写闸门看不见。
- **权限**：投票资格、联署门槛、Boss 否决权都要服务端复验；客户端隐藏不算。
- **冷启动**：组织人数少时投票可能永远达不到门槛；需要“小组织降级规则”或先只做招募门槛。

**验收判据（如果触发后做）**

离线：创建提案 → 联署 → 投票 → 执行；未达门槛拒绝；同一提案重复执行幂等；分红 ref 唯一、总额 ≤ 金库余额；
招募门槛拒绝/放行各一条；`organization_rules` 有唯一 `(org_id, rule_key)`。真机：一个组织完成一次提案全流程。

**为什么现在不做**

- 提案内核不存在，成本高于 I0–I2；当前金库余额与周期数据还不足以支撑分红决策。
- 两张表没有 owner，先做写者会同时引入表归属与跨资源写两个 L3 变更。
- 先做招募门槛（不碰钱）比先做分红安全；但即使招募门槛，也需要提案内核。

**触发条件**

- I0 完成一个真实周期，且至少 2 个组织有正金库余额；
- 组织成员数达到可投票规模（例如 ≥5 人/组织，具体阈值在提案内核设计时定）；
- 先做“招募门槛”提案，分红提案放到下一个周期。

---

## I6. NPC 对手 / 抢单

**一句话价值**：在真人少的时候让竞争期仍然“有人在抢”，服务竞争期玩家与留存。

**触及的文件与资源**

- `T-CityLite.base/resources/[custom]/custom-industry/config/sales.lua`:28 — 全服配额；`:36` 单组织上限。
- `T-CityLite.base/resources/[custom]/custom-industry/server/sale.lua`:156 — `readDemand`；`:354` 50% 上限。
- `T-CityLite.base/resources/[custom]/custom-industry/server/cycle.lua`:459 — 阶段推进后播种配额。
- `T-CityLite.base/resources/[custom]/custom-police/shared/npc_budget.lua`:15 — 现有 NPC 预算 `MAX_GLOBAL = 6`，
  明确不是给产业竞争用的（数量级不够，kind 也不匹配）。
- `docs/server-design/12-industry-operations.md`:313 — “竞争期没有对手，只有配额变少”是已接受缺陷。

**依赖**

- I0 的配额与价格先定；否则 NPC 会把默认 10 的配额吃光。
- 需要一个新的 NPC/模拟需求预算（不能复用警察的 `NPCBudget`），以及“NPC 消耗配额”的确定性调度。
- 需要审计与可解释性：玩家要能看到“谁买走了”，否则只是黑箱。

**成本**：10–15 人日（含模拟、调参、UI、测试）。**不需要 DB 迁移**（如果只做模拟需求，
用配置 + 审计即可）；**不需要重建前端**（除非要把“谁买走了”做成新页面）。

**风险**

- **经济**：NPC 消耗配额等于把玩家收入转走；如果配额太小，玩家永远卖不出。
- **公平**：NPC 行为必须可预测、可关闭；否则玩家会认为系统在针对自己。
- **范围**：一旦做实体 NPC，还要吃 NPC 预算、寻路、帧率；建议先做“模拟需求”，不做实体。

**验收判据（如果触发后做）**

离线：NPC 每阶段按配置消耗固定配额；玩家看到的 `remaining` 与实际一致；重复 tick 不重复扣；
关闭 convar 后 NPC 消耗为 0；审计每个阶段一行。真机：一个压缩周期内玩家能与 NPC 抢同一批配额，
且剩余量在 UI 上可见。

**为什么现在不做**

- 默认配额 10、单组织上限 5；NPC 一进来就会把订单吃光，玩家体验会比“没有对手”更差。
- 需要先有 I0 的数值与真实玩家行为数据；否则调参没有基准。
- 模拟需求也要一套预算与审计，成本不低于 I0–I2 之和。

**触发条件**

- I0 完成一个真实周期，且出现以下任一现象：
  1. 竞争期配额售罄率 < 50%（玩家觉得订单用不完）；
  2. 同时活跃组织数 < 3，竞争期没有“抢”的感觉；
  3. 玩家反馈明确要求“有对手”。
- 先做只读的“需求模拟器”与数值卡，再决定是否上实体 NPC。

---

## M6. adminmenu 迁出 menuv（在途，不重复派工）

**一句话价值**：修掉用户可见的 `/admin` 关不掉、Esc 呼出暂停菜单、能叠在手机上；同时删掉 menuv 这套第二输入面。

**触及的文件与资源**

- `T-CityLite.base/resources/[qb]/qb-adminmenu/client/client.lua` — 18 处 `MenuV` 入口（census 当前值）。
- qb-adminmenu 的 `menu_shim.lua`（#353 的临时垫片）—— **M6 已随 menuv 一起删除**，本条只作历史记录。
- `T-CityLite.base/resources/[qb]/qb-adminmenu/client/noclip.lua` — 合法禁控，迁移时保留语义。
- `T-CityLite.base/resources/[qb]/qb-management/client/cl_org.lua` — 原 cl_boss.lua、cl_gang.lua、cl_org.lua 三套并存，M6b（#385）已合并删除前两份、统一收敛至 `cl_org.lua`。
- `T-CityLite.base/resources/[standalone]/menuv/menuv/menuv.lua`:157 — 14 次 `RegisterKey` 最终落到的唯一 `RegisterKeyMapping`。
- `T-CityLite.base/configs/modules/core.cfg`:25 — `ensure menuv`；M6 下线时删除。
- `T-CityLite.base/tests/architecture/test_adminmenu_input_shim.py` — 垫片契约；M6 后要改为“垫片不存在”。
- `T-CityLite.base/tests/architecture/menu_surface_baseline.json` — `menuv_entry` 基线 47（menuv 自身 29 + adminmenu 18）。

**依赖**：M1–M5 已合入；`custom-menu` 需要支持 adminmenu 的子菜单与表单面（现有 `MenuSpec` / renderer 已支持 list/form/confirm/range）。

**成本**：4–6 人日（issue #348 的口径）。**不需要 DB 迁移**；`custom-menu` 的 HTML 已有构建产物，
adminmenu 迁移本身不需要再构建（除非改动 `custom-menu` 渲染器）。

**风险**：输入面与权限。管理动作的服务端鉴权不能被 UI 迁移改掉；noclip/实体查看等合法禁控要逐条保留并登记。

**验收判据**：

- 离线：`pytest T-CityLite.base/tests/architecture/test_adminmenu_input_shim.py -q`（M6 后改成“垫片已删除/不存在”的断言）；
  census 的 `menuv_entry` 除 menuv 自身外 = 0；adminmenu 的 `DisableAllControlActions` = 0；
  `qb-management` 只剩 `cl_org.lua`。
- 真机：`/admin` 可开可关、Esc 不呼出暂停菜单、手机开着不能叠开；非 Boss 的拒绝路径不变。

**为什么现在做**：真机已复现“关不掉 + 呼出暂停菜单 + 叠在手机上”（`docs/client/ux/menu-system-design.md` §10.3）。
**为什么不在本计划重复派工**：已派给另一个 agent；本计划只把 M7 排在它后面，并把 `menuv_entry = 0` 作为 M7 的前置。

---

## M7. 手机双 `Wait(0)` 收口 + 菜单架构棘轮（#349）

**一句话价值**：把菜单线的最后两处结构性浪费清掉，并把“菜单架构”第一次变成只许下降的闸门。
服务运维（少一条逐帧循环）与架构（半年后不再分叉）。

**触及的文件与资源**

- `T-CityLite.base/resources/[custom]/custom-phone/client/main.lua`:427 — 手机主循环的 `Wait(0)`。
- `T-CityLite.base/resources/[custom]/custom-phone/client/core/device_lock.lua`:28 — 平板移动锁线程；`:39` 第二条 `Wait(0)`。
- `T-CityLite.base/resources/[custom]/custom-prompt/client/main.lua`:50 — `SetContext` 每次调用都发 NUI，没有同内容去重；
  对比 `Show` 在 `:19`–`:32` 已有 `lastShown` 去重。
- `T-CityLite.base/tests/architecture/menu_surface_baseline.json` — 2026-11-25 的取证基线，当前已与代码不一致。
- `tools/dev/menu_surface_census.py`:38 — 取证分类定义；M7 开工前用它重测。
- `T-CityLite.base/tests/architecture/test_input_layer_contracts.py`、`test_m4_focus_stack.py`、`test_qb_menu_adapter.py`、`test_adminmenu_input_shim.py` — 现有输入/焦点闸门。
- `T-CityLite.base/configs/boot.json` — 启动集；M6 下线 menuv 后同步。
- `docs/DEVOPS.md`:56 — 标签体系；新增 `area:menu` 的登记。
- 新增 `test_menu_architecture.py`（放在 `T-CityLite.base/tests/architecture/` 下）。

**依赖**：M6 #348 合入（`menuv_entry` 归 0 的前置）；M4/M5 的基线；`menu_surface_census.py` 可运行。

**成本**：2–3 人日。双循环合并 0.5；prompt 去重 0.5；闸门与反向注入 1；真机 1。
**不需要 DB 迁移，不需要重建前端**；只改客户端 Lua、测试与基线 JSON。

**风险**：焦点/输入回归。手机主循环承载动画、时间、禁用控制、导航；把平板锁并进去时要保证
`DeviceLock.End()` 在每条关闭路径仍被调用，且死亡/实体不存在时自动解锁。

**验收判据**

离线：

- 先重跑 `python tools/dev/menu_surface_census.py`，把当前数字写成新基线（当前实测：
  `setnui_focus=195`、`isnuifocused_read=27`、`qb_menu_entry=159`、`client_wait_zero=223`，
  与文件里的旧基线不同；不重测就会假红/假绿）。
- `cd T-CityLite.base && pytest tests/architecture -q` 全绿。
- `cd T-CityLite.base/resources/[custom]/custom-phone/web && node tests/nui/run.mjs` 通过。
- 新增闸门 `test_menu_architecture.py` 至少断言：
  1. `menuv_entry` 除 menuv 自身外 = 0；
  2. 非排除资源 `backdrop_filter` = 0（monitor 的 6 处作为显式排除项保留）；
  3. `setnui_single_arg` 只允许 allowlist 内的点（qb-input 的两处必须带到期日）；
  4. 门卫用途的 `isnuifocused_read` 只允许 allowlist 内的点；
  5. 新增 `SetNuiFocus` 调用点必须显式登记（按“资源 + 文件 + 计数”登记，不登记行号）；
  6. `client_wait_zero` 只许下降；手机主循环合并后应比基线少一条。
- 反向注入 3 条：手工加一处未登记的 `SetNuiFocus`、回填一处 `backdrop-filter`、重新引入一处 `MenuV` 引用 → 全部必须红。
- prompt 去重：同一内容连续调用两次 `SetContext` → 只发 1 次 NUI；改变一条 → 发 2 次。

真机：平板打开时全客户端只有 1 条屏蔽循环；手机/平板开合、死亡、资源重启后人物不被冻住；
`/admin`（M6 后）与手机不能互相叠开。

**为什么现在做**：M6 之后菜单线只剩这一片；不做就没有棘轮，半年后 M1–M6 的清理会被新代码回填。
**为什么排在 M6 后**：M6 未合入时 `menuv_entry = 0` 不成立；先建闸门只会得到一条永远红的测试。

---

## M8. qb-menu 全量迁移（本轮不做，写清触发条件）

**一句话价值**：去掉最后一整套旧 CEF 菜单页面，让所有菜单都走 `custom-menu` + 焦点栈。服务运维与架构。

**触及的文件与资源**

- `T-CityLite.base/resources/[qb]/qb-menu/client/main.lua` — 旧 NUI 路径。
- `T-CityLite.base/resources/[qb]/qb-menu/client/adapter.lua`:25 — 适配层，`qb_menu_use_custom_menu` 默认 false。
- `T-CityLite.base/resources/[qb]/qb-menu/server/adapter_state.lua`:10 — 服务端把 convar 写进 `GlobalState`。
- `T-CityLite.base/resources/[qb]/qb-menu/html/index.html`、`script.js`、`style.css` — 旧页面；全量迁移后删除。
- `T-CityLite.base/resources/[qb]/qb-input/client/adapter.lua`、`html/` — 同理。
- 当前 census：`qb_menu_entry = 159` / 21 个资源；`qb_input_entry = 21` / 8 个资源。
- `T-CityLite.base/tests/architecture/test_qb_menu_adapter.py` — 适配层行为用例。

**依赖**：M6、M7；`qb_menu_use_custom_menu=true` 在真实服上运行过；`custom-menu` 的 list/form/confirm/子菜单
覆盖所有存量调用形状。

**成本**：8–12 人日（删除旧页面 + 21 个资源逐项回归 + 回滚窗口）。
**不需要 DB 迁移**；需要删除 `qb-menu` / `qb-input` 的旧 HTML 并改 manifest，属于“重建式”删除，
回滚要靠保留旧版本。

**风险**：159 处调用点（2026-11-27 census）的行为差异；`qb-input` 的阻塞式表单语义；回滚只能靠保留旧页面一个版本。

**触发条件（全部满足才做）**

1. M6 已合入，`menuv_entry` 除 menuv 自身外为 0；M7 的闸门已绿。
2. `qb_menu_use_custom_menu=true` 在正式服连续运行 **14 天**；日志中 `custom-menu` 打开失败为 0，
   `qb-menu` 适配层回退旧 NUI 的打印为 0（或低于约定阈值，阈值写进 issue）。
3. 21 个 `qb_menu_entry` 资源中，每一个都至少有一条真实路径在开启适配层后跑过；
   没有资源直接依赖 `qb-menu` 的 NUI DOM/回调。
4. `pytest T-CityLite.base/tests/architecture/test_qb_menu_adapter.py -q` 全绿，且新增一条
   “删除旧页面后适配层仍能打开/关闭/返回子菜单”的用例。
5. 产品明确接受“一个版本的旧页面回滚窗口”。

**验收判据（如果触发后做）**：

- 离线：`qb-menu/html` 与 `qb-input/html` 不再被 manifest 引用；`qb_menu_entry` 的调用点全部经适配层或已迁移；
  `pytest T-CityLite.base/tests/architecture/test_qb_menu_adapter.py -q` 全绿；全量 pytest 绿。
- 真机：列表 / 表单 / 子菜单 / Esc / 资源重启后菜单仍可用；旧页面已不再加载。

**为什么现在不做**：适配层已经可用且默认关闭，完整迁移是 21 个资源的行为回归，玩家看不到直接收益；
没有 14 天真实运行数据就删旧页面，回滚成本高。

---

## D1. #369 命令清单去行号（已实现，待合入）

**一句话价值**：改一行 Lua 不再让命令清单闸门红，CI 不再每天为行号漂移白跑一轮。服务开发/CI。

**触及的文件与资源**

- `tools/dev/scan_commands.py` — 输出格式与 `--check` 比对逻辑。
- `docs/client/ux/admin-commands.md` — 生成物；当前由扫描器写。
- `T-CityLite.base/tests/architecture/test_admin_commands_doc.py` — 比对闸门。
- 实现已在分支 `tool/commands-doc-identity` 的 `648a943b`：表头去掉“位置”，文档里写清用 `rg` 定位；
  验收是“给含命令的 Lua 加一行注释后重新扫描，闸门仍绿”。

**依赖**：分支基于 `2f092048`，合入前要 rebase 到最新 master；如果 M6 改了含命令的 Lua，重跑扫描器即可
（去行号后不再需要为注释漂移重跑）。

**成本**：0.5–1 人日（rebase + 验收 + CHANGELOG）。**不需要 DB 迁移或前端重建**。

**风险**：低。唯一风险是“文档里仍能一眼看出命令属于哪个资源”；实现用资源分组标题解决。

**验收判据**

- `python tools/dev/scan_commands.py --check` 退出码 0。
- 往 `T-CityLite.base/resources/[qb]/qb-target/client.lua` 末尾加一行注释 → 重跑扫描器 → 闸门仍绿。
- 真的新增/删除一条命令 → 闸门红。
- `cd T-CityLite.base && pytest tests/architecture/test_admin_commands_doc.py -q` 绿。
- 真机：不需要（纯文档/工具改动）。

**为什么现在做**：实现已经在分支上；2026-11-26 一天内为行号漂移跑了 3 次 CI（#365 / #368 / M2 各一次）。
合入成本接近零，收益是后续所有 Lua 改动都不再连带文档。

**为什么不做（如果有人想拖）**：拖到 M6/M7 之后，M6 改 adminmenu 时仍会触发同一问题；先合入能减少 M6 的 CI 噪音。

---

## D2. #379 Sonar 三项（到期 2027-01-15）

**一句话价值**：把“暂时跳过的质量门”在到期前关掉，避免“跳过一次就永久不修”。服务 CI / 安全 / 维护。

**触及的文件与资源**

- SonarCloud 项目 `wenkais196-Gabriel_T-City`（外部；需要只读 token，不能入库）。
- `T-CityLite.base/tests/unit/layer3_business/fixtures/industry_probe_common.lua` — #377 已把四个探针的重复
  求值/行构造搬进公共层；issue #379 里记的重复主要落在这里。
- `T-CityLite.base/tests/unit/layer3_business/fixtures/industry_cycle_probe.lua`、`industry_sales_probe.lua`、
  `industry_treasury_probe.lua`、`industry_facility_probe.lua` — issue 列出的重复行分布。
- `docs/engineering/CONSTITUTION.md` — 如果选择“质量门只对 src/ 生效”，理由与到期日要写在这里。
- `CHANGELOG.md` — 交付三件套。

**依赖**：一个只读 SonarCloud token；没有 token 时 Security / Reliability 两项无法定位，盲改风险高于收益。
#377（PR #380）已合入，重复率需要用 Sonar 重新读一次，不能直接拿 issue 里的 5.1% 当现状。

**成本**：1–2 人日（如果重复已被 #377 消掉，且 Security/Reliability 只是少量条目）；3–5 人日（如果两项有真实缺陷）。
**不需要 DB 迁移或前端重建**；只改测试/夹具或 Sonar 规则。

**风险**

- **盲改**：为了把 Rating 从 D 改到 A 而改代码，可能破坏行为；必须先拿到具体 issue 列表。
- **token 管理**：只读 token 不能提交到仓库；只能放在本地环境变量或 Sonar UI。
- **规则变更**：把质量门改成“仅 src/”是显式决策，必须有理由与到期日，不能悄悄放宽。

**验收判据**

- 有 token 时，用 Sonar API 读三项（把 token 放环境变量，不写进命令历史/文档）：

  ```
  curl.exe -s -u "$SONAR_TOKEN:" \
    "https://sonarcloud.io/api/measures/component?component=wenkais196-Gabriel_T-City&metricKeys=new_duplicated_lines_density,new_security_rating,new_reliability_rating"
  ```

  断言：`new_duplicated_lines_density <= 3`、`new_security_rating = 1.0`、`new_reliability_rating = 1.0`
  （或在质量门里选择“仅 src/”后，同一 API 显示通过）。
- 没有 token 时：issue 保持 open，不算完成；可以在 2026-12-15 前先跑一次全量离线闸门，
  但那只证明“正确性闸门绿”，不能替代 Sonar。
- 选择改规则时：`docs/engineering/CONSTITUTION.md` 写明“为什么旧条款不成立”、影响范围与到期复审日；
  同 PR 更新 CHANGELOG。
- 真机：不需要（Sonar API + 离线闸门）。

**为什么现在做**：硬到期日 2027-01-15；拖到 12 月底再要 token，Security/Reliability 的条目可能来不及处理。
**为什么不做（如果有人想拖）**：到期后 issue 会变成“无限期挂账”，而 CI 质量门仍是 D；这不是“暂时跳过”，是永久债务。

---

## 附：本轮明确不做的事（与 §0 摘要一致）

| 不做 | 触发条件 | 依据 |
|---|---|---|
| I3 循环职业并入产业 | I0 完成真实周期且 ≥2 组织有正收入，或 I4 合入 | 单设施无运输落点；工资出口风险 |
| I4 多设施 / 多地块 | I0 后库存连续 7 天打满，或管理者明确要求第二座设施 | schema 迁移会锁死数值 |
| I5 组织治理 | I0 后 ≥2 组织有正余额，且成员规模可投票；先做招募门槛 | 提案内核不存在；分红碰钱 |
| I6 NPC 对手 | I0 后配额售罄率 <50%，或活跃组织 <3 | 默认配额下 NPC 会吃光订单 |
| M8 qb-menu 全量迁移 | M6/M7 完成；convar 开启连续 14 天零回退 | 159 处调用点，回滚成本高 |
