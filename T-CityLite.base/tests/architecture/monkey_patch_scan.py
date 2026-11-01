"""猴补（monkey patch）扫描器 —— 唯一实现，闸门与基线共用。

为什么单独成文件：这条规则要覆盖 `resources/**/*.lua` 里的**赋值形态**，而"什么算猴补"
（哪个前缀、哪种写法、排除哪些目录）只要有两份实现，判定迟早分叉。

约定（改了这里等于改规则，必须同时改负向用例 `test_no_monkey_patch.py`）：

* 前缀固定为 `QBCore` / `QBCore.Functions` / `Player.Functions`——
  只有这四个是"别人的对象"，往上面写东西就是猴补。
* 四种形态都要认：
    1. `function QBCore.Functions.GetPlayer(`  ← compat 现存的两处正是这种，只写 `=` 会漏
    2. `QBCore.Functions.GetPlayer =`
    3. `QBCore.Functions['GetPlayer'] =` / `QBCore.Functions["GetPlayer"] =`
    4. `QBCore.Debug =`（裸 QBCore 命名空间，production-freeze 用）
* 排除：`[qb]/qb-core/**`（API owner，它本来就在定义这些函数）、任何 `tests/` 目录。
* 比对前剥注释与字符串（`strip_lua_noise`），注释里写的赋值不算。
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from net_event_scan import BLOCK_COMMENT, LINE_COMMENT, strip_lua_noise

BASE = Path(__file__).resolve().parents[2]  # T-CityLite.base/
RESOURCES = BASE / "resources"
ALLOWLIST_PATH = Path(__file__).with_name("monkey_patches_allowlist.json")

PREFIXES = ("QBCore", "QBCore.Functions", "Player.Functions")

#: 不扫的目录（相对 resources/）：API owner + 任何测试夹具
EXCLUDED_PARTS = ("qb-core", "tests")

#: 三种写法 × 四个前缀。`Name` 限定成合法标识符，避免把 `X.Y ==` 这类比较当赋值。
NAME = r"[A-Za-z_][A-Za-z0-9_]*"


@dataclass(frozen=True)
class Patch:
    """一处猴补。"""

    file: str      # 相对 T-CityLite.base 的 POSIX 路径
    symbol: str    # 例：QBCore.Functions.GetPlayer
    line: int
    kind: str      # function / assign / bracket / bare

    def where(self) -> str:
        return f"{self.file}:{self.line}"


def _build_patterns() -> list[tuple[re.Pattern[str], str, str]]:
    """返回 (正则, 前缀, 形态名)。"""
    out: list[tuple[re.Pattern[str], str, str]] = []
    for prefix in PREFIXES:
        esc = re.escape(prefix)
        out.append((re.compile(rf"function\s+{esc}\.({NAME})\s*\("), prefix, "function"))
        out.append((re.compile(rf"{esc}\.({NAME})\s*(?<![=<>~])=(?!=)"), prefix, "assign"))
        out.append(
            (
                re.compile(rf"{esc}\[\s*(['\"])({NAME})\1\s*\]\s*(?<![=<>~])=(?!=)"),
                prefix,
                "bracket",
            )
        )
    return out


PATTERNS = _build_patterns()


def is_excluded(rel: Path) -> bool:
    """`rel` 是相对 resources/ 的路径。"""
    return any(part in EXCLUDED_PARTS for part in rel.parts[:-1])


def _is_client_file(rel: Path) -> bool:
    """只认**目录段** client：文件名前缀会把 `server/client_bridge.lua` 误判成客户端。"""
    return "client" in rel.parts[:-1]


def _string_spans(source: str) -> list[tuple[int, int]]:
    """字符串字面量的区间（含引号）。用于把"文档里贴的代码片段"排除掉。"""
    spans: list[tuple[int, int]] = []
    i, n = 0, len(source)
    while i < n:
        ch = source[i]
        if ch in "'\"":
            quote, start = ch, i
            i += 1
            while i < n:
                if source[i] == "\\":
                    i += 2
                    continue
                if source[i] == quote:
                    i += 1
                    break
                i += 1
            spans.append((start, i))
        else:
            i += 1
    return spans


def _strip_comments(source: str) -> str:
    """只去注释、**保留字符串**。

    表下标形态 `QBCore.Functions["GetPlayer"] =` 的名字在字符串里，而 strip_lua_noise 会把
    字符串一起抹成 `''` —— 用剥过字符串的文本去匹配，这种形态永远抓不到。
    """
    text = BLOCK_COMMENT.sub(lambda m: chr(10) * m.group(0).count(chr(10)), source)
    return LINE_COMMENT.sub("", text)


def scan_file(path: Path, rel: Path) -> list[Patch]:
    raw = path.read_text(encoding="utf-8", errors="ignore")
    code = strip_lua_noise(raw)
    comments_only = _strip_comments(raw)
    spans = _string_spans(comments_only)
    is_client = _is_client_file(rel)
    hits: list[Patch] = []
    seen: set[tuple[str, str, int]] = set()
    for pattern, prefix, kind in PATTERNS:
        haystack = comments_only if kind == "bracket" else code
        for match in pattern.finditer(haystack):
            if kind == "bracket" and any(lo <= match.start() < hi for lo, hi in spans):
                continue  # 字符串里贴的代码片段不算猴补
            # 客户端文件里的裸 QBCore 命名空间赋值（qb-fuel 的 `QBCore.PlayerData = pData`）
            # 是玩家数据快照，不是给别人的 API 打补丁。
            if is_client and prefix == "QBCore":
                continue
            name = match.group(match.lastindex) if match.lastindex else ""
            if not name or not re.fullmatch(NAME, name):
                continue
            line = haystack[: match.start()].count(chr(10)) + 1
            symbol = f"{prefix}.{name}"
            key = (symbol, rel.as_posix(), line)
            if key in seen:
                continue
            seen.add(key)
            hits.append(Patch(file=rel.as_posix(), symbol=symbol, line=line, kind=kind))
    return hits


def scan_repo(root: Path | None = None) -> list[Patch]:
    """扫描整个 resources 目录，返回按文件/行排序的猴补列表。"""
    base = root or RESOURCES
    hits: list[Patch] = []
    for path in sorted(base.rglob("*.lua")):
        rel = path.relative_to(base)
        if is_excluded(rel):
            continue
        hits.extend(scan_file(path, rel))
    return hits


@lru_cache(maxsize=1)
def load_allowlist() -> dict:
    with ALLOWLIST_PATH.open(encoding="utf-8") as handle:
        return json.load(handle)


@lru_cache(maxsize=1)
def allowlist_entries() -> tuple[dict, ...]:
    return tuple(load_allowlist().get("entries", []))


def registered_keys() -> set[tuple[str, str]]:
    return {(entry["file"], entry["symbol"]) for entry in allowlist_entries()}


def unregistered(hits: list[Patch]) -> list[Patch]:
    keys = registered_keys()
    return [hit for hit in hits if (hit.file, hit.symbol) not in keys]


def stale_entries(hits: list[Patch]) -> list[dict]:
    """登记了但当前一处都没命中的条目（死条目）。"""
    keys = {(hit.file, hit.symbol) for hit in hits}
    return [entry for entry in allowlist_entries() if (entry["file"], entry["symbol"]) not in keys]
