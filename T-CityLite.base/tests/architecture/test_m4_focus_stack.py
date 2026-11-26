"""M4 焦点栈收口（#346）：qb-target / qb-inventory / qb-hud / story-engine 契约闸门。

规则全部按四目标目录限域（不扫全仓），且每条规则自带反向校验：
1. 四目录内门卫用途 ``IsNuiFocused()`` / ``IsNuiFocusKeepingInput()`` = 0；
   诊断用途仅允许出现在 ``m4_focus_allowlist.json``（``diagnostic_read``）登记的文件且不得处于控制流门卫表达式中（互斥）；
2. 四目录内菜单/面板焦点必须经 ``custom-ui`` 栈（``Push`` / ``Pop`` / ``IsTaken`` / ``ApplyFocus`` / ``ForceClose`` / ``onResourceStop``），
   禁止在业务路径裸调 ``SetNuiFocus*``，且 ``GetResourceState('custom-ui')`` 必须在调用期判断而非文件加载期缓存；
3. 四目录内菜单路径禁止 ``DisableAllControlActions``；全仓其余合法点（noclip / 死亡态 / spawn / 押送 / 原生键盘）
   逐条登记在 ``m4_focus_allowlist.json``（``legitimate_disable_all``），含理由与到期日；
4. 反向注入（把 ``IsTaken`` 换回 ``IsNuiFocused``、把诊断 allowlist 文件塞入门卫判断、在业务路径塞裸 ``SetNuiFocus``、
   在四目录内或未登记文件塞 ``DisableAllControlActions``、过期 allowlist）必须全部红。
"""
from __future__ import annotations

import json
import re
from datetime import date
from pathlib import Path

from lua_source import blank, blank_noise, line_of

BASE = Path(__file__).resolve().parents[2]
RESOURCES = BASE / "resources"
ALLOWLIST_PATH = Path(__file__).with_name("m4_focus_allowlist.json")

M4_TARGET_DIRS: tuple[str, ...] = (
    "resources/[qb]/qb-target",
    "resources/[qb]/qb-inventory",
    "resources/[qb]/qb-hud",
    "resources/[custom]/story-engine",
)

M4_CLIENT_FILES: dict[str, tuple[str, ...]] = {
    "qb-target": ("resources/[qb]/qb-target/client.lua",),
    "qb-inventory": ("resources/[qb]/qb-inventory/client/main.lua",),
    "qb-hud": ("resources/[qb]/qb-hud/client.lua",),
    "story-engine": ("resources/[custom]/story-engine/client/main.lua",),
}

IS_NUI_FOCUSED_RE = re.compile(r"\bIsNuiFocus(?:ed|KeepingInput)\s*\(")
SET_NUI_FOCUS_RE = re.compile(r"\bSetNuiFocus(?:KeepInput)?\s*\(")
DISABLE_ALL_RE = re.compile(r"\bDisableAllControlActions\s*\(")
GUARD_CONTEXT_RE = re.compile(r"\b(?:if|elseif|while|until|return|not|and|or)\b")
LOAD_TIME_STATE_RE = re.compile(
    r"^\s*local\s+\w+\s*=[^\n]*GetResourceState\s*\(\s*['\"]custom-ui['\"]\s*\)",
    re.M,
)

SANCTIONED_FOCUS_BLOCKS = (
    re.compile(r"^local function apply\w*Focus\s*\(.*?^end\b", re.M | re.S),
    re.compile(r"^exports\s*\(\s*['\"]ApplyFocus['\"]\s*,\s*function\s*\(.*?^end\)", re.M | re.S),
    re.compile(r"^AddEventHandler\s*\(\s*['\"]onResourceStop['\"]\s*,\s*function\s*\(.*?^end\)", re.M | re.S),
)


def _load_allowlist() -> dict:
    return json.loads(ALLOWLIST_PATH.read_text(encoding="utf-8"))


def _target_lua_files(base_dir: Path) -> list[Path]:
    files: list[Path] = []
    for rel_dir in M4_TARGET_DIRS:
        root = base_dir / rel_dir
        if root.is_dir():
            files.extend(sorted(p for p in root.rglob("*.lua") if "node_modules" not in p.parts))
    return files


