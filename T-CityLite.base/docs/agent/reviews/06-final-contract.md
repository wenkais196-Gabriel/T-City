# 06 — 四方契约最终一致性评审（`4400d8b`）

- **评审对象**：`feat/agent-takeover-v2` @ `4400d8b`（PR #42，已 ready）
- **基线**：`master`；范围 `git diff master...HEAD` 的 66 个文件（`--stat` 输出 67 行，最后一行是汇总；`--numstat` 为 66）
- **评审日期**：2026-10-22
- **结论**：**需修（needs fix）** — 0×P0、3×P1、15×P2。**风险/审批口径 17/17 完全一致**；不一致集中在“工具面参数 schema ↔ director `Normalize`”和“设计 04 / ACTIONS 文档 ↔ 实现”。
- **约束**：未修改任何被跟踪文件；只新增本文件。`git status --short` 为空。

---

## 1. 基线与实测

所有命令在仓库根 `/home/.../T-City-agent` 执行（工作树干净，`HEAD=4400d8b`）：

```bash
python3 tools/agent_tools.py --check
# agent_tools: OK (30 tools, 2 generated files match)

lua5.4 T-CityLite.base/tests/agent/lua/runner.lua
# http_contract 19 / http_adapter 10 / live_rules 12 / live_api 21 /
# effect_rules 41 / effect_server 17 / director_actions 83 / director_denials 6
# = 8 suites / 209 checks, failed=0

python3 -m pytest -q tests/agent
# 196 passed, 3 skipped, 432 subtests passed

cd T-CityLite.base && python3 -m pytest -q tests/unit
# 262 passed, 136 skipped, 45 subtests passed

for f in $(git diff master...HEAD --name-only | grep '\.lua$'); do luac5.4 -p "$f"; done
# 无输出（全部通过）
```

四方元数据对照用两个只读探针，不落库、不联网：

```bash
lua5.4 /tmp/dump_actions.lua
# 导出 AgentPolicy.ACTIONS（17 项）为 JSON
lua5.4 /tmp/compare_lua_tools.lua
# 6 个抽样工具：get_live_players / grant_player_item / set_player_metadata /
# teleport_player / send_notify / set_time_of_day → ALL 6 SAMPLES MATCH
```

参数契约用同一组输入分别喂给 registry（Python `validate_arguments`，MCP 在
`agent_mcp.py:1048` 实际调用它）和 `policy.Normalize`（`lua5.4` 下直接加载
`resources/[custom]/custom-director/server/policy.lua`），结果见 §3.3。

---

## 2. 结论

- **没有 P0**：17 个动作 ↔ 17 个工具是严格一一对应，没有悬空动作、没有重复映射；
  风险/审批 17/17 一致；生成物 `--check` 干净；L3/L4 全部人审，没有发现可绕过审批
  的路径。上一轮 review 03 的 P1 中，`add_` 动词（F-01）、effect/L2 审批（F-02）、
  untrusted 包装（F-03）在本分支已修复；F-04 的 pattern 渲染已补，但 `integer`
  判定仍不一致（见 C-18）。
- **3 个 P1** 都是“agent 实际看到/调用的契约”与“director 实际执行的契约”不闭环：
  1. **C-01** `teleport` 坐标：registry/MCP 允许 ±10000，policy 与效果通道只允许
     `x/y ∈ -4500..8500`、`z ∈ -200..3000`。前端放行、后端必拒。
  2. **C-02** `teleport.heading`：ACTIONS.md 与 policy/effect 都支持，但 registry、
     生成 Lua、MCP schema 都没有这个参数，agent 按文档传会被 `unknown argument(s)` 拒绝。
  3. **C-03** `docs/agent/design/04-write-actions.md` 仍以“15 个动作 / 双人审批 / bucket
     1000–1999 / 23 工具”为施工口径，和最终 17 动作/30 工具/单审/0–65535 不一致；
     STATUS 的“与设计 04 的差异”表只登记了 3 条动作名差异。
- **15 个 P2** 分三类：工具面与 `Normalize`/生成器的细粒度参数漂移（C-04～C-08、
  C-18）、`/agent/v1/policy` 与 registry 的元数据漂移（C-09）、文档/错误码/测试缺口
  与相邻层口径（C-10～C-17）。它们不会立刻造成越权，但会让“按文档写 prompt 的
  agent”反复收到 400，或让审批人看到与 registry 不一致的风险画像。
- **根因**：没有任何自动化测试把 `agent_tools.json`、`policy.ACTIONS`/`Normalize`
  和文档放在一起比对（C-16）。`--check` 只保证 JSON→Lua/TOOLS.md 的字节一致，
  不保证 Lua→policy 的语义一致。

---

## 3. 四方对照表

### 3.1 工具 ↔ 动作（17 动作 × 4 方）

