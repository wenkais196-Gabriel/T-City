---
id: jobs-content-13-hotdog-remaining-plan
type: plan
status: active
system: quest
owner: hermes
updated: 2026-11-17
review_by: 2027-02-28
plan_status: 1
---

# 热狗摊：剩余工作分片计划（2026-11-17 分工版）

> 本文件是这条线**唯一的执行计划**：现状（§1）＋分片（§2）＋阻塞（§3）＋CC/Hermes 分工与验收闸（§6）＋拍板点（§7）。
> 上一阶段（S0–S5 + CEF 摊位菜单）见 `docs/plan/jobs-content/11-hotdog-dev-plan.md`；真机清单见
> `docs/plan/jobs-content/14-hotdog-live-checklist.md`；UX 规格见 `docs/plan/jobs-content/10-hotdog-ux-spec.md`。
>
> 2026-11-17 修订：把 11-15 复核时的阻塞项逐条回代码核过——4 条已修的**直接换成实际 commit**（不留原文再加一句"已修"），
> 并补上两片代码里仍真实存在的缺口（F 坐标复验、G 顾客走位）。数字全部来自实跑（1813 passed / 147 skipped，2026-11-17）。

## 0. 口径

- 状态事实源按可信度：`plan-status` 块 → `docs/plan/BOARD.md` → 正文 → 代码。正文里的"阻塞项""真机状态"是**时点快照**，
  引用前必须回代码核一遍（本文件 §1 就是这次核完的结果）。
- 数字只写实跑值；`net_events_baseline.json` / `gate_coverage_budget.json` 里的记账值要标"记录值"。
- 真机项没有填写记录就写"无记录"，不因为代码看起来对就归到已完成。

## 1. 现状：真机状态逐条回核（2026-11-17）

