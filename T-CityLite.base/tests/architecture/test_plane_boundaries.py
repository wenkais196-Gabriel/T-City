"""PLANE-01 — 四个平面的依赖方向（`docs/engineering/ARCHITECTURE.md`）。

只拦**架构性**越界，不碰风格：

* P2 client 不得直接碰 DB（`MySQL.*` / `exports['oxmysql']`）——绕过服务端权威；
* P3 server 不得调用"客户端原生"（`SetNuiFocus` / `SendNUIMessage`），那只存在于客户端；
* P0 shared 不得注册事件 / 抢焦点——它必须能被任意平面安全引用；
* `fxmanifest` 的 `client_scripts` 不得列出 `server/` 下的文件（会把服务端代码灌进客户端）。

判定前先剥离 Lua 注释：注释里提到 `SetNuiFocus(true)` 是解释，不是越界
（`story-engine/server/decision_engine.lua` 就有一处，防止误报）。

反向校验在最后，喂进错误形状必须报红。

Run: ``python3 -m pytest -q tests/architecture/test_plane_boundaries.py``
"""

from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"

DB_TOKENS = (r"\bMySQL\s*\.", r"""exports\s*\[\s*['"]oxmysql['"]\s*\]""")
CLIENT_NATIVE_TOKENS = (r"\bSetNuiFocus\s*\(", r"\bSendNUIMessage\s*\(")
PLANE_API_TOKENS = (r"\bRegisterNetEvent\b", r"\bTriggerClientEvent\s*\(", r"\bSetNuiFocus\s*\(")

LINE_COMMENT = re.compile(r"--[^\n]*")
BLOCK_COMMENT = re.compile(r"--\[(=*)\[.*?\]\1\]", re.S)


def strip_lua_comments(text: str) -> str:
    return LINE_COMMENT.sub("", BLOCK_COMMENT.sub("", text))


def find_tokens(text: str, patterns) -> list[str]:
    clean = strip_lua_comments(text)
    hits = []
    for pat in patterns:
        for m in re.finditer(pat, clean):
            line = clean[: m.start()].count("\n") + 1
            hits.append(f"{m.group(0).strip()} @line {line}")
    return hits


def manifest_client_script_entries(text: str) -> list[str]:
    """取 `client_scripts { ... }` 表里的条目（按大括号配平，不跨到 server_scripts）。"""
    entries: list[str] = []
    idx = text.find("client_scripts")
    while idx != -1:
        open_brace = text.find("{", idx)
        if open_brace == -1:
            break
        depth, pos = 0, open_brace
        while pos < len(text):
            if text[pos] == "{":
                depth += 1
            elif text[pos] == "}":
                depth -= 1
                if depth == 0:
                    break
            pos += 1
        block = text[open_brace : pos + 1]
        entries.extend(re.findall(r"""['"]([^'"]+)['"]""", block))
        idx = text.find("client_scripts", pos)
    return entries


def scan(root: Path) -> list[str]:
    problems: list[str] = []
    for lua in root.rglob("client/**/*.lua"):
        if "node_modules" in lua.parts:
            continue
        for hit in find_tokens(lua.read_text(encoding="utf-8", errors="ignore"), DB_TOKENS):
            problems.append(f"[client→DB] {lua.relative_to(root.parent)}: {hit}")
    for lua in root.rglob("server/**/*.lua"):
        if "node_modules" in lua.parts:
            continue
        for hit in find_tokens(lua.read_text(encoding="utf-8", errors="ignore"), CLIENT_NATIVE_TOKENS):
            problems.append(f"[server→NUI] {lua.relative_to(root.parent)}: {hit}")
    for lua in root.rglob("shared/**/*.lua"):
        if "node_modules" in lua.parts:
            continue
        for hit in find_tokens(lua.read_text(encoding="utf-8", errors="ignore"), PLANE_API_TOKENS):
            problems.append(f"[shared→plane api] {lua.relative_to(root.parent)}: {hit}")
    for manifest in root.rglob("fxmanifest.lua"):
        if "node_modules" in manifest.parts:
            continue
        for entry in manifest_client_script_entries(manifest.read_text(encoding="utf-8", errors="ignore")):
            if entry.startswith("server/"):
                problems.append(f"[manifest client←server] {manifest.relative_to(root.parent)}: {entry}")
    return problems


def test_planes_do_not_leak_across_boundaries():
    problems = scan(RESOURCES)
    assert not problems, (
        "平面越界（见 docs/engineering/ARCHITECTURE.md §1/§2）：\n" + "\n".join(problems[:40])
        + (f"\n…共 {len(problems)} 处" if len(problems) > 40 else "")
    )


def test_comment_stripping_keeps_prose_from_tripping_the_rule():
    src = """
    -- SetNuiFocus(true) 会把控制锁死，所以这里用事件关界面
    TriggerClientEvent('story:client:closeDecision', source)
    """
    assert not find_tokens(src, CLIENT_NATIVE_TOKENS)


def test_rules_fire_on_bad_shapes():
    assert find_tokens("MySQL.Async.fetchAll('SELECT 1')", DB_TOKENS)
    assert find_tokens("""exports['oxmysql']:query('SELECT 1')""", DB_TOKENS)
    assert find_tokens("SetNuiFocus(true, true)", CLIENT_NATIVE_TOKENS)
    assert find_tokens("RegisterNetEvent('x', function() end)", PLANE_API_TOKENS)

    manifest_bad = "client_scripts {\n  'client/main.lua',\n  'server/main.lua',\n}\nserver_scripts { 'server/main.lua' }"
    assert "server/main.lua" in manifest_client_script_entries(manifest_bad)
    manifest_good = "client_scripts { 'client/main.lua' }\nserver_scripts {\n  'server/main.lua',\n}"
    assert manifest_client_script_entries(manifest_good) == ["client/main.lua"]
