"""FIT-12 — deprecated write paths are zero or registered with an expiry.

Static, offline contract (no FXServer, no DB, no network):

* ``deprecations.json`` registers every legacy table / command / net event that
  has been announced as retired but still exists (``owner``, ``reason``,
  ``replacement``, ``expected_writes``, ``expires``);
* the scanner counts the real write sites (table) / registrations (command) /
  registrations (event) and fails when the count exceeds ``expected_writes``:
  no new debt may be added to a deprecated path;
* an expired entry that is still present fails, so every known debt must be
  either removed or re-approved with a new expiry;
* an entry that no longer matches anything fails as stale: the register may
  only shrink, never rot.

This makes FIT-12 "known debt + forced expiry" instead of a permanently red
hand-wave.

    python3 -m pytest -q tests/architecture/test_deprecations.py
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
DEPRECATIONS = Path(__file__).with_name("deprecations.json")

RESOURCE_DIRS = {
    "custom-police": CUSTOM / "custom-police" / "server",
    "custom-phone": CUSTOM / "custom-phone" / "server",
    "custom-justice": CUSTOM / "custom-justice" / "server",
    "qb-prison": RESOURCES / "[qb]" / "qb-prison" / "server",
}
KINDS = {"table", "command", "event"}
REQUIRED_ENTRY_FIELDS = (
    "id", "kind", "target", "owner", "reason", "replacement", "expected_writes", "expires",
)


@dataclass(frozen=True)
class Hit:
    path: Path
    line: int
    body: str

    @property
    def where(self) -> str:
        return f"{self.path.relative_to(RESOURCES).as_posix()}:{self.line}"


def lua_files() -> list[tuple[str, Path]]:
    files: list[tuple[str, Path]] = []
    for resource, directory in RESOURCE_DIRS.items():
        assert directory.is_dir(), f"missing scan directory for {resource}: {directory}"
        for path in sorted(directory.rglob("*.lua")):
            files.append((resource, path))
    return files


def load_entries() -> list[dict]:
    return json.loads(DEPRECATIONS.read_text(encoding="utf-8"))["entries"]


def _table_patterns(table: str) -> list[re.Pattern[str]]:
    quoted = rf"[`\"']?{re.escape(table)}[`\"']?"
    return [
        re.compile(
            rf"\b(?:INSERT(?:\s+IGNORE)?\s+INTO|REPLACE\s+INTO)\s+{quoted}", re.I
        ),
        re.compile(rf"\bUPDATE\s+{quoted}\s+SET\b", re.I),
        re.compile(rf"\bDELETE\s+FROM\s+{quoted}", re.I),
    ]


def _event_body(text: str, start: int) -> str:
    end = text.find("\nend)", start)
    return text[start: (len(text) if end < 0 else end + len("end)"))]



def _strip_comments(text: str) -> str:
    """把 `--` 注释抹成空格（保留换行，行号不变）。

    不剥注释时，文档里写的示例（`'INSERT INTO police_arrests'`）会被当成一次真实写入，
    "这张表有几个写者"的预算就被散文污染了 —— 2026-10-25 收口 records.lua 时正是这样。
    """
    out: list[str] = []
    for line in text.splitlines(keepends=True):
        index = line.find("--")
        if index < 0:
            out.append(line)
            continue
        head = line[:index]
        tail = line[index:]
        out.append(head + " " * len(tail.rstrip("\n")) + ("\n" if tail.endswith("\n") else ""))
    return "".join(out)


def hits_for(entry: dict) -> list[Hit]:
    """Find the real occurrences of one deprecation target."""
    target = str(entry.get("target") or "")
    kind = entry.get("kind")
    hits: list[Hit] = []

    for _, path in lua_files():
        text = path.read_text(encoding="utf-8")
        if kind == "table":
            patterns = _table_patterns(target)
        elif kind == "command":
            name = target.lstrip("/")
            patterns = [
                re.compile(
                    rf"(?:QBCore\.Commands\.Add|RegisterCommand)\(\s*['\"]{re.escape(name)}['\"]"
                )
            ]
        elif kind == "event":
            patterns = [
                re.compile(rf"RegisterNetEvent\(\s*['\"]{re.escape(target)}['\"]")
            ]
        else:
            continue

        code = _strip_comments(text) if kind == "table" else text
        for pattern in patterns:
            for match in pattern.finditer(code):
                line = text.count("\n", 0, match.start()) + 1
                body = _event_body(text, match.start()) if kind == "event" else text
                hits.append(Hit(path=path, line=line, body=body))
    hits.sort(key=lambda hit: (str(hit.path), hit.line))
    return hits


def evaluate(entries: list[dict], today: date | None = None) -> list[str]:
    """Return every FIT-12 failure for the given register (empty means PASS)."""
    today = today or date.today()
    errors: list[str] = []
    seen: set[str] = set()

    for entry in entries:
        missing = [field for field in REQUIRED_ENTRY_FIELDS if entry.get(field) in (None, "")]
        if missing:
            errors.append(f"entry {entry.get('id')!r}: missing {', '.join(missing)}")
            continue
        entry_id = str(entry["id"])
        if entry_id in seen:
            errors.append(f"duplicate deprecation id {entry_id!r}")
        seen.add(entry_id)

        if entry["kind"] not in KINDS:
            errors.append(f"{entry_id}: unknown kind {entry['kind']!r}")
            continue
        try:
            expected = int(entry["expected_writes"])
        except (TypeError, ValueError):
            errors.append(f"{entry_id}: expected_writes must be an integer")
            continue
        if expected < 0:
            errors.append(f"{entry_id}: expected_writes must be >= 0")
            continue

        try:
            expiry = date.fromisoformat(str(entry["expires"]))
        except ValueError:
            errors.append(f"{entry_id}: expires is not an ISO date: {entry['expires']!r}")
            expiry = None

        hits = hits_for(entry)
        if not hits:
            errors.append(
                f"{entry_id}: stale entry — {entry['kind']} {entry['target']!r} "
                f"no longer exists; delete the entry"
            )
            continue
        if len(hits) > expected:
            where = ", ".join(hit.where for hit in hits)
            errors.append(
                f"{entry_id}: new debt — {len(hits)} live sites for "
                f"{entry['kind']} {entry['target']!r} (expected <= {expected}): {where}"
            )
        if expiry is not None and expiry < today:
            errors.append(
                f"{entry_id}: expired on {expiry.isoformat()} but "
                f"{entry['kind']} {entry['target']!r} still exists"
            )

        guard = entry.get("guard")
        if guard:
            for hit in hits:
                if str(guard) not in hit.body:
                    errors.append(
                        f"{entry_id}: {hit.where} lost its guard {guard!r}"
                    )
    return errors


# ---------------------------------------------------------------------------
# pytest contract
# ---------------------------------------------------------------------------

def test_register_is_well_formed():
    entries = load_entries()
    assert entries, "deprecation register is empty"
    assert json.loads(DEPRECATIONS.read_text(encoding="utf-8"))["rule"] == "FIT-12"
    for entry in entries:
        assert entry["kind"] in KINDS
        assert date.fromisoformat(entry["expires"]) >= date(2026, 1, 1)
    assert not evaluate(entries)


def test_deprecated_paths_do_not_grow():
    errors = evaluate(load_entries())
    assert not errors, "\n".join(errors)


def test_table_budget_counts_every_write_statement():
    entries = {entry["id"]: entry for entry in load_entries()}
    # 2026-10-25: 两条写路径已收口到 records.lua，写入点 2 → 1（表仍是历史包袱，登记不删）
    arrests = hits_for(entries["police-arrests-table"])
    assert len(arrests) == entries["police-arrests-table"]["expected_writes"] == 1
    assert all("records.lua" in hit.where for hit in arrests), (
        "police_arrests 只该由 records.lua 写")

    bolos = hits_for(entries["police-bolos-table"])
    assert len(bolos) == entries["police-bolos-table"]["expected_writes"] == 2


def test_commands_and_events_are_registered_exactly_once():
    entries = {entry["id"]: entry for entry in load_entries()}
    for entry_id in ("fine-command", "911p-command", "jail-player-event", "police-alert-event"):
        hits = hits_for(entries[entry_id])
        assert len(hits) == 1, f"{entry_id}: {[hit.where for hit in hits]}"


def test_jail_player_event_remains_console_only():
    entries = {entry["id"]: entry for entry in load_entries()}
    entry = entries["jail-player-event"]
    hits = hits_for(entry)
    assert len(hits) == 1
    body = hits[0].body
    assert entry["guard"] == "src ~= 0"
    assert "src ~= 0" in body
    assert "PolicePolicy.Can(" in body


def test_reverse_check_rejects_new_debt():
    entry = {
        "id": "synthetic",
        "kind": "table",
        "target": "police_arrests",
        "owner": "custom-police",
        "reason": "synthetic",
        "replacement": "none",
        # 真实写入点是 1（records.lua）；登记成 0 就是"比预算多写了一处" = new debt
        "expected_writes": 0,
        "added": "2026-10-24",
        "expires": "2026-12-31",
    }
    errors = evaluate([entry])
    assert any("new debt" in error for error in errors)


def test_reverse_check_rejects_expired_entry():
    entry = {
        "id": "synthetic",
        "kind": "command",
        "target": "/fine",
        "owner": "custom-police",
        "reason": "synthetic",
        "replacement": "none",
        "expected_writes": 1,
        "added": "2025-01-01",
        "expires": "2025-01-02",
    }
    errors = evaluate([entry], today=date(2026, 10, 24))
    assert any("expired" in error for error in errors)


def test_reverse_check_rejects_stale_entry():
    entry = {
        "id": "synthetic",
        "kind": "table",
        "target": "police_ghosts",
        "owner": "custom-police",
        "reason": "synthetic",
        "replacement": "none",
        # 真实写入点是 1（records.lua）；登记成 0 就是"比预算多写了一处" = new debt
        "expected_writes": 0,
        "added": "2026-10-24",
        "expires": "2099-01-01",
    }
    errors = evaluate([entry])
    assert any("stale entry" in error for error in errors)
