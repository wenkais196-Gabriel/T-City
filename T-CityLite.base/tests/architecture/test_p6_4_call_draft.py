"""P6-4 AI 调度员：文本报案 → call 卡**草稿**。

核心语义：草稿上板可见，但不响铃、不派单、不派 NPC；采纳是人做的。
实现上复用 police_incidents 表，加一个 status='draft'（迁移 v3.13），
所以「不出现在在勤看板」是**由既有查询的 status 白名单天然保证**的。
"""

from __future__ import annotations

import json
import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
P0 = REPO / "T-CityLite.base/resources/[custom]/custom-police/server/p0.lua"
INC = REPO / "T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua"
POLICY = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/policy.lua"
MAIN = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/main.lua"
REG = REPO / "tools/agent_tools.json"
MIG = REPO / "T-CityLite.base/migrations/v3.13_police_incident_draft.sql"


def test_draft_is_a_state_with_two_exits_only() -> None:
    src = P0.read_text(encoding="utf-8")
    at = src.index("local INCIDENT_STATUS = {")
    block = src[at:src.index("local INCIDENT_DISPOSITIONS")]
    assert "draft = true" in block
    assert "draft = { open = true, closed = true }" in block, "草稿只能采纳或丢弃"
    assert "draft" not in block.split("draft = { open = true, closed = true }")[1].split("open = {")[0]


def test_draft_writer_reuses_the_single_row_writer_and_audits_fail_closed() -> None:
    src = INC.read_text(encoding="utf-8")
    at = src.index("function P.DraftCallSystem")
    block = src[at:at + 900]
    assert "insertIncidentRow" in block, "必须走唯一写者"
    assert "status = 'draft'" in block
    assert "audit_unavailable" in block
    assert "broadcastIncidentAlert" not in block, "草稿绝不能广播"


def test_migration_is_additive_and_idempotent() -> None:
    sql = MIG.read_text(encoding="utf-8")
    assert "ENUM(''draft'',''open''" in sql
    assert "information_schema.COLUMNS" in sql
    assert "PREPARE stmt" in sql


def test_policy_l2_and_all_four_touch_points() -> None:
    src = POLICY.read_text(encoding="utf-8")
    at = src.index("police_call_draft = {")
    assert "risk = 'L2'" in src[at:at + 160]
    assert "requires_approval = true" in src[at:at + 160]
    for marker in ("AgentPolicy.ACTIONS", "AgentPolicy.Normalize(", "AgentPolicy.Preview(", "AgentPolicy.CheckPolicy("):
        assert marker in src
    assert src.count("'police_call_draft'") >= 3


def test_unknown_codes_fall_back_and_priority_is_clamped() -> None:
    src = POLICY.read_text(encoding="utf-8")
    at = src.index("if actionType == 'police_call_draft' then")
    block = src[at:at + 1500]
    assert "AgentPolicy.KNOWN_CODES" in block
    assert "code = '911'" in block
    assert "if priority > 3 then priority = 3 end" in block
    assert "if priority < 1 then priority = 1 end" in block


def test_executor_and_registry() -> None:
    main_src = MAIN.read_text(encoding="utf-8")
    assert "executePoliceCallDraft" in main_src
    assert "DraftCallSystem" in main_src
    assert "police_call_draft = executePoliceCallDraft" in main_src

    d = json.loads(REG.read_text(encoding="utf-8"))
    tool = next(t for t in d["tools"] if t["director_action"] == "police_call_draft")
    assert tool["name"] == "apply_police_call_draft"
    assert tool["risk"] == "L2" and tool["requires_approval"] is True


def test_draft_has_no_target_player_but_is_not_world_blast() -> None:
    src = POLICY.read_text(encoding="utf-8")
    world = src[src.index("AgentPolicy.WORLD_ACTIONS = {"):src.index("AgentPolicy.KNOWN_CODES = {")]
    assert "police_call_draft = true" in world, "文本报案没有目标玩家，要跳过在线闸门"
    definition = src[src.index("police_call_draft = {"):][:160]
    assert "blast_radius = 'single'" in definition, "但爆炸半径仍是一条单，不是全服广播"
