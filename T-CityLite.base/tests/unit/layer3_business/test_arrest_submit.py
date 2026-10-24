"""Static contract for the P1 arrest-as-report single submit path.

One arrest is submitted through a single server-side call, `ArrestSubmit`, that
writes `police_reports(kind='arrest')` plus optional citation/evidence/case,
audits the action and sentences the suspect. The client can never send the
sentence or an out-of-range fine, and the server re-checks the physical
preconditions (restrained, in range, not already jailed, BOLO rank).

Static (source-level) assertions only: they need no FiveM, database or Lua
runtime and run in CI alongside the other layer3_business contracts.

    python3 -m pytest -q T-CityLite.base/tests/unit/layer3_business/test_arrest_submit.py
"""
from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]  # T-CityLite.base/
POLICE = BASE / "resources" / "[custom]" / "custom-police"
JUSTICE = BASE / "resources" / "[custom]" / "custom-justice"
MIGRATION_V34 = BASE / "migrations" / "v3.4_police_arrest.sql"
MIGRATION_V35 = BASE / "migrations" / "v3.5_police_arrest_subject.sql"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def arrest_block() -> str:
    src = read(POLICE / "server/p2_system.lua")
    start = src.index("function ArrestSubmit(")
    end = src.index("\nexports('CreateIncidentSystem'", start)
    return src[start:end]


def get_arrests_block() -> str:
    src = read(POLICE / "server/p3_cases.lua")
    start = src.index("function C.GetArrests(")
    end = src.index("function C.GetCaseDetail(", start)
    return src[start:end]


def case_detail_block() -> str:
    src = read(POLICE / "server/p3_cases.lua")
    start = src.index("function C.GetCaseDetail(")
    end = src.index("exports('CreateCase'", start)
    return src[start:end]


# ---------------------------------------------------------------------------
# Charge catalogue
# ---------------------------------------------------------------------------

def test_charge_catalog_matches_justice_config():
    ours = read(POLICE / "shared/charges.lua")
    justice = read(JUSTICE / "config.lua")

    justice_rows = {
        cid: (int(minutes), int(fine))
        for cid, minutes, fine in re.findall(
            r"(\w+)\s*=\s*\{\s*label = '[^']*',\s*baseMinutes = (\d+),\s*"
            r"maxMinutes = \d+,\s*fine = (\d+)",
            justice,
        )
    }
    assert len(justice_rows) == 13, f"expected 13 justice charges, got {justice_rows}"

    ours_rows = {
        cid: (int(minutes), int(fine))
        for cid, minutes, fine in re.findall(
            r"(\w+)\s*=\s*\{\s*id = '\w+',\s*label = '[^']*',\s*"
            r"baseMinutes = (\d+),\s*fine = (\d+)",
            ours,
        )
    }
    assert ours_rows == justice_rows


def test_charge_catalog_validates_lookups_and_sums():
    src = read(POLICE / "shared/charges.lua")
    assert "function PoliceCharges.Get" in src
    assert "function PoliceCharges.Sum" in src
    assert "function PoliceCharges.List" in src
    assert "MAX_CHARGES = 8" in src
    assert "return { minutes = minutes, fine = fine, labels = labels }" in src
    assert "invalid_charge" in src
    assert "duplicate_charge" in src
    assert "if count < 1 or count > MAX_CHARGES" in src


# ---------------------------------------------------------------------------
# Migrations
# ---------------------------------------------------------------------------

def test_v34_migration_adds_arrest_columns_and_indexes():
    sql = read(MIGRATION_V34)
    assert sql.count("information_schema.COLUMNS") >= 12

    for column in (
        "kind", "case_id", "charges", "is_bolo", "bolo_kind", "bolo_target",
        "location", "officer_citizenid",
    ):
        assert re.search(rf"\b{column}\b", sql), f"police_reports missing {column}"

    for column in ("charge_id", "base_amount", "report_id"):
        assert re.search(rf"\b{column}\b", sql), f"police_citations missing {column}"

    assert "police_evidence" in sql and "report_id" in sql
    assert "ENUM('report','arrest')" in sql
    assert "DEFAULT 'report'" in sql
    assert "charges JSON" in sql
    assert "is_bolo TINYINT" in sql

    assert "information_schema.STATISTICS" in sql
    for index, columns in (
        ("idx_kind_created", "kind, created_at"),
        ("idx_report", "report_id"),
    ):
        assert f"{index} ({columns})" in sql, f"missing index {index}({columns})"

    # Every conditional ALTER must be prepared and deallocated.
    prepared = len(re.findall(r"^PREPARE ", sql, re.M))
    assert prepared == 15
    assert prepared == sql.count("DEALLOCATE PREPARE")
    assert sql.count("IF(@h") + sql.count("IF(@i") == 15


