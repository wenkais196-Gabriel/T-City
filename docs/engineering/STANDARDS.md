---
id: engineering-standards
type: meta
status: active
system: meta
owner: hermes
updated: 2026-11-01
review_by: 2027-04-30
topic: technical-standards
source_of_truth: true
tracks: [docs/engineering/CONSTITUTION.md, docs/engineering/ARCHITECTURE.md]
---

# STANDARDS — 技术标准 v0.2（可执行、可验证）

> **类型**：meta（规范） ｜ **适用**：`T-CityLite.base/resources/**`、`configs/modules/**`、`migrations/**`
> **配套**：`docs/engineering/ARCHITECTURE.md`（四平面与依赖方向）、`docs/engineering/CONSTITUTION.md`（十条红线）
> **一句话**：**写不成闸门的规则不算标准，只是建议。** 每条标准下面都必须有一个能红的测试。

## 0. 为什么需要这一页

宪法十条回答"什么不能做"，架构文档回答"谁可以调用谁"。缺的是第三层：**具体怎么落地，以及落地了没有**。
2026-11-01 的全仓审计给出的实测数字就是这一页的动机：

| 事实 | 实测值 | 后果 |
|---|---|---|
| net event 闸门覆盖 | 曾是 179 / 1102 次注册（16%）；2026-11-01 起引擎层 100%、全仓有基线棘轮 | 宪法④说的"每个事件"当时只管了六分之一 |
| SQL 闸门覆盖 | 15 / 117 次 MySQL 调用（13%） | 宪法③对框架层是空条款 |
| NUI 回调 | 218 处 / 34 文件，无任何闸门 | 客户端消息的信任边界没人管 |
| 存档实现 | 曾是两套 dirty 池 + 两个 900s 定时器，失败即清脏；2026-11-01 已收敛为单写者（失败保留 + 退避 + ack） | 当时会静默丢数据，现已消除 |
| "事件防火墙" | 561 行，运行期调用方 0 | 安全剧场比没有更危险 |

## 1. 五层模型（L = 职责层；P = 平面，见 ARCHITECTURE）

| 层 | 职责 | 唯一入口 | 不许做 |
|---|---|---|---|
| **L0 Boot** | 启停顺序 / convar / feature flag | `boot.json` → 生成的 cfg | 手写顺序注释当规格 |
| **L1 Store** | 玩家与实体数据读写（唯一 SQL 出口） | `Store.SaveFields(cid, fields)` / `Store.Load(cid)` | 业务资源直接写库 |
| **L2 Ledger** | 钱 / 物品 / 资质 | qb-core `Player.Functions.*` | 第二份内存账本 |
| **L3 Guard** | 鉴权 / 限流 / 审计 | `PolicePolicy.Can(src, cap)`、`RateLimit.*` | 各资源自己写 `if job.type` |
| **L4 Domain** | 业务（32 个自研资源） | `exports['<owner>']:service_<ns>_<verb>` | 资源之间同步互调而无超时/降级 |

依赖方向只有一条：**L4 → L3 → L2/L1 → DB**，以及 L0 被所有层读取。反向读状态、核心依赖业务，一律禁止。

## 2. 十三条标准

