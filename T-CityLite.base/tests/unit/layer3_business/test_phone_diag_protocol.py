"""custom-phone 四段往返诊断协议（client/core/diag.lua + server/core/diag.lua）。

覆盖 docs/client/research/client-observability-design.md 的可断言部分：

* 客户端：`_diag` 剥离与 tid 校验、level=0 空转、warmup/slow/fail 采样、
  phase 上限与 overflow、ui 域白名单、以及"不创建任何计时器"；
* 服务端：level 门禁、白名单投影、判定优先级（内存环为 SR/SD 唯一事实源）、
  断点映射（seg1/seg1.5/seg2/seg3-*/seg3.5/seg4）、trace 令牌桶与 ui 5s 冷却、
  8 槽 path 打印、打印预算。

离线运行：lua5.4 + 手写 stub（无 FXServer、无 DB、无网络）。
"""

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
PHONE = BASE / "resources" / "[custom]" / "custom-phone"
CLIENT_DIAG = PHONE / "client" / "core" / "diag.lua"
SERVER_DIAG = PHONE / "server" / "core" / "diag.lua"
MANIFEST = PHONE / "fxmanifest.lua"

LUA_BIN = shutil.which("lua5.4")


def _block(path: Path, marker: str) -> str:
    """Extract the marked region so tests load exactly what ships."""
    source = path.read_text(encoding="utf-8")
    start = source.index(f"-- [{marker}] begin")
    end = source.index(f"-- [{marker}] end", start)
    return source[start:end + len(f"-- [{marker}] end")]


CLIENT_SRC = _block(CLIENT_DIAG, "phone-diag-client")
SERVER_SRC = _block(SERVER_DIAG, "phone-diag-server")

CLIENT_STUBS = r"""
local NOW = 0
local convar = { phone_diag = '1' }
local events = {}
function GetGameTimer() return NOW end
function advance(ms) NOW = NOW + ms end
function GetConvar(name) return convar[name] or '' end
function GetConvarInt(name) return tonumber(convar[name] or '') or 0 end
function setConvar(name, value) convar[name] = value end
function TriggerServerEvent(name, payload) events[#events + 1] = { name = name, payload = payload } end
function SetTimeout() error('client diag must not create timers') end
local function lastEvent()
    return events[#events]
end
local function eventCount()
    return #events
end
"""

SERVER_STUBS = r"""
local NOW = 0
local printed = {}
local convar = { phone_diag = '1' }
local netEvents = {}
local buckets = {}
function GetGameTimer() return NOW end
function advance(ms) NOW = NOW + ms end
function GetConvar(name) return convar[name] or '' end
function GetConvarInt(name) return tonumber(convar[name] or '') or 0 end
function setConvar(name, value) convar[name] = value end
function print(...)
    local parts = {}
    for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
    printed[#printed + 1] = table.concat(parts, ' ')
end
function RegisterNetEvent(name, fn) netEvents[name] = fn end
PhoneRateLimit = {
    Allow = function(key, rate, burst)
        local bucket = buckets[key]
        if not bucket then
            bucket = { tokens = burst, last = NOW }
            buckets[key] = bucket
        else
            local elapsed = (NOW - bucket.last) / 60000
            bucket.tokens = math.min(burst, bucket.tokens + elapsed * rate)
            bucket.last = NOW
        end
        if bucket.tokens < 1 then return false end
        bucket.tokens = bucket.tokens - 1
        return true
    end,
}
local function lastPrint() return printed[#printed] end
local function printCount() return #printed end
local function fireDiag(src, payload)
    local handler = netEvents['phone:server:diag']
    assert(handler, 'phone:server:diag must be registered by the diag module')
    source = src
    handler(payload)
end
"""


def _run(source: str) -> subprocess.CompletedProcess:
    if LUA_BIN is None:
        pytest.skip("lua5.4 is not installed")
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False) as handle:
        handle.write(source)
        path = handle.name
    try:
        return subprocess.run([LUA_BIN, path], capture_output=True, text=True, timeout=15)
    finally:
        Path(path).unlink(missing_ok=True)


def client(body: str) -> str:
    return CLIENT_STUBS + "\n" + CLIENT_SRC + "\n" + body


def server(body: str) -> str:
    return SERVER_STUBS + "\n" + SERVER_SRC + "\n" + body


def assert_client(body: str) -> None:
    result = _run(client(body))
    assert result.returncode == 0, f"{result.stderr}\n{result.stdout}"


