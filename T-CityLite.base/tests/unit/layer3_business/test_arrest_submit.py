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


# ---------------------------------------------------------------------------
# P2: citizen citations / fine notifications
# ---------------------------------------------------------------------------

def p1_src() -> str:
    return read(POLICE / "server/p1.lua")


def test_get_my_citations_is_exported_and_reads_only_the_caller_rows():
    src = p1_src()
    assert "exports('GetMyCitations', P1.GetMyCitations)" in src

    start = src.index("function P1.GetMyCitations(")
    block = src[start:src.index("function P1.GetCitations(", start)]
    assert (
        "SELECT id, amount, reason, status, plate, incident_id, created_at "
        "FROM police_citations WHERE citizenid = ? ORDER BY id DESC LIMIT 50"
    ) in block
    # Parameterised on the caller's own citizenid, never on client input.
    assert "{ actor.citizenid }" in block
    assert "params" not in block.split("function P1.GetMyCitations(", 1)[1]
    # A missing player is an empty result, not an error.
    assert "if not actor or not actor.citizenid then return { rows = {}, count = 0 } end" in block
    assert "rows = rows or {}" in block
    assert "return { rows = rows, count = #rows }" in block
    # Citizen side: no police capability gate.
    assert "PolicePolicy.Can" not in block


def test_issue_citation_notification_has_ticket_number_app_id_and_insert_id():
    src = p1_src()
    start = src.index("function P1.IssueCitation(")
    block = src[start:src.index("--- Citizen-side read", start)]
    assert "notifyCitizen(target, '你收到一张罚单'" in block
    assert "('$%d — %s（罚单 #%d，警官 %s）'):format(" in block
    assert "math.floor(amount), text, tonumber(id), actor.citizenid" in block
    assert "'banking'" in block

    # Both the stored row and the live push carry app_id; the push uses the id
    # returned by the insert (normalised through InsertId), not a hardcoded 0.
    notify_start = src.index("local function notifyCitizen(")
    notify = src[notify_start:src.index("function P1.IssueCitation(", notify_start)]
    assert (
        "INSERT INTO phone_notifications (citizenid, title, content, app_id) "
        "VALUES (?, ?, ?, ?)"
    ) in notify
    assert "{ citizenid, title:sub(1, 200), content:sub(1, 500), appId }" in notify
    assert "local notificationId = InsertId(result)" in notify
    assert "id = notificationId" in notify
    assert "app_id = appId" in notify


def test_arrest_submit_notifies_the_subject_about_the_citation_best_effort():
    block = arrest_block()
    assert "created.citationReason = citationReason" in block
    assert "notifyCitation(target, created.citation, amount, created.citationReason, targetSrc)" in block

    # Only after the citation insert, and after the jail-failed rollback point,
    # so a rolled-back arrest never sends a notification.
    citation_insert = block.index("INSERT INTO police_citations")
    jail_failed = block.index("return fail('jail_failed')")
    notify_call = block.index("notifyCitation(target, created.citation")
    assert citation_insert < notify_call
    assert jail_failed < notify_call

    src = read(POLICE / "server/p2_system.lua")
    start = src.index("local function notifyCitation(")
    helper = src[start:src.index("local function encodeCharges(", start)]
    assert (
        "INSERT INTO phone_notifications (citizenid, title, content, app_id) "
        "VALUES (?, ?, ?, ?)"
    ) in helper
    assert "'你收到一张罚单'" in helper
    assert "('你收到一张罚单 #%d，金额 $%d，罪名 %s'):format(" in helper
    assert "citationId" in helper
    assert "'banking'" in helper
    assert "local notificationId = InsertId(result)" in helper
    assert "id = notificationId" in helper
    assert "app_id = 'banking'" in helper
    # Failure is logged, never rolled back.
    assert "pcall(" in helper
    assert "print(" in helper
    assert "rollback()" not in helper


def test_pay_citation_keeps_status_so_get_my_citations_shows_paid():
    src = p1_src()
    assert "exports('PayCitation', P1.PayCitation)" in src
    assert (
        "UPDATE police_citations SET status = 'paid', paid_at = NOW() "
        "WHERE id = ? AND status = 'unpaid'"
    ) in src

    start = src.index("function P1.GetMyCitations(")
    block = src[start:src.index("function P1.GetCitations(", start)]
    # status is part of the projection, so a paid row is observable afterwards.
    assert "status" in block


