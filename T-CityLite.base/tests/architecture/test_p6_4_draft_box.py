"""P6-4 草稿箱：让草稿能进能出。

草稿写进去之后，必须有人能看见、能采纳，否则就是死数据。
这一层只做服务端闭环（列表 + 采纳），UI 另做。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
INC = REPO / "T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua"
MAIN = REPO / "T-CityLite.base/resources/[custom]/custom-police/server/main.lua"


def _fn(src: str, name: str, size: int = 1200) -> str:
    at = src.index(f"function P.{name}(")
    return src[at:at + size]


def test_list_drafts_is_police_only_and_audits_fail_closed() -> None:
    src = INC.read_text(encoding="utf-8")
    block = _fn(src, "ListDrafts")
    assert "PolicePolicy.Can" in block
    assert "incident.draft.view" in block
    assert "audit_unavailable" in block
    assert "status = 'draft'" in block, "只列草稿"
    assert "LIMIT" in block


def test_adopt_goes_through_the_existing_state_machine() -> None:
    src = INC.read_text(encoding="utf-8")
    block = _fn(src, "AdoptDraft")
    assert "P.SetIncidentStatus(source, id, 'open')" in block, "采纳 = draft→open，复用状态机"
    assert "incident.adopt" in block
    assert "audit_unavailable" in block


def test_net_events_are_registered_and_rate_limited() -> None:
    src = MAIN.read_text(encoding="utf-8")
    assert "RegisterNetEvent('police:server:draftList'" in src
    assert "RegisterNetEvent('police:server:adoptDraft'" in src
    adopt = src[src.index("RegisterNetEvent('police:server:adoptDraft'"):][:900]
    assert "Cooldown" in adopt, "连点会把整箱草稿一次发出去"
    assert "src == 0" in adopt, "控制台 source=0 直接拒"
