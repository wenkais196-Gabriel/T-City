"""FIT-06 — migrations ↔ DB fixture parity.

Static, offline contract (no FXServer, no DB, no network):

* every ``CREATE TABLE`` in ``migrations/*.sql`` must also exist in
  ``tests/fixtures/tcity_schema.sql`` — otherwise the CI DB job imports a
  fixture that silently lacks a table and the DB integration tests skip;
* every ``ALTER TABLE … ADD COLUMN`` in the migrations must be reflected in the
  fixture, so a column added after the initial ``CREATE TABLE`` (v3.3–v3.12:
  ``justice_case_id`` / ``justice_verdict`` / ``justice_status``,
  ``disposition`` / ``closed_by`` / ``closed_reason`` / ``last_activity_at``,
  ``npc_template``, ``expires_at`` / ``completed_at``) is present;
* the required tables listed in ``tests/check_db_schema.py`` must be in the
  fixture too, so the DB checker and the CI fixture cannot drift apart.

Reverse validation lives in :class:`TestDetectorSelfCheck`: one ``CREATE TABLE``
block is deleted from an *in-memory* copy of the fixture and the detector must
report it. The fixture on disk is never modified — a broken parser can therefore
not make this suite pass vacuously.

SQL comments are stripped before parsing: v2.8's header contains the prose
"Idempotent: CREATE TABLE IF NOT EXISTS only." which would otherwise be read as
a table named ``only``.

    python3 -m pytest -q tests/architecture/test_fixture_schema.py
"""
from __future__ import annotations

import importlib.util
import re
from functools import lru_cache
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
MIGRATIONS = BASE / "migrations"
FIXTURE = BASE / "tests" / "fixtures" / "tcity_schema.sql"
DB_CHECK = BASE / "tests" / "check_db_schema.py"

