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

def code_only(source: str) -> str:
    """去掉 Lua 注释：注释里提到某个 API 不算用了它。"""
    return "\n".join(line.split("--", 1)[0] for line in source.splitlines())


PATH_API_EXPORTS = ("Push", "Pop", "Top", "Path", "IsTaken", "Owns", "ResetInput")


def violations_in_shared_layer(source: str) -> list[str]:
    code = code_only(source)
    bad = [f"missing export {name}" for name in PATH_API_EXPORTS if f"exports('{name}'" not in code]
    if "BLOCKED_CONTROLS" not in code:
        bad.append("no curated block list: DisableAllControlActions per frame stutters")
    if "DisableAllControlActions" in code:
        bad.append("still disabling every control each frame")
    if "inList(allow, control)" not in code:
        bad.append("the allow list is not honoured while blocking")
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
    # Release 必须先弹共享栈再看本地账：委托之后本地 stack 是空的，
    # 顺序反了就会"手机关了但帧还挂着"，屏蔽线程继续跑 → 玩家动不了。
    pop_at = source.find("layer:Pop(")
    local_at = source.find("if not removed then return false end")
    if pop_at == -1:
        bad.append("Release never pops the shared stack")
    elif local_at != -1 and pop_at > local_at:
        bad.append("Release consults the local stack before popping the shared one")
    return bad


# --------------------------------------------------------------------------- #
# 反向校验：每一条都必须能指出"坏形状"
# --------------------------------------------------------------------------- #

def violations_in_focus_ownership(layer_source: str, phone_source: str) -> list[str]:
    """SetNuiFocus 是按资源的：栈必须回调页面所属资源，不能自己按。

    在 custom-ui 里按焦点等于把焦点交给一个不存在的页面 —— 手机页面就收不到
    任何鼠标/键盘事件，也没有游标（真机排查了两轮才定位到）。
    """
    bad = []
    if "ownerApply" not in layer_source:
        bad.append("custom-ui applies focus itself instead of delegating to the page owner")
    if "exports[owner]:ApplyFocus" not in layer_source:
        bad.append("custom-ui never calls the owner's ApplyFocus export")
    if "exports('ApplyFocus'" not in phone_source:
        bad.append("the phone does not export ApplyFocus")
    return bad


def test_focus_ownership_gate_detects_a_layer_that_focuses_itself():
    layer = read("custom-ui/client/main.lua")
    phone = read("custom-phone/client/main.lua")
    assert violations_in_focus_ownership(layer, phone) == []

    broken_layer = "SetNuiFocus(true, true)"
    caught = violations_in_focus_ownership(broken_layer, "GetUiState")
    assert any("page owner" in item for item in caught), caught
    assert any("ApplyFocus" in item for item in caught), caught


def test_shared_layer_gate_detects_a_missing_path_api():
    real = read("custom-ui/client/main.lua")
    assert violations_in_shared_layer(real) == [], violations_in_shared_layer(real)

    broken = "exports('OpenMenu', OpenMenu)\nSetNuiFocus(true, true)\nDisableAllControlActions(0)"
    caught = violations_in_shared_layer(broken)
    assert any("IsTaken" in item for item in caught), caught
    assert any("curated block list" in item for item in caught), caught
    assert any("disabling every control" in item for item in caught), caught


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

    # 顺序反例：先看本地账、后弹共享栈 —— 真机上就是"关了但没释放"
    out_of_order = (
        "GetResourceState('custom-ui')\n"
        "function PhoneFocus.PushFrame() end\nfunction PhoneFocus.PopFrame() end\n"
        "local function Release()\nif not removed then return false end\nlayer:Pop('phone')\n"
    )
    assert any("before popping" in item for item in violations_in_phone_focus(out_of_order))

    leaky = "SetNuiFocusKeepInput(keepInput)\nGetResourceState('custom-ui')\n"
    leaky += "function PhoneFocus.PushFrame() end\nfunction PhoneFocus.PopFrame() end\n"
    assert any("keepInput" in item for item in violations_in_phone_focus(leaky))
