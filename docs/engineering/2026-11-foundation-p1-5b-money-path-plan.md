---
id: p1-5b-plan
type: plan
status: final
system: infra
owner: hermes
updated: 2026-11-08
review_by: 2027-03-31
---

# P1-5 二期施工计划：金额写路径收敛（拒绝语义）

> 一期（`2026-11-foundation-p1-5-plan.md`）做的是真机缺陷：跨资源引用 / 金额格式化 / 审计桥接 /
> 重启级联，A–G 阶段已全部完成。本文件对应总计划表里 P1-5 那条判据的剩余部分：
> **「安全校验收敛一份并接进写路径（拒绝语义，不是 clamp）｜`amount=999999` 返回拒绝；
> 5,000,000 上限只剩一处」**。

## 1. 先测量（2026-11-08 实测）

| 事实 | 数值 | 命令 |
|---|---|---|
| `SecurityService.MONEY_MAX_SINGLE_TRANSACTION` 定义点 | **1 处**（qb-core 的 server/services/security_service.lua 第 19 行） | grep `5000000` |
| `ValidateMoneyEvent` 调用点 | 2 处（qb-core 的 player.lua 的 offline `SetMoney` 分支、economy_service 的 SetMoney） | grep `ValidateMoneyEvent` |
| 直接写 `PlayerData.money[...] =` 的位置 | **6 处，全在 qb-core 的 player.lua**（收敛层自己） | grep `PlayerData.money[` |
| 金额写入口 | 3 个：`AddMoney` / `RemoveMoney` / `SetMoney` | — |

**结论**：「写路径已收敛到 qb-core」「阈值只剩一处」这两条成立；缺的是**三个入口的校验不一致**：

| 入口 | 负数 | `NaN` / `inf` | 超 5,000,000 |
|---|---|---|---|
| `EconomyService.AddMoney` | 拒（`<= 0`） | **通过**（`tonumber(math.huge)` 是 `inf`，`inf <= 0` 为假） | **通过** |
| `EconomyService.RemoveMoney` | 拒 | **通过**（余额检查会拦 `inf`，但 `NaN` 的比较恒假 → 可能写进 `NaN`） | **通过** |
| `EconomyService.SetMoney` | 拒 | 拒（走 `ValidateMoneyEvent`） | 拒 |
| qb-core 的 player.lua 三条 fallback（`_G.Bus.EconomyService` 缺失时） | `AddMoney` 拒负数，`RemoveMoney` 拒，`SetMoney` 走 `ValidateMoneyEvent` | **全部通过** | **全部通过** |

所以「999,999 会不会被拒」取决于走哪个入口 —— 这正是要收敛的东西。`999999` 本身低于 5,000,000，
**不该**被阈值拒；判据的真实含义是「同一个非法输入在所有入口得到同一个答复」。

## 2. 目标（三条可断言）

1. **一份实现**：金额校验只写在 `SecurityService.ValidateAmount(amount, opts)`，economy_service 与
   player.lua 的 6 条分支全部调它（economy_service / player.lua 在 fxmanifest 里都排在
   `security_service.lua` 之后，加载期直接取 `_G.Bus.SecurityService` 即可，不需要 fallback）。
2. **拒绝语义**：`NaN` / `inf` / 非数字 / 负数（add/remove 要求 > 0、set 允许 0）/ 超过
   `MONEY_MAX_SINGLE_TRANSACTION` 一律 `false`，**不夹取**（夹取会让"给 999999999 变成给 5000000"，
   比拒绝更难排查）。
3. **闸门**：静态断言「阈值常量全仓只出现一次」「`PlayerData.money[...]` 赋值只在 qb-core 的 player.lua」
   「三个写入口都引用 `ValidateAmount`」，每条配反向形状。

## 3. 不在本轮范围

- `MinusLimit` / `DontAllowMinus` 的业务语义（负余额上限）不动。
- `TransferMoney`（同文件另有实现）只做同样的入口校验，不改原子性策略（P2 再评）。
- core-framework 里的那份分层 security_service 副本**不动**：它是 `Bus.security` 的
  可选层，改它会把两份口径再次分叉；本轮只保证 qb-core 这份是唯一写路径的校验者。

## 4. 验证

| 编号 | 断言 | 方式 |
|---|---|---|
| V1 | 探针：`AddMoney` / `RemoveMoney` / `SetMoney` × {正常, 负数, `NaN`, `inf`, 字符串, 4,999,999, 5,000,001} | 真加载 `security_service.lua` + `economy_service.lua`（mock 玩家与 DB） |
| V2 | 同样七组输入在 `player.lua` 的 fallback 分支（Bus 缺失）得到同样答复 | 同一探针的第二段 |
| V3 | 闸门：阈值常量 1 处、`PlayerData.money[` 只在 `player.lua`、三入口都引用 `ValidateAmount` | `tests/architecture/test_money_write_path.py` + 反向 fixture |
| V4 | 全量回归 | `pytest tests/unit tests/architecture tests/integration` |
| V5 | 真机 | ⚠️ 改的是 qb-core：**有在线客户端时禁止 restart**（SOP §4），本轮只做 `luac5.4 -p` + 探针 + 全量测试，真机留到整服重启窗口 |

## 5. 完成记录（2026-11-08）

- `SecurityService.ValidateAmount(amount, opts)` 是唯一实现；`ValidateMoneyEvent` 的金额四步也收敛到它。
- economy_service 的三个入口 + player.lua 的 six 条分支（offline × 3 / fallback × 3）全部走它，无 fallback 副本。
- 探针 `money_path_probe.lua` 对 master 跑：`ECONOMY_AddMoney_NAN|accept`、`ECONOMY_AddMoney_INF|accept`、
  `ECONOMY_AddMoney_OVER|accept`、`ECONOMY_RemoveMoney_NAN|accept` —— 新版全部 `reject`，
  且 `999999` 与 `SetMoney(0)` 仍放行。
- 闸门 `test_money_write_path.py`（3 条判据 + 4 条反向形状），`gate_mutation_smoke.py` 3 条用例
  全部「注入后红 / 对照绿」。`gate_coverage` 未证明数保持 276。
- 真机（0 名玩家在线时）：`start qb-core` 后控制台依次出现
  `[SecurityService] ✅ Registered to _G.Bus.SecurityService` → `[EconomyService] Registered to _G.Bus.EconomyService`
  （加载顺序与 `local Security = assert(...)` 一致，无 assert 失败）；`resync_modules.ps1` 补回被连带停掉的资源，
  89 个资源、0 `SCRIPT ERROR`。
