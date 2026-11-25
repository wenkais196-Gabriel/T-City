#!/usr/bin/env python3
"""菜单系统取证扫描 —— 产出可棘轮的基线（counts + 资源分布 + 行号样本）。

这是**取证**工具，不是闸门。用途：
  1. 排期前量出真实改动面（「有几处」而不是「大概几处」）；
  2. M1–M7 每落地一片，基线该变小；M7 的架构闸门拿它当棘轮。

用法::

    python3 tools/dev/menu_surface_census.py                      # 只打印表格
    python3 tools/dev/menu_surface_census.py --json <out.json>     # 落基线
    python3 tools/dev/menu_surface_census.py --json T-CityLite.base/tests/architecture/menu_surface_baseline.json

口径说明（容易吵架的地方）：
  * 只扫源码扩展名，跳过 node_modules / dist / build / cache；
  * `backdrop_filter` / `cdn_ref` 会命中第三方 vendor（如 [system]/monitor 的打包 CSS/JS），
    这些在排期里应显式排除，而不是当成待修缺陷；
  * 计数是**出现次数**，不是文件数（同一文件多处会累计）。
"""
from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
RES = BASE / "resources"
TEXT_EXT = {".lua", ".js", ".ts", ".html", ".css", ".scss", ".svelte", ".vue"}
SKIP_DIRS = {"node_modules", ".git", "dist", "build", "cache"}

CATEGORIES = {
    "setnui_focus": (re.compile(r"\bSetNuiFocus(?:KeepInput)?\s*\("), {".lua"}),
    "setnui_single_arg": (re.compile(r"\bSetNuiFocus\s*\(\s*(?:false|true)\s*\)"), {".lua"}),
    "isnuifocused_read": (re.compile(r"\bIsNuiFocus(?:ed|KeepingInput)\s*\("), {".lua"}),
    "disable_all_controls": (re.compile(r"\bDisableAllControlActions\s*\("), {".lua"}),
    "backdrop_filter": (re.compile(r"backdrop-filter"), TEXT_EXT),
    "cdn_ref": (re.compile(r"https?://(?!localhost|127\.0\.0\.1)[a-z0-9.-]+", re.I), {".html", ".css", ".js"}),
    "qb_menu_entry": (re.compile(r"\b(?:openMenu|showHeader|closeMenu)\b"), {".lua"}),
    "qb_input_entry": (re.compile(r"\bShowInput\b"), {".lua"}),
    "menuv_entry": (re.compile(r"\bMenuV\s*[:.](?:CreateMenu|OpenMenu|RegisterKey)\b"), {".lua"}),
    "customui_entry": (re.compile(r"exports\s*\[\s*'custom-ui'\s*\]\s*:\s*(?:Push|OpenMenu|Pop|CloseMenu)"), {".lua"}),
    "orgmenu_export": (re.compile(r"\bAdd(?:Org|Boss|Gang)MenuItem\b"), {".lua"}),
    "client_wait_zero": (re.compile(r"\bWait\s*\(\s*0\s*\)"), {".lua"}),
}


def resource_of(path: Path) -> str:
    try:
        parts = path.relative_to(RES).parts
    except ValueError:
        return "?"
    if not parts:
        return "?"
    return parts[1] if len(parts) > 1 else parts[0]


def scan() -> dict:
    out: dict[str, dict] = {}
    for name, (pattern, exts) in CATEGORIES.items():
        files: dict[str, int] = defaultdict(int)
        samples: list[str] = []
        for path in RES.rglob("*"):
            if not path.is_file() or path.suffix not in exts:
                continue
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            hits = 0
            for line_no, raw in enumerate(text.splitlines(), 1):
                if pattern.search(raw):
                    hits += 1
                    if len(samples) < 12 and not raw.lstrip().startswith("--"):
                        samples.append(f"{path.relative_to(BASE).as_posix()}:{line_no}")
            if hits:
                files[resource_of(path)] += hits
        out[name] = {
            "total": sum(files.values()),
            "resources": dict(sorted(files.items(), key=lambda kv: -kv[1])),
            "samples": sorted(samples),
        }
    return out


def to_md(data: dict) -> str:
    rows = ["| 类别 | 命中数 | 涉及资源数 | 主要资源（命中数） |", "|---|---|---|---|"]
    for name, d in data.items():
        top = ", ".join(f"{k} {v}" for k, v in list(d["resources"].items())[:3])
        rows.append(f"| `{name}` | {d['total']} | {len(d['resources'])} | {top or '—'} |")
    return "\n".join(rows)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default="")
    args = ap.parse_args()
    data = scan()
    if args.json:
        target = Path(args.json)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(to_md(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
