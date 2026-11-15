"""四个金额别名（`Money` / `PhoneMoney` / `QuestMoney` / `TCMoney`）的渲染语义。

为什么单独测：这四个名字被 29 个文件、76 处金额文案共用。它们一旦写错
（比如把整数也渲染成 `500.00`、或对 nil/NaN 抛错），所有金额文案一起坏，
而金额文案的错误**不会**在静态闸门里出现（闸门只查"还有没有 `$%d`"与"实现有几份"）。

S6 返工之后：8 个资源各自的 `shared/money_format.lua` 已删除，四个别名只在
`core-framework/shared/money_aliases.lua` 定义一次（实现仍是 `shared/util.lua`
的 `FormatMoney`）；资源通过 fxmanifest 的
`'@core-framework/shared/money_aliases.lua'` include。

做法：用 lua5.4 先造一个**可调用且可索引**的 `exports` 桩（`__call` 注册、
`__index` 返回 core-framework 的方法表），`dofile` 真实 util.lua 拿到 FormatMoney，
再 `dofile` 别名文件；对**每个别名**跑同一组固定输入，断言输出字符串。冒号调用会
多传方法表，桩里的包装器把它剥掉（与 FiveM 导出调用语义一致）。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

BASE = Path(__file__).resolve().parents[3]
RESOURCES = BASE / "resources"
UTIL = RESOURCES / "[standalone]" / "core-framework" / "shared" / "util.lua"
ALIASES = RESOURCES / "[standalone]" / "core-framework" / "shared" / "money_aliases.lua"

#: 别名文件用 `exports['core-framework']:FormatMoney(value)` 转调唯一实现。
#: 桩必须同时支持 `exports('Name', fn)`（__call）和 `exports['res']:Method(...)`
#: （__index）。FiveM 的冒号调用只把业务参数传给导出函数，所以包装器在
#: `self == framework` 时剥掉多传的方法表。
MOCK_EXPORTS = """
local framework = {}
local function colonSafe(fn)
    return function(self, ...)
        if self == framework then return fn(...) end
        return fn(self, ...)
    end
end
exports = setmetatable({}, {
    __call = function(_, name, fn) framework[name] = colonSafe(fn) end,
    __index = function(_, resource)
        if resource == 'core-framework' then return framework end
        return nil
    end,
})
function IsDuplicityVersion() return false end
function GetResourceState(resource) return resource == 'core-framework' and 'started' or 'stopped' end
"""

ALIAS_NAMES = ("Money", "PhoneMoney", "QuestMoney", "TCMoney")

CASES = [
    ("0.5", "0.50"),
    ("61.75", "61.75"),
    ("0", "0"),
    ("500", "500"),
    ("-12.345", "-12.35"),
    ("'250'", "250"),
    ("nil", "0"),
    ("'abc'", "0"),
    ("0/0", "0"),          # NaN：`num ~= num` 守卫必须回落 '0'
]


@pytest.mark.parametrize("name", ALIAS_NAMES)
def test_money_alias_formats_integers_and_decimals(name):
    assert UTIL.is_file(), f"缺唯一实现：{UTIL}"
    assert ALIASES.is_file(), f"缺别名文件：{ALIASES}"

    # 标签用序号：参数里有引号（'250'），直接拼进标签会把 Lua 字符串打断
    lua_cases = "\n".join(
        f"    print('CASE|{index}|' .. tostring({name}({argument})))"
        for index, (argument, _) in enumerate(CASES)
    )
    script = (
        MOCK_EXPORTS
        + f"dofile([[{UTIL.as_posix()}]])\n"
        + f"dofile([[{ALIASES.as_posix()}]])\n"
        + lua_cases
        + "\n"
    )

    proc = subprocess.run(
        ["lua5.4", "-e", script],
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert proc.returncode == 0, f"{name}: Lua 失败\n{proc.stderr}"

    got = {}
    for line in proc.stdout.splitlines():
        if line.startswith("CASE|"):
            _, index, rendered = line.split("|", 2)
            got[int(index)] = rendered

    for index, (argument, expected) in enumerate(CASES):
        assert got.get(index) == expected, (
            f"{name}({argument}) 期望 {expected!r}，实际 {got.get(index)!r}"
        )
