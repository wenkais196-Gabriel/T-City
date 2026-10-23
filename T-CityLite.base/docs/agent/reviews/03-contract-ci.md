# 03 — 工具契约与 CI 评审（commit `498b888`）

- 仓库：`/home/swk/Documents/deepseek-harness/default-workspace/T-City-agent`
- 分支：`feat/agent-takeover-v2`
- 评审对象：`498b888`（工具 registry、生成器、契约层、registry 驱动的 MCP）
- 评审范围：`tools/agent_tools.json`、`tools/agent_tools.py`、
  `T-CityLite.base/docs/agent/TOOLS.md`、
  `T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua`、
  `tests/agent/test_agent_tools*.py`、`.github/workflows/ci.yml`
- 方法：只读审查 + 在 `/tmp` 的 `git archive HEAD` 副本上做变异实验；
  没有修改任何被 git 跟踪的文件。
- 本地环境：Python `3.14.4`，`lua5.4`/`luac5.4` 可用；CI 目标是 Python 3.12 +
  Ubuntu `lua5.4`。本地无法验证 3.12 字节码差异，但代码只使用 3.10+ 语法。

## 结论

**需修（P1 修复后可合并；无 P0，不阻断）。**

registry 的主干不变量确实被校验，生成链也是确定性的；但当前有 4 个 P1：
命名 `add_` 白名单被放宽为全局动词、`effect` 的审批矩阵存在可放行组合、
设计 §9.1 的 untrusted 包裹没有实现却被 `instructions` 宣称、生成 Lua 的
`validate` 与 Python 语义不一致。前三个影响“契约是否可信”，第四个会在
D7 把 Lua 表接进 `policy.lua` 时变成真实绕过。

## 0. 可复现基线

```bash
cd /home/swk/Documents/deepseek-harness/default-workspace/T-City-agent
git status --porcelain                 # 评审开始时为空
python3 tools/agent_tools.py --check   # rc=0: 20 tools, 2 generated files match
cd T-CityLite.base && python3 ../tools/agent_tools.py --check   # rc=0
cd / && python3 /home/swk/.../tools/agent_tools.py --check      # rc=0
```

所有非法 registry 实验使用同一方法：`git archive HEAD | tar -x -C /tmp/...`，
在副本里改 `tools/agent_tools.json`，然后运行 `--write` / `--check`。
`--write` 在 `load_registry()` 阶段就会因非法 registry 退出 1，所以下表
“write rc=1”同时证明“不会写出半成品”。

## 1. 不变量实测

### 1.1 负例：全部 `exit 1`（符合设计）

| # | 变异 | 实际错误（首条） | `--write` / `--check` |
|---:|:---|:---|:---:|
| N1 | 新增工具名 `run_command` | `registry.tools[20].name: must match '^(?:get|...|add)_[a-z]...'` | 1 / 1 |
| N2 | `get_schema.risk=L1` | `read tools must be L0 (L0 ⇔ read)` | 1 / 1 |
| N3 | `send_notify.risk=L0` | `write/effect tools cannot be L0` | 1 / 1 |
| N4 | `start_player_quest.requires_approval=false` | `L3 tools must require approval` | 1 / 1 |
| N5 | `set_weather.undo.tool=set_missing_weather` | `unknown undo tool ...` | 1 / 1 |
| N6 | `send_notify` 增加 `sql_text` 参数 | `dangerous parameter name (command/SQL/event/eval class)` | 1 / 1 |
| N7 | `send_notify` 增加 `meta:{type:object}` | `...type: must be one of ['string','integer','number','boolean','array']` | 1 / 1 |
| N8 | 读工具增加 `verify` | `read tools must set verify=null` | 1 / 1 |
| N9 | 重复工具名 | `duplicate tool name 'get_schema'` | 1 / 1 |
| N10 | 顶层增加 `extra_field` | `registry.extra_field: unknown top-level field` | 1 / 1 |
| N11 | `send_notify.verify.tool=add_player_money` | `verify must reference a read tool` | 1 / 1 |
| N12 | 读工具 `http.method=POST` | `read tools must use GET` | 1 / 1 |
| N13 | 读工具声明 `undo` | `read tools cannot declare undo` | 1 / 1 |
| N14 | `set_weather` undo 指向更高风险的 `set_player_job` | `undo target risk must be <= this tool's risk` | 1 / 1 |
| N15 | `send_notify` 增加到 13 个 properties | `maxProperties must be <= 12` | 1 / 1 |
| N16 | 数组 `maxItems=51` | `arrays must declare maxItems in 1..50` | 1 / 1 |
| N17 | `additionalProperties=true` | `must be false` | 1 / 1 |
| N18 | `blast_radius=world` 且 `requires_approval=false` | `world-scoped tools must require approval` | 1 / 1 |
| N19 | `required` 引用未声明的 property | `required property 'nope' is not declared in properties` | 1 / 1 |
| N20 | 数组名 `ids`（非 `*_ids`） | `v1 arrays must be named *_ids` | 1 / 1 |

