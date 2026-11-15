"""ARCH — 金额格式化只有一个 owner + 别名接线（S6 返工）。

为什么需要这两条规则：

1. **实现只有一份**：金额可能是小数（比例 / 乘算 / 客户端传入），`('%d'):format(x)`
   在 Lua 5.4 对小数直接抛 `number has no integer representation`，而抛错往往发生在
   「钱已到账 / 审计没写」之后。唯一实现是 `core-framework/shared/util.lua` 的
   `FormatMoney`。历史名字 `Money` / `PhoneMoney` / `QuestMoney` / `TCMoney` 只是调用点
   的引用面，**集中定义一次**在 `core-framework/shared/money_aliases.lua`；各资源已经
   删掉自己那份逐行相同的门面，不许再抄回来。

2. **别名必须真的被加载**：别名文件定义了全局函数，但资源不 include 它时，
   调用点会在运行时报 `attempt to call a nil value (global 'Money')`。静态闸门正是
   该拦这种接线错误的地方：任何 `[custom]` 资源只要调用了这四个名字，它的
   `fxmanifest.lua` 就必须 include `@core-framework/shared/money_aliases.lua`
   （或该资源自己定义了同名等价函数）。

判定口径：

* 扫描 `resources/[custom]/**/*.lua`，找**函数体**里同时出现 `tonumber(...)`、
  `% 1 == 0`、`%.2f` 的实现；
* `custom-quest/client/quest_hotdog_vendor_client.lua` 的委托 fallback
  （先 `if type(QuestMoney) == 'function' then return QuestMoney(value) end`）允许；
* `[custom]` 里非 `local` 的 `function Money(...)` 等全局定义 = 又抄回一份门面 → 红；
* `[qb]/qb-drugs/shared/money_format.lua` 是上游资源，不在 `[custom]` 扫描范围。

`test_reverse_money_format_alias_is_rejected` 与
`test_money_alias_users_load_the_alias_file` 里的反向用例都用合成源码/资源证明规则会红。

    python -m pytest -q tests/architecture/test_money_format_single_owner.py
"""
from __future__ import annotations

import re
import tempfile
from pathlib import Path

from lua_source import blank_noise

BASE = Path(__file__).resolve().parents[2]
CUSTOM = BASE / "resources" / "[custom]"

#: 唯一实现与唯一别名文件（都在 [standalone]，不在 [custom] 扫描根内；显式写出便于审计）。
OWNER = "resources/[standalone]/core-framework/shared/util.lua"
ALIASES = "resources/[standalone]/core-framework/shared/money_aliases.lua"
ALIAS_INCLUDE = "@core-framework/shared/money_aliases.lua"
ALIAS_NAMES = ("Money", "PhoneMoney", "QuestMoney", "TCMoney")

#: S6 之前每个资源一份的门面；删除后不许再出现（出现即有人又抄回一份）。
DELETED_FACADES = (
    "resources/[custom]/custom-market/shared/money_format.lua",
    "resources/[custom]/custom-main/shared/money_format.lua",
    "resources/[custom]/custom-cartel/shared/money_format.lua",
    "resources/[custom]/custom-security/shared/money_format.lua",
    "resources/[custom]/custom-crime/shared/money_format.lua",
    "resources/[custom]/custom-phone/shared/money_format.lua",
    "resources/[custom]/custom-quest/shared/money_format.lua",
    "resources/[custom]/custom-taxes/shared/money_format.lua",
)

#: 委托 fallback：先问 QuestMoney，拿不到才走本地兜底；不是第二份实现。
DELEGATE = "resources/[custom]/custom-quest/client/quest_hotdog_vendor_client.lua"

_FUNCTION = re.compile(r"\b(?:local\s+)?function\s+([A-Za-z_][\w.:]*)\s*\(")
_TOKEN = re.compile(r"\b(?:function|if|for|while|repeat|do|end|until)\b")
_GLOBAL_ALIAS_DEF = re.compile(r"\bfunction\s+(Money|PhoneMoney|QuestMoney|TCMoney)\s*\(")
_ALIAS_CALL = re.compile(r"(?<![:.\w])(Money|PhoneMoney|QuestMoney|TCMoney)\s*\(")
_ALIAS_DEF_SUB = re.compile(r"\bfunction\s+(?:Money|PhoneMoney|QuestMoney|TCMoney)\s*\(")
_DIRECT_ALIAS_DEF = re.compile(
    r"\b(?:local\s+)?function\s+(Money|PhoneMoney|QuestMoney|TCMoney)\s*\(")

