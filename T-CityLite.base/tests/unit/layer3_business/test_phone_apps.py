"""Static contract for the server-authoritative phone app registry."""
import shutil
from p0_sources import p0_files, p0_text
import subprocess
import tempfile
from pathlib import Path

import pytest

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
    # Visible off duty so a 10-7 officer can open the MDT and go 10-8 again;
    # per-query police policy still enforces onduty.
    assert "audience = { jobs = { 'police' } }" in src
    assert "audience = { jobs = { 'police' }, onduty = true }" not in src
    assert "queries = {" in src and "officers" in src
    assert "actions = {" in src and "alert" in src


def test_manifest_loads_registry_before_main():
    manifest = read(PHONE / "fxmanifest.lua")
    assert manifest.index("server/phone_apps.lua") < manifest.index("server/main.lua")
    assert manifest.index("server/apps/police_mdt.lua") < manifest.index("server/main.lua")


def test_client_exposes_app_bridges():
    src = read(PHONE / "client/main.lua")
    assert "RegisterNUICallback('getPhoneApps'" in src
    # appQuery/appAction moved through the shared client-core wrapper.
    for callback in ("appQuery", "appAction"):
        assert f"PhoneBridge.RegisterNui('{callback}'" in src


def test_nui_has_dynamic_renderer():
    app = read(PHONE / "web/src/App.svelte")
    assert "DynamicApp" in app
    assert "dyn:" in app
    assert "loadDynamicApps" in app
    assert "appQuery" in read(PHONE / "web/src/core/request.ts")
    main = read(PHONE / "server/main.lua")
    assert "phone:server:appQuery" in main
    assert "phone:server:appAction" in main


def test_police_mdt_has_dedicated_pages():
    page = PHONE / "web/src/apps/PoliceMDT.svelte"
    assert page.exists()
    src = page.read_text(encoding="utf-8")
    for name in ("units", "incidents", "citizen", "vehicle", "set_status", "assign", "clear"):
        assert f"'{name}'" in src or f'"{name}"' in src
    assert "PoliceMDT" in read(PHONE / "web/src/core/appRegistry.ts")


def test_police_mdt_has_exactly_five_pages():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "type Page = 'dispatch' | 'person' | 'report' | 'case' | 'me'" in ui
    for page, label in (
        ("dispatch", "调度"),
        ("person", "人车"),
        ("report", "文书"),
        ("case", "案件"),
        ("me", "我的"),
    ):
        assert f"['{page}', '{label}']" in ui, page
    # the old 13-tab nav must be gone
    for legacy in (
        "['home','首页']", "['units','单位']", "['incidents','接警']",
        "['citizen','人员']", "['vehicle','车辆']", "['citations','罚单']",
        "['reports','报告']", "['cases','案件']", "['bolos','BOLO']",
        "['warrants','搜查令']", "['arrests','逮捕']", "['audit','审计']",
    ):
        assert legacy not in ui, legacy


def test_police_mdt_pages_expose_subsegments():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    for token in (
        "dispatchSeg", "personSeg", "reportSeg", "caseSeg",
        "openDispatchSeg", "openPersonSeg", "openReportSeg", "openCaseSeg",
        "dispatchSeg === 'units'", "dispatchSeg === 'incidents'",
        "personSeg === 'citizen'", "personSeg === 'vehicle'",
        "reportSeg === 'arrest'", "reportSeg === 'report'",
        "reportSeg === 'citation'", "reportSeg === 'evidence'",
        "caseSeg === 'cases'", "caseSeg === 'bolos'", "caseSeg === 'warrants'",
    ):
        assert token in ui, token


def test_police_mdt_lazy_loads_each_subsegment_once():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    for key in (
        "dispatch", "report:arrest", "report:submit", "report:citation",
        "report:evidence", "case:list", "case:bolos", "case:warrants",
        "me", "audit",
    ):
        assert f"'{key}'" in ui, key
    # one-shot guard: previously loaded keys are never re-queried
    assert "if (loaded[key] || inflight.has(key)) return;" in ui


def test_police_capabilities_are_centralised():
    policy = read(PHONE.parent / "custom-police/shared/policy.lua")
    assert "PolicePolicy.Can" in policy
    assert "incident.assign" in policy and "minGrade = 2" in policy
    p0 = p0_text()
    assert "PolicePolicy.Can" in p0
    assert "audit_unavailable" in p0


