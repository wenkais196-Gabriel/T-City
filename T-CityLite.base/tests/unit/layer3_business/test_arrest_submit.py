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
    assert "version '1.5.0'" in manifest
    assert "version '1.4.0'" not in manifest


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
    assert "SELECT id, subject_citizenid AS citizenid, charges, officer_citizenid" in block
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
    # The transition is a conditional claim: only an unpaid row owned by the
    # caller can be moved to paid.
    assert "SET status = 'paid', paid_at = NOW()" in src
    assert "WHERE id = ? AND citizenid = ? AND status = 'unpaid'" in src

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
    assert "JusticeService.Imprison(case.suspect.citizenid, finalMinutes, case.crimes, {" in block
    assert "replace = true" in block
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


def test_imprison_uses_the_durable_sentence_and_replace_mode():
    block = imprison_block()

    # The DB row is the authority: every imprisonment writes a sentence first.
    assert "JusticeSentences.Apply" in block
    assert "pcall(" in block
    assert "local mode = opts.replace and 'set' or 'add'" in block
    assert "return false, 'sentence_failed'" in block

    # The old metadata-based early return must be gone, otherwise /trial and
    # /plea cannot change an already-running sentence.
    assert "(tonumber(metadata.injail) or 0) > 0 then" not in block
    assert "local metadata = Player.PlayerData.metadata or {}" not in block

    # Offline: write the row, never fake metadata/teleport.
    assert "offline = true" in block
    offline = block.index("if not Player then")
    metadata_write = block.index("Player.Functions.SetMetaData('injail', remaining)")
    assert offline < metadata_write, "offline sentencing must not write metadata"

    # Online: project the authoritative remaining minutes and enter the cell.
    assert "Player.Functions.SetMetaData('injail', remaining)" in block
    assert "TriggerClientEvent('prison:client:Enter', src, remaining)" in block


def test_player_loaded_projects_the_durable_sentence_and_enters_once():
    block = prison_player_loaded_block()
    assert "JusticeSentences.RemainingSeconds" in block
    assert "local remainingMinutes = math.ceil(remainingSeconds / 60)" in block
    assert "Player.Functions.SetMetaData('injail', remainingMinutes)" in block
    assert "if GetResourceState('qb-prison') == 'started' then" in block
    assert "TriggerClientEvent('prison:client:Enter', data.source, remainingMinutes)" in block
    # An offline verdict has no metadata projection yet, so the server enters;
    # a reconnect with metadata>0 is restored by qb-prison itself.
    assert "if not wasInJail then" in block
    assert block.index("if not wasInJail then") < block.index(
        "TriggerClientEvent('prison:client:Enter', data.source, remainingMinutes)")
    # Expired-while-offline is projected to 0 and released, never left as-is.
    assert "if remainingMinutes <= 0 then" in block
    assert "Player.Functions.SetMetaData('injail', 0)" in block

    # prison.lua is the single owner of the login hand-off now.
    main = read(JUSTICE / "server/main.lua")
    assert "AddEventHandler('QBCore:Server:PlayerLoaded'" not in main


def test_auto_alert_requires_on_duty_police_and_rate_limits_per_source():
    src = read(POLICE / "server/main.lua")
    block = auto_alert_block()
    assert "local Player = QBCore.Functions.GetPlayer(src)" in block
    assert "if not Player or not PolicePolicy.Can(Player.PlayerData, 'incident.create') then return end" in block
    assert block.index("PolicePolicy.Can") < block.index("GetQBPlayers()")

    assert "local autoAlertCooldown = {}" in src
    assert "local AUTO_ALERT_COOLDOWN = 10" in src
    assert "if last and now - last < AUTO_ALERT_COOLDOWN then return end" in block
    assert "local isSystem = src == 0" in block
    assert "local cooldownKey = isSystem and 'system' or src" in block
    assert "autoAlertCooldown[cooldownKey] = now" in block

    assert "local function sanitizeAlertCoords(coords)" in src
    assert "local function sanitizeAlertText(text)" in src
    assert "utf8.offset" in src
    assert "math.abs(x) > 10000.0" in src
    assert "local alertCoords = sanitizeAlertCoords(coords)" in block
    assert "local message = sanitizeAlertText(text)" in block
    assert "coords = alertCoords" in block
    assert "description = message" in block
    assert "coords = { x = coords.x" not in block


def test_justice_case_id_is_persisted():
    migration = read(POLICE.parents[2] / "migrations/v3.6_police_justice_case.sql")
    assert "justice_case_id" in migration and "information_schema" in migration
    p2 = read(POLICE / "server/p2_system.lua")
    assert "UPDATE police_reports SET justice_case_id" in p2
    assert "justice_case_id" in p2 and "result.justice_case_id" in p2
    p3 = read(POLICE / "server/p3_cases.lua")
    assert "justice_case_id" in p3
    ui = read(POLICE.parent / "custom-phone/web/src/apps/PoliceMDT.svelte")
    assert "open_case" in ui


