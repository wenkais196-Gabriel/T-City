---
id: base-agent-reviews-05-live-tools
type: audit
status: final
system: agent
owner: hermes
updated: 2026-10-25
---

# 05 — Live tools / `auth` / 游标对抗性评审（`e8df70a`）

- **评审对象**：`feat/agent-takeover-v2` @ `e8df70a`（`feat(agent): expose live perception as three MCP read tools`）
- **基线**：`fe76857`（M1 live endpoints）；范围 `tools/agent_tools.json`、`tools/agent_tools.py`、`tools/agent_mcp.py`、`tests/agent/test_agent_*.py`、`resources/[custom]/custom-director/shared/agent_tools.lua`、`docs/agent/TOOLS.md`
- **评审日期**：2026-10-22
- **结论**：**需修（needs fix）** — 0×P0、2×P1、8×P2。没有鉴权绕过，但在“只读凭证与写凭证分离”和“契约版本”两处声称与实现不一致；当前状态**不建议合并**。
- **行号**：全部以 `e8df70a` 为准。评审期间没有修改任何被 git 跟踪的文件（只新增本文件）；`--write` 后 `git status` 仍只有本 review 一个未跟踪文件。

---

## 1. 基线与方法

在干净 checkout（`/home/.../T-City-agent`）上：

```bash
python3 -m pytest -q tests/agent
# 124 passed, 3 skipped, 362 subtests passed
python3 tools/agent_tools.py --check
# agent_tools: OK (23 tools, 2 generated files match)
luac5.4 -p 'T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua'
lua5.4 T-CityLite.base/tests/agent/lua/runner.lua
# 4 suites, 19 + 10 + 10 + 20 cases, failed=0
```

`--write` 幂等性：再次 `--write` 后两个生成物 sha256 不变，`--check` 仍 OK（命令见 `§7`）。

变异测试与 Lua/Python 对比在**最小副本**里做，避免动仓库：

```bash
mkdir -p /tmp/tcity-min
git archive e8df70a tools tests/agent | tar -x -C /tmp/tcity-min
# 再补两个生成物：
git show e8df70a:T-CityLite.base/docs/agent/TOOLS.md > /tmp/tcity-min/T-CityLite.base/docs/agent/TOOLS.md
git show 'e8df70a:T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua' \
  > "/tmp/tcity-min/T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua"
cd /tmp/tcity-min
python3 -m pytest -q tests/agent/test_agent_tools.py tests/agent/test_agent_contract.py \
  tests/agent/test_agent_mcp_routing.py
# 107 passed, 331 subtests passed
```

> 说明：最小副本缺少 DB fixture，`test_agent_data.py` / `test_agent_mcp.py` 各有一条与本提交无关的失败；变异只跑上面三个文件。评审期间 `/tmp` 一度触发 EDQUOT（`/tmp` 只有 1.7G，整仓副本太大），已删除所有副本，最终环境干净。

---

## 2. 结论

- **没有 P0**：没有发现“无 token 也能调用”“`auth` 直接跳过鉴权”“`citizenid`/`since` 注入到别的端点”的可利用路径。隐藏的 live 工具即使被点名调用也会在 `_call_director` 处因无配置返回 `unauthorized`，网络调用数为 0。
- **2 个 P1** 都落在“声称的安全/契约属性没有闭环”：
  1. **L1** `AGENT_LIVE_TOKEN` 回退 `AGENT_DIRECTOR_TOKEN` 让 live 读复用写凭证，直接推翻设计 01 §5.2“独立 token，不复用”的前提；
  2. **L2** 新增 3 个 active 工具却保持 `registry_version = 1.0.0`，违反 design 03:53“minor = 新增/启停工具”。
- **8 个 P2** 是 `auth` 校验收敛、响应归一、untrusted 路径、游标语法、生成器等价性、错误恢复和文档/测试缺口。
- 生成物本身**当前**是干净的（`--check`、`--write` 幂等、Lua 可编译、59 个 Lua case 全绿）；问题在“生成器对未来 pattern 的承诺”和“Lua 校验器从未被真正执行”。

---

## 3. 发现表