def test_mdt_exposes_lifecycle_and_audit():
    app = read(PHONE / "server/apps/police_mdt.lua")
    for action in ("enroute", "on_scene", "clear", "audit"):
        assert action in app
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "loadAudit" in ui and "on_scene" in ui


def test_police_mdt_dispatch_shows_incident_disposition():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "disposition?: string | null" in ui
    assert "const dispositionLabel" in ui
    assert "incident.disposition" in ui
    # The clear action names its disposition; the server also defaults it.
    assert "disposition: 'cleared'" in ui


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
    for name in ("requestWarrant", "decideWarrant", "submitArrest", "loadWarrants", "arrest_submit"):
        assert name in ui
    app = read(PHONE / "server/apps/police_mdt.lua")
    for name in ("request_warrant", "decide_warrant", "arrest_submit"):
        assert name in app


def test_notifications_can_deeplink_into_mdt():
    notify = read(PHONE / "server/core/notify.lua")
    assert "phone_notifications (citizenid, title, content, app_id)" in notify
    assert "app_id = appId" in notify
    p0 = p0_text()
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
    # 审计只走唯一写者（server/audit.lua）；agent 路径用 WriteAgent 标 actor_kind='agent'
    assert "PoliceAudit.WriteAgent" in sys and "'agent'" in sys
    justice = (PHONE.parent / "custom-justice/server/main.lua").read_text(encoding="utf-8")
    assert "exports('Imprison'" in justice


def test_insert_ids_are_normalized():
    shared = read(PHONE.parent / "custom-police/shared/insert_id.lua")
    assert "function InsertId" in shared and "insertId" in shared
    # p2_system 不再自己建单（走 p0 的唯一写者，归一化也在那里做），所以它不在这份名单里。
    # p1 的报告写入已委派给 records.lua，不再自己拿 InsertId
    # p0 拆成五个模块后，InsertId 归一化落在 p0_incidents.lua 的写入点里
    assert any("InsertId(" in src for src in p0_files().values()), "p0 家族必须经 InsertId 归一化"
    for f in ("p2_evidence.lua", "p3_cases.lua"):
        src = read(PHONE.parent / "custom-police/server" / f)
        assert "InsertId(" in src, f
    sys_src = read(PHONE.parent / "custom-police/server/p2_system.lua")
    assert "PoliceIncidents.InsertRow(" in sys_src, "p2 必须委派给 police_incidents 的唯一写者"


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
    # The structured wrapper forwards both success and { ok=false, error }
    # tables; PhoneApps.Action turns the failure into success=false/error.
    assert "structured('arrest_submit'" in app
    assert "return structured(" in app


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
    assert "['arrests','逮捕']" not in ui
    # arrest submission now lives under Report → 逮捕
    assert "openReportSeg('arrest')" in ui
    assert "onclick={submitArrest}" in ui


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
    assert "structured('report_submit'" in app
    assert "return structured(" in app


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


def test_legacy_evidence_and_bolo_tabs_are_folded_into_report_and_case():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "openReportSeg('evidence')" in ui
    assert "openCaseSeg('bolos')" in ui
    assert "registerEvidence" in ui and "createBolo" in ui
    assert "['evidence','证据']" not in ui
    assert "['bolos','BOLO']" not in ui


def test_mdt_me_query_exposes_identity_and_grade():
    app = read(PHONE / "server/apps/police_mdt.lua")
    assert "me = function(source)" in app
    # resolved lazily through the shared helper, never a top-level QBCore upvalue
    assert app.index("local function core()") < app.index("PhoneApps.Register")
    assert "local QBCore" not in app
    assert "qb.Functions.GetPlayer(source)" in app
    assert "citizenid = data.citizenid" in app
    assert "callsign = tostring(metadata.callsign or '')" in app
    assert "grade = grade" in app
    assert "tonumber(job.grade.level)" in app
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "queryApp(DB, 'me'" in ui
    assert "meInfo" in ui


def test_mdt_audit_section_requires_lieutenant_grade():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "const isLieutenant = $derived(Number(meInfo?.grade ?? 0) >= 3)" in ui
    me_block = ui[ui.index("page === 'me'"):]
    assert "{#if isLieutenant}" in me_block
    assert "loadAudit" in me_block and "auditRows" in me_block
    # audit is no longer a top-level tab
    assert "['audit'" not in ui
    assert "page === 'audit'" not in ui


def test_built_bundle_ships_the_report_flow():
    bundle = "\n".join(
        p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted((PHONE / "html/assets").glob("*.js"))
    )
    for token in ("report_submit", "evidence_label", "bolo_kind"):
        assert token in bundle, token


