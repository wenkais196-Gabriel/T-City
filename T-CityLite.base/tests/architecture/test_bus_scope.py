"""ARCH — 跨资源 Bus 读取闸门（S2a + S2b）。

为什么需要这条规则：FiveM 里每个 resource 是独立的 Lua state，`_G.Bus` **不跨资源**。
`core-framework/bus.lua` 的 `Bus.RegisterService` 只把服务挂到**调用方自己**的 Bus；
别的资源里读 `Bus.<service>` 恒为 nil。这类分支通常包在 `if Bus and ...` 里，
永远不会执行，表现是 BGM 不放、车辆状态永远走 fallback，而日志干干净净。

S2b 把扫描根扩到税/热度/通知：custom-taxes（SinkService）、qb-shops（NPCPricing）、
production-freeze（HeatService/NPCPricing）、custom-phone（EconomyService）与
qb-core 自己的 `functions.lua`（notify）/`heat_service.lua`（CoreEconomy）。

判定口径刻意是「跨资源读取」而不是「出现 Bus 字样」：

* 红：扫描根里读 `Bus.<service>` / `_G.Bus.<service>` / `Bus.SafeCall('<service>', ...)` /
  `Bus.GetService('<service>')` / `Bus._services['<service>']`，且该 service 的 owner
  不是文件所属资源；
* 绿：`Bus.RegisterService(...)`（owner 侧注册）、`Bus.Plugin.*`、owner 在自己进程内
  读写自己的 service（例如 custom-vehicles 的 `Bus.vehicles`）；
* 额外：任何在服务端脚本里调用 `Bus.RegisterService` 的资源，其 fxmanifest 必须真的
  加载了**定义 Bus 的脚本**（`@core-framework/bus.lua` 或本资源根部的 `bus.lua`）；
  只加载一个叫 `server/bus.lua` 的注册模块不算 —— 那正是 qb-vehicleshop 的旧故障。

    python -m pytest -q tests/architecture/test_bus_scope.py
"""
from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
REPO = BASE.parent
RESOURCES = BASE / "resources"
TOOL = REPO / "tools" / "dev" / "service_contracts_scan.py"

#: 扫描根（相对 BASE）。前 4 个是 S2a 的调用方；custom-vehicles/server 是 owner 根：
#: §4.2.5 的变异注入文件在这里，owner 读自己的 `Bus.vehicles` 必须放行。
#: S2b 追加 4 个目录 + 2 个单文件（qb-core 的 services 目录里还有 owner 自注册，
#: 只扫这两个调用点所在的文件，避免把 owner 自读也当跨资源读取）。
SCAN_ROOTS = (
    "resources/[custom]/custom-police/server",
    "resources/[qb]/qb-ambulancejob/server",
    "resources/[qb]/qb-storerobbery/server",
    "resources/[qb]/qb-vehicleshop/server",
    "resources/[custom]/custom-vehicles/server",
    "resources/[custom]/custom-taxes/server",
    "resources/[qb]/qb-shops/server",
    "resources/[system]/production-freeze/server",
    "resources/[custom]/custom-phone/server",
    "resources/[qb]/qb-core/server/functions.lua",
    "resources/[qb]/qb-core/server/services/heat_service.lua",
)

#: owner 文件：允许读写自己的 `_G.Bus.<service>`（*_service 文件就是 qb-core 的
#: 进程内注册者）。本片不把它们放进 SCAN_ROOTS；任何人以后扩大扫描根时按文件放行。
OWNER_FILES = (
    "resources/[qb]/qb-core/server/player.lua",
    "resources/[qb]/qb-core/server/services/sink_service.lua",
    "resources/[qb]/qb-core/server/services/economy_service.lua",
)

#: `Bus.RegisterService('<service>', { ... })` —— 声明侧，同时给出 owner。
REGISTER_RE = re.compile(
    r"Bus\.RegisterService\s*\(\s*(['\"])(?P<service>[^'\"]+)\1")
#: `_G.Bus.<service> = <table>` —— 资源在自己的 Lua state 里直接自注册（写者即 owner）。
BUS_ASSIGN_RE = re.compile(
    r"(?<![\w.])(?:_G\.)?Bus\.(?P<member>[A-Za-z_]\w*)\s*=(?!=)")
