"""扫描**服务端**脚本里残留的 `Citizen.Await`（P2-1）。

为什么只看服务端：`Citizen.Await` 会挂起当前协程。客户端脚本里它通常写在 `CreateThread` 里、
等的是 NUI/动画这类毫秒级回调，停一下无伤大雅；而服务端一侧的读路径一旦 Await DB/HTTP，
停的是**处理该事件的那条协程**，慢库就会把玩家请求拖住（audit R7 的原话是"首次读取阻塞主线程"）。

"哪些文件是服务端"的判定在 `tools/dev/fivem_manifest.py`（按 fxmanifest 的 `server_scripts` /
`shared_scripts` 声明，不按路径猜 —— 见那里的注释与历史教训）。本模块只负责"谁还 Await 了"。

判据：脱掉注释后仍出现 `Citizen.Await` 的**服务端**文件，每个残留点必须在 allowlist 里写明
"为什么这条不算"以及到期日。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"
ALLOWLIST = Path(__file__).with_name("server_await_allowlist.json")

sys.path.insert(0, (BASE.parent / "tools" / "dev").as_posix())
import fivem_manifest  # noqa: E402

AWAIT = re.compile(r"\bCitizen\s*\.\s*Await\s*\(", re.I)

strip_comments = fivem_manifest.strip_comments


def server_files(resources: Path = RESOURCES) -> set[str]:
    return fivem_manifest.server_files(resources)


def scan_source(rel: str, source: str, server: set[str] | None = None) -> list[int]:
    """返回命中行号（1-based）。`server` 省略时按路径启发式判断（供反向形状用）。"""
    if server is None:
        if "/client" in rel or not fivem_manifest.PATH_HEURISTIC.search(rel):
            return []
    elif rel not in server:
        return []
    code = strip_comments(source)
    return [number for number, line in enumerate(code.splitlines(), start=1) if AWAIT.search(line)]


def scan_repo(resources: Path = RESOURCES) -> dict[str, list[int]]:
    hits: dict[str, list[int]] = {}
    server = server_files(resources)
    for rel in sorted(server):
        try:
            source = (resources / rel).read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        found = scan_source(rel, source, server)
        if found:
            hits[rel] = found
    return hits


def allowlist() -> dict[str, dict]:
    return json.loads(ALLOWLIST.read_text(encoding="utf-8"))["entries"]
