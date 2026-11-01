"""net event 静态扫描器 —— 唯一实现，闸门与基线生成器共用。

为什么单独成文件：2026-11-01 之前扫描逻辑住在 `test_net_event_auth.py` 里，只有那份
闸门能用。P1-3 要把范围推到全仓并留一份基线 JSON，如果再抄一份解析器，两边对
"什么算 handler、什么算鉴权"的判定迟早分叉 —— 那就是两套真相。

约定（改了这里等于改规则，必须同时改反向用例）：

* 只认字面量注册：`RegisterNetEvent('name', ...)` / `RegisterServerEvent('name', ...)`；
  变量名注册对闸门不可见，所以另有一条"必须写字面量"的规则。
* 两种注册形态都收：
  - 内联：`RegisterNetEvent('name', function(...) ... end)`，handler 到行首（允许缩进）的 `end)`；
  - 拆分：`RegisterNetEvent('name')` + `AddEventHandler('name', fn)`，去同文件里找 fn 的定义体。
    找不到就给**空 body** —— 空 body 永远算"未鉴权"，只会多报债，不会漏报。
* "已鉴权" = handler 里出现 `STRONG_TOKENS` 之一，或调用方传入的 helper
  （helper 是否真的落到 PolicePolicy.Can，由测试另行追查）。
"""
from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

REGISTER_RE = re.compile(r"^\s*Register(?:Net|Server)Event\(\s*(['\"])(?P<name>[^'\"]+)\1")
REGISTER_ANY = re.compile(r"Register(?:Net|Server)Event\s*\(\s*(?P<arg>[^,\n)]*)")
END_RE = re.compile(r"^\s*end\)\s*$")
INLINE_HANDLER_RE = re.compile(r",\s*function\b")
MAX_BLOCK_LINES = 400

#: A token that proves a unified auth decision inside the handler body.
STRONG_TOKENS: dict[str, re.Pattern[str]] = {
    "PolicePolicy.Can": re.compile(r"PolicePolicy\.Can\("),
    "PolicePolicy.Check": re.compile(r"PolicePolicy\.Check\("),
    "hasCapability": re.compile(r"\bhasCapability\b"),
    "IsPlayerAceAllowed": re.compile(r"IsPlayerAceAllowed\("),
    # qb-core 的权限判定是 HasPermission(src, 'admin') / ('command.'..name)
    "HasPermission": re.compile(r"HasPermission\(\s*src"),
    "system_source": re.compile(r"\bsrc\s*==\s*0\b|\bsrc\s*~=\s*0\s+then\s+return\b"),
    # 回调必须有归属：只有"被问的那个人"能回答（QBCore:Server:TriggerClientCallback）
    "callback_owner": re.compile(r"\.source\s*~=\s*src\b|\bsource\s*~=\s*src\b"),
}


@dataclass(frozen=True)
class Event:
    name: str
    resource: str
    path: Path
    line: int
    body: str
    kind: str = "server"      # server | client

    def where(self, root: Path) -> str:
        return f"{self.path.relative_to(root).as_posix()}:{self.line}"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _split_handler_body(text: str, name: str) -> str:
    """拆分形态：`RegisterNetEvent('x')` + `AddEventHandler('x', fn)`。"""
    ident = re.search(
        r"AddEventHandler\(\s*['\"]" + re.escape(name) + r"['\"]\s*,\s*([A-Za-z_][\w.]*)\s*\)",
        text,
    )
    if not ident:
        return ""
    fn = ident.group(1).split(".")[-1]
    fn_match = re.search(
        r"(?:local\s+)?function\s+" + re.escape(fn) + r"\s*\([^)]*\)(.*?)^end\s*$",
        text,
        re.DOTALL | re.MULTILINE,
    )
    return fn_match.group(1) if fn_match else ""


def scan_file(resource: str, path: Path, kind: str = "server") -> tuple[list[Event], list[str]]:
    """扫描单个文件里的 net event 注册点。"""
    events: list[Event] = []
    problems: list[str] = []
    lines = read(path).splitlines()
    text = "\n".join(lines)

    for index, line in enumerate(lines):
        match = REGISTER_RE.match(line)
        if not match:
            continue
        name = match.group("name")

        if not INLINE_HANDLER_RE.search(line):
            events.append(Event(name=name, resource=resource, path=path, line=index + 1,
                                body=_split_handler_body(text, name), kind=kind))
            continue

        body: list[str] = []
        cursor = index + 1
        terminated = False
        while cursor < len(lines):
            if END_RE.match(lines[cursor]):
                terminated = True
                break
            body.append(lines[cursor])
            cursor += 1
            if len(body) > MAX_BLOCK_LINES:
                problems.append(
                    f"{path.as_posix()}:{index + 1} {name} no top-level 'end)' "
                    f"within {MAX_BLOCK_LINES} lines"
                )
                body = []
                break
        if not terminated:
            if not any(name in problem for problem in problems):
                problems.append(f"{path.as_posix()}:{index + 1} {name} unterminated handler")
            continue
        events.append(
            Event(name=name, resource=resource, path=path, line=index + 1,
                  body="\n".join(body), kind=kind)
        )
    return events, problems


