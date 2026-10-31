"""P6-2：agent 起草报告（L2，审批后执行）。

上一轮被两条硬约束挡住，这一版按它们的语义做：
1. 工具名必须在动词白名单里 —— 所以是 `apply_police_report`（不是 draft_*）；
2. `police_reports` 只有一个写者 —— 所以 DraftReport 委托 records.lua 的
   PoliceRecords.InsertReport，自己不再写 INSERT。
"""

from __future__ import annotations

import json
import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
POLICE = REPO / "T-CityLite.base/resources/[custom]/custom-police/server/p2_system.lua"
POLICY = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/policy.lua"
MAIN = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/main.lua"
REGISTRY = REPO / "tools/agent_tools.json"
ACTIONS_DOC = REPO / "T-CityLite.base/docs/agent/ACTIONS.md"


def test_draft_goes_through_the_single_report_writer() -> None:
    src = POLICE.read_text(encoding="utf-8")
    at = src.find("function Sys.DraftReport")
    assert at != -1, "缺 DraftReport"
    block = src[at:at + 1200]
    assert "PoliceRecords.InsertReport" in block, "必须走唯一写者，不准自己 INSERT"
    assert "INSERT INTO police_reports" not in block
    assert "status = 'draft'" in block
    assert "kind = 'report'" in block
    # 草稿不该带来的副作用
    for forbidden in ("is_bolo = true", "AddMoney", "police_evidence", "police_warrants"):
        assert forbidden not in block, f"草稿里混进了副作用: {forbidden}"


def test_policy_marks_it_l2_and_never_auto_executes() -> None:
    src = POLICY.read_text(encoding="utf-8")
    at = src.find("police_draft_report = {")
    assert at != -1
    block = src[at:at + 200]
    assert "risk = 'L2'" in block
    assert "requires_approval = true" in block
    assert "auto_execute = false" in block


def test_director_executor_delegates_to_the_police_export() -> None:
    src = MAIN.read_text(encoding="utf-8")
    assert "executePoliceDraftReport" in src
    assert "DraftReportSystem" in src
    assert "police_draft_report = executePoliceDraftReport" in src


def test_registry_tool_name_is_inside_the_verb_whitelist() -> None:
    d = json.loads(REGISTRY.read_text(encoding="utf-8"))
    tool = next(t for t in d["tools"] if t["director_action"] == "police_draft_report")
    assert tool["name"] == "apply_police_report"
    assert tool["risk"] == "L2"
    assert tool["requires_approval"] is True
    assert tool["channel"] == "write"
    assert tool["inputSchema"]["properties"]["citizenid"]["pattern"] == "^[A-Za-z0-9_-]{1,11}$"


def test_actions_doc_lists_it() -> None:
    doc = ACTIONS_DOC.read_text(encoding="utf-8")
    assert "`police_draft_report`" in doc
    assert "twenty-four actions" in doc
