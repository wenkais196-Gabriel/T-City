"""P6-4 草稿箱 UI 契约（MDT 手机/平板）。

置信度分档不建列：`needs_review` 落在草稿行的 `disposition`（草稿本来不用这一列），
由 director 判据给出 —— 码位被降级成 911、或描述短于 20 字。
"""

from __future__ import annotations

import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
INC = REPO / "T-CityLite.base/resources/[custom]/custom-police/server/p0_incidents.lua"
DIR_MAIN = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/main.lua"
DIR_POLICY = REPO / "T-CityLite.base/resources/[custom]/custom-director/server/policy.lua"
APP = REPO / "T-CityLite.base/resources/[custom]/custom-phone/server/apps/police_mdt.lua"
UI = REPO / "T-CityLite.base/resources/[custom]/custom-phone/web/src/apps/PoliceMDT.svelte"


def test_review_flag_is_derived_without_a_new_column() -> None:
    src = INC.read_text(encoding="utf-8")
    at = src.index("function P.DraftCallSystem")
    block = src[at:at + 900]
    assert "needs_review" in block
    assert "disposition" in block
    # 不许为了分档去改表：草稿箱用既有 disposition 列
    assert "ALTER TABLE" not in block


def test_list_drafts_expires_stale_drafts_and_exposes_review() -> None:
    src = INC.read_text(encoding="utf-8")
    at = src.index("function P.ListDrafts")
    block = src[at:at + 2000]
    assert "INTERVAL 30 MINUTE" in block, "草稿不能无限期挂着"
    assert "'stale'" in block
    assert "row.review" in block
    assert "age_minutes" in block


def test_discard_requires_grade_two_and_audits() -> None:
    src = INC.read_text(encoding="utf-8")
    at = src.index("function P.DiscardDraft")
    block = src[at:at + 1200]
    assert "grade(actor) < 2" in block and "grade_too_low" in block
    assert "status = 'draft'" in block, "只能丢草稿"
    assert "incident.discard" in block
    assert "audit_unavailable" in block


def test_director_marks_low_confidence_cases() -> None:
    policy = DIR_POLICY.read_text(encoding="utf-8")
    assert "codeFallback" in policy
    assert "code_fallback = codeFallback" in policy
    main = DIR_MAIN.read_text(encoding="utf-8")
    assert "review = (params.code_fallback == true)" in main


def test_phone_app_exposes_drafts_query_and_actions() -> None:
    app = APP.read_text(encoding="utf-8")
    assert "drafts = function(source)" in app
    assert "adopt_draft" in app and "discard_draft" in app
    assert "AdoptDraft" in app and "DiscardDraft" in app


def test_mdt_ui_has_two_lanes_and_a_discard_confirmation() -> None:
    ui = UI.read_text(encoding="utf-8")
    assert "📝 草稿箱" in ui
    assert "可采纳" in ui and "需核对" in ui
    assert "confirmDiscard" in ui, "丢弃必须二次确认"
    assert "adopt_draft" in ui and "discard_draft" in ui
    assert "暂无待采纳草稿" in ui