# ---------------------------------------------------------------------------
# P3: written report + optional evidence + BOLO tag on the report
# ---------------------------------------------------------------------------

def report_submit_block() -> str:
    src = read(POLICE / "server/p2_system.lua")
    start = src.index("function ReportSubmit(")
    end = src.index("\nexports('CreateIncidentSystem'", start)
    return src[start:end]


def get_bolos_block() -> str:
    src = read(POLICE / "server/p3_cases.lua")
    start = src.index("function C.GetBolos(")
    end = src.index("function C.ClearBolo(", start)
    return src[start:end]


def test_report_submit_is_exported_and_gated_by_report_create():
    src = read(POLICE / "server/p2_system.lua")
    block = report_submit_block()
    assert "function ReportSubmit(source, params)" in src
    assert "exports('ReportSubmit', ReportSubmit)" in src
    assert "PolicePolicy.Can(actor, 'report.create')" in block
    assert "if not allowed then return fail(reason or 'forbidden') end" in block
    assert "if type(params) ~= 'table' then return fail('invalid_params') end" in block


def test_report_submit_validates_title_body_and_existing_links():
    block = report_submit_block()
    assert "local title = utf8Sub(trim(params.title), 160)" in block
    assert "if #title < 3 then return fail('invalid_title') end" in block
    assert "local body = utf8Sub(trim(params.body), 4000)" in block
    assert "if #body < 10 then return fail('invalid_body') end" in block

    # Optional subject and context columns, both UTF-8 truncated.
    assert "local subject = trim(params.citizenid)" in block
    assert "subject = utf8Sub(subject, 50)" in block
    assert "utf8Sub(trim(params.location), 120)" in block

    assert "if params.incident_id ~= nil and not incidentId then return fail('invalid_incident') end" in block
    assert "SELECT id FROM police_incidents WHERE id = ? LIMIT 1" in block
    assert "if not incident then return fail('incident_not_found') end" in block

    assert "if params.case_id ~= nil and not caseId then return fail('invalid_case') end" in block
    assert "SELECT id FROM police_cases WHERE id = ? LIMIT 1" in block
    assert "if not caseRow then return fail('case_not_found') end" in block


def test_report_submit_bolo_tag_requires_bolo_create_and_rides_on_the_report():
    block = report_submit_block()
    assert "local bolo = params.bolo == true" in block
    assert "local canBolo = PolicePolicy.Can(actor, 'bolo.create')" in block
    assert "if not canBolo then return fail('bolo_forbidden') end" in block
    assert "if boloKind ~= 'person' and boloKind ~= 'vehicle' then return fail('invalid_bolo_kind') end" in block
    assert "if boloTarget == '' then return fail('invalid_bolo_target') end" in block

    assert "INSERT INTO police_reports" in block
    assert "(kind, incident_id, case_id, subject_citizenid, author_citizenid, title, body," in block
    assert "location, officer_citizenid, is_bolo, bolo_kind, bolo_target)" in block
    assert "VALUES ('report', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)" in block
    assert "bolo and 1 or 0" in block


def test_report_submit_writes_evidence_with_report_link_and_first_chain_entry():
    block = report_submit_block()
    assert "local createEvidence = params.evidence == true" in block
    assert "utf8Sub(trim(params.evidence_label), 120)" in block
    assert "utf8Sub(trim(params.evidence_description), 1000)" in block
    assert "invalid_evidence_label" in block

    assert "INSERT INTO police_evidence" in block
    evidence_insert = block[block.index("INSERT INTO police_evidence"):]
    assert (
        "(exhibit_no, report_id, case_id, incident_id, label, description, location, collected_by)"
        in evidence_insert
    )
    assert "VALUES (NULL, ?, ?, ?, ?, ?, ?, ?)" in evidence_insert
    assert "EX-%06d" in block

    assert "INSERT INTO police_evidence_chain" in block
    assert "'collected'" in block


def test_report_submit_rolls_the_report_back_when_a_child_write_fails():
    block = report_submit_block()
    assert "DELETE FROM police_evidence_chain WHERE evidence_id = ?" in block
    assert "DELETE FROM police_evidence WHERE id = ?" in block
    assert "DELETE FROM police_reports WHERE id = ?" in block
    assert "rollback()" in block
    # The report is inserted before its evidence, so a child failure can delete it.
    assert block.index("INSERT INTO police_reports") < block.index("INSERT INTO police_evidence")


