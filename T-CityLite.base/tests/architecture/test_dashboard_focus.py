"""车机中控必须走**交互路径栈**（custom-ui 的 Input.Push），不能自己 SetNuiFocus。

2026-10-31 真机：面板打开了、没有游标、视角还能转。
根因是车机绕过了焦点仲裁：
  * 栈非空时 apply() 才会起"每帧屏蔽视角控制"的线程，绕过去就没屏蔽；
  * keepInput 是客户端全局且会粘住（手机开过一次一直是 true）；
  * 页面没加载完时 SetNuiFocus 会被忽略，需要 RefreshFocus 再施一次。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
CUSTOM_UI = REPO / "T-CityLite.base/resources/[custom]/custom-ui/client/main.lua"
DASH = REPO / "T-CityLite.base/resources/[system]/tcity-dashboard/client/main.lua"


def test_focus_owner_honours_an_explicit_keepinput_false() -> None:
    src = CUSTOM_UI.read_text(encoding="utf-8")
    at = src.find("function OpenMenu(opts)")
    assert at != -1
    block = src[at:at + 900]
    assert "elseif opts.keepInput == false then" in block
    assert "SetNuiFocusKeepInput(false)" in block


def test_dashboard_pushes_frames_instead_of_setting_focus_directly() -> None:
    src = DASH.read_text(encoding="utf-8")
    assert "exports['custom-ui']:Push({ id = 'dashboard'" in src, "主面板要压栈"
    assert "exports['custom-ui']:Pop('dashboard')" in src, "关闭要弹自己这一帧"
    assert "Push({ id = 'dashboard:seats'" in src, "换座浮层也要压栈"
    assert "Pop('dashboard:seats')" in src
    assert "OpenMenu(" not in src and "CloseMenu(" not in src, (
        "OpenMenu/CloseMenu 是绕过栈的旧 API，车机不该再用"
    )


def test_dashboard_refreshes_focus_after_the_page_is_ready() -> None:
    src = DASH.read_text(encoding="utf-8")
    assert "RefreshFocus()" in src, "页面就绪后必须再施一次焦点，否则收不到键鼠"