def test_built_bundle_ships_the_five_page_mdt():
    bundle = "\n".join(
        p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted((PHONE / "html/assets").glob("*.js"))
    )
    for token in (
        "调度", "人车", "文书", "案件", "我的",
        "10-8 在勤", "10-6 忙碌", "10-7 下班",
        "审计", "搜查令", "BOLO", "一次逮捕提交",
    ):
        assert token in bundle, token


def test_case_detail_renders_justice_verdict():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "{#if caseDetail}" in ui
    detail = ui[ui.index("{#if caseDetail}"):ui.index("{:else if caseSeg === 'bolos'}")]
    for token in ("justice_case_id", "justice_status", "justice_verdict", "verdictText"):
        assert token in detail, token
    # verdict JSON is decoded to finalMinutes / fine / mode (trial vs plea) ...
    for token in ("finalMinutes", "fine", "'trial'", "'plea'", "庭审", "认罪协商"):
        assert token in ui, token
    # ... and a malformed payload falls back to the raw string instead of hiding it.
    assert "catch { return text; }" in ui
    reports = detail[detail.index("{#each caseDetail.reports"):detail.index("{#each caseDetail.evidence")]
    assert "verdictText(r.justice_verdict)" in reports
    arrests = detail[detail.index("{#each caseDetail.arrests"):]
    assert "verdictText(a.justice_verdict)" in arrests
    assert "String(r.justice_case_id)" in reports and "String(a.justice_case_id)" in arrests


def test_person_lookup_splits_warrant_bolo_and_active_wanted():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    for token in (
        "PERSON_GROUP_KEYS", "personFields", "row.warrants", "row.bolo",
        "row.active_wanted", "describeItem", "wantedStars",
        "通缉/令状", "BOLO", "实时通缉星级",
    ):
        assert token in ui, token
    # wants is excluded from the plain key/value dump and never rendered directly.
    assert "PERSON_GROUP_KEYS = new Set(['wants'" in ui
    assert "String(row.wants" not in ui
    assert "{#if row.wants}" not in ui
    person_start = ui.index("{#if personSeg === 'citizen'}")
    citizen = ui[person_start:ui.index("{:else}", person_start)]
    assert "personFields(row)" in citizen
    assert "asList(row.warrants)" in citizen
    assert "asList(row.bolo)" in citizen
    assert "Number(row.active_wanted ?? 0) > 0" in citizen


def test_report_and_citation_templates_fill_forms():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    for token in (
        "REPORT_TEMPLATES", "CITATION_TEMPLATES",
        "交通拦截", "盗窃", "暴力事件", "尾声报告",
        "超速", "闯红灯", "非法停车", "扰乱秩序",
        "applyReportTemplate", "applyArrestTemplate", "applyCitationTemplate",
        "套用报告模板…", "套用逮捕报告模板…", "套用罚单模板…",
    ):
        assert token in ui, token
    # templates only prefill editable local state; submit still posts to the server.
    assert "if (!reportForm.title.trim()) reportForm.title = template.title;" in ui
    assert "reportForm.body = template.body;" in ui
    assert "arrestForm.details = heading;" in ui
    assert "citationForm.reason = template.reason;" in ui
    assert "onclick={createReport}" in ui and "onclick={submitArrest}" in ui
    assert "onclick={issueCitation}" in ui


def test_built_bundle_ships_justice_wanted_sources_and_templates():
    bundle = "\n".join(
        p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted((PHONE / "html/assets").glob("*.js"))
    )
    for token in (
        "justice_case_id", "justice_verdict", "justice_status",
        "通缉/令状", "实时通缉星级",
        "交通拦截", "尾声报告", "超速", "闯红灯", "非法停车", "扰乱秩序",
    ):
        assert token in bundle, token
    # the retired merged `wants` field is filtered, never dumped into the UI
    assert "row.wants" not in bundle


def test_police_mdt_request_backup_action_forwards_the_server_result():
    app = read(PHONE / "server/apps/police_mdt.lua")
    assert "request_backup = function(source, _params)" in app
    assert "exports['custom-police']:RequestBackup(source)" in app
    assert "structured('request_backup'" in app
    assert "return structured(" in app


