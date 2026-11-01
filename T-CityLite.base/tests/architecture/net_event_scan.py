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
* 鉴权判定前**先剥注释与字符串**（`strip_lua_noise`）：注释里写的检查不算检查。
* 客户端脚本不进闸门：先看目录（`server/` 优先），再看 fxmanifest 的 `client_scripts`，
  最后才是文件名约定。客户端 handler 的调用方是服务端，不是玩家可触发的入站面。
"""
from __future__ import annotations

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

REGISTER_RE = re.compile(r"^\s*Register(?:Net|Server)Event\s*\(\s*(['\"])(?P<name>[^'\"]+)\1")
REGISTER_ANY = re.compile(r"Register(?:Net|Server)Event\s*\(\s*(?P<arg>[^,\n)]*)")
# handler 的收尾只认**列 0** 的 `end)`：以前允许缩进，于是 handler 里嵌套的
# `pcall(function() ... end)` 会把函数体从中间截断（2026-11-01 验收发现：
# police:server:adoptDraft 的 body 只有 13 行，后半段的守卫全被截掉）。
END_RE = re.compile(r"^end\)\s*$")
END_ANY_RE = re.compile(r"^\s*end\)\s*$")
INLINE_HANDLER_RE = re.compile(r",\s*function\b")
MAX_BLOCK_LINES = 400

BLOCK_COMMENT = re.compile(r"--\[(=*)\[.*?\]\1\]", re.DOTALL)
LONG_STRING = re.compile(r"\[(=*)\[.*?\]\1\]", re.DOTALL)
LINE_COMMENT = re.compile(r"--[^\n]*")
STRING = re.compile(r"'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\"")

#: A token that proves a unified auth decision inside the handler body.
#:
#: 注意 `src == 0` **不是**鉴权：它只把控制台排除在外，任何玩家照样能触发。
#: 真正表示"只允许服务端触发"的写法是 `src ~= 0 then return`（见 system_source）。
STRONG_TOKENS: dict[str, re.Pattern[str]] = {
    "PolicePolicy.Can": re.compile(r"PolicePolicy\.Can\("),
    "PolicePolicy.Check": re.compile(r"PolicePolicy\.Check\("),
    "hasCapability": re.compile(r"\bhasCapability\b"),
    "IsPlayerAceAllowed": re.compile(r"IsPlayerAceAllowed\("),
    # qb-core 的权限判定是 HasPermission(src, 'admin') / ('command.'..name)
    "HasPermission": re.compile(r"HasPermission\(\s*src"),
    "system_source": re.compile(r"\bsrc\s*~=\s*0\s+then\s+return\b|\bsource\s*~=\s*0\s+then\s+return\b"),
    # 回调必须有归属：只有"被问的那个人"能回答（QBCore:Server:TriggerClientCallback）
    "callback_owner": re.compile(r"\.source\s*~=\s*src\b|\bsource\s*~=\s*src\b"),
    # 职业判定：`if job.name ~= 'judge' then ... return end`（字符串已剥成 ''，所以只钉操作符）
    # 这类事件不靠 ACE/能力位，靠"你不是这个职业就滚"；与 HasPermission 同级
    "job_deny": re.compile(r"\w*[Jj]ob\.name\s*~=\s*''[\s\S]{0,200}?\breturn\b"),
}


def strip_lua_noise(source: str) -> str:
    """去掉块注释、长字符串、行注释与普通字符串，保留行结构（换行不删）。"""
    text = BLOCK_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), source)
    text = LONG_STRING.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    text = LINE_COMMENT.sub("", text)
    text = STRING.sub("''", text)
    return text


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
        # 先只认列 0 的 `end)`：handler 内部的 `pcall(function() ... end)` 也是 `end)`，
        # 早先允许缩进匹配时会把函数体从中间截断（adoptDraft 的 body 只有 13 行就是这原因）。
        # 找不到再退回到"任意缩进"——有些注册点本身就在 `if ... then` 里（custom-phone 的 diag）。
        end_re = END_RE
        while cursor < len(lines):
            if end_re.match(lines[cursor]):
                terminated = True
                break
            body.append(lines[cursor])
            cursor += 1
            if not terminated and cursor >= len(lines) and not body:
                break
            if len(body) > MAX_BLOCK_LINES:
                problems.append(
                    f"{path.as_posix()}:{index + 1} {name} no top-level 'end)' "
                    f"within {MAX_BLOCK_LINES} lines"
                )
                body = []
                break
        if not terminated:
            # 兜底：注册点被包在块里（缩进）时，收尾的 `end)` 也带缩进
            body = []
            cursor = index + 1
            while cursor < len(lines):
                if END_ANY_RE.match(lines[cursor]):
                    terminated = True
                    break
                body.append(lines[cursor])
                cursor += 1
                if len(body) > MAX_BLOCK_LINES:
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


GUARD_HELPERS_PATH = Path(__file__).with_name("net_event_guard_helpers.json")


@lru_cache(maxsize=1)
def guard_helpers() -> dict[str, dict[str, dict]]:
    """资源内部鉴权 helper 的登记表（见 net_event_guard_helpers.json）。"""
    data = json.loads(GUARD_HELPERS_PATH.read_text(encoding="utf-8"))
    return {key: value for key, value in data.items() if not key.startswith("$")}


@lru_cache(maxsize=64)
def helpers_for(resource: str) -> dict[str, re.Pattern[str]]:
    """该资源的 helper 调用形状：`if not H(...) then return`。

    调用但忽略返回值（`H(x); doThing()`）不算鉴权，所以模式里钉死了否定分支与 return。
    """
    registered = guard_helpers().get(resource, {})
    return {
        name: re.compile(
            r"if\s+not\s+"
            + re.escape(name)
            + r"\s*\(.*?\)\s*then[\s\S]{0,400}?\breturn\b"
        )
        for name in registered
    }


def helper_call_problems(
    code: str, name: str, spec: dict | None = None
) -> tuple[int, list[str]]:
    """登记的 helper 在代码里是否被**当成守卫**用（唯一实现，闸门与计数共用）。

    形状要求：`if not H(...)` 的否定分支里真的 `return`，且不在 `if false` 死代码里。
    只匹配名字是不够的 —— `if not H(x) then end` 或"先干活再校验"都能骗过纯正则。

    `shape`（来自登记表，默认 deny_branch）：
      * `pcall`  —— `pcall(H, ...)` 且紧跟 `if not ok` 判定（分发器/委托式）
      * `export` —— `exports['res']:Method(...)`（导出函数内部自己校验）
    """
    shape = (spec or {}).get("shape", "deny_branch")
    if shape == "pcall":
        return _pcall_shape_problems(code, name)
    if shape == "export":
        return _export_shape_problems(code, spec or {})
    if shape == "local_check":
        return _local_check_problems(code, name)
    if shape == "ok_err":
        return _ok_err_shape_problems(code, name)
    if shape == "delegate":
        return _delegate_shape_problems(code, name, spec or {})
    lines = code.splitlines()
    uses, bad = 0, []
    for index, line in enumerate(lines):
        if name + "(" not in line or "function " + name + "(" in line:
            continue
        uses += 1
        text = line.strip()
        if not text.startswith("if not " + name):
            bad.append(str(index + 1) + ": 不是 `if not " + name + "(` 形状: " + text)
            continue
        # 死代码：往上找 10 行内缩进更浅的 `if false`（中间夹语句也要能抓到）
        guard_indent_early = len(line) - len(line.lstrip())
        dead = False
        for back in range(index - 1, max(-1, index - 10), -1):
            previous = lines[back]
            previous_text = previous.strip()
            if not previous_text:
                continue
            previous_indent = len(previous) - len(previous.lstrip())
            if previous_text.startswith("if false") and previous_indent < guard_indent_early:
                dead = True
                break
        if dead:
            bad.append(str(index + 1) + ": 守卫在 `if false` 死代码块里")
            continue
        if "end" in text:
            # 单行写法：if 的 end 就在本行 → return 必须在本行的 end 之前，
            # `if not H(x) then end` + 后面随便一个 return 不能算数
            head = text.split("end")[0]
            if "return" in head:
                continue
            bad.append(str(index + 1) + ": 单行否定分支里没有 return（守卫形同虚设）")
            continue
        if "return" in text:
            continue
        found = False
        guard_indent = len(line) - len(line.lstrip())
        for follow in lines[index + 1:index + 20]:
            inner = follow.strip()
            follow_indent = len(follow) - len(follow.lstrip())
            if inner.startswith("end") and follow_indent == guard_indent:
                break
            if inner.startswith("return"):
                found = True
                break
        if not found:
            bad.append(str(index + 1) + ": 否定分支里没有 return（守卫形同虚设）")
    return uses, bad


def _local_check_problems(code: str, name: str) -> tuple[int, list[str]]:
    """`local flag, ... = H(...)` + 紧跟 `if not flag ... return` 形状（返回值必须被判定）。"""
    assignment = re.compile(
        r"local\s+((?:[A-Za-z_]\w*\s*,\s*)*[A-Za-z_]\w*)[^=]*=\s*"
        + re.escape(name)
        + r"\s*\("
    )
    lines = code.splitlines()
    uses, bad = 0, []
    for index, line in enumerate(lines):
        match = assignment.search(line)
        if not match:
            continue
        uses += 1
        flags = [part.strip() for part in match.group(1).split(",")]
        flags = [f for f in flags if f and f != "_"] or ["_"]
        checked = any(
            any(follow.strip().startswith("if not " + flag) for flag in flags)
            or ("cb(" + flags[0] + ")") in follow
            or ("return " + flags[0]) in follow
            for follow in lines[index:index + 6]
        )
        if not checked:
            bad.append(str(index + 1) + ": 取了 " + name + " 的返回值却没判 `if not " + flag + "`")
    return uses, bad


def _result_checked(lines: list[str], index: int, names: list[str]) -> bool:
    """index 行之后的 12 行里，有没有"针对这些返回值"的否定分支**并真的 return**。"""
    for offset in range(index, min(len(lines), index + 12)):
        line = lines[offset]
        text = line.strip()
        if not text.startswith("if "):
            continue
        negated = any(
            ("not " + name) in text
            or ("type(" + name + ") ~=") in text
            or (name + " ~=") in text
            for name in names
        )
        if not negated:
            continue
        if "return" in text:
            return True
        indent = len(line) - len(line.lstrip())
        for follow in lines[offset + 1:offset + 60]:
            inner = follow.strip()
            if inner.startswith("end") and (len(follow) - len(follow.lstrip())) == indent:
                break
            if inner.startswith("return"):
                return True
    return False


def _assignment_names(lines: list[str], index: int) -> tuple[int, list[str]] | None:
    """找到 `local a, b = <调用>` 的变量名；支持 `pcall(function() return X end)` 包装。

    返回 (赋值所在行号, 变量名)；找不到返回 None（说明返回值被丢弃了）。
    """
    local_assign = re.compile(r"local\s+((?:[A-Za-z_]\w*\s*,\s*)*[A-Za-z_]\w*)[^=]*=")
    for back in range(index, max(-1, index - 4), -1):
        match = local_assign.search(lines[back])
        if match:
            names = [part.strip() for part in match.group(1).split(",") if part.strip()]
            if names:
                return back, names
    return None


def _shape_problems(
    code: str, name: str, call_pattern: str, skip_lines: tuple[str, ...] = ()
) -> tuple[int, list[str]]:
    """通用形状：调用点必须把返回值接住，并在否定分支里真的 return。"""
    lines = code.splitlines()
    pattern = re.compile(call_pattern)
    uses, bad = 0, []
    for index, line in enumerate(lines):
        if not pattern.search(line) or any(skip in line for skip in skip_lines):
            continue
        uses += 1
        found = _assignment_names(lines, index)
        if not found:
            bad.append(str(index + 1) + ": 调用了 " + name + " 但没接返回值（判不了就没拦住）")
            continue
        at, names = found
        if not _result_checked(lines, at, names):
            bad.append(
                str(index + 1) + ": 接了 " + name + " 的返回值却没在失败分支 return（"
                + "/".join(names) + "）"
            )
    return uses, bad


def _local_check_problems(code: str, name: str) -> tuple[int, list[str]]:
    return _shape_problems(
        code, name, r"local\s+(?:[A-Za-z_]\w*\s*,\s*)*[A-Za-z_]\w*[^=]*=\s*"
        + re.escape(name) + r"\s*\(",
    )


def _ok_err_shape_problems(code: str, name: str) -> tuple[int, list[str]]:
    return _local_check_problems(code, name)


def _pcall_shape_problems(code: str, name: str) -> tuple[int, list[str]]:
    return _shape_problems(code, name, r"pcall\(\s*" + re.escape(name) + r"\b")


def _export_shape_problems(code: str, spec: dict) -> tuple[int, list[str]]:
    """`exports['res']:Method(...)`：返回值必须被接住并在否定分支 return。"""
    method = spec.get("call", "").rsplit(":", 1)[-1]
    if not method:
        return (0, [])
    return _shape_problems(code, method, r"exports\[[^\]]*\]\s*:\s*" + re.escape(method) + r"\s*\(")


def _delegate_shape_problems(code: str, name: str, spec: dict) -> tuple[int, list[str]]:
    call = spec.get("call", name)
    return _shape_problems(code, name, re.escape(call) + r"\s*\(", skip_lines=("function ",))


def is_guarded(event: "Event", extra: Mapping[str, re.Pattern[str]] | None = None) -> bool:
    """handler 是否带鉴权证据：强 token、外部 helper 正则，或**登记过且形状正确**的 helper。"""
    code = strip_lua_noise(event.body)
    if any(pattern.search(code) for pattern in STRONG_TOKENS.values()):
        return True
    registered = guard_helpers().get(event.resource, {})
    # 同名时登记表说了算：extra（闸门自带的宽松词匹配）不能把严格形状降级
    for name, pattern in (extra or {}).items():
        if name in registered:
            continue
        if pattern.search(code):
            return True
    for name, spec in registered.items():
        uses, problems = helper_call_problems(code, name, spec)
        if uses and not problems:
            return True
    return False


def auth_tokens(body: str, helpers: Mapping[str, re.Pattern[str]] | None = None) -> list[str]:
    """handler 里出现的鉴权证据：强 token + 项目 helper（helper 另行追查真伪）。

    匹配前先剥注释与字符串 —— 注释里写的检查不算检查。
    """
    code = strip_lua_noise(body)
    found = [token for token, pattern in STRONG_TOKENS.items() if pattern.search(code)]
    for name, pattern in (helpers or {}).items():
        if pattern.search(code):
            found.append(name)
    return found


@lru_cache(maxsize=256)
def _manifest_client_scripts(resource_root: Path) -> frozenset[Path]:
    """fxmanifest 里 `client_scripts { ... }` 声明的文件（绝对路径）。"""
    manifest = resource_root / "fxmanifest.lua"
    if not manifest.is_file():
        manifest = resource_root / "__resource.lua"
    if not manifest.is_file():
        return frozenset()
    text = read(manifest)
    entries: list[str] = []
    server_entries: list[str] = []
    # 块状：client_scripts { 'a.lua', 'b.lua' }
    for match in re.finditer(r"client_scripts?\s*\{(?P<body>[^}]*)\}", text, re.DOTALL):
        entries.extend(re.findall(r"['\"]([^'\"]+)['\"]", match.group("body")))
    # 单数/多个单条：client_script 'a.lua'（playernames / rconlog / runcode / oxmysql 都是这种）
    for match in re.finditer(r"^\s*client_scripts?\s+(?P<q>['\"])(?P<file>[^'\"]+)(?P=q)", text, re.MULTILINE):
        entries.append(match.group("file"))
    # 同一个文件既声 client_script 又声 server_script 的（如 playernames_api.lua）
    # 按服务端算 —— 漏扫比多算危险。
    for match in re.finditer(r"server_scripts?\s*\{(?P<body>[^}]*)\}", text, re.DOTALL):
        server_entries.extend(re.findall(r"['\"]([^'\"]+)['\"]", match.group("body")))
    for match in re.finditer(r"^\s*server_scripts?\s+(?P<q>['\"])(?P<file>[^'\"]+)(?P=q)", text, re.MULTILINE):
        server_entries.append(match.group("file"))
    server_files = {
        (resource_root / entry).resolve() for entry in server_entries if not entry.startswith("@")
    }
    return frozenset(
        (resource_root / entry).resolve() for entry in entries if not entry.startswith("@")
    ) - server_files


def resource_root(path: Path) -> Path:
    """向上找到含 fxmanifest.lua 的资源根（找不到就返回原目录）。"""
    current = path if path.is_dir() else path.parent
    while current != current.parent:
        if (current / "fxmanifest.lua").is_file() or (current / "__resource.lua").is_file():
            return current
        current = current.parent
    return path.parent


def is_client_path(path: Path) -> bool:
    """客户端脚本判定：`/client/` 目录、fxmanifest 的 client_scripts、`cl_*` / `client*` 文件名。

    客户端也会 `RegisterNetEvent`（接服务端下发的通知），但那些 handler 的调用方是
    服务端，不是"任意玩家可触发的入站面"，所以不纳入鉴权闸门。

    两条容易踩反的边界：
    * `server/client_reports.lua` 是**服务端**脚本（名字里有 client，位置在 server/）；
    * `qb-target/init.lua` 是客户端脚本（名字看不出来，只有 fxmanifest 说了）。
    所以顺序是：目录 → manifest → 文件名。
    """
    parts = [part.lower() for part in path.parts[:-1]]
    if "server" in parts:
        return False
    if "client" in parts:
        return True
    if path.resolve() in _manifest_client_scripts(resource_root(path)):
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
