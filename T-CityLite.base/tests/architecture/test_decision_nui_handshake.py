"""决策面板不能依赖 CEF 握手，且 payload 必须带选项。

真机证据（2026-10-31）：
  * 等握手 → CEF 不回 nuiReady → 面板永不出现，3s 看门狗还直接把任务结算了
  * payload 只有 decision_id → telemetry `decision.offer{option_count:0}` + `no_options`
  * 定义在 story-engine 里，OfferDecision 返回 (true,'offered') 不是表 → 必须 GetDecision
"""
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
CLIENT = REPO / "T-CityLite.base/resources/[custom]/story-engine/client/main.lua"
QUEST = REPO / "T-CityLite.base/resources/[custom]/custom-quest/server/quest_manager.lua"


def test_decision_panel_rejects_waiting_for_the_nui_handshake() -> None:
    client = CLIENT.read_text(encoding="utf-8")
    assert "SendNUIMessage(payload)" in client, "必须立即发送，不能等握手"
    assert "SetTimeout(1000" in client, "丢包要补发一次"
    assert "RegisterCommand('story_choose'" in client, "必须有不依赖 CEF 的兜底"
    assert "SetTimeout(20000" in client, "看门狗不该 3s 就动手"


def test_decision_payload_rejects_missing_options() -> None:
    src = QUEST.read_text(encoding="utf-8")
    block = src[src.index("if normalizedType == 'DECISION'"): src.index("TriggerClientEvent(eventName, source, data)")]
    assert "GetDecision" in block, "options 要从 GetDecision 取（OfferDecision 只回 boolean）"
    assert "data.options = def.options" in block
    assert "data.prompt = def.prompt" in block