registry 共 30 个工具、全部 `active`；其中 13 个只读工具 `director_action = null`，
17 个写/效果工具映射到 17 个动作，**无重复、无多对一、无一对多**。
`notify` / `add_money` / `start_quest` / `announce` 均**有**对应工具
（`send_notify` / `add_player_money` / `start_player_quest` / `send_announce`），
不存在“有动作无工具”。

| # | 动作 | 工具 | registry risk/appr | policy risk/appr | ACTIONS.md §5.12 | TOOLS.md | 判定 |
|---:|:---|:---|:---|:---|:---|:---|:---|
| 1 | `notify` | `send_notify` | L1 / false | L1 / false | L1 / no | L1 / no | ✅ |
| 2 | `add_money` | `add_player_money` | L4 / true | L4 / true | L4 / always | L4 / yes | ✅ |
| 3 | `start_quest` | `start_player_quest` | L3 / true | L3 / true | L3 / always | L3 / yes | ✅ |
| 4 | `set_job` | `set_player_job` | L3 / true | L3 / true | L3 / always | L3 / yes | ✅ |
| 5 | `set_job_duty` | `set_job_duty` | L2 / true | L2 / true | L2 / always | L2 / yes | ✅ |
| 6 | `set_metadata` | `set_player_metadata` | L3 / true | L3 / true | L3 / always | L3 / yes | ✅ |
| 7 | `teleport` | `teleport_player` | L3 / true | L3 / true | L3 / always | L3 / yes | ✅ |
| 8 | `spawn_vehicle` | `spawn_vehicle` | L3 / true | L3 / true | L3 / always | L3 / yes | ✅ |
| 9 | `grant_item` | `grant_player_item` | L4 / true | L4 / true | L4 / always | L4 / yes | ✅ |
| 10 | `remove_item` | `remove_player_item` | L4 / true | L4 / true | L4 / always | L4 / yes | ✅ |
| 11 | `set_bucket` | `set_player_bucket` | L3 / true | L3 / true | L3 / always | L3 / yes | ✅ |
| 12 | `kick` | `kick_player` | L4 / true | L4 / true | L4 / always | L4 / yes | ✅ |
| 13 | `announce` | `send_announce` | L2 / true | L2 / true | L2 / always | L2 / yes | ✅ |
| 14 | `set_weather` | `set_weather` | L2 / true | L2 / true | L2 / always | L2 / yes | ✅ |
| 15 | `set_time_of_day` | `set_time_of_day` | L2 / true | L2 / true | L2 / always | L2 / yes | ✅ |
| 16 | `revive` | `revive_player` | L3 / true | L3 / true | L3 / always | L3 / yes | ✅ |
| 17 | `delete_vehicle` | `remove_player_vehicle` | L4 / true | L4 / true | L4 / always | L4 / yes | ✅ |

**风险/审批：17/17 一致，0 处不一致。** `auto_execute` 也一致：policy 只有
`notify.auto_execute = true`（`policy.lua:29-33`），ACTIONS.md §5.12 的 Auto-execute
列同为唯一 `yes`。

工具名与动作名有 9 处刻意不同（`send_notify`/`add_player_money`/`start_player_quest`/
`set_player_job`/`set_player_bucket`/`set_player_metadata`/`grant_player_item`/
`remove_player_item`/`remove_player_vehicle`），语义一一对应，**不是缺陷**；但
`remove_player_vehicle` 实际执行 `delete_vehicle` 且删除不可逆，名字里的 “remove”
容易与 `remove_player_item` 混淆，建议在 TOOLS.md 描述里保留差异说明。

### 3.2 `blast_radius` / `compensation` 的四方漂移

risk/approval 一致，但另外两个暴露给 `/agent/v1/policy` 的字段不一致：

| 动作 | registry blast | policy blast | registry compensation | policy compensation |
|:---|:---|:---|:---|:---|
| `notify` | single | nil | none | nil |
| `add_money` | single | nil | manual | nil |
| `start_quest` | single | nil | manual | nil |
| `set_job` | single | nil | inverse | nil |
| `grant_item` | single | nil | manual | nil |
| `set_weather` | world | world | inverse | nil |
| `set_time_of_day` | world | world | inverse | nil |
| `teleport` | single | single | inverse | nil |
| `spawn_vehicle` | single | single | manual | nil |
| `revive` | single | single | none | nil |
| `set_job_duty` | single | single | none | nil |
| `set_metadata` | single | single | none | nil |
| `announce` | world | world | none | nil |
| `remove_item` | single | single | manual | manual ✅ |
| `kick` | single | single | manual | manual ✅ |
| `set_bucket` | single | single | none | none ✅ |
| `delete_vehicle` | single | single | manual | manual ✅ |

