# 08 — Agent 中枢游戏导演：架构设计与三阶段落地

> **版本**: v0.1（设计稿，未实现）
> **日期**: 2026-10-21
> **定位**: 把 [00–07](README.md) 的"所有权/涌现"设计，落到"AI 导演介入"这一层
> **前置**: [01 预设→涌现漏斗](01-preset-to-emergent-funnel.md)、[05 叙事所有权](05-narrative-ownership.md)、[07 架构集成](07-architecture-integration.md)

---

## 0. 一句话结论

**不要做一个"全知全能的 LLM GM"，要做一个"有预算、有边界、可审计的导演代理"。**

导演的职责不是替玩家玩，而是持续回答三个问题：

1. 现在场上**缺什么**（冲突、机会、信息、压力）？
2. 用什么**最小介入**补上它？
3. 玩家**没有接**这个引导时，如何体面地退场？

这决定了架构必须是 **观察 → 提议 → 规则裁决 → 执行 → 反馈** 的闭环，而不是"LLM 直接改数据库"。

---

## 1. 反模式（先排除错误答案）

| 反模式 | 为什么错 | 正确做法 |
|:---|:---|:---|
| LLM 直接 `AddMoney` / `AddItem` / `SetJob` | 不可审计、不可回滚、可被 prompt injection 利用 | 只能调用受控 action，经济变更走 `EconomyService` 并有预算 |
| 每个 tick 都问 LLM | 延迟 1–5s、成本高、结果抖动 | 分层循环：慢循环 5–30min，快循环 2–5s 且只处理对话 |
| 导演拥有 admin 权限 | 与玩家权限模型冲突，事故无法追责 | 独立 `director` 主体，仅能访问 bridge 的动作白名单 |
| 导演写死剧本，玩家必须配合 | 破坏涌现与玩家能动性 | beat 有 TTL 与"放弃条件"，玩家不接就撤 |
| 把聊天记录/语音全量喂给模型 | 隐私与合规风险 | 默认只喂结构化事件；文本需 opt-in 与脱敏 |
| 先接 LLM 再补观测 | 模型看不到世界，只能瞎编 | **先有事件流与动作层，再接模型** |

---

## 2. 参考模型与可借鉴点

| 来源 | 核心机制 | 对 T-City 的启示 |
|:---|:---|:---|
| **Left 4 Dead AI Director**（Valve） | 用"强度/节奏曲线"动态安排敌人、补给、天气，而非固定脚本 | 导演首先是一个**节奏控制器**；先做规则版，再让 LLM 提议 |
| **Drama Manager**（Façade 及后续研究） | 在多个"戏剧节拍"中选择最符合张力目标的一个 | beat 选择应是**候选集 + 打分**，不是自由生成 |
| **Generative Agents**（Park et al., UIST 2023） | 记忆流 → 反思 → 计划 → 行动；25 个 agent 涌现出传播、社交 | NPC 演员需要**记忆与反思**，但只对"被接触的 NPC"激活以控成本 |
| **Project Sid**（Altera, 2024） | 10–1000+ agent 社会；PIANO 架构保证多输出流一致 | 多 agent 要有**统一的世界状态与并发仲裁**，否则会自相矛盾 |
| **AI Town**（a16z 开源） | 可部署的生成式 agent 小镇，Convex 后端 | 工程上可参考其"游戏循环 / agent 循环"分离 |
| **PedGPT**（FiveM/GTA V） | 用 GPT 驱动行人对话与行为 | FiveM 内已有先例，但**必须服务端权威**，不能客户端直连模型 |
| **AI 跑团 KP / 剧本杀 DM**（产品实践） | KP 负责场景描述、NPC 扮演、规则裁决，但不替玩家掷骰 | 导演 = KP，不是玩家；裁决权在规则引擎 |

**共同结论**：导演是"**受限的叙事调度器**"，不是"世界本身"。世界状态必须由游戏服务器权威维护，模型只产出意图。

---

## 3. T-City 落点架构

### 3.1 分层

