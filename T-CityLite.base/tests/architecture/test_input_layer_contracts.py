"""输入分层的契约闸门（每条检查都能证明自己会红）。

背景见 docs/client/plans/2026-10-27-input-layering.md：
- 只有一个仲裁者（custom-ui 的交互路径栈）能决定"谁拥有输入"；
- 玩法脚本（转向灯、巡航）必须问它，不能再把"被禁用的控制被按下"当成自己的输入；
- 手机导航不得自己 DisableControlAction(172-175) —— 那正好会点亮转向灯
  （indicators.lua 读的正是 IsDisabledControlJustPressed(174/175/187)）。

每个检查都写成"纯函数吃源码"，所以既能核对真实文件，也能喂一段坏形状证明它会红。
"""

from datetime import date
import json
from pathlib import Path
import re

from lua_source import argument_spans, blank_noise, line_of

RESOURCES = Path(__file__).resolve().parents[2] / "resources" / "[custom]"


def read(relative: str) -> str:
    path = RESOURCES / relative
    assert path.is_file(), f"missing {relative}"
    return path.read_text(encoding="utf-8")


# --------------------------------------------------------------------------- #
# 纯检查：返回违规列表（空 = 合规）
# --------------------------------------------------------------------------- #

def code_only(source: str) -> str:
    """去掉 Lua 注释：注释里提到某个 API 不算用了它。"""
    return "\n".join(line.split("--", 1)[0] for line in source.splitlines())


PATH_API_EXPORTS = ("Push", "Pop", "Top", "Path", "IsTaken", "Owns", "ResetInput")


def violations_in_shared_layer(source: str) -> list[str]:
    code = code_only(source)
    bad = [f"missing export {name}" for name in PATH_API_EXPORTS if f"exports('{name}'" not in code]
    if "BLOCKED_CONTROLS" not in code:
        bad.append("no curated block list: DisableAllControlActions per frame stutters")
    if "DisableAllControlActions" in code:
        bad.append("still disabling every control each frame")
    if "inList(allow, control)" not in code:
        bad.append("the allow list is not honoured while blocking")
    return bad


def violations_in_gameplay_guards(sources: dict[str, str]) -> list[str]:
    """玩法脚本必须问 IsTaken，否则上层屏蔽控制会变成它的输入。"""
    return [f"{name} never consults IsTaken" for name, source in sources.items() if "IsTaken" not in source]


def violations_in_nav_disable(source: str) -> list[str]:
    offenders = [
        line.strip()
        for line in source.splitlines()
        if "DisableControlAction(" in line and not line.lstrip().startswith("--")
    ]
    return [f"nav disables controls: {line}" for line in offenders]


def violations_in_phone_frames(source: str) -> list[str]:
    bad = []
    if "PhoneFocus.PushFrame" not in source:
        bad.append("app changes never push a frame")
    if "phone:text" not in source:
        bad.append("focusing an input never pushes a text frame")
    return bad


def violations_in_phone_focus(source: str) -> list[str]:
    bad = []
    for needed in (
        "function PhoneFocus.PushFrame",
        "function PhoneFocus.PopFrame",
        "GetResourceState('custom-ui')",
    ):
        if needed not in source:
            bad.append(f"focus.lua missing {needed}")
    # keepInput 归 custom-ui 的栈统一设置；手机侧只在退化路径里碰它
    if "SetNuiFocusKeepInput(keepInput)" in source:
        bad.append("focus.lua sets keepInput unconditionally instead of delegating")
    # Release 必须先弹共享栈再看本地账：委托之后本地 stack 是空的，
    # 顺序反了就会"手机关了但帧还挂着"，屏蔽线程继续跑 → 玩家动不了。
    pop_at = source.find("layer:Pop(")
    local_at = source.find("if not removed then return false end")
    if pop_at == -1:
        bad.append("Release never pops the shared stack")
    elif local_at != -1 and pop_at > local_at:
        bad.append("Release consults the local stack before popping the shared one")
    return bad


# --------------------------------------------------------------------------- #
# 反向校验：每一条都必须能指出"坏形状"
# --------------------------------------------------------------------------- #

