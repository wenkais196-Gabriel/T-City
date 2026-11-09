"""扫描**服务端**脚本里残留的 `Citizen.Await`（P2-1）。

为什么只看服务端：`Citizen.Await` 会挂起当前协程。客户端脚本里它通常写在 `CreateThread` 里、
等的是 NUI/动画这类毫秒级回调，停一下无伤大雅；而服务端一侧的读路径一旦 Await DB/HTTP，
停的是**处理该事件的那条协程**，慢库就会把玩家请求拖住（audit R7 的原话是"首次读取阻塞主线程"）。

判据刻意保守：只认服务端目录（`/server/` 且不在 `/client/` 下）里**脱掉注释后**还出现
`Citizen.Await` 的文件；每个残留点必须在 allowlist 里写明"为什么这条不算"以及到期日。
"""

from __future__ import annotations

import json
import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"
ALLOWLIST = Path(__file__).with_name("server_await_allowlist.json")

AWAIT = re.compile(r"\bCitizen\s*\.\s*Await\s*\(")


def strip_comments(source: str) -> str:
    """去掉行注释与块注释，保留行结构（字符串里的 `--` 也当注释剥掉 —— 这里只用于"有没有调用"）。"""
    source = re.sub(r"--\[(=*)\[.*?\]\1\]", lambda m: "\n" * m.group(0).count("\n"), source, flags=re.S)
    return re.sub(r"--[^\n]*", "", source)


def is_server_file(rel: str) -> bool:
    return "/server/" in rel or rel.endswith("/server.lua") or "/server_" in rel


def is_client_file(rel: str) -> bool:
    return "/client/" in rel or rel.endswith("/client.lua") or "/client_" in rel


def scan_source(rel: str, source: str) -> list[int]:
    """返回命中行号（1-based）。"""
    if not is_server_file(rel) or is_client_file(rel):
        return []
    code = strip_comments(source)
    return [number for number, line in enumerate(code.splitlines(), start=1) if AWAIT.search(line)]


def scan_repo(resources: Path = RESOURCES) -> dict[str, list[int]]:
    hits: dict[str, list[int]] = {}
    for path in sorted(resources.rglob("*.lua")):
        rel = path.relative_to(resources).as_posix()
        if rel.startswith("archive/"):
            continue
        try:
            source = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        found = scan_source(rel, source)
        if found:
            hits[rel] = found
    return hits


def allowlist() -> dict[str, dict]:
    return json.loads(ALLOWLIST.read_text(encoding="utf-8"))["entries"]
