"""文书类动作的目标可以离线（逮捕令针对的就是不在场的人）。

实机发现：warrant 目标必须在线，等于「只能给在场的人开逮捕令」——语义反了。
修法不是塞进 WORLD_ACTIONS（那会把 blast_radius 变成 world），而是单独一张
OFFLINE_TARGET_ACTIONS：不要求在线，但仍然要求 citizenid 在 players 表里存在，
且这个存在性要在 propose 阶段就判掉（别把废单塞进审批队列）。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
POLICY = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/policy.lua"
MAIN = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/main.lua"


def test_paperwork_actions_allow_offline_targets() -> None:
    src = POLICY.read_text(encoding="utf-8")
    at = src.index("AgentPolicy.OFFLINE_TARGET_ACTIONS = {")
    block = src[at:at + 200]
    assert "police_warrant_request = true" in block
    assert "police_draft_report = true" in block
    # 不能混进 WORLD_ACTIONS：那样 blast_radius 会变成 world
    world = src[src.index("AgentPolicy.WORLD_ACTIONS = {"):src.index("AgentPolicy.OFFLINE_TARGET_ACTIONS = {")]
    assert "police_warrant_request" not in world


def test_gate_skips_online_requirement_but_keeps_existence() -> None:
    src = POLICY.read_text(encoding="utf-8")
    at = src.index("function AgentPolicy.CheckPolicy(")
    block = src[at:]
    assert "AgentPolicy.OFFLINE_TARGET_ACTIONS[actionType]" in block
    assert "citizen_not_found" in block


def test_propose_looks_the_citizen_up_in_the_database() -> None:
    src = MAIN.read_text(encoding="utf-8")
    at = src.index("local function buildContext(")
    block = src[at:at + 2500]
    assert "OFFLINE_TARGET_ACTIONS" in block
    assert "SELECT citizenid FROM players WHERE citizenid = ?" in block
    assert "context.citizen_exists" in block
