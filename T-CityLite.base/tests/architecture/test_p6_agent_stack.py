"""P6 agent 栈闸门（合并版）。

原来 8 个 `test_p6_*.py` 各自复制一份 REPO/路径/读取样板，Sonar 在 "New Code"
上判了 C（重复块），所以合并成一个文件、共享一份辅助函数。

分组：
  §1 只读通道（live 案卷）
  §2 动作层（写）：起草报告 / 申请逮捕令 / call 卡草稿
  §3 参数与策略接线（policy.lua 四处、Lua pattern、离线目标）
  §4 草稿箱（服务端闭环 + MDT 界面契约）
"""

from __future__ import annotations

import json
import pathlib
import re

REPO = pathlib.Path(__file__).resolve().parents[3]
ROOT = REPO / "T-CityLite.base/resources/[custom]"
POLICE = ROOT / "custom-police/server"
DIRECTOR = ROOT / "custom-director/server"
PHONE = ROOT / "custom-phone"
MIGRATIONS = REPO / "T-CityLite.base/migrations"
REGISTRY = REPO / "tools/agent_tools.json"

LIVE_API = DIRECTOR / "live_api.lua"
POLICY = DIRECTOR / "policy.lua"
DIR_MAIN = DIRECTOR / "main.lua"
INC = POLICE / "p0_incidents.lua"
P0 = POLICE / "p0.lua"
P2_SYSTEM = POLICE / "p2_system.lua"
CASES = POLICE / "p3_cases.lua"
APP = PHONE / "server/apps/police_mdt.lua"
UI = PHONE / "web/src/apps/PoliceMDT.svelte"


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def block(text: str, marker: str, size: int = 1200) -> str:
    """从 marker 起截一段，避免每个用例自己算窗口。"""
    at = text.index(marker)
    return text[at:at + size]


def registry_tool(action: str) -> dict:
    data = json.loads(read(REGISTRY))
    return next(t for t in data["tools"] if t["director_action"] == action)


# ══════════════════════════════════════════════════════════════════
# §1 只读通道：GET /agent/v1/live/police/cases/{id}
# ══════════════════════════════════════════════════════════════════


def test_live_route_exists_and_validates_the_id() -> None:
    src = read(LIVE_API)
    assert "/agent/v1/live/police/cases" in src
    part = block(src, "local function handlePoliceCase", 1600)
    assert "invalid_case" in part, "非数字 id 要 400"
    assert "case_not_found" in part, "不存在的案卷要 404"
    for leak in ("charinfo", "firstname", "lastname", "vector3", "summary"):
        assert leak not in part, f"live 案卷读回里混进了 {leak}"


def test_read_tool_is_declared_as_live_get() -> None:
    data = json.loads(read(REGISTRY))
    tool = next(t for t in data["tools"] if t["name"] == "get_police_case")
    assert tool["channel"] == "read"
    assert tool["director_action"] is None, "读类工具不能绑 director 动作"
    assert tool["http"]["method"] == "GET"
    assert tool["auth"] == "live"
    assert tool["compensation"] == "none"


# ══════════════════════════════════════════════════════════════════
# §2 动作层（写）
# ══════════════════════════════════════════════════════════════════


def test_draft_report_goes_through_the_single_report_writer() -> None:
    part = block(read(P2_SYSTEM), "function Sys.DraftReport", 1200)
    assert "PoliceRecords.InsertReport" in part, "必须走唯一写者，不准自己 INSERT"
    assert "INSERT INTO police_reports" not in part
    assert "status = 'draft'" in part and "kind = 'report'" in part
    for forbidden in ("is_bolo = true", "AddMoney", "police_evidence", "police_warrants"):
        assert forbidden not in part, f"草稿里混进了副作用: {forbidden}"


def test_warrant_system_entry_lives_with_the_single_writer() -> None:
    part = block(read(CASES), "function C.RequestWarrantSystem", 1400)
    assert "INSERT INTO police_warrants" in part, "复用唯一的写者"
    assert "audit(" in part and "'agent'" in part
    assert "audit_unavailable" in part, "审计失败必须让调用方看见"
    for forbidden in ("'approved'", "approved_by", "police_bolos"):
        assert forbidden not in part, f"越权副作用: {forbidden}"


def test_call_draft_writer_is_draft_only_and_never_broadcasts() -> None:
    part = block(read(INC), "function P.DraftCallSystem", 900)
    assert "insertIncidentRow" in part, "必须走唯一写者"
    assert "status = 'draft'" in part
    assert "audit_unavailable" in part
    assert "broadcastIncidentAlert" not in part, "草稿绝不能广播"


