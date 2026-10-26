"""p0 家族的源码视图。

`server/p0.lua` 2026-10-26 从一个 1224 行的文件拆成五个模块（纯搬迁、零行为变化）。
测试不该再关心某条规则落在哪个文件里——它们断言的是「这套代码里有没有这条规则」，
所以统一从这里读成一段文本；要定位某个函数在哪，用 `p0_module_of()`。

模块顺序 = fxmanifest 的加载顺序（p0.lua 必须最先，其它模块靠 `P.internal` 取共享名字）。
"""
from __future__ import annotations

import re
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
BASE = TESTS_DIR.parent
POLICE = BASE / "resources" / "[custom]" / "custom-police"

#: 加载顺序，改这里之前先改 fxmanifest
MODULES = (
    "p0.lua",
    "p0_units.lua",
    "p0_lifecycle.lua",
    "p0_incidents.lua",
    "p0_read.lua",
)


def module_paths(server_dir: Path | None = None) -> tuple[Path, ...]:
    directory = server_dir or (POLICE / "server")
    return tuple(directory / name for name in MODULES)


def p0_files(server_dir: Path | None = None) -> dict[str, str]:
    """模块名 → 源码。"""
    return {path.name: path.read_text(encoding="utf-8") for path in module_paths(server_dir)}


def p0_text(server_dir: Path | None = None) -> str:
    """整个家族拼成一段（块查找、规则断言都用它）。"""
    return "\n".join(p0_files(server_dir).values())


def p0_dofiles(lua_quote=str, server_dir: Path | None = None) -> str:
    """给 lua harness 用的加载序列：dofile 每个模块，顺序与 manifest 一致。"""
    return "\n".join(f"dofile({lua_quote(str(path))})" for path in module_paths(server_dir))


def p0_module_of(marker: str, server_dir: Path | None = None) -> str | None:
    """`marker` 在哪个模块里（例：'function P.ClaimIncident('）。"""
    for name, text in p0_files(server_dir).items():
        if marker in text:
            return name
    return None


#: 一个模块内的"下一段定义"起点（用于把 block 限制在单模块内）
_NEXT_DEF = re.compile(
    r"^local function |^function |^exports\(|^RegisterNetEvent\(|^AddEventHandler\(|^CreateThread\(",
    re.M,
)


def p0_block(start: str, end: str | None = None, server_dir: Path | None = None) -> str:
    """取 `start` 所在模块里的一段源码。

    拆分后 "块" 不能跨模块：`function P.AssignUnit(` 之后的下一个 marker 可能在另一个文件，
    直接切片会把整份模块尾部（含别的模块的规则）算进来，断言就变成假的。
    所以 end 只在同一模块内有效，否则取该模块里的下一段定义。
    """
    for text in p0_files(server_dir).values():
        if start not in text:
            continue
        i = text.index(start)
        j = text.index(end, i + 1) if end and end in text[i + 1:] else len(text)
        if j == len(text):
            match = _NEXT_DEF.search(text, i + len(start))
            if match:
                j = match.start()
        return text[i:j]
    raise AssertionError(f"p0 家族里找不到 {start!r}")