实测 `AgentActions.Policy()`（`main.lua:1666-1700`）输出：
`blast=nil` 的动作是 `notify/add_money/start_quest/set_job/grant_item`；
`comp=nil` 的动作除上表 4 个 ✅ 外全部为 nil。registry 则对每个工具都写了
`blast_radius` 和 `compensation`（`tools/agent_tools.json` 全量字段）。
→ 见 **C-09**。

### 3.3 参数契约抽查：registry 允许但 policy 拒绝 / 反之

registry 侧用 MCP 真正执行的 `agent_tools.validate_arguments()`，policy 侧用
`AgentPolicy.Normalize(action, params, {})`（默认 cfg）：

| # | 动作 | 输入 | registry | policy | 性质 |
|---:|:---|:---|:---|:---|:---|
| 1 | `teleport` | `x=-5000` | OK | **FAIL** `x is outside the GTA map bounds` | registry 松 |
| 2 | `teleport` | `x=9000` | OK | **FAIL** 同上 | registry 松 |
| 3 | `teleport` | `z=-500` / `z=4000` | OK | **FAIL** `z is outside...` | registry 松 |
| 4 | `teleport` | `+ heading=90` | **FAIL** `unknown argument(s): heading` | OK → `{..., heading=90}` | registry 紧 |
| 5 | `kick` | `reason=128×'a'` | OK | OK | ✅ 一致 |
| 6 | `kick` | `reason=129×'a'` | FAIL | FAIL | ✅ 一致 |
| 7 | `kick` | `reason=60×'中'`（60 字符 / 180 字节） | OK | **FAIL** `reason exceeds 128 characters` | registry 松（按码点） |
| 8 | `kick` | `reason="   "`（3 空格） | OK | **FAIL** `reason is required`（Trim 后为空） | registry 松 |
| 9 | `set_time_of_day` | `{hour:12}`（省略 minute） | **FAIL** `minute is required` | OK（默认 0） | registry 紧 |
| 10 | `remove_item` | 省略 `amount` | **FAIL** `amount is required` | OK（默认 cap=50） | registry 紧 |
| 11 | `set_weather` | `weather="rain"` | **FAIL** 枚举只收大写 | OK（转大写） | registry 紧 |
| 12 | `spawn_vehicle` | `plate="abc123"` | **FAIL** pattern `^[A-Z0-9]{1,8}$` | OK（trim + upper） | registry 紧 |
| 13 | `grant_item` | `amount=100`（convar 调到 100） | **FAIL** `<= 50` | OK | registry 紧（静态上限） |
| 14 | `add_money` | `amount=2000`（convar 调到 2000） | **FAIL** `<= 1000` | OK | registry 紧（静态上限） |
| 15 | `send_notify` | 额外键 `foo="bar"` | **FAIL** unknown argument | OK（丢弃） | registry 紧 |
| 16 | `grant_item` | `amount=5.0` | **FAIL** `must be integer` | OK（整值浮点） | registry 紧 |
| 17 | `set_metadata` | `key="isdead"` | FAIL | FAIL | ✅ 一致 |
| 18 | `set_metadata` | `key="armor", value=100` | OK | OK | ✅ 一致 |

`teleport` 的双向漂移（1-4）是 C-01/C-02；5/6/17/18 是“已经对齐”的样例；其余
归入 C-04～C-08。

### 3.4 文档数字核对（STATUS.md）

| 声明（`STATUS.md` 行） | 实测 | 判定 |
|:---|:---|:---|
| 30 工具 / 30 active（第 14 行） | `--check` 30 tools；JSON `status` 全 active | ✅ |
| 17 个动作（第 12/21 行） | `AgentPolicy.ACTIONS` 17 项，工具 17 个 | ✅ |
| 8 suites / 209 checks（第 42 行） | runner 8 suites / 209 checks / failed=0 | ✅ |
| 196 passed（第 43 行） | 196 passed, **3 skipped**（DB 集成） | ✅（建议写成 196 passed / 3 skipped） |
| 262 passed（第 44 行） | 262 passed, 136 skipped | ✅ |
| 10 项三段式冒烟（第 17 行） | `agent_smoke.py` 恰好 10 个 `check_*` | ✅ |
| 6 个客户端动作 + 服务端 `give_vehicle_keys`（第 13 行） | `effect_rules.lua:29-37` 6 client + 1 server | ✅ |

`TOOLS.md` 是生成物：30 行风险表逐行与 JSON 比对 **0 处差异**；`--check` 保证
它与 JSON 字节一致。`ACTIONS.md` §5.12 的 17 行 risk/approval 与 policy 逐项比对
**0 处差异**。

### 3.5 错误码抽查（ACTIONS.md §9 vs `main.lua` / `policy.lua` / `http_api.lua`）