def test_v35_migration_adds_subject_citizenid_idempotently():
    sql = read(MIGRATION_V35)
    assert "ALTER TABLE police_reports ADD COLUMN subject_citizenid VARCHAR(50)" in sql
    assert "information_schema.COLUMNS" in sql
    assert "IF(@h1 = 0" in sql

    # Re-running the migration must be a no-op, so the index is guarded too.
    assert "information_schema.STATISTICS" in sql
    assert "IF(@i1 = 0" in sql
    assert "idx_subject_kind_created" in sql

    prepared = len(re.findall(r"^PREPARE ", sql, re.M))
    assert prepared == 2
    assert prepared == sql.count("DEALLOCATE PREPARE")
    # Both ALTERs live inside the guarded prepared-statement strings.
    assert len(re.findall(r"^PREPARE st\d", sql, re.M)) == 2


def test_manifest_loads_charge_catalog_and_version_is_bumped():
    manifest = read(POLICE / "fxmanifest.lua")
    assert "shared/charges.lua" in manifest
    assert manifest.index("shared/charges.lua") < manifest.index("server/p2_system.lua")
    assert "version '1.4.0'" in manifest
    assert "version '1.3.5'" not in manifest


# ---------------------------------------------------------------------------
# ArrestSubmit
# ---------------------------------------------------------------------------

def test_arrest_submit_is_gated_and_audited():
    block = arrest_block()
    src = read(POLICE / "server/p2_system.lua")
    assert "exports('ArrestSubmit', ArrestSubmit)" in src
    assert "PolicePolicy.Can(actor, 'arrest.create')" in block
    assert "QBCore.Functions.GetPlayerByCitizenId(target)" in block
    assert "citizen_offline" in block
    assert "auditPlayer(actor.citizenid, 'arrest.register', target, auditDetail)" in block
    assert 'actor_kind, action, target, detail) VALUES (?, "player", ?, ?, ?)' in src
    assert "audit_unavailable" in block
    assert "function fail(error)" in src


def test_bolo_requires_bolo_create_and_is_audited():
    block = arrest_block()
    assert "local bolo = params.bolo == true" in block
    assert "PolicePolicy.Can(actor, 'bolo.create')" in block
    assert "bolo_forbidden" in block
    assert "auditPlayer(actor.citizenid, 'bolo.create', boloTarget, boloKind .. boloTarget)" in block


def test_target_must_be_restrained_in_range_and_not_jailed():
    block = arrest_block()
    # Both server-side peds must exist.
    assert "local actorPed = GetPlayerPed(tonumber(source) or 0)" in block
    assert "targetPed = (targetSrc and targetSrc > 0) and GetPlayerPed(targetSrc) or 0" in block
    assert "actorPed == 0" in block and "targetPed == 0" in block
    assert "target_unavailable" in block

    # Already serving a sentence.
    assert "(tonumber(metadata.injail) or 0) > 0" in block
    assert "already_jailed" in block

    # Cuffed / dead / last stand only.
    assert "metadata.ishandcuffed == true" in block
    assert "metadata.isdead == true" in block
    assert "metadata.inlaststand == true" in block
    assert "target_not_cuffed" in block

    # The officer must be within 5m of the target ped.
    assert "#(GetEntityCoords(actorPed) - GetEntityCoords(targetPed)) > 5.0" in block
    assert "too_far" in block


