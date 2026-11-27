"""菜单架构棘轮闸门（M7 / #349）：只许比现在小，不许大。

四条不变量：
1. 三边界约束：已接栈资源中 `SetNuiFocus*` 只能出现在 `ApplyFocus`（含其委托的本地包装函数）、
   `onResourceStop`、`onClientResourceStop` 三个合法边界，禁止散落在业务/回调/循环里；
2. 全仓调用点登记：全仓所有 `.lua` 的 `SetNuiFocus*` 必须全部在 `menu_focus_allowlist.json`
   按文件登记计数，任何未登记的新增或计数膨胀立即变红；
3. 基线可复算：`menu_surface_baseline.json` 的每一个数字都必须能由 `tools/dev/menu_surface_census.py`
   实时扫描复算出来（含 `excluded` 与 `non_excluded_total`），拒绝过期或篡改的数字；
4. 单调棘轮：`menuv_entry`、`disable_all_controls`、`backdrop_filter`、`cdn_ref`、
   `client_wait_zero`、`isnuifocused_read`、`setnui_single_arg` 只能保持或下降，绝不允许回弹。
"""
from __future__ import annotations

import copy
import json
import re
import sys
from pathlib import Path

import lua_source
import test_no_backdrop_filter

ARCH_DIR = Path(__file__).resolve().parent
BASE_DIR = ARCH_DIR.parents[1]
REPO_ROOT = BASE_DIR.parent
RESOURCES = BASE_DIR / "resources"
BASELINE_PATH = ARCH_DIR / "menu_surface_baseline.json"
FOCUS_ALLOWLIST_PATH = ARCH_DIR / "menu_focus_allowlist.json"
M4_ALLOWLIST_PATH = ARCH_DIR / "m4_focus_allowlist.json"
CUSTOM_PHONE_DIR = RESOURCES / "[custom]" / "custom-phone"

TOOLS_DEV = REPO_ROOT / "tools" / "dev"
if str(TOOLS_DEV) not in sys.path:
    sys.path.insert(0, str(TOOLS_DEV))

import menu_surface_census  # noqa: E402

SETNUI_RE = re.compile(r"\bSetNuiFocus(?:KeepInput)?\s*\(")
APPLY_FOCUS_RE = re.compile(r"\bexports\s*\(\s*['\"]ApplyFocus['\"]\s*,")
RESOURCE_STOP_RE = re.compile(r"\bAddEventHandler\s*\(\s*['\"]on(?:Client)?ResourceStop['\"]\s*,")
LUA_BLOCK_TOKEN_RE = re.compile(r"(?<!\.)\b(function|if|do|end)\b")
WAIT_ZERO_RE = re.compile(r"\bWait\s*\(\s*0\s*\)")
DISABLE_ALL_RE = re.compile(r"\bDisableAllControlActions\s*\(")


def _find_lua_function_span(code_only: str, fn_name: str) -> tuple[int, int] | None:
    """用词法骨架配平 `local function fn_name(...) ... end` 的字符区间。"""
    decl = re.search(rf"(?:\blocal\s+)?\bfunction\s+{re.escape(fn_name)}\s*\(", code_only)
    if not decl:
        return None
    depth = 0
    for match in LUA_BLOCK_TOKEN_RE.finditer(code_only, decl.start()):
        token = match.group(1)
        if token in {"function", "if", "do"}:
            depth += 1
        elif token == "end":
            depth -= 1
            if depth == 0:
                return (decl.start(), match.end())
    return None


def collect_sanctioned_spans(source: str, wrappers: tuple[str, ...] = ()) -> tuple[list[tuple[int, int]], list[str]]:
    """收集 ApplyFocus / onResourceStop / onClientResourceStop（及经 ApplyFocus 委托的 wrapper）区间。"""
    code_only = lua_source.blank_noise(source)
    with_strings = lua_source.blank_noise(source, keep_strings=True)

    apply_spans: list[tuple[int, int]] = []
    for match in APPLY_FOCUS_RE.finditer(with_strings):
        open_idx = with_strings.find("(", match.start())
        apply_spans.append((match.start(), lua_source.match_paren(with_strings, open_idx)))

    stop_spans: list[tuple[int, int]] = []
    for match in RESOURCE_STOP_RE.finditer(with_strings):
        open_idx = with_strings.find("(", match.start())
        stop_spans.append((match.start(), lua_source.match_paren(with_strings, open_idx)))

    errors: list[str] = []
    wrapper_spans: list[tuple[int, int]] = []
    for name in wrappers:
        invoked_in_apply = any(
            re.search(rf"\b{re.escape(name)}\s*\(", code_only[s:e]) for s, e in apply_spans
        )
        if not invoked_in_apply:
            errors.append(f"包装函数 {name} 未被 exports('ApplyFocus', ...) 调用")
            continue
        span = _find_lua_function_span(code_only, name)
        if span is None:
            errors.append(f"找不到合法边界包装函数 {name} 的闭合区间")
            continue
        wrapper_spans.append(span)

    return [*apply_spans, *stop_spans, *wrapper_spans], errors