# ---------------------------------------------------------------------------
# P6: verdict persistence, legacy /jail retirement, wanted sources
# ---------------------------------------------------------------------------

MIGRATION_V37 = BASE / "migrations" / "v3.7_police_justice_verdict.sql"


def lookup_citizen_block() -> str:
    src = read(POLICE / "server/p0.lua")
    start = src.index("function P.LookupCitizen(")
    end = src.index("function P.LookupVehicle(", start)
    return src[start:end]


def test_v37_migration_adds_verdict_columns_idempotently():
    migration = read(MIGRATION_V37)
    assert "justice_verdict" in migration and "TEXT NULL" in migration
    assert "justice_status" in migration and "VARCHAR(16) NULL" in migration
    assert migration.count("information_schema.COLUMNS") == 2
    assert "PREPARE st1 FROM @s1" in migration
    assert "PREPARE st2 FROM @s2" in migration
    assert "AFTER justice_case_id" in migration


def test_justice_manifest_loads_oxmysql_before_its_scripts():
    manifest = read(JUSTICE / "fxmanifest.lua")
    assert "'@oxmysql/lib/MySQL.lua'" in manifest
    assert manifest.index("'@oxmysql/lib/MySQL.lua'") < manifest.index("'server/main.lua'")


def test_resolve_case_persists_the_verdict_without_blocking_the_sentence():
    src = justice_trial_src()
    block = resolve_case_block()

    assert "local function persistVerdict(caseId, verdict, status)" in src
    assert "pcall(json.encode, verdict)" in src
    assert "UPDATE police_reports SET justice_verdict = ?, justice_status = ? WHERE justice_case_id = ?" in src
    assert "{ encoded, status, tostring(caseId) }" in src
    # A DB/encoding failure only warns; it never aborts the verdict. The await
    # runs in its own thread because command callbacks may not be yieldable.
    helper = src[src.index("local function persistVerdict("):src.index("function JusticeService.ResolveCase(")]
    assert "CreateThread(function()" in helper
    assert "if not wrote then" in helper
    assert "print(" in helper

    assert "persistVerdict(caseId, verdict, case.status)" in block
    set_verdict = block.index("JusticeService.SetVerdict(caseId, verdict)")
    imprison = block.index("JusticeService.Imprison(case.suspect.citizenid, finalMinutes, case.crimes, {")
    persist = block.index("persistVerdict(caseId, verdict, case.status)")
    assert set_verdict < persist, "the verdict must be set before it is written back"
    assert imprison < persist, "a DB failure must not affect the jail sentence"
    assert persist < block.index("return verdict")


def test_case_detail_and_arrests_expose_the_justice_verdict_columns():
    detail = case_detail_block()
    assert "justice_case_id" in detail
    assert "justice_verdict" in detail
    assert "justice_status" in detail
    assert "SELECT id, title, author_citizenid, status, created_at, justice_case_id" in detail
    assert "FROM police_reports WHERE case_id = ?" in detail
    # Both sides of the arrest UNION must expose the same columns.
    assert "NULL AS justice_case_id" in detail
    assert "NULL AS justice_verdict" in detail
    assert "NULL AS justice_status" in detail

    arrests = get_arrests_block()
    assert "justice_case_id" in arrests
    assert "justice_verdict" in arrests
    assert "justice_status" in arrests
    assert "subject_citizenid AS citizenid" in arrests


def test_legacy_jail_command_and_client_handler_are_removed():
    commands = read(POLICE / "server/commands.lua")
    assert "QBCore.Commands.Add('jail'" not in commands
    assert "police:client:JailPlayer" not in commands
    assert "QBCore.Commands.Add('unjail'" in commands

    client = read(POLICE / "client/interactions.lua")
    assert "police:client:JailPlayer" not in client
    assert "police:server:JailPlayer" not in client


def test_server_jail_event_only_accepts_internal_source_zero():
    src = read(POLICE / "server/interactions.lua")
    start = src.index("RegisterNetEvent('police:server:JailPlayer'")
    block = src[start:src.index("RegisterNetEvent('police:server:SeizeCash'", start)]
    assert "if src ~= 0 then return end" in block
    assert "retired" in block and "P6" in block
    guard = block.index("if src ~= 0 then return end")
    assert guard < block.index("local Player = QBCore.Functions.GetPlayer(src)")


def test_lookup_citizen_returns_separate_wanted_sources():
    block = lookup_citizen_block()
    assert "wants = meta.wanted" not in block
    assert "active_wanted = meta.wanted" in block
    assert "warrants = warrants" in block
    assert "bolo = bolo" in block

    assert "SELECT id, reason, status, created_at" in block
    assert "FROM police_warrants" in block
    assert "citizenid = ? AND status IN ('approved','requested')" in block
    assert "SELECT id, kind, target, created_at" in block
    assert "subject_citizenid = ? AND is_bolo = 1" in block
    assert block.count("ORDER BY id DESC LIMIT 5") == 2
    # Both queries are parameterised with the looked-up citizenid.
    assert block.count("{ row.citizenid }") == 2
    # The lookup audit is unchanged.
    assert "audit(actor.citizenid, 'lookup.citizen.result', tostring(row.citizenid), nil)" in block


