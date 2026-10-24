"""FIT-AGENT-OPS — custom-agent-ops observability contract.

Static, offline contract over ``resources/[custom]/custom-agent-ops`` plus a
Lua harness for the parts that only a runtime can prove:

* the manifest is server-only and never declares a client script;
* no net event, NUI callback or HTTP surface is registered;
* ``/agent status|events|tail|health|test`` are registered behind
  ``source == 0`` or ``IsPlayerAceAllowed(source, 'agent.ops')``, and a console
  command invoked by another resource is rejected;
* the four exports exist, and ``PushAgentEvent`` rejects in-process callers;
* the ring is capped at 500, evicts the oldest row, reports ``dropped`` and a
  cursor reset, and ``GetAgentEvents`` clamps ``limit`` to 200;
* sanitisation removes credential keys, strips control characters and truncates
  by UTF-8 characters;
* the JSONL log rotates and removes the oldest archive (cleanup);
* the resource is only wired into ``configs/modules/dev.cfg``.

The Lua harness loads the real ``config.lua`` + ``server/main.lua`` against a
minimal FiveM stub, so a command guard or ring regression cannot pass through
a source-only regex.

    python3 -m pytest -q tests/architecture/test_agent_ops.py
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
REPO = BASE.parent
RESOURCE = BASE / "resources" / "[custom]" / "custom-agent-ops"
MANIFEST = RESOURCE / "fxmanifest.lua"
CONFIG = RESOURCE / "config.lua"
MAIN = RESOURCE / "server" / "main.lua"
DOC = REPO / "docs" / "police" / "AGENT_OPS.md"
DEV_CFG = BASE / "configs" / "modules" / "dev.cfg"

LUA_BIN = shutil.which("lua5.4")

COMMANDS = ("status", "events", "tail", "health", "test")
EXPORTS = ("GetAgentSnapshot", "GetAgentEvents", "PushAgentEvent", "HealthSnapshot")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main_source() -> str:
    return read(MAIN)


# ---------------------------------------------------------------------------
# Harness: the real files against a deliberately small FiveM stub
# ---------------------------------------------------------------------------

HARNESS = r"""
local MAIN = __MAIN__
local CONFIG = __CONFIG__
local RESOURCE = __RESOURCE__