| 项 | 结论 | 证据 |
|---|---|---|
| 模板 | `hotdog_dev_rental`（租 → 摆 → 卖 → 还 + 透明 `step_reward`），convar `quest_hotdog_dev` 才加载 | `T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_hotdog.lua:14`、`:21` |
| 押金 / 计租 / 补退 | 成立：`rental_open` / `rental_close` 落 `quest_event_log`，断线退款排队到下次登录 | `T-CityLite.base/resources/[custom]/custom-quest/server/quest_rental.lua:84-149`、`:161-238` |
| 摆摊三判据 + 挪位 | 成立：离租赁点 200 m / 离路面 6 m / 离其它摊位 15 m；`move` 复用同一条 `ValidatePlacement` | `T-CityLite.base/resources/[custom]/custom-quest/server/quest_booth.lua:196-247`、`T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua:603-622` |
| 挪位客户端触发路径 | 成立（11-15 时被判"没做客户端"，已实现）：放下推车后重按 E 走 `vendorAction('move')` | `T-CityLite.base/resources/[custom]/custom-quest/client/quest_hotdog_client.lua:393`、`:774` |
| 做热狗 | `G` → `KeyMinigame(10)` → 客户端只报 `faults`，品质由服务端定 | `T-CityLite.base/resources/[custom]/custom-quest/client/quest_hotdog_vendor_client.lua:804-825` |
| 键位 | **与规格 §5.1 相反且是有意的**：规格 E 做热狗 / G 开卖，代码 E 开卖收摊 / G 做热狗（文件头注释写明"按任务书用 E / ALT"）。这是待拍板项，不是缺陷 | `T-CityLite.base/resources/[custom]/custom-quest/client/quest_hotdog_vendor_client.lua:23-25`、`:1211`、`:1216` |
| 顾客 | 首位 3–6 s、之后 6–15 s、耐心 30 s；**ped 仍在摊位旁 2.2 m 原地生成，没有 INBOUND 走位** | `T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_hotdog.lua:83-88`；`SpawnCustomerPed` 同 client |
| 玩家购买 | `ALT`（LMENU）打开 6 m 内他人摊位菜单；先扣买家再动库存，失败退款 | `T-CityLite.base/resources/[custom]/custom-quest/client/quest_hotdog_vendor_client.lua:1231`、`T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua:560-599` |
| 旁观者可见摊位 | 成立：`Broadcast.Scope` 按坐标 10 m 推送，payload 在唯一一个构造函数里做字段白名单（不含 citizenid / 收入 / 库存明细） | `T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua:371-423` |
| 账单六行 + 幂等 | 成立：收摊 summary 缓存 30 分钟、取走即删；幂等键按班次 `questId:complete:<runToken>` | `T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor_bridge.lua:40-46`、`T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua`（P1a） |
| 手机账单卡 | 成立：任务 App 第三个 tab，走 `GetQuestReceipts` 内存账本 | `T-CityLite.base/resources/[custom]/custom-quest/server/main.lua:697`、`T-CityLite.base/resources/[custom]/custom-phone/server/apps/quests.lua:61` |
| CEF 焦点 / 状态条六项 | 成立：`SetNuiFocus` 单点归 `vendor_focus`，六条退出路径；状态条有成品三档 / 原料 / 已售 / 收入 / 顾客 / 押金 / 剩余 | `T-CityLite.base/resources/[custom]/custom-quest/client/vendor_focus.lua`、`T-CityLite.base/resources/[custom]/custom-quest/html/vendor.html:106-109` |
| 起始库存 | 6 / 3 / 1（测试期占位） | `T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_hotdog.lua:90` |
| 收摊单通道 | 成立：`step_sell` 不再带 coords/radius，vendor 步只由服务端收摊分支推进 | `T-CityLite.base/resources/[custom]/custom-quest/config/quests/quest_hotdog.lua:95-104` |
| 事件面 | `custom-quest` 11 条 net event / 0 未登记（记录值，2026-11-15） | `T-CityLite.base/tests/architecture/net_events_baseline.json` |
| 全量测试 | 1813 passed / 147 skipped / 51 subtests，287 s（2026-11-17 实跑） | `C:/Users/swkgb/AppData/Local/Programs/Python/Python312/python.exe -m pytest tests/unit tests/architecture -q` |

## 2. 剩余分片

