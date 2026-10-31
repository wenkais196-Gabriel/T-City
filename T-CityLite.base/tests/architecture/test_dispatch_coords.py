"""P2 调度：AC-P2-02 —— 下发给客户端的警情 MUST NOT 带精确坐标（蓝图 D5）。

真机核对（2026-10-31）发现 `broadcastIncidentAlert` 原样广播 x/y/z，
等于给开图玩家一个比调度还准的位置。修复后偏移逻辑收在
`shared/dispatch_view.lua`，任何对外投影（屏幕提示 / 车机 / 手机）都走同一份。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
POLICE = REPO / "T-CityLite.base/resources/[custom]/custom-police"
INCIDENTS = POLICE / "server/p0_incidents.lua"
VIEW = POLICE / "shared/dispatch_view.lua"


def test_client_alert_uses_the_shared_projection() -> None:
    src = INCIDENTS.read_text(encoding="utf-8")
    at = src.find("local function broadcastIncidentAlert")
    assert at != -1
    block = src[at:at + 1400]

    assert "PoliceDispatchView.Fuzz" in block, "必须走共享投影，不许自己算偏移"
    payload = block[block.find("local coords"):block.find("local sent")]
    assert "x = x," not in payload and "y = y," not in payload, (
        "payload 里出现了原始坐标 —— AC-P2-02 会 FAIL"
    )
    assert "point.x" in payload and "point.y" in payload


def test_projection_has_exactly_one_implementation() -> None:
    src = VIEW.read_text(encoding="utf-8")
    assert "function PoliceDispatchView.Fuzz" in src
    assert "GOLDEN_ANGLE" in src, "相邻单号的偏移要散开，不能都朝一个方向"
    # 全仓只该有一处算偏移
    import re
    hits = [p for p in (REPO / "T-CityLite.base/resources").rglob("*.lua")
            if "137.508" in p.read_text(encoding="utf-8", errors="ignore")]
    assert len(hits) == 1, [str(h) for h in hits]