结论：命名正则、`L0⇔read`、`L3/L4⇒审批`、`undo` 目标存在/`undo_supported`/
风险不升、危险参数名、`inputSchema` 的 `additionalProperties`/`maxProperties`/
数组约束、`verify` 必须是 read 工具，这些**确实**被校验。

### 1.2 被放行的反例：`--write` 和随后的 `--check` 都是 `0`

这些不是“合法工具”，而是本应被契约拦住的 registry 仍被接受。均为 `/tmp`
副本实验，复现命令见 §7。

| # | 变异 | 结果 | 关联发现 |
|---:|:---|:---|:---|
| A1 | `send_announce.requires_approval=false`（effect/L2，undo 为 null） | 接受 | F-02 |
| A2 | 新增工具 `add_world_notice`（复用 `add_` 前缀） | 接受 | F-01 |
| A3 | `add_player_money.verify.args={}`（漏掉目标必填 `citizenid`） | 接受 | F-06 |
| A4 | `send_notify.route=gateway`（write 工具走 gateway） | 接受 | F-08 |
| A5 | `add_player_money` 增加 `text:{type:string,maxLength:5000}` | 接受 | F-09 |
| A6 | 把 `get_action.status` 改成 `planned`，`send_notify.verify` 仍指向它 | 接受 | F-06 |
| A7 | `send_announce.risk=L1, requires_approval=false`（effect/L1） | 接受 | F-02 |
| A8 | `send_notify.risk=L2, requires_approval` 保持 false | 接受 | F-02 |
| A9 | 增加 `player_id` / `server_id` / `net_id` / `slot_id` / `source_id` 参数 | 接受 | F-07 |
| A10 | 增加 `citizen_id`（自由 string，无 pattern） | 接受 | F-07 / F-09 |

关键含义：

- `add_` 不是“只对已发布的 `add_player_money` 开例外”，而是对所有新 `add_*`
  开放；命名不变量对新工具基本失效。
- `effect` 不仅能是 L2，还能是 L1；而审批只由 `risk∈{L3,L4}` 或
  `blast_radius=world` 强制，`effect/L1` 和 `effect/L2 + requires_approval=false`
  都能进入 registry。
- `verify` 只检查“目标存在、是 read 工具、args 的 key 在目标 props 里”，
  不检查目标的必填参数、也不检查目标是否 `planned`（不可调用）。

## 2. 生成物一致性

### 2.1 `--write` 幂等

在 `/tmp` 的完整副本中：

```bash
python3 tools/agent_tools.py --write   # rc=0
sha256sum TOOLS.md agent_tools.lua     # run 1
python3 tools/agent_tools.py --write   # rc=0
sha256sum TOOLS.md agent_tools.lua     # run 2 == run 1
python3 tools/agent_tools.py --check   # rc=0
```

结论：两次 `--write` 字节级一致；`--check` 通过；`generated` 字段不由
`--write` 更新（见 F-17，P2）。

### 2.2 cwd 无关

`--check` 在 repo root、`T-CityLite.base`、`/tmp`、`/` 四个 cwd 下都返回 0。
原因：`REPO_ROOT = Path(__file__).resolve().parents[1]`，路径全部相对
`__file__`，不依赖 cwd。结论：cwd 不是缺口。

### 2.3 `TOOLS.md` 与 registry

- `tests/agent/test_agent_tools.py:262-273` 对 `render_tools_md()` 做逐字节比较；
  `--check` 也通过，所以表格数据与 registry 一致。
- 但 `TOOLS.md:60` 的 Contract notes 写死了一句“`effect` tools are `L3`/`L4`”，
  而同文件 `:50-52` 的表格明确列出 `send_announce`/`set_weather`/
  `set_time_of_day` 为 `effect` + `L2`。**生成物自相矛盾**（F-05）。
- `TOOLS.md` 未从 `README.md`/`API.md`/`ACTIONS.md` 链接（设计 D9 未完成）；
  `docs-check` 不会因为孤立文件报红（F-10 / F-18）。

### 2.4 Lua `validate` 与 Python `validate_arguments` 对照

用同一个参数集分别调用生成的 `AgentTools.validate` 和 Python
`agent_tools.validate_arguments`（`lua5.4` 实测）：

