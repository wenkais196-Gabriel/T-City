"""扫描「MySQL 回调里调用跨资源函数引用」—— 唯一实现，闸门与统计共用。

为什么需要它：FiveM 里 `exports['qb-core']:GetCoreObject()` 拿到的是**函数引用**，
在 oxmysql 的 JS 异步回调（`safeCb`）里执行会抛
`Execution of function reference in script host failed`（oxmysql 侧：
`the reference wasn't valid`）。真机 2026-11-01 在进角色路径上复现过；
`qb-garages` 取抵押车是同一形态的第二处。

判定口径：
  * 命中 `MySQL.<method>(` / `exports.oxmysql:<method>(` 这类调用的实参区；
  * 实参区里出现 `function` 关键字 = 有匿名回调，取「`function` 起 → 调用右括号」为回调区间
    （宁滥勿缺：多算的那点尾巴只会多报，不会漏报）；
  * 区间内出现 `QBCore.Functions.<x>` / `Player.Functions.<x>` / `exports[` 即为命中；
  * `TriggerEvent` / `TriggerClientEvent` / `GetPlayerName` 等原生函数**不算**（任何 host 可调）。

明确不覆盖：`local cb = function() ... end; MySQL.query(sql, {}, cb)` 这种间接回调，
以及 `MySQL.x.await` 之后的续体（后者性质相同，但没有回调括号可依，只能靠 code review）。
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]          # T-CityLite.base/
RESOURCES = BASE / "resources"

MYSQL_CALL = re.compile(r"\b(?:MySQL|exports\.oxmysql)\s*[.:]\s*(\w+)\s*(?:\.\s*await\s*)?\(")
RISK = re.compile(r"\bQBCore\.Functions\.\w+|\bPlayer\.Functions\.\w+|exports\s*\[")


@dataclass(frozen=True)
class Hit:
    file: str
    line: int
    pattern: str
    snippet: str


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def _string_spans(text: str) -> list[tuple[int, int]]:
    """字符串字面量区间（跳过注释），避免把文案里的 `Player.Functions.` 当代码。"""
    spans: list[tuple[int, int]] = []
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
            spans.append((i, j + 1))
            i = j + 1
            continue
        if text.startswith("[[", i):
            j = text.find("]]", i)
            j = n if j == -1 else j + 2
            spans.append((i, j))
            i = j
            continue
        i += 1
    return spans


def _in_spans(index: int, spans: list[tuple[int, int]]) -> bool:
    return any(start <= index < end for start, end in spans)


def _match_paren(text: str, open_index: int) -> int:
    """从 `(` 起做括号配平，返回对应 `)` 之后的位置。"""
    depth = 0
    i = open_index
    n = len(text)
    while i < n:
        ch = text[i]
        if ch in "'\"":
            quote = ch
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    break
                i += 1
        elif ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def scan_text(text: str, rel: str = "<inline>") -> list[Hit]:
    spans = _string_spans(text)
    hits: list[Hit] = []

    for call in MYSQL_CALL.finditer(text):
        open_index = call.end() - 1
        close_index = _match_paren(text, open_index)
        if close_index <= open_index:
            continue
        call_text = text[open_index:close_index]

        callback = re.search(r"\bfunction\b", call_text)
        if not callback:
            continue
        body_start = open_index + callback.start()
        body = text[body_start:close_index]

        for risk in RISK.finditer(body):
            absolute = body_start + risk.start()
            if _in_spans(absolute, spans):
                continue
            line = text[:absolute].count("\n") + 1
            raw = text.splitlines()[line - 1].strip()
            if raw.startswith("--"):
                continue
            hits.append(Hit(rel, line, risk.group(0), raw[:110]))
    return hits


def scan_file(path: Path) -> list[Hit]:
    return scan_text(_read(path), path.relative_to(RESOURCES).as_posix())


def scan_repo() -> list[Hit]:
    hits: list[Hit] = []
    for path in sorted(RESOURCES.rglob("*.lua")):
        if "node_modules" in path.parts:
            continue
        hits.extend(scan_file(path))
    return hits


if __name__ == "__main__":  # pragma: no cover - 手工排查用
    found = scan_repo()
    print(f"{len(found)} 处")
    for hit in found:
        print(f"{hit.file}:{hit.line}  [{hit.pattern}]  {hit.snippet}")
