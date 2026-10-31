# P6 Agent 动作 · 研究与施工图（2026-10-31）

> 第一次尝试把 `police_query_case` 做成 **director action**，被注册表校验器当场否掉。
> 这份文档记录否决原因、正确的通道划分，以及三块施工的顺序。

## 1. 否决原因（这次踩到的硬约束）

`tools/agent_tools.py --write` 的校验规则：

| 规则 | 报错 |
|---|---|
| 读类工具必须 `GET` | `http.method: read tools must use GET` |
| 读类工具不能绑 director 动作 | `director_action: read tools must set director_action=null` |
| 读类工具没有补偿语义 | `compensation: read tools must use compensation=none` |

也就是说 **agent 的"眼睛"和"手"走两条不同的通道**：

| 通道 | 形态 | 例子 | token |
|---|---|---|---|
| **live**（眼睛） | `GET /agent/v1/live/...`，只读，不落 `agent_actions` | `get_police_board`、`get_live_players` | live token（只读） |
| **action**（手） | `POST /agent/v1/act`，L1–L4，写 `agent_actions` + 审批 | `apply_police_incident`、`apply_police_jail` | agent token（不能审批）+ admin token（审批） |

## 2. 三块施工顺序

| 步 | 工具 | 通道 | 风险 | 审批 | 数据 |
|---|---|---|---|---|---|
| **P6-1** | `get_police_case` | live `GET /agent/v1/live/police/cases/{case_id}` | L0 | 否 | 案卷摘要：`case_no`/`status`/`court_status`/`sentence_minutes`/`charges`/`suspect_citizenid`/`lead_citizenid`；**不含姓名、坐标、描述正文** |
| **P6-2** | `draft_police_report` | action | L2 | **是** | 写 `police_reports` 草稿（`status='draft'`），不自动提交、不罚款、不生成证据 |
| **P6-3** | `issue_police_warrant` | action | L3 | **是** | 写 `police_warrants`（`status='requested'`），仍需法院/上级批准才生效 |

`P6-4`（AI 调度员：文本报案 → call 卡草稿）依赖 P6-1/2，放在最后。

## 2.1 实施记录

| 步 | 状态 | 说明 |
|---|---|---|
| P6-1 | ✅ 已合并（PR #156，`6e9b474`） | `get_police_case` 走 live GET |
| P6-2 | ✅ 本轮 | 动作 `police_draft_report` + 工具 `apply_police_report`；**注意**：工具名必须在动词白名单（`apply_`），且 `police_reports` 只有一个写者，所以委托 `PoliceRecords.InsertReport` |
| P6-3 | ✅ 本轮 | 动作 `police_warrant_request` + 工具 `apply_police_warrant`；**表已存在**（`police_warrants`），写者 `p3_cases.lua`，系统入口就放在同一文件、共用同一条 INSERT，只到 `requested` |

### 2.2 P6-2 的两条硬约束（实测踩到）

1. **工具名白名单**：`draft_police_report` 被注册表校验器拒绝，只接受
   `get|list|query|count|send|apply|set|start|grant|revoke|spawn|teleport|cancel|remove|kick|revive` 前缀。
2. **单一写者**：`police_reports` 已有唯一写者 `PoliceRecords.InsertReport`
   （`custom-police/server/records.lua`），任何新入口都必须调用它，不得复制 `INSERT`。

## 3. P6-1 设计细节

### 3.1 路由

```
GET /agent/v1/live/police/cases/{case_id}
Authorization: Bearer <live token>
```

* 复用 `live_api.lua` 现有的 `rateGate` 与 `failure()`；
* 只接受 `GET`，其它方法 `405`；
* `case_id` 必须是正整数，否则 `400 invalid_case`；
* 案卷不存在 → `404 case_not_found`。

### 3.2 返回体

```json
{
  "schema_version": 1,
  "case": {
    "case_no": "CASE-2026-000003",
    "title": "…",
    "status": "open",
    "court_status": "guilty",
    "sentence_minutes": 180,
    "lead_citizenid": "DXI50064",
    "suspect_citizenid": "DEV00001",
    "opened_at": "2026-10-30 12:00:00",
    "closed_at": null,
    "charges": [{ "charge": "robbery", "fine": 500, "minutes": 60 }]
  },
  "generated_at": 1793450000
}
```