# ---------------------------------------------------------------------------
# NPC backup ("请求支援"): server authority + client presentation
# ---------------------------------------------------------------------------

BACKUP_CLIENT = POLICE / "client/backup.lua"


def backup_request_block() -> str:
    src = read(POLICE / "server/p2_system.lua")
    start = src.index("function RequestBackup(")
    end = src.index("\nRegisterNetEvent('police:server:backupEnded'", start)
    return src[start:end]


def backup_end_block() -> str:
    src = read(POLICE / "server/p2_system.lua")
    start = src.index("RegisterNetEvent('police:server:backupEnded'")
    end = src.index("\nAddEventHandler('playerDropped'", start)
    return src[start:end]


def backup_drop_block() -> str:
    src = read(POLICE / "server/p2_system.lua")
    start = src.index("AddEventHandler('playerDropped'")
    end = src.index("\n--- Best-effort notification", start)
    return src[start:end]


def test_backup_manifest_ships_client_and_bumps_version():
    manifest = read(POLICE / "fxmanifest.lua")
    assert "client/backup.lua" in manifest
    assert "version '1.5.0'" in manifest
    assert "version '1.4.0'" not in manifest


def test_request_backup_is_exported_gated_and_notifies_only_the_caller():
    src = read(POLICE / "server/p2_system.lua")
    block = backup_request_block()
    assert "exports('RequestBackup', RequestBackup)" in src
    assert "PolicePolicy.Can(actor, 'incident.update')" in block
    assert "return fail('not_police')" in block
    assert "QBCore.Functions.GetPlayer(src)" in block
    assert "TriggerClientEvent('police:client:SpawnBackup', src, requestId)" in block
    assert "return { ok = true, request_id = requestId }" in block
    # The request id is generated server-side, never accepted from the client.
    assert "local requestId = ('BU-%d-%d-%d'):format(src, now, backupSeq)" in block


def test_request_backup_enforces_cooldown_and_two_unit_cap():
    src = read(POLICE / "server/p2_system.lua")
    block = backup_request_block()
    assert "BACKUP_COOLDOWN = 60" in src
    assert "BACKUP_MAX_UNITS = 2" in src
    assert "if now - last < BACKUP_COOLDOWN then return fail('cooldown') end" in block
    assert "if backupUnitCount(cid) >= BACKUP_MAX_UNITS then return fail('limit') end" in block
    # The slot is reserved before the yielding audit insert and rolled back if
    # the audit cannot be written or the player left while it was in flight.
    assert "local units = backupUnits[cid] or {}" in block
    assert "units[requestId] = true" in block
    assert "local function releaseReservation()" in block
    assert "units[requestId] = nil" in block
    assert "backupCooldown[cid] = previousCooldown" in block
    assert "stillThere.PlayerData.citizenid ~= cid" in block


def test_request_backup_audits_with_citizenid_and_unit_id():
    block = backup_request_block()
    assert "auditPlayer(cid, 'backup.request', cid, requestId)" in block
    assert "return fail('audit_unavailable')" in block


def test_backup_does_not_create_player_units_or_sentence_anyone():
    block = backup_request_block()
    assert "INSERT INTO police_units" not in block
    assert "UPDATE police_units" not in block
    assert "police_arrests" not in block
    assert "Jail" not in block


def test_backup_end_decrements_only_the_callers_owned_unit():
    block = backup_end_block()
    assert "local units = backupUnits[cid]" in block
    assert "units[requestId] ~= true then return end" in block
    assert "units[requestId] = nil" in block
    assert "if next(units) == nil then" in block
    assert "backupUnits[cid] = nil" in block
    assert "if backupSource[src] == cid then backupSource[src] = nil end" in block
    # A dropped client releases its pending units so the cap cannot stay locked.
    drop = backup_drop_block()
    assert "local cid = backupSource[src]" in drop
    assert "backupSource[src] = nil" in drop
    assert "backupUnits[cid] = nil" in drop


def test_backup_client_spawns_one_car_and_two_officers():
    src = read(BACKUP_CLIENT)
    assert "RegisterNetEvent('police:client:SpawnBackup'" in src
    assert "BACKUP_VEHICLES = { 'police', 'police2' }" in src
    assert "IsModelInCdimage" in src
    assert "CreateVehicle(vehicleHash" in src
    assert "CreatePedInsideVehicle(vehicle, 4, pedHash, -1, true, true)" in src
    assert "CreatePedInsideVehicle(vehicle, 4, pedHash, 0, true, true)" in src
    assert "if #peds ~= 2 then" in src
    # Never let native cop AI take over the wanted system.
    assert "SetPedAsCop" not in src