def find_boundary_violations(source: str, wrappers: tuple[str, ...] = ()) -> list[str]:
    """返回所有落入三边界之外的 `SetNuiFocus*` 违规说明。"""
    spans, errors = collect_sanctioned_spans(source, wrappers)
    code_only = lua_source.blank_noise(source)
    for match in SETNUI_RE.finditer(code_only):
        if not lua_source.in_spans(match.start(), spans):
            lineno = lua_source.line_of(code_only, match.start())
            errors.append(f"L{lineno}: {match.group(0).strip()} 落在三边界之外")
    return errors


def scan_setnui_counts(resources_dir: Path) -> dict[str, int]:
    """扫描目录下所有 `.lua` 文件，统计代码骨架里的 `SetNuiFocus*` 次数。"""
    counts: dict[str, int] = {}
    for path in sorted(resources_dir.rglob("*.lua")):
        rel = path.relative_to(resources_dir.parent).as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")
        hits = len(SETNUI_RE.findall(lua_source.blank_noise(text)))
        if hits:
            counts[rel] = hits
    return counts


def audit_focus_registry(actual_counts: dict[str, int], entries: list[dict]) -> list[str]:
    """校验全仓 SetNuiFocus* 调用点是否全部精准登记，发现未登记/膨胀/过期条目立即报错。"""
    registered: dict[str, int] = {}
    problems: list[str] = []
    for entry in entries:
        rel = entry.get("file", "")
        if rel in registered:
            problems.append(f"重复登记文件: {rel}")
        registered[rel] = int(entry.get("count", -1))

    for rel, actual in sorted(actual_counts.items()):
        if rel not in registered:
            problems.append(f"未登记的 SetNuiFocus 调用文件: {rel} ({actual} 处)")
        elif actual > registered[rel]:
            problems.append(f"{rel} SetNuiFocus 数量膨胀: 实测 {actual} > 登记 {registered[rel]}")
        elif actual < registered[rel]:
            problems.append(f"{rel} 登记未同步收紧: 实测 {actual} < 登记 {registered[rel]}")

    for rel, expected in sorted(registered.items()):
        if rel not in actual_counts:
            problems.append(f"{rel} 已清零（登记 {expected}），请从 menu_focus_allowlist.json 移除以收紧棘轮")

    return problems


def recompute_census_snapshot(baseline: dict, live: dict | None = None) -> dict:
    """基于 census 实时扫描结果与基线里的 excluded 声明重算期望基线。"""
    snapshot = copy.deepcopy(live if live is not None else menu_surface_census.scan())
    for feature, fresh in snapshot.items():
        old_block = baseline.get(feature)
        if not isinstance(old_block, dict):
            continue
        excluded = old_block.get("excluded")
        if excluded:
            fresh["excluded"] = copy.deepcopy(excluded)
            excluded_total = sum(int(item.get("count") or 0) for item in excluded.values())
            fresh["non_excluded_total"] = max(int(fresh["total"]) - excluded_total, 0)
    return snapshot


