"""P2-4：车机终端的警情页 —— 数据只在服务端脱敏后下发，且只有值班警察能读。

真机链路：车机 NUI → client/police.lua（NUI 回调，本地先判在岗）
→ server/police_api.lua（再判一次 + 限流）→ exports['custom-police']:GetIncidentsPublic
→ shared/dispatch_view.lua（按 D5 偏移坐标）。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
POLICE = REPO / "T-CityLite.base/resources/[custom]/custom-police"
DASH = REPO / "T-CityLite.base/resources/[system]/tcity-dashboard"


def test_public_export_is_source_scoped_and_projected() -> None:
    src = (POLICE / "server/p0_read.lua").read_text(encoding="utf-8")
    at = src.find("exports('GetIncidentsPublic'")
    assert at != -1, "必须导出 GetIncidentsPublic 给车机/手机"
    block = src[at:at + 700]
    assert "PolicePolicy.Can(actor" in block, "export 必须自己判权限（调用方是别的资源）"
    assert "if not audit(actor.citizenid" in block, "export 必须自己写审计并失败关闭"
    assert "readIncidents(nil)" in block, "走共享的只读查询"
    assert "PoliceDispatchView" in block, "坐标必须过投影（D5）"
    assert "for _, incident in ipairs(rows or {}) do" in block, "上游空/异常时要安全退化"


def test_dashboard_server_callback_guards_duty_and_rate() -> None:
    src = (DASH / "server/police_api.lua").read_text(encoding="utf-8")
    at = src.find("tcity-dashboard:server:dispatchList")
    assert at != -1, "车机要有自己的警情回调"
    block = src[at:at + 900]
    assert "onduty" in block, "服务端必须再判一次在岗"
    assert "checkRateLimit(source, 'dispatchList')" in block, "必须限流"
    assert "GetIncidentsPublic(source, 20)" in block, "必须把 source 透传下去"


def test_dashboard_client_exposes_the_nui_callbacks() -> None:
    src = (DASH / "client/police.lua").read_text(encoding="utf-8")
    assert "RegisterNUICallback('dispatchList'" in src
    assert "RegisterNUICallback('dispatchWaypoint'" in src
    assert "SetNewWaypoint" in src, "一键导航要在客户端设点"


def test_dashboard_ui_renders_the_dispatch_section() -> None:
    vue = (DASH / "nui/src/components/tabs/PoliceConsole.vue").read_text(encoding="utf-8")
    assert "dispatchList" in vue and "dispatchWaypoint" in vue
    assert "loadDispatch()" in vue, "打开面板要拉一次"
    assert "STATUS_LABEL" in vue, "状态要给人话"


def test_manifest_loads_the_projection_before_its_readers() -> None:
    src = (POLICE / "fxmanifest.lua").read_text(encoding="utf-8")
    assert src.index("shared/dispatch_view.lua") < src.index("server/p0_read.lua")
