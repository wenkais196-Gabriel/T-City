---
id: police-architecture-deprecations
type: manual
status: active
system: justice
owner: hermes
updated: 2026-10-24
review_by: 2027-01-30
---

# 弃用登记（Deprecations）

> 机器可读事实源：`T-CityLite.base/tests/architecture/deprecations.json`。
> 检查器：`T-CityLite.base/tests/architecture/test_deprecations.py`。
> 规则：FIT-12（见 [07-fitness-tests.md](07-fitness-tests.md)）。本文件是人读镜像，**不是第二事实源**；以 JSON 为准。

---

## 0. 规则

1. 任何被宣布“停止新写入”的表 / 命令 / 事件都必须在 JSON 里登记，即使它还没删。
2. `expected_writes` 是**上限**，不是目标：命中数超过它 → FAIL（新增债务）。
3. `expires` 是硬性日期：过期且目标仍存在 → FAIL。要么清掉路径，要么重新评审并写新的到期日。
4. 命中数为 0 → FAIL（stale）：路径已经删了，登记也必须删。
5. `guard`（可选）会校验 handler 体仍保留该守卫；`police:server:JailPlayer` 的 `src ~= 0` 不能丢。
6. 每次修掉一条，就在同一个变更里删除对应 entry。

---

## 1. 当前登记（6 条，全部 `expires = 2026-12-31`）

| id | kind | target | 现值 | 上限 | replacement |
|---|---|---|---|---|---|
| `police-arrests-table` | table | `police_arrests` | 2 写（`p2_system.lua` `Sys.Jail`、`p3_cases.lua` `RegisterArrest`） | 2 | `police_reports(kind='arrest')` via `ArrestSubmit` |
| `police-bolos-table` | table | `police_bolos` | 2 写（`CreateBolo` / `ClearBolo`） | 2 | `police_reports.is_bolo`（`GetBolos` 已优先读 reports） |
| `fine-command` | command | `/fine` | 1 注册（`commands.lua`） | 1 | `PayCitation` / 手机银行缴罚单 |
| `911p-command` | command | `/911p` | 1 注册（`commands.lua`） | 1 | `custom-police:server:911` + dispatch 队列 |
| `jail-player-event` | event | `police:server:JailPlayer` | 1 注册（`interactions.lua`，`src ~= 0`） | 1 | `ArrestSubmit` / `JailSystem` |
| `police-alert-event` | event | `police:server:policeAlert` | 1 注册（`main.lua`） | 1 | `custom-police:server:911` + dispatch 看板 |

已删除、因此**不登记**的路径：`/jail` 命令、`police:client:JailPlayer`（`interactions.lua` 注释保留历史）。登记它们会立即因 stale 而红。

---

## 2. 每条的“为什么现在不能修”

| id | 为什么 |
|---|---|
| `police-arrests-table` | `GetArrests` / `GetCaseDetail` 仍要读历史行；新写路径已切到 reports，但 agent 的 `Sys.Jail` 仍把 legacy 表当“入狱记录”写。拆掉它需要先把 agent 审计投影到 reports。 |
| `police-bolos-table` | B_PLAN 已宣布停写，MDT 的 `create_bolo` 仍走 `CreateBolo`；`GetBolos` 已双源合并（reports 优先），但写侧没切完。 |
| `fine-command` | 旧命令直接扣现金、不写 `police_citations`、无审计、现金不足还直写 `phone_invoices`（见 FIT-02 allowlist）。退役需要先确认 MDT 缴费覆盖所有场景。 |
| `911p-command` | 旧命令直接扇出 qb-phone 报警事件，绕过 incident 队列；但平民报警入口还没完全切到 `custom-police:server:911`。 |
| `jail-player-event` | 仅保留给控制台/内部兼容调用（`source=0`）；客户端触发已无效。等所有内部调用改走 `ArrestSubmit` 后删除。 |
| `police-alert-event` | qb-drugs / qb-storerobbery / qb-houserobbery 的“热接线”仍用它；这些资源不在本任务改动面内。 |

---

## 3. 到期复查清单（2026-12-31 之前）

- [ ] `police_arrests`：删掉 `Sys.Jail` / `RegisterArrest` 的 INSERT，或把 entry 上限降为 0 并删除 entry。
- [ ] `police_bolos`：删掉 `CreateBolo` / `ClearBolo` 的写，`GetBolos` 只读 reports。
- [ ] `/fine`、`/911p`：删除命令注册（或确认只保留 ACE 管理入口）。
- [ ] `police:server:JailPlayer`：删除事件或确认无内部调用。
- [ ] `police:server:policeAlert`：把 qb-* 报警热接线改到新事件后删除。
- [ ] 同步更新 `docs/police/architecture/07-fitness-tests.md` 的 FIT-12 现状。