def test_dispatch_page_has_request_backup_button_and_localised_errors():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    for token in (
        "request_backup",
        "请求支援",
        "支援已派出（#",
        "backupCooldown",
        "startBackupCooldown",
        "onclick={requestBackup}",
        "disabled={backupBusy || backupCooldown > 0}",
        "cooldown",
        "limit",
        "not_police",
        "60 秒",
    ):
        assert token in ui, token
    # The button lives on the dispatch page, before the units/incidents tabs.
    dispatch = ui[ui.index("{#if page === 'dispatch'}"):ui.index("{:else if page === 'person'}")]
    assert "请求支援" in dispatch
    assert "onclick={requestBackup}" in dispatch
    # Local cooldown is presentation only; the server owns the real 60s window.
    assert "backupCooldown = 60" in ui
    assert "appAction(DB, 'request_backup', {})" in ui


def test_built_bundle_ships_request_backup():
    bundle = "\n".join(
        p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted((PHONE / "html/assets").glob("*.js"))
    )
    for token in ("request_backup", "请求支援", "支援已派出（#", "冷却"):
        assert token in bundle, token


def test_police_mdt_forwards_idempotency_key_untouched():
    app = read(PHONE / "server/apps/police_mdt.lua")
    # Both submits pass the client params straight to the police resource; the
    # registry only unwraps { success, data }.
    assert "arrest_submit = function(source, params)" in app
    assert "report_submit = function(source, params)" in app
    assert "ArrestSubmit(source, params)" in app
    assert "ReportSubmit(source, params)" in app
    assert "idempotency_key" in app

    registry = read(PHONE / "server/phone_apps.lua")
    assert "local handler = app.actions[actionName]" in registry
    assert "pcall(handler, source, type(params) == 'table' and params or {})" in registry


def test_police_mdt_generates_and_resets_idempotency_keys_per_submit():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    # Component state, one key per form.
    assert "let reportIdempotencyKey = $state('')" in ui
    assert "let arrestIdempotencyKey = $state('')" in ui
    assert "crypto.randomUUID?.()" in ui
    assert "${Date.now()}-${Math.random().toString(36).slice(2)}" in ui

    # The key is created before the action call and sent as idempotency_key.
    report_key = ui.index("if (!reportIdempotencyKey) reportIdempotencyKey = newIdempotencyKey()")
    report_action = ui.index("appAction(DB, 'report_submit'", report_key)
    assert report_key < report_action
    assert "idempotency_key: reportIdempotencyKey" in ui
    arrest_key = ui.index("if (!arrestIdempotencyKey) arrestIdempotencyKey = newIdempotencyKey()")
    arrest_action = ui.index("appAction(DB, 'arrest_submit'", arrest_key)
    assert arrest_key < arrest_action
    assert "idempotency_key: arrestIdempotencyKey" in ui

    # Failure keeps the key (the return happens before the reset); success
    # clears it after the server has answered.
    report_fail = ui.index("reportError = reportErrorFor(res?.error)", report_action)
    report_reset = ui.index("reportIdempotencyKey = ''", report_action)
    assert report_fail < report_reset
    arrest_fail = ui.index("if (!res?.success) {", arrest_action)
    arrest_reset = ui.index("arrestIdempotencyKey = ''", arrest_action)
    assert arrest_fail < arrest_reset
    assert "reportResult = res.data ?? {}" in ui
    assert "arrestResult = res.data ?? {}" in ui


def test_built_bundle_ships_idempotent_submits():
    bundle = "\n".join(
        p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted((PHONE / "html/assets").glob("*.js"))
    )
    for token in ("idempotency_key", "randomUUID"):
        assert token in bundle, token


def test_police_mdt_tags_npc_callouts():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    # npc_template is the source of truth; the [NPC] title prefix is the
    # fallback because GetIncidents predates the new column.
    assert "npc_template?: string | null" in ui
    assert "function isNpcIncident" in ui
    assert "incident.npc_template" in ui
    assert "startsWith('[NPC]')" in ui
    assert "function incidentTitle" in ui
    assert "incidentTitle(incident)" in ui
    assert '<span class="tag npc">NPC</span>' in ui
    assert ".tag.npc" in ui
    # The dispatch row still offers the same three actions (no new UI).
    # 三个按钮 → 两个：申领（claim）与清场（clear），到场由引擎自动结算
    assert "claimIncident(incident)" in ui
    assert "updateIncident(incident, 'enroute')" not in ui
    # 「到场」按钮已删除：到场由客户端检测 + 服务端裁定自动结算
    assert "updateIncident(incident, 'on_scene')" not in ui
    assert ">到场<" not in ui
    assert "clearIncident(incident)" in ui


