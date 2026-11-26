"""Lua 里混进 JavaScript 语法 —— 全仓扫描（先剥注释与字符串）。

2026-11-26：`qb-target/client.lua` 里 8 处 `zone.targetoptions.drawColor?[1]`
（JS 可选链）让整个资源**解析失败**，而这行在仓里躺了很久没人发现 —— CI 的
`Lua syntax (changed files)` 只解析**本次改动**的文件，存量错误永远检查不到。

线上为什么看起来没事：FXServer 用 `cache/` 里的旧字节码，文件改了不重启就不重编译。
一旦重启就是「整个 qb-target 不加载」——这种雷必须在仓库层拦。

判据只看**代码**：先剥掉字符串与注释再匹配，避免 `print('broke??')` 这类误报。
"""

from __future__ import annotations

import re
from pathlib import Path

RESOURCES = Path(__file__).resolve().parents[2] / "resources"

#: Lua 里不可能出现的 JS 专有形。
JS_TOKENS = (
    re.compile(r"\w\s*\?\s*\["),   # a?[1]
    re.compile(r"\w\s*\?\s*\w"),   # a?.b  /  a ? b
    re.compile(r"=>"),                 # (x) => y
)


def _strip_literals(text: str) -> str:
    """把字符串与注释替换成空格，保留换行与列位置。"""
    out: list[str] = []
    i, n = 0, len(text)

    def blank(span: str) -> None:
        out.append("".join(ch if ch == "\n" else " " for ch in span))

    while i < n:
        if text.startswith("--[[", i) or text.startswith("--[=[", i):
            end = text.find("]]", i + 4)
            end = n if end < 0 else end + 2
            blank(text[i:end]); i = end
        elif text.startswith("--", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            blank(text[i:end]); i = end
        elif text.startswith("[[", i):
            end = text.find("]]", i)
            end = n if end < 0 else end + 2
            blank(text[i:end]); i = end
        elif text[i] in ("'", '"'):
            quote, j = text[i], i + 1
            while j < n and text[j] != quote:
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            blank(text[i:j]); i = j
        else:
            out.append(text[i]); i += 1
    return "".join(out)


def scan_lua_for_js_tokens(root: Path) -> list[str]:
    hits: list[str] = []
    for path in sorted(root.rglob("*.lua")):
        code = _strip_literals(path.read_text(encoding="utf-8", errors="replace"))
        for lineno, line in enumerate(code.splitlines(), start=1):
            if any(pattern.search(line) for pattern in JS_TOKENS):
                hits.append(f"{path.relative_to(root)}:{lineno}: {line.strip()[:90]}")
    return hits


def test_lua_rejects_javascript_syntax() -> None:
    assert RESOURCES.is_dir(), f"missing {RESOURCES}"
    hits = scan_lua_for_js_tokens(RESOURCES)
    assert hits == [], (
        "以下 Lua 文件里有 JavaScript 专有语法，FiveM 会解析失败：\n" + "\n".join(hits)
    )


def test_scan_detects_the_optional_chaining_shape() -> None:
    """自证：真实事故形状必须被抓到；字符串里的 `??` 不许被误报。"""
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "victim.lua").write_text(
            "local r = zone.targetoptions.drawColor?[1] or Config.DrawColor[1]\n",
            encoding="utf-8",
        )
        assert scan_lua_for_js_tokens(Path(tmp)) != [], "抓不住可选链，等于没有闸门"

        (Path(tmp) / "victim.lua").unlink()
        (Path(tmp) / "ok.lua").write_text(
            "print('you are broke??')\n-- a?.b in a comment is fine\n",
            encoding="utf-8",
        )
        assert scan_lua_for_js_tokens(Path(tmp)) == [], "字符串/注释里的问号被误报"
