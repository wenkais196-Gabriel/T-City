"""FIT-02 — no resource may write a table owned by another resource.

Static, offline contract (no FXServer, no DB, no network):

* scan the resources listed in ``table_owners.json`` → ``scan``;
* extract every SQL write statement (``INSERT [IGNORE] INTO``, ``REPLACE INTO``,
  ``UPDATE <table> SET``, ``DELETE FROM``) from the Lua source after masks out
  comments, so a commented-out statement is not a violation;
* resolve the table owner from the registry (exact name or ``prefix_*`` glob);
* a write from a resource other than the owner is a violation unless it is
  registered in ``entries`` with ``writer`` / ``table`` / ``owner`` / ``reason``
  / ``added`` / ``expires``.

The allowlist is a debt register, not a mute button: expired entries fail, and
an entry that no longer matches any violation fails as stale. New cross-resource
writes must go through an owner export instead (for example
``exports['custom-phone']:Notify(...)`` and
``exports['custom-police']:RecordVerdict(...)``), which is exactly the boundary
this rule protects.

    python3 -m pytest -q tests/architecture/test_cross_resource_writes.py
"""
from __future__ import annotations

import fnmatch
import json
import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
RESOURCES = BASE / "resources"
CUSTOM = RESOURCES / "[custom]"
REGISTRY = Path(__file__).with_name("table_owners.json")

RESOURCE_DIRS = {
    "custom-police": CUSTOM / "custom-police" / "server",
    "custom-phone": CUSTOM / "custom-phone" / "server",
    "custom-justice": CUSTOM / "custom-justice" / "server",
    "qb-prison": RESOURCES / "[qb]" / "qb-prison" / "server",
    "custom-director": CUSTOM / "custom-director" / "server",
    "custom-main": CUSTOM / "custom-main" / "server",
    "custom-career": CUSTOM / "custom-career" / "server",
    "custom-agent-client": CUSTOM / "custom-agent-client" / "server",
    "story-engine": CUSTOM / "story-engine" / "server",
    "tcity-dashboard": RESOURCES / "[system]" / "tcity-dashboard" / "server",
}

WRITE_RES = (
    re.compile(
        r"\b(?:INSERT(?:\s+IGNORE)?\s+INTO|REPLACE\s+INTO)\s+[`\"']?([A-Za-z_][A-Za-z0-9_]*)",
        re.I,
    ),
    re.compile(
        r"\bUPDATE\s+[`\"']?([A-Za-z_][A-Za-z0-9_]*)[`\"']?\s+SET\b",
        re.I,
    ),
    re.compile(
        r"\bDELETE\s+FROM\s+[`\"']?([A-Za-z_][A-Za-z0-9_]*)",
        re.I,
    ),
)
LONG_OPEN = re.compile(r"\[(=*)\[")
REQUIRED_ENTRY_FIELDS = ("id", "writer", "table", "owner", "reason", "added", "expires")


@dataclass(frozen=True)
class Write:
    resource: str
    path: Path
    line: int
    table: str
    verb: str

    @property
    def where(self) -> str:
        return f"{self.path.relative_to(RESOURCES).as_posix()}:{self.line}"


@dataclass(frozen=True)
class Violation:
    write: Write
    owner: str

    @property
    def key(self) -> tuple[str, str]:
        return (self.write.resource, self.write.table)


# ---------------------------------------------------------------------------
# Minimal Lua comment masker: keeps strings (SQL lives in them) and newlines.
# ---------------------------------------------------------------------------

def mask_comments(text: str) -> str:
    out = list(text)
    i, n = 0, len(text)
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
            for k in range(i, end):
                if out[k] != "\n":
                    out[k] = " "
            i = end
        elif char in "'\"":
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == char:
                    i += 1
                    break
                i += 1
        elif char == "[":
            long = LONG_OPEN.match(text, i)
            if long:
                close = "]" + long.group(1) + "]"
                end = text.find(close, long.end())
                i = n if end < 0 else end + len(close)
            else:
                i += 1
        else:
            i += 1
    return "".join(out)


def iter_writes(resource: str, path: Path, text: str) -> list[Write]:
    masked = mask_comments(text)
    found: list[Write] = []
    for regex in WRITE_RES:
        for match in regex.finditer(masked):
            found.append(
                Write(
                    resource=resource,
                    path=path,
                    line=masked.count("\n", 0, match.start()) + 1,
                    table=match.group(1).lower(),
                    verb=match.group(0).split()[0].upper(),
                )
            )
    found.sort(key=lambda item: (item.line, item.table))
    return found


def load_registry() -> dict:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def owner_of(table: str, registry: dict) -> str | None:
    for rule in registry["owners"]:
        for pattern in rule["tables"]:
            if fnmatch.fnmatchcase(table, pattern):
                return rule["owner"]
    return None


def scan_files(registry: dict) -> tuple[list[Write], list[Violation]]:
    writes: list[Write] = []
    for resource in registry["scan"]:
        directory = RESOURCE_DIRS[resource]
        assert directory.is_dir(), f"missing scan directory for {resource}: {directory}"
        for path in sorted(directory.rglob("*.lua")):
            writes.extend(iter_writes(resource, path, path.read_text(encoding="utf-8")))

    violations: list[Violation] = []
    for write in writes:
        owner = owner_of(write.table, registry)
        if owner is None:
            # The registry only judges tables the architecture claims to own.
            continue
        if owner != write.resource:
            violations.append(Violation(write=write, owner=owner))
    return writes, violations