def test_built_bundle_ships_npc_callout_tag():
    bundle = "\n".join(
        p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted((PHONE / "html/assets").glob("*.js"))
    )
    assert "npc_template" in bundle
    assert "NPC" in bundle


# ---------------------------------------------------------------------------
# FIT-04: stable action error codes.
# ---------------------------------------------------------------------------

REGISTRY_LUA = PHONE / "server" / "phone_apps.lua"
POLICE_MDT_LUA = PHONE / "server" / "apps" / "police_mdt.lua"


def run_lua(source: str) -> subprocess.CompletedProcess:
    """Run a throwaway Lua 5.4 chunk; skip when the interpreter is absent."""
    if not shutil.which("lua5.4"):
        pytest.skip("lua5.4 is not installed")
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(source)
        path = f.name
    try:
        return subprocess.run(
            ["lua5.4", path], capture_output=True, text=True, timeout=15
        )
    finally:
        Path(path).unlink(missing_ok=True)


def _lua_path(path: Path) -> str:
    return f"[[{path}]]"


def _fake_core_lua() -> str:
    return f"""
_G.QBCore = {{
  Functions = {{
    GetPlayer = function(source)
      return {{ PlayerData = {{
        source = source, citizenid = 'CID001',
        job = {{ name = 'police', onduty = true, grade = {{ level = 3 }} }},
        charinfo = {{ firstname = 'Jane', lastname = 'Doe' }},
        metadata = {{ callsign = 'A-1' }},
      }} }}
    end,
    GetPlayers = function() return {{ 1 }} end,
  }},
}}
"""


def test_phone_apps_action_flattens_every_handler_shape():
    result = run_lua(
        _fake_core_lua()
        + f"""
assert(loadfile({_lua_path(REGISTRY_LUA)}))()
PhoneApps.Register({{
  id = 'contract', label = 'Contract', icon = 'x',
  audience = {{ jobs = {{ 'police' }} }},
  actions = {{
    -- fail table with code + detail
    fail_table = function() return {{ ok = false, error = 'cooldown', detail = 'wait 60s' }} end,
    -- fail table without an error still gets a stable fallback
    fail_table_no_error = function() return {{ ok = false }} end,
    -- true -> success
    ok_true = function() return true end,
    -- ok table keeps its data
    ok_table = function() return {{ ok = true, data = {{ id = 9 }} }} end,
    -- legacy naked false/nil -> action_rejected
    bare_false = function() return false end,
    bare_nil = function() return nil end,
    -- legacy table without `ok` is still a success
    plain_table = function() return {{ id = 7, case_no = 'CASE-1' }} end,
    -- handler exceptions -> action_failed
    explodes = function() error('boom') end,
  }},
}})

local ok, res, detail = PhoneApps.Action(1, 'contract', 'fail_table', {{}})
assert(ok == false and res == 'cooldown' and detail == 'wait 60s', tostring(res))
ok, res = PhoneApps.Action(1, 'contract', 'fail_table_no_error', {{}})
assert(ok == false and res == 'rejected', tostring(res))
ok, res = PhoneApps.Action(1, 'contract', 'ok_true', {{}})
assert(ok == true and type(res) == 'table', tostring(ok))
ok, res = PhoneApps.Action(1, 'contract', 'ok_table', {{}})
assert(ok == true and res.ok == true and res.data.id == 9, tostring(ok))
ok, res = PhoneApps.Action(1, 'contract', 'bare_false', {{}})
assert(ok == false and res == 'action_rejected', tostring(res))
ok, res = PhoneApps.Action(1, 'contract', 'bare_nil', {{}})
assert(ok == false and res == 'action_rejected', tostring(res))
ok, res = PhoneApps.Action(1, 'contract', 'plain_table', {{}})
assert(ok == true and res.id == 7, tostring(ok))
ok, res = PhoneApps.Action(1, 'contract', 'explodes', {{}})
assert(ok == false and res == 'action_failed', tostring(res))
ok, res = PhoneApps.Action(1, 'contract', 'missing_action', {{}})
assert(ok == false and res == 'action_not_found', tostring(res))
print('ACTION_OK')
"""
    )
    assert result.returncode == 0, result.stderr
    assert "ACTION_OK" in result.stdout


POLICE_ACTIONS = (
    "set_status", "assign", "enroute", "on_scene", "clear",
    "issue_citation", "create_report", "register_evidence",
    "create_case", "create_bolo", "request_warrant", "decide_warrant",
    "register_arrest", "arrest_submit", "report_submit", "request_backup",
)