| 参数 | Python | Lua | 结论 |
|:---|:---|:---|:---|
| `get_player_snapshot{ citizenid:"" }` | 拒绝（pattern） | **接受** | 不一致 |
| `get_player_snapshot{ citizenid:"bad citizen" }` | 拒绝 | **接受** | 不一致 |
| `get_player_snapshot{ citizenid:"ABCDEFGHIJKL" }`（12 字符） | 拒绝 | **接受** | 不一致 |
| `send_notify{ idempotency_key:"has space" }` | 拒绝（`^[!-~]{1,128}$`） | **接受** | 不一致 |
| `send_notify{ idempotency_key:"bad\nkey" }` | 拒绝 | **接受** | 不一致 |
| `send_notify{ text:"x"*301 }` | 拒绝（<=300） | 拒绝 | 一致 |
| `query_players{ limit:201 }` | 拒绝（<=200） | 拒绝 | 一致 |
| `query_players{ limit:200 }` | 接受 | 接受 | 一致 |
| `query_players{ nope:1 }` | 拒绝（unknown argument） | 拒绝 | 一致 |
| `add_player_money{ amount:0 }` | 拒绝（>=1） | 拒绝 | 一致 |
| `add_player_money{ amount:1.0 }` | 拒绝（`_is_int` 拒绝 float） | **接受**（Lua `1.0 % 1 == 0`） | 不一致 |

根因：`render_lua()` 只把 `type/enum/minimum/maximum/minLength/maxLength/
maxItems` 写进 Lua 表，**没有渲染 `pattern`**；生成的
`AgentTools.validate()`（`agent_tools.lua:446-484`）也从不消费
`max_items`。Lua 的 `#value` 还是字节长度，Python 是 Unicode 字符数，
emoji 文本也会出现分歧。

结论：Lua 镜像目前比 Python 宽，尤其 `citizenid` 和 `idempotency_key`
的 pattern 完全丢失；当前它未被 `policy.lua` 使用，所以是潜在缺口，但
一旦 D7 接线就会成为真实绕过（F-04）。

## 3. 发现表

