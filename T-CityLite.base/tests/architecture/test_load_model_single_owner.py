"""ARCH — 模型加载只有一个 owner：`CFShared.LoadModel`（S5）。

为什么需要这条规则：客户端 `RequestModel(hash)` 之后的 `while not HasModelLoaded(hash)`
如果只有 `Wait(10)`，模型缺失（拼错、没进 cdimage、服务器没这条 stream）时线程永远不退出。
`CFShared.LoadModel` 是唯一实现：先 `IsModelInCdimage` 挡掉不存在的模型，再带超时等待，
失败经 `CFShared.Report` 上报一次（每进程同类失败只报一条）。

判定口径刻意是「**无退出条件的循环**」而不是「出现 RequestModel」：

* 红：`while not HasModelLoaded(...)` / `while not NativeBool(HasModelLoaded(...))`，且
  整个循环（条件 + 循环体）里没有 `GetGameTimer() < deadline`、`timeout < N`、
  `generation ~= ...` 这类退出条件；
* 绿：有界循环（热狗两个文件的 `deadline`/`generation` 形状）、`CFShared.LoadModel` 调用、
  注释/字符串里的同名文本；
* 另外 7 个调用文件必须真的改用 `CFShared.LoadModel`；`entity_util.lua` 只保留
  `EntityUtil.Delete`，不得再定义 `EntityUtil.LoadModel` 或本地循环。

    python -m pytest -q tests/architecture/test_load_model_single_owner.py
"""
from __future__ import annotations

import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
CUSTOM = BASE / "resources" / "[custom]"

#: 计划 §4.6.1 的 7 个调用文件（相对 CUSTOM）—— 必须出现 `CFShared.LoadModel`。
CALLERS = (
    "custom-police/client/coroner.lua",
    "custom-police/client/tow.lua",
    "custom-police/client/lockdown.lua",
    "custom-police/client/scenery.lua",
    "custom-cartel/client/main.lua",
    "custom-quest/client/main.lua",
    "custom-quest/client/quest_logistics_client.lua",
)

ENTITY_UTIL = "custom-police/client/entity_util.lua"

#: `while <cond> do` —— 条件在同一行（本仓没有跨行条件）。
WHILE_RE = re.compile(r"\bwhile\b(?P<cond>[^\n]*?)\bdo\b")
#: `not HasModelLoaded(...)` / `not NativeBool(HasModelLoaded(...))`
NEGATED_LOADED_RE = re.compile(
    r"\bnot\s+(?:NativeBool\s*\(\s*)?HasModelLoaded\s*\(")
LOADED_RE = re.compile(r"\bHasModelLoaded\s*\(")
LOCAL_DEF_RE = re.compile(r"\bfunction\s+EntityUtil\.LoadModel\s*\(")
REQUEST_RE = re.compile(r"\bRequestModel\s*\(")

#: 退出条件的形状：时间 deadline、计数器上限、代际（generation）任一即可。
_COMPARE = r"(?:<=|>=|==|~=|<|>)"
_EXIT_RE = re.compile(
    r"GetGameTimer\s*\(\s*\)\s*" + _COMPARE
    + r"|\b(?:deadline|timeout|attempts?|tries|retries?|generation)\b\s*" + _COMPARE
    + r"|" + _COMPARE + r"\s*\b(?:deadline|timeout|attempts?|tries|retries?|generation)\b")

#: 循环体里会开合块的 Lua 关键字（`else`/`elseif` 不改变深度）。
_LUA_TOKEN = re.compile(r"\b(?:function|if|for|while|repeat|do|end|until)\b")
_LONG_BRACKET = re.compile(r"\[(=*)\[")


def _blank(text: str) -> str:
    """用空格替换注释/字符串，保留换行（行号仍然对得上）。"""
    return "".join("\n" if char == "\n" else " " for char in text)


def strip_lua_noise(source: str) -> str:
    """去掉 Lua 的注释与字符串字面量，只留代码（长度/行号不变）。"""
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
                out.append(_blank(source[index:end]))
                index = end
                continue
        if char in "\"'":
            cursor = index + 1
            while cursor < size:
                if source[cursor] == "\\":
                    cursor += 2
                    continue
                if source[cursor] == char:
                    cursor += 1
                    break
                cursor += 1
            out.append(_blank(source[index:cursor]))
            index = cursor
            continue
        out.append(char)
        index += 1
    return "".join(out)


def line_of(source: str, index: int) -> int:
    return source.count("\n", 0, index) + 1


def _loop_end(code: str, body_start: int) -> int:
    """从 `while ... do` 的 `do` 之后开始，返回该循环匹配 `end` 之后的位置。"""
    stack: list[list] = [["while", False]]   # [kind, 等待它自己的 do]
    for match in _LUA_TOKEN.finditer(code, body_start):
        token = match.group(0)
        if token in ("function", "if", "repeat"):
            stack.append([token, False])
        elif token in ("for", "while"):
            stack.append([token, True])
        elif token == "do":
            if stack and stack[-1][0] in ("for", "while") and stack[-1][1]:
                stack[-1][1] = False        # `for ... do` / `while ... do` 的 do 不再开层
            else:
                stack.append(["do", False])
        elif token == "end":
            if stack:
                stack.pop()
            if not stack:
                return match.end()
        elif token == "until":
            if stack and stack[-1][0] == "repeat":
                stack.pop()
            elif stack:
                stack.pop()                 # 容错：坏语法也别把扫描器卡死
            if not stack:
                return match.end()
    return len(code)