def test_actions_are_l2_or_l3_and_approval_bound() -> None:
    src = read(POLICY)
    for action, risk in (
        ("police_draft_report", "L2"),
        ("police_call_draft", "L2"),
        ("police_warrant_request", "L3"),
    ):
        part = block(src, f"{action} = {{", 200)
        assert f"risk = '{risk}'" in part, f"{action} 风险级别错"
        assert "requires_approval = true" in part
        assert "auto_execute = false" in part


def test_executors_delegate_to_police_exports() -> None:
    src = read(DIR_MAIN)
    assert "police_draft_report = executePoliceDraftReport" in src
    assert "DraftReportSystem" in src
    assert "police_warrant_request = executePoliceWarrantRequest" in src
    assert "RequestWarrantSystem" in src
    assert "police_call_draft = executePoliceCallDraft" in src
    assert "DraftCallSystem" in src


def test_write_tools_are_named_inside_the_verb_whitelist() -> None:
    for action, name, risk in (
        ("police_draft_report", "apply_police_report", "L2"),
        ("police_warrant_request", "apply_police_warrant", "L3"),
        ("police_call_draft", "apply_police_call_draft", "L2"),
    ):
        tool = registry_tool(action)
        assert tool["name"] == name
        assert tool["risk"] == risk
        assert tool["requires_approval"] is True
        assert tool["channel"] == "write"


# ══════════════════════════════════════════════════════════════════
# §3 参数与策略接线
# ══════════════════════════════════════════════════════════════════


def test_every_police_action_is_wired_in_all_four_places() -> None:
    src = read(POLICY)
    sections = {}
    starts = {
        "actions": src.index("AgentPolicy.ACTIONS = {"),
        "normalize": src.index("function AgentPolicy.Normalize("),
        "preview": src.index("function AgentPolicy.Preview("),
        "check": src.index("function AgentPolicy.CheckPolicy("),
    }
    order = ["actions", "normalize", "preview", "check"]
    for i, name in enumerate(order):
        end = starts[order[i + 1]] if i + 1 < len(order) else len(src)
        sections[name] = src[starts[name]:end]

    missing = []
    for action in ("police_draft_report", "police_warrant_request", "police_call_draft"):
        if f"{action} = " not in sections["actions"]:
            missing.append(f"{action}@actions")
        for place in ("normalize", "preview", "check"):
            if f"'{action}'" not in sections[place]:
                missing.append(f"{action}@{place}")
    assert not missing, f"动作没接全：{missing}"


def test_no_lua_pattern_uses_regex_quantifiers() -> None:
    src = read(POLICY)
    bad = re.findall(r"match\('\[[^']*\]\{\d+,\d+\}", src)
    assert not bad, f"Lua pattern 里不能写 {{n,m}}：{bad}"


def test_paperwork_actions_allow_offline_targets() -> None:
    src = read(POLICY)
    part = block(src, "AgentPolicy.OFFLINE_TARGET_ACTIONS = {", 200)
    assert "police_warrant_request = true" in part
    assert "police_draft_report = true" in part
    world = src[src.index("AgentPolicy.WORLD_ACTIONS = {"):src.index("AgentPolicy.OFFLINE_TARGET_ACTIONS = {")]
    assert "police_warrant_request" not in world, "别把文书动作塞进 WORLD_ACTIONS"


def test_offline_gate_keeps_the_citizen_existence_check() -> None:
    src = read(POLICY)
    gate = src[src.index("function AgentPolicy.CheckPolicy("):]
    assert "AgentPolicy.OFFLINE_TARGET_ACTIONS[actionType]" in gate
    assert "citizen_not_found" in gate
    ctx = block(read(DIR_MAIN), "local function buildContext(", 2500)
    assert "SELECT citizenid FROM players WHERE citizenid = ?" in ctx


def test_call_draft_has_no_player_but_is_not_world_blast() -> None:
    src = read(POLICY)
    world = src[src.index("AgentPolicy.WORLD_ACTIONS = {"):src.index("AgentPolicy.KNOWN_CODES = {")]
    assert "police_call_draft = true" in world, "文本报案没有目标玩家"
    assert "blast_radius = 'single'" in block(src, "police_call_draft = {", 160)


def test_unknown_codes_fall_back_and_priority_is_clamped() -> None:
    part = block(read(POLICY), "if actionType == 'police_call_draft' then", 2400)
    assert "AgentPolicy.KNOWN_CODES" in part
    assert "code = '911'" in part
    assert "if priority > 3 then priority = 3 end" in part
    assert "if priority < 1 then priority = 1 end" in part