| ID | 严重度 | 文件:行 | 问题 | 复现 | 建议 |
|:---|:---:|:---|:---|:---|:---|
| F-01 | **P1** | `tools/agent_tools.py:44-64` | `add` 被加入全局 `VERBS`；任何新 `add_*` 都通过命名正则，`add_player_money` 的 legacy 例外被扩大成通用动词。`test_agent_tools.py:183-185` 还把它固化为“允许”。 | A2：追加一个 `add_world_notice` 工具（唯一 `director_action`），`--write`/`--check` 均 0。 | 从 `VERBS` 移除 `add`；单独维护 `LEGACY_NAMES={"add_player_money"}` 例外，并要求该名字只能对应既有 `director_action=add_money`。 |
| F-02 | **P1** | `tools/agent_tools.py:383-396` | `effect` 只禁止 L0；`effect/L1`、`effect/L2 + requires_approval=false` 都能通过。审批矩阵实际只强制 L3/L4/world，设计里“effect ⇒ L3/L4”和“L2 默认审批”都没有在 registry 层表达。 | A7：`send_announce.risk=L1, requires_approval=false` → 0；A1：`send_announce.requires_approval=false`（L2、undo=null）→ 0。 | 增加 `effect ⇒ risk∈{L2,L3,L4}`；`effect/L2` 要求 `requires_approval=true` 或 `undo != null`；同步更新设计 §6 与 `TOOLS.md` note。 |
| F-03 | **P1** | `tools/agent_mcp.py:840-879`；设计 `03-tool-contract.md:284-296` | `initialize.instructions` 声称“`untrusted:true` 字段是数据”，但 facade 从未包裹/标注/清洗任何 read 响应；`agent_contract.sanitize_untrusted()`（`agent_contract.py:276`）在运行时没有调用方（只有单测直接调用），`meta.untrusted_fields` 也未生成。玩家名等字符串原样进入模型上下文。 | `grep -n "sanitize_untrusted\|untrusted_fields" tools/agent_mcp.py tools/agent_gateway.py` 无结果；`grep -n "untrusted_fields" tools/agent_tools.json` 只有 registry 声明。 | 至少对 `pii.untrusted_fields` 做 `{text,untrusted:true,source,...}` 包裹和 `meta.untrusted_fields`；或明确降级：删除 instructions 中的承诺并在设计 §9.1 标记 deferred（不建议）。 |
| F-04 | **P1** | `agent_tools.lua:446-484`；`tools/agent_tools.py:1097-1238` | 生成的 Lua `validate` 不检查 `pattern`，不消费 `max_items`；`citizenid` 可空/含空格/超 11 字符，`idempotency_key` 可含空格/换行，`1.0` 被当作 integer。与 Python 语义不一致。 | §2.4 的 `lua5.4` 对照；`grep -n pattern agent_tools.lua` 无结果。 | 渲染 pattern（或生成 Lua 兼容的字符集/长度规则）；在 Lua 里实现 `max_items`；增加 Python↔Lua 参数化对照测试，至少在 D7 接线前完成。 |
| F-05 | P2 | `T-CityLite.base/docs/agent/TOOLS.md:60` vs `:50-52` | 生成的 Contract notes 说 `effect` 只能是 L3/L4，但同一文件表格有 3 个 L2 effect 工具；`render_tools_md()` 把这句话写死，未从 registry/设计同步。 | 直接阅读 `TOOLS.md:50-60`；无需运行。 | 修改 `render_tools_md()` 的 note 为“effect ∈ L2/L3/L4，L2 需审批/undo 条件”，并同步设计 §6；或删除该硬编码句子。 |
| F-06 | P2 | `tools/agent_tools.py:785-806` | `verify` 只校验 args 的 key 在目标 props 中，不校验目标 `required` 是否齐全；也不拒绝 `status=planned` 的 verify 目标（不可调用）。 | A3：`add_player_money.verify.args={}` → 0；A6：`get_action.status=planned` 后 `send_notify.verify` 仍指向它 → 0。 | 解析目标 schema，要求 `target.required` 全部出现在 `verify.args`（允许 `$action_id` 等 builtin）；verify/undo 目标必须 `status=active`；对 `undo.args` 做同样检查。 |
| F-07 | P2 | `tools/agent_tools.py:77`、`:464` | 易变标识黑名单是精确小写集合 `{source,playerid,serverid,netid,slot}`；`player_id`/`server_id`/`net_id`/`slot_id`/`source_id` 全部通过，语义上仍是设计禁止的“槽位/易变标识”。 | A9：给 `send_notify` 加 `player_id`（或其余变体）→ 0。 | 改成按分隔符/前缀匹配：`(^|_)(source|player_?id|server_?id|net_?id|slot)(_|$)`，并加负例测试。 |
| F-08 | P2 | `tools/agent_tools.py:552-578` | `_validate_http` 只看 method/path 格式，不校验 `route` 与 channel 的组合；write 工具可以 `route=gateway`，MCP 会按 gateway 走 GET，参数被拼到 query，写入永远不会发生或打错端点。 | A4：`send_notify.route=gateway`，保留 POST `/agent/v1/act` → 0。 | 强制 `channel in {write,effect} ⇒ route=director`；`route=gateway ⇒ channel=read && method=GET`；必要时校验 path 属于对应通道。 |
| F-09 | P2 | `tools/agent_tools.py:459-520` | 设计说“禁自由文本进游戏参数，唯一例外 notify.text”，但校验器只按参数名黑名单；给 L4 工具加 `text:string,maxLength:5000` 仍被接受（`reason` 的 128 上限只对名字 `reason` 生效）。 | A5：给 `add_player_money` 加 `text`（5000）→ 0；A10：`citizen_id` 自由 string → 0。 | 对所有无 `enum` 的 string 参数要求 `pattern` 或明确的 `free_text` 白名单；对非 `send_notify.text` 的文本加统一上限；补负例。 |
| F-10 | P2 | `T-CityLite.base/docs/agent/API.md:410-418`、`:476-477` | API.md 仍说 MCP 只有 5 个 read 工具、无写端点；实际 registry 有 13 个 active（含 `send_notify`/`add_player_money`/`start_player_quest`）和 7 个 planned。与 `TOOLS.md` 直接矛盾。 | `sed -n 410,418p API.md`；与 `TOOLS.md` 表格对照。 | 更新 API.md §5.1/§6.5：列出 10 个 read + 3 个 write/effect，说明写通道走 director、需审批；或把 API.md 中 MCP 段整体替换为指向 `TOOLS.md`。 |
| F-11 | P2 | `.github/workflows/ci.yml:60-64` | CI 只跑 `tests/unit` 和 `../tests/agent`；`T-CityLite.base/tests/agent/test_lua_harness.py` 不在任一收集路径，因此 `http_adapter` 用例（GET/404/405 同步响应回归）从不执行。 | 本地 `cd T-CityLite.base && python3 -m pytest -q tests/agent/test_lua_harness.py` → 3 passed；但 CI 没有这一行。 | 在 `unit-tests` 增加 `python3 -m pytest -q tests/agent`（工作目录 `T-CityLite.base`）；或显式跑 `lua5.4 tests/agent/lua/runner.lua --case http_adapter`。 |
| F-12 | P2 | `.github/workflows/ci.yml:28-30`、`:60-64` | 没有显式的 `python3 tools/agent_tools.py --check` step；虽然 `test_committed_artifacts_pass_check` 间接调用了 `main(["--check"])`，但依赖测试收集；`compileall -q tests` 只覆盖 `T-CityLite.base/tests`，不覆盖根 `tools/` 与 `tests/agent/`。 | `grep -n "agent_tools.py" .github/workflows/ci.yml` 无结果；`grep -n "compileall" ci.yml` 只有 `tests`。 | 在 repo root 增加 fail-fast step：`python3 tools/agent_tools.py --check`；增加 `python3 -m compileall -q tools tests/agent`。 |
| F-13 | P2 | `T-CityLite.base/resources/[custom]/custom-director/server/policy.lua:15-31`、`fxmanifest.lua:12` | `shared/agent_tools.lua` 被 fxmanifest 加载，但 `policy.lua` 仍硬编码 3 个 action，没有读取 `AgentTools`；设计 §3.1/D7 的“`AgentPolicy.ACTIONS` 由 registry 派生”尚未发生。当前“单一事实源”只覆盖 Python MCP 和文档，不覆盖 director。 | `grep -n "AgentTools" policy.lua` 无结果；`grep -n "agent_tools" fxmanifest.lua` 只有 `shared/agent_tools.lua`。 | 明确这是 D7 未完成项，不要在 PR 中宣称 Lua 已是权威；D7 时让 `policy.lua` 从 `AgentTools.TOOLS` 派生并保留 3 个 legacy 等价断言。 |
| F-14 | P2 | `tools/agent_mcp.py:209-222`、`:942-990`；设计 `03-tool-contract.md:252-262` | registry 的 `rate_limit`、`verify`、`undo` 在运行期只是元数据/`_meta`：MCP 没有令牌桶，`_handle_tools_call` 不执行 verify，也不安排 undo；设计 §8.3 的读 60/写 10/效果 2 限流未实现。 | `grep -n "rate_limit\|undo" tools/agent_mcp.py` 无结果；`verify` 只出现在 `_tool_descriptor()` 的 `_meta`（`agent_mcp.py:212-222`），`_handle_tools_call` 从 942 行直接进入 `_call_*`，没有 rate/verify/undo 逻辑。 | 要么在 MCP 实现令牌桶 + verify/undo 调度并加测试；要么在设计与 `TOOLS.md` 明确标注“M0 仅为元数据，director 负责验证/回滚”，避免把字段当已实现能力。 |
| F-15 | P2 | `tools/agent_tools.json:790`、`:795` | `send_announce` 描述是“to all players / World-scoped”，但 `blast_radius` 是 `single`。它当前 approval=true 所以不构成自动执行，但 blast_radius 是审批矩阵的输入，数据本身不一致。 | `sed -n 788,800p tools/agent_tools.json`。 | 改为 `world`（并保留/强化审批），或在描述中明确“单区域广播”；给 blast_radius 与描述的一致性加人工 review checklist。 |
| F-16 | P2 | `tools/agent_tools.py:895-935` | `validate_arguments`（MCP 运行期）不校验 array 的 `maxItems/minItems/uniqueItems/items`、`const`、`default`；只有 registry 校验器检查。当前 registry 没有 array 参数，因此是潜在缺口。 | 给任一工具加 `foo_ids:{type:array,maxItems:1,...}`，MCP 传 2 个元素：`validate_arguments` 不报错；Lua 也不消费 `max_items`。 | 在 `validate_arguments` 补 array 约束；或在设计里明确 v1 不支持 array 并让 validator 拒绝，避免“schema 有、runtime 不执行”。 |
| F-17 | P2 | `tools/agent_tools.json:5` | `generated` 固定为 `2026-10-22T16:00:00Z`，`--write` 不更新；它不代表生成时间，容易误导审计。 | `grep -n '"generated"' tools/agent_tools.json`；两次 `--write` 后值不变。 | 要么 `--write` 更新时间（但会破坏幂等，需要存 hash 而非时间），要么删除该字段/改名为 `generated_at` 并在 release 时手动更新；当前至少加注释说明。 |
| F-18 | P2 | `T-CityLite.base/docs/agent/{README,API,ACTIONS}.md` | `TOOLS.md` 没有被 `README.md`/`API.md`/`ACTIONS.md` 链接，违反设计 D9 的“链入 3 个 md”；docs-check 只检查已有链接是否可达，不检查孤立文档，所以不会红。 | `grep -rn "TOOLS.md" T-CityLite.base/docs/agent/{README,API,ACTIONS}.md` 无结果。 | 在 API.md/ACTIONS.md 的 MCP/action 段加上 `[TOOLS.md](TOOLS.md)`；在 `tests/agent` 加一个“关键文档互相链接”的静态测试。 |