| ID | 严重度 | 文件:行 | 问题 | 复现 | 建议 |
|:--|:--|:--|:--|:--|:--|
| **L1** | **P1** | `tools/agent_mcp.py:156-167`；`.../live_api.lua:73-80`；`design/01-live-perception.md:198` | live 读在没有 `AGENT_LIVE_TOKEN` 时回退到 `AGENT_DIRECTOR_TOKEN`。单 token 部署下“只读凭证”就是“写凭证”，设计明确禁止的“读凭证泄漏 → 可加钱”重新成立；若服务端按设计配了独立 `agent_live_token`、facade 只配 director token，facade 还会**广告 3 个必然 401 的工具** | `§4 L1` | 默认要求 `AGENT_LIVE_TOKEN`；兼容回退改成显式开关（如 `AGENT_LIVE_ALLOW_SHARED_TOKEN=1`）并打印警告；Lua 侧 `agent_live_token` 同样加显式开关；改掉两个“回退”测试 |
| **L2** | **P1** | `tools/agent_tools.json:4`；`TOOLS.md:4`；`tests/agent/test_agent_contract.py:236`；`design/03-tool-contract.md:53` | 20 → 23 个工具、新增 3 个 active，`registry_version` 仍是 `1.0.0`；测试把旧版本硬编码，CI 反而锁死了这个错误。按 design 03 的 semver 规则应升 `1.1.0` | `§4 L2` | 升 `1.1.0`，重新生成 TOOLS.md，测试改为从 registry 读版本或断言 `1.1.0`；在 PR 描述里记录 minor bump |
| **L3** | P2 | `tools/agent_tools.py:476-486`；`tools/agent_mcp.py:528-533, 694-697` | `auth=live` 只校验 `channel=read` + `route=director`，**不校验 `http.path` 必须是 `/agent/v1/live/`**。给 `get_action`/`list_actions` 加 `auth=live` 能通过校验，并把 live token 发到 `/agent/v1/actions*`；提交说明里“cannot be used to smuggle a second credential path elsewhere”不成立 | `§4 L3` | 增加 `http.path.startswith("/agent/v1/live/")`（或给 `auth` 绑定 endpoint 白名单）；补 `get_action`/`list_actions` 的反例测试 |
| **L4** | P2 | `tools/agent_mcp.py:802-854` | director 归一化先看 `action`/`actions`/`ok`，最后才走 live 的“整包 data”回退。live body 若有顶层 `action`，`data` 变成 `"player.kick"`，其余字段全丢；有 `ok:true,idempotent:true` 会被判成 `idempotent_replay`。提交说明“cannot mistake them for an action result”只在当前三个 endpoint 的字段形状下成立 | `§4 L4` | 对 `auth=live`（或新增 `response_shape:"payload"`）先短路到整包 data，再做通用 director 分支；补“live body 带 action/ok”测试 |
| **L5** | P2 | `tools/agent_mcp.py:744-770`；`tools/agent_tools.json:477-479, 525-527, 577-580` | `pii.untrusted_fields` 按**键名**在任意深度匹配，导致假阳性：`players.0.job.name`、`players.0.gang.name` 被标成玩家可控文本（实际是服务端 job/gang 配置）。该字段无法表达“只要 player 的 name” | `§4 L5` | 支持路径模板（`players[].name`）或只在指定层级匹配；至少排除 job/gang 下的 `name`；`list_live_events` 的 `returns_pii:false` 与 `name/payload` 的标注需说明 |
| **L6** | P2 | `tools/agent_tools.json:561-565`；`tools/agent_tools.py:1067`；`live_store.lua:76-86` | 游标契约三层不一致：① Lua `ParseCursor` 明确接受纯 seq（`"8841"`，注释引用 design 01 §4.3），registry 只接受 `epoch:seq`；② Python `\d` 是 Unicode 语义，Lua `chars="0123456789"` 只认 ASCII，`"١:٢"`/`"１:２"` Python 过、Lua 拒；③ Python 允许 `"0000000001:..."` 这种必 409 的前导零 epoch | `§4 L6` | 统一成 `[0-9]`；明确是否支持纯 seq（支持就加 `^\d{1,9}$` 备选，不支持就改 Lua 注释/设计）；补跨语言矩阵测试 |
| **L7** | P2 | `tools/agent_tools.py:156-195, 630, 1301-1319, 1358-1387` | `parse_segmented_pattern` 接受“相邻数字段”，但 `segmentsMatch` 对“非末尾且下一段不是 literal”的段用 `#value+1` 作 stop，后续段长度为 0，永远 false。实测 `^\d{1,2}:\d{1,3}\d{1,2}$` 通过 registry 校验，Python 匹配 `"12:3456"`，Lua 永远拒绝：生成器把“Lua 不可表达”的 pattern 放行了 | `§4 L7` | 只接受严格交替形状（digit → 至少一个 `:` literal → digit…），或直接限定为当前唯一用例 `^\d{1,9}(:\d{1,9})+$`；加“渲染后在 Lua 里实跑”的生成器测试 |
| **L8** | P2 | `tests/agent/test_agent_tools.py:368-380, 440-458`；`T-CityLite.base/tests/agent/lua/runner.lua` | 没有任何测试**执行**生成的 `agent_tools.lua`：只做字节比对 + `luac -p`。变异 M7b 删掉 `rule.segments` 校验并 `--write` 后，107 个测试全绿，而 Lua 校验器已开始接受 `"1:2:3"`；同理 M3（live action 误判）、M8（live token 解锁写工具）也全部存活 | `§6` | 新增 Lua case `agent_tools.lua`（游标/参数正反例），并让 Python 测试在 `lua5.4` 可用时实跑对比；补 action/ok 污染与 live-token-only 写工具两条 Python 测试 |
| **L9** | P2 | `tools/agent_mcp.py:405-427`；`live_api.lua:344-350`；`design/01-live-perception.md:166` | `_http_error` 只读 body，丢掉响应头；`cursor_epoch_mismatch` 的 `X-Agent-Live-Epoch` 到不了 agent，`ToolCallError` 也没有 headers/epoch 字段。设计要求 409 body 带 `epoch/oldest_seq/newest_seq`，实现只在 header 给 epoch，MCP 再丢 header → 只知道 409，无法重建游标 | `§4 L9` | `ToolCallError` 增加 `headers`/`live_epoch`，409/410 时把 `X-Agent-Live-Epoch` 放进 `meta.live_epoch`（或 `retry_cursor`）；补 HTTPError+headers 测试 |
| **L10** | P2 | `design/03-tool-contract.md:318-351, 280`；`agent_tools.py:1239-1337`；`TOOLS.md`；`.env.example:26`；`agent_mcp.py:224-254` | `auth` 没进契约：design 03 §10.1 的 tool schema 是 `additionalProperties:false` 且没有 `auth`；TOOLS.md 没有 auth 列；Lua mirror 不输出 `auth`；`_meta` 不暴露 auth；`.env.example` 没有 `AGENT_LIVE_TOKEN`。另外 design 03:280 仍写 `AGENT_TOOLSET=all`=全列，而实现会隐藏无 token 的 live 工具 | `§4 L10` | schema 加 `"auth":{"enum":["default","live"],"default":"default"}`；§8.5 补 env；TOOLS.md 加 Auth 列；Lua descriptor 可选地带 `auth`；更新 all 语义文档；`.env.example` 补四个 AGENT_* 变量 |

