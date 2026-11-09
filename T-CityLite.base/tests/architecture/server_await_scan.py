"""扫描**服务端**脚本里残留的 `Citizen.Await`（P2-1）。

为什么只看服务端：`Citizen.Await` 会挂起当前协程。客户端脚本里它通常写在 `CreateThread` 里、
等的是 NUI/动画这类毫秒级回调，停一下无伤大雅；而服务端一侧的读路径一旦 Await DB/HTTP，
停的是**处理该事件的那条协程**，慢库就会把玩家请求拖住（audit R7 的原话是"首次读取阻塞主线程"）。

"哪些文件是服务端"这个问题**不能按路径猜**：`core-framework/services/patron_service.lua`、
`contracts.lua`、`bus.lua`、根级 `*_server.lua` 全是服务端脚本，路径里一个 `/server/` 都没有
（第一版就是这么漏掉被修文件本体的）。所以以 `fxmanifest.lua` 的 `server_scripts` 为准，
`shared_scripts` 两侧都跑、按服务端算；只有拿不到 manifest 时才退回路径启发式。

判据：脱掉注释后仍出现 `Citizen.Await` 的**服务端**文件，每个残留点必须在 allowlist 里写明
"为什么这条不算"以及到期日。
"""

from __future__ import annotations

import glob as globlib
import json
import re
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"
ALLOWLIST = Path(__file__).with_name("server_await_allowlist.json")

AWAIT = re.compile(r"\bCitizen\s*\.\s*Await\s*\(")
MANIFEST_BLOCK = re.compile(
    r"\b(server_scripts|shared_scripts|client_scripts|server_script|client_script)\s*[({=]\s*([^}]*)\}?",
    re.I,
)
QUOTED = re.compile(r"""['"]([^'"]+)['"]""")

#: 拿不到 manifest 时的兜底（只用于"看起来像服务端"）
PATH_HEURISTIC = re.compile(r"(^|/)(server|sv)[^/]*\.lua$", re.I)


def strip_comments(source: str) -> str:
    """去掉行注释与块注释，保留行结构。"""
    source = re.sub(r"--\[(=*)\[.*?\]\1\]", lambda m: "\n" * m.group(0).count("\n"), source, flags=re.S)
    return re.sub(r"--[^\n]*", "", source)


def _manifest_scripts(manifest: Path) -> tuple[set[str], set[str]]:
    """返回 (服务端文件, 客户端文件)，路径相对资源根目录。"""
    server: set[str] = set()
    client: set[str] = set()
    try:
        text = strip_comments(manifest.read_text(encoding="utf-8", errors="ignore"))
    except OSError:
        return server, client

    for match in MANIFEST_BLOCK.finditer(text):
        bucket = client if match.group(1).lower().startswith("client") else server
        for token in QUOTED.findall(match.group(2)):
            token = token.strip()
            if not token.endswith(".lua") or token.startswith("@"):
                continue
            if "*" in token:
                for hit in globlib.glob(str(manifest.parent / token)):
                    bucket.add(Path(hit).relative_to(manifest.parent).as_posix())
                continue
            bucket.add(Path(token).as_posix())
    return server, client


def _resource_server_files(resource_dir: Path) -> set[str] | None:
    """该资源的服务端文件；manifest 里一条脚本都没声明时返回 None（交给启发式）。"""
    manifest = resource_dir / "fxmanifest.lua"
    if not manifest.exists():
        manifest = resource_dir / "__resource.lua"
    if not manifest.exists():
        return None
    server, client = _manifest_scripts(manifest)
    if not server and not client:
        return None
    return server - client


def server_files(resources: Path = RESOURCES) -> set[str]:
    """全仓服务端文件的 rel 路径集合（相对 resources/）。"""
    out: set[str] = set()
    for directory in sorted({p.parent for p in resources.rglob("fxmanifest.lua")}):
        prefix = directory.relative_to(resources).as_posix()
        declared = _resource_server_files(directory)
        if declared is None:
            for path in directory.rglob("*.lua"):
                inner = path.relative_to(directory).as_posix()
                if PATH_HEURISTIC.search(inner) and "/client" not in inner:
                    out.add(f"{prefix}/{inner}")
            continue
        for inner in declared:
            out.add(f"{prefix}/{inner}")
    return out


def scan_source(rel: str, source: str, server: set[str] | None = None) -> list[int]:
    """返回命中行号（1-based）。`server` 省略时按路径启发式判断（供反向形状用）。"""
    if server is None:
        if "/client" in rel or not PATH_HEURISTIC.search(rel):
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