> 注：F-18 是“缺失引用”，不是某一行内容错误；文件列用涉及的三份文档表示。

## 4. 8 条偏差逐条裁决

任务给出的 5 条（add_、effect L2、http.query、untrusted、connect timeout）加上
代码对照可对应的 3 条（Lua 未接线、Lua 弱校验、rate_limit/verify/undo 未执行），
共 8 条。逐条裁决如下：

| # | 偏差 | 裁决 | 严重度 | 理由 / 条件 |
|:--:|:---|:---|:---:|:---|
| D1 | `add_` 作为 legacy verb | **修** | P1 | 现在不是“legacy 例外”，而是把 `add_` 加回白名单；任何新 `add_*` 都能过。应改为精确 legacy 名单（`add_player_money`）+ 既有 `director_action` 校验。 |
| D2 | `effect` 允许 L2（跟 §7.3 工具表，而不是 §6 的“effect⇒L3/L4”） | **设计更新 + 校验器收紧** | P1 | 工具表确实把 `set_weather` 等标为 effect/L2，设计 §6 自相矛盾；但不能停在“表格赢”。至少禁止 effect/L1，并要求 effect/L2 满足审批或 undo 条件；同步改 §6 和 `TOOLS.md:60`。 |
| D3 | `http.query` 隐式映射（registry 不写 query map，facade 按同名参数拼 query） | **保留** | P2 | `_query_pairs()` 有注释说明，且显式 `http.query` 已被 validator 和运行时支持；当前所有 read 参数与 wire 名一致。建议加测试：每个 read 参数要么同名、要么在 `http.query` 显式声明，防止未来改名时静默拼错。 |
| D4 | 未做 per-field untrusted 包裹 | **修（或明确降级并删承诺）** | P1 | 这是设计 §9.1 的核心防线；当前 `instructions` 已向模型承诺 `untrusted:true`，但实际没有字段被标注。最小修复：facade 对 `pii.untrusted_fields` 包裹 + `meta.untrusted_fields`；否则删除承诺并登记为已知风险。 |
| D5 | 没有独立 connect timeout（只有一个 urllib timeout） | **保留/记录** | P2 | 设计写“连接 1s + 读 4s”，但单 timeout 已能限制总时长，且不是安全边界；在文档里改成“单次操作 timeout”即可，不必为 M0 引入自定义 transport。 |
| D6 | Lua 生成表未接入 `policy.lua`（D7 未做） | **保留/记录** | P2 | 本 commit 只到 D3；`fxmanifest` 已加载但 `policy.lua` 仍硬编码 3 个 action。M0 可接受，但不要在 PR/文档中把 Lua 表描述成已生效的“单一事实源”。 |
| D7 | Lua `validate` 语义弱于 Python（pattern/maxItems/integer） | **修（D7 接线前必须）** | P1（当前潜在） | 生成物是“镜像”，却接受空 `citizenid`、带空格/换行的 `idempotency_key`、`1.0`；一旦 `policy.lua` 使用就会绕过。加 pattern 渲染 + 参数化对照测试。 |
| D8 | `rate_limit`/`verify`/`undo` 只有 registry 元数据，运行期未执行 | **记录 + 补文档/测试，或实现** | P2 | 设计 §8.3 明确限流、§6 明确 verify/undo；当前 MCP 只做路由。限流“不是安全边界”，可延后；但 `verify` 的缺失会让“审批后验证”落空，应在 M0 文档里说清由 director 负责，或尽快接上。 |

