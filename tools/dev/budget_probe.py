#!/usr/bin/env python3
"""IO / tick / payload 预算（P2-4）—— 给"性能"这件事一组会报警的数字。

为什么是这三类：

* **IO**：DB 调用总数只涨不跌地跟着业务长，所以它是"趋势指标"；真正会被预算卡住的是**轮询形状** ——
  `while true` + `Wait(≤100ms)` 的循环每条就是约 600 次/分钟，`Wait(≤1000ms)` 是约 60 次/分钟。
* **tick**：`Wait(0)` 的循环会吃满一个 tick；服务端脚本里出现它就等于把一个核钉在某条协程上。
* **payload**：全服广播（`TriggerClientEvent(..., -1, ...)`）里内联 `json.encode` 意味着每次广播都要
  序列化一遍再发 N 份；这类点在预算里单独计数，因为它随在线人数线性放大。

数字都是**静态上界**（按代码结构推导，不需要跑服），因此能在 CI 里卡住"新加一个每秒轮询"这种改动。

用法::

    python3 tools/dev/budget_probe.py                 # 打印当前数字
    python3 tools/dev/budget_probe.py --json
    python3 tools/dev/budget_probe.py --check         # 与 tests/architecture/io_budget.json 比较
    python3 tools/dev/budget_probe.py --check --update  # 刷新 baseline（只能往下写）

退出码：0 = 在预算内；1 = 超预算；2 = 输入缺失。
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
RESOURCES = BASE / "resources"
BUDGET = BASE / "tests" / "architecture" / "io_budget.json"

sys.path.insert(0, (REPO / "tools" / "dev").as_posix())
import fivem_manifest  # noqa: E402

DB = re.compile(
    r"\bMySQL\s*\.\s*(?:query|execute|insert|update|scalar|single|prepare|transaction)\b"
    r"|exports\s*\[\s*['\"]oxmysql['\"]\s*\]"
    r"|exports\.oxmysql",
    re.I,
)
LOOP = re.compile(r"\bwhile\s+([^\n]{0,80}?)\s+do\b|\brepeat\b", re.I)
#: 条件字面量 = 无限循环（周期轮询）；否则是「等条件」循环（busy-wait 的另一种风险）
INFINITE_COND = re.compile(r"^(true|1)$", re.I)
#: 参数不一定是数字字面量（`Wait(ms)` / `Wait()` / `Wait(0.0)` 都见过）：先抓整段，再尝试解析
WAIT = re.compile(r"(?:Citizen\s*\.\s*)?Wait\s*\(([^)]*)\)")
BROADCAST = re.compile(r"TriggerClientEvent\s*\(\s*['\"][^'\"]+['\"]\s*,\s*-1\b")
JSON_INLINE = re.compile(r"json\s*\.\s*encode\s*\(")

#: 循环里拿不到 Wait 间隔时的保守假设：按 1 次/秒 计
UNKNOWN_INTERVAL_MS = 1000


#: 只看循环头之后这一段里"第一个 Wait"：判的是"这条循环多久转一圈"，不需要精确配对
LOOP_WINDOW = 600
#: 轮询周期 ≤ 100ms 视为热循环（≈600 次/分钟/条）；≤ 1000ms 视为次热
FAST_MS = 100
WARM_MS = 1000


CONST_EXPR = re.compile(r"^[0-9a-fA-FxXeE+\-*/(). %\s]+$")
#: 超过一天就不必精确（也不会落在 fast/warm 档），防止 10**400 这类把探针算崩
MAX_MS = 86_400_000


def _constant_ms(raw: str) -> int | None:
    """把 `50`、`0.0`、`3600 * 1000`、`60/2` 这类**常量表达式**折算成毫秒。

    只接受数字与四则运算符 —— 变量/配置（`Config.DecayIntervalMs`）一律算未知，不去猜值。
    """
    raw = raw.strip()
    if not raw or not CONST_EXPR.match(raw):
        return None
    try:
        # 只允许算术：globals/locals 都清空，且上面已限定字符集
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


BLOCK_TOKEN = re.compile(r"\b(do|then|function|repeat|end|until)\b", re.I)
OPENS = {"do", "then", "function", "repeat"}


def _block_body(code: str, start: int) -> str:
    """从循环关键字之后取**配对**到 `end`（`repeat` 取到 `until`）的那段。

    不用固定字符窗口：`while true do` 后面先干一段活、末尾才 `Wait(60)` 是常见写法，
    固定 600 字符会把这类循环漏掉，也会把循环外/内层线程的 Wait 误记成它的间隔。
    """
    depth = 1
    for match in BLOCK_TOKEN.finditer(code, start):
        word = match.group(1).lower()
        if word in OPENS:
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                return code[start:match.start()]
    return code[start:]


def _first_wait(code: str, start: int) -> tuple[int | None, bool]:
    """返回 (毫秒, 是否间隔未知)。

    `Wait(ms)` / `Wait()` 这类未知间隔单独计数（`polling_loops_unknown_interval`），**不并进 fast** ——
    并进去会让 fast 这个数字失真；但不计数就会让"把 Wait(50) 改成 Wait(ms)"成为静默绕过。
    """
    match = WAIT.search(_block_body(code, start))
    if not match:
        return None, False
    value = _constant_ms(match.group(1))
    if value is None:
        return None, True
    return value, False


def _call_arguments(code: str, open_paren: int) -> str:
    """取一对配对括号之间的内容（广播参数可能很长，固定窗口会误判）。"""
    depth = 0
    index = open_paren
    while index < len(code):
        if code[index] == "(":
            depth += 1
        elif code[index] == ")":
            depth -= 1
            if depth == 0:
                return code[open_paren:index]
        index += 1
    return code[open_paren:]


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
    for rel in sorted(fivem_manifest.server_files(resources)):
        try:
            source = (resources / rel).read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        code = fivem_manifest.strip_comments(source)

        metrics["db_call_sites"] += len(DB.findall(code))

        for match in LOOP.finditer(code):
            condition = (match.group(1) or "").strip()
            while condition.startswith("(") and condition.endswith(")"):
                condition = condition[1:-1].strip()
            infinite = bool(INFINITE_COND.match(condition)) or match.group(1) is None
            wait_ms, unknown = _first_wait(code, match.end())
            if unknown:
                # 间隔由配置/变量决定：单独计数（有预算就会显形），但不冒充"快循环"。
                # 只对无限循环计数：等条件的循环退出由条件决定，间隔未知不算风险。
                if infinite:
                    metrics["polling_loops_unknown_interval"] += 1
                continue
            if wait_ms is None:
                continue
            if not infinite:
                # 「等条件」循环：Wait(0) 在这里是正常写法（等到就退出），但忙等仍然是风险
                if wait_ms == 0:
                    metrics["conditional_busy_wait_loops"] += 1
                continue
            if wait_ms == 0:
                metrics["wait_zero_loops"] += 1
            elif wait_ms <= FAST_MS:
                metrics["fast_polling_loops"] += 1
            elif wait_ms <= WARM_MS:
                metrics["warm_polling_loops"] += 1

        for match in BROADCAST.finditer(code):
            metrics["broadcast_sites"] += 1
            open_paren = code.find("(", match.start())
            if open_paren != -1 and JSON_INLINE.search(_call_arguments(code, open_paren)):
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
        "$comment": "P2-4 静态预算。数字是'''上界'''，只能往下调；调高必须在 PR 里写 gate-change: 与理由。",
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
        for name, value in metrics.items():
            limit = load_budget().get(name, {}).get("budget")
            print(f"{name:28s} {value:6d}   预算 {limit if limit is not None else '—'}")

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
