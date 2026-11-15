#!/usr/bin/env python3
"""方法级导出契约扫描器 —— 谁在调 `exports['<res>']:<Method>(...)`，那个方法真的存在吗。

为什么需要它：`exports['custom-main']` 这样的资源代理**永远是 truthy**，所以
`if exports['custom-main'] then` / `if exports['custom-main'].Foo then` 挡不住任何东西；
方法不存在时 FiveM 只在调用点抛 `No such export`，而外面套一层 pcall 就彻底静默。
本工具把「声明」和「调用」都从代码里推出来，在离线测试里做一次全仓对账。

做法刻意保持保守：

* 剥掉行注释/长注释后扫描；落在字符串字面量里的同名文本不算调用；
* 声明侧只认**字面量** `exports('Name', ...)` 和 `Bus.RegisterService('<svc>', { M = ... })`
  两种形状（动态注册的资源登记在 ``service_contracts.json`` 的 ``dynamic_exports``）；
* 调用侧只认字面量 `exports['<res>']:<Method>(`，点号取值（`exports['x'].M`）和无括号的
  资源探测不是调用，不在这里判定；
* 资源名到目录的映射用「最近的 fxmanifest.lua 祖先」，不假设 `resources/<category>/<res>` 的层级。

`service_contracts.json` 是唯一的人工登记表：

* ``services``              —— 每个 `Bus.RegisterService` 方法一条（含字面量 `service_*` 导出）；
* ``planned_services``      —— 契约已登记、实现还是占位的服务名；
* ``dynamic_exports``       —— 运行时循环注册、静态扫不到方法名的资源；
* ``external_exports``      —— **只放树外资源**（树都没装，没法在本地证明）；
* ``in_tree_missing_exports`` —— 树内资源确实缺的导出（vendored 上游/待修调用方），逐条带
  到期日与 follow_up；树内已有声明的方法不许登记进来；
* ``review``                —— 外部调用点的复核锚点（数量 + 服务名 + `reviewed` 标记 +
  `allowlisted_call_sites` 放行总数，任何人加一条放行都要让这个数字在 diff 里动一下）。

用法::

    python3 tools/dev/service_contracts_scan.py             # 打印未解析调用
    python3 tools/dev/service_contracts_scan.py --json      # 机器可读
    python3 tools/dev/service_contracts_scan.py --update    # 从代码重生成 services（review diff 后再提交）

退出码：0 = 扫描完成（是否有违规由测试判断）；2 = 环境不对。
"""

from __future__ import annotations

import argparse
import bisect
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = REPO / "T-CityLite.base"
RESOURCES = BASE / "resources"
REGISTRY = BASE / "tests" / "architecture" / "service_contracts.json"

#: 契约已登记、实现仍是占位的服务（S1 只登记，S2a 删除）。
PLANNED_SERVICES = ("chronicle", "cosmetics", "funnel", "governance", "reputation")

CALL_RE = re.compile(
    r"exports\s*\[\s*(?P<quote>['\"])(?P<res>[^'\"]+)(?P=quote)\s*\]\s*:\s*"
    r"(?P<method>[A-Za-z_]\w*)\s*\("
)
EXPORT_DECL_RE = re.compile(
    r"exports\s*\(\s*(?P<quote>['\"])(?P<name>[^'\"]+)(?P=quote)\s*,"
)
SERVICE_RE = re.compile(
    r"Bus\.RegisterService\s*\(\s*(?P<quote>['\"])(?P<svc>[^'\"]+)(?P=quote)\s*,"
)
SERVICE_EXPORT_RE = re.compile(r"^service_(?P<svc>[A-Za-z0-9_]+)_(?P<method>[A-Z][A-Za-z0-9_]*)$")
METHOD_ASSIGN_RE = re.compile(r"^\s*(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?P<value>.*)$", re.M)
FUNCTION_DEF_RE = re.compile(
    r"(?:^|\n)\s*(?:local\s+)?function\s+(?P<name>[A-Za-z_][\w.:]*)\s*"
    r"\((?P<params>[^)]*)\)"
)
FUNCTION_VALUE_RE = re.compile(
    r"(?:^|\n)\s*(?P<name>[A-Za-z_][\w.:]*)\s*=\s*function\s*\((?P<params>[^)]*)\)"
)
LONG_BRACKET_RE = re.compile(r"\[(=*)\[")


@dataclass(frozen=True)
class Call:
    resource: str      # 被调用的资源（exports['<resource>']）
    method: str
    path: str
    line: int
    caller: str = ""   # 发起调用的资源（文件所属资源）

    def where(self) -> str:
        return f"resources/{self.path}:{self.line}"


