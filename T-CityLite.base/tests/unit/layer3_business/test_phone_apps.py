"""Static contract for the server-authoritative phone app registry."""
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
PHONE = BASE / "resources" / "[custom]" / "custom-phone"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_registry_module_authorises_server_side():
    src = read(PHONE / "server/phone_apps.lua")
    assert "function PhoneApps.Register" in src
    assert "function PhoneApps.ForPlayer" in src
    assert "function PhoneApps.Query" in src
    assert "function PhoneApps.Action" in src
    assert "audienceAllows" in src
    assert "app_forbidden" in src
    assert "function PhoneApps.Query" in src
    assert "function PhoneApps.Action" in src


def test_police_mdt_is_registered_and_gated():
    src = read(PHONE / "server/apps/police_mdt.lua")
    assert "id = 'police_mdt'" in src
    assert "jobs = { 'police' }" in src
    assert "onduty = true" in src
    assert "queries = {" in src and "officers" in src
    assert "actions = {" in src and "alert" in src


def test_manifest_loads_registry_before_main():
    manifest = read(PHONE / "fxmanifest.lua")
    assert manifest.index("server/phone_apps.lua") < manifest.index("server/main.lua")
    assert manifest.index("server/apps/police_mdt.lua") < manifest.index("server/main.lua")


def test_client_exposes_app_bridges():
    src = read(PHONE / "client/main.lua")
    for callback in ("getPhoneApps", "appQuery", "appAction"):
        assert f"RegisterNUICallback('{callback}'" in src


def test_nui_has_dynamic_renderer():
    app = read(PHONE / "web/src/App.svelte")
    assert "DynamicApp" in app
    assert "dyn:" in app
    assert "loadDynamicApps" in app
    assert "appQuery" in read(PHONE / "web/src/stores/apps.ts")
    main = read(PHONE / "server/main.lua")
    assert "phone:server:appQuery" in main
    assert "phone:server:appAction" in main


def test_police_mdt_has_dedicated_pages():
    page = PHONE / "web/src/apps/PoliceMDT.svelte"
    assert page.exists()
    src = page.read_text(encoding="utf-8")
    for name in ("units", "incidents", "citizen", "vehicle", "set_status", "assign", "clear"):
        assert f"'{name}'" in src or f'"{name}"' in src
    assert "PoliceMDT" in read(PHONE / "web/src/App.svelte")


def test_police_capabilities_are_centralised():
    policy = read(PHONE.parent / "custom-police/shared/policy.lua")
    assert "PolicePolicy.Can" in policy
    assert "incident.assign" in policy and "minGrade = 2" in policy
    p0 = read(PHONE.parent / "custom-police/server/p0.lua")
    assert "PolicePolicy.Can" in p0
    assert "audit_unavailable" in p0


def test_mdt_exposes_lifecycle_and_audit():
    app = read(PHONE / "server/apps/police_mdt.lua")
    for action in ("enroute", "on_scene", "clear", "audit"):
        assert action in app
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "loadAudit" in ui and "on_scene" in ui


def test_p1_citations_and_reports():
    policy = read(PHONE.parent / "custom-police/shared/policy.lua")
    assert "citation.issue" in policy and "report.create" in policy
    p1 = read(PHONE.parent / "custom-police/server/p1.lua")
    for export in ("IssueCitation", "GetCitations", "CreateReport", "GetReports"):
        assert f"exports('{export}'" in p1
    app = read(PHONE / "server/apps/police_mdt.lua")
    assert "issue_citation" in app and "create_report" in app
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "issueCitation" in ui and "createReport" in ui


def test_evidence_register_and_chain():
    policy = read(PHONE.parent / "custom-police/shared/policy.lua")
    assert "evidence.register" in policy and "evidence.view" in policy
    ev = read(PHONE.parent / "custom-police/server/p2_evidence.lua")
    for name in ("RegisterEvidence", "GetEvidence", "GetEvidenceChain"):
        assert f"exports('{name}'" in ev
    assert "police_evidence_chain" in ev
    app = read(PHONE / "server/apps/police_mdt.lua")
    assert "register_evidence" in app and "evidence_chain" in app
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "registerEvidence" in ui and "showChain" in ui


def test_citations_can_be_paid_by_owner():
    p1 = read(PHONE.parent / "custom-police/server/p1.lua")
    assert "function P1.PayCitation" in p1
    assert "RemoveMoney('bank'" in p1
    assert "citation.pay" in p1
    phone_server = read(PHONE / "server/main.lua")
    phone_client = read(PHONE / "client/main.lua")
    assert "phone:server:payCitation" in phone_server
    assert "paycitation" in phone_client


