#!/usr/bin/env python3
"""文档断链报告（不阻断）：区分**活跃层**与**历史归档**。

闸门 ``tests/architecture/test_docs_links.py`` 要求全仓活跃文档零断链；唯一例外是带
``LEGACY.md`` 且登记在 ``tests/architecture/legacy_docs.json`` 的历史归档目录。
那个目录里的路径反映的是当时的状态，不修是有意的（改了就伪造历史）。

所以这个报告必须把两类分开算，否则"414 处断链"这种数字会让人误以为闸门失守。

用法::

    python3 tools/dev/docs_links_report.py                 # 汇总 + top 15 文件
    python3 tools/dev/docs_links_report.py --file docs/README.md
    python3 tools/dev/docs_links_report.py --limit 50 --json

判据与闸门一致：反引号里的、带路径分隔符的、看起来像文件的 token；
跳过 URL、命令、通配、模板占位（``<x>`` / ``{a,b}`` / ``[name]``）。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
IGNORED_DIRS = {"node_modules", ".git", "alpine", "txData", "cache", ".venv"}

PATH_TOKEN = re.compile(r"`([^`\s]+)`")
PATH_SUFFIXES = (".md", ".lua", ".py", ".json", ".sql", ".ts", ".svelte", ".cfg", ".sh", ".mjs", ".js", ".html")
SKIP_CHARS = set("{}*<>|$…\u3000")
PLACEHOLDERS = ("[name]", "[hash]", "[res]", "[area]", "[slug]", "[topic]", "[date]", "[x]")


def looks_like_path(token: str) -> bool:
    if any(ch in token for ch in SKIP_CHARS):
        return False
    if any(ph in token for ph in PLACEHOLDERS) or "/" not in token:
        return False
    if token.startswith(("http", "www", "~", "/dev", "/tmp", "/etc")):
        return False
    if " " in token or token.startswith("-"):
        return False
    return token.endswith(PATH_SUFFIXES)


def resolve(token: str, doc: Path) -> bool:
    token = token.split("::")[0].split("#")[0]
    for root in (REPO, BASE, doc.parent, REPO / "docs"):
        if (root / token).exists():
            return True
    return False


def broken(text: str, doc: Path) -> list[str]:
    return sorted({t for t in (m.group(1) for m in PATH_TOKEN.finditer(text))
                   if looks_like_path(t) and not resolve(t, doc)})


def scan(paths: list[Path]) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for doc in paths:
        try:
            text = doc.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        hits = broken(text, doc)
        if hits:
            out[str(doc.relative_to(REPO))] = hits
    return out


def legacy_dirs() -> set[Path]:
    registry = Path(__file__).resolve().parent.parent.parent / "T-CityLite.base" / "tests" / "architecture" / "legacy_docs.json"
    if not registry.is_file():
        return set()
    data = json.loads(registry.read_text(encoding="utf-8"))
    return {REPO / rel for rel in data.get("dirs", {})}


def is_legacy(path: Path, dirs: set[Path]) -> bool:
    return any(path == d or d in path.parents for d in dirs)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--file", action="append", help="只检查指定文件（可重复）")
    ap.add_argument("--limit", type=int, default=15, help="列出前 N 个文件")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if args.file:
        targets = [REPO / f for f in args.file]
    else:
        targets = [p for p in REPO.rglob("*.md")
                   if p.is_file() and not (IGNORED_DIRS & set(p.parts))]

    result = scan(targets)
    dirs = legacy_dirs()
    active = {k: v for k, v in result.items() if not is_legacy(REPO / k, dirs)}
    legacy = {k: v for k, v in result.items() if is_legacy(REPO / k, dirs)}
    total = sum(len(v) for v in active.values())
    counts = Counter({k: len(v) for k, v in active.items()})

    if args.json:
        print(json.dumps({
            "files": len(targets),
            "broken": total,
            "detail": active,
            "legacy_broken": sum(len(v) for v in legacy.values()),
            "legacy_files": len(legacy),
        }, ensure_ascii=False, indent=2))
        return 0

    print(f"[docs_links_report] 检查 {len(targets)} 份文档")
    print(f"  活跃层: 断链 {total} 处 / {len(active)} 个文件  ← 闸门要求为 0")
    print(f"  历史归档: 断链 {sum(len(v) for v in legacy.values())} 处 / {len(legacy)} 个文件  ← 已登记豁免，不修")
    for path, hits in counts.most_common(args.limit):
        print(f"\n{path}  ({hits} 处)")
        for token in result[path][:5]:
            print(f"    - {token}")
        if hits > 5:
            print(f"    …还有 {hits - 5} 处")
    if total:
        print("\n（仅报告，不阻断。修法：指向新位置；文件已删除就改成不带反引号的叙述；"
              "确实是历史文档就移进已登记的归档目录。）")
    else:
        print("\n（活跃层已零断链。）")
    return 0


if __name__ == "__main__":
    try:
        code = main())
    except BrokenPipeError:      # `| head` 之类的下游提前关闭
        code = 0
    sys.exit(code)