@dataclass
class Scan:
    resource_dirs: set[str] = field(default_factory=set)
    declarations: dict[str, set[str]] = field(default_factory=lambda: defaultdict(set))
    #: service -> method -> (path, line)（来自 Bus.RegisterService 块）
    service_methods: dict[str, dict[str, tuple[str, int]]] = field(
        default_factory=lambda: defaultdict(dict))
    #: service -> method -> (path, line)（来自字面量 exports('service_...')）
    literal_service_methods: dict[str, dict[str, tuple[str, int]]] = field(
        default_factory=lambda: defaultdict(dict))
    #: service -> method -> 注册块里 `Method = <value>` 的原文（生成器推导形参用）
    service_values: dict[str, dict[str, str]] = field(
        default_factory=lambda: defaultdict(dict))
    calls: list[Call] = field(default_factory=list)
    #: 放行段实际覆盖的调用点数（call_violations / allowlist_violations 填充）
    allowlisted: dict[str, int] = field(default_factory=lambda: {
        "external": 0, "in_tree_missing": 0, "dynamic_methods": 0})

    def declared_service_methods(self) -> dict[str, dict[str, tuple[str, int]]]:
        merged: dict[str, dict[str, tuple[str, int]]] = defaultdict(dict)
        for source in (self.service_methods, self.literal_service_methods):
            for svc, methods in source.items():
                merged[svc].update(methods)
        return dict(merged)


def analyse_lua(source: str) -> tuple[str, list[tuple[int, int]]]:
    """返回 (注释被替换为空白的代码, 字符串字面量区间)。

    保留换行，所以行号仍然可用。字符串内容保留 —— `exports['res']` 的资源名本身
    就在字符串里；是否算「真调用」由调用点是否落在字符串区间决定。
    """
    out = list(source)
    spans: list[tuple[int, int]] = []
    index, size = 0, len(source)
    while index < size:
        char = source[index]
        if char == "[":
            match = LONG_BRACKET_RE.match(source, index)
            if match:
                close = "]" + match.group(1) + "]"
                end = source.find(close, index + len(match.group(0)))
                end = size if end == -1 else end + len(close)
                spans.append((index, end))
                index = end
                continue
        if char == "-" and source.startswith("--", index):
            match = LONG_BRACKET_RE.match(source, index + 2)
            if match:
                close = "]" + match.group(1) + "]"
                end = source.find(close, index + len(match.group(0)))
                end = size if end == -1 else end + len(close)
            else:
                end = source.find("\n", index)
                end = size if end == -1 else end
            for offset in range(index, end):
                if out[offset] != "\n":
                    out[offset] = " "
            index = end
            continue
        if char in "'\"":
            cursor = index + 1
            while cursor < size:
                if source[cursor] == "\\":
                    cursor += 2
                    continue
                if source[cursor] == char:
                    cursor += 1
                    break
                cursor += 1
            spans.append((index, cursor))
            index = cursor
            continue
        index += 1
    return "".join(out), spans


def in_spans(index: int, spans: list[tuple[int, int]]) -> bool:
    """spans 按起点升序；二分找最后一个 start <= index 的区间。"""
    position = bisect.bisect_right(spans, (index, sys.maxsize)) - 1
    return position >= 0 and spans[position][0] <= index < spans[position][1]


def _line(code: str, index: int) -> int:
    return code.count("\n", 0, index) + 1


def _match_brace(code: str, open_index: int, spans: list[tuple[int, int]]) -> int:
    depth = 0
    index = open_index
    while index < len(code):
        if in_spans(index, spans):
            index += 1
            continue
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return len(code) - 1


def _resource_dirs(resources: Path) -> list[Path]:
    """所有带 fxmanifest.lua 的资源根目录（由深到浅排序，便于取最近的祖先）。"""
    return sorted({p.parent for p in resources.rglob("fxmanifest.lua")},
                  key=lambda p: len(p.parts), reverse=True)


def _resource_of(path: Path, resource_dirs: list[Path]) -> str | None:
    for root in resource_dirs:
        if path.is_relative_to(root):
            return root.name
    return None


def _function_params(resources: Path) -> dict[str, str]:
    """`function A.B(...)` / `A.B = function(...)` 的形参表，按全名索引。"""
    found: dict[str, str] = {}
    for path in resources.rglob("*.lua"):
        code, _ = analyse_lua(path.read_text(encoding="utf-8", errors="ignore"))
        for regex in (FUNCTION_DEF_RE, FUNCTION_VALUE_RE):
            for match in regex.finditer(code):
                found.setdefault(match.group("name"), match.group("params"))
    return found