#: 字面量 `exports('service_<service>_<Method>', ...)` —— 静态导出的 owner 来源。
SERVICE_EXPORT_RE = re.compile(
    r"exports\s*\(\s*(['\"])service_(?P<service>[A-Za-z0-9_]+)_"
    r"(?P<method>[A-Z][A-Za-z0-9_]*)\1")
#: `Bus.<member>` / `_G.Bus.<member>`（不匹配 `MyBus.x` 或字符串里的 `.Bus.`）。
BUS_RE = re.compile(r"(?<![\w.])(?:_G\.)?Bus\.(?P<member>[A-Za-z_]\w*)")
#: `_services['<service>']` 这种直接摸注册表的写法。
SERVICES_INDEX_RE = re.compile(r"\s*\[\s*(['\"])(?P<service>[^'\"]+)\1\s*\]")
#: manifest 里的字面量脚本路径（只关心名字以 bus.lua 结尾的）。
BUS_PATH_RE = re.compile(r"['\"](?P<path>[^'\"]*bus\.lua)['\"]")


def _load_tool():
    spec = importlib.util.spec_from_file_location("service_contracts_scan", TOOL)
    assert spec and spec.loader, f"找不到扫描器：{TOOL}"
    module = importlib.util.module_from_spec(spec)
    sys.modules["service_contracts_scan"] = module
    spec.loader.exec_module(module)
    return module


def _resource_roots(resources: Path = RESOURCES) -> list[Path]:
    """所有带 fxmanifest.lua 的资源根目录（由深到浅，便于取最近的祖先）。"""
    return sorted({path.parent for path in resources.rglob("fxmanifest.lua")},
                  key=lambda path: len(path.parts), reverse=True)


def _resource_root_of(path: Path, roots: list[Path]) -> Path | None:
    for root in roots:
        if path.is_relative_to(root):
            return root
    return None


def _is_client_script(relative: str) -> bool:
    return relative.startswith("client/") or "/client/" in relative


def _first_string_arg(code: str, index: int) -> str | None:
    match = re.match(r"\s*\(\s*(['\"])(?P<arg>[^'\"]+)\1", code[index:])
    return match.group("arg") if match else None


def _defines_bus(text: str) -> bool:
    return bool(re.search(r"function\s+Bus\.RegisterService\s*\(", text)
                or re.search(r"_G\.Bus\s*=", text))


def manifest_loads_bus(manifest_text: str, resource_dir: Path) -> bool:
    """manifest 是否真的加载了一个**定义 Bus** 的脚本。

    `@core-framework/bus.lua` 直接算；本资源自己的脚本要读完内容确认它定义了
    `Bus.RegisterService` / `_G.Bus`，不能只看文件名 —— qb-vehicleshop 的
    `server/bus.lua` 只是一份注册模块，加载它并不会创建 Bus。
    """
    if "@core-framework/bus.lua" in manifest_text:
        return True
    for match in BUS_PATH_RE.finditer(manifest_text):
        relative = match.group("path")
        if relative.startswith("@"):
            continue
        candidate = resource_dir / relative
        if candidate.is_file() and _defines_bus(
                candidate.read_text(encoding="utf-8", errors="ignore")):
            return True
    return False


def wiring_problems(resource: str, resource_dir: Path) -> list[str]:
    """调用 RegisterService 的资源必须加载 Bus，否则注册永远不执行。"""
    manifest = resource_dir / "fxmanifest.lua"
    text = manifest.read_text(encoding="utf-8", errors="ignore") if manifest.is_file() else ""
    if manifest_loads_bus(text, resource_dir):
        return []
    return [
        f"{resource}: 服务端调用了 Bus.RegisterService，但 fxmanifest 没有加载定义 Bus 的"
        "脚本（@core-framework/bus.lua 或本资源根部的 bus.lua）—— 注册永远不会执行"
    ]


