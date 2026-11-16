---
id: jobs-content-13-hotdog-remaining-plan
type: plan
status: active
system: quest
owner: hermes
updated: 2026-11-16
review_by: 2027-02-28
plan_status: 1
---

# 热狗摊：剩余工作分片计划（2026-11-15 复核）

> 来源：CC 的只读调研（会话临时目录下的调研原文，2026-11-15，未入库）。本文件是**验收后**的版本：
> 数字换成实跑值、已修的项标掉、并补上验收时发现的偏差。调研原文是时点证据，不再随代码更新。
> 上一阶段（S0–S5 + CEF 摊位菜单）见 `docs/plan/jobs-content/11-hotdog-dev-plan.md`。

## 0. 验收结论

| # | 结论 |
|---|---|
| 1 | 接受推荐并已执行：**B0 账单数据修复 + B 音效** 已合入（PR #302，`2d78e0f1`）；下一片候选见 §5 |
| 2 | 调研报告的三条硬指控全部复核为真：`PushFor` 未定义、账单 summary 丢失、买家拿不到他人摊位状态 |
| 3 | 报告里 `gate_coverage` 写的是 `total 551 / proven 273`，那是 `T-CityLite.base/tests/architecture/gate_coverage_budget.json` 的记录值；**实跑是 574 / 296 / unproven 278**。报告自己也声明了「未实跑」，不算错，但不能当基线用 |
| 4 | 报告漏了一条：`move` 分支在客户端**没有任何触发路径**（custom-quest 的 client 目录里 grep move 零命中），所以 A11「挪位」不是"差验收"，是"没做客户端" |
| 5 | `docs/plan/jobs-content/11-hotdog-dev-plan.md` §6 的「起始库存 普通 2」与配置不符（`T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_hotdog.lua:83` 是 `common = 6, rare = 3, exotic = 1`）；数值统一由 E 片定稿，这条只登记不改 |

## 1. §6「真机状态」的 ✅ 有几行是假的

| §6 行 | 复核结果 | 证据 |
|---|---|---|
| 模板 `hotdog_dev_rental` 4 步 | 仍成立（注册期会追加一个透明 `step_reward`，quest_manager.lua:975 直接跳过） | `T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_hotdog.lua:21` |
| 押金 / 计租 / 补退 | 成立 | `T-CityLite.base/resources/[custom]/custom-quest/server/quest_rental.lua:84-149,161-238` |
| 摆摊判定三条硬判据 | 成立，但描述要加 `move`（`MoveTo` 只改坐标不重建实体） | `T-CityLite.base/resources/[custom]/custom-quest/server/quest_booth.lua:296`、`T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua:433` |
| 做热狗 `G` → `KeyMinigame(10)` | 成立；**键位与 UX 规格相反**（规格 E 做热狗 / G 开卖） | `T-CityLite.base/resources/[custom]/custom-quest/client/quest_hotdog_vendor_client.lua:1015` |
| 顾客 8–15 s 首位、ped 随报价删除 | 成立；但 ped 是**原地生成**（2.2 m），不是规格要求的 25–40 m 走位 | `T-CityLite.base/resources/[custom]/custom-quest/client/quest_hotdog_vendor_client.lua:283` |
| 玩家购买 `ALT` 菜单 | **不可达**：服务端只把状态推给摊主本人，买家客户端没有任何摊位 | `T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua:77-94`、client 目录同文件的 28-31 行 |
| 账单六行 + 幂等 | **数值会丢**：收摊时 summary 拿到就扔，任务完成时再取已是 nil | `T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua:456-484`、`T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua:1032` |
| 起始库存 普通 2 | **过时**：配置是 6/3/1 | `T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_hotdog.lua:83` |
| 事件面 440 / 0 未登记 | 成立（PR #300 只改 `measured_at`；action 白名单 5 → 6 加了 `move`） | `T-CityLite.base/tests/architecture/net_events_baseline.json` |

## 2. 剩余分片