def test_backup_client_uses_friendly_group_weapons_and_ai_tasks():
    src = read(BACKUP_CLIENT)
    for token in (
        "SetPedFleeAttributes(ped, 0, false)",
        "SetBlockingOfNonTemporaryEvents(ped, true)",
        "SetPedRelationshipGroupHash(ped, BACKUP_GROUP)",
        "GiveWeaponToPed(ped, PISTOL",
        "SetRelationshipBetweenGroups(0, BACKUP_GROUP, PLAYER_GROUP)",
        "SetRelationshipBetweenGroups(0, PLAYER_GROUP, BACKUP_GROUP)",
        "TaskVehicleDriveToCoord(",
        "TaskGoToEntity(ped, playerPed, -1, FOLLOW_STOP_RADIUS",
        "TaskCombatPed(ped, target, 0, 16)",
        "IsPedInCombat",
        "IsPedAPlayer(ped)",
        "SetBlipColour(blip, 38)",
    ):
        assert token in src, token


def test_backup_client_cleans_up_on_timeout_leave_death_and_restart():
    src = read(BACKUP_CLIENT)
    for token in (
        "ESCORT_TIMEOUT_MS = 30000",
        "UNIT_LIFETIME_MS = 300000",
        "LEAVE_RADIUS = 150.0",
        "LEAVE_GRACE_MS = 30000",
        "TriggerServerEvent('police:server:backupEnded', requestId)",
        "RemoveBlip(state.blip)",
        "DeleteEntity(entity)",
        "DeleteVehicle(state.vehicle)",
        "AddEventHandler('onResourceStop'",
        "if resourceName ~= GetCurrentResourceName() then return end",
    ):
        assert token in src, token
    # Unit handles are only used behind existence checks.
    assert src.count("DoesEntityExist(") >= 8


# ---------------------------------------------------------------------------
# SM-01 duty / unit state machine
# ---------------------------------------------------------------------------

P0 = POLICE / "server/p0.lua"


def p0_src() -> str:
    return read(P0)


def p0_block(start_marker: str, end_marker: str) -> str:
    src = p0_src()
    start = src.index(start_marker)
    end = src.index(end_marker, start)
    return src[start:end]


def test_set_unit_status_for_source_owns_the_onduty_projection():
    block = p0_block("function P.SetUnitStatusForSource(", "\nexports('SetUnitStatus'")
    off_branch = block[block.index("if status == 'off_duty' then"):block.index("if status == 'available' then")]
    available_branch = block[block.index("if status == 'available' then"):block.index("-- busy/assigned/enroute/on_scene")]
    busy_branch = block[block.index("-- busy/assigned/enroute/on_scene"):]

    # 10-7 and 10-8 are the only statuses that touch qb-core's projection.
    assert "pcall(function() player.Functions.SetJobDuty(false) end)" in off_branch
    assert "upsertUnit(data.citizenid, callsign, 'off_duty')" in off_branch
    assert "pcall(function() player.Functions.SetJobDuty(true) end)" in available_branch
    assert "upsertUnit(data.citizenid, callsign, 'available')" in available_branch
    assert "SetJobDuty" not in busy_branch
    assert "if data.job.onduty ~= true then return false, 'not_on_duty' end" in busy_branch
    assert "upsertUnit(data.citizenid, callsign, status)" in busy_branch

    # The 10-8/10-7 client commands use the same source-authoritative entry.
    event = p0_block("RegisterNetEvent('custom-police:server:setStatus'", "RegisterNetEvent('custom-police:server:911'")
    assert "P.SetUnitStatusForSource(source, tostring(status or ''))" in event


def test_set_unit_status_rejects_offline_non_offduty_writes():
    block = p0_block("function P.SetUnitStatus(", "function P.GetUnits(")
    assert "QBCore.Functions.GetPlayerByCitizenId(cid)" in block
    assert "elseif not player then" in block
    assert "return false, 'not_on_duty'" in block
    assert "player.PlayerData.job.onduty ~= true" in block
    assert "pcall(function() player.Functions.SetJobDuty(false) end)" in block
    assert "upsertUnit(cid, callsign, status)" in block


def test_on_job_update_preserves_busy_and_task_states():
    block = p0_block("local function syncDuty(data)", "RegisterNetEvent('QBCore:Server:OnJobUpdate'")
    assert "if not isPolice(data) then" in block
    assert "takeUnitOffDuty(data.citizenid)" in block
    assert "upsertUnit(data.citizenid, callsign, 'off_duty')" in block
    assert "SELECT status FROM police_units WHERE citizenid = ? LIMIT 1" in block
    assert "if not current or current.status == 'off_duty' then" in block

    available_write = block.index("upsertUnit(data.citizenid, callsign, 'available')")
    assert block.index("if not current or current.status == 'off_duty' then") < available_write
    # No code path writes busy/assigned/enroute/on_scene back from a job update.
    for status in ("'busy'", "'assigned'", "'enroute'", "'on_scene'"):
        assert status not in block


