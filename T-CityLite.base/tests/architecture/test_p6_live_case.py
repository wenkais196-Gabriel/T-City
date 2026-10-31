"""P6-1：agent 的「眼睛」走 live 只读通道。

第一次尝试把它做成 director action 被注册表校验器否掉：
读类工具必须 GET、director_action=null、compensation=none。
所以这一条是 live 路由，不写 agent_actions，也不需要审批。
"""

from __future__ import annotations

import json
import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
LIVE = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/live_api.lua"
REGISTRY = REPO / "tools/agent_tools.json"


def test_live_route_exists_and_validates_the_id() -> None:
    src = LIVE.read_text(encoding="utf-8")
    assert "/agent/v1/live/police/cases" in src
    at = src.find("local function handlePoliceCase")
    assert at != -1
    block = src[at:at + 1600]
    assert "invalid_case" in block, "非数字 id 要 400"
    assert "case_not_found" in block, "不存在的案卷要 404"
    # 只回案情：不许出现姓名/坐标/正文
    for leak in ("charinfo", "firstname", "lastname", "vector3", "summary"):
        assert leak not in block, f"live 案卷读回里混进了 {leak}"


def test_registry_declares_it_as_a_read_tool() -> None:
    d = json.loads(REGISTRY.read_text(encoding="utf-8"))
    tool = next((t for t in d["tools"] if t["name"] == "get_police_case"), None)
    assert tool is not None, "注册表里必须有 get_police_case"
    assert tool["channel"] == "read"
    assert tool["director_action"] is None, "读类工具不能绑 director 动作"
    assert tool["http"]["method"] == "GET"
    assert tool["auth"] == "live"
    assert tool["compensation"] == "none"
