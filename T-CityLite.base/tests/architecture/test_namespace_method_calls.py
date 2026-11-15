"""资源内自建命名空间的方法调用必须真的存在定义。

为什么需要：
    `QuestVendorBridge.PushFor(citizenid)` 在 `quest_vendor_bridge.lua:449` 被调用，而这个方法
    **从来没有定义过**（真正的推送函数叫 `PushState`）。这类拼错/改名残留 `luac -p` 查不出来
    （语法完全合法），`test_lua_local_order` 也查不出来（它不是 `local function`），只在运行期
    报 `attempt to call a nil value`——而且往往发生在「玩家做了某个动作」之后。

判据（窄而确定）：
    1. 一个命名空间表算「本资源自建的」当且仅当资源内某处写了 `Name = {}` / `Name = X or {}`；
    2. 对自建表的每次 `Name.Method(` 调用，资源内必须存在定义：`function Name.Method(`、
       `Name.Method = <非 nil>`，或经由别名（`local M = Name` 后 `function M.Method(`）；
    3. 外部命名空间（`Citizen` / `CFShared` / `MySQL` / `QuestNodes` …）不参与——它们不在本资源里定义。

为什么不做成白名单：全 `[custom]` 115 个资源实测只有 1 处违规（就是这次修的那处），
零误报意味着不需要放行表；一旦出现误报，说明判据错了，应该修判据而不是加白名单。
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

from lua_source import blank_noise

# parents: [architecture, tests, T-CityLite.base, T-City]
BASE = Path(__file__).resolve().parents[2]
CUSTOM = BASE / "resources/[custom]"

OWN_TABLE = re.compile(r"^\s*(?:local\s+)?([A-Z][A-Za-z0-9_]*)\s*=\s*(?:[A-Za-z0-9_.]*\s*or\s*)?\{\s*\}",
                       re.M)
DEF_FUNCTION = re.compile(r"function\s+([A-Z][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\s*\(")
DEF_ASSIGNED = re.compile(r"^\s*(?:local\s+)?([A-Z][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?!nil\b)",
                          re.M)
ALIAS = re.compile(r"^\s*local\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Z][A-Za-z0-9_]*)\s*$", re.M)
CALL = re.compile(r"(?<![\w.:])([A-Z][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def resource_dirs(root: Path = CUSTOM) -> list[Path]:
    return sorted(p for p in root.iterdir() if p.is_dir() and any(p.rglob("*.lua")))


def sources(resource: Path) -> dict[Path, str]:
    """文件 → 抹掉注释与字符串的代码骨架（长度与行号不变）。"""
    return {f: blank_noise(f.read_text(encoding="utf-8", errors="ignore"))
            for f in sorted(resource.rglob("*.lua"))}


def _own_tables(codes: list[str]) -> set[str]:
    return {name for code in codes for name in OWN_TABLE.findall(code)}


def _aliases(codes: list[str], own: set[str]) -> dict[str, str]:
    """`local M = Name` 这种别名 → 基名（`radio_text.lua` 用这种写法定义方法）。"""
    out: dict[str, str] = {}
    for code in codes:
        for alias, base in ALIAS.findall(code):
            if base in own:
                out[alias] = base
    return out


def _definitions(codes: list[str], alias: dict[str, str]) -> set[tuple[str, str]]:
    defs: set[tuple[str, str]] = set()
    for code in codes:
        for match in DEF_FUNCTION.finditer(code):
            defs.add((alias.get(match.group(1), match.group(1)), match.group(2)))
        for match in DEF_ASSIGNED.finditer(code):
            defs.add((alias.get(match.group(1), match.group(1)), match.group(2)))
    return defs


def violations(resource: Path, root: Path = CUSTOM) -> list[str]:
    """返回 `path:line 名字.方法( 无定义` 形式的违规列表。`root` 只用于把路径打印得短一点。"""
    sources_by_file = sources(resource)
    codes = list(sources_by_file.values())
    own = _own_tables(codes)
    alias = _aliases(codes, own)
    defs = _definitions(codes, alias)

    found: list[str] = []
    for path, code in sources_by_file.items():
        for match in CALL.finditer(code):
            table = alias.get(match.group(1), match.group(1))
            if table in own and (table, match.group(2)) not in defs:
                line = code.count("\n", 0, match.start()) + 1
                where = path.relative_to(root).as_posix()
                found.append(f"{where}:{line} 调用 {match.group(1)}.{match.group(2)}("
                             f"，但 {table}.{match.group(2)} 在本资源里没有定义")
    return found


@pytest.mark.parametrize("resource", resource_dirs(), ids=lambda p: p.name)
def test_called_namespace_methods_exist(resource: Path):
    problems = violations(resource)
    assert not problems, ("调用了本资源自建命名空间里不存在的方法（运行期 attempt to call a nil value）：\n  "
                          + "\n  ".join(problems))


def test_rule_catches_a_missing_method(tmp_path: Path):
    """反向控制：合成一处「自建表 + 未定义方法」必须被抓到。"""
    res = tmp_path / "[custom]" / "probe"
    res.mkdir(parents=True)
    (res / "main.lua").write_text(
        "Probe = Probe or {}\n"
        "function Probe.Known()\n"
        "    return 1\n"
        "end\n"
        "local function boot()\n"
        "    Probe.Known()\n"
        "    Probe.Missing()\n"
        "end\n"
        "boot()\n",
        encoding="utf-8",
    )
    problems = violations(res, root=res)
    assert len(problems) == 1 and "Probe.Missing(" in problems[0], problems
