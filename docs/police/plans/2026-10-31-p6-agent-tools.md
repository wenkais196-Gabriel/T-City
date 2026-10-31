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

## 3. P6-1 设计细节（本轮施工）

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
