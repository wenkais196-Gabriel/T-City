"""ARCH — 金额格式化只有一个 owner：`core-framework/shared/util.lua` 的 `FormatMoney`（S6）。

为什么需要这条规则：金额可能是小数（比例 / 乘算 / 客户端传入），`('%d'):format(x)`
在 Lua 5.4 对小数直接抛 `number has no integer representation`，而抛错往往发生在
「钱已到账 / 审计没写」之后。P1-5 在 8 个 `[custom]` 资源里各写了一份相同语义的
`shared/money_format.lua`；S6 把这 8 份实现收口到 `core-framework`，各资源只留
≤10 行、只转调 `exports['core-framework']:FormatMoney` 的门面。

判定口径（前向）：

* 扫描 `resources/[custom]/**/*.lua`，找**函数体**里同时出现 `tonumber(...)`、
  `% 1 == 0`、`%.2f` 的实现；
* 允许 `core-framework/shared/util.lua`（唯一实现，不在 `[custom]` 扫描范围内）；
* 允许 8 个 `shared/money_format.lua` 门面：文件 ≤10 行、保留原函数名、只出现
  `exports['core-framework']:FormatMoney`，不得再有实现体；
* 允许 `custom-quest/client/quest_hotdog_vendor_client.lua` 的委托 fallback：
  它先 `if type(QuestMoney) == 'function' then return QuestMoney(value) end`，
  不是第二份实现体；
* `[qb]/qb-drugs/shared/money_format.lua` 是上游资源，不在 `[custom]` 扫描范围。

`test_reverse_money_format_alias_is_rejected` 用合成源码证明规则会红：
`PhoneMoney` 的实现体必须被抓住；只转调 owner 的门面、安全的 `$%s` 文案、
注释里的示例不许误报。

    python -m pytest -q tests/architecture/test_money_format_single_owner.py
"""
from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
CUSTOM = BASE / "resources" / "[custom]"

#: 唯一实现（不在 [custom] 扫描根内；显式写出是为了让例外清单可读）。
OWNER = "resources/[standalone]/core-framework/shared/util.lua"

#: 8 个门面必须保留原函数名：调用点一个都不改名。
FACADES = {
    "resources/[custom]/custom-market/shared/money_format.lua": "Money",
    "resources/[custom]/custom-main/shared/money_format.lua": "Money",
    "resources/[custom]/custom-cartel/shared/money_format.lua": "Money",
    "resources/[custom]/custom-security/shared/money_format.lua": "Money",
    "resources/[custom]/custom-crime/shared/money_format.lua": "Money",
    "resources/[custom]/custom-phone/shared/money_format.lua": "PhoneMoney",
    "resources/[custom]/custom-quest/shared/money_format.lua": "QuestMoney",
    "resources/[custom]/custom-taxes/shared/money_format.lua": "TCMoney",
}

#: 委托 fallback：先问 QuestMoney，拿不到才走本地兜底；不是第二份实现。
DELEGATE = "resources/[custom]/custom-quest/client/quest_hotdog_vendor_client.lua"

MAX_FACADE_LINES = 10

_FUNCTION = re.compile(r"\b(?:local\s+)?function\s+([A-Za-z_][\w.:]*)\s*\(")
_TOKEN = re.compile(r"\b(?:function|if|for|while|repeat|do|end|until)\b")
_LONG_BRACKET = re.compile(r"\[(=*)\[")

#: 一份「金额格式化实现」的三个语义标记；缺一个就不是这条规则要抓的形状。
IMPL_MARKERS = (
    re.compile(r"\btonumber\s*\("),
    re.compile(r"%\s*1\s*==\s*0"),
    re.compile(r"%\.2f"),
)

EXPORT_CALL = re.compile(r"exports\s*\[\s*'core-framework'\s*\]\s*:\s*FormatMoney\s*\(")
DELEGATE_GUARD = re.compile(r"type\s*\(\s*QuestMoney\s*\)\s*==\s*'function'")
DELEGATE_CALL = re.compile(r"return\s+QuestMoney\s*\(")


def _blank(text: str) -> str:
    """用空格替换，保留换行（长度/行号不变）。"""
    return "".join("\n" if char == "\n" else " " for char in text)


def _skip_quoted(source: str, index: int, quote: str) -> int:
    cursor, size = index + 1, len(source)
    while cursor < size:
        if source[cursor] == "\\":
            cursor += 2
            continue
        if source[cursor] == quote:
            return cursor + 1
        cursor += 1
    return size


def strip_lua_noise(source: str, *, keep_strings: bool) -> str:
    """去掉注释（可选去掉字符串），长度/行号保持不变。

    标记检测需要保留字符串（`('%.2f'):format` 的 `%.2f` 是字面量），
    而块结构扫描必须去掉字符串（免得 `print("end")` 被当成 `end` 关键字）。
    """
    out: list[str] = []
    index, size = 0, len(source)
    while index < size:
        char = source[index]
        if char == "-" and source.startswith("--", index):
            long_match = _LONG_BRACKET.match(source, index + 2)
            if long_match:
                close = "]" + long_match.group(1) + "]"
                end = source.find(close, long_match.end())
                end = size if end == -1 else end + len(close)
            else:
                end = source.find("\n", index)
                end = size if end == -1 else end
            out.append(_blank(source[index:end]))
            index = end
            continue
        if char == "[":
            long_match = _LONG_BRACKET.match(source, index)
            if long_match:
                close = "]" + long_match.group(1) + "]"
                end = source.find(close, long_match.end())
                end = size if end == -1 else end + len(close)
                chunk = source[index:end]
                out.append(chunk if keep_strings else _blank(chunk))
                index = end
                continue
        if char in "\"'":
            end = _skip_quoted(source, index, char)
            chunk = source[index:end]
            out.append(chunk if keep_strings else _blank(chunk))
            index = end
            continue
        out.append(char)
        index += 1
    return "".join(out)