def _all_lua_files(base_dir: Path) -> list[Path]:
    res_dir = base_dir / "resources"
    if not res_dir.is_dir():
        return []
    return sorted(p for p in res_dir.rglob("*.lua") if "node_modules" not in p.parts)


def _validate_allowlist_entries(entries: list[dict], today: date) -> list[str]:
    bad: list[str] = []
    seen_ids: set[str] = set()
    for entry in entries:
        entry_id = entry.get("id", "?")
        if entry_id in seen_ids:
            bad.append(f"duplicate allowlist id {entry_id!r}")
        seen_ids.add(entry_id)
        for field in ("id", "kind", "resource", "file", "reason", "owner", "added", "expires"):
            if not entry.get(field):
                bad.append(f"{entry_id}: missing required field {field!r}")
        if entry.get("kind") not in ("diagnostic_read", "legitimate_disable_all"):
            bad.append(f"{entry_id}: unknown kind {entry.get('kind')!r}")
        expires = entry.get("expires")
        if expires:
            try:
                if date.fromisoformat(str(expires)) < today:
                    bad.append(f"{entry_id}: allowlist entry expired on {expires}")
            except ValueError:
                bad.append(f"{entry_id}: invalid ISO expires date {expires!r}")
    return bad


def violations_in_isnuifocused_targets(
    base_dir: Path,
    allowlist: dict,
    *,
    today: date | None = None,
    overrides: dict[str, str] | None = None,
) -> list[str]:
    """四目录内门卫用途 IsNuiFocused() 必须为 0；诊断用途与 allowlist 互斥且计数精准。"""
    today = today or date.today()
    overrides = overrides or {}
    entries = allowlist.get("entries", [])
    diag_entries = [e for e in entries if e.get("kind") == "diagnostic_read"]
    bad = _validate_allowlist_entries(diag_entries, today)
    by_file = {e["file"]: e for e in diag_entries}

    hits_by_file: dict[str, int] = {}
    for path in _target_lua_files(base_dir):
        rel = path.relative_to(base_dir).as_posix()
        raw = overrides.get(rel, path.read_text(encoding="utf-8", errors="ignore"))
        code = blank_noise(raw)
        lines = code.splitlines()
        matches = list(IS_NUI_FOCUSED_RE.finditer(code))
        if not matches:
            continue
        hits_by_file[rel] = len(matches)
        entry = by_file.get(rel)
        if entry is None:
            first_line = line_of(code, matches[0].start())
            bad.append(f"{rel}:{first_line}: unexpected IsNuiFocused/IsNuiFocusKeepingInput read (use custom-ui:IsTaken)")
            continue
        for m in matches:
            ln = line_of(code, m.start())
            line_code = lines[ln - 1]
            if GUARD_CONTEXT_RE.search(line_code):
                bad.append(
                    f"{rel}:{ln}: guard/control-flow IsNuiFocused forbidden even with diagnostic allowlist"
                )
        if len(matches) > int(entry.get("count", 0)):
            bad.append(
                f"{rel}: IsNuiFocused/IsNuiFocusKeepingInput count {len(matches)} > allowlist {entry.get('count')}"
            )

    for entry in diag_entries:
        rel = entry.get("file", "")
        actual = hits_by_file.get(rel, 0)
        if actual == 0 and rel not in overrides:
            bad.append(f"{entry.get('id')}: stale diagnostic_read allowlist entry for {rel} (0 hits)")
    return bad


def _strip_sanctioned_focus_blocks(code: str, code_with_str: str) -> str:
    chars = list(code)
    for pattern in SANCTIONED_FOCUS_BLOCKS:
        for match in pattern.finditer(code_with_str):
            chars[match.start():match.end()] = list(blank(code[match.start():match.end()]))
    return "".join(chars)