output = {}
print = function(...)
    local parts = {}
    for index = 1, select('#', ...) do
        parts[#parts + 1] = tostring(select(index, ...))
    end
    output[#output + 1] = table.concat(parts, '\t')
end

local function quote(value)
    value = value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
        :gsub('\r', '\\r'):gsub('\t', '\\t')
    return '"' .. value .. '"'
end

local function encode(value)
    local kind = type(value)
    if value == nil then return 'null' end
    if kind == 'boolean' then return value and 'true' or 'false' end
    if kind == 'number' then return tostring(value) end
    if kind == 'string' then return quote(value) end
    if kind ~= 'table' then return 'null' end

    local metatable = getmetatable(value)
    if metatable and metatable.__jsontype == 'array' then
        local parts = {}
        for index = 1, #value do parts[#parts + 1] = encode(value[index]) end
        return '[' .. table.concat(parts, ',') .. ']'
    end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = quote(tostring(key)) .. ':' .. encode(value[key])
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

json = { encode = encode, decode = function() return {} end }

local exported = {}
local qb = {
    GetCoreObject = function()
        return { Functions = { GetPlayers = function() return {} end }, Players = {} }
    end,
}
local police = {
    GetNpcBudget = function() return { used = 2, max = 6 } end,
}
exports = setmetatable({ ['qb-core'] = qb, ['custom-police'] = police }, {
    __call = function(_, name, fn) exported[name] = fn end,
})

local commands = {}
local handlers = {}
RegisterCommand = function(name, fn) commands[name] = fn end
AddEventHandler = function(name, fn) handlers[name] = fn end
CreateThread = function() end
Wait = function() end

GetCurrentResourceName = function() return 'custom-agent-ops' end
GetResourcePath = function() return RESOURCE end
GetPlayers = function() return { '1', '2' } end
GetGameTimer = function()
    TIMER = (TIMER or 1000) + 100
    return TIMER
end
GetInvokingResource = function() return INVOKING end
IsPlayerAceAllowed = function() return ACE_ALLOWED == true end
RESOURCE_STATES = {}
GetResourceState = function(name) return RESOURCE_STATES[name] or 'started' end
SaveResourceFile = function() return true end
LoadResourceFile = function() return '' end
ExecuteCommand = function(command) EXECUTED = command end

LAST_AUDIT_ID = 42
AUDIT_ROWS = {}
MySQL = {}
MySQL.single = {
    await = function(sql)
        if sql:find('MAX(id)', 1, true) then return { id = LAST_AUDIT_ID } end
        if sql:find('police_units', 1, true) then return { n = 3 } end
        if sql:find('police_incidents', 1, true) then return { n = 2 } end
        if sql:find('justice_sentences', 1, true) then return { n = 1 } end
        if sql:find('police_outbox', 1, true) then return { n = 0 } end
        return { n = 0 }
    end,
}
MySQL.query = {
    await = function(sql)
        if sql:find('police_audit', 1, true) then return AUDIT_ROWS end
        return {}
    end,
}
MySQL.scalar = { await = function() return 1 end }

dofile(CONFIG)
dofile(MAIN)
"""


def run_lua(body: str, tmp_path: Path) -> str:
    if LUA_BIN is None:
        pytest.skip("lua5.4 is not installed")
    script = (
        HARNESS.replace("__MAIN__", json.dumps(MAIN.as_posix()))
        .replace("__CONFIG__", json.dumps(CONFIG.as_posix()))
        .replace("__RESOURCE__", json.dumps(RESOURCE.as_posix()))
    ) + "\n" + body
    path = tmp_path / "agent_ops_harness.lua"
    path.write_text(script, encoding="utf-8")
    result = subprocess.run(
        [LUA_BIN, str(path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    return result.stdout


# ---------------------------------------------------------------------------
# Manifest and wiring
# ---------------------------------------------------------------------------

def test_resource_files_and_server_only_manifest() -> None:
    assert MANIFEST.is_file()
    assert CONFIG.is_file()
    assert MAIN.is_file()
    assert (RESOURCE / "logs" / "README.md").is_file()

    manifest = read(MANIFEST)
    assert "server_only 'yes'" in manifest
    assert "'qb-core'" in manifest
    assert "'oxmysql'" in manifest
    assert "'custom-police'" in manifest
    assert "client_script" not in manifest
    assert "server/main.lua" in manifest
    assert "config.lua" in manifest


def test_no_net_or_client_surface() -> None:
    source = main_source()
    for token in (
        "RegisterNetEvent",
        "RegisterRawNetEvent",
        "TriggerClientEvent",
        "TriggerServerEvent",
        "SetHttpHandler",
        "SendNUIMessage",
    ):
        assert token not in source, f"custom-agent-ops must not use {token}"


def test_commands_are_registered_and_guarded() -> None:
    source = main_source()
    assert "RegisterCommand('agent'" in source
    for command in COMMANDS:
        assert f"function COMMANDS.{command}(" in source, command

    guard = source[source.index("function AgentOps.CanRun("):]
    guard = guard[: guard.index("\nend\n") + len("\nend\n")]
    assert "source == 0" in guard
    assert "GetInvokingResource" in guard
    assert "IsPlayerAceAllowed(source, 'agent.ops')" in guard
    assert "return false, 'ace_denied'" in guard

    # The wrapper must decide before dispatch.
    assert source.index("local allowed, reason = AgentOps.CanRun(source)") < source.index(
        "local handler = COMMANDS[sub]"
    )
    assert "if not allowed then" in source


def test_exports_and_external_push_contract() -> None:
    source = main_source()
    for name in EXPORTS:
        assert re.search(rf"exports\(\s*'{name}'\s*,", source), name

    push = source[source.index("exports('PushAgentEvent'"):]
    push = push[: push.index("exports('HealthSnapshot'")]
    assert "GetInvokingResource" in push or "invoker()" in push
    assert "'not_export'" in push
    assert "PushExternal" in push
    assert "clampInt(limit, 1, 200" in source


def test_queries_are_read_only_parameterised_and_bounded() -> None:
    source = main_source()
    for statement in (
        "INSERT INTO police",
        "UPDATE police",
        "DELETE FROM police",
        "INSERT INTO justice",
        "UPDATE justice",
        "DELETE FROM justice",
    ):
        assert statement not in source.upper(), statement
    assert re.search(r"SELECT\s+\*", source, re.I) is None
    assert "WHERE id > ?" in source
    assert source.count("LIMIT ?") >= 3
    assert "DATE_SUB(NOW(), INTERVAL ? MINUTE)" in source


def test_event_taxonomy_and_sensitive_redaction() -> None:
    source = main_source()
    for event_type in ("duty", "incident", "arrest", "sentence", "npc", "backup", "outbox"):
        assert re.search(rf"^\s*{event_type} = true,", source, re.M), event_type
    assert "['duty.set'] = 'duty'" in source
    assert "['justice.verdict'] = 'sentence'" in source
    assert "isSensitiveAction" in source
    assert "data.redacted = true" in source
    for pii in ("charinfo", "firstname", "lastname", "birthdate"):
        assert pii not in source


def test_ring_and_cleanup_constants() -> None:
    source = main_source()
    assert "local RING_CAPACITY = 500" in source
    assert "function AgentOps.NewRing(" in source
    assert "function AgentOps.RotateFile(" in source
    assert "function AgentOps.ShouldRotate(" in source
    assert "file_log_max_bytes" in source
    assert "os.rename(path, path .. '.1')" in source
    assert "os.remove(path .. '.' .. tostring(count))" in source


def test_only_dev_cfg_ensures_the_resource() -> None:
    assert "ensure custom-agent-ops" in read(DEV_CFG)
    for cfg in sorted((BASE / "configs" / "modules").glob("*.cfg")):
        if cfg.name == "dev.cfg":
            continue
        assert "custom-agent-ops" not in read(cfg), cfg.name


def test_documentation_covers_commands_exports_and_testing() -> None:
    assert DOC.is_file(), DOC
    doc = read(DOC)
    for text in (
        "/agent status",
        "/agent events",
        "/agent tail",
        "/agent health",
        "/agent test",
        "agent.ops",
        "GetAgentSnapshot",
        "GetAgentEvents",
        "PushAgentEvent",
        "HealthSnapshot",
        "Test.run",
        "agent-events.jsonl",
    ):
        assert text in doc, text


# ---------------------------------------------------------------------------
# Runtime contracts (real Lua, stubbed FiveM surface)
# ---------------------------------------------------------------------------

def test_ring_is_bounded_and_cursor_clamps(tmp_path: Path) -> None:
    run_lua(
        r"""
local ring = AgentOps.NewRing(10000)
assert(ring.capacity == 500, 'capacity must clamp to 500, got ' .. tostring(ring.capacity))
for index = 1, 600 do
    AgentOps.Push(ring, { type = 'test', data = { index = index } })
end
assert(#ring.items == 500, 'ring length ' .. tostring(#ring.items))
assert(ring.items[1].id == 101, 'oldest id ' .. tostring(ring.items[1].id))
assert(ring.items[500].id == 600, 'newest id ' .. tostring(ring.items[500].id))
assert(ring.dropped == 100, 'dropped ' .. tostring(ring.dropped))

AgentOps.State.ring = ring
local result = AgentOps.GetEvents(550, 5)
assert(#result.events == 5, 'limit 5')
assert(result.events[1].id == 596 and result.events[5].id == 600)
assert(result.next_id == 600 and result.reset == false)
local reset = AgentOps.GetEvents(9999, 5)
assert(reset.reset == true and #reset.events == 5, 'cursor reset')
local capped = AgentOps.GetEvents(nil, 9999)
assert(#capped.events == 200, 'limit clamps to 200, got ' .. tostring(#capped.events))
""",
        tmp_path,
    )


def test_sanitize_redacts_and_truncates_utf8(tmp_path: Path) -> None:
    run_lua(
        r"""
local long = string.rep('警', 300)
local cut = AgentOps.Truncate(long, 10)
assert(utf8.len(cut) == 10, 'utf8 chars ' .. tostring(utf8.len(cut)))
assert(not cut:find('\n'), 'control newline stripped')

local data = AgentOps.Sanitize({
    password = 'hunter2',
    token = 'abc',
    api_key = 'key',
    note = 'line1\nline2',
    nested = { secret = 's', keep = 1 },
    list = { 1, 2, 3 },
})
assert(data.password == nil and data.token == nil and data.api_key == nil, 'credential keys dropped')
assert(data.note == 'line1 line2', 'control characters blanked')
assert(data.nested.secret == nil and data.nested.keep == 1, 'nested redaction')
assert(data.list[3] == 3, 'list values kept')
local text = AgentOps.Sanitize('token=abc123 rest')
assert(not text:find('abc123'), 'inline token redacted: ' .. tostring(text))
""",
        tmp_path,
    )


def test_command_authorization_rejects_unauthorized_and_resource_console(tmp_path: Path) -> None:
    run_lua(
        r"""
-- Player without agent.ops: denied, and no status payload leaks.
output = {}
ACE_ALLOWED = false
INVOKING = nil
commands['agent'](5, { 'status' }, 'agent status')
local joined = table.concat(output, '\n')
assert(joined:find('denied', 1, true) ~= nil, 'player denied: ' .. joined)
assert(joined:find('police_on_duty', 1, true) == nil, 'status leaked to denied player')

-- Player with agent.ops: allowed.
output = {}
ACE_ALLOWED = true
commands['agent'](5, { 'status' }, '')
joined = table.concat(output, '\n')
assert(joined:find('police_on_duty', 1, true) ~= nil, 'ACE player allowed: ' .. joined)

-- Console: allowed.
output = {}
ACE_ALLOWED = false
INVOKING = nil
commands['agent'](0, { 'status' }, '')
joined = table.concat(output, '\n')
assert(joined:find('police_on_duty', 1, true) ~= nil, 'console allowed: ' .. joined)

-- Console command invoked by another resource: denied.
output = {}
ACE_ALLOWED = false
INVOKING = 'custom-director'
commands['agent'](0, { 'status' }, '')
joined = table.concat(output, '\n')
assert(joined:find('denied', 1, true) ~= nil, 'resource console denied: ' .. joined)
assert(joined:find('police_on_duty', 1, true) == nil, 'resource console leaked status')
""",
        tmp_path,
    )


def test_test_command_requires_custom_testing_and_dispatches(tmp_path: Path) -> None:
    run_lua(
        r"""
INVOKING = nil
ACE_ALLOWED = false

RESOURCE_STATES['custom-testing'] = 'stopped'
output = {}
commands['agent'](0, { 'test', 'smoke' }, '')
local joined = table.concat(output, '\n')
assert(joined:find('custom_testing_not_running', 1, true) ~= nil, joined)

RESOURCE_STATES['custom-testing'] = 'started'
output = {}
EXECUTED = nil
commands['agent'](0, { 'test', 'smoke' }, '')
joined = table.concat(output, '\n')
assert(EXECUTED == 'test run smoke', 'dispatch: ' .. tostring(EXECUTED))
assert(joined:find('"ok":true', 1, true) ~= nil, joined)
""",
        tmp_path,
    )


def test_external_push_requires_export_and_rate_limits(tmp_path: Path) -> None:
    run_lua(
        r"""
-- Direct in-process call: rejected.
INVOKING = nil
local id, err = exported.PushAgentEvent('incident', { title = 'x' })
assert(id == false and err == 'not_export', 'in-process push rejected')

-- Invalid input is rejected before it reaches the ring.
INVOKING = 'custom-director'
id, err = exported.PushAgentEvent('Bad Type', {})
assert(id == false and err == 'invalid_type', 'invalid type')
id, err = exported.PushAgentEvent('incident', 'not-a-table')
assert(id == false and err == 'invalid_data', 'invalid data')

-- A drained bucket rejects one push, then recovers.
AgentOps.State.pushBucket = { tokens = 0, at = os.time() * 1000 + 100000 }
id, err = exported.PushAgentEvent('incident', { title = 'x' })
assert(id == false and err == 'rate_limited', 'rate limited: ' .. tostring(err))
AgentOps.State.pushBucket = { tokens = 1, at = os.time() * 1000 }
id, err = exported.PushAgentEvent('incident', { title = 'x', citizenid = 'cid1' })
assert(type(id) == 'number', 'push id: ' .. tostring(id) .. ' err: ' .. tostring(err))
local events = AgentOps.GetEvents(0, 10)
local last = events.events[#events.events]
assert(last.type == 'incident' and last.citizenid == 'cid1', 'event shape')
assert(last.data.invoker == 'custom-director', 'invoker provenance')
""",
        tmp_path,
    )


def test_audit_poll_maps_and_redacts_sensitive_actions(tmp_path: Path) -> None:
    run_lua(
        r"""
AgentOps.State.ring = AgentOps.NewRing(500)
AgentOps.State.auditCursorReady = false
LAST_AUDIT_ID = 42

-- Anchor the cursor at MAX(id) first.
assert(AgentOps.PollAudit() == true)
assert(AgentOps.State.lastAuditId == 42, 'cursor anchored')

AUDIT_ROWS = {
    { id = 43, actor_citizenid = 'cid1', actor_kind = 'player', action = 'duty.set',
      target = 'onduty', detail = 'go on duty' },
    { id = 44, actor_citizenid = 'cid2', actor_kind = 'player', action = 'lookup.citizen.result',
      target = 'cid3', detail = 'John Doe', created_at = '2026-10-24 12:00:00' },
    { id = 45, actor_citizenid = 'system', actor_kind = 'system', action = 'npc.spawn',
      target = 'backup:1', detail = 'backup:1' },
}
assert(AgentOps.PollAudit() == true)
assert(AgentOps.State.lastAuditId == 45, 'cursor advanced')

local events = AgentOps.GetEvents(0, 10).events
assert(#events == 3, 'three events, got ' .. tostring(#events))
assert(events[1].type == 'duty' and events[1].data.target == 'onduty', 'duty mapping')
assert(events[2].type == 'lookup', 'lookup mapping')
assert(events[2].data.redacted == true, 'sensitive redacted')
assert(events[2].data.target == nil and events[2].data.detail == nil, 'PII payload dropped')
assert(events[2].citizenid == 'cid2', 'actor retained')
assert(events[3].type == 'npc', 'npc mapping')

-- Polling again with no new rows does not duplicate.
assert(AgentOps.PollAudit() == true)
assert(#AgentOps.GetEvents(0, 10).events == 3, 'no duplicate events')
""",
        tmp_path,
    )


def test_log_rotation_removes_oldest_archive(tmp_path: Path) -> None:
    archive = tmp_path / "agent-events.jsonl"
    live = tmp_path / "agent-events.jsonl"
    live.write_text("x" * 120, encoding="utf-8")
    (tmp_path / "agent-events.jsonl.1").write_text("old-1", encoding="utf-8")
    (tmp_path / "agent-events.jsonl.2").write_text("old-2", encoding="utf-8")

    run_lua(
        f"""
assert(AgentOps.ShouldRotate(101, 100) == true)
assert(AgentOps.ShouldRotate(100, 100) == false)
assert(AgentOps.RotateFile({str(live)!r}, 2) == true)
local current = io.open({str(live)!r}, 'r')
assert(current == nil, 'live file moved')
local first = io.open({str(live)!r} .. '.1', 'r')
assert(first ~= nil, 'newest archive exists')
first:close()
local second = io.open({str(live)!r} .. '.2', 'r')
assert(second ~= nil, 'previous archive shifted')
local content = second:read('*a')
second:close()
assert(content == 'old-1', 'oldest archive kept the expected content, got ' .. tostring(content))
local third = io.open({str(live)!r} .. '.3', 'r')
assert(third == nil, 'extra archive removed')
""",
        tmp_path,
    )
    assert not archive.exists()
