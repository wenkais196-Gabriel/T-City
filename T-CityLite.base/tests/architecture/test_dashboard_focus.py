"""车机中控是**独占输入**的全屏终端：打开时必须把 keepInput 关掉。

2026-10-31 真机：面板出来了、光标也有，视角却还能转。
原因是 `SetNuiFocusKeepInput` 是客户端全局标志 —— 手机（keepInput=true）开过一次后
它会一直留着 true，车机再 OpenMenu 只是 `SetNuiFocus(true,true)`，于是 look 依旧归游戏。
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
    assert "elseif opts.keepInput == false then" in block, (
        "OpenMenu 必须区分『没传 keepInput』与『显式 false』"
    )
    assert "SetNuiFocusKeepInput(false)" in block


def test_dashboard_asks_for_exclusive_input_everywhere() -> None:
    src = DASH.read_text(encoding="utf-8")
    assert src.count("OpenMenu({ keepInput = false })") >= 2, "主面板与换座浮层都要独占输入"
    # 退化路径（custom-ui 不在）也要清掉全局 keepInput
    assert src.count("SetNuiFocusKeepInput(false)") >= 2
