"""扫描「顶层缓存 QBCore 但没有重挂」的风险文件 —— 唯一实现，闸门与统计共用。

背景（真机 2026-11-07）：qb-clothing 报
`Execution of function reference in script host failed`。原因是文件顶层

    local QBCore = exports['qb-core']:GetCoreObject()

拿到的是 **qb-core 当次 script host 的快照**，表里的函数是函数引用；`restart qb-core`
之后旧引用全部失效。这与 PR #193 修的「MySQL 回调里调跨资源引用」不是同一类问题：
那次是**上下文**不对，这次是**缓存过期**。

判定（四个条件同时成立才算风险）：
  1. 文件顶层（列 0）缓存 `local <var> = exports['qb-core']:GetCoreObject(`；
     —— 一个文件可能有**多个**缓存变量，逐个判，不能只看第一个；
  2. 文件里用了 `<var>.Functions` / `.Player` / `.Commands` / `.ServerCallbacks` / `.ClientCallbacks`；
  3. 文件里**没有**在这个事件处理器的函数体里给**同一个变量**重新赋值 `GetCoreObject()`
     （有重挂 = 自愈）。判重挂必须结构匹配：
       * 只认 `AddEventHandler('onResourceStart'|'onClientResourceStart', ...)`；
         `RegisterNetEvent` / 注释里出现事件名**不算**；
       * 窗口内必须是 `<var> = exports[...]:GetCoreObject()` 这种**赋值**，
         光出现 `GetCoreObject` 字样（`if` 判断、局部别名、注释）不算；
  4. 该资源**不在** `restart qb-core` 的级联停启范围内（fxmanifest 没有声明 qb-core 依赖）。
     在级联内的资源会随 `restart qb-core` 一起重启，自然重新执行顶层缓存 → 自愈。

口径保守：只认显式 `dependency/dependencies` 声明；用 `@qb-core/shared/…` 只算加载顺序，
不算依赖（真机实证：qb-clothing 就属于这种"声明了共享脚本但没声明依赖"的资源）。

**client 侧单独记账**：`onClientResourceStart('qb-core')` 的跨客户端语义还没在真机验证过，
所以 client 文件的风险不进基线棘轮，而是进 `client_unverified` 清单 —— 扫描器不替它们
宣布安全，修好一个就从清单里删一个。
"""

from __future__ import annotations

import json
import re
import sys
from bisect import bisect_right
from dataclasses import dataclass
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]          # T-CityLite.base/
RESOURCES = BASE / "resources"
BASELINE = Path(__file__).resolve().parent / "stale_core_cache_baseline.json"

CACHE = re.compile(
    r"^local\s+(\w+)\s*=\s*exports(?:\s*\[\s*['\"]qb-core['\"]\s*\]|\.qb-core)\s*:\s*GetCoreObject\s*\(",
    re.M,
)
REHOOK = re.compile(r"AddEventHandler\s*\(\s*['\"](?:onResourceStart|onClientResourceStart)['\"]")
USE_PATTERN = r"\.\s*(?:Functions|Player|Commands|ServerCallbacks|ClientCallbacks)\b"
CLIENT_SEGMENTS = {"client", "cl_client", "cl"}

COMMENT_BLOCK = re.compile(r"--\[=*\[.*?\]=*\]", re.S)   # 覆盖 --[[ ]] 与 --[=[ ]=] 长注释（不用反向引用，避免写入时被转义吃掉）
COMMENT_LINE = re.compile(r"--[^\n]*")


@dataclass(frozen=True)
class Risk:
    file: str           # 相对 resources/
    variable: str
    scope: str = "server"   # server | client

    @property
    def key(self) -> str:
        return f"{self.file}\u0000{self.variable}"


def _blank_comments(source: str, spans: list[tuple[int, int]] | None = None) -> str:
    """把注释替换成等长空白（保留行号）。**字符串内部的 `--` 不算注释**，所以按字符串区间切段处理。"""
    if spans is None:
        spans = _string_spans(source)

    def blank(match: re.Match[str]) -> str:
        return re.sub(r"[^\n]", " ", match.group(0))

    def segment(text: str) -> str:
        return COMMENT_LINE.sub(blank, COMMENT_BLOCK.sub(blank, text))

    pieces: list[str] = []
    cursor = 0
    for start, end in spans:
        pieces.append(segment(source[cursor:start]))
        pieces.append(source[start:end])      # 字符串原样保留
        cursor = end
    pieces.append(segment(source[cursor:]))
    return "".join(pieces)


def _scope(path: Path) -> str:
    """按目录段判 client；根目录下的 client.lua / cl_*.lua 也算（qb-banking、safecracker 就是这种）。"""
    parts = {part.lower() for part in path.parts}
    if parts & CLIENT_SEGMENTS:
        return "client"
    name = path.name.lower()
    if name == "client.lua" or name.startswith("cl_"):
        return "client"
    return "server"


