#!/usr/bin/env python3
"""复用扫描：找出"同一个能力被实现了很多遍"的地方。

不阻断 CI（默认退出 0），先给报告。判据是**同名函数的定义次数**：跨资源的同名
工具函数（身份解析、通知、时间格式化…）是组件碎片化最可靠的信号。

用法::

    python3 tools/dev/reuse_scan.py                  # 报告 top 20
    python3 tools/dev/reuse_scan.py --min 4 --top 40
    python3 tools/dev/reuse_scan.py --fail-on 8      # 同名实现 ≥8 次就失败（逐步收紧）

有意为之：只统计**定义**（`function X(` / `local function X(`），不统计调用点，
这样"某某函数被到处调用"不会污染结果。
"""

from __future__ import annotations

import argparse
import re
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RESOURCES = REPO / "T-CityLite.base" / "resources"

DEF_RE = re.compile(r"^\s*(?:local\s+)?function\s+([A-Za-z_][\w.:]*)\s*\(", re.M)
NOISE_PREFIXES = ("__", "test", "on", "On")
# 通用动词 / 方法的同名定义不构成"碎片化"信号：`Get`、`Register`、`trim` 这类
# 名字在不同模块里各有一份是正常设计。把它们算进来只会让预算表变成垃圾场，
# 然后所有人都学会忽略这个指标。
NOISE_NAMES = {
    "init", "main", "setup", "start", "stop", "draw", "loop", "think", "run", "update",
    "tick", "new", "create", "destroy", "handler", "callback",
    "get", "set", "register", "unregister", "stats", "trim", "audit", "load", "save",
    "send", "notify", "log", "print", "add", "remove", "clear", "reset", "apply",
    "build", "parse", "format", "convert", "validate", "spawn", "delete", "refresh",
    "reload", "enable", "disable", "wait", "drawtext", "help", "usage",
}
MIN_NAME_LEN = 6

# 「同名定义 N 份」原本把"一行转调共享实现"的包装也算成碎片化。那会让合并永远显示不出来
# （5 个 1 行包装仍然算 5 份），于是没人愿意做第二批复用。判据：函数体短、且体内只出现
# 对共享实现的调用（exports[...]/Convar*/RateLimit*/LoadAnimDict/LoadModel/Bus.）。
ADAPTER_RE = re.compile(
    r"exports\[|\bConvar(?:String|Int|Float|Bool)\b|\bRateLimit\w*\b|\bLoadAnimDict\b|\bLoadModel\b|\bBus\.",
)
ADAPTER_MAX_LINES = 10


def is_adapter(src: str, start: int) -> bool:
    """函数体短、且只转调共享实现 → 是包装，不是重复逻辑。"""
    lines = src[start:].splitlines()
    if not lines:
        return False
    head = lines[0]
    indent = len(head) - len(head.lstrip())
    block = [head]
    for line in lines[1:]:
        if line.strip() == "end" and (len(line) - len(line.lstrip())) == indent:
            block.append(line)
            break
        block.append(line)
        if len(block) > ADAPTER_MAX_LINES:
            return False
    text = "\n".join(block)
    return len(block) <= ADAPTER_MAX_LINES and bool(ADAPTER_RE.search(text))


def definitions(root: Path) -> dict[str, list[str]]:
    found: dict[str, list[str]] = defaultdict(list)
    for lua in sorted(root.rglob("*.lua")):
        if "node_modules" in lua.parts:
            continue
        try:
            text = lua.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for match in DEF_RE.finditer(text):
            name = match.group(1)
            tail = name.split(":")[-1].split(".")[-1]
            if tail.lower() in NOISE_NAMES or tail.startswith(NOISE_PREFIXES):
                continue
            if len(tail) < MIN_NAME_LEN:      # 短名几乎都是方法/回调，不是能力
                continue
            if is_adapter(text, match.start()):
                continue
            found[tail].append(str(lua.relative_to(REPO)))
    return found


def report(found: dict[str, list[str]], minimum: int, top: int) -> list[tuple[str, list[str]]]:
    rows = [(name, files) for name, files in found.items() if len(files) >= minimum]
    rows.sort(key=lambda row: (-len(row[1]), row[0]))
    return rows[:top]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--min", type=int, default=3, help="同名定义至少出现几次才报告")
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--fail-on", type=int, default=0, help="某一名字的定义数达到该值时退出码 1")
    args = parser.parse_args()

    if not RESOURCES.is_dir():
        print(f"找不到资源目录: {RESOURCES}")
        return 2

    found = definitions(RESOURCES)
    rows = report(found, args.min, args.top)

    print(f"[reuse_scan] {len(found)} 个不同函数名；同名定义 ≥{args.min} 次的：{sum(1 for f in found.values() if len(f) >= args.min)} 组\n")
    for name, files in rows:
        print(f"{len(files):3d}× {name}")
        for f in files[:4]:
            print(f"      {f}")
        if len(files) > 4:
            print(f"      …还有 {len(files) - 4} 个")

    if args.fail_on:
        worst = max((len(f) for f in found.values()), default=0)
        if worst >= args.fail_on:
            print(f"\n失败：最多同名定义 {worst} 次 ≥ --fail-on {args.fail_on}")
            return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:          # `| head` 之类的下游提前关闭管道
        raise SystemExit(0)