def _function_end(structural: str, body_start: int) -> int:
    """从 `function ... (` 之后开始，返回匹配 `end` 之后的位置。"""
    stack: list[list] = [["function", False]]     # [kind, 等待它自己的 do]
    for match in _TOKEN.finditer(structural, body_start):
        token = match.group(0)
        if token in ("function", "if", "repeat"):
            stack.append([token, False])
        elif token in ("for", "while"):
            stack.append([token, True])
        elif token == "do":
            if stack and stack[-1][0] in ("for", "while") and stack[-1][1]:
                stack[-1][1] = False
            else:
                stack.append(["do", False])
        elif token in ("end", "until"):
            if stack:
                stack.pop()
            if not stack:
                return match.end()
    return len(structural)


def implementations(source: str) -> list[tuple[int, str]]:
    """返回同函数体内同时出现三个实现标记的 `(行号, 函数名)`。"""
    lexical = strip_lua_noise(source, keep_strings=True)
    structural = strip_lua_noise(source, keep_strings=False)
    hits: list[tuple[int, str]] = []
    for match in _FUNCTION.finditer(lexical):
        end = _function_end(structural, match.end())
        body = lexical[match.start():end]
        if all(marker.search(body) for marker in IMPL_MARKERS):
            hits.append((structural.count("\n", 0, match.start()) + 1, match.group(1)))
    return hits


def _is_delegate(source: str) -> bool:
    lexical = strip_lua_noise(source, keep_strings=True)
    return bool(DELEGATE_GUARD.search(lexical) and DELEGATE_CALL.search(lexical))


def test_money_format_has_a_single_implementation():
    """前向：`[custom]` 内 0 份实现体；8 个门面 ≤10 行且只转调 owner。"""
    assert CUSTOM.is_dir(), "找不到 [custom] 资源目录，扫描范围被改坏了？"
    assert (BASE / OWNER).is_file(), f"唯一实现不存在：{OWNER}"

    problems: list[str] = []
    reported: set[str] = set()

    for path in sorted(CUSTOM.rglob("*.lua")):
        relative = path.relative_to(BASE).as_posix()
        source = path.read_text(encoding="utf-8", errors="ignore")
        hits = implementations(source)
        if not hits:
            continue
        if relative == DELEGATE and _is_delegate(source):
            continue
        for line, name in hits:
            problems.append(
                f"{relative}:{line}: {name}() 是一份完整的金额格式化实现 —— "
                "唯一实现是 core-framework/shared/util.lua 的 FormatMoney；"
                "这里只允许 ≤10 行、只转调 exports['core-framework']:FormatMoney 的门面")
        reported.add(relative)

    for relative, function_name in FACADES.items():
        path = BASE / relative
        if not path.is_file():
            problems.append(f"{relative}: 门面文件不存在（8 个资源各保留一份）")
            continue
        if relative in reported:
            continue                       # 已按「实现体」报告过，避免同一文件两条
        text = path.read_text(encoding="utf-8", errors="ignore")
        content = strip_lua_noise(text, keep_strings=True)
        if len(text.splitlines()) > MAX_FACADE_LINES:
            problems.append(
                f"{relative}: {len(text.splitlines())} 行，门面必须 ≤{MAX_FACADE_LINES} 行"
                "（超出说明实现体又长回来了）")
        if not re.search(rf"\bfunction\s+{re.escape(function_name)}\s*\(", content):
            problems.append(f"{relative}: 必须保留原函数名 {function_name}()（调用点不许改名）")
        if not EXPORT_CALL.search(content):
            problems.append(
                f"{relative}: 必须转调 exports['core-framework']:FormatMoney(...)")
        if any(marker.search(content) for marker in IMPL_MARKERS):
            problems.append(f"{relative}: 门面里仍有实现体（tonumber / % 1 == 0 / %.2f）")

    assert not problems, (
        "金额格式化实现只允许一份：core-framework/shared/util.lua 的 FormatMoney。"
        "8 个 [custom] shared/money_format.lua 必须是 ≤10 行、只转调 "
        "exports['core-framework']:FormatMoney 的门面（委托 fallback 与 [qb] 上游除外）。\n  "
        + "\n  ".join(problems))


def test_reverse_money_format_alias_is_rejected():
    """反向：别名实现必须报；只转调 owner、安全 `$%s`、注释示例不许报。"""
    rogue = (
        "local function PhoneMoney(value)\n"
        "    local num = tonumber(value)\n"
        "    if not num then return '0' end\n"
        "    if num % 1 == 0 then return ('%d'):format(num) end\n"
        "    return ('%.2f'):format(num)\n"
        "end\n")
    assert implementations(rogue), "没抓到第二份金额格式化实现（PhoneMoney 别名）"

    assert not implementations(
        "function Money(value)\n"
        "    return exports['core-framework']:FormatMoney(value)\n"
        "end\n"
    ), "只转调 owner 的门面被误报"

    assert not implementations(
        "local text = ('$%s'):format(Money(1))\n"
    ), "安全的 $%s 文案被误报"

    assert not implementations(
        "-- local function Money(v) local n = tonumber(v);\n"
        "-- if n % 1 == 0 then return ('%d'):format(n) end; return ('%.2f'):format(n)\n"
    ), "注释里的示例实现被误报"
