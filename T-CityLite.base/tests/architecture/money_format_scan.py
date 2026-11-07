"""扫描「金额格式化用 %d」—— `$` 与 `%d` 同串的字面量。

为什么：`('$%d'):format(0.5)` 在 Lua 5.4 直接抛
`bad argument #1 to 'format' (number has no integer representation)`。
真机现象（2026-11-01）：`givemoney 1 cash 0.5` 连跑 10 次全部抛错 —— 而
`EconomyService.AddMoney` 的顺序是「写内存 → 更新客户端 → 事件 → 写审计」，
所以钱已经进账、审计没写、调用方还收到错误（有人加 pcall 回落就是双倍入账）。

判据刻意保守：**只认 `$` 与 `%d` 出现在同一个字符串字面量里**。
计数/ID/时间戳的 `%d`、以及 `$%s` 已经正确的写法都不算。
税、佣金、乘算奖励这类必然带小数的金额，全部落在这一形态里。
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]          # T-CityLite.base/
RESOURCES = BASE / "resources"
BASELINE = Path(__file__).resolve().parent / "money_format_baseline.json"

PERCENT_D = re.compile(r"%[-+0-9.]*d")


@dataclass(frozen=True)
class Site:
    file: str
    text: str          # 字面量原文（含引号），用于指纹


def _literals(text: str):
    """产出 (start_index, literal_text)，跳过注释。"""
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "-" and text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue
        if ch in "'\"":
            quote = ch
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == quote:
                    break
                j += 1
            yield i, text[i : j + 1]
            i = j + 1
            continue
        if text.startswith("[[", i):
            j = text.find("]]", i)
            j = n if j == -1 else j + 2
            yield i, text[i:j]
            i = j
            continue
        i += 1


def scan_text(text: str, rel: str = "<inline>") -> list[Site]:
    sites: list[Site] = []
    for index, literal in _literals(text):
        if "$" not in literal:
            continue
        if not PERCENT_D.search(literal):
            continue
        # 行首是注释的（`-- '$%d'`）跳过
        line_start = text.rfind("\n", 0, index) + 1
        prefix = text[line_start:index].strip()
        if prefix.startswith("--"):
            continue
        sites.append(Site(rel, literal))
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
            "金额格式化债：`$` 与 `%d` 同串的字面量基线。只允许减少，不允许增加；"
            "修好一处就从这里删一条（双向相等，删多了也会红）。"
        ),
        "owner": "hermes",
        "expires": "2027-03-31",
        "total": sum(counts.values()),
        "entries": dict(sorted(counts.items())),
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return payload["total"]


if __name__ == "__main__":  # pragma: no cover - 手工用
    total = write_baseline()
    print(f"wrote {BASELINE.name}: {total} 处")
