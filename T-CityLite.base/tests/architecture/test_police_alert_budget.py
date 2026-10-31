"""P2-2：警情通知的预算层必须存在、被接上，并且能一键关掉。

真机问题：建单后逐条 push，连锁事件会把通知栏糊满，重要那条反而看不见。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base/resources/[custom]/custom-police"
BUDGET = RES / "shared/alert_budget.lua"
INCIDENTS = RES / "server/p0_incidents.lua"
MANIFEST = RES / "fxmanifest.lua"


def test_budget_module_keeps_the_documented_windows() -> None:
    src = BUDGET.read_text(encoding="utf-8")
    assert "MERGE_WINDOW_MS = 90 * 1000" in src, "同 code 合并窗口必须 90 秒"
    assert "BURST_WINDOW_MS = 5 * 1000" in src, "突发窗口必须 5 秒"
    assert "BURST_MAX = 3" in src, "非紧急每窗口最多 3 条"
    assert "priority <= 1" in src, "紧急警情要穿透频率上限"


def test_incident_notifications_go_through_the_budget() -> None:
    src = INCIDENTS.read_text(encoding="utf-8")
    at = src.find("local function notifyOnDutyIncident")
    assert at != -1
    block = src[at:at + 1600]
    assert "PoliceAlertBudget" in block, "通知必须过预算层"
    assert "police_alert_budget" in block, "必须有回滚开关"
    assert "Decorate" in block, "合并后要在标题上显示 ×N"


def test_manifest_loads_the_budget_before_the_consumers() -> None:
    src = MANIFEST.read_text(encoding="utf-8")
    assert "shared/alert_budget.lua" in src
    assert src.index("shared/alert_budget.lua") < src.index("server/p0_incidents.lua")
