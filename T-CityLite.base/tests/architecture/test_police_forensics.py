"""L2 后勤·现场化验（蓝图 §6.2）的闸门。

设计上的关键取舍要钉住：**不做 UPDATE**。采样与结果是两条 append-only 的证据行，
这样既不需要给 `police_evidence` 加列（动 schema 属 L4），时间线也天然可读。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base/resources/[custom]/custom-police"
SERVER = RES / "server/forensics.lua"
CLIENT = RES / "client/forensics.lua"


def test_forensics_appends_instead_of_updating() -> None:
    src = SERVER.read_text(encoding="utf-8")

    # 证据必须挂在案卷上（owner 的插入校验要求 case_id）
    assert "case_id = case" in src
    # 两条独立证据：采样 + 结果
    assert "sample.exhibit_no" in src
    assert "forensic.result" in src and "forensic.sample" in src
    # 不做 UPDATE，也不直接写 SQL
    assert "UPDATE police_evidence" not in src, "化验结果必须作为新证据行追加，不能改已有行"
    assert "INSERT INTO" not in src, "证据写入必须走 owner 的导出"
    # 走 owner
    assert "exports['custom-police']:RegisterEvidence" in src
    # 权限 + 在岗 + 冷却
    assert "PolicePolicy.Can(data, 'evidence.register')" in src
    assert "onduty ~= true" in src
    assert "COOLDOWN_SECONDS" in src
    # 警官离线时不留孤儿证据
    assert "officer_offline" in src


def test_forensics_command_is_whitelisted_for_live_tests() -> None:
    src = CLIENT.read_text(encoding="utf-8")
    assert "RegisterCommand('sample'" in src
    assert "police:server:forensicSample" in src
    for kind in ("gsr", "drug", "blood"):
        assert kind in src