def violations_in_focus_ownership(layer_source: str, phone_source: str) -> list[str]:
    """SetNuiFocus 是按资源的：栈必须回调页面所属资源，不能自己按。

    在 custom-ui 里按焦点等于把焦点交给一个不存在的页面 —— 手机页面就收不到
    任何鼠标/键盘事件，也没有游标（真机排查了两轮才定位到）。
    """
    bad = []
    if "ownerApply" not in layer_source:
        bad.append("custom-ui applies focus itself instead of delegating to the page owner")
    if "exports[owner]:ApplyFocus" not in layer_source:
        bad.append("custom-ui never calls the owner's ApplyFocus export")
    if "exports('ApplyFocus'" not in phone_source:
        bad.append("the phone does not export ApplyFocus")
    return bad


def test_focus_ownership_gate_detects_a_layer_that_focuses_itself():
    layer = read("custom-ui/client/main.lua")
    phone = read("custom-phone/client/main.lua")
    assert violations_in_focus_ownership(layer, phone) == []

    broken_layer = "SetNuiFocus(true, true)"
    caught = violations_in_focus_ownership(broken_layer, "GetUiState")
    assert any("page owner" in item for item in caught), caught
    assert any("ApplyFocus" in item for item in caught), caught


def test_shared_layer_gate_detects_a_missing_path_api():
    real = read("custom-ui/client/main.lua")
    assert violations_in_shared_layer(real) == [], violations_in_shared_layer(real)

    broken = "exports('OpenMenu', OpenMenu)\nSetNuiFocus(true, true)\nDisableAllControlActions(0)"
    caught = violations_in_shared_layer(broken)
    assert any("IsTaken" in item for item in caught), caught
    assert any("curated block list" in item for item in caught), caught
    assert any("disabling every control" in item for item in caught), caught


def test_gameplay_guard_gate_detects_a_script_that_reads_controls_directly():
    real = {
        "custom-vehicles/client/indicators.lua": read("custom-vehicles/client/indicators.lua"),
        "custom-vehicles/client/cruise.lua": read("custom-vehicles/client/cruise.lua"),
    }
    assert violations_in_gameplay_guards(real) == [], violations_in_gameplay_guards(real)

    broken = {"custom-vehicles/client/indicators.lua": "if IsDisabledControlJustPressed(0, 174) then end"}
    caught = violations_in_gameplay_guards(broken)
    assert caught and "IsTaken" in caught[0], caught


def test_nav_gate_detects_the_phone_disabling_the_arrow_controls():
    real = read("custom-phone/client/core/nav.lua")
    assert violations_in_nav_disable(real) == [], violations_in_nav_disable(real)

    broken = "DisableControlAction(0, 174, true)\n-- DisableControlAction(0, 30, true) 注释里提到不算\n"
    caught = violations_in_nav_disable(broken)
    assert len(caught) == 1, caught
    assert "174" in caught[0], caught


def test_phone_frame_gate_detects_a_shell_without_app_or_text_frames():
    assert violations_in_phone_frames(read("custom-phone/client/main.lua")) == []
    assert violations_in_phone_focus(read("custom-phone/client/core/focus.lua")) == []

    frames = violations_in_phone_frames("RegisterNUICallback('appState', function() end)")
    assert frames, "a shell that never pushes frames must be caught"

    focus = violations_in_phone_focus("function PhoneFocus.Acquire() end")
    assert focus, "a focus module without delegation hooks must be caught"

    # 顺序反例：先看本地账、后弹共享栈 —— 真机上就是"关了但没释放"
    out_of_order = (
        "GetResourceState('custom-ui')\n"
        "function PhoneFocus.PushFrame() end\nfunction PhoneFocus.PopFrame() end\n"
        "local function Release()\nif not removed then return false end\nlayer:Pop('phone')\n"
    )
    assert any("before popping" in item for item in violations_in_phone_focus(out_of_order))

    leaky = "SetNuiFocusKeepInput(keepInput)\nGetResourceState('custom-ui')\n"
    leaky += "function PhoneFocus.PushFrame() end\nfunction PhoneFocus.PopFrame() end\n"
    assert any("keepInput" in item for item in violations_in_phone_focus(leaky))