def test_player_dropped_releases_unit_and_reopens_orphaned_incident():
    block = p0_block("local function releaseDroppedUnit(citizenid)", "local function onPlayerDropped")
    assert "SELECT incident_id FROM police_units WHERE citizenid = ? LIMIT 1" in block
    assert "takeUnitOffDuty(citizenid)" in block
    assert "SELECT 1 AS ok FROM police_units WHERE incident_id = ? LIMIT 1" in block
    assert "if not other then" in block
    assert "UPDATE police_incidents SET status = 'open'" in block
    assert "status IN ('assigned','enroute','on_scene')" in block
    # qb-core can drop its Player object before the raw event reaches us.
    src = p0_src()
    assert "AddEventHandler('playerDropped'" in src
    assert "AddEventHandler('QBCore:Server:PlayerDropped'" in src


def test_startup_sweep_parks_offline_units_without_deleting_rows():
    block = p0_block("local function sweepOfflineUnits()", "AddEventHandler('onResourceStart'")
    assert "online[data.citizenid] = true" in block
    assert "SELECT citizenid FROM police_units" in block
    assert "not online[cid]" in block
    assert "takeUnitOffDuty(cid)" in block
    assert "audit(cid, 'unit.stale'" in block
    assert "DELETE FROM police_units" not in block

    handler = p0_src()[p0_src().index("AddEventHandler('onResourceStart'"):]
    assert "Wait(10000)" in handler
    assert "sweepOfflineUnits" in handler


def test_grade1_officers_may_only_self_claim_open_or_assigned_incidents():
    block = p0_block("function P.AssignUnit(", "function P.SetIncidentStatus(")
    assert "reason == 'rank_too_low' and grade(actor) < 2 and actor.job.onduty == true" in block
    assert "if target ~= actor.citizenid then return false, 'rank_too_low' end" in block
    assert "if incident.status ~= 'open' and incident.status ~= 'assigned' then return false, 'rank_too_low' end" in block
    assert "INSERT INTO police_incident_units" in block
    assert "assignUnitRow(target, id)" in block
    assert "UPDATE police_incidents SET status = 'assigned'" in block


def test_clearing_an_incident_closes_it_and_releases_only_task_units():
    block = p0_block("function P.SetIncidentStatus(", "local function lookupAllowed")
    assert "local storedStatus = (status == 'cleared') and 'closed' or status" in block
    assert "local closed = (storedStatus == 'closed')" in block
    assert "{ storedStatus, closed and 1 or 0, id }" in block
    assert "releaseIncidentUnits(id)" in block
    assert "return { id = id, status = storedStatus }" in block

    release = p0_block("local function releaseIncidentUnits(", "function P.SetUnitStatus(")
    assert "SET status = 'available', incident_id = NULL" in release
    assert "status IN ('assigned','enroute','on_scene')" in release
    assert "SET incident_id = NULL" in release
    assert "status = 'busy'" in release
    # A manually busy unit is never flipped back to available.
    assert "status = 'available' WHERE incident_id = ? AND status = 'busy'" not in release


def test_unit_writes_are_confined_to_p0_helpers():
    # Task-derived writes and incident clearing go through helpers instead of
    # new direct UPDATEs in AssignUnit/SetIncidentStatus.
    assign = p0_block("function P.AssignUnit(", "function P.SetIncidentStatus(")
    assert "UPDATE police_units" not in assign
    assert "assignUnitRow(target, id)" in assign

    status = p0_block("function P.SetIncidentStatus(", "local function lookupAllowed")
    assert "UPDATE police_units" not in status
    assert "markIncidentUnits(id, status)" in status
    assert "releaseIncidentUnits(id)" in status


# ---------------------------------------------------------------------------
# P7: SM-05 custody — durable sentences, server clock, qb-prison projection
# ---------------------------------------------------------------------------

MIGRATION_V38 = BASE / "migrations" / "v3.8_justice_sentences.sql"
SENTENCE = JUSTICE / "server" / "sentence.lua"
PRISON_SERVER = BASE / "resources" / "[qb]" / "qb-prison" / "server" / "main.lua"


def sentence_src() -> str:
    return read(SENTENCE)


def qb_prison_src() -> str:
    return read(PRISON_SERVER)


def set_jail_status_block() -> str:
    src = qb_prison_src()
    start = src.index("RegisterNetEvent('prison:server:SetJailStatus'")
    end = src.index("RegisterNetEvent('prison:server:SaveJailItems'", start)
    return src[start:end]


