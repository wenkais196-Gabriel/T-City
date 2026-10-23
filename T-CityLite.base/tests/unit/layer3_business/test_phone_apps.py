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