def survey(resources: Path = RESOURCES) -> tuple[dict[str, str], list[str]]:
    """返回 (service -> owner, 接线问题)。

    owner 从三处静态声明推导：`Bus.RegisterService('<service>', {...})`、
    字面量 `exports('service_<service>_<Method>', ...)`，以及
    `_G.Bus.<service> = <table>` 这种进程内自注册（qb-core 的 *Service 模块）。
    """
    tool = _load_tool()
    roots = _resource_roots(resources)
    owners: dict[str, str] = {}
    register_resources: dict[str, Path] = {}

    for path in sorted(resources.rglob("*.lua")):
        resource_dir = _resource_root_of(path, roots)
        if resource_dir is None:
            continue
        resource = resource_dir.name
        relative = path.relative_to(resource_dir).as_posix()
        code, spans = tool.analyse_lua(
            path.read_text(encoding="utf-8", errors="ignore"))

        for match in REGISTER_RE.finditer(code):
            if tool.in_spans(match.start(), spans):
                continue
            owners.setdefault(match.group("service"), resource)
            if not _is_client_script(relative):
                register_resources[resource] = resource_dir

        for match in SERVICE_EXPORT_RE.finditer(code):
            if tool.in_spans(match.start(), spans):
                continue
            owners.setdefault(match.group("service"), resource)

        for match in BUS_ASSIGN_RE.finditer(code):
            if tool.in_spans(match.start(), spans):
                continue
            owners.setdefault(match.group("member"), resource)

    problems: list[str] = []
    for resource, resource_dir in sorted(register_resources.items()):
        problems.extend(wiring_problems(resource, resource_dir))
    return owners, problems


def bus_read_violations(source: str, resource: str, relative: str,
                        owners: dict[str, str],
                        owner_files: tuple[str, ...] | list[str] = ()) -> list[str]:
    """一段 Lua 源码里的跨资源 Bus 读取。`relative` 相对 resources/。"""
    if relative in owner_files:
        return []
    tool = _load_tool()
    code, spans = tool.analyse_lua(source)
    problems: list[str] = []
    seen: set[tuple[int, str, str]] = set()

    def report(key: tuple[int, str, str], message: str) -> None:
        if key in seen:
            return
        seen.add(key)
        problems.append(message)

    for match in BUS_RE.finditer(code):
        if tool.in_spans(match.start(), spans):
            continue
        member = match.group("member")
        line = tool._line(code, match.start())
        where = f"resources/{relative}:{line}"

        if member in ("RegisterService", "Plugin"):
            continue

        if member in ("SafeCall", "GetService"):
            if re.match(r"\s*\(", code[match.end():]) is None:
                continue            # `if Bus.SafeCall then` 只是 guard，不是调用
            service = _first_string_arg(code, match.end())
            if service is None:
                report((line, member, ""),
                       f"{where}: Bus.{member}(...) 的服务名不是字面量，"
                       "静态闸门无法证明它属于本资源")
            elif owners.get(service) != resource:
                report((line, member, service),
                       f"{where}: Bus.{member}('{service}', ...) 是跨资源读取 —— "
                       f"'{service}' 的 owner 是 {owners.get(service) or '未注册'}，不是 {resource}")
            continue

        if member == "_services":
            indexed = SERVICES_INDEX_RE.match(code, match.end())
            if indexed is None:
                continue            # 裸 `Bus._services` 只是表引用，不是服务读取
            service = indexed.group("service")
            if owners.get(service) != resource:
                report((line, member, service),
                       f"{where}: Bus._services['{service}'] 直接摸注册表 —— "
                       f"'{service}' 的 owner 是 {owners.get(service) or '未注册'}，不是 {resource}")
            continue

        service = member
        if owners.get(service) != resource:
            report((line, member, service),
                   f"{where}: Bus.{service} 是跨资源读取 —— "
                   f"'{service}' 的 owner 是 {owners.get(service) or '未注册（跨资源恒 nil）'}，"
                   f"不是 {resource}")

    return problems


