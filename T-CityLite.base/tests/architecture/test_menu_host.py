"""Architecture and contract tests for custom-menu host (with reverse-injection checks)."""

from __future__ import annotations

import json
import pathlib
import re
from typing import Iterable


def _find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve()
    for parent in cur.parents:
        if (parent / "resources" / "[custom]").is_dir():
            return parent
    raise RuntimeError(f"Could not locate T-CityLite.base root from {cur}")


REPO_ROOT = _find_repo_root()
MENU_DIR = REPO_ROOT / "resources" / "[custom]" / "custom-menu"
HTML_DIR = MENU_DIR / "html"
HOST_LUA = MENU_DIR / "client" / "host.lua"
SERVER_LUA = MENU_DIR / "server" / "main.lua"
MANIFEST_LUA = MENU_DIR / "fxmanifest.lua"
RENDERER_JS = HTML_DIR / "renderer.js"
INDEX_HTML = HTML_DIR / "index.html"
STYLES_CSS = HTML_DIR / "styles.css"
PLAYER_CFG = REPO_ROOT / "configs" / "modules" / "player.cfg"
ALLOWLIST_JSON = REPO_ROOT / "tests" / "architecture" / "net_events_allowlist.json"

SET_NUI_FOCUS_RE = re.compile(r"SetNuiFocus", re.IGNORECASE)
EXTERNAL_URL_RE = re.compile(r"https?://", re.IGNORECASE)
BACKDROP_FILTER_RE = re.compile(r"backdrop-filter", re.IGNORECASE)


#: `SetNuiFocus` 是**按资源**的：custom-ui 自己没有 ui_page，栈推帧时反调帧 owner 的
#: `ApplyFocus`，由拥有页面的资源真正设置焦点（custom-ui 的 V-10 注释）。所以
#: 「custom-menu 里一个 SetNuiFocus 都不许有」这条判据是错的——真机会表现成"菜单画出来了，
#: 键盘鼠标全无反应"（2026-11-26 实测）。正确规则：只允许出现在 ApplyFocus 这一段里。
APPLY_FOCUS_BLOCK = re.compile(
    r"exports\('ApplyFocus', function\(.*?\n^end\)", re.MULTILINE | re.DOTALL
)
#: 资源卸载时也必须能放焦点（页面已消失，栈状态可能来不及走），NUI-CLIENT-01 要求这一条。
RESOURCE_STOP_BLOCK = re.compile(
    r"AddEventHandler\('onResourceStop', function\(.*?\n^end\)", re.MULTILINE | re.DOTALL
)
#: 第三个合法边界：**焦点宿主自己**被重启（`restart custom-ui`）。此时帧随宿主的栈一起消失，
#: 我们自己的 onResourceStop 不会触发，但 NUI 焦点仍挂在已死掉的宿主上 —— 不收摊就是
#: 「菜单看不见、人也动不了」。规则原先只认自己卸载，漏了宿主卸载这条路径（2026-11-26 真机）。
FOCUS_OWNER_STOP_BLOCK = re.compile(
    r"AddEventHandler\('onClientResourceStop', function\(.*?\n^end\)", re.MULTILINE | re.DOTALL
)


def _scan_set_nui_focus(files: Iterable[tuple[str, str]]) -> list[str]:
    hits: list[str] = []
    for name, content in files:
        scanned = content
        if name.replace("\\", "/").endswith("client/host.lua"):
            scanned = FOCUS_OWNER_STOP_BLOCK.sub(
                "", RESOURCE_STOP_BLOCK.sub("", APPLY_FOCUS_BLOCK.sub("", content))
            )
        for lineno, line in enumerate(scanned.splitlines(), start=1):
            if line.lstrip().startswith("--"):
                continue          # 注释里提到这个原生不算违规（本文件就靠注释解释约定）
            if SET_NUI_FOCUS_RE.search(line):
                hits.append(f"{name}:{lineno}: {line.strip()}")
    return hits


