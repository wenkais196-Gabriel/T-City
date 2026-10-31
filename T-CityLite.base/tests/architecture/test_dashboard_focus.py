"""车机中控必须走**交互路径栈**，并且自己做焦点的最终施加者。

2026-10-31 真机两轮：
  1) 面板打开、无游标、视角还能转 —— 车机自己 SetNuiFocus，绕过了焦点仲裁；
  2) 改走 Input.Push 之后视角锁住了、还是没有游标 —— 因为 **SetNuiFocus 是按资源的**，
     栈只能决定"谁该有焦点"，真正施加必须由拥有页面的资源来做（帧里的 owner +
     该资源导出的 ApplyFocus），否则焦点给到了没有 ui_page 的 custom-ui。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
CUSTOM_UI = REPO / "T-CityLite.base/resources/[custom]/custom-ui/client/main.lua"
DASH = REPO / "T-CityLite.base/resources/[system]/tcity-dashboard/client/main.lua"
APP = REPO / "T-CityLite.base/resources/[system]/tcity-dashboard/nui/src/App.vue"


def test_focus_owner_honours_an_explicit_keepinput_false() -> None:
    src = CUSTOM_UI.read_text(encoding="utf-8")
    at = src.find("function OpenMenu(opts)")
    assert at != -1
    block = src[at:at + 900]
    assert "elseif opts.keepInput == false then" in block
    assert "SetNuiFocusKeepInput(false)" in block


def test_dashboard_pushes_frames_owned_by_itself() -> None:
    src = DASH.read_text(encoding="utf-8")
    assert "id = 'dashboard'" in src and "owner = 'tcity-dashboard'" in src
    assert "id = 'dashboard:seats'" in src
    assert "Pop('dashboard')" in src and "Pop('dashboard:seats')" in src
    assert "OpenMenu(" not in src and "CloseMenu(" not in src
    # 关键：SetNuiFocus 是按资源的，必须由拥有页面的资源自己施
    assert "exports('ApplyFocus'" in src
    assert "SetNuiFocus(hasFocus == true, hasCursor == true)" in src


def test_dashboard_asks_for_a_refresh_once_the_page_is_ready() -> None:
    src = DASH.read_text(encoding="utf-8")
    app = APP.read_text(encoding="utf-8")
    assert "RegisterNUICallback('dashboardReady'" in src
    assert "RefreshFocus()" in src
    assert "sendNui('dashboardReady'" in app, "NUI 挂载/打开后要主动上报就绪"


def test_dashboard_toggles_once_per_keypress() -> None:
    src = DASH.read_text(encoding="utf-8")
    assert "TOGGLE_DEBOUNCE_MS" in src, "反复 restart 会让 RegisterKeyMapping 重复注册"


def test_dashboard_has_keyboard_navigation() -> None:
    app = APP.read_text(encoding="utf-8")
    assert "onKeydown" in app and "ArrowLeft" in app and "ArrowRight" in app
    assert "Escape" in app, "Esc/Backspace 要能关"
    console = (REPO / "T-CityLite.base/resources/[system]/tcity-dashboard/nui"
               / "src/components/tabs/PoliceConsole.vue").read_text(encoding="utf-8")
    assert "ArrowDown" in console and "ArrowUp" in console, "警情列表要能上下选"


def test_dashboard_keeps_driving_input_while_open() -> None:
    """中控是「边开边看」的终端：默认保留游戏输入，但视角仍被栈屏蔽。"""
    src = DASH.read_text(encoding="utf-8")
    assert "dashboard_drive_while_open" in src, "必须能一键回滚成独占输入"
    assert "keepInput = driveWhileOpen()" in src
    assert "DRIVE_CONTROLS" in src and "allow = DRIVE_CONTROLS" in src
    # 视角控制 1-6 绝不能放进 allow，否则鼠标一动镜头就转、游标没法用
    import re
    block = src[src.index("local DRIVE_CONTROLS"):src.index("}", src.index("local DRIVE_CONTROLS"))]
    ids = {int(n) for n in re.findall(r"\d+", block.split("=", 1)[1])}
    assert not ids & set(range(1, 7)), "视角控制 1-6 不能放进 allow"
