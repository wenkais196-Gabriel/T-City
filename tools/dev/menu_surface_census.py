#!/usr/bin/env python3
"""菜单系统取证扫描 —— 产出可棘轮的基线（counts + 资源分布 + 行号样本）。

这是**取证**工具，不是闸门。用途：
  1. 排期前量出真实改动面（「有几处」而不是「大概几处」）；
  2. M1–M7 每落地一片，基线该变小；M7 的架构闸门拿它当棘轮。

用法::

    python3 tools/dev/menu_surface_census.py                 # 只打印表格
    python3 tools/dev/menu_surface_census.py --json T-CityLite.base/tests/architecture/menu_surface_baseline.json

口径说明（容易吵架的地方）：
  * 只扫源码扩展名，跳过 node_modules / dist / build / cache；
  * `backdrop_filter` / `cdn_ref` 会命中第三方 vendor（如 [system]/monitor 的打包 CSS/JS），
    这些在排期里应显式排除，而不是当成待修缺陷；
  * 计数是**出现次数**，不是文件数（同一文件多处会累计）。

安全：`--json` 只允许写到**仓库内**的 .json 路径（拒绝 `..` 与盘符逃逸），
避免这个工具被当成任意文件写入口。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
RES = BASE / "resources"
TEXT_EXT = {".lua", ".js", ".ts", ".html", ".css", ".scss", ".svelte", ".vue"}
SKIP_DIRS = {"node_modules", ".git", "dist", "build", "cache"}
MAX_SAMPLES = 12

CATEGORIES: dict[str, tuple[re.Pattern[str], set[str]]] = {
    "setnui_focus": (re.compile(r"\bSetNuiFocus(?:KeepInput)?\s*\("), {".lua"}),
    "setnui_single_arg": (re.compile(r"\bSetNuiFocus\s*\(\s*(?:false|true)\s*\)"), {".lua"}),
    "isnuifocused_read": (re.compile(r"\bIsNuiFocus(?:ed|KeepingInput)\s*\("), {".lua"}),
    "disable_all_controls": (re.compile(r"\bDisableAllControlActions\s*\("), {".lua"}),
    "backdrop_filter": (re.compile(r"backdrop-filter"), TEXT_EXT),
    "cdn_ref": (re.compile(r"https?://(?!localhost|127\.0\.0\.1)[a-z0-9.-]+", re.I), {".html", ".css", ".js"}),
    "qb_menu_entry": (re.compile(r"\b(?:openMenu|showHeader|closeMenu)\b"), {".lua"}),
    "qb_input_entry": (re.compile(r"\bShowInput\b"), {".lua"}),
    "menuv_entry": (re.compile(r"\bMenuV\s*[:.](?:CreateMenu|OpenMenu|RegisterKey)\b"), {".lua"}),
    "customui_entry": (re.compile(r"exports\s*\[\s*'custom-ui'\s*\]\s*:\s*(?:Push|OpenMenu|Pop|CloseMenu)"),
                       {".lua"}),
    "orgmenu_export": (re.compile(r"\bAdd(?:Org|Boss|Gang)MenuItem\b"), {".lua"}),
    "client_wait_zero": (re.compile(r"\bWait\s*\(\s*0\s*\)"), {".lua"}),
}


def resource_of(path: Path) -> str:
    """resources/<bracket>/<resource>/... → <resource>；认不出来返回 '?'。"""
    try:
        rel = path.relative_to(RES).as_posix()
    except ValueError:
        return "?"
    segments = rel.split("/")
    if len(segments) >= 2:
        return segments[1]
    return segments[0] if segments else "?"


def source_files(exts: set[str]):
    """遍历资源树里指定扩展名、且不在跳过目录中的文件。"""
    for path in RES.rglob("*"):
        if not path.is_file() or path.suffix not in exts:
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        yield path


def scan_file(path: Path, pattern: re.Pattern[str], samples: list[str]) -> int:
    """返回该文件的命中数，并把前几条非注释样本写进 samples。"""
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return 0
    hits = 0
    for line_no, raw in enumerate(text.splitlines(), 1):
        if not pattern.search(raw):
            continue
        hits += 1
        if len(samples) < MAX_SAMPLES and not raw.lstrip().startswith("--"):
            samples.append(f"{path.relative_to(BASE).as_posix()}:{line_no}")
    return hits


def scan_category(pattern: re.Pattern[str], exts: set[str]) -> dict:
    per_resource: dict[str, int] = defaultdict(int)
    samples: list[str] = []
    for path in source_files(exts):
        hits = scan_file(path, pattern, samples)
        if hits:
            per_resource[resource_of(path)] += hits
    return {
        "total": sum(per_resource.values()),
        "resources": dict(sorted(per_resource.items(), key=lambda kv: -kv[1])),
        "samples": sorted(samples),
    }


def scan() -> dict:
    return {name: scan_category(pattern, exts) for name, (pattern, exts) in CATEGORIES.items()}


def to_md(data: dict) -> str:
    rows = ["| 类别 | 命中数 | 涉及资源数 | 主要资源（命中数） |", "|---|---|---|---|"]
    for name, d in data.items():
        top = ", ".join(f"{k} {v}" for k, v in list(d["resources"].items())[:3])
        rows.append(f"| `{name}` | {d['total']} | {len(d['resources'])} | {top or '—'} |")
    return "\n".join(rows)


def resolve_out(raw: str) -> Path:
    """只允许写到仓库内（拒绝 '..' 逃逸），且必须是 .json。"""
    candidate = Path(raw)
    if not candidate.is_absolute():
        candidate = REPO / candidate
    candidate = candidate.resolve()
    try:
        candidate.relative_to(REPO.resolve())
    except ValueError:
        raise SystemExit(f"拒绝写到仓库外：{raw}") from None
    if candidate.suffix != ".json":
        raise SystemExit(f"输出必须是 .json：{raw}")
    return candidate



def carry_exclusions(data: dict, target: Path) -> None:
    """重新扫描时保留已有基线里的 `excluded` 段（人工维护的排除项，扫不出来）。

    没有这一步，任何人跑一次 `--json` 都会把「monitor 是第三方打包产物，不计入」这条
    人工判断冲掉，闸门随即开始对 monitor 报红 —— 2026-11-26 实际发生过。
    同时按保留了排除项的事实重算 `non_excluded_total`。
    """
    if not target.exists():
        return
    try:
        previous = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return
    for feature, fresh in data.items():
        old_block = previous.get(feature)
        if not isinstance(fresh, dict) or not isinstance(old_block, dict):
            continue
        excluded = old_block.get("excluded")
        if excluded:
            fresh["excluded"] = excluded
            excluded_total = sum(int(item.get("count") or 0) for item in excluded.values())
            fresh["non_excluded_total"] = max(int(fresh.get("total") or 0) - excluded_total, 0)

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default="", help="把基线写到仓库内的 .json 路径")
    args = ap.parse_args()
    data = scan()
    if args.json:
        target = resolve_out(args.json)
        target.parent.mkdir(parents=True, exist_ok=True)
        carry_exclusions(data, target)
        target.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(to_md(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
