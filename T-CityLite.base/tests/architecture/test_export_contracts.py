"""FIT-04 — every police export must carry a stable contract.

Static, offline contract over ``custom-police/server/**/*.lua`` (no FXServer,
no DB, no network). Every value registered with ``exports('Name', target)`` is
resolved to its implementation body (named function or inline function) and
must satisfy three rules:

* **gate** — the body contains a permission/source decision:
  ``PolicePolicy.Can`` / ``PolicePolicy.Check`` / ``PolicePolicy.IsPolice`` /
  ``isPolice`` / ``hasCapability`` / ``IsPlayerAceAllowed``, a verified gate
  helper (``lookupAllowed``), or an explicit ownership comparison
  (``row.citizenid ~= actor.citizenid``). Purely internal exports whose caller
  is an owner resource or the scheduler must be registered as ``system_only``
  (or one of the other explicit kinds) in ``export_allowlist.json``;
* **write audit** — an export whose body mutates (``INSERT`` / ``UPDATE`` /
  ``DELETE``) must call ``audit()``; a write path without a forensic row is a
  violation even when the error codes are correct;
* **error code** — every failure return carries a stable ``snake_case`` string:
  ``return false, '<code>'`` / ``return nil, '<code>'`` / ``fail('<code>')``.
  A bare ``return false`` / ``return nil`` (including the ``then return false
  end`` form) is a violation;
* **sensitive read** — a read that gates a ``.view`` / ``.detail`` / ``.chain``
  capability, or that returns PII (citizenid / names / descriptions / bodies),
  must write its audit row **before** the first query and fail closed with
  ``false, 'audit_unavailable'`` when the audit write fails. Delegating to the
  verified ``lookupAllowed`` helper counts.

``export_allowlist.json`` is an ownership registry for exports that cannot
satisfy one of the rules (static catalogues, citizen-owned reads, the agent
bridge's system-only writes). It is not a place to hide new debt: every entry
must name the export, the exact exception(s) it covers, a reason, an owner and
an ``expires`` date. Expired entries, unknown exports, duplicate entries and
entries whose listed exceptions no longer match the code all FAIL.

    python3 -m pytest -q tests/architecture/test_export_contracts.py
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import date
from functools import lru_cache
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
POLICE = BASE / "resources" / "[custom]" / "custom-police"
SERVER = POLICE / "server"
ALLOWLIST = Path(__file__).with_name("export_allowlist.json")

EXPORT_PREFIX_RE = re.compile(
    r"""^\s*exports\(\s*(?P<quote>['"])(?P<name>[^'"]+)(?P=quote)\s*,\s*(?P<rest>.*)$"""
)
FUNCTION_RE = re.compile(r"^(?:local\s+)?function\s+(?P<name>[A-Za-z_][\w.:]*)\s*\(")
TOP_END_RE = re.compile(r"^end\s*$")
EXPORT_END_RE = re.compile(r"^end\)\s*$")

# The body is analysed with comments removed so a comment such as
# "TODO: call PolicePolicy.Can" can never satisfy the gate.
LONG_COMMENT_RE = re.compile(r"--\[(=*)\[.*?\]\1\]", re.DOTALL)
LINE_COMMENT_RE = re.compile(r"--[^\n]*")

# Permission / source decisions accepted as a gate.
AUTH_RE = re.compile(
    r"PolicePolicy\.(?:Can|Check|IsPolice)\("
    r"|\bisPolice\("
    r"|\bhasCapability\("
    r"|IsPlayerAceAllowed\("
    r"|lookupAllowed\("
    r"|row\.citizenid\s*~=\s*actor\.citizenid\b"
)

CAPABILITY_RE = re.compile(r"PolicePolicy\.Can\(\s*[^,]+,\s*'(?P<cap>[\w.]+)'")
SENSITIVE_CAPS = (".view", ".detail", ".chain")
READ_NAME_RE = re.compile(r"^(?:Get|Lookup|Read|List)", re.IGNORECASE)
SQL_SELECT_RE = re.compile(r"\bSELECT\b", re.IGNORECASE)
SQL_WRITE_RE = re.compile(r"\b(?:INSERT|UPDATE|DELETE)\b", re.IGNORECASE)
PII_RE = re.compile(
    r"\b(?:citizenid|charinfo|firstname|lastname|birthdate|description|summary"
    r"|subject_citizenid|officer_citizenid|author_citizenid|collected_by)\b"
)

AUDIT_CALL_RE = re.compile(r"\b(?:audit|auditPlayer|auditNpc)\s*\(")
AUDIT_GATE_RE = re.compile(r"if\s+not\s+audit(?:Player)?\s*\(")
AUDIT_FAIL_CLOSED = "'audit_unavailable'"
GATE_HELPER_RE = re.compile(r"\blookupAllowed\s*\(")

# ``return false`` / ``return nil`` with no string payload. The trailing text
# distinguishes the legal ``return false, 'code'`` from ``return false end``.
FAILURE_RETURN_RE = re.compile(r"\breturn\s+(?P<value>false|nil)\b(?P<rest>[^\n]*)")

VALID_EXCEPTIONS = {"auth", "write_audit", "error_code", "sensitive_read_audit"}
VALID_KINDS = {
    "system_only",
    "civilian_entry",
    "citizen_owned",
    "static_catalog",
    "diagnostic_read",
    "internal_read",
}
REQUIRED_FIELDS = (
    "id", "file", "export", "kind", "exceptions", "reason", "owner", "added", "expires",
)


@dataclass(frozen=True)
class Export:
    name: str
    path: Path
    line: int
    target: str
    body: str

    @property
    def key(self) -> str:
        return f"custom-police/{self.path.relative_to(POLICE).as_posix()}"


@dataclass(frozen=True)
class Violation:
    export: Export
    code: str
    detail: str

    def __str__(self) -> str:
        return f"{self.export.key}:{self.export.line} {self.export.name} {self.code} ({self.detail})"


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def lua_files() -> list[Path]:
    assert SERVER.is_dir(), f"missing {SERVER}"
    return sorted(SERVER.rglob("*.lua"))


def strip_comments(text: str) -> str:
    text = LONG_COMMENT_RE.sub("", text)
    return LINE_COMMENT_RE.sub("", text)


@lru_cache(maxsize=1)
def named_functions() -> dict[str, tuple[Path, int, str]]:
    """Top-level ``function Name(...)`` -> (path, line, body)."""
    found: dict[str, tuple[Path, int, str]] = {}
    for path in lua_files():
        lines = read(path).splitlines()
        for index, line in enumerate(lines):
            match = FUNCTION_RE.match(line)
            if not match:
                continue
            body: list[str] = []
            # 单行函数（`local function x() return I.x() end`）没有后续行可吞：
            # 不判这一条，body 会一路吃到下一个 `end`，把别人的 SQL 记到它头上。
            if not re.search(r"\bend\s*$", line):
                cursor = index + 1
                while cursor < len(lines) and not TOP_END_RE.match(lines[cursor]):
                    body.append(lines[cursor])
                    cursor += 1
            candidate = (path, index + 1, "\n".join(body))
            existing = found.get(match.group("name"))
            # 拆模块后同一个名字会出现两次：实现（p0_units.lua）和按需解析的转发壳
            # （`return I.foo(...)`）。空壳不能覆盖实现，否则"这个导出委派给了写者"
            # 会被判成"它自己什么都没写"，导出契约闸门就开始误报。
            if existing is None or (not existing[2].strip() and candidate[2].strip()):
                found[match.group("name")] = candidate
    return found


def inline_function_body(lines: list[str], index: int, rest: str) -> str:
    """Body of ``exports('X', function(...) ... end)`` starting at ``index``."""
    # One-line form: the target on the same line already ends with `end)`.
    if re.search(r"\bend\)\s*$", rest):
        return rest[: rest.rfind("end")]

    body = [rest]
    cursor = index + 1
    while cursor < len(lines) and not EXPORT_END_RE.match(lines[cursor]):
        body.append(lines[cursor])
        cursor += 1
    return "\n".join(body)


def scan_exports() -> tuple[list[Export], list[str]]:
    """Return (exports, parse problems)."""
    functions = named_functions()
    exports: list[Export] = []
    problems: list[str] = []

    for path in lua_files():
        lines = read(path).splitlines()
        for index, line in enumerate(lines):
            match = EXPORT_PREFIX_RE.match(line)
            if not match:
                continue
            name = match.group("name")
            rest = match.group("rest").strip()
            target: str
            if rest.startswith("function"):
                target = "<inline function>"
                body = inline_function_body(lines, index, rest)
            else:
                target = rest
                if target.endswith(")"):
                    target = target[:-1].rstrip()
                resolved = functions.get(target)
                if resolved is None:
                    problems.append(
                        f"{path.name}:{index + 1} {name} target {target!r} not found"
                    )
                    body = ""
                else:
                    body = resolved[2]
            exports.append(
                Export(name=name, path=path, line=index + 1, target=target, body=body)
            )
    return exports, problems


# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

def is_read(export: Export) -> bool:
    body = strip_comments(export.body)
    if READ_NAME_RE.match(export.name):
        return True
    if SQL_WRITE_RE.search(body):
        return False
    # 写被委派给 owner 之后，函数体外只剩 SELECT —— 但它在语义上仍是"动作"，
    # 不是"读导出"。不判这一条，PayCitation 会被误判成敏感读。
    if delegated_write(export):
        return False
    return bool(SQL_SELECT_RE.search(body))


def delegated_write(export: Export) -> bool:
    """函数体里没有写 SQL，但它调用的同资源函数有。"""
    for callee in set(re.findall(r"\b([A-Za-z_][\w.:]*)\s*\(", strip_comments(export.body))):
        resolved = named_functions().get(callee)
        if resolved and SQL_WRITE_RE.search(strip_comments(resolved[2])):
            return True
    return False


def is_sensitive_read(export: Export) -> bool:
    body = strip_comments(export.body)
    caps = CAPABILITY_RE.findall(body)
    if any(cap.endswith(SENSITIVE_CAPS) for cap in caps):
        return True
    if not is_read(export):
        return False
    if PII_RE.search(body):
        return True
    # A read may delegate the actual projection to a server helper (for example
    # GetNpcBudget -> NPCBudget.Get). Follow one level so a PII snapshot cannot
    # hide behind a one-line wrapper.
    for callee in set(re.findall(r"\b([A-Za-z_][\w.:]*)\s*\(", body)):
        resolved = named_functions().get(callee)
        if not resolved:
            continue
        callee_body = strip_comments(resolved[2])
        # 只跟随"读"的委派。一个 UPDATE 助手（例如 PoliceCitations.ClaimPaid）里的
        # citizenid 说明不了导出本身在读 PII —— 2026-10-25 就因为把写路径挪进 owner
        # 而把 PayCitation 误判成敏感读。
        # 跳过"纯写"助手（有 UPDATE/INSERT 且没有 SELECT，例如 ClaimPaid）：
        # 它里面的 citizenid 说明不了导出本身在读 PII。不写 SQL 的纯计算助手要照跟。
        if SQL_WRITE_RE.search(callee_body) and not SQL_SELECT_RE.search(callee_body):
            continue
        if PII_RE.search(callee_body):
            return True
    return False


def has_auth_gate(body: str) -> bool:
    return bool(AUTH_RE.search(body))


def bad_failure_returns(body: str) -> list[str]:
    """Bare ``return false`` / ``return nil`` statements without a code."""
    bad: list[str] = []
    for match in FAILURE_RETURN_RE.finditer(body):
        rest = match.group("rest").strip()
        if not rest.startswith(","):
            bad.append(match.group(0).strip())
            continue
        payload = rest[1:].strip()
        if payload == "" or re.match(r"^(?:nil|false)\b", payload):
            bad.append(match.group(0).strip())
    return bad


def audit_gate(body: str) -> bool:
    if GATE_HELPER_RE.search(body) and re.search(r"return\s+false,\s*err\b", body):
        return True
    return bool(AUDIT_GATE_RE.search(body)) and AUDIT_FAIL_CLOSED in body


def audit_before_read(body: str) -> bool:
    audit_at = AUDIT_CALL_RE.search(body)
    helper_at = GATE_HELPER_RE.search(body)
    positions = [pos for pos in (
        audit_at.start() if audit_at else -1,
        helper_at.start() if helper_at else -1,
    ) if pos >= 0]
    if not positions:
        return False
    query_at = SQL_SELECT_RE.search(body)
    if not query_at:
        return True
    return min(positions) < query_at.start()



def delegated_write_audit(export: Export) -> bool:
    """导出的写和审计一起交给 owner 时，审计不在这段函数体里。

    例：`IssueCitation` 现在只做玩家路径的前置检查，行写入与 `citation.issue` 审计在
    `server/citations.lua` 的 `PoliceCitations.Insert` 里。沿着"这段函数调用到的同资源函数"
    找一层：被调用者必须真的写下审计（`audit(` 或 `PoliceAudit.Write(`），否则仍然算违约——
    委派不是豁免，只是把承诺换个地方兑现。
    """
    body = strip_comments(export.body)
    for callee in set(re.findall(r"\b([A-Za-z_][\w.:]*)\s*\(", body)):
        resolved = named_functions().get(callee)
        if not resolved:
            continue
        callee_body = strip_comments(resolved[2])
        if AUDIT_CALL_RE.search(callee_body) or "PoliceAudit.Write" in callee_body:
            return True
    return False


def contract_violations(export: Export) -> list[Violation]:
    body = strip_comments(export.body)
    violations: list[Violation] = []

    if not has_auth_gate(body):
        violations.append(Violation(export, "auth", "no permission/source gate"))

    if (SQL_WRITE_RE.search(body) and not AUDIT_CALL_RE.search(body)
            and not delegated_write_audit(export)):
        violations.append(Violation(
            export, "write_audit", "write path does not call audit() (nor delegate it to an owner)"))

    bare = bad_failure_returns(body)
    if bare:
        violations.append(Violation(
            export, "error_code", "bare failure return(s): " + ", ".join(bare)))

    if is_sensitive_read(export):
        if not audit_gate(body):
            violations.append(Violation(
                export, "sensitive_read_audit",
                "sensitive read does not fail closed on audit_unavailable"))
        elif not audit_before_read(body):
            violations.append(Violation(
                export, "sensitive_read_audit",
                "audit row is written after the query"))

    return violations


def all_violations() -> list[Violation]:
    exports, problems = scan_exports()
    assert problems == [], "export parser problems:\n  " + "\n  ".join(problems)
    found: list[Violation] = []
    for export in exports:
        found.extend(contract_violations(export))
    return found


# ---------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------

def load_allowlist() -> dict:
    with ALLOWLIST.open(encoding="utf-8") as handle:
        return json.load(handle)


def declared_exceptions() -> dict[tuple[str, str], set[str]]:
    """(file, export) -> the exceptions the owner registered for it."""
    declared: dict[tuple[str, str], set[str]] = {}
    for entry in load_allowlist().get("entries", []):
        key = (entry.get("file"), entry.get("export"))
        declared.setdefault(key, set()).update(entry.get("exceptions") or [])
    return declared


def unregistered(code: str) -> list[Violation]:
    declared = declared_exceptions()
    return [
        violation for violation in all_violations()
        if violation.code == code
        and violation.code not in declared.get(
            (violation.export.key, violation.export.name), set())
    ]


def parse_date(value: str, field: str) -> date:
    assert isinstance(value, str), f"{field} must be an ISO date string"
    try:
        return date.fromisoformat(value)
    except ValueError as error:  # noqa: PERF203 - one clarifying message
        raise AssertionError(f"{field} is not an ISO date: {value!r}") from error


def allowlist_problems(today: date | None = None) -> list[str]:
    """Schema, freshness and coverage problems for the allowlist."""
    today = today or date.today()
    data = load_allowlist()
    problems: list[str] = []
    if data.get("version") != 1:
        problems.append("allowlist version must be 1")
    if data.get("rule") != "FIT-04":
        problems.append("allowlist rule must be FIT-04")

    entries = data.get("entries")
    assert isinstance(entries, list), "allowlist entries must be a list"

    exports, parse_problems = scan_exports()
    problems.extend(parse_problems)
    by_key = {(export.key, export.name): export for export in exports}
    actual: dict[tuple[str, str], set[str]] = {}
    for export in exports:
        codes = {violation.code for violation in contract_violations(export)}
        if codes:
            actual[(export.key, export.name)] = codes

    seen_ids: set[str] = set()
    declared: dict[tuple[str, str], set[str]] = {}

    for index, entry in enumerate(entries):
        label = f"entries[{index}]"
        missing = [field for field in REQUIRED_FIELDS if field not in entry]
        if missing:
            problems.append(f"{label} missing fields: {', '.join(missing)}")
            continue

        entry_id = entry["id"]
        label = f"{entry_id}"
        if not isinstance(entry_id, str) or not entry_id:
            problems.append(f"{label}: id must be a non-empty string")
            continue
        if entry_id in seen_ids:
            problems.append(f"{label}: duplicate id")
            continue
        seen_ids.add(entry_id)

        kind = entry["kind"]
        if kind not in VALID_KINDS:
            problems.append(f"{label}: unknown kind {kind!r}")

        exceptions = entry["exceptions"]
        if not isinstance(exceptions, list) or not exceptions:
            problems.append(f"{label}: exceptions must be a non-empty list")
            continue
        unknown = set(exceptions) - VALID_EXCEPTIONS
        if unknown:
            problems.append(f"{label}: unknown exception(s) {sorted(unknown)}")

        if not isinstance(entry["reason"], str) or len(entry["reason"].strip()) < 10:
            problems.append(f"{label}: reason must explain why the gap is accepted")
        if not isinstance(entry["owner"], str) or not entry["owner"].strip():
            problems.append(f"{label}: owner is required")

        added = parse_date(entry["added"], f"{label}.added")
        expires = parse_date(entry["expires"], f"{label}.expires")
        if expires < added:
            problems.append(f"{label}: expires is before added")
        if expires < today:
            problems.append(f"{label}: expired on {expires.isoformat()}")
        if added > today:
            problems.append(f"{label}: added date is in the future ({added.isoformat()})")

        key = (entry["file"], entry["export"])
        if key in declared:
            problems.append(f"{label}: duplicate entry for {key[0]} {key[1]}")
            continue
        declared[key] = set(exceptions)

        if key not in by_key:
            problems.append(
                f"{label}: no export {entry['export']} in {entry['file']}"
            )

    for key, codes in sorted(actual.items()):
        declared_codes = declared.get(key)
        if declared_codes is None:
            problems.append(
                f"unregistered {key[1]} ({key[0]}): {', '.join(sorted(codes))}"
            )
        elif declared_codes != codes:
            missing = codes - declared_codes
            stale = declared_codes - codes
            if missing:
                problems.append(
                    f"{key[1]}: unregistered exception(s) {sorted(missing)}"
                )
            if stale:
                problems.append(
                    f"{key[1]}: allowlist lists fixed exception(s) {sorted(stale)}"
                )

    for key in sorted(declared):
        if key not in by_key:
            continue
        if key not in actual:
            problems.append(
                f"{key[1]}: allowlist entry matches no violation (fixed? remove it)"
            )

    return problems


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_export_scanner_finds_the_whole_surface():
    exports, problems = scan_exports()
    assert problems == [], "export parser problems:\n  " + "\n  ".join(problems)
    assert len(exports) >= 42, (
        f"only {len(exports)} exports parsed — the scanner or the resource "
        f"surface regressed"
    )
    assert len({export.name for export in exports}) == len(exports), (
        "duplicate export name(s) found"
    )


def test_every_export_has_a_permission_or_source_gate():
    missing = [str(violation) for violation in unregistered("auth")]
    assert missing == [], (
        "FIT-04: every export must check PolicePolicy / isPolice / an ownership "
        "comparison, or be registered as an explicit system-only entry in "
        "tests/architecture/export_allowlist.json:\n  " + "\n  ".join(missing)
    )


def test_every_failure_path_returns_a_string_error_code():
    missing = [str(violation) for violation in unregistered("error_code")]
    assert missing == [], (
        "FIT-04: failure returns must carry a stable string code "
        "(`return false, 'code'`) so the MDT can localise them; bare "
        "`return false` / `return nil` is not allowed:\n  " + "\n  ".join(missing)
    )


def test_every_sensitive_read_audits_first_and_fails_closed():
    missing = [str(violation) for violation in unregistered("sensitive_read_audit")]
    assert missing == [], (
        "FIT-04/FIT-05: sensitive reads (`.view`/`.detail`/`.chain`, or rows "
        "with citizenid/names/descriptions) must write their audit row before "
        "the query and return false, 'audit_unavailable' when it fails:\n  "
        + "\n  ".join(missing)
    )


def test_no_export_is_unregistered():
    problems = allowlist_problems()
    assert problems == [], (
        "FIT-04 export allowlist is invalid, stale or incomplete:\n  "
        + "\n  ".join(problems)
    )


def test_scanner_detects_the_three_violation_shapes():
    """Reverse validation: the rules are not vacuously green."""
    def export(name: str, body: str) -> Export:
        return Export(name=name, path=SERVER / "p0.lua", line=1,
                      target="<test>", body=body)

    unaudited = export(
        "GetSecret",
        "local rows = MySQL.query.await('SELECT citizenid FROM players')",
    )
    codes = {violation.code for violation in contract_violations(unaudited)}
    assert codes == {"auth", "sensitive_read_audit"}, codes

    bare = export("DoWrite", "if bad then return false end\nreturn true")
    codes = {violation.code for violation in contract_violations(bare)}
    assert "error_code" in codes, codes

    unaudited_write = export(
        "WriteThing",
        "PolicePolicy.Can(actor, 'case.create')\n"
        "MySQL.update.await('UPDATE police_reports SET status = ?', { status })",
    )
    codes = {violation.code for violation in contract_violations(unaudited_write)}
    assert "write_audit" in codes, codes

    late_audit = export(
        "GetDetail",
        "PolicePolicy.Can(actor, 'case.detail')\n"
        "local rows = MySQL.query.await('SELECT citizenid FROM police_cases')\n"
        "if not audit(actor.citizenid, 'case.detail', nil, nil) then\n"
        "  return false, 'audit_unavailable'\nend",
    )
    codes = {violation.code for violation in contract_violations(late_audit)}
    assert "sensitive_read_audit" in codes, codes
