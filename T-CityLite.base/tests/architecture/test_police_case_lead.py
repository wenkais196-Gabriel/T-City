"""案卷主办人（lead_citizenid）与律师通知的闸门。

2026-10-30 真机发现：`police_cases.lead_citizenid` 一直是 NULL ——
MDT 的 `create_case` 不传这个字段，owner 也不兜底。案卷因此查不出"谁负责"。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
CASES = REPO / "T-CityLite.base/resources/[custom]/custom-police/server/p3_cases.lua"
ARREST = REPO / "T-CityLite.base/resources/[custom]/custom-justice/server/arrest.lua"


def test_case_create_defaults_lead_to_the_actor() -> None:
    src = CASES.read_text(encoding="utf-8")
    at = src.find("function C.CreateCase")
    assert at != -1
    block = src[at:at + 1200]
    assert "lead_citizenid" in block
    # 缺省必须落到 actor 自己，且不能把空串写进库
    assert "if lead == '' then lead = actor.citizenid end" in block, (
        "没传 lead 时必须默认立案人自己"
    )


def test_lawyer_notification_fires_once_per_lawyer() -> None:
    src = ARREST.read_text(encoding="utf-8")
    at = src.find("RegisterNetEvent('justice:server:registerArrest'")
    block = src[at:at + 4000]
    # 每个在线律师一次，且同一案件里没有第二个通知点
    assert block.count("justice:client:lawyerNotify") == 1, "同一案件只应通知一次"
    assert "for _, lawyerSrc in ipairs(lawyerSources) do" in block
    assert "Lawyer.minOnlineForAssignment" in block, "低于门槛不通知"
