---
id: police-plans-2026-10-31-p6-4-ai-dispatcher
type: plan
status: active
system: justice
owner: hermes
updated: 2026-10-31
review_by: 2027-04-30
---

# P6-4 AI 调度员：文本报案 → call 卡草稿（研究与施工图）

> 目标：一段人话（玩家 911 描述、短信、Discord 转述）进来，agent 把它**解析成结构化 call 卡**，
> 但**不直接上板**。人看一眼、点确认，才真正变成一条会响铃的警情。

## 1. 现状（为什么要做这一层）

| 已有 | 位置 | 语义 |
|---|---|---|
| `police_incident_create` | `custom-police` 的 p0_incidents / p2_system | **L1 免审**，建单即广播给在勤警员 |
| `apply_police_incident` | `custom-director` 动作 | agent 唯一的建单手段 |
| NPC callout | p4_npc | 系统建单 + 派 NPC，走 `CreateIncidentSystem` |

问题：agent 一旦建单**立刻响铃**。而 LLM 把「我车被偷了」解析成 `code=10-31 priority=1` 这种判断，
不该无人工确认就惊动全城。所以缺的是**草稿态**：结构化结果先落库、可见但不会响。

## 2. 设计取舍

| 方案 | 评价 |
|---|---|
| A. 完全不落库，草稿只存在于审批面板 | 最简单，但审批面板要重做（现在只显示 preview JSON），且草稿无法被多个警员看到 |
| B. **`police_incidents` 加 `status='draft'`**（本方案） | 复用现有表/投影/看板；`draft` 天然被所有 `status IN (...)` 的查询排除；确认 = `draft → open` 一条 UPDATE + 广播 |
| C. 新建 `police_call_drafts` 表 | 多一张表、多一个写者、多一套投影，收益与 B 相同 |

选 **B**。代价：动 `police_incidents.status` 的 enum（**L4，需人审**，见 §3），以及 shared 状态机加一个点。

## 3. 变更清单

### 3.1 迁移（幂等）

`T-CityLite.base/migrations/v3.13_police_incident_draft.sql`

```sql
-- 给 status 加 draft：草稿态，不上板、不响铃、不计入警力统计
ALTER TABLE police_incidents
  MODIFY COLUMN status ENUM('draft','open','assigned','enroute','on_scene','cleared','closed')
  NOT NULL DEFAULT 'open';
```

用 `information_schema.COLUMNS` 判 `COLUMN_TYPE` 是否已含 `draft`，再 `PREPARE/EXECUTE`，保证重复执行不报错
（与 v3.12 同款写法）。`tests/fixtures/tcity_schema.sql` 同步 enum。

### 3.2 共享状态机

`custom-police/shared/incident_status.lua`：

- `INCIDENT_STATUS.draft = true`
- `INCIDENT_TRANSITIONS.draft = { open = true, closed = true }`（**只有**「发布」和「丢弃」两条出路，草稿不能直接被指派）

### 3.3 服务端写路径

`custom-police/server/p0_incidents.lua`：

```lua
function P.DraftCallSystem(actorCid, data)   -- 与 CreateIncidentSystem 共用 insertIncidentRow
    -- status='draft'、不广播、不派 NPC；审计 incident.draft（fail-closed）
end
exports('DraftCallSystem', P.DraftCallSystem)
```

`:draft` 不进入 `broadcastIncidentAlert`。看板查询（`GetIncidentsPublic` / `PoliceDispatchView`）已经按状态过滤，
需确认 `draft` 不在白名单里，并**新增**一个只给警员的「草稿箱」查询。

### 3.4 Agent 动作

| 项 | 值 |
|---|---|
| 动作 | `police_call_draft` |
| 风险 | **L2**（需人审） |
| 工具名 | `apply_police_call_draft` |
| 入参 | `title`(3–120)、`description`(0–1000)、`code`(≤16，白名单见 §3.5)、`priority`(1–4)、`raw_text`(≤1000，可选)、`x/y/z`(可选) |
| 执行 | `exports['custom-police']:DraftCallSystem('action:<id>', params)` |
| 副作用 | 一行 `status='draft'`；**无广播、无 NPC、无 BOLO、无钱** |

### 3.5 解析契约（agent 侧）

`code` 只接受现有调度码（`911`/`10-31`/`10-32`/`10-50`/…，以 `p0_read`/`p4_npc` 已用的集合为准），
不认识的码一律降到 `911` 并写进 `description` 前缀 `[auto-code-dropped]`，**不允许 invent 新码**。
`priority` 只按四个档位映射，LLM 给出的 0/5 一律夹取。

### 3.6 发布（人做）

警员在 MDT/看板点「采纳」→ 复用现有 `PoliceIncidents.SetStatus` 把 `draft → open`，
再由既有广播路径派发。**agent 没有发布权限**（没有对应 export / 动作）。

## 4. 验收判据

| 编号 | 判据 |
|---|---|
| AC-P6-4-01 | 动作 `police_call_draft` 存在，L2，`requires_approval=true` |
| AC-P6-4-02 | 审批通过后 `police_incidents` 出现一行 `status='draft'`，字段与入参一致 |
| AC-P6-4-03 | 该行**没有**触发广播（审计无 alert、在勤警员收不到 notify） |
| AC-P6-4-04 | `GET /agent/v1/live/police/board` 与车机警情列表**不包含** draft 行 |
| AC-P6-4-05 | 未知 `code` 被降级为 `911` 且留下标记；`priority` 越界被夹取 |
| AC-P6-4-06 | 警员 `SetStatus(draft → open)` 成功，反向 `open → draft` 被拒 |
| AC-P6-4-07 | 幂等键重复不产生第二行 |

