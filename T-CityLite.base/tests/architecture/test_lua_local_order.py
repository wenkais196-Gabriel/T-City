"""Lua 局部函数的**定义顺序**闸门。

为什么需要：
    同一个坑在这个仓库里踩了至少四次：
      1. `closeRentalFor` 定义在调用点之后 → `attempt to call a nil value`
      2. helper 引用了更晚声明的 `local QBCore` → 静默 nil，押金退不回来
      3. `activeNode` 的 local 声明在清理点之后 → 清的是全局，线程不退出
      4. 摆摊预览的 `HidePreviewText` 定义在 `DeleteCart` 之后（2026-11-14 真机前自查抓到）

    `luac -p` 查不出这类问题：语法完全合法，运行时才崩，而且往往崩在「玩家做了某个动作」时。

这里只做一件窄而确定的事：
    同一个 Lua 文件里，`local function NAME(` 的**每次调用**都必须出现在定义之后。
    （`NAME = function()` 这种先赋值后使用的写法不在覆盖范围 —— 那本来也不是 local。）

误报处理：注释行与字符串里的同名文本会被去掉再判断。
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

from lua_source import blank_noise, line_of

# parents: [architecture, tests, T-CityLite.base, T-City] → 资源在 T-CityLite.base 下
BASE = Path(__file__).resolve().parents[2]

# 只查自研资源：qb-* 是上游代码，不去教育它
TARGETS = [
    BASE / "resources/[custom]/custom-quest",
    BASE / "resources/[custom]/custom-phone",
    BASE / "resources/[custom]/custom-police",
]

LOCAL_FN = re.compile(r"^\s*local function ([A-Za-z_][A-Za-z0-9_]*)", re.M)


def lua_files() -> list[Path]:
    files: list[Path] = []
    for root in TARGETS:
        if root.exists():
            files.extend(sorted(root.rglob("*.lua")))
    return files


def violations(path: Path) -> list[str]:
    raw = path.read_text(encoding="utf-8", errors="replace")
    code = blank_noise(raw)

    definitions: dict[str, int] = {}
    for match in LOCAL_FN.finditer(code):
        definitions.setdefault(match.group(1), line_of(code, match.start()))

    problems: list[str] = []
    for name, defined_at in definitions.items():
        call = re.compile(r"(?<![A-Za-z0-9_.:])" + re.escape(name) + r"\s*\(")
        for match in call.finditer(code):
            line = line_of(code, match.start())
            if line < defined_at:
                # 定义行本身也算一次「出现」，跳过
                if code.splitlines()[line - 1].lstrip().startswith("local function "):
                    continue
                problems.append(f"{path.relative_to(BASE)}:{line} 调用了 {name}，但它在第 {defined_at} 行才定义")
                break
    return problems


@pytest.mark.parametrize("path", lua_files(), ids=lambda p: p.name)
def test_local_functions_are_declared_before_they_are_called(path: Path):
    problems = violations(path)
    assert not problems, "局部函数在定义之前被调用（运行时才崩，luac -p 查不出来）：\n  " + "\n  ".join(problems)
