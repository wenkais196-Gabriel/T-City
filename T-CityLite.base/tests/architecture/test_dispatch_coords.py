"""P2 调度：AC-P2-02 —— 下发给客户端的警情 MUST NOT 带精确坐标（蓝图 D5）。

真机核对（2026-10-31）发现 `broadcastIncidentAlert` 原样广播 x/y/z，
等于给开图玩家一个比调度还准的位置。现在改成按单号稳定偏移到半径 60–95% 的点。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
INCIDENTS = REPO / "T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua"


def test_client_alert_never_carries_the_exact_position() -> None:
    src = INCIDENTS.read_text(encoding="utf-8")
    at = src.find("local function broadcastIncidentAlert")
    assert at != -1
    block = src[at:at + 1800]

    # 必须做偏移，且偏移量在半径内（太近等于没偏移，太远就没法出警）
    assert "spread" in block, "必须按半径偏移"
    assert "0.6" in block, "偏移下限（否则等于原地点）"
    assert "math.cos(rad)" in block and "math.sin(rad)" in block
    # 下发的 payload 里 x/y 是**偏移后**的值，不能是原始 x/y
    payload = block[block.find("local coords"):block.find("local sent")]
    assert "x = x," not in payload and "y = y," not in payload, (
        "payload 里出现了原始坐标 —— AC-P2-02 会 FAIL"
    )
    assert "x + math.cos(rad) * spread" in payload
