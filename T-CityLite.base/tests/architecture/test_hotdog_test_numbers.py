"""热狗模板的「测试期占位数值」必须自洽。

为什么单开一条：这些数字是**临时**的（正式值等经济系统联动，见
docs/plan/jobs-content/13-hotdog-remaining-plan.md 的 E 片）。临时数字最容易在改的时候
只改一半——押金调到 50 却忘了把 max_minutes 从 60 降下来，玩家做完一轮就发现押金早被扣穿。
所以把"能算出来的约束"钉死，让下一次改数值时闸门先说话。

真加载模板表（lua5.4），不靠正则猜：
    deposit >= max_minutes × rate_per_min   （满时长也扣不穿押金）
    grace_sec < max_minutes × 60            （免租期不能长过整个计费期）
    common < rare < exotic，且都是偶数        （成品回收按 0.5 折价，避免出现 $7.5）
    0 < first_customer_ms[0] <= first_customer_ms[1] < interval_ms[1]
    0 < patience_ms，三档起始库存 >= 0
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[2]
REPO = BASE.parent
CONFIG = BASE / "resources/[custom]/custom-quest/config/quests/quest_hotdog.lua"

LUA = shutil.which("lua5.4.exe") or shutil.which("lua5.4")

PROBE = Path(__file__).with_name("fixtures") / "hotdog_numbers_probe.lua"

#: 探针输出顺序（与 fixture 里 table.concat 的顺序一一对应）
KEYS = ["deposit", "rate_per_min", "grace_sec", "max_minutes",
        "price_common", "price_rare", "price_exotic",
        "first_lo", "first_hi", "interval_lo", "interval_hi", "patience_ms",
        "stock_common", "stock_rare", "stock_exotic"]


def load_numbers(path: Path = CONFIG) -> dict[str, float]:
    """真跑模板表（fixture 探针），返回 15 个数值。"""
    assert LUA, "需要 lua5.4 / lua5.4.exe"
    proc = subprocess.run([LUA, str(PROBE), str(path)],
                          capture_output=True, encoding="utf-8", errors="replace",
                          timeout=60, stdin=subprocess.DEVNULL)
    assert proc.returncode == 0, f"{proc.stdout}\n{proc.stderr}"
    values = [float(x) for x in proc.stdout.split()]
    assert len(values) == len(KEYS), f"探针输出 {len(values)} 个数，期望 {len(KEYS)}：{proc.stdout!r}"
    return dict(zip(KEYS, values))


def check(numbers: dict[str, float]) -> list[str]:
    """把不变量写成纯函数，反向用例好复用。"""
    problems: list[str] = []
    deposit_min = numbers["max_minutes"] * numbers["rate_per_min"]
    if numbers["deposit"] < deposit_min:
        problems.append(f"押金 {numbers['deposit']:.0f} < 满时长租金 {deposit_min:.0f}"
                        f"（max_minutes {numbers['max_minutes']:.0f} × rate {numbers['rate_per_min']:.0f}）")
    if numbers["grace_sec"] >= numbers["max_minutes"] * 60:
        problems.append(f"免租 {numbers['grace_sec']:.0f}s 不短于计费期 {numbers['max_minutes'] * 60:.0f}s")
    prices = [numbers["price_common"], numbers["price_rare"], numbers["price_exotic"]]
    if not prices[0] < prices[1] < prices[2]:
        problems.append(f"单价没有递增：{prices}")
    odd = [p for p in prices if p % 2 != 0]
    if odd:
        problems.append(f"单价必须是偶数（回收按 0.5 折价），这些是奇数：{odd}")
    if not 0 < numbers["first_lo"] <= numbers["first_hi"] < numbers["interval_hi"]:
        problems.append(f"顾客节奏不自洽：第一位 {numbers['first_lo']:.0f}–{numbers['first_hi']:.0f}ms，"
                        f"间隔上界 {numbers['interval_hi']:.0f}ms")
    if numbers["patience_ms"] <= 0:
        problems.append("耐心时间必须为正")
    stocks = [numbers["stock_common"], numbers["stock_rare"], numbers["stock_exotic"]]
    if any(s < 0 for s in stocks):
        problems.append(f"起始库存不能为负：{stocks}")
    return problems


def test_hotdog_test_numbers_are_self_consistent():
    problems = check(load_numbers())
    assert not problems, "热狗模板的数值不自洽（改数值时请一起算一遍）：\n  " + "\n  ".join(problems)


def test_rule_catches_a_deposit_that_runs_out():
    """反向控制：押金撑不满计费期必须被抓住。"""
    numbers = load_numbers()
    numbers["deposit"] = numbers["max_minutes"] * numbers["rate_per_min"] - 1
    problems = check(numbers)
    assert any("押金" in problem for problem in problems), problems


def test_rule_catches_fractional_recycle_prices():
    """反向控制：单价是奇数 -> 回收价会出小数，必须被抓住。"""
    numbers = load_numbers()
    numbers["price_rare"] = numbers["price_common"] + 1
    problems = check(numbers)
    assert any("偶数" in problem for problem in problems), problems
