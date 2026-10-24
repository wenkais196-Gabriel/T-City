"""FIT-13 — the executable numbers in docs must match the code constants.

Static, offline contract (no FXServer, no DB, no network):

* ``number_budget.json`` registers every number that ops/architecture promises
  and that code implements: NPC budget (2 per player / 6 global), backup
  cooldown (60 s), callout interval (8 min) and chance (0.30), incident stale
  window (45 min), intent TTLs (done 7 days / pending 10 min), outbox interval
  (30 s) and max attempts (5);
* ``kind: implemented`` entries must have a code regex in
  ``T-CityLite.base/resources/...`` and at least one doc regex in
  ``docs/police/architecture/{05-nfr,02-state-machines,09-outbox}.md``. Every
  captured value must equal ``value`` (``scale`` converts ms→s or %→fraction);
* ``kind: proposed`` entries have no code pattern: they let a doc state a
  target (audit retention = 180 days) while the implementation is still
  missing. The JSON itself is the declaration that the number is a target;
  the doc must not drift away from that target.

Reverse checks mutate a doc value and a code constant in memory and require
the evaluator to report them, so changing ``≤2`` to ``≤3`` (or
``MAX_PLAYER = 3``) cannot silently keep FIT-13 green.

    python3 -m pytest -q tests/architecture/test_number_budget.py
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
BUDGET = Path(__file__).with_name("number_budget.json")
DOC_FILES = {
    "docs/police/architecture/05-nfr.md",
    "docs/police/architecture/02-state-machines.md",
    "docs/police/architecture/09-outbox.md",
}
VALID_KINDS = {"implemented", "proposed"}
REQUIRED_NUMBERS = {
    "npc-budget-per-player",
    "backup-cooldown",
    "npc-budget-global",
    "npc-callout-interval",
    "npc-callout-chance",
    "incident-stale-minutes",
    "intent-done-ttl",
    "intent-pending-ttl",
    "outbox-interval",
    "outbox-max-attempts",
    "police-audit-retention",
}
TOLERANCE = 1e-9


@dataclass(frozen=True)
class Entry:
    id: str
    kind: str
    value: float
    unit: str
    code: dict | None
    docs: list[dict]


def load_budget() -> dict:
    return json.loads(BUDGET.read_text(encoding="utf-8"))


def entries(registry: dict | None = None) -> list[Entry]:
    registry = registry or load_budget()
    return [
        Entry(
            id=str(item["id"]),
            kind=str(item["kind"]),
            value=float(item["value"]),
            unit=str(item.get("unit", "")),
            code=item.get("code"),
            docs=list(item.get("docs", [])),
        )
        for item in registry["entries"]
    ]


def _scaled(raw: str, scale: float) -> float:
    return float(raw) * scale


def _same(left: float, right: float) -> bool:
    return abs(left - right) <= TOLERANCE


def _line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def code_findings(entry: Entry, repo: Path = REPO, override: dict[str, str] | None = None) -> list[str]:
    """Return every code-side mismatch for one implemented entry."""
    if entry.code is None:
        return []
    file = str(entry.code.get("file", ""))
    pattern = str(entry.code.get("pattern", ""))
    scale = float(entry.code.get("scale", 1))
    path = repo / file
    if not path.is_file():
        return [f"FIT-13: {entry.id}: code file does not exist: {file}"]
    text = (override or {}).get(file) or path.read_text(encoding="utf-8")
    matches = list(re.finditer(pattern, text))
    if not matches:
        return [f"FIT-13: {entry.id}: code pattern did not match in {file}"]
    findings: list[str] = []
    for match in matches:
        raw = match.group(1)
        value = _scaled(raw, scale)
        if not _same(value, entry.value):
            findings.append(
                f"FIT-13: {file}:{_line_of(text, match.start())} says {value:g} "
                f"for {entry.id}, expected {entry.value:g}"
            )
    return findings


def doc_findings(entry: Entry, repo: Path = REPO, override: dict[str, str] | None = None) -> list[str]:
    """Return every doc-side mismatch for one entry (all matches are checked)."""
    findings: list[str] = []
    for ref in entry.docs:
        file = str(ref.get("file", ""))
        pattern = str(ref.get("pattern", ""))
        group = int(ref.get("group", 1))
        scale = float(ref.get("scale", 1))
        path = repo / file
        if not path.is_file():
            findings.append(f"FIT-13: {entry.id}: doc file does not exist: {file}")
            continue
        text = (override or {}).get(file) or path.read_text(encoding="utf-8")
        matches = list(re.finditer(pattern, text))
        if not matches:
            findings.append(
                f"FIT-13: {entry.id}: doc pattern did not match in {file}: {pattern!r}"
            )
            continue
        for match in matches:
            value = _scaled(match.group(group), scale)
            if not _same(value, entry.value):
                findings.append(
                    f"FIT-13: {file}:{_line_of(text, match.start())} says {value:g} "
                    f"for {entry.id}, expected {entry.value:g}"
                )
    return findings


def evaluate(registry: dict | None = None, repo: Path = REPO) -> list[str]:
    """Return every FIT-13 failure for the whole registry (empty means PASS)."""
    findings: list[str] = []
    for entry in entries(registry):
        if entry.kind == "implemented":
            findings.extend(code_findings(entry, repo))
        findings.extend(doc_findings(entry, repo))
    return findings


def validate_registry(registry: dict) -> list[str]:
    errors: list[str] = []
    ids: set[str] = set()
    for item in registry.get("entries", []):
        missing = [
            field for field in ("id", "kind", "value", "unit", "docs")
            if field not in item
        ]
        if missing:
            errors.append(f"entry missing {', '.join(missing)}: {item!r}")
            continue
        if item["kind"] not in VALID_KINDS:
            errors.append(f"{item['id']}: invalid kind {item['kind']!r}")
        if item["id"] in ids:
            errors.append(f"duplicate entry id {item['id']!r}")
        ids.add(item["id"])
        if not item["docs"]:
            errors.append(f"{item['id']}: needs at least one doc reference")
        if item["kind"] == "implemented" and not item.get("code"):
            errors.append(f"{item['id']}: implemented entry needs a code pattern")
        if item["kind"] == "proposed" and item.get("code"):
            errors.append(f"{item['id']}: proposed entry must not claim a code pattern")
        for ref in item["docs"]:
            for field in ("file", "pattern"):
                if not ref.get(field):
                    errors.append(f"{item['id']}: doc ref missing {field}")
            if ref.get("file") not in DOC_FILES:
                errors.append(f"{item['id']}: doc file outside 05/02/09: {ref.get('file')}")
    return errors


# ---------------------------------------------------------------------------
# pytest contract
# ---------------------------------------------------------------------------

def test_budget_is_well_formed():
    registry = load_budget()
    assert registry["version"] == 1
    assert registry["rule"] == "FIT-13"
    errors = validate_registry(registry)
    assert not errors, "\n".join(errors)
    assert {entry.id for entry in entries(registry)} == REQUIRED_NUMBERS


def test_code_and_docs_agree():
    findings = evaluate()
    assert not findings, "\n".join(findings)


def test_all_three_docs_participate():
    used = {
        ref["file"]
        for entry in entries()
        for ref in entry.docs
    }
    assert used == DOC_FILES, f"FIT-13: docs not covered: {sorted(DOC_FILES - used)}"


def test_proposed_values_are_declared_as_targets():
    proposed = [entry for entry in entries() if entry.kind == "proposed"]
    assert [entry.id for entry in proposed] == ["police-audit-retention"]
    # The retention job is not implemented; the doc target alone is checked.
    assert proposed[0].code is None
    assert proposed[0].value == 180
    assert not doc_findings(proposed[0])


def test_counts():
    registry = entries()
    assert len(registry) == 11
    assert sum(entry.kind == "implemented" for entry in registry) == 10
    assert sum(entry.kind == "proposed" for entry in registry) == 1
    assert len({entry.code["file"] for entry in registry if entry.code}) == 4


# ---------------------------------------------------------------------------
# Reverse checks
# ---------------------------------------------------------------------------

def test_reverse_check_detects_doc_drift():
    entry = next(item for item in entries() if item.id == "npc-budget-per-player")
    file = "docs/police/architecture/05-nfr.md"
    text = (REPO / file).read_text(encoding="utf-8")
    mutated = text.replace("每玩家 ≤2 单位", "每玩家 ≤3 单位", 1)
    assert mutated != text
    findings = doc_findings(entry, override={file: mutated})
    assert any("05-nfr.md" in finding and "3" in finding for finding in findings), findings


def test_reverse_check_detects_code_drift():
    entry = next(item for item in entries() if item.id == "npc-budget-per-player")
    file = entry.code["file"]
    text = (REPO / file).read_text(encoding="utf-8")
    mutated = text.replace("NPCBudget.MAX_PLAYER = 2", "NPCBudget.MAX_PLAYER = 3", 1)
    assert mutated != text
    findings = code_findings(entry, override={file: mutated})
    assert any("MAX_PLAYER" not in finding and "3" in finding for finding in findings), findings


def test_reverse_check_detects_missing_doc_phrase():
    entry = next(item for item in entries() if item.id == "backup-cooldown")
    file = "docs/police/architecture/05-nfr.md"
    text = (REPO / file).read_text(encoding="utf-8")
    mutated = text.replace("冷却 60 s/人", "冷却很快", 1)
    findings = doc_findings(entry, override={file: mutated})
    assert any("did not match" in finding for finding in findings), findings


def test_reverse_check_detects_outbox_interval_scale():
    entry = next(item for item in entries() if item.id == "outbox-interval")
    file = entry.code["file"]
    text = (REPO / file).read_text(encoding="utf-8")
    mutated = text.replace("OUTBOX_INTERVAL_MS = 30000", "OUTBOX_INTERVAL_MS = 60000", 1)
    findings = code_findings(entry, override={file: mutated})
    assert any("60" in finding for finding in findings), findings