def test_report_submit_audits_report_evidence_and_bolo():
    block = report_submit_block()
    assert "auditPlayer(actor.citizenid, 'report.create', tostring(reportId), title)" in block
    assert "auditPlayer(actor.citizenid, 'evidence.register', exhibitNo, evidenceLabel)" in block
    assert "auditPlayer(actor.citizenid, 'bolo.create', boloTarget, boloKind .. ':' .. boloReason)" in block
    assert "if not auditsOk then" in block
    assert "return fail('audit_unavailable')" in block

    # Success shape stays table-based, like ArrestSubmit.
    assert "return { ok = true, report_id = reportId, evidence_id = evidenceId, bolo = bolo }" in block


def test_report_submit_utf8_truncates_all_user_text():
    block = report_submit_block()
    for call in (
        "utf8Sub(trim(params.title), 160)",
        "utf8Sub(trim(params.body), 4000)",
        "utf8Sub(trim(params.location), 120)",
        "utf8Sub(trim(params.evidence_label), 120)",
        "utf8Sub(trim(params.evidence_description), 1000)",
        "utf8Sub(trim(params.bolo_target), 50)",
        "utf8Sub(trim(params.bolo_reason), 500)",
    ):
        assert call in block, call
    assert "trim(params.title):sub(" not in block
    assert "trim(params.body):sub(" not in block


def test_get_bolos_merges_report_tagged_bolos_with_the_legacy_table():
    block = get_bolos_block()
    assert "PolicePolicy.Can(actor, 'bolo.view')" in block

    # Report-side BOLOs: same read shape as police_bolos, tagged by source.
    assert "bolo_kind AS kind" in block
    assert "bolo_target AS target" in block
    assert "SUBSTRING(title, 1, 160) AS reason" in block
    assert "'report' AS source" in block
    assert "WHERE is_bolo=1 AND kind IN ('report','arrest')" in block
    assert "ORDER BY id DESC LIMIT 50" in block

    # Legacy table is still read and merged in Lua, not dropped.
    assert "FROM police_bolos WHERE status = 'active' ORDER BY id DESC LIMIT 50" in block
    assert "row.source = 'legacy'" in block
    assert "table.sort" in block
    assert "#rows > 50" in block

    assert "return { rows = rows, count = #rows }" in block
    assert "audit(actor.citizenid, 'bolo.view', nil, nil)" in block


# ---------------------------------------------------------------------------
# P4: trial / plea / justice case link / reconnect + autoAlert hardening
# ---------------------------------------------------------------------------

def justice_trial_src() -> str:
    return read(JUSTICE / "server/trial.lua")


def resolve_case_block() -> str:
    src = justice_trial_src()
    start = src.index("function JusticeService.ResolveCase(")
    end = src.index("RegisterNetEvent('justice:server:startTrial'", start)
    return src[start:end]


def start_trial_block() -> str:
    src = justice_trial_src()
    start = src.index("RegisterNetEvent('justice:server:startTrial'")
    end = src.index("QBCore.Commands.Add('trial'", start)
    return src[start:end]


def trial_command_block() -> str:
    src = justice_trial_src()
    start = src.index("QBCore.Commands.Add('trial'")
    end = src.index("QBCore.Commands.Add('plea'", start)
    return src[start:end]


def plea_command_block() -> str:
    src = justice_trial_src()
    start = src.index("QBCore.Commands.Add('plea'")
    end = src.index("QBCore.Commands.Add('cases'", start)
    return src[start:end]


def open_case_block() -> str:
    src = read(JUSTICE / "server/main.lua")
    start = src.index("function JusticeService.OpenCase(")
    end = src.index("function JusticeService.GetInmates(", start)
    return src[start:end]


def imprison_block() -> str:
    src = read(JUSTICE / "server/prison.lua")
    start = src.index("function JusticeService.Imprison(")
    end = src.index("RegisterNetEvent('justice:server:imprison'", start)
    return src[start:end]


def prison_player_loaded_block() -> str:
    src = read(JUSTICE / "server/prison.lua")
    start = src.index("RegisterNetEvent('QBCore:Server:PlayerLoaded'")
    end = src.index("-- 减刑请求", start)
    return src[start:end]


