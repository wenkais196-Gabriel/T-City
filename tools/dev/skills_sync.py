#!/usr/bin/env python3
"""把仓库里的技能同步到 Hermes 的技能目录（或反过来），并检查两边是否漂移。

为什么技能要进仓库：技能是"这个项目怎么做"的程序性知识（坑、流程、命令）。
它原本只活在 `~/.hermes/skills/` 里——不在 CI 里、不在 code review 里、换台机器就没了，
而它描述的正是这台机器上的服务器。

方向约定：**仓库是准的**（`.agents/skills/`），Hermes 那份是安装出来的副本。

用法::

    python3 tools/dev/skills_sync.py --to-hermes     # 仓库 → ~/.hermes/skills
    python3 tools/dev/skills_sync.py --from-hermes   # ~/.hermes/skills → 仓库（本地改完往上收）
    python3 tools/dev/skills_sync.py --check         # 只比对，退出码 1 = 有漂移

退出码：0 一致 / 已同步；1 有漂移（--check）；2 环境问题。
"""

from __future__ import annotations

import argparse
import filecmp
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
REPO_SKILLS = REPO / ".agents" / "skills"
#: Hermes 的技能根目录；测试用 HERMES_SKILLS_DIR 指向临时目录来构造漂移。
import os

HERMES_SKILLS = Path(os.environ.get("HERMES_SKILLS_DIR", Path.home() / ".hermes" / "skills"))

#: 仓库里的技能落在 Hermes 的哪个分类下（None = 直接放根）
CATEGORY = {"fivem-resource-development": "software-development"}

IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc")


def hermes_target(name: str) -> Path:
    category = CATEGORY.get(name)
    return HERMES_SKILLS / category / name if category else HERMES_SKILLS / name


def skill_names() -> list[str]:
    if not REPO_SKILLS.is_dir():
        return []
    return sorted(p.name for p in REPO_SKILLS.iterdir() if (p / "SKILL.md").is_file())


def diff_tree(left: Path, right: Path) -> list[str]:
    """返回两边不一致的相对路径（缺文件、内容不同、多文件）。"""
    problems: list[str] = []
    if not left.is_dir() or not right.is_dir():
        return [f"目录缺失: {left if not left.is_dir() else right}"]
    left_files = {p.relative_to(left) for p in left.rglob("*") if p.is_file() and "__pycache__" not in p.parts}
    right_files = {p.relative_to(right) for p in right.rglob("*") if p.is_file() and "__pycache__" not in p.parts}
    for missing in sorted(right_files - left_files):
        problems.append(f"仓库缺: {missing}")
    for extra in sorted(left_files - right_files):
        problems.append(f"Hermes 缺: {extra}")
    for rel in sorted(left_files & right_files):
        if not filecmp.cmp(left / rel, right / rel, shallow=False):
            problems.append(f"内容不同: {rel}")
    return problems


def sync(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src, dst, ignore=IGNORE)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--to-hermes", action="store_true", help="仓库 → Hermes（安装）")
    mode.add_argument("--from-hermes", action="store_true", help="Hermes → 仓库（回收本地修改）")
    mode.add_argument("--check", action="store_true", help="只比对，漂移则退出码 1")
    args = ap.parse_args(argv[1:])

    names = skill_names()
    if not names:
        print(f"仓库里没有技能（{REPO_SKILLS}）", file=sys.stderr)
        return 2

    drifted = 0
    for name in names:
        repo_copy = REPO_SKILLS / name
        hermes_copy = hermes_target(name)
        if args.check:
            problems = diff_tree(repo_copy, hermes_copy)
            if problems:
                drifted += 1
                print(f"[drift] {name}（{hermes_copy}）")
                for line in problems[:10]:
                    print(f"    {line}")
                if len(problems) > 10:
                    print(f"    …还有 {len(problems) - 10} 处")
            else:
                print(f"[ok]    {name}")
        elif args.to_hermes:
            sync(repo_copy, hermes_copy)
            print(f"[install] {name} → {hermes_copy}")
        else:
            sync(hermes_copy, repo_copy)
            print(f"[collect] {name} ← {hermes_copy}")

    if args.check and drifted:
        print(f"\n{drifted} 个技能有漂移。仓库是准的：改完跑 --to-hermes；"
              f"如果是你在 Hermes 那边改的，跑 --from-hermes 收回仓库。")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