---

## 4. 逐条复现

> 以下命令都在 `/tmp/tcity-min`（`§1` 的最小副本）里执行，`sys.path.insert(0,"tools")`。行号对应 `e8df70a`。

### L1 — live token 回退到写 token（P1）

代码：`tools/agent_mcp.py:156-167`

```python
def _live_config() -> tuple[str, str] | None:
    url = _env("AGENT_DIRECTOR_URL").rstrip("/")
    token = _env("AGENT_LIVE_TOKEN") or _env("AGENT_DIRECTOR_TOKEN")
    ...
```

```python
import os, sys, json
from unittest import mock
sys.path.insert(0,'tools'); import agent_mcp
class R:
    def __init__(s,b): s._b=json.dumps(b).encode()
    def read(s): return s._b
    def __enter__(s): return s
    def __exit__(s,*a): return False

env={"AGENT_DIRECTOR_URL":"http://dir.test","AGENT_DIRECTOR_TOKEN":"write"}
with mock.patch.dict(os.environ, env, clear=True), mock.patch('agent_mcp.urllib.request.urlopen') as m:
    m.return_value=R({"schema_version":1,"players":[],"count":0,"sampled_at":1,"precision_m":25})
    res=agent_mcp.handle_message({"jsonrpc":"2.0","id":1,"method":"tools/call",
                                  "params":{"name":"get_live_players","arguments":{}}})["result"]
    req=m.call_args[0][0]
    print(req.get_header("Authorization"), req.full_url, res["isError"])
# Bearer write http://dir.test/agent/v1/live/players False
```

同一环境 `_visible_tools()` 名单：

```
gateway-only   n= 8 live=[]
director-only  n= 8 live=['get_live_player','get_live_players','list_live_events']
live-only      n= 3 live=['get_live_player','get_live_players','list_live_events']
both           n= 8 live=['get_live_player','get_live_players','list_live_events']
all,no-token   n=13 live=[]
all,live-only  n=16 live=['get_live_player','get_live_players','list_live_events']
```

设计原文（`design/01-live-perception.md:198`）：

> Token | **独立** `agent_live_token`，不复用 `agent_actions_token`：只读凭证泄漏不应导致可加钱；可独立轮换

Lua 侧 `live_api.lua:73-80` 同样回退到 `cfg.token`，且 Lua case `actions_token_fallback`（`T-CityLite.base/tests/agent/lua/cases/live_api.lua:258`）与 Python `test_director_token_fallback_advertises_the_live_tools`（`tests/agent/test_agent_mcp_routing.py:589`）**把回退行为固化了**。这不是本提交首创，但本提交把 facade 接到了同一条路径上，并把它当作“keep live reads visible”的兼容特性；按设计这是 P1，不是“可接受偏差”。

补充（静态推断，服务端 `authorized` 只和 `live.token` 比较）：若服务端按设计设置 `agent_live_token=secret`、facade 只给 `AGENT_DIRECTOR_TOKEN=write`，facade 会广告 live 工具，但每次调用都会被服务端 401。也就是说回退在最安全的部署里制造“可见但不可用”，在最省事的部署里制造“读写同权”。

### L2 — registry_version 未升（P1）

```bash
cd /tmp/tcity-min && python3 - <<'PY'
import json
r=json.load(open('tools/agent_tools.json'))
print(r['registry_version'], len(r['tools']))
PY
# 1.0.0 23
```

`design/03-tool-contract.md:53`：

> `registry_version` | registry 顶层 | semver：major=结构破坏，minor=新增/启停工具，patch=描述/limits

`tests/agent/test_agent_contract.py:236` 断言 `1.0.0`，`test_agent_tools.py:79` 只断言格式，所以 CI 不会提醒。网关 `/agent/v1/tools` 与 `TOOLS.md` 也继续声称 `1.0.0`（`TOOLS.md:4`）。

