"""P3-1：对玩家的盘查入口（查证件 / 搜身 / 铐起 / 押送）。

P3 核对（docs/police/plans/2026-10-31-p3-audit.md）的结论：逮捕/报告/罚单/证据、
BOLO、搜身与押送事件都已存在，缺的是"对准一个真人"的入口。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
POLICE = REPO / "T-CityLite.base/resources/[custom]/custom-police"
TARGET = POLICE / "client/player_target.lua"
INTERACTIONS = POLICE / "server/interactions.lua"
MANIFEST = POLICE / "fxmanifest.lua"


def test_player_target_exposes_the_four_verbs() -> None:
    src = TARGET.read_text(encoding="utf-8")
    assert "AddGlobalPlayer" in src, "要挂在玩家身上，不是世界实体"
    for label in ("查证件", "搜身", "铐起", "押送"):
        assert label in src, f"缺动作：{label}"
    assert "canInteract" in src and "onduty" in src, "只有在岗警察才看得到选项"


def test_id_check_is_verified_on_the_server() -> None:
    src = INTERACTIONS.read_text(encoding="utf-8")
    at = src.find("police:server:showId")
    assert at != -1
    block = src[at:at + 1600]
    assert "onduty ~= true" in block, "离岗要拒绝"
    assert "too_far" in block and "GetEntityCoords" in block, "距离必须服务端复算"
    assert "PoliceAudit.Write" in block, "查证件要留审计"
    # 只回公开资料：钱包/背包/案底不该出现在这里
    for leak in ("money", "inventory", "phone"):
        assert leak not in block, f"查证件回包里混进了 {leak}"


def test_manifest_loads_the_target_panel() -> None:
    src = MANIFEST.read_text(encoding="utf-8")
    assert "client/player_target.lua" in src