def test_v38_migration_creates_the_sentences_table_and_indexes_idempotently():
    sql = read(MIGRATION_V38)

    for column in (
        "id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT",
        "citizenid VARCHAR(50) NOT NULL",
        "case_id VARCHAR(32) NULL",
        "minutes INT UNSIGNED NOT NULL",
        "reason VARCHAR(255) NULL",
        "started_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP",
        "ends_at DATETIME NOT NULL",
        "released_at DATETIME NULL",
        "created_by VARCHAR(50) NULL",
    ):
        assert column in sql, f"justice_sentences missing {column}"

    assert "status ENUM(" in sql
    for status in ("active", "released", "expired"):
        assert status in sql
    assert "DEFAULT " in sql and "active" in sql

    assert "KEY idx_citizen_status (citizenid, status)" in sql
    assert "KEY idx_status_ends (status, ends_at)" in sql

    # Re-running the migration must be a no-op: table and indexes are all
    # guarded through information_schema and prepared dynamic SQL.
    assert "information_schema.TABLES" in sql
    assert sql.count("information_schema.STATISTICS") == 2
    assert "IF(@has_table = 0" in sql
    assert "IF(@has_idx_citizen = 0" in sql
    assert "IF(@has_idx_status = 0" in sql
    prepared = len(re.findall(r"^PREPARE ", sql, re.M))
    assert prepared == 3
    assert prepared == sql.count("DEALLOCATE PREPARE")


def test_sentence_service_is_exported_and_uses_server_clock_set_and_add_modes():
    src = sentence_src()

    for name in ("GetSentence", "RemainingSeconds", "ApplySentence", "ReleaseSentence"):
        assert f"exports('{name}'" in src, f"missing export {name}"

    assert "function JusticeSentences.Get(citizenid)" in src
    assert "function JusticeSentences.RemainingSeconds(citizenid)" in src
    assert "function JusticeSentences.Apply(citizenid, minutes, caseId, reason, mode, createdBy)" in src
    assert "function JusticeSentences.Release(citizenid, reason, status)" in src
    assert "function JusticeSentences.ExpireSweep()" in src

    # Both time values come from MySQL NOW(), never from the client or os.time.
    assert "GREATEST(0, TIMESTAMPDIFF(SECOND, NOW(), ends_at))" in src
    assert "math.ceil(seconds / 60)" in src

    # set = replace remaining time (verdict), add = extend (extra arrest).
    assert "if mode ~= 'set' and mode ~= 'add' then return 0, 'invalid_mode' end" in src
    assert "SET ends_at = DATE_ADD(NOW(), INTERVAL ? MINUTE)" in src
    assert "SET ends_at = DATE_ADD(ends_at, INTERVAL ? MINUTE)" in src
    assert "minutes = minutes + ?" in src
    assert "WHERE citizenid = ? AND status = 'active'" in src

    # Release is a conditional transition, so repeated calls are idempotent.
    assert "SET status = ?, released_at = NOW()" in src
    assert "local function affectedRows(result)" in src
    assert "result.affectedRows" in src
    assert "if affectedRows(affected) == 0 then return false end" in src

    # Every statement is parameterised; no client value is concatenated.
    assert ".. citizenid" not in src
    assert ".. minutes" not in src


def test_imprison_no_longer_blocks_on_injail_and_resolve_case_replaces():
    imprison = imprison_block()
    assert "JusticeSentences.Apply" in imprison
    assert "opts.replace and 'set' or 'add'" in imprison
    assert "(tonumber(metadata.injail) or 0) > 0 then" not in imprison
    assert "return false, 'sentence_failed'" in imprison

    resolve = resolve_case_block()
    assert "JusticeService.Imprison(case.suspect.citizenid, finalMinutes, case.crimes, {" in resolve
    assert "replace = true" in resolve
    assert "caseId = caseId" in resolve


def test_qb_prison_set_jail_status_uses_justice_remaining_and_clamps_fallback():
    block = set_jail_status_block()

    assert "exports['custom-justice']:RemainingSeconds(cid)" in block
    assert "pcall(function()" in block
    # Authoritative branch: client jailTime is discarded, seconds -> ceil min.
    assert "remainingMinutes = math.ceil(remainingSeconds / 60)" in block
    # qb-prison fallback keeps the old shape but is bounded 0..120.
    assert "remainingMinutes = math.max(0, math.min(120, remainingMinutes))" in block
    assert "math.floor(tonumber(jailTime) or 0)" in block
    # A zero/negative remaining sentence clears the projection and stops.
    assert "if remainingMinutes <= 0 then" in block
    assert "Player.Functions.SetMetaData('injail', 0)" in block
    clear = block.index("if remainingMinutes <= 0 then")
    write = block.index("Player.Functions.SetMetaData('injail', remainingMinutes)")
    assert clear < write, "the zero branch must return before the positive write"
    # The client value is never written to metadata.
    assert "SetMetaData('injail', jailTime)" not in qb_prison_src()
    # Job stripping happens after the projection and only for a live sentence.
    assert block.index("Player.Functions.SetMetaData('injail', remainingMinutes)") < block.index(
        "Player.PlayerData.job.name ~= 'unemployed'")