# ══════════════════════════════════════════════════════════════════
# §4 草稿箱
# ══════════════════════════════════════════════════════════════════


def test_draft_is_a_state_with_two_exits_only() -> None:
    src = read(P0)
    part = src[src.index("local INCIDENT_STATUS = {"):src.index("local INCIDENT_DISPOSITIONS")]
    assert "draft = true" in part
    assert "draft = { open = true, closed = true }" in part, "草稿只能采纳或丢弃"


def test_migration_is_additive_and_idempotent() -> None:
    sql = read(MIGRATIONS / "v3.13_police_incident_draft.sql")
    assert "ENUM(''draft'',''open''" in sql
    assert "information_schema.COLUMNS" in sql
    assert "PREPARE stmt" in sql


def test_review_flag_is_derived_without_a_new_column() -> None:
    part = block(read(INC), "function P.DraftCallSystem", 900)
    assert "needs_review" in part and "disposition" in part
    assert "ALTER TABLE" not in part


def test_list_drafts_expires_stale_drafts_and_exposes_review() -> None:
    part = block(read(INC), "function P.ListDrafts", 2200)
    assert "INTERVAL 30 MINUTE" in part, "草稿不能无限期挂着"
    assert "'stale'" in part
    assert "row.review" in part and "age_minutes" in part
    assert "incident.draft.view" in part and "audit_unavailable" in part


def test_adopt_goes_through_the_existing_state_machine() -> None:
    part = block(read(INC), "function P.AdoptDraft", 900)
    assert "P.SetIncidentStatus(source, id, 'open')" in part
    assert "incident.adopt" in part and "audit_unavailable" in part


def test_discard_requires_grade_two_and_audits() -> None:
    part = block(read(INC), "function P.DiscardDraft", 1200)
    assert "grade(actor) < 2" in part and "grade_too_low" in part
    assert "status = 'draft'" in part, "只能丢草稿"
    assert "incident.discard" in part and "audit_unavailable" in part


def test_net_events_are_registered_and_rate_limited() -> None:
    src = read(POLICE / "main.lua")
    assert "RegisterNetEvent('police:server:draftList'" in src
    adopt = block(src, "RegisterNetEvent('police:server:adoptDraft'", 900)
    assert "Cooldown" in adopt, "连点会把整箱草稿一次发出去"
    assert "src == 0" in adopt


def test_phone_app_exposes_drafts_query_and_actions() -> None:
    app = read(APP)
    assert "drafts = function(source)" in app
    assert "adopt_draft" in app and "discard_draft" in app
    assert "AdoptDraft" in app and "DiscardDraft" in app


def test_mdt_ui_has_two_lanes_and_a_discard_confirmation() -> None:
    ui = read(UI)
    assert "📝 草稿箱" in ui
    assert "可采纳" in ui and "需核对" in ui
    assert "confirmDiscard" in ui, "丢弃必须二次确认"
    assert "adopt_draft" in ui and "discard_draft" in ui
    assert "暂无待采纳草稿" in ui


# ══════════════════════════════════════════════════════════════════
# §5 P4 证据收口：盘查读数延迟绑定（AC-P4-07..11）
# ══════════════════════════════════════════════════════════════════

EVIDENCE = POLICE / "p2_evidence.lua"
FIELD = POLICE / "interactions.lua"
MIG14 = MIGRATIONS / "v3.14_police_evidence_subject.sql"


def test_pending_reading_needs_a_subject_but_no_case() -> None:
    """AC-P4-07：有 subject 才允许没有父级；普通采集不能借这条路绕过。"""
    part = block(read(EVIDENCE), "local function insertEvidence", 1400)
    assert "subject_citizenid" in part
    assert "'missing_case'" in part, "没有 subject 时仍然必须带父级"
    assert "subject == ''" in part


def test_bind_is_one_update_plus_an_append_only_chain_row() -> None:
    """AC-P4-08：绑定只改 case_id；保管链只追加，绝不 UPDATE。"""
    src = read(EVIDENCE)
    part = block(src, "function EV.BindEvidence", 1600)
    assert "UPDATE police_evidence SET case_id = ?" in part
    assert "WHERE id = ? AND case_id IS NULL" in part, "已绑定的不能再绑"
    assert "evidence.bind" in part and "audit_unavailable" in part
    assert "UPDATE police_evidence_chain" not in src, "链只能 append"


