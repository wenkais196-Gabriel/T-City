---
id: engineering-2026-11-01-next-epic-research
type: research
status: active
system: agent
owner: hermes
updated: 2026-11-01
review_by: 2027-01-30
---

# 2026-11-01 · 下一步开发方向调研（Hermes + Claude Code 双份意见）

> 状态：调研稿，**未实现、未排期**。判据一律是代码/数据，不是文档自述。
> 参与：Hermes（本文件） + Claude Code（`tools/dev/cc_run.sh`，DeepSeek 兼容端点，24 turns）。
> 证据基座：`docs/agent/police/STATUS-2026-10-31.md`、`docs/engineering/scenario-engine/DESIGN.md`、
> `PROJECT_PROGRESS.md`、`docs/server-design/*`、`T-CityLite.base/docs/agent/STATUS.md`。

---

## 0. 一页结论

**推荐下一步做「世界痕迹收口」**（把 `world_state` 从"有服务、有表、零写者"变成第一条真实消费链），
在此之前先花半天修掉一个已证实的证据链缺陷（§4.1）。

理由三条，按权重：

1. **它是唯一"基建已经付过钱、消费者为零"的项。** `WorldStateService.GetRegionState/SetRegionState`
   与 `world_state` 表都在（core-framework 的 services/world_state_service.lua），但全仓
   **0 个调用方**；同类还有 `governance_proposals` / `trust_graph` / `organization_rules`，全部 0 使用。
   这类债拖得越久越像死代码，而它恰好是 `docs/server-design/02-world-traces.md` 的核心命题。
2. **玩家端出口已经现成。** 手机 `CityFeed` 已有帖子/点赞/时间线（`phone_cityfeed`），
   把"城市这周发生了什么"接到它上面不需要新建 UI 平面。
3. **它把 agent 栈从"脚本遥控"变成"需要判断"。** 相比"解析报案文本"，痕迹生成需要读世界状态、
   权衡预算与 owner 权限、写入后自证 —— 这是 `custom-director` 那套 L1–L4 + 审计真正能体现价值的地方。

如果你的目标只是"4 天内看到变化"，改做保释/假释（候选 B）；如果目标是"上线"，直接进 v1.0 收口（候选 E）。

---

## 1. 候选对比

| # | 候选 epic | 现状证据（代码） | 玩家可见 | 结构收益 | 成本 | 主要风险 |
|---|---|---|---|---|---|---|
| **A** | **世界痕迹收口** | `world_state_service.lua` 有 Get/Set + 表；`SetRegionState` 全仓调用 **0**；`story-engine/server/decision_engine.lua:7` 只有一句"后续可扩展到 world_state"的注释；`governance_proposals`/`trust_graph`/`organization_rules` 同样 0 | 高（CityFeed / 物价 / 巡逻密度） | 高（世界状态第一次有写者与读者） | 5–8 人日 | 写者归属：`world_state` 的 owner 是 `core-framework`，跨资源写必须走 Bus 服务，不能各写各的 |
| **B** | 保释 / 假释 | `justice_sentences` + `prison.lua` + `ReleaseInmate` 齐；qb-core 已有 `prison_bail` **定价 sink**；业务代码 bail/parole = 0 | 中（只有被关的人感知） | 低 | 3–4 人日 | 变成"付费跳过 RP"；审批落点（法官/警长）要有真入口 |
| **C** | NPC 生命周期收口 | 三套实现各写一遍（cartel 常驻 / backup / callout）；`npc_budget` 只做槽位计数；`scenario-engine/DESIGN.md` 407 行、零代码 | 无 | 高 | 6–8 人日 | backup 的 10 分钟服务端 TTL 与 callout 的 60s/300m 客户端清理语义冲突 → 实体泄漏或提前删 |
| **D** | P6-4 接真 LLM 解析 | 通道 + 草稿箱 + MDT 界面都在；但玩家已有结构化 911 入口（custom-phone 的 server/emergency.lua → `CreateIncident`），那条路不经 agent | 低–中 | 中 | 3–4 人日 | ① FiveM 生态里 AI 调度已是**商品**（§3）；② Rockstar PLA 对生成式内容有 TOS 争议；③ 不确定性进不了 CI |
| **E** | v1.0 公测收口 | 多机验收欠账 9 项、132 个 DB 用例需建库 | 高 | 低 | 看第二客户端 | 不是开发任务，是验证任务；没第二客户端就卡住 |

---

## 2. Claude Code 的独立意见

CC 排序：**B > C > A?**（它没见过 A，我给它的清单里没有世界痕迹）→ 顺序为 **B（保释）> C（NPC 收口）> D（真 LLM）**，
且给了每条"什么证据会推翻它"。它最有价值的三句：

