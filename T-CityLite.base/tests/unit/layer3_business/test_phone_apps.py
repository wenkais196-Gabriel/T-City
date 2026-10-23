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
