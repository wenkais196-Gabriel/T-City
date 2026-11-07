"""扫描「金额格式化用 %d」—— `$` 紧跟 `%d` 的字面量。

为什么：`('$%d'):format(0.5)` 在 Lua 5.4 直接抛
`bad argument #1 to 'format' (number has no integer representation)`。
真机现象（2026-11-01）：`givemoney 1 cash 0.5` 连跑 10 次全部抛错 —— 而
`EconomyService.AddMoney` 的顺序是「写内存 → 更新客户端 → 事件 → 写审计」，
所以钱已经进账、审计没写、调用方还收到错误（有人加 pcall 回落就是双倍入账）。

判据刻意保守：**只认 `$` 紧跟 `%d`**（`$%d` / `$%5d`）。
反例（不算）：`%.d` 这种「字面点 + d」、`%.2f`、前面不是 `$` 的计数/ID。
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

import lua_source

BASE = Path(__file__).resolve().parents[2]          # T-CityLite.base/
RESOURCES = BASE / "resources"
BASELINE = Path(__file__).resolve().parent / "money_format_baseline.json"

MONEY_PERCENT_D = re.compile(r"\$%[-+ 0-9]*d")


@dataclass(frozen=True)
class Site:
    file: str
    text: str          # 字面量原文（含引号），用于指纹


def scan_text(source: str, rel: str = "<inline>") -> list[Site]:
    sites: list[Site] = []
    for item in lua_source.literals(source):
        if not MONEY_PERCENT_D.search(item.text):
            continue
        line_start = source.rfind("\n", 0, item.start) + 1
        if source[line_start:item.start].strip().startswith("--"):
            continue
        sites.append(Site(rel, item.text))
    return sites


def scan_repo() -> list[Site]:
    sites: list[Site] = []
    for path in sorted(RESOURCES.rglob("*.lua")):
        if "node_modules" in path.parts:
            continue
        rel = path.relative_to(RESOURCES).as_posix()
        sites.extend(scan_text(path.read_text(encoding="utf-8", errors="ignore"), rel))
    return sites


def as_multiset(sites: list[Site]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for site in sites:
        key = f"{site.file}\u0000{site.text}"
        counts[key] = counts.get(key, 0) + 1
    return counts


def write_baseline(path: Path = BASELINE) -> int:
    counts = as_multiset(scan_repo())
    payload = {
        "$comment": (
            "金额格式化债：`$` 紧跟 `%d` 的字面量基线。只允许减少，不允许增加；"
            "修好一处就同步删一条（双向相等，删多了也会红）。"
        ),
        "owner": "hermes",
        "expires": "2027-03-31",
        "total": sum(counts.values()),
        "entries": dict(sorted(counts.items())),
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return payload["total"]


def check() -> tuple[int, int]:
    """返回 (当前命中数, 基线总数) —— 只读，不改文件。"""
    current = sum(as_multiset(scan_repo()).values())
    if not BASELINE.exists():
        return current, 0
    return current, int(json.loads(BASELINE.read_text(encoding="utf-8")).get("total", 0))


if __name__ == "__main__":  # pragma: no cover - 手工用
    import sys

    if "--write" in sys.argv:
        print(f"wrote {BASELINE.name}: {write_baseline()} 处")
    else:
        current, baseline_total = check()
        print(f"当前 {current} 处 / 基线 {baseline_total} 处（只读；要重写基线请加 --write）")
        raise SystemExit(0 if current == baseline_total else 1)