- 保释「唯一同时满足便宜、终局可感知、复用已有 `justice_sentences`/`Release`」；
- 真 LLM「不补入口，玩家可见收益≈0」；
- NPC 收口「如果两套生命周期其实没有交集，那收口是伪需求」。

**两处需要修正 CC 的判断**（我按代码核过）：

| CC 的说法 | 实际代码 | 影响 |
|---|---|---|
| `grep bail\|parole` = 0，暗示要新建 | 30 处命中，其中 `qb-core/config.lua:347` 与 `services/sink_service.lua:150` 已有 `prison_bail` **定价器** | 保释不必新造经济出口，接 sink 即可 —— 成本比 CC 估的更低 |
| 真 LLM「没有任何玩家界面入口」 | 玩家有手机 911 入口，但它**直接建单**、不走 agent（`emergency.lua:30`） | CC 的结论方向对，理由要换：不是"没入口"，而是"已有的入口比它更直接，接 LLM 要回答为什么要多一层" |

---

## 3. 外部调研（决定"差异化"该押在哪）

| 外部事实 | 出处 | 对我们的含义 |
|---|---|---|
| AI 调度 / AI NPC 对话在 FiveM 已是**付费商品**：DispatchAI（$15 单 AI Dispatcher / $25 带 MDT）、helix_npc（LLM 对话 + 预算 + 内容过滤）、srz_npc_witness（160+ 报案模板、5 种来电人格）、peak-ai-npc（服务端权威对话 + 工具白名单） | dispatchai.shop、docs.helixscripts.dev、forum.cfx.re | 「文本报案 → 结构化 call 卡」**不构成差异**；我们的差异在审计/审批/评测与"世界会变" |
| Rockstar PLA / Cfx TOS 对"用生成式 AI 在游戏内动态生成内容"存在争议，社区按"别问别说"处理 | forum.cfx.re 5414371 | 若要走公测，生成式内容应是**可关、可审计、不落玩家可见 PII** 的旁路，不能进核心循环 |
| 学术侧 LLM-as-Game-Master 的成熟做法是「多 agent 分工 + 受约束的执行层」（SENNA 的 Scribe/Examiner/Navigator/Narrator；RPGAgent 的"生成 → 校验 → 回喂错误"循环） | ACM IUI 2026 / CHI 2026 / CHI EA 2025 | 我们的 `custom-director`（propose → policy → approve → execute → 回读）已经是这套结构，缺的是**消费者**而不是新框架 |

---

## 4. 调研中查到的既有缺陷（独立于上面排期）

### 4.1 延迟化验的结果会永久丢失（已证实）

`custom-police/server/forensics.lua:103` 用 `SetTimeout(LAB_DELAY_MS)` 在内存里等 60 秒，回调里若警官
不在线就 `forensic.result_skipped` 直接 return；**资源一重启定时器就消失**，全仓没有 pending 表、
没有 `onResourceStart` 重扫。而采样时已经写了一条「已送检，约 60 秒出结果」的证据行 ——
于是样本会永远停在"已送检"。

与 `docs/agent/police/STATUS-2026-10-31.md` §2 第 2 项「延迟化验已闭环」直接矛盾：闭环只在
"警官不重启、不下线"时成立。修法不复杂（pending 行 + 启动重扫 + 幂等），但它落在证据链上，
**任何动案卷的 epic 之前都该先修**。

### 4.2 世界状态是"有服务、零消费者"（结构性不一致）

见 §1 候选 A 的证据列。`story-engine` 的决策效果只写 `player_choices`，注释留了 TODO 从未接；
`contracts.lua` 自称 "Phase 1 已实现: world_state" —— 实现的是服务，不是世界。

---

## 5. 建议的开工顺序

| 顺序 | 做什么 | 为什么在这个位置 | 验收 |
|---|---|---|---|
| 0 | 修 §4.1 延迟化验丢失 | 已证实缺陷，且在任何案卷改动之前修最便宜 | 重启资源后未出结果的样本自动补出结果（离线单测 + 一次真机重启） |
| 1 | 世界痕迹第一条链：警情结案 → 区域状态 → CityFeed 一条"城市动态" | 选一条最短链路证明整条通路，不铺开五个类目 | 结案后 region 状态变更 + CityFeed 可见 + 审计一行；写入失败不影响结案 |
| 2 | 第二条链：cartel 地盘 / 任务结果二选一 | 证明第二个写者也能守住 owner 约束 | 同上 |
| 3 | 再评估：保释（B）还是 NPC 收口（C） | 有了世界状态，"假释违反条件 → 区域状态"才成立 | — |