def scan_dir(resource: str, directory: Path, kind: str = "server") -> tuple[list[Event], list[str]]:
    """扫描一个目录下的所有 .lua，返回 (events, problems)。"""
    events: list[Event] = []
    problems: list[str] = []
    for path in sorted(directory.rglob("*.lua")):
        found, issues = scan_file(resource, path, kind)
        events.extend(found)
        problems.extend(issues)
    return events, problems


def auth_tokens(body: str, helpers: Mapping[str, object] | None = None) -> list[str]:
    """handler 里出现的鉴权证据：强 token + 项目 helper（helper 另行追查真伪）。"""
    found = [token for token, pattern in STRONG_TOKENS.items() if pattern.search(body)]
    for helper in (helpers or {}):
        if re.search(r"\b" + re.escape(helper) + r"\(", body):
            found.append(helper)
    return found


def is_client_path(path: Path) -> bool:
    """客户端脚本判定：`/client/` 目录、`cl_*.lua` / `client*.lua` 文件名。

    客户端也会 `RegisterNetEvent`（接服务端下发的通知），但那些 handler 的调用方是
    服务端，不是"任意玩家可触发的入站面"，所以不纳入鉴权闸门。

    两条容易踩反的边界：
    * `server/client_reports.lua` 是**服务端**脚本（名字里有 client，位置在 server/）；
    * 根目录的 `client.lua` / `cl_*.lua` 是客户端脚本。
    所以先看目录、再看文件名。
    """
    parts = [part.lower() for part in path.parts[:-1]]
    if "server" in parts:
        return False
    if "client" in parts:
        return True
    name = path.name.lower()
    return name.startswith("cl_") or name.startswith("client")


def scan_repo(resources: Path) -> tuple[list[Event], list[str]]:
    """扫描 `resources/` 下所有服务端脚本里的 net event（用于全仓基线）。"""
    events: list[Event] = []
    problems: list[str] = []
    for path in sorted(resources.rglob("*.lua")):
        if is_client_path(path):
            continue
        if "RegisterNetEvent" not in read(path) and "RegisterServerEvent" not in read(path):
            continue
        rel = path.relative_to(resources)
        # 嵌套分组（如 [cfx-default]/[gameplay]/[examples]/money/server.lua）里，
        # 资源名是第一个"不是 [] 分类目录"的段。
        parts = [part for part in rel.parts[:-1] if not part.startswith("[")]
        resource = parts[0] if parts else rel.parts[0]
        found, issues = scan_file(resource, path, kind="server")
        events.extend(found)
        problems.extend(issues)
    return events, problems


def _non_literal_in_file(path: Path, root: Path | None = None) -> list[str]:
    where = path.relative_to(root) if root else path
    offenders: list[str] = []
    for index, line in enumerate(read(path).splitlines(), 1):
        match = REGISTER_ANY.match(line.strip())
        if not match:
            continue
        arg = match.group("arg").strip()
        if arg[:1] in ("'", '"'):
            continue
        offenders.append(f"{where.as_posix()}:{index}  {arg}")
    return offenders


def non_literal_in_dir(directory: Path, root: Path | None = None) -> list[str]:
    """一个目录里第一个参数不是字符串字面量的注册点（闸门看不见它们）。

    `root` 用来把路径变成仓库相对路径 —— 基线文件要在 Windows 与 CI 的 Linux 上
    逐字节一致，绝对路径会让两边永远不等。
    """
    offenders: list[str] = []
    for path in sorted(directory.rglob("*.lua")):
        if is_client_path(path):
            continue
        offenders.extend(_non_literal_in_file(path, root))
    return offenders


def non_literal_registrations(resources: Path) -> list[str]:
    """全仓（服务端侧）的非字面量注册点。按文件遍历（按目录遍历会因嵌套目录重复计数）。"""
    offenders: list[str] = []
    for path in sorted(resources.rglob("*.lua")):
        if is_client_path(path):
            continue
        offenders.extend(_non_literal_in_file(path, resources))
    return offenders