def _lua_action_list() -> str:
    return ", ".join(f"'{name}'" for name in POLICE_ACTIONS)


def test_police_mdt_actions_return_structured_errors():
    result = run_lua(
        _fake_core_lua()
        + f"""
local police = {{}}
setmetatable(police, {{ __index = function()
  return function() return false, 'not_on_duty' end
end }})
_G.exports = {{
  ['custom-police'] = police,
  ['custom-phone'] = {{ Notify = function() return true end }},
}}
assert(loadfile({_lua_path(REGISTRY_LUA)}))()
assert(loadfile({_lua_path(POLICE_MDT_LUA)}))()
for _, name in ipairs({{ {_lua_action_list()} }}) do
  local ok, err = PhoneApps.Action(1, 'police_mdt', name, {{}})
  assert(ok == false, name .. ' must fail')
  assert(err == 'not_on_duty', name .. ' error=' .. tostring(err))
end
print('STRUCTURED_OK')
"""
    )
    assert result.returncode == 0, result.stderr
    assert "STRUCTURED_OK" in result.stdout


def test_police_mdt_passes_through_specific_error_codes():
    result = run_lua(
        _fake_core_lua()
        + f"""
local police = {{}}
setmetatable(police, {{ __index = function()
  return function() return false, 'not_on_duty' end
end }})
_G.exports = {{
  ['custom-police'] = police,
  ['custom-phone'] = {{ Notify = function() return true end }},
}}
assert(loadfile({_lua_path(REGISTRY_LUA)}))()
assert(loadfile({_lua_path(POLICE_MDT_LUA)}))()

police.SetIncidentStatus = function() return false, 'invalid_transition' end
local ok, err = PhoneApps.Action(1, 'police_mdt', 'enroute', {{}})
assert(not ok and err == 'invalid_transition', tostring(err))

police.ArrestSubmit = function()
  return {{ ok = false, error = 'in_progress', detail = 'already running' }}
end
local detail
ok, err, detail = PhoneApps.Action(1, 'police_mdt', 'arrest_submit', {{}})
assert(not ok and err == 'in_progress' and detail == 'already running',
  tostring(err) .. '/' .. tostring(detail))

police.ReportSubmit = function() return {{ ok = false, error = 'audit_unavailable' }} end
ok, err = PhoneApps.Action(1, 'police_mdt', 'report_submit', {{}})
assert(not ok and err == 'audit_unavailable', tostring(err))

police.RequestBackup = function() return {{ ok = false, error = 'cooldown' }} end
ok, err = PhoneApps.Action(1, 'police_mdt', 'request_backup', {{}})
assert(not ok and err == 'cooldown', tostring(err))
print('PASSTHROUGH_OK')
"""
    )
    assert result.returncode == 0, result.stderr
    assert "PASSTHROUGH_OK" in result.stdout


def test_police_mdt_maps_unknown_capability_and_export_errors():
    result = run_lua(
        _fake_core_lua()
        + f"""
local police = {{}}
setmetatable(police, {{ __index = function()
  return function() return false, 'not_on_duty' end
end }})
_G.exports = {{
  ['custom-police'] = police,
  ['custom-phone'] = {{ Notify = function() return true end }},
}}
assert(loadfile({_lua_path(REGISTRY_LUA)}))()
assert(loadfile({_lua_path(POLICE_MDT_LUA)}))()

police.CreateCase = function() return false, 'unknown_capability' end
local ok, err = PhoneApps.Action(1, 'police_mdt', 'create_case', {{}})
assert(not ok and err == 'forbidden', tostring(err))

police.CreateBolo = function() error('export blew up') end
ok, err = PhoneApps.Action(1, 'police_mdt', 'create_bolo', {{}})
assert(not ok and err == 'export_error', tostring(err))

police.CreateCase = function() return {{ id = 7, case_no = 'CASE-000007' }} end
local res
ok, res = PhoneApps.Action(1, 'police_mdt', 'create_case', {{}})
assert(ok and res.ok == true and res.id == 7, tostring(ok))

police.SetUnitStatusForSource = function() return true end
ok, res = PhoneApps.Action(1, 'police_mdt', 'set_status', {{ status = 'available' }})
assert(ok and res.ok == true, tostring(ok))
print('NORMALISE_OK')
"""
    )
    assert result.returncode == 0, result.stderr
    assert "NORMALISE_OK" in result.stdout