| # | 标准 | 规则（可执行） | 落点 / 缺口 | 宪法 |
|---|---|---|---|---|
| TS-1 | 分层与依赖 | P0–P4 是平面，L0–L4 是职责层；业务只向下依赖，P0 shared 不注册事件、不做 IO | `test_plane_boundaries.py`（需覆盖资源根的 `bus.lua`） | ⑧ |
| TS-2 | 跨资源契约 | 只走 export：先 `GetResourceState == 'started'`，再 `pcall` + 错误码；超时只用于事件请求/响应门面 | `check_bus_wiring.py`（PascalCase 应升 ERROR） | ⑧ |
| TS-3 | 数据所有权 | 一表一 owner；同表多写者必须在 `state_writers_allowlist.json` 登记 `allowed_files` 与理由 | `test_cross_resource_writes.py` | ⑥ |
| TS-4 | 钱与物品唯一出口 | 钱只走 `Player.Functions.*` / `core_economy:TriggerReward`；物品同样收口（现状 `TriggerReward` 直连 `qb-inventory:AddItem`，须登记或改道） | `test_economy_single_owner.py` | ② |
| TS-5 | 入站事件三件套 | 鉴权（`PolicePolicy.Can` / 常量 cap）+ 限流（key 含 src，登记预算）+ 投影；④ 的登记豁免保留，但每类豁免必须有 `expires` | `test_net_event_auth.py`（qb-core 已纳入，引擎层 100%）+ `test_net_event_inventory.py`（全仓 454 个服务端事件基线棘轮，存量按资源登记债务） | ①④⑦ |
| TS-6 | 持久化 | 字段级 dirty 位图；单条多列 upsert；**成功才清位**；失败保留 + 退避重试 + ack；幂等键防重放 | `test_persistence_single_owner.py`（单写者 / 成功才清 / 失败保留 + 退避 + ack **已落地** 2026-11-01）；仍缺：字段级位图、幂等键 | ⑤ |
| TS-7 | 启动与配置 | `boot.json` 单一来源生成 cfg（过渡期：`server.cfg` 唯一源，由 release_check 与模板比对）；convar 单位写进注释并有单测 | 缺 `test_boot_order.py` | ⑩ |
| TS-8 | 预算与可观测 | 指标必须是墙钟与计数（`GetGameTimer` 差值、oxmysql 调用点计数、出站 payload 字节），不用 `os.clock` 冒充阻塞时长 | `test_nui_baseline.py` + 探针 | ⑦ |
| TS-9 | 测试 | 先红后绿且必须离线可跑；闸门范围用棘轮推进：scope 清单 + 带 `expires` 的债务 + 预算只许下降 | `test_gate_coverage.py` / `gate_stats.py` | ⑨ |
| TS-10 | 交付 | 代码 + 文档 + `CHANGELOG.md`；`release_check.py --strict` 要求闸门 diff 带 `gate-change:` 说明，CI 跑 pytest | `tools/dev/release_check.py` | ⑩ |
| TS-11 | NUI 回调信任边界 | 会改状态或返回 PII 的 `RegisterNUICallback`（218 处）必须校验参数类型与来源玩家，并按 `GetPlayerServerId` 限流 | 缺 `test_nui_callback_trust.py` | ① |
| TS-12 | 网关调用者授权 | `core_economy:TriggerReward` 只允许登记在册的资源调用；每次发放写审计行（caller / activity / amount / 倍率），审计失败即拒绝 | `test_export_contracts.py`（现只覆盖 custom-police） | ②⑦ |
| TS-13 | 迁移 | 版本号全局唯一且递增；幂等（`information_schema` 判断）；与 `tests/fixtures/tcity_schema.sql` 快照同步 | 缺 `test_migration_version.py`（现存 v3.11 / v3.12 各两条重号） | ⑤⑩ |

## 3. 执行阶梯（标准怎样从纸面变成闸门）

1. **advisory**：先落测试、`continue-on-error`，公开推进条件（例如"登记率 ≥ 90% 且零断链"）。
2. **棘轮**：新增债务必须带 `owner` + `expires`；`expires` 过期即红；预算只许下降。
3. **blocking**：干净之后转阻断。对 95% 未登记的仓库直接阻断，只会教会所有人绕过 CI。

## 4. 与宪法的关系

- **不重复**：宪法是十条不可协商的不变量；本页是它们的施工细则。冲突时以宪法为准，并回到本页改细则。
- **加新标准**的门槛同宪法：同类错误重复两次以上，且能用一条闸门表达。
- **删闸门**同样要依据：拦下的规则如果背后没有宪法或本页条款，就删，否则闸门会变成噪音。

## 5. 复审

本页每 180 天复审一次，或任一标准对应的闸门被移除/放宽时立即复审。复审时只看两件事：
闸门是否还红得起来（反向校验），以及标准是否还覆盖真实的高风险面（覆盖率数字）。