| Code | 实际返回位置 | §9 表 |
|:---|:---|:---|
| `unsupported_action` | `policy.lua:381,879,933,1119,1128,1323` | ✅ |
| `invalid_params` | `policy.lua` 73 处（如 `:281`） | ✅ |
| `money_cap_exceeded` | `policy.lua:540,1211` | ✅ |
| `daily_budget_exceeded` | `policy.lua:1220` | ✅ |
| `text_too_long` | `policy.lua:412,499,1147,1200` | ✅ |
| `account_unavailable` | `policy.lua:1214` | ✅ |
| `player_not_found` | `policy.lua:1137` | ✅ |
| `quest_not_found` | `policy.lua:1232` | ✅ |
| `job_not_found` / `grade_not_found` / `job_unavailable` | `policy.lua:1241,1245,1256` | ✅ |
| `item_not_found` | `policy.lua:1271,1280` | ✅ |
| `weather_sync_unavailable` / `executor_unavailable` | `policy.lua:1157,1173,1180` | ✅ |
| `model_not_found` / `not_in_vehicle` / `plate_mismatch` | `policy.lua:1188,1307,1316` | ✅ |
| `invalid_account` | `policy.lua:526` | ❌ 不在 §9 表（只在 §7.1 行文提到） |
| `missing_body` | `http_api.lua:245` | ❌ 不在 §9 表（只在 design/05 提到） |
| `internal_error` | `http_api.lua:274` | ❌ 不在 §9 表（只在 API.md 提到） |

20 个抽查码中 **17 个在表中**，3 个实际会返回但表里没有；表里没有“只存在于文档”
的码（其余码都能在源码里找到）。

---

## 4. 发现表