| 片 | 内容 | 谁开发 | 依赖 | 撞闸门 | 真机 | 拍板 | 预估 |
|---|---|---|---|---|---|---|---|
| **F** 摊位坐标服务端复验 | 入库存**实体真坐标**；判据顺序 payload → `ResolveEntity` → `DoesEntityExist` → 玩家 50 m → 模型 → 实体距离 ≤3 m → `ValidatePlacement` → 入库；`move` 用服务端 `booth.netId` 解析实体（忽略 `payload.netId`）。**前置：先修探针的向量桩**——`booth_probe` 的 `__sub` 返回普通表、`#` 恒 0，50 m 判据在探针里一直是空转（实跑 17/17 全绿是假绿） | CC | — | 无新 net event；`max_unproven` 281 → 282，须按实测下调 | S4（远距/挪位） | 否 | 1 天 |
| **G** 顾客 INBOUND 走位 | 25–40 m 生成 → 走向摊位 → 2.5 m 进 WAITING；**同时改服务端报价时机**：`CreateOffer` 在 `spawn_customer` 同一 tick 就设 `expiresAt = now + patience_ms`，30 s 耐心扣掉 18–29 s 走位只剩 1–12 s → 二选一（抬高 `patience_ms` 到「走位上限 + 决策窗口」，或顾客到位后才开价）；成交/拒绝/超时立即清理；前 3 s 不碰撞 | CC | — | 循环预算（禁新增 `Wait(0)` 轮询，复用主循环）、`max_global_npcs` 是服务端活跃报价上限不是 ped 上限、禁 `-1` 广播 | S6、M7 ⛔ | 耐心值归 E 定稿 | 1.5 天 |
| **H** 文档纠偏（Hermes 自做） | 本文件 §1/§3；`14` §1 两条过时缺口；`11` §6 加时点标注并指向本文件；`10` §5.1 键位行按拍板结果改；重生成 BOARD | Hermes | 键位拍板（只有那一行要等） | 文档断链闸 / 文档生命周期检查 | 否 | 部分 | 0.5 天 |
| **C** 旧壳下线调查 | 只读盘点 `hotdog_vendor` 的注册 / convar / UI / 测试 / 文档 / DB 残留 | CC（静态）＋ 人（DB） | DB 只读权限 | 不撞 | 否 | 是（库权限） | 0.5 天 |
| **E** 数值定稿 | 押金 / 租金 / 单价 / 回收 / 税 / 起始库存 / 顾客节奏（**含走位时间**：耐心要覆盖 18–29 s 步行）+ 配置校验测试 + 任务经济闸的 vendor 收入口径显式化。**不要动 `number_budget.json`**：它是 police 的 FIT-13 专用表（固定 11 个 id、只认三份 police 文档），quest 侧要登记数字就另建表并配自己的测试 | CC | 拍板 | `T-CityLite.base/tests/architecture/test_quest_economy.py` | 是 | **是** | 2 天 |
| **D1** 新线转正 | 去 `quest_hotdog_dev` convar、`category='test'` → 正式、定职业门槛 | CC | E 定稿 + 真机 V1–V8 | `T-CityLite.base/tests/architecture/test_quest_economy.py` | 是 | **是** | 1 天 |
| **D2** 旧壳删除 | 删 `hotdog_vendor` 模板块 + 同步测试 / 文档 / CHANGELOG | CC | D1 上线 + 并行观察 + C 的 DB 确认 | `T-CityLite.base/tests/architecture/test_quest_economy.py`、`T-CityLite.base/tests/architecture/test_quest_coords.py` | 是 | **是** | 0.5 天 |

**顺序**（不改，理由在括号里）：

1. **F → G**（互不共享文件，可各自成 PR；两片都不依赖任何拍板，现在就能开）
2. **H 拆三段**：不依赖 F 的部分（`14` §1 两条过时缺口、`11` §6 加时点标注）现在改；本文件 §1/§3 里关于 F/G 的行**等对应片合入后**才改（否则写的是假现状）；`10` §5.1 键位行单列，等拍板 #1
3. **C** 随时（静态盘点可以现在做，DB 那半等权限）
4. **E → D1 → D2** 串行（D1 要正式数值才能算 $/h；D2 要 D1 上线后观察）；E 的耐心值必须含走位时间（见 §2 G 行）
5. 真机单人 S1–S13 可以在任一片合并后跑，不阻塞开发

```plan-status
B0 | done | #302 | -
B  | done | #302 | -
A  | done | #316 | -
C  | todo | - | -
D1 | todo | - | -
D2 | todo | - | -
E  | wip  | - | -
F  | done | T-CityLite.base/tests/unit/layer3_business/test_quest_booth.py | -
G  | todo | - | -
H  | todo | - | -
```

## 3. 阻塞项（只剩 4 条，其余已修）

| 阻塞 | 卡在哪 | 谁能解 |
|---|---|---|
| 顾客原地生成，没有 25–40 m 走位（连带服务端报价时机） | `T-CityLite.base/resources/[custom]/custom-quest/client/quest_hotdog_vendor_client.lua` 的 `SpawnCustomerPed`（2.2 m）；`T-CityLite.base/resources/[custom]/custom-quest/server/quest_vendor.lua:551` 在 spawn 同一 tick 开价 | 开发（G 片） |
| 数值未定稿 | 老板决定 | 老板 |
| 旧壳 DB 残留未知 | 无库权限 | 有库权限的人 |