def parse_entry(entry: dict, registry: dict) -> list[str]:
    """Return schema errors for one allowlist entry (empty when valid)."""
    errors = [f"missing {field}" for field in REQUIRED_ENTRY_FIELDS if not entry.get(field)]
    if errors:
        return errors
    owner = owner_of(str(entry["table"]), registry)
    if owner != entry["owner"]:
        errors.append(
            f"owner {entry['owner']!r} does not match registry owner {owner!r} "
            f"for table {entry['table']!r}"
        )
    try:
        expiry = date.fromisoformat(str(entry["expires"]))
    except ValueError:
        errors.append(f"expires is not an ISO date: {entry['expires']!r}")
        expiry = None
    if expiry is not None and expiry < date.today():
        errors.append(f"expired on {expiry.isoformat()} (still cross-writing {entry['table']})")
    return errors


def match_entries(violations: list[Violation], registry: dict) -> tuple[list[Violation], list[str]]:
    """Split violations into unallowlisted ones and stale-entry errors."""
    entries = registry.get("entries", [])
    matched: set[int] = set()
    unmatched: list[Violation] = []
    for violation in violations:
        hit = None
        for index, entry in enumerate(entries):
            if (entry.get("writer"), entry.get("table")) == violation.key:
                hit = index
                break
        if hit is None:
            unmatched.append(violation)
        else:
            matched.add(hit)

    stale = []
    for index, entry in enumerate(entries):
        if index not in matched:
            stale.append(
                f"stale allowlist entry {entry.get('id')!r}: "
                f"{entry.get('writer')} no longer writes {entry.get('table')}"
            )
    return unmatched, stale


# ---------------------------------------------------------------------------
# pytest contract
# ---------------------------------------------------------------------------

def test_registry_is_well_formed():
    registry = load_registry()
    assert registry["version"] == 1
    assert registry["rule"] == "FIT-02"
    for resource in registry["scan"]:
        assert resource in RESOURCE_DIRS, f"scan resource has no directory: {resource}"
        assert RESOURCE_DIRS[resource].is_dir(), f"missing {RESOURCE_DIRS[resource]}"
    assert registry["owners"], "owner table is empty"

    errors: list[str] = []
    for entry in registry.get("entries", []):
        errors.extend(parse_entry(entry, registry))
    assert not errors, "\n".join(errors)


def test_no_unregistered_cross_resource_writes():
    registry = load_registry()
    _, violations = scan_files(registry)
    unmatched, stale = match_entries(violations, registry)
    detail = [
        f"FIT-02: {item.write.where} {item.write.verb} {item.write.table} "
        f"— owned by {item.owner}; use the owner export or register an expiry"
        for item in unmatched
    ]
    assert not detail and not stale, "\n".join(detail + stale)


def test_phone_notifications_and_police_reports_have_a_single_writer():
    registry = load_registry()
    writes, violations = scan_files(registry)
    for table in ("phone_notifications", "police_reports"):
        owners = {
            write.resource for write in writes if write.table == table
        }
        assert owners <= {owner_of(table, registry)}, (
            f"{table} is written by {sorted(owners)}; only the owner may write it"
        )
        assert not [item for item in violations if item.write.table == table]


def test_notification_and_verdict_use_owner_exports():
    phone = (CUSTOM / "custom-phone" / "server" / "main.lua").read_text(encoding="utf-8")
    assert "exports('Notify'" in phone
    assert "'INSERT INTO phone_notifications (citizenid, title, content, app_id) VALUES (?, ?, ?, ?)'" in phone

    police = (CUSTOM / "custom-police" / "server" / "p3_cases.lua").read_text(encoding="utf-8")
    assert "exports('RecordVerdict', C.RecordVerdict)" in police
    assert "function C.RecordVerdict(justiceCaseId, verdictJson, status)" in police

    justice = (CUSTOM / "custom-justice" / "server" / "trial.lua").read_text(encoding="utf-8")
    assert "exports['custom-police']:RecordVerdict(" in justice
    assert "UPDATE police_reports" not in justice


def test_reverse_check_detects_a_justice_write_to_police_reports():
    """The scanner must catch the exact shape this task removed."""
    registry = load_registry()
    sample = (
        "CreateThread(function()\n"
        "  MySQL.update.await(\n"
        "    'UPDATE police_reports SET justice_verdict = ?, justice_status = ? "
        "WHERE justice_case_id = ?',\n"
        "    { encoded, status, tostring(caseId) })\n"
        "end)\n"
    )
    writes = iter_writes(
        "custom-justice", CUSTOM / "custom-justice" / "server" / "trial.lua", sample
    )
    violations = [
        Violation(write=write, owner=owner_of(write.table, registry))
        for write in writes
        if owner_of(write.table, registry) not in (None, "custom-justice")
    ]
    assert [(item.write.table, item.owner) for item in violations] == [
        ("police_reports", "custom-police")
    ]
    # No allowlist entry exists for justice → police_reports, so an injected
    # regression is reported instead of silently accepted.
    assert not [
        entry
        for entry in registry["entries"]
        if (entry.get("writer"), entry.get("table")) == ("custom-justice", "police_reports")
    ]


def test_commented_sql_is_not_a_violation():
    sample = (
        "-- UPDATE police_reports SET justice_verdict = 'x' WHERE id = 1\n"
        "--[[ INSERT INTO phone_notifications (citizenid) VALUES ('x') ]]\n"
        "local ok = true\n"
    )
    assert iter_writes("custom-justice", Path("x.lua"), sample) == []


def test_on_duplicate_key_update_is_not_a_table_update():
    sample = (
        "MySQL.insert('INSERT INTO players (citizenid, name) VALUES (?, ?) "
        "ON DUPLICATE KEY UPDATE name = ?', { cid, name, name })\n"
    )
    writes = iter_writes("qb-core", Path("x.lua"), sample)
    assert [(write.verb, write.table) for write in writes] == [("INSERT", "players")]