def _split_params(raw: str) -> list[str]:
    params = []
    for part in raw.split(","):
        name = part.strip()
        if not name or name == "...":
            continue
        params.append(name)
    return params


def _resolve_args(value: str, definitions: dict[str, str]) -> list[str]:
    inline = re.match(r"function\s*\((?P<params>[^)]*)\)", value.strip())
    if inline:
        return _split_params(inline.group("params"))
    reference = value.strip().rstrip(",;").strip()
    if reference in definitions:
        return _split_params(definitions[reference])
    tail = reference.rsplit(".", 1)[-1]
    if tail in definitions:
        return _split_params(definitions[tail])
    return []


def _extract_calls(code: str, spans: list[tuple[int, int]],
                   relative: str, caller: str = "") -> list[Call]:
    calls: list[Call] = []
    for match in CALL_RE.finditer(code):
        if in_spans(match.start(), spans):
            continue
        calls.append(Call(
            resource=match.group("res"),
            method=match.group("method"),
            path=relative,
            line=_line(code, match.start()),
            caller=caller,
        ))
    return calls


def extract_calls(source: str, relative: str, caller: str = "") -> list[Call]:
    """从一段 Lua 源码里提取字面量 `exports['res']:Method(` 调用（跳过注释/字符串）。"""
    code, spans = analyse_lua(source)
    return _extract_calls(code, spans, relative, caller)


def scan(resources: Path = RESOURCES) -> Scan:
    scan_result = Scan()
    if not resources.is_dir():
        return scan_result
    roots = _resource_dirs(resources)
    scan_result.resource_dirs = {root.name for root in roots}

    for path in sorted(resources.rglob("*.lua")):
        code, spans = analyse_lua(path.read_text(encoding="utf-8", errors="ignore"))
        relative = path.relative_to(resources).as_posix()
        resource = _resource_of(path, roots)
        if not resource:
            continue

        for match in EXPORT_DECL_RE.finditer(code):
            if in_spans(match.start(), spans):
                continue
            name = match.group("name")
            scan_result.declarations[resource].add(name)
            service_match = SERVICE_EXPORT_RE.match(name)
            if service_match:
                scan_result.literal_service_methods[service_match.group("svc")][
                    service_match.group("method")] = (relative, _line(code, match.start()))

        for match in SERVICE_RE.finditer(code):
            if in_spans(match.start(), spans):
                continue
            service = match.group("svc")
            brace = code.find("{", match.end())
            if brace == -1:
                continue
            end = _match_brace(code, brace, spans)
            block = code[brace + 1:end]
            for entry in METHOD_ASSIGN_RE.finditer(block):
                if in_spans(brace + 1 + entry.start(), spans):
                    continue
                method = entry.group("name")
                scan_result.service_methods[service][method] = (
                    relative, _line(code, brace + 1 + entry.start()))
                scan_result.service_values[service][method] = entry.group("value")
                scan_result.declarations[resource].add(f"service_{service}_{method}")

        scan_result.calls.extend(_extract_calls(code, spans, relative, caller=resource))

    return scan_result


def load_registry(path: Path = REGISTRY) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _allowed_dynamic(registry: dict) -> dict[str, set[str] | None]:
    """{resource: 允许的方法集合}；None 表示整个资源动态注册、无法逐方法列出。"""
    allowed: dict[str, set[str] | None] = {}
    for resource, spec in (registry.get("dynamic_exports") or {}).items():
        mode = (spec or {}).get("mode")
        if mode == "resource":
            allowed[resource] = None
        elif mode == "methods":
            allowed[resource] = set((spec or {}).get("methods") or [])
        else:
            allowed[resource] = set()      # 形状错误由 violations() 单独报
    return allowed


def _allowed_external(registry: dict) -> dict[str, set[str]]:
    allowed: dict[str, set[str]] = {}
    for resource, spec in (registry.get("external_exports") or {}).items():
        methods = (spec or {}).get("methods")
        allowed[resource] = set(methods) if isinstance(methods, list) else set()
    return allowed


def _allowed_in_tree_missing(registry: dict) -> dict[str, set[str]]:
    allowed: dict[str, set[str]] = {}
    for resource, spec in (registry.get("in_tree_missing_exports") or {}).items():
        methods = (spec or {}).get("methods")
        allowed[resource] = set(methods) if isinstance(methods, list) else set()
    return allowed


