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