def verify_baseline_recomputable(baseline: dict, expected: dict) -> list[str]:
    """断言基线文件里的每一个数字都能由 menu_surface_census 复算。"""
    errors: list[str] = []
    if set(baseline.keys()) != set(expected.keys()):
        errors.append(f"基线分类集合与 census 不一致: {sorted(baseline)} vs {sorted(expected)}")
        return errors

    for category, live_block in expected.items():
        base_block = baseline[category]
        if int(base_block.get("total", -1)) != int(live_block["total"]):
            errors.append(f"{category}.total={base_block.get('total')} 与 census={live_block['total']} 不一致")
        base_resources = base_block.get("resources", {})
        if base_resources != live_block["resources"]:
            errors.append(f"{category}.resources 与 census 不一致")
        if sum(base_resources.values()) != int(base_block.get("total", -1)):
            errors.append(f"{category} resources 求和不等于 total")
        if base_block.get("samples") != live_block["samples"]:
            errors.append(f"{category}.samples 与 census 不一致")

        excluded = base_block.get("excluded")
        if excluded:
            for res_name, meta in excluded.items():
                live_res = int(live_block["resources"].get(res_name, 0))
                if int(meta.get("count", -1)) != live_res:
                    errors.append(f"{category}.excluded.{res_name}.count={meta.get('count')} != census={live_res}")
            if int(base_block.get("non_excluded_total", -1)) != int(live_block.get("non_excluded_total", -2)):
                errors.append(
                    f"{category}.non_excluded_total={base_block.get('non_excluded_total')} "
                    f"!= census={live_block.get('non_excluded_total')}"
                )
    return errors


def verify_surface_ratchets(
    live: dict,
    baseline: dict,
    *,
    allowed_disable_resources: set[str],
    phone_wait_zero_max: int = 1,
) -> list[str]:
    """校验棘轮约束：只许比当前基线小，不许大。"""
    errors: list[str] = []

    menuv_resources = set(live["menuv_entry"]["resources"].keys())
    if not menuv_resources.issubset({"menuv"}):
        errors.append(f"menuv 之外出现 MenuV 调用: {sorted(menuv_resources - {'menuv'})}")
    if live["menuv_entry"]["total"] > baseline["menuv_entry"]["total"]:
        errors.append(f"menuv_entry 超基线: {live['menuv_entry']['total']} > {baseline['menuv_entry']['total']}")

    disable_res = set(live["disable_all_controls"]["resources"].keys())
    base_disable_res = set(baseline["disable_all_controls"]["resources"].keys())
    if not disable_res.issubset(base_disable_res | allowed_disable_resources):
        errors.append(
            f"未授权资源出现 DisableAllControlActions: {sorted(disable_res - (base_disable_res | allowed_disable_resources))}"
        )
    if live["disable_all_controls"]["total"] > baseline["disable_all_controls"]["total"]:
        errors.append(
            f"disable_all_controls 超基线: {live['disable_all_controls']['total']} > "
            f"{baseline['disable_all_controls']['total']}"
        )
    for res, cnt in live["disable_all_controls"]["resources"].items():
        cap = baseline["disable_all_controls"]["resources"].get(res, 0)
        if cnt > cap:
            errors.append(f"disable_all_controls[{res}] 超基线: {cnt} > {cap}")

    backdrop_excluded = baseline["backdrop_filter"]["excluded"]
    if set(backdrop_excluded.keys()) != {"monitor"}:
        errors.append(f"backdrop_filter excluded 出现未知豁免资源: {sorted(backdrop_excluded)}")
    non_excluded_backdrop = live["backdrop_filter"]["total"] - sum(
        int(v["count"]) for v in backdrop_excluded.values()
    )
    if non_excluded_backdrop > int(baseline["backdrop_filter"]["non_excluded_total"]):
        errors.append(
            f"backdrop_filter non_excluded_total 超基线: {non_excluded_backdrop} > "
            f"{baseline['backdrop_filter']['non_excluded_total']}"
        )

    if live["cdn_ref"]["total"] > baseline["cdn_ref"]["total"]:
        errors.append(f"cdn_ref 超基线: {live['cdn_ref']['total']} > {baseline['cdn_ref']['total']}")
    for res, cnt in live["cdn_ref"]["resources"].items():
        cap = baseline["cdn_ref"]["resources"].get(res, 0)
        if cnt > cap:
            errors.append(f"cdn_ref[{res}] 超基线: {cnt} > {cap}")

    if live["client_wait_zero"]["total"] > baseline["client_wait_zero"]["total"]:
        errors.append(
            f"client_wait_zero 超基线: {live['client_wait_zero']['total']} > "
            f"{baseline['client_wait_zero']['total']}"
        )
    phone_waits = int(live["client_wait_zero"]["resources"].get("custom-phone", 0))
    if phone_waits > phone_wait_zero_max:
        errors.append(f"custom-phone Wait(0) 超单点泵预算: {phone_waits} > {phone_wait_zero_max}")

    for metric in ("setnui_single_arg", "isnuifocused_read"):
        if live[metric]["total"] > baseline[metric]["total"]:
            errors.append(f"{metric} 超基线: {live[metric]['total']} > {baseline[metric]['total']}")

    return errors


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_setnui_focus_boundaries_rejects_calls_outside_three_sanctioned_boundaries() -> None:
    """所有已接栈资源中的 SetNuiFocus* 必须严格留在 ApplyFocus / onResourceStop / onClientResourceStop 内。"""
    allowlist = _load_json(FOCUS_ALLOWLIST_PATH)
    sanctioned = [e for e in allowlist["entries"] if e.get("kind") == "sanctioned_boundaries"]
    assert len(sanctioned) == 5, f"预期 5 个三边界文件，实际 {len(sanctioned)}"

    for entry in sanctioned:
        path = BASE_DIR / entry["file"]
        source = path.read_text(encoding="utf-8")
        wrappers = tuple(entry.get("wrappers", ()))
        violations = find_boundary_violations(source, wrappers)
        assert not violations, f"{entry['file']} 存在边界违规:\n" + "\n".join(violations)

    # 反向注入自证：向三边界之外注入一行 SetNuiFocus(true, true)，必须立即变红
    host_path = RESOURCES / "[custom]" / "custom-menu" / "client" / "host.lua"
    host_source = host_path.read_text(encoding="utf-8")
    injected_host = host_source.replace(
        "exports('Close', function(reason)",
        "local function leakedFocus()\n    SetNuiFocus(true, true)\nend\nexports('Close', function(reason)",
        1,
    )
    assert injected_host != host_source
    assert find_boundary_violations(injected_host), "反向注入 host 三边界外调用必须报错"

    target_path = RESOURCES / "[qb]" / "qb-target" / "client.lua"
    target_source = target_path.read_text(encoding="utf-8")
    injected_target = target_source + "\nlocal function badLeak()\n    SetNuiFocus(true, true)\nend\n"
    assert find_boundary_violations(injected_target, ("applyTargetFocus",)), (
        "反向注入 qb-target 边界外调用必须报错"
    )