def classify_calls(scan_result: Scan, registry: dict) -> tuple[list[tuple[Call, str | None]],
                                                              dict[str, int]]:
    """每条调用归到「树内声明 / 三段放行 / 未解析」，并统计放行段覆盖的调用点数。

    放行段的计数口径：external + in_tree_missing + dynamic 的 **methods** 模式。
    dynamic 的 resource 模式（qb-core / qb-fuel 的运行时循环）无法逐方法计数，不计入
    `review.allowlisted_call_sites`。
    """
    dynamic = _allowed_dynamic(registry)
    external = _allowed_external(registry)
    in_tree_missing = _allowed_in_tree_missing(registry)
    counts = {"external": 0, "in_tree_missing": 0, "dynamic_methods": 0}

    classified: list[tuple[Call, str | None]] = []
    for call in scan_result.calls:
        if (call.resource in scan_result.resource_dirs
                and call.method in scan_result.declarations.get(call.resource, set())):
            classified.append((call, "declared"))
            continue
        if call.resource in dynamic and dynamic[call.resource] is None:
            classified.append((call, "dynamic_resource"))
            continue
        if call.resource in dynamic and call.method in dynamic[call.resource]:
            counts["dynamic_methods"] += 1
            classified.append((call, "dynamic_methods"))
            continue
        if call.method in in_tree_missing.get(call.resource, set()):
            counts["in_tree_missing"] += 1
            classified.append((call, "in_tree_missing"))
            continue
        if call.method in external.get(call.resource, set()):
            counts["external"] += 1
            classified.append((call, "external"))
            continue
        classified.append((call, None))
    return classified, counts


def allowlisted_counts(scan_result: Scan, registry: dict) -> dict[str, int]:
    """放行段覆盖的调用点数；同时写回 `Scan.allowlisted` 供前向测试/k 计数核对。"""
    _, counts = classify_calls(scan_result, registry)
    scan_result.allowlisted = counts
    return counts


def expired_in_tree_missing(registry: dict, today: date | None = None) -> list[str]:
    """返回 `in_tree_missing_exports` 里已过期或 expires 解析不了的条目。"""
    today = today or date.today()
    problems: list[str] = []
    for resource, spec in (registry.get("in_tree_missing_exports") or {}).items():
        raw = (spec or {}).get("expires")
        try:
            when = date.fromisoformat(str(raw))
        except ValueError:
            problems.append(f"in_tree_missing_exports[{resource}]: expires 不是 ISO 日期 — {raw!r}")
            continue
        if when < today:
            problems.append(f"in_tree_missing_exports[{resource}] 已于 {when} 到期（修掉或删条目）")
    return problems


def _external_service_call_sites(scan_result: Scan, registry: dict) -> list[Call]:
    owner = {}
    for service, spec in (registry.get("services") or {}).items():
        owner[service] = (spec or {}).get("owner")
    sites = []
    for call in scan_result.calls:
        if not call.method.startswith("service_"):
            continue
        match = SERVICE_EXPORT_RE.match(call.method)
        if not match:
            continue
        service = match.group("svc")
        if service in owner and owner[service] and call.caller != call.resource:
            sites.append(call)
    return sites


def call_violations(scan_result: Scan, registry: dict) -> list[str]:
    """每条调用必须能解析到：树内字面量声明 / dynamic_exports / external_exports /
    in_tree_missing_exports。"""
    problems: list[str] = []
    classified, counts = classify_calls(scan_result, registry)
    scan_result.allowlisted = counts

    for call, kind in classified:
        if kind is not None:
            continue
        if call.resource in scan_result.resource_dirs:
            problems.append(
                f"{call.where()}: exports['{call.resource}']:{call.method}() 在树内资源里找不到声明")
        else:
            problems.append(
                f"{call.where()}: exports['{call.resource}']:{call.method}() 的资源不在树内，"
                "也没有登记进 external_exports")
    return problems