def assert_server(body: str) -> None:
    result = _run(server(body))
    assert result.returncode == 0, f"{result.stderr}\n{result.stdout}"


# ---------------------------------------------------------------------------
# 静态契约
# ---------------------------------------------------------------------------


def test_manifest_loads_diag_before_main():
    manifest = MANIFEST.read_text(encoding="utf-8")
    client_block = re.search(r"client_scripts\s*\{(.*?)\}", manifest, re.S)
    server_block = re.search(r"server_scripts\s*\{(.*?)\}", manifest, re.S)
    assert client_block and server_block
    client_scripts = client_block.group(1)
    server_scripts = server_block.group(1)
    assert "client/core/diag.lua" in client_scripts
    assert client_scripts.index("client/core/diag.lua") < client_scripts.index("client/main.lua")
    assert "server/core/diag.lua" in server_scripts
    assert server_scripts.index("server/core/diag.lua") < server_scripts.index("server/main.lua")
    # diag 依赖 rate_limit 的令牌桶
    assert server_scripts.index("server/core/rate_limit.lua") < server_scripts.index("server/core/diag.lua")


def test_diag_registers_its_own_transport():
    assert "RegisterNetEvent('phone:server:diag'" in SERVER_SRC
    assert "phone:server:diag" in CLIENT_SRC


# ---------------------------------------------------------------------------
# 客户端
# ---------------------------------------------------------------------------


def test_client_strips_diag_and_validates_trace_id():
    assert_client(r"""
local payload = { app_id = 'police_mdt', query = 'units', _diag = { v = 1, tid = 'k3f9a2b1' } }
assert(PhoneDiag.TakeTraceId(payload) == 'k3f9a2b1')
assert(payload._diag == nil, '_diag must never reach the server business layer')
assert(payload.app_id == 'police_mdt' and payload.query == 'units')

-- 非法 tid：返回 nil，但仍然剥离字段（否则会跟着 payload 下发）
for _, bad in ipairs({ { tid = 'ab' }, { tid = 'has space' }, { tid = 42 }, { 'not-a-table' } }) do
    local next = { query = 'units', _diag = bad }
    assert(PhoneDiag.TakeTraceId(next) == nil)
    assert(next._diag == nil)
end
assert(PhoneDiag.TakeTraceId('not-a-table') == nil)
assert(PhoneDiag.ValidTraceId('abc') == 'abc')
assert(PhoneDiag.ValidTraceId(('x'):rep(65)) == nil)
""")


def test_client_level_zero_means_no_trace_and_no_event():
    assert_client(r"""
setConvar('phone_diag', '0')
assert(PhoneDiag.Level() == 0)
local trace = PhoneDiag.StartTrace('k3f9a2b1', 'query', 'police_mdt')
assert(trace == nil, 'level=0 must return nil so callers can bail out')
assert(PhoneDiag.Phase(nil, 'req.cli.recv') == false)
assert(PhoneDiag.Finish(nil, 'ok') == false)
assert(PhoneDiag.Emit('ui.open-start') == false)
assert(eventCount() == 0, 'level=0 must not send any event')
""")


def test_client_sampling_warmup_slow_and_fail():
    assert_client(r"""
-- warmup: 前 3 条即使又快又成功也要发
for index = 1, 3 do
    local trace = PhoneDiag.StartTrace(('tid%04d'):format(index), 'query', 'police_mdt')
    assert(trace, 'warmup trace must start')
    PhoneDiag.Phase(trace, 'req.cli.recv')
    assert(PhoneDiag.Finish(trace, 'ok') == true, 'warmup trace must be reported')
end
assert(eventCount() == 3)

-- 第 4 条：快 + 成功 + level=1 → 不报
local quiet = PhoneDiag.StartTrace('tidquiet1', 'query', 'police_mdt')
PhoneDiag.Phase(quiet, 'req.cli.recv')
assert(PhoneDiag.Finish(quiet, 'ok') == false, 'fast+ok must stay silent at level 1')
assert(eventCount() == 3)

-- 失败必报
local failing = PhoneDiag.StartTrace('tidfail1', 'query', 'police_mdt')
PhoneDiag.Phase(failing, 'req.cli.recv')
assert(PhoneDiag.Finish(failing, 'timeout') == true)
assert(eventCount() == 4)

-- 慢必报（>= 400ms）
local slow = PhoneDiag.StartTrace('tidslow1', 'query', 'police_mdt')
PhoneDiag.Phase(slow, 'req.cli.recv')
advance(450)
assert(PhoneDiag.Finish(slow, 'ok') == true)
assert(eventCount() == 5)
local last = lastEvent()
assert(last.name == 'phone:server:diag')
assert(last.payload.mode == 'trace' and last.payload.code == 'ok')
assert(last.payload.dur == 450)
assert(#last.payload.phases == 1 and last.payload.phases[1][1] == 2)

-- level=2 时快+成功也报
setConvar('phone_diag', '2')
advance(6000) -- 越过 5s convar 缓存
local loud = PhoneDiag.StartTrace('tidloud1', 'query', 'police_mdt')
assert(PhoneDiag.Finish(loud, 'ok') == true)
assert(eventCount() == 6)
""")