def test_report_is_the_anchor_and_children_are_linked():
    block = arrest_block()
    assert "INSERT INTO police_reports" in block
    assert "'arrest'" in block
    assert "charges" in block and "encodeCharges(ids)" in block
    assert "is_bolo" in block and "bolo_kind" in block and "bolo_target" in block
    assert "officer_citizenid" in block
    assert "subject_citizenid" in block

    assert "INSERT INTO police_citations" in block
    citation_insert = block[block.index("INSERT INTO police_citations"):]
    assert "report_id" in citation_insert
    assert "base_amount" in citation_insert
    assert "charge_id" in citation_insert

    assert "INSERT INTO police_evidence" in block
    evidence_insert = block[block.index("INSERT INTO police_evidence"):]
    assert "report_id" in evidence_insert

    # Evidence always gets a first custody-chain entry.
    assert "INSERT INTO police_evidence_chain" in block
    assert "'collected'" in block

    # Case linkage is written back onto the report.
    assert "UPDATE police_reports SET case_id = ? WHERE id = ?" in block
    assert "INSERT INTO police_cases" in block
    assert "CASE-%s-%06d" in block

    # police_arrests is retired for new arrests.
    assert "INSERT INTO police_arrests" not in block

    # Compensating rollback keeps a failed multi-write from leaving orphans.
    assert "DELETE FROM police_reports WHERE id = ?" in block
    assert "DELETE FROM police_citations WHERE id = ?" in block
    assert "DELETE FROM police_evidence WHERE id = ?" in block
    assert "DELETE FROM police_evidence_chain WHERE evidence_id = ?" in block
    assert "rollback()" in block


def test_sentence_and_fine_are_server_derived():
    src = read(POLICE / "server/p2_system.lua")
    block = arrest_block()
    assert "MIN_MINUTES = 1" in src
    assert "MAX_MINUTES = 120" in src
    assert "math.max(MIN_MINUTES, math.min(MAX_MINUTES" in block
    assert "PoliceCharges.Sum(ids)" in block

    # The client may suggest a citation amount, but only inside +/-20%.
    assert "CITATION_LOW = 0.8" in src
    assert "CITATION_HIGH = 1.2" in src
    assert "params.citation_amount" in block
    assert "invalid_amount" in block

    # No client-supplied sentence or fine.
    assert "params.minutes" not in block
    assert "params.fine" not in block


def test_jail_failure_rolls_back_before_any_audit():
    block = arrest_block()
    assert "exports['custom-justice']:Imprison(target, minutes, ids)" in block
    assert "SetMetaData('injail', minutes)" in block
    assert "TriggerClientEvent('prison:client:Enter'" in block
    assert "jailed = true" in block

    jail_failed = block.index("if not applied then")
    final_audit = block.index("auditPlayer(actor.citizenid, 'arrest.register'")
    assert jail_failed < final_audit, "the final audit must be written after the sentence"

    failed_branch = block[jail_failed:block.index("-- Audit only once", jail_failed)]
    assert "rollback()" in failed_branch
    assert "return fail('jail_failed')" in failed_branch
    assert "auditPlayer" not in failed_branch


def test_case_creation_requires_case_capability_and_uses_officer_as_lead():
    block = arrest_block()
    assert "PolicePolicy.Can(actor, 'case.create')" in block
    assert "case_forbidden" in block
    assert "case_not_found" in block
    assert "invalid_case_combination" in block
    assert "local createCase = params.create_case == true" in block

    # The lead is the arresting officer; the suspect is named in the summary.
    assert "'INSERT INTO police_cases (title, summary, lead_citizenid, created_by) VALUES (?, ?, ?, ?)'" in block
    assert "{ caseTitle, summary, actor.citizenid, actor.citizenid }" in block
    assert "('%s 因 %s 被捕（%d 分钟），主办警员 %s。')" in block
    assert "target, table.concat(sum.labels, '、'), minutes, actor.citizenid" in block
    assert "auditPlayer(actor.citizenid, 'case.create', created.caseNo, created.caseTitle)" in block


def test_create_citation_defaults_true_but_accepts_false():
    block = arrest_block()
    assert "local createCitation = params.create_citation ~= false" in block
    assert "if createCitation then" in block


def test_success_shape_matches_the_phone_contract():
    block = arrest_block()
    for field in (
        "ok = true, report_id = reportId, minutes = minutes",
        "fine = fine, jailed = true, subject_citizenid = target",
        "result.citation_id",
        "result.evidence_id",
        "result.case_id",
    ):
        assert field in block


def test_get_charges_exports_the_catalog_for_the_mdt():
    src = read(POLICE / "server/p2_system.lua")
    assert "exports('GetCharges'" in src
    assert "PoliceCharges.List()" in src
    assert "minutes = charge.baseMinutes" in src
    assert "return { charges = charges }" in src


# ---------------------------------------------------------------------------
# Read side
# ---------------------------------------------------------------------------

