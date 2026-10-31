"""决策弹窗必须把控制权还回去（真机症状：选完选项人物动不了 / 弹窗不消失）。

三个具体故障点：
  1. 打开时 SetNuiFocusKeepInput(false)，关闭时只 SetNuiFocus(false,false) → keepInput 残留 false
  2. 重复下发时静默 return → 玩家看着旧弹窗，服务端却在等新决策
  3. CEF 不回调 → 焦点永远收不回来
"""
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
CLIENT = REPO / "T-CityLite.base/resources/[custom]/story-engine/client/main.lua"


def test_decision_close_restores_keepinput_and_fires_a_watchdog() -> None:
    src = CLIENT.read_text(encoding="utf-8")

    assert "function closeDecisionSurface(reason)" in src
    assert "SetNuiFocusKeepInput(keepInputBefore == true)" in src, "必须恢复进入前的 keepInput"
    assert "keepInputBefore = IsNuiFocusKeepingInput()" in src
    assert "SetTimeout(" in src and "watchdog" in src, "CEF 不回调时要有看门狗"
    # 三处关闭路径都要走统一出口，不允许再出现裸的 SetNuiFocus(false, false) 收尾
    assert src.count("closeDecisionSurface(") >= 4


def test_duplicate_decision_rejects_the_silent_drop() -> None:
    src = CLIENT.read_text(encoding="utf-8")
    dup = src[src.index("if isNuiOpen then"): src.index("if isNuiOpen then") + 400]
    assert "closeDecisionSurface('duplicate')" in dup, "重复下发必须先回收旧弹窗，不能静默丢弃"