def violations_in_focus_routing(
    base_dir: Path,
    *,
    overrides: dict[str, str] | None = None,
) -> list[str]:
    """四目录内客户端入口必须走 custom-ui 焦点栈，禁止业务层裸调 SetNuiFocus*。"""
    overrides = overrides or {}
    bad: list[str] = []
    for resource, rel_files in M4_CLIENT_FILES.items():
        combined_raw: list[str] = []
        for rel in rel_files:
            path = base_dir / rel
            raw = overrides.get(rel, path.read_text(encoding="utf-8", errors="ignore"))
            combined_raw.append(raw)
            code = blank_noise(raw)
            code_with_str = blank_noise(raw, keep_strings=True)

            if LOAD_TIME_STATE_RE.search(code_with_str):
                bad.append(f"{rel}: GetResourceState('custom-ui') cached at file load time (must check at call time)")

            outside = _strip_sanctioned_focus_blocks(code, code_with_str)
            for m in SET_NUI_FOCUS_RE.finditer(outside):
                ln = line_of(outside, m.start())
                bad.append(f"{rel}:{ln}: bare SetNuiFocus* outside ApplyFocus / onResourceStop")

        joined = blank_noise("\n".join(combined_raw), keep_strings=True)
        for required in (
            "exports['custom-ui']:IsTaken(",
            "exports['custom-ui']:Push(",
            "exports['custom-ui']:Pop(",
            "exports('ApplyFocus'",
            "exports('ForceClose'",
            "onResourceStop",
        ):
            if required not in joined:
                bad.append(f"{resource}: missing required stack integration element {required}")
    return bad


def violations_in_disable_all_controls(
    base_dir: Path,
    allowlist: dict,
    *,
    today: date | None = None,
    overrides: dict[str, str] | None = None,
) -> list[str]:
    """四目录内菜单路径禁止 DisableAllControlActions；全仓其余合法点必须登记在 allowlist。"""
    today = today or date.today()
    overrides = overrides or {}
    entries = allowlist.get("entries", [])
    legit_entries = [e for e in entries if e.get("kind") == "legitimate_disable_all"]
    bad = _validate_allowlist_entries(legit_entries, today)
    by_file = {e["file"]: e for e in legit_entries}

    seen_files: set[str] = set()
    hits_by_file: dict[str, int] = {}

    for path in _all_lua_files(base_dir):
        rel = path.relative_to(base_dir).as_posix()
        seen_files.add(rel)
        raw = overrides.get(rel, path.read_text(encoding="utf-8", errors="ignore"))
        _check_disable_all_file(rel, raw, by_file, hits_by_file, bad)

    for rel, raw in sorted(overrides.items()):
        if rel in seen_files:
            continue
        _check_disable_all_file(rel, raw, by_file, hits_by_file, bad)

    for entry in legit_entries:
        rel = entry.get("file", "")
        if hits_by_file.get(rel, 0) == 0 and rel not in overrides:
            bad.append(f"{entry.get('id')}: stale legitimate_disable_all allowlist entry for {rel} (0 hits)")
    return bad


def _check_disable_all_file(
    rel: str,
    raw: str,
    by_file: dict[str, dict],
    hits_by_file: dict[str, int],
    bad: list[str],
) -> None:
    code = blank_noise(raw)
    matches = list(DISABLE_ALL_RE.finditer(code))
    if not matches:
        return
    hits_by_file[rel] = len(matches)
    if any(rel.startswith(target_dir + "/") for target_dir in M4_TARGET_DIRS):
        ln = line_of(code, matches[0].start())
        bad.append(f"{rel}:{ln}: DisableAllControlActions forbidden inside M4 target directories")
        return
    entry = by_file.get(rel)
    if entry is None:
        ln = line_of(code, matches[0].start())
        bad.append(f"{rel}:{ln}: unlisted DisableAllControlActions call site")
    elif len(matches) > int(entry.get("count", 0)):
        bad.append(f"{rel}: DisableAllControlActions count {len(matches)} > allowlist {entry.get('count')}")


def test_m4_guard_isnuifocused_zero_and_detects_injection() -> None:
    allowlist = _load_allowlist()
    assert violations_in_isnuifocused_targets(BASE, allowlist) == []

    # 反向注入 1（需求 #5）：把每个目标目录的一处 IsTaken() 换回 IsNuiFocused() 必须红
    for rel in (
        "resources/[qb]/qb-target/client.lua",
        "resources/[qb]/qb-inventory/client/main.lua",
        "resources/[qb]/qb-hud/client.lua",
        "resources/[custom]/story-engine/client/main.lua",
    ):
        real = (BASE / rel).read_text(encoding="utf-8")
        injected = real.replace("exports['custom-ui']:IsTaken()", "IsNuiFocused()", 1)
        assert injected != real, f"fixture miss in {rel}"
        caught = violations_in_isnuifocused_targets(BASE, allowlist, overrides={rel: injected})
        assert caught and any(rel in item for item in caught), f"{rel}: {caught}"

    # 反向注入 2（allowlist 互斥）：有 diagnostic allowlist 的 story-engine 若用于门卫判断仍必须红
    story_rel = "resources/[custom]/story-engine/client/main.lua"
    story_real = (BASE / story_rel).read_text(encoding="utf-8")
    story_guard = story_real + "\nlocal function badGuard()\n    if IsNuiFocused() then return true end\nend\n"
    caught_story = violations_in_isnuifocused_targets(BASE, allowlist, overrides={story_rel: story_guard})
    assert caught_story and any("guard/control-flow" in item for item in caught_story), caught_story


