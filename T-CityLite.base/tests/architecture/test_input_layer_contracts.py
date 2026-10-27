"""输入分层的契约闸门（每条检查都能证明自己会红）。

背景见 docs/client/plans/2026-10-27-input-layering.md：
- 只有一个仲裁者（custom-ui 的交互路径栈）能决定"谁拥有输入"；
- 玩法脚本（转向灯、巡航）必须问它，不能再把"被禁用的控制被按下"当成自己的输入；
- 手机导航不得自己 DisableControlAction(172-175) —— 那正好会点亮转向灯
  （indicators.lua 读的正是 IsDisabledControlJustPressed(174/175/187)）。

每个检查都写成"纯函数吃源码"，所以既能核对真实文件，也能喂一段坏形状证明它会红。
"""

from pathlib import Path

RESOURCES = Path(__file__).resolve().parents[2] / "resources" / "[custom]"


def read(relative: str) -> str:
    path = RESOURCES / relative
    assert path.is_file(), f"missing {relative}"
    return path.read_text(encoding="utf-8")


# --------------------------------------------------------------------------- #
# 纯检查：返回违规列表（空 = 合规）
# --------------------------------------------------------------------------- #

PATH_API_EXPORTS = ("Push", "Pop", "Top", "Path", "IsTaken", "Owns", "ResetInput")


def violations_in_shared_layer(source: str) -> list[str]:
    bad = [f"missing export {name}" for name in PATH_API_EXPORTS if f"exports('{name}'" not in source]
    if "DisableAllControlActions" not in source:
        bad.append("the top frame never disables the game's controls")
    if "EnableControlAction" not in source:
        bad.append("no allow list: walking would be blocked too")
    return bad


def violations_in_gameplay_guards(sources: dict[str, str]) -> list[str]:
    """玩法脚本必须问 IsTaken，否则上层屏蔽控制会变成它的输入。"""
    return [f"{name} never consults IsTaken" for name, source in sources.items() if "IsTaken" not in source]


def violations_in_nav_disable(source: str) -> list[str]:
    offenders = [
        line.strip()
        for line in source.splitlines()
        if "DisableControlAction(" in line and not line.lstrip().startswith("--")
    ]
    return [f"nav disables controls: {line}" for line in offenders]


def violations_in_phone_frames(source: str) -> list[str]:
    bad = []
    if "PhoneFocus.PushFrame" not in source:
        bad.append("app changes never push a frame")
    if "phone:text" not in source:
        bad.append("focusing an input never pushes a text frame")
    return bad


def violations_in_phone_focus(source: str) -> list[str]:
    bad = []
    for needed in (
        "function PhoneFocus.PushFrame",
        "function PhoneFocus.PopFrame",
        "GetResourceState('custom-ui')",
    ):
        if needed not in source:
            bad.append(f"focus.lua missing {needed}")
    # keepInput 归 custom-ui 的栈统一设置；手机侧只在退化路径里碰它
    if "SetNuiFocusKeepInput(keepInput)" in source:
        bad.append("focus.lua sets keepInput unconditionally instead of delegating")
    return bad


# --------------------------------------------------------------------------- #
# 反向校验：每一条都必须能指出"坏形状"
# --------------------------------------------------------------------------- #

def test_shared_layer_gate_detects_a_missing_path_api():
    real = read("custom-ui/client/main.lua")
    assert violations_in_shared_layer(real) == [], violations_in_shared_layer(real)

    broken = "exports('OpenMenu', OpenMenu)\nSetNuiFocus(true, true)"
    caught = violations_in_shared_layer(broken)
    assert any("IsTaken" in item for item in caught), caught
    assert any("never disables" in item for item in caught), caught
    assert any("allow list" in item for item in caught), caught


def test_gameplay_guard_gate_detects_a_script_that_reads_controls_directly():
    real = {
        "custom-vehicles/client/indicators.lua": read("custom-vehicles/client/indicators.lua"),
        "custom-vehicles/client/cruise.lua": read("custom-vehicles/client/cruise.lua"),
    }
    assert violations_in_gameplay_guards(real) == [], violations_in_gameplay_guards(real)

    broken = {"custom-vehicles/client/indicators.lua": "if IsDisabledControlJustPressed(0, 174) then end"}
    caught = violations_in_gameplay_guards(broken)
    assert caught and "IsTaken" in caught[0], caught


def test_nav_gate_detects_the_phone_disabling_the_arrow_controls():
    real = read("custom-phone/client/core/nav.lua")
    assert violations_in_nav_disable(real) == [], violations_in_nav_disable(real)

    broken = "DisableControlAction(0, 174, true)\n-- DisableControlAction(0, 30, true) 注释里提到不算\n"
    caught = violations_in_nav_disable(broken)
    assert len(caught) == 1, caught
    assert "174" in caught[0], caught


def test_phone_frame_gate_detects_a_shell_without_app_or_text_frames():
    assert violations_in_phone_frames(read("custom-phone/client/main.lua")) == []
    assert violations_in_phone_focus(read("custom-phone/client/core/focus.lua")) == []

    frames = violations_in_phone_frames("RegisterNUICallback('appState', function() end)")
    assert frames, "a shell that never pushes frames must be caught"

    focus = violations_in_phone_focus("function PhoneFocus.Acquire() end")
    assert focus, "a focus module without delegation hooks must be caught"

    leaky = "SetNuiFocusKeepInput(keepInput)\nGetResourceState('custom-ui')\n"
    leaky += "function PhoneFocus.PushFrame() end\nfunction PhoneFocus.PopFrame() end\n"
    assert any("keepInput" in item for item in violations_in_phone_focus(leaky))