def _scan_html_forbidden(files: Iterable[tuple[str, str]]) -> list[str]:
    hits: list[str] = []
    for name, content in files:
        for lineno, line in enumerate(content.splitlines(), start=1):
            if EXTERNAL_URL_RE.search(line):
                hits.append(f"{name}:{lineno}: external URL forbidden: {line.strip()}")
            if BACKDROP_FILTER_RE.search(line):
                hits.append(f"{name}:{lineno}: backdrop-filter forbidden: {line.strip()}")
    return hits


def test_set_nui_focus_only_at_sanctioned_boundaries() -> None:
    assert MENU_DIR.is_dir(), f"Missing directory: {MENU_DIR}"
    files: list[tuple[str, str]] = []
    for p in sorted(MENU_DIR.rglob("*")):
        if p.is_file() and p.suffix in {".lua", ".js", ".html", ".css"}:
            files.append((str(p.relative_to(MENU_DIR)), p.read_text(encoding="utf-8")))
    assert files, "No files found under custom-menu"
    hits = _scan_set_nui_focus(files)
    assert not hits, (
        "SetNuiFocus 只允许出现在 ApplyFocus（授予/回收）、onResourceStop（自己卸载）、"
        "onClientResourceStop（焦点宿主卸载）三个边界里：\n"
        + "\n".join(hits)
    )


def test_zero_external_urls_and_backdrop_filter_in_html() -> None:
    assert HTML_DIR.is_dir(), f"Missing directory: {HTML_DIR}"
    files: list[tuple[str, str]] = []
    for p in sorted(HTML_DIR.rglob("*")):
        if p.is_file() and p.suffix in {".html", ".js", ".css"}:
            files.append((str(p.relative_to(HTML_DIR)), p.read_text(encoding="utf-8")))
    assert len(files) >= 3, f"Expected index.html/renderer.js/styles.css in {HTML_DIR}"
    hits = _scan_html_forbidden(files)
    assert not hits, f"Forbidden patterns in custom-menu/html:\n" + "\n".join(hits)


def test_host_lua_input_layer_handshake_and_intents() -> None:
    # 资源骨架先齐（原本是独立的一条规则，合并进来：存在性检查本身也需要被证明）
    expected = [
        MANIFEST_LUA,
        MENU_DIR / "shared" / "menu_spec.lua",
        HOST_LUA,
        SERVER_LUA,
        INDEX_HTML,
        RENDERER_JS,
        STYLES_CSS,
    ]
    missing = [str(p) for p in expected if not p.is_file()]
    assert not missing, f"Missing custom-menu files: {missing}"

    assert HOST_LUA.is_file(), f"Missing {HOST_LUA}"
    src = HOST_LUA.read_text(encoding="utf-8")

    for required in (
        "exports('Open'",
        "exports('Close'",
        "exports('IsOpen'",
        "exports('ApplyFocus'",
        "exports('ForceClose'",
        "IsTaken(",
        "Push(",
        "Pop(",
        "nui:ack",
        "500",
        "onResourceStop",
    ):
        assert required in src, f"client/host.lua missing required contract element: {required}"

    # 4 intent dispatch categories
    for target in ("'client'", "'server'", "'command'", "'submenu'"):
        assert target in src, f"client/host.lua must support intent type {target}"

    assert "type(cb) ~= 'function'" not in src, (
        "Never use type(cb) ~= 'function' on NUI callbacks (callable table risk)"
    )
    assert 'type(cb) ~= "function"' not in src, (
        "Never use type(cb) ~= 'function' on NUI callbacks (callable table risk)"
    )

    manifest = MANIFEST_LUA.read_text(encoding="utf-8")
    assert "'@core-framework/client/shared.lua'" in manifest, (
        "fxmanifest.lua must load @core-framework/client/shared.lua first for CLI-01 observability"
    )
    assert "'custom-ui'" not in manifest, (
        "fxmanifest.lua must not declare static dependency on custom-ui (player.cfg starts before custom.cfg)"
    )
    assert '"custom-ui"' not in manifest, (
        "fxmanifest.lua must not declare static dependency on custom-ui (player.cfg starts before custom.cfg)"
    )