### L3 — `auth=live` 只按 route 收敛（P2）

```bash
cd /tmp/tcity-min && python3 - <<'PY'
import sys, json
sys.path.insert(0,'tools'); import agent_tools
reg=agent_tools.load_registry()
for name in ('get_action','list_actions'):
    m=json.loads(json.dumps(reg)); t=next(x for x in m['tools'] if x['name']==name)
    t['auth']='live'
    print(name, agent_tools.validate_registry(m))
m=json.loads(json.dumps(reg)); t=next(x for x in m['tools'] if x['name']=='get_action')
t['auth']='live'; t['http']={'method':'GET','path':'/agent/v1/act'}
print('path=/act', agent_tools.validate_registry(m))
PY
# get_action []
# list_actions []
# path=/act []
```

端到端证明（沿用 L1 的假 urlopen，registry 用 `mock.patch("agent_mcp._load_registry")` 注入）：

```python
# get_action(auth=live) -> Bearer live http://dir.test/agent/v1/actions/1 isError False
```

即 live token 确实会被发到 actions 路由。当前出厂 registry 没有这种工具，所以不是可利用漏洞；但提交说明把它当成了安全属性。

### L4 — live body 仍会被误判成动作结果（P2）

```python
tool = next(t for t in agent_tools.load_registry()['tools'] if t['name']=='get_live_players')
for raw in [
  {"schema_version":1,"players":[{"name":"Bob"}],"count":1,"action":"player.kick"},
  {"schema_version":1,"players":[],"count":0,"ok":True,"idempotent":True},
  {"schema_version":1,"players":[],"count":2.0},
]:
    e = agent_mcp._normalize(tool, raw, request_id="r")
    print(e['kind'], repr(e['data']), e['meta'].get('count'))
# ok 'player.kick' None
# idempotent_replay {'schema_version': 1, 'players': [], 'count': 0, 'ok': True, 'idempotent': True} None
# ok {'schema_version': 1, 'players': [], 'count': 2.0} None
```

端到端 `tools/call` 同样返回 `data="player.kick"`。当前 `/agent/v1/live/players` 不产出顶层 `action`/`ok`，所以是潜在问题；但 MCP 的职责正是隔离上游形状，靠“字段恰好不叫 action”不是不变量。

### L5 — untrusted 路径假阳性（P2）

```python
payload = {"schema_version":1,"players":[{"citizenid":"ABC123","name":"Bob",
           "job":{"name":"police"},"gang":{"name":"none"}}],"count":1}
agent_mcp._untrusted_paths(tool, payload)
# ['players.0.name', 'players.0.job.name', 'players.0.gang.name']
```

`job.name` / `gang.name` 来自服务端 job/gang 配置，不是玩家可控文本。`get_live_player` 的 `player.job.name` 同理。当前测试只断言 `name in untrusted_fields` 与 `players.0.name`，没有覆盖假阳性。

另：`list_live_events` 的 `pii.returns_pii=false` 但 `untrusted_fields=["name","payload"]`；事件 payload 里可有玩家名/金额。不一定是 PII 违规，但字段语义需要说明（见 L10）。

### L6 — 游标契约不一致（P2）

Python vs Lua 25 组正反例（`lua5.4` 实跑，完整脚本见 §6 之前的命令）：

```
ok    0 py=True  lua=True  '1:1'
ok    1 py=True  lua=True  '1761136800:8841'
ok    2 py=True  lua=True  '9999999999:999999999'
ok    3 py=True  lua=True  '0000000001:000000001'
ok    4 py=False lua=False '12345678901:1'
ok    5 py=False lua=False '1:1234567890'
ok    6 py=False lua=False '1:2:3'
ok    7 py=False lua=False 'abc:1'
ok   10 py=False lua=False ':1'
ok   13 py=False lua=False '1:2 '
DIFF 14 py=True  lua=False '١:٢'      # Arabic-Indic digits
DIFF 20 py=True  lua=False '１:２'      # fullwidth digits
ok   23 py=True  lua=True  '01:02'
ok   24 py=True  lua=True  '1:000000000'
```

（其余 `1:abc`、`1:`、空串、前后空格、`1.2:3`、`-1:2`、`1:2\n`、`1::2` 均双方 false；`0:0`、`1234567890:1`、`1:12345678901` 等边界见下。）

完整对比脚本（25 组，`/tmp` 内自包含）：

