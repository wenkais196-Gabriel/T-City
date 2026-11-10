#!/usr/bin/env python3
"""IO / tick / payload 预算（P2-4）—— 给"性能"这件事一组会报警的数字。

三类指标：

* **IO**：DB 调用点总数（趋势指标）+ 无限循环里的轮询形状；
* **tick**：`while true` + `Wait(0)`（吃满一个 tick）、等条件循环里的 `Wait(0)`（忙等）；
* **payload**：全服广播点，以及广播参数里内联 `json.encode` 的点（每次广播重新序列化 N 份）。

结构分析走 `tools/dev/lua_blocks.py` 的**词法切分 + 块配对**，不是正则截字符串 —— 早先的版本用固定
字符窗口找循环体，被复核抓出四类误判（字符串里的 `end`、`elseif … then`、嵌套线程、`Wait` 在体末尾）。

分类规则（每一类都有自己的预算）：
  * `while true` / `while 1` / `repeat … until false` → **无限轮询**：
    Wait(0) / ≤100ms / ≤1000ms / 未知间隔 分别计数；
  * 其余 `while` / `for` / `repeat` → **等条件循环**：Wait(0) 是正常写法，单独计 `conditional_busy_wait_loops`
    （用来显形"等一个永远不成立的条件"这类死等）。

用法::

    python3 tools/dev/budget_probe.py                 # 打印当前数字
    python3 tools/dev/budget_probe.py --json
    python3 tools/dev/budget_probe.py --check         # 与 tests/architecture/io_budget.json 比较
    python3 tools/dev/budget_probe.py --check --update # 刷新 baseline（只能往下写）

退出码：0 = 在预算内；1 = 超预算；2 = 输入缺失。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
RESOURCES = BASE / "resources"
BUDGET = BASE / "tests" / "architecture" / "io_budget.json"

sys.path.insert(0, (REPO / "tools" / "dev").as_posix())
import fivem_manifest  # noqa: E402
import lua_blocks  # noqa: E402

DB_WORDS = {"MySQL", "oxmysql"}
DB_METHODS = {"query", "execute", "insert", "update", "scalar", "single", "prepare", "transaction"}
FAST_MS = 100
WARM_MS = 1000
#: 超过一天就不必精确（也不会落在 fast/warm 档），防止 `10**400` 把探针算崩
MAX_MS = 86_400_000
CONST_EXPR = re.compile(r"^[0-9a-fA-FxXeE+\-*/(). %\s]+$")


def _constant_ms(tokens: list[tuple[str, str, int]]) -> int | None:
    """把 `50`、`0.0`、`1e3`、`0x64`、`3600 * 1000` 这类**常量表达式**折算成毫秒。

    只接受数字与四则运算符 —— 变量/配置（`Config.DecayIntervalMs`）一律算未知，不去猜值。
    """
    raw = "".join(token[1] for token in tokens).strip()
    if not raw or not CONST_EXPR.match(raw):
        return None
    try:
        value = eval(raw, {"__builtins__": {}}, {})  # noqa: S307 —— 字符集已限定为数字与运算符
    except (SyntaxError, ValueError, TypeError, ZeroDivisionError, OverflowError, MemoryError):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    if number != number or number in (float("inf"), float("-inf")):
        return None
    return min(int(abs(number)), MAX_MS)


def _call_arguments(tokens: list[tuple[str, str, int]], open_index: int) -> list[tuple[str, str, int]]:
    """`(` 之后的参数 token（到配对 `)` 为止）。"""
    depth = 0
    for cursor in range(open_index, len(tokens)):
        value = tokens[cursor][1]
        if value == "(":
            depth += 1
        elif value == ")":
            depth -= 1
            if depth == 0:
                return tokens[open_index + 1:cursor]
    return tokens[open_index + 1:]


def _find_wait(tokens: list[tuple[str, str, int]], start: int, end: int,
               excluded: set[int] | None = None) -> tuple[int | None, bool]:
    """在 [start, end) 里找第一个 `Wait(...)`（含 `Citizen.Wait`）。

    返回 (毫秒, 是否间隔未知)。间隔写成变量/配置 → unknown，单独计数（见模块 docstring）。
    """
    for cursor in range(start, end):
        if excluded and cursor in excluded:
            continue
        kind, value, _offset = tokens[cursor]
        if kind != "name" or value != "Wait":
            continue
        if cursor + 1 >= end or tokens[cursor + 1][1] != "(":
            continue
        arguments = _call_arguments(tokens, cursor + 1)
        if not arguments:
            return None, True
        milliseconds = _constant_ms(arguments)
        return (milliseconds, False) if milliseconds is not None else (None, True)
    return None, False


def _is_infinite(loop: dict) -> bool:
    kind = loop["kind"]
    condition = (loop.get("condition") or "").strip().lower()
    if kind == "repeat":
        # 只有 `until false`（字面量）才算无限；条件取不到时按有限处理（不虚增 fast/warm）
        return condition == "false"
    if kind == "for":
        return False
    normalized = condition.replace(" ", "")
    while normalized.startswith("(") and normalized.endswith(")"):
        normalized = normalized[1:-1]
    return normalized in {"true", "1"}


def measure(resources: Path = RESOURCES) -> dict[str, int]:
    """返回结构计数（不是运行时测量，但形状变化会直接反映成数字变化）。"""
    metrics = {
        "db_call_sites": 0,
        "fast_polling_loops": 0,
        "warm_polling_loops": 0,
        "wait_zero_loops": 0,
        "conditional_busy_wait_loops": 0,
        "polling_loops_unknown_interval": 0,
        "broadcast_sites": 0,
        "broadcast_inline_json": 0,
    }
    db_pattern = re.compile(
        r"\bMySQL\s*\.\s*(?:" + "|".join(DB_METHODS) + r")\b"
        r"|exports\s*\[\s*['\"]oxmysql['\"]\s*\]"
        r"|exports\.oxmysql",
        re.I,
    )

    for rel in sorted(fivem_manifest.server_files(resources)):
        try:
            source = (resources / rel).read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        code = fivem_manifest.strip_comments(source)
        metrics["db_call_sites"] += len(db_pattern.findall(code))

        tokens = lua_blocks.tokenize(code)
        all_loops = lua_blocks.loops(tokens)
        for loop in all_loops:
            # 只找**这条循环自己的** Wait：嵌套循环（常见是循环里再 CreateThread）有它自己的节奏，
            # 把它算到外层头上会让"外层其实 60 秒一圈"被误报成 fast。
            nested: set[int] = set()
            for other in all_loops:
                if other is loop:
                    continue
                if loop["body_start"] <= other["start"] < loop["body_end"]:
                    nested.update(range(other["start"], other["body_end"] + 1))
            milliseconds, unknown = _find_wait(
                tokens, loop["body_start"], loop["body_end"], nested)
            infinite = _is_infinite(loop)
            if unknown:
                if infinite:
                    metrics["polling_loops_unknown_interval"] += 1
                continue
            if milliseconds is None:
                continue
            if not infinite:
                if milliseconds == 0:
                    metrics["conditional_busy_wait_loops"] += 1
                continue
            if milliseconds == 0:
                metrics["wait_zero_loops"] += 1
            elif milliseconds <= FAST_MS:
                metrics["fast_polling_loops"] += 1
            elif milliseconds <= WARM_MS:
                metrics["warm_polling_loops"] += 1

        for cursor, (kind, value, _offset) in enumerate(tokens):
            if kind != "name" or value != "TriggerClientEvent":
                continue
            if cursor + 1 >= len(tokens) or tokens[cursor + 1][1] != "(":
                continue
            arguments = _call_arguments(tokens, cursor + 1)
            # 参数形状：<'event'>, <target = -1>, <payload...>
            # 词法上 `-1` 是 symbol('-') + number('1')：判定广播目标时要按这个形状认
            is_broadcast = any(
                arguments[index][1] == "-" and arguments[index + 1][0] == "number"
                and arguments[index + 1][1] == "1"
                for index in range(min(len(arguments) - 1, 5))
            )
            if not is_broadcast:
                continue
            metrics["broadcast_sites"] += 1
            if any(token[0] == "name" and token[1] == "json" for token in arguments) and \
               any(token[0] == "name" and token[1] == "encode" for token in arguments):
                metrics["broadcast_inline_json"] += 1
    return metrics


def load_budget(path: Path = BUDGET) -> dict[str, dict]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8")).get("metrics", {})


def check(metrics: dict[str, int] | None = None, path: Path = BUDGET,
          resources: Path = RESOURCES) -> list[str]:
    """返回超预算的说明（空 = 通过）。"""
    metrics = metrics if metrics is not None else measure(resources)
    budget = load_budget(path)
    problems: list[str] = []
    for name, value in metrics.items():
        entry = budget.get(name)
        if entry is None:
            problems.append(f"{name} = {value}，但 io_budget.json 里没有它（新增指标要同时写预算）")
            continue
        limit = int(entry["budget"])
        if value > limit:
            problems.append(
                f"{name} = {value} > 预算 {limit}。要么改回原形状，要么在 PR 里写 gate-change: 与理由"
                f"（{entry.get('note', '')}）"
            )
    return problems


def write_budget(metrics: dict[str, int], path: Path = BUDGET) -> None:
    """刷新 baseline：只允许往下写（数字变大 = 退步，拒绝）。"""
    existing = load_budget(path)
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {
        "$comment": "P2-4 静态预算。数字是结构计数，只能往下调；调高必须在 PR 里写 gate-change: 与理由。",
        "metrics": {},
    }
    for name, value in metrics.items():
        previous = int(existing.get(name, {}).get("budget", value))
        if value > previous:
            raise SystemExit(f"[budget] {name} 从 {previous} 涨到 {value}：预算只能往下调")
        data["metrics"].setdefault(name, {})["budget"] = value
        data["metrics"][name].setdefault("note", "")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="IO / tick / payload 静态预算（P2-4）")
    parser.add_argument("--check", action="store_true", help="与 io_budget.json 比较")
    parser.add_argument("--json", action="store_true", help="JSON 输出")
    parser.add_argument("--update", action="store_true", help="刷新 baseline（只能往下）")
    args = parser.parse_args(argv)

    if not RESOURCES.exists():
        print(f"[budget] 缺少 {RESOURCES}", file=sys.stderr)
        return 2

    metrics = measure()
    if args.update:
        write_budget(metrics)
        print(f"[budget] 已刷新 baseline：{metrics}")
        return 0

    if args.json:
        print(json.dumps(metrics, ensure_ascii=False, indent=2))
    else:
        budget = load_budget()
        for name, value in metrics.items():
            limit = budget.get(name, {}).get("budget")
            print(f"{name:30s} {value:6d}   预算 {limit if limit is not None else '—'}")

    if args.check:
        problems = check(metrics)
        if problems:
            print(f"[budget] {len(problems)} 项超预算：")
            for problem in problems:
                print(f"  - {problem}")
            return 1
        print("[budget] 通过：全部指标在预算内")
    return 0


if __name__ == "__main__":
    sys.exit(main())