**必须修（P1）**：D1、D2、D4、D7。
**记录即可（P2）**：D3、D5、D6、D8（其中 D8 的 verify 部分建议在 M0 发布说明中显式声明）。
**需要设计更新**：D2（§6 与 §7.3 矛盾）、D4（若降级则 §9.1 要改）、D8（若 M0 不做限流则 §8.3 要标注阶段）。

## 5. CI 缺口清单（具体到 step/命令）

当前 CI 覆盖情况：

| 现有 job/step | 是否覆盖新代码 | 说明 |
|:---|:---:|:---|
| `static-checks` → `compileall -q tests`（`T-CityLite.base`） | 部分 | 只编译 `T-CityLite.base/tests`，不编译根 `tools/*.py`、`tests/agent/*.py`。 |
| `unit-tests` → `pytest -q tests/unit` | 是 | 包含 `test_director_http_contract.py`；`lua5.4` 已安装，本地 262 passed / 136 skipped。 |
| `unit-tests` → `pytest -q ../tests/agent` | 是 | 包含 `test_agent_tools.py`，因此 `--check` 与合法性测试会被间接执行。 |
| `lua-syntax` → changed `*.lua` | 是（有条件） | 本 commit 的 `agent_tools.lua`/`fxmanifest.lua` 在 diff 中，`luac5.4 -p` 本地通过；但 `git diff ... || true` 会静默吞掉 diff 失败。 |
| `docs-check` | 否（advisory） | 只打印缺失链接，永远 exit 0；当前有 2 条既有缺失（`PROJECT_PROGRESS.md`、`docs/archive/QBCore_Lite_versions/README.md`），新文件不会让它红。 |

