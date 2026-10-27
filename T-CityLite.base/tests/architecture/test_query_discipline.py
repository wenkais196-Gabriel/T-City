"""FIT-09 — query discipline: no ``SELECT *``, row sets need ``LIMIT``, parameterised WHERE.

Static, offline contract (no FXServer, no DB, no network):

* scan ``custom-police/server/**/*.lua``, ``custom-phone/server/**/*.lua``,
  ``custom-justice/server/**/*.lua`` and (when present)
  ``qb-prison/server/**/*.lua``;
* extract the SQL string passed to every ``MySQL.*`` call (cross-line ``[[ ]]``
  and ``a .. b`` fragments are joined) plus standalone SQL literals that are
  assembled in a variable before execution;
* flag ``select_star`` when a projection is ``SELECT *`` / ``SELECT alias.*``
  (``COUNT(*)`` is fine);
* flag ``no_limit`` when a row-set query has no ``LIMIT``. ``MySQL.single`` /
  ``MySQL.scalar`` / ``fetchScalar`` are single-row calls and are exempt, as are
  aggregate-only selects (``COUNT``/``SUM``/``AVG``/``MIN``/``MAX``/``GREATEST``);
* flag ``unsafe_concat`` when a literal containing ``WHERE`` is concatenated
  with a lowercase variable/expression (uppercase constants and literal
  continuations are allowed) and ``format_sql`` for ``string.format``-built SQL;
* comments are stripped first, so ``-- SELECT *) ...`` in a comment is not a
  violation; long brackets and escapes are handled.

Violations that are safe but not visible to a static scanner (a LIMIT appended
at the call site, for example) must be registered in ``query_allowlist.json``
with ``pattern`` / ``reason`` / ``owner`` / ``expires``. Expired or stale
entries fail the suite: the allowlist may only shrink.

    python3 -m pytest -q tests/architecture/test_query_discipline.py
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
SCAN_DIRS = (
    ("custom-police", CUSTOM / "custom-police" / "server"),
    ("custom-phone", CUSTOM / "custom-phone" / "server"),
    ("custom-justice", CUSTOM / "custom-justice" / "server"),
    ("qb-prison", RESOURCES / "[qb]" / "qb-prison" / "server"),
)
OPTIONAL_DIRS = {"qb-prison"}
ALLOWLIST = Path(__file__).with_name("query_allowlist.json")

LONG_OPEN = re.compile(r"\[(=*)\[")
MYSQL_CALL = re.compile(r"\bMySQL((?:\s*\.\s*\w+)+)\s*\(")
SQL_START = re.compile(
    r"^\s*(?:SELECT\b|INSERT\s+INTO\b|UPDATE\s+\S+\s+SET\b|DELETE\s+FROM\b|REPLACE\s+INTO\b)",
    re.I,
)
SELECT_ROWS = re.compile(r"^\s*SELECT\b", re.I)
SELECT_STAR = re.compile(r"\bSELECT\s+(?:[A-Za-z_]\w*\s*\.\s*)?\*", re.I)
AGGREGATE = re.compile(r"^\s*SELECT\s+(?:COUNT|SUM|AVG|MIN|MAX|GREATEST)\s*\(", re.I)
HAS_LIMIT = re.compile(r"\bLIMIT\b", re.I)
WHERE = re.compile(r"\bWHERE\b", re.I)
FROM = re.compile(r"\bFROM\b", re.I)
FORMAT_SPEC = re.compile(r"%[sdq]")
UPPER_CONSTANT = re.compile(r"^[A-Z][A-Z0-9_]+$")
IDENTIFIER = re.compile(r"^[A-Za-z_]\w*")

REQUIRED_FIELDS = ("id", "rule", "file", "pattern", "reason", "owner", "expires")


@dataclass(frozen=True)
class Statement:
    path: Path
    line: int
    method: str
    sql: str

    @property
    def where(self) -> str:
        try:
            return f"{self.path.relative_to(RESOURCES).as_posix()}:{self.line}"
        except ValueError:
            return f"{self.path}:{self.line}"


@dataclass(frozen=True)
class Finding:
    rule: str
    path: Path
    line: int
    sql: str

    @property
    def where(self) -> str:
        try:
            return f"{self.path.relative_to(RESOURCES).as_posix()}:{self.line}"
        except ValueError:
            return f"{self.path}:{self.line}"


# ---------------------------------------------------------------------------
# Lua-side scanning: comments out, strings in, calls split on the first argument
# ---------------------------------------------------------------------------

def mask_comments(text: str) -> str:
    """Blank ``--`` / ``--[[ ]]`` comments while keeping strings and newlines."""
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


def iter_strings(text: str, start: int = 0, end: int | None = None):
    """Yield ``(start, end, content)`` for every short/long Lua string."""
    end = len(text) if end is None else end
    i = start
    while i < end:
        char = text[i]
        if char in "'\"":
            j = i + 1
            while j < end:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == char:
                    break
                j += 1
            yield i, min(j + 1, end), text[i + 1:j]
            i = j + 1
        elif char == "[":
            long = LONG_OPEN.match(text, i)
            if long and long.start() == i:
                close = "]" + long.group(1) + "]"
                j = text.find(close, long.end(), end)
                if j < 0:
                    yield i, end, text[long.end():end]
                    i = end
                else:
                    yield i, j + len(close), text[long.end():j]
                    i = j + len(close)
            else:
                i += 1
        else:
            i += 1


def _line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def _close_paren(masked: str, open_index: int) -> int:
    depth = 0
    i = open_index
    n = len(masked)
    while i < n:
        char = masked[i]
        if char in "'\"":
            quote = char
            i += 1
            while i < n:
                if masked[i] == "\\":
                    i += 2
                    continue
                if masked[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if char == "[":
            long = LONG_OPEN.match(masked, i)
            if long:
                close = "]" + long.group(1) + "]"
                j = masked.find(close, long.end())
                i = n if j < 0 else j + len(close)
                continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def _first_argument(masked: str, open_index: int, close: int) -> tuple[int, int]:
    """Return the [start, end) span of the first argument of the call."""
    depth = 0
    i = open_index + 1
    while i < close:
        char = masked[i]
        if char in "'\"":
            quote = char
            i += 1
            while i < close:
                if masked[i] == "\\":
                    i += 2
                    continue
                if masked[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if char == "[":
            long = LONG_OPEN.match(masked, i)
            if long:
                close2 = "]" + long.group(1) + "]"
                j = masked.find(close2, long.end(), close)
                i = close if j < 0 else j + len(close2)
                continue
        if char in "({[":
            depth += 1
        elif char in ")}]":
            depth -= 1
        elif char == "," and depth == 0:
            return open_index + 1, i
        i += 1
    return open_index + 1, close


def _mysql_method(chain: str) -> str:
    parts = [part.strip() for part in chain.split(".") if part.strip()]
    if parts and parts[0].lower() == "async" and len(parts) > 1:
        return parts[1]
    return parts[0] if parts else "?"


def _normalise(sql: str) -> str:
    return re.sub(r"\s+", " ", sql).strip()


def extract_statements(path: Path, text: str) -> list[Statement]:
    masked = mask_comments(text)
    statements: list[Statement] = []
    covered: list[tuple[int, int]] = []

    for match in MYSQL_CALL.finditer(masked):
        open_index = masked.find("(", match.start())
        close = _close_paren(masked, open_index)
        if close < 0:
            continue
        covered.append((open_index, close))
        arg_start, arg_end = _first_argument(masked, open_index, close)
        parts = [content for _, _, content in iter_strings(masked, arg_start, arg_end)]
        sql = _normalise(" ".join(part.strip() for part in parts))
        if SQL_START.match(sql):
            statements.append(
                Statement(path, _line_of(text, match.start()), _mysql_method(match.group(1)), sql)
            )

    def inside_call(position: int) -> bool:
        return any(start <= position < end for start, end in covered)

    # SQL assembled in a variable: merge literals joined by `..`, then check if
    # the assembled statement starts with a SQL verb.
    groups: list[tuple[int, int, list[str]]] = []
    for start, end, content in iter_strings(masked):
        if inside_call(start):
            continue
        if groups:
            prev_start, prev_end, parts = groups[-1]
            if re.fullmatch(r"\s*\.\.\s*", masked[prev_end:start]):
                parts.append(content)
                groups[-1] = (prev_start, end, parts)
                continue
        groups.append((start, end, [content]))
    for start, _, parts in groups:
        sql = _normalise(" ".join(part.strip() for part in parts))
        if SQL_START.match(sql):
            statements.append(Statement(path, _line_of(text, start), "raw", sql))
    return statements


def _unsafe_concats(path: Path, masked: str, text: str) -> list[Finding]:
    findings: list[Finding] = []
    for start, end, content in iter_strings(masked):
        if not WHERE.search(content):
            continue
        # Only scrutinise literals that look like SQL, not log messages.
        if not SQL_START.match(content) and not FROM.search(content):
            continue
        cursor = end
        while cursor < len(masked) and masked[cursor].isspace():
            cursor += 1
        if not masked.startswith("..", cursor):
            continue
        cursor += 2
        while cursor < len(masked) and masked[cursor].isspace():
            cursor += 1
        operand = masked[cursor:cursor + 120]
        if not operand:
            continue
        if operand[0] in "'\"":
            continue
        if LONG_OPEN.match(operand):
            continue
        if operand[0].isdigit():
            continue
        identifier = IDENTIFIER.match(operand)
        if identifier and UPPER_CONSTANT.match(identifier.group(0)):
            continue
        findings.append(
            Finding(
                "unsafe_concat",
                path,
                _line_of(text, start),
                _normalise(content + " .. " + operand.splitlines()[0])[:240],
            )
        )
    return findings


def _format_sql(path: Path, masked: str, text: str) -> list[Finding]:
    findings: list[Finding] = []
    for start, end, content in iter_strings(masked):
        if not SQL_START.match(content) or not FORMAT_SPEC.search(content):
            continue
        before = masked[max(0, start - 40):start]
        after = masked[end:end + 40]
        if re.search(r"string\.format\s*\(\s*$", before) or re.match(r"\s*:\s*format\s*\(", after):
            findings.append(
                Finding("format_sql", path, _line_of(text, start), _normalise(content)[:240])
            )
    return findings


def scan_source(path: Path, text: str) -> list[Finding]:
    findings: list[Finding] = []
    masked = mask_comments(text)
    for statement in extract_statements(path, text):
        if SELECT_STAR.search(statement.sql):
            findings.append(Finding("select_star", path, statement.line, statement.sql))
        if not SELECT_ROWS.match(statement.sql):
            continue
        method = statement.method.lower()
        single_row = "single" in method or "scalar" in method
        if single_row or AGGREGATE.match(statement.sql) or HAS_LIMIT.search(statement.sql):
            continue
        findings.append(Finding("no_limit", path, statement.line, statement.sql))
    findings.extend(_unsafe_concats(path, masked, text))
    findings.extend(_format_sql(path, masked, text))
    return findings


def lua_files(targets: list[Path] | None = None) -> list[Path]:
    if targets is None:
        targets = [directory for _, directory in SCAN_DIRS if directory.is_dir()]
    files: list[Path] = []
    for target in targets:
        if target.is_file() and target.suffix == ".lua":
            files.append(target)
        elif target.is_dir():
            files.extend(sorted(target.rglob("*.lua")))
    return sorted(set(files))


def scan_paths(targets: list[Path] | None = None) -> list[Finding]:
    findings: list[Finding] = []
    for path in lua_files(targets):
        findings.extend(scan_source(path, path.read_text(encoding="utf-8")))
    return findings


def collect_statements(targets: list[Path] | None = None) -> list[Statement]:
    statements: list[Statement] = []
    for path in lua_files(targets):
        statements.extend(extract_statements(path, path.read_text(encoding="utf-8")))
    return statements


# ---------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------

def load_allowlist() -> list[dict]:
    with ALLOWLIST.open(encoding="utf-8") as handle:
        data = json.load(handle)
    return data.get("entries", [])


def validate_allowlist(entries: list[dict]) -> list[str]:
    problems: list[str] = []
    today = date.today()
    for entry in entries:
        missing = [field for field in REQUIRED_FIELDS if not entry.get(field)]
        if missing:
            problems.append(f"{entry.get('id', '?')}: missing fields {missing}")
            continue
        try:
            expires = date.fromisoformat(entry["expires"])
        except ValueError:
            problems.append(f"{entry['id']}: invalid expires {entry['expires']!r}")
            continue
        if expires < today:
            problems.append(f"{entry['id']}: expired on {entry['expires']} (today {today})")
        try:
            re.compile(entry["pattern"])
        except re.error as exc:
            problems.append(f"{entry['id']}: bad pattern ({exc})")
    return problems


def _resource_relative(path: Path) -> str:
    """``resources/[custom]/custom-police/server/x.lua`` -> ``custom-police/server/x.lua``."""
    try:
        relative = path.relative_to(RESOURCES).as_posix()
    except ValueError:
        return path.as_posix()
    match = re.match(r"^\[[^\]]+\]/(.*)$", relative)
    return match.group(1) if match else relative


def _entry_matches(entry: dict, finding: Finding) -> bool:
    relative = _resource_relative(finding.path)
    if not fnmatch.fnmatch(relative, entry["file"]):
        return False
    if entry.get("rule") and entry["rule"] != finding.rule:
        return False
    return re.search(entry["pattern"], finding.sql) is not None


def apply_allowlist(findings: list[Finding], entries: list[dict]) -> tuple[list[Finding], int, list[str]]:
    """Return (unallowed findings, allowlisted count, stale-entry problems)."""
    used: set[str] = set()
    kept: list[Finding] = []
    allowlisted = 0
    for finding in findings:
        matched = None
        for entry in entries:
            if _entry_matches(entry, finding):
                matched = entry
                break
        if matched is None:
            kept.append(finding)
        else:
            used.add(matched["id"])
            allowlisted += 1
    stale = [
        f"{entry['id']}: allowlist entry matches no violation (delete it)"
        for entry in entries
        if entry.get("id") not in used
    ]
    return kept, allowlisted, stale


def report() -> str:
    findings = scan_paths()
    entries = load_allowlist()
    problems = validate_allowlist(entries)
    kept, allowlisted, stale = apply_allowlist(findings, entries)
    status = "FAIL" if (kept or problems or stale) else "PASS"
    lines = [
        f"FIT-09 query-discipline  {status}  {len(kept)} violations, "
        f"{allowlisted} allowlisted, {len(findings)} findings"
    ]
    for finding in kept:
        lines.append(f"  {finding.where}  {finding.rule}  {finding.sql[:160]}")
    for problem in problems + stale:
        lines.append(f"  ALLOWLIST {problem}")
    lines.append(
        '  summary: {"rule":"FIT-09","violations":%d,"allowlisted":%d,'
        '"findings":%d,"allowlist_problems":%d}'
        % (len(kept), allowlisted, len(findings), len(problems) + len(stale))
    )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------

def test_scanned_resources_exist_and_the_scanner_is_not_vacuous():
    for resource, directory in SCAN_DIRS:
        if resource in OPTIONAL_DIRS:
            continue
        assert directory.is_dir(), f"missing scan directory: {directory}"
    statements = collect_statements()
    assert len(statements) >= 80, f"only {len(statements)} SQL statements parsed — parser drifted"
    parsed = {statement.path.as_posix() for statement in statements}
    for expected in (
        "custom-police/server/p0_incidents.lua",
        "custom-police/server/p0_units.lua",
        "custom-police/server/p1.lua",
        "custom-police/server/p2_evidence.lua",
        "custom-police/server/p3_cases.lua",
        "custom-phone/server/main.lua",
        "custom-justice/server/sentence.lua",
    ):
        assert any(path.endswith(expected) for path in parsed), f"{expected} contributed no SQL"


def test_no_query_discipline_violations():
    findings = scan_paths()
    entries = load_allowlist()
    problems = validate_allowlist(entries)
    kept, allowlisted, stale = apply_allowlist(findings, entries)
    output = report()
    print(output)
    assert problems == [], "\n".join(problems)
    assert stale == [], "\n".join(stale)
    assert kept == [], output
    # The scan must still be doing work: a parser that silently finds nothing
    # would also report zero violations.
    assert findings, "no SQL findings at all — the scanner is broken"


def test_allowlist_is_explicit_and_used():
    entries = load_allowlist()
    findings = scan_paths()
    _, allowlisted, stale = apply_allowlist(findings, entries)
    assert validate_allowlist(entries) == []
    assert stale == []
    assert allowlisted == sum(
        1 for finding in findings
        if any(_entry_matches(entry, finding) for entry in entries)
    )
    # Only the two statically-invisible-but-safe LIMITs are allowed today.
    assert allowlisted == 2, f"expected 2 allowlisted findings, got {allowlisted}"


def test_injected_select_star_is_caught(tmp_path):
    target = tmp_path / "custom-police" / "server" / "injected.lua"
    target.parent.mkdir(parents=True)
    target.write_text(
        "local rows = MySQL.query.await('SELECT * FROM police_units')\n",
        encoding="utf-8",
    )
    findings = scan_paths([target])
    assert ("select_star", 1) in [(finding.rule, finding.line) for finding in findings]


def test_injected_missing_limit_and_unsafe_concat_are_caught(tmp_path):
    missing_limit = tmp_path / "custom-police" / "server" / "no_limit.lua"
    missing_limit.parent.mkdir(parents=True)
    missing_limit.write_text(
        "local rows = MySQL.query.await('SELECT id FROM police_units')\n",
        encoding="utf-8",
    )
    concat = tmp_path / "custom-police" / "server" / "concat.lua"
    concat.write_text(
        "local id = 1\n"
        "local rows = MySQL.query.await('SELECT id FROM police_units WHERE id = ' .. id)\n",
        encoding="utf-8",
    )
    findings = scan_paths([missing_limit, concat])
    assert ("no_limit", 1) in [(finding.rule, finding.line) for finding in findings]
    assert ("unsafe_concat", 2) in [(finding.rule, finding.line) for finding in findings]


def test_injected_format_built_sql_is_caught(tmp_path):
    target = tmp_path / "format.lua"
    target.write_text(
        "local id = 1\n"
        "local sql = string.format('SELECT id FROM police_units WHERE id = %s', id)\n",
        encoding="utf-8",
    )
    findings = scan_paths([target])
    assert ("format_sql", 2) in [(finding.rule, finding.line) for finding in findings]


def test_safe_shapes_and_comments_are_not_flagged(tmp_path):
    target = tmp_path / "safe.lua"
    target.write_text(
        "-- MySQL.query.await('SELECT * FROM police_units')\n"
        "local one = MySQL.single.await('SELECT id FROM police_units WHERE id = ?', { 1 })\n"
        "local count = MySQL.scalar.await('SELECT COUNT(*) FROM police_units')\n"
        "local rows = MySQL.query.await('SELECT id FROM police_units LIMIT 10')\n"
        "local allowed = MySQL.query.await(\n"
        "    'SELECT id FROM police_units WHERE citizenid = ? ' .. TABLE_NAME .. ' LIMIT 10', { 'x' })\n",
        encoding="utf-8",
    )
    assert scan_paths([target]) == []


if __name__ == "__main__":  # pragma: no cover - manual runner
    print(report())
