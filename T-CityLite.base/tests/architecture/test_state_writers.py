"""FIT-11 — state-machine columns may only be written by registered writers.

Static, offline contract (no FXServer, no DB, no network):

* scan every ``resources/**/*.lua`` server file for a literal
  ``UPDATE police_* SET ...``;
* map the table + assigned columns to a rule in
  ``state_writers_allowlist.json``:

  =========================  =========================================
  table / column             allowed writer(s)
  =========================  =========================================
  ``police_units.status``    ``custom-police/server/p0.lua``
  ``police_units.incident_id`` ``custom-police/server/p0.lua``
  ``police_incidents.status`` ``custom-police/server/p0.lua``
  ``police_reports``         ``p1.lua`` / ``p2_system.lua`` / ``p3_cases.lua``
  ``police_cases``           ``p2_system.lua`` / ``p3_cases.lua``
  ``police_citations``       ``p1.lua``
  ``police_warrants.status`` ``p3_cases.lua``
  ``police_bolos.status``    ``p3_cases.lua``
  =========================  =========================================

* a writer outside ``allowed_files`` is a violation unless the exact
  ``(writer, table, file, function)`` tuple is registered in ``entries`` with
  a reason and an expiry. Other resources (``custom-justice``, ``custom-phone``,
  ``qb-prison``) must use a ``custom-police`` export; they may not write police
  state directly;
* entries are a debt register: expired entries fail, and an entry that no
  longer matches a real write fails as stale.

Current known debt (registered, 2027-03-31): the legacy director
``Sys.AssignUnit`` path in ``p2_system.lua`` writes ``police_units`` and
``police_incidents`` directly. It should call ``P.AssignUnit`` instead; until
then both writes are pinned to that one function so a new writer elsewhere in
the file cannot hide behind the entry.

Reverse checks inject the exact shape this rule removed
(``custom-justice`` writing ``police_incidents.status``) and require the
scanner to go red.

    python3 -m pytest -q tests/architecture/test_state_writers.py
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import date
from functools import lru_cache
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
RESOURCES = BASE / "resources"
REGISTRY = Path(__file__).with_name("state_writers_allowlist.json")

UPDATE_RE = re.compile(
    r"\bUPDATE\s+[`\"']?(police_[A-Za-z0-9_]+)[`\"']?\s+SET\b", re.I
)
WHERE_RE = re.compile(r"\bWHERE\b", re.I)
COLUMN_RE = re.compile(r"[`\"']?([A-Za-z_][A-Za-z0-9_]*)[`\"']?\s*=")
FUNCTION_RE = re.compile(
    r"(?m)^[ \t]*(?:local[ \t]+)?function[ \t]+([A-Za-z0-9_.:]+)[ \t]*\("
)
LONG_OPEN = re.compile(r"\[(=*)\[")
REQUIRED_RULE_FIELDS = ("id", "table", "columns", "allowed_files", "reason")
REQUIRED_ENTRY_FIELDS = (
    "id", "writer", "table", "file", "function", "reason", "added", "expires",
)


@dataclass(frozen=True)
class Write:
    resource: str
    file: str
    line: int
    table: str
    columns: frozenset[str]
    function: str
    rule_id: str

    @property
    def key(self) -> tuple[str, str, str, str]:
        return (self.resource, self.table, self.file, self.function)

    @property
    def policy_key(self) -> str:
        return f"{self.resource}/{self.file}"

    @property
    def where(self) -> str:
        return f"{self.resource}/{self.file}:{self.line}"


def mask_comments(text: str) -> str:
    """Blank Lua comments while keeping SQL strings and line numbers."""
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
        else:
            i += 1
    return "".join(out)


def _line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def _function_at(masked: str, offset: int) -> str:
    functions = [match for match in FUNCTION_RE.finditer(masked) if match.start() < offset]
    return functions[-1].group(1) if functions else "(top-level)"


def _updates(masked: str) -> list[re.Match[str]]:
    return list(UPDATE_RE.finditer(masked))


def _columns(masked: str, match: re.Match[str]) -> frozenset[str]:
    tail = masked[match.end():]
    where = WHERE_RE.search(tail)
    # A SET clause always precedes WHERE in this codebase; the cap is only a
    # guard against a malformed literal swallowing the rest of the file.
    clause = tail[: where.start()] if where else tail[:400]
    return frozenset(column.lower() for column in COLUMN_RE.findall(clause))


@lru_cache(maxsize=1)
def load_registry() -> dict:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def rules_by_id(registry: dict) -> dict[str, dict]:
    return {rule["id"]: rule for rule in registry["rules"]}


def classify(registry: dict, table: str, columns: frozenset[str]) -> dict | None:
    for rule in registry["rules"]:
        if rule["table"] != table:
            continue
        required = {column.lower() for column in rule["columns"]}
        if required and not columns & required:
            continue
        return rule
    return None


def _resource_and_file(path: Path) -> tuple[str, str]:
    for parent in path.parents:
        if (parent / "fxmanifest.lua").is_file():
            return parent.name, path.relative_to(parent).as_posix()
    relative = path.relative_to(RESOURCES)
    return relative.parts[1], "/".join(relative.parts[2:])


def iter_state_writes(
    path: Path,
    registry: dict | None = None,
    resource: str | None = None,
    file: str | None = None,
) -> list[Write]:
    """Extract every domain state write from one Lua source."""
    registry = registry or load_registry()
    masked = mask_comments(path.read_text(encoding="utf-8", errors="ignore"))
    if resource is None or file is None:
        resource, file = _resource_and_file(path)
    found: list[Write] = []
    for match in _updates(masked):
        table = match.group(1).lower()
        columns = _columns(masked, match)
        rule = classify(registry, table, columns)
        if rule is None:
            continue
        found.append(
            Write(
                resource=resource,
                file=file,
                line=_line_of(masked, match.start()),
                table=table,
                columns=columns,
                function=_function_at(masked, match.start()),
                rule_id=rule["id"],
            )
        )
    found.sort(key=lambda write: (write.line, write.table))
    return found


@lru_cache(maxsize=1)
def scan_state_writes() -> tuple[tuple[Write, ...], tuple[Write, ...]]:
    """Return (all domain writes, unregistered writes)."""
    registry = load_registry()
    allowed = {
        rule["id"]: set(rule["allowed_files"])
        for rule in registry["rules"]
    }
    writes: list[Write] = []
    for path in sorted(RESOURCES.glob("**/*.lua")):
        writes.extend(iter_state_writes(path, registry))

    entries = {
        (entry["writer"], entry["table"], entry["file"], entry["function"])
        for entry in registry["entries"]
    }
    violations = [
        write
        for write in writes
        if write.policy_key not in allowed[write.rule_id] and write.key not in entries
    ]
    return tuple(writes), tuple(violations)


def validate_registry(registry: dict, today: date | None = None) -> list[str]:
    errors: list[str] = []
    today = today or date.today()
    ids: set[str] = set()
    for rule in registry.get("rules", []):
        errors.extend(
            f"rule missing {field}" for field in REQUIRED_RULE_FIELDS if field not in rule
        )
        if rule.get("id") in ids:
            errors.append(f"duplicate rule id {rule.get('id')!r}")
        ids.add(rule.get("id"))
        if not isinstance(rule.get("columns"), list):
            errors.append(f"{rule.get('id')}: columns must be a list")
        if not any(str(item).startswith("custom-police/") for item in rule.get("allowed_files", [])):
            errors.append(f"{rule.get('id')}: allowed_files must stay inside custom-police")

    entries: set[tuple[str, str, str, str]] = set()
    for entry in registry.get("entries", []):
        errors.extend(
            f"entry missing {field}" for field in REQUIRED_ENTRY_FIELDS if not entry.get(field)
        )
        key = (
            entry.get("writer"), entry.get("table"),
            entry.get("file"), entry.get("function"),
        )
        if key in entries:
            errors.append(f"duplicate entry key {key!r}")
        entries.add(key)
        try:
            expiry = date.fromisoformat(str(entry.get("expires")))
        except ValueError:
            errors.append(f"{entry.get('id')}: expires is not an ISO date")
            continue
        if expiry < today:
            errors.append(f"{entry.get('id')}: expired on {expiry.isoformat()}")
        if str(entry.get("file", "")).startswith("/"):
            errors.append(f"{entry.get('id')}: file is resource-relative")
    return errors


def stale_entries(registry: dict, writes: tuple[Write, ...]) -> list[str]:
    seen = {write.key for write in writes}
    return [
        f"stale state-writer entry {entry.get('id')!r}: "
        f"{entry.get('writer')}/{entry.get('file')}::{entry.get('function')} "
        f"no longer updates {entry.get('table')}"
        for entry in registry.get("entries", [])
        if (entry.get("writer"), entry.get("table"), entry.get("file"), entry.get("function"))
        not in seen
    ]


# ---------------------------------------------------------------------------
# pytest contract
# ---------------------------------------------------------------------------

def test_registry_is_well_formed():
    registry = load_registry()
    assert registry["version"] == 1
    assert registry["rule"] == "FIT-11"
    assert registry["rules"], "state-writer rule table is empty"
    errors = validate_registry(registry)
    # Entries in this file are allowed to be current; expiry is still checked.
    assert not errors, "\n".join(errors)


def test_no_unregistered_state_writer():
    registry = load_registry()
    writes, violations = scan_state_writes()
    assert len(writes) >= 15, f"scanner found only {len(writes)} state writes"
    detail = [
        f"FIT-11: {write.where} UPDATE {write.table} SET {sorted(write.columns)} "
        f"in {write.function} — register the writer or route it through the service"
        for write in violations
    ]
    detail += stale_entries(registry, writes)
    assert not detail, "\n".join(detail)


def test_non_police_resources_have_no_direct_police_state_write():
    writes, _ = scan_state_writes()
    foreign = [write for write in writes if write.resource != "custom-police"]
    detail = [
        f"FIT-11: {write.where} writes {write.table} from {write.resource}; "
        "use exports['custom-police'] instead"
        for write in foreign
    ]
    assert not detail, "\n".join(detail)


def test_units_and_incidents_are_p0_only_plus_the_registered_legacy_branch():
    registry = load_registry()
    writes, violations = scan_state_writes()
    assert not violations
    for rule_id in ("police_units.status", "police_incidents.status"):
        rule = next(rule for rule in registry["rules"] if rule["id"] == rule_id)
        assert rule["allowed_files"] == ["custom-police/server/p0.lua"]
        writers = {
            (write.resource, write.file, write.function)
            for write in writes
            if write.rule_id == rule_id
        }
        # Every unit/incident state write now goes through p0 helpers.
        assert {writer[0] for writer in writers} == {"custom-police"}
        non_p0 = {
            writer for writer in writers if writer[1] != "server/p0.lua"
        }
        assert non_p0 == set()


def test_report_and_citation_writers_match_the_registry():
    writes, _ = scan_state_writes()
    for table, expected in {
        # 2026-10-25: 三张记录表收口到 server/records.lua
        "police_reports": {"server/records.lua"},
        "police_cases": {"server/records.lua"},
        "police_arrests": {"server/records.lua"},
        # 2026-10-25: 罚单收口到 server/citations.lua（p1 只做前置检查与通知）
        "police_citations": {"server/citations.lua"},
    }.items():
        actual = {write.file for write in writes if write.table == table}
        assert actual <= expected, f"{table} written by {sorted(actual)}"


# ---------------------------------------------------------------------------
# Reverse checks
# ---------------------------------------------------------------------------

def test_reverse_check_detects_a_justice_write_to_police_incidents(tmp_path: Path):
    sample = (
        "CreateThread(function()\n"
        "  MySQL.update.await(\n"
        "    \"UPDATE police_incidents SET status = 'closed' WHERE id = ?\", { id })\n"
        "end)\n"
    )
    path = tmp_path / "trial.lua"
    path.write_text(sample, encoding="utf-8")
    writes = iter_state_writes(path, resource="custom-justice", file="server/trial.lua")
    assert len(writes) == 1
    write = writes[0]
    assert (write.resource, write.table, write.function) == (
        "custom-justice", "police_incidents", "(top-level)",
    )
    assert write.rule_id == "police_incidents.status"
    assert write.policy_key == "custom-justice/server/trial.lua"
    # No entry exists for justice → police state, so the scanner reports it.
    registry = load_registry()
    assert not [
        entry for entry in registry["entries"]
        if (entry["writer"], entry["table"]) == ("custom-justice", "police_incidents")
    ]


def test_reverse_check_detects_a_phone_citation_write(tmp_path: Path):
    sample = "MySQL.update('UPDATE police_citations SET status = \"paid\" WHERE id = ?', { id })\n"
    path = tmp_path / "pay.lua"
    path.write_text(sample, encoding="utf-8")
    writes = iter_state_writes(path, resource="custom-phone", file="server/pay.lua")
    assert [write.table for write in writes] == ["police_citations"]


def test_reverse_check_detects_a_new_writer_inside_an_allowed_file(tmp_path: Path):
    """The p2 exception is pinned to Sys.AssignUnit, not the whole file."""
    sample = (
        "function Sys.Jail(actorId, citizenid)\n"
        "  MySQL.update.await('UPDATE police_units SET status = \"off_duty\" WHERE citizenid = ?', { citizenid })\n"
        "end\n"
    )
    path = tmp_path / "p2_system.lua"
    path.write_text(sample, encoding="utf-8")
    writes = iter_state_writes(path, resource="custom-police", file="server/p2_system.lua")
    assert writes[0].function == "Sys.Jail"
    registry = load_registry()
    assert writes[0].key not in {
        (entry["writer"], entry["table"], entry["file"], entry["function"])
        for entry in registry["entries"]
    }


def test_commented_update_is_not_a_violation(tmp_path: Path):
    sample = (
        "-- MySQL.update('UPDATE police_incidents SET status = \"closed\" WHERE id = 1')\n"
        "--[[ UPDATE police_units SET status = 'off_duty' ]]\n"
        "local ok = true\n"
    )
    path = tmp_path / "comment.lua"
    path.write_text(sample, encoding="utf-8")
    assert iter_state_writes(path, resource="custom-justice", file="server/comment.lua") == []


def test_select_and_insert_are_not_state_updates(tmp_path: Path):
    sample = (
        "MySQL.query.await('SELECT status FROM police_incidents WHERE id = ?', { id })\n"
        "MySQL.insert.await('INSERT INTO police_reports (title) VALUES (?)', { title })\n"
        "MySQL.update.await('UPDATE police_outbox SET status = \\'done\\' WHERE id = ?', { id })\n"
    )
    path = tmp_path / "reads.lua"
    path.write_text(sample, encoding="utf-8")
    assert iter_state_writes(path, resource="custom-police", file="server/x.lua") == []