```bash
cd /tmp/tcity-min
cat > /tmp/cmp.lua <<'LUA'
local A = dofile('T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua')
for line in io.lines('/tmp/cases.hex') do
  local i, hex = line:match('^(%d+)\t([0-9a-f]*)$')
  local b = {}
  for p in hex:gmatch('%x%x') do b[#b+1] = string.char(tonumber(p,16)) end
  print(i .. '\t' .. tostring(A.validate('list_live_events', { since = table.concat(b) })))
end
LUA
python3 - <<'PY'
import sys, re, subprocess
sys.path.insert(0,'tools'); import agent_tools
cases = ["1:1","1761136800:8841","9999999999:999999999","0000000001:000000001",
 "12345678901:1","1:1234567890","1:2:3","abc:1","1:abc","1:",":1","",
 " 1:2","1:2 ","\u0661:\u0662","1.2:3","-1:2","0:0","1:2\n","1::2",
 "\uff11:\uff12","1234567890:1","1:12345678901","01:02","1:000000000"]
open('/tmp/cases.hex','w').write(''.join(f"{i}\t{s.encode().hex()}\n" for i,s in enumerate(cases)))
pat = next(t for t in agent_tools.load_registry()['tools']
           if t['name']=='list_live_events')['inputSchema']['properties']['since']['pattern']
out = subprocess.run(['lua5.4','/tmp/cmp.lua'],capture_output=True,text=True).stdout
lua = {int(l.split('\t')[0]): l.split('\t')[1]=='true' for l in out.splitlines()}
print([(s, bool(re.fullmatch(pat,s)), lua[i]) for i,s in enumerate(cases)
       if bool(re.fullmatch(pat,s)) != lua[i]])
PY
# [('١:٢', True, False), ('１:２', True, False)]
```

纯 seq 的差异更实际：

```bash
cd /tmp/tcity-min && lua5.4 /tmp/lua_compare.lua | tail -6
# cursor 8841                     ok seq=8841
# cursor 1761136800:8841          ok seq=8841
# cursor abc:1                    ok seq=1
# cursor 0000000001:000000001     ok seq=1
# cursor +1:2                     ok seq=2
```

`LiveStore:ParseCursor`（`live_store.lua:76-86`）明确支持纯 seq，注释写“design 01 §4.3”；registry 的 `since` pattern 只允许 `epoch:seq`，所以 agent 拿到 `event.seq` 或 `X-Agent-Live-Seq` 后不能直接当 `since` 用。Python 的 `\d` 还接受 Unicode 数字，最终由 Lua 400，属于“客户端放行、服务端拒绝”的跨层不一致。

超长/前导零/时区：`since` 是纯游标，不含时区（`sampled_at`/`last_seen_ms` 是 epoch ms，与 `since` 无关）；Lua `tonumber` 会把 `1:99999999999999999999` 收成 `1e+20`，但 registry 的 9 位上限让它在 Python 侧先被拒；`01:02` 会通过 Python，但 epoch `01` 永不等于服务端 `os.time()`，最终 409。前导零因此是“能过校验但必失败”的输入，不是安全洞。

更根本的是三方对“游标长什么样”没有共识：

- **设计 01 §4.3**（`design/01-live-perception.md:163`）：`v1:<8 位 hex epoch>:<seq>`，并允许纯数字 `since=1024`；
- **M1 实现**（`live_store.lua:70-86, 119-121`）：`<os.time() 十进制>:<seq>`，也接受纯 seq，但**不接受** `v1:...`（两个冒号直接 `invalid_cursor`）；
- **本提交 registry**（`agent_tools.json:561-565`）：只接受 `<1-10 位十进制>:<1-9 位十进制>`，既拒绝 `v1:deadbeef:1`，也拒绝纯 seq。

实测：`v1:1761136800:1`、`v1:deadbeef:1` 在 Python 和 Lua 两侧都是 invalid。registry 跟的是 M1 实现而不是设计；这本身可以接受（实现更新），但设计 01:163 与 `live_api.lua:4` 的“frozen contract”注释必须改一处，否则下一个客户端按设计实现就会全量失败。

### L7 — 分段生成器接受 Lua 不能等价表达的 pattern（P2）

```bash
cd /tmp/tcity-min && python3 - <<'PY'
import sys, json, re
sys.path.insert(0,'tools'); import agent_tools
p=r'^\d{1,2}:\d{1,3}\d{1,2}$'
print(agent_tools.parse_segmented_pattern(p))
reg=agent_tools.load_registry(); t=next(x for x in reg['tools'] if x['name']=='list_live_events')
t['inputSchema']['properties']['since']['pattern']=p
print(agent_tools.validate_registry(reg))
open('/tmp/adj.lua','w').write(agent_tools.render_lua(reg))
print(bool(re.fullmatch(p,'12:3456')))
PY
# [('0123456789',1,2,False), (':',1,1,True), ('0123456789',1,3,False), ('0123456789',1,2,False)]
# []
# True
cat > /tmp/adj_check.lua <<'LUA'
local A = dofile('/tmp/adj.lua')
print('adj', tostring(A.validate('list_live_events', { since = '12:3456' })))
LUA
lua5.4 /tmp/adj_check.lua
# adj false
```

`segmentsMatch` 对“下一段不是 literal”的非末尾段用 `stop=#value+1`，后续段长度必为 0，所以 Lua 永远 false。当前 registry 只有 `^\d{1,10}:\d{1,9}$`，不触发；但 `_validate_input_schema` 的职责就是“只放行 Lua 可表达的 pattern”，这个洞把该保证打破了。

### L8 — 生成物校验器从未被执行（P2，测试有效性）

变异 M7b：删除 `render_lua` 中

