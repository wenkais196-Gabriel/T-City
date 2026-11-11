---
id: ux-index
type: manual
status: active
system: ux
owner: hermes
updated: 2026-11-11
review_by: 2027-02-28
---

# UX 设计索引

> 每个模块一份独立设计文档，四阶段（调研 / 设计 / 计划 / 验收）齐全才算 `active`。
> 工作流与 CC 分工见 [00-workflow.md](./00-workflow.md)。

## 真机验证

逐项操作清单见 [PLAYTEST.md](./PLAYTEST.md)（按模块编号，反馈时带编号即可）。

## 模块清单与进度

| 模块 | 文档 | 覆盖的资源 | 状态 | 备注 |
|---|---|---|---|---|
| 手机 | [modules/phone.md](./modules/phone.md) | `custom-phone`、`custom-ui`（焦点/层） | **active** | 文字输入已修；Garage 标注已加 |
| 经济与交易 | [modules/economy.md](./modules/economy.md) | `qb-shops`、`qb-banking`、`custom-market`、`qb-pawnshop`、`core_economy` | **active · 已交付** | 商店单入口 `[E]`；购买回执带余额与差额 |
| 医疗与急救 | [modules/medical.md](./modules/medical.md) | `qb-ambulancejob`、`custom-consumables` | **active · 已交付** | 复活护甲 0 / 饥渴 50；施救与医院热区改 `[E]` |
| 通知与提示 | [modules/notify-prompt.md](./modules/notify-prompt.md) | `custom-notify`、`custom-prompt`、`qb-core` Notify | **active** | 横向组件，其余模块都依赖它 |
| 警务 | [modules/police.md](./modules/police.md) | `custom-police`、`custom-justice`、MDT | **active** | 去重合并 + 验尸官反馈 + 76 处回执降噪（待 PO 真机验） |
| 载具与车库 | [modules/vehicles.md](./modules/vehicles.md) | `qb-garages`、`qb-vehicleshop`、`qb-fuel`、`custom-vehicles` | **active · 已交付** | V-1…V-7 全完成（取车回执、扣押三件套、主动推送） |
| 犯罪与组织 | [modules/crime.md](./modules/crime.md) | `qb-storerobbery`、`custom-cartel`、`qb-drugs`、`custom-mining`、`custom-crime` | **active · 已交付** | 报警分类、结算去重、单一派发、门槛入提示 |
| 职业与任务 | [modules/jobs.md](./modules/jobs.md) | `custom-career`、`custom-quest`、`qb-management` | **active · 已交付** | 完成/步骤/失败各只发一条；`[E]` 入口；J-6 因无门槛字段不做 |
| 角色与出生 | [modules/identity.md](./modules/identity.md) | `qb-multicharacter`、`qb-spawn`、`qb-apartments` | **active** | 卡片标快照时间、删角色需输全名、脏数据容错；出生选择（I-3）单列一批 |
| HUD 与状态 | [modules/hud.md](./modules/hud.md) | `qb-hud`、`qb-scoreboard` | **active · 已交付** | 圆环数值 + 三档配色 + 低状态提醒 + `/menu` 冲突已修 |
| 管理与审计 | [modules/admin.md](./modules/admin.md) | `custom-admin`、`custom-logs`、`/agent` | **active · 已交付** | 339 条命令清单（生成式）、`/tccops` 权限洞已修、审计 + 二次确认 |

## 横向规则（所有模块都必须遵守）

1. **通道**：`feed` 结果 / `toast` 需停一下 / `error` 拒绝 / `phone` IC 内容。四选一，不叠用。
2. **键位**：`E` 上下文动作（面前唯一）、`ALT` 世界物件列表（多目标）、`M` 手机、`Z` 快捷栏。
3. **一物件一入口**：同一交互禁止同时有 E 和 ALT。
4. **错误不打断**：动作没生效只走 `error`。
5. **空态要说人话**：加载中 / 无数据 / 无权限，各自有文案，不许留白屏。

## 交付节奏

| 阶段 | 内容 | 状态 |
|---|---|---|
| A | 12 个资源的 `DrawText` → `custom-prompt` | 待开工 |
| B | 商店去双入口、验尸官改 E | 待开工 |
| C | `qb-ambulancejob` / `qb-management` 单动作热区 → E | 待开工 |
| D | 交易 / 任务 / 罚款三类通知迁移（约 40 处） | 待开工 |
