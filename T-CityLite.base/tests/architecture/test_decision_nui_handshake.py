"""决策面板必须先握手再发消息（否则焦点锁死、画面空白）。

真机证据（2026-10-31 20:2x）：telemetry 显示
  decision.offer / nui.focus{focused=1,keepInput=false} / heartbeat{nuiOpen=true, nuiAgeMs 6s→36s}
但没有任何 nui.makeChoice —— 玩家看不到面板、点不了、Esc 也退不出。
"""
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
CLIENT = REPO / "T-CityLite.base/resources/[custom]/story-engine/client/main.lua"
HTML = REPO / "T-CityLite.base/resources/[custom]/story-engine/client/decision_nui.html"


def test_decision_panel_rejects_sending_before_the_nui_handshake() -> None:
    html = HTML.read_text(encoding="utf-8")
    assert "nuiPost('nuiReady'" in html, "NUI 必须自证已加载"

    client = CLIENT.read_text(encoding="utf-8")
    assert "RegisterNUICallback('nuiReady'" in client
    assert "pendingNuiPayload" in client, "未握手时要缓存而不是丢弃"
    assert "closeDecisionSurface('nui_not_ready')" in client, "握手超时必须交还控制"


def test_decision_payload_rejects_missing_options() -> None:
    """模板只写 decision_id；prompt/options 必须从 OfferDecision 的返回值并进 payload。

    真机 telemetry：`decision.offer` 紧跟一条 `decision.no_options` —— 客户端拿不到
    options 就只能发 skip，玩家永远看不到按钮。
    """
    src = (REPO / "T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua").read_text(
        encoding="utf-8"
    )
    block = src[src.index("if normalizedType == 'DECISION'"): src.index("TriggerClientEvent(eventName, source, data)")]
    assert "type(result) == 'table'" in block
    assert "data.options = result.options" in block
    assert "data.prompt = result.prompt" in block
