---
id: agent-police-atools-discipline
type: manual
status: active
system: agent
owner: hermes
updated: 2026-10-31
review_by: 2027-01-30
---

# 加 / 改一个 agent 动作：检查清单

> 一次做对的顺序。每一条都对应一个闸门，漏了不是"没测到"，而是**运行时静默失败**。

## 1. 先判断：读还是写

| 形态 | 通道 | 举例 | 关键约束 |
|---|---|---|---|
| 读 | live `GET /agent/v1/live/...` | `get_police_case` | 必须是 `GET`、`director_action=null`、`compensation=none`；不写 `agent_actions` |
| 写 | `POST /agent/v1/act` | `apply_police_report` | 必须有风险级别、审批、幂等键 |

> 把读动作做成写动作会被 `tools/agent_tools.py --write` 直接拒（读类工具的形状是强制的）。

## 2. 写动作要改的地方（缺一不可）

| # | 文件 | 改什么 | 漏了会怎样 |
|---|---|---|---|
| 1 | custom-director 的 policy 模块 → `AgentPolicy.ACTIONS` | 加动作定义（`risk` / `requires_approval` / `auto_execute` / `blast_radius`） | propose 直接 `unsupported_action` |
| 2 | 同文件 → `AgentPolicy.Normalize` | 参数白名单 + 类型/长度校验 | 参数被丢或 `unknown field` |
| 3 | 同文件 → `AgentPolicy.Preview` | 审批人看到的投影 | propose 阶段 400 |
| 4 | 同文件 → `AgentPolicy.CheckPolicy` | 运行时闸门 | approve 前被拒 |
| 5 | custom-director 的 main 模块 | 执行器 + 加到分发表 | 执行时 `unsupported_action` |
| 6 | `tools/agent_tools.json` | 工具定义（名字必须在动词白名单里） | `--write` 校验失败 |
| 7 | `python tools/agent_tools.py --write` | 重新生成 `TOOLS.md` 与 Lua 镜像 | `--check` 漂移 |
| 8 | `docs/agent/ACTIONS.md` | 动作矩阵 + 计数 | 文档闸门红 |
| 9 | 服务端资源 | 真正的写路径**必须走该表的唯一写者** | `test_police_single_writer` 红 |

## 3. 名字与参数

| 规则 | 说明 |
|---|---|
| 工具名前缀 | 必须是 `get/list/query/count/send/apply/set/start/grant/revoke/spawn/teleport/cancel/remove/kick/revive` 之一 |
| 参数别用 `description` | 校验器把它当"危险字段名"（含 `script`）→ 用 `details` |
| `citizenid` | schema 写 `^[A-Za-z0-9_-]{1,11}$`；**Lua 侧不要写 `{1,11}`**（Lua pattern 没有量词），用 `#s > 11` 判 |
| 回填字段 | 执行器用到的服务端回填（如 `code_fallback`）**必须**同时进 `rejectUnknownFields` 白名单，否则 approve 重放归一化时报 `unknown field` |
| 离线目标 | 文书类动作（报告/通缉）加进 `AgentPolicy.OFFLINE_TARGET_ACTIONS`，不要塞 `WORLD_ACTIONS`（那会把 blast_radius 变成 world） |

## 4. 服务端侧

| 约束 | 做法 |
|---|---|
| 单一写者 | 找到该表的 owner（`records.lua` / `p0_incidents.lua` / `p2_evidence.lua`），加函数或给它加参数；**不要复制 SQL** |
| 审计 | 写操作先审计；审计失败必须 `audit_unavailable`（fail-closed） |
| export 鉴权 | 玩家路径用 `pd(source)` + `PolicePolicy.Can`；系统路径登记到 `tests/architecture/export_allowlist.json`（写清 `owner` / `expires` / 理由） |
| 敏感读 | 读别人数据前先写审计，失败就不给看（FIT-05） |

## 5. 闸门与验收

```bash
python tools/agent_tools.py --check                      # 注册表三处一致
python3 -m pytest tests/tools -q                         # 动作/工具契约
python3 -m pytest tests/architecture -q                  # 写者/鉴权/文档/覆盖预算
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua        # golden
python3 tools/dev/release_check.py                       # 交付前
```

真机三步：`restart` 后 **SCRIPT ERROR 新增 0** → propose 得 `202 pending_approval` → approve 后 DB 回读字段与预期一致。
