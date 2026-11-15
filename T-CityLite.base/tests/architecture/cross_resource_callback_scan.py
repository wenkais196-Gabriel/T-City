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

明确不覆盖：`local cb = function() ... end; MySQL.query(sql, {}, cb)` 这种**间接回调**
（已知盲区，登记在 P1-5 计划 §8：当前全仓 0 处该形态）。

为什么 `MySQL.x.await` 的续体**不在**此列：oxmysql 的 Lua 包装里 `.await` =
`promise.new()` + `Citizen.Await(p)`，恢复的是**调用方自己的协程**，所以续体里调跨资源
函数引用是安全的；而回调闭包是被传给 JS、由 oxmysql 的宿主执行，那里没有调用方的 script host。
实证：全仓 337 处 `.await`，其中 `qb-management/server/sv_gang.lua:24-26` 在
`MySQL.query.await` 之后直接调 `QBCore.Functions.GetPlayerByCitizenId`，长期运行无报错。
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

import lua_source

BASE = Path(__file__).resolve().parents[2]          # T-CityLite.base/
RESOURCES = BASE / "resources"

MYSQL_CALL = re.compile(r"\b(?:MySQL|exports\.oxmysql)\s*[.:]\s*\w+(?:\.await)?\s*\(")
RISK = re.compile(r"\bQBCore\.Functions\.\w+|\bPlayer\.Functions\.\w+|exports\s*\[")


@dataclass(frozen=True)
class Hit:
    file: str
    line: int
    pattern: str
    snippet: str


def scan_text(source: str, rel: str = "<inline>") -> list[Hit]:
    spans = lua_source.string_spans(source)
    hits: list[Hit] = []

    for call in MYSQL_CALL.finditer(source):
        open_index = call.end() - 1
        close_index = lua_source.match_paren(source, open_index)
        if close_index <= open_index:
            continue

        callback = re.search(r"\bfunction\b", source[open_index:close_index])
        if not callback:
            continue
        body_start = open_index + callback.start()
        body = source[body_start:close_index]

        for risk in RISK.finditer(body):
            absolute = body_start + risk.start()
            if lua_source.in_spans(absolute, spans):
                continue
            line = lua_source.line_of(source, absolute)
            raw = source.splitlines()[line - 1].strip()
            if raw.startswith("--"):
                continue
            hits.append(Hit(rel, line, risk.group(0), raw[:110]))
    return hits


def scan_file(path: Path) -> list[Hit]:
    return scan_text(path.read_text(encoding="utf-8", errors="ignore"),
                     path.relative_to(RESOURCES).as_posix())


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
