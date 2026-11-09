"""FiveM 资源清单的解析工具（tools/dev 与测试共用）。

两个消费者：
  * `tests/architecture/server_await_scan.py` —— 服务端 Await 闸门（P2-1）；
  * `tools/dev/budget_probe.py` —— IO / tick / payload 预算（P2-4）。

"哪些文件是服务端"**不能按路径猜**：`core-framework/services/patron_service.lua`、`contracts.lua`、
`bus.lua`、根级 `*_server.lua` 全是服务端脚本，路径里一个 `/server/` 都没有。以 `fxmanifest.lua` 的
`server_scripts` / `shared_scripts` 为准（shared 两侧都跑，按服务端算），拿不到 manifest 才退回路径启发式。

manifest 的写法要全认（历史教训：只认 `keyword [{=]` 会让 20+ 个用 `server_script 'main.lua'` 的资源
贡献 0 个文件）：

    server_scripts { 'a.lua', 'b/*.lua' }
    server_scripts({ 'a.lua' })
    server_script 'server/main.lua'
    shared_script '@other/x.lua'        -- 跨资源引用，归别的资源管

`glob` 要 `recursive=True`，且目录部分要 `glob.escape`（资源目录名带方括号，`[qb]` 在 glob 里是字符类）。
"""

from __future__ import annotations

import glob as globlib
import re
from pathlib import Path

KEYWORD = re.compile(r"\b(server_scripts?|shared_scripts?|client_scripts?)\b", re.I)
QUOTED = re.compile(r"""['"]([^'"]+)['"]""")
COMMENT = re.compile(r"--\[(=*)\[.*?\]\1\]|--[^\n]*", re.S)
#: 拿不到 manifest 时的兜底：目录名或文件名以 server/sv 起头
PATH_HEURISTIC = re.compile(r"(^|/)(server|sv)([^/]*\.lua$|/)", re.I)


def strip_comments(source: str) -> str:
    """去掉行注释与块注释，保留行结构（行号要对得上）。"""
    return COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), source)


def _statement(text: str, index: int) -> str:
    """关键词之后的内容：`{`/`(` 走括号配对，否则取到行尾。"""
    length = len(text)
    while index < length and text[index] in " \t":
        index += 1
    if index < length and text[index] in "{(":
        opener = text[index]
        closer = "}" if opener == "{" else ")"
        depth, start = 0, index + 1
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


def manifest_scripts(manifest: Path) -> tuple[set[str], set[str]]:
    """返回 (服务端文件, 客户端文件)，路径相对资源根目录。"""
    server: set[str] = set()
    client: set[str] = set()
    try:
        text = strip_comments(manifest.read_text(encoding="utf-8", errors="ignore"))
    except OSError:
        return server, client

    for match in KEYWORD.finditer(text):
        bucket = client if match.group(1).lower().startswith("client") else server
        for token in QUOTED.findall(_statement(text, match.end())):
            token = token.strip()
            if not token.endswith(".lua") or token.startswith("@"):
                continue
            if "*" in token:
                pattern = globlib.escape(manifest.parent.as_posix()) + "/" + token
                for hit in globlib.glob(pattern, recursive=True):
                    bucket.add(Path(hit).relative_to(manifest.parent).as_posix())
                continue
            bucket.add(Path(token).as_posix())
    return server, client


def resource_server_files(resource_dir: Path) -> set[str] | None:
    """该资源的服务端文件；manifest 里一条脚本都没声明时返回 None（交给启发式）。"""
    manifest = resource_dir / "fxmanifest.lua"
    if not manifest.exists():
        manifest = resource_dir / "__resource.lua"
    if not manifest.exists():
        return None
    server, _client = manifest_scripts(manifest)
    if not server and not _client:
        return None
    # 不做 `server - client`：shared_scripts 和同时出现在两边（connectqueue 的 shared/sh_queue.lua）
    # 都确实在服务端执行，减掉就是漏检。
    return server


def server_files(resources: Path) -> set[str]:
    """全仓服务端文件的 rel 路径集合（相对 resources/）。"""
    out: set[str] = set()
    for directory in sorted({p.parent for p in resources.rglob("fxmanifest.lua")}):
        prefix = directory.relative_to(resources).as_posix()
        declared = resource_server_files(directory)
        if declared is None:
            for path in directory.rglob("*.lua"):
                inner = path.relative_to(directory).as_posix()
                if PATH_HEURISTIC.search(inner) and not inner.startswith("client"):
                    out.add(f"{prefix}/{inner}")
            continue
        for inner in declared:
            out.add(f"{prefix}/{inner}")
    return out


def resource_index(resources: Path) -> dict[str, Path]:
    """资源名 → 目录（资源放在 `[qb]/qb-core` 这类分类子目录下）。"""
    index: dict[str, Path] = {}
    for manifest in resources.rglob("fxmanifest.lua"):
        index.setdefault(manifest.parent.name, manifest.parent)
    return index