> 摊位坐标未复验（红线①）**已解**：`QuestBooth.VerifyEntity` 集中判据、入库存实体真坐标、`move` 用服务端 `booth.netId`；
> 证据见 `docs/plan/jobs-content/14-hotdog-live-checklist.md` §4（真机部分仍是 ⛔）。

## 4. 本轮已修（可点回 commit）

| 片 | 项 | PR / commit |
|---|---|---|
| **B0** | 账单售出 / 回收行恒为 0（summary 拿到就扔） | #302 |
| **B** | 顾客上门 / 收银音效 | #302 |
| **A** | 手机账单卡（第三个 tab + 已结算） | #316 |
| — | 买家看不到他人摊位 → `Broadcast.Scope` 10 m 白名单推送 | #304 |
| — | `vendor` 步骤同时挂通用 interact（收摊推进两次） | #305 |
| — | CEF 焦点单点 + 状态条六项 | #319 |
| — | 摊位 CEF 菜单（中文不再方块）+ 摊位微调 | 40e7c4a7 |
| — | 账单幂等键按班次 + `GetQuestReceipts` 导出 | 01124843 |
| — | `QuestVendorBridge.PushFor` 未定义 | #301（附 `T-CityLite.base/tests/architecture/test_namespace_method_calls.py`） |
| — | `local function` 定义在调用之后 | #300 + `T-CityLite.base/tests/architecture/test_lua_local_order.py` |

## 5. 明确不做

- 不新增 net event（F/G 都用现有 `quest:client:*` 与本地表现）。
- **改**顾客报价的**时机**（G 里那二选一），但**不改**排班的概率、间隔与全局上限。
- 不动 police 的 `NPCBudget`（那是另一个平面），热狗 NPC 上限沿用 `max_global_npcs`。
- 不动 `number_budget.json`（police 的 FIT-13 专用表）。
- 不在本轮做数值调优（E 片，且必须先拍板）。
- 不删旧壳（D2 要观察期），不顺手改相邻模板。

## 6. CC 开发 / Hermes 验收协议

### 6.1 每片 DoD（九条，缺一条不算完成）

1. 代码 + 配置 + 测试，且**反向校验必须写明形态**：测试名带 `rejects` / `detects` / `on_bad_shapes`，或同 PR 加一条 `gate_mutation_smoke` 用例（否则新增前向规则把 `max_unproven` 往上顶）；
2. 全量套件绿（实跑输出贴进 PR）；
3. 新 net event 已登记（本批预期 0 条；用 `net_events_baseline.json` 的 diff 证明 0 条）；
4. 真机三态**落到 `14-hotdog-live-checklist.md`**：每条 ✅ / ⚪ / ⛔ + 日期 + 日志行或截图。只写一句 ⛔ 不算——⛔ 要写"做到哪一步 + 缺什么"，并同时进本文件 §3；
5. `CHANGELOG.md` 一行；
6. 记账类文件按实测更新：`T-CityLite.base/tests/architecture/gate_coverage_budget.json` 的 `max_unproven` 下调到实测值；`T-CityLite.base/tests/architecture/io_budget.json` 不涨（涨了要写理由）；
7. 触及的 UX/清单行同步改：新错误码、走位行为进 `10` 与 `14` 对应行，不许只活在代码注释里；
8. 合入后更新 `plan-status` 块与本文件对应行，`python tools/docs_lifecycle.py --board` 重生成 `docs/plan/BOARD.md`；
9. 回滚方式在 PR body 里写一句（对应 §8 那一行）。

### 6.2 验收命令（CC 与 Hermes 必须跑同一条）

```bash
# Hermes 侧（本机 shell 是 bash）
PY="C:/Users/swkgb/AppData/Local/Programs/Python/Python312/python.exe"   # 本机唯一带 pytest 的解释器
cd T-CityLite.base && "$PY" -m pytest tests/unit tests/architecture -q     # 基线 1813 passed / 147 skipped
"$PY" tools/dev/gate_mutation_smoke.py --only <本片关键字> && echo matched>=1   # 零命中时脚本返回 2，不是绿
luac5.4 -p <改过的 .lua>
```

