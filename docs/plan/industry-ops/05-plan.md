---
id: industry-ops-s5-plan
type: plan
status: active
system: economy
owner: hermes
updated: 2026-11-26
review_by: 2027-03-31
stage: P
plan_status: 1
---

# 计划：S5 产业 UI（快照 + Boss 菜单 + 手机只读 App）

> 阶段 P 的产物。上游：[12 — 产业运营与组织运营](../../server-design/12-industry-operations.md)，
> 前一片：[04-plan.md](./04-plan.md)（S4 销售/配额，已合并 #361）。
> 施工单元：[#337](https://github.com/wenkais196-Gabriel/T-City/issues/337)，交付 PR **#362**。

```plan-status
R1 | done | #362 | 2026-11-26
R2 | done | #362 | 2026-11-26
R3 | done | #362 | 2026-11-26
R4 | done | #362 | 2026-11-26
R5 | done | #362 | 2026-11-26
R6 | done | #362 | 2026-11-26
```

---

## 1. 范围

把 S1–S4 的闭环从控制台搬到玩家能用的界面，**不写新 NUI**：

- **唯一读模型**：custom-industry 的 server/ui.lua 提供 Snapshot / EstimateSale / Sell / HireWorkstation 与 5 个 QBCore callback；
- **Boss 菜单**：客户端把「产业」注入 qb-management 的动态菜单项，点开是二级列表（库存、两数配额、单位售价、雇工位、卖出）；
- **手机**：custom-phone 注册一个只读 App，按组织成员可见。

## 2. 溯源：为什么手机只能看不能卖

通用 `DynamicApp` 只有键值列表，没有通用动作按钮。要给它加动作就得改 `custom-phone/web/src` 并重跑构建，
那是另一片（M2 的渲染器复用）。所以本片手机端**只读**，卖出入口只有 Boss 菜单；
custom-phone 的产业 App 服务端文件里的 sell action 已实现并测过，属于「先备好、暂不暴露」。

## 3. 验收标准（可执行）

| # | 标准 | 证据 |
|---|---|---|
| R1 | 面板每个数字都能在库里对上 | 真机截图 + SQL 对账（见 §10） |
| R2 | 卖出走 estimate → 确认 → sell，金额只由服务端算 | 真机：5 件 / $250 |
| R3 | 配额到顶时给的是「本组织配额已用完」而不是笼统失败 | 真机：maxQty=0、blocked=org_cap |
| R4 | 非 Boss 看不到写操作入口 | 真机：Grade1 只剩读数，写入口全无 |
| R5 | 手机 App 只在组织成员可见 | 真机：出现（只读） |
| R6 | `industry_enable=false` 时菜单项与 App 都消失 | 真机：命令只给提示、App 消失 |

## 4. 切片

| 片 | 内容 | 结果 |
|---|---|---|
| R1 | 服务端读模型 + 5 个 callback（含 Snapshot 两数配额） | ✅ |
| R2 | Boss 菜单注入 + 二级列表渲染 + 卖出/雇工位流程 | ✅ |
| R3 | 手机只读 App + audience 扩展（gangs / visible） | ✅ |
| R4 | 单测 11 条 + UI 层 Boss 复验短路用例 | ✅ |
| R5 | 非 Boss 视图真机取证 | ✅ |
| R6 | 关闸回落真机取证 | ✅ |

## 5. 关键实现约束

1. **前端不算钱**：金额只来自 EstimateSale（复用 S4 的 QuoteRevenue）；前端上送 price/revenue/multiplier 一律只记录、不参与计算。
2. **鉴权两层，且都要能独立证明**：UI 层复验一次、销售层再复验一次。删掉 UI 层那句不能靠内层兜底蒙过去（见 §6 的缺口）。
3. **不加新 net event**：走 QBCore callback + export，登记表不动。
4. **不碰 custom-phone/web/src**：不加构建产物、不加第二个 node_modules。

## 6. 先红后绿

| 注入 | 原结果 | 处理 |
|---|---|---|
| `resolveOrgId` 不校验成员 | 红 | —— |
| 删掉 `Sell` 的 `IsOrgBoss` 复验 | **绿（缺口）** | 补短路用例：桩替换销售层，断言非 Boss `reached=0`、Boss `reached=1`；同一注入现在必红 |

## 7. 架构对照

只动业务平面（`custom-industry` + `custom-phone` 的服务端注册表），不改协议、不改表结构、不加 net event。
`custom-phone` 的改动只在服务端的 App 注册与 audience 判定，不触前端构建。

## 8. 登记表同步清单

- net event 登记表：**无新增**（核对过 allowlist）；
- 表 owner：**无新增表**；
- 命令清单：新增 `/industry`、`/orgmenu` 两个客户端命令（不走 QBCore.Commands.Add，无权限参数）。

## 9. 回滚

`industry_enable=false` + `restart custom-industry`：菜单项不注入、App 不注册、命令不响应。
面板本身只是 qb-menu 的一段列表，无独立 NUI 资源可残留。

## 10. 施工记录

| 日期 | 事件 |
|---|---|
| 2026-11-26 | CC 实现（`ec84a325`，worktree E:/T-City-s5）。11 条新单测，`layer3_business` 808 passed。 |
| 2026-11-26 | Hermes 注入：`resolveOrgId` 跳过成员校验 → 红；删 `Sell` 的 Boss 复验 → **绿（缺口）**，补短路用例后转红。 |
| 2026-11-26 | 结构闸门 100 passed；`custom-phone/web/src` 与 html 产物零 diff（符合"不写新 NUI"）。 |
| 2026-11-26 | **真机前置缺陷 1（P0）**：服务端 `type(qb.Functions.CreateCallback) ~= 'function'` 恒真 —— 本 build 里跨资源导出的函数是**可调用表**（`type=table`），5 个 callback 全部没注册，日志只留一行 `UI callbacks not registered`。改为只判 nil + 有界重试（500ms×60）。 |
| 2026-11-26 | **真机前置缺陷 2（P0）**：客户端同一形状 `type(qb.Functions.TriggerCallback) == 'function'` 恒假 —— `uiEnabled` 永远 false，注入被自己挡掉。改 pcall。 |
| 2026-11-26 | **真机前置缺陷 3**：qb-management 的 Boss/Gang 菜单是**世界坐标触发区**，`Config.BossMenus` 里没有 `miner`，注入的项没有任何入口可达。 |
| 2026-11-26 | **真机前置缺陷 4**：`Money()` 是 qb-core 的客户端全局，本资源没 import，渲染第一行就 `attempt to call a nil value (global 'Money')`，整个面板中断。换成本地千分位实现（从右往左分组；左侧贪婪正则会在长数字上重复插逗号直到死循环）。 |
| 2026-11-26 | **真机前置缺陷 5**：`cl_org.lua` 的提示循环里「shownMenu 为真但玩家不在 1.5m 内 → CloseMenuFull()」会关掉**任何**用 qb-menu 打开的界面，包括我们的面板。改走 `/industry` 直开（不置 shownMenu）。 |
| 2026-11-26 | **真机 R1 通过**：面板 金库 $47675 / 库存 92-144 / 工位 3-10 / 配额 全服剩 10-10 本组织剩 5-5 / 单价 $50 / 累计产出 100，逐项与库对上；雇工位 $123,018（=floor(50000×1.35³)）正确禁用并给出 `funds` 原因。 |
| 2026-11-26 | **真机 R2 通过**：卖 5 件 → 通知"入账 $250"，金库 47675→47925、库存 92→87、quota_used 0→5；`industry_sales` id=5 ref=`sys:sale:mining_co:…` revenue=250，`org_ledger` +250 ref=`sale:5`（ref 用的是卖单 id，不是数量，所以重复卖同数量不会撞唯一键）。 |
| 2026-11-26 | **真机 R3 通过**：配额到顶后按钮变成「卖出…（最多 0 件）· 本组织配额已用完」并禁用，`maxQty = min(87, 0, 5) = 0`。 |
| 2026-11-26 | **真机 R5 通过**：手机端「产业」App 出现，显示只读快照。 |
| 2026-11-26 | **发现 S4 双源隐患（转 S6 前置）**：全服已用是可变计数器 `industry_demand.quota_used`，本组织已用是派生 `SUM(industry_sales.qty)`。手动重置前者后出现「全服剩 10、本组织剩 0」这种不可能状态，界面照单全收。倾向改成两侧都从流水派生（配额是竞争稀缺资源，可篡改计数器等于作弊入口）。 |
| 2026-11-26 | **真机超额截断通过**：配额抬到 20/已用 5（本组织上限 10、剩 5）后输 **9** → 成交 **5**（`sale:6` +250），不是报错。 |
| 2026-11-26 | **真机 R5 通过**：`setjob miner 1`（阶层 entry）后标题变 "Mining Co. · L1 · Miner"，金库/设施/库存/配额/单价/累计产出照常可读，**雇工位与卖出两项完全消失**。 |
| 2026-11-26 | **真机 R6 通过**：`setr industry_enable false` + restart 后 `/industry` 与 `/orgmenu` 只弹「产业功能未开启」、不出面板，手机「产业」App 消失。 |
| 2026-11-26 | 关闸时补两处：① 服务端在 `industry_enable=false` 分支也注册 `industry:server:uiState` 回答器 —— 否则客户端每次上线都撞出一条 `qb-core SCRIPT ERROR: Execution of function reference in script host failed`（支持配置不该有噪音）；② 两个客户端命令加 `uiEnabled` 守卫，关闸时本地提示而不是去问一个不存在的回调。 |
