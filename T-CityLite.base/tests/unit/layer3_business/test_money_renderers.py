"""六个资源的 `Money()` 渲染器：整数不带小数点、小数保留两位、非法输入回落 '0'。

为什么单独测：这六个 `shared/money_format.lua` 是 P1-5 阶段 E 新建的，被 26 处文案共用。
它们一旦写错（比如把整数也渲染成 `500.00`、或对 nil 抛错），所有金额文案一起坏，
而金额文案的错误**不会**在静态闸门里出现（闸门只查"还有没有 `$%d`"）。

做法：用 lua5.4 直接 `dofile` 每个模块，跑一组固定输入，断言输出字符串。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
RESOURCES = BASE / "resources"

MODULES = {
    "qb-drugs": "[qb]/qb-drugs",
    "custom-cartel": "[custom]/custom-cartel",
    "custom-crime": "[custom]/custom-crime",
    "custom-security": "[custom]/custom-security",
    "custom-main": "[custom]/custom-main",
    "custom-market": "[custom]/custom-market",
    "custom-phone": "[custom]/custom-phone",
    "custom-quest": "[custom]/custom-quest",
}

FUNCTIONS = {
    "custom-phone": "PhoneMoney",
    "custom-quest": "QuestMoney",
}

CASES = [
    ("0.5", "0.50"),
    ("61.75", "61.75"),
    ("0", "0"),
    ("500", "500"),
    ("-12.345", "-12.35"),
    ("'250'", "250"),
    ("nil", "0"),
    ("'abc'", "0"),
]


def _module_path(resource: str) -> Path:
    relative = MODULES[resource]
    return RESOURCES / relative / "shared" / "money_format.lua"


@pytest.mark.parametrize("resource", sorted(MODULES))
def test_money_renderer_formats_integers_and_decimals(resource):
    path = _module_path(resource)
    assert path.exists(), f"{resource} 缺少 shared/money_format.lua"

    function = FUNCTIONS.get(resource, "Money")
    # 标签用序号：参数里有引号（'250'），直接拼进标签会把 Lua 字符串打断
    lua_cases = "\n".join(
        f"    print('CASE|{index}|' .. tostring({function}({argument})))"
        for index, (argument, _) in enumerate(CASES)
    )
    script = f"dofile([[{path.as_posix()}]])\n" + lua_cases + "\n"

    proc = subprocess.run(
        ["lua5.4", "-e", script],
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert proc.returncode == 0, f"{resource}: Lua 失败\n{proc.stderr}"

    got = {}
    for line in proc.stdout.splitlines():
        if line.startswith("CASE|"):
            _, index, rendered = line.split("|", 2)
            got[int(index)] = rendered

    for index, (argument, expected) in enumerate(CASES):
        assert got.get(index) == expected, (
            f"{resource} 的 {function}({argument}) 期望 {expected!r}，实际 {got.get(index)!r}"
        )
