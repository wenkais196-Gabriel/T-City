"""司法链"造数据"后门的闸门，以及 P1 现状的守卫。

背景（2026-10-30 实测）：`police_cases` / `police_reports` / `police_arrests` /
`justice_sentences` 四张表和 `CreateCase` / `RegisterArrest` / `RecordVerdict`
三个导出**早就存在**，但四张表都是 0 行 —— 链路"写好了但没跑过"。
所以 P1 需要的是一个能重复跑通它的入口，而不是第二套写库代码。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
RES = REPO / "T-CityLite.base/resources/[custom]/custom-police"
SEED = RES / "server/seed_dev.lua"


def test_case_seed_is_gated_and_reuses_the_owner_exports() -> None:
    src = SEED.read_text(encoding="utf-8")

    # 门控：默认关 + 只接受控制台
    assert "GetConvar('police_seed_dev_enabled', '0')" in src
    assert "if source ~= 0 then return end" in src

    # 必须复用 owner 的导出，不许自己写 SQL（表有唯一 owner）
    assert "exports['custom-police']:CreateCase" in src
    assert "exports['custom-police']:RegisterArrest" in src
    assert "INSERT INTO" not in src and "MySQL." not in src, (
        "造数据也必须走 owner，不能绕过唯一写者"
    )
