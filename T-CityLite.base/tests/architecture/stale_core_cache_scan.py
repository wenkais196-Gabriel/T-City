"""扫描「顶层缓存 QBCore 但没有重挂」的风险文件 —— 唯一实现，闸门与统计共用。

背景（真机 2026-11-07）：qb-clothing 报
`Execution of function reference in script host failed`。原因是文件顶层

    local QBCore = exports['qb-core']:GetCoreObject()

拿到的是 **qb-core 当次 script host 的快照**，表里的函数是函数引用；`restart qb-core`
之后旧引用全部失效。这与 PR #193 修的「MySQL 回调里调跨资源引用」不是同一类问题：
那次是**上下文**不对，这次是**缓存过期**。

判定（四个条件同时成立才算风险）：
  1. 文件顶层（列 0）缓存 `local <var> = exports['qb-core']:GetCoreObject(`；
  2. 文件里用了 `<var>.Functions` / `.Player` / `.Commands` / `.ServerCallbacks` / `.ClientCallbacks`；
  3. 文件里**没有**在 `onResourceStart` / `onClientResourceStart` 回调中重解析 `GetCoreObject`
     （有重挂 = 自愈，这三种形态视为安全）；
  4. 该资源**不在** `restart qb-core` 的级联停启范围内（fxmanifest 没有声明 qb-core 依赖）。
     在级联内的资源会随 `restart qb-core` 一起重启，自然重新执行顶层缓存 → 自愈。

口径保守：只认显式 `dependency/dependencies` 声明；用 `@qb-core/shared/…` 只算加载顺序，
不算依赖（真机实证：qb-clothing 就属于这种"声明了共享脚本但没声明依赖"的资源）。
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]          # T-CityLite.base/
RESOURCES = BASE / "resources"
BASELINE = Path(__file__).resolve().parent / "stale_core_cache_baseline.json"

CACHE = re.compile(r"^local\s+(\w+)\s*=\s*exports(?:\[\s*['\"]qb-core['\"]\s*\]|\.qb-core)\s*:\s*GetCoreObject\s*\(", re.M)
REHOOK_EVENTS = ("onResourceStart", "onClientResourceStart")
USES = ("Functions", "Player", "Commands", "ServerCallbacks", "ClientCallbacks")


@dataclass(frozen=True)
class Risk:
    file: str           # 相对 resources/
    variable: str


def _manifest(resource_dir: Path) -> str:
    for name in ("fxmanifest.lua", "__resource.lua"):
        path = resource_dir / name
        if path.exists():
            return path.read_text(encoding="utf-8", errors="ignore")
    return ""


def _declares_qb_core(manifest: str) -> bool:
    """fxmanifest 是否显式声明 qb-core 依赖（会随 restart qb-core 被停掉）。"""
    if re.search(r"dependenc(?:y|ies)[^\n]*\n?(?:[^\n]*\n){0,8}?[^\n]*['\"]qb-core['\"]", manifest):
        return True
    return bool(re.search(r"^\s*['\"]?qb-core['\"]?\s*$", manifest, re.M)) and "dependenc" in manifest


def _has_rehook(source: str) -> bool:
    for event in REHOOK_EVENTS:
        for match in re.finditer(event, source):
            window = source[match.start(): match.start() + 800]
            if "GetCoreObject" in window:
                return True
    return False


def scan_file(path: Path) -> Risk | None:
    source = path.read_text(encoding="utf-8", errors="ignore")
    cache = CACHE.search(source)
    if not cache:
        return None

    variable = cache.group(1)
    pattern = re.compile(rf"\b{re.escape(variable)}\s*\.\s*(?:{'|'.join(USES)})\b")
    if not pattern.search(source):
        return None

    if _has_rehook(source):
        return None

    resource_dir = path.parent
    while resource_dir != RESOURCES and not _manifest(resource_dir):
        resource_dir = resource_dir.parent
    if resource_dir == RESOURCES:
        return None
    if _declares_qb_core(_manifest(resource_dir)):
        return None

    return Risk(path.relative_to(RESOURCES).as_posix(), variable)


def scan_repo() -> list[Risk]:
    risks: list[Risk] = []
    for path in sorted(RESOURCES.rglob("*.lua")):
        if "node_modules" in path.parts:
            continue
        risk = scan_file(path)
        if risk:
            risks.append(risk)
    return risks


def as_set(risks: list[Risk]) -> list[str]:
    return sorted(f"{risk.file}\u0000{risk.variable}" for risk in risks)


def write_baseline() -> int:
    current = as_set(scan_repo())
    payload = {
        "$comment": (
            "顶层缓存 QBCore 且不在重启级联内、又没有 onResourceStart 重解析的文件。"
            "这些资源在 `restart qb-core` 之后会继续用失效的函数引用。只允许减少："
            "修好一处（加重解析）就同步删一条；新增必须在本轮修掉，不得加进基线。"
        ),
        "owner": "hermes",
        "expires": "2027-03-31",
        "count": len(current),
        "entries": current,
    }
    BASELINE.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return len(current)


def check() -> tuple[list[str], list[str]]:
    current = set(as_set(scan_repo()))
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))["entries"] if BASELINE.exists() else []
    return sorted(current - set(baseline)), sorted(set(baseline) - current)


if __name__ == "__main__":  # pragma: no cover
    if "--write" in sys.argv:
        print(f"wrote {BASELINE.name}: {write_baseline()} 处")
    else:
        added, removed = check()
        print(f"新增 {len(added)} / 已消除 {len(removed)}")
        for item in added:
            print("  +", item.replace("\u0000", "  var="))
        for item in removed:
            print("  -", item.replace("\u0000", "  var="))
        raise SystemExit(1 if added else 0)