| ID | 严重度 | 位置 | 问题 | 证据 | 建议 |
|:--|:--|:--|:--|:--|:--|
| **C-01** | **P1** | `tools/agent_tools.json:1288-1304`；`server/policy.lua:196-200,776-793`；`shared/agent_tools.lua:452-458` | `teleport` 的 agent 面 schema 写 `x/y/z ∈ -10000..10000`，但 director policy 与效果通道只接受 `x/y ∈ -4500..8500`、`z ∈ -200..3000`。MCP 先按 registry 放行，HTTP 到 director 后必然 `invalid_params`；审批人甚至会先看到一个“合法”提案。 | registry 探针：`x=-5000 → OK`、`x=9000 → OK`、`z=-500 → OK`；policy 探针：三者均 `FAIL x/z is outside the GTA map bounds`。ACTIONS.md:77-78 与 `effect_rules.lua:21-25` 都是 -4500..8500/-200..3000。 | 把 registry 的 x/y/z `minimum/maximum` 改成与 `MAP_BOUNDS` 完全一致（建议从同一常量生成），并加一条“registry 边界 == policy 边界”的跨语言测试。 |
| **C-02** | **P1** | `tools/agent_tools.json:1279-1315`；`shared/agent_tools.lua:450-456`；`server/policy.lua:767-806`；`docs/agent/ACTIONS.md:34,79` | ACTIONS.md 明确 `teleport` 支持可选 `heading 0..360`，policy 也实现了，但 registry inputSchema 没有 `heading`、生成 Lua 的 `params` 没有它；MCP 在 `agent_mcp.py:1048` 会以 `unknown argument(s): heading` 直接拒绝。agent 按文档传参必失败，不传则落点朝向由引擎决定。 | `validate_arguments("teleport_player", {..., heading:90})` → `FAIL: unknown argument(s): heading`；`AgentPolicy.Normalize` 同输入 → OK 且返回 `heading=90`。 | registry 增加 `heading: {type:"number", minimum:0, maximum:360}`，`--write` 重新生成 Lua/TOOLS.md；同步保留 ACTIONS.md 的 `heading?`。 |
| **C-03** | **P1** | `docs/agent/design/04-write-actions.md:1,13,38-57,536-549`；`docs/agent/STATUS.md:23-29` | design 04 仍以“15 个动作 / 16 行清单 / 23 工具”为“施工口径”，与最终 17 动作/30 工具不一致，且安全相关的差异没有在 STATUS 的“与设计 04 的差异”表登记：① `kick` 设计要求“永远 + 双人”，实现是单 approver；② `set_bucket` 设计要求 `1000–1999` + `GetPlayersInBucket` 桶内占用检查，实现是 `0..65535` 且无占用检查（`policy.lua:722-745` 只校验范围）；③ 风险等级：`set_job` 设计 L4→实现 L3、`delete_vehicle` 设计 L3→实现 L4、`remove_item` 设计 L3→实现 L4、`add_item` L3→`grant_item` L4；④ §13.3 写“23 工具 / 23 active”，实际 30/30。 | 读 design 04:38-57 与 `policy.lua:29-129` 对照；`grep -rn -e required_approvals -e approval_count server/` 无结果；`set_bucket` 探针 `bucket=1`/`65535` 均 OK；STATUS:23-29 只列了 `send_phone_message`/`set_money`/`delete_vehicle` 三条。 | 给 design 04 加“已由 §13 取代”的 banner，补 §13.4 记录最终 7 个动作与风险变更；或在 STATUS 差异表补上双人审批、bucket 范围/占用检查、set_job 风险等级三项，并明确“降级为单审/开放 0..65535”的理由。 |
| **C-04** | P2 | `tools/agent_tools.json:1140-1143,1559-1562`；`server/policy.lua:448-485,680-720`；`docs/agent/ACTIONS.md:39,67,87` | 文档把 `set_time_of_day.minute` 和 `remove_item.amount` 定义为可选（policy 也给了默认值 0 / cap），但 registry 把它们放进 `required`。按 schema 调用的 agent 必须显式传值，文档默认值在 MCP 路径上不可达。 | registry 探针：`{hour:12}` → `minute is required`；省略 `amount` → `amount is required`。policy 探针两者均 OK。 | registry 把 `minute`/`remove_item.amount` 移出 `required`（policy 已有默认值）；`--write` 重新生成。 |
| **C-05** | P2 | `tools/agent_tools.json:1040-1058,1384-1392,1829-1837`；`server/policy.lua:432-446,814-846,857-880`；`docs/agent/ACTIONS.md:65,81-82` | 文档说 weather “case-insensitive, normalized to uppercase”、plate “trimmed and uppercased”，policy 确实这么做；但 registry 的 `enum` 只收大写、plate `pattern` 只收 `[A-Z0-9]`，MCP 会在归一化之前拒绝 `"rain"`/`"abc123"`。 | registry：`set_weather {weather:"rain"}` → FAIL 枚举；`spawn_vehicle {plate:"abc123"}` → FAIL pattern。policy：两者均 OK。 | 要么 registry 接受小写（enum 加小写变体/大小写不敏感校验），要么把文档改成“调用方必须先大写”；推荐前者，与 policy 的归一化一致。 |
| **C-06** | P2 | `server/policy.lua:279-288`；`tools/agent_tools.json:1695`；`docs/agent/ACTIONS.md:70,85,87,90` | `cleanString` 用 `#cleaned`（字节）判断长度，而 registry/JSON Schema 与文档按“字符”计。4 个 `reason` 字段（`add_money`/`grant_item`/`remove_item`/`kick`）在 CJK 输入下会“registry 通过、policy 拒绝”。 | `kick reason=60×'中'`：registry OK；policy `invalid_params: reason exceeds 128 characters`（实际 60 字符）。 | policy 改用已有的 `AgentPolicy.TextLength`（`policy.lua:233-240`）做长度判断；错误文案同步改成 characters。 |
| **C-07** | P2 | `tools/agent_tools.json:721,814,967,1462,1545`；`server/main.lua:51-56`；`server/policy.lua:376-378`；`docs/agent/ACTIONS.md:61,63,69,84,87` | registry 把可调 convar 的上限写死：`notify/announce` 300、`add_money` 1000、`grant/remove` 50。文档说这些上限由 `agent_actions_max_*` 控制（policy 默认 50/1000，clamp 到 1..1000 / 0..1e9 / 1..2000）。运维一旦调高 convar，MCP 仍按旧上限拒绝；调低时 registry 又放行、policy 拒绝。 | `agent_actions_max_item_amount=100` 时 policy 接受 `amount=100`，registry `amount must be <= 50`；`max_money=2000` 时 policy 接受 2000，registry `<= 1000`。 | 明确“工具面 schema 固定为默认值”并在 TOOLS.md 标注；或让 MCP 从 `/agent/v1/policy` 的 `limits` 动态收紧/放宽（至少不要比 policy 更严）。 |
| **C-08** | P2 | `server/policy.lua:487-518,520-552,554-561`；`tools/agent_tools.json` 各 `additionalProperties:false`；`docs/agent/ACTIONS.md:93-99` | `notify`/`add_money`/`start_quest` 的 `Normalize` 刻意不调用 `rejectUnknownFields`（文档说这三个丢弃未知键），但 registry/MCP 一律拒绝未知键。同一动作经 MCP 与经 `exports.Propose` 行为不同。 | registry：`send_notify {..., foo:"bar"}` → unknown argument；policy：OK 且丢弃 `foo`。 | 统一语义：要么三个动作也 `rejectUnknownFields`（推荐，和另外 14 个一致），要么在文档里注明“仅 export 路径丢弃，MCP 路径拒绝”。 |
| **C-09** | P2 | `server/main.lua:1666-1700`；`server/policy.lua:29-129`；`tools/agent_tools.json`（每工具）；`docs/agent/ACTIONS.md:48,745-747` | registry 对 17 个动作都声明了 `blast_radius` + `compensation`，但 `AgentActions.Policy()` 输出的 `blast_radius` 有 5 个 nil、`compensation` 有 8 个该有值却 nil（`add_money/start_quest/set_job/set_weather/set_time_of_day/teleport/spawn_vehicle/grant_item`）。ACTIONS.md 自己也不一致：第 48 行说 player-scoped 一律 nil，第 745-747 行又说 9 个动作显式 `single`。 | 直接调用 `Policy()`：`notify blast=nil comp=nil`、`set_weather blast=world comp=nil`、`set_job blast=nil comp=nil`；registry 对应 `single` + `manual`/`inverse`。 | 以 registry 为准补齐 `policy.ACTIONS` 的 `blast_radius`/`compensation`（或反过来从 policy 生成 registry 这两列）；同步修正 ACTIONS.md:48 的表述。 |
| **C-10** | P2 | `docs/agent/ACTIONS.md:826-830`；`server/main.lua:1270-1277`；`docs/agent/STATUS.md:36` | ACTIONS.md §7.1 写“Normalization failures (...) are not denial rows”，实现却在 Normalize 失败时调用 `recordDenial`，Lua case `normalize_rejection_is_recorded` 也把它固化了；STATUS.md:36 说“记录 Normalize/CheckPolicy/审批复核失败”，与 ACTIONS.md 直接矛盾。 | `grep -n recordDenial main.lua` → `:1274`（Normalize 分支）；`director_denials.lua:198-210` 断言 1 条 normalize denial；STATUS:36。 | 更新 ACTIONS.md §7.1 为“Normalize 失败也记 denial（只存 param_keys/hash）”，并说明这是 2026-10-22 的审计增强。 |
| **C-11** | P2 | `docs/agent/ACTIONS.md:28,625-626,1107-1109`；`server/main.lua:898-927`；`docs/agent/STATUS.md:35` | ACTIONS.md 三处说 `set_time_of_day` “no read-back”、结果只有 `{hour,minute,at}`；实现（以及 Lua case `set_time_readback_mismatch_is_verification_failed`）会读回 `getTime()` 并比对，结果含 `before/after/verify_result`。STATUS.md:35 也把 `set_time_of_day` 列进“执行后回读”。 | `main.lua:914-927`：`readWeatherTime()` + 不一致返回 `verification_failed`；`sed -n '1094,1112p' ACTIONS.md` 仍写 no read-back。 | 更新 ACTIONS.md §1 矩阵与 §8 的 `set_time_of_day` 段（含 `verify_result` 语义：旧版无 `getTime()` 时退化为 `false`）。 |
| **C-12** | P2 | `docs/agent/ACTIONS.md:1121-1158`；`server/policy.lua:526`；`server/http_api.lua:245,274` | §9 错误码表漏了 3 个实际会返回的 code：`invalid_account`（add_money 非法账户，policy 返回、HTTP 400）、`missing_body`（无 body，400）、`internal_error`（live 拦截/适配器异常，500）。它们在本仓库其他文档里有零散记载，但“HTTP errors”表是 agent 的唯一索引。 | `grep -n invalid_account policy.lua` → `:526`；`grep -n missing_body http_api.lua` → `:245`；`grep -n internal_error http_api.lua` → `:274`。 | 在 §9 表补 3 行（含 HTTP 400/500 与 kind 映射），或在表头声明“以 `agent_contract.CODE_TO_KIND` 为全集”。 |
| **C-13** | P2 | `tools/agent_contract.py:36-100`；`resources/[custom]/custom-director/server/policy.lua` 各 `fail/failBool` | `CODE_TO_KIND` 没有映射 9 个 director policy code：`item_not_found`/`job_not_found`/`job_unavailable`/`grade_not_found`/`model_not_found`/`not_in_vehicle`/`plate_mismatch`/`weather_sync_unavailable`/`executor_unavailable`，外加 `missing_body`。`classify()` 把它们全部降级成 `internal_error`（retryable=false），MCP 据此把“物品/职业不存在”报成服务端内部错误。 | `classify("item_not_found") == ("internal_error", False)`；`classify("job_not_found")` 同；`classify("missing_body")` 同。 | 在 `CODE_TO_KIND` 追加：前 7 个 → `policy_denied`/`not_found`/`target_unavailable`，`weather_sync_unavailable`/`executor_unavailable` → `upstream_unavailable`，`missing_body` → `invalid_argument`；同步 `test_agent_contract.py` 的快照表。 |
| **C-14** | P2 | `docs/agent/TOOLS.md:80`；`tools/agent_tools.py:1210`；`tools/agent_tools.json`（`send_announce` channel=effect, risk=L2） | 生成器写死的 Contract note 说“`effect` tools are `L3`/`L4`”，但同一张表第 17 行 `send_announce` 就是 effect/L2；registry 校验器（`agent_tools.py:529-530`）也明确允许 effect ∈ L2/L3/L4。这是 review 03 F-05 的遗留项，未修。 | `TOOLS.md:80` 与 `TOOLS.md:28`（`send_announce ... effect ... L2`）直接矛盾；`agent_tools.py:530` 的错误文案。 | 把 note 改成“effect ∈ L2/L3/L4；L2 必须 requires_approval=true 或 undo!=null”（与校验器一致），重新 `--write`。 |
| **C-15** | P2 | `server/main.lua:1184-1200`；`tests/agent/lua/cases/director_actions.lua:122-137`；`tests/agent/lua/cases/director_actions.lua`（无 add_money/start_quest） | `_Execute` 只暴露 14 个执行器，`notify`/`add_money`/`start_quest` 不在其中；`tests/agent/lua/cases/director_actions.lua` 恰好没有这三个动作的用例。结果是 17 个动作里 3 个**没有任何执行路径测试**（只有 Normalize/Preview/Policy 用例在 `test_agent_actions_policy.lua`）。 | `_Execute = {set_job, set_job_duty, set_metadata, grant_item, remove_item, set_bucket, kick, announce, set_weather, set_time_of_day, teleport, spawn_vehicle, revive, delete_vehicle}`（14 个）；`executors_exposed` 只断言这 14 个；`grep add_money` 与 `grep start_quest` 在 `tests/agent/lua/cases/director_actions.lua` 均为 0。 | 把 `executeNotify/executeAddMoney/executeStartQuest` 也挂到 `_Execute`，补 `notify` 的 kind/text、`add_money` 的 delta/预算、`start_quest` 的 catalog 三条用例。 |
| **C-16** | P2 | `tests/agent/*.py`、`tools/agent_tools.py` | 没有任何自动测试把 `agent_tools.json`、`policy.ACTIONS`、`policy.Normalize`、ACTIONS.md 放在一起比对：`--write`/`--check` 只保证 JSON→(Lua,TOOLS.md) 字节一致；Python 侧 `grep AgentPolicy.ACTIONS` 无结果；Lua 侧也没有读取 `AgentTools.TOOLS`。C-01～C-09 全部因此逃过 CI。 | `grep -rn "AgentPolicy.ACTIONS" tests/agent/*.py tools/*.py`（以及 `policy.lua`） 只命中生成器注释；`grep -n "AgentTools" policy.lua` 无结果（review 03 F-13 仍未闭环）。 | 加一个 `agent_contract_check.py`（待建，或 pytest）：解析 `policy.lua` 的 `ACTIONS` 与 `Normalize` 分支，断言 (a) `{tool.director_action} == ACTIONS 键集`；(b) 每个动作的 risk/approval/blast/comp 一致；(c) 每个 inputSchema 的 required/enum/min/max 与 Normalize 的边界一致。CI 跑它。 |
| **C-17** | P2 | `custom-agent-client/shared/effect_rules.lua:33`；`server/policy.lua:61-66`；`docs/agent/ACTIONS.md:34` | 效果通道把 `teleport` 标成 **L2**，而 director 的同一动作与文档都是 **L3**。teleport 不在 `WORLD_ACTIONS`、也不会自动执行，但它进入效果通道的审计/限流口径时风险等级低了一级，与“L2 仅世界表现类”的分类冲突。 | `effect_rules.lua:33` `teleport = { site='client', risk='L2' }`；`policy.lua:62` `teleport.risk='L3'`。 | 把效果通道的 `teleport` 风险改成 L3（或补注释说明“通道原始动作低于 director 包装动作”），并在 design/02 的 L0–L4 表里登记。 |
| **C-18** | P2 | `shared/agent_tools.lua:672-681`；`tools/agent_tools.py:1098-1106`；`server/policy.lua:520-552` | 同一份 JSON 的 `integer` 在三处有三种判定：生成 Lua 用 `value % 1 == 0`，接受 `5.0`；Python `validate_arguments` 用 `isinstance(int)`，拒绝 `5.0`；`Normalize` 用 `math.floor` 相等，接受。`grant_item.amount=5.0` 会被 Lua/`Normalize` 放行、被 MCP 拒绝。 | `AgentTools.validate('grant_player_item', {..., amount=5.0, ...})` → OK；`validate_arguments` 同输入 → `amount must be integer`；`Normalize` 同输入 → OK。这是 review 03 F-04 的残留项。 | 统一 `integer` 语义（建议按 JSON Schema：数学整数即 integer，或反过来三处都只收 Lua/JSON 整数），并在 `agent_tools.py` 的校验器与生成 Lua 里各加一条 `5.0` 用例。 |