def test_police_mdt_alert_is_structured_and_still_fans_out():
    result = run_lua(
        _fake_core_lua()
        + f"""
local police = {{}}
setmetatable(police, {{ __index = function()
  return function() return false, 'not_on_duty' end
end }})
_G.exports = {{
  ['custom-police'] = police,
  ['custom-phone'] = {{ Notify = function() return true end }},
}}
assert(loadfile({_lua_path(REGISTRY_LUA)}))()
assert(loadfile({_lua_path(POLICE_MDT_LUA)}))()

local ok, res = PhoneApps.Action(1, 'police_mdt', 'alert', {{ message = 'All units respond' }})
assert(ok and res.ok == true and res.sent == 1, tostring(ok) .. '/' .. tostring(res and res.sent))

local err
ok, err = PhoneApps.Action(1, 'police_mdt', 'alert', {{ message = '   ' }})
assert(not ok and err == 'invalid_message', tostring(err))
print('ALERT_OK')
"""
    )
    assert result.returncode == 0, result.stderr
    assert "ALERT_OK" in result.stdout


def test_police_mdt_no_longer_collapses_errors_to_booleans():
    src = read(POLICE_MDT_LUA)
    for name in POLICE_ACTIONS:
        assert f"{name} = function" in src, name
    assert src.count("structured('") == 19
    assert "return ok and res" not in src
    assert "error = 'export_error'" in src
    assert "unknown_capability" in src and "'forbidden'" in src


def test_mdt_localises_the_contract_error_codes():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "const ERROR_TEXT: Record<string, string>" in ui
    assert "function errorText(code: unknown): string" in ui
    # Unknown codes fall back to the raw code, never to a generic "失败".
    assert "ERROR_TEXT[key] ?? (key || '提交失败')" in ui
    for code in (
        "not_police", "not_on_duty", "rank_too_low", "cooldown", "limit",
        "global_limit", "in_progress", "invalid_idempotency_key",
        "invalid_transition", "incident_not_found", "not_assigned",
        "already_jailed", "too_far", "not_handcuffed", "case_forbidden",
        "audit_unavailable", "db_error", "export_error",
    ):
        assert f"{code}:" in ui, code
    # One shared table, not one inline map per action.
    assert ui.count("const reasons: Record<string, string>") == 0


def test_built_bundle_ships_the_error_code_map():
    bundle = "\n".join(
        p.read_text(encoding="utf-8", errors="ignore")
        for p in sorted((PHONE / "html/assets").glob("*.js"))
    )
    for token in (
        "invalid_idempotency_key", "in_progress", "invalid_transition",
        "not_on_duty", "export_error", "cooldown", "global_limit",
        "职级不足", "服务端处理异常", "审计不可用",
    ):
        assert token in bundle, token


def test_error_code_doc_lists_every_action_and_required_code():
    doc = BASE.parent / "docs" / "police" / "ARCHITECTURE_ERRORS.md"
    assert doc.exists(), doc
    text = doc.read_text(encoding="utf-8")
    for name in POLICE_ACTIONS:
        assert f"`{name}`" in text, name
    for code in (
        "not_police", "not_on_duty", "rank_too_low", "cooldown", "limit",
        "global_limit", "in_progress", "invalid_idempotency_key",
        "invalid_transition", "incident_not_found", "not_assigned",
        "already_jailed", "too_far", "not_handcuffed", "case_forbidden",
        "audit_unavailable", "db_error", "export_error",
    ):
        assert f"`{code}`" in text, code
    assert "unknown_capability" in text and "forbidden" in text


# ----------------------------------------------------
# appQuery/appAction request_id protocol
# ----------------------------------------------------
# qb-core keeps one pending callback per name, so the old
# QBCore.Functions.TriggerCallback('phone:server:appQuery') path could not run
# two queries concurrently (PoliceMDT refresh does Promise.all). The NUI
# bridges now use dedicated net events plus a client-generated request_id; the
# legacy QBCore callbacks stay for other callers.
def test_client_app_bridges_use_the_request_id_protocol():
    client = read(PHONE / "client/main.lua")
    bridge = read(PHONE / "client/core/bridge.lua")
    for token in (
        "phone:server:appQueryRequest",
        "phone:client:appQueryResponse",
        "phone:server:appActionRequest",
        "phone:client:appActionResponse",
    ):
        assert token in client or token in bridge, token
    assert "pending" in bridge and "pending[id]" in bridge
    assert "APP_REQUEST_TIMEOUT_MS = 8000" in bridge
    assert "error = 'timeout'" in bridge
    assert "resource_stopped" in bridge


