"""FIT-03 — every net event must be authenticated or explicitly registered.

Static, offline contract (no FXServer, no DB, no network):

* scan ``custom-police/server/**/*.lua`` and ``custom-phone/server/**/*.lua``;
* for every ``RegisterNetEvent('name', function ... end)`` extract the handler
  body up to the first top-level ``end)`` (this repo's indentation style);
* the body must contain a unified auth decision: ``PolicePolicy.Can``,
  ``PolicePolicy.Check``, ``hasCapability``, ``IsPlayerAceAllowed``, a
  system-source guard (``src == 0`` / ``src ~= 0 then return``) or one of the
  project helpers listed in ``AUTH_HELPERS`` (each helper is checked to really
  call ``PolicePolicy.Can`` below, so the indirection cannot rot);
* otherwise the event must be registered in ``net_events_allowlist.json`` with
  name / category / reason / owner / expires, and the category's claim must be
  visible in the handler body (a manual ``job.type`` check really exists, a
  civilian path really validates, a session path really binds to the caller).

Anything else fails, so a new unguarded net event cannot land silently.

    python3 -m pytest -q tests/architecture/test_net_event_auth.py
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
RESOURCES = BASE / "resources"
CUSTOM = RESOURCES / "[custom]"
DIAG_MODULE = CUSTOM / "custom-phone" / "server" / "core" / "diag.lua"
SCAN_DIRS = (
    ("custom-police", CUSTOM / "custom-police" / "server"),
    ("custom-phone", CUSTOM / "custom-phone" / "server"),
    # 2026-10-25: 框架自己也有 net event（客户端诊断通道等），之前完全没被扫过
    ("core-framework", BASE / "resources" / "[standalone]" / "core-framework" / "server"),
)
ALLOWLIST = Path(__file__).with_name("net_events_allowlist.json")

REGISTER_RE = re.compile(r"""^\s*RegisterNetEvent\(\s*(['"])(?P<name>[^'"]+)\1""")
END_RE = re.compile(r"^end\)\s*$")
MAX_BLOCK_LINES = 400

# A token that proves a unified auth decision inside the handler body.
STRONG_TOKENS = {
    "PolicePolicy.Can": re.compile(r"PolicePolicy\.Can\("),
    "PolicePolicy.Check": re.compile(r"PolicePolicy\.Check\("),
    "hasCapability": re.compile(r"\bhasCapability\b"),
    "IsPlayerAceAllowed": re.compile(r"IsPlayerAceAllowed\("),
    "system_source": re.compile(r"\bsrc\s*==\s*0\b|\bsrc\s*~=\s*0\s+then\s+return\b"),
}

# Project helpers that wrap PolicePolicy.Can. Verified in
# test_auth_helpers_really_enforce_policypolicy so the allowlist cannot hide a
# helper that stopped checking.
AUTH_HELPERS = {
    "onDutyOfficer": (
        CUSTOM / "custom-police" / "server" / "evidence.lua",
        "PolicePolicy.Can(",
    ),
    "NPC.SubmitResult": (
        CUSTOM / "custom-police" / "server" / "p4_npc.lua",
        "PolicePolicy.Can(",
    ),
}

# What each allowlist category promises, and the token that must back it up.
MANUAL_CHECK = re.compile(r"job\.type|[Ii]sPolice|onduty|hasCapability|GetItemByName")
CIVILIAN_GUARD = re.compile(
    r"type\(|tonumber\(|sanitize|COOLDOWN|cooldown|coordsNearSource|updatingCops|"
    r"metadata\[|evidenceInfo|diff\("
)
SESSION_BIND = re.compile(
    r"metadata|taken_by|receiver_number|units\[requestId\]|"
    r"(?:StoreNotification|PhoneNotify\.Store)\(source|"
    r"ResolveSource\(source\)|GetPlayer\(targetSrc"
)
DIAGNOSTIC_GUARD = re.compile(
    # 2026-10-25: 框架的诊断通道走限流 owner，不叫 COOLDOWN 也不叫 PhoneDiag.Accept
    r"COOLDOWN|cooldown|diagRateLimited|PHASES|PhoneDiag\.Accept|"
    r"RateLimitWindow|RateLimitCooldown|RateLimitTokenBucket"
)

REQUIRED_FIELDS = ("name", "file", "category", "reason", "evidence", "owner", "expires")
DEBT_CATEGORIES = {"unchecked_debt"}


@dataclass(frozen=True)
class Event:
    name: str
    resource: str
    path: Path
    line: int
    body: str

    @property
    def where(self) -> str:
        rel = self.path.relative_to(RESOURCES).as_posix()
        return f"{rel}:{self.line}"


def lua_files() -> list[Path]:
    files: list[Path] = []
    for _, directory in SCAN_DIRS:
        assert directory.is_dir(), f"missing scan directory: {directory}"
        files.extend(sorted(directory.rglob("*.lua")))
    return files


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def scan_events() -> tuple[list[Event], list[str]]:
    """Return (events, problems). A problem is an unterminated handler."""
    events: list[Event] = []
    problems: list[str] = []
    for resource, directory in SCAN_DIRS:
        for path in sorted(directory.rglob("*.lua")):
            lines = read(path).splitlines()
            for index, line in enumerate(lines):
                match = REGISTER_RE.match(line)
                if not match:
                    continue
                name = match.group("name")
                body: list[str] = []
                cursor = index + 1
                while cursor < len(lines):
                    if END_RE.match(lines[cursor]):
                        break
                    body.append(lines[cursor])
                    cursor += 1
                    if len(body) > MAX_BLOCK_LINES:
                        problems.append(
                            f"{path.relative_to(RESOURCES).as_posix()}:{index + 1} "
                            f"{name} no top-level 'end)' within {MAX_BLOCK_LINES} lines"
                        )
                        body = []
                        cursor = len(lines)
                        break
                if cursor >= len(lines) and not body:
                    # Either the block was terminated exactly on the last line
                    # (ok) or we bailed out above (already reported).
                    if not any(name in p for p in problems):
                        problems.append(
                            f"{path.relative_to(RESOURCES).as_posix()}:{index + 1} "
                            f"{name} unterminated handler"
                        )
                    continue
                events.append(
                    Event(name=name, resource=resource, path=path, line=index + 1,
                          body="\n".join(body))
                )
    return events, problems


def auth_tokens(body: str) -> list[str]:
    found = [token for token, pattern in STRONG_TOKENS.items() if pattern.search(body)]
    found += [helper for helper in AUTH_HELPERS if re.search(rf"\b{re.escape(helper)}\(", body)]
    return found


def load_allowlist() -> dict:
    with ALLOWLIST.open(encoding="utf-8") as handle:
        return json.load(handle)


def allowlist_entries() -> dict[str, dict]:
    data = load_allowlist()
    return {entry["name"]: entry for entry in data.get("entries", [])}


def unregistered(events: list[Event]) -> list[Event]:
    registered = allowlist_entries()
    return [event for event in events if not auth_tokens(event.body) and event.name not in registered]


def report() -> str:
    events, problems = scan_events()
    registered = allowlist_entries()
    bad = unregistered(events)
    guarded = sum(1 for event in events if auth_tokens(event.body))
    lines = [
        f"FIT-03 net-event-auth  {'FAIL' if (bad or problems) else 'PASS'}  "
        f"{len(bad)}/{len(events)} unguarded",
    ]
    for event in bad:
        lines.append(f"  {event.where}  {event.name}  no_auth")
    for problem in problems:
        lines.append(f"  SKIP {problem}")
    lines.append(
        '  summary: {"rule":"FIT-03","events":%d,"strong_auth":%d,"allowlisted":%d,'
        '"violations":%d,"skipped":%d}'
        % (len(events), guarded, len(registered), len(bad), len(problems))
    )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Scanner sanity
# ---------------------------------------------------------------------------

def test_scanner_covers_both_resources_and_every_handler_terminates():
    events, problems = scan_events()
    assert problems == [], "unparsable handlers:\n" + "\n".join(problems)
    # A broken terminator heuristic would silently skip handlers, so pin the
    # shape: 40+ handlers across the two resources.
    assert len(events) >= 40, f"only {len(events)} net events found — scanner regression?"
    # 2026-10-25: 范围加了 core-framework（框架自己的 net event 之前没被扫过）
    assert {event.resource for event in events} == {"custom-police", "custom-phone", "core-framework"}
    assert all(event.name for event in events)
    assert all(len(event.body) > 0 for event in events)
    names = [event.name for event in events]
    assert len(names) == len(set(names)), "duplicate net event registration"


# ---------------------------------------------------------------------------
# The rule itself
# ---------------------------------------------------------------------------

def test_every_net_event_is_authenticated_or_registered():
    events, problems = scan_events()
    assert problems == [], "unparsable handlers:\n" + "\n".join(problems)
    bad = unregistered(events)
    if bad:
        detail = "\n".join(
            f"  {event.where}  {event.name}  no_auth — add PolicePolicy.Can(...) "
            f"inside the handler, or register it in "
            f"tests/architecture/net_events_allowlist.json"
            for event in bad
        )
        raise AssertionError(
            f"FIT-03: {len(bad)}/{len(events)} net events have no auth token:\n{detail}"
        )
    # Every allowlisted event must still exist (no dead exemption, no typo).
    names = {event.name for event in events}
    stale = sorted(set(allowlist_entries()) - names)
    assert stale == [], f"allowlist entries for events that no longer exist: {stale}"


def test_allowlist_entries_carry_a_reason_owner_and_expiry():
    data = load_allowlist()
    entries = data.get("entries", [])
    assert entries, "allowlist is empty — the rule would pass with no documentation"
    known_categories = set(data["categories"])
    today = date.today()
    seen: set[str] = set()
    for entry in entries:
        name = entry.get("name", "?")
        for field in REQUIRED_FIELDS:
            value = entry.get(field)
            assert isinstance(value, str) and value.strip(), f"{name}: missing {field}"
        assert name not in seen, f"duplicate allowlist entry: {name}"
        seen.add(name)
        assert entry["category"] in known_categories, (
            f"{name}: unknown category {entry['category']!r}"
        )
        # owner 的"必须是所属资源"由 test_allowlisted_events_* 里对 path/resource 的
        # 一致性检查覆盖（2026-10-25: 原来这里写死两个资源名，框架加进扫描范围后就登不了了）
        expires = date.fromisoformat(entry["expires"])
        assert expires >= today, (
            f"{name}: allowlist entry expired on {entry['expires']} — re-review the "
            f"handler and either fix it or renew with a new justification "
            f"(hard expiry is the point of the allowlist)"
        )



def allowlist_path(file_field: str) -> Path:
    """allowlist 里的 ``file`` 到真实路径。

    约定：[custom] 下的资源省略括号目录（``custom-police/server/x.lua``），
    其它分组必须带前缀（``[standalone]/core-framework/server/x.lua``）。
    2026-10-25 之前这里写死 ``CUSTOM / file``，于是框架资源没法登记。
    """
    return RESOURCES / file_field if file_field.startswith("[") else CUSTOM / file_field


def test_allowlisted_events_really_show_the_claim_in_their_body():
    """A category is a promise; check the handler still keeps it."""
    events = {event.name: event for event in scan_events()[0]}
    for name, entry in allowlist_entries().items():
        event = events[name]
        assert event.path == allowlist_path(entry["file"]), (
            f"{name}: allowlist says {entry['file']} but the handler is at {event.where}"
        )
        category = entry["category"]
        if category == "already_checked":
            assert MANUAL_CHECK.search(event.body), (
                f"{name}: registered as already_checked but no job/onduty/item check "
                f"in the handler body — fix the handler or change the category"
            )
        elif category == "civilian":
            assert CIVILIAN_GUARD.search(event.body), (
                f"{name}: registered as civilian but the handler does not validate or "
                f"rate limit anything"
            )
        elif category == "session":
            assert SESSION_BIND.search(event.body), (
                f"{name}: registered as session-bound but the handler never binds to "
                f"the caller's own session/ownership"
            )
        elif category == "diagnostic":
            assert DIAGNOSTIC_GUARD.search(event.body), (
                f"{name}: registered as diagnostic but no rate limit / field whitelist"
            )
        # unchecked_debt carries no claim beyond the reason + expiry.


def test_diag_helper_really_limits_and_sanitizes():
    """`PhoneDiag.Accept` satisfies the diagnostic guard by delegation, so the
    claim has to hold where the delegation lands — same idea as AUTH_HELPERS."""
    source = read(DIAG_MODULE)
    for token in (
        "function PhoneDiag.Accept",
        "PhoneDiag.Sanitize",
        "allowTrace",
        "allowUi",
        "printBudgetOk",
        "TRACE_PER_MIN = ",
        "TRACE_BURST = ",
        "UI_COOLDOWN_MS = ",
        "PRINT_BUDGET_PER_SEC = ",
    ):
        assert token in source, f"doc claims {token!r} but it is gone from {DIAG_MODULE.name}"


def test_auth_helpers_really_enforce_policypolicy():
    """The allowlist trusts helpers; verify each one still calls the policy."""
    for helper, (path, token) in AUTH_HELPERS.items():
        source = read(path)
        pattern = re.compile(
            rf"(?:local )?function {re.escape(helper)}\([^)]*\)(.*?)^end\s*$",
            re.DOTALL | re.MULTILINE,
        )
        match = pattern.search(source)
        assert match, f"auth helper {helper} is not defined in {path.name} anymore"
        assert token in match.group(1), (
            f"auth helper {helper} in {path.name} no longer calls {token} — "
            f"every event using it is now unguarded"
        )


def test_civilian_and_police_entry_points_exist_in_both_resources():
    """Guard against a rename that makes this suite silently vacuous."""
    events = {event.name: event for event in scan_events()[0]}
    for name in (
        "police:server:policeAlert",   # civilian report entry point
        "police:server:autoAlert",     # strong-auth reference implementation
        "evidence:server:CreateBloodDrop",
        "evidence:server:ClearBlooddrops",
        "phone:server:focusState",
        "phone:server:clientError",
    ):
        assert name in events, f"{name} disappeared — update the FIT-03 baseline"


def test_no_auth_token_is_smuggled_in_via_a_comment():
    """Tokens inside comments do not count... unless the body really checks.

    This is a cheap guard: a handler whose *only* strong token appears on a
    `--` line is reported, because a commented-out check is not a check.
    """
    offenders = []
    for event in scan_events()[0]:
        if not auth_tokens(event.body):
            continue
        code = "\n".join(
            line for line in event.body.splitlines() if not line.lstrip().startswith("--")
        )
        if not auth_tokens(code):
            offenders.append(event.where + " " + event.name)
    assert offenders == [], f"auth token only appears in comments: {offenders}"


if __name__ == "__main__":  # pragma: no cover - manual runner
    print(report())


# ---------------------------------------------------------------------------
# 注册形式本身也是一条规则：必须写字面量
# ---------------------------------------------------------------------------

REGISTER_ANY = re.compile(r"RegisterNetEvent\s*\(\s*(?P<arg>[^,\n)]+)")


def non_literal_registrations() -> list[str]:
    """返回"第一个参数不是字符串字面量"的注册点。

    为什么必须钉这条：扫描器按字面量取事件名，`RegisterNetEvent(EVENT_NAME, ...)`
    会让整条事件对闸门不可见——而诊断类事件能往服务端日志写字，看不见就等于没管。
    实证：框架的客户端诊断通道第一版就是这么写的，加进 SCAN_DIRS 后依然"8 passed"。
    """
    offenders = []
    for _resource, directory in SCAN_DIRS:
        for path in sorted(directory.rglob("*.lua")):
            for index, line in enumerate(read(path).splitlines(), 1):
                match = REGISTER_ANY.match(line.strip())
                if not match:
                    continue
                arg = match.group("arg").strip()
                if arg[:1] in ("'", '"'):
                    continue
                try:
                    where = path.relative_to(RESOURCES).as_posix()
                except ValueError:          # 反向校验用的是临时目录
                    where = path.as_posix()
                offenders.append(f"{where}:{index}  RegisterNetEvent({arg} ...)")
    return offenders


def test_net_event_registration_uses_a_literal_name():
    offenders = non_literal_registrations()
    assert not offenders, (
        "这些 net event 用变量名注册，架构闸门看不见它们（等于没管）：\n  " + "\n  ".join(offenders))


def test_literal_rule_fires_on_the_variable_form(tmp_path: Path):
    """反向校验：把变量形式喂给判定函数，必须被抓到。"""
    spike = tmp_path / "spike.lua"
    spike.write_text("RegisterNetEvent(EVENT_NAME, function() end)\n", encoding="utf-8")
    original = globals()["SCAN_DIRS"]
    try:
        globals()["SCAN_DIRS"] = (("spike", tmp_path),)
        assert non_literal_registrations(), "变量名注册必须被判为违规"
        spike.write_text("RegisterNetEvent('x:server:y', function() end)\n", encoding="utf-8")
        assert not non_literal_registrations(), "字面量注册不该被误报"
    finally:
        globals()["SCAN_DIRS"] = original