**不含**：姓名、坐标、案卷正文、证据内容 —— 那些走 MDT（人看）或 P4 的证据视图。

### 3.3 注册表条目

`tools/agent_tools.json` 追加读类工具，字段照 `get_police_board`：

| 字段 | 值 |
|---|---|
| `channel` | `read` |
| `route` | `director` |
| `director_action` | `null` |
| `risk` | `L0` |
| `auth` | `live` |
| `rate_limit` | `per_minute: 60`, `burst: 10` |
| `http` | `GET /agent/v1/live/police/cases/{case_id}` |
| `pii.returns_pii` | `true`（返回 citizenid，但不是姓名/坐标） |

改完必须 `python tools/agent_tools.py --write` 重新生成 `TOOLS.md`，CI 用 `--check` 挡漂移。

### 3.4 验收判据

| 编号 | 判据 |
|---|---|
| AC-P6-01 | 用 live token 读一张存在的案卷 → 200，字段与 DB 一致 |
| AC-P6-02 | agent token 调 live 路由 → 401（token 隔离） |
| AC-P6-03 | 不存在的 id → 404 `case_not_found`；非数字 → 400 `invalid_case` |
| AC-P6-04 | 返回体里**没有**姓名、坐标、描述正文 |
| AC-P6-05 | `tools/agent_tools.py --check` 通过（TOOLS.md 与 registry 无漂移） |

## 4. 实机端到端（2026-10-31，本机 FXServer @30130）

令牌用本地 server.cfg 里的 `agent_actions_token` / `agent_actions_admin_token`（脚本不打印）。
目标玩家取在线角色 `DXI50064`（策略要求目标在线）。

| 步 | 结果 |
|---|---|
| P6-2 propose | `202 pending_approval`，`id=19` |
| P6-2 幂等 | 同 key 再提 → `idempotent=true`、同一个 `id=19` |
| P6-2 approve | `200 executed`，`result={"report_id":1,"status":"draft"}` |
| P6-2 DB | `police_reports#1`：`status=draft`、`kind=report`、`author=action:19`、`subject=DXI50064` |
| P6-3 propose | `202 pending_approval`，`id=20` |
| P6-3 approve | `200 executed`，`result={"warrant_id":1,"status":"requested"}` |
| P6-3 DB | `police_warrants#1`：`status=requested`、`requested_by=action:20`、`approved_by=NULL` |
| 审计 | `warrant.request`（target DXI50064）与 `report.draft`（target 1）`actor_kind=agent` |
| 动作表 | `agent_actions#19/#20` 均 `executed`、`approved_by=dev:live` |

### 4.1 联调中暴露的三件事（都已修）

| 现象 | 根因 | 修法 |
|---|---|---|
| `citizenid is invalid`，合法 ID 也被拒 | Lua pattern **没有 `{n,m}`**，`^[A-Za-z0-9_%-]{1,11}$` 永不匹配 | 长度用 `#s > 11` 判，字符集用 `+` |
| propose 阶段 `unsupported_action` | policy.lua 有**四处**要接：ACTIONS / Normalize / Preview / CheckPolicy，我只接了两处 | 四处补齐；新增 `test_p6_policy_touch_points.py` 守住 |
| `player_not_found`（目标离线） | 运行期闸门要求目标在线（`WORLD_ACTIONS` 之外的都要求） | ✅ 已修：单独一张 `OFFLINE_TARGET_ACTIONS`（warrant/report），不要求在线但要求 `players` 表里存在，且存在性在 **propose** 阶段就判 |

### 4.2 离线目标实机证据

| 用例 | 结果 |
|---|---|
| 离线公民 `DEV00001` 申请逮捕令 | `202 pending_approval` → `approve` `200 executed`，`warrant_id=2/3`，`status=requested` |
| 不存在的 `NOPE0001` | `400 citizen_not_found`（**propose 阶段**就拒，不进审批队列） |
