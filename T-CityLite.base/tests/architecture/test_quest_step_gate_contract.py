"""契约：`nodeComplete` 必须在推进步骤之前咨询 validator 闸。

阶段 D · C1 的实现只有「顺序正确」才有意义：闸放在 `AdvanceStep` 之后等于没拦。
顺序是文本能判的，所以钉在这里，并带一条反向校验（把顺序调反的合成片段必须判红）。

为什么不用行为测试：`custom-quest/server/main.lua` 依赖 MySQL/exports/原生，
离线加载整支成本过高（现有 `test_quest_manager.py` 只截取纯 Lua 前 82 行）。
"""

from __future__ import annotations

from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
MAIN_LUA = BASE / "resources/[custom]/custom-quest/server/main.lua"

HANDLER_OPEN = "RegisterNetEvent('quest:server:nodeComplete'"
GATE_CALL = "QuestStepGate.RequiredValidator"
ADVANCE_CALL = "QuestManager.AdvanceStep("


def _handler_region(text: str) -> str:
    start = text.index(HANDLER_OPEN)
    nxt = text.find("RegisterNetEvent(", start + len(HANDLER_OPEN))
    return text[start:] if nxt == -1 else text[start:nxt]


def gate_precedes_advance(region: str) -> bool:
    """闸出现在处理器里，且位置在推进之前。"""
    gate_at = region.find(GATE_CALL)
    if gate_at == -1:
        return False
    advance_at = region.find(ADVANCE_CALL)
    if advance_at == -1:
        return False
    return gate_at < advance_at


def test_node_complete_consults_the_gate_before_advancing():
    region = _handler_region(MAIN_LUA.read_text(encoding="utf-8", errors="replace"))
    assert GATE_CALL in region, "nodeComplete 这条腿没有咨询 QuestStepGate（validator 会被跳过）"
    assert ADVANCE_CALL in region, "处理器里找不到 AdvanceStep，测试锚点失效（先更新这条断言）"
    assert gate_precedes_advance(region), "闸在 AdvanceStep 之后，等于没拦"


def test_rejects_reversed_order_and_missing_gate():
    """反向校验：顺序调反的片段必须判红，否则上一条断言永远成立。"""
    reversed_region = f"local x = 1\n{ADVANCE_CALL}cid, q, s)\nlocal r = {GATE_CALL}(step)\n"
    assert not gate_precedes_advance(reversed_region), "谓词对顺序调反的片段仍然通过（断言没有区分力）"
    missing_region = f"{ADVANCE_CALL}cid, q, s)\n"
    assert not gate_precedes_advance(missing_region), "谓词对没有闸的片段仍然通过"