def test_no_cross_resource_bus_reads():
    """前向：扫描根里 0 个跨资源 Bus 读取；调用 RegisterService 的资源都真的加载了 Bus。"""
    assert (BASE / "resources").is_dir(), "找不到 resources 目录，范围被改坏了？"

    owners, wiring = survey()
    assert owners, "一个 Bus.RegisterService / service_* 导出都解析不到，扫描器坏了？"
    assert owners.get("atmosphere") == "tcity-atmosphere", owners.get("atmosphere")
    assert owners.get("vehicles") == "custom-vehicles", owners.get("vehicles")
    assert owners.get("storage") == "custom-storage", owners.get("storage")

    problems: list[str] = []
    for root in SCAN_ROOTS:
        root_path = BASE / root
        assert root_path.exists(), f"扫描根不存在：{root}"
        resource_dir = _resource_root_of(root_path, _resource_roots())
        assert resource_dir is not None and resource_dir.name != "resources", (
            f"扫描根不在任何资源目录下：{root}")
        resource = resource_dir.name
        paths = [root_path] if root_path.is_file() else sorted(root_path.rglob("*.lua"))
        for path in paths:
            relative = path.relative_to(RESOURCES).as_posix()
            problems.extend(bus_read_violations(
                path.read_text(encoding="utf-8", errors="ignore"),
                resource, relative, owners, OWNER_FILES))

    assert not (problems or wiring), (
        "跨资源 Bus 闸门红了。读取侧：`_G.Bus` 是资源私有状态，跨资源读 `Bus.<service>` 恒 nil，"
        "改成 owner 的 `exports['<owner>']:service_<service>_<Method>`；"
        "接线侧：调用 Bus.RegisterService 的资源必须在 fxmanifest 里加载定义 Bus 的脚本，"
        "否则注册永远不会执行。\n  "
        + "\n  ".join(problems + wiring))


def test_reverse_cross_resource_bus_read_is_rejected(tmp_path):
    """反向：跨资源读取/未接线的注册必须报；注释、字符串、owner 自读必须不报。"""
    owners = {"vehicles": "custom-vehicles", "storage": "custom-storage"}

    cross = bus_read_violations(
        "Bus.storage.CanAccess(src, 'org')\n", "custom-police", "probe.lua", owners)
    assert any("storage" in problem for problem in cross), cross

    quiet = (
        "-- Bus.storage.CanAccess(src, 'org')\n"
        "local sample = \"Bus.storage.CanAccess(src, 'org')\"\n"
    )
    assert not bus_read_violations(quiet, "custom-police", "probe.lua", owners)

    owner_read = bus_read_violations(
        "Bus.vehicles.GetState(plate)\n", "custom-vehicles",
        "resources/[custom]/custom-vehicles/server/probe.lua", owners)
    assert not owner_read, owner_read

    # `_G.Bus.<service> = <table>` 是 owner 在自己进程内的自注册（写），不是读取。
    owners_with_heat = dict(owners, HeatService="qb-core")
    self_register = bus_read_violations(
        "_G.Bus.HeatService = HeatService\n", "qb-core",
        "resources/[qb]/qb-core/server/services/heat_service.lua", owners_with_heat)
    assert not self_register, self_register

    # OWNER_FILES：owner 文件读自己的 EconomyService 放行；同样读取换个文件必须报。
    own_economy = "_G.Bus.EconomyService.RemoveMoney(cid, 'bank', 1, 'x')\n"
    assert not bus_read_violations(
        own_economy, "qb-core", OWNER_FILES[1], owners, OWNER_FILES)
    assert bus_read_violations(
        own_economy, "qb-core", "resources/[qb]/qb-core/server/other.lua",
        owners, OWNER_FILES)

    probe = tmp_path / "probe"
    (probe / "server").mkdir(parents=True)
    (probe / "server" / "main.lua").write_text(
        "Bus.RegisterService('probe', { Ping = function() end })\n", encoding="utf-8")
    manifest = probe / "fxmanifest.lua"
    manifest.write_text(
        "fx_version 'cerulean'\ngame 'gta5'\nserver_scripts { 'server/main.lua' }\n",
        encoding="utf-8")
    _, wiring = survey(tmp_path)
    assert any("probe" in problem for problem in wiring), wiring

    manifest.write_text(
        "fx_version 'cerulean'\ngame 'gta5'\n"
        "server_scripts { '@core-framework/bus.lua', 'server/main.lua' }\n",
        encoding="utf-8")
    _, wiring_after = survey(tmp_path)
    assert not wiring_after, wiring_after

    (probe / "server" / "heat.lua").write_text(
        "_G.Bus.HeatService = {}\n", encoding="utf-8")
    owners_after, _ = survey(tmp_path)
    assert owners_after.get("HeatService") == "probe", owners_after