def test_m4_consumers_route_focus_via_custom_ui_and_rejects_bare_setnuifocus() -> None:
    assert violations_in_focus_routing(BASE) == []

    # 反向注入 1：业务路径直接出现裸 SetNuiFocus(true, true) 必须红
    target_rel = "resources/[qb]/qb-target/client.lua"
    target_real = (BASE / target_rel).read_text(encoding="utf-8")
    target_bare = target_real.replace(
        "\tacquireTargetFocus()",
        "\tSetNuiFocus(true, true)\n\tacquireTargetFocus()",
        1,
    )
    assert target_bare != target_real
    caught_bare = violations_in_focus_routing(BASE, overrides={target_rel: target_bare})
    assert any("bare SetNuiFocus*" in item for item in caught_bare), caught_bare

    # 反向注入 2：把 GetResourceState('custom-ui') 挪到文件加载期缓存必须红
    inv_rel = "resources/[qb]/qb-inventory/client/main.lua"
    inv_real = (BASE / inv_rel).read_text(encoding="utf-8")
    inv_load_time = "local cachedCustomUi = GetResourceState('custom-ui') == 'started'\n" + inv_real
    caught_load = violations_in_focus_routing(BASE, overrides={inv_rel: inv_load_time})
    assert any("file load time" in item for item in caught_load), caught_load

    # 反向注入 3：缺 ForceClose 导出必须红
    inv_no_force = inv_real.replace("exports('ForceClose'", "exports('DisabledForceClose'", 1)
    caught_missing = violations_in_focus_routing(BASE, overrides={inv_rel: inv_no_force})
    assert any("missing required stack integration element exports('ForceClose'" in item for item in caught_missing), caught_missing


def test_m4_no_disable_all_controls_and_allowlist_ratchet_detects_new_sites() -> None:
    allowlist = _load_allowlist()
    assert violations_in_disable_all_controls(BASE, allowlist) == []

    # 反向注入 1：四目录内出现 DisableAllControlActions(0) 必须红
    target_rel = "resources/[qb]/qb-target/client.lua"
    target_real = (BASE / target_rel).read_text(encoding="utf-8")
    target_bad = target_real + "\nlocal function badLoop() DisableAllControlActions(0) end\n"
    caught_target = violations_in_disable_all_controls(BASE, allowlist, overrides={target_rel: target_bad})
    assert any("forbidden inside M4 target directories" in item for item in caught_target), caught_target

    # 反向注入 2：四目录外未登记文件新增 DisableAllControlActions(0) 必须红
    caught_other = violations_in_disable_all_controls(
        BASE,
        allowlist,
        overrides={"resources/[qb]/qb-core/client/rogue.lua": "DisableAllControlActions(0)\n"},
    )
    assert any("unlisted DisableAllControlActions" in item for item in caught_other), caught_other


def test_m4_allowlist_registry_rejects_expired_or_missing_fields() -> None:
    allowlist = _load_allowlist()
    assert _validate_allowlist_entries(allowlist.get("entries", []), date.today()) == []

    expired = {
        "entries": [
            {
                **allowlist["entries"][0],
                "expires": "2020-01-01",
            }
        ]
    }
    assert any("expired" in item for item in _validate_allowlist_entries(expired["entries"], date.today()))

    no_reason = {
        "entries": [
            {
                **allowlist["entries"][0],
                "reason": "",
            }
        ]
    }
    assert any("reason" in item for item in _validate_allowlist_entries(no_reason["entries"], date.today()))