# --------------------------------------------------------------------------- #
# V-10：传 owner 的资源必须实现 ApplyFocus（否则栈静默回退 → 面板有、光标无）
# --------------------------------------------------------------------------- #

BASE = Path(__file__).resolve().parents[2]


def _resource_sources() -> dict[str, str]:
    """把每个资源目录下的 client Lua 拼起来（只看 client，焦点与页面都在客户端）。"""
    out: dict[str, str] = {}
    for manifest in (BASE / "resources").rglob("fxmanifest.lua"):
        resource = manifest.parent
        chunk = []
        for lua in resource.rglob("*.lua"):
            if "client" not in lua.parts:
                continue
            chunk.append(code_only(lua.read_text(encoding="utf-8", errors="ignore")))
        if chunk:
            out[resource.name] = "\n".join(chunk)
    return out


def violations_in_menu_owners(sources: dict[str, str]) -> list[str]:
    """用 `OpenMenu({...owner=...})` 的资源，必须导出 ApplyFocus。

    依据（真机两轮）：SetNuiFocus 是按资源的，custom-ui 没有 ui_page；栈会回调
    `exports[owner]:ApplyFocus`，缺这个导出时 pcall 静默失败 → 回退到 custom-ui 自己按
    → 面板能显示、没有光标、点不了按钮（扣押场取款）。注释里写"文件末尾有 export"不算数，
    这里只看代码（code_only 已经剥掉注释）。
    """
    bad = []
    for name, code in sources.items():
        if "custom-ui']:OpenMenu(" not in code:
            continue
        uses_owner = "owner = GetCurrentResourceName()" in code or "owner = GetCurrentResourceName()" in code
        if not uses_owner:
            continue
        # 锚定行首，避免"注释里提到"或"字符串里提到"蒙混过关
        anchored = any(line.lstrip().startswith("exports('ApplyFocus'") for line in code.splitlines())
        if not anchored:
            bad.append(f"{name} 用 OpenMenu(owner=…) 但没有 exports('ApplyFocus')")
    return bad


def test_menu_owner_focus_gate_detects_missing_apply_focus():
    """V-10 回归：qb-garages 曾经只有注释、没有 export，真机就是"没光标"。"""
    sources = _resource_sources()
    assert violations_in_menu_owners(sources) == [], violations_in_menu_owners(sources)

    # 反向：一个传 owner 却不导出 ApplyFocus 的资源必须被抓住
    fake = {"qb-fake": "exports['custom-ui']:OpenMenu({ keepInput = false, owner = GetCurrentResourceName() })"}
    caught = violations_in_menu_owners(fake)
    assert caught and "qb-fake" in caught[0], caught

    # 反向：只有注释提到 ApplyFocus 的也必须红
    fake2 = {
        "qb-comment": "-- 真正的按下在 exports('ApplyFocus') 里\n"
        "exports['custom-ui']:OpenMenu({ keepInput = false, owner = GetCurrentResourceName() })"
    }
    assert violations_in_menu_owners(fake2), "注释里的 export 声明被当成实现了"


# --------------------------------------------------------------------------- #
# M1：ForceClose / onClientResourceStop / 单点键泵 / 单参 SetNuiFocus / menuv 记账
# --------------------------------------------------------------------------- #

ALLOWLIST_PATH = Path(__file__).with_name("input_layer_allowlist.json")
MAX_WAIT_ZERO_IN_CUSTOM_UI = 4
_CLOSURE_PARAM_NAMES = {"cb", "callback", "fn", "func", "handler", "onclose", "close"}


def _load_allowlist() -> dict:
    return json.loads(ALLOWLIST_PATH.read_text(encoding="utf-8"))


