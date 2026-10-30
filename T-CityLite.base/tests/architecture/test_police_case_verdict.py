"""案卷判决回写（AC-P1-03 / v3.11）的闸门。

判决有两个落点：报告（`police_reports.justice_verdict`，按 justice_case_id）与
案卷（`police_cases.court_status/sentence_minutes`，按 id）。报告可能不存在，
所以案卷那一列必须存在且能写。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
BASE = REPO / "T-CityLite.base"
MIGRATION = BASE / "migrations/v3.11_police_case_verdict.sql"
FIXTURE = BASE / "tests/fixtures/tcity_schema.sql"
RECORDS = BASE / "resources/[custom]/custom-police/server/records.lua"
CASES = BASE / "resources/[custom]/custom-police/server/p3_cases.lua"
JUSTICE = BASE / "resources/[custom]/custom-justice/server/main.lua"


def test_migration_is_idempotent_and_fixture_matches() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    # 幂等：information_schema 判断 + PREPARE/EXECUTE（照 v3.6 的写法）
    assert sql.count("information_schema.COLUMNS") >= 2
    assert "PREPARE" in sql and "DEALLOCATE" in sql
    assert "ALTER TABLE police_cases" in sql
    for column in ("court_status", "sentence_minutes"):
        assert column in sql
        assert column in FIXTURE.read_text(encoding="utf-8"), "fixture 必须同步新列"


def test_verdict_writes_to_the_case_through_the_owner() -> None:
    records = RECORDS.read_text(encoding="utf-8")
    assert "RecordCaseVerdict" in records
    # 参数化 + 按 id 定位
    assert "UPDATE police_cases SET court_status = ?, sentence_minutes = ? WHERE id = ?" in records

    cases = CASES.read_text(encoding="utf-8")
    assert "exports('RecordCaseVerdict'" in cases, "必须作为导出暴露给司法侧"

    justice = JUSTICE.read_text(encoding="utf-8")
    # 建案时记录两套 id 的映射；判决时按映射回写
    assert "police_case_id" in justice
    assert "RecordCaseVerdict(c.police_case_id" in justice