def _manifest_path(resource_dir: Path) -> Path | None:
    """按**文件存在**判断资源根，不能按内容真值 —— 空 manifest 会让整个资源消失。"""
    for name in ("fxmanifest.lua", "__resource.lua"):
        candidate = resource_dir / name
        if candidate.is_file():
            return candidate
    return None


def _declares_qb_core(manifest: str) -> bool:
    """fxmanifest 是否显式声明 qb-core 依赖（会随 restart qb-core 被停掉）。"""
    if re.search(r"dependenc(?:y|ies)[^\n]*\n?(?:[^\n]*\n){0,8}?[^\n]*['\"]qb-core['\"]", manifest):
        return True
    return bool(re.search(r"^\s*['\"]?qb-core['\"]?\s*$", manifest, re.M)) and "dependenc" in manifest


def _string_spans(source: str) -> list[tuple[int, int]]:
    """找出字符串字面量的区间（含引号/长括号）。字符串里写着"赋值"或整个 handler 都不算代码。"""
    spans: list[tuple[int, int]] = []
    index = 0
    length = len(source)
    while index < length:
        char = source[index]
        if char in ("'", '"'):
            quote = char
            start = index
            index += 1
            while index < length:
                if source[index] == "\\":
                    index += 2
                    continue
                if source[index] == quote:
                    index += 1
                    break
                index += 1
            spans.append((start, index))
            continue
        if char == "[":
            bracket = re.match(r"\[(=*)\[", source[index:])
            if bracket:
                closer = "]" + bracket.group(1) + "]"
                end = source.find(closer, index + len(bracket.group(0)))
                end = length if end < 0 else end + len(closer)
                spans.append((index, end))
                index = end
                continue
        index += 1
    return spans


def _in_string(spans: list[tuple[int, int]], position: int) -> bool:
    if not spans:
        return False
    index = bisect_right(spans, (position, float("inf"))) - 1
    if index < 0:
        return False
    start, end = spans[index]
    return start <= position < end


def _handler_bodies(clean: str, spans: list[tuple[int, int]]):
    """把每个**真代码里**的 AddEventHandler('onResourceStart'…) 括号配对区间取出来。

    两处过滤：① 事件名出现在字符串里不算（长字符串伪造整个 handler）；② 窗口按括号配对，
    不按字符数猜。
    """
    for match in REHOOK.finditer(clean):
        if _in_string(spans, match.start()):
            continue
        open_index = clean.find("(", match.start())
        if open_index < 0:
            continue
        depth = 0
        for index in range(open_index, len(clean)):
            if _in_string(spans, index):
                continue                       # 字符串里的括号不参与配对
            char = clean[index]
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    yield clean[open_index:index + 1], open_index
                    break


def _has_rehook(source: str, variable: str) -> bool:
    """结构化判重挂：只在 AddEventHandler('onResourceStart'…) 的**函数体区间**里找，且必须是真赋值。

    两种安全写法（其余一律不算）：
      A. `<var> = exports['qb-core']:GetCoreObject()`（右值是**导出调用**本身）；
      B. `if ok and core then <var> = core end`，且 `core` 在同一区间里由
         `local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)` 绑定
         —— 真机实证 A 在 qb-core 刚起来时会偶发 failed，B 才稳。

    明确不接受（都有反向用例）：`<var> = <var>`、右值是死值/nil、赋值落在 `if not ok` 失败分支、
    赋值在 handler 之外、以及只出现字符串 `'GetCoreObject'` 而没有真调用。
    """
    spans = _string_spans(source)
    clean = _blank_comments(source, spans)
    export = r"exports\s*(?:\s*\[\s*['\x22]qb-core['\x22]\s*\]|\.qb-core)\s*:\s*GetCoreObject\s*\("
    direct = re.compile(r"\b" + re.escape(variable) + r"\s*=\s*" + export)
    retry_assign = re.compile(r"\b" + re.escape(variable) + r"\s*=\s*(\w+)\b")
    export_call = re.compile(export)
    for handler_body, offset in _handler_bodies(clean, spans):
        # 这两个判断在"整份 handler 的文本"上做，先把字符串区间换算成 handler 内坐标
        local_spans = [(start - offset, end - offset) for start, end in spans if end > offset and start < offset + len(handler_body)]

        def real_match(pattern: re.Pattern[str]) -> re.Match[str] | None:
            for match in pattern.finditer(handler_body):
                if not _in_string(local_spans, match.start()):
                    return match
            return None

        def unreachable(position: int) -> bool:
            """死分支 / 反了的事件名分支：赋值位置之前的同窗口守卫里能看出来。"""
            line_prefix = handler_body[handler_body.rfind("\n", 0, position) + 1: position]
            guard = handler_body[max(0, position - 220): position]
            if re.search(r"if\s+false\b", line_prefix + guard):
                return True
            # `if n ~= 'qb-core' then <赋值> end` = 反了的分支；`then return end` 是正常守卫，不算
            if re.search(
                r"~=\s*['\x22]qb-core['\x22][^\n]*\bthen\b(?![^\n]*\breturn\b)", guard
            ) and not re.search(r"==\s*['\x22]qb-core['\x22]", guard):
                return True
            return False

        match = real_match(direct)
        if match and not unreachable(match.start()):
            return True
        if not real_match(export_call):
            continue
        for match in retry_assign.finditer(handler_body):
            if _in_string(local_spans, match.start()):
                continue
            if unreachable(match.start()):
                continue
            bound = match.group(1)
            if bound == variable:
                continue                      # `X = X` 不是重挂
            line_prefix = handler_body[handler_body.rfind("\n", 0, match.start()) + 1: match.start()]
            guard = handler_body[max(0, match.start() - 300): match.start()]
            if not re.search(r"if\s+ok\b", guard):
                continue                      # 没有成功守卫
            if re.search(r"if\s+not\s+ok\b|ok\s*==\s*false|unless", guard + line_prefix):
                continue                      # 赋值在失败分支里
            binding = re.compile(r"local\s+[^\n=]*\b" + re.escape(bound) + r"\b[^\n=]*=\s*pcall\s*\(")
            if binding.search(handler_body):
                return True
    return False


