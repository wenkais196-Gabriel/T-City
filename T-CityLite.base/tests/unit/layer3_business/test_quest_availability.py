"""QA-01 — 「这个玩家现在能接哪些任务」必须由服务端算，而且算得对。

`GetAvailableQuests` 是手机任务 App 的数据源。它算错的后果是两头的：把不能接的显示成
"可接"，玩家点了会被 TriggerQuest 二次拒绝；把能接的藏起来，30 个任务模板就永远没人看得到。

这里直接跑 `server/quest_availability.lua`（lua5.4 真执行，依赖全部打桩），喂五种不满足
条件的形状，每一种都必须被拒且原因码可区分；再喂一份全满足的，必须放行。
"""
from __future__ import annotations

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[3]
MODULE = BASE / "resources/[custom]/custom-quest/server/quest_availability.lua"
HARNESS = BASE / "tests/fixtures/quest_availability_harness.lua"


def run() -> dict[str, dict]:
    assert MODULE.is_file(), f"缺少服务端模块: {MODULE}"
    script = HARNESS.read_text(encoding="utf-8").replace("__MODULE__", str(MODULE))
    proc = subprocess.run(["lua5.4", "-"], input=script, capture_output=True, text=True, timeout=30)
    if proc.returncode != 0:
        raise AssertionError(f"Lua 执行失败:\n{proc.stdout}\n{proc.stderr}")
    out: dict[str, dict] = {}
    for line in proc.stdout.strip().splitlines():
        parts = (line.split("|") + ["", "", ""])[:4]
        out[parts[0]] = {"case": parts[0], "ok": parts[1] == "true", "code": parts[2], "msg": parts[3]}
    return out


def test_availability_matrix():
    got = run()
    assert got["all_good"]["ok"], f"全部条件满足时必须可接: {got['all_good']}"
    assert got["tags_match"]["ok"], "标签匹配时必须可接"

    for case, expected in [
        ("tags_mismatch", "tags"),
        ("not_enough_police", "police"),
        ("missing_license", "license"),
        ("already_active", "active"),
        ("on_cooldown", "cooldown"),
    ]:
        row = got[case]
        assert not row["ok"], f"{case} 必须被拒（否则玩家点了会被 TriggerQuest 二次拒绝）"
        assert row["code"] == expected, f"{case} 的原因码应为 {expected}，实际 {row['code']}"

    assert got["career_missing_is_lenient"]["ok"], (
        "依赖资源缺失时应与 TriggerQuest 的宽松策略一致，不能把任务全部藏起来"
    )


def test_list_marks_availability_and_keeps_phone_shape():
    got = run()
    assert got["list_contains_free"]["ok"], "满足条件的任务必须出现在列表里且 available=true"
    assert got["list_contains_cop"]["ok"], "不满足条件的任务也要出现，只是 available=false"
    assert got["list_contains_cop"]["code"] == "police", (
        f"不可接时要给出原因码供 UI 显示: {got['list_contains_cop']}"
    )
    assert got["list_row_shape"]["ok"], "手机端依赖 id/title/category/level 这几个字段"

def test_export_arguments_are_not_shifted():
    """跨资源导出的调用约定：exports['res']:Method(a) 的第一个参数是 proxy 自己。

    写错成 dot 调用（少传 self）会静默把 source 当成 tags、把 tags 丢成 nil，
    真实环境里就变成"所有带标签的任务都被判为不满足"，而测试如果只看返回值仍然全绿。
    这里直接检查自定义导出收到的两个参数是否各就各位。
    """
    got = run()
    assert got["tag_args"]["code"] == "table", f"第三方导出收到的 tags 不是 table：{got['tag_args']}"
    assert got["tag_args"]["msg"] == "1", f"第三方导出收到的 source 不是玩家 source：{got['tag_args']}"

def test_blocked_quests_explain_what_is_missing():
    """玩家看到的不能只是一句 "You do not meet the requirements"。

    TriggerQuest 除了职业/警力/执照，还会拒"剧情线没完成"和"剧情抉择没做"——这两项以前
    availability 层完全没检查，等于手机上说"可接"、点下去被拒。现在两项都要检查，
    而且要把缺的那一条用人话列出来。
    """
    got = run()
    assert got["arc_locked"]["code"] == "arc", f"剧情线未完成必须被拒: {got['arc_locked']}"
    assert got["arc_text"]["ok"], f"要求里应写明是哪条剧情线: {got['arc_text']}"
    assert got["choice_locked"]["code"] == "choice", f"剧情抉择未做必须被拒: {got['choice_locked']}"
    assert got["choice_text"]["ok"], f"要求里应写明需要哪次选择: {got['choice_text']}"
    assert got["choice_ok"]["ok"], "抉择满足后应放行"

    assert got["req_police_unmet"]["ok"], "缺警力那条需求必须标成未满足"
    assert got["req_police_unmet"]["code"] == "has_text", "需求必须有可读文案"
    assert got["req_reason_is_human"]["ok"], f"拒绝原因要是人话: {got['req_reason_is_human']}"

    # 剧情线一次性：通关后必须从"可接"里消失（每轮只能玩一遍）
    assert got["arc_already_done"]["code"] == "arc_done", f"已通关的剧情线必须被拒: {got['arc_already_done']}"
    assert got["arc_done_text"]["ok"], f"要说明每轮只能玩一遍: {got['arc_done_text']}"
    # min_police = 0 不是约束，不许变成"在勤警力 ≥ 0（当前 0）"这种噪音
    assert got["zero_police_is_noise"]["ok"], "min_police = 0 不该产生需求项"