> CC 侧是 PowerShell：变量写 `$PY`，Lua 必须写 `luac5.4.exe -p`（裸名会被 Windows 当"文档"交给
> OpenWith 并阻塞命令）。两边跑的是同一组文件，命令形状各自适配。

### 6.3 CC 的硬约束（写进每份任务书）

1. ⛔ 不许 `Stop-Process` / `taskkill` / `kill` 任何进程（包装器本身是 python）。
2. 全量 pytest 正常 4–5 分钟，不是卡死；先跑改到的文件，最后跑全量。
3. ⛔ 不许 `git add -A`；逐文件 add，提交前 `git status --short` 看一眼（树里可能有我的未提交改动）。
4. 不许为了让测试变绿而放宽闸门 / 预算 / 白名单；被拦先判断是代码错还是规则错，写进 commit message。
5. 一票一会儿一个 PR；**不 push、不开 PR、不 merge**，git 操作归 Hermes。
6. 需要真机才能确认的写进 ⛔，不许写成"已验证"。

### 6.4 Hermes 的验收（独立，不抄 CC 的输出）

1. `git diff --stat` 对着 §2 的文件清单逐条核，多出来的路径要理由。
2. 自己复跑 6.2 的三条命令；结果以我的输出为准。
3. 反向注入**两种改法**：整块删掉 + 把守卫短路成 `if false and …`；两种都要红，只删就红的是"接线测试"。
4. **先证明探针的桩没把判据短路**：`booth_probe` 的向量桩让 `#` 恒 0，距离类判据在探针里从未执行过（实跑 17/17 是假绿）。凡新加距离/坐标判据，先修桩再写用例，并留一条"桩失效会红"的反向用例。
5. 在干净 worktree（`git worktree add E:/T-City-ci-sim HEAD`）跑一次，防 gitignored 文件造成的假绿。
6. CI 全绿才 merge（`gh pr checks <n>` 计数为 0），然后补 CHANGELOG / 索引 / 清分支。

## 7. 拍板点（需要老板，按影响面排序）

| # | 问题 | 选项 | 影响 | 不拍板的后果 |
|---|---|---|---|---|
| 1 | 键位以哪边为准 | Ⓐ 维持代码：E 开卖/收摊、G 做热狗、ALT 购买（任务书口径）· Ⓑ 对齐 UX 规格 §5.1：E 做、G 开卖 | H（只改规格一行）或另开一片改键位映射 + 全部文案 | 文档与代码互相矛盾，下一轮读文档的人会把代码改回规格 |
| 2 | 正式数值 | 押金 / 租金 / 单价 / 回收 / 税 / 起始库存 / 顾客节奏，按目标 $/h 反算 | E → D1 | E 无法开工，D1/D2 全部堵在这里 |
| 3 | 摆摊门槛 | 所有平民 / 需执照 / 需在岗特定职业 | D1 | D1 无法定 `category` 与接单条件 |
| 4 | 旧壳观察期 | 现定 7 天，可改 | D2 | 只影响 D2 的开工日期 |
| 5 | DB 只读权限 | 谁给、给哪个库 | C | C 只能交静态盘点，在线存档那半标 ⛔ |

## 8. 回滚方式

| 片 | 回滚 |
|---|---|
| F | `git revert <sha>`；无迁移。若线上出现误拒，可临时把容差从 3.0 放宽到 10.0 并记债 |
| G | `git revert <sha>`；顾客 ped 回到原地生成，不影响权威状态 |
| E | `git revert <sha>` + 重启 `custom-quest`（数值只在配置里，无 DB） |
| D1 | 把 convar 与 `category` 改回 = revert；旧模板在 D2 之前一直留着 |
| D2 | revert 单个 commit 即可恢复模板块；前提是 D1 已上线且观察过 |