```python
"      if rule.segments and not segmentsMatch(rule.segments, value) then",
"        return false, 'invalid_params'",
"      end",
```

然后 `python3 tools/agent_tools.py --write`，再跑 107 个测试：

```
107 passed, 331 subtests passed
```

而生成物已经不再校验游标：

```bash
cat > /tmp/m7b_check.lua <<'LUA'
local A = dofile('/tmp/mut/m7b/T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua')
for _, v in ipairs({'1:2:3','12345678901:1','1761136800:8841'}) do
  print(string.format('%q -> %s', v, tostring(A.validate('list_live_events', { since = v }))))
end
LUA
lua5.4 /tmp/m7b_check.lua
# "1:2:3" -> true
# "12345678901:1" -> true
# "1761136800:8841" -> true
```

原因：`test_generated_artifacts_match_renderers` 只比较“文件 == renderer 输出”，`test_generated_lua_compiles` 只做 `luac -p`；`T-CityLite.base/tests/agent/lua/runner.lua` 没有加载 `agent_tools.lua`。所以“生成器 + 生成物”可以一起坏掉而全绿。

### L9 — 409 的 epoch 头被丢弃（P2）

```bash
cd /tmp/tcity-min && python3 - <<'PY'
import sys, io, json, urllib.error
sys.path.insert(0,'tools'); import agent_mcp
body=json.dumps({"error":"cursor epoch does not match","code":"cursor_epoch_mismatch"}).encode()
hdr={"X-Agent-Live-Epoch":"1761136800","Content-Type":"application/json"}
exc=urllib.error.HTTPError("http://dir.test/agent/v1/live/events",409,"Conflict",hdr,io.BytesIO(body))
e=agent_mcp._http_error(exc,"director")
print(e.code, e.status, hasattr(e,"epoch"), e.retry_after_ms)
PY
# cursor_epoch_mismatch 409 False None
```

`agent_mcp.py:405-427` 只解析 body；`live_api.lua:344-347` 把新 epoch 放在 `X-Agent-Live-Epoch`。设计 01:166 本来要求 409 body 带 `epoch/oldest_seq/newest_seq`，实现把 epoch 挪到 header、body 只剩 `{error,code}`；MCP 又丢掉 header，于是 agent 连 `epoch`/`oldest_seq`/`newest_seq` 都拿不到，重建路径在 MCP 侧彻底断了。

### L10 — `auth` 未进入契约/文档/生成物（P2）

- `design/03-tool-contract.md:318-351` 的 `$defs.tool` 是 `additionalProperties:false`，属性表里没有 `auth`；现在 registry 的 3 个 live 工具都有 `"auth":"live"`（`agent_tools.json:448,500,548`），用该 schema 校验会失败。
- `render_lua` 不输出 `auth`（`agent_tools.py:1239-1337`）；`AgentTools.TOOLS[...]` 里没有 auth，Lua policy 无法知道 live 工具需要另一份凭证。
- `TOOLS.md` 的 routing/risk 表没有 Auth 列，operator 看不出哪 3 个工具需要 `AGENT_LIVE_TOKEN`。
- `_tool_descriptor` 的 `_meta` 只有 risk/channel/route/...（`agent_mcp.py:224-254`），客户端无法发现 auth。
- `.env.example` 只有 `AGENT_TOKEN`，没有 `AGENT_GATEWAY_*` / `AGENT_DIRECTOR_*` / `AGENT_LIVE_TOKEN`。
- `design/03-tool-contract.md:280` 仍写 `all`=全列；实现（`agent_mcp.py:271-274`）在无 live token 时连 `all` 也隐藏。这个行为更安全，但设计/文档没跟上，且 `test_debug_toolset_still_hides_live_tools_without_a_token` 把它固化成了新契约。

---

## 5. `auth` 字段裁决

**设计成立。** 把“只读 live 感知”与“写/效果”分到两个凭证、并让工具声明 `auth: live`，是对现有 `route/channel` 模型的最小扩展；`default` 作为缺省值也保持了向后兼容。实现上两个必要条件都做了：

- 可见性：`_visible_tools` 在 `auto/read/all` 三种 toolset 下都要求 live 配置存在（`agent_mcp.py:265-278`）；
- 可调用性：`_callable_here` → `_route_available` 对 `auth=live` 要求 `_live_config()`，`_call_director` 再次检查配置（`agent_mcp.py:257-262, 694-697`）。**没有“用 auth 跳过 token”的路径**；`AGENT_TOOLSET=all` 且无 token 时，工具不列出、点名调用也 `unauthorized`、网络 0 次（实测）。

但**需要文档更新 + 一处校验收紧**，否则“auth 是安全边界”只是注释：