def justice_main_player_loaded_block() -> str:
    src = read(JUSTICE / "server/main.lua")
    start = src.index("AddEventHandler('QBCore:Server:PlayerLoaded'")
    end = src.index("-- 🔧 司法部门管理指令", start)
    return src[start:end]


def auto_alert_block() -> str:
    src = read(POLICE / "server/main.lua")
    start = src.index("RegisterNetEvent('police:server:autoAlert'")
    end = src.index("RegisterNetEvent('police:server:UpdateCurrentCops'", start)
    return src[start:end]


def test_resolve_case_is_the_shared_sentencing_entry_point():
    block = resolve_case_block()
    assert "function JusticeService.ResolveCase(caseId, opts)" in block
    assert "local mode = opts.mode" in block
    assert "if mode ~= 'trial' and mode ~= 'plea'" in block

    # trial: lawyer -30%, first offence -20%, floor 5 minutes (unchanged).
    assert "local hasLawyer = #case.lawyers > 0" in block
    assert "Config.Justice.Reductions.lawyer_defense.rate" in block
    assert "Config.Justice.Reductions.first_offense.rate" in block
    assert "math.max(5, baseMinutes - lawyerReduction - firstOffenseReduction)" in block

    # plea: no lawyer/first-offence discount, exactly 60%.
    assert "finalMinutes = math.max(5, math.floor(baseMinutes * 0.6))" in block

    # The service sentences and closes the case; notifications live in commands.
    assert "JusticeService.SetVerdict(caseId, verdict)" in block
    assert "JusticeService.Imprison(case.suspect.citizenid, finalMinutes, case.crimes)" in block
    assert "case.status = 'closed'" in block
    assert "return verdict" in block
    assert "TriggerClientEvent" not in block

    for field in (
        "caseId = caseId",
        "baseMinutes = baseMinutes",
        "finalMinutes = finalMinutes",
        "fine = baseFine",
        "crimeLabels = crimeLabels",
        "mode = mode",
    ):
        assert field in block, field


def test_trial_command_requires_a_judge_and_keeps_the_existing_notifications():
    block = trial_command_block()
    assert "QBCore.Commands.Add('trial'" in block
    assert "Judge.PlayerData.job.name ~= 'judge'" in block
    assert "mode = 'trial'" in block
    assert "announceTrialVerdict(caseId, verdict, src)" in block

    src = justice_trial_src()
    assert "TriggerClientEvent('justice:client:verdictReceived'" in src
    assert "notify(lawyer.src, 'justice_verdict_lawyer'" in src
    assert "notify(judgeSrc, 'justice_verdict_judge'" in src

    # The legacy net event is only a compatibility wrapper around ResolveCase.
    wrapper = start_trial_block()
    assert "JusticeService.ResolveCase(caseId" in wrapper
    assert "mode = 'trial'" in wrapper
    assert "local baseMinutes = 0" not in wrapper
    assert "lawyerReduction" not in wrapper


def test_plea_command_is_sergeant_plus_and_rejects_when_a_judge_is_online():
    block = plea_command_block()
    assert "QBCore.Commands.Add('plea'" in block
    assert "local grade = tonumber(job and job.grade and job.grade.level) or 0" in block
    assert "job.name ~= 'police'" in block
    assert "grade < 2" in block
    assert "hasOnlineJudge()" in block
    assert "judge_online" in block
    assert "mode = 'plea'" in block
    assert "announcePleaVerdict(caseId, verdict, src)" in block

    # The judge check must gate the sentencing call.
    assert block.index("hasOnlineJudge()") < block.index("JusticeService.ResolveCase")

    src = justice_trial_src()
    start = src.index("local function hasOnlineJudge()")
    end = src.index("--- 法官开庭后的通知", start)
    judge = src[start:end]
    assert "QBCore.Functions.GetPlayers()" in judge
    assert "QBCore.Functions.GetPlayer(players[i])" in judge
    assert "Player.PlayerData.job.name == 'judge'" in judge
    assert "return true" in judge