def unbounded_model_loops(source: str) -> list[int]:
    """返回无退出条件的 `while not HasModelLoaded` 循环的行号（1 起）。"""
    code = strip_lua_noise(source)
    hits: list[int] = []
    for match in WHILE_RE.finditer(code):
        if not NEGATED_LOADED_RE.search(match.group("cond")):
            continue
        loop_text = code[match.start():_loop_end(code, match.end())]
        if _EXIT_RE.search(loop_text):
            continue
        hits.append(line_of(code, match.start()))
    return hits


def _client_files() -> list[Path]:
    return sorted(
        path for path in CUSTOM.rglob("*.lua")
        if "client" in path.relative_to(CUSTOM).parts)


def _label(path: Path) -> str:
    return path.relative_to(CUSTOM).as_posix()


def test_no_local_loadmodel_loops():
    """前向：无退出条件的本地模型循环为 0；7 个调用文件与 entity_util 完成收口。"""
    assert CUSTOM.is_dir(), "找不到 [custom] 资源目录，扫描范围被改坏了？"
    problems: list[str] = []

    for path in _client_files():
        relative = _label(path)
        source = path.read_text(encoding="utf-8", errors="ignore")
        code = strip_lua_noise(source)
        for line in unbounded_model_loops(source):
            problems.append(
                f"{relative}:{line}: 无退出条件的本地模型加载循环 —— "
                "改用 CFShared.LoadModel(hash, timeoutMs)")
        stale_at = code.find("EntityUtil.LoadModel")
        if stale_at != -1:
            problems.append(
                f"{relative}:{line_of(code, stale_at)}: 仍引用 EntityUtil.LoadModel —— "
                "本地实现已删除，改用 CFShared.LoadModel")

    util = CUSTOM / ENTITY_UTIL
    if not util.is_file():
        problems.append(f"{ENTITY_UTIL}: 文件不存在（应保留 EntityUtil.Delete）")
    else:
        util_code = strip_lua_noise(util.read_text(encoding="utf-8", errors="ignore"))
        local_loop = any(
            LOADED_RE.search(match.group("cond")) for match in WHILE_RE.finditer(util_code))
        if LOCAL_DEF_RE.search(util_code) or local_loop:
            problems.append(
                f"{ENTITY_UTIL}: 仍保留本地模型加载实现（EntityUtil.LoadModel/while "
                "HasModelLoaded）—— 只保留 EntityUtil.Delete，模型加载走 CFShared.LoadModel")

    for relative in CALLERS:
        path = CUSTOM / relative
        if not path.is_file():
            problems.append(f"{relative}: 迁移文件不存在")
            continue
        code = strip_lua_noise(path.read_text(encoding="utf-8", errors="ignore"))
        if "CFShared.LoadModel" not in code:
            request = REQUEST_RE.search(code)
            where = f"{relative}:{line_of(code, request.start())}" if request else relative
            problems.append(
                f"{where}: 7 个调用文件必须改用 CFShared.LoadModel，"
                "不许再留本地/别名实现")

    assert not problems, (
        "模型加载唯一 owner 是 CFShared.LoadModel（core-framework/client/shared.lua）。"
        "无退出条件的循环会在模型缺失时把客户端线程卡死；失败也必须经 CFShared.Report "
        "上报一次。\n  " + "\n  ".join(problems))


def test_reverse_unbounded_model_loop_is_rejected():
    """反向：无退出条件的循环必须报；有界循环、共享调用、注释/字符串不许报。"""
    assert unbounded_model_loops(
        "RequestModel(hash)\n"
        "while not HasModelLoaded(hash) do\n    Wait(10)\nend\n")
    assert unbounded_model_loops(
        "while not NativeBool(HasModelLoaded(hash)) do Citizen.Wait(10) end\n")

    assert not unbounded_model_loops(
        "RequestModel(hash)\n"
        "local deadline = GetGameTimer() + 5000\n"
        "while not HasModelLoaded(hash) and GetGameTimer() < deadline do\n"
        "    Wait(10)\n"
        "end\n")
    assert not unbounded_model_loops(
        "local deadline = GetGameTimer() + 5000\n"
        "while not NativeBool(HasModelLoaded(hash)) and GetGameTimer() < deadline do\n"
        "    Wait(50)\n"
        "    if generation ~= current then return end\n"
        "end\n")
    assert not unbounded_model_loops(
        "local timeout = 0\n"
        "while not HasModelLoaded(hash) do\n"
        "    Wait(10)\n"
        "    timeout = timeout + 1\n"
        "    if timeout > 300 then return end\n"
        "end\n")

    assert not unbounded_model_loops("CFShared.LoadModel(hash, 5000)\n")
    assert not unbounded_model_loops(
        "-- while not HasModelLoaded(hash) do Wait(10) end\n"
        "local sample = \"while not HasModelLoaded(hash) do Wait(10) end\"\n")