1. **凭证回退必须显式化**（L1）：`AGENT_LIVE_TOKEN or AGENT_DIRECTOR_TOKEN` 让 `auth=live` 的语义从“独立凭证”退化成“有 director token 就行”。建议默认不允许回退；若必须兼容，用显式 `AGENT_LIVE_ALLOW_SHARED_TOKEN=1`，并在启动日志/文档里写清“此时 live 读凭证 = 写凭证”。
2. **校验绑定 endpoint，而不是 route**（L3）：`auth=live` 应要求 `http.path` 以 `/agent/v1/live/` 开头（并建议要求 `method=GET`）。否则“不能把第二份凭证带到别处”的承诺不成立。
3. **补契约**（L10）：design 03 §10.1 加 `auth`，§8.5 加 `AGENT_LIVE_TOKEN`/回退策略，TOOLS.md 加 Auth 列，`.env.example` 补变量；Lua mirror 可选输出 `auth`（即使 policy 不用，也应保持“契约镜像”完整）。
4. **暴露给客户端可选**：在 `_meta` 加 `"t-city/auth": "live"` 是低成本改进，能让 Hub/日志区分“这次调用用了哪份凭证”。
5. **`AGENT_TOOLSET=all` 的语义**：如果坚持“all 也不广告无凭证的 live 工具”，请在 design 03:280 改成“all = 全列可路由工具；live 仍需独立凭证”，否则实现与设计继续各说各话。

一句话：**auth 的设计成立，不需要推倒；需要把“独立凭证”从注释变成默认行为，并把字段写进契约与生成物。**

---

## 6. 变异测试（测试有效性）

基线（最小副本）：`107 passed, 331 subtests passed`。每条变异只改最小副本，不动仓库。

| # | 变异 | 预期 | 实际 | 结论 |
|:--|:--|:--|:--|:--|
| M1 | 删除 `_visible_tools` 的 live 门 + `_route_available` 的 live 分支改为 `return True` | 可见性/调用测试红 | 3 红：`test_live_tools_need_the_live_token_to_be_advertised`、`test_debug_toolset_still_hides_live_tools_without_a_token`、`test_missing_gateway_token_hides_reads` | ✅ 有效；`test_hidden_live_tool_cannot_be_called` 仍绿，因为 `_call_director` 独立检查配置（这是好的纵深） |
| M2 | 删掉 `_validate_tool` 的 `channel != "read"` 检查（允许 write 用 auth=live） | registry 测试红 | 1 红：`test_live_auth_is_rejected_on_write_tools` | ✅ |
| M3 | 在 `_normalize` 的 director 分支前加“live 且 `action` 存在 → 返回 action” | live 测试红 | **0 红** | ❌ 覆盖缺口（L4） |
| M3b | 把 live 回退的 `data=raw` 改成 `data=raw.get("data")` | 整包 body 测试红 | 4 红（3 个 live + write routing） | ✅ |
| M4 | 删除 `validate_arguments` 的 `re.fullmatch` 检查 | 游标/pattern 测试红 | 5 红（含 4 个 cursor subtest + `test_argument_type_enum_pattern_and_bounds`） | ✅ |
| M5 | `_live_config` 只用 `AGENT_DIRECTOR_TOKEN`（忽略 live token） | live token 测试红 | 4 红（3 个 live + visibility） | ✅ |
| M6 | 删掉 `route != "director"` 检查 | gateway auth 测试红 | 1 红：`test_live_auth_is_rejected_on_gateway_reads` | ✅ |
| M7b | 删除 `rule.segments` 校验并 `--write` | Lua 游标测试红 | **0 红**；Lua 实跑 `"1:2:3" -> true` | ❌ 覆盖缺口（L8） |
| M8 | `_director_config` 接受 `AGENT_LIVE_TOKEN`（写工具可用 live token） | 凭证分离测试红 | **0 红**；live-token-only 列出 8 个工具（含 `add_player_money`/`send_notify`） | ❌ 覆盖缺口（L1 的反方向） |

结论：M1/M2/M4/M5/M6/M3b 说明现有测试对“显式断言过的路径”是有效的；三个存活变异正好对应本 review 的三类盲区——**live 响应形状污染**、**Lua 校验器实际行为**、**live token 反向解锁写工具**。建议把 M3/M7b/M8 作为新测试的模板。

三个存活变异的关键片段（其余变更是删/改对应 `if`，见 `§3` 行号）：

```python
# M3：在 _normalize 的 `if route == "director":` 之后、`if "actions" in raw:` 之前插入
if tool.get("auth") == "live" and "action" in raw:
    return agent_contract.envelope_ok(name, raw.get("action"),
                                      meta=stable_meta, request_id=request_id)

# M7b：删除 render_lua 中这三行，然后 python3 tools/agent_tools.py --write
"      if rule.segments and not segmentsMatch(rule.segments, value) then",
"        return false, 'invalid_params'",
"      end",

# M8：_director_config 的 token 行改为
token = _env("AGENT_DIRECTOR_TOKEN") or _env("AGENT_LIVE_TOKEN")
```

M7b 实跑检查：`/tmp/m7b_check.lua` 加载变异后的 `agent_tools.lua`，`AgentTools.validate('list_live_events',{since='1:2:3'})` 返回 `true`；M8 在 `LIVE_ENV`（只有 `AGENT_LIVE_TOKEN`）下 `_visible_tools()` 返回 8 个工具，含 `add_player_money`、`send_notify`。

---

## 7. 验证过、没问题的点