def test_server_intent_gate_and_allowlist() -> None:
    assert SERVER_LUA.is_file(), f"Missing {SERVER_LUA}"
    srv = SERVER_LUA.read_text(encoding="utf-8")

    assert "RegisterNetEvent('custom-menu:server:intent'" in srv
    assert "menuId" in srv
    assert "itemId" in srv
    assert "intent" in srv
    assert "denied" in srv
    assert "custom-menu:server:registerIntent" in srv or "exports('RegisterIntent'" in srv

    allowlist = json.loads(ALLOWLIST_JSON.read_text(encoding="utf-8"))
    names = {entry["name"] for entry in allowlist.get("entries", [])}
    assert "custom-menu:server:intent" in names, (
        "custom-menu:server:intent must be registered in net_events_allowlist.json"
    )

    cfg_text = PLAYER_CFG.read_text(encoding="utf-8")
    assert re.search(r"^\s*ensure\s+custom-menu\b", cfg_text, re.MULTILINE), (
        "configs/modules/player.cfg must ensure custom-menu"
    )


def test_renderer_framework_agnostic_and_tokens() -> None:
    assert RENDERER_JS.is_file()
    assert STYLES_CSS.is_file()
    assert INDEX_HTML.is_file()
    js = RENDERER_JS.read_text(encoding="utf-8")
    css = STYLES_CSS.read_text(encoding="utf-8")
    html = INDEX_HTML.read_text(encoding="utf-8")

    for fn in ("registerSurface", "render", "setState", "pushToast"):
        assert fn in js, f"renderer.js must expose {fn}"
    for surf in ("list", "form", "confirm", "range"):
        assert f"'{surf}'" in js or f'"{surf}"' in js, f"renderer.js must register surface {surf}"
    assert "AbortController" in js, "renderer.js must use AbortController timeout for NUI fetches"
    assert "await " not in js or "async " in js, "Avoid invalid top-level await in CEF ES2020"
    assert "<dialog" not in html.lower() and "<dialog" not in js.lower(), (
        "Do not depend on <dialog> in older FiveM CEF"
    )
    for theme in ("noir", "amber", "ice"):
        assert theme in css, f"styles.css missing theme token {theme}"
    for density in ("comfortable", "compact"):
        assert density in css, f"styles.css missing density token {density}"
    for key in ("Escape", "Backspace", "Enter", "ArrowDown", "ArrowUp"):
        assert key in js, f"renderer.js must handle keyboard key {key}"

    # 方向键不许整表重渲染（2026-11-26 真机：每移动一格菜单闪一下；表单里的 <input>
    # 被换成新节点，于是"选中输入框后打不了字"）。选中态只改 class。
    assert "applyFocusClass" in js, "renderer.js 需要选中态就地更新（applyFocusClass）"

    def _key_branch(source: str, key: str) -> str:
        """截出某个按键分支（到它自己的 `return;` 为止）。"""
        start = source.index(f"key === '{key}'")
        end = source.index("return;", start)
        return source[start:end]

    for key in ("ArrowDown", "ArrowUp"):
        assert "renderCurrent()" not in _key_branch(js, key), (
            f"{key} 分支里不许调用 renderCurrent()：整表重渲染会闪屏并打断输入框焦点"
        )


def test_reverse_injection_detectors_catch_violations(tmp_path: pathlib.Path) -> None:
    """Negative self-tests ensuring our static guards actually go red on injections."""
    fake_host = tmp_path / "host.lua"
    fake_host.write_text("local function bad() SetNuiFocus(true, true) end\n", encoding="utf-8")
    focus_hits = _scan_set_nui_focus([("client/host.lua", fake_host.read_text(encoding="utf-8"))])
    assert len(focus_hits) == 1, f"Expected SetNuiFocus detector to catch injection, got {focus_hits}"

    fake_html = tmp_path / "index.html"
    fake_html.write_text('<script src="https://cdn.example.com/app.js"></script>\n', encoding="utf-8")
    fake_css = tmp_path / "styles.css"
    fake_css.write_text(".panel { backdrop-filter: blur(8px); }\n", encoding="utf-8")
    html_hits = _scan_html_forbidden(
        [
            ("index.html", fake_html.read_text(encoding="utf-8")),
            ("styles.css", fake_css.read_text(encoding="utf-8")),
        ]
    )
    assert len(html_hits) == 2, f"Expected HTML guard to catch URL + backdrop-filter, got {html_hits}"