def violations_in_force_close(source: str) -> list[str]:
    """ForceClose 必须存在且不接收 Lua 闭包参数；不得再依赖 type(x)=='function'。"""
    code = blank_noise(source)
    code_with_str = blank_noise(source, keep_strings=True)
    bad: list[str] = []

    if "exports('ForceClose'" not in code_with_str and 'exports("ForceClose"' not in code_with_str:
        bad.append("missing export ForceClose")

    if re.search(r"type\s*\([^)]*\)\s*[~=]=\s*['\"]function['\"]", code_with_str):
        bad.append("still relies on type(x)=='function' instead of owner ForceClose dispatch")

    match = re.search(r"\bfunction\s+(?:Input\.)?ForceClose\s*\(", code)
    if not match:
        bad.append("missing function ForceClose definition")
        return bad

    open_idx = match.end() - 1
    params = [
        code[start:end].strip()
        for start, end in argument_spans(code, open_idx)
        if code[start:end].strip()
    ]
    if len(params) > 2:
        bad.append(f"ForceClose takes >2 params {params}: closure/callback params are forbidden")
    for param in params:
        if param.lower() in _CLOSURE_PARAM_NAMES:
            bad.append(f"ForceClose accepts closure-like param {param!r}")
    return bad


def violations_in_resource_stop(source: str) -> list[str]:
    """资源卸载/重启必须由 custom-ui 在 onClientResourceStop 里自动弹出该 owner 的全部帧。"""
    code_with_str = blank_noise(source, keep_strings=True)
    bad: list[str] = []
    if not re.search(r"AddEventHandler\s*\(\s*['\"]onClientResourceStop['\"]", code_with_str):
        bad.append("custom-ui missing onClientResourceStop handler to pop stopped owner frames")
    return bad


def violations_in_key_pump(source: str, max_wait_zero: int = MAX_WAIT_ZERO_IN_CUSTOM_UI) -> list[str]:
    """单点键泵：custom-ui 必须用 IsRawKeyDown 轮询，且 Wait(0) 不得超过棘轮上限。"""
    code = blank_noise(source)
    code_with_str = blank_noise(source, keep_strings=True)
    bad: list[str] = []

    if not re.search(r"\bIsRawKeyDown\s*\(", code):
        bad.append("custom-ui missing IsRawKeyDown single-point key pump")
    if "exports('RegisterKeyPump'" not in code_with_str:
        bad.append("custom-ui missing RegisterKeyPump export")
    if "exports('UnregisterKeyPump'" not in code_with_str:
        bad.append("custom-ui missing UnregisterKeyPump export")
    if "menu_focus_owner" not in code_with_str:
        bad.append("custom-ui missing menu_focus_owner rollback convar")

    wait_zeros = re.findall(r"\bWait\s*\(\s*0\s*\)", code)
    if len(wait_zeros) > max_wait_zero:
        bad.append(f"custom-ui Wait(0) count grew to {len(wait_zeros)} > {max_wait_zero}")

    stack_loops = re.findall(r"\bwhile\s+topFrame\s*\(\s*\)\s+do\b", code)
    if len(stack_loops) != 1:
        bad.append(f"expected exactly 1 while topFrame() do pump loop, found {len(stack_loops)}")
    return bad


def single_arg_setnui_focus_sites(resources_root: Path) -> dict[str, list[int]]:
    """找出资源树内所有单参 SetNuiFocus(...) 代码调用点（剥离注释与字符串）。"""
    sites: dict[str, list[int]] = {}
    base_dir = resources_root.parent
    for lua in sorted(resources_root.rglob("*.lua")):
        if "node_modules" in lua.parts:
            continue
        raw = lua.read_text(encoding="utf-8", errors="ignore")
        code = blank_noise(raw)
        lines: list[int] = []
        for match in re.finditer(r"\bSetNuiFocus\s*\(", code):
            open_idx = match.end() - 1
            args = [
                code[start:end].strip()
                for start, end in argument_spans(code, open_idx)
                if code[start:end].strip()
            ]
            if len(args) < 2:
                lines.append(line_of(code, match.start()))
        if lines:
            sites[lua.relative_to(base_dir).as_posix()] = lines
    return sites