- **无 token 不可调用**：`AGENT_TOOLSET=all` 且无任何 token 时 `get_live_players` 返回 `unauthorized`，`urlopen` 调用数 0；只配 `AGENT_DIRECTOR_URL` 也一样（`§4 L1` 名单）。
- **live token 不会在出厂 registry 下流向非 live 端点**：同时配置两个 token 时 `get_action` 用 `Bearer write` 访问 `/agent/v1/actions/1`；`send_notify` 同理。反向（live token 流向非 live）只在 L3 的 registry 变异下发生。
- **路径替换不可注入**：`get_live_player` 的 `citizenid` 对 `../x`、`a/b`、`a?b`、`a%2Fb` 全部 `invalid characters`；即使绕过校验，`urllib.parse.quote(safe="")` 也把 `/` 编成 `%2F`、`%` 编成 `%25`、`?` 编成 `%3F`。`..` 本身不被编码，但 schema 不允许点号，当前不可达。
- **`since` 被 URL 编码**：`_build_url` 产出 `...?since=1761136800%3A8841`；Lua `urlDecode` 会还原 `:`（`http_api.lua:39-44`），测试也验证了 `parse_qs`。
- **`meta.count` 与 `data.count` 不冲突**：`get_live_players` 的 `count` 是 Lua 截断后的页内数量，`meta.count` 只是同一值的提升；`list_live_events` 没有 count。唯一瑕疵是 `isinstance(count,int)` 对 `2.0`/`True` 不提升（L4 第三行），当前 Lua 只发整数，不构成 P2。
- **生成物**：`--check` 干净；再次 `--write` 后 sha256 不变；`luac5.4 -p` 通过；Lua runner 59 个 case 全绿。

  ```bash
  cd /path/to/T-City-agent
  sha256sum T-CityLite.base/docs/agent/TOOLS.md \
    "T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua" > /tmp/h1
  python3 tools/agent_tools.py --write >/dev/null
  sha256sum T-CityLite.base/docs/agent/TOOLS.md \
    "T-CityLite.base/resources/[custom]/custom-director/shared/agent_tools.lua" > /tmp/h2
  diff /tmp/h1 /tmp/h2 && python3 tools/agent_tools.py --check
  ```
- **`segmentsMatch` 对出厂 pattern 与 Python 等价**：25 组里 23 组一致；2 组差异是 Python `\d` 的 Unicode 语义（L6），不是 `segmentsMatch` 的 ASCII 逻辑错误。
- **Lua 侧 `live_api` 的 20 个 case** 覆盖了 disabled、wrong token、actions fallback、epoch mismatch、limit clamp 等；问题不在 M1 的 HTTP 语义，而在 facade 的凭证选择与 L8 的“生成器校验器未被实跑”。

### 次要观察（未计入发现表）

- `list_live_events` 的 `returns_pii:false` 与 `untrusted_fields:["name","payload"]` 语义不一致（L5/L10）。
- facade 仍没有实现 registry 声明的 60/min 限流（前一轮 R10），live 工具会让轮询更频繁；这是既有缺口，不在本提交引入。
- `_http_error` 也没有利用 `Retry-After`（429 的 `retry_after_ms` 恒 None）；与 L9 同源。
- `get_live_players` 的 `job` 过滤在 Python 端限 64 字符、Lua 端 `sanitize_text` 32；只影响超长输入，Lua 会按自己的规则截断/不匹配。

---

## 8. 限制

- 没有连接真实 FXServer/MySQL 做端到端；HTTP 层全部用假 `urlopen`，Lua 侧用官方 harness + `lua5.4`。
- 未评审 M1 的 live 采集/事件环实现本身（`live_events.lua`、`live_cache.lua` 的并发/性能），只评审本提交如何消费其响应。
- 未验证跨进程/多 agent 的 token 轮换、代理重定向（前一轮 R9）与真实 TLS；这些不在本提交 diff 内。
- `/tmp` EDQUOT 导致整仓副本失败；已改用 844K 最小副本并清理，所有命令可重跑。未对仓库做任何写操作（除本 review 文件）。

---

- **P0 = 0；P1 = 2（L1 live token 回退、L2 registry_version 未升）；P2 = 8（L3–L10）。**
- **最严重：L1** —— `AGENT_LIVE_TOKEN` 回退 `AGENT_DIRECTOR_TOKEN`，单 token 部署下只读凭证与写凭证重新合一，直接推翻 design 01 §5.2 的分离前提；且独立 live token 部署时 facade 会广告必然 401 的工具。
- **次严重：L2** —— 新增 3 个 active 工具仍保持 `registry_version 1.0.0`，按 design 03:53 应升 `1.1.0`，测试还硬编码了旧值。
- **建议：需修，当前不建议合并**；L1/L2 合并前必须修，L3/L4/L8 同批修（auth 校验收敛、响应归一、Lua 校验器实跑），L5/L6/L7/L9/L10 可排 M1。
- **`auth` 裁决**：设计成立（read + director + 独立凭证），但需把“独立”变成默认行为、把校验从 route 收敛到 path，并补 schema/TOOLS.md/Lua mirror/.env 文档。