_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_LINE_COMMENT = re.compile(r"--[^\n]*")
_CREATE_TABLE = re.compile(
    r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`?([A-Za-z0-9_]+)`?\s*\(",
    re.I,
)
_ADD_COLUMN = re.compile(
    r"ALTER\s+TABLE\s+`?([A-Za-z0-9_]+)`?\s+ADD\s+COLUMN\s+"
    r"(?:IF\s+NOT\s+EXISTS\s+)?`?([A-Za-z0-9_]+)`?",
    re.I,
)
# A column definition starts a line with `name` followed by a type; index and
# constraint lines start with PRIMARY / KEY / UNIQUE / CONSTRAINT instead, so a
# column that still appears in an index no longer counts as present.
_COLUMN_DEF = re.compile(r"^\s*`([A-Za-z0-9_]+)`\s+[A-Za-z]", re.M)

# Tables the police / justice / agent code paths cannot run without. Kept
# explicit (in addition to the migration-derived set) so a regression in
# _CREATE_TABLE cannot make the suite pass while a domain table is missing.
REQUIRED_DOMAIN_TABLES = (
    "police_units",
    "police_incidents",
    "police_incident_units",
    "police_audit",
    "police_citations",
    "police_reports",
    "police_evidence",
    "police_evidence_chain",
    "police_cases",
    "police_bolos",
    "police_warrants",
    "police_arrests",
    "justice_sentences",
    "police_write_intents",
    "police_outbox",
    "agent_events",
    "agent_actions",
    "agent_denials",
    "agent_effects",
    "agent_director_state",
)

# (migration, table, column) added by an ALTER rather than the CREATE TABLE.
# These are the post-v3.6 columns that must show up in the fixture.
CRITICAL_ADD_COLUMNS = (
    ("v3.6_police_justice_case.sql", "police_reports", "justice_case_id"),
    ("v3.7_police_justice_verdict.sql", "police_reports", "justice_verdict"),
    ("v3.7_police_justice_verdict.sql", "police_reports", "justice_status"),
    ("v3.10_police_incident_disposition.sql", "police_incidents", "disposition"),
    ("v3.10_police_incident_disposition.sql", "police_incidents", "closed_by"),
    ("v3.10_police_incident_disposition.sql", "police_incidents", "closed_reason"),
    ("v3.10_police_incident_disposition.sql", "police_incidents", "last_activity_at"),
    ("v3.11_police_npc_callout.sql", "police_incidents", "npc_template"),
    ("v3.12_police_outbox.sql", "police_write_intents", "expires_at"),
    ("v3.12_police_outbox.sql", "police_write_intents", "completed_at"),
)


# ── Parsing ────────────────────────────────────────────────────────────────

def strip_sql_comments(sql: str) -> str:
    """Remove ``/* … */`` and ``-- …`` comments so prose is not parsed as DDL."""
    return _LINE_COMMENT.sub("", _BLOCK_COMMENT.sub("", sql))


def read_sql(path: Path) -> str:
    return strip_sql_comments(path.read_text(encoding="utf-8", errors="ignore"))


@lru_cache(maxsize=1)
def fixture_sql() -> str:
    return read_sql(FIXTURE)


def table_names(sql: str) -> set[str]:
    return {m.group(1).lower() for m in _CREATE_TABLE.finditer(sql)}


def table_block(sql: str, table: str) -> str | None:
    """Return the ``CREATE TABLE`` statement for *table* (comments stripped)."""
    pattern = re.compile(
        r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`?"
        + re.escape(table)
        + r"`?\s*\(",
        re.I,
    )
    match = pattern.search(sql)
    if match is None:
        return None
    end = sql.find(";", match.end())
    return sql[match.start():] if end == -1 else sql[match.start():end]


def has_column(sql: str, table: str, column: str) -> bool:
    block = table_block(sql, table)
    if block is None:
        return False
    return column.lower() in {
        match.group(1).lower() for match in _COLUMN_DEF.finditer(block)
    }


@lru_cache(maxsize=1)
def migration_tables() -> dict[str, tuple[str, ...]]:
    """``{table: (migration files that CREATE it, …)}`` over all migrations."""
    found: dict[str, set[str]] = {}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        for match in _CREATE_TABLE.finditer(read_sql(path)):
            found.setdefault(match.group(1).lower(), set()).add(path.name)
    return {table: tuple(sorted(files)) for table, files in found.items()}


@lru_cache(maxsize=1)
def migration_added_columns() -> dict[tuple[str, str], tuple[str, ...]]:
    """``{(table, column): (migration files that ADD it, …)}``."""
    found: dict[tuple[str, str], set[str]] = {}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        for match in _ADD_COLUMN.finditer(read_sql(path)):
            key = (match.group(1).lower(), match.group(2).lower())
            found.setdefault(key, set()).add(path.name)
    return {key: tuple(sorted(files)) for key, files in found.items()}


def missing_tables(sql: str | None = None) -> list[str]:
    """Migration tables absent from *sql* (defaults to the fixture on disk)."""
    present = table_names(fixture_sql() if sql is None else sql)
    return sorted(set(migration_tables()) - present)


def missing_columns(sql: str | None = None) -> list[str]:
    """``table.column`` pairs added by a migration but absent from *sql*."""
    text = fixture_sql() if sql is None else sql
    return [
        f"{table}.{column} ({'/'.join(files)})"
        for (table, column), files in sorted(migration_added_columns().items())
        if not has_column(text, table, column)
    ]


@lru_cache(maxsize=1)
def db_check_expected_schema() -> dict[str, dict[str, list[str]]]:
    spec = importlib.util.spec_from_file_location("_tcity_check_db_schema", DB_CHECK)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.EXPECTED_SCHEMA


# ── Fixture covers the migrations ──────────────────────────────────────────

def test_every_migration_table_is_in_the_fixture():
    missing = missing_tables()
    assert not missing, (
        f"FIT-06: tests/fixtures/tcity_schema.sql missing {len(missing)} "
        f"tables from migrations: " + ", ".join(missing)
    )


@pytest.mark.parametrize("table", REQUIRED_DOMAIN_TABLES)
def test_required_domain_table_is_in_the_fixture(table):
    assert table in table_names(fixture_sql()), (
        f"FIT-06: {table} is required by the police/justice/agent domain but "
        "tests/fixtures/tcity_schema.sql does not create it"
    )


def test_every_migration_added_column_is_in_the_fixture():
    missing = missing_columns()
    assert not missing, (
        f"FIT-06: tests/fixtures/tcity_schema.sql is missing "
        f"{len(missing)} columns added by migrations: " + ", ".join(missing)
    )


@pytest.mark.parametrize("migration,table,column", CRITICAL_ADD_COLUMNS)
def test_critical_add_column_is_parsed_and_in_the_fixture(migration, table, column):
    assert (MIGRATIONS / migration).is_file(), f"missing migration {migration}"
    added = {
        (tbl, col)
        for (tbl, col), files in migration_added_columns().items()
        if migration in files
    }
    assert (table, column) in added, (
        f"{migration} no longer adds {table}.{column}; update the migration "
        "and this contract together"
    )
    block = table_block(fixture_sql(), table)
    assert block is not None, f"fixture does not create {table}"
    assert has_column(fixture_sql(), table, column), (
        f"FIT-06: fixture {table} is missing `{column}` added by {migration}"
    )


def test_check_db_schema_required_tables_are_in_the_fixture():
    fixture = table_names(fixture_sql())
    expected = {name.lower() for name in db_check_expected_schema()}
    missing = sorted(expected - fixture)
    assert not missing, (
        "tests/check_db_schema.py requires tables the fixture does not create: "
        + ", ".join(missing)
    )


# ── Reverse validation ─────────────────────────────────────────────────────

class TestDetectorSelfCheck:
    """A deleted table must be reported; the fixture on disk is untouched.

    This removes one ``CREATE TABLE`` block from an in-memory copy of the
    fixture only (no temporary file, no write), which is the reverse case the
    real check has to catch when a migration adds a table and the fixture is
    forgotten.
    """

    def test_removing_a_table_is_reported(self):
        sql = fixture_sql()
        pruned = re.sub(
            r"CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+`police_units`.*?;",
            "",
            sql,
            count=1,
            flags=re.S,
        )
        assert pruned != sql, "self-check pattern no longer matches police_units"
        assert "police_units" not in table_names(pruned)
        assert missing_tables(pruned) == ["police_units"], (
            "removing one table must report exactly that table; got "
            f"{missing_tables(pruned)}"
        )

    def test_removing_a_column_is_reported(self):
        sql = fixture_sql()
        pruned = sql.replace("`npc_template` varchar(32) DEFAULT NULL,", "", 1)
        assert pruned != sql, "self-check pattern no longer matches npc_template"
        gaps = missing_columns(pruned)
        assert any(gap.startswith("police_incidents.npc_template") for gap in gaps), (
            f"removed column was not reported; got {gaps}"
        )