def violations_in_single_arg_setnui_focus(
    resources_root: Path, allowlist: dict, today: date | None = None
) -> list[str]:
    today = today or date.today()
    sites = single_arg_setnui_focus_sites(resources_root)
    entries = allowlist.get("single_arg_setnui_focus", [])
    allowed_by_file = {entry["file"]: entry for entry in entries}
    bad: list[str] = []

    for entry in entries:
        if not entry.get("reason") or not entry.get("owner"):
            bad.append(f"{entry.get('id', '?')}: allowlist entry missing reason/owner")
        expires = entry.get("expires")
        if expires is not None:
            try:
                if date.fromisoformat(str(expires)) < today:
                    bad.append(f"{entry['id']}: allowlist entry expired on {expires}")
            except ValueError:
                bad.append(f"{entry['id']}: invalid expires date {expires!r}")
        hits = len(sites.get(entry["file"], []))
        if hits == 0 and entry.get("kind") != "vendor_exclusion":
            bad.append(f"{entry['id']}: stale allowlist entry for {entry['file']} (0 hits)")

    for rel_file, lines in sorted(sites.items()):
        entry = allowed_by_file.get(rel_file)
        if entry is None:
            bad.append(f"{rel_file}:{lines}: unexpected single-arg SetNuiFocus call(s)")
        elif len(lines) > int(entry.get("count", 0)):
            bad.append(f"{rel_file}:{lines}: single-arg SetNuiFocus count {len(lines)} > {entry['count']}")
    return bad


def violations_in_unintegrated_menu_ledger(base_dir: Path, allowlist: dict) -> list[str]:
    ledger = allowlist.get("unintegrated_menu_ledger", {})
    entries = ledger.get("entries", [])
    bad: list[str] = []
    if not entries:
        return ["unintegrated_menu_ledger has no entries"]
    shim_entries = [e for e in entries if e.get("file") == "resources/[qb]/qb-adminmenu/client/menu_shim.lua"]
    if len(shim_entries) != 1:
        bad.append("unintegrated_menu_ledger must account for qb-adminmenu/client/menu_shim.lua exactly once")
    for entry in entries:
        rel = entry.get("file", "")
        if not rel or not (base_dir / rel).is_file():
            bad.append(f"{entry.get('id', '?')}: missing file {rel!r}")
        if not entry.get("reason") or not entry.get("issue"):
            bad.append(f"{entry.get('id', '?')}: missing reason/issue")
    return bad


def test_force_close_gate_detects_closure_param_or_type_function():
    real = read("custom-ui/client/main.lua")
    assert violations_in_force_close(real) == [], violations_in_force_close(real)

    # 反向注入 1：ForceClose 接收闭包参数 → 必须红
    with_closure = real.replace(
        "function Input.ForceClose(frameId, reason)",
        "function Input.ForceClose(frameId, reason, onClose)",
    )
    if with_closure == real:
        with_closure = real + "\nfunction ForceClose(frameId, reason, onClose) end\n"
    assert violations_in_force_close(with_closure), "ForceClose receiving a closure param must fail"

    # 反向注入 2：恢复 type(x)=='function' 判据 → 必须红
    with_type_fn = real + "\nif type(current.close) == 'function' then current.close() end\n"
    assert violations_in_force_close(with_type_fn), "type(x)=='function' check must fail"

    # 反向注入 3：移除 ForceClose 导出 → 必须红
    without_export = real.replace("exports('ForceClose'", "-- removed")
    assert violations_in_force_close(without_export), "missing ForceClose export must fail"


def test_resource_stop_gate_detects_missing_on_client_resource_stop():
    real = read("custom-ui/client/main.lua")
    assert violations_in_resource_stop(real) == [], violations_in_resource_stop(real)

    # 反向注入：删掉 onClientResourceStop → 必须红
    without_stop = real.replace("onClientResourceStop", "onClientResourceStart")
    assert violations_in_resource_stop(without_stop), "missing onClientResourceStop must fail"


def test_key_pump_gate_detects_missing_raw_key_or_extra_wait_zero():
    real = read("custom-ui/client/main.lua")
    assert violations_in_key_pump(real) == [], violations_in_key_pump(real)

    # 反向注入 1：删掉 IsRawKeyDown → 必须红
    without_raw = real.replace("IsRawKeyDown", "IsDisabledControlJustPressed")
    assert violations_in_key_pump(without_raw), "missing IsRawKeyDown must fail"

    # 反向注入 2：在 custom-ui 里新增一条 Wait(0) 循环 → 必须红
    extra_loop = real + "\nCreateThread(function() while true do Wait(0) end end)\n"
    assert violations_in_key_pump(extra_loop), "extra Wait(0) loop in custom-ui must fail"