---

## 5. 已核对一致（逐项）

1. **工具 ↔ 动作**：30 工具 / 17 动作 / 17 个唯一 `director_action`；13 个只读工具
   `director_action=null`；无重复、无悬空（`tools/agent_tools.json`，`--check`）。
2. **17 个动作都有工具**，包括题面点名的 `notify`/`add_money`/`start_quest`/`announce`。
3. **风险 + 审批**：registry == policy == ACTIONS.md §5.12 == TOOLS.md，17/17，0 处差异。
4. **auto_execute**：仅 `notify` 为 true，其余 16 个 false（`policy.lua:29-129`）。
5. **世界动作**：`announce`/`set_weather`/`set_time_of_day` 无 `citizenid`、可零人在线
   （`policy.lua:134-139,393-485,1136`），`blast_radius=world` 四方一致。
6. **生成物**：`--check` 通过（30 tools，2 files）；Lua `params/required/schema/auth/risk`
   与 JSON 抽样 6/6 完全一致；所有变更 Lua `luac5.4 -p` 通过。
7. **`resources/[custom]/custom-director/shared/agent_tools.lua` 无手改**：`--check` 字节比对通过，文件头是 `@generated`。
8. **STATUS 数字**：209 checks / 8 suites、196 passed（+3 DB skip）、262 unit passed、
   30/30、17 动作、10 项 smoke —— 全部可复现。
