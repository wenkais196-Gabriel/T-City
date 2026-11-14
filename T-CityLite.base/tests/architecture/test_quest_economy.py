"""循环型任务的收益必须落在目标带里 —— 否则"干活为主"的经济设计只是一句口号。

背景：`04-numbers.md` 定的是 1,400–2,800 $/h。新路线（garbage_v1_* / bus_v1_*）是按这个算出来的，
但**存量 7 条旧壳**一直停在 $150–800/次，从没人把"一次几分钟"折算成"每小时多少"。

2026-11-14 拿到第一个实测：`hotdog_vendor` 在同一地点连做 4 步，服务端日志
`🏁 COMPLETING … 用时=0.9 分钟`，当时给的是 $165 现金 → **约 11,000 $/h**，是新路线的 4–8 倍。
这就是"旧壳印钞"的实证。

估算口径在 `tools/dev/quest_econ.py`（唯一实现，本测试只消费它的结果，不复制公式）：
    路程 = 步骤间直线距离之和 × 1.4（近似绕路）/ 15 m/s + 交互时长 + 25 s 固定开销

这条闸门一次断言三件事，且**自己构造坏形状**（所以它不是"存在即正确"的静态断言）：
  1. 受闸任务（平民的可重复任务）$/h 都在 1,400–2,800 ±400 之内；
  2. `hotdog_vendor` 按**实测** 0.9 分钟也在带内（估算 0.6 分钟是零路程的理想值）；
  3. 喂一个 1.4 km / $5,000–8,000 的模板进去，估算器必须判越界。
"""

from __future__ import annotations

import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
REPO = BASE.parent
sys.path.insert(0, str(REPO / "tools/dev"))

import quest_econ  # noqa: E402  # type: ignore[reportMissingImports]

#: 真机实测时长（分钟）：hotdog_vendor，2026-11-14
MEASURED_MINUTES = {"hotdog_vendor": 0.9}

#: 本轮必须受闸的存量 7 条旧壳（R1 决定书：与新路线同档）
SHELLS = {"hotdog_vendor", "taxi_fare", "bus_route", "tow_service",
          "garbage_collection", "recycle_run", "news_report"}

BAND_LO = quest_econ.BAND_LOW - quest_econ.BAND_TOLERANCE
BAND_HI = quest_econ.BAND_HIGH + quest_econ.BAND_TOLERANCE

BAD_SHAPE = """
id = 'overpaid_probe',
category = 'civilian',
rewards = { money = { type = 'cash', min = 5000, max = 8000 } },
steps = { { id = 'step_a', coords = { x = 100.0, y = 200.0, z = 30.0 } },
          { id = 'step_b', coords = { x = 400.0, y = 200.0, z = 30.0 } } }
"""


def _rows() -> dict[str, quest_econ.QuestEcon]:
    return {row.name: row for row in quest_econ.all_quests()}


def _overpaid_on_bad_shapes() -> quest_econ.QuestEcon:
    """把"1 分钟给 $5,000–8,000"的形状喂给估算器，它必须看得见并判越界。"""
    row = quest_econ.measure("overpaid_probe", "probe.lua", BAD_SHAPE)
    assert row is not None, "估算器看不见这段配置，它就证明不了任何东西"
    assert quest_econ.is_gated(row), "civilian 可重复任务必须默认受闸"
    assert row.minutes < 2, "1.4 公里的路程不该估到 2 分钟以上"
    assert row.per_hour_mid > BAND_HI, (
        f"这个形状算出来是 {row.per_hour_mid:.0f} $/h，估算器没把它判成越界")
    return row


def test_quest_economy_band_holds_on_bad_shapes():
    # 规则本身先被证明：坏形状必须判红
    _overpaid_on_bad_shapes()

    rows = _rows()
    gated = {name: row for name, row in rows.items() if quest_econ.is_gated(row)}

    # 7 条旧壳一个都不能漏（改名/换 category 会让闸门静默失效）
    missing = SHELLS - set(gated)
    assert not missing, f"这些旧壳没进闸门（改名或换了 category？）：{sorted(missing)}"

    out = {n: round(r.per_hour_mid) for n, r in gated.items()
           if not BAND_LO <= r.per_hour_mid <= BAND_HI}
    assert not out, f"这些任务的估算收益越出 {BAND_LO:.0f}–{BAND_HI:.0f} $/h：{out}"

    # 估算按零路程算，实测必然更慢：用实测值复算一遍 hotdog
    hotdog = rows["hotdog_vendor"]
    measured = (hotdog.money_min + hotdog.money_max) / 2 / MEASURED_MINUTES["hotdog_vendor"] * 60
    assert BAND_LO <= measured <= BAND_HI, (
        f"按实测 {MEASURED_MINUTES['hotdog_vendor']} 分钟算是 {measured:.0f} $/h，"
        f"价格 ${hotdog.money_min}-${hotdog.money_max} 偏高")

    # 一次性剧情章节（story_arc）一轮只能玩一遍，$50,000 的大额奖励不是印钞机
    story = [r for r in rows.values() if r.once]
    assert story, "没有识别出任何一次性模板 —— story_arc 标记可能改名了"
    assert not [r for r in story if quest_econ.is_gated(r)], "一次性剧情章节不该受 $/h 闸门约束"