#: 一份「金额格式化实现」的三个语义标记；缺一个就不是这条规则要抓的形状。
IMPL_MARKERS = (
    re.compile(r"\btonumber\s*\("),
    re.compile(r"%\s*1\s*==\s*0"),
    re.compile(r"%\.2f"),
)

EXPORT_CALL = re.compile(r"exports\s*\[\s*'core-framework'\s*\]\s*:\s*FormatMoney\s*\(")
DELEGATE_GUARD = re.compile(r"type\s*\(\s*QuestMoney\s*\)\s*==\s*'function'")
DELEGATE_CALL = re.compile(r"return\s+QuestMoney\s*\(")


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
    lexical = blank_noise(source, keep_strings=True)
    structural = blank_noise(source, keep_strings=False)
    hits: list[tuple[int, str]] = []
    for match in _FUNCTION.finditer(lexical):
        end = _function_end(structural, match.end())
        body = lexical[match.start():end]
        if all(marker.search(body) for marker in IMPL_MARKERS):
            hits.append((structural.count("\n", 0, match.start()) + 1, match.group(1)))
    return hits


def global_alias_definitions(source: str) -> list[tuple[int, str]]:
    """`[custom]` 里非 `local` 的 `function Money(...)` 等 → (行号, 名字)。"""
    structural = blank_noise(source, keep_strings=False)
    hits: list[tuple[int, str]] = []
    for match in _GLOBAL_ALIAS_DEF.finditer(structural):
        line_start = structural.rfind("\n", 0, match.start()) + 1
        if re.search(r"\blocal\s+$", structural[line_start:match.start()]):
            continue                       # `local function Money(...)` 是文件内委托，允许
        hits.append((structural.count("\n", 0, match.start()) + 1, match.group(1)))
    return hits


def alias_calls(source: str) -> set[str]:
    """返回源码里调用的别名（剥注释/字符串；函数定义不算调用）。"""
    structural = blank_noise(source, keep_strings=False)
    structural = _ALIAS_DEF_SUB.sub("function __alias_definition(", structural)
    return {match.group(1) for match in _ALIAS_CALL.finditer(structural)}


def _is_delegate(source: str) -> bool:
    lexical = blank_noise(source, keep_strings=True)
    return bool(DELEGATE_GUARD.search(lexical) and DELEGATE_CALL.search(lexical))


def _manifest_text(resource: Path) -> str:
    manifest = resource / "fxmanifest.lua"
    return manifest.read_text(encoding="utf-8", errors="ignore") if manifest.is_file() else ""


def _defines_alias(resource: Path, name: str) -> bool:
    pattern = re.compile(rf"\bfunction\s+{re.escape(name)}\s*\(")
    for path in resource.rglob("*.lua"):
        if path.name == "fxmanifest.lua":
            continue
        if pattern.search(blank_noise(
                path.read_text(encoding="utf-8", errors="ignore"), keep_strings=False)):
            return True
    return False


def alias_wiring_problems(resources: list[Path]) -> list[str]:
    """资源调用了别名、但既没 include 别名文件、也没定义等价函数的那些资源。"""
    problems: list[str] = []
    for resource in sorted(resources):
        used: set[str] = set()
        for path in resource.rglob("*.lua"):
            if path.name in ("fxmanifest.lua", "__resource.lua"):
                continue
            used |= alias_calls(path.read_text(encoding="utf-8", errors="ignore"))
        if not used:
            continue
        if ALIAS_INCLUDE in _manifest_text(resource):
            continue
        missing = sorted(name for name in used if not _defines_alias(resource, name))
        if missing:
            problems.append(
                f"{resource.name}: 调用了 {', '.join(f'{name}()' for name in missing)}，"
                f"但 fxmanifest.lua 没有 '{ALIAS_INCLUDE}'（运行时会 attempt to call a nil value）")
    return problems


def custom_resources() -> list[Path]:
    return sorted(path for path in CUSTOM.iterdir() if path.is_dir())