```
┌──────────────────────────────────────────────────────────────┐
│  Agent Hub（进程外，Python/Node）                              │
│  ├─ Director Planner（慢循环：弧线/节奏/组织关系）              │
│  ├─ Scene Director（中循环：场景/事件/任务投放）                │
│  ├─ NPC Actors（快循环：对话/反应/记忆）                        │
│  ├─ Memory（Postgres/SQLite：事件、beat、结果、玩家画像）        │
│  ├─ Policy & Budget（动作白名单、配额、熔断）                   │
│  └─ Approval UI（Discord/Web：L3+ 动作人工审批）                │
└───────────────────────────┬──────────────────────────────────┘
                            │ HTTP(S)，Bearer Token，仅内网
┌───────────────────────────▼──────────────────────────────────┐
│  custom-director（FiveM server-only resource，新增）            │
│  ├─ Ingest：订阅 quest/story/world/economy/player 事件          │
│  ├─ Observation API：POST /v1/observe（批量事件）               │
│  ├─ Snapshot API：GET /v1/snapshot（世界/玩家/组织摘要）         │
│  ├─ Action API：POST /v1/act（schema 校验 + 幂等 + 预算）        │
│  ├─ Executor：world_state / quest / notify / atmosphere / ...   │
│  ├─ Audit：world_events + custom-logs + 因果链                  │
│  └─ Kill switch：/director off、convar、自动熔断                │
└───────────────────────────┬──────────────────────────────────┘
                            │ exports / TriggerEvent
┌───────────────────────────▼──────────────────────────────────┐
│  现有游戏系统                                                  │
│  core-framework（Bus/WorldState/Patron/Persistence）            │
│  custom-quest（任务）· story-engine（抉择）· custom-phone（推送）│
│  custom-logs（审计）· economy-dashboard（指标）                 │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 为什么桥要单独一个 resource

- **权限隔离**：bridge 是唯一拥有 `director` 权限的资源；模型永远拿不到服务器控制台。
- **可关停**：`stop custom-director` 即断开 AI，不影响游戏。
- **可替换**：Hub 可以是本地脚本、LangGraph、AutoGen、Dify，游戏侧契约不变。
- **可观测**：所有进出流量在一个资源内统一记账。

### 3.3 通信方式

| 方向 | 方式 | 说明 |
|:---|:---|:---|
| Hub → 游戏 | `SetHttpHandler`（FiveM 服务端原生） | 只监听 `127.0.0.1` 或内网；`Authorization: Bearer <token>`；token 存 convar，不入库不入仓库 |
| 游戏 → Hub | `PerformHttpRequest` 批量推送，或 Hub 轮询 `/v1/events` | 事件先入内存队列，按 1s/50 条批量发送；失败重试 + 落盘兜底 |
| 紧急停用 | convar `director_enabled false` + `/director off` | 立即拒绝所有 act，保留 observe |

> ⚠️ 不要把 `SetHttpHandler` 暴露到公网；不要用客户端 NUI 直连模型（客户端可被抓包/改包）。

---

## 4. 数据契约（先定 schema，再写模型）

### 4.1 DirectorEvent（游戏 → Hub）

```json
{
  "event_id": "evt_01J...",
  "ts": 1760000000,
  "type": "quest.step_completed",
  "severity": "minor|notable|major|legendary",
  "actors": [{"kind": "player", "id": "ABC123", "name": "..."}],
  "location": {"region": "davis", "x": 0, "y": 0, "z": 0},
  "payload": {"quest_id": "...", "step_id": "...", "decision_id": "..."},
  "visibility": "public|participants|director_only",
  "trace_id": "beat_..."
}
```

**第一批事件源（按性价比排序）**：

| 事件 | 来源 | 用途 |
|:---|:---|:---|
| `quest.started/step/completed/failed` | `quest:server:on*` | 节奏与漏斗 |
| `story.decision_made` | `story:server:onDecisionMade` | 分支与后果 |
| `world.state_changed` | `WorldStateService` | 世界痕迹 |
| `economy.anomaly` | `core_economy` | 经济健康 |
| `player.entered_region` / `player.died` | 新增轻量采集 | 场景触发 |
| `crime.started` / `police.response` | `custom-crime` / `qb-policejob` | 冲突强度 |
| `org.member_changed` | `custom-career` | 社会结构 |

### 4.2 Beat（Hub 内部，导演的"节拍"）

```json
{
  "beat_id": "beat_...",
  "intent": "raise_tension|offer_opportunity|reveal_information|create_shortage|reward_risk",
  "targets": ["player:ABC123", "org:cartel"],
  "constraints": {"max_cost": 0, "max_actions": 2, "ttl_sec": 300, "requires_approval": false},
  "success_signal": "player.accepted_quest|player.entered_region",
  "abort_signal": "player.left_region|timeout",
  "created_by": "planner|rules|human"
}
```

### 4.3 Action（Hub → 游戏）

```json
{
  "action_id": "act_...",
  "beat_id": "beat_...",
  "type": "notify|atmosphere|world_state|quest|scene|npc_dialogue",
  "args": {...},
  "idempotency_key": "beat_.../1",
  "expires_at": 1760000300,
  "budget": {"tokens": 800, "money_delta": 0}
}
```

### 4.4 ActionResult（游戏 → Hub）

```json
{
  "action_id": "act_...",
  "ok": true,
  "error": null,
  "state_delta": {"region": "davis", "key": "tension", "from": 0.2, "to": 0.6},
  "undo_token": "undo_...",
  "latency_ms": 12
}
```

---

## 5. 动作白名单（按风险分级）

| 级别 | 动作 | 影响 | 默认策略 |
|:---|:---|:---|:---|
| **L0 观察** | 读 world_state / 任务 / 指标 / 事件 | 无 | 允许 |
| **L1 表现** | `notify`、`phone_message`、`atmosphere.PlayScene`、世界标记、BGM | 无状态 | 允许（有频控） |
| **L2 世界** | `world_state.SetRegionState`、天气/时间、生成可交互场景物、临时 NPC | 可逆 | 允许，需 TTL + undo |
| **L3 任务** | `TriggerQuest`、投放抉择、调整任务目标、发放奖励 | 有状态 | 需预算 + 审计；高价值需人审 |
| **L4 经济/权限** | 加钱、改职业/帮派、封禁、白名单 | 不可逆 | **默认禁止**，仅人工审批 |

**统一前置校验**（bridge 内实现，不依赖模型自觉）：

1. 目标玩家在线 / 目标组织存在
2. 动作在 `director` ACE 白名单内
3. 幂等键未执行过
4. 冷却与每日预算未超
5. 参数类型/范围合法（金额上限、文本长度、坐标范围）
6. 若 `requires_approval`，进入待审队列，超时自动拒绝

---

## 6. 导演循环

### 6.1 慢循环（5–30 分钟）：叙事弧

输入：过去窗口的事件摘要 + 世界状态 + 在线玩家画像
输出：1–3 个 beat（候选），打分后选 1 个

打分维度：

- **张力缺口**：当前区域是否长时间无冲突/无事件
- **参与度**：目标玩家最近是否活跃、是否刚完成主线
- **公平性**：不能连续针对同一玩家/组织
- **成本**：动作数与 token 预算
- **可执行性**：目标是否在线、地点是否可达

### 6.2 中循环（30–120 秒）：场景与节奏

- 检查 beat 的 `success_signal` / `abort_signal`
- 若玩家偏离，标记 beat 失败并记录原因（这是训练导演的语料）
- 若玩家接近，追加一个 L1/L2 动作强化氛围

### 6.3 快循环（2–5 秒）：NPC 反应

- 只处理"玩家主动接触的 NPC"
- 有严格 token/时长上限；超时降级为模板台词
- 不允许在快循环里改世界状态

### 6.4 玩家能动性保护

- beat 的 `abort_signal` 必须包含"玩家明确拒绝/离开"
- 同一玩家 30 分钟内不被同一 intent 重复针对
- 导演不能强制传送、强制扣款、强制战斗
- 玩家可在设置中关闭"导演事件"（opt-out），仅保留世界级事件

---

## 7. NPC 演员层

### 7.1 适用边界

- **只对"玩家主动交互的 NPC"启用 LLM**（对话、交易、情报）
- 背景行人用规则/模板，避免成本爆炸
- NPC 的行为必须通过服务端动作执行（移动、动画、交易），客户端只负责表现

### 7.2 记忆结构（借鉴 Generative Agents）

```
memory_stream: [(ts, type, content, importance, participants)]
reflection:   周期性把重要记忆总结成高层判断
plan:         当天/当场景的目标列表
relationships: 对玩家/组织的信任与态度
```

存储：Hub 侧 Postgres/SQLite；游戏侧只存 `npc_id + 最近 N 条摘要`，避免玩家数据外泄。

### 7.3 与"导演"的分工

- 导演决定**发生什么**（beat）
- NPC 决定**怎么反应**（dialogue/act）
- 规则引擎决定**是否允许**（validation）
- 玩家决定**是否接受**（agency）

---

## 8. 安全、预算与治理

### 8.1 身份

- `director` 不是 admin，不继承 `qbcore.god`
- ACE：`add_ace resource.custom-director command.director allow`（仅自定义命令）
- bridge 内维护 `DIRECTOR_ACTIONS` 白名单；未知 action 一律拒绝

### 8.2 预算（建议初始值）

| 项 | 上限 |
|:---|:---|
| 全局 act 速率 | 10 次/分钟 |
| 单玩家被导演介入 | 6 次/小时 |
| L3 任务投放 | 2 次/小时/组织 |
| LLM token | 50k/小时（可调） |
| 经济影响 | L4 默认 0；L3 奖励走统一经济出口并设上限 |

### 8.3 人审

- L3+ 动作进入 `pending_actions` 表
- Discord/Web 审批，5 分钟超时拒绝
- 审批人看到：beat 理由、目标、预期影响、历史同类动作

### 8.4 回滚

- `world_state.previous_value`（已存在）→ 提供 `undo` API
- 任务：`FailQuest` + 补偿动作
- 经济：只允许"可追回"的操作（有交易流水）；不可逆操作禁用

### 8.5 审计与熔断

- 每次动作写 `world_events`（含 `beat_id/action_id/trace_id`）
- 错误率 > 5% 或玩家投诉 > 阈值 → 自动降级为"仅 L1"
- `/director status` 输出：队列、预算、最近 10 个动作

---

## 9. 评估指标

| 维度 | 指标 | 目标（首月） |
|:---|:---|:---|
| 留存 | D7 / D30 | 相对基线 +10% |
| 参与 | 人均事件参与/日 | > 1.5 |
| 导演质量 | beat 接受率 | > 40% |
| 导演质量 | 玩家"重复感"反馈 | < 20% |
| 稳定性 | act 失败率 | < 2% |
| 经济 | 异常波动次数/周 | 0 |
| 成本 | 每在线小时 LLM 成本 | 设硬上限 |

**A/B 方法**：按玩家/时段分流；导演关闭组只保留世界级事件。所有 beat 与结果落库，供离线回放（复用 `tools/sandbox_simulator.py`）。

---

## 10. 三阶段落地（与总路线图对齐）

| 阶段 | 导演相关交付 | 退出标准 |
|:---|:---|:---|
| **Phase 1 基础** | 事件采集（quest/story/world）落 `world_events`；`custom-director` 骨架 + `/health`；预算/审计表 | 事件可查、bridge 可启动、无写权限 |
| **Phase 2 角色扮演** | 规则版导演（无 LLM）：按张力/在线人数投放 L1/L2；NPC 模板对话；人审队列 | 连续 7 天无事故；beat 接受率可测 |
| **Phase 3 智能导演** | LLM Planner + NPC Actors；L3 任务投放；自动熔断；A/B | 72h 公测；失败率 < 2%；成本可控 |

> **关键顺序**：先有观测（Phase 1）→ 再有规则导演（Phase 2）→ 最后才接 LLM（Phase 3）。反过来做，必然得到"会瞎编的 GM"。

---

## 11. 最小可行 MVP（建议 2 周）

如果只想先看到效果，不要一上来做完整 Hub：

1. `custom-director` 只做三件事：
   - `GET /v1/snapshot`：在线玩家数、区域、活跃任务、最近事件
   - `POST /v1/act`：仅支持 `notify`、`atmosphere`、`set_world_state`
   - 事件推送到一个本地 webhook（先用文件/HTTP 模拟）
2. 一个 Python 脚本（非 LLM）：
   - 每 5 分钟检查"某区域 20 分钟无事件"
   - 发一条氛围通知 + 切 BGM + 写 world_state `tension`
3. 观察 3 天：玩家是否注意到、是否跟随、是否反感
4. 有效果后，再把"规则判断"替换为 LLM 选择 beat

这样风险最小，也能最快验证"导演是否真的提升体验"。

---

## 12. 参考与延伸阅读

- Generative Agents: Interactive Simulacra of Human Behavior — <https://arxiv.org/abs/2304.03442>
- Project Sid: Many-agent simulations toward AI civilization — <https://arxiv.org/abs/2411.00114>
- An Architecture for AI Game Masters in Tabletop RPGs (M. Eland) — <https://www.taylorfrancis.com/chapters/edit/10.1201/9781003632269-16/architecture-ai-game-masters-tabletop-rpgs-matt-eland>
- An Authoring Framework for LLM-Based Drama Managers — <https://dl.acm.org/doi/10.1145/3807895.3807937>
- Left 4 Dead Director 逆向研究 — <https://github.com/zeljkovranjes/l4d2-director-system-research>
- PedGPT（FiveM AI peds）— <https://github.com/MickMelon/PedGPT>
- FiveM Script Runtimes（资源隔离与序列化）— <https://docs.fivem.net/docs/developers/script-runtimes/>
- FiveM SetHttpHandler — <https://cfxnatives.dev/natives/SET_HTTP_HANDLER>

---

## 13. 待决问题（需要产品/运营拍板）

1. **导演的权限边界**：L3（投放任务/奖励）是否允许自动执行，还是必须人审？
2. **玩家知情权**：是否明确告知"本服有 AI 导演"？是否允许 opt-out？
3. **数据边界**：聊天/语音是否进入模型？若进入，保留多久、谁能看？
4. **成本上限**：每在线小时可接受的 LLM 成本是多少？这决定模型档位与 NPC 激活率。
5. **失败策略**：导演连续 3 次被玩家无视时，是换策略还是停用该玩家 24h？
6. **与 GM 团队的关系**：AI 导演是 GM 的副驾（建议），还是替代部分 GM？