def _resource_root(path: Path) -> Path | None:
    directory = path.parent
    while directory != directory.parent:
        if directory == RESOURCES:
            return None
        if _manifest_path(directory):
            return directory
        directory = directory.parent
    return None


def scan_file(path: Path) -> list[Risk]:
    source = path.read_text(encoding="utf-8", errors="ignore")
    caches = [match.group(1) for match in CACHE.finditer(source)]
    if not caches:
        return []

    clean = _blank_comments(source)
    risks: list[Risk] = []
    for variable in dict.fromkeys(caches):          # 去重、保序
        if not re.search(r"\b" + re.escape(variable) + USE_PATTERN, clean):
            continue
        if _has_rehook(source, variable):
            continue
        risks.append(Risk(path.relative_to(RESOURCES).as_posix(), variable, _scope(path)))
    if not risks:
        return []

    root = _resource_root(path)
    if root is None:
        return []
    manifest = _manifest_path(root)
    if manifest and _declares_qb_core(manifest.read_text(encoding="utf-8", errors="ignore")):
        return []
    return risks


def scan_repo() -> list[Risk]:
    risks: list[Risk] = []
    for path in sorted(RESOURCES.rglob("*.lua")):
        if "node_modules" in path.parts:
            continue
        risks.extend(scan_file(path))
    return risks


def split_scopes(risks: list[Risk]) -> tuple[list[str], list[str]]:
    server = sorted(risk.key for risk in risks if risk.scope == "server")
    client = sorted(risk.key for risk in risks if risk.scope == "client")
    return server, client


def write_baseline() -> tuple[int, int]:
    server, client = split_scopes(scan_repo())
    payload = {
        "$comment": (
            "顶层缓存 QBCore 且不在重启级联内、又没有 onResourceStart 重解析的文件（server 侧）。"
            "这些资源在 `restart qb-core` 之后会继续用失效的函数引用。只允许减少："
            "修好一处（加重解析）就同步删一条；新增必须在本轮修掉，不得加进基线。"
            "client_unverified 是**还没验证过跨客户端语义**的那批，不进棘轮，但也不许悄悄变多。"
        ),
        "owner": "hermes",
        "expires": "2027-03-31",
        "count": len(server),
        "entries": server,
        "client_count": len(client),
        "client_unverified": client,
    }
    BASELINE.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return len(server), len(client)


def load_baseline() -> dict:
    return json.loads(BASELINE.read_text(encoding="utf-8")) if BASELINE.exists() else {}


def check() -> tuple[list[str], list[str], list[str], list[str]]:
    server, client = split_scopes(scan_repo())
    data = load_baseline()
    base_server = data.get("entries", [])
    base_client = data.get("client_unverified", [])
    return (
        sorted(set(server) - set(base_server)),
        sorted(set(base_server) - set(server)),
        sorted(set(client) - set(base_client)),
        sorted(set(base_client) - set(client)),
    )


if __name__ == "__main__":  # pragma: no cover
    if "--write" in sys.argv:
        server, client = write_baseline()
        print(f"wrote {BASELINE.name}: server={server} client={client}")
    else:
        added, removed, client_added, client_removed = check()
        print(
            f"server 新增 {len(added)} / 已消除 {len(removed)}；"
            f"client 新增 {len(client_added)} / 已消除 {len(client_removed)}"
        )
        for label, items in (("+", added), ("-", removed), ("c+", client_added), ("c-", client_removed)):
            for item in items:
                print(f"  {label}", item.replace("\u0000", "  var="))
        raise SystemExit(1 if added or client_added else 0)