def test_nui_app_query_no_longer_uses_the_single_slot_callback():
    client = read(PHONE / "client/main.lua")
    start = client.index("PhoneBridge.RegisterNui('appQuery'")
    end = client.index("PhoneBridge.RegisterNui('appAction'", start)
    block = client[start:end]
    assert "phone:server:appQueryRequest" in block
    assert "PhoneBridge.Request" in block
    assert "TriggerCallback" not in block
    action = client[client.index("PhoneBridge.RegisterNui('appAction'"):]
    action = action[:action.index("-- [phone-app-readers] end")]
    assert "phone:server:appActionRequest" in action
    assert "PhoneBridge.Request" in action
    assert "TriggerCallback" not in action


def test_server_echoes_request_ids_only_to_the_calling_source():
    server = read(PHONE / "server/main.lua")
    assert "RegisterNetEvent('phone:server:appQueryRequest'" in server
    assert "RegisterNetEvent('phone:server:appActionRequest'" in server
    assert "#requestId >= 3 and #requestId <= 64" in server
    assert "TriggerClientEvent(eventName, src, requestId, response)" in server
    for event in ("appQueryResponse", "appActionResponse"):
        assert f"TriggerClientEvent('phone:client:{event}', -1" not in server
    # Legacy callbacks remain for other callers even though the NUI dropped them.
    assert "CreateCallback('phone:server:appQuery'" in server
    assert "CreateCallback('phone:server:appAction'" in server


def test_nui_app_fetch_outlives_the_client_deadline():
    nui = read(PHONE / "web/src/utils/nui.ts")
    assert "APP_REQUEST_TIMEOUT_MS = 9000" in nui
    assert "eventName === 'appQuery'" in nui and "eventName === 'appAction'" in nui


def test_mdt_translates_protocol_errors():
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    for code in ("timeout", "no_response", "bad_request", "resource_stopped"):
        assert f"{code}:" in ui, code


def test_route_is_drawn_by_the_police_client_not_the_phone_ui():
    """路线不再由 MDT 点击触发：被派到就出现，所以绘制点是 custom-police 客户端。

    手机侧原来那个 mdtNavigate 回调已经没有调用者——同一件事留两份实现就是两个 bug。
    """
    ui = read(PHONE / "web/src/apps/PoliceMDT.svelte")
    assert "fetchNui('mdtNavigate'" not in ui, "MDT 不该自己画路线（服务端会推）"

    phone_client = read(PHONE / "client/main.lua")
    assert "mdtNavigate" not in phone_client, "旧的手机路线回调应删除（死代码）"

    guidance = read(PHONE.parent / "custom-police/client/incident_guidance.lua")
    assert "police:client:routeToIncident" in guidance, "要接收服务端推来的路线"
    assert "SetBlipRoute(" in guidance, "要有路线（不然只是一闪而过的圆点）"
    assert "SetBlipDisplay(blip, 2)" in guidance, "要显示距离"
    assert "RemoveBlip" in guidance, "换目标/到达时必须收掉上一条"
    # 到场检测也在同一个文件里：命中 → nonce → 服务端裁定
    assert "requestArriveNonce" in guidance
    assert "TriggerServerEvent('police:server:arriveIncident'" in guidance


def test_queries_distinguish_not_loaded_from_not_found() -> None:
    """玩家刚进服时服务端还没有这个玩家：那是"还没加载"，不是"查无此人"。

    前端据此重试一次；如果两者共用 player_not_found，界面就只能报错了。
    """
    import pathlib

    phone = pathlib.Path(__file__).resolve().parents[3] / "resources/[custom]/custom-phone"
    server = (phone / "server/phone_apps.lua").read_text(encoding="utf-8")
    assert "return nil, nil, 'player_not_ready'" in server, "服务端必须区分未加载与不存在"
    assert "return nil, nil, 'player_not_found'" not in server.split("local function resolve")[1][:400], (
        "resolve 不能再把未加载报成 player_not_found")

    request = (phone / "web/src/core/request.ts").read_text(encoding="utf-8")
    assert "RETRYABLE = new Set(['player_not_ready'])" in request
    assert "RETRY_DELAY_MS" in request
    assert request.count("sendOnce<T>(") >= 3, "phoneRequest 必须先发一次、失败后再重试一次"

    mdt = (phone / "web/src/apps/PoliceMDT.svelte").read_text(encoding="utf-8")
    assert "player_not_ready: '角色还在加载，稍等一下'" in mdt
