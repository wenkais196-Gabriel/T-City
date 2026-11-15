"""扫描「金额写路径」是否仍然收敛 —— 三条静态判据。

为什么需要它：金额校验曾经散落在三个入口（`AddMoney` / `RemoveMoney` / `SetMoney`），
`SetMoney` 有阈值熔断、另外两个没有；`player.lua` 里 `Bus.EconomyService` 缺失时还有一份
直接写表的 fallback。结果是**同一个非法输入在不同路径得到不同答复**（NaN 能进账、
5000001 能进账）。收敛之后，任何"再写一份"的改动都必须让闸门变红。

判据：

1. `PlayerData.money[...]` 的**赋值**只允许出现在 `[qb]/qb-core/server/player.lua`
   （收敛层自己那 6 处）。
2. 单笔阈值 `MONEY_MAX_SINGLE_TRANSACTION` 全仓**只定义一次**。
3 三个写入口的函数体里都必须出现 `ValidateAmount(`。

扫描跑在**去掉注释与字符串**的代码上：`-- PlayerData.money['cash'] = 5` 这种注释不算命中，
而 `print("PlayerData.money[x] = 1")` 也不会。
"""

from __future__ import annotations

import re
from pathlib import Path

import lua_source

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"

# 只认真正的赋值：`money[x] = ` / `money[x] = money[x] + 1` / `+=`
# 不认比较（`==`）、也不认 `local money = player.PlayerData.money` 这种取引用。
MONEY_ASSIGN = re.compile(r"PlayerData\.money\s*\[[^\]\n]+\]\s*(?:\+|-|\*|/)?=(?!=)")
THRESHOLD_DEF = re.compile(r"MONEY_MAX_SINGLE_TRANSACTION\s*=(?!=)")
# 两个形状都要认：`function EconomyService.AddMoney(` 与 `function self.Functions.AddMoney(`
ENTRY_DEF = re.compile(
    r"function\s+(?:(?:self|EconomyService)(?:\.Functions)?\.)?(AddMoney|RemoveMoney|SetMoney)\s*\("
)
VALIDATOR_CALL = "ValidateAmount("

# 收敛层：只有这个文件允许直接写 money 表
MONEY_OWNER = "[qb]/qb-core/server/player.lua"
# 三个写入口所在文件（player.lua 的 fallback + economy_service 的实现）
ENTRY_FILES = ("[qb]/qb-core/server/player.lua", "[qb]/qb-core/server/services/economy_service.lua")


def strip_noise(source: str) -> str:
    """去注释与字符串，保留行结构。"""
    source = re.sub(r"--\[(=*)\[.*?\]\1\]", lambda m: "\n" * m.group(0).count("\n"), source, flags=re.S)
    source = re.sub(r"--[^\n]*", "", source)
    spans = lua_source.string_spans(source)
    out = []
    index = 0
    for start, end in spans:
        out.append(source[index:start])
        out.append(re.sub(r"[^\n]", " ", source[start:end]))
        index = end
    out.append(source[index:])
    return "".join(out)


def money_assignments(rel: str, source: str) -> list[int]:
    """返回命中行号（1-based）。"""
    code = strip_noise(source)
    lines = code.splitlines()
    return [number for number, line in enumerate(lines, start=1) if MONEY_ASSIGN.search(line)]


def threshold_definitions(rel: str, source: str) -> list[int]:
    code = strip_noise(source)
    return [n for n, line in enumerate(code.splitlines(), start=1) if THRESHOLD_DEF.search(line)]


def entry_bodies(source: str) -> dict[str, str]:
    """按括号配平切出三个写入口的函数体（`function X.Y(...) ... end`）。"""
    code = strip_noise(source)
    bodies: dict[str, str] = {}
    for match in ENTRY_DEF.finditer(code):
        name = match.group(1)
        open_paren = code.find("(", match.start())
        close_paren = lua_source.match_paren(code, open_paren)
        if close_paren is None:
            continue
        # 函数体到**下一个函数定义**（缩进任意）或文件尾 —— 只在「缩进 4 格」处切会把两个相邻的
        # `function EconomyService.X(` 连成一段，于是没校验的函数可能借着下一个函数的 ValidateAmount 通过。
        tail = code[close_paren:]
        next_def = re.search(r"\n[ \t]*function[ \t]", tail)
        bodies[name] = tail[: next_def.start()] if next_def else tail
    return bodies


def iter_lua_files(resources: Path):
    for path in sorted(resources.rglob("*.lua")):
        rel = path.relative_to(resources).as_posix()
        if rel.startswith("archive/"):
            continue
        yield rel, path


def scan_repo(resources: Path = RESOURCES) -> dict:
    assignments: dict[str, list[int]] = {}
    thresholds: dict[str, list[int]] = {}
    entries_with_validator: dict[str, bool] = {}
    for rel, path in iter_lua_files(resources):
        try:
            source = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        hits = money_assignments(rel, source)
        if hits:
            assignments[rel] = hits
        defs = threshold_definitions(rel, source)
        if defs:
            thresholds[rel] = defs
        if rel in ENTRY_FILES:
            for name, body in entry_bodies(source).items():
                entries_with_validator[f"{rel}:{name}"] = VALIDATOR_CALL in body
    return {
        "assignments": assignments,
        "thresholds": thresholds,
        "entries": entries_with_validator,
    }