9. **TOOLS.md**：30 行 `risk/blast_radius/requires_approval` 与 JSON 0 差异。
10. **ACTIONS.md §5.12**：17 行 risk/approval 与 policy 0 差异；动作清单 14 player-scoped
    + 3 world = 17，计数正确。
11. **参数枚举**：`set_metadata` 4 个 key（hunger/thirst/stress/armor）在 registry enum、
    `METADATA_KEYS`、文档三处一致；`isdead`/`inlaststand` 均被拒。
12. **`kick.reason` 128**（ASCII）与 `grant_item.amount` 默认 50 在 registry 与 policy
    默认配置下一致；`grant_item.reason` 的 `HasControlChars` 比 `add_money.reason` 严，
    但两者都在文档“no C0 controls”范围内。
13. **策略拒绝落库语义**：policy 拒绝不写 `agent_actions`，只写 `agent_denials`
    （`main.lua:1319-1335`），与 STATUS:36/ACTIONS §7.1 的主干一致（细节见 C-10）。
14. **L3/L4 无误放行**：`StatusFor` 对 16 个非 notify 动作返回 `pending_approval`
    （`policy.lua:1334-1338`），`RequiresApproval` 与 ACTIONS 一致。

---

## 6. 其他观察（不计入 P）

- registry 的 `verify` 有两处形同虚设：`teleport_player` 只断言
  `citizenid == $citizenid`（`agent_tools.json:1320-1333`），`grant_player_item` 同样只
  校验 citizenid，无法发现“没传送/没发到物品”。当前 MCP 不执行 `verify`（review 03
  F-14），director 自己做了回读，所以不影响运行；但 TOOLS.md 的 Verify 列会让读者
  以为这两条能验真。建议改成可断言的位置/数量字段，或在 TOOLS.md 标注“metadata only”。