def test_get_arrests_reads_the_report_table_with_the_subject_mapping():
    block = get_arrests_block()
    assert "SELECT id, subject_citizenid AS citizenid, charges, officer_citizenid, created_at" in block
    assert "FROM police_reports" in block
    assert "WHERE kind = 'arrest'" in block
    assert "subject_citizenid = ?" in block
    assert "ORDER BY id DESC LIMIT 50" in block
    assert "FROM police_arrests" not in block, "GetArrests must not read the retired table"
    assert "audit(actor.citizenid, 'arrest.view'" in block


def test_case_detail_arrests_union_new_reports_with_legacy_rows():
    block = case_detail_block()
    assert "FROM police_reports WHERE kind = 'arrest' AND case_id = ?" in block
    assert "UNION" in block
    assert "FROM police_arrests WHERE case_id = ?" in block
    assert "{ id, id }" in block
    assert "ORDER BY id DESC LIMIT 50" in block


# ---------------------------------------------------------------------------
# UTF-8 truncation
# ---------------------------------------------------------------------------

def test_utf8_shim_is_defined_before_it_is_used():
    src = read(POLICE / "server/p2_system.lua")
    assert "local function utf8Sub(s, limit)" in src
    assert "utf8.offset" in src
    assert src.index("local function utf8Sub(s, limit)") < src.index("local function audit(")
    assert "pcall(utf8.offset, s, limit + 1)" in src


def test_utf8_sub_replaces_byte_slicing_for_user_text():
    block = arrest_block()
    for call in (
        "utf8Sub(trim(params.details), 1000)",
        "utf8Sub(trim(params.bolo_target), 50)",
        "utf8Sub(trim(params.location), 120)",
        "utf8Sub(trim(params.evidence_label), 120)",
        "utf8Sub(table.concat(sum.labels, '、'), 240)",
        "utf8Sub(('逮捕 — %s'):format(table.concat(sum.labels, '、')), 160)",
    ):
        assert call in block, call

    for legacy in (
        "trim(params.details):sub(",
        "trim(params.bolo_target):sub(",
        "trim(params.location):sub(",
        "trim(params.evidence_label):sub(",
        "table.concat(sum.labels, '、'):sub(",
    ):
        assert legacy not in block, legacy

    p3 = read(POLICE / "server/p3_cases.lua")
    assert "local function utf8Sub(s, limit)" in p3
    for call in (
        "utf8Sub(trim(params and params.title), 160)",
        "utf8Sub(trim(params and params.summary), 2000)",
        "utf8Sub(trim(params and params.target), 50)",
        "utf8Sub(trim(params and params.reason), 500)",
        "utf8Sub(trim(params and params.charges), 1000)",
    ):
        assert call in p3, call


def test_no_database_transaction_is_promised_while_backend_lacks_one():
    p2 = read(POLICE / "server/p2_system.lua")
    backend = read(BASE / "resources" / "[standalone]" / "oxmysql" / "dist" / "build.js")

    # The bundled backend is what decides whether MySQL.transaction can work.
    assert "exports('transaction'" not in backend
    assert not re.search(r"MySQL\.transaction\.await\s*\(", p2)
    assert "No database transaction is used here on purpose" in p2
    assert "compensating rollback" in p2
    assert "NO `transaction` export" in p2


# ---------------------------------------------------------------------------
# Legacy /jail
# ---------------------------------------------------------------------------

def test_legacy_jail_requires_arrest_capability_rejects_bad_time_and_audits():
    src = read(POLICE / "server/interactions.lua")
    start = src.index("RegisterNetEvent('police:server:JailPlayer'")
    block = src[start:src.index("RegisterNetEvent('police:server:SeizeCash'", start)]

    assert "PolicePolicy.Can(Player.PlayerData, 'arrest.create')" in block
    assert "local jailTime = tonumber(time)" in block
    assert "if not jailTime or jailTime <= 0 then return end" in block
    assert "if jailTime < 1 then return end" in block
    assert "if jailTime < 1 then jailTime = 1 end" not in block
    assert "if jailTime > 120 then jailTime = 120 end" in block

    # Audited, and the audit is written before the sentence is applied.
    assert "audit(Player.PlayerData.citizenid, 'arrest.register'" in block
    assert "legacy /jail" in block
    assert block.index("audit(Player.PlayerData.citizenid, 'arrest.register'") < block.index(
        "SetMetaData('injail', jailTime)"
    )

    assert "SetMetaData('injail', jailTime)" in block
    assert "police:client:SendToJail" in block
    assert "time = jailTime" in block
