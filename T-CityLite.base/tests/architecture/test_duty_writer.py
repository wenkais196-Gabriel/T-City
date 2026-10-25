"""FIT-01 — ``job.onduty`` has a single writer: the police duty service.

Static, offline contract (no FXServer, no DB, no network):

* scan the server Lua of ``custom-police`` / ``custom-main`` /
  ``custom-director`` plus the qb-core primitive ``server/player.lua``;
* every ``SetJobDuty(`` call site must be registered in
  ``duty_writers_allowlist.json``; a call in any other file is a violation;
* for the two non-police allowlist entries (``custom-main`` and
  ``custom-director``) every call must additionally sit in a function whose
  body has a police guard (``jobName == 'police'`` / ``type == 'leo'``) *before*
  the call, calls ``SetDutyForSource``, and has an ``else``/``elseif`` between
  the guard and the call — i.e. the call is in the non-police branch, not in
  the police branch;
* the police service file must keep exactly one ``SetJobDuty(`` call, inside
  ``P.SetDutyForSource``;
* a commented-out or long-string call is not a call (comments/long strings are
  masked before matching).

The reverse tests below inject ``Player.Functions.SetJobDuty(true)`` into a
temporary copy of ``custom-main/server/dispatch.lua`` and require the scanner
to fail, both at module scope and inside the police branch.

    python3 -m pytest -q tests/architecture/test_duty_writer.py
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
RESOURCES = BASE / "resources"
REGISTRY = Path(__file__).with_name("duty_writers_allowlist.json")

SCAN_ROOT_GLOB = "*/*/server"
# qb-core is framework vendor code (the task forbids editing it). QBCore:ToggleDuty
# calls the primitive internally; its projection is covered by custom-police's
# OnJobUpdate handler, so it is not a custom writer and not in the allowlist.
FRAMEWORK_INTERNAL_FILES = {"qb-core/server/events.lua"}
# Test-fixture / archived resources are not product writers.
SKIP_RESOURCE_PREFIXES = ("custom-testing/",)
CALL_RE = re.compile(r"\bSetJobDuty\s*\(")
SERVICE_CALL_RE = re.compile(r"\bSetDutyForSource\s*\(")
POLICE_GUARD_RE = re.compile(
    r"(?:jobName|job\.name|currentJob\.name)\s*==\s*'police'"
    r"|(?:currentJob\.type|job\.type|type)\s*==\s*'leo'"
)
NON_POLICE_BRANCH_RE = re.compile(r"\b(?:elseif|else)\b")
TOKEN_RE = re.compile(r"\b(?:function|if|elseif|else|for|while|do|repeat|until|end)\b")
LONG_OPEN = re.compile(r"\[(=*)\[")
REQUIRED_FIELDS = ("id", "file", "kind", "reason", "added")
VALID_KINDS = {"primitive", "service", "non_police_branch"}


@dataclass(frozen=True)
class FunctionRange:
    start: int
    end: int


@dataclass(frozen=True)
class Call:
    file: str
    line: int
    text: str


@dataclass(frozen=True)
class Violation:
    call: Call
    reason: str

    @property
    def where(self) -> str:
        return f"{self.call.file}:{self.call.line}"


# ---------------------------------------------------------------------------
# Lua masking / block structure (comments and long strings first)
# ---------------------------------------------------------------------------

def mask_lua(text: str, blank_strings: bool = False) -> str:
    """Blank comments (and optionally string literals), preserving newlines."""
    out = list(text)
    i, n = 0, len(text)

    def blank(start: int, end: int) -> None:
        for k in range(start, min(end, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        char = text[i]
        if char == "-" and text.startswith("--", i):
            long = LONG_OPEN.match(text, i + 2)
            if long:
                close = "]" + long.group(1) + "]"
                end = text.find(close, long.end())
                end = n if end < 0 else end + len(close)
            else:
                end = text.find("\n", i)
                end = n if end < 0 else end
            blank(i, end)
            i = end
        elif char in "'\"":
            quote = char
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == quote:
                    j += 1
                    break
                j += 1
            if blank_strings:
                blank(i, j)
            i = j
        elif char == "[":
            long = LONG_OPEN.match(text, i)
            if long:
                close = "]" + long.group(1) + "]"
                end = text.find(close, long.end())
                end = n if end < 0 else end + len(close)
                blank(i, end)
                i = end
            else:
                i += 1
        else:
            i += 1
    return "".join(out)


def function_ranges(structured: str) -> list[FunctionRange]:
    """Best-effort function blocks for the repository's Lua style.

    Tracks ``function``/``if``/``for``/``while``/``do``/``repeat`` and their
    closing ``end``/``until`` tokens on the comment/string-free text. A
    function range spans its opening line through the matching ``end`` line.
    """
    ranges: list[FunctionRange] = []
    stack: list[tuple[int, int]] = []  # (depth before function, start line)
    depth = 0
    pending_do = 0
    for lineno, line in enumerate(structured.splitlines(), 1):
        for token in TOKEN_RE.findall(line):
            if token == "function":
                stack.append((depth, lineno))
                depth += 1
            elif token == "if":
                depth += 1
            elif token in ("for", "while"):
                depth += 1
                pending_do += 1
            elif token == "do":
                if pending_do > 0:
                    pending_do -= 1
                else:
                    depth += 1
            elif token == "repeat":
                depth += 1
            elif token in ("end", "until"):
                depth = max(0, depth - 1)
                if token == "end" and stack and depth == stack[-1][0]:
                    _, start_line = stack.pop()
                    ranges.append(FunctionRange(start=start_line, end=lineno))
    return ranges


def enclosing_functions(ranges: list[FunctionRange], line: int) -> list[FunctionRange]:
    """Enclosing function blocks, innermost first."""
    hits = [item for item in ranges if item.start <= line <= item.end]
    return sorted(hits, key=lambda item: item.start, reverse=True)


# ---------------------------------------------------------------------------
# Scanner
# ---------------------------------------------------------------------------

def load_registry() -> dict:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def rel_key(path: Path, root: Path) -> str:
    # [custom]/custom-main/server/x.lua -> custom-main/server/x.lua
    return "/".join(path.relative_to(root).parts[1:])


def scan(root: Path = RESOURCES) -> tuple[list[Call], list[Violation]]:
    registry = load_registry()
    entries = {entry["file"]: entry for entry in registry["entries"]}
    calls: list[Call] = []

    for server_dir in sorted(item for item in root.glob(SCAN_ROOT_GLOB) if item.is_dir()):
        for path in sorted(server_dir.rglob("*.lua")):
            key = rel_key(path, root)
            if key in FRAMEWORK_INTERNAL_FILES or key.startswith(SKIP_RESOURCE_PREFIXES):
                continue
            text = path.read_text(encoding="utf-8")
            code = mask_lua(text, blank_strings=True)
            raw_lines = text.splitlines()
            for match in CALL_RE.finditer(code):
                line = code.count("\n", 0, match.start()) + 1
                calls.append(Call(file=key, line=line, text=raw_lines[line - 1].strip()))

    violations: list[Violation] = []
    for call in calls:
        entry = entries.get(call.file)
        if entry is None:
            violations.append(Violation(call, "unregistered_writer"))
            continue
        if entry["kind"] in ("primitive", "service"):
            continue

        path = root / "[custom]" / call.file if call.file.startswith("custom-") else root / call.file
        text = path.read_text(encoding="utf-8")
        masked = mask_lua(text)
        structured = mask_lua(text, blank_strings=True)
        ranges = function_ranges(structured)
        funcs = enclosing_functions(ranges, call.line)
        if not funcs:
            violations.append(Violation(call, "outside_function"))
            continue

        # The call may sit inside an inline `function()` closure (pcall). Walk
        # outwards: the guard and service call live in the enclosing handler.
        reason = "no_police_guard_before_call"
        matched = False
        for func in funcs:
            func_lines = masked.splitlines()[func.start - 1:func.end]
            before_call = "\n".join(masked.splitlines()[func.start - 1:call.line])
            whole_func = "\n".join(func_lines)

            if not SERVICE_CALL_RE.search(whole_func):
                reason = "no_duty_service_in_function"
                continue
            guard = None
            for match in POLICE_GUARD_RE.finditer(before_call):
                guard = match
            if guard is None:
                reason = "no_police_guard_before_call"
                continue
            if not NON_POLICE_BRANCH_RE.search(before_call[guard.end():]):
                reason = "not_in_non_police_branch"
                continue
            matched = True
            break
        if not matched:
            violations.append(Violation(call, reason))

    return calls, violations


def format_violations(violations: list[Violation]) -> str:
    if not violations:
        return "FIT-01 PASS 0 unregistered SetJobDuty writers"
    lines = [f"FIT-01 FAIL {len(violations)} unregistered SetJobDuty writer(s)"]
    lines.extend(f"  {item.where} {item.call.text}  {item.reason}" for item in violations)
    return "\n".join(lines)


def write_fixture(root: Path, files: dict[str, str]) -> Path:
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return root


def real_file(rel: str) -> str:
    # rel is the allowlist key, e.g. custom-main/server/dispatch.lua
    prefix = "[qb]/" if rel.startswith("qb-core/") else "[custom]/"
    return (RESOURCES / prefix / rel).read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# Scanner tests
# ---------------------------------------------------------------------------

def test_allowlist_is_well_formed() -> None:
    registry = load_registry()
    assert registry["version"] == 1
    assert registry["rule"] == "FIT-01"
    entries = registry["entries"]
    assert len(entries) == 3, "allowlist must register the remaining FIT-01 writers"
    files = [entry["file"] for entry in entries]
    assert sorted(files) == [
        "custom-director/server/main.lua",
        "custom-main/server/dispatch.lua",
        "qb-core/server/player.lua",
    ]
    for entry in entries:
        for field in REQUIRED_FIELDS:
            assert entry.get(field), f"{entry.get('id')}: missing {field}"
        assert entry["kind"] in VALID_KINDS, entry["id"]
        assert "expires" in entry, f"{entry['id']}: expires must be explicit (null for owners)"
        assert (RESOURCES / ("[qb]/" if entry["file"].startswith("qb-core/") else "[custom]")
                / entry["file"]).is_file(), entry["file"]

    for entry in entries:
        if entry["kind"] == "non_police_branch":
            assert "非 leo / ambulance/mechanic/taxi" in entry["reason"], entry["id"]
            assert entry.get("guard"), entry["id"]


def test_scan_passes_with_zero_unregistered_writers() -> None:
    calls, violations = scan()
    assert calls, "scanner found no SetJobDuty call sites; paths are wrong"
    assert violations == [], format_violations(violations)
    # Every allowlisted file must be an actual writer (stale registry guard).
    registered = {entry["file"] for entry in load_registry()["entries"]}
    assert {call.file for call in calls} == registered
    assert format_violations(violations) == "FIT-01 PASS 0 unregistered SetJobDuty writers"


def test_reverse_adding_setjobduty_at_module_scope_fails(tmp_path: Path) -> None:
    source = real_file("custom-main/server/dispatch.lua")
    injected = source + "\nPlayer.Functions.SetJobDuty(true)\n"
    root = write_fixture(
        tmp_path / "resources",
        {"[custom]/custom-main/server/dispatch.lua": injected},
    )
    _, violations = scan(root)
    assert len(violations) == 1, format_violations(violations)
    assert violations[0].where.endswith("dispatch.lua:{}".format(source.count("\n") + 2))
    assert violations[0].reason == "outside_function", format_violations(violations)


def test_reverse_adding_setjobduty_inside_police_branch_fails(tmp_path: Path) -> None:
    source = real_file("custom-main/server/dispatch.lua")
    lines = source.splitlines()
    guard = next(i for i, line in enumerate(lines) if "if jobName == 'police' then" in line)
    lines.insert(guard + 1, "        Player.Functions.SetJobDuty(true)")
    root = write_fixture(
        tmp_path / "resources",
        {"[custom]/custom-main/server/dispatch.lua": "\n".join(lines) + "\n"},
    )
    _, violations = scan(root)
    assert len(violations) == 1, format_violations(violations)
    assert violations[0].where.endswith(f"dispatch.lua:{guard + 2}")
    assert violations[0].reason == "not_in_non_police_branch", format_violations(violations)


def test_reverse_unregistered_file_fails(tmp_path: Path) -> None:
    root = write_fixture(
        tmp_path / "resources",
        {"[custom]/custom-career/server/rogue.lua": "Player.Functions.SetJobDuty(true)\n"},
    )
    _, violations = scan(root)
    assert violations, "an unregistered writer file must fail"
    assert violations[0].where == "custom-career/server/rogue.lua:1"
    assert violations[0].reason == "unregistered_writer", format_violations(violations)


def test_commented_and_quoted_calls_are_ignored(tmp_path: Path) -> None:
    source = (
        "-- Player.Functions.SetJobDuty(true)\n"
        "--[[ Player.Functions.SetJobDuty(false) ]]\n"
        "local message = 'never call SetJobDuty(true)'\n"
    )
    root = write_fixture(
        tmp_path / "resources",
        {"[custom]/custom-police/server/rogue.lua": source},
    )
    calls, violations = scan(root)
    assert calls == [] and violations == [], format_violations(violations)


# ---------------------------------------------------------------------------
# Server-side contract tests (source shape, same rule as the scanner)
# ---------------------------------------------------------------------------

def body_of(rel: str, marker: str) -> str:
    text = real_file(rel)
    start = text.index(marker)
    start_line = text.count("\n", 0, start) + 1
    ranges = function_ranges(mask_lua(text, blank_strings=True))
    func = next((item for item in ranges if item.start == start_line), None)
    assert func is not None, f"no function block starts at {rel}:{start_line}"
    return "\n".join(text.splitlines()[func.start - 1:func.end])


def test_police_service_is_the_only_p0_writer() -> None:
    source = real_file("custom-police/server/p0.lua")
    code = mask_lua(source, blank_strings=True)
    structured = mask_lua(source, blank_strings=True)
    ranges = function_ranges(structured)
    calls = [code.count("\n", 0, match.start()) + 1 for match in CALL_RE.finditer(code)]
    assert calls == [], f"the service owns the projection, no direct SetJobDuty in p0: {calls}"

    body = body_of("custom-police/server/p0.lua", "function P.SetDutyForSource(")
    assert "local data = pd(source)" in body
    assert "if not isPolice(data) then return false, 'not_police' end" in body
    assert "if onDuty ~= true and onDuty ~= false then return false, 'duty_failed' end" in body
    assert "player.PlayerData.job.onduty = onDuty" in body
    assert "TriggerEvent('QBCore:Server:OnJobUpdate'" in body
    assert "TriggerClientEvent('QBCore:Client:OnJobUpdate'" in body
    assert "syncDuty(live)" in body
    assert "takeUnitOffDuty(live.citizenid)" in body
    assert "live.job.onduty ~= onDuty" in body
    assert "onDuty and 'on' or 'off'" in body
    assert "audit(live.citizenid, 'duty.set'" in body
    assert "return true" in body
    assert "exports('SetDutyForSource', P.SetDutyForSource)" in source


def test_10_8_and_10_7_call_the_duty_service() -> None:
    body = body_of("custom-police/server/p0.lua", "function P.SetUnitStatusForSource(")
    assert "P.SetDutyForSource(source, false, 'unit_status')" in body
    assert "P.SetDutyForSource(source, true, 'unit_status')" in body
    assert "player.Functions.SetJobDuty" not in body
    assert "upsertUnit(data.citizenid, callsign, 'off_duty')" in body
    assert "upsertUnit(data.citizenid, callsign, 'available')" in body


def test_set_unit_status_off_duty_calls_the_service_and_keeps_offline_path() -> None:
    body = body_of("custom-police/server/p0.lua", "function P.SetUnitStatus(")
    assert "P.SetDutyForSource(player.PlayerData.source, false, 'unit_status')" in body
    assert "player.Functions.SetJobDuty" not in body
    assert "elseif not player then" in body, "offline citizen may only park the unit row"
    assert "return false, 'not_on_duty'" in body


def test_custom_main_quick_command_prefers_the_police_export() -> None:
    body = body_of("custom-main/server/dispatch.lua", "QBCore.Commands.Add('duty'")
    assert "if jobName == 'police' then" in body
    assert "SetDutyForSource(src, newDuty, 'quick_command')" in body
    service_at = body.index("SetDutyForSource(src, newDuty, 'quick_command')")
    direct_at = body.index("Player.Functions.SetJobDuty(newDuty)")
    assert service_at < direct_at
    # The direct call is only reachable from the non-police branch.
    branch_at = body.index("elseif jobName == 'ambulance' or jobName == 'mechanic' or jobName == 'taxi' then")
    assert branch_at < direct_at
    assert "切换执勤失败" in body and "return" in body


def test_custom_main_wanted_lock_prefers_the_police_export() -> None:
    body = body_of("custom-main/server/dispatch.lua", "AddEventHandler('QBCore:Server:OnJobUpdate'")
    assert "SetDutyForSource(src, false, 'wanted_lock')" in body
    assert "if jobName == 'police' then" in body
    service_at = body.index("SetDutyForSource(src, false, 'wanted_lock')")
    direct_at = body.index("Player.Functions.SetJobDuty(false)")
    branch_at = body.index("else", body.index("if jobName == 'police' then"))
    assert service_at < branch_at < direct_at


def test_custom_director_set_job_duty_prefers_the_police_export() -> None:
    body = body_of("custom-director/server/main.lua", "local function executeSetJobDuty(")
    assert "currentJob.type == 'leo' or currentJob.name == 'police'" in body
    assert "SetDutyForSource(source, params.onduty, 'director')" in body
    service_at = body.index("SetDutyForSource(source, params.onduty, 'director')")
    direct_at = body.index("player.Functions.SetJobDuty(params.onduty)")
    branch_at = body.index("else", body.index("if currentJob.type == 'leo'"))
    assert service_at < branch_at < direct_at
    # Existing return / verification shape is preserved.
    assert "execution_failed: SetDutyForSource threw: %s" in body
    assert "execution_failed: SetDutyForSource rejected: %s" in body
    assert "verification_failed before=%s after=%s expected=%s" in body
    assert "verify_result = true" in body