建议新增/修改：

1. **fail-fast 的 registry 检查**（repo root，`static-checks` 或新 job）：
   ```yaml
   - name: Tool registry drift
     run: python3 tools/agent_tools.py --check
   ```
   虽然 `test_committed_artifacts_pass_check` 已间接覆盖，但直接 step 能在
   pytest 收集/依赖失败时仍然给出明确信号。

2. **根 Python 语法检查**（repo root）：
   ```yaml
   - name: Python syntax (agent tools)
     run: python3 -m compileall -q tools tests/agent
   ```

3. **Lua harness 接入 CI**（`T-CityLite.base`，`unit-tests`）：
   ```yaml
   - name: Lua harness (adapter + policy)
     run: python3 -m pytest -q tests/agent
     working-directory: T-CityLite.base
   ```
   这会执行 `tests/agent/test_lua_harness.py` 的 `http_contract`、`http_adapter`
   和 `test_agent_actions_policy.lua`；当前它从未被 CI 调用（`tests/unit` 只覆盖
   policy，不覆盖 `http_adapter`）。

4. **Lua/Python 契约对照测试**（新增 `tests/agent/test_agent_tools_lua_parity.py`
   或放进 `test_agent_tools.py`）：
   ```bash
   lua5.4 -e 'local A=dofile(".../agent_tools.lua"); assert(not A.validate("get_player_snapshot",{citizenid=""}))'
   ```
   CI 已有 `lua5.4`，无需新依赖；建议参数化覆盖
   `citizenid`、`idempotency_key`、`text`、`limit`、`amount`。

5. **负例覆盖**：把 §1.2 的 A1/A2/A3/A4/A5/A6/A7/A9 固化进
   `tests/agent/test_agent_tools.py`，避免本次的 4 个 P1 再次回归。

6. **docs 硬约束**（可选，先修既有 2 条缺失）：
   ```yaml
   - name: Docs links (strict)
     run: python3 tests/check_docs_links.py   # 或把现有 inline 脚本改成 sys.exit(1)
   ```
   并在 `tests/agent` 增加“TOOLS.md 必须被 README/API/ACTIONS 链接”的断言。
   当前 inline docs-check 是 advisory，不能阻止孤立文档（F-18）。

7. **lua-syntax 的健壮性**（可选但建议）：
   - `git fetch --no-tags --depth=50 origin "$base"` 或 `--unshallow`；
   - 把 `git diff ... || true` 改成“失败即 exit 1”，不要静默 skip。
   在单分支浅克隆中，`origin/<base>` 可能不存在，`|| true` 会让整个 job
   以“No Lua changes”退出 0；本仓库当前 `fetch-depth: 0` 大概率能工作，但这是
   一个容易回归的静默跳过点。

8. **触发分支**：`on.push.branches` 只有 `master/dev`；`feat/agent-takeover-v2`
   的 push 不会跑 CI，只能靠 PR。如果希望 worktree 分支也跑，加 `feat/**`，
   或明确“以 PR 为准”。

**Ubuntu + lua5.4 结论**：`test_director_http_contract.py` 在 `tests/unit` 中，
CI 已安装 `lua5.4`，本地可跑通；`tests/agent/lua` 的 `http_contract` 通过
`test_director_http_contract.py` 跑通，`http_adapter` 仅由
`test_lua_harness.py` 驱动，而它不在 CI 路径中——这是实际缺口。

## 6. 文档一致性