- `remove_player_vehicle` 与 `delete_vehicle` 的名称差异（见 §3.1）建议在
  `ACTIONS.md` 的差异表保留一句（STATUS:29 已有，但 TOOLS.md 没有）。
- `set_time_of_day` 的 `hour` 也是 `integer`，与 C-18 同源（整值浮点）。

---

## 7. 限制

- 未连真实 FXServer / MySQL / GTA 客户端：`Propose`/`Approve` 的 DB 行为、`DropPlayer`
  异步、`SetEntityCoords` 的 OneSync 时序均未验证（与 STATUS §4 的“没有做过”一致）。
- 未跑 `tools/agent_smoke.py`（需要 live server）；只核对了它的 10 个 check 数量。
- `agent_gateway` 的视图字段无法在无 DB 环境下确认，因此没有评估 registry 中
  `verify` 对 `get_player_snapshot` 字段的可满足性。
- `/tmp` 探针脚本未入库；仓库内只新增本文件。

---

**P0 = 0，P1 = 3，P2 = 15。**
最严重一条：**C-01** — `teleport` 的 agent 面 schema 允许 ±10000，director/效果通道只接受 `-4500..8500`/`-200..3000`，MCP 放行的坐标到 director 必然 `invalid_params`。
其次：**C-02**（`heading` 在工具面缺失，按文档调用必失败）、**C-03**（design 04 未与最终 17 动作/单审/bucket 范围对账）。
建议：**修完 C-01/C-02/C-03 后再合并**；不建议以当前状态合并。
其余 15 个 P2 可随 PR 记录并排期（优先 C-09/C-10/C-11 的文档修正与 C-16 的四方回归测试）。