def test_p2_cases_bolos_warrants_arrests():
    policy = read(PHONE.parent / "custom-police/shared/policy.lua")
    for cap in ("case.create", "bolo.create", "warrant.request", "warrant.approve", "arrest.create"):
        assert cap in policy
    p3 = read(PHONE.parent / "custom-police/server/p3_cases.lua")
    for export in ("CreateCase", "GetCases", "CreateBolo", "GetBolos", "ClearBolo",
                   "RequestWarrant", "DecideWarrant", "GetWarrants",
                   "RegisterArrest", "GetArrests"):
        assert f"exports('{export}'" in p3
    assert "CASE-%s-%06d" in p3
    app = read(PHONE / "server/apps/police_mdt.lua")
    for name in ("cases", "bolos", "warrants", "arrests", "create_case", "create_bolo"):
        assert name in app
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "createCase" in ui and "createBolo" in ui


def test_verdict_imprisons_on_the_server():
    justice = PHONE.parent / "custom-justice"
    assert "JusticeService.Inmates = inmates" in (justice / "server/main.lua").read_text(encoding="utf-8")
    prison = (justice / "server/prison.lua").read_text(encoding="utf-8")
    assert "function JusticeService.Imprison" in prison
    assert "function JusticeService.Imprison" in prison and "END" not in prison
    trial = (justice / "server/trial.lua").read_text(encoding="utf-8")
    assert "JusticeService.Imprison(case.suspect.citizenid" in trial
    client = (justice / "client/main.lua").read_text(encoding="utf-8")
    verdict_block = client[client.index("justice:client:verdictReceived"):client.index("法院 / 监狱 Blip")]
    assert "TriggerServerEvent('justice:server:imprison'" not in verdict_block
    assert "imprison" not in verdict_block.split("-- Sentence and teleport")[1]


def test_p2_warrant_and_arrest_ui():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    for name in ("requestWarrant", "decideWarrant", "registerArrest", "loadWarrants"):
        assert name in ui
    app = read(PHONE / "server/apps/police_mdt.lua")
    for name in ("request_warrant", "decide_warrant", "register_arrest"):
        assert name in app


def test_notifications_can_deeplink_into_mdt():
    server = read(PHONE / "server/main.lua")
    assert "phone_notifications (citizenid, title, content, app_id)" in server
    assert "app_id = appId" in server
    p0 = read(PHONE.parent / "custom-police/server/p0.lua")
    assert "app_id" in p0 and "police_mdt" in p0
    ui = read(PHONE / "web/src/apps/Notifications.svelte")
    assert "openTarget" in ui and "dyn:" in ui


def test_sentences_use_qb_prison_when_available():
    justice = PHONE.parent / "custom-justice"
    prison = (justice / "server/prison.lua").read_text(encoding="utf-8")
    assert "GetResourceState('qb-prison')" in prison
    assert "prison:client:Enter" in prison
    assert "injail" in prison
    assert "QBCore:Server:PlayerLoaded" in prison
    main = (justice / "server/main.lua").read_text(encoding="utf-8")
    assert "prison:client:UnjailPerson" in main


def test_case_detail_aggregates_linked_records():
    p3 = read(PHONE.parent / "custom-police/server/p3_cases.lua")
    assert "function C.GetCaseDetail" in p3
    assert "exports('GetCaseDetail'" in p3
    assert "police_reports WHERE case_id" in p3
    assert "police_evidence WHERE case_id" in p3
    assert "police_arrests WHERE case_id" in p3
    app = read(PHONE / "server/apps/police_mdt.lua")
    assert "case_detail" in app
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "openCase" in ui and "caseDetail" in ui


def test_agent_system_entry_points_are_audited():
    sys = read(PHONE.parent / "custom-police/server/p2_system.lua")
    for export in ("CreateIncidentSystem", "AssignUnitSystem", "JailSystem"):
        assert f"exports('{export}'" in sys
    assert "actor_kind" in sys and '"agent"' in sys
    assert "police_audit" in sys
    justice = (PHONE.parent / "custom-justice/server/main.lua").read_text(encoding="utf-8")
    assert "exports('Imprison'" in justice


def test_insert_ids_are_normalized():
    shared = read(PHONE.parent / "custom-police/shared/insert_id.lua")
    assert "function InsertId" in shared and "insertId" in shared
    for f in ("p0.lua", "p1.lua", "p2_evidence.lua", "p2_system.lua", "p3_cases.lua"):
        src = read(PHONE.parent / "custom-police/server" / f)
        assert "InsertId(id)" in src, f


def test_mdt_charges_query_reads_the_police_catalogue():
    app = read(PHONE / "server/apps/police_mdt.lua")
    assert "charges = function(_source)" in app
    assert "exports['custom-police']:GetCharges()" in app
    assert "rows = res.charges" in app
    assert "count = #res.charges" in app


