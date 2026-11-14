#!/usr/bin/env python3
"""任务收益的离线估算：把「配置里的价」换算成「每小时能挣多少」。

为什么需要：`04-numbers.md` 的目标带（1,400–2,800 $/h）要靠三项相乘才对得上 ——
站数、单站耗时、单次收益。前两项以前是估的，于是旧壳（taxi / bus_route / tow /
garbage_collection / hotdog / news_report / recycle）一直停在 $150–800/次，
按 1–2 分钟的实测时长折算就是 **11,000–30,000 $/h**，比新路线高一个数量级。

估算口径（故意保守，宁可估长不估短）：
    travel_s   = 各步骤之间的**直线距离之和** × ROAD_FACTOR / SPEED_MPS
                 （直线距离一定短于实际路线，所以乘 1.4 近似绕路）
    interact_s = 配置里所有 `duration`（毫秒）之和
    overhead_s = 接单 + 结算 + 上下车的固定开销
    hours      = (travel_s + interact_s + overhead_s) / 3600

校准点（2026-11-14 真机）：`hotdog_vendor` 在同一地点连做 4 步，实测 **0.9 分钟**
（估算 0.6 分钟 = 12 s 交互 + 25 s 开销，差异是玩家操作/对话时间）。

用法：
    python tools/dev/quest_econ.py --list           # 所有任务：估算时长、$/h
    python tools/dev/quest_econ.py --check          # 越出目标带就非零退出（可进 CI）
"""

from __future__ import annotations

import argparse
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
QUESTS_DIR = REPO / "T-CityLite.base/resources/[custom]/custom-quest/config/quests"

# 物流任务的目的地在 destCoords（不是 coords）；漏掉它的话距离会少算一个数量级
COORD_RE = re.compile(
    r"(?:dest|return)?[cC]oords\s*=\s*\{\s*x\s*=\s*(-?[\d.]+)\s*,\s*y\s*=\s*(-?[\d.]+)\s*,\s*z\s*=\s*(-?[\d.]+)"
)
REWARD_RE = re.compile(
    r"money\s*=\s*\{\s*type\s*=\s*'(\w+)'\s*,\s*min\s*=\s*(\d+)\s*,\s*max\s*=\s*(\d+)"
)
DURATION_RE = re.compile(r"duration\s*=\s*(\d+)")
ID_RE = re.compile(r"id\s*=\s*'([a-z0-9_]+)'")

#: 直线距离 → 实际路线的经验倍数
ROAD_FACTOR = 1.4
#: 城市平均车速（m/s）：54 km/h
SPEED_MPS = 15.0
#: 接单 / 结算 / 上下车的固定开销
OVERHEAD_S = 25.0
#: 目标带（$ / 小时），见 docs/plan/jobs-content/02-design.md §2
BAND_LOW = 1400.0
BAND_HIGH = 2800.0
#: 判定时允许的余量（估算本身有 ±20% 误差）
BAND_TOLERANCE = 400.0

#: 飞行类：时长由航线决定，不按地面速度估
FLIGHT_HINTS = ("aviation", "pilot", "flight", "airlift")
#: 一次性内容不算 $/h：剧情章节一轮只能玩一遍（conditions.story_arc），执照考试也是
ONCE_MARKER = "story_arc"
#: 受闸口径：**平民（civilian）的可重复任务**必须落在目标带里。
#: 犯罪 / 物流 / 采矿 / 警察的价位是另一轮决策（风险溢价、资本成本不同），先只计入报表。
GATED_CATEGORY = "civilian"
CATEGORY_RE = re.compile(r"category\s*=\s*'([a-z_]+)'")
#: 采矿链（miner_apprentice / miner_mid / miner_boss）虽是 civilian，但它的时长取决于
#: 挖矿与出售的实际交互（配置里没有 duration），估算器看不见这段时间 —— 强行判会冤枉它。
#: 采矿另开一轮估值，和犯罪/物流一起决策。
EXEMPT_PREFIX = ("miner_",)

@dataclass
class QuestEcon:
    name: str
    file: str
    points: int
    distance_m: float
    interact_s: float
    minutes: float
    money_min: int
    money_max: int
    category: str = ""
    once: bool = False

    @property
    def per_hour_mid(self) -> float:
        if self.minutes <= 0:
            return 0.0
        return ((self.money_min + self.money_max) / 2) / self.minutes * 60


def template_blocks(text: str) -> dict[str, str]:
    """按花括号配对切出每个模板（与 quest_map.py 同法，避免跨模板串味）。"""
    out: dict[str, str] = {}
    for match in ID_RE.finditer(text):
        name = match.group(1)
        if name.startswith("step_"):
            continue
        open_at = text.rindex("{", 0, match.start())
        depth = 0
        for pos in range(open_at, len(text)):
            if text[pos] == "{":
                depth += 1
            elif text[pos] == "}":
                depth -= 1
                if depth == 0:
                    out.setdefault(name, text[open_at:pos + 1])
                    break
    return out