def test_setnui_focus_registry_rejects_unregistered_calls(tmp_path: Path) -> None:
    """全仓所有 SetNuiFocus* 必须逐文件登记并核对精确次数；漏登或超数必须红。"""
    allowlist = _load_json(FOCUS_ALLOWLIST_PATH)
    actual_counts = scan_setnui_counts(RESOURCES)
    problems = audit_focus_registry(actual_counts, allowlist["entries"])
    assert not problems, "SetNuiFocus 登记审计失败:\n" + "\n".join(problems)

    # 反向注入 1：临时资源目录里新增一处未登记的 SetNuiFocus(true, true) -> 必须红
    fake_res = tmp_path / "resources" / "[custom]" / "fake-leak"
    fake_res.mkdir(parents=True)
    (fake_res / "client.lua").write_text("RegisterCommand('x', function() SetNuiFocus(true, true) end)\n", encoding="utf-8")
    injected_counts = scan_setnui_counts(tmp_path / "resources")
    assert audit_focus_registry(injected_counts, []), "未登记文件的 SetNuiFocus 必须变红"

    # 反向注入 2：往已登记的文件额外注入一处 SetNuiFocus -> 次数超过登记必须红
    bumped_counts = dict(actual_counts)
    first_rel = next(iter(bumped_counts))
    bumped_counts[first_rel] += 1
    assert audit_focus_registry(bumped_counts, allowlist["entries"]), (
        f"向已登记文件 {first_rel} 多注入 1 处 SetNuiFocus 必须变红"
    )


def test_menu_baseline_census_rejects_unrecomputable_numbers() -> None:
    """menu_surface_baseline.json 中每一个数字都必须能由 menu_surface_census 复算，篡改任何一项即红。"""
    baseline = _load_json(BASELINE_PATH)
    expected = recompute_census_snapshot(baseline)
    errors = verify_baseline_recomputable(baseline, expected)
    assert not errors, "基线与实时 census 不一致:\n" + "\n".join(errors)

    # 反向注入：把基线任意字段调高或调低，校验函数必须报错
    tampered_total = copy.deepcopy(baseline)
    tampered_total["cdn_ref"]["total"] += 1
    assert verify_baseline_recomputable(tampered_total, expected), "篡改 total 必须变红"

    tampered_excluded = copy.deepcopy(baseline)
    tampered_excluded["backdrop_filter"]["non_excluded_total"] += 1
    assert verify_baseline_recomputable(tampered_excluded, expected), "篡改 non_excluded_total 必须变红"

    tampered_res = copy.deepcopy(baseline)
    tampered_res["client_wait_zero"]["resources"]["custom-phone"] = 2
    assert verify_baseline_recomputable(tampered_res, expected), "篡改分资源计数必须变红"