def test_mdt_arrest_submit_forwards_the_server_result():
    app = read(PHONE / "server/apps/police_mdt.lua")
    assert "arrest_submit = function(source, params)" in app
    assert "exports['custom-police']:ArrestSubmit(source, params)" in app
    assert "res.ok ~= true" in app
    assert "return res" in app


def test_arrest_page_has_multiselect_slider_and_submit():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    for token in (
        "一次逮捕提交",
        "loadCharges",
        "selectedChargeIds",
        "charge_ids",
        'type="range"',
        "citation_amount",
        "citationAmount",
        "create_citation",
        "create_evidence",
        "evidence_label",
        "bolo_kind",
        "bolo_target",
        "create_case",
        "arrest_submit",
        "onclick={submitArrest}",
        "arrestResult",
    ):
        assert token in ui, token
    assert "arrestForm.incident_id" in ui and "arrestForm.location" in ui


def test_legacy_arrest_registration_form_is_no_longer_rendered():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "onclick={registerArrest}" not in ui
    assert "bind:value={arrestForm.charges}" not in ui
    assert "['arrests','逮捕']" in ui


def test_get_my_citations_callback_returns_rows():
    server = read(PHONE / "server/main.lua")
    assert "phone:server:getMyCitations" in server
    start = server.index("phone:server:getMyCitations")
    end = server.index("phone:server:payCitation", start)
    block = server[start:end]
    assert "pcall" in block
    assert "exports['custom-police']:GetMyCitations(source)" in block
    assert "success = true" in block and "rows = rows" in block
    assert "count = tonumber(res.count) or #rows" in block
    assert "success = false, error = 'unavailable'" in block


def test_client_bridges_the_citation_callbacks():
    client = read(PHONE / "client/main.lua")
    assert "RegisterNUICallback('getMyCitations'" in client
    assert "phone:server:getMyCitations" in client
    assert "RegisterNUICallback('payCitation'" in client
    assert "data.citationId" in client


def test_banking_lists_and_pays_citations():
    ui = read(PHONE / "web/src/apps/Banking.svelte")
    for token in (
        "我的罚单",
        "getMyCitations",
        "payCitation",
        "citationId",
        "citation.status === 'unpaid'",
        "onMount",
        "支付",
    ):
        assert token in ui, token
    assert "fetchNui<any>('payCitation'" in ui
    assert "await loadCitations()" in ui
    assert "citations = Array.isArray(res.rows)" in ui
    # The client never sets status locally: only custom-police may do that.
    assert "status = 'paid'" not in ui


def test_notification_deeplink_supports_banking_app():
    ui = read(PHONE / "web/src/apps/Notifications.svelte")
    assert "notif.app_id === 'banking'" in ui
    assert "activeApp.set('banking')" in ui
    assert "activeApp.set(`dyn:${notif.app_id}`)" in ui
    assert "markNotificationsRead" in ui


def test_built_bundle_ships_the_citation_flow():
    bundle = "\n".join(
        p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted((PHONE / "html/assets").glob("*.js"))
    )
    for token in ("getMyCitations", "payCitation", "我的罚单"):
        assert token in bundle, token


def test_mdt_report_submit_forwards_the_server_result():
    app = read(PHONE / "server/apps/police_mdt.lua")
    assert "report_submit = function(source, params)" in app
    assert "exports['custom-police']:ReportSubmit(source, params)" in app
    assert "if not ok or type(res) ~= 'table' then return false end" in app
    assert "return res" in app


def test_report_page_collects_incident_evidence_and_bolo_fields():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    for token in (
        "report_submit",
        "关联警情",
        "对象 citizenid",
        "案件 id",
        "地点",
        "reportForm.incident_id",
        "evidence_label",
        "evidence_description",
        "bolo_kind",
        "bolo_target",
        "bolo_reason",
        "reportOpts.evidence",
        "reportOpts.bolo",
        'type="checkbox"',
        "createReport",
        "loadBolos",
        "报告 #",
    ):
        assert token in ui, token


def test_report_page_localises_server_rejections():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    for token in (
        "bolo_forbidden",
        "case_not_found",
        "incident_not_found",
        "action_rejected",
        "Sergeant+",
    ):
        assert token in ui, token


def test_legacy_evidence_and_bolo_tabs_stay_available():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "['evidence','证据']" in ui
    assert "['bolos','BOLO']" in ui
    assert "registerEvidence" in ui and "createBolo" in ui


def test_built_bundle_ships_the_report_flow():
    bundle = "\n".join(
        p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted((PHONE / "html/assets").glob("*.js"))
    )
    for token in ("report_submit", "evidence_label", "bolo_kind"):
        assert token in bundle, token