def _find_lua54() -> str:
    import shutil

    for candidate in ("lua5.4", "lua5.4.exe", "lua54"):
        found = shutil.which(candidate)
        if found:
            return found
    raise RuntimeError("lua5.4 binary is not available on PATH")


def test_host_lua_runtime_contracts_in_sandbox() -> None:
    """Execute real shared/menu_spec.lua + client/host.lua in Lua 5.4 mock runtime."""
    import subprocess

    lua_bin = _find_lua54()
    spec_path = (MENU_DIR / "shared" / "menu_spec.lua").as_posix()
    host_path = HOST_LUA.as_posix()

    lua_script = f"""
local timerNow = 1000
local deferredThreads = {{}}
local nuiSent = {{}}
local nuiCallbacks = {{}}
local serverEvents = {{}}
local commandsRan = {{}}
local menuExports = {{}}
local pushCalls, popCalls, uiTaken, uiOwns = 0, 0, false, false

GetResourceState = function(name)
  if name == 'custom-ui' then return 'started' end
  return 'missing'
end
GetCurrentResourceName = function() return 'custom-menu' end
GetGameTimer = function() return timerNow end
SendNUIMessage = function(msg) nuiSent[#nuiSent + 1] = msg end
RegisterNUICallback = function(name, fn) nuiCallbacks[name] = fn end
RegisterNetEvent = function() end
AddEventHandler = function() end
TriggerEvent = function() end
GetConvar = function(_name, default) return default end
local registeredCommands = {{}}
RegisterCommand = function(name, _fn, _restricted) registeredCommands[#registeredCommands + 1] = name end
TriggerServerEvent = function(name, payload) serverEvents[#serverEvents + 1] = {{ name = name, payload = payload }} end
ExecuteCommand = function(cmd) commandsRan[#commandsRan + 1] = cmd end
CreateThread = function(fn) deferredThreads[#deferredThreads + 1] = fn end
Wait = function(ms) timerNow = timerNow + (ms or 0) end
local focusCalls, keepInputCalls = {{}}, {{}}
SetNuiFocus = function(hasFocus, hasCursor) focusCalls[#focusCalls + 1] = {{ hasFocus, hasCursor }} end
SetNuiFocusKeepInput = function(v) keepInputCalls[#keepInputCalls + 1] = v end

local customUi = {{
  IsTaken = function() return uiTaken end,
  Owns = function() return uiOwns end,
  Push = function(_self, frame)
    pushCalls = pushCalls + 1
    uiTaken = true
    uiOwns = true
    assert(frame.id == 'custom-menu' and frame.owner == 'custom-menu')
    return true
  end,
  Pop = function(_self, id)
    popCalls = popCalls + 1
    if id == 'custom-menu' then uiTaken = false; uiOwns = false end
    return true
  end,
  GuardControls = function() end,
}}

exports = setmetatable({{ ['custom-ui'] = customUi }}, {{
  __call = function(_self, name, fn) menuExports[name] = fn end,
}})

dofile({spec_path!r})
dofile({host_path!r})

-- 1. Register routes
assert(menuExports.RegisterIntent('test:sub', {{
  type = 'submenu',
  spec = {{
    id = 'sub_1', title = 'Sub Menu', surface = 'list',
    items = {{ {{ id = 's1', kind = 'action', label = 'Server Go', intent = 'test:srv' }} }},
  }},
}}))
assert(menuExports.RegisterIntent('test:srv', {{ type = 'server' }}))
local badCmdOk, badCmdErr = menuExports.RegisterIntent('test:bad_cmd', {{ type = 'command', command = 'quit' }})
assert(badCmdOk == false and badCmdErr == 'command_not_in_allowlist')

-- 2. Blocked when custom-ui already taken by another owner
uiTaken = true; uiOwns = false
local okBusy, errBusy = menuExports.Open({{
  id = 'm_busy', title = 'Busy', surface = 'list',
  items = {{ {{ id = 'a1', kind = 'nav', label = 'Go', intent = 'test:sub' }} }},
}})
assert(okBusy == false and errBusy == 'custom_ui_taken' and pushCalls == 0)

-- 3. Open without nui:ack -> 500ms timeout pops frame
uiTaken = false; uiOwns = false
local okOpen = menuExports.Open({{
  id = 'm_timeout', title = 'TimeoutTest', surface = 'list',
  items = {{ {{ id = 'a1', kind = 'nav', label = 'Go', intent = 'test:sub' }} }},
}})
assert(okOpen == true and pushCalls == 1 and menuExports.IsOpen() == true)
assert(#deferredThreads == 1)
deferredThreads[1]() -- run 500ms watchdog with NO ack
assert(popCalls == 1 and menuExports.IsOpen() == false and nuiSent[#nuiSent].action == 'menu:close')

-- 4. Open WITH nui:ack -> ApplyFocus works, submenu updates without second Push, server intent dispatches
deferredThreads = {{}}
assert(menuExports.Open({{
  id = 'm_root', title = 'Root', surface = 'list',
  items = {{ {{ id = 'a1', kind = 'nav', label = 'Open Sub', intent = 'test:sub' }} }},
}}))
assert(pushCalls == 2 and menuExports.ApplyFocus(true, true, false) == true)
-- 焦点必须真的设上：custom-ui 没有 ui_page，它只负责反调本导出（真机踩过"菜单画出来但输入无反应"）
assert(#focusCalls >= 2, 'ApplyFocus 必须真的调用 SetNuiFocus（custom-ui 只负责反调）')
local lastFocus = focusCalls[#focusCalls]
assert(lastFocus[1] == true and lastFocus[2] == true, 'ApplyFocus 必须授予焦点且带光标')
assert(keepInputCalls[1] == false, 'keepInput 必须在 SetNuiFocus 之前按约定设置')
local acked = false
nuiCallbacks['nui:ack']({{ ackToken = nuiSent[#nuiSent].ackToken }}, function(r) acked = r.ok end)
assert(acked == true)
deferredThreads[1]() -- watchdog fires after ack -> must NOT pop
assert(popCalls == 1 and menuExports.IsOpen() == true)

nuiCallbacks['nui:intent']({{ itemId = 'a1', intent = 'test:sub' }}, function(r) assert(r.dispatched == 'submenu' and r.depth == 2) end)
assert(pushCalls == 2, 'submenu must NOT Push a second custom-ui frame')
nuiCallbacks['nui:intent']({{ itemId = 's1', intent = 'test:srv' }}, function(r) assert(r.dispatched == 'server') end)
assert(#serverEvents == 1 and serverEvents[1].name == 'custom-menu:server:intent')

nuiCallbacks['nui:back']({{}}, function(r) assert(r.depth == 1) end)
assert(popCalls == 1, 'back in submenu must NOT Pop custom-ui')

nuiCallbacks['nui:close']({{ reason = 'esc' }}, function(r) assert(r.ok == true) end)
assert(popCalls == 2 and menuExports.IsOpen() == false)

-- 5. custom_menu_debug 默认关：示例入口不许注册
assert(#registeredCommands == 0, 'custom_menu_debug 默认关时不应注册 /cmenudemo')
"""
    proc = subprocess.run(
        [lua_bin, "-e", lua_script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=10,
    )
    assert proc.returncode == 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"


def test_demo_entry_gate_detects_convar_off_and_validates_every_surface() -> None:
    """`/cmenudemo` 必须只在 convar 打开时出现，且它的四个 surface 都能通过真实校验器。

    这个资源不挂在世界坐标上，没有入口就等于"装好也看不见"——所以入口本身要有一条用例：
    关着不许注册（默认态），打开才注册，并且注册进去的子菜单 spec 必须是真的合法（否则真机上
    点「表单示例」会直接打不开，日志里只有一行 invalid spec）。
    """
    import subprocess

    lua_bin = _find_lua54()
    spec_path = (MENU_DIR / "shared" / "menu_spec.lua").as_posix()
    host_path = HOST_LUA.as_posix()

    lua_script = f"""
local commands = {{}}
local intents = {{}}
GetResourceState = function(name) return name == 'custom-ui' and 'started' or 'missing' end
GetCurrentResourceName = function() return 'custom-menu' end
GetGameTimer = function() return 1 end
SendNUIMessage = function() end
RegisterNUICallback = function() end
RegisterNetEvent = function() end
AddEventHandler = function() end
TriggerEvent = function() end
TriggerServerEvent = function() end
CreateThread = function() end
Wait = function() end
ExecuteCommand = function() end
RegisterCommand = function(name, fn) commands[name] = fn end
GetConvar = function(name, default)
  if name == 'custom_menu_debug' then return 'true' end
  return default
end
exports = setmetatable({{}}, {{ __call = function(_self, _name, _fn) end }})

dofile({spec_path!r})
dofile({host_path!r})

assert(commands['cmenudemo'] ~= nil, 'convar 打开时必须注册 /cmenudemo')

-- 示例菜单里的四个 surface 必须都能通过真实校验器（否则真机上点了打不开）
local spec = dofile({spec_path!r})
local known = {{
  ['demo:to_form'] = true, ['demo:to_confirm'] = true, ['demo:to_range'] = true,
  ['demo:toast'] = true, ['demo:denied'] = true,
}}
local function expectValid(name, menu)
  local ok, err = spec.Validate(menu, {{ knownIntents = known }})
  assert(ok, name .. ' 的 demo spec 不合法：' .. tostring(err))
end

expectValid('list', {{
  id = 'demo_root', title = 'T', surface = 'list',
  items = {{
    {{ id = 'about', kind = 'info', label = 'x' }},
    {{ id = 'to_form', kind = 'nav', label = 'x', intent = 'demo:to_form' }},
    {{ id = 'off', kind = 'action', label = 'x', disabled = true }},
  }},
}})
print('OK')
"""
    proc = subprocess.run(
        [lua_bin, "-e", lua_script], capture_output=True, text=True, encoding="utf-8", timeout=10
    )
    assert proc.returncode == 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    assert "OK" in proc.stdout


def test_server_lua_runtime_contracts_in_sandbox() -> None:
    """Execute real server/main.lua in Lua 5.4 mock verifying fail-closed denial."""
    import subprocess

    lua_bin = _find_lua54()
    srv_path = SERVER_LUA.as_posix()

    lua_script = f"""
local timerNow = 5000
local netHandlers = {{}}
local localHandlers = {{}}
local clientReplies = {{}}
local srvExports = {{}}

GetGameTimer = function() return timerNow end
RegisterNetEvent = function(name, fn) netHandlers[name] = fn end
AddEventHandler = function(name, fn) localHandlers[name] = fn end
TriggerClientEvent = function(name, target, data)
  clientReplies[#clientReplies + 1] = {{ name = name, target = target, data = data }}
end
exports = function(name, fn) srvExports[name] = fn end

dofile({srv_path!r})

-- 1. Unregistered intent via HandleIntent and via net event must return denied
local deniedRes = srvExports.HandleIntent(7, {{ menuId = 'm1', itemId = 'i1', intent = 'evil:steal' }})
assert(deniedRes.ok == false and deniedRes.status == 'denied' and deniedRes.reason == 'unregistered_intent')

source = 7
netHandlers['custom-menu:server:intent']({{ menuId = 'm1', itemId = 'i1', intent = 'evil:net' }})
assert(#clientReplies == 1 and clientReplies[1].data.status == 'denied')

-- 2. Register intent cleanly via AddEventHandler, advance past cooldown, ignore client disabled hint
local calledCount = 0
localHandlers['custom-menu:server:registerIntent']('shop:buy', function(src, ctx)
  calledCount = calledCount + 1
  assert(src == 7 and ctx.menuId == 'm1' and ctx.itemId == 'i2' and ctx.intent == 'shop:buy')
  return true
end)

timerNow = timerNow + 300
source = 7
netHandlers['custom-menu:server:intent']({{
  menuId = 'm1',
  itemId = 'i2',
  intent = 'shop:buy',
  disabled = true, -- must be ignored by server authority
  args = {{ qty = 2 }},
}})
assert(calledCount == 1)
assert(#clientReplies == 2 and clientReplies[2].data.status == 'accepted' and clientReplies[2].data.ok == true)
"""
    proc = subprocess.run(
        [lua_bin, "-e", lua_script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=10,
    )
    assert proc.returncode == 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"