def test_opencase_export_creates_a_justice_case_for_an_online_suspect():
    block = open_case_block()
    src = read(JUSTICE / "server/main.lua")
    assert "function JusticeService.OpenCase(citizenid, officerSrc, crimes)" in block
    assert "exports('OpenCase'" in src
    assert "OpenCase = JusticeService.OpenCase" in src
    assert "QBCore.Functions.GetPlayerByCitizenId(citizenid)" in block
    assert "Config.Justice.Crimes[crimeId]" in block
    assert "JusticeService.CreateCase(" in block
    assert "return false" in block
    assert "return caseId or false" in block


def test_arrest_submit_open_case_opens_a_justice_case_before_jailing():
    block = arrest_block()
    assert "local openCase = params.open_case == true" in block
    assert "exports['custom-justice']:OpenCase(target, source, ids)" in block
    assert "created.justiceCaseId = tostring(justiceCaseId)" in block
    assert "return fail('open_case_failed')" in block
    assert "result.justice_case_id = created.justiceCaseId" in block
    assert "justice:%s" in block  # audit detail keeps the link

    report = block.index("INSERT INTO police_reports")
    open_call = block.index("exports['custom-justice']:OpenCase(")
    imprison = block.index("custom-justice']:Imprison")
    assert report < open_call < imprison, "open_case must run after the report and before jailing"

    # The write-back is guarded: police_reports.case_id is BIGINT and joins
    # police_cases, while justice ids are strings.
    assert "if created.justiceCaseId and not caseId then" in block
    assert "local numericJusticeId = tonumber(created.justiceCaseId)" in block
    assert "UPDATE police_reports SET case_id = ? WHERE id = ?" in block

    # The justice case is in-memory and cannot be rolled back with the police rows.
    jail_failed = block.index("return fail('jail_failed')")
    assert "custom-justice memory" in block[:jail_failed + 600]
    assert "cannot" in block and "rolled back" in block


def test_imprison_does_not_reset_an_existing_sentence():
    block = imprison_block()
    assert "local metadata = Player.PlayerData.metadata or {}" in block
    assert "if (tonumber(metadata.injail) or 0) > 0 then" in block
    assert "return true" in block

    metadata_check = block.index("(tonumber(metadata.injail) or 0) > 0")
    online_write = block.index(
        "JusticeService.Inmates[citizenid] = {",
        block.index("local src = Player.PlayerData.source"),
    )
    assert metadata_check < online_write, "the dedupe check must run before the sentence is overwritten"


def test_player_loaded_recovery_does_not_double_count_with_qb_prison():
    block = prison_player_loaded_block()
    assert "inmate.qbPrison = GetResourceState('qb-prison') == 'started'" in block
    assert "if GetResourceState('qb-prison') ~= 'started' then" in block
    guard = block.index("GetResourceState('qb-prison') ~= 'started'")
    trigger = block.index("TriggerClientEvent('justice:client:enterPrison'")
    assert guard < trigger
    # qb-prison owns metadata.injail + prison:client:Enter on reconnect.
    assert "Player.Functions.SetMetaData('injail'" not in block
    assert "TriggerClientEvent('prison:client:Enter'" not in block

    main_block = justice_main_player_loaded_block()
    assert "if inmate.offline then return end" in main_block
    assert "if GetResourceState('qb-prison') == 'started' then return end" in main_block
    assert main_block.index("inmate.offline") < main_block.index("TriggerClientEvent")


def test_auto_alert_requires_on_duty_police_and_rate_limits_per_source():
    src = read(POLICE / "server/main.lua")
    block = auto_alert_block()
    assert "local Player = QBCore.Functions.GetPlayer(src)" in block
    assert "if not Player or not PolicePolicy.Can(Player.PlayerData, 'incident.create') then return end" in block
    assert block.index("PolicePolicy.Can") < block.index("GetQBPlayers()")

    assert "local autoAlertCooldown = {}" in src
    assert "local AUTO_ALERT_COOLDOWN = 10" in src
    assert "if last and now - last < AUTO_ALERT_COOLDOWN then return end" in block
    assert "autoAlertCooldown[src] = now" in block

    assert "local function sanitizeAlertCoords(coords)" in src
    assert "local function sanitizeAlertText(text)" in src
    assert "utf8.offset" in src
    assert "math.abs(x) > 10000.0" in src
    assert "local alertCoords = sanitizeAlertCoords(coords)" in block
    assert "local message = sanitizeAlertText(text)" in block
    assert "coords = alertCoords" in block
    assert "description = message" in block
    assert "coords = { x = coords.x" not in block
