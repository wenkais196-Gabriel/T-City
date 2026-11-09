"""扫描**服务端**脚本里残留的 `Citizen.Await`（P2-1）。

为什么只看服务端：`Citizen.Await` 会挂起当前协程。客户端脚本里它通常写在 `CreateThread` 里、
等的是 NUI/动画这类毫秒级回调，停一下无伤大雅；而服务端一侧的读路径一旦 Await DB/HTTP，
停的是**处理该事件的那条协程**，慢库就会把玩家请求拖住（audit R7 的原话是"首次读取阻塞主线程"）。

"哪些文件是服务端"**不能按路径猜**：`core-framework/services/patron_service.lua`、`contracts.lua`、
`bus.lua`、根级 `*_server.lua` 全是服务端脚本，路径里一个 `/server/` 都没有（第一版就是这么漏掉
被修文件本体的）。所以以 `fxmanifest.lua` 的声明为准；只有拿不到 manifest 时才退回路径启发式。

manifest 的写法必须全部认下来（第二版按 `keyword [{=]` 正则去匹配，`server_script 'x.lua'` 这种
单数 + 空格的写法一条都匹配不到，20+ 个资源贡献 0 个服务端文件）：

    server_scripts { 'a.lua', 'b/*.lua' }      -- 复数 + 花括号
    server_scripts({ 'a.lua' })                -- 复数 + 括号
    server_script 'server/main.lua'            -- 单数 + 空格，到行尾
    shared_script '@other/x.lua'               -- 跨资源引用，归别的资源管，跳过

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

AWAIT = re.compile(r"\bCitizen\s*\.\s*Await\s*\(", re.I)
KEYWORD = re.compile(r"\b(server_scripts?|shared_scripts?|client_scripts?)\b", re.I)
QUOTED = re.compile(r"""['"]([^'"]+)['"]""")

#: 拿不到 manifest 时的兜底：目录名或文件名以 server/sv 起头
PATH_HEURISTIC = re.compile(r"(^|/)(server|sv)([^/]*\.lua$|/)", re.I)


def strip_comments(source: str) -> str:
    """去掉行注释与块注释，保留行结构。"""
    source = re.sub(r"--\[(=*)\[.*?\]\1\]", lambda m: "\n" * m.group(0).count("\n"), source, flags=re.S)
    return re.sub(r"--[^\n]*", "", source)


def _statement(text: str, index: int) -> str:
    """从关键词之后的第一个非空白字符开始，取这条声明的内容。

    `(` / `{` 起头 → 括号配对收口；否则（单数 + 空格写法）取到行尾。
    """
    length = len(text)
    while index < length and text[index] in " \t":
        index += 1
    if index < length and text[index] in "{(":
        opener = text[index]
        closer = "}" if opener == "{" else ")"
        depth = 0
        start = index + 1
        while index < length:
            if text[index] == opener:
                depth += 1
            elif text[index] == closer:
                depth -= 1
                if depth == 0:
                    return text[start:index]
            index += 1
        return text[start:]

    end = text.find("\n", index)
    return text[index:end if end != -1 else length]


def _manifest_scripts(manifest: Path) -> tuple[set[str], set[str]]:
    """返回 (服务端文件, 客户端文件)，路径相对资源根目录。"""
    server: set[str] = set()
    client: set[str] = set()
    try:
        text = strip_comments(manifest.read_text(encoding="utf-8", errors="ignore"))
    except OSError:
        return server, client

    for match in KEYWORD.finditer(text):
        kind = match.group(1).lower()
        bucket = client if kind.startswith("client") else server
        for token in QUOTED.findall(_statement(text, match.end())):
            token = token.strip()
            if not token.endswith(".lua") or token.startswith("@"):
                continue
            if "*" in token:
                # recursive：`server/**/*.lua` 也要连 `server/` 顶层一起算。
                # 目录部分要 escape：资源目录名带方括号（`[voice]`、`[qb]`）在 glob 里是字符类，
                # 不转义就一个文件都匹配不到。
                pattern = globlib.escape(manifest.parent.as_posix()) + "/" + token
                for hit in globlib.glob(pattern, recursive=True):
                    bucket.add(Path(hit).relative_to(manifest.parent).as_posix())
                continue
            path = Path(token)
            bucket.add(path.as_posix())
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
                if PATH_HEURISTIC.search(inner) and not inner.startswith("client"):
                    out.add(f"{prefix}/{inner}")
            continue
        for inner in declared:
            out.add(f"{prefix}/{inner}")
    return out


def scan_source(rel: str, source: str, server: set[str] | None = None) -> list[int]:
    """返回命中行号（1-based）。`server` 省略时按路径启发式判断（供反向形状用）。"""
    if server is None:
        if rel.startswith("client") or not PATH_HEURISTIC.search(rel):
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