def test_client_phase_cap_and_unknown_phase():
    assert_client(r"""
local trace = PhoneDiag.StartTrace('tidcap01', 'query', 'police_mdt')
for index = 1, 10 do
    PhoneDiag.Phase(trace, 'req.cli.recv')
end
assert(#trace.marks == PhoneDiag.MAX_PHASES, 'marks must be capped at MAX_PHASES')
assert(trace.overflow == true, 'overflow must be flagged, not silently swallowed')
assert(PhoneDiag.Phase(trace, 'not.a.phase') == false, 'unknown phase must be rejected')
-- 同一条 trace 只能 Finish 一次
assert(PhoneDiag.Finish(trace, 'ok') == true)
assert(PhoneDiag.Finish(trace, 'ok') == false)
local sent = lastEvent()
assert(sent.payload.overflow == true)
""")


def test_client_ui_events_only_accept_ui_phases():
    assert_client(r"""
setConvar('phone_diag', '1')
assert(PhoneDiag.Emit('req.cli.recv') == false, 'request phases must not go through Emit')
assert(PhoneDiag.Emit('ui.open-start') == true)
local payload = lastEvent().payload
assert(payload.mode == 'event' and payload.phase == 'ui.open-start')
assert(payload.tid == nil, 'ui events carry no trace id')

PhoneDiag.Emit('ui.close', { attempt = 2, focused = true, keepInput = false, owner = 'phone' })
payload = lastEvent().payload
assert(payload.attempt == 2 and payload.focused == true and payload.keepInput == false)
assert(payload.owner == 'phone')
""")


def test_client_open_trace_cap_prevents_leaks():
    assert_client(r"""
local traces = {}
for index = 1, 40 do
    traces[index] = PhoneDiag.StartTrace(('leak%04d'):format(index), 'query', 'police_mdt')
end
local started = 0
for index = 1, 40 do if traces[index] then started = started + 1 end end
assert(started <= 32, 'at most 32 traces may stay open: ' .. started)
local state = PhoneDiag.State()
assert(state.open <= 32)
""")


# ---------------------------------------------------------------------------
# 服务端
# ---------------------------------------------------------------------------


def test_server_level_gate_and_sanitize():
    assert_server(r"""
setConvar('phone_diag', '0')
assert(PhoneDiag.Accept(7, { mode = 'trace', tid = 'k3f9a2b1', code = 'ok' }) == false)
assert(printCount() == 0, 'level=0 must not print')

setConvar('phone_diag', '1')
advance(6000)
local cleaned = PhoneDiag.Sanitize({
    mode = 'trace', tid = 'k3f9a2b1', kind = 'query', app = 'police_mdt',
    code = 'ok', dur = 12, citizenid = 'ABC123', payload = { secret = 1 },
})
assert(cleaned.tid == 'k3f9a2b1')
assert(cleaned.citizenid == nil, 'unknown fields must be dropped')
assert(cleaned.payload == nil, 'payload must never be logged')

-- 非法 tid / 非 ui phase
assert(PhoneDiag.Sanitize({ mode = 'trace', tid = 'ab' }).tid == nil)
assert(PhoneDiag.Sanitize({ mode = 'event', phase = 'req.cli.recv' }).phase == nil)
assert(PhoneDiag.Sanitize({ mode = 'event', phase = 'ui.open-ack' }).phase == 'ui.open-ack')
""")