| 片 | 内容 | 依赖 | 撞闸门 | 真机 | 老板拍板 | 预估 |
|---|---|---|---|---|---|---|
| **B0** 账单数据修复 | 缓存收摊 summary（一次性消费 + 过期），任务完成时 `issueSettleReceipt` 拿到真实售出/库存/原料 | — | 不撞 | 否 | 否 | 0.5 天 |
| **B** 音效 | `doorbell`（25 m 世界声）+ `Shop`（只给交易双方），零新增素材 | — | 不撞（不新增 net event、不新增 `-1` 广播） | 是（听感） | 否 | 0.5 天 |
| **A** 手机账单卡片 | 先出原型给老板挑，**不进仓库**；实现等拍板 + B0 | B0 | 实现时撞 NUI 契约 / money format | 实现要 | **是**（宿主与视觉） | 1 天原型 |
| **C** 旧壳下线调查 | 只读盘点 `hotdog_vendor` 的注册 / convar / UI / 测试 / 文档 / DB 残留 | DB 只读权限 | 不撞 | 否 | 否 | 0.5 天 |
| **D1** 新线转正 | 去 `quest_hotdog_dev` convar、`category='test'` → 正式、定职业门槛 | 数值定稿 + 真机 V1–V8 | `test_quest_economy.py`（vendor 型收入口径要显式化） | 是 | **是** | 1 天 |
| **D2** 旧壳删除 | 删 `hotdog_vendor` 模板块 + 同步测试 / 文档 / CHANGELOG | D1 上线 + 并行观察 7 天 + C 的 DB 确认 | `test_quest_economy.py`（`SHELLS` 7 条）、`test_quest_coords.py` | 是 | **是** | 0.5 天 |
| **E** 数值定稿 | 押金 / 租金 / 单价 / 回收 / 税 / 起始库存 / 顾客节奏 + 配置校验测试 | **测试期占位值已配**（押金 50 / 租金 1 / 单价 8·16·32 / 顾客 3–6 s，见 `docs/plan/jobs-content/14-hotdog-live-checklist.md` §0）；正式值等经济系统联动 | 会动 `test_quest_economy.py` 口径 | 是 | **是**（正式值） | 2 天 |

**顺序**：B0 → B 可立刻做（互不共享文件）；A 的原型可与 B 并行，但**实现必须等 B0**（否则卡片上售出永远是 0）；
E → D1 → D2 串行；C 随时可做，产出一份调查文档。

```plan-status
B0 | done | #302 | -
B  | done | #302 | -
A  | done | #316 | -
C  | todo | - | -
D1 | todo | - | -
D2 | todo | - | -
E  | wip  | - | -
```

## 3. 阻塞项

| 阻塞 | 卡在哪 | 谁能解 |
|---|---|---|
| 买家拿不到他人摊位状态 | `T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua:77-94` 只按摊主 `source` 推 | 开发（按附近玩家推 `isOwner=false`） |
| `vendor` 步骤同时挂通用 interact 节点 | `T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua:177` + `T-CityLite.base/resources/[custom]/custom-quest/client/main.lua:415` | 开发（去掉该步的通用 interact 数据） |
| 摆摊坐标未与实体真实坐标比对 | `T-CityLite.base/resources/[custom]/custom-quest/server/quest_booth.lua:224-247` | 开发（容差 ≤ 3 m）——红线① |
| CEF 按钮没有焦点路径 | 全 `custom-quest` 无 `SetNuiFocus`，按钮靠鼠标 | 开发 + 真机 |
| 状态条缺顾客 / 押金 / 剩余时间三项 | `T-CityLite.base/resources/[custom]/custom-quest/html/vendor.html:95-102` | 开发（S6 半成品） |
| 数值未定稿 | 老板决定 | 老板 |
| 旧壳 DB 残留未知 | 无库权限 | 有库权限的人 |

## 4. 本轮已修

| 项 | PR |
|---|---|
| 账单售出 / 回收行恒为 0（收摊 summary 拿到就扔） | #302（B0：30 分钟缓存 + 取走即删 + 开新会话即清） |
| 顾客上门 / 收银音效（零新增素材） | #302（B 片：`doorbell` 25 m + `Shop` 三人称音量 0.35/0.3/0.25） |
| `QuestVendorBridge.PushFor` 未定义（`move` 分支运行期崩） | #301，附新闸门 `T-CityLite.base/tests/architecture/test_namespace_method_calls.py` |
| 摊位 CEF 菜单的 `post()` 缺超时（NUI-CLIENT-01） | #300 |
| `local function` 定义在调用之后（`coronerFeedback` / `HidePreviewText`） | #300 + `test_lua_local_order.py` |

## 5. 下一片候选（按可开工度）

| 片 | 为什么可以做 | 前置 |
|---|---|---|
| **A 手机账单卡片原型** | B0 已合入，账单数据不再是 0；原型只在会话临时目录做，不进仓库 | 老板挑视觉（宿主：任务 App 详情栏 / 通知摘要 / 独立 App / 游戏内菜单） |
| **C 旧壳下线调查** | 只读盘点，不依赖数值与真机 | 需要 DB 只读权限才能确认在线存档 |
| 买家能看到他人摊位（A10） | 卡在服务端只按摊主 `source` 推状态 | 开发 + 真机双人 |
| 数值定稿 → D1 新线转正 → D2 删旧壳 | 测试期占位值已配好（够单人验收）；**正式值**仍等经济系统联动 | 老板 |
