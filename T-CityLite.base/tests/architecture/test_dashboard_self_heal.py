"""车机不能再"静默无响应"：锁服务缺失时必须自愈或明说。

真机两次事故：custom-vehicles 被 `restart <别的资源>` 连坐停掉，
按 I 之后客户端只发了 request_lock 就再无下文，玩家看到的是"按键坏了"。
"""
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
DASH = REPO / "T-CityLite.base/resources/[system]/tcity-dashboard"


def test_dashboard_rejects_a_stopped_lock_service() -> None:
    src = (DASH / "server/main.lua").read_text(encoding="utf-8")
    assert "GetResourceState('custom-vehicles')" in src
    assert "StartResource('custom-vehicles')" in src, "服务端要能把锁服务拉起来"
    assert "onResourceStart" in src


def test_dashboard_rejects_a_silent_no_reply() -> None:
    src = (DASH / "client/main.lua").read_text(encoding="utf-8")
    assert "lockPending = true" in src
    assert "SetTimeout(900" in src
    assert "车机服务未就绪" in src, "没有回执时必须告诉玩家缺的是什么，别静默"