def test_money_format_has_a_single_implementation():
    """前向：`[custom]` 内 0 份实现、0 个全局别名；别名只在唯一文件里定义一次。"""
    assert CUSTOM.is_dir(), "找不到 [custom] 资源目录，扫描范围被改坏了？"
    assert (BASE / OWNER).is_file(), f"唯一实现不存在：{OWNER}"

    problems: list[str] = []

    for relative in DELETED_FACADES:
        if (BASE / relative).exists():
            problems.append(
                f"{relative}: 旧门面已删除，不许再出现 —— "
                f"别名只在 {ALIASES} 定义一次，资源通过 '{ALIAS_INCLUDE}' 加载")

    for path in sorted(CUSTOM.rglob("*.lua")):
        relative = path.relative_to(BASE).as_posix()
        source = path.read_text(encoding="utf-8", errors="ignore")
        hits = implementations(source)
        if relative == DELEGATE and _is_delegate(source):
            hits = []
        for line, name in hits:
            problems.append(
                f"{relative}:{line}: {name}() 是一份完整的金额格式化实现 —— "
                f"唯一实现是 {OWNER} 的 FormatMoney")
        for line, name in global_alias_definitions(source):
            problems.append(
                f"{relative}:{line}: 又定义了全局 {name}()（第二份门面）—— "
                f"别名只在 {ALIASES} 定义一次")

    alias_path = BASE / ALIASES
    if not alias_path.is_file():
        problems.append(f"{ALIASES}: 别名文件不存在")
    else:
        content = blank_noise(
            alias_path.read_text(encoding="utf-8", errors="ignore"), keep_strings=True)
        for name in ALIAS_NAMES:
            if not re.search(rf"\bfunction\s+{name}\s*\(", content):
                problems.append(f"{ALIASES}: 缺别名 {name}()")
        if not EXPORT_CALL.search(content):
            problems.append(
                f"{ALIASES}: 必须转调 exports['core-framework']:FormatMoney(...)")
        if any(marker.search(content) for marker in IMPL_MARKERS):
            problems.append(f"{ALIASES}: 别名文件里出现了实现体（tonumber / % 1 == 0 / %.2f）")

    assert not problems, (
        "金额格式化实现只允许一份（core-framework/shared/util.lua 的 FormatMoney）；"
        f"四个历史别名只在 {ALIASES} 定义一次，资源 include '{ALIAS_INCLUDE}'。\n  "
        + "\n  ".join(problems))


def test_reverse_money_format_alias_is_rejected():
    """反向：别名实现/全局复制必须报；local 委托、安全 `$%s`、注释示例不许报。"""
    rogue = (
        "local function PhoneMoney(value)\n"
        "    local num = tonumber(value)\n"
        "    if not num then return '0' end\n"
        "    if num % 1 == 0 then return ('%d'):format(num) end\n"
        "    return ('%.2f'):format(num)\n"
        "end\n")
    assert implementations(rogue), "没抓到第二份金额格式化实现（PhoneMoney 别名）"

    assert global_alias_definitions(
        "function Money(value) return exports['core-framework']:FormatMoney(value) end\n"
    ), "又抄回一份全局别名门面没被抓住"
    assert not global_alias_definitions(
        "local function Money(value) return alias(value) end\n"
    ), "文件内 local 委托被误报"

    assert not implementations(
        "function Money(value)\n"
        "    return exports['core-framework']:FormatMoney(value)\n"
        "end\n"
    ), "只转调 owner 的别名被误报"

    assert not implementations(
        "local text = ('$%s'):format(Money(1))\n"
    ), "安全的 $%s 文案被误报"

    assert not implementations(
        "-- local function Money(v) local n = tonumber(v);\n"
        "-- if n % 1 == 0 then return ('%d'):format(n) end; return ('%.2f'):format(n)\n"
    ), "注释里的示例实现被误报"


def test_money_alias_users_load_the_alias_file():
    """前向：调用别名的 [custom] 资源都在 fxmanifest 里加载了别名文件。"""
    assert CUSTOM.is_dir(), "找不到 [custom] 资源目录，扫描范围被改坏了？"

    problems = alias_wiring_problems(custom_resources())

    # 反向：合成一个调 Money() 但 manifest 没 include 的资源，必须红；
    # 补上 include 之后必须绿（证明规则不是永远红）。
    with tempfile.TemporaryDirectory() as tmp:
        resource = Path(tmp) / "custom-demo"
        (resource / "server").mkdir(parents=True)
        (resource / "fxmanifest.lua").write_text(
            "fx_version 'cerulean'\nserver_scripts { 'server/main.lua' }\n", encoding="utf-8")
        (resource / "server" / "main.lua").write_text(
            "CreateThread(function() print(Money(1)) end)\n", encoding="utf-8")
        wired = alias_wiring_problems([resource])
        assert wired, "调用了 Money() 但 fxmanifest 没 include 别名文件的资源没被抓住"

        (resource / "fxmanifest.lua").write_text(
            "fx_version 'cerulean'\nshared_scripts { '"
            + ALIAS_INCLUDE + "' }\n", encoding="utf-8")
        assert not alias_wiring_problems([resource]), "补上 include 后规则仍然红（永远红）"

    assert not problems, (
        "这些 [custom] 资源调用了金额别名，但 fxmanifest 没加载别名文件"
        f"（'{ALIAS_INCLUDE}'），运行时会 attempt to call a nil value：\n  "
        + "\n  ".join(problems))