def test_qb_prison_jail_item_events_require_an_active_sentence_and_give_once():
    src = qb_prison_src()
    save = src[src.index("RegisterNetEvent('prison:server:SaveJailItems'"):
               src.index("RegisterNetEvent('prison:server:GiveJailItems'")]
    give = src[src.index("RegisterNetEvent('prison:server:GiveJailItems'"):
               src.index("RegisterNetEvent('prison:server:ResetJailItems'")]
    reset = src[src.index("RegisterNetEvent('prison:server:ResetJailItems'"):
                src.index("RegisterNetEvent('prison:server:SecurityLockdown'")]

    assert "(metadata.injail or 0) <= 0" in save
    assert "(metadata.injail or 0) <= 0" in reset
    # Give is the mirror image: it must only run after the sentence projection
    # was cleared (release), otherwise Give -> Save cycles farm the $80 stipend.
    assert "(metadata.injail or 0) > 0" in give

    # Save/Give cannot be looped to re-earn the $80 stipend: Save only snapshots
    # once per sentence, Reset cannot re-open it, Give consumes it exactly once.
    assert "JailItemsSeized[src] = nil" in set_jail_status_block()
    assert "if JailItemsSeized[src] then return end" in save
    assert "JailItemsSeized[src] = true" in save
    assert "JailItemsSeized[src] = nil" not in reset
    assert "JailItemsRestored[src] = nil" in save
    assert "if not hasSeizedItems then return end" in give
    assert "if JailItemsRestored[src] then return end" in give
    assert give.index("JailItemsRestored[src] = true") < give.index("for _, v in pairs(jailItems)")
    assert "Player.Functions.SetMetaData('jailitems', {})" in give


def test_sentence_sweep_runs_on_start_and_every_fifteen_seconds():
    src = sentence_src()

    startup_start = src.index("AddEventHandler('onResourceStart'")
    loop_start = src.index("\nCreateThread(function()", startup_start)
    startup = src[startup_start:loop_start]
    loop = src[loop_start:]
    assert "pcall(JusticeSentences.ExpireSweep)" in startup
    assert "pcall(JusticeSentences.ExpireSweep)" in loop
    assert "Wait(15000)" in loop

    sweep_start = src.index("function JusticeSentences.ExpireSweep()")
    sweep = src[sweep_start:src.index("-- Startup sweep", sweep_start)]
    assert "UPDATE justice_sentences" in sweep
    assert "SET status = 'expired', released_at = NOW()" in sweep
    assert "WHERE status = 'active' AND ends_at <= NOW()" in sweep
    assert "TriggerClientEvent('prison:client:UnjailPerson'" in sweep
    assert "SetMetaData('injail', 0)" in sweep


def test_justice_manifest_loads_sentence_before_prison_and_release_uses_the_db():
    manifest = read(JUSTICE / "fxmanifest.lua")
    assert "'server/sentence.lua'" in manifest
    assert manifest.index("server/sentence.lua") < manifest.index("server/prison.lua")

    src = read(JUSTICE / "server/main.lua")
    start = src.index("function JusticeService.ReleaseInmate(")
    end = src.index("-- 获取在线职业人数", start)
    block = src[start:end]
    assert "pcall(JusticeSentences.Release" in block
    assert "Player.Functions.SetMetaData('injail', 0)" in block
    assert "TriggerClientEvent('prison:client:UnjailPerson'" in block


# ---------------------------------------------------------------------------
# SM-03: idempotent police write intents (v3.9)
# ---------------------------------------------------------------------------

MIGRATION_V39 = BASE / "migrations" / "v3.9_police_write_intents.sql"


def with_intent_block() -> str:
    src = read(POLICE / "server/p2_system.lua")
    start = src.index("local function withIntent(")
    end = src.index("\nlocal function auditPlayer(", start)
    return src[start:end]


def test_v39_migration_creates_the_write_intent_ledger_idempotently():
    sql = read(MIGRATION_V39)
    assert "police_write_intents" in sql
    assert "idem_key VARCHAR(128) NOT NULL" in sql
    assert "action VARCHAR(32) NOT NULL" in sql
    assert "actor_citizenid VARCHAR(50) NOT NULL" in sql
    assert "status ENUM(''pending'',''done'',''failed'') NOT NULL DEFAULT ''pending''" in sql
    assert "result_json TEXT NULL" in sql
    assert "created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP" in sql
    assert "updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP" in sql
    assert "PRIMARY KEY (idem_key)" in sql
    assert "KEY idx_actor_created (actor_citizenid, created_at)" in sql
    assert "KEY idx_created (created_at)" in sql

    # Re-runnable: the table and both indexes are guarded and prepared once.
    assert sql.count("information_schema.TABLES") == 1
    assert sql.count("information_schema.STATISTICS") == 2
    assert sql.count("CREATE TABLE IF NOT EXISTS") == 1
    assert len(re.findall(r"^PREPARE stmt_", sql, re.M)) == 3
    assert sql.count("DEALLOCATE PREPARE") == 3