def measure(name: str, filename: str, block: str) -> QuestEcon | None:
    points = [(float(x), float(y)) for x, y, _ in COORD_RE.findall(block)]
    reward = REWARD_RE.search(block)
    # 少于 2 个坐标就量不出路程（矿工/洗衣这类是运行时用变量拼步骤的），
    # 强行按 0 距离算会把它们全判成"印钞"——那不是事实，是估算器看不见。
    if len(points) < 2 or not reward:
        return None
    distance = sum(math.dist(points[i], points[i + 1]) for i in range(len(points) - 1))
    interact_s = sum(int(d) for d in DURATION_RE.findall(block)) / 1000.0
    seconds = distance * ROAD_FACTOR / SPEED_MPS + interact_s + OVERHEAD_S
    once = ONCE_MARKER in block or "license" in name or "exam" in name
    cat = CATEGORY_RE.search(block)
    return QuestEcon(
        name=name, file=filename, points=len(points),
        distance_m=distance * ROAD_FACTOR, interact_s=interact_s,
        minutes=seconds / 60.0,
        money_min=int(reward.group(2)), money_max=int(reward.group(3)),
        category=cat.group(1) if cat else "",
        once=once,
    )


def all_quests() -> list[QuestEcon]:
    out: list[QuestEcon] = []
    for cfg in sorted(QUESTS_DIR.rglob("*.lua")):
        text = cfg.read_text(encoding="utf-8", errors="replace")
        for name, block in template_blocks(text).items():
            row = measure(name, cfg.name, block)
            if row:
                out.append(row)
    return out


def is_flight(name: str) -> bool:
    return any(hint in name for hint in FLIGHT_HINTS)


def is_gated(row: "QuestEcon") -> bool:
    """平民的可重复任务受闸；一次性剧情章节与飞行类不算 $/h。"""
    if row.name.startswith(EXEMPT_PREFIX):
        return False
    return row.category == GATED_CATEGORY and not row.once and not is_flight(row.name)


def main() -> int:
    ap = argparse.ArgumentParser(description="任务收益估算（$/h）")
    ap.add_argument("--list", action="store_true", help="列出所有任务")
    ap.add_argument("--check", action="store_true", help="越出目标带就非零退出")
    args = ap.parse_args()

    rows = all_quests()
    rows.sort(key=lambda r: -r.per_hour_mid)
    if args.list or not args.check:
        print(f"{'任务':<28}{'点':>3}{'路程m':>7}{'交互s':>6}{'估时min':>9}"
              f"{'价格':>13}{'$/h':>8}  判定")
        for row in rows:
            in_band = BAND_LOW - BAND_TOLERANCE <= row.per_hour_mid <= BAND_HIGH + BAND_TOLERANCE
            if row.once:
                verdict = "一次性"
            elif is_flight(row.name):
                verdict = "飞行类"
            elif is_gated(row):
                verdict = "OK" if in_band else "越界"
            else:
                verdict = "待决策" if not in_band else "OK"
            print(f"{row.name:<28}{row.points:>3}{row.distance_m:>7.0f}{row.interact_s:>6.0f}"
                  f"{row.minutes:>9.1f}{f'${row.money_min}-{row.money_max}':>13}"
                  f"{row.per_hour_mid:>8.0f}  {verdict}")

    if args.check:
        bad = [r for r in rows
               if is_gated(r)
               and not (BAND_LOW - BAND_TOLERANCE <= r.per_hour_mid <= BAND_HIGH + BAND_TOLERANCE)]
        wait = [r for r in rows
                if not is_gated(r) and not r.once and not is_flight(r.name)
                and not (BAND_LOW - BAND_TOLERANCE <= r.per_hour_mid <= BAND_HIGH + BAND_TOLERANCE)]
        if wait:
            print(f"\n另有 {len(wait)} 个非本轮任务越带（犯罪/采矿/物流，价位待决策）："
                  + ", ".join(f"{r.name} {r.per_hour_mid:.0f}$/h" for r in wait[:6]) + " …")
        if bad:
            print("\n越出目标带的任务（估算 $/h 不在 "
                  f"{BAND_LOW:.0f}–{BAND_HIGH:.0f} ±{BAND_TOLERANCE:.0f}）：", file=sys.stderr)
            for row in bad:
                print(f"  {row.name}: ${row.money_min}-{row.money_max} / {row.minutes:.1f} min "
                      f"= {row.per_hour_mid:.0f} $/h", file=sys.stderr)
            return 1
        print(f"\n受闸任务全部在目标带内（{BAND_LOW:.0f}–{BAND_HIGH:.0f} ±{BAND_TOLERANCE:.0f} $/h）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