def test_menu_surface_ratchet_detects_menuv_disable_all_backdrop_cdn_and_wait_zero_growth() -> None:
    """menuv / disable_all_controls / backdrop_filter / cdn_ref / Wait(0) / IsNuiFocused 不许涨。"""
    baseline = _load_json(BASELINE_PATH)
    live = menu_surface_census.scan()

    m4 = _load_json(M4_ALLOWLIST_PATH)
    allowed_disable_entries = [
        entry for entry in m4["entries"] if entry.get("kind") == "legitimate_disable_all"
    ]
    allowed_disable = {entry["resource"] for entry in allowed_disable_entries}
    allowed_disable_files = {entry["file"]: int(entry["count"]) for entry in allowed_disable_entries}

    errors = verify_surface_ratchets(live, baseline, allowed_disable_resources=allowed_disable)
    assert not errors, "菜单架构棘轮失败:\n" + "\n".join(errors)

    # 确认实际代码里的 DisableAllControlActions 只出现在 m4_focus_allowlist 登记的 4 个合法文件
    active_disable: dict[str, int] = {}
    for path in sorted(RESOURCES.rglob("*.lua")):
        cleaned = lua_source.blank_noise(path.read_text(encoding="utf-8", errors="replace"))
        hits = len(DISABLE_ALL_RE.findall(cleaned))
        if hits:
            active_disable[path.relative_to(BASE_DIR).as_posix()] = hits
    assert active_disable == allowed_disable_files, (
        f"实际代码 DisableAllControlActions 与 m4_focus_allowlist 不一致: {active_disable} vs {allowed_disable_files}"
    )

    # 额外确认 custom-phone 仅存 1 处 Wait(0) 且在 main.lua 内、不在 device_lock.lua 内
    phone_wait_files = []
    for path in sorted(CUSTOM_PHONE_DIR.rglob("*.lua")):
        cleaned = lua_source.blank_noise(path.read_text(encoding="utf-8"))
        hits = len(WAIT_ZERO_RE.findall(cleaned))
        if hits:
            phone_wait_files.append((path.relative_to(CUSTOM_PHONE_DIR).as_posix(), hits))
    assert phone_wait_files == [("client/main.lua", 1)], (
        f"custom-phone 必须收口为单点每帧泵，实际 Wait(0): {phone_wait_files}"
    )

    # 确认除 monitor 外不存在非注释的生效 backdrop-filter
    active_backdrop = test_no_backdrop_filter.scan_backdrop_filter(
        RESOURCES, excluded=set(baseline["backdrop_filter"]["excluded"])
    )
    assert not active_backdrop, f"发现生效中的非 monitor backdrop-filter: {active_backdrop}"

    # 反向注入自证：每条指标注入超额项都必须被棘轮拦住
    bad_menuv = copy.deepcopy(live)
    bad_menuv["menuv_entry"]["resources"]["qb-adminmenu"] = 1
    bad_menuv["menuv_entry"]["total"] += 1
    assert verify_surface_ratchets(bad_menuv, baseline, allowed_disable_resources=allowed_disable)

    bad_disable = copy.deepcopy(live)
    bad_disable["disable_all_controls"]["resources"]["custom-menu"] = 1
    bad_disable["disable_all_controls"]["total"] += 1
    assert verify_surface_ratchets(bad_disable, baseline, allowed_disable_resources=allowed_disable)

    bad_backdrop = copy.deepcopy(live)
    bad_backdrop["backdrop_filter"]["total"] += 1
    assert verify_surface_ratchets(bad_backdrop, baseline, allowed_disable_resources=allowed_disable)

    bad_cdn = copy.deepcopy(live)
    bad_cdn["cdn_ref"]["total"] += 1
    assert verify_surface_ratchets(bad_cdn, baseline, allowed_disable_resources=allowed_disable)

    bad_wait = copy.deepcopy(live)
    bad_wait["client_wait_zero"]["resources"]["custom-phone"] = 2
    assert verify_surface_ratchets(bad_wait, baseline, allowed_disable_resources=allowed_disable)
