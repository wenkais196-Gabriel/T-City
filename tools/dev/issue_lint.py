#!/usr/bin/env python3
"""issue 合规检查 —— 标签齐不齐、标题格式对不对、正文有没有"前序核验"。

为什么不放进 CI：查 issue 要 GitHub API 与 token，而仓库的闸门必须**离线可跑**。
所以这里只吃 `gh issue list --json` 的输出（JSON 文件或 stdin），可以离线、可测、可批量跑。

用法::

    gh issue list --state open --limit 200 --json number,title,labels,body > /tmp/issues.json
    python3 tools/dev/issue_lint.py /tmp/issues.json          # 只看违规
    python3 tools/dev/issue_lint.py /tmp/issues.json --fix-plan   # 打印 gh label 命令（不执行）

判据（缺一条就算违规）：

1. **标签**：必须有 1 个 `type:*`、1 个 `priority:*`、≥1 个 `area:*`；`status:*` 可选。
   `phase:*` 可选（阶段计划里的 issue 建议带上）。
2. **标题**：`<type>(<scope>): <描述>` —— 与 commit 约定同形，scope 是资源名或模块名。
3. **正文**：如果正文有 `- [ ]` 任务清单，其中**必须**包含"前序核验"（这是本仓的硬约定：
   每个 issue 的第一件事是确认前置成立，不成立就往前溯）。

退出码：0 = 全部合规；1 = 有违规（便于本地/夜间任务用）。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TITLE = re.compile(r"^(feat|fix|refactor|chore|docs|test|perf|build|ci|style)(\([a-z0-9:_-]+\))?!?: \S")
CHECKBOX = re.compile(r"^\s*- \[ \]", re.M)
REQUIRED_PREFIXES = ("type:", "priority:", "area:")


def load(source: str) -> list[dict]:
    if source == "-":
        return json.load(sys.stdin)
    return json.loads(Path(source).read_text(encoding="utf-8"))


def problems_for(issue: dict) -> list[str]:
    """返回该 issue 的违规清单（空 = 合规）。"""
    out: list[str] = []
    labels = {label["name"] if isinstance(label, dict) else label for label in issue.get("labels", [])}

    for prefix in REQUIRED_PREFIXES:
        if not any(name.startswith(prefix) for name in labels):
            out.append(f"缺少 {prefix}* 标签")

    legacy = sorted(name for name in labels if name in {"bug", "enhancement", "documentation"})
    if legacy:
        out.append(f"用了旧标签 {legacy}（应改成 type:*）")

    title = issue.get("title", "")
    if not TITLE.match(title):
        out.append("标题不符合 <type>(<scope>): <描述>")

    body = issue.get("body") or ""
    if CHECKBOX.search(body) and "前序核验" not in body:
        out.append("有任务清单但没有「前序核验」")

    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", nargs="?", default="-", help="gh issue list --json 的输出文件，或 - 读 stdin")
    parser.add_argument("--fix-plan", action="store_true", help="打印建议的 gh label 命令，不执行")
    args = parser.parse_args(argv[1:])

    issues = load(args.source)
    bad = [(issue, problems_for(issue)) for issue in issues]
    bad = [(issue, problems) for issue, problems in bad if problems]

    for issue, problems in bad:
        print(f"#{issue.get('number')} {issue.get('title', '')[:60]}")
        for problem in problems:
            print(f"    - {problem}")

    if args.fix_plan:
        print("\n# 建议命令（补标签）：")
        for issue, problems in bad:
            kinds = [p for p in problems if p.startswith("缺少")]
            print(f"# #{issue.get('number')}: " + "；".join(kinds))

    print(f"\n检查 {len(issues)} 个 issue，违规 {len(bad)} 个")
    return 0 if not bad else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