def test_server_verdict_priority_uses_ring_as_truth():
    """判定只覆盖 Lua 侧可观测的 6 个槽位。

    NS/ND 两槽（NUI 即将 fetch / NUI 已 resolve）无法在 Lua 侧证实——NUI 只把 tid
    带下来，CEF 的 resolve 没有任何回调。把它们留在判定里会把"一切正常"误判成
    seg4（实测踩过：code=ok 却 break=seg4 reason=nui-never-settled）。
    """
    assert_server(r"""
-- 1) 环里没有该 tid → seg2（客户端批次里没有 srv.* 是正常的，不能据此下结论）
assert(PhoneDiag.Verdict({ CR = true, CF = true }, nil) == 'seg2')

-- 2) 有 tid 但没有 doneAt → seg3-produce
assert(PhoneDiag.Verdict({ CR = true, CF = true }, { recvAt = 1 }) == 'seg3-produce')

local entry = { recvAt = 1, doneAt = 2 }
-- 3) 之后才看其余槽位
assert(PhoneDiag.Verdict({ CR = true }, entry) == 'seg1.5')
assert(PhoneDiag.Verdict({ CR = true, CF = true, CP = true, CA = true }, entry) == nil)
assert(PhoneDiag.Verdict({ CR = true, CF = true, CA = true }, entry) == 'seg3-deliver')
assert(PhoneDiag.Verdict({ CR = true, CF = true, CP = true }, entry) == 'seg3.5')

-- 4) 只有 CR/CF 缺失才算断；NUI 侧两段不参与判定
assert(PhoneDiag.Verdict({}, entry) == nil, 'no client marks must not be accused as seg1/seg4')
""")


def test_server_trace_batch_merges_ring_into_path():
    assert_server(r"""
setConvar('phone_diag', '1')
advance(6000)
assert(PhoneDiag.RecordRecv(7, 'k3f9a2b1', 'query') == true)
PhoneDiag.RecordDone(7, 'k3f9a2b1', 'ok')

fireDiag(7, {
    mode = 'trace', tid = 'k3f9a2b1', kind = 'query', app = 'police_mdt',
    code = 'ok', dur = 84,
    phases = { { 1, 0 }, { 2, 2 }, { 3, 51 }, { 6, 84 }, { 7, 84 }, { 8, 86 } },
})
local line = lastPrint()
assert(line, 'a trace must print one line')
assert(line:find('path=CR|CF|SR|SD|CP|CA', 1, true), 'SR/SD must come from the ring: ' .. line)
assert(line:find('break=none', 1, true), line)
assert(line:find('code=ok', 1, true) and line:find('dur', 1, true) == nil)
""")


def test_server_trace_rate_limit_and_ui_cooldown():
    assert_server(r"""
setConvar('phone_diag', '1')
advance(6000)
-- burst=5：第 6 条必须被丢
for index = 1, 6 do
    PhoneDiag.Accept(7, { mode = 'trace', tid = ('tid%04d'):format(index), code = 'ok', dur = 1 })
end
local summary = PhoneDiag.Summary(7)
assert(summary.dropped == 1, 'sixth trace must be dropped: ' .. tostring(summary.dropped))

-- ui 域：同一 (phase, src) 5s 内只打一次
PhoneDiag.Reset()
setConvar('phone_diag', '1')
local before = printCount()
PhoneDiag.Accept(7, { mode = 'event', phase = 'ui.open-ack', focused = true })
PhoneDiag.Accept(7, { mode = 'event', phase = 'ui.open-ack', focused = true })
PhoneDiag.Accept(8, { mode = 'event', phase = 'ui.open-ack', focused = true })
assert(printCount() == before + 2, 'same phase+src must be cooled down, other src must pass')
advance(5100)
PhoneDiag.Accept(7, { mode = 'event', phase = 'ui.open-ack', focused = true })
assert(printCount() == before + 3, 'cooldown must expire after 5s')
""")


def test_server_record_helpers_are_noops_at_level_zero():
    assert_server(r"""
setConvar('phone_diag', '0')
assert(PhoneDiag.RecordRecv(7, 'k3f9a2b1', 'query') == false)
PhoneDiag.RecordDone(7, 'k3f9a2b1', 'ok')
assert(PhoneDiag.Summary().ring == 0)
""")


def test_server_print_budget_caps_flood():
    assert_server(r"""
setConvar('phone_diag', '2')
advance(6000)
PhoneDiag.Reset()
local sent = 0
for index = 1, 80 do
    PhoneDiag.Accept(7, { mode = 'event', phase = 'ui.reassert', focused = false })
    -- ui 冷却会先拦住，这里用不同 src 绕过冷却，专门压打印预算
    PhoneDiag.Accept(100 + index, { mode = 'event', phase = 'ui.reassert', focused = false })
end
assert(printCount() <= PhoneDiag.PRINT_BUDGET_PER_SEC, 'print budget must cap one second: ' .. printCount())
assert(PhoneDiag.Summary().dropped > 0, 'over-budget lines must be counted as dropped')
""")