def allowlist_violations(scan_result: Scan, registry: dict) -> list[str]:
    """放行表自身的诚实性：树外/树内分层、到期日、放行总数锚点。"""
    problems: list[str] = []

    in_tree = registry.get("in_tree_missing_exports")
    if not isinstance(in_tree, dict):
        problems.append("service_contracts.json 缺 `in_tree_missing_exports` 段（或不是对象）")
        in_tree = {}

    for resource, spec in in_tree.items():
        if not isinstance(spec, dict):
            problems.append(f"in_tree_missing_exports[{resource}]: 条目必须是对象")
            continue
        for field_name in ("methods", "owner", "why", "source", "follow_up", "expires"):
            if not spec.get(field_name):
                problems.append(f"in_tree_missing_exports[{resource}]: 缺 `{field_name}`")
        methods = spec.get("methods") if isinstance(spec.get("methods"), list) else []
        if resource not in scan_result.resource_dirs:
            problems.append(
                f"in_tree_missing_exports[{resource}]: 不是树内资源；树外资源请登记 external_exports")
            continue
        for method in methods:
            if method in scan_result.declarations.get(resource, set()):
                problems.append(
                    f"in_tree_missing_exports[{resource}]:{method} 在代码里已有声明，不能登记为缺失")

    for resource, spec in (registry.get("external_exports") or {}).items():
        if resource in scan_result.resource_dirs:
            problems.append(
                f"external_exports[{resource}]: 资源在树内；树内缺导出请登记 in_tree_missing_exports")
        methods = (spec or {}).get("methods")
        if not isinstance(methods, list) or not methods:
            problems.append(f"external_exports[{resource}]: methods 必须是非空列表")

    problems.extend(expired_in_tree_missing(registry))

    counts = allowlisted_counts(scan_result, registry)
    total = sum(counts.values())
    expected = (registry.get("review") or {}).get("allowlisted_call_sites")
    if not isinstance(expected, int) or isinstance(expected, bool):
        problems.append("review.allowlisted_call_sites 必须是整数")
    elif expected != total:
        problems.append(
            f"review.allowlisted_call_sites 写的是 {expected}，实测 {total} 处"
            f"（external={counts['external']} / in_tree_missing={counts['in_tree_missing']} / "
            f"dynamic_methods={counts['dynamic_methods']}）；加了一条放行就同步改这个数字")
    return problems


def registry_violations(scan_result: Scan, registry: dict) -> list[str]:
    """登记表自身的完整性：段缺失、service_* 对账、review 锚点。"""
    problems: list[str] = []

    for key in ("services", "planned_services", "dynamic_exports",
                "external_exports", "in_tree_missing_exports", "plugin_contract", "review"):
        if key not in registry:
            problems.append(f"service_contracts.json 缺 `{key}` 段")

    services = registry.get("services") or {}

    for resource, spec in (registry.get("dynamic_exports") or {}).items():
        mode = (spec or {}).get("mode")
        if mode not in ("resource", "methods"):
            problems.append(f"dynamic_exports[{resource}]: mode 必须是 resource/methods")
        if mode == "methods" and not (spec or {}).get("methods"):
            problems.append(f"dynamic_exports[{resource}]: methods 为空，等于没登记")

    # 1) 每条 service_* 声明必须在 services 里恰好有一条，反之亦然。
    declared_services = scan_result.declared_service_methods()
    for service in sorted(set(declared_services) | set(services)):
        declared = set(declared_services.get(service, {}))
        registered = set((services.get(service) or {}).get("methods") or {})
        for method in sorted(declared - registered):
            path, line = declared_services[service][method]
            problems.append(
                f"service_{service}_{method} 已声明，但 service_contracts.json 没有对应条目"
                f"（resources/{path}:{line}）")
        for method in sorted(registered - declared):
            problems.append(
                f"service_contracts.json 登记了 service_{service}_{method}，但代码里没有声明（死条目）")

    # 2) review 锚点必须与实测一致，且被外部调用的方法必须人工复核过。
    review = registry.get("review") or {}
    sites = _external_service_call_sites(scan_result, registry)
    expected = review.get("external_call_sites")
    if expected != len(sites):
        problems.append(
            f"review.external_call_sites 写的是 {expected!r}，实测 {len(sites)} 处；"
            "调用面变了就更新登记表（review diff 后提交）")
    called_services = sorted({
        match.group("svc") for match in map(SERVICE_EXPORT_RE.match, (c.method for c in sites))
        if match
    })
    if sorted(review.get("services") or []) != called_services:
        problems.append(
            f"review.services 与实测被外部调用的服务不一致：登记 {review.get('services')!r}，"
            f"实测 {called_services!r}")
    for call in sites:
        match = SERVICE_EXPORT_RE.match(call.method)
        if not match:
            problems.append(f"{call.where()}: 无法从 {call.method} 解析出服务名")
            continue
        service, method = match.group("svc"), match.group("method")
        entry = (((services.get(service) or {}).get("methods") or {}).get(method) or {})
        if entry.get("reviewed") is not True:
            problems.append(
                f"service_{service}_{method} 有外部调用（{call.where()}），但登记条目 reviewed != true")

    return problems


