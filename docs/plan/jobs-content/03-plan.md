---
id: jobs-content-03-plan
type: plan
status: draft
system: jobs
owner: hermes
updated: 2026-11-13
review_by: 2027-02-28
stage: P
---

# 计划：R1 多站驾驶（garbage + bus）

> 阶段 P 的产物。上游：[01-research.md](./01-research.md)（R）、[02-design.md](./02-design.md)（D）。
> 本计划只覆盖 **R1**；R0（trucker 收编）与 C1（validator 闸）已合并进 master。

---

## 1. 范围

**要做**

- `garbage`：站点谱 + 袋数计价 + 服务端校验（复用 C1 的 `validator_id` 机制）
- `bus`：站点谱 + 准点率 + 服务端校验
- 两者共用一份 `validate_route_stop` 校验器（不写两份）

**明确不做**（防膨胀）

| 不做 | 为什么 |
|---|---|
| NPC 顾客/乘客 | 属于 R2/R3；C4 顾客预算还没做，先不引入 NPC |
| 新表 / 新资源 / 新 net event | 本轮硬约束（roadmap §8） |
| 乱序多站 | 线性 FSM，永久不做（02-design §4） |
| garbage/bus 的专属 HUD | 先复用现有「站 3/6」进度（quest 面板），专属 HUD 等 R2 的 taxi 计价表一起做 |

---

## 2. 验收标准（可执行）

| # | 标准 | 怎么验证 |
|---|---|---|
| 1 | 校验器只在「顺序正确 + 在岗 + 在站」时返回 true | `pytest tests/unit/layer3_business/test_route_stop_validator.py` → 8 条用例全绿（含 3 条反向形状） |
| 2 | 跳站/乱序被拒 | 同一套用例里的 `out_of_order` 形状 → `false` + 错误码 |
| 3 | 非 garbage/bus 触发结算被拒 | probe 里 job=unemployed 触发 → 无 money / 无 rep |
| 4 | 单次结算只发一条 | 沿用 quest 的「完成才 toast」；probe 断言 money 只加一次 |
| 5 | 数值落在低技能带 | 数值卡：garbage 4/6/8 站 → $370/$705/$1,140；bus 6/8/10 站 → $486/$648/$810（02-design §2.3） |
| 6 | 全量门禁绿 | `pytest tests/unit tests/architecture`；`docs_lifecycle --check` |

---

## 3. 切片（每片独立可运行）

| 片 | 内容 | 可独立验收 |
|---|---|---|
| **P1** | `validate_route_stop` 校验器 + 单测（纯逻辑，先红后绿） | 是（离线用例） |
| **P2** | garbage 的站点谱配置 + 接进 quest 池 | 是（能接单、能按序推站） |
| **P3** | bus 的站点谱配置 + 准点率系数 | 是（同上） |
| **P4** | 数值卡落地 + 文档/CHANGELOG | 是（数字对得上 02-design） |

---

## 4. 任务清单

| # | 任务 | 文件 | verify（命令/断言） | 状态 |
|---|---|---|---|---|
| 1 | 写复现用例（RED）：乱序/跳站/远距/非本职业 四种形状必须被拒 | tests/unit/layer3_business/test_route_stop_validator.py + 同目录 fixtures 里的 route_stop_probe.lua | `pytest ...test_route_stop_validator` 失败 | ☑ 2026-11-13（#248） |
| 2 | 实现校验器（GREEN）：custom-quest 的 server/quest_route_validators.lua | 新文件 + fxmanifest | 同一用例通过 | ☑ 2026-11-13（#248） |
| 3 | garbage 站点谱配置 | custom-quest 的 config/quests/quest_garbage.lua（新）+ fxmanifest `files` | 接单后 `current_step` 按序推进 | ☑ 配置已落：`quest_garbage.lua` 三档（4/6/8 站） |
| 4 | bus 站点谱配置 + 准点率 | custom-quest 的 config/quests/quest_bus.lua（新） | 同上；准点率影响结算金额 | ☐ |
| 5 | 数值卡落进配置（per_stop / 袋价 / 准点区间） | 两份新配置 + `02-design.md` §2.3 对齐 | 单趟收益与 §2.3 差 ≤15% | ☑ garbage：370/705/1140 与 §2.3 一致，测试钉住 |
| 6 | 反向校验：把校验器改成 `return true` → 用例必须红 | 同上 | 手动注入后 `pytest` 红 | ☑ 反向：删掉配置文件 → probe 直接失败 |
| 7 | 文档 + CHANGELOG | roadmap §5 R1 打勾说明、CHANGELOG | 文档引用路径真实存在 | ☐ |
| 8 | 交付检查 | — | `tools/dev/release_check.py` | ☐ |

---

## 5. 并行度与顺序

`P1 → P2 → P3 → P4` 串行：P2/P3 都依赖同一份校验器，先把它做对再铺内容；
P4 只改配置与文档，可在 P2/P3 之后并行收尾。

---

## 6. 风险

| 风险 | 缓解 |
|---|---|
| 校验器依赖 `destCoords`/`radius` 注入，注入不上会把玩家拦死 | P1 用例里显式覆盖「没有注入」的形状 → 返回明确错误码，不静默 true |
| 与现有 `quest_public_services.lua` 里的 shell 任务重名 | 新配置用不同 id 前缀 `garbage_v1_*` / `bus_v1_*`，旧壳保留不动、不进池 |
| 两份新配置让 `files {}` 与 `AutoLoad` 不一致 | fxmanifest 的 `files` 与注册表都改；`test_manifest_syntax` 会拦 |

---

## 7. 施工记录

| 日期 | 切片 | 结果 |
|---|---|---|
| 2026-11-13 | P1 校验器 | #248 合并；8 条用例（含冷启动与跨任务隔离）；CC 复核后补了两条绕过路径 |
| 2026-11-13 | P2 garbage 配置 | `quest_garbage.lua` 三档（4/6/8 站，$370/$705/$1,140）；3 条配置测试钉住站号连续 / 元数据齐全 / 首尾 interact / id 唯一 |

**已知缺陷（既有，不在本轮修）**：`conditions.daily_limit` 在 custom-quest 里**没有调用点**
（`quest_db.lua` 只定义查询，`CheckDailyLimit` 无人调用），所以配置里写的每日上限目前**不生效**。
数值卡落地时应把它接上，或用冷却兜住。
