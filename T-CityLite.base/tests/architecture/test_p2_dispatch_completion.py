"""P2 收尾的四个缺口（2026-10-31）。

* AC-P2-05 幂等键 `ref` + `merge_count`（迁移 v3.12 + 合并分支）
* AC-P2-09 只有 lead 能结案
* AC-P2-04 到场要"停稳"（速度上限），不只是进半径
* AC-P2-10/11 可测性（bench / 无警在线建单不报错）
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
POLICE = REPO / "T-CityLite.base/resources/[custom]/custom-police"
INCIDENTS = POLICE / "server/p0_incidents.lua"
GUIDE = POLICE / "client/incident_guidance.lua"
POLICY = POLICE / "shared/policy.lua"
MIGRATION = REPO / "T-CityLite.base/migrations/v3.12_police_incident_ref.sql"


def test_ref_and_merge_count_exist_in_schema_and_merge_path() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "ADD COLUMN ref VARCHAR(64)" in sql
    assert "ADD COLUMN merge_count INT NOT NULL DEFAULT 1" in sql
    assert "idx_ref_activity" in sql

    src = INCIDENTS.read_text(encoding="utf-8")
    assert "findMergeableIncident(code, coords, ref)" in src, "合并要先按 ref"
    assert "merge_count = COALESCE(merge_count, 1) + 1" in src, "合并要把次数记在单上"
    assert "add('ref', ref)" in src, "新建时要落 ref"


def test_only_the_lead_can_close() -> None:
    src = INCIDENTS.read_text(encoding="utf-8")
    at = src.find("function P.SetIncidentStatus")
    block = src[at:at + 2500]
    assert "role = 'primary'" in block, "要查这张单的 lead"
    assert "return false, 'lead_only'" in block


def test_arrival_requires_the_vehicle_to_stop() -> None:
    policy = POLICY.read_text(encoding="utf-8")
    assert "ARRIVE_MAX_SPEED" in policy, "速度上限要放在共享规则里"
    guide = GUIDE.read_text(encoding="utf-8")
    assert "slowEnough" in guide and "GetEntitySpeed" in guide, "到场判定要带速度"