def test_with_intent_replays_done_and_releases_pending_and_failed():
    src = read(POLICE / "server/p2_system.lua")
    assert "local INTENT_KEY_MIN = 8" in src
    assert "local INTENT_KEY_MAX = 128" in src
    assert "INTENT_KEY_PATTERN = '^[A-Za-z0-9_%-]+$'" in src
    assert "invalid_idempotency_key" in src

    block = with_intent_block()
    # No key: fully backward compatible, no ledger traffic.
    assert "if key == nil or key == '' then return fn() end" in block
    # Claim first, then cache the committed result as JSON.
    assert "INSERT INTO police_write_intents (idem_key, action, actor_citizenid)" in block
    assert "SET status = 'done', result_json = ?" in block
    assert "json.encode" in block and "json.decode" in src
    # done → replay the cached result.
    assert "elseif existing.status == 'done' then" in block
    assert "local cached = decodeIntentResult(existing)" in block
    assert "return cached" in block
    # pending → a concurrent/duplicate submit is in flight.
    assert "elseif existing.status == 'pending' then" in block
    assert "return fail('in_progress')" in block
    # failed (and every business/exception failure) frees the key.
    assert "deleteIntent(key)" in block
    assert "result.ok ~= true" in block
    assert "if not ok then" in block
    # Lazy sweep before the claim, bounded so it stays cheap.
    sweep = "DELETE FROM police_write_intents WHERE created_at < NOW() - INTERVAL 1 DAY LIMIT 200"
    assert sweep in block
    assert block.index(sweep) < block.index("INSERT INTO police_write_intents")


def test_arrest_submit_claims_an_intent_before_any_write():
    block = arrest_block()
    wrapper = "withIntent('arrest', actor.citizenid, params.idempotency_key, function()"
    assert wrapper in block
    # The claim wraps the target lookup: a replay returns the cached result
    # before the physical checks, so a second submit of an already-jailed
    # suspect is not rejected as already_jailed.
    assert block.index(wrapper) < block.index("QBCore.Functions.GetPlayerByCitizenId(target)")
    assert block.index(wrapper) < block.index("already_jailed")
    assert block.index(wrapper) < block.index("INSERT INTO police_reports")
    assert "params.idempotency_key" in block


def test_report_submit_claims_an_intent_before_any_write():
    block = report_submit_block()
    wrapper = "withIntent('report', actor.citizenid, params.idempotency_key, function()"
    assert wrapper in block
    assert block.index(wrapper) < block.index("INSERT INTO police_reports")
    assert block.index(wrapper) < block.index("INSERT INTO police_evidence")


def test_open_case_requires_case_capability():
    block = arrest_block()
    start = block.index("local openCase = params.open_case == true")
    open_block = block[start:block.index("local bolo = params.bolo", start)]
    assert "PolicePolicy.Can(actor, 'case.create')" in open_block
    assert "return fail('case_forbidden')" in open_block


def test_arrest_audits_citation_and_evidence_children():
    block = arrest_block()
    # The child rows are audited independently, after their inserts.
    assert "created.exhibitNo = exhibitNo" in block
    assert "auditPlayer(actor.citizenid, 'citation.issue', tostring(created.citation)" in block
    assert "('$%d'):format(amount)" in block
    assert "auditPlayer(actor.citizenid, 'evidence.register', created.exhibitNo" in block
    assert block.index("INSERT INTO police_citations") < block.index("citation.issue")
    assert block.index("INSERT INTO police_evidence") < block.index("'evidence.register'")
    # The arrest audit is still written once the sentence is applied.
    assert "auditPlayer(actor.citizenid, 'arrest.register', target, auditDetail)" in block


def test_pay_citation_claims_before_charging_and_rolls_back_on_failure():
    src = p1_src()
    # Bundled oxmysql returns { affectedRows = n }; stock builds return n.
    assert "local function affectedRows(result)" in src
    assert "if type(result) == 'number' then return result end" in src
    assert "tonumber(result.affectedRows)" in src

    start = src.index("function P1.PayCitation(")
    block = src[start:]
    assert "affectedRows(claim) == 0" in block
    # The conditional claim must run before any money moves.
    claim = block.index("SET status = 'paid', paid_at = NOW()")
    remove = block.index("RemoveMoney('bank'")
    assert claim < remove
    assert "WHERE id = ? AND citizenid = ? AND status = 'unpaid'" in block
    # Losing the claim is reported with the reason, never charged.
    for code in ("'not_found'", "'not_owner'", "'already_'"):
        assert code in block
    # A failed RemoveMoney puts the row back so the owner can retry.
    rollback = block.index("SET status = 'unpaid', paid_at = NULL")
    assert remove < rollback
    assert "WHERE id = ? AND status = 'paid'" in block
    assert "return false, 'insufficient_funds'" in block
    # Only the successful payer writes the audit.
    assert "audit(actor.citizenid, 'citation.pay', tostring(id)" in block
