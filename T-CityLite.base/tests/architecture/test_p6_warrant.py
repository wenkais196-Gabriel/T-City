"""P6-3：agent 申请逮捕令（L3，审批后也只到 requested）。

设计取舍：不新建表、不新开写者。`police_warrants` 的唯一写者是
`custom-police/server/p3_cases.lua`，所以系统侧入口就放在同一文件里，
共用同一条 INSERT，只把 actor 换成 action:<id>。
"""

from __future__ import annotations

import json
import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
CASES = REPO / "T-CityLite.base/resources/[custom]/custom-police/server/p3_cases.lua"
POLICY = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/policy.lua"
MAIN = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/main.lua"
REGISTRY = REPO / "tools/agent_tools.json"


def test_system_entry_lives_with_the_single_writer() -> None:
    src = CASES.read_text(encoding="utf-8")
    at = src.find("function C.RequestWarrantSystem")
    assert at != -1
    block = src[at:at + 1400]
    assert "INSERT INTO police_warrants" in block, "复用唯一的写者，别另开一条路径"
    assert "'requested'" in block or 'status = ' in block
    assert "audit(" in block and "'agent'" in block
    assert "audit_unavailable" in block, "审计失败必须让调用方看见"
    # 只到 requested：不许自己批准
    for forbidden in ("'approved'", "approved_by", "police_bolos"):
        assert forbidden not in block, f"越权副作用: {forbidden}"


def test_policy_is_l3_and_approval_bound() -> None:
    src = POLICY.read_text(encoding="utf-8")
    at = src.find("police_warrant_request = {")
    assert at != -1
    block = src[at:at + 200]
    assert "risk = 'L3'" in block
    assert "requires_approval = true" in block
    assert "auto_execute = false" in block


def test_executor_and_registry() -> None:
    main_src = MAIN.read_text(encoding="utf-8")
    assert "executePoliceWarrantRequest" in main_src
    assert "RequestWarrantSystem" in main_src
    assert "police_warrant_request = executePoliceWarrantRequest" in main_src

    d = json.loads(REGISTRY.read_text(encoding="utf-8"))
    tool = next(t for t in d["tools"] if t["director_action"] == "police_warrant_request")
    assert tool["name"] == "apply_police_warrant"
    assert tool["risk"] == "L3"
    assert tool["requires_approval"] is True
    assert tool["inputSchema"]["properties"]["reason"]["maxLength"] == 128