def test_already_bound_and_subject_mismatch_are_rejected() -> None:
    """AC-P4-09/10：重复绑定与主体不符都要拒；force 需留审计。"""
    part = block(read(EVIDENCE), "function EV.BindEvidence", 1600)
    assert "'already_bound'" in part
    assert "'subject_mismatch'" in part
    assert "force" in part and "evidence.bind_forced" in part


def test_case_creation_auto_binds_pending_readings() -> None:
    """AC-P4-08：立案后自动把该公民的待挂载读数挂上（失败不阻断立案）。"""
    part = block(read(CASES), "function C.CreateCase", 2000)
    assert "BindPendingFor" in part
    assert "pcall" in part, "绑定失败不能挡住立案"
    binder = block(read(EVIDENCE), "function EV.BindPendingFor", 1400)
    assert "subject_citizenid = ? AND case_id IS NULL" in binder
    assert "'auto_bound'" in binder


def test_field_test_writes_a_pending_row_without_an_incident() -> None:
    """AC-P4-07：没有在办警情时也要留证据（此前只写审计）。"""
    part = block(read(FIELD), "police:server:fieldTest", 6000)
    assert "subject_citizenid" in part
    assert "pending = pending" in part
    assert "RegisterEvidence" in part


def test_migration_14_is_additive_and_idempotent() -> None:
    sql = read(MIG14)
    assert "subject_citizenid" in sql
    assert "information_schema.COLUMNS" in sql
    assert "PREPARE stmt" in sql


# ══════════════════════════════════════════════════════════════════
# §6 AI 调度员 MVP（agent 侧解析）+ 指纹/DNA 采样比对
# ══════════════════════════════════════════════════════════════════

MVP = REPO / "tools/agent/dispatch_mvp.py"
FORENSICS = POLICE / "forensics.lua"


def test_mvp_separates_fetching_from_parsing() -> None:
    """脚本只取内容与提交；解析交给 agent（不在脚本里猜）。"""
    src = read(MVP)
    assert "def cmd_fetch" in src and "def cmd_submit" in src
    assert "phone_messages" in src
    assert "police_call_draft" in src
    # 不许在脚本里做"关键词 → 代码"的伪解析
    assert "if '抢' in" not in src and "if \"抢\" in" not in src


def test_mvp_is_idempotent_and_does_not_print_tokens() -> None:
    src = read(MVP)
    assert "idempotency_key" in src
    assert "dispatch_mvp/" in src, "幂等键要按来源 id 生成"
    assert "print(token" not in src and "print(agent" not in src


def test_forensics_collects_fingerprint_and_dna_samples() -> None:
    src = read(FORENSICS)
    assert "fingerprint = " in src and "dna = " in src
    assert "MATCH_KINDS" in src
    assert "snapshotCandidates" in src
    assert "<= 30.0" in src, "候选只认采样时 30 m 内的人"


def test_compare_matches_only_the_scene_candidates() -> None:
    # 比对逻辑在 owner（p2_evidence），入口在 forensics —— 不要在两处各写一遍
    part = block(read(EVIDENCE), "function EV.CompareSample", 1800)
    assert "already_matched" in part
    assert "not_a_sample" in part
    assert "chain(id, 'matched'" in part, "命中要追加保管链"
    assert "return { match = false }" in part, "名单外的人要明确 no_match"

    entry = block(read(FORENSICS), "police:server:compareSample", 1600)
    assert "CompareSample" in entry, "入口必须委托 owner"
    assert "forensic.compare" in entry


# ══════════════════════════════════════════════════════════════════
# §7 日志清理（2026-10-31）
# ══════════════════════════════════════════════════════════════════

CRYPTO = REPO / "T-CityLite.base/resources/[qb]/qb-crypto/server/main.lua"
QUEST_MAIN = ROOT / "custom-quest/server/main.lua"


def test_crypto_normalises_affected_rows_and_avoids_nested_await() -> None:
    """104 行崩溃：本服 update 回表，且回调里再 await 会 nested ref。"""
    src = read(CRYPTO)
    part = block(src, "local history = json.encode", 1200)
    assert "MySQL.update.await" in part
    assert "function(affectedRows)" not in part, "不要再走回调形态"
    assert "affectedRows or updated[1]" in part, "table/number 都要吃"


def test_quest_phone_reads_fail_soft() -> None:
    """手机任务列表是读路径：内部出错不能穿透成 export 异常。"""
    src = read(QUEST_MAIN)
    part = block(src, "local function phoneReadFailSoft", 1500)
    assert "pcall" in part
    assert "phoneReadFailSoft" in part
    detail = block(src, "exports('GetQuestDetail'", 600)
    assert "phoneReadFailSoft" in detail