| 文档 | 问题 | 关联 |
|:---|:---|:---|
| `TOOLS.md` | `:60` 说 effect 只能是 L3/L4，`:50-52` 表格有 L2 effect；同一文件自相矛盾。 | F-05 |
| `TOOLS.md` | 未被 `README.md`/`API.md`/`ACTIONS.md` 链接；设计 D9 未完成。 | F-18 |
| `API.md` | `:410-418` 只列 5 个 read 工具；`:476-477` 说“MCP exposes only the five read tools / No write endpoints”。与 `TOOLS.md` 的 13 active（含 3 个写）直接冲突。 | F-10 |
| `ACTIONS.md` | `:18-24` 只列 `notify/add_money/start_quest`，`:288` 的 action_type 也只有 3 个；`:409` 仍把 L2+ 列为 out of scope。`TOOLS.md` 有 7 个 planned（含 L2/L3/L4）。严格说不是“已实现”的矛盾，但文档没有说明“planned 尚未进 policy.lua”，容易误读。 | F-13 |
| `design/03-tool-contract.md` | `:15`（L2 默认审批）与 `:144`/`:153`（effect⇒L3/L4）互相矛盾；`:245` 要求 `http.query`，registry 实际隐式映射；`:284-296` 的 untrusted 未实现。 | D2/D3/D4 |
| docs-check | 当前 2 条既有缺失：`PROJECT_PROGRESS.md: ./quest-system-design.md`、`docs/archive/QBCore_Lite_versions/README.md: ../quest-system-design.md`；脚本只打印、不 exit 1，所以不会因为新文件变红。 | F-18 |

## 7. 复现命令（最小集）

### 7.1 负例 / 放行例的通用方法

```bash
set -e
R=/home/swk/Documents/deepseek-harness/default-workspace/T-City-agent
T=$(mktemp -d)
git -C "$R" archive HEAD | tar -x -C "$T"
python3 - "$T" <<'PY'
import copy, json, sys
from pathlib import Path
root = Path(sys.argv[1])
reg = json.loads((root/"tools/agent_tools.json").read_text())
def tool(name):
    return next(t for t in reg["tools"] if t["name"] == name)

# 例 A1：effect/L2 + requires_approval=false
tool("send_announce")["requires_approval"] = False

# 例 A2：新增 add_ 工具
t = copy.deepcopy(tool("send_notify"))
t["name"] = "add_world_notice"
t["director_action"] = "announce_world"
reg["tools"].append(t)

# 例 F-06：verify 漏掉必填参数
tool("add_player_money")["verify"]["args"] = {}

(root/"tools/agent_tools.json").write_text(json.dumps(reg, indent=2) + "\n")
PY
cd "$T"
python3 tools/agent_tools.py --write
python3 tools/agent_tools.py --check
echo "check rc=$?"   # 对 A1/A2/A3 观察是否为 0
```

> 每次只改一个变异；上例把三个变异写在一起，实际实验应分开跑，才能把
> “接受/拒绝”归因到单条规则。

### 7.2 Lua 对照

```bash
cat >/tmp/check_lua.lua <<'LUA'
local AT = dofile(arg[1])
local cases = {
  {"snapshot empty", "get_player_snapshot", {citizenid=""}},
  {"snapshot space", "get_player_snapshot", {citizenid="bad citizen"}},
  {"idem space", "send_notify", {citizenid="ABC12345", text="hi", idempotency_key="has space"}},
  {"text 301", "send_notify", {citizenid="ABC12345", text=string.rep("x",301)}},
  {"limit 201", "query_players", {limit=201}},
}
for _, c in ipairs(cases) do
  local ok, err = AT.validate(c[2], c[3])
  print(c[1], ok, err)
end
LUA
lua5.4 /tmp/check_lua.lua \
  "$R/T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua"
```

### 7.3 CI 等价命令

```bash
cd "$R/T-CityLite.base"
python3 -m compileall -q tests
python3 -m pytest -q tests/unit
python3 -m pytest -q ../tests/agent
python3 -m pytest -q tests/agent/test_lua_harness.py   # 当前 CI 没跑
cd "$R"
python3 tools/agent_tools.py --check                   # 当前 CI 没有显式 step
```

## 8. 最终判定

- **P0：0**。当前 active 工具没有发现可直接触发的越权/执行漏洞。
- **P1：4**（F-01 命名 `add_`、F-02 effect 审批、F-03 untrusted、F-04 Lua 语义）。
- **P2：14**（F-05–F-18；含 CI、文档、潜在运行期缺口）。
- **最严重**：F-03（untrusted 未实现但 `instructions` 已承诺）——它是当前
  read 数据进入模型上下文的真实安全缺口；F-01/F-02 是契约层最严重的两个
  “不变量未真正生效”问题。
- **建议**：**不要按当前状态合并**。先修 F-01/F-02/F-03，并把 F-04 作为
  D7 的 gate；F-05/F-06/F-07/F-08/F-09 建议一并补校验与测试；F-10–F-18
  可随 PR 记录并排期。修完 P1 后此 commit 的生成链和主要不变量质量是好的，
  可以合并。