def violations(scan_result: Scan, registry: dict) -> list[str]:
    """把「放行表不诚实」「调用解析不了」「service_* 登记不齐」一次说清。"""
    return (allowlist_violations(scan_result, registry)
            + registry_violations(scan_result, registry)
            + call_violations(scan_result, registry))


def _existing_methods(registry: dict) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for service, spec in (registry.get("services") or {}).items():
        for method, entry in ((spec or {}).get("methods") or {}).items():
            out[f"{service}.{method}"] = entry if isinstance(entry, dict) else {}
    return out


def update_registry(registry: dict, scan_result: Scan) -> dict:
    """从代码重生成 `services` / `planned_services`，其余段原样保留。"""
    definitions = _function_params(RESOURCES)   # 只有生成器需要形参表
    existing = _existing_methods(registry)
    merged = scan_result.declared_service_methods()

    services: dict[str, dict] = {}
    for service in sorted(merged):
        methods: dict[str, dict] = {}
        for method in sorted(merged[service]):
            old = existing.get(f"{service}.{method}", {})
            methods[method] = {
                "args": _resolve_args(
                    scan_result.service_values.get(service, {}).get(method, ""), definitions),
                "returns": old.get("returns", "unverified"),
                "failure": old.get("failure", "unverified"),
                "reviewed": old.get("reviewed", False),
            }
        owner = None
        for source in (scan_result.service_methods, scan_result.literal_service_methods):
            if service in source and source[service]:
                path = next(iter(source[service].values()))[0]
                owner = _owner_for_path(scan_result, path)
                break
        services[service] = {
            "status": "planned" if service in PLANNED_SERVICES else "implemented",
            "owner": owner,
            "methods": methods,
        }

    updated = dict(registry)
    updated["schema_version"] = 1
    updated["services"] = services
    updated["planned_services"] = sorted(PLANNED_SERVICES)
    return updated


def _owner_for_path(scan_result: Scan, relative: str) -> str | None:
    """`relative` 是相对 resources/ 的路径；最近的有 fxmanifest 的目录就是资源名。"""
    parts = relative.split("/")
    for size in range(len(parts) - 1, 0, -1):
        candidate = parts[size - 1]
        if candidate in scan_result.resource_dirs:
            return candidate
    return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--update", action="store_true",
                        help="从代码重生成 services / planned_services（review diff 后再提交）")
    args = parser.parse_args(argv[1:])

    if not RESOURCES.is_dir():
        print(f"找不到资源目录：{RESOURCES}", file=sys.stderr)
        return 2

    scan_result = scan()
    if args.update and not REGISTRY.is_file():
        print(f"登记表不存在：{REGISTRY}（先提交人工段，再跑 --update）", file=sys.stderr)
        return 2
    registry = load_registry() if REGISTRY.is_file() else {}

    if args.update:
        updated = update_registry(registry, scan_result)
        # NOSONAR 固定目标路径（模块常量 REGISTRY），写入内容是本脚本从代码生成的 JSON，
        # 不含任何来自文件内容的路径片段 —— 与 tools/dev/booth_roads.py 的同类标注一致。
        REGISTRY.write_text(json.dumps(updated, ensure_ascii=False, indent=2) + "\n",
                            encoding="utf-8")
        total = sum(len(spec.get("methods") or {}) for spec in updated["services"].values())
        print(f"已写入 {REGISTRY.relative_to(REPO)}："
              f"{len(updated['services'])} 个服务 / {total} 个方法")
        return 0

    problems = violations(scan_result, registry)
    if args.json:
        print(json.dumps({
            "calls": len(scan_result.calls),
            "resources": len(scan_result.resource_dirs),
            "services": len(scan_result.declared_service_methods()),
            "service_methods": sum(len(v) for v in scan_result.declared_service_methods().values()),
            "problems": problems,
        }, ensure_ascii=False, indent=2))
        return 0

    print(f"扫描 {len(scan_result.calls)} 处字面量导出调用 / "
          f"{len(scan_result.resource_dirs)} 个资源 / "
          f"{sum(len(v) for v in scan_result.declared_service_methods().values())} 个 service 方法")
    if not problems:
        print("未发现未解析的导出调用。")
        return 0
    print(f"\n发现 {len(problems)} 条问题：")
    for problem in problems:
        print("  -", problem)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