def test_single_arg_setnui_focus_gate_detects_new_call_sites(tmp_path: Path):
    allowlist = _load_allowlist()
    assert violations_in_single_arg_setnui_focus(BASE / "resources", allowlist) == []

    # 明确核实 custom-ui 为 0，且 monitor 在 allowlist 中写明理由
    sites = single_arg_setnui_focus_sites(BASE / "resources")
    assert "resources/[custom]/custom-ui/client/main.lua" not in sites
    monitor_entries = [e for e in allowlist["single_arg_setnui_focus"] if e.get("owner") == "monitor"]
    assert len(monitor_entries) == 2 and all(e.get("reason") for e in monitor_entries)

    # 反向注入：custom-ui 或其它资源新增单参 SetNuiFocus(false) → 必须红
    res_dir = tmp_path / "resources" / "[custom]" / "custom-ui" / "client"
    res_dir.mkdir(parents=True)
    (res_dir / "main.lua").write_text("SetNuiFocus(false)\n", encoding="utf-8")
    caught = violations_in_single_arg_setnui_focus(tmp_path / "resources", {"single_arg_setnui_focus": []})
    assert caught and "custom-ui" in caught[0], caught


def test_unintegrated_menu_ledger_detects_missing_shim_entry():
    allowlist = _load_allowlist()
    assert violations_in_unintegrated_menu_ledger(BASE, allowlist) == []

    # 反向：清空记账条目必须红
    assert violations_in_unintegrated_menu_ledger(BASE, {"unintegrated_menu_ledger": {"entries": []}})
    # 确认没有第二份未接入菜单记账文件
    other_ledgers = [
        p.name for p in Path(__file__).parent.glob("*allowlist*.json")
        if p.name != ALLOWLIST_PATH.name and "unintegrated_menu_ledger" in p.read_text(encoding="utf-8")
    ]
    assert other_ledgers == [], f"duplicate unintegrated menu ledgers: {other_ledgers}"


# --------------------------------------------------------------------------- #
# M1 兼容层：ForceClose 必须给「没有实现 ForceClose 导出」的 owner 留退路
# --------------------------------------------------------------------------- #

def violations_in_force_close_legacy_fallback(source: str) -> list[str]:
    """弹栈之后必须有一条退路，否则 UI 留在屏幕上。

    真机背景（2026-11-25）：`tcity-dashboard` 是唯一 `esc = true` 的帧，它只传了 `close`
    闭包、**没有导出 `ForceClose`**。旧的 Esc 路径调的就是那个闭包；改成只走
    `exports[owner]:ForceClose` 之后，按 Esc 会弹栈成功、面板却还在（鼠标被夺），
    属于比原问题更糟的回归。所以：owner 有导出 → 走新契约；没有 → 退回帧自带的 close。
    """
    code = blank_noise(source)
    match = re.search(r"\bfunction\s+(?:Input\.)?ForceClose\s*\(", code)
    if not match:
        return ["missing function ForceClose definition"]

    body = code[match.start():match.start() + 1200]
    bad: list[str] = []
    if "delivered" not in body:
        bad.append("ForceClose does not track whether the owner export actually handled the close")
    if ".close" not in body:
        bad.append("ForceClose has no legacy close fallback for owners without the export")
    return bad


def test_force_close_fallback_detects_a_missing_legacy_path():
    real = read("custom-ui/client/main.lua")
    assert violations_in_force_close_legacy_fallback(real) == [], \
        "\n".join(violations_in_force_close_legacy_fallback(real))

    # 反向注入：把回退块整段删掉（只留 owner 导出一路）必须红
    fallback = "    if not delivered and target.close ~= nil then"
    assert fallback in real, "夹具没命中：ForceClose 的回退块形状变了？"
    start = real.index(fallback)
    end = real.index("    if TriggerEvent ~= nil then", start)
    without_fallback = real[:start] + real[end:]
    assert without_fallback != real
    caught = violations_in_force_close_legacy_fallback(without_fallback)
    assert caught and any("fallback" in item for item in caught), caught