## 5. 施工顺序

1. 迁移 v3.13 + fixture 同步（**需先获批**，动 enum）
2. shared 状态机加 `draft` + 单向流转
3. `DraftCallSystem` + 审计（走唯一写者 `insertIncidentRow`）
4. policy 四处接点（ACTIONS / Normalize / Preview / CheckPolicy）+ 执行器 + 工具 `apply_police_call_draft`
5. 看板/车机过滤 `draft`（确认现有查询已排除，缺就补）
6. 闸门：AC-01..07 各一条
7. 真机：propose → approve → DB 回读 → 看板不含 → 警员发布 → 看板包含

## 6. 实机证据（2026-10-31，本机 FXServer @30130）

迁移 v3.13 已应用到 Docker `tcity-mariadb`，`status` 列变成
`enum('draft','open','assigned','enroute','on_scene','cleared','closed')`，重复执行 rc=0（幂等）。

| 用例 | 结果 |
|---|---|
| 未知 code `99-ZZZ` + priority 9 | preview 里 `code=911`、`priority=3`（降级 + 夹取） |
| 审批 | `200 executed` → `{"incident_id":65,"status":"draft","code":"911"}` |
| 已知 code `10-32` + priority 7 | `code=10-32` 保留、`priority=3`、`incident_id=66` |
| 在勤看板 | `GET /agent/v1/live/police/board` → `calls: 0`（草稿**不上板**） |
| DB | `police_incidents` 里两条 `status='draft'`，`created_by=action:24/25` |
| 审计 | `incident.draft`，`actor_kind='agent'`（第一版漏传 actorKind、记成了 player，已修） |

### 6.1 施工中修正的两处

| 现象 | 根因 | 修法 |
|---|---|---|
| preview 说 priority=4、库里存 3 | 存储层 `insertIncidentRow` 本来就把 priority 夹到 **1..3** | 规范化跟着夹到 1..3，preview 与库一致 |
| 未知 code 也能进 | 没有码位白名单，LLM 可以发明 `99-ZZZ` | 新增 `AgentPolicy.KNOWN_CODES`，不认识就降 `911` |

### 6.2 尚未验证（需要真人操作）

| 项 | 原因 |
|---|---|
| AC-P6-4-06 警员「采纳」`draft → open` | 需要警员在 MDT 里点采纳；状态机层面已由闸门覆盖（`draft` 只有 `open`/`closed` 两条出路） |
| 草稿在 MDT 里的可见性/样式 | 需要前端补「草稿箱」视图（当前看板刻意不列 draft） |

## 7. 草稿箱（服务端）

| 入口 | 行为 |
|---|---|
| `police:server:draftList` → `ListDrafts` | 在勤警察才可读；**先写 `incident.draft.view` 审计再查询**，审计失败返回 `audit_unavailable`；只列 `status='draft'`，`LIMIT 20` |
| `police:server:adoptDraft` → `AdoptDraft` | 复用 `SetIncidentStatus(source, id, 'open')`（状态机只允许 draft→open/closed），成功后写 `incident.adopt`；3 秒冷却 |
| 客户端事件 | `police:client:draftList` / `police:client:draftResult`（UI 接这两个） |

真机：`restart custom-police` 后 SCRIPT ERROR 新增 0；闸门覆盖「只列草稿 / 审计 fail-closed / 采纳走状态机 / 事件限流 + 拒绝控制台」。

**未做**：MDT/车机里的草稿箱界面（下一步，需要先定视觉）。

## 8. 界面施工记录（手机 / 平板 MDT）

| 项 | 决策 |
|---|---|
| 版式 | **C 分信度车道**（可采纳 / 需核对），落在 MDT **调度 → 接警**页顶部，车机不做 |
| 分档依据 | **不建列**：`needs_review` 写进草稿行的 `disposition`；判据 = 码位被降级成 911，或 `details` 短于 20 字 |
| 丢弃 | 前端二次确认（点一次变「确认丢弃？」），服务端要求 **grade ≥ 2**，写 `incident.discard` |
| 过期 | 30 分钟无人处理 → `closed` + `disposition='stale'`，在 `ListDrafts` 的读路径上惰性清理 |
| 空态 | 「暂无待采纳草稿」 |
| 采纳后 | 行消失 + notice「草稿 #68 已上板」，随即出现在接警列表 |

### 8.1 真机证据（2026-10-31）

| 用例 | 结果 |
|---|---|
| 高置信草稿（`10-31` + 详细描述） | `#68` `status=draft`、`disposition=NULL` |
| 低置信草稿（`details='听不清'`） | `#69` `status=draft`、`disposition=needs_review` |
| 重启 3 个资源 | SCRIPT ERROR 新增 **0** |
| MDT 打开 | `[custom-phone][diag] app=police_mdt code=ok` |

### 8.2 施工中修掉的问题

`police_call_draft` 审批阶段报 `unknown field code_fallback for police_call_draft`：
`code_fallback` 是服务端回填给执行器的标记，approve 时会拿存的 params **再规范化一次**，
白名单里没有它 → 草稿永远停在 `rejected`。已纳入白名单（并保留回放时的原判）。
